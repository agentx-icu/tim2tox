# Tim2Tox 开发
> 语言 / Language: [中文](DEVELOPMENT_GUIDE.md) | [English](DEVELOPMENT_GUIDE.en.md)


本文档提供 Tim2Tox 的开发指南，包括如何添加新功能、代码结构说明、构建系统说明和测试指南。

## 目录

- [代码结构](#代码结构)
- [添加新功能](#添加新功能)
- [构建系统](#构建系统)
- [测试指南](#测试指南)
- [代码规范](#代码规范)
- [调试技巧](#调试技巧)

## 代码结构

### 目录结构

```
tim2tox/
├── include/              # 公共头文件（V2TIM API 定义）
│   ├── V2TIMManager.h
│   ├── V2TIMMessageManager.h
│   ├── V2TIMFriendshipManager.h
│   ├── V2TIMGroupManager.h
│   └── ...
├── source/               # C++ 核心实现
│   ├── V2TIMManagerImpl.cpp/h
│   ├── V2TIMMessageManagerImpl.cpp/h
│   ├── V2TIMFriendshipManagerImpl.cpp/h
│   ├── V2TIMGroupManagerImpl.cpp/h
│   ├── ToxManager.cpp/h
│   └── ...
├── ffi/                  # C/C++ FFI 接口层
│   ├── tim2tox_ffi.h/cpp
│   ├── dart_compat_layer.h/cpp
│   ├── callback_bridge.h/cpp
│   ├── json_parser.h/cpp
│   └── CMakeLists.txt
├── dart/                 # Dart 包（Flutter 绑定）
│   ├── lib/
│   │   ├── ffi/          # FFI 绑定层
│   │   ├── service/      # 服务层
│   │   ├── sdk/          # SDK Platform 实现
│   │   ├── models/       # 数据模型
│   │   └── interfaces/   # 抽象接口
│   └── pubspec.yaml
├── test/                 # C++ 测试
│   ├── CMakeLists.txt
│   ├── ToxUtilTest.cpp
│   └── ...
├── example/              # C++ 示例程序
│   ├── echo_bot_client.cpp
│   ├── echo_bot_server.cpp
│   └── ...
├── third_party/          # 第三方依赖（c-toxcore）
├── CMakeLists.txt        # 主构建文件
└── build.sh              # 构建脚本
```

### 核心模块

#### 1. V2TIM 实现层 (`source/`)

实现 V2TIM API，提供与腾讯云 IM SDK 兼容的接口。

- **V2TIMManagerImpl**: 核心管理器实现
- **V2TIMMessageManagerImpl**: 消息管理实现
- **V2TIMFriendshipManagerImpl**: 好友管理实现
- **V2TIMGroupManagerImpl**: 群组管理实现
- **V2TIMConversationManagerImpl**: 会话管理实现
- **V2TIMSignalingManagerImpl**: 信令管理实现
- **V2TIMCommunityManagerImpl**: 社区管理实现

#### 2. Tox 核心层 (`source/ToxManager.*`)

管理 Tox 实例和生命周期，处理底层 P2P 通信。

- **ToxManager**: Tox 实例管理
- **ToxAVManager**: 音视频管理（可选）
- **IrcClientManager**: IRC 通道桥接管理

#### 3. FFI 接口层 (`ffi/`)

提供 C 接口，供 Dart FFI 调用。

- **tim2tox_ffi.h / tim2tox_ffi.cpp**：Platform 路径的高层 C API（`tim2tox_ffi_*`）
- **dart_compat_layer.cpp**：Binary Replacement 路径兼容层的"主入口"，模块化后只剩注释（28 行）
- **dart_compat_internal.h**：共享声明和前置声明
- **callback_bridge.h / callback_bridge.cpp**：回调桥接（`SendCallbackToDart` / `DartInitDartApiDL` / `DartRegisterSendPort`）
- **json_parser.h / json_parser.cpp**：JSON 消息构建与解析
- **`Dart*` 兼容层（12 个功能模块）**：
  - `dart_compat_utils.cpp` — 工具函数与全局变量
  - `dart_compat_listeners.cpp` — Listener 实现与回调注册
  - `dart_compat_callbacks.cpp` — 回调类实现
  - `dart_compat_sdk.cpp` — SDK 初始化与认证
  - `dart_compat_message.cpp` — 消息相关
  - `dart_compat_friendship.cpp` — 好友相关
  - `dart_compat_conversation.cpp` — 会话相关
  - `dart_compat_group.cpp` — 群组相关
  - `dart_compat_user.cpp` — 用户相关
  - `dart_compat_signaling.cpp` — 信令相关
  - `dart_compat_community.cpp` — 社区相关（占位）
  - `dart_compat_other.cpp` — 其他杂项（`DartCallExperimentalAPI`）

每个模块的当前规模与职责见 [MODULARIZATION.md](../architecture/MODULARIZATION.md)。

### 功能文档

- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) — Tim2Tox 架构（包含群聊实现说明，覆盖 Group vs Conference API、映射关系管理、恢复机制、回调机制、错误处理、性能优化）

详细说明请参考 [模块化文档](../architecture/MODULARIZATION.md)。

### 修改 FFI / dart_compat 前必读

- [MODULARIZATION.md](../architecture/MODULARIZATION.md) — dart_compat 模块拆分与职责
- [FFI_FUNCTION_DECLARATION_GUIDE.md](FFI_FUNCTION_DECLARATION_GUIDE.md) — `tim2tox_ffi_*` 的 `extern "C"` 声明规则与自检清单

#### 4. Dart 绑定层 (`dart/lib/`)

提供 Flutter/Dart 绑定。

- **ffi/**: 底层 FFI 绑定
- **service/**: 高级服务层
- **sdk/**: SDK Platform 实现
- **interfaces/**: 抽象接口定义

## 添加新功能

### 步骤 1: 在 C++ 层实现 V2TIM API

如果新功能需要添加新的 V2TIM API，首先在头文件中声明：

```cpp
// include/V2TIMMessageManager.h
virtual void NewFeature(const V2TIMString& param, V2TIMCallback* callback) = 0;
```

然后在实现文件中实现：

```cpp
// source/V2TIMMessageManagerImpl.cpp
void V2TIMMessageManagerImpl::NewFeature(const V2TIMString& param, V2TIMCallback* callback) {
    // 实现逻辑
    // 调用 ToxManager 或底层功能
    // 通过 callback 返回结果
}
```

### 步骤 2: 在 FFI 层添加 C 接口

如果需要从 Dart 层调用，在 `ffi/tim2tox_ffi.h` 中添加：

```c
// 新功能接口
int tim2tox_ffi_new_feature(const char* param);
```

在 `ffi/tim2tox_ffi.cpp` 中实现：

```cpp
int tim2tox_ffi_new_feature(const char* param) {
    auto mgr = V2TIMManager::GetInstance()->GetMessageManager();
    // 调用 V2TIM API
    // 返回结果
}
```

### 步骤 3: 在 Dart 层添加绑定

在 `dart/lib/ffi/tim2tox_ffi.dart` 中添加 FFI 绑定：

```dart
late final int Function(ffi.Pointer<pkgffi.Utf8>) newFeatureNative =
    _lib.lookupFunction<_new_feature_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_new_feature');

int newFeature(String param) {
  final paramPtr = param.toNativeUtf8();
  try {
    return newFeatureNative(paramPtr);
  } finally {
    malloc.free(paramPtr);
  }
}
```

在 `dart/lib/service/ffi_chat_service.dart` 中添加高级 API：

```dart
Future<bool> newFeature(String param) async {
  final result = _ffi.newFeature(param);
  return result == 1;
}
```

### 步骤 4: 在 SDK Platform 中添加

如果需要在 UIKit SDK 中使用，在 `dart/lib/sdk/tim2tox_sdk_platform.dart` 中实现：

```dart
@override
Future<V2TimCallback> newFeature({required String param}) async {
  try {
    final result = await ffiService.newFeature(param);
    return V2TimCallback(code: 0, desc: 'Success');
  } catch (e) {
    return V2TimCallback(code: -1, desc: e.toString());
  }
}
```

### 步骤 5: 添加回调支持（如需要）

如果需要事件回调，在 `ffi/callback_bridge.cpp` 中添加回调类型：

```cpp
// 在 GlobalCallbackType 枚举中添加
enum GlobalCallbackType {
    // ...
    kCallbackTypeNewFeature = 66,
};
```

在 Listener 实现中添加回调：

```cpp
// 在相应的 Listener 类中
void OnNewFeature(const V2TIMString& data) {
    std::string json = BuildGlobalCallbackJson(
        kCallbackTypeNewFeature,
        {{"data", data.CString()}}
    );
    SendCallbackToDart(json.c_str());
}
```

## 构建系统

> **日常构建/跑测试请以 [README_BUILD.md](../../README_BUILD.md) 为准**（作为唯一入口，包含脚本说明与故障排除）。本节保留为 CMake 参数与产物的技术参考，尽量不重复脚本细节。

### CMake 构建

Tim2Tox 使用 CMake 作为构建系统。

#### 基本构建

```bash
mkdir build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_FFI=ON
make -j$(nproc)
```

#### 构建选项

主要构建选项：

- `BUILD_FFI`: 是否构建 FFI 动态库（默认：ON）
- `BUILD_TOXAV`: 是否构建音视频支持（默认：OFF）
- `USE_IPV6`: 启用 IPv6 支持（默认：ON）
- `ENABLE_STATIC`: 构建静态库（默认：ON）
- `ENABLE_SHARED`: 构建动态库（默认：OFF）

日志级别选项：

- `ERROR`: 启用错误日志（默认：ON）
- `WARNING`: 启用警告日志（默认：ON）
- `INFO`: 启用信息日志（默认：ON）
- `DEBUG`: 启用调试日志（默认：OFF）
- `TRACE`: 启用跟踪日志（默认：OFF）

#### 使用构建脚本

```bash
./build.sh
```

更多脚本用法（包括推荐的 `build_ffi.sh`、增量/强制重建、测试运行与常见问题）请统一参考 [README_BUILD.md](../../README_BUILD.md)。

### 构建产物

构建完成后，在 `build/` 目录下会生成：

- `source/libtim2tox.a`: 静态库
- `ffi/libtim2tox_ffi.dylib` (macOS) 或 `libtim2tox_ffi.so` (Linux) 或 `tim2tox_ffi.dll` (Windows): FFI 动态库

### 依赖管理

#### 系统依赖

- **CMake**: >= 3.4.1
- **C++20 兼容的编译器**: GCC 10+, Clang 12+, MSVC 2019+
- **libsodium**: 加密库
  - macOS: `brew install libsodium`
  - Linux: `apt-get install libsodium-dev` 或 `yum install libsodium-devel`
  - Windows: 通过 vcpkg 安装

#### 第三方依赖

- **c-toxcore**: 自动通过 CMake 的 `FetchContent` 下载和构建
- **Google Test**: 用于单元测试（可选）

### 跨平台构建

#### macOS

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_FFI=ON
make -j$(sysctl -n hw.ncpu)
```

#### Linux

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_FFI=ON
make -j$(nproc)
```

#### Windows

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_FFI=ON -G "Visual Studio 16 2019" -A x64
cmake --build . --config Release
```

## 多实例支持

Tim2Tox 支持创建多个独立的 Tox 实例，每个实例拥有独立的网络端口、DHT ID 和持久化路径。这对于测试场景特别有用。

### 架构变更

**之前（单例模式）**：
- `ToxManager` 和 `V2TIMManagerImpl` 都是单例
- 所有测试节点共享同一个 Tox 实例
- 无法进行真正的多节点互操作测试

**现在（多实例支持）**：
- `ToxManager` 和 `V2TIMManagerImpl` 都是可实例化的类
- 保留了默认实例的向后兼容性（通过 `GetInstance()` 方法）
- 支持创建独立的测试实例，每个实例拥有独立的网络配置

### 测试实例管理（FFI 层）

**新增 FFI 函数**：
- `tim2tox_ffi_create_test_instance(const char* init_path)`: 创建新的测试实例
- `tim2tox_ffi_set_current_instance(int64_t instance_handle)`: 设置当前活动实例
- `tim2tox_ffi_destroy_test_instance(int64_t instance_handle)`: 销毁测试实例

**使用场景**：
- 自动化测试（`tim2tox/auto_tests`）：每个测试节点创建独立实例
- 本地 bootstrap 配置：节点可以通过 127.0.0.1 互相连接
- 测试隔离：每个实例使用独立的持久化路径

**生产环境**：
- 生产环境应用使用默认实例即可
- 无需调用测试实例管理函数
- 直接使用 `TIMManager.instance` 或 `V2TIMManagerImpl::GetInstance()`

### 实现细节

**C++ 层**：
- `ToxManager`: 从单例改为可实例化类，支持多个 Tox 实例
- `V2TIMManagerImpl`: 从单例改为可实例化类，每个实例拥有自己的 `ToxManager`
- 回调处理：使用全局 `Tox* -> ToxManager*` 映射处理不支持 `user_data` 的回调

**FFI 层**：
- 测试实例映射：`std::unordered_map<int64_t, V2TIMManagerImpl*>`
- 当前实例跟踪：`g_current_instance_id`（0 表示使用默认实例）
- 所有 FFI 函数通过 `GetCurrentInstance()` 获取正确的实例

**Dart 层**：
- `TestNode` 类（`tim2tox/auto_tests/test/test_helper.dart`）使用测试实例管理
- 每个 `TestNode` 在 `initSDK` 时创建独立的 C++ 实例
- 在 `login` 和 FFI 调用前设置当前实例

## 测试指南

### C++ 单元测试

使用 Google Test 框架进行单元测试。

#### 运行测试

```bash
cd build
make test
ctest
```

或者直接运行测试可执行文件：

```bash
./build/test/ToxUtilTest
```

#### 编写测试

在 `test/` 目录下创建测试文件：

```cpp
// test/NewFeatureTest.cpp
#include <gtest/gtest.h>
#include <V2TIMManager.h>

TEST(NewFeatureTest, BasicTest) {
    // 测试代码
    EXPECT_EQ(1, 1);
}
```

在 `test/CMakeLists.txt` 中添加：

```cmake
add_executable(NewFeatureTest NewFeatureTest.cpp)
target_link_libraries(NewFeatureTest tim2tox gtest gtest_main)
add_test(NAME NewFeatureTest COMMAND NewFeatureTest)
```

### Dart 测试

在 `dart/` 目录下运行：

```bash
cd dart
flutter test
```

### 多实例测试

Tim2Tox 支持多实例测试，允许在同一进程中运行多个独立的 Tox 节点：

```bash
cd auto_tests
flutter test test/scenarios/scenario_multi_instance_test.dart
```

**测试场景**：
- `scenario_multi_instance_test.dart`: 验证每个节点拥有独立的实例、端口和 DHT ID
- 验证节点之间可以通过 127.0.0.1 bootstrap 互相连接

**测试实例管理**：
- 每个 `TestNode` 在初始化时创建独立的 C++ 实例
- 使用 `configureLocalBootstrap()` 配置本地 bootstrap，加速节点连接
- 测试完成后自动销毁所有测试实例

### 集成测试

使用 `example/` 目录下的示例程序进行集成测试：

```bash
cd example/build
./echo_bot_client
./echo_bot_server
```

## 代码规范

### C++ 代码规范

- 使用 4 空格缩进
- 类名使用 PascalCase
- 函数名和变量名使用 camelCase
- 常量使用 UPPER_SNAKE_CASE
- 头文件使用 `#pragma once` 或 include guard
- 所有公共 API 必须有文档注释

### Dart 代码规范

- 遵循 Dart 官方风格指南
- 使用 2 空格缩进
- 类名使用 PascalCase
- 函数名和变量名使用 camelCase
- 常量使用 lowerCamelCase
- 所有公共 API 必须有文档注释

### 提交规范

提交消息格式：

```
<type>: <subject>

<body>

<footer>
```

类型：
- `feat`: 新功能
- `fix`: 修复 bug
- `docs`: 文档更新
- `style`: 代码格式调整
- `refactor`: 重构
- `test`: 测试相关
- `chore`: 构建/工具相关

## 调试技巧

### C++ 调试

#### 使用 GDB

```bash
gdb ./build/example/echo_bot_client
(gdb) break V2TIMMessageManagerImpl::SendMessage
(gdb) run
```

#### 使用 LLDB (macOS)

```bash
lldb ./build/example/echo_bot_client
(lldb) breakpoint set --name V2TIMMessageManagerImpl::SendMessage
(lldb) run
```

#### 启用调试日志

在 CMake 配置时启用：

```bash
cmake .. -DDEBUG=ON -DTRACE=ON
```

### Dart 调试

#### Flutter 调试

```bash
cd dart
flutter run --debug
```

#### 日志输出

在代码中使用 `LoggerService`：

```dart
loggerService?.debug('Debug message');
loggerService?.info('Info message');
loggerService?.warning('Warning message');
loggerService?.error('Error message', error, stackTrace);
```

### 常见问题

#### 1. 链接错误

**问题**: 找不到符号

**解决**: 
- 检查 CMakeLists.txt 中的链接库配置
- 确保所有依赖库都已正确链接
- 检查库的搜索路径

#### 2. 运行时崩溃

**问题**: 应用启动后崩溃

**常见原因和解决方案**:

1. **动态库路径问题**:
   - 检查动态库路径是否正确
   - 使用 `otool -L` (macOS) 或 `ldd` (Linux) 检查依赖
   - 确保所有依赖库都在正确的位置

2. **内存管理问题**:
   - 检查悬空指针
   - 使用智能指针管理对象生命周期
   - 避免在已销毁的对象上调用方法

3. **V2TIM_LOG 在 detached thread 中崩溃**:
   
   **问题描述**: 在 detached thread（如 `RejoinKnownGroups` 线程）中使用 `V2TIM_LOG` 可能导致崩溃，错误类型为 `EXC_BAD_ACCESS` 或 `Instruction Abort`。
   
   **根本原因**:
   - 静态局部变量析构顺序问题：`V2TIMLog` 单例可能在 detached thread 仍在运行时被销毁
   - 访问已销毁对象的成员变量：`mutex_` 可能在析构过程中被访问
   
   **解决方案**:
   - 避免在 detached thread 中使用 `V2TIM_LOG`
   - 使用 `fprintf(stderr, ...)` 替代（线程安全）
   - 确保 detached thread 在对象销毁前完成
   - 使用 `std::thread::join()` 等待线程完成
   
   **代码示例**:
   ```cpp
   // 不推荐：在 detached thread 中使用 V2TIM_LOG
   std::thread([this]() {
       V2TIM_LOG(kInfo, "Thread running");  // 可能导致崩溃
   }).detach();
   
   // 推荐：使用 fprintf 或确保线程在对象销毁前完成
   std::thread([this]() {
       fprintf(stderr, "[INFO] Thread running\n");  // 线程安全
   }).detach();
   
   // 或使用 join() 确保线程完成
   std::thread t([this]() {
       V2TIM_LOG(kInfo, "Thread running");
   });
   t.join();  // 等待线程完成
   ```
   
   **关键代码位置**:
   - `tim2tox/source/V2TIMManagerImpl.cpp:RejoinKnownGroups()` - 使用 detached thread
   - `tim2tox/source/V2TIMLog.cpp` - V2TIM_LOG 实现

4. **使用调试器定位崩溃**:
   - 使用 GDB 或 LLDB 查看崩溃位置
   - 检查堆栈跟踪
   - 查看内存状态

#### 3. FFI 调用失败

**问题**: Dart FFI 调用返回错误

**解决**:
- 检查函数签名是否匹配
- 检查参数类型转换
- 检查字符串生命周期（使用 `toNativeUtf8()` 和 `malloc.free()`）

#### 4. 回调不触发

**问题**: 注册的回调没有被调用

**解决**:
- 检查回调注册是否正确
- 检查 `SendCallbackToDart` 是否被调用
- 检查 Dart 层的 `ReceivePort` 是否正常监听

## 性能优化

### C++ 优化

- 避免不必要的字符串拷贝（使用引用）
- 使用移动语义（`std::move`）
- 减少动态内存分配
- 使用对象池复用对象

### Dart 优化

- 避免频繁的 FFI 调用
- 使用流（Stream）而不是轮询
- 缓存常用数据
- 使用 `Isolate` 处理耗时操作

## 相关文档

- [API 参考](../api/API_REFERENCE.md) - 完整 API 文档
- [Tim2Tox 架构](../architecture/ARCHITECTURE.md) - 整体架构设计
- [Tim2Tox FFI 兼容层](../architecture/FFI_COMPAT_LAYER.md) - Dart* 函数兼容层说明
