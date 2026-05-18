#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init commit-msg-redact
pfit_start_service normal
repo="$(pfit_make_repo repo)"

printf 'content\n' > "$repo/file.txt"
git -C "$repo" add file.txt
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'Fix alice@example.com now' >/dev/null
git -C "$repo" log -1 --pretty=%B | grep -q '<PRIVATE_EMAIL>'

echo "PASS test_commit_msg_redact"
