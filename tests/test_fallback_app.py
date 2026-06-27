from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from privacy_filter_service.fallback_app import create_fallback_app, load_fallback_settings


@pytest_asyncio.fixture()
async def client():
    app = create_fallback_app()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


class TestFallbackHealth:
    @pytest.mark.asyncio
    async def test_health_is_ready_without_model(self, client: AsyncClient) -> None:
        resp = await client.get("/health")

        assert resp.status_code == 200
        assert resp.json()["ready"] is True
        assert resp.json()["device"] == "local-rules"

    def test_can_use_settings_with_cpu_service_and_large_hook_limit(self) -> None:
        settings = load_fallback_settings(
            config_text="""
[service]
host = "127.0.0.1"
port = 8765
device = "cpu"
output_mode = "typed"
decode_mode = "viterbi"
decode_backend = "upstream"
model_path = "/tmp/fake-checkpoint"
log_level = "WARNING"

[hook]
max_file_bytes = 262144

[fallback]
port = 8766
"""
        )

        app = create_fallback_app(settings)

        assert app.state.settings.fallback.port == 8766


class TestFallbackRedact:
    @pytest.mark.asyncio
    async def test_redact_returns_opf_compatible_json(self, client: AsyncClient) -> None:
        resp = await client.post(
            "/redact",
            json={"text": "Email alice@example.com and token sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"},
        )

        assert resp.status_code == 200
        data = resp.json()
        assert data["redacted_text"] == "Email <PRIVATE_EMAIL> and token <SECRET>"
        assert data["summary"]["by_label"] == {"private_email": 1, "secret": 1}

    @pytest.mark.asyncio
    async def test_redact_text_returns_plain_text(self, client: AsyncClient) -> None:
        resp = await client.post("/redact/text", json={"text": "Call 415-555-1212"})

        assert resp.status_code == 200
        assert "text/plain" in resp.headers["content-type"]
        assert resp.text == "Call <PRIVATE_PHONE>"

    @pytest.mark.asyncio
    async def test_redact_batch_returns_ordered_results(self, client: AsyncClient) -> None:
        resp = await client.post(
            "/redact/batch",
            json={"texts": ["clean", "Email alice@example.com"]},
        )

        assert resp.status_code == 200
        data = resp.json()
        assert [item["redacted_text"] for item in data] == [
            "clean",
            "Email <PRIVATE_EMAIL>",
        ]
