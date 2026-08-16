#!/usr/bin/env bash
# Install an OPF-owned dispatcher root and delegate the previous hooks path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_HOOKS_INPUT="${PRIVACY_FILTER_HOOKS_DIR:-$HOME/.config/privacy-filter/git-hooks}"
case "$TARGET_HOOKS_INPUT" in /*) ;; *) printf '[ERROR] managed hooks path must be absolute: %s\n' "$TARGET_HOOKS_INPUT" >&2; exit 1 ;; esac
TARGET_HOOKS_DIR="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TARGET_HOOKS_INPUT")"
STATE_FILE="$TARGET_HOOKS_DIR/.privacy-filter-hooks-state"
DOCTOR=false
UNLOCKED=false
MIGRATED_LEGACY_PRE_COMMIT_OLD=0
MIGRATED_LEGACY_PRE_COMMIT=0
MIGRATED_LEGACY_COMMIT_MSG=0
STAGED_LEGACY_PRE_COMMIT_OLD=0
STAGED_LEGACY_PRE_COMMIT=0
STAGED_LEGACY_COMMIT_MSG=0
REMOVED_LEGACY_PRE_COMMIT_OLD=0
REMOVED_LEGACY_PRE_COMMIT=0
REMOVED_LEGACY_COMMIT_MSG=0
ROOT_CREATED=false
GLOBAL_CHANGED=false
PRIOR_GLOBAL_HOOKS_PATH=""
PRIOR_DELEGATE_PATH=""

info() { printf '[INFO]  %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die() { error "$*"; exit 1; }
checksum() { cksum < "$1" | awk '{print $1 ":" $2}'; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die 'SHA-256 utility not found (need sha256sum or shasum)'
  fi
}
is_dispatcher() { [ -f "$1" ] && grep -qF '# privacy-filter-dispatcher-v1' "$1"; }
# Only archive exact, known OPF hook identities. Marker-based detection could
# delete a user wrapper that invokes OPF and then performs additional checks.
# The two retired identities are the verified incident-era releases; keeping
# hashes rather than their contents avoids reintroducing their source.
is_legacy_opf() {
  local file="$1" hook="${2:?hook name required}" identity
  [ -f "$file" ] || return 1
  cmp -s "$file" "$PROJECT_ROOT/hooks/$hook" && return 0
  identity="$(sha256_file "$file")"
  case "$hook:$identity" in
    pre-commit:31eb638ad5444c5daad260af6f457f9248e136f8f3ecf0d41fd42f757ecbc669|commit-msg:9a6c7f7eeecd2e174868cd435a3a0c6882bd34e17ab487d069df1eae46013170) return 0 ;;
    *) return 1 ;;
  esac
}
is_relative_hooks_path() { case "$1" in ''|/*|'~/'*) return 1 ;; *) return 0 ;; esac; }

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
      --doctor) DOCTOR=true ;;
      --force) info '--force is no longer required; the prior hooks path is preserved as a delegate' ;;
      -h|--help) printf 'Usage: %s [--doctor]\n' "$0"; exit 0 ;;
      *) die "Unknown argument: $arg. Use --help for usage." ;;
    esac
  done
}

unlock_root() {
  local file
  mkdir -p "$TARGET_HOOKS_DIR"
  chmod 700 "$TARGET_HOOKS_DIR"
  for file in pre-commit commit-msg _lib.sh pf_fallback.py pre-commit.opf commit-msg.opf .privacy-filter-hooks-state; do
    [ -e "$TARGET_HOOKS_DIR/$file" ] && chmod u+w "$TARGET_HOOKS_DIR/$file"
  done
  [ -d "$TARGET_HOOKS_DIR/legacy-backup" ] && chmod 700 "$TARGET_HOOKS_DIR/legacy-backup"
  UNLOCKED=true
}
lock_root() {
  [ "$UNLOCKED" = true ] || return 0
  chmod 555 "$TARGET_HOOKS_DIR"
  UNLOCKED=false
}
trap 'status=$?; [ "$status" -eq 0 ] || rollback_install; lock_root; exit "$status"' EXIT

write_dispatcher() {
  local hook dispatcher
  hook="$1"
  dispatcher="$TARGET_HOOKS_DIR/$hook"
  cat > "$dispatcher" <<'EOF'
#!/usr/bin/env bash
# privacy-filter-dispatcher-v1
# OPF runs before the preserved prior hooks path and controls whether it runs.
set -u
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_name="$(basename "$0")"
before_index=""
before_message=""
case "$hook_name" in
  pre-commit) before_index="$(git write-tree 2>/dev/null || true)" ;;
  commit-msg) [ "$#" -gt 0 ] && before_message="$(cksum < "$1")" ;;
esac
"$hook_dir/$hook_name.opf" "$@"
status=$?
[ "$status" -eq 0 ] || exit "$status"
delegate_dir="$(sed -n 's/^delegate_hooks_path=//p' "$hook_dir/.privacy-filter-hooks-state" | head -n 1)"
[ -z "$delegate_dir" ] || [ "${delegate_dir#/}" != "$delegate_dir" ] || delegate_dir="$(git rev-parse --show-toplevel 2>/dev/null || true)/$delegate_dir"
[ -n "$delegate_dir" ] && [ "$delegate_dir" != "$hook_dir" ] && [ -x "$delegate_dir/$hook_name" ] || exit 0
"$delegate_dir/$hook_name" "$@"
status=$?
[ "$status" -eq 0 ] || exit "$status"
case "$hook_name" in
  pre-commit) [ "$before_index" = "$(git write-tree 2>/dev/null || true)" ] || "$hook_dir/$hook_name.opf" "$@" ;;
  commit-msg) [ "$before_message" = "$(cksum < "$1")" ] || "$hook_dir/$hook_name.opf" "$@" ;;
esac
exit $?
EOF
  chmod 555 "$dispatcher"
}

write_state() {
  local delegate="$1" file expected_pre=0 expected_msg=0
  if ! is_relative_hooks_path "$delegate"; then
    [ -n "$delegate" ] && [ -x "$delegate/pre-commit" ] && [ "$STAGED_LEGACY_PRE_COMMIT" != 1 ] && expected_pre=1
    [ -n "$delegate" ] && [ -x "$delegate/commit-msg" ] && [ "$STAGED_LEGACY_COMMIT_MSG" != 1 ] && expected_msg=1
  fi
  umask 077
  {
    printf 'version=3\n'
    printf 'managed_root=%s\n' "$TARGET_HOOKS_DIR"
    printf 'delegate_hooks_path=%s\n' "$delegate"
    printf 'delegate_pre_commit_expected=%s\n' "$expected_pre"
    printf 'delegate_commit_msg_expected=%s\n' "$expected_msg"
    printf 'legacy_pre_commit=%s\n' "$MIGRATED_LEGACY_PRE_COMMIT"
    printf 'legacy_pre_commit_old=%s\n' "$MIGRATED_LEGACY_PRE_COMMIT_OLD"
    printf 'legacy_commit_msg=%s\n' "$MIGRATED_LEGACY_COMMIT_MSG"
    for file in pre-commit commit-msg _lib.sh pf_fallback.py pre-commit.opf commit-msg.opf; do
      printf 'checksum_%s=%s\n' "${file//./_}" "$(checksum "$TARGET_HOOKS_DIR/$file")"
    done
  } > "$STATE_FILE"
  chmod 444 "$STATE_FILE"
}
state_value() { sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1; }

migrate_legacy_opf() {
  local prior="$1" source backup
  [ -n "$prior" ] && [ -d "$prior" ] || return 0
  mkdir -p "$TARGET_HOOKS_DIR/legacy-backup"
  source="$prior/pre-commit"
  backup="$TARGET_HOOKS_DIR/legacy-backup/pre-commit"
  if [ ! -e "$backup" ] && is_legacy_opf "$source" pre-commit; then
    cp -p "$source" "$backup"
    MIGRATED_LEGACY_PRE_COMMIT=1
    STAGED_LEGACY_PRE_COMMIT=1
    info 'Staged active legacy OPF pre-commit for archival to prevent double execution'
  fi
  source="$prior/pre-commit.old"
  backup="$TARGET_HOOKS_DIR/legacy-backup/pre-commit.old"
  if [ ! -e "$backup" ] && is_legacy_opf "$source" pre-commit; then
    cp -p "$source" "$backup"
    MIGRATED_LEGACY_PRE_COMMIT_OLD=1
    STAGED_LEGACY_PRE_COMMIT_OLD=1
    info 'Staged legacy OPF pre-commit.old for archival; active pre-commit remains the delegate'
  fi
  source="$prior/commit-msg"
  backup="$TARGET_HOOKS_DIR/legacy-backup/commit-msg"
  if [ ! -e "$backup" ] && is_legacy_opf "$source" commit-msg; then
    cp -p "$source" "$backup"
    MIGRATED_LEGACY_COMMIT_MSG=1
    STAGED_LEGACY_COMMIT_MSG=1
    info 'Staged legacy OPF commit-msg for archival to prevent double execution'
  fi
}

commit_legacy_migration() {
  local prior="$1" source backup
  [ -n "$prior" ] || return 0
  if [ "$STAGED_LEGACY_PRE_COMMIT" = 1 ]; then
    source="$prior/pre-commit"; backup="$TARGET_HOOKS_DIR/legacy-backup/pre-commit"
    [ -w "$prior" ] || die 'cannot safely archive legacy pre-commit: prior hooks directory is not writable'
    is_legacy_opf "$source" pre-commit && [ "$(checksum "$source")" = "$(checksum "$backup")" ] || die 'legacy pre-commit changed during installation; refusing removal'
    rm -f "$source"
    REMOVED_LEGACY_PRE_COMMIT=1
  fi
  if [ "$STAGED_LEGACY_PRE_COMMIT_OLD" = 1 ]; then
    source="$prior/pre-commit.old"; backup="$TARGET_HOOKS_DIR/legacy-backup/pre-commit.old"
    [ -w "$prior" ] || die 'cannot safely archive legacy pre-commit.old: prior hooks directory is not writable'
    is_legacy_opf "$source" pre-commit && [ "$(checksum "$source")" = "$(checksum "$backup")" ] || die 'legacy pre-commit.old changed during installation; refusing removal'
    rm -f "$source"
    REMOVED_LEGACY_PRE_COMMIT_OLD=1
  fi
  if [ "${PRIVACY_FILTER_TEST_FAIL_AFTER_FIRST_LEGACY_REMOVAL:-0}" = 1 ]; then die 'forced failure after first legacy removal'; fi
  if [ "$STAGED_LEGACY_COMMIT_MSG" = 1 ]; then
    source="$prior/commit-msg"; backup="$TARGET_HOOKS_DIR/legacy-backup/commit-msg"
    [ -w "$prior" ] || die 'cannot safely archive legacy commit-msg: prior hooks directory is not writable'
    is_legacy_opf "$source" commit-msg && [ "$(checksum "$source")" = "$(checksum "$backup")" ] || die 'legacy commit-msg changed during installation; refusing removal'
    rm -f "$source"
    REMOVED_LEGACY_COMMIT_MSG=1
  fi
}

validate_target_ownership() {
  if [ ! -e "$TARGET_HOOKS_DIR" ]; then ROOT_CREATED=true; return 0; fi
  [ -d "$TARGET_HOOKS_DIR" ] || die "managed hooks path is not a directory: $TARGET_HOOKS_DIR"
  if find "$TARGET_HOOKS_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    valid_managed_state || die "refusing nonempty unmanaged hooks directory: $TARGET_HOOKS_DIR"
  fi
}

valid_managed_state() {
  local version root key
  [ -f "$STATE_FILE" ] || return 1
  version="$(state_value version)"
  case "$version" in
    3) root="$(state_value managed_root)"; [ "$root" = "$TARGET_HOOKS_DIR" ] || return 1 ;;
    2) ;;
    *) return 1 ;;
  esac
  for key in checksum_pre-commit checksum_commit-msg checksum__lib_sh checksum_pf_fallback_py checksum_pre-commit_opf checksum_commit-msg_opf; do
    [ -n "$(state_value "$key")" ] || return 1
  done
  return 0
}

rollback_staged_legacy() {
  [ "$ROOT_CREATED" = true ] || return 0
  rm -f "$TARGET_HOOKS_DIR/legacy-backup/pre-commit" "$TARGET_HOOKS_DIR/legacy-backup/pre-commit.old" "$TARGET_HOOKS_DIR/legacy-backup/commit-msg"
  rmdir "$TARGET_HOOKS_DIR/legacy-backup" 2>/dev/null || true
  rmdir "$TARGET_HOOKS_DIR" 2>/dev/null || true
}

rollback_install() {
  local file
  if [ "$REMOVED_LEGACY_PRE_COMMIT" = 1 ] && [ -n "$PRIOR_DELEGATE_PATH" ]; then
    cp -p "$TARGET_HOOKS_DIR/legacy-backup/pre-commit" "$PRIOR_DELEGATE_PATH/pre-commit" || true
  fi
  if [ "$REMOVED_LEGACY_PRE_COMMIT_OLD" = 1 ] && [ -n "$PRIOR_DELEGATE_PATH" ]; then
    cp -p "$TARGET_HOOKS_DIR/legacy-backup/pre-commit.old" "$PRIOR_DELEGATE_PATH/pre-commit.old" || true
  fi
  if [ "$REMOVED_LEGACY_COMMIT_MSG" = 1 ] && [ -n "$PRIOR_DELEGATE_PATH" ]; then
    cp -p "$TARGET_HOOKS_DIR/legacy-backup/commit-msg" "$PRIOR_DELEGATE_PATH/commit-msg" || true
  fi
  if [ "$GLOBAL_CHANGED" = true ]; then
    if [ -n "$PRIOR_GLOBAL_HOOKS_PATH" ]; then
      git config --global core.hooksPath "$PRIOR_GLOBAL_HOOKS_PATH" || true
    else
      git config --global --unset core.hooksPath || true
    fi
  fi
  [ "$ROOT_CREATED" = true ] || return 0
  chmod 700 "$TARGET_HOOKS_DIR" 2>/dev/null || true
  for file in pre-commit commit-msg _lib.sh pf_fallback.py pre-commit.opf commit-msg.opf .privacy-filter-hooks-state legacy-backup/pre-commit legacy-backup/pre-commit.old legacy-backup/commit-msg; do
    rm -f "$TARGET_HOOKS_DIR/$file" 2>/dev/null || true
  done
  rmdir "$TARGET_HOOKS_DIR/legacy-backup" 2>/dev/null || true
  rmdir "$TARGET_HOOKS_DIR" 2>/dev/null || true
}

doctor() {
  local effective effective_identity expected actual file key failed=0 delegate expected_pre expected_msg local_override worktree_override
  effective="$(git config --get core.hooksPath 2>/dev/null || true)"
  effective_identity="$(normalize_hooks_path "$effective" 2>/dev/null || true)"
  local_override="$(git config --local --get core.hooksPath 2>/dev/null || true)"
  worktree_override="$(git config --worktree --get core.hooksPath 2>/dev/null || true)"
  [ -z "$local_override" ] && [ -z "$worktree_override" ] || { error 'repository local/worktree core.hooksPath override bypasses OPF'; failed=1; }
  [ "$effective_identity" = "$TARGET_HOOKS_DIR" ] || { error "effective core.hooksPath is '$effective', expected '$TARGET_HOOKS_DIR'"; failed=1; }
  [ -f "$STATE_FILE" ] || { error "missing ownership state: $STATE_FILE"; failed=1; }
  [ "$(stat -c '%a' "$TARGET_HOOKS_DIR" 2>/dev/null || stat -f '%Lp' "$TARGET_HOOKS_DIR" 2>/dev/null || true)" = 555 ] || { error "managed dispatcher root is not locked (expected mode 555): $TARGET_HOOKS_DIR"; failed=1; }
  for file in pre-commit commit-msg _lib.sh pf_fallback.py pre-commit.opf commit-msg.opf; do
    key="checksum_${file//./_}"
    expected="$(state_value "$key")"
    if [ -z "$expected" ] || [ ! -f "$TARGET_HOOKS_DIR/$file" ]; then
      error "missing managed hook file: $TARGET_HOOKS_DIR/$file"; failed=1
    else
      actual="$(checksum "$TARGET_HOOKS_DIR/$file")"
      [ "$expected" = "$actual" ] || { error "changed managed hook file: $TARGET_HOOKS_DIR/$file"; failed=1; }
    fi
  done
  is_dispatcher "$TARGET_HOOKS_DIR/pre-commit" || { error 'missing or changed OPF pre-commit dispatcher'; failed=1; }
  is_dispatcher "$TARGET_HOOKS_DIR/commit-msg" || { error 'missing or changed OPF commit-msg dispatcher'; failed=1; }
  delegate="$(state_value delegate_hooks_path)"
  expected_pre="$(state_value delegate_pre_commit_expected)"
  expected_msg="$(state_value delegate_commit_msg_expected)"
  # A relative delegate is resolved per repository by the dispatcher, so this
  # host-level doctor cannot determine whether a particular repository has it.
  if [ -n "$delegate" ] && ! is_relative_hooks_path "$delegate"; then
    [ -d "$delegate" ] || { error "delegate hooks directory is missing: $delegate"; failed=1; }
    [ "$expected_pre" != 1 ] || [ -x "$delegate/pre-commit" ] || { error "expected delegate hook is missing: $delegate/pre-commit"; failed=1; }
    [ "$expected_msg" != 1 ] || [ -x "$delegate/commit-msg" ] || { error "expected delegate hook is missing: $delegate/commit-msg"; failed=1; }
  fi
  if [ "$failed" -ne 0 ]; then error 'privacy-filter hook integrity FAILED; rerun install/install-hooks.sh to repair.'; return 1; fi
  info 'privacy-filter hook integrity OK'
  info "delegate hooks path: ${delegate:-<none>}"
}

main() {
  parse_args "$@"
  if [ "$DOCTOR" = true ]; then doctor; return; fi
  local prior prior_state_value configured configured_identity
  configured="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  configured_identity="$(normalize_hooks_path "$configured" 2>/dev/null || true)"
  prior="${configured_identity:-$configured}"
  if [ "$configured_identity" = "$TARGET_HOOKS_DIR" ] && [ -f "$STATE_FILE" ]; then
    prior_state_value="$(state_value delegate_hooks_path)"
    prior="$(normalize_hooks_path "$prior_state_value" 2>/dev/null || printf '%s' "$prior_state_value")"
    MIGRATED_LEGACY_PRE_COMMIT="$(state_value legacy_pre_commit)"
    MIGRATED_LEGACY_PRE_COMMIT_OLD="$(state_value legacy_pre_commit_old)"
    MIGRATED_LEGACY_COMMIT_MSG="$(state_value legacy_commit_msg)"
    [ -n "$MIGRATED_LEGACY_PRE_COMMIT" ] || MIGRATED_LEGACY_PRE_COMMIT=0
    [ -n "$MIGRATED_LEGACY_PRE_COMMIT_OLD" ] || MIGRATED_LEGACY_PRE_COMMIT_OLD=0
    [ -n "$MIGRATED_LEGACY_COMMIT_MSG" ] || MIGRATED_LEGACY_COMMIT_MSG=0
  fi
  [ "$prior" = "$TARGET_HOOKS_DIR" ] && prior=""
  # Refuse a path with a newline because the state file is a line-oriented format.
  case "$prior" in *$'\n'*) die 'core.hooksPath contains a newline and cannot be composed safely' ;; esac
  PRIOR_GLOBAL_HOOKS_PATH="$configured"
  PRIOR_DELEGATE_PATH="$prior"
  validate_target_ownership
  unlock_root
  if ! is_relative_hooks_path "$prior"; then migrate_legacy_opf "$prior"; fi
  if [ "${PRIVACY_FILTER_TEST_FAIL_AFTER_MIGRATION:-0}" = 1 ]; then
    rollback_staged_legacy
    die 'forced failure after legacy staging'
  fi
  install -m 555 "$PROJECT_ROOT/hooks/_lib.sh" "$TARGET_HOOKS_DIR/_lib.sh"
  install -m 555 "$PROJECT_ROOT/hooks/pf_fallback.py" "$TARGET_HOOKS_DIR/pf_fallback.py"
  install -m 555 "$PROJECT_ROOT/hooks/pre-commit" "$TARGET_HOOKS_DIR/pre-commit.opf"
  install -m 555 "$PROJECT_ROOT/hooks/commit-msg" "$TARGET_HOOKS_DIR/commit-msg.opf"
  write_dispatcher pre-commit
  write_dispatcher commit-msg
  write_state "$prior"
  git config --global core.hooksPath "$TARGET_HOOKS_DIR"
  GLOBAL_CHANGED=true
  lock_root
  doctor
  commit_legacy_migration "$prior"
  info "Hook installation complete. OPF runs first; prior hooks remain at '${prior:-<none>}' as delegates."
}
main "$@"
