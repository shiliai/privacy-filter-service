#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init no-verify
pfit_start_service normal
repo="$(pfit_make_repo repo)"

printf "email = 'alice@example.com'\n" > "$repo/leak.py"
git -C "$repo" add leak.py
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit --no-verify -m 'raw alice@example.com' >/dev/null
git -C "$repo" log -1 --pretty=%B | grep -q 'raw alice@example.com'
git -C "$repo" show HEAD:leak.py | grep -q 'alice@example.com'
if [ -s "$PF_IT_SERVICE_LOG" ]; then
  echo "--no-verify should bypass service entirely" >&2
  exit 1
fi

echo "PASS test_no_verify"
