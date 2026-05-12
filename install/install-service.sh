#!/usr/bin/env bash
# install-service.sh — install and start the privacy-filter systemd user service.
# All operations are user-scoped (no sudo required).
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve project root (this script lives in <root>/install/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
info()  { printf '[\033[1;34mINFO\033[0m]  %s\n' "$*"; }
warn()  { printf '[\033[1;33mWARN\033[0m]  %s\n' "$*" >&2; }
error() { printf '[\033[1;31mERROR\033[0m] %s\n' "$*" >&2; }
ok()    { printf '[\033[1;32m OK \033[0m]  %s\n' "$*"; }

die() { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Validate prerequisites
# ---------------------------------------------------------------------------
check_prereqs() {
  command -v uv >/dev/null 2>&1   || die "uv is not installed. Install from https://docs.astral.sh/uv/"
  systemctl --version >/dev/null 2>&1 || die "systemctl --user is not available (no user session?)"

  local model_path="/mnt/LLM/OpenAI/privacy_filter"
  if [ ! -d "$model_path" ]; then
    die "Model directory not found: $model_path"
  fi

  local venv_bin="$PROJECT_ROOT/.venv/bin/privacy-filter-service"
  if [ ! -x "$venv_bin" ]; then
    die "Virtual env missing or incomplete. Run 'uv sync' in $PROJECT_ROOT"
  fi
}

# ---------------------------------------------------------------------------
# 2. Create target directories
# ---------------------------------------------------------------------------
CONFIG_DIR="$HOME/.config/privacy-filter"
SYSTEMD_DIR="$HOME/.config/systemd/user"

create_dirs() {
  mkdir -p "$CONFIG_DIR" "$SYSTEMD_DIR"
}

# ---------------------------------------------------------------------------
# 3. Deploy config.toml (only if absent; otherwise prompt)
# ---------------------------------------------------------------------------
deploy_config() {
  local src="$PROJECT_ROOT/config.toml.example"
  local dst="$CONFIG_DIR/config.toml"

  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    chmod 600 "$dst"
    ok "config.toml installed → $dst"
    info "Edit $dst to set model_path and other options."
  else
    printf '[\033[1;33m???\033[0m]  config.toml already exists at %s\n' "$dst" >&2
    printf '       Overwrite? [y/N] ' >&2
    local ans
    read -r ans
    if echo "$ans" | grep -qi '^y'; then
      cp "$src" "$dst"
      chmod 600 "$dst"
      ok "config.toml overwritten → $dst"
    else
      info "Keeping existing config.toml"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 4. Deploy env file (only if absent; otherwise prompt)
# ---------------------------------------------------------------------------
deploy_env() {
  local src="$PROJECT_ROOT/config/env.example"
  local dst="$CONFIG_DIR/env"

  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    chmod 600 "$dst"
    ok "env installed → $dst"
  else
    printf '[\033[1;33m???\033[0m]  env already exists at %s\n' "$dst" >&2
    printf '       Overwrite? [y/N] ' >&2
    local ans
    read -r ans
    if echo "$ans" | grep -qi '^y'; then
      cp "$src" "$dst"
      chmod 600 "$dst"
      ok "env overwritten → $dst"
    else
      info "Keeping existing env"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 5. Install systemd unit (substitute %h → $HOME)
# ---------------------------------------------------------------------------
install_unit() {
  local src="$PROJECT_ROOT/systemd/privacy-filter.service"
  local dst="$SYSTEMD_DIR/privacy-filter.service"

  if [ ! -f "$src" ]; then
    die "Unit file not found: $src"
  fi

  sed "s|%h|$HOME|g" "$src" > "$dst"
  chmod 644 "$dst"
  ok "Unit file installed → $dst"
}

# ---------------------------------------------------------------------------
# 6. Reload daemon, enable and start service
# ---------------------------------------------------------------------------
enable_service() {
  info "Reloading systemd user daemon…"
  systemctl --user daemon-reload

  info "Enabling and starting privacy-filter.service…"
  systemctl --user enable --now privacy-filter.service
  ok "Service enabled"
}

# ---------------------------------------------------------------------------
# 7. Health check — wait up to 30s for /health → ready=true
# ---------------------------------------------------------------------------
health_check() {
  local base_url="http://127.0.0.1:8765"
  local elapsed=0
  local interval=2

  info "Waiting for service to become healthy (timeout 30s)…"
  while [ "$elapsed" -lt 30 ]; do
    local response
    response="$(curl -fsS -m "$interval" "$base_url/health" 2>/dev/null)" || true

    if printf '%s' "$response" | python3 -c '
import json, sys
data = json.load(sys.stdin)
sys.exit(0 if data.get("ready") else 1)
' 2>/dev/null; then
      ok "Service is healthy (ready=true)"
      return 0
    fi

    elapsed=$((elapsed + interval))
    printf '       …%ds elapsed\n' "$elapsed" >&2
  done

  warn "Service did not report ready=true within 30s"
  warn "Check logs: journalctl --user -u privacy-filter.service -n 50"
  return 1
}

# ---------------------------------------------------------------------------
# 8. Offer loginctl enable-linger
# ---------------------------------------------------------------------------
offer_linger() {
  printf '[\033[1;33m???\033[0m]  Enable linger so the service runs at boot? [y/N] ' >&2
  local ans
  read -r ans
  if echo "$ans" | grep -qi '^y'; then
    loginctl enable-linger "$USER"
    ok "Linger enabled for $USER — service will start at boot"
  else
    info "Linger not enabled. Service runs only while you are logged in."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "Installing privacy-filter service…"
  info "Project root: $PROJECT_ROOT"

  check_prereqs
  create_dirs
  deploy_config
  deploy_env
  install_unit
  enable_service
  health_check || true
  offer_linger

  info "Installation complete."
  info "  • Logs:    journalctl --user -u privacy-filter.service -f"
  info "  • Config:  $CONFIG_DIR/config.toml"
  info "  • Env:     $CONFIG_DIR/env"
  info "  • Uninstall: install/uninstall.sh"
}

main "$@"
