# Tim2Tox Development Guide
> Language: [Chinese](DEVELOPMENT_GUIDE.md) | [English](DEVELOPMENT_GUIDE.en.md)


This document provides development guidelines for Tim2Tox, including how to add new features, code structure instructions, build system instructions, and testing guidelines.

## Contents

- [Code Structure](#code-structure)
- [Add New Features](#add-new-features)
- [Build System](#build-system)
- [Testing Guide](#testing-guide)
- [Coding Guidelines](#code-specifications)
- [Debugging Tips](#debugging-tips)

## Code structure

### Contents structure

```
tim2tox/
├── include/ # public headers (V2TIM API definitions)
│   ├── V2TIMManager.h
│   ├── V2TIMMessageManager.h
│   ├── V2TIMFriendshipManager.h
│   ├── V2TIMGroupManager.h
│   └── ...
├── source/ # C++ core implementation
│   ├── V2TIMManagerImpl.cpp/h
│   ├── V2TIMMessageManagerImpl.cpp/h
│   ├── V2TIMFriendshipManagerImpl.cpp/h
│   ├── V2TIMGroupManagerImpl.cpp/h
│   ├── ToxManager.cpp/h
│   └── ...
├── ffi/ # C/C++ FFI interface layer
│   ├── tim2tox_ffi.h/cpp
│   ├── dart_compat_layer.h/cpp
│   ├── callback_bridge.h/cpp
│   ├── json_parser.h/cpp
│   └── CMakeLists.txt
├── dart/ # Dart package (Flutter binding)
│   ├── lib/
│ │ ├── ffi/ # FFI binding layer
│ │ ├── service/ # Service layer
│ │ ├── sdk/ # SDK Platform implementation
│ │ ├── models/ # Data model
│ │ └── interfaces/ # abstract interface
│   └── pubspec.yaml
├── test/ # C++ test
│   ├── CMakeLists.txt
│   ├── ToxUtilTest.cpp
│   └── ...
├── example/ # C++ example program
│   ├── echo_bot_client.cpp
│   ├── echo_bot_server.cpp
│   └── ...
├── third_party/ # Third-party dependency (c-toxcore)
├── CMakeLists.txt # Main build file
└── build.sh # Build script
```

### Core module

#### 1. V2TIM implementation layer (`source/`)

Implement V2TIM API and provide an interface compatible with Tencent Cloud IM SDK.

- **V2TIMManagerImpl**: core manager implementation
- **V2TIMMessageManagerImpl**: Message management implementation
- **V2TIMFrendshipManagerImpl**: friend management implementation
- **V2TIMGroupManagerImpl**: Group management implementation
- **V2TIMConversationManagerImpl**: session management implementation
- **V2TIMSignalingManagerImpl**: signaling management implementation
- **V2TIMCommunityManagerImpl**: community management implementation

#### 2. Tox core layer (`source/ToxManager.*`)

Manage Tox instances and lifecycle, and handle underlying P2P communication.

- **ToxManager**: Tox instance management
- **ToxAVManager**: audio and video management (optional)
- **IrcClientManager**: IRC channel bridge management

#### 3. FFI interface layer (`ffi/`)

Provides the C interface that Dart FFI calls.

- **tim2tox_ffi.h / tim2tox_ffi.cpp** — the high-level Platform-path C API (`tim2tox_ffi_*`)
- **dart_compat_layer.cpp** — the "main entry" for the binary-replacement compat layer; after modularization it is just 28 lines of comments
- **dart_compat_internal.h** — shared declarations and forward declarations
- **callback_bridge.h / callback_bridge.cpp** — callback bridge (`SendCallbackToDart` / `DartInitDartApiDL` / `DartRegisterSendPort`)
- **json_parser.h / json_parser.cpp** — JSON message construction and parsing
- **`Dart*` compat layer (12 functional modules)**:
  - `dart_compat_utils.cpp` — utility functions and globals
  - `dart_compat_listeners.cpp` — listener impls and callback registration
  - `dart_compat_callbacks.cpp` — callback classes
  - `dart_compat_sdk.cpp` — SDK init and auth
  - `dart_compat_message.cpp` — messaging
  - `dart_compat_friendship.cpp` — friends
  - `dart_compat_conversation.cpp` — conversations
  - `dart_compat_group.cpp` — groups
  - `dart_compat_user.cpp` — users
  - `dart_compat_signaling.cpp` — signaling
  - `dart_compat_community.cpp` — community (placeholder)
  - `dart_compat_other.cpp` — miscellaneous (`DartCallExperimentalAPI`)

For per-module sizes and responsibilities, see [MODULARIZATION.en.md](../architecture/MODULARIZATION.en.md).

### Functional documentation

- [ARCHITECTURE.en.md](../architecture/ARCHITECTURE.en.md) — Tim2Tox architecture (covers group-chat implementation: Group vs Conference API, mapping management, recovery, callback mechanism, error handling, performance)

### Read before modifying FFI / dart_compat

- [MODULARIZATION.en.md](../architecture/MODULARIZATION.en.md) — dart_compat modular split and responsibilities
- [FFI_FUNCTION_DECLARATION_GUIDE.en.md](FFI_FUNCTION_DECLARATION_GUIDE.en.md) — `extern "C"` declaration rules and checklist for `tim2tox_ffi_*`

#### 4. Dart binding layer (`dart/lib/`)

Provides Flutter/Dart bindings.

- **ffi/**: underlying FFI binding
- **service/**: Advanced service layer
- **sdk/**: SDK Platform implementation
- **interfaces/**: abstract interface definition

## Add new features

### Step 1: Implement V2TIM API in C++ layer

If new functionality requires adding a new V2TIM API, first declare it in the header file:

```cpp
// include/V2TIMMessageManager.h
virtual void NewFeature(const V2TIMString& param, V2TIMCallback* callback) = 0;
```

Then implement it in the implementation file:

```cpp
// source/V2TIMMessageManagerImpl.cpp
void V2TIMMessageManagerImpl::NewFeature(const V2TIMString& param, V2TIMCallback* callback) {
    // Implement logic
    // Call ToxManager or underlying function
    // Return results through callback
}
```

### Step 2: Add C interface at FFI layer

If you need to call it from the Dart layer, add in `ffi/tim2tox_ffi.h`:

```c
// New functional interface
int tim2tox_ffi_new_feature(const char* param);
```

Implemented in `ffi/tim2tox_ffi.cpp`:

```cpp
int tim2tox_ffi_new_feature(const char* param) {
    auto mgr = V2TIMManager::GetInstance()->GetMessageManager();
    // Call V2TIM API
    // Return results
}
```

### Step 3: Add binding in Dart layer

Add FFI binding in `dart/lib/ffi/tim2tox_ffi.dart`:

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

Add high-level API in `dart/lib/service/ffi_chat_service.dart`:

```dart
Future<bool> newFeature(String param) async {
  final result = _ffi.newFeature(param);
  return result == 1;
}
```

### Step 4: Add in SDK Platform

If you need to use it in UIKit SDK, implement it in `dart/lib/sdk/tim2tox_sdk_platform.dart`:

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

### Step 5: Add callback support (if needed)

If event callback is required, add the callback type in `ffi/callback_bridge.cpp`:

```cpp
// Added in GlobalCallbackType enumeration
enum GlobalCallbackType {
    // ...
    kCallbackTypeNewFeature = 66,
};
```

Add callback in Listener implementation:

```cpp
// In the corresponding Listener class
void OnNewFeature(const V2TIMString& data) {
    std::string json = BuildGlobalCallbackJson(
        kCallbackTypeNewFeature,
        {{"data", data.CString()}}
    );
    SendCallbackToDart(json.c_str());
}
```

## Build system

> **For day-to-day build & test workflows, use [README_BUILD.md](../../README_BUILD.md) as the single source of truth** (scripts, options, troubleshooting). This section stays as a technical reference for CMake flags and build outputs, and avoids duplicating script details.

### CMake build

Tim2Tox uses CMake as the build system.

#### Basic build

```bash
mkdir build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_FFI=ON
make -j$(nproc)
```

#### Build options

Main build options:

- `BUILD_FFI`: Whether to build FFI dynamic library (default: ON)
- `BUILD_TOXAV`: Whether to build audio and video support (default: OFF)
- `USE_IPV6`: Enable IPv6 support (default: ON)
- `ENABLE_STATIC`: Build static library (default: ON)
- `ENABLE_SHARED`: Build dynamic library (default: OFF)

Log level options:

- `ERROR`: Enable error logging (default: ON)
- `WARNING`: Enable warning logging (default: ON)
- `INFO`: Enable message logging (default: ON)
- `DEBUG`: Enable debug log (default: OFF)
- `TRACE`: Enable trace log (default: OFF)

#### Using build script

```bash
./build.sh
```

For script usage (including the recommended `build_ffi.sh`, incremental/forced rebuild, running tests, and common issues), refer to [README_BUILD.md](../../README_BUILD.md).

### Build product

After the build is completed, the following will be generated in the `build/` directory:

- `source/libtim2tox.a`: static library
- `ffi/libtim2tox_ffi.dylib` (macOS) or `libtim2tox_ffi.so` (Linux) or `tim2tox_ffi.dll` (Windows): FFI dynamic library

### Dependency management

#### System dependencies

- **CMake**: >= 3.4.1
- **C++20 compatible compilers**: GCC 10+, Clang 12+, MSVC 2019+
- **libsodium**: encryption library
  - macOS: `brew install libsodium`
  - Linux: `apt-get install libsodium-dev` or `yum install libsodium-devel`
  - Windows: Install via vcpkg

#### Third-party dependencies

- **c-toxcore**: Automatically download and build via CMake's `FetchContent`
- **Google Test**: for unit testing (optional)

### Cross-platform build

#### macOS

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_FFI=ON
make -j$(sysctl -n hw.ncpu)
```

#### Linux

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_FFI=ON
make -j$(nproc)
```#### Windows

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_FFI=ON -G "Visual Studio 16 2019" -A x64
cmake --build . --config Release
```

## Multiple instance support
Tim2Tox supports the creation of multiple independent Tox instances, each instance has an independent network port, DHT ID and persistence path. This is especially useful for testing scenarios.

### Architecture changes

**Before (singleton mode)**:
- `ToxManager` and `V2TIMManagerImpl` are both singletons
- All test nodes share the same Tox instance
- No true multi-node interoperability testing possible

**Now (Multiple Instance Support)**:
- `ToxManager` and `V2TIMManagerImpl` are instantiable classes
- Preserved backward compatibility of default instances (via `GetInstance()` method)
- Supports the creation of independent test instances, each instance has independent network configuration

### Test instance management (FFI layer)

**New FFI function**:
- `tim2tox_ffi_create_test_instance(const char* init_path)`: Create a new test instance
- `tim2tox_ffi_set_current_instance(int64_t instance_handle)`: Set the current active instance
- `tim2tox_ffi_destroy_test_instance(int64_t instance_handle)`: Destroy test instance

**Usage Scenario**:
- Automated testing (`tim2tox/auto_tests`): Create an independent instance for each test node
- Local bootstrap configuration: nodes can connect to each other via 127.0.0.1
- Test isolation: use independent persistence paths for each instance

**Production environment**:
- Production applications use the default instance
- No need to call test instance management functions
- Use `TIMManager.instance` or `V2TIMManagerImpl::GetInstance()` directly

### Implementation details

**C++ layer**:
- `ToxManager`: Changed from singleton to instantiable class, supporting multiple Tox instances
- `V2TIMManagerImpl`: Changed from singleton to instantiable class, each instance has its own `ToxManager`
- Callback handling: Use the global `Tox* -> ToxManager*` mapping to handle callbacks that do not support `user_data`

**FFI layer**:
- Test instance mapping: `std::unordered_map<int64_t, V2TIMManagerImpl*>`
- Current instance tracking: `g_current_instance_id` (0 means use the default instance)
- All FFI functions get the correct instance via `GetCurrentInstance()`

**Dart layer**:
- `TestNode` class (`tim2tox/auto_tests/test/test_helper.dart`) uses test instance management
- Each `TestNode` creates a separate C++ instance when `initSDK`
- Set current instance before `login` and FFI calls

## Testing Guide

### C++ unit testing

Use Google Test framework for unit testing.

#### Run the test

```bash
cd build
make test
ctest
```

Or run the test executable directly:

```bash
./build/test/ToxUtilTest
```

#### Write tests

Create a test file in the `test/` directory:

```cpp
// test/NewFeatureTest.cpp
#include <gtest/gtest.h>
#include <V2TIMManager.h>

TEST(NewFeatureTest, BasicTest) {
    // test code
    EXPECT_EQ(1, 1);
}
```

Added in `test/CMakeLists.txt`:

```cmake
add_executable(NewFeatureTest NewFeatureTest.cpp)
target_link_libraries(NewFeatureTest tim2tox gtest gtest_main)
add_test(NAME NewFeatureTest COMMAND NewFeatureTest)
```

### Dart Test

Run in the `dart/` directory:

```bash
cd dart
flutter test
```

### Multiple instance testing

Tim2Tox supports multi-instance testing, allowing multiple independent Tox nodes to be run in the same process:

```bash
cd auto_tests
flutter test test/scenarios/scenario_multi_instance_test.dart
```

**Test scenario**:
- `scenario_multi_instance_test.dart`: Verify each node has an independent instance, port and DHT ID
- Verify that nodes can connect to each other through 127.0.0.1 bootstrap

**Test instance management**:
- Each `TestNode` creates an independent C++ instance on initialization
- Use `configureLocalBootstrap()` to configure local bootstrap to speed up node connection
- Automatically destroy all test instances after testing is completed

### Integration testing

Use the sample program in the `example/` directory for integration testing:

```bash
cd example/build
./echo_bot_client
./echo_bot_server
```

## Code specifications

### C++ code specifications

- Use 4 spaces for indentation
- Use PascalCase for class names
- Use camelCase for function names and variable names
- Constant use UPPER_SNAKE_CASE
- Use `#pragma once` or include guard for header files
- All public APIs must have documentation comments

### Dart code specification

- Follow the official Dart style guide
- Use 2 spaces for indentation
- Use PascalCase for class names
- Use camelCase for function names and variable names
- constant use lowerCamelCase
- All public APIs must have documentation comments

### Submission specifications

Submit message format:

```
<type>: <subject>

<body>

<footer>
```

Type:
- `feat`: New features
- `fix`: bug fix
- `docs`: Documentation update
- `style`: Code format adjustment
- `refactor`: Reconstruction
- `test`: Test related
- `chore`: Build/tool related

## Debugging Tips

### C++ Debugging

#### Using GDB

```bash
gdb ./build/example/echo_bot_client
(gdb) break V2TIMMessageManagerImpl::SendMessage
(gdb) run
```

#### Using LLDB (macOS)

```bash
lldb ./build/example/echo_bot_client
(lldb) breakpoint set --name V2TIMMessageManagerImpl::SendMessage
(lldb) run
```

#### Enable debug logs

Enabled during CMake configuration:

```bash
cmake .. -DDEBUG=ON -DTRACE=ON
```

### Dart Debugging

#### Flutter Debugging

```bash
cd dart
flutter run --debug
```

#### Log output

Use `LoggerService` in your code:

```dart
loggerService?.debug('Debug message');
loggerService?.info('Info message');
loggerService?.warning('Warning message');
loggerService?.error('Error message', error, stackTrace);
```

### FAQ

#### 1. Link error

**Problem**: Symbol not found

**Solution**:
- Check the library configuration in CMakeLists.txt
- Make sure all dependent libraries are linked correctly
- Check search paths for libraries

#### 2. Crash during runtime

**Issue**: App crashes after launching

**Common Causes and Solutions**:

1. **Dynamic library path problem**:
   - Check whether the dynamic library path is correct
   - Check dependencies using `otool -L` (macOS) or `ldd` (Linux)
   - Make sure all dependent libraries are in the correct location

2. **Memory management issues**:
   - Check for dangling pointers
   - Use smart pointers to manage object lifecycle
   - Avoid calling methods on destroyed objects

3. **V2TIM_LOG crashed in detached thread**:
   
   **Problem description**: Using `V2TIM_LOG` in a detached thread (such as a `RejoinKnownGroups` thread) may cause a crash with error type `EXC_BAD_ACCESS` or `Instruction Abort`.
   
   **Root Cause**:
   - Static local variable destruction order issue: `V2TIMLog` singleton may be destroyed while the detached thread is still running
   - Accessing member variables of a destroyed object: `mutex_` may be accessed during the destruction process
   
   **Solution**:
   - Avoid using `V2TIM_LOG` in detached thread
   - Use `fprintf(stderr, ...)` instead (thread safe)
   - Ensure detached thread completes before object is destroyed
   - Use `std::thread::join()` to wait for the thread to complete
   
   **Code Example**:
   ```cpp
   // Not recommended: use V2TIM_LOG in a detached thread
   std::thread([this]() {
       V2TIM_LOG(kInfo, "Thread running");  // May cause a crash
   }).detach();
   
   // Recommended: use fprintf or ensure the thread completes before object destruction
   std::thread([this]() {
       fprintf(stderr, "[INFO] Thread running\n");  // Thread-safe
   }).detach();
   
   // Or use join() to ensure the thread completes
   std::thread t([this]() {
       V2TIM_LOG(kInfo, "Thread running");
   });
   t.join();  // Wait for the thread to complete
   ```
   
   **Key code location**:
   - `tim2tox/source/V2TIMManagerImpl.cpp:RejoinKnownGroups()` - use detached thread
   - `tim2tox/source/V2TIMLog.cpp` - V2TIM_LOG implementation4. **Use the debugger to locate the crash**:
   - Use GDB or LLDB to view crash locations
   - Check stack trace
   - View memory status

#### 3. FFI call failed

**Issue**: Dart FFI call returns error

**Solution**:
- Check if function signature matches
- Check parameter type conversion
- Check string lifetime (using `toNativeUtf8()` and `malloc.free()`)

#### 4. Callback does not trigger

**Problem**: The registered callback is not called

**Solution**:
- Check whether the callback registration is correct
- Check if `SendCallbackToDart` is called
- Check whether `ReceivePort` of Dart layer is listening normally

## Performance optimization

### C++ Optimization

- Avoid unnecessary string copies (use quotes)
- Use move semantics (`std::move`)
- Reduce dynamic memory allocation
- Use object pool to reuse objects

### Dart optimization

- Avoid frequent FFI calls
- Use Stream instead of polling
- Cache frequently used data
- Use `Isolate` to handle time-consuming operations

## Related documents

- [API Reference](../api/API_REFERENCE.en.md) - Complete API documentation
- [Tim2Tox Architecture](../architecture/ARCHITECTURE.en.md) - Overall architecture design
- [Tim2Tox FFI Compatibility Layer](../architecture/FFI_COMPAT_LAYER.en.md) - Dart* compat layer description
