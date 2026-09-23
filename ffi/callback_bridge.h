// Callback bridge for Dart ReceivePort communication
#pragma once

#if defined(_WIN32) || defined(_WIN64)
  // MSVC: the Dart SDK headers may not be present in some CI environments.
  // Keep this header compilable by falling back to minimal stubs.
#endif

#if defined(__has_include)
#  if __has_include(<dart_api_dl.h>)
#    include <dart_api_dl.h>
#    define TIM2TOX_HAS_DART_API_DL 1
#  else
#    define TIM2TOX_HAS_DART_API_DL 0
#  endif
#else
#  define TIM2TOX_HAS_DART_API_DL 0
#endif

#if !TIM2TOX_HAS_DART_API_DL
// Minimal Dart API DL stubs for builds where <dart_api_dl.h> isn't available.
// These are sufficient for compilation; runtime Dart messaging won't work.
#include <cstdint>
using Dart_Port = int64_t;
static constexpr Dart_Port ILLEGAL_PORT = -1;

enum Dart_CObject_Type { Dart_CObject_kString = 0 };

struct Dart_CObject {
    Dart_CObject_Type type;
    union {
        const char* as_string;
    } value;
};

// Real Dart_InitializeApiDL returns intptr_t (0 = success, non-zero = failure).
// The stub returns -1 to report "not implemented" without the misleading bool.
static inline intptr_t Dart_InitializeApiDL(void* /*data*/) { return -1; }
static inline bool Dart_PostCObject_DL(Dart_Port /*port*/, Dart_CObject* /*obj*/) { return false; }
#endif

#include <cstdint>
#include <string>
#include <mutex>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize Dart API
// Returns 0 on success, non-zero on failure.
// intptr_t (not int) to match the binding's `ffi.IntPtr` return and the
// underlying Dart_InitializeApiDL.
intptr_t DartInitDartApiDL(void* data);

// Register Dart SendPort for receiving callbacks
// Note: Dart_Port is int64_t (64-bit), not int (32-bit)
void DartRegisterSendPort(int64_t send_port);
// Symmetric unregister; added in 8.9.7540+3 to match SDK call site.
void DartUnregisterSendPort(int64_t send_port);

#ifdef __cplusplus
}
#endif

// Send callback message to Dart layer
// callback_type: "globalCallback" or "apiCallback"
// json_data: JSON string containing callback data
// user_data: user data pointer (can be nullptr)
void SendCallbackToDart(const char* callback_type, const std::string& json_data, void* user_data);

// Like SendCallbackToDart, but a message that cannot be posted yet (no port /
// Dart API) is held — latest per dedupe_key, bounded — and posted when the
// port is registered, instead of being dropped. See callback_bridge.cpp.
// owner_instance_id is the emitting instance: its held messages are dropped
// by DiscardDurableCallbacksForInstance when that session ends.
void SendDurableCallbackToDart(const char* callback_type, const std::string& json_data,
                               const std::string& dedupe_key, int64_t owner_instance_id);

// Drop every held durable message of owner_instance_id (its session ended:
// replaying them into the next session of the same instance id — an account
// switch reuses instance 0 — would apply the old account's state).
void DiscardDurableCallbacksForInstance(int64_t owner_instance_id);

// Check if Dart port is registered
bool IsDartPortRegistered();

