# Tim2Tox API 参考 — Dart 包
> 语言 / Language: [中文](API_REFERENCE_DART.md) | [English](API_REFERENCE_DART.en.md)

本文档为 [API_REFERENCE.md](API_REFERENCE.md) 的 Dart 包部分。Dart 包名为 `tim2tox_dart`（路径依赖于 `tim2tox/dart/`），所有公开符号通过 `package:tim2tox_dart/tim2tox_dart.dart` 重导出。

## 概览

```
┌─────────────────────────────────────────────────┐
│  UIKit / 业务代码                                  │
└─────────────┬────────────────────────┬────────────┘
              │ (Platform 路径)         │ (Service 路径)
   Tim2ToxSdkPlatform ────────────►  FfiChatService
              │                        │
              └────► Tim2ToxFfi (dart:ffi) ────► libtim2tox_ffi
```

- `Tim2ToxFfi` —— `dart:ffi` 直接绑定，类型严格匹配 C 签名（`Pointer<Utf8>`、`Pointer<Int8>` 等）。
- `FfiChatService` —— 应用应直接使用的服务层；管理初始化、轮询、历史、Stream、多实例注册等。
- `Tim2ToxSdkPlatform` —— 实现 `TencentCloudChatSdkPlatform`，把 UIKit / 业务侧的 SDK 调用路由到 `FfiChatService`。

### Tim2ToxFfi

底层 `dart:ffi` 绑定。**字段是函数对象（`late final ... Function(...)`），不是方法**；签名与 C 一致，使用 FFI 指针类型。

**文件**：`dart/lib/ffi/tim2tox_ffi.dart`

```dart
class Tim2ToxFfi {
  static Tim2ToxFfi open();

  // C 签名：int tim2tox_ffi_init(void);
  late final int Function() init;

  // C 签名：int tim2tox_ffi_login(const char* user_id, const char* user_sig);
  late final int Function(Pointer<Utf8>, Pointer<Utf8>) login;

  // C 签名：int tim2tox_ffi_poll_text(int64_t instance_id, char* buffer, int buffer_len);
  late final int Function(int, Pointer<Int8>, int) pollText;

  // C 签名：int tim2tox_ffi_get_login_user(char* buffer, int buffer_len);
  late final int Function(Pointer<Int8>, int) getLoginUser;

  // ToxAV / 信令 / IRC / Profile crypto / 多实例 / DHT 等 100+ 个绑定
  // —— 请直接看源码或 API_REFERENCE_FFI.md
  late final int  Function(int)      avInitialize;
  late final void Function(int)      avShutdown;
  late final void Function(int)      avIterate;
  // ... 等等
}
```

> 应用通常**不直接**使用 `Tim2ToxFfi`。除非你在写测试或低层适配代码，否则用 `FfiChatService`。

### FfiChatService

应用入口的服务层。**所有 Dart 侧的状态（消息历史、轮询计时器、Stream、多实例上下文）都集中在它里面。**

**文件**：`dart/lib/service/ffi_chat_service.dart`

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
    // ...（详见构造函数）
  });

  // 生命周期
  Future<void> init({String? profileDirectory});
  Future<void> uninit();
  Future<void> login({required String userId, required String userSig});
  Future<void> logout();

  // 轮询：login 后**必须显式启动**，否则不会有事件到达 Dart
  Future<void> startPolling();
  Future<void> stopPolling();

  // 发送（注意命名）
  Future<void>     sendText(String peerId, String text);
  Future<void>     sendTyping(String peerId, bool on);
  Future<bool>     sendC2CCustom(String peerId, Uint8List data);
  Future<bool>     sendGroupCustom(String groupId, Uint8List data);
  Future<bool>     sendGroupText(String groupId, String text);

  // 历史
  List<ChatMessage>       getHistory(String conversationId);
  Future<void>            clearHistory(String conversationId);

  // Streams
  Stream<ChatMessage>     get messages;
  Stream<bool>            get connectionStatusStream;
  // ... 群事件、信令事件、好友事件等多个 Stream
}
```

> 旧名 `sendMessage` / `setTyping` 已**不存在**。直接发送使用 `sendText` / `sendTyping`；如果你的代码走 V2TIM 风格的 `sendMessage(...)`，走的是 `Tim2ToxSdkPlatform`，不是 `FfiChatService`。

### Tim2ToxSdkPlatform

实现 `TencentCloudChatSdkPlatform` 接口；客户端做 `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)` 后，UIKit / 业务侧的 V2TIM 风格调用会被路由到本类，再委托给 `FfiChatService`。

**文件**：`dart/lib/sdk/tim2tox_sdk_platform.dart`

```dart
class Tim2ToxSdkPlatform extends TencentCloudChatSdkPlatform {
  Tim2ToxSdkPlatform({
    required FfiChatService ffiService,
    EventBusProvider?              eventBusProvider,
    ConversationManagerProvider?   conversationManagerProvider,
    ExtendedPreferencesService?    preferencesService,
  });

  // 真实返回类型：Future<V2TimValueCallback<bool>>
  @override
  Future<V2TimValueCallback<bool>> initSDK({ /* sdkAppID, loglevel, listener, ... */ });

  @override
  Future<V2TimCallback> login({required String userID, required String userSig});

  @override
  Future<V2TimCallback> logout();

  // 发送消息（V2TIM 风格命名）
  @override
  Future<V2TimValueCallback<V2TimMessage>> sendMessage({ /* ... */ });

  // 历史、好友、群组、会话、信令等 70+ @override 方法
  // 完整接口看 TencentCloudChatSdkPlatform 抽象类
}
```

> `Tim2ToxSdkPlatform` 目前是一个 ~8 千行的单体（70+ `@override`），按 V2TIM 接口的所有方法逐一委托。重构计划在 ARCHITECTURE.md §10 简要提及。

## 接口

Tim2Tox 不绑定具体客户端 —— 它通过下列接口接收 Preferences / Logger / Bootstrap / EventBus / ConversationManager 注入。所有接口在 `dart/lib/interfaces/`。

### PreferencesService / ExtendedPreferencesService

`ExtendedPreferencesService` 继承自 `PreferencesService`（基础键值访问），额外约束群、好友资料、Bootstrap、头像、黑名单等 ~40 个领域方法。**`FfiChatService` 与 `Tim2ToxSdkPlatform` 都要求 ExtendedPreferencesService，不能仅实现 PreferencesService。**

精简清单（完整定义见 `dart/lib/interfaces/extended_preferences_service.dart`）：

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
  // 群
  Future<Set<String>> getGroups();
  Future<void>        setGroups(Set<String> groups);
  Future<Set<String>> getQuitGroups();
  Future<void>        setQuitGroups(Set<String> groups);
  Future<void>        addQuitGroup(String groupId);
  Future<void>        removeQuitGroup(String groupId);

  // 自身头像 / 友头像 / 友昵称
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

  // 本地好友 (Tox ID 集合)
  Future<Set<String>> getLocalFriends();
  Future<void>        setLocalFriends(Set<String> ids);

  // Bootstrap
  Future<String> getBootstrapNodeMode();                                           // "default" / "custom"
  Future<({String host, int port, String pubkey})?> getCurrentBootstrapNode();
  Future<void>   setCurrentBootstrapNode(String host, int port, String pubkey);

  // 下载与文件接收
  Future<int>     getAutoDownloadSizeLimit();
  Future<void>    setAutoDownloadSizeLimit(int sizeInMB);
  Future<String?> getDownloadsDirectory();
  Future<void>    setDownloadsDirectory(String? path);
  Future<String?> getAvatarPath();
  Future<void>    setAvatarPath(String? path);

  // 群资料（Dart 侧持久化，C++ 不存）
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

  // 黑名单（可选 userToxId 表示要哪个账号视角的列表）
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

`EventBus` 是一个最小的 `add(event)` / `on<T>()` 接口（详见 `event_bus.dart`），客户端可以适配自己的事件总线。

### ConversationManagerProvider

```dart
abstract class ConversationManagerProvider {
  Future<List<FakeConversation>> getConversationList();
  Future<void>                   setPinned(String conversationID, bool isPinned);
  Future<void>                   deleteConversation(String conversationID);
  Future<int>                    getTotalUnreadCount();
}
```

## 相关文档

- [API_REFERENCE.md](API_REFERENCE.md) — 总索引、数据类型、错误码、示例
- [API_REFERENCE_V2TIM.md](API_REFERENCE_V2TIM.md) — V2TIM C++ 接口
- [API_REFERENCE_FFI.md](API_REFERENCE_FFI.md) — C FFI 接口
- [BINARY_REPLACEMENT.md](../architecture/BINARY_REPLACEMENT.md) — 二进制替换路径下的 Dart 层接入
- [BOOTSTRAP_AND_POLLING.md](../integration/BOOTSTRAP_AND_POLLING.md) — `startPolling` 时机与节奏
