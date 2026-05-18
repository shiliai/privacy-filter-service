#!/usr/bin/env bash
# Integration tests for install/uninstall scripts.
# Uses temporary XDG/git homes to avoid polluting the real user environment.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
INSTALL_DIR="$ROOT_DIR/install"

pass=0
fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS: %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$desc" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf '  PASS: %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle not found: %s\n' "$desc" "$needle" >&2
    fail=$((fail + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    printf '  PASS: %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    file not found: %s\n' "$desc" "$path" >&2
    fail=$((fail + 1))
  fi
}

assert_file_not_exists() {
  local desc="$1" path="$2"
  if [ ! -f "$path" ]; then
    printf '  PASS: %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    file should not exist: %s\n' "$desc" "$path" >&2
    fail=$((fail + 1))
  fi
}

make_test_home() {
  local home="$1"
  mkdir -p "$home/.config/systemd/user"
  mkdir -p "$home/.config/privacy-filter"
  mkdir -p "$home/.config/git/hooks"
}

cleanup_test_home() {
  local home="$1"
  rm -rf "$home"
}

# ============================================================================
# Test 1: install-hooks.sh — clean install
# ============================================================================
test_clean_install() {
  printf '\n--- test_clean_install ---\n'
  local home
  home="$(mktemp -d)"
  trap 'cleanup_test_home "$home"' RETURN

  make_test_home "$home"

  HOME="$home" git config --global --init core.hooksPath 2>/dev/null || true
  HOME="$home" git config --global --unset core.hooksPath 2>/dev/null || true

  local output
  output="$(HOME="$home" bash "$INSTALL_DIR/install-hooks.sh" 2>&1)" || true

  local hooks_path
  hooks_path="$(HOME="$home" git config --global core.hooksPath 2>/dev/null)" || true
  assert_eq "core.hooksPath set to our dir" "$home/.config/git/hooks" "$hooks_path"

  assert_file_exists "pre-commit hook copied" "$home/.config/git/hooks/pre-commit"
  assert_file_exists "commit-msg hook copied" "$home/.config/git/hooks/commit-msg"
  assert_file_exists "_lib.sh copied" "$home/.config/git/hooks/_lib.sh"

  assert_contains "output mentions completion" "$output" "Hook installation complete"

  cleanup_test_home "$home"
  trap - RETURN
}

# ============================================================================
# Test 2: install-hooks.sh — collision aborts
# ============================================================================
test_collision_abort() {
  printf '\n--- test_collision_abort ---\n'
  local home
  home="$(mktemp -d)"
  trap 'cleanup_test_home "$home"' RETURN

  make_test_home "$home"

  HOME="$home" git config --global core.hooksPath "/some/other/path"

  local output
  output="$(HOME="$home" bash "$INSTALL_DIR/install-hooks.sh" 2>&1)" && {
    printf '  FAIL: install-hooks.sh should have exited non-zero on collision\n' >&2
    fail=$((fail + 1))
  } || {
    assert_contains "aborts with collision message" "$output" "Aborting to avoid silently overriding"
    assert_contains "suggests --force" "$output" "--force"
  }

  local hooks_path
  hooks_path="$(HOME="$home" git config --global core.hooksPath 2>/dev/null)" || true
  assert_eq "core.hooksPath unchanged after collision" "/some/other/path" "$hooks_path"

  cleanup_test_home "$home"
  trap - RETURN
}

# ============================================================================
# Test 3: install-hooks.sh --force — overrides with backup
# ============================================================================
test_force_override() {
  printf '\n--- test_force_override ---\n'
  local home
  home="$(mktemp -d)"
  trap 'cleanup_test_home "$home"' RETURN

  make_test_home "$home"
  mkdir -p "$home/other-hooks"
  touch "$home/other-hooks/their-hook"

  HOME="$home" git config --global core.hooksPath "$home/other-hooks"

  local output
  output="$(HOME="$home" bash "$INSTALL_DIR/install-hooks.sh" --force 2>&1)" || true

  local hooks_path
  hooks_path="$(HOME="$home" git config --global core.hooksPath 2>/dev/null)" || true
  assert_eq "core.hooksPath updated to our dir" "$home/.config/git/hooks" "$hooks_path"

  local backup_count
  backup_count="$(find "$home" -maxdepth 1 -name 'other-hooks.bak-*' | wc -l)"
  assert_eq "backup created" "1" "$backup_count"

  assert_file_exists "pre-commit hook copied" "$home/.config/git/hooks/pre-commit"
  assert_file_exists "commit-msg hook copied" "$home/.config/git/hooks/commit-msg"

  cleanup_test_home "$home"
  trap - RETURN
}

# ============================================================================
# Test 4: uninstall.sh — reverses hooks and service
# ============================================================================
test_uninstall() {
  printf '\n--- test_uninstall ---\n'
  local home
  home="$(mktemp -d)"
  trap 'cleanup_test_home "$home"' RETURN

  make_test_home "$home"

  HOME="$home" git config --global core.hooksPath "$home/.config/git/hooks"
  cp "$ROOT_DIR/hooks/pre-commit" "$home/.config/git/hooks/pre-commit"
  cp "$ROOT_DIR/hooks/commit-msg" "$home/.config/git/hooks/commit-msg"
  cp "$ROOT_DIR/hooks/_lib.sh" "$home/.config/git/hooks/_lib.sh"

  echo "# user config" > "$home/.config/privacy-filter/config.toml"
  echo "OPF_CHECKPOINT=/tmp/model" > "$home/.config/privacy-filter/env"

  touch "$home/.config/systemd/user/privacy-filter.service"

  local output
  output="$(HOME="$home" bash "$INSTALL_DIR/uninstall.sh" 2>&1)" || true

  local hooks_path
  hooks_path="$(HOME="$home" git config --global core.hooksPath 2>/dev/null)" || true
  assert_eq "core.hooksPath unset" "" "$hooks_path"

  assert_file_not_exists "pre-commit hook removed" "$home/.config/git/hooks/pre-commit"
  assert_file_not_exists "commit-msg hook removed" "$home/.config/git/hooks/commit-msg"
  assert_file_not_exists "_lib.sh removed" "$home/.config/git/hooks/_lib.sh"

  assert_file_exists "user config.toml preserved" "$home/.config/privacy-filter/config.toml"
  assert_file_exists "user env preserved" "$home/.config/privacy-filter/env"

  assert_contains "output mentions preserved config" "$output" "Preserved"

  cleanup_test_home "$home"
  trap - RETURN
}

# ============================================================================
# Run all tests
# ============================================================================
test_clean_install
test_collision_abort
test_force_override
test_uninstall

printf '\n========================================\n'
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
printf '========================================\n'

if [ "$fail" -gt 0 ]; then
  exit 1
fi
