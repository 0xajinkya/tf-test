# Public API

OpenAI-style `chat/completions` for familiarity. The gateway is the upstream `iii-http` worker, which forwards to the engine.

## Endpoint

```
POST http://<api_endpoint>/v1/chat/completions
Content-Type: application/json
```

## Request

```json
{
  "model": "inference-worker",
  "messages": [
    { "role": "system", "content": "You are a helpful assistant." },
    { "role": "user",   "content": "Summarize the CAP theorem in one sentence." }
  ],
  "temperature": 0.2,
  "max_tokens": 256
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `model` | string | yes | Must match a registered worker capability. Default: `inference-worker`. |
| `messages` | array | yes | At least one entry. `role` ∈ {`system`, `user`, `assistant`}. |
| `temperature` | number | no | `0.0–2.0`, default `1.0`. |
| `max_tokens` | integer | no | Default `512`. |
| `stream` | boolean | no | If `true`, response is `text/event-stream`. |

## Response (non-streaming)

```json
{
  "id": "cmpl-01HXYZ...",
  "object": "chat.completion",
  "created": 1747800000,
  "model": "inference-worker",
  "choices": [
    {
      "index": 0,
      "message": { "role": "assistant", "content": "..." },
      "finish_reason": "stop"
    }
  ],
  "usage": { "prompt_tokens": 42, "completion_tokens": 18, "total_tokens": 60 }
}
```

## Errors

| HTTP | `error.type` | Cause |
|------|--------------|-------|
| 400 | `invalid_request_error` | Missing `messages`, bad JSON, unknown `model` |
| 408 | `request_timeout` | Worker did not respond within `request_timeout_ms` (default 30 000) |
| 502 | `upstream_error` | Engine reachable but worker raised |
| 503 | `no_worker_available` | No worker is currently registered for the requested model |

Error body:

```json
{ "error": { "type": "no_worker_available", "message": "No worker registered for model 'inference-worker'" } }
```

## Smoke test

```bash
API=$(cd terraform && terraform output -raw api_endpoint)

curl -sS -X POST "$API/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "inference-worker",
    "messages": [{"role":"user","content":"ping"}]
  }' | jq
```
