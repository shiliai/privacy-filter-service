#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init pre-commit-pii
pfit_start_service normal
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/pii.stderr"

printf "email = 'alice@example.com'\n" > "$repo/leak.py"
git -C "$repo" add leak.py

if PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'pii file' 2>"$stderr_file"; then
  echo "expected commit to fail" >&2
  exit 1
fi

grep -q 'blocked commit' "$stderr_file"
patch_file="$(pfit_patch_path "$repo")"
cp "$repo/leak.py" "$PF_IT_ROOT/original.txt"
git -C "$repo" apply --check "$patch_file"
git -C "$repo" apply "$patch_file"
grep -q '<PRIVATE_EMAIL>' "$repo/leak.py"
git -C "$repo" apply --reverse --check "$patch_file"
git -C "$repo" apply --reverse "$patch_file"
cmp -s "$repo/leak.py" "$PF_IT_ROOT/original.txt"
git -C "$repo" apply --cached "$patch_file"
git -C "$repo" show :leak.py | grep -q '<PRIVATE_EMAIL>'

echo "PASS test_pre_commit_pii"
