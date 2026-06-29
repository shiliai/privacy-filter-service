#!/usr/bin/env bash
# PRIVACY_FILTER_URL in ~/.bashrc is only sourced by INTERACTIVE shells. When
# git runs from a non-interactive context (SSH/cron/CI) that export is invisible
# and the hook would silently drop to the local fallback. The hook must also
# read the primary URL from git config (privacyfilter.url), which git loads on
# every invocation regardless of shell type.
#
# Security: the hook reads ONLY `git config --global` (never repo-local
# .git/config) for the primary URL — the URL is where PII is sent, so a repo
# must not be able to redirect it. This test sets the URL via global git config
# AND asserts a repo-local value CANNOT override/hijack it into the fallback.
set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init git-config-url
pfit_start_service normal
mock_url="$PRIVACY_FILTER_URL"        # capture before unsetting the env
repo="$(pfit_make_repo repo)"
stderr_file="$PF_IT_ROOT/gc-url.stderr"

printf "contact = 'alice@example.com'\n" > "$repo/leak.py"
git -C "$repo" add leak.py

# Primary URL via GLOBAL git config (no PRIVACY_FILTER_URL env), plus a
# repo-local value pointing at a DEAD host that must NOT win.
git config --global privacyfilter.url "$mock_url"
git -C "$repo" config privacyfilter.url "http://127.0.0.1:1"   # must be ignored
unset PRIVACY_FILTER_URL

if PRIVACY_FILTER_URL="" git -C "$repo" commit --allow-empty-message -m '' 2>"$stderr_file" >/dev/null; then
  echo "expected primary (URL via global git config) to block the PII commit" >&2
  exit 1
fi
grep -Eq 'blocked commit' "$stderr_file"

# Proof the PRIMARY (mock /redact) was used — URL came from GLOBAL config, and
# the repo-local dead URL did NOT hijack it into the fallback.
pfit_log_contains '/redact' || { echo "FAIL: mock /redact not called — global git-config URL not used" >&2; exit 1; }
if grep -q 'local non-model fallback' "$stderr_file"; then
  echo "FAIL: fallback fired — repo-local privacyfilter.url hijacked the primary" >&2
  exit 1
fi

echo "PASS test_git_config_url"
