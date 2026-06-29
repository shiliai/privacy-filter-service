#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$ROOT_DIR/hooks"
MOCK_SERVICE="$SCRIPT_DIR/mock_service.py"

PF_IT_ROOT="${PF_IT_ROOT:-}"
PF_IT_OWNS_ROOT=0
PF_IT_SERVER_PID=""
PF_IT_SERVICE_LOG=""
PF_IT_PORT=""

pfit_cleanup() {
  if [ -n "$PF_IT_SERVER_PID" ] && kill -0 "$PF_IT_SERVER_PID" 2>/dev/null; then
    kill "$PF_IT_SERVER_PID" 2>/dev/null || true
    wait "$PF_IT_SERVER_PID" 2>/dev/null || true
  fi
  if [ "$PF_IT_OWNS_ROOT" -eq 1 ] && [ -n "$PF_IT_ROOT" ] && [ -d "$PF_IT_ROOT" ]; then
    rm -rf "$PF_IT_ROOT"
  fi
}

pfit_init() {
  local name
  name="$1"
  if [ -z "$PF_IT_ROOT" ]; then
    PF_IT_ROOT="$(mktemp -d "/tmp/pf-it-${name}-XXXXXX")"
    PF_IT_OWNS_ROOT=1
  else
    mkdir -p "$PF_IT_ROOT"
  fi

  export HOME="$PF_IT_ROOT/home"
  export GIT_CONFIG_GLOBAL="$PF_IT_ROOT/fake.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"

  trap pfit_cleanup EXIT
}

pfit_pick_port() {
  python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

pfit_start_service() {
  local mode
  mode="$1"
  PF_IT_PORT="$(pfit_pick_port)"
  PF_IT_SERVICE_LOG="$PF_IT_ROOT/service.log"
  python3 "$MOCK_SERVICE" --port "$PF_IT_PORT" --mode "$mode" --log-file "$PF_IT_SERVICE_LOG" &
  PF_IT_SERVER_PID=$!
  export PRIVACY_FILTER_URL="http://127.0.0.1:$PF_IT_PORT"

  for _ in $(seq 1 50); do
    if curl -fsS -m 1 "$PRIVACY_FILTER_URL/health" >/dev/null 2>&1; then
      : > "$PF_IT_SERVICE_LOG"
      return 0
    fi
    sleep 0.1
  done

  echo "service failed to start" >&2
  return 1
}

pfit_make_repo() {
  local name repo
  name="$1"
  repo="$PF_IT_ROOT/$name"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.name 'Test User'
  git -C "$repo" config user.email 'test@example.com'
  cp "$HOOKS_DIR/pre-commit" "$repo/.git/hooks/pre-commit"
  cp "$HOOKS_DIR/commit-msg" "$repo/.git/hooks/commit-msg"
  cp "$HOOKS_DIR/_lib.sh" "$repo/.git/hooks/_lib.sh"
  cp "$HOOKS_DIR/pf_fallback.py" "$repo/.git/hooks/pf_fallback.py"
  chmod +x "$repo/.git/hooks/pre-commit" "$repo/.git/hooks/commit-msg" "$repo/.git/hooks/_lib.sh" "$repo/.git/hooks/pf_fallback.py"
  printf '%s\n' "$repo"
}

pfit_assert_no_patch() {
  local repo
  repo="$1"
  if compgen -G "$repo/.git/privacy-filter/redact-*.patch" >/dev/null; then
    echo "unexpected patch found in $repo" >&2
    return 1
  fi
}

pfit_patch_path() {
  local repo patch
  repo="$1"
  patch="$(compgen -G "$repo/.git/privacy-filter/redact-*.patch" || true)"
  if [ -z "$patch" ]; then
    echo "missing patch in $repo" >&2
    return 1
  fi
  printf '%s\n' "$patch"
}

pfit_log_contains() {
  local needle
  needle="$1"
  grep -q -- "$needle" "$PF_IT_SERVICE_LOG"
}
