# Tim2Tox FFI 兼容层
> 语言 / Language: [中文](FFI_COMPAT_LAYER.md) | [English](FFI_COMPAT_LAYER.en.md)

本文档解释 `Dart*` 兼容层（Binary Replacement 路径用的那组符号）的实现要点：架构、回调桥接、JSON 格式和实现现状。**`tim2tox_ffi_*` 那组 C API（Platform 路径用）是另一组接口**，见 [API_REFERENCE_FFI.md](../api/API_REFERENCE_FFI.md)。

## 目录

- [概述](#概述)
- [架构设计](#架构设计)
- [回调机制](#回调机制)
- [JSON 消息格式](#json-消息格式)
- [实现状态](#实现状态)
- [使用指南](#使用指南)
- [常见问题](#常见问题)
- [已修复问题](#已修复问题)

## 概述

Binary Replacement 方案的核心：替换动态库后，Tencent Cloud SDK 的 `NativeLibraryManager` 仍然通过 `bindings.DartXXX(...)` 调用 native 符号，这些 `Dart*` 符号由 tim2tox 在 `ffi/dart_compat_*.cpp` 中实现，最终调用 `V2TIMManagerImpl` / `ToxManager` 等 C++ 类。

> Binary Replacement 的整体方案、配置方式与调用链路请先读 [BINARY_REPLACEMENT.md](BINARY_REPLACEMENT.md)；本文聚焦兼容层本身。

### 核心思想

1. **函数签名完全匹配**：每个 `Dart*` 函数的签名必须与 `native_imsdk_bindings_generated.dart` 中声明的一致 —— 这是 ABI，任何漂移都会导致调用方栈错乱。
2. **按需实现**：只实现实际被业务/UIKit 使用的 `Dart*` 函数。当前已实现的符号总数请直接通过 `grep -hE '^\s*(int|void|const char\*) Dart[A-Z]' ffi/dart_compat_*.cpp | sort -u` 统计；切勿依赖文档里的固定数字，它会漂。
3. **回调桥接**：业务事件通过 `SendCallbackToDart` 经 `Dart_PostCObject_DL` 投递到 Dart 的 `SendPort`，JSON 形态与 Tencent SDK 约定一致。

### 优势

- ✅ **零 Dart 代码修改**：调用方代码不需要改。
- ✅ **工作量可控**：只实现真正用到的 `Dart*`。
- ✅ **设计兼容**：函数签名与回调 JSON 形状跟随 Tencent SDK 版本走（升级时双侧需同步验证）。
- ✅ **易于维护**：13 个功能模块按职责拆分，详见 [MODULARIZATION.md](MODULARIZATION.md)。

## 架构设计

```
Dart 层 (NativeLibraryManager)
    ↓ bindings.DartXXX(...)
    ↓ FFI 动态查找符号
C++ 层 (ffi/dart_compat_*.cpp)
    ↓ DartXXX() 函数实现
    ↓ JSON 解析 + 参数转换
    ↓ 调用 V2TIM SDK API
V2TIM 实现 (source/V2TIM*Impl.cpp)
    ↓ 通过 ToxManager 执行
    ↓ 监听器（Listener）回调
C++ 层 (Listener 实现，在 dart_compat_listeners.cpp)
    ↓ 转换为 JSON 消息
    ↓ SendCallbackToDart()
Dart 层 (ReceivePort)
    ↓ NativeLibraryManager._handleNativeMessage()
    ↓ 分发到业务监听器
```

### 文件分布

模块文件、当前规模与功能职责见 [MODULARIZATION.md](MODULARIZATION.md)。本文不重复维护一份会过时的行数表。

回调与 JSON 工具：

- `ffi/callback_bridge.cpp` / `callback_bridge.h` —— 注册 `SendPort`、`SendCallbackToDart`、`DartInitDartApiDL` / `DartRegisterSendPort` 等。
- `ffi/json_parser.cpp` / `json_parser.h` —— 构建 globalCallback / apiCallback JSON、解析入参 JSON、`ParseJsonString` / `ExtractJsonValue` / `BuildJsonObject` 等工具。

Listener 实现集中在 `ffi/dart_compat_listeners.cpp`（≈2800 行），包括 `DartSDKListenerImpl` / `DartAdvancedMsgListenerImpl` / `DartFriendshipListenerImpl` / `DartConversationListenerImpl` / `DartGroupListenerImpl` / `DartSignalingListenerImpl` / `DartCommunityListenerImpl`。

## 回调机制

### 初始化流程

1. **Dart 层初始化 Dart API**：
```dart
final result = bindings.DartInitDartApiDL(DartApiDL.initData);
```

2. **Dart 层注册 SendPort**：
```dart
final receivePort = ReceivePort();
bindings.DartRegisterSendPort(receivePort.sendPort.nativePort);
```

3. **C++ 层存储 SendPort**（参数为 int64_t，与 Tencent SDK 的 `native_imsdk_bindings_generated.dart` 完全一致）：
```cpp
void DartRegisterSendPort(int64_t send_port) {
    g_dart_port = static_cast<Dart_Port>(send_port);
}
```

### 回调发送流程

1. **C++ 层事件触发**（节选自 `dart_compat_listeners.cpp`）：
```cpp
void DartAdvancedMsgListenerImpl::OnRecvNewMessage(const V2TIMMessage& message) {
    std::string json = BuildGlobalCallbackJson(
        GlobalCallbackType::ReceiveNewMessage,
        {{"json_message", MessageToJson(message)}}
    );
    SendCallbackToDart("globalCallback", json, /*user_data*/ nullptr);
}
```

2. **`SendCallbackToDart` 实际实现要点**（`ffi/callback_bridge.cpp`）：
   - 取 mutex 保护 `g_dart_port` / `g_dart_api_initialized`。
   - 大小限制：单条消息超过 **1 MB** 直接丢弃并打 error 日志。
   - 用 `malloc(message_len + 1)` 分配，`memcpy` 拷贝；**不**使用 `strdup`。
   - 调用 `Dart_PostCObject_DL`；返回 false（投递失败）时 `free` 缓冲，避免内存泄漏。
   - 实际签名仍保留 `void* user_data` 参数，但当前实现没有把它写入消息体 —— 关联请求由 JSON 里的 `user_data` 字段承担。

3. **Dart 层接收消息**：
```dart
receivePort.listen((message) {
  final json = jsonDecode(message as String);
  _handleNativeMessage(json);
});
```

### 回调类型

#### Global Callback

事件通知，格式：

```json
{
  "callback": "globalCallback",
  "callbackType": 7,
  "json_message": "{...}",
  "user_data": "..."
}
```

#### API Callback

API 调用结果，格式：

```json
{
  "callback": "apiCallback",
  "user_data": "...",
  "code": 0,
  "desc": "OK",
  "json_...": "{...}"
}
```

## JSON 消息格式

### Global Callback 示例

接收新消息：

```json
{
  "callback": "globalCallback",
  "callbackType": 7,
  "json_message": "{\"msgID\":\"1234567890_user123\",\"timestamp\":1234567890,\"sender\":\"user123\",\"text\":\"Hello\"}",
  "user_data": ""
}
```

好友新增：

```json
{
  "callback": "globalCallback",
  "callbackType": 40,
  "json_friend_info_array": "[{\"userID\":\"user123\",\"nickName\":\"Alice\"}]",
  "user_data": ""
}
```

群组 tips：

```json
{
  "callback": "globalCallback",
  "callbackType": 17,
  "json_group_tips_elem": "{\"type\":1,\"groupID\":\"group123\",\"memberList\":[{\"userID\":\"user123\"}]}",
  "user_data": ""
}
```

### API Callback 示例

登录结果：

```json
{
  "callback": "apiCallback",
  "user_data": "login_123",
  "code": 0,
  "desc": "OK"
}
```

好友列表结果：

```json
{
  "callback": "apiCallback",
  "user_data": "get_friend_list_456",
  "code": 0,
  "desc": "OK",
  "json_friend_info_array": "[{\"userID\":\"user123\",\"nickName\":\"Alice\"}]"
}
```

发送消息结果：

```json
{
  "callback": "apiCallback",
  "user_data": "send_msg_789",
  "code": 0,
  "desc": "OK",
  "json_message": "{\"msgID\":\"1234567890_user123\",\"timestamp\":1234567890}"
}
```

### 字段命名规则

JSON 字段名必须与 `NativeLibraryManager._handleGlobalCallback` / `_handleApiCallback` 期望的完全匹配：

- `json_message`：消息对象
- `json_friend_info_array`：好友信息数组
- `json_group_tips_elem`：群组提示元素
- `json_conversation_array`：会话数组
- `json_signaling_info`：信令信息
- `json_topic_info`：话题信息

不要发明新字段名 —— 这是 ABI 的一部分。

## 实现状态

### 基础设施 ✅

- `DartInitDartApiDL` / `DartRegisterSendPort` / `SendCallbackToDart`：已实现，`callback_bridge.cpp`。
- JSON 解析与构建：`json_parser.cpp`。

### Listener 实现 ✅

按照 `dart_compat_listeners.cpp` 的现状，下列 Listener 的核心方法都已实现；个别极少使用的边缘回调以源码为准。

- `DartSDKListenerImpl`：`OnConnectSuccess` / `OnConnectFailed` / `OnKickedOffline` / `OnUserSigExpired` / `OnSelfInfoUpdated` / `OnUserStatusChanged` / `OnUserInfoChanged` / `OnLog`
- `DartAdvancedMsgListenerImpl`：`OnRecvNewMessage` / `OnRecvMessageModified` / `OnRecvMessageRevoked` / `OnRecvMessageReadReceipts` / `OnRecvMessageExtensionsChanged` / `OnRecvMessageExtensionsDeleted` / `OnRecvMessageReactionChanged` / `OnRecvAllMessageReceiveOptionChanged` / `OnRecvGroupPinnedMessageChanged`
- `DartFriendshipListenerImpl`：好友/申请/黑名单/分组/官方账号/关注全套
- `DartConversationListenerImpl`：会话变化 + 会话分组全套
- `DartGroupListenerImpl`：`OnGroupTipsEvent` / `OnGroupAttributeChanged`
- `DartSignalingListenerImpl`：邀请/取消/接受/拒绝/超时/修改
- `DartCommunityListenerImpl`：话题创建/删除/修改/REST 自定义数据

### 业务 `Dart*` API

不在本文维护一份"全部已实现的 `Dart*` 名单"——名单会随实现增删，最新可信来源是源码本身：

```sh
# 列出所有当前实现的 Dart* C 函数
grep -hE '^\s*(int|void|const char\*)\s+Dart[A-Z][A-Za-z0-9_]+\s*\(' ffi/dart_compat_*.cpp \
  | grep -oE 'Dart[A-Z][A-Za-z0-9_]+' \
  | sort -u
```

按模块的职责清单见 [MODULARIZATION.md](MODULARIZATION.md)。**没有被列出的 `Dart*` 名字通常意味着"未实现"** —— UIKit 调用会落到默认实现或返回错误。如果发现某个 Tencent SDK 期望的 `Dart*` 缺失，新增时按 [FFI_FUNCTION_DECLARATION_GUIDE.md](../development/FFI_FUNCTION_DECLARATION_GUIDE.md) 流程办。

### V2TIM 对象到 JSON 转换工具

序列化辅助函数集中在 `dart_compat_utils.cpp` 与 `dart_compat_callbacks.cpp`：`MessageVectorToJson`、`FriendInfoVectorToJson`、`ConversationVectorToJson`、`MessageSearchResultToJson`、`FriendOperationResultVectorToJson` 等。新增对象类型时建议在这两个文件里加。

## 使用指南

### 回调设置函数（典型模式）

```cpp
void DartSetOnAddFriendCallback(void* user_data) {
    // 1. 存储 user_data（转换为字符串）
    std::string userDataStr = user_data
        ? std::string(static_cast<const char*>(user_data))
        : "";

    // 2. 创建或获取 Listener 实例
    static std::shared_ptr<DartFriendshipListenerImpl> listener =
        std::make_shared<DartFriendshipListenerImpl>(userDataStr);

    // 3. 注册到 V2TIM
    auto mgr = V2TIMManager::GetInstance()->GetFriendshipManager();
    mgr->AddFriendListener(listener.get());
}
```

### 业务 API 函数（典型模式）

```cpp
// 真实 DartLogin 签名：int DartLogin(const char* user_id, const char* user_sig, void* user_data)
int DartLogin(const char* user_id, const char* user_sig, void* user_data) {
    std::string userDataStr = user_data
        ? std::string(static_cast<const char*>(user_data))
        : "";

    // 自定义 V2TIMCallback 子类把成功 / 失败发回 Dart
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

### Listener 实现（典型模式）

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
    // ... 其他回调
};
```

### JSON 构建示例

Global Callback：

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

API Callback：

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

## 调试技巧

### 启用调试日志

`callback_bridge.cpp` 与 `json_parser.cpp` 关键路径上已有 `V2TIM_LOG(kError, ...)` / `V2TIM_LOG(kInfo, ...)`。如需更细，可在 CMake 配置时打开 `-DDEBUG=ON` / `-DTRACE=ON`。

### 验证 JSON 格式

可以本地写一个最小 Dart `jsonDecode` 测试，对照 `NativeLibraryManager._handleGlobalCallback` 实际期待的形状。

### 检查函数符号

```bash
nm -D build/ffi/libtim2tox_ffi.dylib | grep Dart    # macOS
objdump -T build/ffi/libtim2tox_ffi.so | grep Dart  # Linux
```

`build_ffi.sh` 自带 `Dart_PostCObject_DL` 符号验证。

### 测试回调

在 Dart 层加日志：

```dart
receivePort.listen((message) {
  print('Received callback: $message');
  _handleNativeMessage(jsonDecode(message as String));
});
```

## 常见问题

### 回调不触发

- `DartInitDartApiDL` / `DartRegisterSendPort` 顺序是否正确（必须先 init 再 register）？
- `IsDartPortRegistered()` 是否返回 true？
- 是否走错路径 —— Platform 路径下事件经 `tim2tox_ffi_*` 投递，与 `SendCallbackToDart` 是两套。

### JSON 字段不匹配

- 检查字段名与 `NativeLibraryManager._handleGlobalCallback` / `_handleApiCallback` 期望的完全一致。
- 字段值类型（数字 vs 字符串）是否正确？很多字段在 Dart 端会用 `int.parse(map['code'].toString())` 兜底，但新增字段不要依赖。

### 函数符号未找到

- 是否在 `extern "C"` 块里？
- `ffi/CMakeLists.txt` 是否包含新增的 `.cpp` 文件？
- 重新 `./build_ffi.sh` 后 `nm -D | grep` 看一下。

### 内存泄漏

- 不要在 `SendCallbackToDart` 之外手动 `free` 已 post 出去的字符串 —— 由 Dart 接收方释放。
- `Dart_PostCObject_DL` 返回 false 时 caller 需要 `free`（`callback_bridge.cpp` 里有处理）。

## 已修复问题

> 历史快照，仅供参考；具体修复点请以 git history 为准。

### 1. Conversation ID 统一处理

会话相关接口要求带前缀的 `conversationID`（`c2c_xxx` / `group_xxx`），消息接口要求 base ID。已统一通过 `dart_compat_utils.cpp` 中的 `BuildFullConversationID()` / `ExtractBaseConversationID()` 两个辅助函数处理：

- 会话路径函数（`DartPinConversation` / `DartGetConversation` / `DartDeleteConversation` / `DartSetConversationDraft` / `DartMarkConversation`）：使用 `BuildFullConversationID`。
- 消息路径函数（`DartSendMessage` / `DartGetHistoryMessageList` / `DartClearHistoryMessage`）：使用 `ExtractBaseConversationID`。

### 2. 会话 JSON 字段

`ConversationVectorToJson` 现在使用不带前缀的 `userID`（C2C） / `groupID`（群）作为 `conv_id`；`MessageSearchResultToJson` 同步修复。重复会话问题由此解决。

### 3. `PinConversation` `unreadCount` 未初始化

`V2TIMConversationManagerImpl::PinConversation()` 不再返回未初始化的 `unreadCount`，改为从缓存读取或显式置 0。

### 4. 事件回调使用真实列表

`OnConversationGroupCreated` / `OnConversationsAddedToGroup` / `OnConversationsDeletedFromGroup` 不再投占位 `"[]"`，改用 `ConversationVectorToJson(conversationList)`。

## 相关文档

- [Tim2Tox 架构](ARCHITECTURE.md) — 整体架构
- [Binary Replacement](BINARY_REPLACEMENT.md) — 路径 A 整体方案
- [Modularization](MODULARIZATION.md) — `dart_compat_*` 模块当前规模与职责
- [开发指南](../development/DEVELOPMENT_GUIDE.md)
- [FFI 函数声明指南](../development/FFI_FUNCTION_DECLARATION_GUIDE.md)
- [API_REFERENCE.md](../api/API_REFERENCE.md) — 总索引
