# iii Inference Platform on AWS

> Reproducible AWS deployment of the [iii](https://github.com/iii-hq/iii) engine + workers behind a public JSON API. Real llama.cpp inference (TinyLlama 1.1B GGUF by default). API-key auth + per-key rate limit at the caller worker. nginx public ingress, SSM-only admin access, GitHub Actions CI/CD via OIDC.

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

## How iii is installed

The engine VM runs `iii -c /etc/iii/engine.yaml` after installing the CLI in cloud-init:

```bash
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
```

That single binary bundles the engine + `iii-http` worker. No upstream binaries are bundled into CI artifacts — cloud-init fetches them at boot.

Workers use the SDKs:
- Python `iii>=0.11` (`pip install iii`)
- TypeScript `iii-sdk@^0.11` (`npm install iii-sdk`)

## Request flow

```
client
  → nginx :80               (gateway VM, public)
    → engine :3111 iii-http (engine VM, private)
      → engine :49134 WS    (in-process)
        → caller.chat_proxy   (caller-worker VM)
            auth + rate + log
            → inference.chat  (inference-worker VM, llama.cpp)
            ← response
        ← response
      ← response
    ← response
  ← response
```

The HTTP path `/v1/chat/completions` is registered as a trigger by the **caller-worker**, not the gateway. nginx just forwards `:80 → engine:3111` so the public surface stays small.

## Auth + rate limit

API keys live in SSM Parameter Store at `/iii/api_keys` (SecureString), comma-separated:

```bash
aws ssm put-parameter \
  --name /iii/api_keys --type SecureString --overwrite \
  --value "key-alpha,key-beta,key-gamma"

# Rotate -> bounce the worker so it re-reads at boot.
aws ssm send-command --document-name iii-prod-deploy \
  --targets "Key=tag:role,Values=caller-worker" \
  --parameters "release=$(git rev-parse HEAD)"
```

Per-key rate limit defaults to 60 req/min (token bucket). Tune via `var.rate_limit_per_minute`.

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
