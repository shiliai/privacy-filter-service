#!/usr/bin/env bash
# remote_fallback.sh — e2e test for remote OPF primary plus local fallback.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_DIR="$ROOT_DIR/hooks"
PRIMARY_URL="${PRIVACY_FILTER_URL:-http://192.168.88.75:8765}"
FALLBACK_HOST="${PRIVACY_FILTER_FALLBACK_HOST:-127.0.0.1}"
FALLBACK_PORT="${PRIVACY_FILTER_FALLBACK_PORT:-8766}"
FALLBACK_URL="${PRIVACY_FILTER_FALLBACK_URL:-http://${FALLBACK_HOST}:${FALLBACK_PORT}}"
TMP_ROOT="$(mktemp -d /tmp/pf-e2e-remote-fallback-XXXXXX)"
FALLBACK_PID=""
STARTED_FALLBACK=0
PYTHON_BIN="$ROOT_DIR/.venv/bin/python"

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="python3"
fi

cleanup() {
  if [ "$STARTED_FALLBACK" -eq 1 ] && [ -n "$FALLBACK_PID" ] && kill -0 "$FALLBACK_PID" 2>/dev/null; then
    kill "$FALLBACK_PID" 2>/dev/null || true
    wait "$FALLBACK_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

info() {
  printf '[INFO] %s\n' "$*"
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

ready() {
  local base_url="$1"
  local response
  response="$(curl -fsS -m 2 "$base_url/health" 2>/dev/null)" || return 1
  printf '%s' "$response" | python3 -c 'import json, sys; data = json.load(sys.stdin); raise SystemExit(0 if data.get("ready") is True else 1)'
}

wait_ready() {
  local base_url="$1"
  for _ in $(seq 1 80); do
    if ready "$base_url"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

start_fallback() {
  if ready "$FALLBACK_URL"; then
    info "Using existing fallback at $FALLBACK_URL"
    return 0
  fi

  local config_file="$TMP_ROOT/fallback-config.toml"
  cat > "$config_file" <<EOF
[fallback]
host = "$FALLBACK_HOST"
port = $FALLBACK_PORT
base_url = "$FALLBACK_URL"
EOF

  info "Starting fallback at $FALLBACK_URL"
  PRIVACY_FILTER_CONFIG="$config_file" PYTHONPATH="$ROOT_DIR/src" "$PYTHON_BIN" -m privacy_filter_service.fallback_app > "$TMP_ROOT/fallback.log" 2>&1 &
  FALLBACK_PID=$!
  STARTED_FALLBACK=1

  if ! wait_ready "$FALLBACK_URL"; then
    sed -n '1,120p' "$TMP_ROOT/fallback.log" >&2 || true
    die "fallback did not become ready at $FALLBACK_URL"
  fi
}

make_repo() {
  local name="$1"
  local repo="$TMP_ROOT/$name"
  git init -q "$repo"
  git -C "$repo" config user.name 'E2E User'
  git -C "$repo" config user.email 'e2e@example.com'
  cp "$HOOKS_DIR/pre-commit" "$repo/.git/hooks/pre-commit"
  cp "$HOOKS_DIR/commit-msg" "$repo/.git/hooks/commit-msg"
  cp "$HOOKS_DIR/_lib.sh" "$repo/.git/hooks/_lib.sh"
  chmod +x "$repo/.git/hooks/pre-commit" "$repo/.git/hooks/commit-msg" "$repo/.git/hooks/_lib.sh"
  printf '%s\n' "$repo"
}

latest_patch() {
  local repo="$1"
  find "$repo/.git/privacy-filter" -name 'redact-*.patch' -type f 2>/dev/null | sort | tail -1
}

apply_patch_and_commit() {
  local repo="$1"
  local patch_file="$2"
  local output
  shift 2
  git -C "$repo" apply --index "$patch_file"
  if ! output="$(env "$@" git -C "$repo" commit -m 'apply privacy redaction' 2>&1 >/dev/null)"; then
    printf '%s\n' "$output" >&2
    die "redacted commit should have succeeded"
  fi
}

test_primary_default_blocks_then_allows_clean_commit() {
  local repo patch_file output
  repo="$(make_repo primary-default)"

  cat > "$repo/contact.txt" <<'TXT'
Contact alice@example.com or 415-555-1212 for support.
TXT
  git -C "$repo" add contact.txt

  if output="$(env -u PRIVACY_FILTER_URL PRIVACY_FILTER_FALLBACK_URL="$FALLBACK_URL" git -C "$repo" commit -m 'add pii' 2>&1)"; then
    die "primary OPF commit should have been blocked"
  fi

  patch_file="$(latest_patch "$repo")"
  [ -n "$patch_file" ] && [ -f "$patch_file" ] || die "primary OPF did not create a redaction patch"
  grep '^+' "$patch_file" | grep -q '<PRIVATE_EMAIL>' || die "primary OPF patch did not redact email"
  grep '^+' "$patch_file" | grep -q '<PRIVATE_PHONE>' || die "primary OPF patch did not redact phone"
  apply_patch_and_commit "$repo" "$patch_file" -u PRIVACY_FILTER_URL PRIVACY_FILTER_FALLBACK_URL="$FALLBACK_URL"
  info "Primary default path blocked PII and allowed the redacted commit"
}

test_fallback_blocks_then_allows_clean_commit() {
  local repo patch_file output
  repo="$(make_repo fallback-pre-commit)"

  cat > "$repo/secret.txt" <<'TXT'
Portal privacy.example.com uses token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature
Email alice@example.com or call 415-555-1212.
TXT
  git -C "$repo" add secret.txt

  if output="$(PRIVACY_FILTER_URL="http://127.0.0.1:1" PRIVACY_FILTER_FALLBACK_URL="$FALLBACK_URL" git -C "$repo" commit -m 'fallback pii' 2>&1)"; then
    die "fallback commit should have been blocked"
  fi

  printf '%s' "$output" | grep -q 'local fallback used' || die "hook did not report local fallback usage"
  patch_file="$(latest_patch "$repo")"
  [ -n "$patch_file" ] && [ -f "$patch_file" ] || die "fallback did not create a redaction patch"
  grep '^+' "$patch_file" | grep -q '<PRIVATE_EMAIL>' || die "fallback patch did not redact email"
  grep '^+' "$patch_file" | grep -q '<PRIVATE_PHONE>' || die "fallback patch did not redact phone"
  grep '^+' "$patch_file" | grep -q '<PRIVATE_URL>' || die "fallback patch did not redact bare domain"
  grep '^+' "$patch_file" | grep -q '<SECRET>' || die "fallback patch did not redact JWT"
  apply_patch_and_commit "$repo" "$patch_file" PRIVACY_FILTER_URL="http://127.0.0.1:1" PRIVACY_FILTER_FALLBACK_URL="$FALLBACK_URL"
  info "Fallback pre-commit path blocked PII and allowed the redacted commit"
}

test_fallback_commit_msg_redacts() {
  local repo msg output
  repo="$(make_repo fallback-commit-msg)"

  printf 'clean\n' > "$repo/clean.txt"
  git -C "$repo" add clean.txt
  output="$(PRIVACY_FILTER_URL="http://127.0.0.1:1" PRIVACY_FILTER_FALLBACK_URL="$FALLBACK_URL" git -C "$repo" commit -m 'Fix alice@example.com token' 2>&1 >/dev/null)"
  printf '%s' "$output" | grep -q 'local fallback used' || die "commit-msg hook did not report local fallback usage"
  msg="$(git -C "$repo" log -1 --pretty=%B)"
  case "$msg" in
    *'<PRIVATE_EMAIL>'*) ;;
    *) die "commit message was not redacted by fallback: $msg" ;;
  esac
  info "Fallback commit-msg path redacted the commit message"
}

ready "$PRIMARY_URL" || die "primary OPF is not ready at $PRIMARY_URL"
start_fallback
test_primary_default_blocks_then_allows_clean_commit
test_fallback_blocks_then_allows_clean_commit
test_fallback_commit_msg_redacts

printf '[PASS] remote OPF primary plus local fallback e2e\n'
