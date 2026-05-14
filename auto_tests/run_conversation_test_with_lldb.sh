#!/usr/bin/env bash
# Run scenario_conversation_test under lldb so that when native code (libtim2tox_ffi.dylib)
# crashes, lldb stops and you can inspect the native stack and variables.
#
# Usage:
#   ./run_conversation_test_with_lldb.sh
#
# When SIGSEGV happens, lldb will stop. Then run:
#   (lldb) bt          # native backtrace
#   (lldb) frame variable
#   (lldb) frame select 0  # then frame variable for that frame
#
# Note: "flutter" is a script, not a Mach-O binary, so lldb cannot load it directly.
# We start "flutter test" in background, then attach lldb to the flutter_tester process.

set -e
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this debug script is macOS-only (lldb + flutter_tester Mach-O)."
  echo "       Got OS: $(uname -s). Use platform-native debugger tooling for non-Darwin hosts."
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v flutter &>/dev/null; then
  echo "Error: flutter not in PATH. Add Flutter SDK to PATH and retry."
  exit 1
fi

echo "Starting flutter test in background..."
flutter test test/scenarios/scenario_conversation_test.dart &
FLUTTER_PID=$!

# Wait for flutter_tester to appear (flutter script may spawn dart then flutter_tester)
echo "Waiting for flutter_tester process..."
for i in {1..25}; do
  sleep 1
  TESTER_PID=$(pgrep -f flutter_tester 2>/dev/null | head -1)
  if [[ -n "$TESTER_PID" ]]; then
    break
  fi
done

if [[ -z "$TESTER_PID" ]]; then
  echo "Error: flutter_tester process not found. Test may have finished or failed to start."
  wait "$FLUTTER_PID" 2>/dev/null || true
  exit 1
fi

echo "Attaching lldb to flutter_tester (PID $TESTER_PID)..."
echo "When crash happens, run: bt   then   frame variable"
exec lldb -o "continue" -p "$TESTER_PID"
