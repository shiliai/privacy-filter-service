#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init hook-paths-repair

managed_parent="$HOME/managed-parent"
managed="$managed_parent/hooks"
delegate="$HOME/delegate-hooks"
legacy_log="$PF_IT_ROOT/legacy.log"
delegate_log="$PF_IT_ROOT/delegate.log"
mkdir -p "$managed_parent" "$delegate"

# Relative managed roots are ambiguous and must be rejected before writes.
if PRIVACY_FILTER_HOOKS_DIR='relative-hooks' bash "$ROOT_DIR/install/install-hooks.sh" >/dev/null 2>&1; then
  echo 'expected relative managed root rejection' >&2
  exit 1
fi
[ ! -e "$ROOT_DIR/relative-hooks" ]

# An unmodified legacy OPF hook is archived, but custom wrapper behavior is
# retained as the delegate.
cp "$HOOKS_DIR/pre-commit" "$delegate/pre-commit"
cp "$HOOKS_DIR/commit-msg" "$delegate/commit-msg"
cp "$HOOKS_DIR/_lib.sh" "$delegate/_lib.sh"
cp "$HOOKS_DIR/pf_fallback.py" "$delegate/pf_fallback.py"
sed '2i\
printf '\''legacy-pre-commit-ran\\n'\'' >> "$PF_LEGACY_LOG"' "$delegate/pre-commit" > "$delegate/pre-commit.tmp"
mv "$delegate/pre-commit.tmp" "$delegate/pre-commit"
chmod 755 "$delegate/pre-commit" "$delegate/commit-msg" "$delegate/_lib.sh" "$delegate/pf_fallback.py"
git config --global core.hooksPath '~/delegate-hooks/'

PRIVACY_FILTER_HOOKS_DIR="$managed_parent/../managed-parent/hooks" PF_LEGACY_LOG="$legacy_log" bash "$ROOT_DIR/install/install-hooks.sh" 2>"$PF_IT_ROOT/custom-wrapper.stderr"
grep -qF 'custom OPF pre-commit wrapper preserved as delegate and will execute OPF a second time' "$PF_IT_ROOT/custom-wrapper.stderr"
[ "$(git config --global --get core.hooksPath)" = "$managed" ]
grep -qF "delegate_hooks_path=$delegate" "$managed/.privacy-filter-hooks-state"
[ -e "$delegate/pre-commit" ]
[ ! -e "$delegate/commit-msg" ]
[ ! -f "$managed/legacy-backup/pre-commit" ]
[ -f "$managed/legacy-backup/commit-msg" ]
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh" --doctor >/dev/null 2>"$PF_IT_ROOT/custom-wrapper-doctor.stderr"
grep -qF 'delegate pre-commit contains OPF and will execute it a second time' "$PF_IT_ROOT/custom-wrapper-doctor.stderr"

repo="$PF_IT_ROOT/repo"
mkdir -p "$repo"
git init -q "$repo"
git -C "$repo" config user.name 'Test User'
git -C "$repo" config user.email 'test@example.com'
printf 'safe = true\n' > "$repo/clean.txt"
git -C "$repo" add clean.txt
PF_LEGACY_LOG="$legacy_log" git -C "$repo" commit -m 'single opf path' >/dev/null
grep -qFx 'legacy-pre-commit-ran' "$legacy_log"

# A later tool cannot overwrite the locked root. Its documented integration
# path is the preserved delegate directory, where a clean commit runs it.
cat > "$delegate/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf 'foreign-tool-ran\n' >> "$PF_DELEGATE_LOG"
exit 0
EOF
chmod 755 "$delegate/pre-commit"
if [ "$(id -u)" -ne 0 ] && cp "$delegate/pre-commit" "$managed/pre-commit" 2>/dev/null; then
  echo 'expected managed-root overwrite rejection' >&2
  exit 1
fi
printf 'safe = "delegate"\n' > "$repo/delegate.txt"
git -C "$repo" add delegate.txt
PF_DELEGATE_LOG="$delegate_log" git -C "$repo" commit -m 'foreign delegate' >/dev/null
grep -qFx 'foreign-tool-ran' "$delegate_log"

# A v2 install may have preserved a relative delegate. Upgrading must retain
# it and resolve it from the repository root when the dispatcher runs.
v3_state="$PF_IT_ROOT/v3-hooks-state"
cp "$managed/.privacy-filter-hooks-state" "$v3_state"
chmod u+w "$managed/.privacy-filter-hooks-state"
sed -e 's/^version=3$/version=2/' -e 's|^delegate_hooks_path=.*$|delegate_hooks_path=.githooks|' "$v3_state" > "$managed/.privacy-filter-hooks-state"
chmod 444 "$managed/.privacy-filter-hooks-state"
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh"
grep -qF 'delegate_hooks_path=.githooks' "$managed/.privacy-filter-hooks-state"
[ "$(git config --global --get core.hooksPath)" = "$managed" ]
mkdir -p "$repo/.githooks"
cat > "$repo/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf 'relative-delegate-ran\n' >> "$PF_DELEGATE_LOG"
EOF
chmod 755 "$repo/.githooks/pre-commit"
printf 'safe = "relative delegate"\n' > "$repo/relative-delegate.txt"
git -C "$repo" add relative-delegate.txt
PF_DELEGATE_LOG="$delegate_log" git -C "$repo" commit -m 'relative delegate' >/dev/null
grep -qFx 'relative-delegate-ran' "$delegate_log"
chmod u+w "$managed/.privacy-filter-hooks-state"
cp "$v3_state" "$managed/.privacy-filter-hooks-state"
chmod 444 "$managed/.privacy-filter-hooks-state"

# A fresh install also preserves a Git-supported relative global hooks path.
relative_managed="$HOME/relative-managed-hooks"
git config --global core.hooksPath '.githooks'
PRIVACY_FILTER_HOOKS_DIR="$relative_managed" bash "$ROOT_DIR/install/install-hooks.sh"
grep -qF 'delegate_hooks_path=.githooks' "$relative_managed/.privacy-filter-hooks-state"
[ "$(git config --global --get core.hooksPath)" = "$relative_managed" ]
PRIVACY_FILTER_HOOKS_DIR="$relative_managed" bash "$ROOT_DIR/install/uninstall.sh" --hooks-only
git config --global core.hooksPath "$managed"

# Git's ~user/path syntax resolves through the OS account database, not the
# repository root or this test's isolated HOME.
account_user="$(id -un)"
account_home="$(python3 -c 'import pwd; print(pwd.getpwuid(__import__("os").getuid()).pw_dir)')"
user_tilde_managed="$HOME/user-tilde-managed-hooks"
git config --global core.hooksPath "~$account_user/."
PRIVACY_FILTER_HOOKS_DIR="$user_tilde_managed" bash "$ROOT_DIR/install/install-hooks.sh"
grep -qF "delegate_hooks_path=$account_home" "$user_tilde_managed/.privacy-filter-hooks-state"
PRIVACY_FILTER_HOOKS_DIR="$user_tilde_managed" bash "$ROOT_DIR/install/uninstall.sh" --hooks-only
[ "$(git config --global --get core.hooksPath)" = "$account_home" ]
git config --global core.hooksPath "$managed"

# The real incident-era hook identities migrate, while the adjacent custom
# wrapper coverage above proves marker matches alone are insufficient.
incident_delegate="$HOME/incident-delegate"
incident_managed="$HOME/incident-managed-hooks"
incident_hash_bin="$PF_IT_ROOT/incident-hash-bin"
mkdir -p "$incident_delegate" "$incident_hash_bin"
printf '#!/usr/bin/env bash\n# fake incident pre-commit fixture\nexit 0\n' > "$incident_delegate/pre-commit"
printf '#!/usr/bin/env bash\n# fake incident commit-msg fixture\nexit 0\n' > "$incident_delegate/commit-msg"
if command -v sha256sum >/dev/null 2>&1; then incident_hash_tool=sha256sum; else incident_hash_tool=shasum; fi
cat > "$incident_hash_bin/$incident_hash_tool" <<'EOF'
#!/usr/bin/env bash
for path in "$@"; do :; done
case "${path##*/}" in
  pre-commit) printf '%s  %s\n' '31eb638ad5444c5daad260af6f457f9248e136f8f3ecf0d41fd42f757ecbc669' "$path" ;;
  commit-msg) printf '%s  %s\n' '9a6c7f7eeecd2e174868cd435a3a0c6882bd34e17ab487d069df1eae46013170' "$path" ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$incident_hash_bin/$incident_hash_tool"
chmod 755 "$incident_delegate/pre-commit" "$incident_delegate/commit-msg"
git config --global core.hooksPath "$incident_delegate"
PATH="$incident_hash_bin:$PATH" PRIVACY_FILTER_HOOKS_DIR="$incident_managed" bash "$ROOT_DIR/install/install-hooks.sh"
[ ! -e "$incident_delegate/pre-commit" ]
[ ! -e "$incident_delegate/commit-msg" ]
[ -f "$incident_managed/legacy-backup/pre-commit" ]
[ -f "$incident_managed/legacy-backup/commit-msg" ]
PRIVACY_FILTER_HOOKS_DIR="$incident_managed" bash "$ROOT_DIR/install/uninstall.sh" --hooks-only
git config --global core.hooksPath "$managed"

# Reinstall records expected mutable delegate hooks without hashing contents.
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh"
grep -qF 'delegate_pre_commit_expected=1' "$managed/.privacy-filter-hooks-state"
mv "$delegate" "$delegate.missing"
if PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh" --doctor >/dev/null 2>&1; then
  echo 'expected doctor to report missing delegate directory' >&2
  exit 1
fi
mv "$delegate.missing" "$delegate"
mv "$delegate/pre-commit" "$delegate/pre-commit.missing"
if PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh" --doctor >/dev/null 2>&1; then
  echo 'expected doctor to report missing expected delegate hook' >&2
  exit 1
fi
mv "$delegate/pre-commit.missing" "$delegate/pre-commit"

# A valid ownership state permits deterministic repair of managed damage.
chmod 755 "$managed"
rm -f "$managed/pre-commit"
chmod 555 "$managed"
if PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh" --doctor >/dev/null 2>&1; then
  echo 'expected doctor failure for deleted dispatcher' >&2
  exit 1
fi
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh"
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh" --doctor

chmod 755 "$managed"
chmod 755 "$managed/pre-commit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$managed/pre-commit"
chmod 555 "$managed/pre-commit" "$managed"
if PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh" --doctor >/dev/null 2>&1; then
  echo 'expected doctor failure for overwritten dispatcher marker' >&2
  exit 1
fi
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh"
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh" --doctor

# Textual and symlink aliases of the managed root never become delegates.
git config --global core.hooksPath "$managed/"
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh"
grep -qF "delegate_hooks_path=$delegate" "$managed/.privacy-filter-hooks-state"
ln -s "$managed" "$HOME/managed-link"
git config --global core.hooksPath "$HOME/managed-link"
PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/install-hooks.sh"
grep -qF "delegate_hooks_path=$delegate" "$managed/.privacy-filter-hooks-state"

# Hook-only rollback restores hook configuration without invoking service control.
mock_bin="$PF_IT_ROOT/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl called\n' >> "$PF_SYSTEMCTL_LOG"
exit 0
EOF
chmod 755 "$mock_bin/systemctl"
systemctl_log="$PF_IT_ROOT/systemctl.log"
git config --global core.hooksPath "$HOME/conflicting-hooks"
if PATH="$mock_bin:$PATH" PF_SYSTEMCTL_LOG="$systemctl_log" PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/uninstall.sh" --hooks-only >/dev/null 2>&1; then
  echo 'expected uninstall to stop on a global hooksPath conflict' >&2
  exit 1
fi
[ -f "$managed/.privacy-filter-hooks-state" ]
[ "$(git config --global --get core.hooksPath)" = "$HOME/conflicting-hooks" ]
git config --global core.hooksPath "$managed"
PATH="$mock_bin:$PATH" PF_SYSTEMCTL_LOG="$systemctl_log" PRIVACY_FILTER_HOOKS_DIR="$managed" bash "$ROOT_DIR/install/uninstall.sh" --hooks-only
[ ! -e "$systemctl_log" ]
[ "$(git config --global --get core.hooksPath)" = "$delegate" ]

echo 'PASS test_hook_paths_repair'
