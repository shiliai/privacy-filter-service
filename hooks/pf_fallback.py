#!/usr/bin/env python3
"""Local non-model PII fallback for the privacy-filter git hooks.

Invoked in-process by the hooks (via ``hooks/_lib.sh``'s ``pf_redact``) when
the primary OPF model service is unreachable — or when no service is
configured at all (e.g. macOS with no GPU). It does lightweight regex-based
PII detection that needs **no model, no GPU, no torch** — only the Python
standard library — so it runs identically on macOS and Linux and needs no
daemon / systemd / launchd.

Contract — drop-in for the POST /redact HTTP endpoint:
  * reads a JSON request body ``{"text": "..."}`` on stdin
  * writes a JSON response on stdout with exactly the fields the hooks parse::

        {
          "text": "<original>",
          "redacted_text": "<text with PII replaced by placeholders>",
          "summary": {"span_count": <int>, "by_label": {<label>: <count>}},
          "schema_version": 1
        }

Placeholders use the same ``<UPPER_LABEL>`` format as the model service (see
``src/privacy_filter_service/models.py`` LABELS), so the hooks' existing
diff / patch / summary logic is reused unchanged.

Only mechanically-detectable, high-precision categories are matched by
default: ``private_email``, ``private_phone``, ``account_number`` (credit
cards, Luhn-validated) and ``secret`` (API keys / tokens / passwords).
Person names, postal addresses, URLs and dates need the model and are
intentionally NOT matched here — regex would produce too many false
positives in source code. Add patterns to ``_LABEL_RULES`` to extend.
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter


def _placeholder(label: str) -> str:
    """Mirror the model's ``<UPPER_LABEL>`` placeholder format."""
    return f"<{label.upper()}>"


# (compiled regex, label). Applied in order; each match is replaced by the
# label placeholder and counted. Order matters: specific patterns first so a
# later pattern cannot match inside an already-redacted placeholder.
_LABEL_RULES: list[tuple[re.Pattern[str], str]] = [
    # --- email -----------------------------------------------------------
    (re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"), "private_email"),
    # --- phone: North-American 10-digit (separators required) -----------
    (re.compile(r"\b\(?\d{3}\)?[-.\s]\d{3}[-.\s]\d{4}\b"), "private_phone"),
    # --- phone: international (leading '+' keeps false positives down) --
    (re.compile(r"\+\d{1,3}[\s.-]?\(?\d{1,4}\)?[\s.-]?\d{3,4}[\s.-]?\d{3,4}"), "private_phone"),
    # --- secrets: cloud / SCM / bearer tokens --------------------------
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "secret"),                    # AWS access key id
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b"), "secret"),           # GitHub token
    (re.compile(r"\bglpat-[A-Za-z0-9_\-]{20,}\b"), "secret"),            # GitLab token
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}\b"), "secret"),        # Slack token
    (re.compile(r"\bBearer\s+[A-Za-z0-9_\-.=]{20,}\b"), "secret"),
    # --- secrets: key = "value" assignments -----------------------------
    (re.compile(
        r"(?i)\b(api[_-]?key|secret|password|passwd|token|access[_-]?key|"
        r"client[_-]?secret|private[_-]?key)\b\s*[:=]\s*['\"]?"
        r"[A-Za-z0-9/_+=\-.]{16,}['\"]?"
    ), "secret"),
]

# Candidate credit-card / account numbers: 13..19 digits, optionally spaced
# or dashed. Luhn-validated before redaction to avoid false positives.
_CARD_RE = re.compile(r"\b(?:\d[ -]?){13,19}\b")


def _luhn_ok(digits: str) -> bool:
    total = 0
    parity = len(digits) % 2
    for i, ch in enumerate(digits):
        n = ord(ch) - 48
        if i % 2 == parity:
            n *= 2
            if n > 9:
                n -= 9
        total += n
    return total % 10 == 0


def redact(text: str) -> tuple[str, Counter]:
    """Return (redacted_text, Counter of label -> count)."""
    counts: Counter = Counter()

    def _make_sub(label: str):
        def _sub(_match: re.Match[str]) -> str:
            counts[label] += 1
            return _placeholder(label)
        return _sub

    for regex, label in _LABEL_RULES:
        text = regex.sub(_make_sub(label), text)

    def _card_sub(match: re.Match[str]) -> str:
        digits = re.sub(r"\D", "", match.group(0))
        if len(digits) < 13 or len(digits) > 19 or not _luhn_ok(digits):
            return match.group(0)
        counts["account_number"] += 1
        return _placeholder("account_number")

    text = _CARD_RE.sub(_card_sub, text)
    return text, counts


def _read_text() -> str:
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return raw
    if isinstance(data, dict):
        return str(data.get("text", ""))
    if isinstance(data, str):
        return data
    return raw


def main() -> None:
    text = _read_text()
    redacted, counts = redact(text)
    result = {
        "text": text,
        "redacted_text": redacted,
        "summary": {"span_count": int(sum(counts.values())), "by_label": dict(counts)},
        "schema_version": 1,
    }
    sys.stdout.write(json.dumps(result))


if __name__ == "__main__":
    main()
