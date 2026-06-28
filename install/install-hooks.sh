#!/usr/bin/env bash
# install-hooks.sh — install privacy-filter git hooks globally.
# Sets core.hooksPath to ~/.config/git/hooks/ after safety checks.
# All operations are user-scoped (no sudo required).
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve project root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_HOOKS_DIR="$HOME/.config/git/hooks"
FORCE=false

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
info()  { printf '[\033[1;34mINFO\033[1;0m]  %s\n' "$*"; }
warn()  { printf '[\033[1;33mWARN\033[0m]  %s\n' "$*" >&2; }
error() { printf '[\033[1;31mERROR\033[0m] %s\n' "$*" >&2; }
ok()    { printf '[\033[1;32m OK \033[0m]  %s\n' "$*"; }

die() { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Parse --force flag
# ---------------------------------------------------------------------------
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --force) FORCE=true ;;
      -h|--help)
        echo "Usage: $0 [--force]"
        echo "  --force  Override existing core.hooksPath (backs up old value)"
        exit 0
        ;;
      *)
        die "Unknown argument: $arg. Use --help for usage."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 1. Check current core.hooksPath
# ---------------------------------------------------------------------------
check_hooks_path() {
  local current
  current="$(git config --global core.hooksPath 2>/dev/null)" || true

  if [ -z "$current" ]; then
    info "core.hooksPath is not set — proceeding"
    return 0
  fi

  if [ "$current" = "$TARGET_HOOKS_DIR" ]; then
    info "core.hooksPath already points to $TARGET_HOOKS_DIR — updating hooks"
    return 0
  fi

  if [ "$FORCE" = true ]; then
    local backup="${current}.bak-$(date +%Y%m%d%H%M%S)"
    info "core.hooksPath is set to: $current"
    info "Backing up existing hooks path reference → $backup"
    if [ -d "$current" ]; then
      cp -a "$current" "$backup"
    fi
    git config --global core.hooksPath "$TARGET_HOOKS_DIR"
    ok "core.hooksPath updated (backup: $backup)"
    return 0
  fi

  error "core.hooksPath is already set to: $current"
  error "This installer targets:          $TARGET_HOOKS_DIR"
  error ""
  error "Aborting to avoid silently overriding your hook configuration."
  error "Re-run with --force to backup and replace."
  exit 1
}

# ---------------------------------------------------------------------------
# 2. Detect Husky / pre-commit / Lefthook in recent repos (non-fatal warn)
# ---------------------------------------------------------------------------
detect_hook_managers() {
  local search_dirs=()
  local dd

  for dd in "$HOME/project" "$HOME/projects" "$HOME/repos" "$HOME/code" "$HOME/work" "$HOME/src"; do
    [ -d "$dd" ] && search_dirs+=("$dd")
  done

  if [ "${#search_dirs[@]}" -eq 0 ]; then
    return 0
  fi

  local found=0
  local marker
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    warn "Hook manager artifact found: $marker"
    found=1
  done < <(
    find "${search_dirs[@]}" -maxdepth 3 \
      \( -name '.husky' -type d \
      -o -name '.pre-commit-config.yaml' \
      -o -name 'lefthook.yml' \) \
      2>/dev/null | head -n 20
  ) || true

  if [ "$found" = "1" ]; then
    warn "Some repos use other hook managers. A global core.hooksPath override"
    warn "may bypass per-repo hooks. Use PRIVACY_FILTER_SKIP=1 if needed."
  fi
}

# ---------------------------------------------------------------------------
# 3. Copy hooks
# ---------------------------------------------------------------------------
copy_hooks() {
  mkdir -p "$TARGET_HOOKS_DIR"

  local hook_files=("pre-commit" "commit-msg" "_lib.sh")
  for hf in "${hook_files[@]}"; do
    local src="$PROJECT_ROOT/hooks/$hf"
    local dst="$TARGET_HOOKS_DIR/$hf"
    if [ ! -f "$src" ]; then
      die "Hook source not found: $src"
    fi
    cp "$src" "$dst"
    chmod +x "$dst"
  done
  ok "Hooks installed → $TARGET_HOOKS_DIR/"
}

# ---------------------------------------------------------------------------
# 4. Set core.hooksPath
# ---------------------------------------------------------------------------
set_hooks_path() {
  local current
  current="$(git config --global core.hooksPath 2>/dev/null)" || true
  if [ "$current" = "$TARGET_HOOKS_DIR" ]; then
    return 0
  fi
  git config --global core.hooksPath "$TARGET_HOOKS_DIR"
  ok "core.hooksPath → $TARGET_HOOKS_DIR"
}

# ---------------------------------------------------------------------------
# 5. Print verification commands
# ---------------------------------------------------------------------------
print_verify() {
  echo ""
  info "Verify installation:"
  echo "  git config --global core.hooksPath"
  echo "  ls -la $TARGET_HOOKS_DIR/"
  echo ""
  info "To skip hooks in a specific repo:"
  echo "  PRIVACY_FILTER_SKIP=1 git commit -m 'my message'"
  echo ""
  info "To uninstall:"
  echo "  install/uninstall.sh"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  info "Installing privacy-filter git hooks…"

  check_hooks_path
  detect_hook_managers
  copy_hooks
  set_hooks_path
  print_verify

  ok "Hook installation complete."
}

main "$@"
