#!/usr/bin/env bash
# smoke.sh — end-to-end smoke test for privacy-filter-service.
# Exercises the full lifecycle: install → test → uninstall.
# Idempotent: safe to run twice in a row.
# Total runtime target: ≤ 60s.
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_REPO="/tmp/pf-e2e-$$"
E2E_GITCONFIG="/tmp/pf-e2e-gitconfig-$$"
SERVICE_NAME="privacy-filter.service"
BASE_URL="http://127.0.0.1:8765"
HEALTH_TIMEOUT=30

REAL_GITCONFIG="$HOME/.gitconfig"
REAL_HOOKS_DIR="$HOME/.config/git/hooks"
REAL_CONFIG_DIR="$HOME/.config/privacy-filter"
REAL_CONFIG_TOML="$REAL_CONFIG_DIR/config.toml"
REAL_ENV_FILE="$REAL_CONFIG_DIR/env"

PASS_COUNT=0
FAIL_COUNT=0
_CONFIG_BACKUP=""
_ENV_BACKUP=""
_SAVED_HOOKS_PATH=""

export GIT_CONFIG_GLOBAL="$E2E_GITCONFIG"
if [ -d "$PROJECT_ROOT/.venv/bin" ]; then
  export PATH="$PROJECT_ROOT/.venv/bin:$PATH"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '[INFO]  %s\n' "$*"; }
pass()  { printf '[PASS]  Test %s: %s\n' "$1" "$2"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { printf '[FAIL]  Test %s: %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
die()   { printf '[FATAL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Cleanup — runs even on failure
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  info "Cleaning up…"
  systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$SERVICE_NAME" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  rm -rf "$TEST_REPO" 2>/dev/null || true
  rm -f "$E2E_GITCONFIG" 2>/dev/null || true

  # Restore backed-up config/env
  if [ -n "${_CONFIG_BACKUP:-}" ] && [ -f "${_CONFIG_BACKUP:-}" ]; then
    cp "$_CONFIG_BACKUP" "$REAL_CONFIG_TOML" 2>/dev/null || true
    rm -f "$_CONFIG_BACKUP"
  fi
  if [ -n "${_ENV_BACKUP:-}" ] && [ -f "${_ENV_BACKUP:-}" ]; then
    cp "$_ENV_BACKUP" "$REAL_ENV_FILE" 2>/dev/null || true
    rm -f "$_ENV_BACKUP"
  fi

  # Restore original hooks path
  restore_hooks_path
  info "Cleanup complete."

  # If any test failed, ensure non-zero exit
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
}

save_hooks_path() {
  _SAVED_HOOKS_PATH="$(git config --file "$REAL_GITCONFIG" core.hooksPath 2>/dev/null)" || true
}

restore_hooks_path() {
  if [ -n "${_SAVED_HOOKS_PATH:-}" ]; then
    git config --file "$REAL_GITCONFIG" core.hooksPath "$_SAVED_HOOKS_PATH"
  else
    git config --file "$REAL_GITCONFIG" --unset core.hooksPath 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
setup_gitconfig() {
  touch "$E2E_GITCONFIG"
  git config --global user.email "smoke@test.local"
  git config --global user.name "Smoke Test"
}

wait_for_healthy() {
  local elapsed=0 interval=2
  info "Waiting for service healthy (timeout ${HEALTH_TIMEOUT}s)…"
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
    local response
    response="$(curl -sS -m "$interval" "$BASE_URL/health" 2>/dev/null)" || true
    if [ -n "$response" ]; then
      if printf '%s' "$response" | python3 -c '
import json, sys
data = json.load(sys.stdin)
sys.exit(0 if data.get("ready") else 1)
' 2>/dev/null; then
        info "Service is healthy."
        return 0
      fi
    fi
    elapsed=$((elapsed + interval))
    info "  …${elapsed}s elapsed"
    sleep "$interval"
  done
  die "Service did not become healthy within ${HEALTH_TIMEOUT}s"
}

ensure_model_path() {
  local has_path
  has_path="$(grep '^model_path = ' "$REAL_CONFIG_TOML" | grep -v '""' | head -1)" || true
  if [ -z "$has_path" ]; then
    local checkpoint="/mnt/LLM/OpenAI/privacy_filter"
    if [ -d "$checkpoint" ]; then
      sed -i "s|^model_path = .*|model_path = \"$checkpoint\"|" "$REAL_CONFIG_TOML"
      info "Set model_path → $checkpoint"
    else
      die "No model checkpoint found at $checkpoint"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------
install_service() {
  info "Installing service (non-interactive)…"

  _CONFIG_BACKUP=""
  _ENV_BACKUP=""
  if [ -f "$REAL_CONFIG_TOML" ]; then
    _CONFIG_BACKUP="/tmp/pf-e2e-config-backup-$$"
    cp "$REAL_CONFIG_TOML" "$_CONFIG_BACKUP"
  fi
  if [ -f "$REAL_ENV_FILE" ]; then
    _ENV_BACKUP="/tmp/pf-e2e-env-backup-$$"
    cp "$REAL_ENV_FILE" "$_ENV_BACKUP"
  fi

  if [ ! -f "$REAL_CONFIG_TOML" ]; then
    mkdir -p "$REAL_CONFIG_DIR"
    cp "$PROJECT_ROOT/config.toml.example" "$REAL_CONFIG_TOML"
  fi
  if [ ! -f "$REAL_ENV_FILE" ]; then
    mkdir -p "$REAL_CONFIG_DIR"
    cp "$PROJECT_ROOT/config/env.example" "$REAL_ENV_FILE"
  fi

  ensure_model_path

  printf 'n\nn\nn\n' | bash "$PROJECT_ROOT/install/install-service.sh" 2>&1
  wait_for_healthy
}

install_hooks() {
  info "Installing hooks…"
  bash "$PROJECT_ROOT/install/install-hooks.sh" --force 2>&1
}

create_test_repo() {
  rm -rf "$TEST_REPO"
  mkdir -p "$TEST_REPO"
  git -C "$TEST_REPO" init
}

# ---------------------------------------------------------------------------
# Uninstall & verify
# ---------------------------------------------------------------------------
uninstall_all() {
  info "Uninstalling…"
  bash "$PROJECT_ROOT/install/uninstall.sh" 2>&1
}

verify_uninstall() {
  local ok=true

  if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info "  Service still active — FAIL"
    ok=false
  fi

  if [ -f "$HOME/.config/systemd/user/$SERVICE_NAME" ]; then
    info "  Unit file still exists — FAIL"
    ok=false
  fi

  local hooks_path
  hooks_path="$(git config --file "$REAL_GITCONFIG" core.hooksPath 2>/dev/null)" || true
  if [ -n "$hooks_path" ]; then
    info "  core.hooksPath still set to: $hooks_path — FAIL"
    ok=false
  fi

  if [ -d "$REAL_HOOKS_DIR" ]; then
    local remaining
    remaining="$(find "$REAL_HOOKS_DIR" -type f 2>/dev/null)" || true
    if [ -n "$remaining" ]; then
      info "  Hook directory not empty — FAIL"
      ok=false
    fi
  fi

  $ok && info "  Uninstall verified clean." || true
  $ok
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
LAST_PATCH=""

test_1_clean_commit() {
  info "Test 1: clean file commit…"
  cd "$TEST_REPO"
  echo "hello world" > clean.txt
  git add clean.txt
  if git commit -m "clean commit" 2>&1; then
    pass 1 "clean commit succeeded"
  else
    fail 1 "clean commit should have succeeded"
  fi
}

test_2_pii_commit_blocked() {
  info "Test 2: PII file commit (expect blocked)…"
  cd "$TEST_REPO"
  echo "Contact: alice@example.com for details" > pii.txt
  git add pii.txt
  local output
  if output="$(git commit -m "add pii" 2>&1)"; then
    fail 2 "PII commit should have been blocked"
  else
    # Extract patch path from hook output
    local patch_file=""
    patch_file="$(printf '%s' "$output" | grep -oP '(?<=apply with: git apply --index ")[^"]+')" || true
    if [ -z "$patch_file" ] || [ ! -f "$patch_file" ]; then
      patch_file="$(find "$TEST_REPO/.git/privacy-filter" -name 'redact-*.patch' -type f 2>/dev/null | sort -r | head -1)" || true
    fi
    if [ -n "$patch_file" ] && [ -f "$patch_file" ]; then
      pass 2 "PII commit blocked, patch at $patch_file"
      LAST_PATCH="$patch_file"
    else
      fail 2 "PII commit blocked but no patch file found"
    fi
  fi
}

test_3_apply_patch_and_commit() {
  info "Test 3: apply patch and commit (expect success)…"
  cd "$TEST_REPO"
  if [ -z "${LAST_PATCH:-}" ] || [ ! -f "${LAST_PATCH:-}" ]; then
    fail 3 "no patch file available from test 2"
    return
  fi
  if git apply --index "$LAST_PATCH" 2>&1; then
    if git commit -m "fixed: redacted PII" 2>&1; then
      local content
      content="$(git show HEAD:pii.txt 2>/dev/null)" || true
      if printf '%s' "$content" | grep -q "alice@example.com"; then
        fail 3 "committed file still contains PII"
      else
        pass 3 "commit succeeded with redacted content"
      fi
    else
      fail 3 "commit after patch apply should have succeeded"
    fi
  else
    fail 3 "git apply --index failed"
  fi
}

test_4_commit_msg_redaction() {
  info "Test 4: commit message PII redaction…"
  cd "$TEST_REPO"
  echo "some data" > msg.txt
  git add msg.txt
  if git commit -m "reach alice@example.com for info" 2>&1; then
    local msg
    msg="$(git log -1 --format='%s' 2>/dev/null)" || true
    if printf '%s' "$msg" | grep -q "alice@example.com"; then
      fail 4 "commit message still contains PII: $msg"
    else
      pass 4 "commit message PII was redacted: $msg"
    fi
  else
    fail 4 "commit with PII message should succeed (redaction, not block)"
  fi
}

test_5_skip_bypass() {
  info "Test 5: PRIVACY_FILTER_SKIP=1 bypass…"
  cd "$TEST_REPO"
  echo "bob@example.com secret data" > skip.txt
  git add skip.txt
  if PRIVACY_FILTER_SKIP=1 git commit -m "skip test" 2>&1; then
    local content
    content="$(git show HEAD:skip.txt 2>/dev/null)" || true
    if printf '%s' "$content" | grep -q "bob@example.com"; then
      pass 5 "skip bypass: PII preserved in file"
    else
      fail 5 "skip bypass: PII was unexpectedly redacted"
    fi
  else
    fail 5 "skip commit should have succeeded"
  fi
}

test_6_service_down() {
  info "Test 6: service down → local fallback blocks PII…"
  cd "$TEST_REPO"
  systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  sleep 1
  echo "charlie@example.com more secrets" > fallback.txt
  git add fallback.txt
  # Service is down, but the bundled local non-model fallback must still catch
  # the PII — no silent fail-open leak.
  if git commit -m "fallback test" >/dev/null 2>&1; then
    fail 6 "fallback: commit should be blocked when service is down"
  else
    pass 6 "fallback: PII blocked by local fallback with service down"
  fi

  info "Test 6b: fail-open escape hatch (FAIL_OPEN=1, no fallback)…"
  # Opt out of the fallback and into fail-open: the commit must succeed and
  # the PII must be preserved unredacted.
  if PRIVACY_FILTER_NO_FALLBACK=1 PRIVACY_FILTER_FAIL_OPEN=1 git commit -m "failopen test" >/dev/null 2>&1; then
    pass 6 "fail-open: commit succeeded with FAIL_OPEN=1"
    if git show HEAD:fallback.txt 2>/dev/null | grep -q "charlie@example.com"; then
      pass 6 "fail-open: PII preserved unredacted"
    else
      fail 6 "fail-open: PII unexpectedly redacted"
    fi
  else
    fail 6 "fail-open: commit should succeed with FAIL_OPEN=1"
  fi
}

test_7_no_journal_leak() {
  info "Test 7: checking journal for PII leaks…"
  if journalctl --user -u "$SERVICE_NAME" --since '10 minutes ago' 2>/dev/null | grep -q "alice@example"; then
    fail 7 "PII 'alice@example' found in journal logs"
  else
    pass 7 "no PII leakage in journal"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "=== Privacy Filter E2E Smoke Test ==="
  info "Project root:  $PROJECT_ROOT"
  info "Test repo:     $TEST_REPO"
  info "Isolated git:  $E2E_GITCONFIG"

  trap cleanup EXIT

  # ---- Clean state ----
  systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$SERVICE_NAME" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true

  # Unset core.hooksPath so install-hooks.sh runs cleanly
  save_hooks_path
  git config --file "$REAL_GITCONFIG" --unset core.hooksPath 2>/dev/null || true

  setup_gitconfig

  # ---- Install ----
  install_service
  install_hooks

  # ---- Tests ----
  create_test_repo

  test_1_clean_commit
  test_2_pii_commit_blocked
  test_3_apply_patch_and_commit
  test_4_commit_msg_redaction
  test_5_skip_bypass
  test_6_service_down
  test_7_no_journal_leak

  # ---- Uninstall & verify ----
  uninstall_all

  if verify_uninstall; then
    info "Uninstall verification: PASS"
  else
    info "Uninstall verification: FAIL"
  fi

  # ---- Summary ----
  echo ""
  printf '=%.0s' {1..50}
  echo ""
  printf '  PASS: %d\n' "$PASS_COUNT"
  printf '  FAIL: %d\n' "$FAIL_COUNT"
  printf '=%.0s' {1..50}
  echo ""

  [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
