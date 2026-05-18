#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init skip-env
pfit_start_service normal
repo="$(pfit_make_repo repo)"

printf "email = 'alice@example.com'\n" > "$repo/leak.py"
git -C "$repo" add leak.py
PRIVACY_FILTER_SKIP=1 PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'skip alice@example.com' >/dev/null
git -C "$repo" log -1 --pretty=%B | grep -q 'skip alice@example.com'
git -C "$repo" show HEAD:leak.py | grep -q 'alice@example.com'
if [ -s "$PF_IT_SERVICE_LOG" ]; then
  echo "skip env should bypass service entirely" >&2
  exit 1
fi

echo "PASS test_skip_env"
