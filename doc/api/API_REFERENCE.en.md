# Tim2Tox API Reference
> Language: [Chinese](API_REFERENCE.md) | [English](API_REFERENCE.en.md)

This document is the index for Tim2Tox API reference. Detailed APIs are split into separate documents by module.

## Contents

- [V2TIM C++ API](API_REFERENCE_V2TIM.en.md) — C++ V2TIM interface (compatible with Tencent Cloud IM SDK)
- [C FFI Interface](API_REFERENCE_FFI.en.md) — C bindings for Dart FFI
- [Dart Package API](API_REFERENCE_DART.en.md) — Dart high-level API and interface definitions
- [Data Types](#data-types) — Common data types (this document)
- [Callback Types](#callback-types)
- [Error Codes](#error-codes)
- [Usage Examples](#usage-examples)
- [Related documents](#related-documents)

## Data Types

### V2TIMString

String type, compatible with C++ and Dart.

```cpp
class V2TIMString {
    const char* CString() const;
    // ...
};
```

### V2TIMBuffer

Binary data buffer.

```cpp
class V2TIMBuffer {
    const uint8_t* Data() const;
    size_t Size() const;
    // ...
};
```

### V2TIMMessage

Message object. Only the most common fields are shown — see `include/V2TIMMessage.h:302` for the full definition.

```cpp
struct V2TIMMessage : V2TIMBaseObject {
    V2TIMString msgID;
    int64_t     timestamp;
    V2TIMString sender;
    V2TIMString groupID;        // Group ID for group messages (empty for C2C)
    V2TIMString userID;         // Peer account ID (C2C scenario)
    V2TIMElemVector elemList;   // Message elements (text / image / file / custom)
    // ...(status, isSelf, isRead, cloudCustomData, localCustomData, etc.)
};
```

### V2TIMFriendInfo

Friend information (`include/V2TIMFriendship.h:249`). Note that `nickName` and `faceURL` are not top-level — they live inside the nested `userFullInfo` field.

```cpp
struct V2TIMFriendInfo {
    V2TIMString        userID;            // Friend ID
    V2TIMString        friendRemark;       // Friend remark (≤ 96 bytes)
    uint64_t           friendAddTime;      // UTC timestamp when added
    V2TIMCustomInfo    friendCustomInfo;
    V2TIMStringVector  friendGroups;       // Friend group memberships
    V2TIMUserFullInfo  userFullInfo;       // Nested: holds nickName / faceURL / etc.
    uint32_t           modifyFlag;         // Bitwise V2TIMFriendInfoModifyFlag
};
```

### V2TIMGroupInfo

Group information (`include/V2TIMGroup.h:324`; note the actual field order is groupID → groupType → groupName).

```cpp
struct V2TIMGroupInfo {
    V2TIMString groupID;
    V2TIMString groupType;      // "group" (new API) or "conference" (old API)
    V2TIMString groupName;
    V2TIMString notification;   // Group announcement (Group type only; maps to tox_group_topic)
    V2TIMString introduction;
    // ...(faceURL, owner, createTime, memberCount, ...)
};
```

**V2TIMGroupMemberFullInfo** (`include/V2TIMGroup.h:211`, inherits from `V2TIMGroupMemberInfo`):

```cpp
// Parent V2TIMGroupMemberInfo provides: userID / nickName / friendRemark / nameCard / faceURL / onlineDevices
struct V2TIMGroupMemberFullInfo : public V2TIMGroupMemberInfo {
    V2TIMCustomInfo customInfo;
    uint32_t        role;        // V2TIM_GROUP_MEMBER_ROLE_{OWNER,ADMIN,MEMBER}
    uint32_t        muteUntil;   // Mute-until timestamp
    int64_t         joinTime;
    bool            isOnline;
    uint32_t        modifyFlag;
};
```

> tim2tox specifics: `nickName` is taken from friend info; `nameCard` comes from `tox_group_peer_get_name` and is only meaningful for Group-type groups.

## Callback Types

### V2TIMCallback

Universal callback interface (`include/V2TIMCallback.h:34`). It is an abstract class — subclass it and override the two virtual methods; you cannot construct it directly from a pair of lambdas.

```cpp
class V2TIMCallback : public V2TIMBaseCallback {
    virtual void OnSuccess() = 0;
    virtual void OnError(int error_code, const V2TIMString& error_message) = 0;
};
```

### V2TIMValueCallback

Callback with a typed result (`include/V2TIMCallback.h:59`).

```cpp
template<class T>
class V2TIMValueCallback : public V2TIMBaseCallback {
    virtual void OnSuccess(const T& value) = 0;
    virtual void OnError(int error_code, const V2TIMString& error_message) = 0;
};
```

### V2TIMSendCallback

Message-sending callback (`include/V2TIMCallback.h:101`, inherits from `V2TIMValueCallback<V2TIMMessage>` — so `OnSuccess(const V2TIMMessage&)` comes from the base).

```cpp
class V2TIMSendCallback : public V2TIMValueCallback<V2TIMMessage> {
    // OnSuccess(const V2TIMMessage&) and OnError(...) are inherited
    virtual void OnProgress(uint32_t progress) = 0;
};
```

## Error Codes

Common error codes are defined in `include/V2TIMErrorCode.h`:

- `ERR_SUCC` (0): Success
- `ERR_SDK_NOT_INITIALIZED` (6013): SDK not initialized
- `ERR_INVALID_PARAMETERS` (6017): Invalid parameter
- `ERR_USER_SIG_EXPIRED` (6206): User signature expired
- `ERR_SDK_COMM_API_CALL_FREQUENCY_LIMIT` (7008): API call frequency limit

## Usage Examples

### C++ Usage Example

`V2TIMCallback` / `V2TIMSendCallback` are abstract — subclass them to provide the overrides:

```cpp
#include <V2TIMManager.h>

class MyCallback : public V2TIMCallback {
public:
    void OnSuccess() override { /* success */ }
    void OnError(int code, const V2TIMString& msg) override { /* failed */ }
};

int main() {
    // Initialize SDK
    V2TIMSDKConfig config;
    config.logLevel = V2TIM_LOG_DEBUG;
    V2TIMManager::GetInstance()->InitSDK(123456, config);

    // Login
    V2TIMManager::GetInstance()->Login(
        V2TIMString("user123"),
        V2TIMString("userSig"),
        new MyCallback()
    );

    // Send message
    // Real signature (include/V2TIMMessageManager.h:235):
    //   virtual V2TIMString SendMessage(V2TIMMessage& message,
    //                                   const V2TIMString& receiver,
    //                                   const V2TIMString& groupID,
    //                                   V2TIMMessagePriority priority,
    //                                   bool onlineUserOnly,
    //                                   const V2TIMOfflinePushInfo& offlinePushInfo,
    //                                   V2TIMSendCallback* callback) = 0;
    auto* msgMgr = V2TIMManager::GetInstance()->GetMessageManager();
    V2TIMMessage msg = msgMgr->CreateTextMessage(V2TIMString("Hello"));
    V2TIMOfflinePushInfo emptyPushInfo;
    V2TIMString msgID = msgMgr->SendMessage(
        msg,
        /*receiver=*/V2TIMString("friend123"),
        /*groupID=*/V2TIMString(),                       // empty for C2C
        V2TIMMessagePriority::V2TIM_PRIORITY_NORMAL,
        /*onlineUserOnly=*/false,
        emptyPushInfo,
        new MySendCallback()                              // your subclass
    );
    return 0;
}
```

### Dart Usage Example

```dart
import 'package:tim2tox_dart/tim2tox_dart.dart';

// Create the service
final ffiService = FfiChatService(
  preferencesService: prefsAdapter,           // ExtendedPreferencesService impl
  loggerService: loggerAdapter,
  bootstrapService: bootstrapAdapter,
);

// Initialize
await ffiService.init();

// Login
await ffiService.login(userId: userID, userSig: userSig);

// Send a C2C text message (note: the method is sendText, not sendMessage)
await ffiService.sendText(peerId, "Hello");

// Listen for messages
ffiService.messages.listen((message) {
  print('Received: ${message.text}');
});
```

> The Platform path (`Tim2ToxSdkPlatform`) exposes V2TIM-style names (`sendMessage` etc.) — see [API_REFERENCE_DART.en.md](API_REFERENCE_DART.en.md). `FfiChatService` itself uses the direct lower-level names (`sendText` / `sendTyping` / `sendC2CCustom` / ...); don't confuse the two.

## Related documents

- [Development Guide](../development/DEVELOPMENT_GUIDE.en.md) - How to add new features and extensions
- [Tim2Tox Architecture](../architecture/ARCHITECTURE.en.md) - Overall architecture design
- [Tim2Tox FFI compatibility layer](../architecture/FFI_COMPAT_LAYER.en.md) - Dart* function compatibility layer description
