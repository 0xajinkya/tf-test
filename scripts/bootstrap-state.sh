#!/usr/bin/env bash
# Create or destroy the S3 bucket + DynamoDB table used as Terraform remote state.
# Run once per AWS account before the first `terraform init`.
set -euo pipefail

PROJECT="${PROJECT:-iii}"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${PROJECT}-tf-state-${ACCOUNT_ID}"
TABLE="${PROJECT}-tf-lock"

cmd="${1:-create}"

case "$cmd" in
  create)
    echo "==> creating bucket $BUCKET in $REGION"
    if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
      if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
      else
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
          --create-bucket-configuration "LocationConstraint=$REGION"
      fi
    fi
    aws s3api put-bucket-versioning --bucket "$BUCKET" \
      --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
      '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}'

    echo "==> creating dynamodb table $TABLE"
    if ! aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
      aws dynamodb create-table --table-name "$TABLE" --region "$REGION" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST
      aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
    fi

    cat <<EOF

State bootstrap complete.

Add these to GitHub repo Variables (Settings → Variables → Actions):
  TF_STATE_BUCKET     $BUCKET
  TF_LOCK_TABLE       $TABLE
  AWS_DEPLOY_ROLE_ARN <set after first 'terraform apply' from output deploy_role_arn>

Init Terraform locally:
  cd terraform
  terraform init \\
    -backend-config="bucket=$BUCKET" \\
    -backend-config="key=$PROJECT/prod/terraform.tfstate" \\
    -backend-config="region=$REGION" \\
    -backend-config="dynamodb_table=$TABLE" \\
    -backend-config="encrypt=true"
EOF
    ;;

  --destroy|destroy)
    echo "WARNING: this deletes $BUCKET and $TABLE."
    read -r -p "Type 'yes' to continue: " ack
    [ "$ack" = "yes" ] || { echo "aborted"; exit 1; }
    aws s3 rm "s3://$BUCKET" --recursive || true
    aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" || true
    aws dynamodb delete-table --table-name "$TABLE" --region "$REGION" || true
    ;;

  *)
    echo "usage: $0 [create|destroy]" >&2
    exit 1
    ;;
esac
