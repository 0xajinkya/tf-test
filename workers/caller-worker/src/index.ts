/**
 * iii caller-worker (TypeScript, iii-sdk@^0.12).
 *
 * Registers `caller.chat_proxy` as an HTTP-triggered function. On every request:
 *   1. Validate X-API-Key against allowlist (env API_KEYS, sourced from SSM).
 *   2. Per-key token-bucket rate limit.
 *   3. Structured JSON log to stdout (-> /var/log/iii/caller-worker.log via systemd).
 *   4. Forward payload to `inference.chat` via the engine.
 */
import { registerWorker, http, type ApiResponse, type HttpRequest } from "iii-sdk";

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
function log(level: "info" | "warn" | "error", fields: Record<string, unknown>): void {
  process.stdout.write(
    JSON.stringify({ ts: new Date().toISOString(), level, worker: "caller-worker", ...fields }) + "\n",
  );
}

function err(status: number, type: string, message: string): ApiResponse<number, Record<string, unknown>> {
  return { status_code: status, body: { error: { type, message } } };
}

// ----- connect + register -----
const iii = registerWorker(ENGINE_URL, { workerName: "caller-worker" });

iii.registerFunction(
  "caller.chat_proxy",
  http(async (req: HttpRequest, res) => {
    const reqId = `req-${Math.random().toString(36).slice(2, 10)}`;
    const startedAt = Date.now();

    const headers = req.headers ?? {};
    const headerValue = (k: string): string => {
      const v = headers[k] ?? headers[k.toLowerCase()] ?? "";
      return Array.isArray(v) ? v[0] ?? "" : v;
    };
    const apiKey = headerValue("x-api-key") || headerValue("X-API-Key");
    const body = (req.body ?? {}) as Record<string, unknown>;

    const send = (resp: ApiResponse<number, Record<string, unknown>>) => {
      res.status(resp.status_code);
      res.headers({ "content-type": "application/json" });
      res.stream.write(JSON.stringify(resp.body ?? {}));
      res.close();
    };

    if (API_KEYS.size > 0 && !API_KEYS.has(apiKey)) {
      log("warn", { request_id: reqId, event: "auth_fail" });
      send(err(401, "unauthorized", "Missing or invalid X-API-Key"));
      return;
    }
    if (!consume(apiKey || "anon")) {
      log("warn", { request_id: reqId, event: "rate_limited" });
      send(err(429, "rate_limited", `Limit ${RATE_LIMIT_PER_MIN}/min exceeded`));
      return;
    }
    const messages = body["messages"];
    if (!Array.isArray(messages) || messages.length === 0) {
      send(err(400, "invalid_request", "messages must be a non-empty array"));
      return;
    }

    log("info", {
      request_id: reqId,
      event: "request",
      api_key_hint: apiKey.slice(0, 4),
      model: body["model"] ?? "inference-worker",
      msg_count: messages.length,
    });

    try {
      const result = await iii.trigger<Record<string, unknown>, Record<string, unknown>>({
        function_id: "inference.chat",
        payload: body,
      });
      log("info", {
        request_id: reqId,
        event: "response",
        latency_ms: Date.now() - startedAt,
        total_tokens: (result?.usage as { total_tokens?: number } | undefined)?.total_tokens,
      });
      send({ status_code: 200, body: result });
    } catch (e) {
      log("error", { request_id: reqId, event: "upstream_error", err: String(e) });
      send(err(502, "upstream_error", String(e)));
    }
  }),
);

iii.registerTrigger({
  type: "http",
  function_id: "caller.chat_proxy",
  config: { api_path: "/v1/chat/completions", http_method: "POST" },
});

log("info", {
  event: "started",
  engine: ENGINE_URL,
  rate_limit: RATE_LIMIT_PER_MIN,
  key_count: API_KEYS.size,
});

await new Promise(() => {}); // run forever
