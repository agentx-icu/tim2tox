# Tim2Tox 与 V2TIM 的关系
> 语言 / Language: [中文](PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.md) | [English](PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.en.md)

## 1. 整体架构（混合模式）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  App / UIKit / 测试                                                          │
│  - TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)            │
│  - TIMConversationManager.instance.addConversationListener(...) 等           │
└───────────────────────────────────────────┬─────────────────────────────────┘
                                            │
┌───────────────────────────────────────────▼─────────────────────────────────┐
│  tencent_cloud_chat_sdk（未替换，仍为原包）                                    │
│  - TencentCloudChatSdkPlatform（接口）                                        │
│  - TIMConversationManager / TIMMessageManager 等 adapter                      │
│  - 所有 API 最终调用 platform.xxx() 或 NativeLibraryManager（FFI）            │
└───────────────────────────────────────────┬─────────────────────────────────┘
                    │                                    │
        Platform 接口调用                     Binary-replacement FFI 调用
                    │                                    │
┌───────────────────▼──────────────────┐   ┌────────────▼─────────────────────┐
│  Tim2ToxSdkPlatform（Dart）           │   │  ffi/dart_compat_*.cpp（C++）     │
│  - 实现 TencentCloudChatSdkPlatform   │   │  - DartInitSDK / DartLogin / ...  │
│  - addConversationListener 等         │   │  - SafeGetV2TIMManager()          │
│  - _conversationListeners 等          │   │  - 调 V2TIM* 实现                 │
│  - globalCallback 分发（instance_id） │   │  - SendCallbackToDart             │
└───────────────────┬──────────────────┘   └────────────┬─────────────────────┘
                    │                                    │
                    │         Dart_PostCObject_DL        │
                    └────────────────┬───────────────────┘
                                     │
┌────────────────────────────────────▼─────────────────────────────────────────┐
│  Native 层（C++）                                                              │
│  - V2TIMManagerImpl（每实例一个，多实例时 instance_id 区分）                    │
│  - V2TIMConversationManagerImpl（每实例一个，由 V2TIMManagerImpl 构造时拥有）   │
│  - V2TIMSignalingManagerImpl（每实例一个）                                     │
│  - ToxManager / toxcore                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **二进制替换**：不替换 `tencent_cloud_chat_sdk` 的类，只替换**平台实例**（`TencentCloudChatSdkPlatform.instance`）和**Native 实现**（动态库换成 `libtim2tox_ffi`）。
- **Tim2ToxSdkPlatform**：实现 `TencentCloudChatSdkPlatform` 接口，所有"平台方法"（如 `addConversationListener`、`getConversationList`）由它处理；同时负责接收 Native 发来的 `globalCallback`，按 `instance_id` 分发给各 listener。
- **V2TIM***：C++ 里的业务实现（会话、消息、群组、信令等）。

> 重要：`V2TIMConversationManagerImpl` 不是单例 —— 它是 `V2TIMManagerImpl` 在构造时通过 `V2TIMConversationManagerImpl(V2TIMManagerImpl* owner)` 持有的成员对象（`source/V2TIMConversationManagerImpl.h:38`、`source/V2TIMManagerImpl.cpp` 构造点）。它通过 `manager_impl_` 字段反向引用所属实例，不需要 `GetInstance()` 或 `SetManagerImpl()`。`V2TIMSignalingManagerImpl` 同样为实例成员。

## 2. Tim2ToxSdkPlatform 与 V2TIM* 的对应关系

| 能力       | Dart 侧（Platform/Adapter）               | C++ 侧（V2TIM*） |
|------------|-------------------------------------------|------------------|
| 会话列表   | Platform.getConversationList / provider    | V2TIMConversationManagerImpl（`GetConversationList`、缓存、`PinConversation`） |
| 会话监听   | Platform.addConversationListener           | `V2TIMConversationManagerImpl::AddConversationListener` + dart_compat 注册 `DartConversationListenerImpl` |
| 会话变更回调 | Platform `_conversationListeners` + globalCallback 分发 | C++ 调 listener → dart_compat → `SendCallbackToDart("globalCallback", ...)` |
| 消息       | Platform + FFI send/poll                   | `V2TIMMessageManagerImpl` + Tox |
| 群组       | Platform + FFI                             | `V2TIMGroupManagerImpl` |
| 信令       | Platform + FFI                             | `V2TIMSignalingManagerImpl`（每实例） |

- **会话监听**：
  - **C++**：`V2TIMConversationManagerImpl::AddConversationListener` 只是把 `V2TIMConversationListener*` 放进 `listeners_`（见 `source/V2TIMConversationManagerImpl.cpp:73`）。`dart_compat_listeners.cpp` 在 Dart 调任意 `DartSetOnConvXxxCallback` 时通过 `GetOrCreateConversationListener()` 取得 `DartConversationListenerImpl` 并 `AddConversationListener` 进当前实例。
  - **Dart**：`Tim2ToxSdkPlatform.addConversationListener` 把 listener 存进 `_conversationListeners` 与按实例分组的 `_instanceConversationListeners[id]`；收到 `globalCallback(ConversationEvent)` 时按 `instance_id` 分发。
- 因此：**会话监听的"事件源"在 C++ `V2TIMConversationManagerImpl` + dart_compat；"接收与分发"在 Dart `Tim2ToxSdkPlatform`。**

## 3. addConversationListener 实现位置（历史问题与现状）

> 这一节描述的曾是一段历史 bug 与修复，现已落地，留作背景。

### 3.1 C++ 已实现 `AddConversationListener`

C++ 端 `V2TIMConversationManagerImpl::AddConversationListener` 直接 `listeners_.push_back(listener)`，无需在 Dart 端"再实现一层"。

### 3.2 历史 bug —— "addConversationListener has not been implemented"

历史上的报错根因不在 C++，而是 Dart 侧调用时机：

- `Tim2ToxSdkPlatform` 构造函数里 `_setupInternalConversationListener()` 会注册一个 internal listener。
- 如果在那里调 `TIMConversationManager.instance.addConversationListener(internalListener)`，adapter 内部会回到 `TencentCloudChatSdkPlatform.instance.addConversationListener(...)`。
- 但此时 `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)` 还**没有赋值完成**（构造函数尚未返回），`.instance` 仍是默认平台，默认实现是 `throw UnimplementedError(...)`。

### 3.3 修复（**已落地**）

`tim2tox_sdk_platform.dart:2266 / 2300-2305` 的当前实现：`_setupInternalConversationListener` 只调用 `this.addConversationListener(listener: internalListener)`，不再绕回 adapter。代码里有相应注释解释这个绕道：

```dart
// Don't call TIMConversationManager.instance.addConversationListener here: during
// construction, TencentCloudChatSdkPlatform.instance has not been assigned yet,
// so the adapter would call the default platform's addConversationListener (which
// throws UnimplementedError).
addConversationListener(listener: internalListener);
```

如果未来又需要把 internal listener 同步到 adapter，建议用 `Future.microtask(...)` 延后到下一轮事件循环，等 `.instance = Tim2ToxSdkPlatform(...)` 完成赋值再调。

## 4. 小结

- **混合模式下**：`Tim2ToxSdkPlatform` 是 Platform 实现，`V2TIM*` 是 Native 能力实现；两者通过 FFI + globalCallback 协作，Platform 按 `instance_id` 分发回 Dart listener。
- **会话监听链路**：C++ `AddConversationListener`（已在 `V2TIMConversationManagerImpl`） + `dart_compat_listeners.cpp` 注册 → globalCallback → Dart `Tim2ToxSdkPlatform._conversationListeners` → 业务 listener。
- 旧的"addConversationListener has not been implemented"报错来自构造期调用顺序，已修复 —— 现在内部 listener 走 `this.addConversationListener(...)`，不再触发"通过 adapter 调到尚未赋值的 instance"的环。
