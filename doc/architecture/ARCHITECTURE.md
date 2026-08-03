[简体中文](./ARCHITECTURE.zh-CN.md)

# Tim2Tox Deep Architecture

This document is for **framework maintainers** and **integration engineers**. It explains how Tim2Tox maps UIKit-side calls to the Tox network protocol, layer boundaries, why both binary-replacement and Platform/FfiChatService paths exist, and how Bootstrap, polling, callback bridging, and message/session/friend/group management work together. It is a technical reference, not a product overview.

## Contents

- [1. Core design goals](#1-core-design-goals)
- [2. Technical constraints](#2-technical-constraints)
- [3. Layered architecture](#3-layered-architecture)
- [4. Key directories and key classes](#4-key-directories-and-key-classes)
- [5. Typical call chains](#5-typical-call-chains)
- [6. FFI boundary design principles](#6-ffi-boundary-design-principles)
- [7. Callback bridging mechanism](#7-callback-bridging-mechanism)
- [8. Bootstrap and polling](#8-bootstrap-and-polling)
- [9. Multi-instance support: purpose and boundaries](#9-multi-instance-support-purpose-and-boundaries)
- [10. Relationship with the integrating client](#10-relationship-with-the-integrating-client)
- [11. Common extension points](#11-common-extension-points)
- [12. Risks and testing recommendations](#12-risks-and-testing-recommendations)

---

## 1. Core design goals

| Goal | Description |
|------|-------------|
| **Bridge UIKit and Tox** | Upper layer is Tencent Cloud Chat UIKit / V2TIM-style API; lower layer is c-toxcore P2P protocol. Tim2Tox performs semantic mapping and data translation. |
| **Compatible V2TIM calls and callback format** | Callers (SDK/app) do not need to change business logic. Callback format (e.g. apiCallback/globalCallback JSON) matches the native SDK contract so listener dispatch works unchanged. |
| **Dual paths** | Support **binary replacement path** (NativeLibraryManager → Dart*) and **Platform/FfiChatService path** (TencentCloudChatSdkPlatform → FfiChatService → tim2tox_ffi_*). Clients can use one or both. |
| **Reusable, not tied to a specific client** | Dependencies are injected via interfaces (Preferences, Logger, Bootstrap, EventBus, ConversationManager, etc.); no direct dependency on any particular app. Any Flutter chat client can reuse Tim2Tox. |

---

## 2. Technical constraints

| Constraint | Description |
|------------|-------------|
| **Compatible with original SDK call style** | Dart* function signatures match `native_imsdk_bindings_generated.dart`. After the app replaces the native library with `setNativeLibraryName('tim2tox_ffi')`, the SDK still calls `bindings.DartXXX(...)`; tim2tox implements these symbols in `dart_compat_*.cpp`. See [BINARY_REPLACEMENT.md](BINARY_REPLACEMENT.md), [FFI_COMPAT_LAYER.md](FFI_COMPAT_LAYER.md). |
| **Callback format** | C++ sends via `SendCallbackToDart(callback_type, json_data, user_data)`. The JSON shape expected by Dart’s `NativeLibraryManager._handleNativeMessage` (e.g. `callback`, `callbackType`, `user_data`, `code`, `desc`) must match the native SDK contract so the same listener logic can handle it. |
| **Cross-language boundary** | The FFI boundary exposes **C only** (no C++ types, exceptions, or smart pointers). Dart binds C functions via `dart:ffi`. Strings/buffers are either caller-allocated or written by the implementation; return values are specified (e.g. 0/1, bytes written). |

---

## 3. Layered architecture

From bottom to top: C++ core → C FFI → Dart bindings → SDK Platform. Both entry points (tim2tox_ffi_* and Dart*) meet at the FFI layer and use the same V2TIM implementation and Tox core.

```
┌─────────────────────────────────────────────────────────────────┐
│  Flutter/UIKit application layer                                  │
│  Callers: TIMManager / TencentCloudChatSdkPlatform.instance       │
└───────────────────────────┬───────────────────────────────────────┘
                            │
        ┌───────────────────┴───────────────────┐
        │  Dart SDK Platform layer               │
        │  Tim2ToxSdkPlatform → FfiChatService    │  Only when isCustomPlatform
        │  FFI: tim2tox_ffi.dart (Tim2ToxFfi)    │
        └───────────────────┬───────────────────┘
                            │
┌───────────────────────────┴───────────────────────────────────────┐
│  C FFI layer (libtim2tox_ffi)                                       │
│  tim2tox_ffi_* (high-level API)  │  Dart* (dart_compat_*) compat   │
│  Caller: FfiChatService           │  Caller: NativeLibraryManager   │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌───────────────────────────┴───────────────────────────────────────┐
│  V2TIM API implementation (source/)                                │
│  V2TIMManagerImpl, V2TIMMessageManagerImpl, ...                     │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌───────────────────────────┴───────────────────────────────────────┐
│  Tox core (source/ToxManager) + c-toxcore                            │
└───────────────────────────────────────────────────────────────────┘
```

**Boundaries**:

- **C++ core**: Implements V2TIM semantics (login, messages, friends, groups, conversations, etc.) and delegates to ToxManager for Tox network operations. It does not know about Dart or Platform.
- **C FFI layer**: Exposes C APIs for Dart or SDK native bindings; translates parameters/return values between C and C++; does not hold Dart objects, only sends JSON messages via SendPort.
- **Dart bindings**: Wrap `tim2tox_ffi_*` calls and manage polling, history, and other state. FfiChatService is the **callee** for the Platform path and the **caller** of FFI.
- **SDK Platform**: When `isCustomPlatform == true`, the SDK routes a subset of methods to `Tim2ToxSdkPlatform`, which delegates to FfiChatService or native capabilities.

---

## 4. Key directories and key classes

| Layer | Directory/File | Key class/module | Responsibility |
|-------|----------------|------------------|----------------|
| C++ core | `source/` | `V2TIMManagerImpl` | SDK init, login, instance and Tox lifecycle, access to sub-managers. |
| | | `ToxManager` | Tox instance create/iterate, friends/groups/messages, c-toxcore. |
| | | `V2TIMMessageManagerImpl` | Send/receive messages; history is bridged (actual history lives on Dart). |
| | | `V2TIMFriendshipManagerImpl` / `V2TIMGroupManagerImpl` / `V2TIMConversationManagerImpl` | Friends, groups, conversations. |
| C FFI | `ffi/` | `tim2tox_ffi.h/cpp` | C API: init, login, poll, send, bootstrap, multi-instance, etc. |
| | | `dart_compat_layer.cpp` + `dart_compat_*.cpp` | Dart* compat layer for NativeLibraryManager FFI calls. |
| | | `callback_bridge.cpp/h` | SendPort registration, SendCallbackToDart, deliver C++ events to Dart. |
| | | `json_parser.cpp/h` | Build apiCallback / globalCallback JSON. |
| Dart | `dart/lib/ffi/` | `tim2tox_ffi.dart` (Tim2ToxFfi) | Dart FFI bindings to tim2tox_ffi_*. |
| | `dart/lib/service/` | `FfiChatService` | Init, login, polling, send, history, streams, multi-instance registration. |
| | `dart/lib/sdk/` | `Tim2ToxSdkPlatform` | Implements TencentCloudChatSdkPlatform; routes SDK calls to FfiChatService. |
| | `dart/lib/utils/` | `MessageHistoryPersistence` | Per-conversation history persistence (Dart side); C++ has no history store. |

---

## 5. Typical call chains

Each chain below shows **caller → callee** and **failure paths**.

### 5.1 Init

```
App/Client                FfiChatService          Tim2ToxFfi (Dart)     C FFI              V2TIMManagerImpl      ToxManager
    |                            |                        |                   |                        |                    |
    | init()                     |                        |                   |                        |                    |
    |--------------------------->|                        |                   |                        |                    |
    |                            | tim2tox_ffi_init()      |                   |                        |                    |
    |                            | or init_with_path()     |                   |                        |                    |
    |                            |------------------------>|------------------>|                        |                    |
    |                            |                        |                   | InitSDK()              |                    |
    |                            |                        |                   |----------------------->|                    |
    |                            |                        |                   |                        | create/load Tox    |
    |                            |                        |                   |                        |------------------->|
    |                            |                        |                   | return 1/0             |                    |
    |                            |                        |                   |<-----------------------|                    |
    |                            |                        | return 1/0        |                        |                    |
    |                            |<------------------------|                   |                        |                    |
    |                            | _loadAndApplySavedBootstrapNode()           |                        |                    |
    |                            | (apply Bootstrap node, see §8)             |                        |                    |
    |<---------------------------|                        |                   |                        |                    |
```

**Failure paths**: C returns 0 if `init_path` is invalid or not writable; behavior when already inited is implementation-defined. Dart can throw or show an error based on the return value.

### 5.2 Login

```
App/Client                FfiChatService          Tim2ToxFfi             C FFI              V2TIMManagerImpl
    |                            |                        |                   |                        |
    | login(userId, userSig)      |                        |                   |                        |
    |--------------------------->|                        |                   |                        |
    |                            | tim2tox_ffi_login()     |                   |                        |
    |                            | or login_async()        |                   |                        |
    |                            |------------------------>|----------------->|                        |
    |                            |                        |                   | Login() [async]         |
    |                            |                        |                   |----------------------->|
    |                            |                        |                   | [later] callback        |
    |                            |                        |                   |<-----------------------|
    |                            | (Future completes /     |                   |                        |
    |                            |  callback)              |                   |                        |
    |<---------------------------|                        |                   |                        |
```

**Failure paths**: Returns 0 if instance is not created or not inited; login failure is reported via async callback with success=0 and error_code/error_message.

### 5.3 Send (C2C text)

```
UIKit / ChatMessageProvider   Tim2ToxSdkPlatform    FfiChatService    Tim2ToxFfi    C FFI                    V2TIMMessageManagerImpl   ToxManager   c-toxcore
    |                                |                    |               |            |                              |                    |            |
    | sendMessage() / sendText()      |                    |               |            |                              |                    |            |
    |-------------------------------->|                    |               |            |                              |                    |            |
    |                                | sendText()          |               |            |                              |                    |            |
    |                                |------------------->|               |            |                              |                    |            |
    |                                |                    | tim2tox_ffi_send_c2c_text()  |                              |                    |            |
    |                                |                    |-------------->|----------->|                              |                    |            |
    |                                |                    |               |            | SendMessage()                 |                    |            |
    |                                |                    |               |            |----------------------------->|                    |            |
    |                                |                    |               |            |                              | SendMessage()       |            |
    |                                |                    |               |            |                              |------------------->|            |
    |                                |                    |               |            |                              |                    | tox_friend_send_message()
    |                                |                    |               |            |                              |                    |----------->|
    |                                |                    |               |            | return 1 (submitted)          |                    |            |
    |                                |                    |               |            |<------------------------------|                    |            |
    |                                |                    |<---------------|<-----------|                              |                    |            |
```

**Failure paths**: C returns 0 for not logged in, friend not found, or buffer issues; send timeout/failure is reported via later callbacks (e.g. message status).

### 5.4 History

History is persisted on the **Dart side**; C++ does not store message history. Platform methods like getHistoryMessageList are implemented by Tim2ToxSdkPlatform calling FfiChatService.getHistory, which reads from MessageHistoryPersistence.

```
UIKit / conversation UI      Tim2ToxSdkPlatform    FfiChatService              MessageHistoryPersistence
    |                                |                    |                                |
    | getHistoryMessageList()         |                    |                                |
    |-------------------------------->|                    |                                |
    |                                | getHistory(convId)  |                                |
    |                                |------------------->|                                |
    |                                |                    | getHistory(id)                  |
    |                                |                    |------------------------------->|
    |                                |                    | List<ChatMessage>               |
    |                                |                    |<--------------------------------|
    |                                | (convert to SDK     |                                |
    |                                |  types)            |                                |
    |<--------------------------------|                    |                                |
```

**Failure paths**: Returns an empty list for invalid conversation id or uninitialized persistence; clearing history is done via Platform calling FfiChatService clearHistoryMessage / messageHistoryPersistence.

### 5.5 Callback (C++ → Dart)

```
c-toxcore / ToxManager    V2TIM Listener impl      json_parser / callback_bridge    Dart ReceivePort    NativeLibraryManager / Platform
    |                            |                            |                            |                            |
    | event (e.g. friend msg)     |                            |                            |                            |
    |--------------------------->|                            |                            |                            |
    |                            | BuildGlobalCallbackJson()  |                            |                            |
    |                            | or BuildApiCallbackJson()  |                            |                            |
    |                            |--------------------------->|                            |                            |
    |                            |                            | SendCallbackToDart()        |                            |
    |                            |                            | Dart_PostCObject_DL()       |                            |
    |                            |                            |--------------------------->|                            |
    |                            |                            |                            | _handleNativeMessage()     |
    |                            |                            |                            |--------------------------->|
    |                            |                            |                            | dispatch to Listeners /    |
    |                            |                            |                            | Platform                   |
```

**Failure paths**: If SendPort is not registered or Dart is not initialized, SendCallbackToDart returns without sending. For multi-instance, instance_id is used on the Dart side to route to the correct FfiChatService (see §7).

---

## 6. FFI boundary design principles

| Principle | Description |
|-----------|-------------|
| **C-only surface** | Header `tim2tox_ffi.h` contains only C types and `extern "C"` functions. Dart binds C functions via FFI and does not touch C++. |
| **Thread safety** | Callback sender (e.g. SendCallbackToDart) uses a mutex for port and send logic. Dart side must ensure ReceivePort ownership if using multiple isolates. |
| **Dual entry points** | **tim2tox_ffi_***: used by FfiChatService or direct FFI callers; higher-level API (e.g. poll_text by instance_id). **Dart***: used by NativeLibraryManager via dynamic lookup; signatures match native SDK-generated bindings; internally call V2TIM or tim2tox_ffi_*. |
| **Parameter and return conventions** | Output buffers are **caller-allocated**; implementation writes and returns bytes written or 0 on error. Booleans/status use 0/1; instance uses int64_t handle. Async results are delivered via callbacks or Dart-side poll. See [FFI_FUNCTION_DECLARATION_GUIDE.md](../development/FFI_FUNCTION_DECLARATION_GUIDE.md). |

---

## 7. Callback bridging mechanism

- **Registration**: After loading the library, Dart calls `DartRegisterSendPort(sendPort.nativePort)`; C++ stores the port globally (with lock).
- **Sending**: In V2TIM Listener implementations, C++ builds JSON (BuildGlobalCallbackJson / BuildApiCallbackJson) and calls `SendCallbackToDart(callback_type, json_data, user_data)`, which uses `Dart_PostCObject_DL` to post to the Dart ReceivePort. In the current C++ implementation the `user_data` parameter is not used when sending; request–callback correlation relies on fields such as `user_data` inside the JSON.
- **Types**: `globalCallback` for global events (connection status, new message, friend changes, etc.); `apiCallback` for one-off API results (e.g. login done, add-friend result).
- **Multi-instance**: Some callbacks carry instance_id; Dart uses `_instanceServices[instanceId]` to route to the right FfiChatService; default instance 0 can fall back to `_globalService`. **Note**: Per-instance routing only applies to callbacks that go through FfiChatService/tim2tox_ffi (e.g. DHT node response, ToxAV); under the **binary replacement path** NativeLibraryManager still has a single set of global listeners and does not dispatch by instance_id. See [MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md).
- **Key code**: `ffi/callback_bridge.cpp` (SendPort storage, SendCallbackToDart), `ffi/dart_compat_callbacks.cpp` (callback classes), `ffi/dart_compat_listeners.cpp` (listener registration); Dart side trampolines and `_instanceServices` lookup in `ffi_chat_service.dart`.

See [FFI_COMPAT_LAYER.md](FFI_COMPAT_LAYER.md).

---

## 8. Bootstrap and polling

### Bootstrap

- **Purpose**: Tox needs at least one DHT Bootstrap node to join the network. The node is configured by the client (auto from public nodes / manual / lan).
- **When applied**: At the end of `FfiChatService.init()`, `_loadAndApplySavedBootstrapNode()` runs: it reads the current node from Prefs (e.g. getCurrentBootstrapNode() or BootstrapService getters), then calls `tim2tox_ffi_add_bootstrap_node(instance_id, host, port, public_key_hex)`.
- **Collaboration**: Bootstrap decides “who to connect to”; actual connection and DHT setup are done by c-toxcore via Tox iteration.

### Polling

- **Purpose**: C++ enqueues received text/custom messages, connection status, file events, etc. Dart **polls** to drain the queue and process events, avoiding direct Dart API calls from C++ callbacks (threading/isolate constraints).
- **Start**: `FfiChatService.startPolling()` cancels the previous timer, sets `_pollTimerCallback`, runs once immediately, then schedules next poll with `_scheduleNextPoll`.
- **Per round**: Call `tim2tox_ffi_poll_text(instance_id, buffer, len)` (and custom, etc.) to read from the queue; parse line-based events (e.g. `conn:success`, `c2c:`, `gtext:`, `file_request:`, `file_done:`), update connection state, message streams, file progress. For multi-instance, poll each instance in `_knownInstanceIds`; non-default instances are prioritized so file_request is consumed in time.
- **Interval**: Shorter (e.g. 50ms) when there is file transfer or multi-instance; 200ms when recently active; 1000ms when idle. Profile is saved periodically (e.g. every 60s).

See [BOOTSTRAP_AND_POLLING.md](../integration/BOOTSTRAP_AND_POLLING.md) for details and client-side contract.

---

## 9. Multi-instance support: purpose and boundaries

- **Purpose**: Mainly for **testing** (e.g. multi-node interaction in auto_tests). **Production** uses the **default instance** (instance_id 0) and does not create test instances.
- **Boundaries**:
  - **Create / switch / destroy**: `tim2tox_ffi_create_test_instance` / `create_test_instance_ex`, `tim2tox_ffi_set_current_instance`, `tim2tox_ffi_destroy_test_instance`. Each instance has its own init_path, network port, DHT ID.
  - **Polling**: `tim2tox_ffi_poll_text(instance_id, ...)` returns only events for that instance or broadcast (id 0). On Dart, `registerInstanceForPolling(instanceId)` adds the instance to `_knownInstanceIds`; a single FfiChatService polls each instance in turn and routes events via `_instanceServices` when registered.
  - **Lifecycle**: After destroy, the instance must be removed from the polling registry (`unregisterInstanceForPolling`) to avoid polling an invalid instance.

See [MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md).

---

## 10. Relationship with the integrating client

Integrators can use a **hybrid** setup (binary replacement + Platform); the client owns UI and interface injection, Tim2Tox provides the core:

- **Binary replacement**: Call `setNativeLibraryName('tim2tox_ffi')` as early as possible so the SDK loads `libtim2tox_ffi`. Most TIMManager/NativeLibraryManager calls then go through Dart* → V2TIM.
- **Platform**: Set `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(ffiService: ffiChatService)`. When `isCustomPlatform == true`, the SDK routes a subset of methods to the Platform; Tim2ToxSdkPlatform delegates to FfiChatService (history, polling, callbacks, call bridge, etc.).
- **Division of work**: History (getHistoryMessageList, clearHistory, etc.) is provided by Platform → FfiChatService; login, send message, friends, groups can go through binary replacement or Platform; in hybrid mode Platform fills custom callbacks, Bootstrap write, calls.
- **Client responsibilities**: Provide Bootstrap settings and node sources, message/session UI, and implement Preferences, Logger, BootstrapService, etc. and inject them into FfiChatService.

For a full example and startup order, see each client project’s documentation. See [BINARY_REPLACEMENT.md](BINARY_REPLACEMENT.md) for routing and the main [README](../../README.md) integration section.

---

## 11. Common extension points

| Extension point | How |
|-----------------|-----|
| **New V2TIM capability** | Implement in the corresponding *Impl in `source/`. If needed for the binary-replacement path, add a Dart* function in `ffi/dart_compat_*.cpp` that calls the V2TIM API. |
| **New FFI API** | Declare and implement the C function in `tim2tox_ffi.h/cpp`; add Dart binding in `dart/lib/ffi/tim2tox_ffi.dart`. If used by Platform, add a call from FfiChatService or Tim2ToxSdkPlatform to Tim2ToxFfi. |
| **New Platform method** | Implement the new TencentCloudChatSdkPlatform method in Tim2ToxSdkPlatform, delegating to FfiChatService or native. |
| **Dependency injection** | Inject BootstrapService, LoggerService, ExtendedPreferencesService, etc. via FfiChatService constructor; client implements the interfaces and passes them in. See existing `interfaces/`. |

See [MODULARIZATION.md](MODULARIZATION.md), [DEVELOPMENT_GUIDE.md](../development/DEVELOPMENT_GUIDE.md) for module layout and development flow.

---

## 12. Risks and testing recommendations

### Limitations and exception paths

- **Call order**: Calling login/send before init will fail; the C++ layer returns 0 or reports via async callback. Guard init/login state on the Dart side and document “when to call”.
- **Polling not started**: If `startPolling()` is never called, the C++ event queue (connection status, new messages, file events, etc.) keeps growing and connection/messages are never consumed by Dart. Call `startPolling()` soon after init or login.
- **Multi-instance callbacks**: Only some callbacks (e.g. DHT response, ToxAV) are routed correctly per instance; most globalCallbacks use “current instance” on the C++ side to fill instance_id and can be wrong when triggered from Tox’s async thread; under the binary replacement path the Dart side does not dispatch by instance_id. See [MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md).

### Risks

| Risk | Description |
|------|-------------|
| **Callback thread and Dart isolate** | C++ callbacks may run on a non-main isolate or background thread. After posting via SendPort to Dart, UI and state updates should run on the main isolate; keep trampolines simple and avoid cross-isolate references. |
| **Calls before library init** | Calling login/send before init will fail. Guard init/login state on the Dart side and document “when to call” clearly. |
| **Duplicate history/callbacks with dual paths** | If the same message is both delivered via binary replacement (OnRecvNewMessage) and written via Platform history, it may be stored or notified twice. Current design uses BinaryReplacementHistoryHook and Platform history responsibilities to avoid this; keep the split clear when maintaining. |
| **Multi-instance dispose and port** | After destroying an instance, polling or delivering callbacks for that instance can touch freed resources. Unregister from polling on destroy and ensure C++ does not post to that instance. |

### Testing recommendations

- **C++ unit tests**: In `test/`, cover critical V2TIM/ToxManager logic.
- **Dart/integration**: In `auto_tests`, cover multi-instance, login, send, polling, history. Cover both **binary replacement path** (no Platform) and **Platform path** (isCustomPlatform) so both remain valid.
- **Regression**: After changing callback_bridge, dart_compat_*, or tim2tox_ffi, run full integration and client smoke tests.

---

## Related documentation

- [API Reference](../api/API_REFERENCE.md)
- [API Reference Writing Template](../api/API_REFERENCE_TEMPLATE.md)
- [Binary replacement](BINARY_REPLACEMENT.md)
- [FFI compat layer](FFI_COMPAT_LAYER.md)
- [Bootstrap and polling](../integration/BOOTSTRAP_AND_POLLING.md)
- [Multi-instance support](../development/MULTI_INSTANCE_SUPPORT.md)
- isCustomPlatform routing: see [BINARY_REPLACEMENT](BINARY_REPLACEMENT.md)
- [Development guide](../development/DEVELOPMENT_GUIDE.md)
