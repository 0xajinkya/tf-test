# What changes for a 100× model

The baseline assumes a small CPU-friendly model on a `t3.large`. Scaling the model 100× — say, from a 1B-parameter CPU model to a 70B-parameter GPU model — forces changes across compute, networking, deployment, and cost discipline.

## Compute

| Layer | Today | 100× |
|-------|-------|------|
| Inference VM | `t3.large`, CPU | `g6.12xlarge` (4× L4) or `p5.48xlarge` (8× H100) depending on quant + batch |
| Quantisation | none | FP8 / INT4 with TensorRT-LLM or vLLM AWQ |
| Serving runtime | naive Python loop | **vLLM** or **TGI** with continuous batching + PagedAttention |
| Concurrency model | 1 request per worker | dozens per worker via continuous batching |
| Cold start | seconds | minutes (50–200 GB weights). Need warm pools + pre-pulled weights baked into AMI or EFS-cached |

The inference worker becomes the bottleneck and the cost centre. The engine and gateway barely change.

## Storage

- Model weights move from "bake into AMI" to **EFS or FSx for Lustre** mounted read-only on every inference VM. New model version = new EFS access point; old version stays mounted until drained.
- Or: weights live in **S3**, downloaded once per instance on boot into a local NVMe scratch volume. Faster steady-state, slower scale-out.

## Autoscaling

- Single `t3.large` → **Auto Scaling Group of GPU instances** behind an internal NLB that the engine dispatches to. ASG scales on a custom CloudWatch metric `iii_pending_requests / worker`.
- Scale-in is **graceful**: lifecycle hook drains the WebSocket, finishes in-flight requests, then terminates.
- Spot for non-critical traffic, on-demand floor for SLO traffic. Capacity-rebalancing on.

## Networking + front door

- ALB → API gateway becomes **NLB → ALB → many gateway instances** as throughput grows. Gateways are stateless and trivially horizontal.
- WebSocket fan-out from engine → worker fleet needs a real **service mesh** (App Mesh / Envoy) or move the engine onto **EKS** with headless services so workers can be discovered without re-deploying the engine.
- Add **CloudFront** in front for global PoP, caching of static assets, and shield against L7 floods.

## Reliability

- Multi-AZ becomes mandatory, not optional. One inference ASG per AZ, anti-affinity rules.
- **Request hedging** in the gateway: dispatch slow requests to a second worker after p95, take whichever finishes first.
- Bulkhead pools per tenant so one heavy user cannot starve others.

## Deployment

- Container the inference worker. Push to ECR with image scanning. Pull on instance launch.
- **Blue/green at the ASG level**: spin up a new ASG with the new model version, shift traffic at the NLB target group with weighted routing, drain old.
- Weights versioned independently from code; the worker takes `MODEL_VERSION` env var pointing at an EFS path or S3 prefix.

## Observability

- Token-level metrics: TTFT (time to first token), TPOT (time per output token), tokens/sec/GPU, KV-cache utilisation, queue depth.
- GPU metrics via DCGM exporter → Managed Prometheus.
- Trace each request end-to-end (gateway → engine → worker → CUDA kernel timing) via OpenTelemetry.

## Cost discipline

- Budget alerts per service via AWS Budgets.
- Savings Plans for steady GPU baseline; spot for burst.
- A single `p5.48xlarge` at on-demand is ~$98/h. Even one idle instance is $70k/year — auto-shutdown of dev environments is no longer optional.
- Quantise aggressively. FP8 on H100 ~2× tokens/sec/$ over BF16.

## Security additions

- Prompt + response logging requires PII review and a redaction step before the log line leaves the worker.
- Rate limit per API key (WAF + DynamoDB token bucket). At 100× the model, a single abusive key can burn five-figure dollar amounts per hour.
- Tenant isolation: separate ASGs or at minimum separate KV caches; do not share GPU memory across tenants without explicit consent.
