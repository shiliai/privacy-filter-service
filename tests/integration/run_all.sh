#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tests=(
  test_pre_commit_clean.sh
  test_pre_commit_pii.sh
  test_pre_commit_partial.sh
  test_pre_commit_binary.sh
  test_pre_commit_oversize.sh
  test_lfs_pointer.sh
  test_commit_msg_redact.sh
  test_commit_msg_clean.sh
  test_commit_msg_comment.sh
  test_commit_msg_empty_redact.sh
  test_service_down.sh
  test_malformed_response.sh
  test_fallback_redact.sh
  test_fallback_patterns.sh
  test_fail_closed.sh
  test_skip_env.sh
  test_no_verify.sh
  test_concurrent.sh
)

declare -a temp_roots=()
declare -a passed=()
declare -a failed=()

cleanup() {
  local dir
  for dir in "${temp_roots[@]:-}"; do
    [ -n "$dir" ] && [ -d "$dir" ] && rm -rf "$dir"
  done
}

trap cleanup EXIT

for test_name in "${tests[@]}"; do
  test_path="$SCRIPT_DIR/$test_name"
  if [ ! -x "$test_path" ]; then
    chmod +x "$test_path"
  fi

  temp_root="$(mktemp -d "/tmp/pf-it-${test_name%.sh}-XXXXXX")"
  temp_roots+=("$temp_root")

  printf '==> %s\n' "$test_name"
  if PF_IT_ROOT="$temp_root" bash "$test_path"; then
    passed+=("$test_name")
  else
    failed+=("$test_name")
  fi
done

printf '\nSummary\n'
printf 'PASS %s\n' "${#passed[@]}"
# ${arr[@]+"${arr[@]}"} is the set -u safe idiom for a possibly-empty array
# (bash 3.2 errors on "${arr[@]}" when the array is empty).
for test_name in ${passed[@]+"${passed[@]}"}; do
  printf '  PASS %s\n' "$test_name"
done
printf 'FAIL %s\n' "${#failed[@]}"
for test_name in ${failed[@]+"${failed[@]}"}; do
  printf '  FAIL %s\n' "$test_name"
done

if [ "${#failed[@]}" -gt 0 ]; then
  exit 1
fi
