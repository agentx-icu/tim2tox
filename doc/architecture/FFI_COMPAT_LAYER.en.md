# Tim2Tox FFI Compatibility Layer
> Language: [Chinese](FFI_COMPAT_LAYER.md) | [English](FFI_COMPAT_LAYER.en.md)

This document explains the implementation of the `Dart*` compatibility layer (the symbols used by the binary-replacement path): architecture, callback bridging, JSON format, and current implementation state. **The `tim2tox_ffi_*` C API used by the Platform path is a separate surface** — see [API_REFERENCE_FFI.en.md](../api/API_REFERENCE_FFI.en.md).

## Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Callback mechanism](#callback-mechanism)
- [JSON message format](#json-message-format)
- [Implementation status](#implementation-status)
- [Usage guide](#usage-guide)
- [Troubleshooting](#troubleshooting)
- [Fixed issues](#fixed-issues)

## Overview

The core of the binary-replacement scheme: after the dylib is swapped, the Tencent Cloud SDK's `NativeLibraryManager` keeps calling `bindings.DartXXX(...)` to invoke native symbols. Those `Dart*` symbols are implemented in tim2tox's `ffi/dart_compat_*.cpp` and ultimately delegate to `V2TIMManagerImpl` / `ToxManager` etc.

> For the end-to-end scheme, configuration, and call chain, read [BINARY_REPLACEMENT.en.md](BINARY_REPLACEMENT.en.md) first; this document focuses on the compatibility layer itself.

### Core ideas

1. **Signatures must match exactly**: every `Dart*` function's signature must match the declaration in `native_imsdk_bindings_generated.dart` — that is the ABI, any drift corrupts the caller's stack.
2. **Implement on demand**: only implement the `Dart*` functions that real UIKit / business code uses. The current count is whatever `grep -hE '^\s*(int|void|const char\*) Dart[A-Z]' ffi/dart_compat_*.cpp | sort -u` returns; don't hard-code a number here, it will drift.
3. **Callback bridging**: events flow back through `SendCallbackToDart` and `Dart_PostCObject_DL` to the Dart `SendPort`. The JSON shape matches the Tencent SDK contract.

### Benefits

- ✅ **Zero Dart code changes.**
- ✅ **Bounded effort**: implement only the `Dart*` functions that are actually called.
- ✅ **Compatible by design**: signatures and callback JSON track the Tencent SDK contract (re-verify on SDK upgrades).
- ✅ **Maintainable**: 13 modules split by responsibility — see [MODULARIZATION.en.md](MODULARIZATION.en.md).

## Architecture

```
Dart side (NativeLibraryManager)
    ↓ bindings.DartXXX(...)
    ↓ FFI dynamic lookup
C++ side (ffi/dart_compat_*.cpp)
    ↓ DartXXX() implementation
    ↓ parse JSON, convert params
    ↓ call V2TIM SDK API
V2TIM implementation (source/V2TIM*Impl.cpp)
    ↓ run via ToxManager
    ↓ listener callbacks
C++ side (listeners in dart_compat_listeners.cpp)
    ↓ build JSON messages
    ↓ SendCallbackToDart()
Dart side (ReceivePort)
    ↓ NativeLibraryManager._handleNativeMessage()
    ↓ dispatch to business listeners
```

### File layout

For module files, current sizes, and responsibilities, see [MODULARIZATION.en.md](MODULARIZATION.en.md). This document does not maintain a duplicate line-count table that will rot.

Callback / JSON utilities:

- `ffi/callback_bridge.{cpp,h}` — `SendPort` registration, `SendCallbackToDart`, `DartInitDartApiDL` / `DartRegisterSendPort`, etc.
- `ffi/json_parser.{cpp,h}` — `BuildGlobalCallbackJson` / `BuildApiCallbackJson`, `ParseJsonString` / `ExtractJsonValue` / `BuildJsonObject` and the rest of the JSON helpers.

Listener implementations are centralized in `ffi/dart_compat_listeners.cpp` (~2800 lines): `DartSDKListenerImpl`, `DartAdvancedMsgListenerImpl`, `DartFriendshipListenerImpl`, `DartConversationListenerImpl`, `DartGroupListenerImpl`, `DartSignalingListenerImpl`, `DartCommunityListenerImpl`.

## Callback mechanism

### Initialization

1. **Dart side: initialize Dart API**:
```dart
final result = bindings.DartInitDartApiDL(DartApiDL.initData);
```

2. **Dart side: register SendPort**:
```dart
final receivePort = ReceivePort();
bindings.DartRegisterSendPort(receivePort.sendPort.nativePort);
```

3. **C++ side: store the port** (parameter type `int64_t`, matching the Tencent SDK declaration in `native_imsdk_bindings_generated.dart`):
```cpp
void DartRegisterSendPort(int64_t send_port) {
    g_dart_port = static_cast<Dart_Port>(send_port);
}
```

### Event delivery

1. **C++ side fires the event** (excerpt from `dart_compat_listeners.cpp`):
```cpp
void DartAdvancedMsgListenerImpl::OnRecvNewMessage(const V2TIMMessage& message) {
    std::string json = BuildGlobalCallbackJson(
        GlobalCallbackType::ReceiveNewMessage,
        {{"json_message", MessageToJson(message)}}
    );
    SendCallbackToDart("globalCallback", json, /*user_data*/ nullptr);
}
```

2. **What `SendCallbackToDart` actually does** (`ffi/callback_bridge.cpp`):
   - Takes a mutex protecting `g_dart_port` / `g_dart_api_initialized`.
   - Size guard: drops messages larger than **1 MB** and logs an error.
   - Allocates with `malloc(message_len + 1)` and `memcpy` (NOT `strdup`).
   - Calls `Dart_PostCObject_DL`; if it returns false (post failed), `free`s the buffer to avoid a leak.
   - The `void* user_data` parameter is part of the signature but the current implementation does **not** write it into the message body — request correlation rides on the `user_data` JSON field instead.

3. **Dart side receives**:
```dart
receivePort.listen((message) {
  final json = jsonDecode(message as String);
  _handleNativeMessage(json);
});
```

### Callback types

#### Global Callback

Event notification:

```json
{
  "callback": "globalCallback",
  "callbackType": 7,
  "json_message": "{...}",
  "user_data": "..."
}
```

#### API Callback

API result:

```json
{
  "callback": "apiCallback",
  "user_data": "...",
  "code": 0,
  "desc": "OK",
  "json_...": "{...}"
}
```

## JSON message format

### Global Callback examples

Receive new message:

```json
{
  "callback": "globalCallback",
  "callbackType": 7,
  "json_message": "{\"msgID\":\"1234567890_user123\",\"timestamp\":1234567890,\"sender\":\"user123\",\"text\":\"Hello\"}",
  "user_data": ""
}
```

Friend added:

```json
{
  "callback": "globalCallback",
  "callbackType": 40,
  "json_friend_info_array": "[{\"userID\":\"user123\",\"nickName\":\"Alice\"}]",
  "user_data": ""
}
```

Group tips:

```json
{
  "callback": "globalCallback",
  "callbackType": 17,
  "json_group_tips_elem": "{\"type\":1,\"groupID\":\"group123\",\"memberList\":[{\"userID\":\"user123\"}]}",
  "user_data": ""
}
```

### API Callback examples

Login result:

```json
{
  "callback": "apiCallback",
  "user_data": "login_123",
  "code": 0,
  "desc": "OK"
}
```

Get friend list result:

```json
{
  "callback": "apiCallback",
  "user_data": "get_friend_list_456",
  "code": 0,
  "desc": "OK",
  "json_friend_info_array": "[{\"userID\":\"user123\",\"nickName\":\"Alice\"}]"
}
```

Send-message result:

```json
{
  "callback": "apiCallback",
  "user_data": "send_msg_789",
  "code": 0,
  "desc": "OK",
  "json_message": "{\"msgID\":\"1234567890_user123\",\"timestamp\":1234567890}"
}
```

### Field naming

JSON field names must match exactly what `NativeLibraryManager._handleGlobalCallback` / `_handleApiCallback` expect:

- `json_message` — message object
- `json_friend_info_array` — friend-info array
- `json_group_tips_elem` — group-tips element
- `json_conversation_array` — conversation array
- `json_signaling_info` — signaling info
- `json_topic_info` — topic info

Don't invent new field names — they are part of the ABI.

## Implementation status

### Infrastructure ✅

- `DartInitDartApiDL` / `DartRegisterSendPort` / `SendCallbackToDart` — implemented in `callback_bridge.cpp`.
- JSON build/parse utilities — `json_parser.cpp`.

### Listener implementations ✅

Per the current `dart_compat_listeners.cpp`, all of the following listeners have their core methods implemented. A few edge methods may still be partial — the source is authoritative.

- `DartSDKListenerImpl`: `OnConnectSuccess` / `OnConnectFailed` / `OnKickedOffline` / `OnUserSigExpired` / `OnSelfInfoUpdated` / `OnUserStatusChanged` / `OnUserInfoChanged` / `OnLog`
- `DartAdvancedMsgListenerImpl`: `OnRecvNewMessage` / `OnRecvMessageModified` / `OnRecvMessageRevoked` / `OnRecvMessageReadReceipts` / `OnRecvMessageExtensionsChanged` / `OnRecvMessageExtensionsDeleted` / `OnRecvMessageReactionChanged` / `OnRecvAllMessageReceiveOptionChanged` / `OnRecvGroupPinnedMessageChanged`
- `DartFriendshipListenerImpl`: friends / applications / blacklist / friend groups / official accounts / following
- `DartConversationListenerImpl`: conversation events + conversation groups
- `DartGroupListenerImpl`: `OnGroupTipsEvent` / `OnGroupAttributeChanged`
- `DartSignalingListenerImpl`: invite / cancel / accept / reject / timeout / modify
- `DartCommunityListenerImpl`: topic created / deleted / changed / REST custom data

### Business `Dart*` APIs

This document does not maintain a list of "all implemented `Dart*` functions" — it would rot. The authoritative source is the code:

```sh
# List all currently implemented Dart* C functions
grep -hE '^\s*(int|void|const char\*)\s+Dart[A-Z][A-Za-z0-9_]+\s*\(' ffi/dart_compat_*.cpp \
  | grep -oE 'Dart[A-Z][A-Za-z0-9_]+' \
  | sort -u
```

For module-by-module responsibilities, see [MODULARIZATION.en.md](MODULARIZATION.en.md). **A `Dart*` name absent from the listing typically means "not implemented"** — UIKit calls fall through to default behavior or return errors. To add one, follow [FFI_FUNCTION_DECLARATION_GUIDE.en.md](../development/FFI_FUNCTION_DECLARATION_GUIDE.en.md).

### V2TIM-to-JSON serialization helpers

Centralized in `dart_compat_utils.cpp` and `dart_compat_callbacks.cpp`: `MessageVectorToJson`, `FriendInfoVectorToJson`, `ConversationVectorToJson`, `MessageSearchResultToJson`, `FriendOperationResultVectorToJson`, etc. Add new ones in those files.

## Usage guide

### Callback-setter pattern

```cpp
void DartSetOnAddFriendCallback(void* user_data) {
    std::string userDataStr = user_data
        ? std::string(static_cast<const char*>(user_data))
        : "";

    static std::shared_ptr<DartFriendshipListenerImpl> listener =
        std::make_shared<DartFriendshipListenerImpl>(userDataStr);

    auto mgr = V2TIMManager::GetInstance()->GetFriendshipManager();
    mgr->AddFriendListener(listener.get());
}
```

### Business API pattern

```cpp
// Real DartLogin signature: int DartLogin(const char* user_id, const char* user_sig, void* user_data)
int DartLogin(const char* user_id, const char* user_sig, void* user_data) {
    std::string userDataStr = user_data
        ? std::string(static_cast<const char*>(user_data))
        : "";

    class LoginCb : public V2TIMCallback {
        std::string ud_;
    public:
        explicit LoginCb(std::string ud) : ud_(std::move(ud)) {}
        void OnSuccess() override {
            std::string json = BuildApiCallbackJson(ud_, {{"code","0"}, {"desc","OK"}});
            SendCallbackToDart("apiCallback", json, nullptr);
        }
        void OnError(int code, const V2TIMString& msg) override {
            std::string json = BuildApiCallbackJson(ud_, {
                {"code", std::to_string(code)},
                {"desc", msg.CString()},
            });
            SendCallbackToDart("apiCallback", json, nullptr);
        }
    };

    SafeGetV2TIMManager()->Login(
        V2TIMString(user_id ? user_id : ""),
        V2TIMString(user_sig ? user_sig : ""),
        new LoginCb(userDataStr)
    );
    return 0; // TIM_SUCC
}
```

### Listener pattern

```cpp
class DartAdvancedMsgListenerImpl : public V2TIMAdvancedMsgListener {
    std::string userData_;
public:
    explicit DartAdvancedMsgListenerImpl(std::string ud) : userData_(std::move(ud)) {}
    void OnRecvNewMessage(const V2TIMMessage& message) override {
        std::string messageJson = MessageToJson(message);
        std::string json = BuildGlobalCallbackJson(
            GlobalCallbackType::ReceiveNewMessage,
            {{"json_message", messageJson}},
            userData_
        );
        SendCallbackToDart("globalCallback", json, nullptr);
    }
    // ... other callbacks
};
```

### JSON build examples

Global callback:

```cpp
std::string json = BuildGlobalCallbackJson(
    GlobalCallbackType::ReceiveNewMessage,
    {
        {"json_message", messageJson},
        {"json_offlinePushInfo", pushInfoJson},
    },
    userDataStr
);
```

API callback:

```cpp
std::string json = BuildApiCallbackJson(
    userDataStr,
    {
        {"code", "0"},
        {"desc", "OK"},
        {"json_friend_info_array", friendListJson},
    }
);
```

## Debugging tips

### Enable verbose logs

`callback_bridge.cpp` and `json_parser.cpp` already emit `V2TIM_LOG(kError, ...)` / `V2TIM_LOG(kInfo, ...)` on hot paths. For more, configure CMake with `-DDEBUG=ON` / `-DTRACE=ON`.

### Inspect symbols

```bash
nm -D build/ffi/libtim2tox_ffi.dylib | grep Dart    # macOS
objdump -T build/ffi/libtim2tox_ffi.so | grep Dart  # Linux
```

`build_ffi.sh` already verifies that `Dart_PostCObject_DL` is exported.

### Trace callbacks in Dart

```dart
receivePort.listen((message) {
  print('Received callback: $message');
  _handleNativeMessage(jsonDecode(message as String));
});
```

## Troubleshooting

### Callback never fires

- Are `DartInitDartApiDL` / `DartRegisterSendPort` called in the right order (init first, then register)?
- Does `IsDartPortRegistered()` return true?
- Are you on the wrong path? Events on the Platform path go through `tim2tox_ffi_*` polling, which is a different mechanism.

### JSON field mismatch

- Field names must match `_handleGlobalCallback` / `_handleApiCallback` exactly.
- Field types (number vs string) matter — many fields are parsed with `int.parse(map['code'].toString())` defensively, but don't rely on that for new fields.

### Symbol not found

- Is the function inside an `extern "C"` block?
- Did you add the `.cpp` to `ffi/CMakeLists.txt`?
- Re-run `./build_ffi.sh` and `nm -D | grep` to check.

### Memory leaks

- Do not `free` strings already posted via `SendCallbackToDart` — the receiving Dart isolate frees them.
- If `Dart_PostCObject_DL` returns false, the caller must `free` (already handled in `callback_bridge.cpp`).

## Fixed issues

> Historical snapshot, kept for reference; the source of truth is the git history.

### 1. Conversation ID handling unified

Conversation APIs expect a prefixed ID (`c2c_xxx` / `group_xxx`); message APIs expect the base ID. Both are now mediated by two helpers in `dart_compat_utils.cpp`:

- Conversation-path functions (`DartPinConversation`, `DartGetConversation`, `DartDeleteConversation`, `DartSetConversationDraft`, `DartMarkConversation`) use `BuildFullConversationID`.
- Message-path functions (`DartSendMessage`, `DartGetHistoryMessageList`, `DartClearHistoryMessage`) use `ExtractBaseConversationID`.

### 2. Conversation JSON fields

`ConversationVectorToJson` now uses the unprefixed `userID` (C2C) / `groupID` (group) as `conv_id`; `MessageSearchResultToJson` follows the same rule. This eliminated the duplicate-conversation bug.

### 3. `PinConversation` `unreadCount` initialization

`V2TIMConversationManagerImpl::PinConversation()` no longer returns an uninitialized `unreadCount`; it either reads from the cache or explicitly sets 0.

### 4. Event callbacks now carry real lists

`OnConversationGroupCreated` / `OnConversationsAddedToGroup` / `OnConversationsDeletedFromGroup` no longer post `"[]"` placeholders; they now serialize via `ConversationVectorToJson(conversationList)`.

## Related documents

- [Tim2Tox Architecture](ARCHITECTURE.en.md)
- [Binary Replacement](BINARY_REPLACEMENT.en.md)
- [Modularization](MODULARIZATION.en.md)
- [Development Guide](../development/DEVELOPMENT_GUIDE.en.md)
- [FFI Function Declaration Guide](../development/FFI_FUNCTION_DECLARATION_GUIDE.en.md)
- [API_REFERENCE.en.md](../api/API_REFERENCE.en.md)
