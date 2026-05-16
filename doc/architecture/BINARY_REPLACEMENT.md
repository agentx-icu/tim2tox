# Tim2Tox 二进制替换
> 语言 / Language: [中文](BINARY_REPLACEMENT.md) | [English](BINARY_REPLACEMENT.en.md)


本文档详细说明如何使用底层 Tox 二进制实现替换 TIMSDK 的二进制，实现零 Dart 代码修改的集成方案。

## 概述

二进制替换方案（BINARY REPLACEMENT MODE）是一种通过替换动态库文件来实现后端切换的方案，使得 Dart 层代码完全不需要修改，就能从腾讯云 IM SDK 切换到 Tox P2P 协议。

**当前使用状态**: ✅ **接入方可使用混合模式（Binary Replacement + Platform 接口）；示例见采用本仓库的上层客户端。**

**配置方式**:
- 在 `main()` 最早期调用 `setNativeLibraryName('tim2tox_ffi')` 配置库名
- 可选：设置 `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)` 启用高级功能

## 核心原理

### 1. 动态库替换

**关键文件**: `tencent_cloud_chat_sdk-8.7.7201/lib/native_im/bindings/native_library_manager.dart`

在 `NativeLibraryManager` 中，通过 `setNativeLibraryName()` 配置动态库名称（默认为原始 SDK 的 `dart_native_imsdk`）：

```dart
// 默认值为原始 SDK，调用方在 main() 最早期覆盖
String _nativeLibName = 'dart_native_imsdk';
void setNativeLibraryName(String name) {
  _nativeLibName = name;
}

final DynamicLibrary _dylib = () {
  final libName = _nativeLibName;
  if (Platform.isMacOS) {
    try {
      return DynamicLibrary.open('$libName.framework/Versions/A/$libName');
    } catch (e) {
      return DynamicLibrary.open('lib$libName.dylib');
    }
  }
  // ... 其他平台的处理
}();
```

**使用方式**（在 `main()` 最早期、任何 SDK 调用之前）：
```dart
import 'package:tencent_cloud_chat_sdk/native_im/bindings/native_library_manager.dart';
setNativeLibraryName('tim2tox_ffi');
```

**重要**: `_dylib` 是顶层 `final` 变量，在首次访问时惰性初始化。`setNativeLibraryName()` 必须在任何 `NativeLibraryManager.bindings` 使用之前调用，否则会加载默认的 `dart_native_imsdk`。

**编译产物**:
- macOS: `libtim2tox_ffi.dylib`
- Linux: `libtim2tox_ffi.so`
- iOS: `tim2tox_ffi.framework` 或 `libtim2tox_ffi.dylib`
- Android: `libtim2tox_ffi.so`
- Windows: `tim2tox_ffi.dll`

### 2. 函数签名完全匹配

**关键文件**：`ffi/dart_compat_*.cpp`（注意：原来的 `dart_compat_layer.cpp` 已模块化为 13 个 `.cpp`，自身仅剩 28 行注释，无业务实现）

所有 `Dart*` 函数的签名必须与 `native_imsdk_bindings_generated.dart` 中声明的完全一致：

```cpp
// 真实签名（见 ffi/dart_compat_sdk.cpp:9）
extern "C" {
    int DartInitSDK(uint64_t sdk_app_id, const char* json_sdk_config) {
        std::string config_str = json_sdk_config ? std::string(json_sdk_config) : "{}";
        std::string init_path = ExtractJsonValue(config_str, "sdk_config_config_file_path");
        std::string log_path  = ExtractJsonValue(config_str, "sdk_config_log_file_path");

        V2TIMSDKConfig sdk_config;
        if (!init_path.empty()) sdk_config.initPath = V2TIMString(init_path.c_str());
        if (!log_path.empty())  sdk_config.logPath  = V2TIMString(log_path.c_str());
        sdk_config.logLevel = static_cast<V2TIMLogLevel>(
            ExtractJsonInt(config_str, "sdk_config_log_level", /*default*/ 3, /*silent*/ true));

        // Dart 端用 uint64_t，V2TIM::InitSDK 期望 uint32_t —— 显式裁剪
        bool ok = SafeGetV2TIMManager()->InitSDK(static_cast<uint32_t>(sdk_app_id), sdk_config);
        return ok ? 0 : 1; // 0 = TIM_SUCC
    }
}
```

注意几点：

- **真实签名是 `(uint64_t, const char*)`**，没有 `user_data` 参数。
- 返回 `0 = success / 1 = failure`，符合 V2TIM `TIM_SUCC = 0` 的约定 —— 这与 `tim2tox_ffi_*` 那组 C API（`1 = success`）相反，是历史 ABI 差异。
- `sdk_app_id` 通过 JSON 不是直接进入函数 —— 与某些早期文档不同。

**函数签名来源**：`native_imsdk_bindings_generated.dart` 由 `ffigen` 从原生 SDK 头文件生成。tim2tox patches 后的 SDK 必须与 tim2tox 的实现保持二进制一致。

### 3. FFI 动态符号查找

**关键文件**: `tencent_cloud_chat_sdk-8.7.7201/lib/native_im/bindings/native_imsdk_bindings_generated.dart`

Dart 层通过 FFI 动态查找符号：

```dart
class NativeImsdkBindings {
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName) _lookup;
  
  NativeImsdkBindings(ffi.DynamicLibrary dynamicLibrary)
      : _lookup = dynamicLibrary.lookup;
  
  int DartInitSDK(ffi.Pointer<ffi.Char> json_init_param, ffi.Pointer<ffi.Void> user_data) {
    return _DartInitSDK(json_init_param, user_data);
  }
  
  late final _DartInitSDKPtr = _lookup<ffi.NativeFunction<...>>('DartInitSDK');
  late final _DartInitSDK = _DartInitSDKPtr.asFunction<int Function(...)>();
}
```

当 `_dylib` 指向 `libtim2tox_ffi.dylib` 时，`_lookup('DartInitSDK')` 会在 `libtim2tox_ffi.dylib` 中查找符号，而不是原生的 `dart_native_imsdk`。

### 4. 回调机制

**关键文件**: `tim2tox/ffi/callback_bridge.cpp`

C++ 层通过 `Dart_PostCObject_DL` 将事件发送回 Dart 层：

```cpp
// 真实实现见 ffi/callback_bridge.cpp
void SendCallbackToDart(const char* callback_type, const std::string& json_data, void* user_data) {
    std::lock_guard<std::mutex> lock(g_dart_port_mutex);
    if (!g_dart_api_initialized || g_dart_port == ILLEGAL_PORT) return;

    if (json_data.size() > 1 * 1024 * 1024) {       // 1MB 上限
        V2TIM_LOG(kError, "message too large: {}", json_data.size());
        return;
    }

    char* buf = static_cast<char*>(malloc(json_data.size() + 1));
    if (!buf) return;
    std::memcpy(buf, json_data.data(), json_data.size());
    buf[json_data.size()] = '\0';

    Dart_CObject cobj;
    cobj.type = Dart_CObject_kString;
    cobj.value.as_string = buf;

    if (!Dart_PostCObject_DL(g_dart_port, &cobj)) {
        free(buf);                                   // 投递失败时由调用方释放
    }
    // 成功后由 Dart 接收方负责释放
}
```

**初始化流程**:
1. Dart 层调用 `DartInitDartApiDL(data)` 初始化 Dart API
2. Dart 层调用 `DartRegisterSendPort(port)` 注册 SendPort
3. C++ 层存储端口号，用于后续发送回调

## 完整调用流程

### SDK 初始化流程

```
Dart 层 (TIMManager.initSDK)
  ↓
NativeLibraryManager.bindings.DartInitSDK(...)
  ↓
FFI 动态查找符号 'DartInitSDK' (在 libtim2tox_ffi.dylib 中)
  ↓
C++ 层 (ffi/dart_compat_sdk.cpp::DartInitSDK)
  ↓
解析 JSON 参数 (json_parser.cpp)
  ↓
V2TIMManager::GetInstance()->InitSDK(...)
  ↓
ToxManager::getInstance().init(...)
  ↓
tox_new() (c-toxcore)
  ↓
回调: SendApiCallbackResult(user_data, 0, "OK")
  ↓
Dart 层 (ReceivePort 接收回调)
  ↓
NativeLibraryManager._handleNativeMessage()
  ↓
业务代码处理结果
```

### 消息发送流程

```
Dart 层 (TIMMessageManager.sendMessage)
  ↓
NativeLibraryManager.bindings.DartSendMessage(...)
  ↓
C++ 层 (ffi/dart_compat_message.cpp::DartSendMessage)
  ↓
V2TIMMessageManagerImpl::SendMessage(...)
  ↓
ToxManager::SendMessage(...)
  ↓
tox_friend_send_message() (c-toxcore)
  ↓
P2P 网络传输
```

### 消息接收流程

```
P2P 网络接收
  ↓
tox_friend_message() 回调 (c-toxcore)
  ↓
ToxManager::OnFriendMessage(...)
  ↓
V2TIMMessageManagerImpl::OnRecvNewMessage(...)
  ↓
DartAdvancedMsgListenerImpl::OnRecvNewMessage(...)
  ↓
BuildGlobalCallbackJson() (json_parser.cpp)
  ↓
SendCallbackToDart("globalCallback", json_data, nullptr)
  ↓
Dart_PostCObject_DL(g_dart_port, &cobj)
  ↓
Dart 层 (ReceivePort 接收回调)
  ↓
NativeLibraryManager._handleNativeMessage()
  ↓
NativeLibraryManager._handleGlobalCallback()
  ↓
业务代码处理消息
```

## 关键组件

### 1. dart_compat_*.cpp（拆分后的 `Dart*` 实现）

**位置**：`ffi/dart_compat_{sdk,message,friendship,conversation,group,user,signaling,community,other,listeners,callbacks,utils}.cpp`，以及说明性的 `ffi/dart_compat_layer.cpp`（仅 28 行注释）。

**职责**：实现所有 `Dart*` 函数，提供与原生 SDK 完全兼容的 ABI 表面。

**主要函数（节选）**：
- `DartInitSDK`（`dart_compat_sdk.cpp`）：SDK 初始化
- `DartLogin`（`dart_compat_sdk.cpp`）：用户登录
- `DartSendMessage`（`dart_compat_message.cpp`）：发送消息
- `DartGetConversationList`（`dart_compat_conversation.cpp`）：获取会话列表
- `DartGetFriendList`（`dart_compat_friendship.cpp`）：获取好友列表

完整模块职责与行数清单见 [MODULARIZATION.md](MODULARIZATION.md)。

**典型实现模式**：
```cpp
int DartXXX(const char* json_param, void* user_data) {
    std::string json_str = json_param ? json_param : "";
    std::string field1   = ExtractJsonValue(json_str, "field1");

    // 1. 调用 V2TIM SDK API
    V2TIMManager::GetInstance()->GetXXXManager()->XXX(...);

    // 2. 通过回调返回结果（异步）
    SendApiCallbackResult(user_data, /*code=*/0, /*desc=*/"OK");
    return 0; // TIM_SUCC
}
```

### 2. callback_bridge.cpp/h

**位置**: `tim2tox/ffi/callback_bridge.cpp`

**职责**: 实现回调桥接机制，将 C++ 事件发送到 Dart 层。

**主要函数**:
- `DartInitDartApiDL`: 初始化 Dart API
- `DartRegisterSendPort(int64_t send_port)`: 注册 Dart SendPort（签名需与 native_imsdk_bindings_generated.dart 一致）
- `SendCallbackToDart`: 发送回调消息到 Dart 层

### 3. json_parser.cpp/h

**位置**: `tim2tox/ffi/json_parser.cpp`

**职责**: 实现 JSON 消息构建和解析工具。

**主要函数**:
- `BuildGlobalCallbackJson`: 构建 globalCallback JSON 消息
- `BuildApiCallbackJson`: 构建 apiCallback JSON 消息
- `ExtractJsonValue`: 提取 JSON 值
- `ParseJsonString`: 解析 JSON 字符串

### 4. Listener 实现

**位置**：`ffi/dart_compat_listeners.cpp`

**职责**: 实现 V2TIM Listener 接口，将 Tox 事件转换为 JSON 消息。

**主要 Listener**:
- `DartSDKListenerImpl`: SDK 事件监听（连接状态、用户状态等）
- `DartAdvancedMsgListenerImpl`: 消息事件监听（新消息、消息修改等）
- `DartFriendshipListenerImpl`: 好友事件监听（好友添加、删除等）
- `DartConversationListenerImpl`: 会话事件监听（会话更新等）
- `DartGroupListenerImpl`: 群组事件监听（群组提示等）
- `DartSignalingListenerImpl`: 信令事件监听（音视频邀请等）
- `DartCommunityListenerImpl`: 社区事件监听（话题创建等）

## 与 Platform 接口方案的区别

### 方案对比

| 特性 | 二进制替换方案 | Platform 接口方案 | 混合模式（当前使用） |
|------|-------------|-----------------|-------------------|
| **Dart 代码修改** | 仅 `setNativeLibraryName` | 需要设置 Platform | 两者都需要 |
| **功能丰富度** | 基础功能 | 高级功能 | 完整功能 |
| **自定义 callback** | 通过 `customCallbackHandler` | 直接在 Platform 实现 | `customCallbackHandler` 注册到 Platform |
| **适用场景** | 快速集成 | 需要高级功能 | 生产环境 |

### 混合模式（推荐）

接入方可同时使用二进制替换和 Platform 接口，例如：

1. `setNativeLibraryName('tim2tox_ffi')` — 加载 `libtim2tox_ffi.dylib`
2. `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)` — 启用高级功能
3. `Tim2ToxSdkPlatform` 构造函数注册 `NativeLibraryManager.customCallbackHandler` — 接管自定义 callback

### customCallbackHandler 机制

SDK 中 `NativeLibraryManager._handleNativeCallback` 的 switch 默认分支委托给 `customCallbackHandler`：

```dart
// NativeLibraryManager 类内
static Future<void> Function(
  String callbackName,
  Map<String, dynamic> data,
  Map<String, ApiCallback> apiCallbackMap,
)? customCallbackHandler;

// _handleNativeCallback switch:
default:
  if (customCallbackHandler != null) {
    await customCallbackHandler!(callbackName, dataFromNativeMap, _apiCallbackMap);
  }
  break;
```

Tim2ToxSdkPlatform 在构造时注册 handler，处理 3 个自定义 callback：
- `clearHistoryMessage` — 清除 C2C/群组聊天历史
- `groupQuitNotification` — 群退出后清理状态
- `groupChatIdStored` — 存储群 chat_id 映射

### Platform 接口方案

**调用路径**：
```
UIKit SDK
  ↓
TencentCloudChatSdkPlatform.instance (Tim2ToxSdkPlatform)
  ↓
FfiChatService (高级服务层)
  ↓
Tim2ToxFfi (FFI 绑定)
  ↓
tim2tox_ffi_* (C FFI 接口)
  ↓
V2TIM*Manager (C++ API 实现)
  ↓
ToxManager (Tox 核心)
  ↓
c-toxcore (P2P 通信)
```

**特点**:
- 需要设置 `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)`
- 需要修改 Dart 层代码
- 使用高级服务层（FfiChatService）提供更丰富的功能
- 支持消息历史管理、事件轮询、状态管理等高级功能

**关键文件**:
- `tim2tox/dart/lib/sdk/tim2tox_sdk_platform.dart` - Platform 接口实现
- `tim2tox/dart/lib/service/ffi_chat_service.dart` - 高级服务层
- `tim2tox/dart/lib/ffi/tim2tox_ffi.dart` - FFI 绑定

### 纯二进制替换方案

**调用路径**：
```
UIKit SDK
  ↓
TIMManager.instance
  ↓
NativeLibraryManager (原生 SDK 的调用方式)
  ↓
bindings.DartXXX(...) (FFI 动态查找符号)
  ↓
libtim2tox_ffi.dylib (替换后的动态库)
  ↓
dart_compat_layer.cpp (Dart* 函数实现)
  ↓
V2TIM*Manager (C++ API 实现)
  ↓
ToxManager (Tox 核心)
  ↓
c-toxcore (P2P 通信)
```

**特点**:
- **零 Dart 代码修改**: 不需要设置 `TencentCloudChatSdkPlatform.instance`
- **完全兼容**: 函数签名和回调格式完全匹配原生 SDK
- **只需替换动态库**: 将 `dart_native_imsdk` 替换为 `libtim2tox_ffi`
- **适用场景**: 快速验证、最小化接入、隔离调试

**关键文件**:
- `tencent_cloud_chat_sdk-8.7.7201/lib/native_im/bindings/native_library_manager.dart` - 动态库加载
- `tim2tox/ffi/dart_compat_*.cpp` - `Dart*` 函数实现（按职责拆分为 13 个模块）
- `tim2tox/ffi/callback_bridge.cpp` - 回调桥接机制

## 使用 Dart API（tim2tox_ffi.dart）驱动同一后端

同一套原生动态库（`libtim2tox_ffi`）对外提供**两套 C 接口**，对应两种用法：

| 入口 | 符号前缀 | 调用方 | 参数/回调 |
|------|----------|--------|-----------|
| 二进制替换 | `Dart*`（如 `DartInitSDK`） | SDK 的 `NativeLibraryManager.bindings` | JSON 入参 + `Dart_PostCObject_DL` → ReceivePort |
| Dart API | `tim2tox_ffi_*`（如 `tim2tox_ffi_init`） | Dart 层 `Tim2ToxFfi`（tim2tox_ffi.dart） | 原生类型 + `setCallback` 事件回调 |

- **二进制替换方案**下，应用只调用 `setNativeLibraryName('tim2tox_ffi')`，由 SDK 通过 `bindings.DartXXX(...)` 使用 `Dart*` 接口，应用侧**不直接使用** tim2tox_ffi.dart。
- **Platform 方案**下，应用设置 `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(...)`，内部通过 `FfiChatService` 使用 **Tim2ToxFfi**（即 tim2tox_ffi.dart）调用 `tim2tox_ffi_*`，驱动同一套后端。

若希望**不依赖 SDK 的 NativeLibraryManager**，直接用 Dart 代码驱动同一套 Tox 后端（例如独立测试、自研 UI、或与二进制替换共用同一库文件），可仅使用 **Dart API（tim2tox_ffi.dart）** 按下列方式实现“同一后端”的初始化与调用流程。

### 1. 加载动态库

与二进制替换使用的是**同一动态库**（编译产物见上文「编译产物」）。Dart 侧通过 `Tim2ToxFfi.open()` 按平台查找并打开该库（macOS 下为 `libtim2tox_ffi.dylib` 等）：

```dart
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';

final ffi = Tim2ToxFfi.open();
```

### 2. 初始化与事件回调

- **初始化**：在调用其他接口前调用 `init()` 或 `initWithPath(profileDir)`（可选指定 profile 目录）。
- **事件回调**：通过 `setCallback(callback, userData)` 注册统一事件回调；C 层会按 `event_type`、`sender`、`payload` 回调，对应 Tox 消息、好友、群组等事件（与二进制替换方案中的 globalCallback 语义一致，但走的是 tim2tox_ffi 的 C 回调而非 ReceivePort）。

```dart
// 初始化（二选一）
ffi.init();
// 或指定 profile 目录：ffi.initWithPath('path/to/profile'.toNativeUtf8());

// 注册事件回调：签名见 tim2tox_ffi.dart 中 event 回调类型（event_type, sender_utf8, payload_bytes, payload_len）
ffi.setCallback(yourEventCallbackNative, ffi.Pointer<ffi.Void>.fromAddress(0));
```

### 3. 登录

- 同步：`login(userId.toNativeUtf8(), userSig.toNativeUtf8())`
- 异步（推荐）：`loginAsync(instanceId, userId, userSig, nativeCallback, userData)`，在回调中处理成功/失败。

登录成功后即可调用好友、消息、群组等接口。

### 4. 典型能力与 Dart API 对应关系

| 能力 | Dart API（tim2tox_ffi.dart） |
|------|------------------------------|
| 初始化 | `init()` / `initWithPath(...)` |
| 登录 | `login(...)` / `loginAsync(...)` |
| 事件接收 | `setCallback(...)` |
| C2C 文本 | `sendText(toUserId, text)` |
| 好友列表 | `getFriendList(buffer, size)` |
| 群组 | `createGroup`, `joinGroup`, `sendGroupText`, `getKnownGroups`, ... |
| 信令/音视频 | `signalingAddListenerNative`, `avInitialize`, `avStartCallNative`, ... |
| 多实例/测试 | `createTestInstanceNative`, `setCurrentInstance`, `injectCallback` 等 |

以上接口均直接绑定到 `tim2tox_ffi_*` 符号，与二进制替换使用的 `Dart*` 符号不同，但底层同为 V2TIM/ToxManager/c-toxcore，行为一致。

### 5. 与二进制替换的选用建议

- **仅做后端替换、尽量少改 Dart**：使用**二进制替换**（`setNativeLibraryName('tim2tox_ffi')`），不直接使用 tim2tox_ffi.dart。
- **需要高级能力或自定义 Platform**：使用 **Platform 方案**（`Tim2ToxSdkPlatform` + `FfiChatService`），此时由 FfiChatService 内部通过 tim2tox_ffi.dart 调用 `tim2tox_ffi_*`。
- **不依赖 SDK、直接驱动 Tox 后端**：仅依赖 tim2tox_ffi.dart，`Tim2ToxFfi.open()` → `init` → `setCallback` → `login`，再按需调用上述能力接口。

**关键文件**:
- `tim2tox/dart/lib/ffi/tim2tox_ffi.dart` — Dart API 绑定（tim2tox_ffi_*）
- `tim2tox/dart/lib/service/ffi_chat_service.dart` — Platform 方案下的高级服务层（内部使用 Tim2ToxFfi）

## 部署方式

### 1. 编译动态库

**位置**: `tim2tox/ffi/CMakeLists.txt`

```bash
cd tim2tox
mkdir -p build && cd build
cmake ..
make tim2tox_ffi
```

**输出**:
- macOS: `build/ffi/libtim2tox_ffi.dylib`
- Linux: `build/ffi/libtim2tox_ffi.so`

### 2. 打包到应用

**macOS**（路径以实际客户端项目为准）:
```bash
cp tim2tox/build/ffi/libtim2tox_ffi.dylib \
   <客户端项目>/build/macos/Build/Products/Debug/<app>.app/Contents/MacOS/
```

**Linux**:
```bash
cp tim2tox/build/ffi/libtim2tox_ffi.so \
   <客户端项目>/build/linux/x64/debug/bundle/lib/
```

### 3. 依赖库处理

**libsodium** (Tox 的加密库依赖):
- macOS: 使用 `install_name_tool` 修改动态库的依赖路径
- Linux: 确保系统已安装 `libsodium` 或打包到应用

## 优势

1. **最小 Dart 代码修改**: 仅需在 `main()` 中添加一行 `setNativeLibraryName('tim2tox_ffi')`
2. **SDK 无专有代码**: SDK 中只有通用扩展点（`setNativeLibraryName`、`customCallbackHandler`、`isCustomPlatform`），无 tim2tox 专有逻辑
3. **易于 SDK 升级**: SDK 升级时只需合并通用扩展点和 bug 修复（内存管理、空安全），不涉及 tim2tox 专有代码
4. **完全兼容**: 函数签名和回调格式完全匹配原生 SDK
5. **可测试**: 通过 `tim2tox_ffi_inject_callback` FFI 函数可注入 callback 进行单元测试

## 限制

1. **函数签名必须完全匹配**: 任何签名不匹配都会导致运行时错误
2. **JSON 格式必须匹配**: 参数和回调的 JSON 格式必须与原生 SDK 完全一致
3. **回调机制依赖**: 依赖 Dart API DL 的回调机制，需要正确初始化

## 已修复问题

本节记录在二进制替换方案开发和测试过程中发现并已修复的问题。

### 1. 会话置顶功能流程修复

**问题描述**：
- `OnConversationChanged` 事件中 `conv_event` 字段未正确设置
- 导致 Dart 层无法正确识别会话更新事件

**修复方案**：
- 在 `DartConversationListenerImpl::OnConversationChanged` 中正确设置 `conv_event = "2"`（conversationEventUpdate）
- 确保 `ConversationVectorToJson` 包含 `conv_is_pinned` 字段
- 验证完整的事件流程：C++ 层 → globalCallback → Dart 层 → UIKit SDK

**已修复的代码位置**：
- `tim2tox/ffi/dart_compat_listeners.cpp:DartConversationListenerImpl::OnConversationChanged()`
- `tim2tox/ffi/dart_compat_utils.cpp:ConversationVectorToJson()`

**验证结果**：
- ✅ 会话置顶/取消置顶操作正确触发 `OnConversationChanged` 事件
- ✅ Dart 层正确解析 `conv_event = "2"` 并路由到 `onConversationChanged`
- ✅ UI 正确更新会话列表的置顶状态

### 2. 群组ID生成逻辑修复

**问题描述**：
- 使用 `conference_number` 直接生成群组 ID（`tox_%u`），导致 ID 重用冲突
- 当旧的群组被删除后，新的群组可能重用相同的 ID

**修复方案**：
- 使用全局计数器 `next_group_id_counter_` 生成唯一 ID（`tox_%llu`）
- 检查冲突并确保唯一性
- 在退出/删除群组时正确清理映射关系，防止 ID 重用

**已修复的代码位置**：
- `tim2tox/source/V2TIMManagerImpl.cpp:CreateGroup()`
- `tim2tox/source/V2TIMManagerImpl.cpp:QuitGroup()`
- `tim2tox/source/V2TIMManagerImpl.cpp:DismissGroup()`

**验证结果**：
- ✅ 群组ID生成唯一，避免重用历史ID
- ✅ 退出/删除群组时正确清理映射关系

### 3. GetJoinedGroupList 和 SearchGroups 修复

**问题描述**：
- `GetJoinedGroupList` 和 `SearchGroups` 直接生成群组ID，而不是使用已建立的映射关系
- 导致返回的群组ID与创建时的不一致

**修复方案**：
- 优先从 `V2TIMManagerImpl` 的映射中获取群组ID
- 如果映射中不存在，才尝试通过其他方式获取
- 确保返回的群组ID与创建时的一致

**已修复的代码位置**：
- `tim2tox/source/V2TIMGroupManagerImpl.cpp:GetJoinedGroupList()`
- `tim2tox/source/V2TIMGroupManagerImpl.cpp:SearchGroups()`

**验证结果**：
- ✅ `GetJoinedGroupList` 和 `SearchGroups` 正确使用映射关系
- ✅ 返回的群组ID与创建时的一致

## 调试

### 检查符号导出

**macOS**:
```bash
nm -D libtim2tox_ffi.dylib | grep Dart
```

**Linux**:
```bash
nm -D libtim2tox_ffi.so | grep Dart
```

### 检查动态库依赖

**macOS**:
```bash
otool -L libtim2tox_ffi.dylib
```

**Linux**:
```bash
ldd libtim2tox_ffi.so
```

### 日志输出

C++ 层使用 `fprintf(stdout, ...)` 和 `fprintf(stderr, ...)` 输出日志，可以在 Flutter 控制台看到。

## 相关文档

- [Tim2Tox FFI 兼容层](FFI_COMPAT_LAYER.md) - 详细的实现说明
- [Tim2Tox 架构](ARCHITECTURE.md) - 整体架构设计
- [开发指南](../development/DEVELOPMENT_GUIDE.md) - 开发指南
