# Workers

Two reference workers ship in this repo:

| Worker | Language | iii function ID |
|--------|----------|-----------------|
| `inference-worker` | Python 3.11 + llama.cpp | `inference.chat` |
| `caller-worker`    | TypeScript / Node 20 | `caller.chat_proxy` (HTTP trigger: `POST /v1/chat/completions`) |

Both use the official iii SDKs (`iii-sdk` for Python via PyPI name `iii-sdk` →
imports as `iii`; `iii-sdk` for Node).

- `inference-worker`: lazy-loads a GGUF model via `llama-cpp-python` and
  exposes `inference.chat` (OpenAI chat-completion shape). Default model:
  TinyLlama 1.1B Q4_K_M, downloaded in cloud-init. Swap by changing
  `var.gguf_model_url`.
- `caller-worker`: registers `caller.chat_proxy` + an HTTP trigger at
  `POST /v1/chat/completions`. Validates `X-API-Key` (from SSM
  `/iii/api_keys`), applies a per-key token-bucket rate limit, emits
  structured JSON logs, forwards to `inference.chat` via the engine.

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
