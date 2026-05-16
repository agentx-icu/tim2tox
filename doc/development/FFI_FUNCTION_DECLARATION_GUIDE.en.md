# Tim2Tox FFI Function Declaration Guide
> Language: [Chinese](FFI_FUNCTION_DECLARATION_GUIDE.md) | [English](FFI_FUNCTION_DECLARATION_GUIDE.en.md)


## Problem background

All `tim2tox_ffi_*` functions are defined in `tim2tox_ffi.cpp` within the `extern "C"` block. When calling these functions in a C++ file, you must use the `extern "C"` declaration, otherwise it will cause C++ name mangling problems, which may cause linking errors or runtime crashes.

## Rules

### 1. Declare uniformly at the top of the file

**All** `tim2tox_ffi_*` functions must be declared in a `extern "C"` block at the top of the file.

**Correct example** (`V2TIMManagerImpl.cpp`):

```cpp
// Forward declaration for FFI functions
// NOTE: All tim2tox_ffi_* functions are defined in extern "C" blocks in tim2tox_ffi.cpp
// They MUST be declared here with extern "C" to avoid C++ name mangling issues.
// Tip: keep these in sync with ffi/tim2tox_ffi.h — many group / multi-instance helpers
// take `int64_t instance_id` as their first parameter.
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

### 2. Repeated declarations inside functions are prohibited

**Error Example**:

```cpp
void SomeFunction() {
    // ❌ Error: Don’t declare inside a function
    extern int tim2tox_ffi_set_group_chat_id(int64_t instance_id, const char* group_id, const char* chat_id);
    tim2tox_ffi_set_group_chat_id(instance_id, group_id, chat_id);
}
```

**Correct example**:

```cpp
void SomeFunction() {
    // ✅ Correct: Use it directly, the function has been declared at the top of the file
    // Function is already declared with extern "C" at file scope
    tim2tox_ffi_set_group_chat_id(instance_id, group_id, chat_id);
}
```

## Checklist

When adding a new `tim2tox_ffi_*` function call:

1. ✅ Check if the function has been declared in the `extern "C"` block at the top of the file
2. ✅ If not declared, add to the `extern "C"` block at the top of the file
3. ✅ Make sure not to use the `extern int tim2tox_ffi_...` statement inside a function
4. ✅ If you need to add comments inside the function, use: `// Function is already declared with extern "C" at file scope`

## How to verify

### Compile time check

Use the following command to check if there are also `extern` declarations inside the function:

```bash
grep -r "^\s*extern\s+int\s+tim2tox_ffi_" tim2tox/source/*.cpp
```

If the output is empty, there is no problem.

### Runtime check

If you encounter link errors or runtime crashes (especially null pointer access), check:

1. Is the function correctly declared as `extern "C"` at the top of the file?
2. Whether the declaration is repeated incorrectly inside the function

## Common mistakes

### Error 1: Using `extern int` declaration inside a function

```cpp
// ❌ Error
void MyFunction() {
    extern int tim2tox_ffi_get_group_type_from_storage(...);
    // ...
}
```

**Cause**: A `extern int` declaration inside a function will not be linked using `extern "C"`, resulting in C++ name mangling.

**Fix**: Remove declarations inside functions and make sure they are declared at the top of the file.

### Mistake 2: Forgot to declare it at the top of the file

```cpp
// ❌ Error: No declaration at top of file
void MyFunction() {
    tim2tox_ffi_get_group_type_from_storage(...);  // Link error
}
```

**FIX**: Add `extern "C"` declaration at top of file.

## Related documents

- `tim2tox/ffi/tim2tox_ffi.cpp`: definition of all FFI functions (all within `extern "C"` block)
- `tim2tox/ffi/tim2tox_ffi.h`: Header file declaration of FFI function
- `tim2tox/source/V2TIMManagerImpl.cpp`: Example - Correct way to declare
- `tim2tox/source/V2TIMGroupManagerImpl.cpp`: Example - Correct way to declare