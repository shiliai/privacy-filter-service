#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init pre-commit-partial
pfit_start_service normal
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/partial.stderr"

printf 'v1\n' > "$repo/a.txt"
git -C "$repo" add a.txt
printf 'v2\n' > "$repo/a.txt"

if PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'partial staging' 2>"$stderr_file"; then
  echo "expected partial staging commit to fail" >&2
  exit 1
fi

grep -q 'Partial staging not supported in v1' "$stderr_file"

echo "PASS test_pre_commit_partial"
