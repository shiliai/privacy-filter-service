"""Tests for sanitized logging setup."""

import io
import json
import logging

import pytest

from privacy_filter_service.logging_setup import (
    RedactFilter,
    configure_logging,
    request_id_middleware,
)


@pytest.fixture(autouse=True)
def _reset_logging():
    yield
    root = logging.getLogger()
    root.handlers.clear()
    for name in ("uvicorn.access", "uvicorn.error"):
        lg = logging.getLogger(name)
        lg.handlers.clear()
        lg.propagate = True
        lg.setLevel(logging.WARNING)


class TestRedactFilter:
    def test_redacts_text_field(self):
        filt = RedactFilter()
        rec = logging.LogRecord("test", logging.INFO, "", 0, "hi", (), None)
        rec.text = "alice@example.com"
        assert filt.filter(rec) is True
        assert rec.text == "<REDACTED>"

    def test_redacts_all_sensitive_keys(self):
        filt = RedactFilter()
        rec = logging.LogRecord("test", logging.INFO, "", 0, "hi", (), None)
        sensitive = {
            "text": "secret",
            "message": "secret",
            "content": "secret",
            "payload": "secret",
            "redacted_text": "secret",
            "detected_spans": "secret",
            "placeholder": "secret",
        }
        for k, v in sensitive.items():
            setattr(rec, k, v)
        filt.filter(rec)
        for k in sensitive:
            assert getattr(rec, k) == "<REDACTED>", f"{k} was not redacted"

    def test_preserves_safe_fields(self):
        filt = RedactFilter()
        rec = logging.LogRecord("test", logging.INFO, "", 0, "hi", (), None)
        rec.span_count = 3
        filt.filter(rec)
        assert rec.span_count == 3


class TestConfigureLogging:
    def test_email_not_in_output(self):
        buf = io.StringIO()
        configure_logging("INFO", stream=buf)
        log = logging.getLogger("test")
        log.info("processed", extra={"text": "alice@example.com", "span_count": 1})
        out = buf.getvalue()
        assert "alice@example.com" not in out, f"email leaked in output: {out}"

    def test_span_count_present(self):
        buf = io.StringIO()
        configure_logging("INFO", stream=buf)
        log = logging.getLogger("test")
        log.info("processed", extra={"span_count": 1})
        out = buf.getvalue()
        data = json.loads(out.strip())
        assert data["span_count"] == 1

    def test_output_is_json(self):
        buf = io.StringIO()
        configure_logging("INFO", stream=buf)
        log = logging.getLogger("test")
        log.info("hello")
        out = buf.getvalue().strip()
        data = json.loads(out)
        assert data["msg"] == "hello"
        assert data["level"] == "INFO"
        assert "timestamp" in data
        assert "request_id" in data
        assert data["span_count"] == 0
        assert data["duration_ms"] == 0

    def test_debug_level_redacts(self):
        buf = io.StringIO()
        configure_logging("DEBUG", stream=buf)
        log = logging.getLogger("test")
        log.debug("raw", extra={"content": "sensitive data"})
        out = buf.getvalue()
        assert "sensitive data" not in out


class TestUvicornAccessLog:
    def test_uvicorn_access_suppressed(self):
        configure_logging("INFO")
        access = logging.getLogger("uvicorn.access")
        assert access.propagate is False
        assert access.level > logging.CRITICAL

    def test_uvicorn_access_source_contains_handling(self):
        import inspect
        src = inspect.getsource(configure_logging)
        assert "uvicorn.access" in src
