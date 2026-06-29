#!/usr/bin/env bash
# A misbehaving primary returns shape-valid JSON that is internally
# contradictory: it claims PII (span_count = 1) but returns an empty
# redacted_text. commit-msg must NOT blank the message and silently succeed —
# it must treat this as a failed redaction and fail-closed by default.
# (No staged file + --allow-empty isolates this to the commit-msg hook.)
set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init empty-redact
pfit_start_service redact-empty
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/empty-redact.stderr"

# Default (fail-closed): contradictory empty redaction must BLOCK.
if PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit --allow-empty --allow-empty-message \
    -m 'contact alice@example.com pls' 2>"$stderr_file" >/dev/null; then
  echo "expected commit-msg to block on an empty/contradictory redaction" >&2
  exit 1
fi
grep -Eq 'FAIL_OPEN|redaction|bypass' "$stderr_file"

# FAIL_OPEN=1 → allowed through (fail-open contract), original message preserved.
repo2="$(pfit_make_repo repo2)"
stderr2="$PF_IT_ROOT/empty-redact-open.stderr"
if ! PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" PRIVACY_FILTER_FAIL_OPEN=1 git -C "$repo2" commit --allow-empty --allow-empty-message \
    -m 'contact alice@example.com pls' 2>"$stderr2" >/dev/null; then
  echo "expected fail-open to allow the commit" >&2
  exit 1
fi

echo "PASS test_commit_msg_empty_redact"
