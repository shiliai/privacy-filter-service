#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init concurrent
pfit_start_service normal

repo_a="$(pfit_make_repo repo-a)"
repo_b="$(pfit_make_repo repo-b)"
stderr_a="$PF_IT_ROOT/repo-a.stderr"
stderr_b="$PF_IT_ROOT/repo-b.stderr"

printf "email = 'alice@example.com'\n" > "$repo_a/leak.py"
printf "email = 'bob@example.com'\n" > "$repo_b/leak.py"
git -C "$repo_a" add leak.py
git -C "$repo_b" add leak.py

set +e
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo_a" commit -m 'repo a' 2>"$stderr_a" &
pid_a=$!
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo_b" commit -m 'repo b' 2>"$stderr_b" &
pid_b=$!
wait "$pid_a"
status_a=$?
wait "$pid_b"
status_b=$?
set -e

[ "$status_a" -ne 0 ]
[ "$status_b" -ne 0 ]

patch_a="$(pfit_patch_path "$repo_a")"
patch_b="$(pfit_patch_path "$repo_b")"
[ "$patch_a" != "$patch_b" ]

git -C "$repo_a" apply --index "$patch_a"
git -C "$repo_b" apply --index "$patch_b"
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo_a" commit -m 'repo a redacted' >/dev/null
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo_b" commit -m 'repo b redacted' >/dev/null
git -C "$repo_a" show HEAD:leak.py | grep -q '<PRIVATE_EMAIL>'
git -C "$repo_b" show HEAD:leak.py | grep -q '<PRIVATE_EMAIL>'

echo "repo_a_patch=$patch_a"
echo "repo_b_patch=$patch_b"
echo "PASS test_concurrent"
