# Tim2Tox FFI 函数声明
> 语言 / Language: [中文](FFI_FUNCTION_DECLARATION_GUIDE.md) | [English](FFI_FUNCTION_DECLARATION_GUIDE.en.md)


## 问题背景

所有 `tim2tox_ffi_*` 函数都在 `tim2tox_ffi.cpp` 中定义在 `extern "C"` 块内。当在 C++ 文件中调用这些函数时，必须使用 `extern "C"` 声明，否则会导致 C++ 名称修饰（name mangling）问题，可能引发链接错误或运行时崩溃。

## 规则

### 1. 在文件顶部统一声明

**所有** `tim2tox_ffi_*` 函数必须在文件顶部的 `extern "C"` 块中声明。

**正确示例** (`V2TIMManagerImpl.cpp`):

```cpp
// Forward declaration for FFI functions
// NOTE: All tim2tox_ffi_* functions are defined in extern "C" blocks in tim2tox_ffi.cpp
// They MUST be declared here with extern "C" to avoid C++ name mangling issues.
// Tip: keep these in sync with ffi/tim2tox_ffi.h — note that many group / multi-instance
// helpers take `int64_t instance_id` as their first parameter.
extern "C" {
int tim2tox_ffi_save_friend_nickname(const char* friend_id, const char* nickname);
int tim2tox_ffi_save_friend_status_message(const char* friend_id, const char* status_message);
int tim2tox_ffi_irc_forward_tox_message(const char* group_id, const char* sender, const char* message);
int tim2tox_ffi_get_known_groups(int64_t instance_id, char* buffer, int buffer_len);
int tim2tox_ffi_set_group_chat_id(int64_t instance_id, const char* group_id, const char* chat_id);
int tim2tox_ffi_get_group_chat_id_from_storage(int64_t instance_id, const char* group_id, char* out_chat_id, int out_len);
int tim2tox_ffi_set_group_type(int64_t instance_id, const char* group_id, const char* group_type);
int tim2tox_ffi_get_group_type_from_storage(int64_t instance_id, const char* group_id, char* out_group_type, int out_len);
int tim2tox_ffi_get_auto_accept_group_invites(int64_t instance_id);
}
```

### 2. 禁止在函数内部重复声明

**错误示例**:

```cpp
void SomeFunction() {
    // ❌ 错误：不要在函数内部声明
    extern int tim2tox_ffi_set_group_chat_id(int64_t instance_id, const char* group_id, const char* chat_id);
    tim2tox_ffi_set_group_chat_id(instance_id, group_id, chat_id);
}
```

**正确示例**:

```cpp
void SomeFunction() {
    // ✅ 正确：直接使用，函数已在文件顶部声明
    // Function is already declared with extern "C" at file scope
    tim2tox_ffi_set_group_chat_id(instance_id, group_id, chat_id);
}
```

## 检查清单

在添加新的 `tim2tox_ffi_*` 函数调用时：

1. ✅ 检查函数是否已在文件顶部的 `extern "C"` 块中声明
2. ✅ 如果未声明，添加到文件顶部的 `extern "C"` 块中
3. ✅ 确保不在函数内部使用 `extern int tim2tox_ffi_...` 声明
4. ✅ 如果需要在函数内部添加注释，使用：`// Function is already declared with extern "C" at file scope`

## 如何验证

### 编译时检查

使用以下命令检查是否还有函数内部的 `extern` 声明：

```bash
grep -r "^\s*extern\s+int\s+tim2tox_ffi_" tim2tox/source/*.cpp
```

如果输出为空，说明没有问题。

### 运行时检查

如果遇到链接错误或运行时崩溃（特别是空指针访问），检查：

1. 函数是否在文件顶部正确声明为 `extern "C"`
2. 是否在函数内部错误地重复声明

## 常见错误

### 错误 1: 在函数内部使用 `extern int` 声明

```cpp
// ❌ 错误
void MyFunction() {
    extern int tim2tox_ffi_get_group_type_from_storage(...);
    // ...
}
```

**原因**: 函数内部的 `extern int` 声明不会使用 `extern "C"` 链接，导致 C++ 名称修饰。

**修复**: 移除函数内部的声明，确保在文件顶部声明。

### 错误 2: 忘记在文件顶部声明

```cpp
// ❌ 错误：文件顶部没有声明
void MyFunction() {
    tim2tox_ffi_get_group_type_from_storage(...);  // 链接错误
}
```

**修复**: 在文件顶部添加 `extern "C"` 声明。

## 相关文件

- `tim2tox/ffi/tim2tox_ffi.cpp`: 所有 FFI 函数的定义（都在 `extern "C"` 块内）
- `tim2tox/ffi/tim2tox_ffi.h`: FFI 函数的头文件声明
- `tim2tox/source/V2TIMManagerImpl.cpp`: 示例 - 正确的声明方式
- `tim2tox/source/V2TIMGroupManagerImpl.cpp`: 示例 - 正确的声明方式
