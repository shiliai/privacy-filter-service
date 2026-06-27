#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

pfit_init fallback-service
pfit_start_fallback_service normal
repo="$(pfit_make_repo repo)"

git -C "$repo" config user.name 'Test User'
git -C "$repo" config user.email 'test@example.com'

cat > "$repo/contact.txt" <<'TXT'
Contact alice@example.com or 415-555-1212.
TXT
git -C "$repo" add contact.txt

if PRIVACY_FILTER_URL="http://127.0.0.1:1" PRIVACY_FILTER_FALLBACK_URL="$PRIVACY_FILTER_FALLBACK_URL" git -C "$repo" commit -m 'fallback pii' 2>"$PF_IT_ROOT/stderr.log"; then
  echo "commit should be blocked by fallback service" >&2
  exit 1
fi

grep -q 'fallback' "$PF_IT_ROOT/stderr.log"
pfit_fallback_log_contains '"path": "/redact"'

patch_file="$(pfit_patch_path "$repo")"
grep -q '<PRIVATE_EMAIL>' "$patch_file"
grep -q '<PRIVATE_PHONE>' "$patch_file"

echo "PASS test_fallback_service"
