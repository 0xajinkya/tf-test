# Troubleshooting log — bootstrap to first deploy

A chronological record of every issue hit while bringing the `iii-prod` stack up from a fresh laptop, what caused each, and how it was fixed. Use this as a recipe when re-bootstrapping or when training a teammate.

---

## 1. `terraform` not installed

**Symptom**
```
zsh: command not found: terraform
```

**Cause**
Terraform binary not present on the workstation.

**Fix**
HashiCorp removed Terraform from the default Homebrew formulae (BSL licence change in 2023). Install via the official tap:
```
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform -version
```
Alternative: `brew install opentofu` (OpenTofu is a drop-in fork).

---

## 2. `terraform init` — literal placeholder in bucket name

**Symptom**
```
Error: Failed to get existing workspaces: ... InvalidBucketName:
The specified bucket is not valid.
Bucket: "iii-tf-state-<account-id>"
```

**Cause**
The `<account-id>` placeholder in the `-backend-config="bucket=..."` flag was passed literally; the shell did not expand it.

**Fix**
Resolve the account ID first:
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init \
  -backend-config="bucket=iii-tf-state-${ACCOUNT_ID}" \
  -backend-config="key=iii/prod/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=iii-tf-lock" \
  -backend-config="encrypt=true"
```

---

## 3. Bootstrap script — no AWS credentials

**Symptom**
```
Unable to locate credentials. You can configure credentials by running "aws login".
```
after `aws sso login --profile ajinkya` succeeded.

**Cause**
The SSO session is bound to a named profile; the bootstrap script uses the default credential chain, which had no fallback creds.

**Fix**
Export the profile in the current shell:
```
export AWS_PROFILE=ajinkya
aws sts get-caller-identity   # verify
./scripts/bootstrap-state.sh create
```

---

## 4. `terraform apply` — non-ASCII in Security Group description

**Symptom**
```
Error: creating Security Group (iii-prod-worker):
api error InvalidParameterValue: Value (Workers — egress only) for parameter
GroupDescription is invalid. Character sets beyond ASCII are not supported.
```

**Cause**
EC2 rejects non-ASCII characters in SG descriptions. The file contained an em-dash (`—`, U+2014).

**Fix**
Edit `terraform/security-groups.tf` line 17 — replace `—` with `-`. Run a sanity check across all `.tf` files:
```
grep -rnP "[^\x00-\x7F]" terraform/
```
Only `#` comments allowed to contain non-ASCII (never sent to AWS).

---

## 5. Stale state lock after a failed apply

**Symptom**
```
Error: Error acquiring the state lock
ConditionalCheckFailedException: The conditional request failed
ID: fa54ddae-93f1-5aa0-a3de-948ebb1e7289
```

**Cause**
Previous `terraform apply` died mid-flight without releasing the DynamoDB lock row.

**Fix**
Force-unlock from inside the Terraform directory:
```
cd terraform
terraform force-unlock <lock-id>
```
Only safe when no other Terraform process is running.

Subtle trap: running `terraform force-unlock` from the repo root (one level above `terraform/`) tries to unlock a non-existent **local** backend and prints:
```
Local state cannot be unlocked by another process
```
Always `cd terraform` first.

---

## 6. `aws ssm describe-instance-information` returns nothing

**Symptom**
No output, no error.

**Cause**
`AWS_DEFAULT_REGION` not set; the call landed in a region with no instances.

**Fix**
Always pass `--region us-east-1` (or export `AWS_DEFAULT_REGION=us-east-1`):
```
aws ssm describe-instance-information --region us-east-1 --output table
```

---

## 7. `aws ssm start-session` — `TargetNotConnected`

**Symptom**
```
TargetNotConnected: i-... is not connected.
```

**Cause checklist (in order of likelihood)**
1. SSM agent has not finished registering yet (1–3 min after boot).
2. CLI defaulting to a different region.
3. Instance role missing `AmazonSSMManagedInstanceCore`.
4. SSM interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) missing or not in the instance's AZ.
5. VPC-endpoint SG not allowing 443 from the instance SG.

**Fix**
Wait, retry with `--region`. If still failing, verify with:
```
aws ssm describe-instance-information --region us-east-1 \
  --query 'InstanceInformationList[?InstanceId==`i-...`]'
aws ec2 describe-instances --region us-east-1 --instance-ids i-... \
  --query 'Reservations[].Instances[].[IamInstanceProfile.Arn,Placement.AvailabilityZone]'
```

---

## 8. `SessionManagerPlugin is not found`

**Symptom**
```
SessionManagerPlugin is not found. Please refer to SessionManager Documentation ...
```

**Cause**
The AWS CLI ships without the binary that streams SSM session traffic.

**Fix**
```
brew install --cask session-manager-plugin
session-manager-plugin --version
```

---

## 9. Cloud-init `apt` fails on Ubuntu instances

**Symptom**
Repeated `Could not connect to us-east-1.ec2.archive.ubuntu.com:80` and `security.ubuntu.com:80` followed by:
```
E: Package 'awscli' has no installation candidate
```

**Root causes (compounding)**
1. The egress security groups (gateway, engine, worker) allowed only port 443. Apt uses port 80 — blocked.
2. Ubuntu 24.04 (Noble) removed the `awscli` package from `apt` entirely — it now ships only as a snap or via the official `awscli-exe-linux-x86_64.zip`. So even with internet, `apt-get install awscli` would have failed.

**Fix**
Migrate the four instances (gateway + engine + inference-worker + caller-worker) to **Amazon Linux 2023**:

- `data.aws_ami.al2023` filters on `al2023-ami-2023.*-x86_64`, owner `137112412989`.
- `awscli` v2 is preinstalled.
- Default yum repositories are served from regional S3 buckets, reachable through the existing **S3 gateway endpoint** without any internet egress or NAT.

User-data rewrites (`apt-get` → `dnf -y`, `python3-venv` → `python3-pip`, `build-essential` → `gcc gcc-c++ make`, etc.) live in `terraform/user-data/*.sh.tftpl`.

---

## 10. AL2023 — `curl` / `curl-minimal` conflict

**Symptom**
Thousands of lines like:
```
package curl-minimal-8.17.0-1.amzn2023.0.3.x86_64 from amazonlinux conflicts
with curl provided by curl-8.15.0-4.amzn2023.0.1.x86_64 from amazonlinux
(try to add '--allowerasing' to command line ...)
```

**Cause**
AL2023 ships `curl-minimal` as the default. `dnf install curl` attempts to swap that for the full `curl` package — a conflicting upgrade path that dnf refuses without explicit consent.

**Fix (two-layer)**
- Drop the `curl` token from every `dnf -y install ...` line. `curl-minimal` already exposes the `curl` binary.
- Add `--allowerasing` to the `dnf -y install ...` invocations so future minor conflicts (e.g. `coreutils-single` vs `coreutils`) resolve automatically.

Applied across all four `user-data/*.sh.tftpl` files.

---

## 11. User-data changes did not replace running instances

**Symptom**
After editing `user-data/*.sh.tftpl`, `terraform apply` showed in-place updates only. Instances kept the broken first-boot state.

**Cause**
By default Terraform records `user_data` as a metadata diff; it doesn't recreate the EC2 instance because cloud-init only runs on first boot.

**Fix**
Add to each `aws_instance` block:
```hcl
user_data_replace_on_change = true
```
Next apply tears the instance down and recreates it, triggering cloud-init fresh.

---

## 12. CloudWatch agent — invalid `journald` source

**Symptom**
```
E! Invalid Json input schema.
Under path : /logs/logs_collected | Error : Additional property journald is not allowed
configuration validation first phase failed. Agent version: 1.0
```

**Cause**
The CloudWatch agent JSON schema does **not** support a `journald` source under `logs_collected`. Only `files`, `windows_events`, etc.

**Fix**
1. Re-wire systemd units to write directly to a file:
   ```ini
   StandardOutput=append:/var/log/iii/<role>.log
   StandardError=append:/var/log/iii/<role>.log
   ```
2. Point the CW agent at that file plus the cloud-init log:
   ```jsonc
   "logs": { "logs_collected": { "files": { "collect_list": [
     { "file_path": "/var/log/iii/<role>.log",
       "log_group_name": "/iii/<role>",
       "log_stream_name": "{instance_id}" },
     { "file_path": "/var/log/iii-userdata.log",
       "log_group_name": "/iii/userdata",
       "log_stream_name": "{instance_id}-<role>" }
   ] } } }
   ```
The IAM role already has `CloudWatchAgentServerPolicy`; private subnets already have a `logs` VPC interface endpoint, so no NAT is required.

---

## 13. App services fail with `203/EXEC`

**Symptom**
```
iii-gateway.service: Main PID: 2529 (code=exited, status=203/EXEC)
```
and `curl http://<gateway>/` returns `Connection refused`.

**Cause**
The binary at `/opt/iii/current/bin/iii-http` (or `iii-engine`) doesn't exist — no artifact has been uploaded to the artifact bucket yet.

**Fix**
Bundle and push the artifact:
```
make bundle-workers
ARTIFACT_BUCKET=$(terraform -chdir=terraform output -raw artifact_bucket)
RELEASE=$(grep '^iii_release' terraform/terraform.tfvars | awk -F'"' '{print $2}')
aws s3 cp /tmp/inference-worker.tar.gz \
  "s3://${ARTIFACT_BUCKET}/${RELEASE}/" --region us-east-1
aws s3 cp /tmp/caller-worker.tar.gz \
  "s3://${ARTIFACT_BUCKET}/${RELEASE}/" --region us-east-1
```
For automated builds see `.github/workflows/deploy.yml` (OIDC role → S3 → `ssm:SendCommand` to restart services).

---

## 14. SSM parameter — `ParameterNotFound` immediately after `put-parameter`

**Symptom**
```
aws ssm get-parameter --name /iii/api_keys --with-decryption
An error occurred (ParameterNotFound) when calling the GetParameter operation
```

**Cause**
The earlier `put-parameter` call failed silently because either (a) SSO creds expired or (b) the call landed in the wrong region.

**Fix**
```
aws sso login --profile ajinkya
export AWS_PROFILE=ajinkya
aws ssm put-parameter \
  --name /iii/api_keys --type SecureString --overwrite \
  --value "$(openssl rand -hex 16),$(openssl rand -hex 16)" \
  --region us-east-1
aws ssm get-parameter --name /iii/api_keys --with-decryption \
  --query 'Parameter.Value' --output text --region us-east-1
```
Always pass `--region`. `put-parameter`/`get-parameter` are region-scoped.

---

## 15. State bucket deleted manually — `destroy` impossible

**Symptom**
```
terraform destroy
Error: S3 bucket "iii-tf-state-133074138423" does not exist.
```

**Cause**
The state bucket was removed outside of Terraform. Without the state file Terraform doesn't know what resources to destroy.

**Fix path**
1. Stop the bleed manually (NAT gateway + EC2 are the costly bits):
   ```bash
   REGION=us-east-1
   aws ec2 describe-instances --region $REGION \
     --filters "Name=tag:app,Values=iii" "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].InstanceId' --output text \
     | xargs -n1 -I{} aws ec2 terminate-instances --instance-ids {} --region $REGION

   NAT_ID=$(aws ec2 describe-nat-gateways --region $REGION \
     --filter "Name=tag:Name,Values=iii-prod-nat" \
     --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text)
   [ -n "$NAT_ID" ] && aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID --region $REGION
   ```
2. Use the AWS console "Delete VPC" workflow to clean up subnets, RTs, IGW, endpoints, SGs.
3. Delete the orphaned artifact bucket, IAM role/profile, log groups, EIP.
4. Recreate the state backend: `./scripts/bootstrap-state.sh create`.

Prevention: never delete the state bucket manually — use `terraform destroy` then `./scripts/bootstrap-state.sh destroy` once empty.

---

## 16. `terraform init` — checksum mismatch after rebuilding state

**Symptom**
```
Error refreshing state: state data in S3 does not have the expected content.
Calculated checksum:
Stored checksum:     1ea84d2d7488e367b39ef6851a578230
```

**Cause**
DynamoDB still has the **digest row** from the deleted state object. The new (empty) bucket has no checksum, so Terraform refuses to trust the digest.

**Fix**
Drop the stale rows:
```bash
aws dynamodb delete-item --table-name iii-tf-lock --region us-east-1 \
  --key '{"LockID":{"S":"iii-tf-state-133074138423/iii/prod/terraform.tfstate-md5"}}'
aws dynamodb delete-item --table-name iii-tf-lock --region us-east-1 \
  --key '{"LockID":{"S":"iii-tf-state-133074138423/iii/prod/terraform.tfstate"}}'
```
Then `terraform init` again.

Inspect what's in the lock table when in doubt:
```
aws dynamodb scan --table-name iii-tf-lock --region us-east-1
```

---

## 17. Quality-of-life paper cuts

These don't break anything but waste minutes if you trip over them.

| Symptom | Cause | Fix |
|---|---|---|
| `pytest` reports `collected 0 items` then `file or directory not found: #` | zsh `interactive_comments` is off; the `#` from a trailing comment was passed as a path argument | Strip the comment, or `setopt interactive_comments` (add to `~/.zshrc`). |
| `aws ec2 ...` followed by `aws ssm ...` on one line errors with `Unknown options: ssm, ...` | Two commands chained without `&&`; the second was parsed as args to the first | Always use `&&` (or `;`) between AWS CLI invocations. |
| Backend warning `"dynamodb_table" is deprecated. Use parameter "use_lockfile" instead.` | Terraform ≥1.10 prefers S3-native locking | Migrate `versions.tf` to `use_lockfile = true` when convenient. |

---

## Useful diagnostic one-liners

```bash
# Who am I and where am I pointed?
echo "profile=$AWS_PROFILE region=$AWS_DEFAULT_REGION"
aws sts get-caller-identity

# What's running tagged `app=iii`?
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:app,Values=iii" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# SSM agent registration
aws ssm describe-instance-information --region us-east-1 \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName]' --output table

# Live tail user-data on a host
aws ssm start-session --region us-east-1 --target i-...
sudo tail -f /var/log/iii-userdata.log

# CloudWatch logs
aws logs describe-log-groups --region us-east-1 --log-group-name-prefix /iii/
aws logs tail /iii/engine    --region us-east-1 --since 10m --follow
aws logs tail /iii/userdata  --region us-east-1 --since 30m
```

---

## Lessons that the codebase already encodes

- Force replacement on user-data drift (`user_data_replace_on_change = true`).
- AL2023 over Ubuntu when private subnets can't reach the public internet.
- Drop `curl` from `dnf install`; use `--allowerasing` for AL2023.
- CloudWatch logging via the `files` source, never `journald`.
- Always pass `--region` to AWS CLI calls.
- `AWS_PROFILE` exported in the shell — every script in this repo assumes the default credential chain resolves to your SSO profile.
