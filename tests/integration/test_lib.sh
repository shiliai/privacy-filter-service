#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/hooks/_lib.sh"

assert_success() {
  local description=$1
  shift

  if "$@"; then
    return 0
  fi

  printf 'FAIL: %s\n' "$description" >&2
  exit 1
}

assert_failure() {
  local description=$1
  shift

  if "$@"; then
    printf 'FAIL: %s\n' "$description" >&2
    exit 1
  fi
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

repo_dir="$tmp_root/repo"
mkdir -p "$repo_dir"

(
  cd "$repo_dir"
  git init -q

  printf 'hello\n' > a.txt
  python3 - <<'PY'
from pathlib import Path
Path("b.bin").write_bytes(bytes(range(256)))
PY
  git add a.txt b.bin

  assert_success 'utf-8 text file should pass' pf_is_text_file a.txt
  assert_failure 'binary file should fail' pf_is_text_file b.bin
)

assert_success \
  'PRIVACY_FILTER_SKIP=1 should activate skip' \
  bash -c 'source "$1"; PRIVACY_FILTER_SKIP=1 pf_skip_active' _ "$ROOT_DIR/hooks/_lib.sh"

assert_failure \
  'unset PRIVACY_FILTER_SKIP should not activate skip' \
  bash -c 'source "$1"; pf_skip_active' _ "$ROOT_DIR/hooks/_lib.sh"

fail_open_output="$({
  cd "$repo_dir" && bash -c 'source "$1"; pf_fail_open "bad reason"' _ "$ROOT_DIR/hooks/_lib.sh";
} 2>&1)"

if [[ "$fail_open_output" != *'[privacy-filter] bad reason'* ]]; then
  printf 'FAIL: pf_fail_open should sanitize warning output (got: %s)\n' "$fail_open_output" >&2
  exit 1
fi

printf 'test_lib.sh: OK\n'
