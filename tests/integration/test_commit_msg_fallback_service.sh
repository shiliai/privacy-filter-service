#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

pfit_init commit-msg-fallback-service
pfit_start_fallback_service normal
repo="$(pfit_make_repo repo)"

cat > "$repo/clean.txt" <<'TXT'
clean content
TXT
git -C "$repo" add clean.txt

PRIVACY_FILTER_URL="http://127.0.0.1:1" PRIVACY_FILTER_FALLBACK_URL="$PRIVACY_FILTER_FALLBACK_URL" \
  git -C "$repo" commit -m 'Fix alice@example.com now' 2>"$PF_IT_ROOT/stderr.log" >/dev/null

msg="$(git -C "$repo" log -1 --pretty=%B)"
case "$msg" in
  *'<PRIVATE_EMAIL>'*) ;;
  *)
    echo "commit message was not redacted by fallback: $msg" >&2
    exit 1
    ;;
esac

grep -q 'local fallback' "$PF_IT_ROOT/stderr.log"
pfit_fallback_log_contains '"path": "/redact/text"'

echo "PASS test_commit_msg_fallback_service"
