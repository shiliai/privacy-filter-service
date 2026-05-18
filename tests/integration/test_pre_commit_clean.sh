#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init pre-commit-clean
pfit_start_service normal
repo="$(pfit_make_repo repo)"

printf 'print(2 + 2)\n' > "$repo/calc.py"
git -C "$repo" add calc.py
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'clean file' >/dev/null
pfit_assert_no_patch "$repo"
pfit_log_contains '"path": "/redact"'

echo "PASS test_pre_commit_clean"
