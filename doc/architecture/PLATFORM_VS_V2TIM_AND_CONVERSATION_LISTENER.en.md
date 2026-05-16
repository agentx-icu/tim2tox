# Tim2Tox and V2TIM
> Language: [Chinese](PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.md) | [English](PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.en.md)

## 1. End-to-end architecture (hybrid)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  App / UIKit / tests                                                          │
│  - TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)             │
│  - TIMConversationManager.instance.addConversationListener(...) etc.          │
└───────────────────────────────────────────┬─────────────────────────────────┘
                                            │
┌───────────────────────────────────────────▼─────────────────────────────────┐
│  tencent_cloud_chat_sdk (not replaced; original package)                      │
│  - TencentCloudChatSdkPlatform (interface)                                    │
│  - TIMConversationManager / TIMMessageManager / ... adapters                  │
│  - All APIs eventually call platform.xxx() or NativeLibraryManager (FFI)      │
└───────────────────────────────────────────┬─────────────────────────────────┘
                    │                                    │
        Platform-interface call                Binary-replacement FFI call
                    │                                    │
┌───────────────────▼──────────────────┐   ┌────────────▼─────────────────────┐
│  Tim2ToxSdkPlatform (Dart)            │   │  ffi/dart_compat_*.cpp (C++)      │
│  - Implements TencentCloudChatSdkPlat │   │  - DartInitSDK / DartLogin / ...  │
│  - addConversationListener, etc.      │   │  - SafeGetV2TIMManager()          │
│  - _conversationListeners, etc.       │   │  - Drives V2TIM* implementations  │
│  - globalCallback dispatch by inst.id │   │  - SendCallbackToDart             │
└───────────────────┬──────────────────┘   └────────────┬─────────────────────┘
                    │                                    │
                    │         Dart_PostCObject_DL        │
                    └────────────────┬───────────────────┘
                                     │
┌────────────────────────────────────▼─────────────────────────────────────────┐
│  Native (C++)                                                                 │
│  - V2TIMManagerImpl (per instance; distinguished by instance_id)              │
│  - V2TIMConversationManagerImpl (per instance; owned by V2TIMManagerImpl)     │
│  - V2TIMSignalingManagerImpl (per instance)                                   │
│  - ToxManager / toxcore                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Binary replacement** does not replace any class in `tencent_cloud_chat_sdk`; it only swaps the **platform instance** (`TencentCloudChatSdkPlatform.instance`) and the **native implementation** (the dylib is replaced by `libtim2tox_ffi`).
- **Tim2ToxSdkPlatform** implements `TencentCloudChatSdkPlatform`; every "platform method" (e.g. `addConversationListener`, `getConversationList`) is fulfilled by it. It is also the receiver of `globalCallback` messages from native, dispatched to per-listener lists by `instance_id`.
- **V2TIM*** are the C++ business implementations (conversation, message, group, signaling, etc.).

> Important: `V2TIMConversationManagerImpl` is **not** a singleton. It is a per-instance member that `V2TIMManagerImpl` constructs and owns via `V2TIMConversationManagerImpl(V2TIMManagerImpl* owner)` (see `source/V2TIMConversationManagerImpl.h:38` and the construction site in `source/V2TIMManagerImpl.cpp`). It references its owner through `manager_impl_`; there is no `GetInstance()` and no `SetManagerImpl()`. `V2TIMSignalingManagerImpl` is also a per-instance member.

## 2. How Tim2ToxSdkPlatform maps to V2TIM*

| Capability   | Dart side (Platform / adapter)             | C++ side (V2TIM*) |
|--------------|--------------------------------------------|-------------------|
| Conversation list   | `Platform.getConversationList` / provider | `V2TIMConversationManagerImpl` (`GetConversationList`, cache, `PinConversation`) |
| Conversation listener | `Platform.addConversationListener`     | `V2TIMConversationManagerImpl::AddConversationListener` + dart_compat registers a `DartConversationListenerImpl` |
| Conversation change callback | `Platform._conversationListeners` + globalCallback dispatch | C++ invokes the listener → dart_compat → `SendCallbackToDart("globalCallback", ...)` |
| Messaging   | Platform + FFI send/poll                   | `V2TIMMessageManagerImpl` + Tox |
| Groups      | Platform + FFI                             | `V2TIMGroupManagerImpl` |
| Signaling   | Platform + FFI                             | `V2TIMSignalingManagerImpl` (per instance) |

- **Conversation listening**:
  - **C++**: `V2TIMConversationManagerImpl::AddConversationListener` just appends the listener to `listeners_` (see `source/V2TIMConversationManagerImpl.cpp:73`). `dart_compat_listeners.cpp` lazily registers a `DartConversationListenerImpl` (via `GetOrCreateConversationListener()`) into the current instance the first time the Dart side asks for any `DartSetOnConvXxxCallback`.
  - **Dart**: `Tim2ToxSdkPlatform.addConversationListener` stores the listener in `_conversationListeners` and in the per-instance map `_instanceConversationListeners[id]`. When `globalCallback(ConversationEvent)` arrives, it is dispatched to the matching list by `instance_id`.
- Net effect: **the event source for conversation listeners is C++ `V2TIMConversationManagerImpl` + dart_compat; the reception and dispatch happen in Dart `Tim2ToxSdkPlatform`.**

## 3. addConversationListener implementation site (historical bug)

> The original wording in this section described a bug; it has since been fixed. Kept here as background.

### 3.1 C++ already implements `AddConversationListener`

The C++ side `V2TIMConversationManagerImpl::AddConversationListener` simply does `listeners_.push_back(listener)`. The Dart layer does not need to "re-implement" it.

### 3.2 Historical bug — "addConversationListener has not been implemented"

The original error did not come from C++; it came from a Dart-side call-ordering problem:

- `Tim2ToxSdkPlatform`'s constructor called `_setupInternalConversationListener()` to register an internal listener.
- That helper called `TIMConversationManager.instance.addConversationListener(internalListener)`.
- The adapter forwarded back to `TencentCloudChatSdkPlatform.instance.addConversationListener(...)`.
- But at that moment `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)` **had not been assigned yet** (the constructor had not returned). `.instance` was still the default platform, whose default implementation `throws UnimplementedError(...)`.

### 3.3 Fix (**already applied**)

The current implementation at `dart/lib/sdk/tim2tox_sdk_platform.dart:2266 / 2300-2305` only calls `this.addConversationListener(...)` and no longer detours through the adapter:

```dart
// Don't call TIMConversationManager.instance.addConversationListener here: during
// construction, TencentCloudChatSdkPlatform.instance has not been assigned yet,
// so the adapter would call the default platform's addConversationListener (which
// throws UnimplementedError).
addConversationListener(listener: internalListener);
```

If syncing back to the adapter is ever required, the recommended approach is to defer with `Future.microtask(...)` so `.instance = Tim2ToxSdkPlatform(...)` has time to land.

## 4. Summary

- **In hybrid mode**, `Tim2ToxSdkPlatform` is the Platform implementation and `V2TIM*` are the native capability implementations. They cooperate over FFI + globalCallback; Platform dispatches back to per-instance Dart listeners by `instance_id`.
- **Conversation-listener chain**: C++ `AddConversationListener` (already implemented in `V2TIMConversationManagerImpl`) + `dart_compat_listeners.cpp` registration → globalCallback → Dart `Tim2ToxSdkPlatform._conversationListeners` → business listener.
- The historical "addConversationListener has not been implemented" failure came from constructor-time call ordering and is now fixed — the internal listener goes through `this.addConversationListener(...)`, avoiding the "adapter calls a not-yet-assigned `.instance`" loop.
