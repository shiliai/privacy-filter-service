"""Tests for /redact/batch endpoint."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from privacy_filter_service.config import Settings, load_settings
from privacy_filter_service.models import RedactionResult, RedactionSummary

MINIMAL_TOML = """
[service]
host = "127.0.0.1"
port = 18765
device = "cpu"
output_mode = "typed"
decode_mode = "viterbi"
model_path = "/tmp/fake-checkpoint"
log_level = "WARNING"
"""


def _make_settings() -> Settings:
    return load_settings(config_text=MINIMAL_TOML)


def _make_result(text: str, redacted: str, span_count: int = 0) -> RedactionResult:
    return RedactionResult(
        text=text,
        redacted_text=redacted,
        detected_spans=[],
        summary=RedactionSummary(
            output_mode="typed",
            span_count=span_count,
            by_label={},
        ),
    )


def _mock_engine(results: list[RedactionResult] | None = None) -> MagicMock:
    engine = MagicMock()
    engine.ready = True
    engine.device = "cpu"
    engine.output_mode = "typed"
    engine.decode_mode = "viterbi"
    if results is None:
        results = [
            _make_result("Hello world", "Hello world", 0),
            _make_result("alice@example.com", "<PRIVATE_EMAIL>", 1),
        ]
    engine.redact_batch = AsyncMock(return_value=results)
    return engine


def _build_app(engine: MagicMock) -> object:
    from fastapi import FastAPI

    from privacy_filter_service.app import _register_routes

    settings = _make_settings()
    app = FastAPI()
    app.state.settings = settings
    app.state.engine = engine
    app.state.start_time = 0.0
    _register_routes(app)
    return app


@pytest_asyncio.fixture()
async def client():
    engine = _mock_engine()
    app = _build_app(engine)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac, engine


@pytest_asyncio.fixture()
async def client_no_engine():
    app = _build_app(None)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


class TestBatch:
    @pytest.mark.asyncio
    async def test_batch_returns_list(self, client):
        ac, engine = client
        results = [
            _make_result("Hello world", "Hello world", 0),
            _make_result("alice@example.com", "<PRIVATE_EMAIL>", 1),
            _make_result("555-123-4567", "<PRIVATE_PHONE>", 1),
        ]
        engine.redact_batch.return_value = results

        resp = await ac.post(
            "/redact/batch",
            json={"texts": ["Hello world", "alice@example.com", "555-123-4567"]},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert len(data) == 3
        assert data[0]["summary"]["span_count"] == 0
        assert data[1]["summary"]["span_count"] == 1
        assert data[2]["summary"]["span_count"] == 1

    @pytest.mark.asyncio
    async def test_batch_empty_returns_empty_list(self, client):
        ac, engine = client
        engine.redact_batch.return_value = []

        resp = await ac.post("/redact/batch", json={"texts": []})
        assert resp.status_code == 200
        assert resp.json() == []

    @pytest.mark.asyncio
    async def test_batch_order_preserved(self, client):
        ac, engine = client
        results = [
            _make_result("first", "first", 0),
            _make_result("second", "<X>", 1),
            _make_result("third", "third", 0),
        ]
        engine.redact_batch.return_value = results

        resp = await ac.post(
            "/redact/batch",
            json={"texts": ["first", "second", "third"]},
        )
        data = resp.json()
        assert data[0]["text"] == "first"
        assert data[1]["text"] == "second"
        assert data[2]["text"] == "third"

    @pytest.mark.asyncio
    async def test_batch_503_when_not_ready(self, client_no_engine):
        resp = await client_no_engine.post("/redact/batch", json={"texts": ["hello"]})
        assert resp.status_code == 503

    @pytest.mark.asyncio
    async def test_batch_oversized_text_returns_413(self, client):
        ac, engine = client
        big_text = "x" * 300_000
        resp = await ac.post("/redact/batch", json={"texts": ["short", big_text]})
        assert resp.status_code == 413
        assert "index 1" in resp.json()["detail"]
        engine.redact_batch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_batch_first_text_oversized(self, client):
        ac, engine = client
        big_text = "x" * 300_000
        resp = await ac.post("/redact/batch", json={"texts": [big_text, "short"]})
        assert resp.status_code == 413
        assert "index 0" in resp.json()["detail"]

    @pytest.mark.asyncio
    async def test_batch_no_raw_text_in_error(self, client):
        ac, engine = client
        big_text = "secret@example.com" + "x" * 300_000
        resp = await ac.post("/redact/batch", json={"texts": [big_text]})
        assert resp.status_code == 413
        assert "secret@example.com" not in resp.text

    @pytest.mark.asyncio
    async def test_batch_over_100_items(self, client):
        ac, engine = client
        texts = ["hello"] * 101
        resp = await ac.post("/redact/batch", json={"texts": texts})
        assert resp.status_code == 422
        engine.redact_batch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_batch_calls_engine_with_texts(self, client):
        ac, engine = client
        engine.redact_batch.return_value = [
            _make_result("a", "a", 0),
            _make_result("b", "b", 0),
        ]
        await ac.post("/redact/batch", json={"texts": ["a", "b"]})
        engine.redact_batch.assert_awaited_once_with(["a", "b"])
