from __future__ import annotations

import pytest
from pydantic import ValidationError

from privacy_filter_service.models import (
    LABELS,
    DetectedSpan,
    HealthResponse,
    ModelInfoResponse,
    RedactBatchRequest,
    RedactRequest,
    RedactionResult,
    RedactionSummary,
)


class TestLabels:
    def test_count(self):
        assert len(LABELS) == 8

    def test_contains_expected(self):
        for expected in (
            "account_number",
            "private_email",
            "private_person",
            "secret",
        ):
            assert expected in LABELS

    def test_is_tuple(self):
        assert isinstance(LABELS, tuple)


class TestRedactRequest:
    def test_valid(self):
        req = RedactRequest(text="hello world")
        assert req.text == "hello world"

    def test_empty_text_allowed(self):
        req = RedactRequest(text="")
        assert req.text == ""


class TestRedactBatchRequest:
    def test_valid(self):
        req = RedactBatchRequest(texts=["a", "b"])
        assert req.texts == ["a", "b"]

    def test_rejects_over_100(self):
        with pytest.raises(ValidationError):
            RedactBatchRequest(texts=[str(i) for i in range(101)])


class TestDetectedSpan:
    def test_valid(self):
        span = DetectedSpan(
            label="private_person",
            start=0,
            end=5,
            text="Alice",
            placeholder="<PRIVATE_PERSON>",
        )
        assert span.label == "private_person"
        assert span.start == 0
        assert span.end == 5

    def test_missing_field_raises(self):
        with pytest.raises(ValidationError):
            DetectedSpan(label="x", start=0)


class TestRedactionSummary:
    def test_valid(self):
        s = RedactionSummary(
            output_mode="typed",
            span_count=2,
            by_label={"private_person": 1, "private_date": 1},
        )
        assert s.decoded_mismatch is False

    def test_with_decoded_mismatch(self):
        s = RedactionSummary(
            output_mode="typed",
            span_count=1,
            by_label={"secret": 1},
            decoded_mismatch=True,
        )
        assert s.decoded_mismatch is True


class TestRedactionResult:
    def test_model_validate_opf_output(self):
        data = {
            "text": "Alice email alice@example.com",
            "redacted_text": "<PRIVATE_PERSON> email <PRIVATE_EMAIL>",
            "detected_spans": [
                {
                    "label": "private_person",
                    "start": 0,
                    "end": 5,
                    "text": "Alice",
                    "placeholder": "<PRIVATE_PERSON>",
                },
                {
                    "label": "private_email",
                    "start": 13,
                    "end": 29,
                    "text": "alice@example.com",
                    "placeholder": "<PRIVATE_EMAIL>",
                },
            ],
            "summary": {
                "output_mode": "typed",
                "span_count": 2,
                "by_label": {"private_email": 1, "private_person": 1},
                "decoded_mismatch": False,
            },
        }
        result = RedactionResult.model_validate(data)
        assert result.summary.span_count == 2
        assert len(result.detected_spans) == 2
        assert result.schema_version == 1

    def test_default_schema_version(self):
        result = RedactionResult.model_validate(
            {
                "text": "x",
                "redacted_text": "x",
                "detected_spans": [],
                "summary": {
                    "output_mode": "typed",
                    "span_count": 0,
                    "by_label": {},
                },
            }
        )
        assert result.schema_version == 1

    def test_optional_warning(self):
        result = RedactionResult.model_validate(
            {
                "text": "x",
                "redacted_text": "x",
                "detected_spans": [],
                "summary": {
                    "output_mode": "typed",
                    "span_count": 0,
                    "by_label": {},
                },
                "warning": "decode mismatch",
            }
        )
        assert result.warning == "decode mismatch"


class TestHealthResponse:
    def test_valid(self):
        h = HealthResponse(ready=True, device="cpu", uptime_s=1.5, version="0.1.0")
        assert h.ready is True
        assert h.device == "cpu"


class TestModelInfoResponse:
    def test_valid(self):
        m = ModelInfoResponse(
            device="cuda",
            labels=["private_person"],
            output_mode="typed",
            decode_mode="default",
            version="0.1.0",
        )
        assert m.labels == ["private_person"]

    def test_no_model_path_field(self):
        fields = set(ModelInfoResponse.model_fields.keys())
        assert "model_path" not in fields
        assert "checkpoint" not in fields
