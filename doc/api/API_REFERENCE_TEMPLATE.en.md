# Tim2Tox API Reference Writing Template

> Language: [Chinese](API_REFERENCE_TEMPLATE.md) | [English](API_REFERENCE_TEMPLATE.en.md)

This document defines the writing rules for Tim2Tox API reference entries, used when maintaining [API_REFERENCE.en.md](API_REFERENCE.en.md) or module-split API docs. Each API entry must include the required fields and clearly distinguish **client-facing APIs** from **internal maintenance APIs**, and **stable interfaces** from **implementation details**.

---

## 1. Scope

This template applies to:

- **C FFI APIs** (functions declared in `tim2tox_ffi.h`, e.g. `tim2tox_ffi_*`)
- **Dart package public API** (e.g. public methods and properties of `FfiChatService`, `Tim2ToxSdkPlatform`, `Tim2ToxFfi`)
- **V2TIM C++ surface exposed to FFI** (behavior invoked by Dart* or tim2tox_ffi, used to describe “callee” semantics)

You do not need a separate entry for every internal Dart* symbol; but if a Dart* function is invoked by the client or SDK via NativeLibraryManager, it should be documented as a client API or stable interface as appropriate.

---

## 2. Per-API entry structure (required)

Each API entry must include the following; optional fields may be labeled “optional” or “if applicable”.

| Field | Description |
|-------|-------------|
| **Purpose** | One sentence: what the API does and typical use case. |
| **Parameters** | Name, type, meaning; nullable/optional; for buffer parameters state “caller allocates, implementation writes” or “implementation fills; caller provides buffer and length”. |
| **Return value** | Type and meaning of values (e.g. 0=fail / 1=success, bytes written, handle, negative error codes). |
| **When to call** | Preconditions (e.g. after init, after login); whether it can be called repeatedly or must be called in a given phase. |
| **Threading / async** | Blocking or not; which thread runs; which thread/isolate completes callbacks or Futures. |
| **Failure behavior** | Return codes or exceptions, meaning of error messages, typical failure paths (not inited, invalid handle, timeout, invalid args, etc.). |
| **Relation to other modules** | Callers (e.g. FfiChatService, NativeLibraryManager, app code); callees (e.g. V2TIMManagerImpl, ToxManager); for internal APIs state “called only by xx”. |
| **Example** | Minimal runnable snippet (pseudo or real code) to help integrators. |

---

## 3. Markdown entry example

Below is one example entry that follows the structure above (C FFI style).

```markdown
### tim2tox_ffi_send_c2c_text

**Classification**: [Client] [Stable]

- **Purpose**: Send a C2C text message to the given friend; typically called by FfiChatService.sendText, eventually sent by V2TIMMessageManagerImpl via ToxManager to c-toxcore.
- **Parameters**:
  - `user_id`: `const char*`, friend userID (usually 64-char hex public key), non-null.
  - `text`: `const char*`, UTF-8 text, non-null.
- **Return value**: `int`. 1 if send was submitted, 0 on failure (e.g. not logged in, friend not found, invalid args).
- **When to call**: Must be called after init and successful login; may be called repeatedly.
- **Threading / async**: No restriction on calling thread; actual send and delivery are asynchronous; outcome is reported via message status callbacks or poll events.
- **Failure behavior**: On 0 return no extra error code is provided; typical causes: current instance not logged in, user_id not a friend, null or invalid encoding.
- **Relation to other modules**: Caller: FfiChatService → Tim2ToxFfi; callee: V2TIMMessageManagerImpl → ToxManager → tox_friend_send_message.
- **Example**:
  ```c
  const char* uid = "0123..."; // 64-char hex
  const char* msg = "hello";
  int ok = tim2tox_ffi_send_c2c_text(uid, msg);
  if (!ok) { /* handle failure */ }
  ```
```

---

## 4. Classification and tags

At the start of each entry (title or first line), use the following tags for **audience** and **stability**.

### 4.1 Audience

| Tag | Meaning |
|-----|---------|
| **[Client]** | Client-facing API. Used directly or indirectly by the SDK or Flutter app (e.g. via TIMManager, Platform, FfiChatService public methods). |
| **[Internal]** | Internal maintenance API. Used only inside tim2tox (e.g. dart_compat_* implementations, FfiChatService private methods, Dart* symbols for NativeLibraryManager dynamic lookup; not recommended for app code to depend on). |

### 4.2 Stability

| Tag | Meaning |
|-----|---------|
| **[Stable]** | Stable interface. Committed to backward compatibility; signature and semantics are not changed without care; suitable for third-party integration and documentation. |
| **[Implementation]** | Implementation detail. May change or be removed during refactors; no cross-version stability guarantee. |

### 4.3 Combined examples

| Entry type | Suggested tags | Notes |
|------------|----------------|--------|
| tim2tox_ffi_init, login, send, etc. | [Client] [Stable] | Public C API used by client or FfiChatService. |
| FfiChatService.init, login, getHistory | [Client] [Stable] | Public Dart service API. |
| Dart* functions (e.g. DartInitSDK) | [Internal] [Stable] or [Implementation] | Invoked by SDK via dynamic lookup; signatures match native bindings. Use Stable if aligned with native SDK, else Implementation. |
| FfiChatService internal methods (e.g. _loadAndApplySavedBootstrapNode) | [Internal] [Implementation] | Framework-internal only; may be renamed or removed. |

---

## 5. Per-layer examples (optional reference)

When writing entries by layer, maintainers can use the table below as a checklist; each entry should still include all eight fields from §2.

| Layer | Example API | One-line purpose |
|-------|-------------|-------------------|
| C FFI | `tim2tox_ffi_init_with_path` | Initialize SDK with a given directory; used for multi-account or test instances. |
| C FFI | `tim2tox_ffi_poll_text` | Pull the next text/event line from the given instance’s event queue. |
| Dart | `FfiChatService.startPolling()` | Start the poll timer; drain C++ event queue and update connection/message/file state. |
| Dart | `Tim2ToxSdkPlatform.getHistoryMessageList` | Platform implementation: load history for a conversation by delegating to FfiChatService.getHistory and MessageHistoryPersistence. |

Expand each into a full entry (purpose, parameters, return value, when to call, threading/async, failure, relation to other modules, example) and add [Client]/[Internal] and [Stable]/[Implementation] tags.

---

## 6. Relation to existing API_REFERENCE

- [API_REFERENCE.en.md](API_REFERENCE.en.md) is the current API list and descriptions. New or revised entries should follow **this template** in structure and tags.
- If API docs are split by module (e.g. separate files for C FFI, Dart Service, Dart Platform), each file should still use the same entry structure and classification tags, and the index should point to “Writing rules: see API_REFERENCE_TEMPLATE”.
