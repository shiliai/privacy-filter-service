#!/usr/bin/env bash
# Remove only the OPF-owned dispatcher root and restore the prior global path.
set -euo pipefail

CONFIG_DIR="$HOME/.config/privacy-filter"
SYSTEMD_DIR="$HOME/.config/systemd/user"
HOOKS_INPUT="${PRIVACY_FILTER_HOOKS_DIR:-$HOME/.config/privacy-filter/git-hooks}"
case "$HOOKS_INPUT" in /*) ;; *) printf '[ERROR] managed hooks path must be absolute: %s\n' "$HOOKS_INPUT" >&2; exit 1 ;; esac
HOOKS_DIR="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HOOKS_INPUT")"
STATE_FILE="$HOOKS_DIR/.privacy-filter-hooks-state"
HOOKS_ONLY=false
SERVICE_NAME="privacy-filter.service"
UNIT_FILE="$SYSTEMD_DIR/$SERVICE_NAME"
info() { printf '[INFO]  %s\n' "$*"; }; warn() { printf '[WARN]  %s\n' "$*" >&2; }; ok() { printf '[ OK ]  %s\n' "$*"; }
state_value() { sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1; }
normalize_hooks_path() {
  local value="$1"
  case "$value" in
    '') printf '' ;;
    '~/'*) value="$HOME/${value#\~/}"; python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$value" ;;
    /*) python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$value" ;;
    *) return 1 ;;
  esac
}
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --hooks-only) HOOKS_ONLY=true ;;
      -h|--help) printf 'Usage: %s [--hooks-only]\n' "$0"; exit 0 ;;
      *) printf '[ERROR] unknown argument: %s\n' "$arg" >&2; exit 1 ;;
    esac
  done
}

uninstall_service() {
  systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null && systemctl --user stop "$SERVICE_NAME" || true
  systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && systemctl --user disable "$SERVICE_NAME" || true
  if [ -f "$UNIT_FILE" ]; then rm -f "$UNIT_FILE"; systemctl --user daemon-reload || true; fi
}
uninstall_hooks() {
  local current prior file legacy
  [ -f "$STATE_FILE" ] || { warn 'No privacy-filter ownership state; leaving hooks and git configuration unchanged'; return; }
  prior="$(state_value delegate_hooks_path)"
  current="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  if [ "$(normalize_hooks_path "$current" 2>/dev/null || true)" = "$HOOKS_DIR" ]; then
    if [ -n "$prior" ]; then git config --global core.hooksPath "$prior"; else git config --global --unset core.hooksPath || true; fi
    ok 'core.hooksPath restored'
  else
    warn "global core.hooksPath changed to '$current'; leaving it unchanged"
  fi
  chmod 700 "$HOOKS_DIR"
  if [ -n "$prior" ] && [ -d "$prior" ]; then
    for legacy in pre-commit pre-commit.old commit-msg; do
      if [ -f "$HOOKS_DIR/legacy-backup/$legacy" ]; then
        if [ -e "$prior/$legacy" ]; then
          warn "not restoring legacy $legacy: destination exists; recover from $HOOKS_DIR/legacy-backup/$legacy"
        else
          mv "$HOOKS_DIR/legacy-backup/$legacy" "$prior/$legacy"
        fi
      fi
    done
  fi
  for file in pre-commit commit-msg _lib.sh pf_fallback.py pre-commit.opf commit-msg.opf .privacy-filter-hooks-state; do rm -f "$HOOKS_DIR/$file"; done
  rmdir "$HOOKS_DIR/legacy-backup" 2>/dev/null || true
  rmdir "$HOOKS_DIR" 2>/dev/null || warn "managed hooks directory not empty: $HOOKS_DIR"
}
main() {
  parse_args "$@"
  if [ "$HOOKS_ONLY" = false ]; then uninstall_service; else info 'Rolling back privacy-filter hooks only; service left unchanged'; fi
  uninstall_hooks
  [ -f "$CONFIG_DIR/config.toml" ] && info "Preserved: $CONFIG_DIR/config.toml"
  [ -f "$CONFIG_DIR/env" ] && info "Preserved: $CONFIG_DIR/env"
  ok 'Uninstall complete.'
}
main "$@"
