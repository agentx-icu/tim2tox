[English](./ARCHITECTURE.md)

# Tim2Tox 深度架构文档

本文档面向**框架维护者**与**二次集成工程师**，说明 Tim2Tox 如何将 UIKit 侧调用映射到 Tox 网络协议、各层边界、双路径设计原因，以及 Bootstrap、轮询、回调桥接与消息/会话/好友/群组管理的协作方式。偏技术参考，非产品介绍。

## 目录

- [1. 核心设计目标](#1-核心设计目标)
- [2. 技术约束](#2-技术约束)
- [3. 分层架构](#3-分层架构)
- [4. 关键目录与关键类](#4-关键目录与关键类)
- [5. 典型调用链](#5-典型调用链)
- [6. FFI 边界设计原则](#6-ffi-边界设计原则)
- [7. 回调桥接机制](#7-回调桥接机制)
- [8. Bootstrap 与 Polling](#8-bootstrap-与-polling)
- [9. 多实例支持的用途与边界](#9-多实例支持的用途与边界)
- [10. 与接入客户端的关系](#10-与接入客户端的关系)
- [11. 常见扩展方式](#11-常见扩展方式)
- [12. 风险点与测试建议](#12-风险点与测试建议)

---

## 1. 核心设计目标

| 目标 | 说明 |
|------|------|
| **连接 UIKit 与 Tox** | 上层为 Tencent Cloud Chat UIKit / V2TIM 风格 API，底层为 c-toxcore P2P 协议；Tim2Tox 负责语义映射与数据转换。 |
| **兼容 V2TIM 调用与回调格式** | 调用方（SDK/应用）无需改写业务逻辑；回调格式（如 apiCallback/globalCallback JSON）与原生 SDK 约定一致，便于监听器分发。 |
| **双路径并存** | 支持**二进制替换路径**（NativeLibraryManager → Dart*）与 **Platform/FfiChatService 路径**（TencentCloudChatSdkPlatform → FfiChatService → tim2tox_ffi_*），客户端可择一或混合使用。 |
| **可复用、不绑定具体客户端** | 通过接口注入（Preferences、Logger、Bootstrap、EventBus、ConversationManager 等）依赖，不直接依赖任一具体 App 代码，可被任意 Flutter 聊天客户端复用。 |

---

## 2. 技术约束

| 约束 | 说明 |
|------|------|
| **兼容原有 SDK 调用方式** | Dart* 函数签名与 `native_imsdk_bindings_generated.dart` 中定义一致；当 App 通过 `setNativeLibraryName('tim2tox_ffi')` 替换动态库后，SDK 仍通过 `bindings.DartXXX(...)` 调用，由 tim2tox 的 `dart_compat_*.cpp` 实现这些符号。详见 [BINARY_REPLACEMENT.md](BINARY_REPLACEMENT.md)、[FFI_COMPAT_LAYER.md](FFI_COMPAT_LAYER.md)。 |
| **回调格式** | C++ 通过 `SendCallbackToDart(callback_type, json_data, user_data)` 发送；Dart 层 `NativeLibraryManager._handleNativeMessage` 期望的 JSON 结构（如 `callback`、`callbackType`、`user_data`、`code`、`desc`）需与原生 SDK 约定一致，以便同一套监听器逻辑可处理。 |
| **跨语言边界** | FFI 边界仅暴露 **C 接口**（无 C++ 类型、异常、智能指针）；Dart 通过 `dart:ffi` 绑定 C 函数；字符串/缓冲区由调用方分配或由实现写入，并约定返回值（如 0/1、bytes written）。 |

---

## 3. 分层架构

从下到上分为：C++ 核心 → C FFI 接口 → Dart 绑定 → SDK Platform；两条调用入口（tim2tox_ffi_* 与 Dart*）在 FFI 层汇合后均进入同一套 V2TIM 实现与 Tox 核心。

```
┌─────────────────────────────────────────────────────────────────┐
│  Flutter/UIKit 应用层                                             │
│  调用方: TIMManager / TencentCloudChatSdkPlatform.instance        │
└───────────────────────────┬───────────────────────────────────────┘
                            │
        ┌───────────────────┴───────────────────┐
        │  Dart SDK Platform 层                 │
        │  Tim2ToxSdkPlatform → FfiChatService  │  仅当 isCustomPlatform 时
        │  FFI: tim2tox_ffi.dart (Tim2ToxFfi)  │
        └───────────────────┬───────────────────┘
                            │
┌───────────────────────────┴───────────────────────────────────────┐
│  C FFI 接口层 (libtim2tox_ffi)                                     │
│  tim2tox_ffi_* (高级 API)  │  Dart* (dart_compat_*) 兼容层         │
│  调用方: FfiChatService     │  调用方: NativeLibraryManager         │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌───────────────────────────┴───────────────────────────────────────┐
│  V2TIM API 实现层 (source/)                                        │
│  V2TIMManagerImpl, V2TIMMessageManagerImpl, ...                   │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌───────────────────────────┴───────────────────────────────────────┐
│  Tox 核心层 (source/ToxManager) + c-toxcore                        │
└───────────────────────────────────────────────────────────────────┘
```

**职责边界简述**：

- **C++ 核心**：实现 V2TIM 语义（登录、消息、好友、群组、会话等），委托 ToxManager 执行 Tox 网络操作；不感知 Dart 或 Platform。
- **C FFI 层**：提供 C 接口供 Dart 或 SDK 原生绑定调用；将参数/返回值在 C 与 C++ 之间转换；不持有 Dart 对象，仅通过 SendPort 发送 JSON 消息。
- **Dart 绑定**：封装 `tim2tox_ffi_*` 调用、管理轮询与历史等状态；FfiChatService 为 Platform 路径的**被调用方**，同时是 FFI 的**调用方**。
- **SDK Platform**：当 `isCustomPlatform == true` 时，SDK 将部分或全部方法路由到 `Tim2ToxSdkPlatform`，由其实现委托给 FfiChatService / 原生能力。

---

## 4. 关键目录与关键类

| 层级 | 目录/文件 | 关键类/模块 | 职责 |
|------|-----------|-------------|------|
| C++ 核心 | `source/` | `V2TIMManagerImpl` | SDK 初始化、登录、实例与 Tox 生命周期、获取各子 Manager。 |
| | | `ToxManager` | Tox 实例创建/迭代、好友/群组/消息与 c-toxcore 对接。 |
| | | `V2TIMMessageManagerImpl` | 消息发送/接收、历史查询桥接（实际历史在 Dart 侧）。 |
| | | `V2TIMFriendshipManagerImpl` / `V2TIMGroupManagerImpl` / `V2TIMConversationManagerImpl` | 好友、群组、会话的 V2TIM 实现。 |
| C FFI | `ffi/` | `tim2tox_ffi.h/cpp` | C API：init/login/poll/send/bootstrap/多实例等。 |
| | | `dart_compat_layer.cpp` + `dart_compat_*.cpp` | Dart* 兼容层，对接 NativeLibraryManager 的 FFI 调用。 |
| | | `callback_bridge.cpp/h` | SendPort 注册、SendCallbackToDart，将 C++ 事件投递到 Dart。 |
| | | `json_parser.cpp/h` | 构建 apiCallback/globalCallback 等 JSON。 |
| Dart | `dart/lib/ffi/` | `tim2tox_ffi.dart` (Tim2ToxFfi) | 对 tim2tox_ffi_* 的 Dart FFI 绑定。 |
| | `dart/lib/service/` | `FfiChatService` | 初始化、登录、轮询、发送、历史、Stream、多实例注册。 |
| | `dart/lib/sdk/` | `Tim2ToxSdkPlatform` | 实现 TencentCloudChatSdkPlatform，将 SDK 调用路由到 FfiChatService。 |
| | `dart/lib/utils/` | `MessageHistoryPersistence` | 会话维度历史持久化（Dart 侧），C++ 无历史存储。 |

---

## 5. 典型调用链

以下每条链均给出**调用方 → 被调用方**的时序与**失败路径**说明。

### 5.1 Init

```
App/Client                FfiChatService          Tim2ToxFfi (Dart)     C FFI              V2TIMManagerImpl      ToxManager
    |                            |                        |                   |                        |                    |
    | init()                     |                        |                   |                        |                    |
    |--------------------------->|                        |                   |                        |                    |
    |                            | tim2tox_ffi_init()     |                   |                        |                    |
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
    |                            | (Bootstrap 节点应用，见 §8)                   |                        |                    |
    |<---------------------------|                        |                   |                        |                    |
```

**失败路径**：`init_path` 无效或不可写时 C 层返回 0；已初始化时由实现决定是否返回成功或失败；Dart 层可根据返回值抛出或提示。

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
    |                            | (Future 完成 / 回调)   |                   |                        |
    |<---------------------------|                        |                   |                        |
```

**失败路径**：instance 未创建或未初始化时返回 0；登录失败通过 async 回调的 success=0 与 error_code/error_message 传递。

### 5.3 Send（单聊文本）

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

**失败路径**：未登录、好友不存在、缓冲区不足等在 C 层返回 0；发送超时/失败通过后续回调（如消息状态）通知。

### 5.4 History

历史由 **Dart 侧** 持久化，C++ 不存储消息历史。Platform 的 getHistoryMessageList 等由 Tim2ToxSdkPlatform 转调 FfiChatService.getHistory，最终从 MessageHistoryPersistence 读取。

```
UIKit / 会话页              Tim2ToxSdkPlatform    FfiChatService              MessageHistoryPersistence
    |                                |                    |                                |
    | getHistoryMessageList()         |                    |                                |
    |-------------------------------->|                    |                                |
    |                                | getHistory(convId)  |                                |
    |                                |------------------->|                                |
    |                                |                    | getHistory(id)                  |
    |                                |                    |------------------------------->|
    |                                |                    | List<ChatMessage>               |
    |                                |                    |<--------------------------------|
    |                                | (转换为 SDK 类型)   |                                |
    |<--------------------------------|                    |                                |
```

**失败路径**：会话 id 无效或未初始化持久化时返回空列表；清除历史由 Platform 调用 FfiChatService 的 clearHistoryMessage / messageHistoryPersistence 完成。

### 5.5 Callback（C++ → Dart）

```
c-toxcore / ToxManager    V2TIM Listener 实现      json_parser / callback_bridge    Dart ReceivePort    NativeLibraryManager / Platform
    |                            |                            |                            |                            |
    | 事件 (如好友消息)            |                            |                            |                            |
    |--------------------------->|                            |                            |                            |
    |                            | BuildGlobalCallbackJson()  |                            |                            |
    |                            | 或 BuildApiCallbackJson()   |                            |                            |
    |                            |--------------------------->|                            |                            |
    |                            |                            | SendCallbackToDart()        |                            |
    |                            |                            | Dart_PostCObject_DL()        |                            |
    |                            |                            |--------------------------->|                            |
    |                            |                            |                            | _handleNativeMessage()     |
    |                            |                            |                            |--------------------------->|
    |                            |                            |                            | 分发到 Listeners / Platform |
```

**失败路径**：SendPort 未注册或 Dart 未初始化时 SendCallbackToDart 内直接 return；多实例时通过 instance_id 在 Dart 侧路由到对应 FfiChatService（见 §7）。

---

## 6. FFI 边界设计原则

| 原则 | 说明 |
|------|------|
| **仅暴露 C 接口** | 头文件 `tim2tox_ffi.h` 仅含 C 类型与 `extern "C"` 函数；Dart 通过 FFI 绑定 C 函数，不接触 C++。 |
| **线程安全** | 回调发送端（如 `SendCallbackToDart`）使用互斥锁保护 port 与发送逻辑；Dart 侧若多 isolate 需自行保证 ReceivePort 归属。 |
| **双入口** | **tim2tox_ffi_***：供 FfiChatService / 直接 FFI 调用者使用，语义更贴近“高级 API”（如 poll_text 按 instance_id）。**Dart***：供 NativeLibraryManager 动态查找，签名与原生 SDK 生成的 bindings 一致，内部转调 V2TIM 或 tim2tox_ffi_*。 |
| **参数与返回值约定** | 输出型缓冲区由**调用方分配**，实现写入并返回写入字节数或 0 表示错误；布尔/状态用 0/1；instance 用 int64_t handle；异步结果通过回调或 Dart 侧 poll 获取。详见 [FFI_FUNCTION_DECLARATION_GUIDE.md](../development/FFI_FUNCTION_DECLARATION_GUIDE.md)。 |

---

## 7. 回调桥接机制

- **注册**：Dart 层在加载库后调用 `DartRegisterSendPort(sendPort.nativePort)`，C++ 将 port 存于全局（带锁）。
- **发送**：C++ 侧 V2TIM Listener 实现中构造 JSON（BuildGlobalCallbackJson / BuildApiCallbackJson），再调用 `SendCallbackToDart(callback_type, json_data, user_data)`，内部通过 `Dart_PostCObject_DL` 将消息投递到 Dart ReceivePort。当前 C++ 实现中 `user_data` 参数未参与发送逻辑，请求与回调的关联依赖 JSON 内的 `user_data` 等字段。
- **类型**：`globalCallback` 用于全局事件（连接状态、新消息、好友变化等）；`apiCallback` 用于单次 API 结果（如登录完成、请求好友结果）。
- **多实例**：部分回调带 instance_id；Dart 侧 `_instanceServices[instanceId]` 将事件路由到对应 FfiChatService，默认 instance 0 可回退到 `_globalService`。**注意**：按 instance 路由仅对经 FfiChatService/tim2tox_ffi 的回调（如 DHT 节点响应、ToxAV）成立；**二进制替换路径**下 NativeLibraryManager 仍只有一套全局 listener，不按 instance_id 分发，详见 [MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md)。
- **关键代码**：`ffi/callback_bridge.cpp`（SendPort 存储、SendCallbackToDart）、`ffi/dart_compat_callbacks.cpp`（回调类实现）、`ffi/dart_compat_listeners.cpp`（监听器注册）；Dart 侧 `ffi_chat_service.dart` 中的 trampoline 与 `_instanceServices` 查找。

详见 [FFI_COMPAT_LAYER.md](FFI_COMPAT_LAYER.md)。

---

## 8. Bootstrap 与 Polling

### Bootstrap

- **用途**：Tox 需要至少一个 DHT Bootstrap 节点才能加入网络；节点由客户端配置（auto 拉取公共节点 / manual 手动输入 / lan 局域网服务）。
- **应用时机**：`FfiChatService.init()` 末尾调用 `_loadAndApplySavedBootstrapNode()`：根据 Prefs 的 mode 读取当前节点（如 `getCurrentBootstrapNode()` 或 `BootstrapService.getBootstrapHost/Port/PublicKey()`），然后调用 `tim2tox_ffi_add_bootstrap_node(instance_id, host, port, public_key_hex)`。
- **协作**：Bootstrap 决定“连谁”；真正连接与 DHT 建立依赖 Tox 迭代与网络，由下层 c-toxcore 完成。

### Polling

- **用途**：C++ 将接收到的文本/自定义消息、连接状态、文件事件等放入队列，Dart 层通过 **轮询** 拉取并处理，避免在 C++ 回调中直接调用 Dart API 带来的线程/隔离约束。
- **启动**：`FfiChatService.startPolling()` 取消旧 Timer，设置 `_pollTimerCallback`，首次立即执行一次并随后按间隔 `_scheduleNextPoll`。
- **每轮逻辑**：调用 `tim2tox_ffi_poll_text(instance_id, buffer, len)`（及 custom 等）从队列取事件；解析行格式（如 `conn:success`、`c2c:`、`gtext:`、`file_request:`、`file_done:` 等），更新连接状态、消息流、文件进度等；多实例时按 `_knownInstanceIds` 轮询各 instance，优先处理非默认实例以便 file_request 等及时被消费。
- **间隔策略**：有文件传输或多实例时用较短间隔（如 50ms）；最近有活动时 200ms；空闲 1000ms；另设 profile 定期保存（如 60s）。

Bootstrap 与 Polling 的详细流程与客户端侧约定见 [BOOTSTRAP_AND_POLLING.md](../integration/BOOTSTRAP_AND_POLLING.md)。

---

## 9. 多实例支持的用途与边界

- **用途**：主要用于**测试**（如 auto_tests 中多节点互操作）；生产环境使用**默认实例**（instance_id 0），无需创建 test instance。
- **边界**：
  - **创建/切换/销毁**：`tim2tox_ffi_create_test_instance` / `create_test_instance_ex`、`tim2tox_ffi_set_current_instance`、`tim2tox_ffi_destroy_test_instance`；每个实例独立 init_path、网络端口、DHT ID。
  - **轮询**：`tim2tox_ffi_poll_text(instance_id, ...)` 只返回该 instance 或广播（id 0）的事件；Dart 侧 `registerInstanceForPolling(instanceId)` 将 instance 加入 `_knownInstanceIds`，单例 FfiChatService 轮询时依次 poll 各 instance，并通过 `_instanceServices` 将事件路由到对应服务（若已注册）。
  - **生命周期**：destroy 后需从轮询注册表移除（`unregisterInstanceForPolling`），避免 poll 到无效 instance。

详见 [MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md)。

---

## 10. 与接入客户端的关系

接入方可采用**混合架构**（二进制替换 + Platform），由客户端负责 UI 与接口注入，Tim2Tox 提供底层能力：

- **二进制替换**：在应用最早阶段 `setNativeLibraryName('tim2tox_ffi')`，SDK 加载 `libtim2tox_ffi`，大部分 TIMManager/NativeLibraryManager 调用走 Dart* → V2TIM。
- **Platform**：设置 `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(ffiService: ffiChatService)`；当 `isCustomPlatform == true` 时，SDK 将配置的若干方法路由到 Platform，由 Tim2ToxSdkPlatform 委托给 FfiChatService（历史、轮询、部分回调、通话桥等）。
- **分工**：历史消息、clearHistory、getHistoryMessageList 等由 Platform → FfiChatService 提供；登录、发消息、好友/群组等可走二进制替换或 Platform，混合下由 Platform 补足自定义回调、Bootstrap 写入、通话等。
- **客户端职责**：提供 Bootstrap 设置与节点来源、消息/会话 UI，并实现 Preferences、Logger、BootstrapService 等接口注入给 FfiChatService。

完整示例与启动顺序见各客户端项目文档。路由行为见 [BINARY_REPLACEMENT.md](BINARY_REPLACEMENT.md)、主 [README](../../README.md) 集成方案。

---

## 11. 常见扩展方式

| 扩展点 | 做法 |
|--------|------|
| **新增 V2TIM 能力** | 在 `source/` 对应 *Impl 中实现新接口；若需供二进制替换路径使用，在 `ffi/dart_compat_*.cpp` 中增加 Dart* 函数并转调 V2TIM。 |
| **新增 FFI 接口** | 在 `tim2tox_ffi.h/cpp` 声明并实现 C 函数；在 `dart/lib/ffi/tim2tox_ffi.dart` 增加 Dart 绑定；若需供 Platform 使用，在 FfiChatService 或 Tim2ToxSdkPlatform 中增加对 Tim2ToxFfi 的调用。 |
| **新增 Platform 方法** | 在 `Tim2ToxSdkPlatform` 中实现 TencentCloudChatSdkPlatform 的新方法，委托给 FfiChatService 或原生能力。 |
| **依赖注入** | 通过 FfiChatService 构造函数注入 BootstrapService、LoggerService、ExtendedPreferencesService 等；客户端实现接口并传入，见现有 interfaces/。 |

模块化与开发流程见 [MODULARIZATION.md](MODULARIZATION.md)、[DEVELOPMENT_GUIDE.md](../development/DEVELOPMENT_GUIDE.md)。

---

## 12. 风险点与测试建议

### 限制与异常路径

- **调用顺序**：init 之前调用 login/send 会失败；C++ 层会返回 0 或通过异步回调报错。建议 Dart 层对 init/login 状态做守卫并文档化“调用时机”。
- **未启动轮询**：若未调用 `startPolling()`，C++ 侧事件队列（连接状态、新消息、文件事件等）会持续积压，连接/消息无法被 Dart 消费。应在 init 或 login 后尽快调用 `startPolling()`。
- **多实例回调**：仅部分回调（如 DHT 响应、ToxAV）能按 instance 正确路由；多数 globalCallback 在 C++ 侧依赖“当前实例”填写 instance_id，在 Tox 异步线程触发时可能错位，且二进制替换路径下 Dart 端不按 instance_id 分发，详见 [MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md)。

### 风险点

| 风险 | 说明 |
|------|------|
| **回调线程与 Dart isolate** | C++ 回调可能在非主 isolate 或后台线程执行；通过 SendPort 投递到 Dart 后，需在主 isolate 处理 UI 与状态；trampoline 中避免复杂逻辑与跨 isolate 引用。 |
| **库未初始化即调用** | init 前调用 login/send 等会失败；建议在 Dart 层对 init/login 状态做守卫，并明确文档“调用时机”。 |
| **双路径下历史/回调重复** | 同一条消息若既走二进制替换（OnRecvNewMessage）又走 Platform 历史写入，可能重复落库或重复通知；当前通过 BinaryReplacementHistoryHook 与 Platform 历史分工规避，维护时注意两路径的职责划分。 |
| **多实例 dispose 与 port** | destroy 实例后若仍 poll 或仍向该 instance 的 service 投递回调，可能访问已释放资源；需在 destroy 时取消轮询注册并确保 C++ 侧不再向该 instance 投递。 |

### 测试建议

- **C++ 单元测试**：`test/` 下对 V2TIM/ToxManager 关键逻辑做单测。
- **Dart/集成**：`auto_tests` 中多实例、登录、发消息、轮询、历史等流程覆盖；同时覆盖**二进制替换路径**（不设 Platform）与 **Platform 路径**（设 isCustomPlatform），确保两条路径均可用。
- **回归**：修改 callback_bridge、dart_compat_*、tim2tox_ffi 后跑完整集成与客户端冒烟。

---

## 相关文档

- [API 参考](../api/API_REFERENCE.md)
- [API 参考写作模板](../api/API_REFERENCE_TEMPLATE.md)
- [二进制替换](BINARY_REPLACEMENT.md)
- [FFI 兼容层](FFI_COMPAT_LAYER.md)
- [Bootstrap 与轮询](../integration/BOOTSTRAP_AND_POLLING.md)
- [多实例支持](../development/MULTI_INSTANCE_SUPPORT.md)
- isCustomPlatform 路由行为见 [BINARY_REPLACEMENT](BINARY_REPLACEMENT.md)
- [开发指南](../development/DEVELOPMENT_GUIDE.md)
