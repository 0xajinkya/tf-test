"""Stub tests — real model load is too heavy for CI.
Smoke test the import + handler shape only.
"""
import os
os.environ.setdefault("MODEL_PATH", "/nonexistent")


def test_module_imports():
    # llama_cpp + iii must import without side effects on import.
    import inference_worker.main  # noqa: F401


def test_handler_signature():
    from inference_worker import main
    assert callable(main.chat)
    assert callable(main.main)
