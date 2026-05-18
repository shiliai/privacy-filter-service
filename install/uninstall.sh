#!/usr/bin/env bash
# uninstall.sh — remove privacy-filter service and hooks.
# Preserves user config (config.toml, env).
set -euo pipefail

CONFIG_DIR="$HOME/.config/privacy-filter"
SYSTEMD_DIR="$HOME/.config/systemd/user"
HOOKS_DIR="$HOME/.config/git/hooks"
SERVICE_NAME="privacy-filter.service"
UNIT_FILE="$SYSTEMD_DIR/$SERVICE_NAME"

info()  { printf '[\033[1;34mINFO\033[0m]  %s\n' "$*"; }
warn()  { printf '[\033[1;33mWARN\033[0m]  %s\n' "$*" >&2; }
ok()    { printf '[\033[1;32m OK \033[0m]  %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Stop and disable systemd service
# ---------------------------------------------------------------------------
uninstall_service() {
  if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info "Stopping $SERVICE_NAME…"
    systemctl --user stop "$SERVICE_NAME"
    ok "Service stopped"
  else
    info "Service not running"
  fi

  if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl --user disable "$SERVICE_NAME"
    ok "Service disabled"
  fi

  if [ -f "$UNIT_FILE" ]; then
    rm -f "$UNIT_FILE"
    ok "Unit file removed"
    systemctl --user daemon-reload
  fi
}

# ---------------------------------------------------------------------------
# 2. Unset core.hooksPath if it points to our hooks directory
# ---------------------------------------------------------------------------
uninstall_hooks() {
  local current
  current="$(git config --global core.hooksPath 2>/dev/null)" || true

  if [ "$current" = "$HOOKS_DIR" ]; then
    git config --global --unset core.hooksPath
    ok "core.hooksPath unset"
  elif [ -n "$current" ]; then
    warn "core.hooksPath is set to: $current (not our directory — leaving as-is)"
  else
    info "core.hooksPath not set"
  fi

  if [ -d "$HOOKS_DIR" ]; then
    local hook_files=("pre-commit" "commit-msg" "_lib.sh")
    for hf in "${hook_files[@]}"; do
      if [ -f "$HOOKS_DIR/$hf" ]; then
        rm -f "$HOOKS_DIR/$hf"
      fi
    done
    rmdir "$HOOKS_DIR" 2>/dev/null && ok "Hooks directory removed" || warn "Hooks directory not empty — left in place"
  fi
}

# ---------------------------------------------------------------------------
# 3. Preserve user config, report what was kept
# ---------------------------------------------------------------------------
report_preserved() {
  if [ -f "$CONFIG_DIR/config.toml" ]; then
    info "Preserved: $CONFIG_DIR/config.toml"
  fi
  if [ -f "$CONFIG_DIR/env" ]; then
    info "Preserved: $CONFIG_DIR/env"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "Uninstalling privacy-filter…"

  uninstall_service
  uninstall_hooks
  report_preserved

  ok "Uninstall complete. User config preserved in $CONFIG_DIR/"
}

main "$@"
