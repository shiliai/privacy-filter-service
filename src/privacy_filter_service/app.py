"""FastAPI application factory with lifespan-managed OPF engine."""

from __future__ import annotations

import logging
import time
from contextlib import asynccontextmanager
from typing import AsyncIterator

import uvicorn
from fastapi import Depends, FastAPI, Request, Response
from fastapi.responses import PlainTextResponse

from privacy_filter_service.config import Settings, load_settings
from privacy_filter_service.logging_setup import configure_logging, request_id_middleware
from privacy_filter_service.models import (
    LABELS,
    HealthResponse,
    ModelInfoResponse,
    RedactBatchRequest,
    RedactRequest,
)
from privacy_filter_service.opf_engine import OPFEngine

log = logging.getLogger(__name__)

MAX_BATCH_SIZE = 100


# ---------------------------------------------------------------------------
# Dependency: retrieve engine from app state
# ---------------------------------------------------------------------------


def _get_engine(request: Request) -> OPFEngine | None:
    engine: OPFEngine | None = getattr(request.app.state, "engine", None)
    return engine


# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Create engine, warm up model, tear down on shutdown."""
    settings: Settings = app.state.settings
    engine = OPFEngine(settings.service)
    app.state.engine = engine
    app.state.start_time = time.monotonic()
    log.info(
        "warming up OPF engine (device=%s, decode_backend=%s)",
        engine.device,
        engine.decode_backend,
    )
    await engine.warmup()
    log.info(
        "OPF engine ready (device=%s, decode_backend=%s)",
        engine.device,
        engine.decode_backend,
    )
    yield
    app.state.engine = None


# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build and return a configured FastAPI instance."""
    if settings is None:
        settings = load_settings()

    app = FastAPI(
        title="Privacy Filter Service",
        version="0.1.0",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
    )
    app.state.settings = settings
    app.add_middleware(request_id_middleware)

    _register_routes(app)
    return app


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


def _register_routes(app: FastAPI) -> None:
    """Attach all endpoint handlers to *app*."""

    @app.get("/health", response_model=HealthResponse)
    async def health(request: Request) -> HealthResponse | Response:
        engine: OPFEngine | None = getattr(request.app.state, "engine", None)
        if engine is None or not engine.ready:
            return Response(
                content=HealthResponse(
                    ready=False, device="unknown", uptime_s=0.0, version="0.1.0"
                ).model_dump_json(),
                status_code=503,
                media_type="application/json",
            )
        uptime = time.monotonic() - getattr(request.app.state, "start_time", 0)
        return HealthResponse(
            ready=True,
            device=engine.device,
            uptime_s=round(uptime, 2),
            version="0.1.0",
        )

    @app.get("/model-info", response_model=ModelInfoResponse)
    async def model_info(
        request: Request,
        engine: OPFEngine | None = Depends(_get_engine),
    ) -> ModelInfoResponse | Response:
        if engine is None or not engine.ready:
            return Response(status_code=503, content='{"detail":"engine not ready"}')
        return ModelInfoResponse(
            device=engine.device,
            labels=list(LABELS),
            output_mode=engine.output_mode,
            decode_mode=engine.decode_mode,
            decode_backend=engine.decode_backend,
            version="0.1.0",
        )

    @app.post("/redact")
    async def redact(
        body: RedactRequest,
        request: Request,
        engine: OPFEngine | None = Depends(_get_engine),
    ) -> Response:
        if engine is None or not engine.ready:
            return Response(status_code=503, content='{"detail":"engine not ready"}')
        settings: Settings = request.app.state.settings
        if len(body.text.encode("utf-8")) > settings.hook.max_file_bytes:
            return Response(
                status_code=413,
                content='{"detail":"text exceeds maximum allowed size"}',
                media_type="application/json",
            )
        t0 = time.monotonic()
        result = await engine.redact(body.text)
        duration_ms = round((time.monotonic() - t0) * 1000, 2)
        log.info(
            "redact request",
            extra={
                "endpoint": "/redact",
                "text_len": len(body.text),
                "span_count": result.summary.span_count,
                "duration_ms": duration_ms,
            },
        )
        return Response(
            content=result.model_dump_json(),
            media_type="application/json",
        )

    @app.post("/redact/text")
    async def redact_text(
        body: RedactRequest,
        request: Request,
        engine: OPFEngine | None = Depends(_get_engine),
    ) -> Response:
        if engine is None or not engine.ready:
            return Response(status_code=503, content='{"detail":"engine not ready"}')
        settings: Settings = request.app.state.settings
        if len(body.text.encode("utf-8")) > settings.hook.max_file_bytes:
            return Response(
                status_code=413,
                content='{"detail":"text exceeds maximum allowed size"}',
                media_type="application/json",
            )
        t0 = time.monotonic()
        result = await engine.redact(body.text)
        duration_ms = round((time.monotonic() - t0) * 1000, 2)
        log.info(
            "redact/text request",
            extra={
                "endpoint": "/redact/text",
                "text_len": len(body.text),
                "span_count": result.summary.span_count,
                "duration_ms": duration_ms,
            },
        )
        return PlainTextResponse(result.redacted_text)

    @app.post("/redact/batch")
    async def redact_batch(
        body: RedactBatchRequest,
        request: Request,
        engine: OPFEngine | None = Depends(_get_engine),
    ) -> Response:
        if engine is None or not engine.ready:
            return Response(status_code=503, content='{"detail":"engine not ready"}')
        settings: Settings = request.app.state.settings
        if len(body.texts) > MAX_BATCH_SIZE:
            return Response(
                status_code=413,
                content='{"detail":f"batch size {len(body.texts)} exceeds limit of {MAX_BATCH_SIZE}"}',
                media_type="application/json",
            )
        for idx, text in enumerate(body.texts):
            if len(text.encode("utf-8")) > settings.hook.max_file_bytes:
                return Response(
                    status_code=413,
                    content=f'{{"detail":"text at index {idx} exceeds maximum allowed size"}}',
                    media_type="application/json",
                )
        t0 = time.monotonic()
        results = await engine.redact_batch(body.texts)
        duration_ms = round((time.monotonic() - t0) * 1000, 2)
        total_spans = sum(r.summary.span_count for r in results)
        log.info(
            "redact/batch request",
            extra={
                "endpoint": "/redact/batch",
                "text_len": sum(len(t) for t in body.texts),
                "span_count": total_spans,
                "duration_ms": duration_ms,
            },
        )
        import json

        return Response(
            content=json.dumps([r.model_dump() for r in results]),
            media_type="application/json",
        )


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


def main() -> None:
    """CLI entrypoint — configure logging and start uvicorn."""
    settings = load_settings()
    configure_logging(settings.service.log_level)
    app = create_app(settings)
    uvicorn.run(
        app,
        host=settings.service.host,
        port=settings.service.port,
        workers=1,
        access_log=False,
    )
