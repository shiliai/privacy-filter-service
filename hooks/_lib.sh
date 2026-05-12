#!/usr/bin/env bash

pf_url() {
  printf '%s' "${PRIVACY_FILTER_URL:-http://127.0.0.1:8765}"
}

pf_skip_active() {
  [ "${PRIVACY_FILTER_SKIP:-0}" = "1" ]
}

_pf_service_ready() {
  local response
  if ! response="$(curl -fsS -m 2 "$(pf_url)/health" 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "$response" | python3 -c 'import json, sys; data = json.load(sys.stdin); raise SystemExit(0 if data.get("ready") is True else 1)'
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

pf_post_json() {
  local endpoint url timeout response curl_status body http_code
  endpoint="$1"
  url="$(pf_url)${endpoint}"
  timeout="${PRIVACY_FILTER_TIMEOUT_S:-5}"

  response="$(curl -sS --max-time "$timeout" -X POST -H 'Content-Type: application/json' --data-binary @- --write-out $'\nHTTP:%{http_code}' "$url")"
  curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    printf 'HTTP:0\n' >&2
    return "$curl_status"
  fi

  http_code="${response##*$'\n'}"
  body="${response%$'\n'HTTP:*}"
  printf '%s\n' "$http_code" >&2
  printf '%s' "$body"
}

pf_cleanup_old_patches() {
  local dir
  dir="$(pf_privacy_dir)"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name 'redact-*.patch' -mtime +1 -delete 2>/dev/null || true
}
