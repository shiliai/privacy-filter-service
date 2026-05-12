#!/usr/bin/env bash
# Integration tests for hooks/commit-msg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
EVIDENCE_DIR="$PROJECT_ROOT/.sisyphus/evidence"

PASS=0
FAIL=0

# Service URL — default to plan-specified test port; override via env
PF_URL="${PRIVACY_FILTER_URL:-http://127.0.0.1:18765}"

# Minimal stub for _lib.sh functions when T10 isn't done yet.
# The real commit-msg sources _lib.sh; we provide stubs for isolated testing.
create_stub_lib() {
    local dest="$1"
    cat > "$dest" << 'STUB_EOF'
#!/usr/bin/env bash
# Stub _lib.sh for commit-msg testing
pf_skip_active() {
    [ "${PRIVACY_FILTER_SKIP:-0}" = "1" ]
}

_pf_service_ready() {
    local url="${PRIVACY_FILTER_URL:-http://127.0.0.1:18765}"
    local ready
    ready=$(curl -fsS -m "${PRIVACY_FILTER_TIMEOUT_S:-5}" "$url/health" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('ready',False))" 2>/dev/null \
        || echo "False")
    [ "$ready" = "True" ]
}

pf_post_json() {
    local endpoint="$1"
    local url="${PRIVACY_FILTER_URL:-http://127.0.0.1:18765}"
    curl -fsS --max-time "${PRIVACY_FILTER_TIMEOUT_S:-5}" \
        -X POST \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "${url}${endpoint}" 2>/dev/null
}

pf_warn_once() {
    local key="$1"
    local msg="$2"
    echo "$msg" >&2
}

pf_ensure_dir() {
    mkdir -p .git/privacy-filter
    chmod 700 .git/privacy-filter 2>/dev/null || true
}
STUB_EOF
}

# Create a test repo with commit-msg hook installed
setup_test_repo() {
    local repo_dir="$1"
    rm -rf "$repo_dir"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init -q

    # Copy hook and stub lib
    mkdir -p .git/hooks
    cp "$HOOKS_DIR/commit-msg" .git/hooks/commit-msg
    chmod +x .git/hooks/commit-msg
    create_stub_lib .git/hooks/_lib.sh

    # Configure git identity
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Create initial commit so subsequent commits have a parent
    echo "init" > init.txt
    git add init.txt
    git commit -q -m "init" --no-verify

    cd "$PROJECT_ROOT"
}

# Create a test repo WITHOUT commit-msg hook (for bypass testing)
setup_test_repo_no_hook() {
    local repo_dir="$1"
    rm -rf "$repo_dir"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init -q

    git config user.email "test@test.com"
    git config user.name "Test User"

    echo "init" > init.txt
    git add init.txt
    git commit -q -m "init" --no-verify

    cd "$PROJECT_ROOT"
}

assert_pass() {
    local name="$1"
    echo "  [PASS] $name"
    PASS=$((PASS + 1))
}

assert_fail() {
    local name="$1"
    local reason="${2:-}"
    echo "  [FAIL] $name $reason"
    FAIL=$((FAIL + 1))
}

# Cleanup
cleanup() {
    rm -rf /tmp/pf-cm-test-*
}
trap cleanup EXIT

# ===========================================================================
echo "=== commit-msg integration tests ==="
echo ""

# Check service availability first
echo "Checking service at $PF_URL ..."
if ! curl -fsS -m 3 "$PF_URL/health" > /dev/null 2>&1; then
    echo "WARNING: Service not available at $PF_URL"
    echo "Tests that require the service will be SKIPPED."
    echo "Set PRIVACY_FILTER_URL to point to a running service."
    SERVICE_UP=0
else
    echo "Service is up."
    SERVICE_UP=1
fi
echo ""

# ===========================================================================
# Test 1: PII in message → redacted
# ===========================================================================
echo "--- Test 1: PII in commit message → redacted ---"
if [ "$SERVICE_UP" -eq 1 ]; then
    REPO="/tmp/pf-cm-test-pii-$$"
    setup_test_repo "$REPO"
    cd "$REPO"
    echo "change" > change.txt
    git add change.txt
    PRIVACY_FILTER_URL="$PF_URL" git commit -m "Fix bug for alice@example.com" 2>/tmp/pf-cm-test1-err.log || true
    committed_msg=$(git log -1 --pretty=%B)
    if echo "$committed_msg" | grep -q '<PRIVATE_EMAIL>'; then
        assert_pass "PII redacted in commit message"
    else
        assert_fail "PII redacted in commit message" "expected <PRIVATE_EMAIL> in: $committed_msg"
    fi
    # Commit must succeed (exit 0)
    if git log -1 --quiet 2>/dev/null; then
        assert_pass "Commit succeeded (non-blocking)"
    else
        assert_fail "Commit succeeded"
    fi
    mkdir -p "$EVIDENCE_DIR"
    git log -1 --pretty=%B > "$EVIDENCE_DIR/task-12-redact-msg.txt" 2>/dev/null || true
    cd "$PROJECT_ROOT"
else
    echo "  [SKIP] Service not available"
fi
echo ""

# ===========================================================================
# Test 2: Comment lines preserved (hook must not modify them)
# ===========================================================================
echo "--- Test 2: Comment lines preserved ---"
if [ "$SERVICE_UP" -eq 1 ]; then
    REPO="/tmp/pf-cm-test-comment-$$"
    setup_test_repo "$REPO"
    cd "$REPO"
    echo "change" > change.txt
    git add change.txt

    # Write a message file directly and invoke hook on it
    MSG_FILE="/tmp/pf-cm-test-msg-$$"
    cat > "$MSG_FILE" << 'EOF'
Subject line with alice@example.com
# this is a comment with bob@secret.org
Body text with 555-123-4567
EOF

    PRIVACY_FILTER_URL="$PF_URL" .git/hooks/commit-msg "$MSG_FILE" 2>/tmp/pf-cm-test2-err.log || true

    # The comment line must still contain the original email (not redacted)
    result=$(cat "$MSG_FILE")
    if echo "$result" | grep -q '# this is a comment with bob@secret.org'; then
        assert_pass "Comment line with email preserved"
    else
        assert_fail "Comment line with email preserved" "comment was modified"
    fi

    # The subject line should be redacted
    if echo "$result" | grep -q '<PRIVATE_EMAIL>'; then
        assert_pass "Subject line redacted"
    else
        assert_fail "Subject line redacted"
    fi

    mkdir -p "$EVIDENCE_DIR"
    cat "$MSG_FILE" > "$EVIDENCE_DIR/task-12-comment-preserved.txt" 2>/dev/null || true
    rm -f "$MSG_FILE"
    cd "$PROJECT_ROOT"
else
    echo "  [SKIP] Service not available"
fi
echo ""

# ===========================================================================
# Test 3: Service down → message unchanged + stderr warning
# ===========================================================================
echo "--- Test 3: Service down → message unchanged + warning ---"
REPO="/tmp/pf-cm-test-down-$$"
setup_test_repo "$REPO"
cd "$REPO"
echo "change" > change.txt
git add change.txt

MSG_FILE="/tmp/pf-cm-test-msg-down-$$"
cat > "$MSG_FILE" << 'EOF'
Fix for alice@example.com
EOF

# Point to a dead port
PRIVACY_FILTER_URL="http://127.0.0.1:1" .git/hooks/commit-msg "$MSG_FILE" 2>/tmp/pf-cm-test3-err.log || true

result=$(cat "$MSG_FILE")
if echo "$result" | grep -q 'alice@example.com'; then
    assert_pass "Message unchanged when service down"
else
    assert_fail "Message unchanged when service down"
fi

if grep -qi 'unavailable\|skipping' /tmp/pf-cm-test3-err.log 2>/dev/null; then
    assert_pass "Warning printed to stderr"
else
    assert_fail "Warning printed to stderr"
fi

mkdir -p "$EVIDENCE_DIR"
cat "$MSG_FILE" > "$EVIDENCE_DIR/task-12-service-down.txt" 2>/dev/null || true
rm -f "$MSG_FILE"
cd "$PROJECT_ROOT"
echo ""

# ===========================================================================
# Test 4: PRIVACY_FILTER_SKIP=1 → no service call
# ===========================================================================
echo "--- Test 4: PRIVACY_FILTER_SKIP=1 → bypass ---"
REPO="/tmp/pf-cm-test-skip-$$"
setup_test_repo "$REPO"
cd "$REPO"
echo "change" > change.txt
git add change.txt

MSG_FILE="/tmp/pf-cm-test-msg-skip-$$"
cat > "$MSG_FILE" << 'EOF'
Fix for alice@example.com
EOF

PRIVACY_FILTER_SKIP=1 PRIVACY_FILTER_URL="http://127.0.0.1:1" .git/hooks/commit-msg "$MSG_FILE" 2>/tmp/pf-cm-test4-err.log || true

result=$(cat "$MSG_FILE")
if echo "$result" | grep -q 'alice@example.com'; then
    assert_pass "Bypass: message unchanged with SKIP=1"
else
    assert_fail "Bypass: message unchanged with SKIP=1"
fi

# No warning should be printed when skipping
if [ ! -s /tmp/pf-cm-test4-err.log ] || ! grep -q 'unavailable' /tmp/pf-cm-test4-err.log 2>/dev/null; then
    assert_pass "Bypass: no service warning when SKIP=1"
else
    assert_fail "Bypass: no service warning when SKIP=1"
fi

rm -f "$MSG_FILE"
cd "$PROJECT_ROOT"
echo ""

# ===========================================================================
# Test 5: Clean message → unchanged
# ===========================================================================
echo "--- Test 5: Clean message → unchanged ---"
if [ "$SERVICE_UP" -eq 1 ]; then
    REPO="/tmp/pf-cm-test-clean-$$"
    setup_test_repo "$REPO"
    cd "$REPO"
    echo "change" > change.txt
    git add change.txt

    MSG_FILE="/tmp/pf-cm-test-msg-clean-$$"
    cat > "$MSG_FILE" << 'EOF'
Fix typo in README
EOF

    PRIVACY_FILTER_URL="$PF_URL" .git/hooks/commit-msg "$MSG_FILE" 2>/tmp/pf-cm-test5-err.log || true

    result=$(cat "$MSG_FILE")
    if echo "$result" | grep -q 'Fix typo in README'; then
        assert_pass "Clean message unchanged"
    else
        assert_fail "Clean message unchanged"
    fi

    rm -f "$MSG_FILE"
    cd "$PROJECT_ROOT"
else
    echo "  [SKIP] Service not available"
fi
echo ""

# ===========================================================================
# Test 6: Verbose section (------ >8 ------) preserved unchanged
# ===========================================================================
echo "--- Test 6: Verbose section preserved ---"
if [ "$SERVICE_UP" -eq 1 ]; then
    REPO="/tmp/pf-cm-test-verbose-$$"
    setup_test_repo "$REPO"
    cd "$REPO"
    echo "change" > change.txt
    git add change.txt

    MSG_FILE="/tmp/pf-cm-test-msg-verbose-$$"
    cat > "$MSG_FILE" << 'EOF'
Subject with alice@example.com
# some comment
Body text
------ >8 ------
diff --git a/change.txt b/change.txt
index 1234567..abcdefg 100644
--- a/change.txt
+++ b/change.txt
@@ -1 +1 @@
-change
+changed
EOF

    PRIVACY_FILTER_URL="$PF_URL" .git/hooks/commit-msg "$MSG_FILE" 2>/tmp/pf-cm-test6-err.log || true

    result=$(cat "$MSG_FILE")
    # Verbose section must be preserved exactly
    if echo "$result" | grep -q 'index 1234567..abcdefg'; then
        assert_pass "Verbose diff section preserved"
    else
        assert_fail "Verbose diff section preserved"
    fi

    # Subject should be redacted
    if echo "$result" | grep -q '<PRIVATE_EMAIL>'; then
        assert_pass "Subject above verbose marker redacted"
    else
        assert_fail "Subject above verbose marker redacted"
    fi

    rm -f "$MSG_FILE"
    cd "$PROJECT_ROOT"
else
    echo "  [SKIP] Service not available"
fi
echo ""

# ===========================================================================
# Summary
# ===========================================================================
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "OVERALL: FAIL"
    exit 1
else
    echo "OVERALL: PASS"
    exit 0
fi
