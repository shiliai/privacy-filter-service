#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init service-down
# drop-on-redact: the mock answers /health but kills itself on the first
# /redact POST, so the primary is unreachable for the actual redaction.
pfit_start_service drop-on-redact
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/service-down.stderr"

printf "email = 'alice@example.com'\n" > "$repo/leak.py"
git -C "$repo" add leak.py

# The primary drops the connection on /redact, so the local non-model fallback
# must take over and STILL block the PII — no silent fail-open.
if PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'service down mid test' 2>"$stderr_file" >/dev/null; then
  echo "expected commit to be blocked by the local fallback" >&2
  exit 1
fi

grep -Eq 'blocked commit|fallback' "$stderr_file"
patch_file="$(pfit_patch_path "$repo")"
git -C "$repo" apply --check "$patch_file"
git -C "$repo" apply "$patch_file"
grep -q '<PRIVATE_EMAIL>' "$repo/leak.py"

echo "PASS test_service_down"
