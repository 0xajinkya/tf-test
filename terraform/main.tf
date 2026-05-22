data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  # default_tags in the provider block already applies project + environment to
  # every resource; per-resource Name tag is added inline.
  name = "${var.project_name}-${var.environment}"
}

resource "random_id" "artifact_suffix" {
  byte_length = 4
}

# S3 bucket for build artifacts that VMs pull on deploy.
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts-${random_id.artifact_suffix.hex}"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Active release pointer, written by the deploy workflow.
# Initial value is a placeholder; the first `deploy.yml` run overwrites it
# with the real git SHA and the lifecycle block keeps Terraform from reverting.
resource "aws_ssm_parameter" "active_release" {
  name  = "/${var.project_name}/active_release"
  type  = "String"
  value = "pending-first-deploy"

  lifecycle {
    ignore_changes = [value]
  }
}

# CloudWatch log groups
resource "aws_cloudwatch_log_group" "service" {
  for_each          = toset(["gateway", "engine", "caller-worker", "inference-worker"])
  name              = "/${var.project_name}/${each.key}"
  retention_in_days = 14
}
