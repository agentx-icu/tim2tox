[English](./MULTI_INSTANCE_SUPPORT.md)

# Tim2Tox 多实例支持

## 概述

Tim2Tox 现在支持创建多个独立的 Tox 实例，每个实例拥有独立的网络端口、DHT ID 和持久化路径。这对于测试场景特别有用，允许在同一进程中运行多个节点进行互操作测试。

## 架构变更

### 之前（单例模式）

- `ToxManager` 和 `V2TIMManagerImpl` 都是单例
- 所有测试节点共享同一个 Tox 实例
- 无法进行真正的多节点互操作测试
- 所有节点使用相同的网络端口和 DHT ID

### 现在（多实例支持）

- `ToxManager` 和 `V2TIMManagerImpl` 都是可实例化的类
- 保留了默认实例的向后兼容性（通过 `GetInstance()` 方法）
- 支持创建独立的测试实例，每个实例拥有独立的网络配置
- 每个实例使用独立的持久化路径

## 使用场景

### 生产环境（默认实例）

对于生产环境应用，直接使用默认实例即可：

```dart
// 生产环境：直接使用默认实例
await TIMManager.instance.initSDK(...);
await TIMManager.instance.login(...);
```

**特点**：
- 无需特殊配置
- 使用 `V2TIMManagerImpl::GetInstance()` 获取默认实例
- 完全向后兼容

### 测试环境（多实例）

对于自动化测试（如 `tim2tox/auto_tests`），可以创建多个独立实例：

```dart
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;

// 创建测试实例
final ffiInstance = ffi_lib.Tim2ToxFfi.open();
final initPathPtr = '/path/to/instance/data'.toNativeUtf8();
final instanceHandle = ffiInstance.createTestInstanceNative(initPathPtr);

// 设置当前实例（后续 FFI 调用将使用此实例）
ffiInstance.setCurrentInstance(instanceHandle);

// 使用实例进行 SDK 操作
await TIMManager.instance.initSDK(...);
await TIMManager.instance.login(...);

// 销毁测试实例
ffiInstance.destroyTestInstance(instanceHandle);
```

**特点**：
- 每个测试节点拥有独立的实例
- 独立的网络端口和 DHT ID
- 独立的持久化路径，确保测试隔离
- 支持本地 bootstrap 配置，加速节点连接

## API 参考

### FFI 函数

#### `tim2tox_ffi_create_test_instance`

创建新的测试实例。

**函数签名**：
```c
int64_t tim2tox_ffi_create_test_instance(const char* init_path);
```

**参数**：
- `init_path`: 实例的初始化路径（用于持久化存储）

**返回值**：
- 成功：返回实例句柄（> 0）
- 失败：返回 0

**Dart 绑定**：
```dart
final ffiInstance = ffi_lib.Tim2ToxFfi.open();
final initPathPtr = '/path/to/data'.toNativeUtf8();
final handle = ffiInstance.createTestInstanceNative(initPathPtr);
```

#### `tim2tox_ffi_set_current_instance`

设置当前活动的实例。后续所有 FFI 调用将使用此实例。

**函数签名**：
```c
int tim2tox_ffi_set_current_instance(int64_t instance_handle);
```

**参数**：
- `instance_handle`: 实例句柄（0 表示使用默认实例）

**返回值**：
- 成功：返回 1
- 失败：返回 0

**Dart 绑定**：
```dart
ffiInstance.setCurrentInstance(handle);
```

**推荐**：多实例场景下请用 `Tim2ToxInstance.runWithInstance` / `runWithInstanceAsync` 包住对 `TIMManager`、`TIMFriendshipManager`、`TIMGroupManager` 等的调用，避免在测试或业务代码里频繁手写 `setCurrentInstance`。参见“实例作用域（推荐）”小节。

#### `tim2tox_ffi_destroy_test_instance`

销毁测试实例。

**函数签名**：
```c
int tim2tox_ffi_destroy_test_instance(int64_t instance_handle);
```

**参数**：
- `instance_handle`: 要销毁的实例句柄（不能是 0）

**返回值**：
- 成功：返回 1
- 失败：返回 0

**Dart 绑定**：
```dart
ffiInstance.destroyTestInstance(handle);
```

### 实例作用域（推荐）

多实例场景下应尽量用 **实例作用域** 包住对 `TIMManager`、`TIMFriendshipManager`、`TIMGroupManager` 等的调用，而不是在调用前到处手写 `setCurrentInstance`。

- **Tim2ToxInstance**（`package:tim2tox_dart/instance/tim2tox_instance.dart`）：对某个实例句柄的封装，提供：
  - `runWithInstance<R>(R Function() action)`：在“当前实例”设为该实例的前提下执行同步逻辑，执行完后恢复原先的当前实例。
  - `runWithInstanceAsync<R>(Future<R> Function() action)`：同上，用于异步逻辑。
- **TestNode**（`test_helper.dart`）提供 `runWithInstance` / `runWithInstanceAsync`，内部委托给 `Tim2ToxInstance.fromHandle(testInstanceHandle)`。测试中应对该节点做 SDK 操作时，使用 `node.runWithInstance(() => ...)` 或 `await node.runWithInstanceAsync(() async => ...)`，避免显式 `setCurrentInstance(node.testInstanceHandle!)`。

示例：

```dart
// 按实例执行一段逻辑
final instance = Tim2ToxInstance(instanceHandle);
await instance.runWithInstanceAsync(() async {
  await TIMManager.instance.login(...);
});
instance.runWithInstance(() => TIMManager.instance.someSyncCall());

// 在 TestNode 上
await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(...));
bob.runWithInstance(() => TIMMessageManager.instance.addAdvancedMsgListener(listener));
```

**按实例注册的调用**：凡依赖「当前实例」的注册（如 `setDhtNodesResponseCallback`、`ToxAVService` 构造时使用的 `getCurrentInstanceId()`、`addFriendListener` / `addGroupListener`）都应在对应实例的 `runWithInstance` / `runWithInstanceAsync` 内执行，这样 `getCurrentInstanceId()` 在注册时刻即为该实例的 handle，路由与生命周期才会正确。`test_helper` 中的 `enableAutoAccept` 已在 `runWithInstance` 内注册 listener；其他场景若需按实例注册，应同样包在 `node.runWithInstance` 内。

## 实现细节

### C++ 层

**ToxManager**：
- 从单例改为可实例化类
- 每个实例管理自己的 Tox 对象
- 回调处理：使用全局 `Tox* -> ToxManager*` 映射处理不支持 `user_data` 的回调

**V2TIMManagerImpl**：
- 从单例改为可实例化类
- 每个实例拥有自己的 `ToxManager`
- 保留了 `GetInstance()` 方法用于向后兼容

**关键代码**：
```cpp
// ToxManager.h
class ToxManager {
public:
    ToxManager();  // 公开构造函数
    ~ToxManager();

    // 向后兼容：获取默认实例
    static ToxManager* getDefaultInstance();
};

// V2TIMManagerImpl.h
class V2TIMManagerImpl : public V2TIMManager {
public:
    V2TIMManagerImpl();  // 公开构造函数
    ~V2TIMManagerImpl();

    // 向后兼容：获取默认实例
    static V2TIMManagerImpl* GetInstance();

    // 获取此实例的 ToxManager
    ToxManager* GetToxManager() { return tox_manager_.get(); }

private:
    std::unique_ptr<ToxManager> tox_manager_;
};
```

### FFI 层

**测试实例管理**：
- 实例映射：`std::unordered_map<int64_t, V2TIMManagerImpl*>`
- 当前实例跟踪：`g_current_instance_id`（0 表示使用默认实例）
- 所有 FFI 函数通过 `GetCurrentInstance()` 获取正确的实例

**关键代码**：
```cpp
// 测试实例管理
static std::mutex g_test_instances_mutex;
static std::unordered_map<int64_t, V2TIMManagerImpl*> g_test_instances;
static int64_t g_next_instance_id = 1;
static int64_t g_current_instance_id = 0; // 0 = 默认实例

// 获取当前实例
static V2TIMManagerImpl* GetCurrentInstance() {
    std::lock_guard<std::mutex> lock(g_test_instances_mutex);
    if (g_current_instance_id == 0) {
        return V2TIMManagerImpl::GetInstance();  // 默认实例
    }
    auto it = g_test_instances.find(g_current_instance_id);
    if (it != g_test_instances.end()) {
        return it->second;
    }
    return V2TIMManagerImpl::GetInstance();  // 回退到默认实例
}
```

### Dart 层

**TestNode 类**（`tim2tox/auto_tests/test/test_helper.dart`）：
- 每个 `TestNode` 在 `initSDK` 时创建独立的 C++ 实例
- 在 `login` 和 FFI 调用前设置当前实例
- 在 `dispose` 时销毁测试实例

**关键代码**：
```dart
class TestNode {
  int? _testInstanceHandle;

  int? get testInstanceHandle => _testInstanceHandle;

  Future<void> initSDK({String? initPath, String? logPath}) async {
    // 创建测试实例
    final ffiInstance = ffi_lib.Tim2ToxFfi.open();
    final initPathPtr = testInitPath.toNativeUtf8();
    try {
      final instanceHandle = ffiInstance.createTestInstanceNative(initPathPtr);
      _testInstanceHandle = instanceHandle;

      // 设置当前实例
      ffiInstance.setCurrentInstance(instanceHandle);
    } finally {
      pkgffi.malloc.free(initPathPtr);
    }

    // 初始化 SDK（使用当前实例）
    await timManager!.initSDK(...);
  }

  Future<void> login({Duration? timeout}) async {
    // 设置当前实例
    if (testInstanceHandle != null) {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      ffiInstance.setCurrentInstance(testInstanceHandle!);
    }

    // 登录（使用当前实例）
    await timManager!.login(...);
  }

  Future<void> dispose() async {
    // 销毁测试实例
    if (_testInstanceHandle != null) {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      ffiInstance.destroyTestInstance(_testInstanceHandle!);
      _testInstanceHandle = null;
    }
  }
}
```

## 测试验证

### 多实例测试

运行多实例测试验证功能：

```bash
cd tim2tox/auto_tests
flutter test test/scenarios/scenario_multi_instance_test.dart
```

**测试内容**：
1. 验证每个节点拥有独立的实例句柄
2. 验证每个节点拥有不同的 UDP 端口
3. 验证每个节点拥有不同的 DHT ID
4. 验证节点之间可以通过 127.0.0.1 bootstrap 互相连接

### 测试结果示例

```
[Test] Node alice: instance=1, port=33445, dhtId=F81861944932B2C3B46AA3AC3BEDF59C40A8E063AB6BC9D471305524DAC65343
[Test] Node bob: instance=2, port=33448, dhtId=6BFF8910CA9DA8645CEFCA10BA4BC07FF9AA3F1DF2A1D078E09AD5E47213910D
[Test] Node charlie: instance=3, port=33449, dhtId=BAE1C11998FC010680A59A5C4D8E2D4D250B2AB04B4FA62DD0DE678F59F04F3F
[Test] ✅ All nodes have independent instances, ports, and DHT IDs
```

## 向后兼容性

### 生产环境应用

**无需修改**：生产环境应用继续使用默认实例，无需任何代码修改。

**调用路径**：
```
TIMManager.instance.initSDK()
  ↓
NativeLibraryManager.bindings.DartInitSDK()
  ↓
dart_compat_sdk.cpp::DartInitSDK()
  ↓
V2TIMManagerImpl::GetInstance()->InitSDK()  // 使用默认实例
  ↓
ToxManager::getDefaultInstance()->initialize()  // 使用默认 ToxManager
```

### 测试环境

**需要修改**：测试环境需要使用新的测试实例管理 API。

**调用路径**：
```
TestNode.initSDK()
  ↓
ffiInstance.createTestInstanceNative()  // 创建新实例
  ↓
ffiInstance.setCurrentInstance()  // 设置当前实例
  ↓
TIMManager.instance.initSDK()
  ↓
GetCurrentInstance()->InitSDK()  // 使用当前测试实例
```

## 注意事项

1. **实例生命周期**：测试实例必须在测试完成后销毁，避免资源泄漏
2. **实例切换**：在调用 FFI / SDK 前，必须确保“当前实例”正确。**推荐**用 `Tim2ToxInstance.runWithInstance` / `runWithInstanceAsync` 或 TestNode 的 `runWithInstance` / `runWithInstanceAsync` 包住多实例调用，避免在业务或测试里到处手写 `setCurrentInstance`。
3. **默认实例**：生产环境始终使用默认实例，无需创建测试实例
4. **持久化路径**：每个测试实例使用独立的持久化路径，确保数据隔离

### V2TIMFriendshipManagerImpl 缓存与多实例（后续处理）

- **friend_id_map_**：在 `V2TIMFriendshipManagerImpl.h` 中声明，当前 .cpp 中未使用，可视为死代码；若将来启用且存在多实例，需按实例隔离或随实例切换清空。
- **friend_info_db_**、**friend_groups_**、**pending_applications_**：V2TIMFriendshipManagerImpl 为单例且**没有** SetManagerImpl，通过 GetCurrentInstance() 取 Tox；上述缓存在多实例下会混用。若约定“同一时刻仅一个当前实例”（单 isolate + runWithInstance 串行），可暂不修改；若将来需严格多实例隔离，应在 Friendship 层引入 SetManagerImpl 或“当前实例”抽象，并在实例切换时清空或按实例键隔离这些结构。

### 多线程与 setCurrentInstance

- **setCurrentInstance 非多线程安全**：`g_current_instance_id` 为进程内全局变量。若多线程同时调用 `setCurrentInstance`，或在 A 调用 `setCurrentInstance(alice)` 后、其后续 `GetCurrentInstance()` 前，另一线程调用了 `setCurrentInstance(bob)`，则 A 可能拿到错误实例。
- **推荐**：多实例使用应在**单 isolate** 内、通过 `runWithInstance` / `runWithInstanceAsync` **串行**执行各实例上的逻辑，不要在多线程中依赖“当前实例”的全局状态。
- 若将来需要多线程安全，可考虑在 C++ 侧将“当前实例”改为线程本地（如 `thread_local`），或让所有入口显式传 instance_id；目前文档约定为“单 isolate + runWithInstance 串行”。

### 多实例下 Tox 回调路由

结论：**仅部分回调能保证按实例正确路由**；经 SendCallbackToDart 的 globalCallback 在 C++ 填写的 instance_id 多数依赖“当前实例”，在 Tox 异步线程触发时可能错位，且 Dart 端目前未按 instance_id 分发。

#### 已正确按实例路由的回调

1. **DHT 节点响应**（`tim2tox_ffi.cpp`）
   - 在 `on_dht_nodes_response_internal(Tox* tox, ...)` 中根据 **Tox*** 在 `g_test_instances` 中查 instance_id，再按 instance_id 取 `g_instance_dht_callbacks[instance_id]` 与 user_data，回调时把 instance_id 带给 Dart。
   - Dart 侧 `_dhtNodesResponseTrampoline` 从 userData 读出 instance_id，用 `_instanceServices[instanceId]` 投递到对应 FfiChatService。

2. **ToxAV 回调**（on_call、on_call_state、audio/video receive）
   - C++ 在 `tim2tox_ffi_av_initialize` 里用 **闭包捕获的 instance_id** 注册到 ToxAVManager，触发时从 `g_instance_av_callbacks[captured_instance_id]` 取回调和 user_data。
   - Dart 侧 ToxAVService 的 trampoline 从 userData 读出 instance_id，用 `_instanceServices[instanceId]` 投递到对应 ToxAVService。

3. **好友申请列表增加**（OnFriendApplicationListAdded）
   - 在 `dart_compat_listeners.cpp` 的 `DartFriendshipListenerImpl::OnFriendApplicationListAdded` 中，**不用** `GetCurrentInstanceId()`，而是遍历 `g_friendship_listeners`，用 `this` 反查所属 instance_id，再以该 instance_id 调用 `BuildGlobalCallbackJson(..., instance_id)` 并 SendCallbackToDart。

#### 存在错误或未按实例路由的回调

1. **C++ 侧：多数 globalCallback 的 instance_id 来源错误**
   - `dart_compat_listeners.cpp` 中其余所有 OnXxx（如 OnConnectSuccess、OnRecvNewMessage、OnFriendListAdded、OnMessageRevoke、各 ConvEvent、各 Group 回调等）在**触发时**用 `GetCurrentInstanceId()` 得到 instance_id，再写入 JSON。
   - 这些回调往往由 **Tox 所在线程或异步路径** 触发（例如网络事件、好友/消息/群变更）。触发时“当前实例”来自主线程最后一次 `setCurrentInstance`，**不一定**等于产生事件的 Tox 所属实例，因此 JSON 里的 instance_id 可能对应错误实例。

2. **Dart 侧：未按 instance_id 分发**
   - `tencent_cloud_chat_sdk` 的 `NativeLibraryManager._handleGlobalCallback` 会解析并打印 `instance_id`，但**不**用它选择 listener；始终调用同一套 `_sdkListener`、`_advancedMsgListener`、`_friendshipListener` 等。
   - 即便 C++ 将来把 instance_id 写对，目前 Dart 仍是“单套全局 listener”，多实例下无法把回调只投递到“对应实例”的监听者。

#### 建议（后续可做）

- **C++**：对所有通过 dart_compat 发出的 globalCallback，在 OnXxx 内**不要**用 `GetCurrentInstanceId()` 填 instance_id，改为与 OnFriendApplicationListAdded 一致：从 listener 身份推 instance_id（例如在 `g_sdk_listeners` / `g_advanced_msg_listeners` / `g_group_listeners` 等里用 `this` 反查 instance_id），再传入 `BuildGlobalCallbackJson(..., instance_id)`。
- **Dart/SDK**：若要做严格多实例，需在 NativeLibraryManager（或上层）维护“instance_id → 该实例的 SDK/AdvancedMsg/Friendship/Group 等 listener 集合”，在 `_handleGlobalCallback` 中根据 JSON 的 `instance_id` 只通知对应实例的 listener；否则即便 C++ 填对 instance_id，仍会广播到所有实例的 listener。

在**单 isolate + 仅通过 runWithInstance/runWithInstanceAsync 串行切换“当前实例”**的约定下，若所有 listener 的注册与业务都包在对应实例的 `runWithInstance` 内，且 Tox 回调触发时主线程不会恰好在“另一实例”的 runWithInstance 中，则多数场景下可能仍能工作，但**不能保证**“谁的事件就一定送给谁”；严格多实例仍需上述 C++ 与 Dart 两处改动。

## 相关文件

- **C++ 实现**：
  - `tim2tox/source/ToxManager.h/cpp`
  - `tim2tox/source/V2TIMManagerImpl.h/cpp`
- **FFI 接口**：
  - `tim2tox/ffi/tim2tox_ffi.h/cpp`
- **Dart 绑定**：
  - `tim2tox/dart/lib/ffi/tim2tox_ffi.dart`
  - `tim2tox/dart/lib/instance/tim2tox_instance.dart`（实例作用域）
- **测试代码**：
  - `tim2tox/auto_tests/test/test_helper.dart`
  - `tim2tox/auto_tests/test/scenarios/scenario_multi_instance_test.dart`
