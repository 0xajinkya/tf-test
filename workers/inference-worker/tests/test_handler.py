import asyncio
from inference_worker.main import run_inference


def test_run_inference_echoes_last_user_message():
    result = asyncio.run(run_inference({
        "model": "inference-worker",
        "messages": [
            {"role": "system", "content": "be terse"},
            {"role": "user", "content": "ping"},
        ],
    }))
    assert result["object"] == "chat.completion"
    assert result["model"] == "inference-worker"
    assert "ping" in result["choices"][0]["message"]["content"]
    assert result["choices"][0]["finish_reason"] == "stop"


def test_run_inference_handles_empty_messages():
    result = asyncio.run(run_inference({"model": "x", "messages": []}))
    assert result["choices"][0]["message"]["content"].endswith("echo: ")
