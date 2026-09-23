#include "callback_bridge.h"
#include "V2TIMLog.h"
#include <cstring>
#include <cstdint>
#include <csignal>
#ifndef _WIN32
#include <signal.h>
#include <unistd.h>
#endif
#include <cstdlib>
#include <algorithm>
#include <unordered_map>
#include <utility>
#include <vector>

#ifdef _WIN32
extern "C" int _write(int, const void*, unsigned int);
#endif

namespace {
constexpr char kFatalSignalMarker[] = "[callback_bridge] FATAL: native signal\n";

static void WriteFatalSignalMarker() {
#ifdef _WIN32
    (void)_write(2, kFatalSignalMarker,
                 static_cast<unsigned int>(sizeof(kFatalSignalMarker) - 1));
#endif
#ifndef _WIN32
    (void)write(STDERR_FILENO, kFatalSignalMarker,
                sizeof(kFatalSignalMarker) - 1);
#endif
}
}

// Store Dart_Port for sending callbacks
static Dart_Port g_dart_port = ILLEGAL_PORT;
static std::mutex g_dart_port_mutex;
static bool g_dart_api_initialized = false;

// Durable notifications waiting for a port (see SendDurableCallbackToDart).
// Guarded by g_dart_port_mutex. Keyed by the caller's dedupe key so only the
// latest value per key survives; `seq` keeps the replay in arrival order.
struct PendingDurableCallback {
    uint64_t seq;
    std::string json;
    int64_t owner_instance_id;  // see DiscardDurableCallbacksForInstance
};
static std::unordered_map<std::string, PendingDurableCallback> g_pending_durable;
static uint64_t g_pending_durable_seq = 0;
// Keys are per group, so this is only reached by a pathological group count.
static constexpr size_t kMaxPendingDurable = 4096;

static bool PostJsonToDartLocked(const std::string& message);
static void ReplayPendingDurableLocked();

static void HandleFatalSignal(int sig) {
    WriteFatalSignalMarker();
#ifdef _WIN32
    std::_Exit(128 + sig);
#endif
#ifndef _WIN32
    struct sigaction default_action {};
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);
    default_action.sa_flags = 0;
    (void)sigaction(sig, &default_action, nullptr);

    sigset_t unblocked_signal;
    sigemptyset(&unblocked_signal);
    sigaddset(&unblocked_signal, sig);
    (void)sigprocmask(SIG_UNBLOCK, &unblocked_signal, nullptr);

    (void)kill(getpid(), sig);
    _exit(128 + sig);
#endif
}

static void InstallCrashHandlersOnce() {
    static bool installed = false;
    if (installed) return;
    installed = true;
    signal(SIGSEGV, HandleFatalSignal);
    signal(SIGABRT, HandleFatalSignal);
#ifdef SIGBUS
    signal(SIGBUS, HandleFatalSignal);
#endif
}

extern "C" {
    // Initialize Dart API
    // Function signature must match native_imsdk_bindings_generated.dart:
    // IntPtr DartInitDartApiDL(Pointer<Void> data)
    // ABI note: the binding declares an IntPtr (pointer-width) return, and the
    // underlying Dart_InitializeApiDL also returns intptr_t. Declaring `int`
    // here truncated it to 32 bits. Callers only test zero/non-zero so nothing
    // has broken yet, but the width must match the binding.
    intptr_t DartInitDartApiDL(void* data) {
        if (!data) {
            return 1;
        }

        InstallCrashHandlersOnce();

        // Dart_InitializeApiDL returns intptr_t: 0 = success, non-zero = failure
        // (missing symbols or ABI mismatch). Without a successful init,
        // Dart_PostCObject_DL must not be called, so propagate the failure
        // instead of silently flipping g_dart_api_initialized.
        intptr_t init_rc = Dart_InitializeApiDL(data);
        if (init_rc != 0) {
            return 1;
        }
        std::lock_guard<std::mutex> lock(g_dart_port_mutex);
        g_dart_api_initialized = true;
        ReplayPendingDurableLocked();
        return 0;
    }

    // Register Dart SendPort for receiving callbacks
    // Function signature must match native_imsdk_bindings_generated.dart:
    // void DartRegisterSendPort(int64_t send_port)
    // Note: Dart_Port is int64_t (64-bit), not int (32-bit)
    void DartRegisterSendPort(int64_t send_port) {
        std::lock_guard<std::mutex> lock(g_dart_port_mutex);
        g_dart_port = static_cast<Dart_Port>(send_port);
        ReplayPendingDurableLocked();
    }

    // Symmetric counterpart to DartRegisterSendPort. The Tencent SDK started
    // calling this in 8.9.7540+3 from NativeLibraryManager.unregisterPort().
    // No toxee code path invokes it today, but the symbol must exist so the
    // FFI lookup doesn't crash if it ever fires.
    void DartUnregisterSendPort(int64_t send_port) {
        std::lock_guard<std::mutex> lock(g_dart_port_mutex);
        if (g_dart_port == static_cast<Dart_Port>(send_port)) {
            g_dart_port = ILLEGAL_PORT;
        }
    }
}

// Check if Dart port is registered
bool IsDartPortRegistered() {
    std::lock_guard<std::mutex> lock(g_dart_port_mutex);
    return g_dart_port != ILLEGAL_PORT;
}

// Send callback message to Dart layer
// The message format must match what NativeLibraryManager._handleNativeMessage expects:
// - JSON string with "callback" field ("globalCallback" or "apiCallback")
// - For globalCallback: contains "callbackType" and other JSON data fields
// - For apiCallback: contains "user_data" and result data
void SendCallbackToDart(const char* callback_type, const std::string& json_data, void* user_data) {
    if (!callback_type) {
        return;
    }

    std::lock_guard<std::mutex> lock(g_dart_port_mutex);
    if (!g_dart_api_initialized || g_dart_port == ILLEGAL_PORT || !callback_type) {
        return;
    }
    (void)PostJsonToDartLocked(json_data);
}

// Caller holds g_dart_port_mutex and has checked the API/port are ready.
static bool PostJsonToDartLocked(const std::string& message) {
    Dart_CObject cobj;
    cobj.type = Dart_CObject_kString;

    size_t message_len = message.length();

    if (message_len > 1024 * 1024) {
        V2TIM_LOG(kError, "[callback_bridge] SendCallbackToDart: ERROR - message_len too large: {}", message_len);
        return false;
    }

    char* message_cstr = static_cast<char*>(malloc(message_len + 1));
    if (!message_cstr) {
        V2TIM_LOG(kError, "[callback_bridge] SendCallbackToDart: ERROR - malloc failed for message_len={}", message_len);
        return false;
    }

    std::memcpy(message_cstr, message.data(), message_len);
    message_cstr[message_len] = '\0';

    cobj.value.as_string = message_cstr;
    // Dart_PostCObject_DL copies the CObject graph (including the kString
    // payload) into the receiving isolate's heap before returning, so the
    // caller retains ownership of message_cstr regardless of post success.
    const bool posted = Dart_PostCObject_DL(g_dart_port, &cobj);
    free(message_cstr);
    return posted;
}

// Post now, or — while no SendPort is registered / the Dart API is not
// initialized — hold the message (latest per dedupe_key, bounded) and post it
// from DartRegisterSendPort / DartInitDartApiDL. For notifications whose loss
// loses client-persisted state (group identity / kind), which native learns
// during login-time restore and rejoin, before the client has a port.
// The client must still pull the full state once its handler is installed
// (tim2tox_ffi_get_group_identity_snapshot): a registered port does not mean
// the Dart side has a handler for these callbacks yet.
// The held JSON is the caller's, so a replay carries whatever instance /
// session stamp the caller wrote into it; the session's owner drops what is
// still held when the session ends (DiscardDurableCallbacksForInstance).
void SendDurableCallbackToDart(const char* callback_type, const std::string& json_data,
                               const std::string& dedupe_key, int64_t owner_instance_id) {
    if (!callback_type) return;
    std::lock_guard<std::mutex> lock(g_dart_port_mutex);
    if (g_dart_api_initialized && g_dart_port != ILLEGAL_PORT &&
        PostJsonToDartLocked(json_data)) {
        g_pending_durable.erase(dedupe_key);  // superseded by what was just sent
        return;
    }
    auto it = g_pending_durable.find(dedupe_key);
    if (it != g_pending_durable.end()) {
        it->second = PendingDurableCallback{++g_pending_durable_seq, json_data, owner_instance_id};
        return;
    }
    if (g_pending_durable.size() >= kMaxPendingDurable) {
        auto oldest = g_pending_durable.begin();
        for (auto cur = g_pending_durable.begin(); cur != g_pending_durable.end(); ++cur) {
            if (cur->second.seq < oldest->second.seq) oldest = cur;
        }
        V2TIM_LOG(kWarning,
                  "[callback_bridge] durable callback buffer full ({}); dropping the oldest ({}); "
                  "the client's identity snapshot pull still recovers it",
                  kMaxPendingDurable, oldest->first);
        g_pending_durable.erase(oldest);
    }
    g_pending_durable.emplace(dedupe_key,
                              PendingDurableCallback{++g_pending_durable_seq, json_data,
                                                     owner_instance_id});
}

void DiscardDurableCallbacksForInstance(int64_t owner_instance_id) {
    std::lock_guard<std::mutex> lock(g_dart_port_mutex);
    size_t dropped = 0;
    for (auto it = g_pending_durable.begin(); it != g_pending_durable.end();) {
        if (it->second.owner_instance_id == owner_instance_id) {
            it = g_pending_durable.erase(it);
            ++dropped;
        } else {
            ++it;
        }
    }
    if (dropped > 0) {
        V2TIM_LOG(kInfo,
                  "[callback_bridge] discarded {} held durable callback(s) of ended session (instance_id={})",
                  dropped, (long long)owner_instance_id);
    }
}

// Caller holds g_dart_port_mutex.
static void ReplayPendingDurableLocked() {
    if (!g_dart_api_initialized || g_dart_port == ILLEGAL_PORT || g_pending_durable.empty()) {
        return;
    }
    std::vector<std::pair<uint64_t, std::string>> ordered;
    ordered.reserve(g_pending_durable.size());
    for (auto& entry : g_pending_durable) {
        ordered.emplace_back(entry.second.seq, entry.first);
    }
    std::sort(ordered.begin(), ordered.end());
    size_t posted = 0;
    for (const auto& [seq, key] : ordered) {
        auto it = g_pending_durable.find(key);
        if (it == g_pending_durable.end()) continue;
        if (!PostJsonToDartLocked(it->second.json)) break;  // port gone: keep the rest
        g_pending_durable.erase(it);
        ++posted;
    }
    V2TIM_LOG(kInfo, "[callback_bridge] replayed {} durable callback(s) held before the port was ready; {} left",
              posted, g_pending_durable.size());
}
