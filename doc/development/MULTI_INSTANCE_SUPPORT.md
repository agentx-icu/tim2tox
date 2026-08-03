[简体中文](./MULTI_INSTANCE_SUPPORT.zh-CN.md)

# Tim2Tox Multi-Instance Support

## Overview

Tim2Tox now supports the creation of multiple independent Tox instances, each with independent network ports, DHT IDs and persistence paths. This is particularly useful for testing scenarios, allowing multiple nodes to be run in the same process for interoperability testing.

## Architecture changes

### Before (singleton mode)

- `ToxManager` and `V2TIMManagerImpl` are singletons
- All test nodes share the same Tox instance
- No true multi-node interoperability testing possible
- All nodes use the same network port and DHT ID

### Now (multi-instance support)

- `ToxManager` and `V2TIMManagerImpl` are instantiable classes
- Preserved backward compatibility of default instances (via `GetInstance()` method)
- Supports the creation of independent test instances, each instance has independent network configuration
- Use independent persistence paths for each instance

## Usage scenarios

### Production environment (default instance)

For production applications, use the default instance:

```dart
// Production environment: use the default instance directly
await TIMManager.instance.initSDK(...);
await TIMManager.instance.login(...);
```

**Features**:
- No special configuration required
- Use `V2TIMManagerImpl::GetInstance()` to get the default instance
- Fully backwards compatible

### Test environment (multiple instances)

For automated testing (such as `tim2tox/auto_tests`), multiple independent instances can be created:

```dart
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;

// Create test instance
final ffiInstance = ffi_lib.Tim2ToxFfi.open();
final initPathPtr = '/path/to/instance/data'.toNativeUtf8();
final instanceHandle = ffiInstance.createTestInstanceNative(initPathPtr);

// Sets the current instance (subsequent FFI calls will use this instance)
ffiInstance.setCurrentInstance(instanceHandle);

// Use examples for SDK operations
await TIMManager.instance.initSDK(...);
await TIMManager.instance.login(...);

// Destroy test instance
ffiInstance.destroyTestInstance(instanceHandle);
```

**Features**:
- Each test node has an independent instance
- Separate network port and DHT ID
- Independent persistence path to ensure test isolation
- Support local bootstrap configuration to speed up node connection

## API Reference

### FFI function

#### `tim2tox_ffi_create_test_instance`

Create a new test instance.

**Function signature**:
```c
int64_t tim2tox_ffi_create_test_instance(const char* init_path);
```

**Parameters**:
- `init_path`: Initialization path of the instance (for persistent storage)

**Return Value**:
- Success: Returns instance handle (> 0)
- Failure: return 0

**Dart binding**:
```dart
final ffiInstance = ffi_lib.Tim2ToxFfi.open();
final initPathPtr = '/path/to/data'.toNativeUtf8();
final handle = ffiInstance.createTestInstanceNative(initPathPtr);
```

#### `tim2tox_ffi_set_current_instance`

Sets the currently active instance. All subsequent FFI calls will use this instance.

**Function signature**:
```c
int tim2tox_ffi_set_current_instance(int64_t instance_handle);
```

**Parameters**:
- `instance_handle`: instance handle (0 means use the default instance)

**Return Value**:
- Success: Return 1
- Failure: return 0

**Dart binding**:
```dart
ffiInstance.setCurrentInstance(handle);
```

**Recommendation**: In multi-instance scenarios, please use `Tim2ToxInstance.runWithInstance` / `runWithInstanceAsync` to wrap calls to `TIMManager`, `TIMFriendshipManager`, `TIMGroupManager`, etc. to avoid frequent handwriting of `setCurrentInstance` in test or business code. See the "Instance scope (recommended)" section.

#### `tim2tox_ffi_destroy_test_instance`

Destroy the test instance.

**Function signature**:
```c
int tim2tox_ffi_destroy_test_instance(int64_t instance_handle);
```

**Parameters**:
- `instance_handle`: Instance handle to be destroyed (cannot be 0)

**Return Value**:
- Success: Return 1
- Failure: return 0

**Dart binding**:
```dart
ffiInstance.destroyTestInstance(handle);
```

### Instance scope (recommended)

In multi-instance scenarios, you should try to use **instance scope** to wrap calls to `TIMManager`, `TIMFriendshipManager`, `TIMGroupManager`, etc. instead of handwriting `setCurrentInstance` everywhere before calling.

- **Tim2ToxInstance** (`package:tim2tox_dart/instance/tim2tox_instance.dart`): An encapsulation of an instance handle, providing:
  - `runWithInstance<R>(R Function() action)`: Execute synchronization logic under the premise that the "current instance" is set to this instance, and restore the original current instance after execution.
  - `runWithInstanceAsync<R>(Future<R> Function() action)`: Same as above, used for asynchronous logic.
- **TestNode** (`test_helper.dart`) provides `runWithInstance` / `runWithInstanceAsync` and delegates internally to `Tim2ToxInstance.fromHandle(testInstanceHandle)`. When performing SDK operations on this node during testing, use `node.runWithInstance(() => ...)` or `await node.runWithInstanceAsync(() async => ...)` to avoid explicit `setCurrentInstance(node.testInstanceHandle!)`.

Example:

```dart
// Execute a piece of logic based on an instance
final instance = Tim2ToxInstance(instanceHandle);
await instance.runWithInstanceAsync(() async {
  await TIMManager.instance.login(...);
});
instance.runWithInstance(() => TIMManager.instance.someSyncCall());

// on TestNode
await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(...));
bob.runWithInstance(() => TIMMessageManager.instance.addAdvancedMsgListener(listener));
```

**Call by instance registration**: Any registration that relies on the "current instance" (such as `getCurrentInstanceId()`, `addFriendListener` / `addGroupListener` used in the construction of `setDhtNodesResponseCallback`, `ToxAVService`) should be executed within the `runWithInstance` / `runWithInstanceAsync` of the corresponding instance, so that `getCurrentInstanceId()` is the instance of the instance at the time of registration. handle, routing and lifecycle will be correct. `enableAutoAccept` in `test_helper` has registered listener in `runWithInstance`; if other scenarios need to be registered by instance, they should also be included in `node.runWithInstance`.

## Implementation details

### C++ layer

**ToxManager**:
- Changed from singleton to instantiable class
- Each instance manages its own Tox object
- Callback processing: Use the global `Tox* -> ToxManager*` mapping to handle callbacks that do not support `user_data`

**V2TIMManagerImpl**:
- Changed from singleton to instantiable class
- Each instance has its own `ToxManager`
- Retained `GetInstance()` method for backward compatibility

**Key code**:
```cpp
// ToxManager.h
class ToxManager {
public:
    ToxManager();  // public constructor
    ~ToxManager();

    // Backward compatibility: Get the default instance
    static ToxManager* getDefaultInstance();
};

// V2TIMManagerImpl.h
class V2TIMManagerImpl : public V2TIMManager {
public:
    V2TIMManagerImpl();  // public constructor
    ~V2TIMManagerImpl();

    // Backward compatibility: Get the default instance
    static V2TIMManagerImpl* GetInstance();

    // Get the ToxManager for this instance
    ToxManager* GetToxManager() { return tox_manager_.get(); }

private:
    std::unique_ptr<ToxManager> tox_manager_;
};
```

### FFI layer

**Test instance management**:
- Instance mapping: `std::unordered_map<int64_t, V2TIMManagerImpl*>`
- Current instance tracking: `g_current_instance_id` (0 means use the default instance)
- All FFI functions get the correct instance via `GetCurrentInstance()`

**Key code**:
```cpp
// Test instance management
static std::mutex g_test_instances_mutex;
static std::unordered_map<int64_t, V2TIMManagerImpl*> g_test_instances;
static int64_t g_next_instance_id = 1;
static int64_t g_current_instance_id = 0; // 0 = default instance

// Get the current instance
static V2TIMManagerImpl* GetCurrentInstance() {
    std::lock_guard<std::mutex> lock(g_test_instances_mutex);
    if (g_current_instance_id == 0) {
        return V2TIMManagerImpl::GetInstance();  // default instance
    }
    auto it = g_test_instances.find(g_current_instance_id);
    if (it != g_test_instances.end()) {
        return it->second;
    }
    return V2TIMManagerImpl::GetInstance();  // Fallback to default instance
}
```

### Dart layer

**TestNode class** (`tim2tox/auto_tests/test/test_helper.dart`):
- Each `TestNode` creates an independent C++ instance at `initSDK`
- Set current instance before `login` and FFI calls
- Destroy test instance at `dispose`

**Key code**:
```dart
class TestNode {
  int? _testInstanceHandle;

  int? get testInstanceHandle => _testInstanceHandle;

  Future<void> initSDK({String? initPath, String? logPath}) async {
    // Create test instance
    final ffiInstance = ffi_lib.Tim2ToxFfi.open();
    final initPathPtr = testInitPath.toNativeUtf8();
    try {
      final instanceHandle = ffiInstance.createTestInstanceNative(initPathPtr);
      _testInstanceHandle = instanceHandle;

      // Set current instance
      ffiInstance.setCurrentInstance(instanceHandle);
    } finally {
      pkgffi.malloc.free(initPathPtr);
    }

    // Initialize SDK (using current instance)
    await timManager!.initSDK(...);
  }

  Future<void> login({Duration? timeout}) async {
    // Set current instance
    if (testInstanceHandle != null) {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      ffiInstance.setCurrentInstance(testInstanceHandle!);
    }

    // Log in (using current instance)
    await timManager!.login(...);
  }

  Future<void> dispose() async {
    // Destroy test instance
    if (_testInstanceHandle != null) {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      ffiInstance.destroyTestInstance(_testInstanceHandle!);
      _testInstanceHandle = null;
    }
  }
}
```

## Test verification

### Multiple instance testing

Run a multi-instance test to verify functionality:

```bash
cd tim2tox/auto_tests
flutter test test/scenarios/scenario_multi_instance_test.dart
```

**Test content**:
1. Verify that each node has an independent instance handle
2. Verify that each node has a different UDP port
3. Verify that each node has a different DHT ID
4. Verify that nodes can connect to each other through 127.0.0.1 bootstrap

### Test result example

```
[Test] Node alice: instance=1, port=33445, dhtId=F81861944932B2C3B46AA3AC3BEDF59C40A8E063AB6BC9D471305524DAC65343
[Test] Node bob: instance=2, port=33448, dhtId=6BFF8910CA9DA8645CEFCA10BA4BC07FF9AA3F1DF2A1D078E09AD5E47213910D
[Test] Node charlie: instance=3, port=33449, dhtId=BAE1C11998FC010680A59A5C4D8E2D4D250B2AB04B4FA62DD0DE678F59F04F3F
[Test] ✅ All nodes have independent instances, ports, and DHT IDs
```

## Backward compatibility

### Production environment application

**No modifications required**: Production applications continue to use the default instance without any code modifications.

**Call path**:
```
TIMManager.instance.initSDK()
  ↓
NativeLibraryManager.bindings.DartInitSDK()
  ↓
dart_compat_sdk.cpp::DartInitSDK()
  ↓
V2TIMManagerImpl::GetInstance()->InitSDK()  // Use default instance
  ↓
ToxManager::getDefaultInstance()->initialize()  // Use default ToxManager
```

### Test environment

**MODIFICATION REQUIRED**: The test environment needs to use the new test instance management API.

**Call path**:
```
TestNode.initSDK()
  ↓
ffiInstance.createTestInstanceNative()  // Create new instance
  ↓
ffiInstance.setCurrentInstance()  // Set current instance
  ↓
TIMManager.instance.initSDK()
  ↓
GetCurrentInstance()->InitSDK()  // Use current test instance
```

## Notes

1. **Instance lifecycle**: The test instance must be destroyed after the test is completed to avoid resource leakage
2. **Instance switching**: Before calling FFI/SDK, you must ensure that the "current instance" is correct. **Recommended** Use `Tim2ToxInstance.runWithInstance` / `runWithInstanceAsync` or TestNode's `runWithInstance` / `runWithInstanceAsync` to wrap multi-instance calls to avoid handwriting `setCurrentInstance` everywhere in business or testing.
3. **Default instance**: The production environment always uses the default instance, no need to create a test instance
4. **Persistence path**: Each test instance uses an independent persistence path to ensure data isolation### V2TIMFriendshipManagerImpl caching and multiple instances (subsequent processing)

- **friend_id_map_**: Declared in `V2TIMFriendshipManagerImpl.h`, it is not used in the current .cpp and can be regarded as dead code; if it is enabled in the future and there are multiple instances, it needs to be isolated by instance or cleared with instance switching.
- **friend_info_db_**, **friend_groups_**, **pending_applications_**: V2TIMFrendshipManagerImpl is a singleton and **does not** SetManagerImpl. Tox is obtained through GetCurrentInstance(); the above caches will be mixed in multiple instances. If it is agreed that "there is only one current instance at the same time" (single isolate + runWithInstance serial), you can leave it unchanged for now; if strict multi-instance isolation is required in the future, SetManagerImpl or "current instance" abstraction should be introduced in the Friendship layer, and these structures should be cleared or isolated by instance key when switching instances.

### Multithreading and setCurrentInstance

- **setCurrentInstance is not multi-thread safe**: `g_current_instance_id` is an in-process global variable. If multiple threads call `setCurrentInstance` at the same time, or after A calls `setCurrentInstance(alice)` but before its subsequent `GetCurrentInstance()`, another thread calls `setCurrentInstance(bob)`, then A may get an error instance.
- **Recommendation**: When using multiple instances, the logic on each instance should be executed in **single isolate** through `runWithInstance` / `runWithInstanceAsync` **serial**, and do not rely on the global state of the "current instance" in multi-threads.
- If multi-thread safety is required in the future, consider changing the "current instance" to thread local (such as `thread_local`) on the C++ side, or let all entries explicitly pass instance_id; the current document convention is "single isolate + runWithInstance serial".

### Tox callback routing under multiple instances

Conclusion: **Only some callbacks can guarantee correct routing by instance**; the instance_id filled in in C++ via SendCallbackToDart's globalCallback mostly relies on the "current instance" and may be misplaced when the Tox asynchronous thread is triggered, and the Dart side is not currently distributed by instance_id.

#### Correctly routed callbacks per instance

1. **DHT node response** (`tim2tox_ffi.cpp`)
   - In `on_dht_nodes_response_internal(Tox* tox, ...)`, check the instance_id in `g_test_instances` based on **Tox***, then press instance_id to get `g_instance_dht_callbacks[instance_id]` and user_data, and bring instance_id to Dart during callback.
   - Dart side `_dhtNodesResponseTrampoline` reads the instance_id from userData and delivers it to the corresponding FfiChatService using `_instanceServices[instanceId]`.

2. **ToxAV callback** (on_call, on_call_state, audio/video receive)
   - C++ uses the instance_id captured by the closure in `tim2tox_ffi_av_initialize` to register to ToxAVManager, and gets the callback and user_data from `g_instance_av_callbacks[captured_instance_id]` when triggered.
   - The trampoline of ToxAVService on the Dart side reads the instance_id from userData and delivers it to the corresponding ToxAVService using `_instanceServices[instanceId]`.

3. **Friend application list added** (OnFriendApplicationListAdded)
   - In `dart_compat_listeners.cpp`'s `DartFriendshipListenerImpl::OnFriendApplicationListAdded`, instead of using `GetCurrentInstanceId()`, traverse `g_friendship_listeners`, use `this` to check the instance_id it belongs to, and then use this instance_id to call `BuildGlobalCallbackJson(..., instance_id)` and SendCallbackToDart.

#### There is an error or the callback is not routed by instance

1. **C++ side: The source of instance_id of most globalCallbacks is wrong**
   - All other OnXxx in `dart_compat_listeners.cpp` (such as OnConnectSuccess, OnRecvNewMessage, OnFriendListAdded, OnMessageRevoke, each ConvEvent, each Group callback, etc.) use `GetCurrentInstanceId()` to get the instance_id when triggered, and then write it to JSON.
   - These callbacks are often triggered by the thread or asynchronous path where **Tox is located** (such as network events, friend/message/group changes). When triggered, the "current instance" comes from the last `setCurrentInstance` of the main thread, which is not necessarily equal to the instance of the Tox that generated the event, so the instance_id in JSON may correspond to the wrong instance.

2. **Dart side: not distributed by instance_id**
   - `tencent_cloud_chat_sdk`'s `NativeLibraryManager._handleGlobalCallback` will parse and print `instance_id`, but will not use it to select the listener; always calling the same set of `_sdkListener`, `_advancedMsgListener`, `_friendshipListener`, etc.
   - Even if C++ writes the instance_id correctly in the future, Dart currently still has a "single set of global listeners", and it is impossible to deliver callbacks only to the listeners of the "corresponding instance" in multiple instances.

#### Suggestions (can be done later)

- **C++**: For all globalCallbacks issued through dart_compat, **do not** use `GetCurrentInstanceId()` to fill in the instance_id in OnXxx. Change it to the same as OnFriendApplicationListAdded: push the instance_id from the listener identity (for example, use `this` in `g_sdk_listeners` / `g_advanced_msg_listeners` / `g_group_listeners`, etc. to check back instance_id), and then pass in `BuildGlobalCallbackJson(..., instance_id)`.
- **Dart/SDK**: If you want to implement strict multi-instance, you need to maintain "instance_id → the SDK/AdvancedMsg/Friendship/Group and other listener collections of the instance" in NativeLibraryManager (or the upper layer). In `_handleGlobalCallback`, only the listener of the corresponding instance is notified according to JSON's `instance_id`; otherwise, even if C++ fills in the correct instance_id, it will still be broadcast to the listeners of all instances.

Under the agreement of **single isolate + serial switching of "current instance" only through runWithInstance/runWithInstanceAsync**, if the registration and business of all listeners are included in the `runWithInstance` of the corresponding instance, and the main thread will not happen to be in the runWithInstance of "another instance" when the Tox callback is triggered, it may still work in most scenarios, but there is no guarantee** that "whose event will be sent to whom"; Strict multi-instance still requires the above C++ and Dart has two changes.

## Related documents

- **C++ implementation**:
  - `tim2tox/source/ToxManager.h/cpp`
  - `tim2tox/source/V2TIMManagerImpl.h/cpp`
- **FFI interface**:
  - `tim2tox/ffi/tim2tox_ffi.h/cpp`
- **Dart Bindings**:
  - `tim2tox/dart/lib/ffi/tim2tox_ffi.dart`
  - `tim2tox/dart/lib/instance/tim2tox_instance.dart` (instance scope)
- **Test Code**:
  - `tim2tox/auto_tests/test/test_helper.dart`
  - `tim2tox/auto_tests/test/scenarios/scenario_multi_instance_test.dart`
