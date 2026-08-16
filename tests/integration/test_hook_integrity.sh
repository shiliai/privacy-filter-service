#!/usr/bin/env bash
# Regression coverage for OPF-first global hook composition and repair.
set -euo pipefail
source "$(dirname "$0")/common.sh"

pfit_init hook-integrity
prior_hooks="$PF_IT_ROOT/prior-hooks"
opf_hooks="$HOME/.config/privacy-filter/git-hooks"
delegate_log="$PF_IT_ROOT/delegate.log"
mkdir -p "$prior_hooks"

cat > "$prior_hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf 'foreign-pre-commit\n' >> "$PF_DELEGATE_LOG"
if [ "${PF_DELEGATE_STAGE_SECRET:-0}" = 1 ]; then
  printf 'credential = "AKIAFAKEFAKEFAKEFAKE"\n' > "$PF_DELEGATE_REPO/delegate-added.txt"
  git -C "$PF_DELEGATE_REPO" add delegate-added.txt
fi
exit "${PF_DELEGATE_STATUS:-0}"
EOF
chmod 755 "$prior_hooks/pre-commit"

# Reproduce the incident's legacy shared root: a foreign active pre-commit,
# OPF at pre-commit.old, and a legacy OPF commit-msg that must not run twice.
cp "$HOOKS_DIR/pre-commit" "$prior_hooks/pre-commit.old"
cp "$HOOKS_DIR/commit-msg" "$prior_hooks/commit-msg"
cp "$HOOKS_DIR/_lib.sh" "$prior_hooks/_lib.sh"
chmod 755 "$prior_hooks/pre-commit.old" "$prior_hooks/commit-msg" "$prior_hooks/_lib.sh"
git config --global core.hooksPath "$prior_hooks"

# A nonempty target without OPF ownership must be left completely untouched.
foreign_target="$PF_IT_ROOT/foreign-target"
mkdir -p "$foreign_target"
printf 'foreign target\n' > "$foreign_target/sentinel"
chmod 711 "$foreign_target"
if PRIVACY_FILTER_HOOKS_DIR="$foreign_target" bash "$ROOT_DIR/install/install-hooks.sh" >/dev/null 2>&1; then
  echo 'expected install to refuse nonempty unmanaged target' >&2
  exit 1
fi
[ "$(stat -c '%a' "$foreign_target" 2>/dev/null || stat -f '%Lp' "$foreign_target")" = 711 ]
grep -qFx 'foreign target' "$foreign_target/sentinel"
chmod 755 "$foreign_target"

# Legacy entries remain live until managed installation has passed its checks.
failed_root="$PF_IT_ROOT/failed-root"
if PRIVACY_FILTER_HOOKS_DIR="$failed_root" PRIVACY_FILTER_TEST_FAIL_AFTER_FIRST_LEGACY_REMOVAL=1 bash "$ROOT_DIR/install/install-hooks.sh" >/dev/null 2>&1; then
  echo 'expected forced post-migration failure' >&2
  exit 1
fi
[ -f "$prior_hooks/pre-commit.old" ]
[ -f "$prior_hooks/commit-msg" ]
[ "$(git config --global --get core.hooksPath)" = "$prior_hooks" ]
[ ! -e "$failed_root" ]

PRIVACY_FILTER_HOOKS_DIR="$opf_hooks" bash "$ROOT_DIR/install/install-hooks.sh"
[ "$(git config --global --get core.hooksPath)" = "$opf_hooks" ]
[ -x "$prior_hooks/pre-commit" ]
[ ! -e "$prior_hooks/pre-commit.old" ]
[ ! -e "$prior_hooks/commit-msg" ]
[ -f "$opf_hooks/legacy-backup/pre-commit.old" ]
[ -f "$opf_hooks/legacy-backup/commit-msg" ]

repo="$PF_IT_ROOT/repo"
mkdir -p "$repo"
git init -q "$repo"
git -C "$repo" config user.name 'Test User'
git -C "$repo" config user.email 'test@example.com'

# An unmistakably fake fixture still has the shape of an AWS access key.
printf 'credential = "AKIAFAKEFAKEFAKEFAKE"\n' > "$repo/fixture.txt"
git -C "$repo" add fixture.txt
if PF_DELEGATE_LOG="$delegate_log" git -C "$repo" commit -m 'blocked fake fixture' >/dev/null 2>&1; then
  echo 'expected deterministic local secret gate to block the commit' >&2
  exit 1
fi
[ ! -e "$delegate_log" ]

# The ordinary postinstall overwrite fails loudly for an unprivileged owner.
if [ "$(id -u)" -ne 0 ]; then
  if cp "$prior_hooks/pre-commit" "$opf_hooks/pre-commit" 2>/dev/null; then
    echo 'expected locked OPF dispatcher root to reject foreign overwrite' >&2
    exit 1
  fi
fi
PRIVACY_FILTER_HOOKS_DIR="$opf_hooks" bash "$ROOT_DIR/install/install-hooks.sh" --doctor

git -C "$repo" reset -q
printf 'safe = true\n' > "$repo/clean.txt"
git -C "$repo" add clean.txt
PF_DELEGATE_LOG="$delegate_log" git -C "$repo" commit -m 'clean delegate' >/dev/null
grep -qFx 'foreign-pre-commit' "$delegate_log"

# A delegate may stage new content. The dispatcher snapshots the index and
# re-runs OPF after delegation, so this second fake fixture is still blocked.
printf 'safe = "before delegate"\n' > "$repo/delegate-source.txt"
git -C "$repo" add delegate-source.txt
if PF_DELEGATE_LOG="$delegate_log" PF_DELEGATE_REPO="$repo" PF_DELEGATE_STAGE_SECRET=1 git -C "$repo" commit -m 'delegate adds fake secret' >/dev/null 2>&1; then
  echo 'expected post-delegate OPF rescan to block staged fake secret' >&2
  exit 1
fi
git -C "$repo" show :delegate-added.txt | grep -qF 'AKIAFAKEFAKEFAKEFAKE'
git -C "$repo" reset -q

# Delegate failures are returned after OPF succeeds.
printf 'safe = "again"\n' > "$repo/exit.txt"
git -C "$repo" add exit.txt
if PF_DELEGATE_LOG="$delegate_log" PF_DELEGATE_STATUS=23 git -C "$repo" commit -m 'delegate fails' >/dev/null 2>&1; then
  echo 'expected preserved delegate failure to block the commit' >&2
  exit 1
fi
git -C "$repo" reset -q

# Doctor resolves Git configuration from the target repository, so a local
# override is visible rather than falsely reporting the global install healthy.
git -C "$repo" config core.hooksPath "$prior_hooks"
if (cd "$repo" && PRIVACY_FILTER_HOOKS_DIR="$opf_hooks" bash "$ROOT_DIR/install/install-hooks.sh" --doctor) >/dev/null 2>&1; then
  echo 'expected doctor to reject repository-local core.hooksPath override' >&2
  exit 1
fi
git -C "$repo" config --unset core.hooksPath

# Existing archive files must never authorize deletion of hooks created later
# by another tool in the delegated path.
printf 'new foreign pre-commit.old\n' > "$prior_hooks/pre-commit.old"
cat > "$prior_hooks/commit-msg" <<'EOF'
#!/usr/bin/env bash
printf 'foreign-commit-msg\n' >> "$PF_DELEGATE_LOG"
exit 0
EOF
chmod 755 "$prior_hooks/commit-msg"
old_checksum="$(cksum < "$prior_hooks/pre-commit.old")"
msg_checksum="$(cksum < "$prior_hooks/commit-msg")"

# Reinstall keeps the same delegate relationship and remains integrity-clean.
before="$(cksum < "$opf_hooks/pre-commit")"
PRIVACY_FILTER_HOOKS_DIR="$opf_hooks" bash "$ROOT_DIR/install/install-hooks.sh"
after="$(cksum < "$opf_hooks/pre-commit")"
[ "$before" = "$after" ]
[ "$old_checksum" = "$(cksum < "$prior_hooks/pre-commit.old")" ]
[ "$msg_checksum" = "$(cksum < "$prior_hooks/commit-msg")" ]
printf 'safe = "post reinstall"\n' > "$repo/reinstall.txt"
git -C "$repo" add reinstall.txt
PF_DELEGATE_LOG="$delegate_log" git -C "$repo" commit -m 'delegate after reinstall' >/dev/null
grep -qFx 'foreign-commit-msg' "$delegate_log"
PRIVACY_FILTER_HOOKS_DIR="$opf_hooks" bash "$ROOT_DIR/install/install-hooks.sh" --doctor

printf 'new precommit old\n' > "$prior_hooks/pre-commit.old"
printf 'new commit message hook\n' > "$prior_hooks/commit-msg"
PRIVACY_FILTER_HOOKS_DIR="$opf_hooks" bash "$ROOT_DIR/install/uninstall.sh" 2>"$PF_IT_ROOT/uninstall.stderr"
[ "$(git config --global --get core.hooksPath)" = "$prior_hooks" ]
[ "$(cat "$prior_hooks/pre-commit.old")" = 'new precommit old' ]
[ "$(cat "$prior_hooks/commit-msg")" = 'new commit message hook' ]
[ -f "$opf_hooks/legacy-backup/pre-commit.old" ]
[ -f "$opf_hooks/legacy-backup/commit-msg" ]
grep -qF 'not restoring legacy' "$PF_IT_ROOT/uninstall.stderr"
[ -x "$prior_hooks/pre-commit" ]

echo 'PASS test_hook_integrity'
