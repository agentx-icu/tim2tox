#!/bin/bash
# Run tests with native library path configured.
# Automatically builds the library if needed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIM2TOX_DIR="$PROJECT_ROOT/tim2tox"

# Pick the correct shared-library filename and the matching Flutter engine
# cache subdirectory for the host OS. dlopen on each platform expects a
# different extension, and the cache is laid out under arch-specific dirs.
case "$(uname -s)" in
  Darwin)
    LIB_NAME="libtim2tox_ffi.dylib"
    if [[ "$(uname -m)" == "arm64" ]]; then
      FLUTTER_ENGINE_ARCH="darwin-arm64"
    else
      FLUTTER_ENGINE_ARCH="darwin-x64"
    fi
    ;;
  Linux)
    LIB_NAME="libtim2tox_ffi.so"
    FLUTTER_ENGINE_ARCH="linux-x64"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    LIB_NAME="tim2tox_ffi.dll"
    FLUTTER_ENGINE_ARCH="windows-x64"
    ;;
  *)
    echo "Warning: unrecognized OS $(uname -s); defaulting to Darwin layout."
    LIB_NAME="libtim2tox_ffi.dylib"
    FLUTTER_ENGINE_ARCH="darwin-x64"
    ;;
esac

LIB_SOURCE="$TIM2TOX_DIR/build/ffi/$LIB_NAME"

# Build library if needed (smart build - only rebuilds if necessary)
if [[ -f "$TIM2TOX_DIR/build_ffi.sh" ]]; then
    echo "Checking if library needs to be built..."
    "$TIM2TOX_DIR/build_ffi.sh"
else
    echo "Warning: build_ffi.sh not found. Skipping automatic build."
fi

# Find Flutter executable directory
FLUTTER_EXE=$(which flutter)
FLUTTER_BIN_DIR=$(dirname "$FLUTTER_EXE")
FLUTTER_ENGINE_DIR="$FLUTTER_BIN_DIR/cache/artifacts/engine/$FLUTTER_ENGINE_ARCH"

# Create symlink in Flutter engine directory (where dlopen searches)
if [[ -f "$LIB_SOURCE" && -d "$FLUTTER_ENGINE_DIR" ]]; then
  ln -sf "$LIB_SOURCE" "$FLUTTER_ENGINE_DIR/$LIB_NAME" 2>/dev/null || true
  echo "Created symlink: $FLUTTER_ENGINE_DIR/$LIB_NAME -> $LIB_SOURCE"
else
  echo "Warning: Library not found at $LIB_SOURCE or Flutter engine dir not found ($FLUTTER_ENGINE_DIR)"
fi

# Change to test directory
cd "$SCRIPT_DIR"

# Run tests
flutter test --no-pub "$@"

# Note: We don't remove the symlink as it might be used by other tests
