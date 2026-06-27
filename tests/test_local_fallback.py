from __future__ import annotations

import json
import subprocess
import sys

from privacy_filter_service.local_fallback import redact_text
from privacy_filter_service.models import RedactionResult


def test_redact_text_returns_opf_compatible_result_for_email_phone_and_secret() -> None:
    text = (
        "Contact alice@example.com or 415-555-1212. "
        "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"
    )

    result = redact_text(text)

    validated = RedactionResult.model_validate(result.model_dump())
    assert validated.schema_version == 1
    assert validated.summary.output_mode == "typed"
    assert validated.summary.by_label["private_email"] == 1
    assert validated.summary.by_label["private_phone"] == 1
    assert validated.summary.by_label["secret"] == 1
    assert validated.summary.span_count == 3
    assert "alice@example.com" not in validated.redacted_text
    assert "415-555-1212" not in validated.redacted_text
    assert "sk-proj-" not in validated.redacted_text
    assert "<PRIVATE_EMAIL>" in validated.redacted_text
    assert "<PRIVATE_PHONE>" in validated.redacted_text
    assert "<SECRET>" in validated.redacted_text


def test_redact_text_suppresses_overlapping_secret_inside_email() -> None:
    text = "Email alice@example.com"

    result = redact_text(text)

    assert result.redacted_text == "Email <PRIVATE_EMAIL>"
    assert [(span.label, span.start, span.end) for span in result.detected_spans] == [
        ("private_email", 6, 23)
    ]


def test_cli_reads_stdin_and_writes_json() -> None:
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "privacy_filter_service.local_fallback",
            "--format",
            "json",
        ],
        input="Call 415-555-1212",
        text=True,
        capture_output=True,
        check=True,
    )

    payload = json.loads(proc.stdout)
    assert payload["redacted_text"] == "Call <PRIVATE_PHONE>"
    assert payload["summary"]["by_label"] == {"private_phone": 1}


def test_cli_can_write_redacted_text_only() -> None:
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "privacy_filter_service.local_fallback",
            "--format",
            "text",
            "Email alice@example.com",
        ],
        text=True,
        capture_output=True,
        check=True,
    )

    assert proc.stdout == "Email <PRIVATE_EMAIL>\n"


def test_redact_text_detects_jwt_as_secret() -> None:
    text = (
        "Authorization: Bearer "
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
        "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkFsaWNlIn0."
        "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    )

    result = redact_text(text)

    assert result.summary.by_label == {"secret": 1}
    assert result.redacted_text == "Authorization: Bearer <SECRET>"


def test_redact_text_detects_private_key_block_as_secret() -> None:
    text = (
        "key = '''-----BEGIN PRIVATE KEY-----\n"
        "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n"
        "-----END PRIVATE KEY-----'''"
    )

    result = redact_text(text)

    assert result.summary.by_label == {"secret": 1}
    assert "<SECRET>" in result.redacted_text
    assert "BEGIN PRIVATE KEY" not in result.redacted_text


def test_redact_text_detects_bare_domain_as_private_url() -> None:
    text = "Customer portal lives at privacy.example.com/path?id=123"

    result = redact_text(text)

    assert result.summary.by_label == {"private_url": 1}
    assert result.redacted_text == "Customer portal lives at <PRIVATE_URL>"
