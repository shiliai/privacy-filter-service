#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init lfs-pointer
pfit_start_service normal
repo="$(pfit_make_repo repo)"

cat > "$repo/lfs-pointer.bin" <<'LFS_EOF'
version https://git-lfs.github.com/spec/v1
oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
size 12345
LFS_EOF

git -C "$repo" add lfs-pointer.bin
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'add lfs pointer' >/dev/null

pfit_assert_no_patch "$repo"
if pfit_log_contains '"path": "/redact"'; then
  echo "LFS pointer file should not hit /redact" >&2
  exit 1
fi

echo "PASS test_lfs_pointer"
