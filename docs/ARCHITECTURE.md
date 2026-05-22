# Architecture

## Components

| Service | Host | Runtime | Port | Reachable from |
|---------|------|---------|------|----------------|
| nginx (reverse proxy) | EC2 in **public** subnet | systemd | `:80` (HTTP) | Internet 0.0.0.0/0 |
| iii engine + `iii-http` | EC2 in **private** subnet | `iii -c engine.yaml`, systemd | `:49134` (WS), `:3111` (HTTP) | gateway SG (3111), worker SGs (49134) |
| caller-worker | EC2 in **private** subnet | Node 20, systemd | (egress WS only) | — |
| inference-worker | EC2 in **private** subnet | Python 3.11 + llama.cpp, systemd | (egress WS only) | — |

Each worker opens an outbound WebSocket to the engine and registers iii **functions** (`inference.chat`, `caller.chat_proxy`). nginx forwards `:80 → engine:3111`. `iii-http` (bundled in the engine process) dispatches HTTP triggers to the registered functions.

## Network

- 1 VPC, CIDR `10.0.0.0/16`.
- 2 AZs (`a`, `b`) for the engine subnet and ALB-readiness, even though the assignment uses single instances.
- Public subnets: `10.0.0.0/24`, `10.0.1.0/24`. Route table → IGW.
- Private subnets: `10.0.10.0/24`, `10.0.11.0/24`. Route table → single NAT gateway in `public-a`.
- VPC endpoints (Gateway type) for `s3` + (Interface type) for `ssm`, `ssmmessages`, `ec2messages`, `logs`. Keeps SSM and CloudWatch traffic off the public internet.

## Security groups (least privilege)

```
sg-gateway:
  ingress: tcp/80   from 0.0.0.0/0
  egress:  tcp/3111 to sg-engine, tcp/443 to 0.0.0.0/0 (NAT, package install)

sg-engine:
  ingress: tcp/3111  from sg-gateway
           tcp/49134 from sg-worker
  egress:  tcp/443  to 0.0.0.0/0 (NAT, iii install + package updates)

sg-worker:
  ingress: none
  egress:  tcp/49134 to sg-engine, tcp/443 to 0.0.0.0/0
```

## IAM

- **Instance role** `iii-vm-role`: `AmazonSSMManagedInstanceCore`, plus `s3:GetObject` on the artifact bucket and `logs:PutLogEvents` on the project log group.
- **Deploy role** `iii-deploy-role`: trusted by GitHub OIDC (`token.actions.githubusercontent.com`) restricted to `repo:OWNER/REPO:ref:refs/heads/main`. Permissions: `ec2:*` (scoped via tag conditions), `iam:PassRole` for `iii-vm-role`, `s3:PutObject` on artifact bucket, `ssm:SendCommand` for the deploy document.

## Data flow

```
client ──HTTP POST /v1/chat/completions──▶ nginx :80 (gateway VM)
                                            │
                                            ▼
                                  proxy_pass → engine :3111 (iii-http)
                                            │
                                            ▼
                                  engine dispatches HTTP trigger to function
                                  `caller.chat_proxy` (registered by caller-worker)
                                            │
                            caller validates X-API-Key, rate-limits, logs
                                            │
                                            ▼
                                  iii.trigger("inference.chat", payload)
                                            │
                                            ▼
                                  inference-worker runs llama.cpp, returns
                                            │
                                            ▼
                                  caller returns -> iii-http -> nginx -> client
```

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
