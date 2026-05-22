/**
 * iii caller-worker (TypeScript).
 *
 * Connects to the iii engine over WebSocket, registers the `caller::dispatch`
 * capability, and forwards inbound requests to the inference worker through
 * the engine. In the current deployment shape it is a thin pass-through
 * scaffold — replace `dispatch()` with real orchestration logic.
 */
import WebSocket from "ws";

const ENGINE_URL = process.env.III_ENGINE_URL ?? "ws://127.0.0.1:9000";
const WORKER_NAME = process.env.III_WORKER_NAME ?? "caller-worker";
const RECONNECT_BACKOFF_MS = Number(process.env.III_RECONNECT_BACKOFF_MS ?? 1000);

type InvokeMessage = {
  type: "invoke";
  id: string;
  payload: Record<string, unknown>;
};

export async function dispatch(payload: Record<string, unknown>): Promise<Record<string, unknown>> {
  return {
    object: "caller.ack",
    received_at: new Date().toISOString(),
    forwarded_keys: Object.keys(payload),
  };
}

function log(level: "info" | "warn" | "error", msg: string, extra?: Record<string, unknown>) {
  const line = { ts: new Date().toISOString(), level, worker: WORKER_NAME, msg, ...extra };
  process.stdout.write(JSON.stringify(line) + "\n");
}

function connectOnce(): Promise<void> {
  return new Promise((resolve) => {
    const ws = new WebSocket(ENGINE_URL);

    ws.on("open", () => {
      log("info", "connected", { engine: ENGINE_URL });
      ws.send(JSON.stringify({
        type: "register",
        worker: WORKER_NAME,
        capabilities: ["caller::dispatch"],
      }));
    });

    ws.on("message", async (raw) => {
      let msg: InvokeMessage;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        log("warn", "invalid JSON from engine");
        return;
      }
      if (msg.type !== "invoke") return;
      try {
        const result = await dispatch(msg.payload ?? {});
        ws.send(JSON.stringify({ type: "result", id: msg.id, payload: result }));
      } catch (err) {
        log("error", "handler error", { err: String(err) });
        ws.send(JSON.stringify({
          type: "error",
          id: msg.id,
          error: { type: "handler_error", message: String(err) },
        }));
      }
    });

    ws.on("close", (code) => {
      log("warn", "connection closed", { code });
      resolve();
    });

    ws.on("error", (err) => {
      log("warn", "ws error", { err: String(err) });
    });
  });
}

async function main(): Promise<void> {
  let shutdown = false;
  for (const sig of ["SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      log("info", "shutdown signal", { sig });
      shutdown = true;
    });
  }
  while (!shutdown) {
    await connectOnce();
    if (shutdown) break;
    log("info", `reconnecting in ${RECONNECT_BACKOFF_MS}ms`);
    await new Promise((r) => setTimeout(r, RECONNECT_BACKOFF_MS));
  }
}

main().catch((err) => {
  log("error", "fatal", { err: String(err) });
  process.exit(1);
});
