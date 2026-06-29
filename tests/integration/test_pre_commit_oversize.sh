#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init pre-commit-oversize
pfit_start_service normal
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/oversize.stderr"

python3 - "$repo/large.txt" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text("A" * 1024 * 1024, encoding="utf-8")
PY

git -C "$repo" add large.txt
# Empty commit message so commit-msg does not hit /redact for the message;
# any /redact in the log then reflects pre-commit (which must skip the file).
PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" git -C "$repo" commit --allow-empty-message -m '' 2>"$stderr_file" >/dev/null
pfit_assert_no_patch "$repo"
grep -q 'skipping oversized file' "$stderr_file"
if pfit_log_contains '"path": "/redact"'; then
  echo "oversized file should not hit /redact" >&2
  exit 1
fi

echo "PASS test_pre_commit_oversize"
