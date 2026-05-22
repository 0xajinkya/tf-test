# Runbook

## Prerequisites

| Tool | Version |
|------|---------|
| terraform | ≥ 1.7 |
| aws-cli | v2 |
| gh | ≥ 2.40 (for OIDC bootstrap) |
| jq | any |

AWS account with admin or sufficient IAM to create VPC, EC2, IAM roles, S3, DynamoDB, SSM parameters.

## First deploy

```bash
# 1. Bootstrap remote state (one-time, manual)
./scripts/bootstrap-state.sh           # creates S3 bucket + DynamoDB lock table

# 2. Configure
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars     # set project_name, region, allowed_ingress_cidrs

# 3. Apply
cd terraform
terraform init
terraform plan -out tfplan
terraform apply tfplan

# 4. Wait for cloud-init (~3 min) then probe
API=$(terraform output -raw api_endpoint)
curl -s "$API/healthz"
```

## GitHub setup (one-time, after first apply)

After `terraform apply` succeeds, capture outputs and set GitHub repo Variables (Settings → Secrets and variables → Actions → Variables):

| Variable | Value (source) |
|----------|----------------|
| `AWS_DEPLOY_ROLE_ARN` | `terraform output -raw deploy_role_arn` |
| `ARTIFACT_BUCKET` | `terraform output -raw artifact_bucket` |
| `TF_STATE_BUCKET` | from `scripts/bootstrap-state.sh` |
| `TF_LOCK_TABLE` | from `scripts/bootstrap-state.sh` |
| `AWS_PLAN_ROLE_ARN` | (optional, for `terraform-plan` workflow) |

Also create two GitHub Environments:
- `prod` — used by `deploy.yml`. Add required reviewers if you want manual approvals.
- `prod-plan` — used by `terraform-plan.yml`.

## Redeploy app code

Push to `main`. The `deploy.yml` workflow:

1. Builds `caller-worker` (`npm run build`) and packages `inference-worker` as a tarball.
2. Uploads both to `s3://<artifact_bucket>/<git-sha>/`.
3. Writes the active SHA to SSM parameter `/iii/active_release`.
4. Invokes SSM RunCommand on instances tagged `app in {caller-worker, inference-worker, gateway, engine}` to:
   - Download the new artifact from S3.
   - Stop the systemd unit.
   - Swap symlink `current → <sha>`.
   - Start the unit.
5. Polls `GET /healthz` until 200 OK or 5-minute timeout.

## Rollback

```bash
# List recent releases
aws s3 ls s3://$ARTIFACT_BUCKET/ | tail

# Pin previous SHA
PREV_SHA=abcdef0
aws ssm put-parameter --name /iii/active_release --value "$PREV_SHA" --overwrite

# Re-run the deploy doc
aws ssm send-command \
  --document-name iii-deploy \
  --targets "Key=tag:project,Values=iii"
```

## Debug

```bash
# List managed instances
aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,Tags]' --output table

# Open a session (no SSH, no port 22)
aws ssm start-session --target i-0123456789abcdef0

# On the instance:
sudo systemctl status iii-engine
sudo journalctl -u iii-engine -f -n 200
```

CloudWatch:

```bash
aws logs tail /iii/gateway --follow
aws logs tail /iii/engine --since 10m
```

## Destroy

```bash
cd terraform
terraform destroy
```

State bucket and DynamoDB table are intentionally **not** destroyed — drop them manually with `scripts/bootstrap-state.sh --destroy` if you really want to.
