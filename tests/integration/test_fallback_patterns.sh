#!/usr/bin/env bash
# Unit checks for hooks/pf_fallback.py regex coverage. Runs the fallback
# directly (no git machinery) and asserts which placeholders appear / don't.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fallback="$ROOT_DIR/hooks/pf_fallback.py"

# run_fallback <text> : print the redacted_text the fallback produces.
run_fallback() {
  local text="$1"
  printf '%s' "$text" \
    | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))' \
    | python3 "$fallback" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["redacted_text"])'
}

expect_present() {
  local text="$1" needle="$2" out
  out="$(run_fallback "$text")"
  if ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: expected placeholder $needle for input: $text" >&2
    echo "  got: $out" >&2
    exit 1
  fi
}

expect_absent() {
  local text="$1" needle="$2" out
  out="$(run_fallback "$text")"
  if grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: did not expect placeholder $needle for input: $text" >&2
    echo "  got: $out" >&2
    exit 1
  fi
}

# Baseline categories still work.
expect_present 'contact alice@example.com here' '<PRIVATE_EMAIL>'
expect_present 'phone 555-123-4567' '<PRIVATE_PHONE>'

# Newly covered secret families.
google_key="AIza$(python3 -c "print('A'*35)")"          # AIza + 35 = real 39-char key
stripe_key="sk_live_$(python3 -c "print('a'*24)")"      # sk_live_ + 24
expect_present "ref = \"${google_key}\"" '<SECRET>'
expect_present "ref = \"${stripe_key}\"" '<SECRET>'
expect_present 'ref = "AKIAABCDEFGHIJKLMNOP"' '<SECRET>'   # AWS access key id (AKIA + 16)

# All-same-digit runs are not real cards — must NOT be redacted (FP guard).
expect_absent 'ref = "0000000000000000"' '<ACCOUNT_NUMBER>'
expect_absent 'ref = "4444444444444444"' '<ACCOUNT_NUMBER>'
# Positive control: a real Luhn-valid card is still redacted.
expect_present 'card = "4111111111111111"' '<ACCOUNT_NUMBER>'

echo "PASS test_fallback_patterns"
