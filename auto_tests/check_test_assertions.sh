#!/bin/bash
# Guardrail checks for test assertion anti-patterns.
# Usage: ./check_test_assertions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGETS=(
  "test/scenarios"
  "test/scenarios_binary"
  "test/unit_tests"
)

FAILED=0

echo "Running assertion guard checks..."

# --- rg-independent checks run FIRST so they still report if ripgrep is absent ---

# Every test file must be registered in a run_tests_ordered.sh phase array, or
# it silently never runs in ANY tier. Six files were orphaned this way until
# 2026-08-08 (754-line message_history_persistence_test.dart among them).
orphans=""
is_registered_in_phase() {
  local target="$1"
  awk -v target="$target" '
    /^[[:space:]]*PHASE[[:alnum:]_]*[[:space:]]*=[[:space:]]*\([[:space:]]*$/ {
      in_phase = 1
      next
    }
    in_phase && index($0, "\"" target "\"") > 0 {
      found = 1
    }
    in_phase && /^[[:space:]]*\)[[:space:]]*$/ {
      in_phase = 0
    }
    END { exit found ? 0 : 1 }
  ' run_tests_ordered.sh
}

for f in test/scenarios/*_test.dart test/scenarios_binary/*_test.dart test/unit_tests/*.dart; do
  [ -e "$f" ] || continue
  if ! is_registered_in_phase "$f"; then
    orphans="$orphans  $f"$'\n'
  fi
done
if [ -n "$orphans" ]; then
  echo "[FAIL] Every test file is registered in a run_tests_ordered.sh phase"
  printf '%s' "$orphans"
  echo ""
  FAILED=1
else
  echo "[PASS] Every test file is registered in a run_tests_ordered.sh phase"
fi

# The ordered runner spawns Flutter child processes directly, so it must stage
# the built FFI library where flutter_tester's native loader actually searches.
# DYLD_LIBRARY_PATH is stripped/ignored for this macOS test launch path.
if grep -q '^_stage_native_library_for_flutter_tests()' run_tests_ordered.sh &&
   grep -q '^_stage_native_library_for_flutter_tests$' run_tests_ordered.sh &&
   grep -q 'flutter_engine_dir' run_tests_ordered.sh &&
   grep -q 'flutter_tester.exe' run_tests_ordered.sh &&
   grep -q 'linux-arm64' run_tests_ordered.sh &&
   grep -q 'build/ci-macos/ffi' run_tests_ordered.sh &&
   grep -q 'build/ci-windows/ffi/Release' run_tests_ordered.sh &&
   grep -q 'ln -sfn' run_tests_ordered.sh; then
  echo "[PASS] Ordered runner stages the native library for flutter_tester"
else
  echo "[FAIL] Ordered runner stages the native library for flutter_tester"
  FAILED=1
fi

# rg is REQUIRED. Without this guard `hits=$(rg ... || true)` swallowed rg's
# exit 127 ("command not found"), leaving $hits empty, so every check printed
# [PASS] and the script exited 0 — the guard reported success on any machine
# (or CI runner) that had no ripgrep installed.
if ! command -v rg >/dev/null 2>&1; then
  echo "check_test_assertions: ripgrep (rg) not found on PATH." >&2
  echo "  All checks below depend on it; refusing to report a false PASS." >&2
  echo "  Install it (apt install ripgrep / brew install ripgrep) and re-run." >&2
  exit 127
fi

run_check() {
  local name="$1"
  local pattern="$2"

  local hits
  hits=$(rg -n --pcre2 "$pattern" "${TARGETS[@]}" || true)
  if [ -n "$hits" ]; then
    echo "[FAIL] $name"
    echo "$hits"
    echo ""
    FAILED=1
  else
    echo "[PASS] $name"
  fi
}

# Ratchet: a known-bad pattern with a pre-existing population. Fails only when
# the count GROWS past the recorded baseline, so it stops the bleeding without
# blocking on a cleanup that has to happen file by file.
run_ratchet() {
  local name="$1"
  local baseline="$2"
  local pattern="$3"

  # --count-matches (NOT -c): -c counts matching LINES, which undercounts in
  # multiline (-U) mode where one match spans several lines.
  local matches=""
  matches=$(rg -U --pcre2 --count-matches --no-filename "$pattern" "${TARGETS[@]}" 2>/dev/null) || {
    local rg_status=$?
    if [ "$rg_status" -ne 1 ]; then
      echo "[FAIL] $name (ripgrep failed with exit $rg_status)"
      return "$rg_status"
    fi
  }
  local count
  count=$(printf '%s\n' "$matches" | awk '{s+=$1} END {print s+0}')
  if [ "$count" -gt "$baseline" ]; then
    echo "[FAIL] $name (found $count, baseline $baseline)"
    rg -U --pcre2 -n "$pattern" "${TARGETS[@]}" || true
    echo ""
    FAILED=1
  elif [ "$count" -lt "$baseline" ]; then
    echo "[PASS] $name ($count < baseline $baseline — please lower the baseline)"
  else
    echo "[PASS] $name (at baseline $baseline)"
  fi
}

# --- rg-based checks ---

# Tautology: expect(... || true, ...)
run_check "No tautological '|| true' in expect" \
  "expect\\([^;\\n]*\\|\\|\\s*true"

# Tautology: expect(x == 0 || x != 0, isTrue)
run_check "No tautological '==0 || !=0' checks in expect" \
  "expect\\([^;\\n]*==\\s*0\\s*\\|\\|\\s*[^;\\n]*!=\\s*0"

# Tautology: expect(x != 0 || x == 0, isTrue)
run_check "No tautological '!=0 || ==0' checks in expect" \
  "expect\\([^;\\n]*!=\\s*0\\s*\\|\\|\\s*[^;\\n]*==\\s*0"

# Empty catch blocks swallow failures.
run_check "No empty catch blocks" \
  "catch\\s*\\([^\\)]*\\)\\s*\\{\\s*\\}"

# Empty catchError handlers swallow failures.
run_check "No empty catchError handlers" \
  "catchError\\(\\s*\\([^\\)]*\\)\\s*\\{\\s*\\}\\s*\\)"

# The "no empty catch blocks" rule above requires literally nothing between the
# braces, so `catch (_) { // retry — request may have been dropped }` sails past
# it. That comment-only form is the shape actually used in this suite, and it
# swallows real failures exactly the same way. Ratcheted at the 2026-08-08 count.
run_ratchet "No NEW comment-only catch blocks" 36 \
  "catch\\s*\\([^\\)]*\\)\\s*\\{(?:\\s*//[^\\n]*\\n)*\\s*\\}"

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "Assertion guard checks failed."
  exit 1
fi

echo ""
echo "All assertion guard checks passed."
