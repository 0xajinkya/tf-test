# iii Inference Platform on AWS

> **Scope note.** This repo ships the **deployment infrastructure** (AWS via Terraform, systemd units, CI/CD via GitHub Actions) for the iii platform. The upstream `iii-engine` / `iii-http` binaries are **not** bundled — see [Known scope limit](#known-scope-limit--iii-engine--iii-http-binaries) below. The Python `inference-worker` and TypeScript `caller-worker` are real, runnable stubs that speak the engine protocol; their handlers return deterministic echo responses pending real model wiring.

Reproducible deployment of an iii engine + workers behind a public JSON API on AWS.

```
                                  Internet
                                     │
                          ┌──────────▼──────────┐
                          │  Public subnet      │
                          │  ┌───────────────┐  │
                          │  │ API Gateway   │  │  EC2 t3.small, public IP
                          │  │ iii-http :80  │  │  systemd: iii-gateway
                          │  └──────┬────────┘  │
                          └─────────┼───────────┘
                                    │ WebSocket
                          ┌─────────▼───────────┐
                          │ Private subnet      │
                          │  ┌───────────────┐  │
                          │  │ iii Engine    │  │  EC2 t3.small
                          │  │ ws :9000      │  │  systemd: iii-engine
                          │  └──────┬────────┘  │
                          │  ┌──────┴────────┐  │
                          │  │ caller-worker │  │  EC2 t3.small (TS, Node 20)
                          │  └───────────────┘  │
                          │  ┌───────────────┐  │
                          │  │ inference-    │  │  EC2 t3.large (Python 3.11)
                          │  │ worker        │  │
                          │  └───────────────┘  │
                          │     NAT egress only │
                          └─────────────────────┘
```

## Repo layout

```
terraform/        AWS infra (VPC, EC2, IAM, SGs, user-data)
systemd/          Service units copied to each VM
config/           iii engine + worker YAML configs
workers/          Application code (Python inference, TS caller)
.github/          CI + deploy workflows
docs/             Architecture, API, runbook, hardening, 100x scale
```

## Quick start

1. Install: `terraform >= 1.7`, `aws cli v2`, `gh` CLI.
2. `aws configure sso` (or static keys), then `aws sts get-caller-identity`.
3. `cp terraform/terraform.tfvars.example terraform/terraform.tfvars` and edit.
4. `cd terraform && terraform init && terraform apply`.
5. Capture `terraform output api_endpoint`.
6. Smoke test: see [docs/API.md](docs/API.md).

## CI/CD

- `ci.yml` — runs on every PR: `terraform fmt -check`, `terraform validate`, `tflint`, worker lint/typecheck.
- `deploy.yml` — runs on push to `main`: builds worker artifacts → uploads to S3 → `terraform apply` → triggers SSM RunCommand to pull new code on each VM.

OIDC trust between GitHub and AWS — no long-lived secrets in GitHub.

## Known scope limit — iii engine + iii-http binaries

This repo ships the **deployment infrastructure** for an iii service, not the iii project itself. The `engine.tar.gz` and `gateway.tar.gz` bundles produced by CI contain only the systemd unit + YAML config — they do **not** contain the `iii-engine` or `iii-http` binaries.

To finish wiring a live deployment, drop the upstream binaries (or build them in CI) into the staging directory before tarring:

```bash
# in .github/workflows/deploy.yml, "Package gateway + engine" step:
install -d $stage/bin
curl -sL https://example.com/iii/v1.2.3/iii-engine -o $stage/bin/iii-engine
chmod +x $stage/bin/iii-engine
```

The Python `inference-worker` and TypeScript `caller-worker` are real stubs — they connect to the engine, register their capabilities, and serve requests with a deterministic echo handler. Swap the handler bodies for real model inference when you have the engine running.

## Docs

| File | Purpose |
|------|---------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Network, IAM, data flow |
| [docs/API.md](docs/API.md) | Public JSON contract |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Deploy, redeploy, rollback, debug |
| [docs/HARDENING.md](docs/HARDENING.md) | Production posture beyond the baseline |
| [docs/SCALE-100X.md](docs/SCALE-100X.md) | What changes for a 100× model |

## Design choices and trade-offs

See [docs/ARCHITECTURE.md#decisions](docs/ARCHITECTURE.md#decisions).
