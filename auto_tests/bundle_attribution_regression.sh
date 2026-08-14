#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/bundle_attribution.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tim2tox-bundle-attribution.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

assert_rows() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s\nexpected:\n%s\nactual:\n%s\n' \
      "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_counts() {
  local name="$1"
  local rows="$2"
  local expected_failed="$3"
  local expected_passed="$4"
  local failed passed
  failed=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "FAILED" {n++} END {print n + 0}')
  passed=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "PASSED" {n++} END {print n + 0}')
  if [ "$failed" -ne "$expected_failed" ] || [ "$passed" -ne "$expected_passed" ]; then
    printf 'FAIL: %s (failed=%s passed=%s)\n' "$name" "$failed" "$passed" >&2
    exit 1
  fi
}

ATTRIBUTED_LOG="$TMP_DIR/attributed.log"
cat > "$ATTRIBUTED_LOG" <<'EOF'
00:01 +0 -1: /tmp/fake/test/scenario_attributed_test.dart: group test [E]
EOF

ROWS=$(bundle_attribution_rows 17 "$ATTRIBUTED_LOG" \
  "test/scenarios/scenario_attributed_test.dart" \
  "test/scenarios/scenario_unreached_test.dart")
assert_rows "attributed failure plus unmentioned input" "$ROWS" \
  $'FAILED\tscenario_attributed_test\tBUNDLE\nFAILED\tscenario_unreached_test\tBUNDLE UNRESOLVED exit=17'
assert_counts "attributed failure plus unmentioned input" "$ROWS" 2 0

ROWS=$(bundle_attribution_rows 124 "$ATTRIBUTED_LOG" \
  "test/scenarios/scenario_attributed_test.dart" \
  "test/scenarios/scenario_unreached_test.dart")
assert_rows "timeout keeps timeout label" "$ROWS" \
  $'FAILED\tscenario_attributed_test\tBUNDLE\nFAILED\tscenario_unreached_test\tBUNDLE TIMEOUT'
assert_counts "timeout keeps timeout label" "$ROWS" 2 0

UNATTRIBUTED_LOG="$TMP_DIR/unattributed.log"
cat > "$UNATTRIBUTED_LOG" <<'EOF'
00:02 +0 -1: bundle process exited before any file reached terminal output
EOF

ROWS=$(bundle_attribution_rows 23 "$UNATTRIBUTED_LOG" \
  "test/scenarios/scenario_first_test.dart" \
  "test/scenarios/scenario_second_test.dart")
assert_rows "zero attributed failures keeps unattributed label" "$ROWS" \
  $'FAILED\tscenario_first_test\tBUNDLE UNATTRIBUTED exit=23\nFAILED\tscenario_second_test\tBUNDLE UNATTRIBUTED exit=23'
assert_counts "zero attributed failures keeps unattributed label" "$ROWS" 2 0

printf 'PASS: bundle attribution regression (all cases: 6 failed, 0 passed)\n'
