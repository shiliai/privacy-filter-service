#!/usr/bin/env bash
# Local non-model fallback as the only engine (no PRIVACY_FILTER_URL).
set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init fallback-redact
# No service started and no URL → the bundled local non-model fallback is the
# only engine. Unset defensively in case the caller's env leaks a URL in.
unset PRIVACY_FILTER_URL
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/fallback.stderr"

# PII file → fallback catches email + phone → blocked, with a reviewable patch.
printf "contact = 'alice@example.com'\nphone = 555-123-4567\n" > "$repo/leak.py"
git -C "$repo" add leak.py
if git -C "$repo" commit --allow-empty-message -m '' 2>"$stderr_file" >/dev/null; then
  echo "expected fallback to block the PII commit" >&2
  exit 1
fi
grep -q 'blocked commit' "$stderr_file"
patch_file="$(pfit_patch_path "$repo")"
git -C "$repo" apply --check "$patch_file"
git -C "$repo" apply "$patch_file"
grep -q '<PRIVATE_EMAIL>' "$repo/leak.py"
grep -q '<PRIVATE_PHONE>' "$repo/leak.py"

# Drop leak.py from the index: the patch was applied to the worktree, so it is
# now partially staged and must not be re-committed. The next commit should
# contain only the clean file.
git -C "$repo" rm --cached -q -f --ignore-unmatch leak.py
# Clear the patch left by the blocked PII commit so the clean commit starts fresh.
rm -f "$repo"/.git/privacy-filter/redact-*.patch

# Clean file → fallback finds nothing → commit succeeds, no patch.
echo "print('hello')" > "$repo/clean.py"
git -C "$repo" add clean.py
git -C "$repo" commit --allow-empty-message -m '' >/dev/null
pfit_assert_no_patch "$repo"

echo "PASS test_fallback_redact"
