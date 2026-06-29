#!/usr/bin/env bash
# Last-resort behaviour: no primary AND fallback disabled.
# Default = fail-closed (block); PRIVACY_FILTER_FAIL_OPEN=1 = allow unredacted.
set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init fail-closed
unset PRIVACY_FILTER_URL
repo="$(pfit_make_repo repo)"
stderr_closed="$PF_IT_ROOT/failclosed.stderr"

printf "contact = 'alice@example.com'\n" > "$repo/leak.py"
git -C "$repo" add leak.py

# No primary, fallback disabled → no engine → default fail-closed: blocked.
if PRIVACY_FILTER_NO_FALLBACK=1 git -C "$repo" commit --allow-empty-message -m '' 2>"$stderr_closed" >/dev/null; then
  echo "expected fail-closed to block the commit" >&2
  exit 1
fi
grep -Eq 'no redaction engine|FAIL_OPEN|bypass' "$stderr_closed"
pfit_assert_no_patch "$repo"

# Same situation with FAIL_OPEN=1 → commit allowed (unredacted) + warning.
stderr_open="$PF_IT_ROOT/failopen.stderr"
if ! PRIVACY_FILTER_NO_FALLBACK=1 PRIVACY_FILTER_FAIL_OPEN=1 git -C "$repo" commit --allow-empty-message -m '' 2>"$stderr_open" >/dev/null; then
  echo "expected fail-open to allow the commit" >&2
  exit 1
fi
grep -Eq 'fail-open|unavailable' "$stderr_open"
# PII preserved unredacted (fail-open let it through).
git -C "$repo" show HEAD:leak.py | grep -q 'alice@example.com'

echo "PASS test_fail_closed"
