#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init service-down
pfit_start_service drop-on-redact
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/service-down.stderr"

printf "email = 'alice@example.com'\n" > "$repo/leak.py"
git -C "$repo" add leak.py
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'service down mid test' 2>"$stderr_file" >/dev/null
git -C "$repo" log -1 --pretty=%B | grep -q 'service down mid test'
git -C "$repo" show HEAD:leak.py | grep -q 'alice@example.com'
grep -Eiq 'fail-open|unavailable|failed' "$stderr_file"

echo "PASS test_service_down"
