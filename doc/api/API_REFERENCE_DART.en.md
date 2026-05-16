# Tim2Tox API Reference — Dart Package
> Language: [Chinese](API_REFERENCE_DART.md) | [English](API_REFERENCE_DART.en.md)

This document is the Dart sub-volume of [API_REFERENCE.en.md](API_REFERENCE.en.md). The Dart package is named `tim2tox_dart` (path dependency on `tim2tox/dart/`); all public symbols are re-exported through `package:tim2tox_dart/tim2tox_dart.dart`.

## Overview

```
┌─────────────────────────────────────────────────┐
│  UIKit / Application code                         │
└─────────────┬────────────────────────┬────────────┘
              │ (Platform path)         │ (Service path)
   Tim2ToxSdkPlatform ────────────►  FfiChatService
              │                        │
              └────► Tim2ToxFfi (dart:ffi) ────► libtim2tox_ffi
```

- `Tim2ToxFfi` — direct `dart:ffi` bindings; signatures match C exactly (`Pointer<Utf8>`, `Pointer<Int8>`, …).
- `FfiChatService` — the service layer apps should use; owns init / polling / history / streams / multi-instance context.
- `Tim2ToxSdkPlatform` — implements `TencentCloudChatSdkPlatform`; routes UIKit-style SDK calls to `FfiChatService`.

### Tim2ToxFfi

Low-level `dart:ffi` bindings. **Members are function-typed fields (`late final ... Function(...)`), not methods**; signatures mirror C exactly and use FFI pointer types.

**File**: `dart/lib/ffi/tim2tox_ffi.dart`

```dart
class Tim2ToxFfi {
  static Tim2ToxFfi open();

  // C signature: int tim2tox_ffi_init(void);
  late final int Function() init;

  // C signature: int tim2tox_ffi_login(const char* user_id, const char* user_sig);
  late final int Function(Pointer<Utf8>, Pointer<Utf8>) login;

  // C signature: int tim2tox_ffi_poll_text(int64_t instance_id, char* buffer, int buffer_len);
  late final int Function(int, Pointer<Int8>, int) pollText;

  // C signature: int tim2tox_ffi_get_login_user(char* buffer, int buffer_len);
  late final int Function(Pointer<Int8>, int) getLoginUser;

  // 100+ more bindings (ToxAV / signaling / IRC / profile crypto / multi-instance / DHT / ...)
  // See the source or API_REFERENCE_FFI.en.md.
  late final int  Function(int)      avInitialize;
  late final void Function(int)      avShutdown;
  late final void Function(int)      avIterate;
  // ...
}
```

> Applications typically should **not** use `Tim2ToxFfi` directly. Reach for `FfiChatService` unless you're writing low-level glue or tests.

### FfiChatService

The application-facing service layer. **All Dart-side state — message history, polling timers, streams, multi-instance context — lives here.**

**File**: `dart/lib/service/ffi_chat_service.dart`

```dart
class FfiChatService {
  FfiChatService({
    required ExtendedPreferencesService preferencesService,
    required LoggerService              loggerService,
    BootstrapService?                   bootstrapService,
    EventBusProvider?                   eventBusProvider,
    ConversationManagerProvider?        conversationManagerProvider,
    MessageHistoryPersistence?          messageHistoryPersistence,
    OfflineMessageQueuePersistence?     offlineMessageQueuePersistence,
    Tim2ToxFailedMessagePersistence?    failedMessagePersistence,
    String?                             historyDirectory,
    String?                             queueFilePath,
    String?                             fileRecvPath,
    String?                             avatarsPath,
    // ...(see constructor)
  });

  // Lifecycle
  Future<void> init({String? profileDirectory});
  Future<void> uninit();
  Future<void> login({required String userId, required String userSig});
  Future<void> logout();

  // Polling: after login you MUST start it explicitly, or no events will reach Dart.
  Future<void> startPolling();
  Future<void> stopPolling();

  // Send (note the names)
  Future<void>     sendText(String peerId, String text);
  Future<void>     sendTyping(String peerId, bool on);
  Future<bool>     sendC2CCustom(String peerId, Uint8List data);
  Future<bool>     sendGroupCustom(String groupId, Uint8List data);
  Future<bool>     sendGroupText(String groupId, String text);

  // History
  List<ChatMessage>       getHistory(String conversationId);
  Future<void>            clearHistory(String conversationId);

  // Streams
  Stream<ChatMessage>     get messages;
  Stream<bool>            get connectionStatusStream;
  // ...plus several streams for group events, signaling, friend events
}
```

> The old names `sendMessage` / `setTyping` do **not** exist on `FfiChatService`. For direct sends use `sendText` / `sendTyping`. If your code calls a V2TIM-style `sendMessage(...)`, it is going through `Tim2ToxSdkPlatform`, not `FfiChatService`.

### Tim2ToxSdkPlatform

Implements the `TencentCloudChatSdkPlatform` interface. Once a client does `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)`, V2TIM-style SDK calls from UIKit / business code are routed through this class and delegated to `FfiChatService`.

**File**: `dart/lib/sdk/tim2tox_sdk_platform.dart`

```dart
class Tim2ToxSdkPlatform extends TencentCloudChatSdkPlatform {
  Tim2ToxSdkPlatform({
    required FfiChatService ffiService,
    EventBusProvider?              eventBusProvider,
    ConversationManagerProvider?   conversationManagerProvider,
    ExtendedPreferencesService?    preferencesService,
  });

  // Real return type: Future<V2TimValueCallback<bool>>
  @override
  Future<V2TimValueCallback<bool>> initSDK({ /* sdkAppID, loglevel, listener, ... */ });

  @override
  Future<V2TimCallback> login({required String userID, required String userSig});

  @override
  Future<V2TimCallback> logout();

  // Send message (V2TIM-style naming)
  @override
  Future<V2TimValueCallback<V2TimMessage>> sendMessage({ /* ... */ });

  // 70+ more @override methods covering history, friends, groups, conversations, signaling, etc.
  // The full surface is the TencentCloudChatSdkPlatform abstract class.
}
```

> `Tim2ToxSdkPlatform` is currently a ~8 kLOC monolith (70+ `@override`s), delegating each V2TIM method to `FfiChatService`. A refactor is mentioned in ARCHITECTURE.en.md §10.

## Interfaces

Tim2Tox is not tied to any specific client — it receives Preferences / Logger / Bootstrap / EventBus / ConversationManager via the interfaces below. All interfaces live in `dart/lib/interfaces/`.

### PreferencesService / ExtendedPreferencesService

`ExtendedPreferencesService` extends `PreferencesService` (basic key/value access) and adds ~40 domain methods for groups, friend info, Bootstrap, avatars, blacklist, etc. **Both `FfiChatService` and `Tim2ToxSdkPlatform` require an `ExtendedPreferencesService` — a bare `PreferencesService` is not enough.**

Condensed surface (full definition in `dart/lib/interfaces/extended_preferences_service.dart`):

```dart
abstract class PreferencesService {
  Future<String?> getString(String key);
  Future<void>    setString(String key, String value);
  Future<bool?>   getBool(String key);
  Future<void>    setBool(String key, bool value);
  Future<int?>    getInt(String key);
  Future<void>    setInt(String key, int value);
  Future<void>    remove(String key);
}

abstract class ExtendedPreferencesService extends PreferencesService {
  // Groups
  Future<Set<String>> getGroups();
  Future<void>        setGroups(Set<String> groups);
  Future<Set<String>> getQuitGroups();
  Future<void>        setQuitGroups(Set<String> groups);
  Future<void>        addQuitGroup(String groupId);
  Future<void>        removeQuitGroup(String groupId);

  // Self avatar / friend avatar / friend nickname
  Future<String?> getSelfAvatarHash();
  Future<void>    setSelfAvatarHash(String? hash);
  Future<String?> getFriendNickname(String friendId);
  Future<void>    setFriendNickname(String friendId, String nickname);
  Future<String?> getFriendStatusMessage(String friendId);
  Future<void>    setFriendStatusMessage(String friendId, String statusMessage);
  Future<String?> getFriendAvatarPath(String friendId);
  Future<void>    setFriendAvatarPath(String friendId, String? path);
  Future<String?> getFriendAvatarHash(String friendId);
  Future<void>    setFriendAvatarHash(String friendId, String hash);

  // Local friends (set of Tox IDs)
  Future<Set<String>> getLocalFriends();
  Future<void>        setLocalFriends(Set<String> ids);

  // Bootstrap
  Future<String> getBootstrapNodeMode();                                           // "default" / "custom"
  Future<({String host, int port, String pubkey})?> getCurrentBootstrapNode();
  Future<void>   setCurrentBootstrapNode(String host, int port, String pubkey);

  // Downloads / file recv
  Future<int>     getAutoDownloadSizeLimit();
  Future<void>    setAutoDownloadSizeLimit(int sizeInMB);
  Future<String?> getDownloadsDirectory();
  Future<void>    setDownloadsDirectory(String? path);
  Future<String?> getAvatarPath();
  Future<void>    setAvatarPath(String? path);

  // Group metadata (persisted on the Dart side; C++ does not store this)
  Future<String?> getGroupName(String groupId);
  Future<void>    setGroupName(String groupId, String name);
  Future<String?> getGroupAvatar(String groupId);
  Future<void>    setGroupAvatar(String groupId, String? avatarPath);
  Future<String?> getGroupNotification(String groupId);
  Future<void>    setGroupNotification(String groupId, String? notification);
  Future<String?> getGroupIntroduction(String groupId);
  Future<void>    setGroupIntroduction(String groupId, String? introduction);
  Future<String?> getGroupOwner(String groupId);
  Future<void>    setGroupOwner(String groupId, String ownerId);
  Future<String?> getGroupChatId(String groupId);
  Future<void>    setGroupChatId(String groupId, String chatId);

  // Blacklist (optional userToxId selects which account's view)
  Future<Set<String>> getBlackList([String? userToxId]);
  Future<void>        setBlackList(Set<String> userIDs, [String? userToxId]);
  Future<void>        addToBlackList(List<String> userIDs, [String? userToxId]);
  Future<void>        removeFromBlackList(List<String> userIDs, [String? userToxId]);
}
```

### LoggerService

```dart
abstract class LoggerService {
  void log(String message);
  void logWarning(String message);
  void logError(String message, [Object? error, StackTrace? stack]);
  void logDebug(String message);
}
```

### BootstrapService

```dart
abstract class BootstrapService {
  Future<String?> getBootstrapHost();
  Future<int?>    getBootstrapPort();
  Future<String?> getBootstrapPublicKey();
  Future<void>    setBootstrapNode({required String host, required int port, required String publicKey});
}
```

### EventBus / EventBusProvider

```dart
abstract class EventBusProvider {
  EventBus get eventBus;
}
```

`EventBus` is a minimal `add(event)` / `on<T>()` interface (see `event_bus.dart`); clients can adapt their own bus.

### ConversationManagerProvider

```dart
abstract class ConversationManagerProvider {
  Future<List<FakeConversation>> getConversationList();
  Future<void>                   setPinned(String conversationID, bool isPinned);
  Future<void>                   deleteConversation(String conversationID);
  Future<int>                    getTotalUnreadCount();
}
```

## Related documents

- [API_REFERENCE.en.md](API_REFERENCE.en.md) — index, data types, error codes, examples
- [API_REFERENCE_V2TIM.en.md](API_REFERENCE_V2TIM.en.md) — V2TIM C++ interface
- [API_REFERENCE_FFI.en.md](API_REFERENCE_FFI.en.md) — C FFI interface
- [BINARY_REPLACEMENT.en.md](../architecture/BINARY_REPLACEMENT.en.md) — Dart-side wiring for the binary-replacement path
- [BOOTSTRAP_AND_POLLING.en.md](../integration/BOOTSTRAP_AND_POLLING.en.md) — When and how to drive `startPolling`
