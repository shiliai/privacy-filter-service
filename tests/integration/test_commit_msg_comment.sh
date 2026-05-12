#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init commit-msg-comment
pfit_start_service normal
repo="$(pfit_make_repo repo)"
msg_file="$PF_IT_ROOT/message.txt"

cat > "$msg_file" <<'EOF'
Subject alice@example.com
# keep bob@example.com comment
Body 555-123-4567
EOF

(
  cd "$repo"
  PRIVACY_FILTER_URL="$PRIVACY_FILTER_URL" .git/hooks/commit-msg "$msg_file" >/dev/null
)
python3 - "$msg_file" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
expected = "Subject <PRIVATE_EMAIL>\n# keep bob@example.com comment\nBody <PRIVATE_PHONE>\n"
if text != expected:
    raise SystemExit(f"unexpected message file:\n{text!r}")
PY

echo "PASS test_commit_msg_comment"
