"""iii inference worker.

Connects to the iii engine over WebSocket, registers the
`inference::run_inference` capability, and serves requests until killed.

The backend is intentionally a stub so the platform deployment can be
exercised end-to-end without a real model. Swap the body of
`run_inference` for llama.cpp / vLLM / a remote provider when wiring
up real inference.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
import time
import uuid
from typing import Any

import websockets

LOG = logging.getLogger("inference-worker")

ENGINE_URL = os.environ.get("III_ENGINE_URL", "ws://127.0.0.1:9000")
WORKER_NAME = os.environ.get("III_WORKER_NAME", "inference-worker")
LOG_LEVEL = os.environ.get("III_LOG_LEVEL", "info").upper()
RECONNECT_BACKOFF_S = float(os.environ.get("III_RECONNECT_BACKOFF_S", "1.0"))


def _format_completion(model: str, content: str) -> dict[str, Any]:
    return {
        "id": f"cmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": 0,
            "completion_tokens": len(content.split()),
            "total_tokens": len(content.split()),
        },
    }


async def run_inference(payload: dict[str, Any]) -> dict[str, Any]:
    """The capability handler the engine dispatches to."""
    model = payload.get("model", WORKER_NAME)
    messages = payload.get("messages") or []
    last_user = next(
        (m.get("content", "") for m in reversed(messages) if m.get("role") == "user"),
        "",
    )
    # Stub: echo the user's last message. Replace with real backend.
    content = f"[{WORKER_NAME}] echo: {last_user}"
    return _format_completion(model, content)


async def _serve(ws: websockets.WebSocketClientProtocol) -> None:
    await ws.send(json.dumps({
        "type": "register",
        "worker": WORKER_NAME,
        "capabilities": ["inference::run_inference"],
    }))
    LOG.info("registered %s with engine", WORKER_NAME)

    async for raw in ws:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            LOG.warning("invalid JSON from engine: %r", raw[:200])
            continue

        if msg.get("type") != "invoke":
            continue

        req_id = msg.get("id")
        try:
            result = await run_inference(msg.get("payload") or {})
            await ws.send(json.dumps({"type": "result", "id": req_id, "payload": result}))
        except Exception as exc:  # pragma: no cover
            LOG.exception("handler error")
            await ws.send(json.dumps({
                "type": "error",
                "id": req_id,
                "error": {"type": "handler_error", "message": str(exc)},
            }))


async def main() -> None:
    logging.basicConfig(
        level=LOG_LEVEL,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    while not stop.is_set():
        try:
            LOG.info("connecting to %s", ENGINE_URL)
            async with websockets.connect(ENGINE_URL, ping_interval=20) as ws:
                serve_task = asyncio.create_task(_serve(ws))
                stop_task = asyncio.create_task(stop.wait())
                done, pending = await asyncio.wait(
                    [serve_task, stop_task],
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for t in pending:
                    t.cancel()
        except (OSError, websockets.WebSocketException) as exc:
            LOG.warning("engine unreachable: %s; retry in %.1fs", exc, RECONNECT_BACKOFF_S)
            try:
                await asyncio.wait_for(stop.wait(), timeout=RECONNECT_BACKOFF_S)
            except asyncio.TimeoutError:
                continue

    LOG.info("shutdown")
