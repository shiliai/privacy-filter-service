"""Tests for /health and /model-info endpoints."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from privacy_filter_service.config import Settings, load_settings
from privacy_filter_service.models import LABELS

MINIMAL_TOML = """
[service]
host = "127.0.0.1"
port = 18765
device = "cpu"
output_mode = "typed"
decode_mode = "viterbi"
decode_backend = "upstream"
model_path = "/tmp/fake-checkpoint"
log_level = "WARNING"

[hook]
max_file_bytes = 1024
"""


def _make_settings() -> Settings:
    return load_settings(config_text=MINIMAL_TOML)


def _mock_engine(**overrides) -> MagicMock:
    engine = MagicMock()
    engine.ready = overrides.get("ready", True)
    engine.device = overrides.get("device", "cpu")
    engine.output_mode = overrides.get("output_mode", "typed")
    engine.decode_mode = overrides.get("decode_mode", "viterbi")
    engine.decode_backend = overrides.get("decode_backend", "upstream")
    return engine


def _build_app(engine=None):
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
    app = _build_app(engine=None)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest_asyncio.fixture()
async def client_ready():
    app = _build_app(engine=_mock_engine())
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


class TestHealthNotReady:
    @pytest.mark.asyncio
    async def test_health_503_when_no_engine(self, client: AsyncClient):
        resp = await client.get("/health")
        assert resp.status_code == 503
        data = resp.json()
        assert data["ready"] is False


class TestHealthReady:
    @pytest.mark.asyncio
    async def test_health_200_when_ready(self, client_ready: AsyncClient):
        resp = await client_ready.get("/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["ready"] is True
        assert data["device"] == "cpu"
        assert "uptime_s" in data
        assert "version" in data


class TestModelInfo:
    @pytest.mark.asyncio
    async def test_model_info_ok(self, client_ready: AsyncClient):
        resp = await client_ready.get("/model-info")
        assert resp.status_code == 200
        data = resp.json()
        assert "model_path" not in data
        assert "checkpoint" not in data
        assert data["device"] == "cpu"
        assert len(data["labels"]) == len(LABELS)
        assert data["output_mode"] == "typed"
        assert data["decode_mode"] == "viterbi"
        assert data["decode_backend"] == "upstream"
        assert "version" in data

    @pytest.mark.asyncio
    async def test_model_info_labels_content(self, client_ready: AsyncClient):
        resp = await client_ready.get("/model-info")
        data = resp.json()
        assert set(data["labels"]) == set(LABELS)

    @pytest.mark.asyncio
    async def test_model_info_503_when_not_ready(self, client: AsyncClient):
        resp = await client.get("/model-info")
        assert resp.status_code == 503
