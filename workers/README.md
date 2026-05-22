# Workers

Two reference workers ship in this repo:

| Worker | Language | Capability |
|--------|----------|------------|
| `inference-worker` | Python 3.11 | `inference::run_inference` |
| `caller-worker`    | TypeScript / Node 20 | `caller::dispatch` |

Both are **stubs**: they speak the iii engine WebSocket protocol but the
`run_inference` / `dispatch` handlers return deterministic synthetic data.
Swap them for real implementations:

- `inference-worker`: replace `inference_worker.main.run_inference` with a
  call into llama.cpp, vLLM, an OpenAI-compatible upstream, etc.
- `caller-worker`: replace `dispatch` with whatever orchestration logic
  the gateway should run before the inference hop (auth, rate limiting,
  prompt shaping, batching).

The artifact format the deploy expects: a tarball whose root is the
release directory. Build locally with:

```bash
# inference-worker
( cd workers/inference-worker && \
  tar -czf /tmp/inference-worker.tar.gz \
    --transform 's,^,inference-worker/,' \
    src requirements.txt pyproject.toml )

# caller-worker
( cd workers/caller-worker && \
  npm ci && npm run build && \
  tar -czf /tmp/caller-worker.tar.gz dist package.json package-lock.json )
```

CI does this for you on push to `main`.
