"""Rules-only local fallback redactor for when OPF is unavailable."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from typing import Iterable, Sequence

from detect_secrets.plugins.keyword import KeywordDetector
from detect_secrets.plugins.private_key import PrivateKeyDetector
from detect_secrets.plugins.jwt import JwtTokenDetector
from detect_secrets.plugins.openai import OpenAIDetector
from presidio_analyzer import Pattern, PatternRecognizer

from privacy_filter_service.models import DetectedSpan, RedactionResult, RedactionSummary

_EMAIL_RECOGNIZER = PatternRecognizer(
    supported_entity="private_email",
    patterns=[
        Pattern(
            "email",
            r"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b",
            0.95,
        )
    ],
)
_PHONE_RECOGNIZER = PatternRecognizer(
    supported_entity="private_phone",
    patterns=[
        Pattern(
            "north_american_phone",
            r"(?<!\d)(?:\+?1[\s.\-]?)?(?:\(?[2-9]\d{2}\)?[\s.\-]?)"
            r"[2-9]\d{2}[\s.\-]?\d{4}(?!\d)",
            0.80,
        )
    ],
)
_URL_RECOGNIZER = PatternRecognizer(
    supported_entity="private_url",
    patterns=[
        Pattern(
            "http_url",
            r"\bhttps?://[^\s<>'\"]+",
            0.70,
        ),
        Pattern(
            "bare_domain",
            r"(?<![@\w.-])(?:[A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?\.)+"
            r"[A-Z]{2,}(?:/[^\s<>'\"]*)?",
            0.65,
        )
    ],
)

_RECOGNIZERS: tuple[PatternRecognizer, ...] = (
    _EMAIL_RECOGNIZER,
    _PHONE_RECOGNIZER,
    _URL_RECOGNIZER,
)

_SECRET_PLUGINS = (
    KeywordDetector(),
    PrivateKeyDetector(),
    JwtTokenDetector(),
    OpenAIDetector(),
)

_SECRET_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"\bsk-(?:proj|live|test)?-[A-Za-z0-9_\-]{20,}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S),
)

_PLACEHOLDERS = {
    "private_email": "<PRIVATE_EMAIL>",
    "private_phone": "<PRIVATE_PHONE>",
    "private_url": "<PRIVATE_URL>",
    "secret": "<SECRET>",
}


@dataclass(frozen=True)
class _CandidateSpan:
    label: str
    start: int
    end: int
    placeholder: str
    score: float
    source: str


def redact_text(text: str) -> RedactionResult:
    """Redact high-confidence PII/secrets without model inference."""
    spans = _select_non_overlapping_spans(
        [*_iter_presidio_spans(text), *_iter_secret_spans(text)]
    )
    detected = [
        DetectedSpan(
            label=span.label,
            start=span.start,
            end=span.end,
            text=text[span.start : span.end],
            placeholder=span.placeholder,
        )
        for span in spans
    ]
    redacted = _apply_redactions(text, detected)
    by_label: dict[str, int] = {}
    for span in detected:
        by_label[span.label] = by_label.get(span.label, 0) + 1
    return RedactionResult(
        text=text,
        redacted_text=redacted,
        detected_spans=detected,
        summary=RedactionSummary(
            output_mode="typed",
            span_count=len(detected),
            by_label=dict(sorted(by_label.items())),
            decoded_mismatch=False,
        ),
        schema_version=1,
        warning="local rules-only fallback; not equivalent to OPF model detection",
    )


def _iter_presidio_spans(text: str) -> Iterable[_CandidateSpan]:
    for recognizer in _RECOGNIZERS:
        results = recognizer.analyze(
            text,
            entities=[recognizer.supported_entities[0]],
            nlp_artifacts=None,
        )
        for result in results:
            if result.start < result.end:
                yield _CandidateSpan(
                    label=result.entity_type,
                    start=result.start,
                    end=result.end,
                    placeholder=_PLACEHOLDERS[result.entity_type],
                    score=float(result.score),
                    source="presidio",
                )


def _iter_secret_spans(text: str) -> Iterable[_CandidateSpan]:
    for match in _iter_secret_regex_matches(text):
        yield match

    cursor = 0
    for line_no, line in enumerate(text.splitlines(keepends=True), start=1):
        line_start = cursor
        cursor += len(line)
        for plugin in _SECRET_PLUGINS:
            for secret in plugin.analyze_line("stdin", line, line_no):
                secret_value = getattr(secret, "secret_value", None)
                if not secret_value:
                    continue
                relative_start = line.find(secret_value)
                if relative_start < 0:
                    continue
                start = line_start + relative_start
                end = start + len(secret_value)
                yield _CandidateSpan(
                    label="secret",
                    start=start,
                    end=end,
                    placeholder=_PLACEHOLDERS["secret"],
                    score=0.90,
                    source=f"detect-secrets:{secret.type}",
                )


def _iter_secret_regex_matches(text: str) -> Iterable[_CandidateSpan]:
    for pattern in _SECRET_PATTERNS:
        for match in pattern.finditer(text):
            if match.start() < match.end():
                yield _CandidateSpan(
                    label="secret",
                    start=match.start(),
                    end=match.end(),
                    placeholder=_PLACEHOLDERS["secret"],
                    score=0.95,
                    source="regex",
                )


def _select_non_overlapping_spans(spans: Sequence[_CandidateSpan]) -> list[_CandidateSpan]:
    ordered = sorted(
        spans,
        key=lambda span: (
            span.start,
            -(span.end - span.start),
            _label_priority(span.label),
            -span.score,
        ),
    )
    selected: list[_CandidateSpan] = []
    cursor = 0
    for span in ordered:
        if span.start < cursor:
            continue
        selected.append(span)
        cursor = span.end
    return selected


def _label_priority(label: str) -> int:
    if label == "private_email":
        return 0
    if label == "secret":
        return 1
    return 2


def _apply_redactions(text: str, spans: Sequence[DetectedSpan]) -> str:
    if not spans:
        return text
    pieces: list[str] = []
    cursor = 0
    for span in spans:
        pieces.append(text[cursor : span.start])
        pieces.append(span.placeholder)
        cursor = span.end
    pieces.append(text[cursor:])
    return "".join(pieces)


def _read_input(args: argparse.Namespace) -> str:
    if args.text:
        return " ".join(args.text)
    return sys.stdin.read()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run local rules-only PII fallback")
    parser.add_argument("text", nargs="*", help="Text to redact. Reads stdin if omitted.")
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output structured JSON or redacted text only.",
    )
    parser.add_argument(
        "--json-indent",
        type=int,
        default=None,
        help="JSON indentation. Defaults to compact output.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    result = redact_text(_read_input(args))
    if args.format == "text":
        print(result.redacted_text)
    else:
        print(json.dumps(result.model_dump(), indent=args.json_indent, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
