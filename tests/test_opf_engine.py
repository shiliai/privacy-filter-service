from __future__ import annotations

# pyright: reportMissingTypeStubs=false, reportPrivateUsage=false

import asyncio
import sys
from types import SimpleNamespace
from typing import Literal

import pytest

from privacy_filter_service import opf_engine
from privacy_filter_service.config import ServiceConfig, Settings


def _service_config(device: Literal["cpu", "cuda"] = "cpu") -> ServiceConfig:
    return ServiceConfig(
        device=device,
        output_mode="typed",
        decode_mode="viterbi",
        model_path="/tmp/mock-model",
        host="0.0.0.0",
        port=8765,
        log_level="INFO",
    )


def _opf_result(text: str, span_count: int = 1) -> SimpleNamespace:
    return SimpleNamespace(
        to_dict=lambda: {
            "schema_version": 1,
            "summary": {
                "output_mode": "typed",
                "span_count": span_count,
                "by_label": {"private_person": span_count},
                "decoded_mismatch": False,
            },
            "text": text,
            "redacted_text": "[private_person]",
            "detected_spans": [
                {
                    "label": "private_person",
                    "start": 0,
                    "end": len(text),
                    "text": text,
                    "placeholder": "[private_person]",
                }
            ],
        }
    )


def _patch_redact_with_gpu_decode(
    monkeypatch: pytest.MonkeyPatch,
    calls: list[tuple[str, str]] | None = None,
    *,
    span_count: int = 1,
    return_text_only: bool = False,
) -> None:
    def fake_redact_with_gpu_decode(opf: object, text: str) -> SimpleNamespace | str:
        if calls is not None:
            calls.append(("redact", text))
        if return_text_only:
            return text
        return _opf_result(text, span_count=span_count)

    monkeypatch.setattr(opf_engine, "redact_with_gpu_decode", fake_redact_with_gpu_decode)


@pytest.fixture(autouse=True)
def reset_engine_singleton() -> None:
    opf_engine._engine = None


@pytest.mark.asyncio
async def test_warmup_initializes_opf_and_marks_ready(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, str]] = []

    class FakeOPF:
        def __init__(self, **kwargs: str) -> None:
            calls.append(("init", kwargs["device"]))

    monkeypatch.setattr(opf_engine, "OPF", FakeOPF)
    _patch_redact_with_gpu_decode(monkeypatch, calls)

    engine = opf_engine.OPFEngine(_service_config())
    await engine.warmup()

    assert engine.ready is True
    assert calls == [("init", "cpu"), ("redact", "test")]


@pytest.mark.asyncio
async def test_redact_converts_opf_result_to_pydantic(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeOPF:
        def __init__(self, **_: str) -> None:
            pass

    monkeypatch.setattr(opf_engine, "OPF", FakeOPF)
    _patch_redact_with_gpu_decode(monkeypatch, span_count=2)

    engine = opf_engine.OPFEngine(_service_config())
    result = await engine.redact("Alice")

    assert result.text == "Alice"
    assert result.summary.span_count == 2


@pytest.mark.asyncio
async def test_redact_batch_serializes_and_preserves_order(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[str] = []

    class FakeOPF:
        def __init__(self, **_: str) -> None:
            pass

    monkeypatch.setattr(opf_engine, "OPF", FakeOPF)

    def fake_redact_with_gpu_decode(opf: object, text: str) -> SimpleNamespace:
        seen.append(text)
        return _opf_result(text)

    monkeypatch.setattr(opf_engine, "redact_with_gpu_decode", fake_redact_with_gpu_decode)

    engine = opf_engine.OPFEngine(_service_config())
    results = await engine.redact_batch(["one", "two", "three"])

    assert seen == ["test", "one", "two", "three"]
    assert [result.text for result in results] == ["one", "two", "three"]


@pytest.mark.asyncio
async def test_concurrent_redact_calls_share_lock(monkeypatch: pytest.MonkeyPatch) -> None:
    active = 0
    max_active = 0
    seen: list[str] = []

    class FakeOPF:
        def __init__(self, **_: str) -> None:
            pass

    def fake_redact_with_gpu_decode(opf: object, text: str) -> SimpleNamespace:
        nonlocal active, max_active
        active += 1
        max_active = max(max_active, active)
        seen.append(text)
        import time

        time.sleep(0.01)
        active -= 1
        return _opf_result(text)

    monkeypatch.setattr(opf_engine, "OPF", FakeOPF)
    monkeypatch.setattr(opf_engine, "redact_with_gpu_decode", fake_redact_with_gpu_decode)

    engine = opf_engine.OPFEngine(_service_config())
    await engine.warmup()
    _ = await asyncio.gather(engine.redact("first"), engine.redact("second"), engine.redact("third"))

    assert max_active == 1
    assert seen == ["test", "first", "second", "third"]


@pytest.mark.asyncio
async def test_get_engine_returns_singleton(monkeypatch: pytest.MonkeyPatch) -> None:
    init_count = 0

    class FakeOPF:
        def __init__(self, **_: str) -> None:
            nonlocal init_count
            init_count += 1

    monkeypatch.setattr(opf_engine, "OPF", FakeOPF)
    _patch_redact_with_gpu_decode(monkeypatch)

    settings = Settings(service=_service_config())
    first = await opf_engine.get_engine(settings)
    second = await opf_engine.get_engine(settings)

    assert first is second
    assert init_count == 1


@pytest.mark.asyncio
async def test_warmup_raises_if_opf_returns_text_only(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeOPF:
        def __init__(self, **_: str) -> None:
            pass

    monkeypatch.setattr(opf_engine, "OPF", FakeOPF)
    _patch_redact_with_gpu_decode(monkeypatch, return_text_only=True)

    engine = opf_engine.OPFEngine(_service_config())
    with pytest.raises(TypeError, match="text-only"):
        await engine.warmup()


@pytest.mark.asyncio
async def test_cuda_warmup_fails_fast_when_gpu_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeCuda:
        @staticmethod
        def is_available() -> bool:
            return False

    class FakeTorch:
        cuda: FakeCuda = FakeCuda()

    class FakeOPF:
        def __init__(self, **_: str) -> None:
            raise AssertionError("OPF() should not be called when CUDA is unavailable")

    monkeypatch.setattr(opf_engine, "OPF", FakeOPF)
    monkeypatch.setitem(sys.modules, "torch", FakeTorch)

    engine = opf_engine.OPFEngine(_service_config(device="cuda"))
    with pytest.raises(RuntimeError, match="CUDA"):
        await engine.warmup()


@pytest.mark.gpu
@pytest.mark.asyncio
async def test_cuda_warmup_succeeds_when_gpu_available(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeCuda:
        @staticmethod
        def is_available() -> bool:
            return True

    class FakeTorch:
        cuda: FakeCuda = FakeCuda()

    class FakeOPF:
        def __init__(self, **kwargs: str) -> None:
            assert kwargs["device"] == "cuda"

    monkeypatch.setitem(sys.modules, "torch", FakeTorch)
    monkeypatch.setattr(opf_engine, "OPF", FakeOPF)
    _patch_redact_with_gpu_decode(monkeypatch)

    engine = opf_engine.OPFEngine(_service_config(device="cuda"))
    await engine.warmup()

    assert engine.ready is True
