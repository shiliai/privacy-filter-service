"""FastAPI service for the local rules-only fallback redactor."""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import uvicorn
from fastapi import FastAPI, Response
from fastapi.responses import PlainTextResponse

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore[no-redef]

from pydantic import BaseModel, Field, ValidationError

from privacy_filter_service.config import PRIVACY_FILTER_CONFIG_ENV, FallbackConfig, Settings
from privacy_filter_service.local_fallback import redact_text as fallback_redact_text
from privacy_filter_service.models import (
    LABELS,
    HealthResponse,
    ModelInfoResponse,
    RedactBatchRequest,
    RedactRequest,
)

MAX_BATCH_SIZE = 100
VERSION = "0.1.0"


class FallbackOnlySettings(BaseModel):
    fallback: FallbackConfig = Field(default_factory=FallbackConfig)


def load_fallback_settings(
    config_path: str | Path | None = None,
    config_text: str | None = None,
) -> FallbackOnlySettings:
    """Load only fallback service settings without OPF service validation."""
    if config_text is not None:
        raw: dict = tomllib.loads(config_text)
    else:
        if config_path is None:
            config_path = os.environ.get(
                PRIVACY_FILTER_CONFIG_ENV,
                Path.home() / ".config" / "privacy-filter" / "config.toml",
            )
        config_path = Path(config_path)
        if not config_path.is_file():
            print(f"[FATAL] Config file not found: {config_path}", file=sys.stderr)
            sys.exit(1)
        raw = tomllib.loads(config_path.read_text(encoding="utf-8"))

    fallback = raw.setdefault("fallback", {})
    if "PRIVACY_FILTER_FALLBACK_HOST" in os.environ:
        fallback["host"] = os.environ["PRIVACY_FILTER_FALLBACK_HOST"]
    if "PRIVACY_FILTER_FALLBACK_PORT" in os.environ:
        fallback["port"] = int(os.environ["PRIVACY_FILTER_FALLBACK_PORT"])
    if "PRIVACY_FILTER_FALLBACK_URL" in os.environ:
        fallback["base_url"] = os.environ["PRIVACY_FILTER_FALLBACK_URL"]

    try:
        return FallbackOnlySettings.model_validate({"fallback": fallback})
    except (ValidationError, ValueError) as exc:
        print("[FATAL] Invalid fallback configuration:", file=sys.stderr)
        print(exc, file=sys.stderr)
        sys.exit(1)


def create_fallback_app(settings: Settings | None = None) -> FastAPI:
    """Build a local rules-only fallback app with OPF-compatible routes."""
    app = FastAPI(
        title="Privacy Filter Fallback Service",
        version=VERSION,
        docs_url=None,
        redoc_url=None,
    )
    app.state.settings = settings
    app.state.start_time = time.monotonic()
    _register_routes(app)
    return app


def _register_routes(app: FastAPI) -> None:
    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        uptime = time.monotonic() - getattr(app.state, "start_time", 0)
        return HealthResponse(
            ready=True,
            device="local-rules",
            uptime_s=round(uptime, 2),
            version=VERSION,
        )

    @app.get("/model-info", response_model=ModelInfoResponse)
    async def model_info() -> ModelInfoResponse:
        return ModelInfoResponse(
            device="local-rules",
            labels=list(LABELS),
            output_mode="typed",
            decode_mode="rules",
            decode_backend="local_fallback",
            version=VERSION,
        )

    @app.post("/redact")
    async def redact(body: RedactRequest) -> Response:
        result = fallback_redact_text(body.text)
        return Response(content=result.model_dump_json(), media_type="application/json")

    @app.post("/redact/text")
    async def redact_text(body: RedactRequest) -> Response:
        result = fallback_redact_text(body.text)
        return PlainTextResponse(result.redacted_text)

    @app.post("/redact/batch")
    async def redact_batch(body: RedactBatchRequest) -> Response:
        if len(body.texts) > MAX_BATCH_SIZE:
            return Response(
                status_code=413,
                content=f'{{"detail":"batch size {len(body.texts)} exceeds limit of {MAX_BATCH_SIZE}"}}',
                media_type="application/json",
            )
        results = [fallback_redact_text(text).model_dump() for text in body.texts]
        return Response(content=json.dumps(results), media_type="application/json")


def main() -> None:
    settings = load_fallback_settings()
    app = create_fallback_app(settings)
    uvicorn.run(
        app,
        host=settings.fallback.host,
        port=settings.fallback.port,
        workers=1,
        access_log=False,
    )


if __name__ == "__main__":
    main()
