#!/usr/bin/env bash
# Primary returns HTTP 200 with a non-JSON body (e.g. a reverse-proxy HTML
# error page). The hook must NOT fail-open on the malformed response: it must
# treat the primary as failed, run the local non-model fallback, and still
# block the PII. Regression test for the contract: default = fail-closed.
set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init malformed-response
# /health answers normally, but /redact serves a 200 HTML body.
pfit_start_service malformed-redact
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/malformed-response.stderr"

printf "email = 'alice@example.com'\n" > "$repo/leak.py"
git -C "$repo" add leak.py

# Malformed 200 from primary → fallback must catch the email → commit blocked.
if PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'malformed primary response' 2>"$stderr_file" >/dev/null; then
  echo "expected fallback to block the PII commit despite a malformed primary 200" >&2
  exit 1
fi

grep -Eq 'blocked commit|fallback' "$stderr_file"
patch_file="$(pfit_patch_path "$repo")"
git -C "$repo" apply --check "$patch_file"
git -C "$repo" apply "$patch_file"
grep -q '<PRIVATE_EMAIL>' "$repo/leak.py"

# And with the fallback disabled, a malformed 200 must default to fail-closed
# (block) — not silently let the PII through.
repo2="$(pfit_make_repo repo2)"
printf "email = 'alice@example.com'\n" > "$repo2/leak.py"
git -C "$repo2" add leak.py
stderr2="$PF_IT_ROOT/malformed-nofallback.stderr"
if PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" PRIVACY_FILTER_NO_FALLBACK=1 git -C "$repo2" commit -m 'no fallback' 2>"$stderr2" >/dev/null; then
  echo "expected fail-closed block when primary is malformed and fallback disabled" >&2
  exit 1
fi
grep -Eq 'FAIL_OPEN|redaction|bypass|engine' "$stderr2"

echo "PASS test_malformed_response"
