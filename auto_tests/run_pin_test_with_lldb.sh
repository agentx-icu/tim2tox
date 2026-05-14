#!/usr/bin/env bash
# Run scenario_conversation_pin_test under lldb; on SIGSEGV run "bt" and save to lldb_pin_crash.log.
# Usage: ./run_pin_test_with_lldb.sh
# Then inspect lldb_pin_crash.log for native backtrace.
#
# macOS-only: uses lldb + the darwin-x64 Flutter engine cache layout. On
# Linux, use a gdb-based equivalent (not provided); on Windows, attach the
# Visual Studio debugger to flutter_tester.exe instead.

set -e
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this debug script is macOS-only (relies on lldb + darwin-x64 Flutter engine cache layout)."
  echo "       Got OS: $(uname -s). Use platform-native debugger tooling for non-Darwin hosts."
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Build lib and set up symlink (same as run_tests_with_lib.sh)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIM2TOX_DIR="$PROJECT_ROOT/tim2tox"
LIB_SOURCE="$TIM2TOX_DIR/build/ffi/libtim2tox_ffi.dylib"
if [[ -f "$TIM2TOX_DIR/build_ffi.sh" ]]; then
  echo "Building library if needed..."
  "$TIM2TOX_DIR/build_ffi.sh"
fi
FLUTTER_EXE=$(which flutter)
FLUTTER_BIN_DIR=$(dirname "$FLUTTER_EXE")
FLUTTER_ENGINE_DIR="$FLUTTER_BIN_DIR/cache/artifacts/engine/darwin-x64"
if [[ -f "$LIB_SOURCE" && -d "$FLUTTER_ENGINE_DIR" ]]; then
  ln -sf "$LIB_SOURCE" "$FLUTTER_ENGINE_DIR/libtim2tox_ffi.dylib" 2>/dev/null || true
fi

if ! command -v flutter &>/dev/null; then
  echo "Error: flutter not in PATH."
  exit 1
fi

CRASH_LOG="$SCRIPT_DIR/lldb_pin_crash.log"
echo "Pin test crash log will be written to: $CRASH_LOG"

echo "Starting flutter test (pin) in background..."
flutter test --no-pub test/scenarios/scenario_conversation_pin_test.dart &
FLUTTER_PID=$!

echo "Waiting for flutter_tester process..."
for i in {1..30}; do
  sleep 1
  TESTER_PID=$(pgrep -f "flutter_tester.*scenario_conversation_pin" 2>/dev/null | head -1)
  [[ -z "$TESTER_PID" ]] && TESTER_PID=$(pgrep -f flutter_tester 2>/dev/null | head -1)
  if [[ -n "$TESTER_PID" ]]; then
    break
  fi
done

if [[ -z "$TESTER_PID" ]]; then
  echo "Error: flutter_tester not found."
  wait "$FLUTTER_PID" 2>/dev/null || true
  exit 1
fi

echo "Attaching lldb to flutter_tester (PID $TESTER_PID). On SIGSEGV, bt will be run and saved to $CRASH_LOG"
{
  echo "=== lldb attach PID $TESTER_PID ==="
  echo "=== When process stops (e.g. SIGSEGV), backtrace follows ==="
} > "$CRASH_LOG"

# When continue returns (process stopped), run bt and thread backtrace all, then quit.
# Use -batch so lldb doesn't wait for user input; after "continue" returns we run bt.
lldb -p "$TESTER_PID" \
  -o "continue" \
  -o "bt" \
  -o "thread backtrace all" \
  -o "process kill" \
  -o "quit" 2>&1 | tee -a "$CRASH_LOG"

wait "$FLUTTER_PID" 2>/dev/null || true
echo "Done. Check $CRASH_LOG for native backtrace."
