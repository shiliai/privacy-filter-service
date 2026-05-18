#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_DIR="$ROOT_DIR/hooks"

SERVER_PID=""
REQUEST_LOG=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT

start_mock_server() {
  local port log_file server_script
  port="$1"
  log_file="$2"
  server_script="$3"
  python3 "$server_script" "$port" "$log_file" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    if python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
sock = socket.socket()
sock.settimeout(0.1)
try:
    sock.connect(("127.0.0.1", port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
raise SystemExit(0)
PY
    then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

init_repo() {
  local repo_dir
  repo_dir="$1"
  rm -rf "$repo_dir"
  mkdir -p "$repo_dir"
  git init -q "$repo_dir"
  git -C "$repo_dir" config user.name 'Test User'
  git -C "$repo_dir" config user.email 'test@example.com'
  cp "$HOOK_DIR/pre-commit" "$repo_dir/.git/hooks/pre-commit"
  cp "$HOOK_DIR/_lib.sh" "$repo_dir/.git/hooks/_lib.sh"
  chmod +x "$repo_dir/.git/hooks/pre-commit" "$repo_dir/.git/hooks/_lib.sh"
}

write_mock_server() {
  local server_script
  server_script="$1"
  cat > "$server_script" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG_FILE = sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _write_log(self, entry):
        with open(LOG_FILE, 'a', encoding='utf-8') as fh:
            fh.write(entry + '\n')

    def do_GET(self):
        self._write_log(f'GET {self.path}')
        if self.path == '/health':
            body = json.dumps({'ready': True, 'device': 'cpu', 'uptime_s': 1.0, 'version': 'test'}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        payload = json.loads(self.rfile.read(length).decode('utf-8'))
        text = payload.get('text', '')
        self._write_log(f'POST {self.path}')
        if self.path == '/redact':
          redacted = text.replace('alice@example.com', '<PRIVATE_EMAIL>')
          span_count = 1 if redacted != text else 0
          by_label = {'private_email': span_count} if span_count else {}
          body = json.dumps({
              'text': text,
              'redacted_text': redacted,
              'summary': {'span_count': span_count, 'by_label': by_label},
          }).encode('utf-8')
          self.send_response(200)
          self.send_header('Content-Type', 'application/json')
          self.send_header('Content-Length', str(len(body)))
          self.end_headers()
          self.wfile.write(body)
          return
        self.send_response(404)
        self.end_headers()

ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
PY
}

assert_no_patch() {
  local repo_dir
  repo_dir="$1"
  if compgen -G "$repo_dir/.git/privacy-filter/redact-*.patch" > /dev/null; then
    echo 'unexpected patch found'
    return 1
  fi
}

run_clean_commit() {
  local repo_dir port log_file server_script
  repo_dir="/tmp/pf-pre-clean-$$"
  port=18765
  log_file="/tmp/pf-pre-clean-$$.log"
  server_script="/tmp/pf-pre-clean-$$.py"
  : > "$log_file"
  write_mock_server "$server_script"
  start_mock_server "$port" "$log_file" "$server_script"
  init_repo "$repo_dir"
  printf 'print(2 + 2)\n' > "$repo_dir/calc.py"
  git -C "$repo_dir" add calc.py
  PRIVACY_FILTER_URL="http://127.0.0.1:$port" git -C "$repo_dir" commit -m 'clean'
  assert_no_patch "$repo_dir"
  echo 'clean_commit: ok'
}

run_pii_commit() {
  local repo_dir port log_file server_script patch_file
  repo_dir="/tmp/pf-pre-pii-$$"
  port=18766
  log_file="/tmp/pf-pre-pii-$$.log"
  server_script="/tmp/pf-pre-pii-$$.py"
  : > "$log_file"
  cleanup
  SERVER_PID=""
  write_mock_server "$server_script"
  start_mock_server "$port" "$log_file" "$server_script"
  init_repo "$repo_dir"
  printf "email = 'alice@example.com'\n" > "$repo_dir/leak.py"
  git -C "$repo_dir" add leak.py
  if PRIVACY_FILTER_URL="http://127.0.0.1:$port" git -C "$repo_dir" commit -m 'test'; then
    echo 'expected commit to fail'
    return 1
  fi
  patch_file="$(compgen -G "$repo_dir/.git/privacy-filter/redact-*.patch")"
  [ -n "$patch_file" ]
  git -C "$repo_dir" apply --check "$patch_file"
  git -C "$repo_dir" apply --index "$patch_file"
  git -C "$repo_dir" diff --cached -- leak.py | grep -q '<PRIVATE_EMAIL>'
  PRIVACY_FILTER_URL="http://127.0.0.1:$port" git -C "$repo_dir" commit -m 'redacted'
  echo 'pii_commit: ok'
}

run_partial_staging() {
  local repo_dir port log_file server_script stderr_file
  repo_dir="/tmp/pf-pre-partial-$$"
  port=18767
  log_file="/tmp/pf-pre-partial-$$.log"
  server_script="/tmp/pf-pre-partial-$$.py"
  stderr_file="/tmp/pf-pre-partial-$$.stderr"
  : > "$log_file"
  cleanup
  SERVER_PID=""
  write_mock_server "$server_script"
  start_mock_server "$port" "$log_file" "$server_script"
  init_repo "$repo_dir"
  printf 'v1\n' > "$repo_dir/a.txt"
  git -C "$repo_dir" add a.txt
  printf 'v2\n' > "$repo_dir/a.txt"
  if PRIVACY_FILTER_URL="http://127.0.0.1:$port" git -C "$repo_dir" commit -m 'partial' 2> "$stderr_file"; then
    echo 'expected partial staging commit to fail'
    return 1
  fi
  grep -q 'Partial staging not supported in v1' "$stderr_file"
  echo 'partial_staging: ok'
}

run_binary_skip() {
  local repo_dir port log_file server_script
  repo_dir="/tmp/pf-pre-binary-$$"
  port=18768
  log_file="/tmp/pf-pre-binary-$$.log"
  server_script="/tmp/pf-pre-binary-$$.py"
  : > "$log_file"
  cleanup
  SERVER_PID=""
  write_mock_server "$server_script"
  start_mock_server "$port" "$log_file" "$server_script"
  init_repo "$repo_dir"
  head -c 1024 /dev/urandom > "$repo_dir/bin.dat"
  git -C "$repo_dir" add bin.dat
  PRIVACY_FILTER_URL="http://127.0.0.1:$port" git -C "$repo_dir" commit -m 'binary'
  assert_no_patch "$repo_dir"
  echo 'binary_skip: ok'
}

run_service_down() {
  local repo_dir stderr_file
  repo_dir="/tmp/pf-pre-down-$$"
  stderr_file="/tmp/pf-pre-down-$$.stderr"
  cleanup
  SERVER_PID=""
  init_repo "$repo_dir"
  printf "email = 'alice@example.com'\n" > "$repo_dir/leak.py"
  git -C "$repo_dir" add leak.py
  PRIVACY_FILTER_URL='http://127.0.0.1:18769' git -C "$repo_dir" commit -m 'service-down' 2> "$stderr_file"
  grep -Eiq 'down|unavailable|fail-open' "$stderr_file"
  echo 'service_down: ok'
}

run_bypass() {
  local repo_dir port log_file server_script
  repo_dir="/tmp/pf-pre-bypass-$$"
  port=18770
  log_file="/tmp/pf-pre-bypass-$$.log"
  server_script="/tmp/pf-pre-bypass-$$.py"
  : > "$log_file"
  cleanup
  SERVER_PID=""
  write_mock_server "$server_script"
  start_mock_server "$port" "$log_file" "$server_script"
  init_repo "$repo_dir"
  printf "email = 'alice@example.com'\n" > "$repo_dir/leak.py"
  git -C "$repo_dir" add leak.py
  PRIVACY_FILTER_SKIP=1 PRIVACY_FILTER_URL="http://127.0.0.1:$port" git -C "$repo_dir" commit -m 'bypass'
  [ ! -s "$log_file" ]
  echo 'bypass: ok'
}

case "${1:-all}" in
  clean_commit) run_clean_commit ;;
  pii_commit) run_pii_commit ;;
  partial_staging) run_partial_staging ;;
  binary_skip) run_binary_skip ;;
  service_down) run_service_down ;;
  bypass) run_bypass ;;
  all)
    run_clean_commit
    run_pii_commit
    run_partial_staging
    run_binary_skip
    run_service_down
    run_bypass
    ;;
  *)
    echo "unknown scenario: $1" >&2
    exit 1
    ;;
esac
