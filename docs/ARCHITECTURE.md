# Architecture

## Components

| Service | Host | Runtime | Port | Reachable from |
|---------|------|---------|------|----------------|
| iii API gateway (`iii-http`) | EC2 in **public** subnet | binary, systemd | `:80` (HTTP) | Internet 0.0.0.0/0 |
| iii engine | EC2 in **private** subnet | binary, systemd | `:9000` (WebSocket) | gateway SG, worker SGs |
| caller-worker | EC2 in **private** subnet | Node 20, systemd | (egress WS only) | — |
| inference-worker | EC2 in **private** subnet | Python 3.11, systemd | (egress WS only) | — |

Each worker holds an outbound WebSocket connection to the engine. The gateway accepts HTTP, forwards into the engine via WS, the engine dispatches to a registered worker capability.

## Network

- 1 VPC, CIDR `10.0.0.0/16`.
- 2 AZs (`a`, `b`) for the engine subnet and ALB-readiness, even though the assignment uses single instances.
- Public subnets: `10.0.0.0/24`, `10.0.1.0/24`. Route table → IGW.
- Private subnets: `10.0.10.0/24`, `10.0.11.0/24`. Route table → single NAT gateway in `public-a`.
- VPC endpoints (Gateway type) for `s3` + (Interface type) for `ssm`, `ssmmessages`, `ec2messages`, `logs`. Keeps SSM and CloudWatch traffic off the public internet.

## Security groups (least privilege)

```
sg-gateway:
  ingress: tcp/80 from 0.0.0.0/0
  egress:  tcp/9000 to sg-engine

sg-engine:
  ingress: tcp/9000 from sg-gateway, sg-caller, sg-inference
  egress:  none (deny by default; only NAT for package updates during user-data)

sg-caller, sg-inference:
  ingress: none
  egress:  tcp/9000 to sg-engine, tcp/443 to 0.0.0.0/0 (NAT, for package install)
```

## IAM

- **Instance role** `iii-vm-role`: `AmazonSSMManagedInstanceCore`, plus `s3:GetObject` on the artifact bucket and `logs:PutLogEvents` on the project log group.
- **Deploy role** `iii-deploy-role`: trusted by GitHub OIDC (`token.actions.githubusercontent.com`) restricted to `repo:OWNER/REPO:ref:refs/heads/main`. Permissions: `ec2:*` (scoped via tag conditions), `iam:PassRole` for `iii-vm-role`, `s3:PutObject` on artifact bucket, `ssm:SendCommand` for the deploy document.

## Data flow

```
client ──HTTP POST /v1/chat/completions──▶ gateway:80
                                            │
                                            ▼
                                  forwards request to iii engine via WS
                                            │
                                            ▼
                            engine selects worker that registered
                            capability `inference::run_inference`
                                            │
                            ┌───────────────┴───────────────┐
                            ▼                               ▼
                  caller-worker (orchestration)   inference-worker (model)
```

Note: `caller-worker` exists per the upstream tutorial pattern. In this deployment it is used for request shaping / batching hooks; if not needed it can be removed by setting `enable_caller_worker = false` in `terraform.tfvars`.

## Observability

- **Logs:** `journalctl` on each VM, shipped to CloudWatch Logs via the CloudWatch Agent. Log groups: `/iii/gateway`, `/iii/engine`, `/iii/caller-worker`, `/iii/inference-worker`.
- **Metrics:** CloudWatch Agent ships CPU, memory, disk, network. Custom metric `iii_request_count` emitted from gateway via embedded metric format.
- **Tracing:** out of scope for this submission. Hook point documented in [HARDENING.md](HARDENING.md).

## Decisions

| Decision | Choice | Why | Alternative |
|----------|--------|-----|-------------|
| Cloud | AWS | Brief allows either; AWS has stronger SSM/OIDC story | GCP equivalent in [HARDENING.md](HARDENING.md) |
| Compute | EC2 + systemd | Matches brief literally; reproducible via Terraform + cloud-init | ECS/Fargate, EKS |
| Front door | EC2 with public IP running iii-http | Simplest; brief asks only for "public endpoint" | ALB → private gateway (adds cost, gains TLS + WAF) |
| Engine placement | dedicated private VM | Clear failure domain; matches "each worker on its own VM" spirit | Co-locate with gateway to save 1 instance |
| Admin access | SSM Session Manager only | No port 22 anywhere; no SSH keys to manage | Bastion + SSH (legacy) |
| Secrets | SSM Parameter Store (SecureString) | Native, audited, free tier | Secrets Manager (rotation) |
| Registry | ECR | AWS-native, OIDC-friendly | GHCR ruled out per scope |
| State | S3 + DynamoDB lock | Standard; encrypted, versioned | Terraform Cloud |
