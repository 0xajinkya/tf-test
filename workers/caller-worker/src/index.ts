/**
 * iii caller-worker.
 *
 * Registers `caller.chat_proxy` and a public HTTP trigger
 * (POST /v1/chat/completions). Responsibilities:
 *   1. Validate X-API-Key against allowlist from env (sourced from SSM Parameter Store at boot).
 *   2. Per-key token-bucket rate limit.
 *   3. Structured JSON logging of every request to /var/log/iii/caller-worker.log via stdout
 *      (CloudWatch Agent ships to /iii/caller-worker log group).
 *   4. Forward to inference.chat via the engine.
 */
import { III } from "iii-sdk";

const ENGINE_URL = process.env.III_ENGINE_URL ?? "ws://127.0.0.1:49134";
const RATE_LIMIT_PER_MIN = Number(process.env.RATE_LIMIT_PER_MINUTE ?? 60);
const API_KEYS = new Set(
  (process.env.API_KEYS ?? "")
    .split(",")
    .map((k) => k.trim())
    .filter(Boolean),
);

// ----- token bucket per key -----
type Bucket = { tokens: number; updatedAt: number };
const buckets = new Map<string, Bucket>();
const REFILL_PER_MS = RATE_LIMIT_PER_MIN / 60_000;

function consume(key: string): boolean {
  const now = Date.now();
  let b = buckets.get(key);
  if (!b) {
    b = { tokens: RATE_LIMIT_PER_MIN, updatedAt: now };
    buckets.set(key, b);
  }
  const elapsed = now - b.updatedAt;
  b.tokens = Math.min(RATE_LIMIT_PER_MIN, b.tokens + elapsed * REFILL_PER_MS);
  b.updatedAt = now;
  if (b.tokens >= 1) {
    b.tokens -= 1;
    return true;
  }
  return false;
}

// ----- structured log -----
function log(level: "info" | "warn" | "error", fields: Record<string, unknown>) {
  process.stdout.write(
    JSON.stringify({ ts: new Date().toISOString(), level, worker: "caller-worker", ...fields }) + "\n",
  );
}

function err(status: number, type: string, message: string) {
  return { status_code: status, body: { error: { type, message } } };
}

// ----- handler -----
async function chatProxy(req: any) {
  const reqId = `req-${Math.random().toString(36).slice(2, 10)}`;
  const startedAt = Date.now();
  const headers: Record<string, string> = req?.headers ?? {};
  const apiKey =
    headers["x-api-key"] ?? headers["X-API-Key"] ?? headers["X-Api-Key"] ?? "";
  const body = req?.body ?? {};

  if (API_KEYS.size > 0 && !API_KEYS.has(apiKey)) {
    log("warn", { request_id: reqId, event: "auth_fail", reason: "bad_or_missing_key" });
    return err(401, "unauthorized", "Missing or invalid X-API-Key");
  }
  if (!consume(apiKey || "anon")) {
    log("warn", { request_id: reqId, event: "rate_limited", api_key_hint: apiKey.slice(0, 4) });
    return err(429, "rate_limited", `Limit ${RATE_LIMIT_PER_MIN}/min exceeded`);
  }
  if (!Array.isArray(body?.messages) || body.messages.length === 0) {
    return err(400, "invalid_request", "messages must be a non-empty array");
  }

  log("info", {
    request_id: reqId,
    event: "request",
    api_key_hint: apiKey.slice(0, 4),
    model: body.model ?? "inference-worker",
    msg_count: body.messages.length,
  });

  try {
    const result = await iii.invokeFunction("inference.chat", body);
    log("info", {
      request_id: reqId,
      event: "response",
      latency_ms: Date.now() - startedAt,
      total_tokens: result?.usage?.total_tokens,
    });
    return { status_code: 200, body: result };
  } catch (e) {
    log("error", { request_id: reqId, event: "upstream_error", err: String(e) });
    return err(502, "upstream_error", String(e));
  }
}

// ----- bootstrap -----
const iii = new III(ENGINE_URL);

iii.registerFunction({ id: "caller.chat_proxy" }, chatProxy);

iii.registerTrigger({
  type: "http",
  function_id: "caller.chat_proxy",
  config: {
    api_path: "/v1/chat/completions",
    http_method: "POST",
  },
});

log("info", { event: "started", engine: ENGINE_URL, rate_limit: RATE_LIMIT_PER_MIN, key_count: API_KEYS.size });

await new Promise(() => {}); // run forever
