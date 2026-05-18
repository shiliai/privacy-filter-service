#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init commit-msg-clean
pfit_start_service normal
repo="$(pfit_make_repo repo)"

printf 'content\n' > "$repo/file.txt"
git -C "$repo" add file.txt
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'Fix docs typo' >/dev/null
msg="$(git -C "$repo" log -1 --pretty=%B)"
[ "$msg" = 'Fix docs typo' ]

echo "PASS test_commit_msg_clean"
