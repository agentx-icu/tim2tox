# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**Tim2Tox** is a reusable **compatibility layer / framework** that lets a V2TIM-style caller (Tencent Cloud Chat UIKit, or any client built against `tencent_cloud_chat_sdk`) run against the **Tox P2P network** instead of Tencent Cloud IM. It is *not* a finished client and *not* a thin Tox protocol wrapper — it implements V2TIM semantics (login, messages, friends, groups, conversations, signaling) on top of `c-toxcore` and preserves the native SDK's callback JSON contract so existing listeners and UI code keep working.

The canonical integrating client is [`toxee`](https://github.com/anonymoussoft/toxee), which vendors this repo at `third_party/tim2tox`. **Tim2Tox does not depend on toxee.** Anything client-specific (account model, UI, FakeUIKit, persistence wiring) belongs in toxee, not here.

Authoritative architecture deep-dive: `doc/architecture/ARCHITECTURE.en.md`. FFI/binary-replacement boundary: `doc/architecture/FFI_COMPAT_LAYER.en.md` and `doc/architecture/BINARY_REPLACEMENT.en.md`. Build doc: `README_BUILD.md`.

## Architecture — the one thing to internalize

There are **two coexisting call paths** from the Flutter/UIKit side down into Tim2Tox. They share the same C++ core and Tox instance — they only differ in how Dart reaches the FFI:

1. **Binary-replacement path** — App calls `setNativeLibraryName('tim2tox_ffi')`, then the SDK keeps doing `NativeLibraryManager → bindings.DartXXX(...)`. Tim2Tox implements those `Dart*` symbols in `ffi/dart_compat_*.cpp` (e.g. `dart_compat_sdk.cpp`, `dart_compat_message.cpp`, …). Signatures must stay byte-compatible with `native_imsdk_bindings_generated.dart` — that is the whole point of the layer.
2. **Platform path** — Client installs `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)`. Calls flow `Tim2ToxSdkPlatform → FfiChatService → Tim2ToxFfi → tim2tox_ffi_*` C API. Used for things that can't live purely in C++: **history (`getHistoryMessageList*`), `clearHistoryMessage`, conversation list, Bootstrap node management, polling, signaling/calling glue, multi-instance routing**.

Both entry points meet at the C FFI layer (`libtim2tox_ffi`) and call into the **same** `V2TIMManagerImpl` / `ToxManager` / `c-toxcore` stack underneath. When a client uses both (toxee does), avoid double-writing history or double-firing the same callback — toxee mediates this via `BinaryReplacementHistoryHook`; the equivalent helper lives at `dart/lib/utils/binary_replacement_history_hook.dart` and is exported from this package.

### Callback contract (do not casually change)

C++ delivers events to Dart via `callback_bridge.cpp` → `SendCallbackToDart(callback_type, json_data, user_data)` → a registered `SendPort`. The JSON shape (`callback`, `callbackType`, `user_data`, `code`, `desc`, …) must match what Dart's `NativeLibraryManager._handleNativeMessage` expects — that is the contract that lets unmodified listeners receive events. JSON construction lives in `ffi/json_parser.cpp`; the `nlohmann` variant is gated behind `json_parser_nlohmann.cpp.example` and not currently built.

### FFI boundary rules

- The boundary is **C only** — no C++ types, exceptions, references, or smart pointers cross it.
- Strings/buffers are either caller-allocated (Dart provides a buffer + capacity, C writes and returns bytes-written) or returned as `const char*` owned by C with a documented lifetime.
- Return convention is typically `int32_t`: `1 = ok`, `0 = failure`. Async results come back via the SendPort callback bridge.
- `Dart_PostCObject_DL` must be exported from `libtim2tox_ffi.dylib`. `build_ffi.sh` verifies this with `nm -g | grep`.

### History ownership

C++ does **not** persist message history. Persistence lives entirely on the Dart side in `dart/lib/utils/message_history_persistence.dart`. Both paths feed it: the Platform path writes through `FfiChatService`; the binary-replacement path writes through `BinaryReplacementHistoryHook` which wraps `V2TimAdvancedMsgListener`. Don't add a C++ history store — that's a layering violation.

### Multi-instance

`Tim2ToxInstance` (`dart/lib/instance/tim2tox_instance.dart`) and `tim2tox_ffi_*` instance-scoped APIs exist primarily for `auto_tests/` to run many simulated peers in one process. Production clients use the default singleton. The `runWithInstance` / `runWithInstanceAsync` pattern in test code is for routing manager calls to the right instance — see `auto_tests/test/test_helper.dart` (`TestNode`). Don't design production features around multi-instance.

## Layout — by responsibility

- `source/` — C++ core. `V2TIMManagerImpl`, `V2TIMMessageManagerImpl`, `V2TIMFriendshipManagerImpl`, `V2TIMGroupManagerImpl`, `V2TIMConversationManagerImpl`, `V2TIMSignalingManagerImpl`, `ToxManager`, `ToxAVManager`. Knows nothing about Dart or Platform.
- `include/` — V2TIM-style C++ headers (public API surface of the C++ core).
- `ffi/` — C FFI. `tim2tox_ffi.{h,cpp}` is the high-level C API used by the Platform path; `dart_compat_layer.cpp` + `dart_compat_*.cpp` are the `Dart*` symbols used by the binary-replacement path. `callback_bridge.{h,cpp}` and `json_parser.{h,cpp}` are shared by both. The compat layer was split out of a 3200-line file into 13 modules (see `doc/architecture/MODULARIZATION.en.md`) — keep that split when adding new categories.
- `dart/lib/` — Dart package `tim2tox_dart` (path-dep'd by integrators).
  - `ffi/tim2tox_ffi.dart` — raw `dart:ffi` bindings (`Tim2ToxFfi`).
  - `service/ffi_chat_service.dart` — `FfiChatService`, the Platform-path callee. Owns init, login, polling, send, history, streams, instance registration.
  - `service/` also holds the call-bridge / TUICallKit glue (`call_bridge_service.dart`, `tuicallkit_*.dart`, `toxav_service.dart`, `av_codec_service.dart`).
  - `sdk/tim2tox_sdk_platform.dart` — `Tim2ToxSdkPlatform` implementing `TencentCloudChatSdkPlatform`. Routes SDK calls to `FfiChatService`.
  - `interfaces/` — injected interfaces (`PreferencesService`, `ExtendedPreferencesService`, `LoggerService`, `BootstrapService`, `EventBus`, `EventBusProvider`, `ConversationManagerProvider`). Clients implement these — Tim2Tox provides no concrete impls.
  - `utils/` — `MessageHistoryPersistence`, `BinaryReplacementHistoryHook`, `MessageConverter`, `OfflineMessageQueuePersistence`, `Tim2ToxFailedMessagePersistence`, `MessageIdGenerator`, `ConversationIdUtils`.
  - `instance/` — `Tim2ToxInstance` (multi-instance context).
  - `models/` — `ChatMessage`, fake UIKit models.
  - `tim2tox_dart.dart` is the public barrel.
- `third_party/c-toxcore` — vendored Tox protocol implementation. CMake guards against double-add with `if(NOT TARGET toxcore_static)`.
- `auto_tests/` — Dart/Flutter scenario suite. 74 scenario files (73 mode-aware + 1 virtual-clock smoke). Each scenario is a **single file** that runs wall-clock by default and virtual-clock under `RUN_VIRTUAL=1` (it reads `shouldRunVirtual` and gates `VirtualClock.enableEarly/enableForScenario`; the `*Virtual` body helpers fall back to real-time when the clock is off). There are no `*_virtual_test.dart` siblings. Borrows test-case design from `c-toxcore/auto_tests/`. See `auto_tests/README.md` and `auto_tests/VIRTUAL_CLOCK.md`.
- `test/` — small C++ unit tests (`ToxUtilTest.cpp`, `V2TIMMessageTest.cpp`, `V2TIMStringTest.cpp`), gated by `-DTIM2TOX_BUILD_TESTS=ON`.
- `example/` — standalone C/C++ usage examples (echo bot, client). Not part of the Flutter integration path.
- `doc/` — canonical documentation; new design docs go here. Most pages are bilingual (`*.md` Chinese + `*.en.md` English).
- `patches/tencent_cloud_chat_sdk/` — patches the integrator applies to a vendored copy of the Tencent SDK. Used by toxee's `bootstrap_deps.dart`. **Editing a patch here is a cross-repo change** — verify the resulting patched SDK still compiles and still matches the `Dart*` signatures Tim2Tox implements.
- `tool/apply_sdk_patches.dart` + `tool/tencent_cloud_chat_sdk.lock.json` — pins the SDK version the patches are written against.

## Build

Day-to-day FFI build (incremental, only rebuilds when sources are newer):

```bash
./build_ffi.sh
# Produces build/ffi/libtim2tox_ffi.dylib (macOS), with toxav + DHT_bootstrap enabled.
# Verifies Dart_PostCObject_DL is exported.
```

Full build from scratch (no toxav, no bootstrap daemon — used for the static C++ core / tests):

```bash
bash build.sh
# build/source/libtim2tox.a + dependent toxcore static libs.
```

Force rebuild:

```bash
rm -rf build && ./build_ffi.sh
```

CMake options that matter (see `CMakeLists.txt`):

- `BUILD_FFI=ON` (default) — build `libtim2tox_ffi`. The Flutter side requires this.
- `BUILD_TOXAV=ON`, `MUST_BUILD_TOXAV=ON` — `build_ffi.sh` turns these on; `build.sh` turns them off. Calling features need toxav.
- `DHT_BOOTSTRAP=ON`, `BOOTSTRAP_DAEMON=ON` — `build_ffi.sh` turns these on so local bootstrap nodes work in `auto_tests/`.
- `ENABLE_SHARED=OFF`, `ENABLE_STATIC=ON` — `libtim2tox.a` is static; only the FFI shim is shared.
- `TIM2TOX_BUILD_TESTS=ON` — opt-in C++ test suite under `test/`.
- `TIM2TOX_DEP_PREFIX=<path>` — non-Homebrew dep prefix (`include/`, `lib/`).
- C++20, C11, `-fPIC`, `CMAKE_EXPORT_COMPILE_COMMANDS=ON`.

Version is generated from `source/version.h.in` → `build/generated/version.h` at configure time. The `project(... VERSION ...)` line in `CMakeLists.txt` is the single source of truth — don't hard-code versions elsewhere.

Dart package:

```bash
cd dart && flutter pub get
```

Integrators consume `dart/` via path dependency on `tim2tox_dart`; they additionally vendor and patch `tencent_cloud_chat_sdk` (the patches live in `patches/tencent_cloud_chat_sdk/`).

## Tests

C++ unit tests (small, gated by `-DTIM2TOX_BUILD_TESTS=ON`):

```bash
cmake -S . -B build-tests -DTIM2TOX_BUILD_TESTS=ON
cmake --build build-tests
ctest --test-dir build-tests
```

Dart/Flutter scenario suite (the primary regression gate):

```bash
cd auto_tests
./run_tests.sh                                     # all tests; auto-builds the FFI lib if needed
./run_tests.sh 'scenario_message'                  # name filter (passes through to `flutter test --name`)
./run_tests_ordered.sh                             # phases 1–14 in complexity order, 180s timeout/test
./run_tests_ordered.sh 4                           # single phase
./run_tests_ordered.sh 5,6                         # comma list
./run_tests_ordered.sh 7-9                         # range
RUN_VIRTUAL=1 ./run_tests_ordered.sh               # virtual-clock mode: each mode-aware scenario self-selects via shouldRunVirtual, dramatically faster
./run_tests_ordered.sh --merge-output 13           # merge logs to merged_results/ for one phase
```

Phases are: 1 BASIC · 2 FRIENDSHIP · 3 MESSAGE · 4 GROUP · 5 TOXAV · 6 PROFILE · 7 CONVERSATION · 8 FILE · 9 CONFERENCE · 10 GROUP_EXT · 11 NETWORK · 12 OTHER · 13 BINARY (binary-replacement-path scenarios in `scenarios_binary/`) · 14 UNIT (`unit_tests/`).

Single test by file:

```bash
cd auto_tests
flutter test test/scenarios/scenario_message_test.dart
```

### Virtual clock mode — why it exists

Tox protocol timers run in seconds (60s DHT ping, 122s BAD_NODE, 10s onion path…). Wall-clock `setUpAll` for multi-node scenarios can take tens of seconds. Virtual mode replaces Tox's `mono_time` source with a process-shared clock driven from Dart (`pumpTestTick(scenario, ...)` advances time + manually iterates each instance), so an effective "advance 60 seconds" lands in milliseconds. UDP loopback still uses wall time, so a small `wallSleep` inside `pumpTestTick` is intentional.

Phase 13 (binary-replacement) and Phase 14 (unit tests) don't touch Tox timers and have **no** virtual variants. For everything else, prefer running with `RUN_VIRTUAL=1` locally. A test that's flaky under wall-clock will remain flaky under virtual — that's a protocol-layer bug, not a clock-mode bug.

When writing a virtual variant: see `auto_tests/VIRTUAL_CLOCK.md` (canonical `setUpAll` template, `*Virtual` replacement table, group-invite retry pattern).

### Test instance discipline

In multi-node scenarios (alice, bob, …) **every** call into a `TIM*Manager` must run inside the right node's instance context, or it will hit the wrong instance and fail with `ToxManager not initialized`. Wrap caller and listener registration with the node's `runWithInstance` / `runWithInstanceAsync`. Use `bob.getToxId()` (the 76-char Tox ID), not `bob.userId`, as the C2C receiver.

## Constraints worth remembering

- **`Dart*` signatures are an ABI** — when adding or modifying a `dart_compat_*.cpp` function, the matching declaration in the integrator's `native_imsdk_bindings_generated.dart` (patched-Tencent-SDK side) must stay in sync. A signature drift will compile fine and crash at call time with a wrong-argument-count or stack-corruption symptom.
- **Callback JSON shape is an ABI** — same reasoning. If you add a new callback type, mirror the field names the unmodified Tencent SDK would have produced. Look at `json_parser.cpp` for existing precedents before inventing new fields.
- **No C++ leaks across the FFI boundary** — if a C function returns memory, document who frees it and how. `pkgffi.Utf8` strings allocated by Dart must be freed by Dart; buffers passed in by Dart must not be retained past the call.
- **C++ has no history store** — see "History ownership" above. Don't add one.
- **Single CMake graph** — `third_party/c-toxcore` is added with a `TARGET` guard. Don't re-`add_subdirectory()` it from inside `source/` or `ffi/`.
- **Bilingual docs** — the canonical document is `doc/.../X.md` (Chinese); `X.en.md` is the English mirror. When editing one, update the other or note divergence at the top.
- **macOS / desktop first** — iOS/Android FFI loading paths are the integrator's problem (toxee handles them in `build_all.sh`). Don't assume mobile-specific build glue here.
- **`build_ffi.sh` toggles options that `build.sh` doesn't** — if you ran `build.sh` first and then `build_ffi.sh` complains about a stale `CMakeCache.txt`, that's by design: `build_ffi.sh` detects the missing `BUILD_TOXAV=ON` / `DHT_BOOTSTRAP=ON` and reconfigures. Don't paper over it by deleting checks in the script.
