"""Sanitized logging setup — never logs raw text.

Provides structured JSON logging with automatic redaction of sensitive fields
and request-ID middleware for FastAPI.
"""

from __future__ import annotations

import json
import logging
import sys
import uuid
from contextvars import ContextVar
from typing import Any, Callable, Optional

_request_id: ContextVar[str] = ContextVar("request_id", default="-")

_REDACT_KEYS = frozenset(
    {"text", "message", "content", "payload", "redacted_text", "detected_spans", "placeholder"}
)

_FORMATTER_SKIP_KEYS = frozenset({
    "name", "msg", "args", "created", "relativeCreated",
    "exc_info", "exc_text", "stack_info", "lineno", "funcName",
    "pathname", "filename", "module", "thread", "threadName",
    "process", "processName", "levelname", "levelno", "message",
    "msecs", "taskName",
})


class RedactFilter(logging.Filter):
    """Strips sensitive fields from *LogRecord* attributes and *extra* dict."""

    def filter(self, record: logging.LogRecord) -> bool:
        for key in list(record.__dict__.keys()):
            if key in _REDACT_KEYS:
                setattr(record, key, "<REDACTED>")
        return True


class _SafeJSONFormatter(logging.Formatter):
    """Emit one JSON object per line with guaranteed redaction."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "logger": record.name,
            "request_id": _request_id.get("-"),
            "msg": record.getMessage(),
        }

        safe_extra_keys = {
            k: v
            for k, v in record.__dict__.items()
            if k not in _REDACT_KEYS and k not in _FORMATTER_SKIP_KEYS
        }

        payload["span_count"] = safe_extra_keys.pop("span_count", 0)
        payload["duration_ms"] = safe_extra_keys.pop("duration_ms", 0)
        payload.update(safe_extra_keys)

        for key in _REDACT_KEYS:
            payload.pop(key, None)

        if record.exc_info and not record.exc_text:
            record.exc_text = self.formatException(record.exc_info)
        if record.exc_text:
            payload["exception"] = "<REDACTED>"

        return json.dumps(payload, default=str)


def configure_logging(
    level: str = "INFO",
    *,
    stream: Optional[Any] = None,
) -> None:
    """Set up structured JSON logging.

    Parameters
    ----------
    level:
        Logging level string (DEBUG, INFO, WARNING, ERROR, …).
    stream:
        Writeable stream; defaults to *sys.stdout*.
    """
    root = logging.getLogger()
    root.handlers.clear()

    handler = logging.StreamHandler(stream or sys.stdout)
    handler.setFormatter(_SafeJSONFormatter(datefmt="%Y-%m-%dT%H:%M:%S.%fZ"))
    handler.addFilter(RedactFilter())
    root.setLevel(getattr(logging, level.upper(), logging.INFO))
    root.addHandler(handler)

    logging.getLogger("uvicorn.access").handlers.clear()
    logging.getLogger("uvicorn.access").propagate = False
    logging.getLogger("uvicorn.access").setLevel(logging.CRITICAL + 1)

    logging.getLogger("uvicorn.error").addFilter(RedactFilter())


def request_id_middleware(app: Any) -> Callable:
    """ASGI middleware that injects ``X-Request-ID`` into every request.

    If the header is already present it is reused; otherwise a UUID4 is
    generated.  The ID is stored in a context var so loggers can pick it up.
    """
    from starlette.middleware.base import BaseHTTPMiddleware
    from starlette.requests import Request
    from starlette.responses import Response

    class _Middleware(BaseHTTPMiddleware):
        async def dispatch(self, request: Request, call_next: Callable) -> Response:
            rid = request.headers.get("X-Request-ID", str(uuid.uuid4()))
            token = _request_id.set(rid)
            try:
                response = await call_next(request)
            finally:
                _request_id.reset(token)
            response.headers["X-Request-ID"] = rid
            return response

    return _Middleware(app)
