"""iii inference worker.

Registers `inference.chat` with the iii engine. Backend: llama.cpp via
llama-cpp-python loading a local GGUF. Model path is fixed via env;
download happens at deploy time in cloud-init.
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys
import time
import uuid
from typing import Any

from iii import III
from llama_cpp import Llama

LOG = logging.getLogger("inference-worker")

ENGINE_URL = os.environ.get("III_ENGINE_URL", "ws://127.0.0.1:49134")
WORKER_NAME = os.environ.get("III_WORKER_NAME", "inference-worker")
LOG_LEVEL = os.environ.get("III_LOG_LEVEL", "info").upper()
MODEL_PATH = os.environ.get("MODEL_PATH", "/var/lib/iii/models/model.gguf")
N_CTX = int(os.environ.get("MODEL_N_CTX", "2048"))
N_THREADS = int(os.environ.get("MODEL_N_THREADS", str(os.cpu_count() or 2)))

# Load once at startup, share across invocations.
_llm: Llama | None = None


def _load_model() -> Llama:
    global _llm
    if _llm is None:
        LOG.info("loading model from %s (n_ctx=%d, threads=%d)", MODEL_PATH, N_CTX, N_THREADS)
        _llm = Llama(
            model_path=MODEL_PATH,
            n_ctx=N_CTX,
            n_threads=N_THREADS,
            verbose=False,
        )
        LOG.info("model loaded")
    return _llm


async def chat(data: dict[str, Any]) -> dict[str, Any]:
    """Handler for inference.chat. Input mirrors OpenAI chat-completion."""
    llm = _load_model()
    messages = data.get("messages") or []
    temperature = float(data.get("temperature", 0.7))
    max_tokens = int(data.get("max_tokens", 256))
    model_name = data.get("model", WORKER_NAME)

    started = time.time()
    # llama-cpp-python exposes create_chat_completion; same shape as OpenAI.
    raw = await asyncio.to_thread(
        llm.create_chat_completion,
        messages=messages,
        temperature=temperature,
        max_tokens=max_tokens,
    )
    elapsed_ms = int((time.time() - started) * 1000)
    LOG.info("inference complete: %dms tokens=%s", elapsed_ms, raw.get("usage"))

    choice = raw["choices"][0]
    usage = raw.get("usage", {})
    return {
        "id": raw.get("id") or f"cmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model_name,
        "choices": [{
            "index": 0,
            "message": {
                "role": choice["message"]["role"],
                "content": choice["message"]["content"],
            },
            "finish_reason": choice.get("finish_reason", "stop"),
        }],
        "usage": {
            "prompt_tokens": usage.get("prompt_tokens", 0),
            "completion_tokens": usage.get("completion_tokens", 0),
            "total_tokens": usage.get("total_tokens", 0),
        },
    }


async def main() -> None:
    logging.basicConfig(
        level=LOG_LEVEL,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )

    # Pre-load before connecting so the engine doesn't dispatch to a not-ready worker.
    _load_model()

    iii = III(ENGINE_URL)
    await iii.connect()
    iii.register_function("inference.chat", chat)
    LOG.info("registered inference.chat with engine at %s", ENGINE_URL)

    # Block forever.
    await asyncio.Event().wait()
