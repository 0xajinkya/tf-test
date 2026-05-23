# ---------- Instance role: SSM + read artifacts + push logs ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vm" {
  name               = "${local.name}-vm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "vm_ssm" {
  role       = aws_iam_role.vm.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "vm_cw_agent" {
  role       = aws_iam_role.vm.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "vm_inline" {
  statement {
    sid       = "ReadArtifacts"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "ReadActiveRelease"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [aws_ssm_parameter.active_release.arn]
  }
  statement {
    sid       = "ReadAPIKeys"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.api_keys_ssm_path}"]
  }
}

# Placeholder API-keys param. Update value out-of-band via:
#   aws ssm put-parameter --name /iii/api_keys --type SecureString \
#     --value "key1,key2,key3" --overwrite
resource "aws_ssm_parameter" "api_keys" {
  name      = var.api_keys_ssm_path
  type      = "SecureString"
  value     = "changeme-rotate-via-cli"
  overwrite = true

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_iam_role_policy" "vm_inline" {
  name   = "${local.name}-vm-inline"
  role   = aws_iam_role.vm.id
  policy = data.aws_iam_policy_document.vm_inline.json
}

resource "aws_iam_instance_profile" "vm" {
  name = "${local.name}-vm"
  role = aws_iam_role.vm.name
}

# ---------- Deploy role: trusted by GitHub OIDC ----------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_oidc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = concat(
        [for b in var.github_branches : "repo:${var.github_repo}:ref:refs/heads/${b}"],
        [for e in var.github_environments : "repo:${var.github_repo}:environment:${e}"],
      )
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${local.name}-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume.json
}

data "aws_iam_policy_document" "deploy_inline" {
  statement {
    sid       = "UploadArtifacts"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:AbortMultipartUpload"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "PinRelease"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = [aws_ssm_parameter.active_release.arn]
  }
  statement {
    sid       = "RunDeployDocument"
    actions   = ["ssm:SendCommand", "ssm:ListCommands", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
  statement {
    sid       = "DescribeEc2"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy_inline" {
  name   = "${local.name}-deploy-inline"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_inline.json
}

# ---------- SSM document used by the deploy workflow ----------

resource "aws_ssm_document" "deploy" {
  name            = "${local.name}-deploy"
  document_type   = "Command"
  document_format = "YAML"

  content = <<-DOC
    schemaVersion: "2.2"
    description: "Pull and restart iii service on this VM"
    parameters:
      release:
        type: String
        description: "Git SHA or release tag"
        default: "main"
    mainSteps:
      - action: aws:runShellScript
        name: pullAndRestart
        inputs:
          runCommand:
            - "set -euo pipefail"
            - "TOKEN=$(curl -sX PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
            - "ROLE=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/tags/instance/role)"
            - "REL={{ release }}"
            - "if [ \"$ROLE\" = \"gateway\" ]; then systemctl reload nginx; exit 0; fi"
            - "if [ \"$ROLE\" = \"engine\" ]; then systemctl restart iii-engine; exit 0; fi"
            - "ART=s3://${aws_s3_bucket.artifacts.id}/$REL/$ROLE.tar.gz"
            - "mkdir -p /opt/iii/releases/$REL"
            - "aws s3 cp $ART /tmp/$ROLE.tar.gz"
            - "tar -xzf /tmp/$ROLE.tar.gz -C /opt/iii/releases/$REL"
            - "ln -sfn /opt/iii/releases/$REL /opt/iii/current"
            - "if [ \"$ROLE\" = \"caller-worker\" ]; then cd /opt/iii/current && npm install --omit=dev --no-audit --no-fund && chown -R iii:iii node_modules; fi"
            - "if [ \"$ROLE\" = \"inference-worker\" ]; then [ -x /opt/iii/venv/bin/pip ] || python3.11 -m venv /opt/iii/venv; /opt/iii/venv/bin/pip install --upgrade pip wheel; /opt/iii/venv/bin/pip install -r /opt/iii/current/requirements.txt; chown -R iii:iii /opt/iii/venv; fi"
            - "systemctl daemon-reload"
            - "systemctl restart iii-$ROLE.service"
  DOC
}
