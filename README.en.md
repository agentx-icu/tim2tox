# Tim2Tox

> Language: [Chinese](README.md) | [English](README.en.md)

---

## Project positioning

**Tim2Tox** is a **reusable compatibility layer / framework** that connects **Tencent Cloud Chat UIKit** with **Tox**. It lets existing Flutter chat UI and business logic built on the Tencent Cloud IM SDK (V2TIM) switch to the Tox P2P network **without changing UI or call patterns**.

**Definition**:

- **It is**: A reusable compatibility layer/framework—providing a C++ core, C FFI, Dart bindings, and SDK Platform integration for any Flutter client to integrate.
- **It is not**: The final client application (no full app, account system, or product UI).
- **It is not**: A thin Tox protocol wrapper (it also implements V2TIM semantic mapping, callback bridging, history, polling, and other capabilities required to plug into UIKit).

---

## Problem it solves

**Core compatibility problem**: UIKit and business code expect **V2TIM-style** calls (e.g. `TIMManager.instance.login()`, `getMessageManager().sendMessage()`) and the **native SDK callback format** (e.g. `apiCallback` / `globalCallback` JSON). Switching directly to Tox would require rewriting a lot of logic and UI. Tim2Tox implements V2TIM semantics at the **protocol layer** and keeps the callback contract so that:

- Callers still use `TIMManager`, various Managers, Listeners, etc. as before;
- The bottom layer actually performs Tox init, login, send message, friends/groups, etc.;
- Events are delivered back to Dart in the existing callback/JSON format, so listeners and UI do not need to change for the protocol layer.

In short: **It solves the compatibility problem of “replacing the cloud IM backend with Tox P2P while keeping UIKit call and callback conventions.”**

---

## Architecture overview

The stack is split into four layers from bottom to top. **Two call entry points** meet at the C FFI layer and share the same C++ implementation and Tox core.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Flutter / UIKit application layer                                        │
│  Callers: TIMManager.instance / TencentCloudChatSdkPlatform.instance     │
└─────────────────────────────┬─────────────────────────────────────────────┘
                              │
    ┌─────────────────────────┴─────────────────────────┐
    │  Dart layer (tim2tox_dart)                         │
    │  Tim2ToxSdkPlatform → FfiChatService → Tim2ToxFfi  │  (Platform path)
    │  or NativeLibraryManager → bindings.Dart*()        │  (Binary replacement path)
    └─────────────────────────────┬─────────────────────────────────────────┘
                                  │
┌─────────────────────────────────┴─────────────────────────────────────────┐
│  C FFI layer (libtim2tox_ffi)                                               │
│  tim2tox_ffi_* (high-level API)  │  Dart* (dart_compat_*) compat layer     │
└─────────────────────────────┬─────────────────────────────────────────────┘
                              │
┌─────────────────────────────┴─────────────────────────────────────────┐
│  C++ core (source/)                                                     │
│  V2TIMManagerImpl, V2TIMMessageManagerImpl, ToxManager, ...             │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │
┌─────────────────────────────┴─────────────────────────────────────────┐
│  c-toxcore (P2P protocol)                                               │
└─────────────────────────────────────────────────────────────────────────┘
```

### Call chain (how the two entry points meet)

```
                    UIKit / business code
                           │
         ┌─────────────────┴─────────────────┐
         │                                     │
    Path A: Binary replacement            Path B: Platform
    TIMManager.instance                 TencentCloudChatSdkPlatform.instance
         │                                     │
    NativeLibraryManager                  Tim2ToxSdkPlatform
         │                                     │
    bindings.DartXXX(...)                 FfiChatService
         │                                     │
         └──────────────┬──────────────────────┘
                        │
              libtim2tox_ffi (C)
              ├─ dart_compat_*.cpp (Dart* impl)   ← Path A
              └─ tim2tox_ffi_* (C API)            ← Path B
                        │
              V2TIMManagerImpl / V2TIMMessageManagerImpl / ...
                        │
              ToxManager → c-toxcore
```

### Why each layer exists

| Layer | Purpose |
|-------|---------|
| **C++ core** | Implements V2TIM semantics (login, messages, friends, groups, conversations, etc.) and talks to c-toxcore; no Dart dependency, easier to test and reuse. |
| **C FFI** | Dart can only call C via FFI; the C layer provides a “no C++ leakage” boundary, parameter/return conventions, and Dart* symbols for binary replacement. |
| **Dart bindings** | Wrap FFI calls, manage polling and history state, expose Stream/Future; FfiChatService is the single callee for the Platform path. |
| **SDK Platform** | When the SDK uses `isCustomPlatform`, some capabilities (e.g. history, polling, custom callbacks) must be provided by the client; Tim2ToxSdkPlatform implements that interface and delegates to FfiChatService. |

---

## Core capabilities

- **V2TIM semantics**: Init/Login, send/receive messages, friends/groups/conversations, signaling, etc., aligned with Tencent Cloud IM SDK’s V2TIM API style.
- **Dual entry points**: **Binary replacement** (swap the native library; SDK still uses NativeLibraryManager → Dart*) and **Platform** (set `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform`; some or all methods go through FfiChatService).
- **Callback bridging**: C++ events are sent to Dart via JSON and SendPort in the same format as the native SDK, so listeners can be reused.
- **History and polling**: History is persisted on the Dart side (MessageHistoryPersistence); polling (startPolling) drains the C++ event queue for connection/message/file events and updates state.
- **Dependency injection**: Preferences, Logger, Bootstrap, EventBus, ConversationManager, etc. are injected via interfaces; no binding to a specific client.
- **Multi-instance**: Multiple Tox instances supported (mainly for testing); production uses the default single instance.

---

## Directory structure

| Directory / file | Responsibility |
|------------------|----------------|
| `source/` | C++ core: V2TIMManagerImpl, V2TIMMessageManagerImpl, ToxManager, etc.; V2TIM implementation and c-toxcore integration. |
| `include/` | V2TIM-style C++ headers (API definitions). |
| `ffi/` | C FFI: tim2tox_ffi.h/cpp (C API), dart_compat_*.cpp (Dart* compat layer), callback_bridge, json_parser. |
| `dart/lib/ffi/` | Dart FFI bindings to tim2tox_ffi_* (Tim2ToxFfi). |
| `dart/lib/service/` | FfiChatService: init, login, polling, send, history, streams, multi-instance registration. |
| `dart/lib/sdk/` | Tim2ToxSdkPlatform: implements TencentCloudChatSdkPlatform, routes SDK calls to FfiChatService. |
| `dart/lib/interfaces/` | Injectable interfaces (BootstrapService, LoggerService, ExtendedPreferencesService, etc.). |
| `dart/lib/utils/` | MessageHistoryPersistence and other utilities. |
| `third_party/` | c-toxcore and other dependencies. |
| `doc/` | Architecture, API reference, integration and maintenance docs. |
| `auto_tests/` | Automated integration tests. |

---

## Two integration paths and integration steps

Tim2Tox supports **binary replacement** (minimal code change, swap library only) and **Platform / FfiChatService** (history, polling, Bootstrap, calls implemented on the Dart side). You can use one or both (hybrid). For path comparison, choice guide, and **five integration steps**, see [doc/integration/INTEGRATION_OVERVIEW.en.md](doc/integration/INTEGRATION_OVERVIEW.en.md).

**Clients using Tim2Tox**: An example client that uses this repo is [toxee](https://github.com/anonymoussoft/toxee) (a Flutter chat client based on Tox; hybrid setup, interface implementations, Bootstrap, history are documented there).

---

## Build

### Minimal build and verification

> For full build options, script behavior, and troubleshooting, use [README_BUILD.md](README_BUILD.md) as the single source of truth.

1. **Build C++ / FFI library (recommended; incremental)**

```bash
# Run from the repo root (under toxee that is third_party/tim2tox/)
./build_ffi.sh
```

Output: `build/ffi/libtim2tox_ffi.dylib` (macOS) or `build/ffi/libtim2tox_ffi.so` (Linux). Note that `build/source/libtim2tox.a` is **not** an output of `build_ffi.sh` — it is produced by `bash build.sh` (see [README_BUILD.en.md](README_BUILD.en.md)).

2. **Dart package**

```bash
cd dart
flutter pub get
```

3. **Verify**

- In a Flutter app that depends on this package, run `flutter run` and perform init → login → send message.
- Or run the auto tests: `cd auto_tests && ./run_tests_ordered.sh` (FFI library must be built first; `run_all_tests.sh` is a compatibility entry point). See [auto_tests/README.en.md](auto_tests/README.en.md).

---

## Reading guide for maintainers

- **Architecture and boundaries**: [doc/architecture/ARCHITECTURE.en.md](doc/architecture/ARCHITECTURE.en.md) — layers, call chains, FFI/callbacks, Bootstrap/polling, dual paths, risks and testing.
- **FFI and binary replacement**: [doc/architecture/FFI_COMPAT_LAYER.en.md](doc/architecture/FFI_COMPAT_LAYER.en.md), [doc/architecture/BINARY_REPLACEMENT.en.md](doc/architecture/BINARY_REPLACEMENT.en.md).
- **Development and modules**: [doc/development/DEVELOPMENT_GUIDE.en.md](doc/development/DEVELOPMENT_GUIDE.en.md), [doc/architecture/MODULARIZATION.en.md](doc/architecture/MODULARIZATION.en.md).
- **API and template**: [doc/api/API_REFERENCE.en.md](doc/api/API_REFERENCE.en.md), [doc/api/API_REFERENCE_TEMPLATE.en.md](doc/api/API_REFERENCE_TEMPLATE.en.md).

---

## Known limitations and boundaries

- **History**: Message history lives on the Dart side (MessageHistoryPersistence); C++ does not persist it. Loading history goes through Platform/FfiChatService.
- **Multi-instance**: Multiple Tox instances are mainly for testing; production uses the default single instance.
- **Callback thread**: C++ callbacks are posted to Dart via SendPort; handle UI/state on the main isolate.
- **Dual paths**: In a hybrid setup, avoid duplicate history/callbacks (BinaryReplacementHistoryHook and Platform responsibilities).
- **Platforms**: Build and tests are primarily macOS/desktop; mobile FFI library loading and paths should be verified per platform.

---

## Documentation index

### What to read first

| Role | Suggested order |
|------|------------------|
| **Engineer understanding the project** | This README → [doc/architecture/ARCHITECTURE.en.md](doc/architecture/ARCHITECTURE.en.md) §1–3 (goals, constraints, layers). |
| **Developer integrating into a client** | This README (positioning, two paths, how to integrate) → [doc/architecture/BINARY_REPLACEMENT.en.md](doc/architecture/BINARY_REPLACEMENT.en.md) or [doc/architecture/ARCHITECTURE.en.md](doc/architecture/ARCHITECTURE.en.md) §10 (client relationship) → [doc/integration/BOOTSTRAP_AND_POLLING.en.md](doc/integration/BOOTSTRAP_AND_POLLING.en.md) (if doing Bootstrap/connectivity). |
| **Maintainer changing the implementation** | [doc/architecture/ARCHITECTURE.en.md](doc/architecture/ARCHITECTURE.en.md) full doc → [doc/architecture/FFI_COMPAT_LAYER.en.md](doc/architecture/FFI_COMPAT_LAYER.en.md), [doc/api/API_REFERENCE_TEMPLATE.en.md](doc/api/API_REFERENCE_TEMPLATE.en.md) → [doc/development/DEVELOPMENT_GUIDE.en.md](doc/development/DEVELOPMENT_GUIDE.en.md), [doc/architecture/MODULARIZATION.en.md](doc/architecture/MODULARIZATION.en.md). |

### By audience

| Document | Best for |
|----------|----------|
| This README, [ARCHITECTURE](doc/architecture/ARCHITECTURE.en.md) §1–4, §10, [BINARY_REPLACEMENT](doc/architecture/BINARY_REPLACEMENT.en.md), [BOOTSTRAP_AND_POLLING](doc/integration/BOOTSTRAP_AND_POLLING.en.md) | **Integrators** (positioning, integration options, steps). |
| [ARCHITECTURE](doc/architecture/ARCHITECTURE.en.md) full, [FFI_COMPAT_LAYER](doc/architecture/FFI_COMPAT_LAYER.en.md), [API_REFERENCE](doc/api/API_REFERENCE.en.md), [API_REFERENCE_TEMPLATE](doc/api/API_REFERENCE_TEMPLATE.en.md), [DEVELOPMENT_GUIDE](doc/development/DEVELOPMENT_GUIDE.en.md), [MODULARIZATION](doc/architecture/MODULARIZATION.en.md), [MULTI_INSTANCE_SUPPORT](doc/development/MULTI_INSTANCE_SUPPORT.en.md) | **Maintainers** (implementation details, extension points, testing and risks). |

### Full index entry points

- [doc/README.en.md](doc/README.en.md) — Documentation index and recommended reading paths
- [README_BUILD.md](README_BUILD.md) — Build guide (single source of truth)

---

## License

This project is licensed under GPL-3.0. See [LICENSE](LICENSE).
