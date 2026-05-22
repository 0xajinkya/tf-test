# Production hardening

The shipped baseline is intentionally pragmatic for an assignment. This document lists what to change for a real production deployment, ordered by impact-per-effort.

## Network

- **TLS termination.** Put an Application Load Balancer in front of the gateway. Issue an ACM cert for your domain, terminate TLS at the ALB, force HTTP→HTTPS redirect. The gateway moves to a private subnet behind the ALB and only the ALB has a public IP.
- **WAF.** Attach `AWS WAFv2` to the ALB. Enable `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet`, rate-limit rule (1000 req / 5 min per IP).
- **Egress allow-list.** Replace `0.0.0.0/0` egress on workers with an explicit allow-list (HuggingFace, PyPI, npm, package mirrors). Use a VPC egress proxy (e.g. Squid) or `aws_network_firewall`.
- **PrivateLink to S3 + ECR.** Already present for SSM and Logs; extend to `s3`, `ecr.api`, `ecr.dkr` so artifact pulls never traverse the internet.
- **Per-AZ NAT.** Single NAT in the baseline is a SPOF. Move to one NAT per AZ for HA.

## Identity and access

- **No standing admin.** Replace `AdministratorAccess` in the deploy role with the minimal set: `ec2:Describe*`, `ssm:SendCommand` scoped to the deploy document, `s3:PutObject` on the artifact bucket prefix, `iam:PassRole` only for `iii-vm-role`.
- **Permission boundaries.** Attach a permissions boundary to `iii-deploy-role` so even a compromised workflow cannot create privilege-escalation paths.
- **Conditional OIDC trust.** Lock the OIDC trust policy to a specific `sub` claim including environment (`repo:OWNER/REPO:environment:prod`) and `job_workflow_ref`.
- **Just-in-time human access.** Use IAM Identity Center with time-bound `AWSSSOReadOnlyAccess` + a break-glass role guarded by approvals.

## Secrets

- Move static config out of cloud-init into **SSM Parameter Store** (SecureString, KMS-encrypted with a CMK).
- For credentials with rotation needs (DB passwords, third-party API keys) use **AWS Secrets Manager** with automatic rotation lambdas.
- Never bake secrets into AMIs or user-data — both are visible to anyone with `ec2:DescribeInstanceAttribute`.

## Compute and supply chain

- **Container the workers.** Build minimal images (`python:3.11-slim`, `node:20-bookworm-slim`), push to ECR. Use ECR image scanning + `inspector2` for vulnerability findings.
- **Sigstore + SBOM.** Sign images with `cosign`, attach an SBOM with `syft`, and have the deploy step verify the signature before pulling.
- **Immutable AMIs.** Bake a hardened base AMI (CIS Level 1) with Packer. Cloud-init only injects config, not packages.
- **Auto Scaling Groups, not single EC2.** Replace the four standalone instances with ASGs of `min=1, desired=1, max=N`. Termination-protected via lifecycle hooks that drain WebSocket connections.

## Runtime

- **gVisor / Firecracker** for the inference worker if it executes untrusted prompts that trigger code paths.
- **Read-only root filesystem** for all services (`ProtectSystem=strict`, `ReadWritePaths=/var/lib/iii`), already partially configured in the systemd units.
- **Resource caps.** `CPUQuota`, `MemoryMax`, `TasksMax` on each unit so a runaway worker cannot starve the host.

## Observability

- **Tracing.** OpenTelemetry SDK in both workers; OTLP exporter to AWS Distro for OpenTelemetry collector → X-Ray + Managed Prometheus.
- **Structured logs.** JSON to stdout, parsed by CloudWatch Logs Insights queries. Required fields: `ts`, `level`, `request_id`, `worker`, `latency_ms`.
- **SLOs.** Define p95 latency and error-rate SLOs; alert via CloudWatch Alarms → SNS → PagerDuty.

## Data + compliance

- **At-rest encryption.** EBS volumes already encrypted (default in this Terraform). Ensure CMK ownership, not AWS-managed key, for audit trail.
- **In-transit encryption inside the VPC.** mTLS on the engine ↔ worker WebSocket via a private CA (AWS Private CA). Mutual auth replaces "SG membership" as the trust anchor.
- **Audit.** CloudTrail org-trail to a logging account; CloudTrail Lake for ad-hoc queries; GuardDuty + Security Hub enabled.

## Disaster recovery

- **State recovery.** S3 versioning + cross-region replication on the Terraform state bucket.
- **AMI + config snapshots** in a second region; Terraform code is region-parameterised already.
- **RTO/RPO.** Document targets. With ASG + ALB + multi-AZ, single-instance failure RTO is ~2 min; full-region failure RTO is ~30 min with cold standby in `us-west-2`.

## GCP variant (for reference)

If migrating to GCP: VPC + Cloud NAT + private subnets, Compute Engine MIGs behind an external HTTPS Load Balancer with Cloud Armor, Workload Identity Federation for GitHub Actions, Secret Manager, OS Login for admin access, Cloud Logging + Cloud Monitoring. Same architecture, different vendor.
