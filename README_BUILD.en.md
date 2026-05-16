# Build Guide
> Language: [Chinese](README_BUILD.md) | [English](README_BUILD.en.md)

## Quick start

### Build the FFI library (smart build, **preferred**)

```bash
./build_ffi.sh
```

This script:
- ✅ Only builds when needed (library missing or sources newer)
- ✅ Auto-configures CMake when needed
- ✅ Enables `BUILD_TOXAV`, `DHT_BOOTSTRAP`, and `BOOTSTRAP_DAEMON` (required by `auto_tests` when using local bootstrap)
- ✅ Verifies that the `Dart_PostCObject_DL` symbol is exported

Output: `build/ffi/libtim2tox_ffi.dylib` (macOS) / `build/ffi/libtim2tox_ffi.so` (Linux).

### Run the tests (auto-builds)

```bash
cd auto_tests
./run_tests.sh                 # simple run with per-test timing
./run_tests_ordered.sh         # recommended: run Phase 1-14 in order, 180 s timeout per test
```

The test scripts call `./build_ffi.sh` internally and only rebuild when necessary. Details in [auto_tests/README.en.md](auto_tests/README.en.md).

## Build options

### 1. Incremental FFI build (preferred)

```bash
./build_ffi.sh
```

**Characteristics**:
- Builds only when source / CMake files are newer than the library.
- Configures with `BUILD_TOXAV=ON`, `MUST_BUILD_TOXAV=ON`, `DHT_BOOTSTRAP=ON`, `BOOTSTRAP_DAEMON=ON`, `BUILD_FFI=ON`, `ENABLE_STATIC=ON`, `ENABLE_SHARED=OFF`, `USE_IPV6=ON`, `CMAKE_BUILD_TYPE=Release`.
- Only builds the `tim2tox_ffi` target (does not build `libtim2tox.a` or the examples).
- On macOS, auto-discovers Homebrew-installed `opus`, `libvpx`, `libconfig`, etc.

### 2. Basic static-library build (`build.sh`)

```bash
bash build.sh
```

**Characteristics**:
- Full configure + `make -j$(sysctl -n hw.ncpu)`, but **turns off** ToxAV / DHT_bootstrap / Bootstrap daemon (note the `-DBUILD_TOXAV=OFF -DDHT_BOOTSTRAP=OFF -DBOOTSTRAP_DAEMON=OFF` flags at the top of the script).
- Produces static libraries such as `build/source/libtim2tox.a`; does not specifically build `tim2tox_ffi` (even though `BUILD_FFI` defaults to ON).
- Use it when running C++ unit tests, building examples, or producing static artifacts in environments that don't need calling.

> **Important difference**: `build.sh` is **not** a "full build". If you need AV calls or the local Bootstrap (`auto_tests`), use `./build_ffi.sh`.

### 3. Force a rebuild

```bash
rm -rf build
./build_ffi.sh
```

Or just nuke the library file:

```bash
rm -f build/ffi/libtim2tox_ffi.dylib build/ffi/libtim2tox_ffi.so
./build_ffi.sh
```

### 4. Test scripts

| Script | Purpose |
|--------|---------|
| `auto_tests/run_tests.sh [pattern]` | Simple run with optional name filter; auto-builds. |
| `auto_tests/run_tests_ordered.sh [PHASE...]` | Run Phase 1-14 in order with 180 s per-test timeout; recommended entry. |
| `auto_tests/run_all_tests.sh` | Compatibility wrapper around `run_tests_ordered.sh`. |
| `auto_tests/run_tests_with_lib.sh` | Variant that explicitly sets `DYLD_LIBRARY_PATH` for non-default builds. |
| `auto_tests/run_group_tests.sh` | Alias for the group-related phases. |
| `auto_tests/run_conversation_test_with_lldb.sh` / `run_pin_test_with_lldb.sh` | Run a single scenario under lldb for capturing native stack traces. |

## Skip / rebuild logic

`build_ffi.sh` rebuild conditions:

1. **Library file missing** → build
2. **Any FFI source (`ffi/*.cpp/*.h/*.hpp`) newer than the library** → rebuild
3. **`ffi/CMakeLists.txt` newer than the library** → rebuild
4. **`CMakeCache.txt` missing or required options absent** → re-configure
5. Otherwise → skip

## Verify the build

```bash
ls -la build/ffi/libtim2tox_ffi.dylib   # macOS
ls -la build/ffi/libtim2tox_ffi.so      # Linux

# Verify Dart_PostCObject_DL is exported (the script does this automatically)
nm -g build/ffi/libtim2tox_ffi.dylib | grep Dart_PostCObject_DL
```

## FAQ

### How do I force a rebuild?
```bash
rm -rf build
./build_ffi.sh
```

### Build failed — now what?
1. Delete the entire `build/` and rebuild.
2. Scroll through terminal output and find the first `error:` (CMake output is long; the first error is usually root cause).
3. On macOS, if `opus` / `libvpx` are missing: `brew install opus libvpx libconfig libsodium`.
4. On Linux, if `sodium` is missing: `sudo apt install libsodium-dev` (or your distro's equivalent).

### How do I just build the FFI lib?
Run `./build_ffi.sh`.

### Where are the build logs?
Build logs go straight to stdout/stderr in your terminal. The scripts do not write a `build.log`. If you want one: `./build_ffi.sh 2>&1 | tee build.log`.

## Reference timings

- **First build**: 5-15 minutes (depending on machine and toolchain)
- **Incremental build**: 1-5 minutes
- **No changes**: < 1 s (skipped)

## Related files

- `build_ffi.sh` — incremental FFI build (preferred)
- `build.sh` — basic static-library build (no ToxAV / DHT_bootstrap)
- `CMakeLists.txt` — top-level CMake config
- `ffi/CMakeLists.txt` — FFI subproject
- `auto_tests/run_tests.sh` / `run_tests_ordered.sh` / ... — test scripts
