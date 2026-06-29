#!/usr/bin/env bash

pf_url() {
  # Empty when no primary is configured. Env var wins; otherwise fall back to
  # GLOBAL git config (privacyfilter.url) so the value reaches git even when
  # it is launched from a NON-interactive shell (plain SSH / cron / CI) — those
  # do NOT source ~/.bashrc, so an `export PRIVACY_FILTER_URL=...` there is
  # invisible and the hook would silently drop to the local fallback. git
  # config is read on every git invocation, regardless of shell type.
  #
  # GLOBAL only (never repo-local .git/config): the URL is where PII is sent,
  # so a repo must not be able to override it (else an embedded script could
  # `git config privacyfilter.url http://evil/` and exfiltrate PII). Per-repo
  # overrides remain possible via the PRIVACY_FILTER_URL env var.
  if [ -n "${PRIVACY_FILTER_URL:-}" ]; then
    printf '%s' "${PRIVACY_FILTER_URL}"
    return
  fi
  git config --global --get privacyfilter.url 2>/dev/null || true
}

pf_skip_active() {
  [ "${PRIVACY_FILTER_SKIP:-0}" = "1" ]
}

pf_primary_configured() {
  [ -n "$(pf_url)" ]
}

# Local non-model fallback lives next to this library (hooks/pf_fallback.py).
pf_fallback_path() {
  printf '%s/pf_fallback.py' "$(dirname "${BASH_SOURCE[0]:-$0}")"
}

pf_fallback_enabled() {
  [ "${PRIVACY_FILTER_NO_FALLBACK:-0}" != "1" ] && [ -f "$(pf_fallback_path)" ]
}

# Fail-open (allow unredacted commit) only when explicitly opted in; the
# default is fail-closed so PII never slips through silently.
pf_fail_open_enabled() {
  [ "${PRIVACY_FILTER_FAIL_OPEN:-0}" = "1" ]
}

_pf_service_ready() {
  local response
  pf_primary_configured || return 1
  if ! response="$(curl -fsS -m 2 "$(pf_url)/health" 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "$response" | python3 -c 'import json, sys; data = json.load(sys.stdin); raise SystemExit(0 if data.get("ready") is True else 1)'
}

# Choose the redaction engine to use for this commit. Call once, then pass the
# result to pf_redact for every file. Prints: primary | fallback | none.
pf_select_engine() {
  if pf_primary_configured && _pf_service_ready; then
    printf 'primary\n'
  elif pf_fallback_enabled; then
    printf 'fallback\n'
  else
    printf 'none\n'
  fi
}

# POST a {"text": ...} JSON payload to the primary /redact endpoint; print the
# response body on stdout (exit 0) only on HTTP 200, else exit non-zero.
_pf_post_redact() {
  local payload url timeout response http_code
  payload="$1"
  pf_primary_configured || return 1
  url="$(pf_url)/redact"
  timeout="${PRIVACY_FILTER_TIMEOUT_S:-}"
  [ -n "$timeout" ] || timeout="$(git config --global --get privacyfilter.timeout 2>/dev/null || true)"
  [ -n "$timeout" ] || timeout=5
  response="$(printf '%s' "$payload" | curl -fsS --max-time "$timeout" -X POST \
    -H 'Content-Type: application/json' --data-binary @- \
    --write-out $'\n%{http_code}' "$url" 2>/dev/null)" || return 1
  http_code="${response##*$'\n'}"
  [ "$http_code" = "200" ] || return 1
  printf '%s' "${response%$'\n'*}"
}

# Run the local non-model fallback on a JSON payload; print result JSON.
_pf_fallback_redact() {
  local payload="$1"
  printf '%s' "$payload" | python3 "$(pf_fallback_path)" 2>/dev/null
}

# Validate that a candidate redaction-result JSON has the shape the hooks parse
# (redacted_text + summary.span_count). Guards against a primary that returns
# HTTP 200 with a non-JSON body (e.g. an in-path reverse proxy serving an HTML
# error page): such a response must be treated as a primary failure so the local
# fallback is consulted rather than silently fail-opening.
_pf_result_valid() {
  python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if not isinstance(d, dict):
    raise SystemExit(1)
if not isinstance(d.get("redacted_text"), str):
    raise SystemExit(1)
s = d.get("summary")
if not isinstance(s, dict) or not isinstance(s.get("span_count"), int):
    raise SystemExit(1)
' 2>/dev/null
}

# pf_redact <engine>: read raw text from stdin, print a redaction result JSON
# on stdout (same shape as POST /redact), return 0 on success / 1 if no engine
# could produce a result. When the selected primary fails mid-request (e.g. the
# service drops the connection) OR returns a malformed/unusable 200 response,
# it transparently falls back to the local non-model detector.
pf_redact() {
  local engine payload body
  engine="$1"
  payload="$(python3 -c 'import json, sys; print(json.dumps({"text": sys.stdin.read()}))')" || return 1
  if [ "$engine" = "primary" ]; then
    if body="$(_pf_post_redact "$payload")" && printf '%s' "$body" | _pf_result_valid; then
      printf '%s' "$body"
      return 0
    fi
    # Primary failed or returned a malformed/unusable response (e.g. a proxy
    # serving an HTML error page with HTTP 200): fall back to the local
    # non-model detector if it is available.
    if pf_fallback_enabled && _pf_fallback_redact "$payload"; then
      return 0
    fi
    return 1
  elif [ "$engine" = "fallback" ]; then
    if pf_fallback_enabled && _pf_fallback_redact "$payload"; then
      return 0
    fi
    return 1
  fi
  return 1
}

pf_git_dir() {
  git rev-parse --git-dir 2>/dev/null
}

pf_privacy_dir() {
  printf '%s/privacy-filter' "$(pf_git_dir)"
}

pf_ensure_dir() {
  local dir
  dir="$(pf_privacy_dir)"
  mkdir -p "$dir"
  chmod 700 "$dir"
}

pf_warn_once() {
  local key msg now state_file last=0
  key="$1"
  msg="$2"
  pf_ensure_dir
  now="$(date +%s)"
  state_file="$(pf_privacy_dir)/last-warn-${key}"
  if [ -f "$state_file" ]; then
    IFS= read -r last < "$state_file" || last=0
  fi
  if [ $((now - last)) -ge 300 ]; then
    printf '[privacy-filter] %s\n' "$msg" >&2
  else
    printf '[privacy-filter] %s\n' "$key" >&2
  fi
  printf '%s\n' "$now" > "$state_file"
  chmod 600 "$state_file"
}

pf_fail_open() {
  pf_warn_once unavailable "$1"
  exit 0
}

# Default fail-closed exit for every recoverable-but-unverified state (read
# failure, malformed response, unappliable patch): block the commit unless
# PRIVACY_FILTER_FAIL_OPEN=1 explicitly opts back into fail-open. Keeps every
# exit-0 path consistent with the pf_select_engine / pf_redact contract so PII
# never slips through silently by default.
pf_exit_fail_open_or_block() {
  local reason="$1"
  if pf_fail_open_enabled; then
    pf_warn_once unavailable "$reason, fail-open"
    exit 0
  fi
  printf '[privacy-filter] %s. Set PRIVACY_FILTER_FAIL_OPEN=1 to allow unredacted commits, or PRIVACY_FILTER_SKIP=1 to bypass.\n' "$reason" >&2
  exit 1
}

pf_is_lfs_pointer() {
  local path first_line
  path="$1"

  [ -f "$path" ] || return 1

  # Git LFS pointer files are small text stubs that start with:
  #   version https://git-lfs.github.com/spec/v1
  first_line="$(head -n 1 -- "$path" 2>/dev/null || true)"
  [ "$first_line" = "version https://git-lfs.github.com/spec/v1" ]
}

pf_too_large() {
  local bytes max_bytes
  bytes="$1"
  max_bytes="${PRIVACY_FILTER_MAX_FILE_BYTES:-262144}"
  [ "$bytes" -gt "$max_bytes" ]
}

pf_is_text_file() {
  local path numstat_line added removed attr_value encoding mode
  path="$1"

  [ -f "$path" ] || return 1
  [ ! -L "$path" ] || return 1

  mode="$(git ls-files --stage -- "$path" | python3 -c 'import sys; line = sys.stdin.readline().strip(); print(line.split()[0] if line else "")')"
  [ "$mode" != "160000" ] || return 1

  numstat_line="$(git diff --cached --numstat -- "$path")"
  if [ -n "$numstat_line" ]; then
    added="${numstat_line%%$'\t'*}"
    removed="${numstat_line#*$'\t'}"
    removed="${removed%%$'\t'*}"
    if [ "$added" = "-" ] && [ "$removed" = "-" ]; then
      return 1
    fi
  fi

  attr_value="$(git check-attr binary -- "$path" | python3 -c 'import sys; line = sys.stdin.readline().strip(); print(line.rsplit(": ", 1)[-1] if line else "")')"
  if [ "$attr_value" = "set" ] || [ "$attr_value" = "true" ]; then
    return 1
  fi

  encoding="$(file --brief --mime-encoding -- "$path" | tr '[:upper:]' '[:lower:]')"
  case "$encoding" in
    utf-8|us-ascii) return 0 ;;
    *) return 1 ;;
  esac
}

pf_cleanup_old_patches() {
  local dir
  dir="$(pf_privacy_dir)"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name 'redact-*.patch' -mtime +1 -delete 2>/dev/null || true
}
