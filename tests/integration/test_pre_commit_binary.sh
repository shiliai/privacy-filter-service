#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init pre-commit-binary
pfit_start_service normal
repo="$(pfit_make_repo repo)"

python3 - "$repo/blob.bin" <<'PY'
from pathlib import Path
import os, sys
Path(sys.argv[1]).write_bytes(os.urandom(1024))
PY

git -C "$repo" add blob.bin
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit -m 'binary file' >/dev/null
pfit_assert_no_patch "$repo"
if pfit_log_contains '"path": "/redact"'; then
  echo "binary file should not hit /redact" >&2
  exit 1
fi

echo "PASS test_pre_commit_binary"
