"""Pydantic v2 models for the privacy-filter-service API."""

from __future__ import annotations

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Label taxonomy
# ---------------------------------------------------------------------------

LABELS: tuple[str, ...] = (
    "account_number",
    "private_address",
    "private_email",
    "private_person",
    "private_phone",
    "private_url",
    "private_date",
    "secret",
)

assert len(LABELS) == 8, f"Expected 8 labels, got {len(LABELS)}"


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------


class RedactRequest(BaseModel):
    """Single-text redaction request."""

    text: str


class RedactBatchRequest(BaseModel):
    """Batch redaction request (up to 100 texts)."""

    texts: list[str] = Field(..., max_length=100)


# ---------------------------------------------------------------------------
# Response domain models
# ---------------------------------------------------------------------------


class DetectedSpan(BaseModel):
    """One detected character span with label and placeholder."""

    label: str
    start: int
    end: int
    text: str
    placeholder: str


class RedactionSummary(BaseModel):
    """Compact summary of a redaction pass.

    Mirrors the dict returned by ``opf._core.runtime.build_detection_summary``.
    """

    output_mode: str
    span_count: int
    by_label: dict[str, int]
    decoded_mismatch: bool = False


class RedactionResult(BaseModel):
    """Structured result returned by the public OPF redaction API.

    Field names match ``opf._api.RedactionResult.to_dict()`` exactly for 1:1
    serialization compatibility.
    """

    text: str
    redacted_text: str
    detected_spans: list[DetectedSpan]
    summary: RedactionSummary
    schema_version: int = 1
    warning: str | None = None


# ---------------------------------------------------------------------------
# Operational models
# ---------------------------------------------------------------------------


class HealthResponse(BaseModel):
    """Liveness / readiness probe response."""

    ready: bool
    device: str
    uptime_s: float
    version: str


class ModelInfoResponse(BaseModel):
    """Runtime model metadata exposed to callers.

    Intentionally omits ``model_path`` and ``checkpoint`` to avoid leaking
    internal filesystem layout (PII-adjacent security concern).
    """

    device: str
    labels: list[str]
    output_mode: str
    decode_mode: str
    decode_backend: str
    version: str
