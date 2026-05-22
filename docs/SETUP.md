# Setup — from zero to working iii API on AWS

Walks a fresh AWS account through deploying this stack end-to-end. ~30 min total.

## 0. Prerequisites

| Tool | Minimum version | Install |
|------|-----------------|---------|
| `terraform` | 1.7 | `brew install terraform` |
| `aws-cli` | v2 | `brew install awscli` |
| `gh` | 2.40 | `brew install gh` |
| `jq` | any | `brew install jq` |
| `git` | any | usually preinstalled |

AWS account with **administrator-level credentials** for the bootstrap phase. After bootstrap, day-to-day work uses a scoped deploy role.

GitHub account that owns the repo you push from. CI uses GitHub OIDC — no static AWS keys stored anywhere.

## 1. Clone + configure AWS CLI

```bash
git clone https://github.com/<your-fork>/dev-ops.git
cd dev-ops

# Authenticate (pick one)
aws configure sso           # preferred
# OR
aws configure               # static keys

aws sts get-caller-identity # sanity-check
```

## 2. Bootstrap Terraform remote state

Creates S3 bucket + DynamoDB lock table that hold Terraform state. One-time per AWS account.

```bash
export AWS_REGION=us-east-1
./scripts/bootstrap-state.sh create
```

Output gives you:
- `TF_STATE_BUCKET` = `iii-tf-state-<account-id>`
- `TF_LOCK_TABLE` = `iii-tf-lock`

Save both — you'll need them in GitHub.

## 3. Configure `terraform.tfvars`

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
```

Required edits:
```hcl
github_repo = "your-username/dev-ops"   # MUST match exact GitHub repo path
```

Optional but recommended:
```hcl
allowed_ingress_cidrs = ["<your_ip>/32"]    # find via: curl -s ifconfig.me
gguf_model_url        = "<huggingface URL>" # default is TinyLlama 1.1B
rate_limit_per_minute = 60
```

## 4. First `terraform apply`

```bash
cd terraform

terraform init \
  -backend-config="bucket=iii-tf-state-<account-id>" \
  -backend-config="key=iii/prod/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=iii-tf-lock" \
  -backend-config="encrypt=true"

terraform plan -out tfplan      # review
terraform apply tfplan
```

Takes ~3 min for AWS to provision. ~5-10 min more for cloud-init on each VM (inference VM longest: llama-cpp-python compile + GGUF download).

Capture outputs:
```bash
terraform output
```
Save: `api_endpoint`, `artifact_bucket`, `deploy_role_arn`, `ssm_deploy_document`.

## 5. Wait for cloud-init to finish on every VM

```bash
for IID in $(aws ec2 describe-instances --filters "Name=tag:app,Values=iii" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text); do
  echo "$IID..."
  aws ssm send-command --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["cloud-init status --wait"]' \
    --query 'Command.CommandId' --output text
done
```

Wait until all four return `status: done` (not `running`).

## 6. Configure GitHub repo (one-time)

### a. Set repo Variables

`Settings → Secrets and variables → Actions → Variables tab`:

| Variable | Value |
|----------|-------|
| `AWS_DEPLOY_ROLE_ARN` | `terraform output -raw deploy_role_arn` |
| `ARTIFACT_BUCKET` | `terraform output -raw artifact_bucket` |
| `SSM_DEPLOY_DOCUMENT` | `terraform output -raw ssm_deploy_document` |
| `TF_STATE_BUCKET` | from step 2 |
| `TF_LOCK_TABLE` | from step 2 |

### b. Create GitHub Environments

`Settings → Environments → New environment`:
- `prod` (required)
- `stage` (only if/when enabling the `dev` branch later)

Optionally add required reviewers on `prod` for manual gating.

## 7. Set API keys in SSM

```bash
KEY=$(openssl rand -hex 16)
echo "API key: $KEY"   # save this; share with users

aws ssm put-parameter --region us-east-1 \
  --name /iii/api_keys --type SecureString --overwrite \
  --value "$KEY"
```

For multiple keys, comma-separate: `--value "key1,key2,key3"`.

## 8. First deploy via CI

Push any commit to `main`, or trigger manually:

```bash
gh workflow run deploy.yml --ref main
gh run watch
```

CI does:
1. Build worker bundles (`npm run build` for TS, `tar` for Python).
2. Assume the deploy role via OIDC (no stored AWS creds).
3. Upload bundles to S3.
4. Pin SSM parameter `/iii/active_release` to git SHA.
5. SSM RunCommand: every VM pulls the new artifact, restarts its service.
6. Smoke-test `$API/healthz`.

First deploy: ~10-15 min (llama-cpp-python compile on inference VM). Subsequent deploys: ~1-2 min.

## 9. Sanity check

```bash
API=$(cd terraform && terraform output -raw api_endpoint)

curl -sS "$API/healthz"          # expect: "ok"

curl -sS -X POST "$API/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $KEY" \
  -d '{
    "model": "inference-worker",
    "messages": [{"role":"user","content":"hi"}],
    "max_tokens": 32
  }' | jq
```

First response: cold model load, 5-15s. After that: 1-3s on TinyLlama.

## 10. Sharing the endpoint

See [API.md](API.md) for request/response schema. Minimum hand-over message:

```
URL:      http://<gateway_public_ip>
Auth:     header X-API-Key: <key>
Endpoint: POST /v1/chat/completions
Docs:     <link to your fork's API.md>
Rate:     60 req/min/key
```

Caveats to disclose:
- HTTP, not HTTPS. Path observers see payloads.
- Single instance. Restart = downtime.
- Public IP changes if the instance is replaced (use an Elastic IP or Route 53 to stabilize — see "Stabilising the endpoint" below).

---

## Caveats and gotchas

### Costs (us-east-1, on-demand)

| Resource | Hourly | Notes |
|----------|--------|-------|
| NAT gateway | ~$0.045 | Biggest line item |
| 4 × EC2 (t3.small + t3.large + 2 × t3.small) | ~$0.16 | Bulk |
| EIP (only if you add one) | ~$0.005 | If unattached |
| S3 / SSM / CloudWatch | < $1/mo | Small |

**~$5/day idle.** Run `terraform destroy` when not in use.

### AWS region

Defaults to `us-east-1`. Change `var.region` + `var.azs` for another region. VPC endpoint service names and CloudWatch agent S3 URL auto-pick the region.

### Quotas

Fresh AWS accounts have low EC2 quotas. If apply fails with `VcpuLimitExceeded`, request a quota increase under **Service Quotas → EC2 → All Standard (A, C, D, H, I, M, R, T, Z) instances** (default = 32 vCPU, the stack uses ~6).

### Python version

iii-sdk requires Python ≥3.10. AL2023's `python3` is 3.9. The inference VM installs `python3.11` explicitly. If you swap AMIs, verify Python version.

### llama-cpp-python compile time

First boot of the inference VM takes 5-8 min for the native compile. To skip this on every redeploy, either:
- Switch to `--only-binary=llama-cpp-python` in `requirements.txt` (uses prebuilt wheel; smaller chance of CUDA support).
- Bake a custom AMI with Packer once the stack is stable.

### iii config schema

Top-level keys are `workers:` only (no `engine:` block). Engine WS port is set inside the `iii-worker-manager` worker. Default port `49134` (WS), `3111` (iii-http HTTP). If you upgrade iii minor version, re-read [the upstream config example](https://github.com/iii-hq/iii/blob/main/engine/config.yaml) — schema may evolve.

### SSM Session Manager only

There is no SSH (no port 22 open anywhere). Use `aws ssm start-session --target <instance-id>` for shell access. Requires the SSM agent (preinstalled on AL2023) + outbound HTTPS to the SSM VPC endpoint (already configured).

### Cloud-init log location

Two log files matter on every VM:
- `/var/log/iii-userdata.log` — your bootstrap script (ours, via `tee`).
- `/var/log/cloud-init-output.log` — full cloud-init output, including stderr.

`sudo cloud-init status --long` tells you if cloud-init succeeded, errored, or is still running.

### GitHub OIDC trust policy

The deploy role trusts `repo:OWNER/REPO:ref:refs/heads/main` AND `repo:OWNER/REPO:environment:prod` (because the deploy job has `environment: prod`, which changes the OIDC `sub` claim). If you fork or rename the repo, update `var.github_repo` and re-apply.

To enable stage: add `dev` to `var.github_branches` and `stage` to `var.github_environments` in tfvars, then re-apply. Workflow already ternary-routes `main → prod` / `dev → stage`.

### Cost alerts

Add a billing alarm before leaving the stack idle:

```bash
aws budgets create-budget --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{"BudgetName":"iii-prod","BudgetLimit":{"Amount":"50","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"you@example.com"}]}]'
```

### Stabilising the endpoint

For a permanent IP / domain:

1. **Elastic IP** (5 min, free while attached):
   ```hcl
   resource "aws_eip" "gateway" {
     instance = aws_instance.gateway.id
     domain   = "vpc"
   }
   ```
   Update `output "api_endpoint"` to use `aws_eip.gateway.public_ip`.

2. **Route 53 A record** pointing at the EIP — gives a stable URL.

3. **ACM cert + ALB** in front for HTTPS. Documented in [HARDENING.md](HARDENING.md).

### Rotating API keys

```bash
NEW=$(openssl rand -hex 16)
aws ssm put-parameter --name /iii/api_keys --type SecureString \
  --value "$NEW" --overwrite

# Bounce caller-worker so it re-reads
aws ssm send-command --document-name iii-prod-deploy \
  --targets "Key=tag:role,Values=caller-worker" \
  --parameters "release=$(aws ssm get-parameter --name /iii/active_release --query Parameter.Value --output text)"
```

To support multiple active keys during rotation, comma-separate: `--value "old_key,new_key"`.

### Swapping the model

```bash
# In terraform.tfvars
gguf_model_url = "https://huggingface.co/<org>/<repo>/resolve/main/<file>.gguf"
gguf_n_ctx     = 4096

terraform apply   # inference VM replaces, downloads new model
```

For larger models (>2 GB), bump `var.instance_types.inference_worker` and the EBS volume size in `terraform/ec2.tf`. See [SCALE-100X.md](SCALE-100X.md) for GPU options.

## Teardown

```bash
cd terraform
terraform destroy
```

Removes: VPC, NAT, EC2, IAM, SGs, S3 artifact bucket (versioned — empties on destroy via `force_destroy = false`, so you may need to empty manually first), SSM params, log groups.

**Kept:**
- Terraform state bucket (`iii-tf-state-...`) + DynamoDB lock table — drop with `./scripts/bootstrap-state.sh destroy` only if truly done with the account.
- CloudWatch log groups — retention is 14 days so they fade automatically.

Always run `terraform destroy` from the same workstation that did `apply` (state bucket access required).

## When things break — quick reference

| Symptom | First look |
|---------|-----------|
| CI deploy fails `AssumeRoleWithWebIdentity` | `var.github_repo` mismatch with actual repo path. Re-apply. |
| CI deploy fails `NoSuchBucket` | `ARTIFACT_BUCKET` repo var stale. `terraform output -raw artifact_bucket` and update. |
| `Wait for SSM completion` times out | First deploy needs >5 min for inference compile. Default already bumped to 15 min in CI loop. |
| 502 from API | `iii-engine` failed to start. `sudo journalctl -u iii-engine -n 50` on engine VM. |
| 401 `unauthorized` | Wrong / missing `X-API-Key`. Or caller-worker didn't reload after key rotation. |
| 429 `rate_limited` | Hit per-key bucket. `var.rate_limit_per_minute` to raise. |
| Engine `unknown field` parse error | iii config schema changed upstream. Re-fetch from [iii engine repo](https://github.com/iii-hq/iii/blob/main/engine/config.yaml). |
| `ModuleNotFoundError` Python | Python version <3.10. inference VM must use `python3.11`. |

[RUNBOOK.md](RUNBOOK.md) has more debugging recipes.
