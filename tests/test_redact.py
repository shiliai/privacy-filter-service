"""Tests for /redact and /redact/text endpoints."""

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


def _make_redaction_result(text: str, redacted: str, span_count: int = 1) -> RedactionResult:
    return RedactionResult(
        text=text,
        redacted_text=redacted,
        detected_spans=[
            {
                "label": "private_email",
                "start": 0,
                "end": len(text),
                "text": text,
                "placeholder": "<PRIVATE_EMAIL>",
            }
        ],
        summary=RedactionSummary(
            output_mode="typed",
            span_count=span_count,
            by_label={"private_email": span_count},
        ),
    )


def _mock_engine(result: RedactionResult | None = None) -> MagicMock:
    engine = MagicMock()
    engine.ready = True
    engine.device = "cpu"
    engine.output_mode = "typed"
    engine.decode_mode = "viterbi"
    if result is None:
        result = _make_redaction_result("test", "<PRIVATE_EMAIL> test", 1)
    engine.redact = AsyncMock(return_value=result)
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


class TestRedact:
    @pytest.mark.asyncio
    async def test_redact_returns_200(self, client):
        ac, engine = client
        result = _make_redaction_result("alice@example.com", "<PRIVATE_EMAIL>", 1)
        engine.redact.return_value = result

        resp = await ac.post("/redact", json={"text": "alice@example.com"})
        assert resp.status_code == 200
        data = resp.json()
        assert data["redacted_text"] == "<PRIVATE_EMAIL>"
        assert data["summary"]["span_count"] == 1

    @pytest.mark.asyncio
    async def test_redact_calls_engine(self, client):
        ac, engine = client
        resp = await ac.post("/redact", json={"text": "hello world"})
        assert resp.status_code == 200
        engine.redact.assert_awaited_once_with("hello world")

    @pytest.mark.asyncio
    async def test_redact_503_when_not_ready(self, client_no_engine):
        resp = await client_no_engine.post("/redact", json={"text": "hello"})
        assert resp.status_code == 503

    @pytest.mark.asyncio
    async def test_redact_413_oversized(self, client):
        ac, engine = client
        big_text = "x" * 300_000
        resp = await ac.post("/redact", json={"text": big_text})
        assert resp.status_code == 413
        engine.redact.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_redact_no_raw_text_in_error(self, client):
        ac, engine = client
        big_text = "secret@example.com" + "x" * 300_000
        resp = await ac.post("/redact", json={"text": big_text})
        assert resp.status_code == 413
        assert "secret@example.com" not in resp.text


class TestRedactText:
    @pytest.mark.asyncio
    async def test_redact_text_returns_plain(self, client):
        ac, engine = client
        result = _make_redaction_result("Alice", "<PRIVATE_PERSON>", 1)
        engine.redact.return_value = result

        resp = await ac.post("/redact/text", json={"text": "Alice"})
        assert resp.status_code == 200
        assert "text/plain" in resp.headers["content-type"]
        assert "PRIVATE" in resp.text

    @pytest.mark.asyncio
    async def test_redact_text_503_when_not_ready(self, client_no_engine):
        resp = await client_no_engine.post("/redact/text", json={"text": "hello"})
        assert resp.status_code == 503

    @pytest.mark.asyncio
    async def test_redact_text_413_oversized(self, client):
        ac, engine = client
        big_text = "x" * 300_000
        resp = await ac.post("/redact/text", json={"text": big_text})
        assert resp.status_code == 413
        engine.redact.assert_not_awaited()
