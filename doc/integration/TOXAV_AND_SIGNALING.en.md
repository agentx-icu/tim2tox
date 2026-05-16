# Tim2Tox ToxAV and Signaling
> Language: [Chinese](TOXAV_AND_SIGNALING.md) | [English](TOXAV_AND_SIGNALING.en.md)

This document describes the current call link of tim2tox, focusing on `ToxAVService`, `CallBridgeService`, `TUICallKitAdapter` and multi-instance callback routing.

## 1. Goal

tim2tox currently supports two types of call entrances:

- **UIKit signaling call**: Initiate/accept invitations through the signaling API exposed by `Tim2ToxSdkPlatform`
- **Native ToxAV calls**: Directly handle incoming calls and status callbacks from ToxAV, used for interoperability scenarios such as qTox

Both paths ultimately end up on the same set of ToxAV instances and media callbacks.

## 2. Core components

### 2.1 `ToxAVService`

Location: `tim2tox/dart/lib/service/toxav_service.dart`

Responsibilities:

- Call `tim2tox_ffi_av_*` FFI interface
- Maintain Dart side `ToxAVService` instance mapping by `instance_id`
- Register call / state / audio / video four types of native callback
- Provide high-level methods such as `startCall()`, `answerCall()`, `endCall()` to the outside world

### 2.2 `CallBridgeService`

Location: `tim2tox/dart/lib/service/call_bridge_service.dart`

Responsibilities:

- Monitor `V2TimSignalingListener`
- Map signaling invite / cancel / accept / reject / timeout as call state machine
- Drive `ToxAVService` on accept / reject / timeout and other nodes

### 2.3 `TUICallKitAdapter`

Location: `tim2tox/dart/lib/service/tuicallkit_adapter.dart`

Responsibilities:

- As the adaptation layer of `TUICallingService` in TUICore
- Translate UIKit's call request into signaling invite
- If `friendNumber` can be parsed out, `ToxAVService.startCall()` will be triggered simultaneously

### 2.4 TUICore Registration

Location: `tim2tox/dart/lib/service/tuicallkit_tuicore_integration.dart`

Responsibilities:

- Exposing `TUICallKitAdapter` to TUICore via `registerToxAVWithTUICore(adapter)`
- This is the only registration point for UIKit call buttons and the tim2tox call stack

## 3. Call link

### 3.1 Initiate a call (UIKit)

1. UIKit calls TUICore’s `TUICallingService.call`
2. `ToxAVCallService.onCall()` forwards the request to `TUICallKitAdapter.handleCall()`
3. `TUICallKitAdapter` calls `Tim2ToxSdkPlatform.invite()`
4. If invite is successful, `onOutgoingCallInitiated` will be thrown to the UI
5. If you find friend `friendNumber`, continue to call `ToxAVService.startCall()`

### 3.2 Receive signaling invitation

1. `Tim2ToxSdkPlatform` receives signaling listener callback
2. `CallBridgeService` structure `CallInfo`
3. The upper-layer UI decides accept/reject
4. `CallBridgeService.acceptInvitation()` first calls signaling accept, then calls `ToxAVService.answerCall()`

### 3.3 Receiving native ToxAV calls

1. C++/FFI callback into `ToxAVService` trampoline
2. Press `instance_id` to find the target `ToxAVService`
3. The upper layer maps it to native call, usually using inviteID in the form of `native_av_<friendNumber>`

## 4. Multi-instance routing

Currently all ToxAV FFI interfaces explicitly receive `instance_id`:

- `tim2tox_ffi_av_initialize(int64_t instance_id)`
- `tim2tox_ffi_av_start_call(int64_t instance_id, ...)`
- `tim2tox_ffi_av_set_*_callback(int64_t instance_id, ...)`

Design reasons:

- Multiple Tox instances run simultaneously in automated tests
- The Dart side must ensure that the callback returns the correct `ToxAVService`
- So `ToxAVService` is constructed to read `getCurrentInstanceId()` and maintain `_instanceServices[instanceId]`

The last hop from native callback to Dart is completed by trampoline; it reads `instance_id` from `userData` and then delivers it to the corresponding service instance.

## 5. Relationship with the client

The client must create and initialize the call-related components (e.g. CallServiceManager) after setting `Tim2ToxSdkPlatform`, and wire ToxAVService, CallBridgeService, TUICallKit adapter, etc. If Platform is not set first, the signaling path will be incomplete. For concrete integration and UI, see each client project’s documentation.

## 6. Current Limitations

- `TUICallKitAdapter` currently only supports 1-to-1 calls, group calls have not been completed yet
- When signaling invite is successful but `friendNumber` cannot be found, it will degrade to signaling-only state.
- The native ToxAV path and the signaling path coexist, so the upper-layer UI must be able to handle both inviteID forms

## 7. Related documents

- [ARCHITECTURE.en.md](../architecture/ARCHITECTURE.en.md)
- [API Reference](../api/API_REFERENCE.en.md)
- [MULTI_INSTANCE_SUPPORT.en.md](../development/MULTI_INSTANCE_SUPPORT.en.md)
- For client-side calling and extensions implementation, see each client project’s documentation (e.g. when Tim2Tox is used as a submodule, the parent repo’s doc).