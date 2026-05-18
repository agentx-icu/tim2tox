#include "tim2tox_ffi.h"
#include <V2TIMManager.h>
#include <V2TIMGroupManager.h>
#include <V2TIMListener.h>
#include <V2TIMMessage.h>
#include <V2TIMCallback.h>
#include <V2TIMFriendshipManager.h>
#include <V2TIMMessageManager.h>
#include <mutex>
#include <queue>
#include <string>
#include <vector>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include "ToxManager.h"
#include "ToxUtil.h"
#include "V2TIMManagerImpl.h"
#include "V2TIMMessageManagerImpl.h"
#include "V2TIMLog.h"
#include "irc_client_api.h"
#include "V2TIMSignalingManager.h"
#include "V2TIMSignalingManagerImpl.h"  // For CheckTimeouts() in iterate hook
#ifdef BUILD_TOXAV
#include "ToxAVManager.h"
#endif
#ifdef _WIN32
// Windows: provide a tiny dlfcn-like shim using LoadLibrary/GetProcAddress.
// Prevent windows.h from including winsock.h (which conflicts with winsock2.h).
#ifndef _WINSOCKAPI_
#define _WINSOCKAPI_
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#ifndef RTLD_LAZY
#define RTLD_LAZY 0
#endif
static void* tim2tox_dlopen(const char* filename, int /*flags*/) {
    if (!filename) return nullptr;
    return reinterpret_cast<void*>(LoadLibraryA(filename));
}
static void* tim2tox_dlsym(void* handle, const char* symbol) {
    if (!handle || !symbol) return nullptr;
    return reinterpret_cast<void*>(GetProcAddress(reinterpret_cast<HMODULE>(handle), symbol));
}
static void tim2tox_dlclose(void* handle) {
    if (!handle) return;
    FreeLibrary(reinterpret_cast<HMODULE>(handle));
}
static const char* tim2tox_dlerror() {
    // Best-effort: keep build-time compilation simple.
    return "dlfcn stub: LoadLibrary/GetProcAddress failed";
}
#define dlopen tim2tox_dlopen
#define dlsym tim2tox_dlsym
#define dlclose tim2tox_dlclose
#define dlerror tim2tox_dlerror
#else
#include <dlfcn.h>
#endif
#include <V2TIMManager.h>
#include <unordered_map>
#include <unordered_set>
#include <map>
#include <cstdio>
#include <cstdlib>
#include <sys/stat.h>
#ifndef _WIN32
#include <unistd.h>
#endif
#include <errno.h>
#include <cstring>
#include <cctype>
#include <sstream>
#include <iomanip>
#include "../third_party/c-toxcore/toxencryptsave/toxencryptsave.h"
#include "../third_party/c-toxcore/toxcore/tox.h"
#include "../third_party/c-toxcore/toxcore/tox_private.h"
#include "../third_party/c-toxcore/toxcore/tox_dispatch.h"
#include "../third_party/c-toxcore/toxcore/DHT.h"
#include "json_parser.h"
#include "callback_bridge.h"
#ifndef _WIN32
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#else
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

// mkdir wrapper: MSVC on Windows uses _mkdir and doesn't take mode.
#ifdef _WIN32
#include <direct.h>
static inline int tim2tox_mkdir(const char* path, int /*mode*/) {
    return _mkdir(path);
}
#else
static inline int tim2tox_mkdir(const char* path, int mode) {
    return mkdir(path, mode);
}
#endif

// Forward declarations (defined later in this file)
V2TIMManagerImpl* GetCurrentInstance();
int64_t GetCurrentInstanceId();
int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
int64_t GetReceiverInstanceOverride(void);
void SetReceiverInstanceOverride(int64_t id);
void ClearReceiverInstanceOverride(void);

// Test instance management (for multi-instance testing) - moved outside namespace for GetCurrentInstance access
static std::mutex g_test_instances_mutex;
static std::unordered_map<int64_t, V2TIMManagerImpl*> g_test_instances;
static std::unordered_map<V2TIMManagerImpl*, int64_t> g_instance_to_id; // Reverse map: V2TIMManagerImpl* -> instance_id
static int64_t g_next_instance_id = 1;
static int64_t g_current_instance_id = 0; // 0 means use default instance
// Sentinel for "manager not in map" (instance being torn down). Callers must not route to instance 0.
static constexpr int64_t kInstanceIdDestroyed = -1;

// Test instance options (for passing Tox_Options to InitSDK)
// Made non-static so V2TIMManagerImpl can access it
struct TestInstanceOptions {
    int local_discovery_enabled;
    int ipv6_enabled;
};

// Global test instance options (accessible from V2TIMManagerImpl)
std::mutex g_test_instance_options_mutex;
std::unordered_map<int64_t, TestInstanceOptions> g_test_instance_options;

// Global known groups list (synchronized from Dart layer) - moved outside namespace for FFI access
// This is a simple, direct approach: Dart layer updates this list when knownGroups changes,
// and C++ layer reads from it directly without complex recursion protection
// Changed to per-instance storage for multi-instance support
static std::mutex g_known_groups_mutex;
static std::map<int64_t, std::vector<std::string>> g_known_groups_list; // instance_id -> List of group IDs

// Global chat_id storage (groupID -> chat_id mapping) - moved outside namespace for FFI access
// This is used to rebuild the group_id_to_group_number_ mapping after restart
// Changed to per-instance storage for multi-instance support
static std::mutex g_chat_id_storage_mutex;
static std::map<int64_t, std::unordered_map<std::string, std::string>> g_group_id_to_chat_id; // instance_id -> (groupID -> 64-char hex chat_id)

// Global group type storage (groupID -> groupType mapping) - moved outside namespace for FFI access
// This is used to distinguish between "group" (new API) and "conference" (old API) after restart
// Changed to per-instance storage for multi-instance support
static std::mutex g_group_type_storage_mutex;
static std::map<int64_t, std::unordered_map<std::string, std::string>> g_group_id_to_group_type; // instance_id -> (groupID -> "group" or "conference")

// Global auto-accept group invites setting - moved outside namespace for FFI access
// This setting controls whether group invitations are automatically accepted
// Changed to per-instance storage for multi-instance support
static std::mutex g_auto_accept_group_invites_mutex;
static std::map<int64_t, bool> g_auto_accept_group_invites; // instance_id -> bool (default false)

namespace {
std::atomic<tim2tox_event_cb> g_cb{nullptr};
std::atomic<void*> g_cb_user{nullptr};

// IRC dynamic library handle
void* g_irc_lib_handle = nullptr;
bool g_irc_lib_loaded = false;
std::mutex g_irc_lib_mutex;

// Forward declare callback types (matching irc_client_api.h)
typedef void (*irc_message_callback_t)(const char* group_id, const char* sender_nick, const char* message, void* user_data);
typedef void (*tox_group_message_callback_t)(const char* group_id, const char* sender, const char* message, void* user_data);

// Connection status enumeration
typedef enum {
    IRC_CONNECTION_DISCONNECTED = 0,
    IRC_CONNECTION_CONNECTING = 1,
    IRC_CONNECTION_CONNECTED = 2,
    IRC_CONNECTION_AUTHENTICATING = 3,
    IRC_CONNECTION_RECONNECTING = 4,
    IRC_CONNECTION_ERROR = 5
} irc_connection_status_t;

// New callback types
typedef void (*irc_connection_status_callback_t)(const char* channel, irc_connection_status_t status, const char* message, void* user_data);
typedef void (*irc_user_list_callback_t)(const char* channel, const char* users, void* user_data);
typedef void (*irc_user_join_part_callback_t)(const char* channel, const char* nickname, int joined, void* user_data);

// IRC API function pointers
typedef int (*irc_init_t)(void);
typedef void (*irc_shutdown_t)(void);
typedef int (*irc_connect_channel_t)(const char*, int, const char*, const char*, const char*, const char*, const char*, int, const char*);
typedef int (*irc_disconnect_channel_t)(const char*);
typedef int (*irc_send_message_t)(const char*, const char*);
typedef int (*irc_is_connected_t)(const char*);
typedef void (*irc_set_message_callback_t)(irc_message_callback_t, void*);
typedef void (*irc_set_tox_message_callback_t)(tox_group_message_callback_t, void*);
typedef int (*irc_forward_tox_message_t)(const char*, const char*, const char*);
typedef void (*irc_set_connection_status_callback_t)(irc_connection_status_callback_t, void*);
typedef void (*irc_set_user_list_callback_t)(irc_user_list_callback_t, void*);
typedef void (*irc_set_user_join_part_callback_t)(irc_user_join_part_callback_t, void*);

irc_init_t g_irc_init = nullptr;
irc_shutdown_t g_irc_shutdown = nullptr;
irc_connect_channel_t g_irc_connect_channel = nullptr;
irc_disconnect_channel_t g_irc_disconnect_channel = nullptr;
irc_send_message_t g_irc_send_message = nullptr;
irc_is_connected_t g_irc_is_connected = nullptr;
irc_set_message_callback_t g_irc_set_message_callback = nullptr;
irc_set_tox_message_callback_t g_irc_set_tox_message_callback = nullptr;
irc_forward_tox_message_t g_irc_forward_tox_message = nullptr;
irc_set_connection_status_callback_t g_irc_set_connection_status_callback = nullptr;
irc_set_user_list_callback_t g_irc_set_user_list_callback = nullptr;
irc_set_user_join_part_callback_t g_irc_set_user_join_part_callback = nullptr;

} // namespace

// Forward declarations
struct GlobalState;

// Helper function to enqueue connection status events
// This will be defined after GlobalState is complete
void enqueue_conn_event(const char* event);

// SDKListenerImpl and SimpleMsgListenerImpl moved outside namespace so they can be used by GlobalState
class SDKListenerImpl : public V2TIMSDKListener {
public:
    void OnConnectSuccess() override {
        // Route via polling queue to avoid FFI callback from background thread
        // Flutter will poll and handle this event in its isolate
        // DO NOT call FFI callback directly from background thread - it will crash
        enqueue_conn_event("conn:success");
    }
    void OnConnectFailed(int code, const V2TIMString& msg) override {
        // Route via polling queue to avoid FFI callback from background thread
        // DO NOT call FFI callback directly from background thread - it will crash
        enqueue_conn_event("conn:failed");
    }
    void OnUserStatusChanged(const V2TIMUserStatusVector&) override {}
};

// Parse instance_id from event line for instance-routed events; 0 = broadcast to all.
static int64_t parse_instance_id_from_line(const std::string& s) {
    if (s.size() < 14) return 0;
    if (s.compare(0, 13, "progress_recv:") == 0) {
        const char* p = s.c_str() + 13;
        char* end = nullptr;
        long long id = strtoll(p, &end, 10);
        if (end != p && *end == ':') return static_cast<int64_t>(id);
    } else if (s.compare(0, 9, "file_done:") == 0) {
        const char* p = s.c_str() + 9;
        char* end = nullptr;
        long long id = strtoll(p, &end, 10);
        if (end != p && *end == ':') return static_cast<int64_t>(id);
    } else if (s.compare(0, 12, "file_request:") == 0) {
        const char* p = s.c_str() + 12;
        char* end = nullptr;
        long long id = strtoll(p, &end, 10);
        if (end != p && *end == ':') return static_cast<int64_t>(id);
    }
    return 0;
}

class SimpleMsgListenerImpl : public V2TIMSimpleMsgListener {
public:
    void enqueue_text_line(const std::string& s) {
        int64_t instance_id = parse_instance_id_from_line(s);
        if (instance_id == 0) {
            instance_id = GetReceiverInstanceOverride();
        }
        std::lock_guard<std::mutex> lock(m_);
        text_q_.emplace(instance_id, s);
    }
    void OnRecvC2CTextMessage(const V2TIMString&, const V2TIMUserFullInfo& sender, const V2TIMString& text) override {
        // Always route via polling queue: "c2c:<sender>:<text>"
        std::string line = std::string("c2c:") + sender.userID.CString() + ":" + text.CString();
        enqueue_text_line(line);
    }
    void OnRecvC2CCustomMessage(const V2TIMString&, const V2TIMUserFullInfo& sender, const V2TIMBuffer& customData) override {
        // For simplicity, notify as text line with size only (extend as needed)
        char size_buf[32]; snprintf(size_buf, sizeof(size_buf), "%d", (int)customData.Size());
        std::string line = std::string("c2cbin:") + sender.userID.CString() + ":" + size_buf;
        enqueue_text_line(line);
    }
    void OnRecvGroupTextMessage(const V2TIMString& msgID, const V2TIMString& groupID, const V2TIMGroupMemberFullInfo& sender, const V2TIMString& text) override {
        // Polling line: "gtext:<groupID>|<sender>:<text>"
        std::string header = std::string("gtext:") + groupID.CString() + "|" + sender.userID.CString() + ":";
        std::string line = header + text.CString();
        enqueue_text_line(line);
    }
    void OnRecvGroupCustomMessage(const V2TIMString& msgID, const V2TIMString& groupID, const V2TIMGroupMemberFullInfo& sender, const V2TIMBuffer& customData) override {
        // Enqueue custom data to custom queue for binary data
        {
            std::lock_guard<std::mutex> lock(m_);
            std::vector<unsigned char> data(customData.Data(), customData.Data() + customData.Size());
            custom_q_.push(data);
        }
        // Also notify via text queue with sender info for Flutter to know who sent it
        char size_buf[32]; snprintf(size_buf, sizeof(size_buf), "%d", (int)customData.Size());
        std::string line = std::string("gcustom:") + groupID.CString() + "|" + sender.userID.CString() + ":" + size_buf;
        enqueue_text_line(line);
    }
    // instance_id: only return events for this instance (or broadcast events with id 0).
    int poll_text(int64_t instance_id, char* buf, int len) {
        std::lock_guard<std::mutex> lock(m_);
        if (text_q_.empty()) {
            return 0;
        }
        const size_t qsize = text_q_.size();
        for (size_t i = 0; i < qsize; ++i) {
            auto p = std::move(text_q_.front());
            text_q_.pop();
            if (p.first == 0 || p.first == instance_id) {
                const std::string& s = p.second;
                int n = (int)std::min(s.size(), (size_t)(len - 1));
                if (n > 0) memcpy(buf, s.data(), n);
                buf[n] = 0;
                return n;
            }
            text_q_.push(std::move(p));
        }
        return 0;
    }
    int poll_custom(unsigned char* buf, int len) {
        std::lock_guard<std::mutex> lock(m_);
        if (custom_q_.empty()) return 0;
        auto v = std::move(custom_q_.front());
        custom_q_.pop();
        int n = (int)std::min(v.size(), (size_t)len);
        if (n > 0) memcpy(buf, v.data(), n);
        return n;
    }
private:
    std::mutex m_;
    std::queue<std::pair<int64_t, std::string>> text_q_;
    std::queue<std::vector<unsigned char>> custom_q_;
};

// GlobalState - moved outside namespace so it can be accessed from FFI functions
// R-08: inited state is per-instance (g_inited_instance_ids), not stored here
struct GlobalState {
    SDKListenerImpl sdk_listener;
    SimpleMsgListenerImpl simple_listener;
    std::string file_recv_dir = "/tmp/tim2tox_recv"; // Default directory, can be changed via tim2tox_ffi_set_file_recv_dir
    // file sending contexts: instance_id -> (key (friend_no<<32 | file_no) -> FILE* and size)
    std::mutex send_mtx;
    std::map<int64_t, std::unordered_map<uint64_t, std::pair<FILE*, uint64_t>>> send_files; // instance_id -> file map
    struct RecvCtx { FILE* fp; uint64_t size; uint64_t received; std::string path; std::string sender_hex; uint32_t kind; };
    // file receiving contexts: instance_id -> (key (friend_no<<32 | file_no) -> RecvCtx)
    std::map<int64_t, std::unordered_map<uint64_t, RecvCtx>> recv_files; // instance_id -> file map
} G;

// R-08: Per-instance inited state (replaces global G.inited for instance-aware checks)
static std::mutex g_inited_mutex;
static std::unordered_set<int64_t> g_inited_instance_ids;

static void MarkInstanceInited(int64_t id) {
    std::lock_guard<std::mutex> lk(g_inited_mutex);
    g_inited_instance_ids.insert(id);
}
static void MarkInstanceUninited(int64_t id) {
    std::lock_guard<std::mutex> lk(g_inited_mutex);
    g_inited_instance_ids.erase(id);
}
static bool IsInstanceInited(int64_t id) {
    std::lock_guard<std::mutex> lk(g_inited_mutex);
    return g_inited_instance_ids.count(id) != 0;
}

// Helper function implementation - defined after G is complete
void enqueue_conn_event(const char* event) {
    G.simple_listener.enqueue_text_line(event);
}

// Register file/typing callbacks on a given instance's ToxManager.
// Must be called for each instance (default in tim2tox_ffi_init, test instances in create_test_instance_ex)
// so that file receive and progress callbacks run with the correct manager_impl for instance routing.
static void RegisterToxManagerFileCallbacks(V2TIMManagerImpl* manager_impl) {
    if (!manager_impl) return;
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return;
    tox_manager->setFriendTypingCallback([manager_impl](uint32_t friend_number, bool typing) {
        ToxManager* tm = manager_impl->GetToxManager();
        if (!tm) return;
        Tox* tox = tm->getTox();
        if (!tox) return;
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
        TOX_ERR_FRIEND_GET_PUBLIC_KEY err;
        if (tox_friend_get_public_key(tox, friend_number, pubkey, &err) && err == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
            std::string uid = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
            std::string line = std::string("typing:") + uid + ":" + (typing ? "1" : "0");
            G.simple_listener.enqueue_text_line(line);
        }
    });
    tox_manager->setFileChunkRequestCallback([manager_impl](uint32_t friend_number, uint32_t file_number, uint64_t position, size_t length) {
        ToxManager* tm = manager_impl->GetToxManager();
        if (!tm) return;
        Tox* tox = tm->getTox();
        if (!tox) return;
        int64_t instance_id = GetInstanceIdFromManager(manager_impl);
        if (instance_id == kInstanceIdDestroyed) return;
        uint64_t key = (static_cast<uint64_t>(friend_number) << 32) | file_number;
        FILE* fp = nullptr;
        uint64_t fsize = 0;
        {
            std::lock_guard<std::mutex> lk(G.send_mtx);
            auto instance_it = G.send_files.find(instance_id);
            if (instance_it == G.send_files.end()) return;
            auto it = instance_it->second.find(key);
            if (it == instance_it->second.end()) return;
            fp = it->second.first;
            fsize = it->second.second;
        }
        if (!fp) return;
        if (length == 0) {
            std::lock_guard<std::mutex> lk(G.send_mtx);
            fclose(fp);
            auto instance_it = G.send_files.find(instance_id);
            if (instance_it != G.send_files.end()) instance_it->second.erase(key);
            return;
        }
        std::vector<uint8_t> buf(length);
        if (fseek(fp, static_cast<long>(position), SEEK_SET) != 0) return;
        size_t nread = fread(buf.data(), 1, length, fp);
        if (nread == 0) return;
        tox_file_send_chunk(tox, friend_number, file_number, position, buf.data(), nread, nullptr);
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
        TOX_ERR_FRIEND_GET_PUBLIC_KEY err;
        if (tox_friend_get_public_key(tox, friend_number, pubkey, &err) && err == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
            std::string uid = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
            uint64_t sent = position + nread;
            char line[256];
            snprintf(line, sizeof(line), "progress_send:%s:%llu:%llu", uid.c_str(),
                     (unsigned long long)sent, (unsigned long long)fsize);
            G.simple_listener.enqueue_text_line(line);
        }
    });
    tox_manager->setFileRecvCallback([manager_impl](uint32_t friend_number, uint32_t file_number, uint32_t kind, uint64_t file_size, const uint8_t* filename, size_t filename_length) {
        int64_t recv_instance_id = GetInstanceIdFromManager(manager_impl);
        if (recv_instance_id == kInstanceIdDestroyed) return;
        V2TIM_LOG(kInfo, "[ffi] OnFileRecv: ENTRY friend_number={} file_number={} kind={} size={} instance_id={}",
                  friend_number, file_number, kind, (unsigned long long)file_size, (long long)recv_instance_id);
        ToxManager* tm = manager_impl->GetToxManager();
        if (!tm) {
            V2TIM_LOG(kError, "[ffi] OnFileRecv: tox manager is null");
            return;
        }
        Tox* tox = tm->getTox();
        if (!tox) {
            V2TIM_LOG(kError, "[ffi] OnFileRecv: tox instance is null");
            return;
        }
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
        TOX_ERR_FRIEND_GET_PUBLIC_KEY err;
        std::string sender_hex;
        if (tox_friend_get_public_key(tox, friend_number, pubkey, &err) && err == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
            sender_hex = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        } else {
            sender_hex = "unknown";
        }
        std::string dir = G.file_recv_dir;
        int mkdir_result = tim2tox_mkdir(dir.c_str(), 0755);
        if (mkdir_result != 0 && errno != EEXIST) {
            V2TIM_LOG(kError, "[ffi] fileRecvCallback: failed to create directory {} (errno: {})", dir, errno);
        }
        std::string name(reinterpret_cast<const char*>(filename), filename_length);
        bool has_invalid_chars = false;
        for (size_t i = 0; i < name.length(); i++) {
            unsigned char c = static_cast<unsigned char>(name[i]);
            if (c < 32 && c != 9 && c != 10 && c != 13) { has_invalid_chars = true; break; }
            if (c == '/' || c == '\\') name[i] = '_';
        }
        if (has_invalid_chars || name.empty()) {
            if (kind == 1) {
                char default_name[64];
                snprintf(default_name, sizeof(default_name), "avatar_%u_%u", friend_number, file_number);
                name = default_name;
            } else {
                char default_name[64];
                snprintf(default_name, sizeof(default_name), "file_%u_%u", friend_number, file_number);
                name = default_name;
            }
        }
        char fname_buf[64];
        snprintf(fname_buf, sizeof(fname_buf), "_%u_%u", friend_number, file_number);
        std::string full = dir + "/" + sender_hex + fname_buf + "_" + name;
        int64_t instance_id = GetInstanceIdFromManager(manager_impl);
        if (instance_id == kInstanceIdDestroyed) return;
        uint64_t key = (static_cast<uint64_t>(friend_number) << 32) | file_number;
        {
            std::lock_guard<std::mutex> lk(G.send_mtx);
            G.recv_files[instance_id][key] = {nullptr, file_size, 0, full, sender_hex, kind};
        }
        char line[2048];
        snprintf(line, sizeof(line), "file_request:%lld:%s:%u:%llu:%u:%s", (long long)instance_id, sender_hex.c_str(), file_number,
                 (unsigned long long)file_size, kind, name.c_str());
        G.simple_listener.enqueue_text_line(line);
        // File messages are handled solely by FfiChatService via file_request polling.
        // Do NOT call NotifyAdvancedListenersReceivedMessage here - it causes duplicate
        // messages in chat UI (C++ msgID differs from FfiChatService msgID, so dedup fails).
    });
    tox_manager->setFileRecvChunkCallback([manager_impl](uint32_t friend_number, uint32_t file_number, uint64_t position, const uint8_t* data, size_t length) {
        ToxManager* tm = manager_impl->GetToxManager();
        if (!tm) {
            V2TIM_LOG(kError, "[ffi] OnRecvFileData: ToxManager instance is null");
            return;
        }
        Tox* tox = tm->getTox();
        if (!tox) {
            V2TIM_LOG(kError, "[ffi] OnRecvFileData: tox instance is null");
            return;
        }
        int64_t instance_id = GetInstanceIdFromManager(manager_impl);
        if (instance_id == kInstanceIdDestroyed) return;
        uint64_t key = (static_cast<uint64_t>(friend_number) << 32) | file_number;
        FILE* fp = nullptr;
        std::string full, sender_hex;
        uint32_t file_kind = 0;
        {
            std::lock_guard<std::mutex> lk(G.send_mtx);
            auto instance_it = G.recv_files.find(instance_id);
            if (instance_it == G.recv_files.end()) {
                V2TIM_LOG(kError, "[ffi] OnRecvFileData: instance {} not found in recv_files map", (long long)instance_id);
                return;
            }
            auto it = instance_it->second.find(key);
            if (it == instance_it->second.end()) {
                V2TIM_LOG(kError, "[ffi] OnRecvFileData: entry NOT found in recv_files map for key={}", (unsigned long long)key);
                return;
            }
            fp = it->second.fp;
            full = it->second.path;
            sender_hex = it->second.sender_hex;
            file_kind = it->second.kind;
        }
        if (length == 0) {
            uint64_t final_size = 0;
            {
                std::lock_guard<std::mutex> lk(G.send_mtx);
                auto instance_it = G.recv_files.find(instance_id);
                if (instance_it != G.recv_files.end()) {
                    auto it = instance_it->second.find(key);
                    if (it != instance_it->second.end()) final_size = it->second.size;
                }
                if (fp) { fflush(fp); fclose(fp); }
                if (instance_it != G.recv_files.end()) instance_it->second.erase(key);
            }
            /* Send final progress_recv (100%) so Dart progress listener gets transferComplete */
            if (final_size > 0) {
                char line[1024];
                snprintf(line, sizeof(line), "progress_recv:%lld:%s:%llu:%llu:%s", (long long)instance_id, sender_hex.c_str(),
                         (unsigned long long)final_size, (unsigned long long)final_size, full.c_str());
                G.simple_listener.enqueue_text_line(line);
            }
            struct stat st{};
            if (stat(full.c_str(), &st) == 0 && st.st_size > 0) {
                char line[2048];
                snprintf(line, sizeof(line), "file_done:%lld:%s:%u:%s", (long long)instance_id, sender_hex.c_str(), file_kind, full.c_str());
                V2TIM_LOG(kInfo, "[ffi] Sending file_done event: {}", line);
                G.simple_listener.enqueue_text_line(line);
            } else {
                V2TIM_LOG(kError, "[ffi] Received file does not exist or is empty: {}", full);
            }
            return;
        }
        if (!fp) {
            V2TIM_LOG(kError, "[ffi] OnRecvFileData: file pointer is null for friend={}, file={}", friend_number, file_number);
            return;
        }
        fseek(fp, static_cast<long>(position), SEEK_SET);
        size_t written = fwrite(data, 1, length, fp);
        if (written != length) {
            V2TIM_LOG(kError, "[ffi] OnRecvFileData: partial write: expected {} bytes, wrote {}", length, written);
        }
        fflush(fp);
        {
            std::lock_guard<std::mutex> lk(G.send_mtx);
            auto instance_it = G.recv_files.find(instance_id);
            if (instance_it != G.recv_files.end()) {
                auto it = instance_it->second.find(key);
                if (it != instance_it->second.end()) {
                    it->second.received = position + length;
                    char line[1024];
                    snprintf(line, sizeof(line), "progress_recv:%lld:%s:%llu:%llu:%s", (long long)instance_id, sender_hex.c_str(),
                             (unsigned long long)it->second.received,
                             (unsigned long long)it->second.size,
                             it->second.path.c_str());
                    G.simple_listener.enqueue_text_line(line);
                }
            }
        }
    });
}

// Test instance management functions - defined outside namespace so they can be called from C/Dart
// Extended version with options support
int64_t tim2tox_ffi_create_test_instance_ex(const char* init_path, int local_discovery_enabled, int ipv6_enabled) {
    if (!init_path) {
        V2TIM_LOG(kError, "[ffi] create_test_instance_ex: init_path is null");
        return 0;
    }

    V2TIM_LOG(kInfo, "[ffi] create_test_instance_ex: ENTRY - init_path={}, local_discovery={}, ipv6={}", init_path, local_discovery_enabled, ipv6_enabled);

    V2TIMManagerImpl* instance = new V2TIMManagerImpl();
    if (!instance) {
        V2TIM_LOG(kError, "[ffi] create_test_instance_ex: failed to create V2TIMManagerImpl");
        return 0;
    }
    V2TIM_LOG(kInfo, "[ffi] create_test_instance_ex: Created V2TIMManagerImpl instance={}", (void*)instance);
    
    // CRITICAL: Register instance BEFORE InitSDK so that GetInstanceIdFromManager can find it
    // This ensures that InitSDK can correctly identify which instance it's initializing
    int64_t instance_id;
    {
        std::lock_guard<std::mutex> lock(g_test_instances_mutex);
        instance_id = g_next_instance_id++;
        g_test_instances[instance_id] = instance;
        g_instance_to_id[instance] = instance_id; // Update reverse map
        V2TIM_LOG(kInfo, "[ffi] create_test_instance_ex: Registered instance_id={}, instance={} BEFORE InitSDK", (long long)instance_id, (void*)instance);
    }

    {
        std::lock_guard<std::mutex> lock(g_test_instance_options_mutex);
        g_test_instance_options[instance_id] = {local_discovery_enabled, ipv6_enabled};
        V2TIM_LOG(kInfo, "[ffi] create_test_instance_ex: Stored options for instance_id={}", (long long)instance_id);
    }

    V2TIMSDKConfig cfg;
    cfg.initPath = V2TIMString(init_path);

    instance->AddSDKListener(&G.sdk_listener);
    V2TIM_LOG(kInfo, "[ffi] create_test_instance_ex: About to call InitSDK for instance={} (instance_id={})", (void*)instance, (long long)instance_id);
    bool ok = instance->InitSDK(0, cfg);
    if (!ok) {
        V2TIM_LOG(kError, "[ffi] create_test_instance_ex: InitSDK failed");
        // Clean up registration on failure
        {
            std::lock_guard<std::mutex> lock(g_test_instances_mutex);
            g_test_instances.erase(instance_id);
            g_instance_to_id.erase(instance);
        }
        {
            std::lock_guard<std::mutex> lock(g_test_instance_options_mutex);
            g_test_instance_options.erase(instance_id);
        }
        delete instance;
        return 0;
    }
    instance->AddSimpleMsgListener(&G.simple_listener);
    RegisterToxManagerFileCallbacks(instance);

    V2TIM_LOG(kInfo, "[ffi] create_test_instance_ex: InitSDK completed successfully for instance={} (instance_id={})", (void*)instance, (long long)instance_id);

    MarkInstanceInited(instance_id);
    return instance_id;
}

// Backward compatibility version (uses default options)
int64_t tim2tox_ffi_create_test_instance(const char* init_path) {
    // Default: local_discovery_enabled=1, ipv6_enabled=1
    return tim2tox_ffi_create_test_instance_ex(init_path, 1, 1);
}

// Helper function to get test instance options (for V2TIMManagerImpl access)
// Returns true if options found and filled, false otherwise
// Made extern "C" so it can be called from V2TIMManagerImpl.cpp
extern "C" bool GetTestInstanceOptions(int64_t instance_id, int* out_local_discovery, int* out_ipv6) {
    std::lock_guard<std::mutex> lock(g_test_instance_options_mutex);
    auto it = g_test_instance_options.find(instance_id);
    if (it != g_test_instance_options.end()) {
        if (out_local_discovery) *out_local_discovery = it->second.local_discovery_enabled;
        if (out_ipv6) *out_ipv6 = it->second.ipv6_enabled;
        return true;
    }
    return false;
}

int tim2tox_ffi_set_current_instance(int64_t instance_handle) {
    std::lock_guard<std::mutex> lock(g_test_instances_mutex);
    
    int64_t old_instance_id = g_current_instance_id;
    
    if (instance_handle == 0) {
        g_current_instance_id = 0;
        V2TIM_LOG(kInfo, "[ffi] set_current_instance: Changed from instance_id={} to 0 (default)", (long long)old_instance_id);
        return 1;
    }

    auto it = g_test_instances.find(instance_handle);
    if (it == g_test_instances.end()) {
        V2TIM_LOG(kError, "[ffi] set_current_instance: instance {} not found (total instances: {})", (long long)instance_handle, g_test_instances.size());
        return 0;
    }

    g_current_instance_id = instance_handle;
    V2TIM_LOG(kInfo, "[ffi] set_current_instance: Changed from instance_id={} to {} (manager={})", (long long)old_instance_id, (long long)instance_handle, (void*)it->second);
    return 1;
}

// Thread-local receiver instance override (file recv path sets so OnRecvNewMessage uses receiver)
static thread_local int64_t g_receiver_instance_override = 0;
int64_t GetReceiverInstanceOverride(void) { return g_receiver_instance_override; }
void SetReceiverInstanceOverride(int64_t id) { g_receiver_instance_override = id; }
void ClearReceiverInstanceOverride(void) { g_receiver_instance_override = 0; }

// Get current instance ID (for listener management)
int64_t GetCurrentInstanceId() {
    std::lock_guard<std::mutex> lock(g_test_instances_mutex);
    int64_t instance_id = g_current_instance_id;
    // fprintf(stdout, "[ffi] GetCurrentInstanceId: returning instance_id=%lld\n", (long long)instance_id);
    // fflush(stdout);
    return instance_id;
}

int64_t tim2tox_ffi_get_current_instance_id(void) {
    return GetCurrentInstanceId();
}

// Get V2TIMManager for a given instance_id. Used by dart_compat when request includes instance_id
// (e.g. inviteUserToGroup) so the operation runs on the correct instance even if "current" changed.
// Returns nullptr if instance_id not found.
V2TIMManager* GetManagerForInstanceId(int64_t instance_id) {
    if (instance_id == 0) {
        return V2TIMManagerImpl::GetInstance();
    }
    std::lock_guard<std::mutex> lock(g_test_instances_mutex);
    auto it = g_test_instances.find(instance_id);
    if (it != g_test_instances.end()) {
        return static_cast<V2TIMManager*>(it->second);
    }
    return nullptr;
}

// Get instance ID from V2TIMManagerImpl pointer
// Returns 0 for default instance, positive for test instances, kInstanceIdDestroyed if not in map (teardown).
int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager) {
    if (!manager) {
        return 0;
    }
    std::lock_guard<std::mutex> lock(g_test_instances_mutex);
    auto it = g_instance_to_id.find(manager);
    if (it != g_instance_to_id.end()) {
        return it->second;
    }
    
    // Not found - check if this is the default instance
    V2TIMManagerImpl* default_instance = V2TIMManagerImpl::GetInstance();
    if (manager == default_instance) {
        g_instance_to_id[manager] = 0;
        return 0;
    }
    
    // Manager not in map: instance was destroyed or teardown race. Return sentinel
    // so callers do not mis-route to instance 0. No WARNING log to avoid tearDown spam.
    return kInstanceIdDestroyed;
}

// R-08: Whether the "current" instance has been inited (for FFI that don't take instance_id).
static bool IsCurrentInstanceInited() {
    V2TIMManagerImpl* m = GetCurrentInstance();
    if (!m) return false;
    return IsInstanceInited(GetInstanceIdFromManager(m));
}

// Iterate all (instance_id, manager) pairs. Used by dart_compat to register
// group/friendship listeners with every instance when addGroupListener is called
// (avoids race where only "current" instance gets the listener when logins run in parallel).
// IMPORTANT: Do NOT hold g_test_instances_mutex while invoking the callback. The callback
// calls manager->AddGroupListener(), which calls GetInstanceIdFromManager() and would
// try to take g_test_instances_mutex again -> deadlock. Copy under lock, then invoke outside lock.
extern "C" void Tim2ToxFfiForEachInstanceManager(void (*cb)(int64_t id, void* manager, void* user), void* user) {
    if (!cb) return;
    std::vector<std::pair<int64_t, void*>> copy;
    {
        std::lock_guard<std::mutex> lock(g_test_instances_mutex);
        copy.reserve(g_test_instances.size());
        for (const auto& kv : g_test_instances) {
            copy.push_back({kv.first, static_cast<void*>(kv.second)});
        }
    }
    for (const auto& p : copy) {
        cb(p.first, p.second, user);
    }
}

int tim2tox_ffi_destroy_test_instance(int64_t instance_handle) {
    if (instance_handle == 0) {
        V2TIM_LOG(kError, "[ffi] destroy_test_instance: cannot destroy default instance (handle=0)");
        return 0;
    }

    V2TIMManagerImpl* instance = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_test_instances_mutex);
        auto it = g_test_instances.find(instance_handle);
        if (it == g_test_instances.end()) {
            V2TIM_LOG(kError, "[ffi] destroy_test_instance: instance {} not found", (long long)instance_handle);
            return 0;
        }
        instance = it->second;
        // Don't erase yet - we need it for CleanupInstanceListeners
        
        // If this was the current instance, switch to default
        if (g_current_instance_id == instance_handle) {
            g_current_instance_id = 0;
        }
    }
    
    // Cleanup listeners for this instance BEFORE UnInitSDK so no listener
    // callbacks use this instance during teardown.
    extern void CleanupInstanceListeners(int64_t instance_id);
    CleanupInstanceListeners(instance_handle);
    
    // UnInitSDK MUST run while the instance is still in g_instance_to_id:
    // UnInitSDK() calls GetInstanceIdFromManager(this) for save path. If we
    // erase first, that lookup fails and triggers "Manager not found" WARNING.
    if (instance) {
        instance->UnInitSDK();
    }
    
    // Remove from maps only AFTER UnInitSDK so no code path (including
    // UnInitSDK and any callbacks it joins) sees the manager as "not found".
    MarkInstanceUninited(instance_handle);
    {
        std::lock_guard<std::mutex> lock(g_test_instances_mutex);
        g_test_instances.erase(instance_handle);
        g_instance_to_id.erase(instance);
    }
    
    if (instance) {
        delete instance;
    }
    
    return 1;
}

// Helper function to get current instance (for use in other FFI functions and dart_compat layer)
// Defined outside namespace so it can be called from FFI functions and dart_compat_utils.cpp
// Made non-static so it can be accessed from dart_compat layer for multi-instance support
V2TIMManagerImpl* GetCurrentInstance() {
    std::lock_guard<std::mutex> lock(g_test_instances_mutex);
    if (g_current_instance_id == 0) {
        V2TIMManagerImpl* default_instance = V2TIMManagerImpl::GetInstance();
        // Register default instance in g_instance_to_id if not already registered
        // This ensures GetInstanceIdFromManager can find it
        if (default_instance && g_instance_to_id.find(default_instance) == g_instance_to_id.end()) {
            g_instance_to_id[default_instance] = 0;
            V2TIM_LOG(kInfo, "[ffi] GetCurrentInstance: Registered default instance {} with instance_id=0", (void*)default_instance);
        }
        return default_instance;
    }
    auto it = g_test_instances.find(g_current_instance_id);
    if (it != g_test_instances.end()) {
        return it->second;
    }
    V2TIMManagerImpl* default_instance = V2TIMManagerImpl::GetInstance();
    if (default_instance && g_instance_to_id.find(default_instance) == g_instance_to_id.end()) {
        g_instance_to_id[default_instance] = 0;
        V2TIM_LOG(kInfo, "[ffi] GetCurrentInstance: Registered default instance {} with instance_id=0 (fallback)", (void*)default_instance);
    }
    return default_instance;
}

// R-08: Get manager for instance_id; no fallback to default (return nullptr if not found).
static V2TIMManagerImpl* GetInstanceFromId(int64_t instance_id) {
    if (instance_id == 0) return GetCurrentInstance();
    std::lock_guard<std::mutex> lock(g_test_instances_mutex);
    auto it = g_test_instances.find(instance_id);
    if (it != g_test_instances.end()) return it->second;
    return nullptr;
}

int tim2tox_ffi_init(void) {
    return tim2tox_ffi_init_with_path(nullptr);
}

int tim2tox_ffi_init_with_path(const char* init_path) {
    if (IsInstanceInited(0)) return 1;
    V2TIMSDKConfig cfg;
    if (init_path && init_path[0] != '\0') {
        cfg.initPath = V2TIMString(init_path);
        V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_init_with_path: using initPath={}", init_path);
    }
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    manager_impl->AddSDKListener(&G.sdk_listener);
    bool ok = manager_impl->InitSDK(0, cfg);
    if (!ok) return 0;
    manager_impl->AddSimpleMsgListener(&G.simple_listener);
    // Hook typing and file callbacks on this instance's ToxManager (per-instance so file recv routes correctly)
    RegisterToxManagerFileCallbacks(manager_impl);
    MarkInstanceInited(0);
    return 1;
}

int tim2tox_ffi_login(const char* user_id, const char* user_sig) {
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_login: ENTRY - user_id={}, user_sig={}, inited={}", user_id ? user_id : "(null)", user_sig ? "(provided)" : "(null)", IsCurrentInstanceInited());

    if (!IsCurrentInstanceInited()) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_login: ERROR - current instance not inited, returning 0");
        return 0;
    }

    static struct Cb : public V2TIMCallback {
        void OnSuccess() override {
            V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_login: OnSuccess callback called");
        }
        void OnError(int code, const V2TIMString& msg) override {
            V2TIM_LOG(kError, "[ffi] tim2tox_ffi_login: OnError callback called - code={}, msg={}", code, msg.CString());
            V2TIM_LOG(kError, "[ffi] Login error {}: {}", code, msg.CString());
        }
    } cb;

    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_login: Calling GetCurrentInstance()->Login()");

    GetCurrentInstance()->Login(user_id ? user_id : "", user_sig ? user_sig : "", &cb);

    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_login: EXIT - returning 1");
    return 1;
}

int tim2tox_ffi_login_async(int64_t instance_id, const char* user_id, const char* user_sig, tim2tox_login_callback_t callback, void* user_data) {
    int64_t id = (instance_id == 0) ? GetCurrentInstanceId() : instance_id;
    // NOTE: keep both "instance_id" (original arg) and "id" (normalized) to debug routing issues.
    V2TIM_LOG(kInfo,
              "[ffi] tim2tox_ffi_login_async: ENTRY instance_id={}, resolved_id={}, callback_ptr={}, user_data_ptr={}, user_id={}",
              (long long)instance_id,
              (long long)id,
              (void*)callback,
              user_data,
              user_id ? user_id : "(null)");

    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) {
        V2TIM_LOG(kError,
                  "[ffi] tim2tox_ffi_login_async: ERROR manager not found for instance_id={}. callback_ptr={}",
                  (long long)instance_id,
                  (void*)callback);
        if (callback) callback(0, -1, "instance not found", user_data);
        return 0;
    }
    if (!IsInstanceInited(id)) {
        V2TIM_LOG(kError,
                  "[ffi] tim2tox_ffi_login_async: ERROR instance not inited for resolved_id={}. callback_ptr={}",
                  (long long)id,
                  (void*)callback);
        if (callback) callback(0, -2, "instance not inited", user_data);
        return 0;
    }
    if (!user_id || !user_id[0]) {
        V2TIM_LOG(kError,
                  "[ffi] tim2tox_ffi_login_async: ERROR user_id empty. callback_ptr={}",
                  (void*)callback);
        if (callback) callback(0, -3, "user_id empty", user_data);
        return 0;
    }
    struct LoginCb : public V2TIMCallback {
        tim2tox_login_callback_t cb = nullptr;
        void* ud = nullptr;

        explicit LoginCb(tim2tox_login_callback_t callback, void* user_data)
            : cb(callback), ud(user_data) {}

        void OnSuccess() override {
            V2TIM_LOG(kInfo,
                      "[ffi] tim2tox_ffi_login_async: OnSuccess called. cb_ptr={}, ud_ptr={}",
                      (void*)cb,
                      ud);
            if (cb) cb(1, 0, "", ud);
            delete this;
        }
        void OnError(int code, const V2TIMString& msg) override {
            V2TIM_LOG(kError,
                      "[ffi] tim2tox_ffi_login_async: OnError called. code={}, cb_ptr={}, ud_ptr={}, msg={}",
                      code,
                      (void*)cb,
                      ud,
                      msg.CString());
            if (cb) {
                std::string msg_copy(msg.CString());
                cb(0, code, msg_copy.c_str(), ud);
            }
            delete this;
        }
    };
    auto* login_cb = new LoginCb(callback, user_data);
    manager->Login(user_id ? user_id : "", user_sig ? user_sig : "", login_cb);
    V2TIM_LOG(kInfo,
              "[ffi] tim2tox_ffi_login_async: EXIT (Login invoked). instance_id={}, resolved_id={}",
              (long long)instance_id,
              (long long)id);
    return 1;
}

int tim2tox_ffi_add_friend(const char* user_id, const char* wording) {
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_add_friend: ENTRY - user_id={}, wording={}, inited={}", user_id ? user_id : "(null)", wording ? wording : "(null)", IsCurrentInstanceInited());

    if (!IsCurrentInstanceInited() || !user_id) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_add_friend: ERROR - inited={}, user_id={}, returning 0", IsCurrentInstanceInited(), (void*)user_id);
        return 0;
    }

    V2TIMFriendAddApplication app;
    app.userID = user_id;
    if (wording) app.addWording = wording;
    struct AddCb : public V2TIMValueCallback<V2TIMFriendOperationResult> {
        void OnSuccess(const V2TIMFriendOperationResult& r) override {
            V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_add_friend: OnSuccess - result_code={}", r.resultCode);
        }
        void OnError(int code, const V2TIMString& msg) override {
            V2TIM_LOG(kError, "[ffi] tim2tox_ffi_add_friend: OnError - code={}, msg={}", code, msg.CString());
            V2TIM_LOG(kError, "[ffi] AddFriend error {}: {}", code, msg.CString());
        }
    } addcb;
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    manager_impl->GetFriendshipManager()->AddFriend(app, &addcb);
    return 1;
}

int tim2tox_ffi_send_c2c_text(const char* user_id, const char* text) {
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_send_c2c_text: ENTRY - user_id={}, text_len={}, inited={}", user_id ? user_id : "(null)", text ? strlen(text) : 0, IsCurrentInstanceInited());

    if (!IsCurrentInstanceInited() || !user_id || !text) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_send_c2c_text: ERROR - inited={}, user_id={}, text={}, returning 0", IsCurrentInstanceInited(), (void*)user_id, (void*)text);
        return 0;
    }

    struct SendCb : public V2TIMSendCallback {
        void OnSuccess(const V2TIMMessage& m) override {
            V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_send_c2c_text: OnSuccess - msg_id={}", m.msgID.CString());
        }
        void OnError(int code, const V2TIMString& msg) override {
            V2TIM_LOG(kError, "[ffi] tim2tox_ffi_send_c2c_text: OnError - code={}, msg={}", code, msg.CString());
        }
        void OnProgress(uint32_t p) override {
            (void)p;
        }
    } sendcb;

    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_send_c2c_text: Calling SendC2CTextMessage()");

    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    manager_impl->SendC2CTextMessage(text, user_id, &sendcb);

    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_send_c2c_text: EXIT - returning 1");
    return 1;
}

int tim2tox_ffi_send_c2c_custom(const char* user_id, const unsigned char* data, int data_len) {
    if (!IsCurrentInstanceInited() || !user_id || !data || data_len <= 0) return 0;
    struct SendCb : public V2TIMSendCallback {
        void OnSuccess(const V2TIMMessage& m) override {
        }
        void OnError(int code, const V2TIMString& msg) override {
            // Error logged via V2TIM_LOG
        }
        void OnProgress(uint32_t p) override {
            (void)p;
        }
    } sendcb;
    V2TIMBuffer buffer(data, data_len);
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    manager_impl->SendC2CCustomMessage(buffer, user_id, &sendcb);
    return 1;
}

int tim2tox_ffi_poll_text(int64_t instance_id, char* buffer, int buffer_len) {
    int64_t id = (instance_id == 0) ? GetCurrentInstanceId() : instance_id;
    if (!IsInstanceInited(id) || !buffer || buffer_len <= 0) return 0;
    return G.simple_listener.poll_text(instance_id, buffer, buffer_len);
}

int tim2tox_ffi_poll_custom(unsigned char* buffer, int buffer_len) {
    if (!IsCurrentInstanceInited() || !buffer || buffer_len <= 0) return 0;
    return G.simple_listener.poll_custom(buffer, buffer_len);
}

int tim2tox_ffi_get_login_user(char* buffer, int buffer_len) {
    if (!IsCurrentInstanceInited() || !buffer || buffer_len <= 0) return 0;
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    auto uid = manager_impl->GetLoginUser();
    std::string s = uid.CString();
    int n = (int)std::min(s.size(), (size_t)(buffer_len - 1));
    if (n > 0) memcpy(buffer, s.data(), n);
    buffer[n] = 0;
    return n;
}

// Returns the self Tox address (76-hex public key + nospam + checksum) for
// the current instance, written into `buffer` as a NUL-terminated string.
// Returns the number of bytes written (excluding NUL), or 0 if the address
// is not yet populated (e.g. before the first DHT connection establishes).
// Use this — not tim2tox_ffi_get_login_user — when a caller actually needs
// the Tox identity (e.g. auto_tests passing it to AddFriend).
int tim2tox_ffi_get_self_tox_id(char* buffer, int buffer_len) {
    if (!IsCurrentInstanceInited() || !buffer || buffer_len <= 0) return 0;
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    auto addr = manager_impl->GetSelfToxAddress();
    std::string s = addr.CString();
    int n = (int)std::min(s.size(), (size_t)(buffer_len - 1));
    if (n > 0) memcpy(buffer, s.data(), n);
    buffer[n] = 0;
    return n;
}

void tim2tox_ffi_uninit(void) {
    if (!IsInstanceInited(0)) return;
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    manager_impl->UnInitSDK();
    MarkInstanceUninited(0);
}

void tim2tox_ffi_save_tox_profile(void) {
    if (!IsCurrentInstanceInited()) return;
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    if (manager_impl) {
        manager_impl->SaveToxProfile();
    }
}

void tim2tox_ffi_set_callback(tim2tox_event_cb cb, void* user_data) {
    g_cb.store(cb);
    g_cb_user.store(user_data);
}

int tim2tox_ffi_get_friend_list(char* buffer, int buffer_len) {
    if (!IsCurrentInstanceInited() || !buffer || buffer_len <= 0) return 0;
    struct LCb : public V2TIMValueCallback<V2TIMFriendInfoVector> {
        std::string out;
        std::mutex m;
        std::condition_variable cv;
        bool done = false;
        void OnSuccess(const V2TIMFriendInfoVector& v) override {
            std::string s;
            for (size_t i = 0; i < v.Size(); ++i) {
                const auto& fi = v[i];
                std::string uid = fi.userID.CString();
                std::string nick = fi.friendRemark.CString(); // may be empty
                // online flag from role storage, see impl mapping
                int online = (fi.userFullInfo.role == V2TIM_USER_STATUS_ONLINE) ? 1 : 0;
                s.append(uid);
                s.push_back('\t');
                s.append(nick);
                s.push_back('\t');
                s.append(online ? "1" : "0");
                s.push_back('\n');
            }
            {
                std::lock_guard<std::mutex> lk(m);
                out.swap(s);
                done = true;
            }
            cv.notify_one();
        }
        void OnError(int, const V2TIMString&) override {
            std::lock_guard<std::mutex> lk(m);
            done = true;
            cv.notify_one();
        }
    } lcb;
    GetCurrentInstance()->GetFriendshipManager()->GetFriendList(&lcb);
    // wait for callback
    {
        std::unique_lock<std::mutex> lk(lcb.m);
        lcb.cv.wait_for(lk, std::chrono::seconds(3), [&]{ return lcb.done; });
        if (!lcb.done) return 0;
        int n = (int)std::min(lcb.out.size(), (size_t)(buffer_len - 1));
        if (n > 0) memcpy(buffer, lcb.out.data(), n);
        buffer[n] = 0;
        return n;
    }
}

int tim2tox_ffi_set_self_info(const char* nickname, const char* status_message) {
    if (!IsCurrentInstanceInited()) return 0;
    V2TIMUserFullInfo info;
    if (nickname) info.nickName = nickname;
    if (status_message) info.selfSignature = status_message;
    struct Cb : public V2TIMCallback {
        void OnSuccess() override {}
        void OnError(int code, const V2TIMString& msg) override {
            // Error logged via V2TIM_LOG
        }
    } cb;
    GetCurrentInstance()->SetSelfInfo(info, &cb);
    return 1;
}

int tim2tox_ffi_save_friend_nickname(const char* friend_id, const char* nickname) {
    // This function is called from C++ to notify Flutter layer to save friend nickname
    // Route via polling queue to avoid FFI callback from background thread
    // Flutter will poll and handle this event in its isolate
    // DO NOT call FFI callback directly from background thread - it will crash
    if (!IsCurrentInstanceInited() || !friend_id || !nickname) return 0;
    
    // Enqueue event via polling queue: "nickname_changed:<friend_id>:<nickname>"
    std::string line = std::string("nickname_changed:") + friend_id + ":" + nickname;
    G.simple_listener.enqueue_text_line(line);
    return 1;
}

int tim2tox_ffi_save_friend_status_message(const char* friend_id, const char* status_message) {
    // This function is called from C++ to notify Flutter layer to save friend status message
    // Route via polling queue to avoid FFI callback from background thread
    // Flutter will poll and handle this event in its isolate
    // DO NOT call FFI callback directly from background thread - it will crash
    if (!IsCurrentInstanceInited() || !friend_id || !status_message) return 0;
    
    // Enqueue event via polling queue: "status_changed:<friend_id>:<status_message>"
    std::string line = std::string("status_changed:") + friend_id + ":" + status_message;
    G.simple_listener.enqueue_text_line(line);
    return 1;
}

static int get_friend_applications_impl(V2TIMManager* manager, char* buffer, int buffer_len) {
    if (!manager || !buffer || buffer_len <= 0) return 0;
    struct RCb : public V2TIMValueCallback<V2TIMFriendApplicationResult> {
        std::string out; std::mutex m; std::condition_variable cv; bool done=false;
        void OnSuccess(const V2TIMFriendApplicationResult& r) override {
            std::string s;
            for (size_t i = 0; i < r.applicationList.Size(); ++i) {
                const auto& a = r.applicationList[i];
                s.append(a.userID.CString());
                s.push_back('\t');
                s.append(a.addWording.CString());
                s.push_back('\n');
            }
            { std::lock_guard<std::mutex> lk(m); out.swap(s); done=true; }
            cv.notify_one();
        }
        void OnError(int, const V2TIMString&) override { std::lock_guard<std::mutex> lk(m); done=true; cv.notify_one(); }
    } rcb;
    manager->GetFriendshipManager()->GetFriendApplicationList(&rcb);
    std::unique_lock<std::mutex> lk(rcb.m);
    rcb.cv.wait_for(lk, std::chrono::seconds(3), [&]{return rcb.done;});
    int n = (int)std::min(rcb.out.size(), (size_t)(buffer_len - 1));
    if (n > 0) memcpy(buffer, rcb.out.data(), n);
    buffer[n] = 0;
    return n;
}

int tim2tox_ffi_get_friend_applications(char* buffer, int buffer_len) {
    if (!IsCurrentInstanceInited() || !buffer || buffer_len <= 0) return 0;
    return get_friend_applications_impl(GetCurrentInstance(), buffer, buffer_len);
}

int tim2tox_ffi_get_friend_applications_for_instance(int64_t instance_id, char* buffer, int buffer_len) {
    int64_t id = (instance_id == 0) ? GetCurrentInstanceId() : instance_id;
    if (!IsInstanceInited(id) || !buffer || buffer_len <= 0) return 0;
    V2TIMManager* manager = GetManagerForInstanceId(instance_id);
    if (!manager) return 0;
    return get_friend_applications_impl(manager, buffer, buffer_len);
}

int tim2tox_ffi_accept_friend(const char* user_id) {
    if (!IsCurrentInstanceInited() || !user_id) return 0;
    V2TIMFriendApplication app; app.userID = user_id;
    struct Cb : public V2TIMValueCallback<V2TIMFriendOperationResult> {
        void OnSuccess(const V2TIMFriendOperationResult& r) override {
        }
        void OnError(int code, const V2TIMString& msg) override {
            // Error logged via V2TIM_LOG
        }
    } cb;
    GetCurrentInstance()->GetFriendshipManager()->AcceptFriendApplication(app, V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD, &cb);
    return 1;
}

int tim2tox_ffi_delete_friend(const char* user_id) {
    if (!IsCurrentInstanceInited() || !user_id) return 0;
    V2TIMStringVector ids; ids.PushBack(user_id);
    struct Cb : public V2TIMValueCallback<V2TIMFriendOperationResultVector> {
        void OnSuccess(const V2TIMFriendOperationResultVector& v) override {
        }
        void OnError(int code, const V2TIMString& msg) override {
            // Error logged via V2TIM_LOG
        }
    } cb;
    GetCurrentInstance()->GetFriendshipManager()->DeleteFromFriendList(ids, V2TIM_FRIEND_TYPE_BOTH, &cb);
    return 1;
}

int tim2tox_ffi_set_typing(const char* user_id, int typing_on) {
    if (!IsCurrentInstanceInited() || !user_id) return 0;
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    if (!manager_impl) return 0;
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return 0;
    Tox* tox = tox_manager->getTox();
    if (!tox) return 0;
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE] = {0};
    if (!ToxUtil::tox_hex_to_bytes(user_id, (int)strlen(user_id), pubkey, TOX_PUBLIC_KEY_SIZE)) return 0;
    TOX_ERR_FRIEND_BY_PUBLIC_KEY err;
    uint32_t friend_no = tox_friend_by_public_key(tox, pubkey, &err);
    if (err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) return 0;
    tox_self_set_typing(tox, friend_no, typing_on ? true : false, nullptr);
    return 1;
}

int tim2tox_ffi_create_group(const char* group_name, const char* group_type, char* out_group_id, int out_len) {
    if (!IsCurrentInstanceInited() || !out_group_id || out_len <= 0) {
        return 0;
    }
    struct Cb : public V2TIMValueCallback<V2TIMString> {
        std::string gid; std::mutex m; std::condition_variable cv; bool done=false; int err_code=0; std::string err_msg;
        void OnSuccess(const V2TIMString& id) override {
            gid = id.CString();
            done = true;
            cv.notify_one();
        }
        void OnError(int code, const V2TIMString& msg) override {
            err_code = code;
            err_msg = msg.CString();
            done = true;
            cv.notify_one();
        }
    } cb;
    
    // Get instance and verify it's valid before calling virtual function
    V2TIMManager* manager = GetCurrentInstance();
    if (!manager) {
        V2TIM_LOG(kError, "[ffi] CreateGroup: GetCurrentInstance() returned null");
        return 0;
    }
    
    // Verify object is still valid by checking if it's a V2TIMManagerImpl instance
    // Cast to implementation class to verify vtable is valid
    V2TIMManagerImpl* manager_impl = dynamic_cast<V2TIMManagerImpl*>(manager);
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] CreateGroup: dynamic_cast to V2TIMManagerImpl failed (vtable may be corrupted)");
        return 0;
    }
    
    // Verify object is running (initialized)
    if (!manager_impl->IsRunning()) {
        V2TIM_LOG(kError, "[ffi] CreateGroup: manager is not running (not initialized)");
        return 0;
    }
    
    
    // Use try-catch to handle any potential crashes from invalid vtable
    // Call through implementation class directly to avoid vtable issues
    try {
        // Call CreateGroup through implementation class directly (not through virtual function)
        // This avoids potential vtable corruption issues
        // group_type can be "group" (new API) or "conference" (old API), default to "group"
        V2TIMString groupTypeStr(group_type && strlen(group_type) > 0 ? group_type : "group");
        V2TIMString groupID("");
        V2TIMString groupName(group_name ? group_name : "");
        manager_impl->CreateGroup(groupTypeStr, groupID, groupName, &cb);
    } catch (const std::exception& e) {
        V2TIM_LOG(kError, "[ffi] CreateGroup: Exception caught when calling CreateGroup: {}", e.what());
        return 0;
    } catch (...) {
        V2TIM_LOG(kError, "[ffi] CreateGroup: Unknown exception caught when calling CreateGroup (possible vtable corruption)");
        return 0;
    }
    std::unique_lock<std::mutex> lk(cb.m);
    bool timed_out = !cb.cv.wait_for(lk, std::chrono::seconds(5), [&]{return cb.done;});
    if (timed_out) {
        return 0;
    }
    if (cb.gid.empty()) {
        return 0;
    }
    int n = (int)std::min(cb.gid.size(), (size_t)(out_len - 1));
    if (n > 0) memcpy(out_group_id, cb.gid.data(), n);
    out_group_id[n] = 0;
    return n;
}

int tim2tox_ffi_join_group(const char* group_id, const char* request_msg) {
    if (!IsCurrentInstanceInited() || !group_id) return 0;
    struct Cb : public V2TIMCallback {
        void OnSuccess() override {}
        void OnError(int code, const V2TIMString& msg) override {
            // Error logged via V2TIM_LOG
        }
    } cb;
    const char* wording = request_msg ? request_msg : "";
    GetCurrentInstance()->JoinGroup(group_id, wording, &cb);
    return 1;
}

int tim2tox_ffi_send_group_text(const char* group_id, const char* text) {
    if (!IsCurrentInstanceInited() || !group_id || !text) return 0;
    struct SendCb : public V2TIMSendCallback {
        void OnSuccess(const V2TIMMessage& m) override {}
        void OnError(int code, const V2TIMString& msg) override {
            // Error logged via V2TIM_LOG
        }
        void OnProgress(uint32_t) override {}
    } sendcb;
    GetCurrentInstance()->SendGroupTextMessage(text, group_id, V2TIMMessagePriority::V2TIM_PRIORITY_NORMAL, &sendcb);
    return 1;
}

// R-07: Update known groups in Core (FFI forwards to manager)
int tim2tox_ffi_update_known_groups(int64_t instance_id, const char* groups_str) {
    if (!groups_str) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) return 0;
    std::vector<std::string> list;
    std::istringstream iss(groups_str);
    std::string line;
    while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\n') line.pop_back();
        if (!line.empty()) list.push_back(line);
    }
    manager->SetKnownGroupIDs(list);
    return (int)list.size();
}

extern "C" {
// R-07: Read known groups from Core (FFI forwards to manager)
int tim2tox_ffi_get_known_groups(int64_t instance_id, char* buffer, int buffer_len) {
    if (!buffer || buffer_len <= 0) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) { if (buffer_len > 0) buffer[0] = 0; return 0; }
    std::vector<std::string> groups = manager->GetKnownGroupIDs();
    std::string result;
    for (const auto& group_id : groups) {
        if (!group_id.empty()) { result.append(group_id); result.push_back('\n'); }
    }
    int n = (int)std::min(result.size(), (size_t)(buffer_len - 1));
    if (n > 0) { memcpy(buffer, result.data(), n); buffer[n] = 0; } else { buffer[0] = 0; }
    return n;
}

// Get full tox group chat_id from groupID
// group_id: group ID like "tox_6"
// out_chat_id: output buffer for chat_id (64-char hex string, TOX_GROUP_CHAT_ID_SIZE * 2)
// out_len: size of output buffer (should be at least 65 for null terminator)
// Returns: 1 on success, 0 on error
int tim2tox_ffi_get_group_chat_id(int64_t instance_id, const char* group_id, char* out_chat_id, int out_len) {
    int64_t id = (instance_id == 0) ? GetCurrentInstanceId() : instance_id;
    if (!IsInstanceInited(id) || !group_id || !out_chat_id || out_len < 65) {
        return 0;
    }
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) {
        return 0;
    }
    
    V2TIMString groupIDStr(group_id);
    Tox_Group_Number group_number = UINT32_MAX;
    if (!manager_impl->GetGroupNumberFromID(groupIDStr, group_number)) {
        // R-07: Try Core metadata for stored chat_id
        char stored_chat_id[65];
        bool has_stored_chat_id = manager_impl->GetGroupChatIdFromStorage(std::string(group_id), stored_chat_id, sizeof(stored_chat_id));
        
        if (has_stored_chat_id) {
            // Convert hex string to binary chat_id
            uint8_t target_chat_id[TOX_GROUP_CHAT_ID_SIZE];
            std::string chat_id_hex(stored_chat_id);
            std::istringstream iss(chat_id_hex);
            bool valid = true;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                std::string byte_str = chat_id_hex.substr(i * 2, 2);
                char* endptr;
                unsigned long byte_val = strtoul(byte_str.c_str(), &endptr, 16);
                if (*endptr != '\0' || byte_val > 255) {
                    valid = false;
                    break;
                }
                target_chat_id[i] = static_cast<uint8_t>(byte_val);
            }
            
            if (valid) {
                // Try to find group by chat_id
                ToxManager* tox_manager = manager_impl->GetToxManager();
                if (tox_manager) {
                    group_number = tox_manager->getGroupByChatId(target_chat_id);
                    if (group_number != UINT32_MAX) {
                        // Rebuild the mapping for future use
                        std::lock_guard<std::mutex> lock(manager_impl->mutex_);
                        manager_impl->group_id_to_group_number_[V2TIMString(group_id)] = group_number;
                        manager_impl->group_number_to_group_id_[group_number] = V2TIMString(group_id);
                    }
                }
            }
        }
        
        // If still not found, try to find matching group by checking group_number_to_group_id_ mapping
        if (group_number == UINT32_MAX) {
            ToxManager* tox_manager = manager_impl->GetToxManager();
            if (tox_manager) {
                size_t group_count = tox_manager->getGroupListSize();
                if (group_count > 0) {
                    std::vector<Tox_Group_Number> group_list(group_count);
                    tox_manager->getGroupList(group_list.data(), group_count);
                
                    std::lock_guard<std::mutex> lock(manager_impl->mutex_);
                    for (Tox_Group_Number group_num : group_list) {
                        auto it = manager_impl->group_number_to_group_id_.find(group_num);
                        if (it != manager_impl->group_number_to_group_id_.end() && 
                            it->second.CString() == std::string(group_id)) {
                            group_number = group_num;
                            break;
                        }
                    }
                }
            }
        }
        
        // If still not found, the mapping is truly empty and we can't match
        if (group_number == UINT32_MAX) {
            // R-07: Return stored chat_id from Core metadata even if group not found
            char stored_chat_id[65];
            bool has_stored_chat_id = manager_impl->GetGroupChatIdFromStorage(std::string(group_id), stored_chat_id, sizeof(stored_chat_id));
            if (has_stored_chat_id) {
                // Copy stored chat_id to output buffer
                int copy_len = (int)std::min((size_t)(out_len - 1), strlen(stored_chat_id));
                memcpy(out_chat_id, stored_chat_id, copy_len);
                out_chat_id[copy_len] = '\0';
                return 1;
            }
            return 0;
        }
    }
    
    if (group_number == UINT32_MAX) {
        return 0;
    }
    
    // Get chat_id from ToxManager
    // manager_impl is already defined at the beginning of the function
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return 0;
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    Tox_Err_Group_State_Query err_chat_id;
    if (!tox_manager->getGroupChatId(group_number, chat_id, &err_chat_id) ||
        err_chat_id != TOX_ERR_GROUP_STATE_QUERY_OK) {
        return 0;
    }
    
    // Convert to hex string (64 characters: 32 bytes * 2)
    std::ostringstream oss;
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
    }
    std::string hex_str = oss.str();
    
    // Copy to output buffer
    int copy_len = (int)std::min((size_t)(out_len - 1), hex_str.length());
    memcpy(out_chat_id, hex_str.c_str(), copy_len);
    out_chat_id[copy_len] = '\0';
    return 1;
}

// R-07: Store group chat_id in Core (FFI forwards to manager); optionally notify Dart for persistence
int tim2tox_ffi_set_group_chat_id(int64_t instance_id, const char* group_id, const char* chat_id) {
    if (!group_id || !chat_id) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) return 0;
    manager->SetGroupChatIdInStorage(std::string(group_id), std::string(chat_id));
    std::ostringstream json;
    json << "{";
    json << "\"callback\":\"groupChatIdStored\",";
    std::string escaped_group_id = EscapeJsonString(std::string(group_id));
    json << "\"group_id\":\"" << escaped_group_id << "\",";
    std::string escaped_chat_id = EscapeJsonString(std::string(chat_id));
    json << "\"chat_id\":\"" << escaped_chat_id << "\"";
    json << "}";
    std::string json_str = json.str();
    try {
        SendCallbackToDart("groupChatIdStored", json_str, nullptr);
    } catch (...) {
        V2TIM_LOG(kError, "[tim2tox_ffi] tim2tox_ffi_set_group_chat_id: EXCEPTION in SendCallbackToDart");
    }

    return 1;
}

// R-07: Get group chat_id from Core metadata (FFI forwards to manager)
int tim2tox_ffi_get_group_chat_id_from_storage(int64_t instance_id, const char* group_id, char* out_chat_id, int out_len) {
    if (!group_id || !out_chat_id || out_len < 65) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) return 0;
    return manager->GetGroupChatIdFromStorage(std::string(group_id), out_chat_id, out_len) ? 1 : 0;
}

// R-07: Store group type in Core (FFI forwards to manager); notify Dart for persistence
int tim2tox_ffi_set_group_type(int64_t instance_id, const char* group_id, const char* group_type) {
    if (!group_id || !group_type) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) return 0;
    manager->SetGroupTypeInStorage(std::string(group_id), std::string(group_type));
    // Notify Dart layer to persist to SharedPreferences
    std::ostringstream json;
    json << "{";
    json << "\"callback\":\"groupTypeStored\",";
    json << "\"group_id\":\"" << EscapeJsonString(std::string(group_id)) << "\",";
    json << "\"group_type\":\"" << EscapeJsonString(std::string(group_type)) << "\"";
    json << "}";
    
    std::string json_str = json.str();
    try {
        SendCallbackToDart("groupTypeStored", json_str, nullptr);
    } catch (...) {
        // Continue execution even if SendCallbackToDart fails
    }
    
    return 1;
}

// R-07: Get group type from Core metadata (FFI forwards to manager)
int tim2tox_ffi_get_group_type_from_storage(int64_t instance_id, const char* group_id, char* out_group_type, int out_len) {
    if (!group_id || !out_group_type || out_len < 16) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) return 0;
    return manager->GetGroupTypeFromStorage(std::string(group_id), out_group_type, out_len) ? 1 : 0;
}

// R-07: Auto-accept setting in Core (FFI forwards to manager)
int tim2tox_ffi_set_auto_accept_group_invites(int64_t instance_id, int enabled) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) return 0;
    manager->SetAutoAcceptGroupInvites(enabled != 0);
    return 1;
}

int tim2tox_ffi_get_auto_accept_group_invites(int64_t instance_id) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (!manager) return 0;
    return manager->GetAutoAcceptGroupInvites() ? 1 : 0;
}

// Get count of conferences restored from savedata (for Dart to discover and assign group_ids)
int tim2tox_ffi_get_restored_conference_count(int64_t instance_id) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return -1;
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return -1;
    size_t count = tox_manager->getConferenceListSize();
    return static_cast<int>(count);
}

// Get list of conference numbers restored from savedata
int tim2tox_ffi_get_restored_conference_list(int64_t instance_id, uint32_t* out_list, int max_count) {
    if (!out_list || max_count <= 0) return -1;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return -1;
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return -1;
    size_t count = tox_manager->getConferenceListSize();
    if (count == 0) return 0;
    size_t to_copy = std::min(static_cast<size_t>(max_count), count);
    tox_manager->getConferenceList(out_list, to_copy);
    return static_cast<int>(to_copy);
}

int tim2tox_ffi_rejoin_known_groups(void) {
    if (!IsCurrentInstanceInited()) {
        V2TIM_LOG(kError, "[ffi] rejoin_known_groups: SDK not initialized");
        return 0;
    }
    
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] rejoin_known_groups: manager_impl is null");
        return 0;
    }
    
    manager_impl->RejoinKnownGroups();
    return 1;
}

// Get number of peers in a specific conference
int tim2tox_ffi_get_conference_peer_count(int64_t instance_id, uint32_t conference_number) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return -1;
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return -1;
    Tox* tox = tox_manager->getTox();
    if (!tox) return -1;
    TOX_ERR_CONFERENCE_PEER_QUERY err;
    uint32_t count = tox_conference_peer_count(tox, conference_number, &err);
    if (err != TOX_ERR_CONFERENCE_PEER_QUERY_OK) return -1;
    return static_cast<int>(count);
}

// Get comma-separated hex public keys of all peers in a conference
int tim2tox_ffi_get_conference_peer_pubkeys(int64_t instance_id, uint32_t conference_number, char* out_buf, int buf_size) {
    if (!out_buf || buf_size <= 0) return -1;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return -1;
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return -1;
    Tox* tox = tox_manager->getTox();
    if (!tox) return -1;
    TOX_ERR_CONFERENCE_PEER_QUERY err;
    uint32_t peer_count = tox_conference_peer_count(tox, conference_number, &err);
    if (err != TOX_ERR_CONFERENCE_PEER_QUERY_OK) return -1;

    std::string result;
    int written = 0;
    for (uint32_t i = 0; i < peer_count; i++) {
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
        TOX_ERR_CONFERENCE_PEER_QUERY err_key;
        if (tox_manager->getConferencePeerPublicKey(conference_number, i, pubkey, &err_key) &&
            err_key == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
            if (!result.empty()) result += ',';
            result += ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
            written++;
        }
    }
    if (static_cast<int>(result.size()) >= buf_size) return -1; // buffer too small
    strncpy(out_buf, result.c_str(), buf_size);
    out_buf[buf_size - 1] = '\0';
    return written;
}
} // extern "C"

int tim2tox_ffi_send_group_custom(const char* group_id, const unsigned char* data, int data_len) {
    if (!IsCurrentInstanceInited() || !group_id || !data || data_len <= 0) return 0;
    struct SendCb : public V2TIMSendCallback {
        void OnSuccess(const V2TIMMessage& m) override { V2TIM_LOG(kInfo, "[ffi] SendGroupCustom ok, msgID={}", m.msgID.CString()); }
        void OnError(int code, const V2TIMString& msg) override { V2TIM_LOG(kInfo, "[ffi] SendGroupCustom err {}: {}", code, msg.CString()); }
        void OnProgress(uint32_t) override {}
    } sendcb;
    V2TIMBuffer buffer(data, data_len);
    GetCurrentInstance()->SendGroupCustomMessage(buffer, group_id, V2TIMMessagePriority::V2TIM_PRIORITY_NORMAL, &sendcb);
    return 1;
}

int tim2tox_ffi_send_file(int64_t instance_id, const char* user_id, const char* file_path) {
    int64_t id = (instance_id == 0) ? GetCurrentInstanceId() : instance_id;
    if (!IsInstanceInited(id) || !user_id || !file_path) {
        V2TIM_LOG(kError, "[ffi] send_file: invalid arguments");
        return -1;
    }
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] send_file: manager_impl is null");
        return -1;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[ffi] send_file: tox_manager is null");
        return -1;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[ffi] send_file: tox instance is null");
        return -1;
    }
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE] = {0};
    if (!ToxUtil::tox_hex_to_bytes(user_id, strlen(user_id), pubkey, TOX_PUBLIC_KEY_SIZE)) {
        V2TIM_LOG(kError, "[ffi] send_file: failed to parse user_id");
        return -2;
    }
    TOX_ERR_FRIEND_BY_PUBLIC_KEY err;
    uint32_t friend_no = tox_friend_by_public_key(tox, pubkey, &err);
    if (err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        V2TIM_LOG(kError, "[ffi] send_file: friend {} not found in tox (err={})", user_id, err);
        return -3;
    }
    TOX_ERR_FRIEND_QUERY query_err;
    TOX_CONNECTION friend_conn = tox_friend_get_connection_status(tox, friend_no, &query_err);
    if (query_err != TOX_ERR_FRIEND_QUERY_OK || friend_conn == TOX_CONNECTION_NONE) {
        V2TIM_LOG(kError, "[ffi] send_file: friend {} not connected (err={})", user_id, query_err);
        return -4;
    }
    struct stat st{};
    if (stat(file_path, &st) != 0 || st.st_size <= 0) {
        V2TIM_LOG(kError, "[ffi] send_file: file missing or empty {}", file_path);
        return -5;
    }
    FILE* fp = fopen(file_path, "rb");
    if (!fp) {
        V2TIM_LOG(kError, "[ffi] send_file: fopen failed for {}", file_path);
        return -6;
    }
    std::string path(file_path);
    std::string name = path;
    size_t pos = path.find_last_of("/\\");
    if (pos != std::string::npos) name = path.substr(pos + 1);
    std::string lower_name = name;
    std::string lower_path = path;
    for (char& ch : lower_name) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    for (char& ch : lower_path) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    auto ends_with = [&](const char* suffix) -> bool {
        const size_t suffix_len = std::strlen(suffix);
        const size_t name_len = lower_name.size();
        return name_len >= suffix_len &&
               lower_name.compare(name_len - suffix_len, suffix_len, suffix) == 0;
    };
    const bool is_image = ends_with(".png") || ends_with(".jpg") ||
                          ends_with(".jpeg") || ends_with(".gif") ||
                          ends_with(".webp") || ends_with(".bmp") ||
                          ends_with(".heic");
    const bool avatar_name_pattern =
        (lower_name.rfind("avatar_", 0) == 0) ||
        (lower_name.rfind("self_avatar", 0) == 0) ||
        (lower_name.find("_avatar") != std::string::npos);
    const bool from_avatar_dir =
        (lower_path.find("/avatars/") != std::string::npos) ||
        (lower_path.find("\\avatars\\") != std::string::npos);
    const uint32_t tox_file_kind =
        (is_image && avatar_name_pattern && from_avatar_dir)
            ? TOX_FILE_KIND_AVATAR
            : TOX_FILE_KIND_DATA;
    TOX_ERR_FILE_SEND f_err;
    uint32_t file_no = tox_file_send(
        tox, friend_no, tox_file_kind, (uint64_t)st.st_size, nullptr,
        reinterpret_cast<const uint8_t*>(name.c_str()), name.size(), &f_err);
    if (f_err != TOX_ERR_FILE_SEND_OK) {
        V2TIM_LOG(kError, "[ffi] send_file: tox_file_send failed err={}", f_err);
        fclose(fp);
        return -7;
    }
    {
        std::lock_guard<std::mutex> lk(G.send_mtx);
        uint64_t key = (static_cast<uint64_t>(friend_no) << 32) | file_no;
        G.send_files[instance_id][key] = std::make_pair(fp, static_cast<uint64_t>(st.st_size));
    }
    return 1;
}

int tim2tox_ffi_iterate_current_instance(int count) {
    if (!IsCurrentInstanceInited() || count <= 0) return 0;
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    if (!manager_impl) return 0;
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return 0;
    for (int i = 0; i < count; ++i) {
        tox_manager->iterate(0);
    }
    return 1;
}

// --- Test-mode virtual clock + manual iterate ---------------------------------
// Process-global virtual clock shared by all instances currently in test mode.
// Production callers never touch this; test_mode_ on V2TIMManagerImpl is the
// gate that decides whether mono_time reads from this value.
static std::atomic<uint64_t> g_virtual_time_ms{0};

extern "C" uint64_t tim2tox_virtual_time_cb(void* /*user_data*/) {
    return g_virtual_time_ms.load(std::memory_order_acquire);
}

int tim2tox_ffi_set_virtual_time_ms(uint64_t time_ms) {
    g_virtual_time_ms.store(time_ms, std::memory_order_release);
    return 1;
}

// Defined in V2TIMManagerImpl.cpp.
extern std::atomic<bool> g_default_test_mode;

int tim2tox_ffi_set_default_test_mode(int enabled) {
    g_default_test_mode.store(enabled != 0, std::memory_order_release);
    V2TIM_LOG(kInfo, "[ffi] set_default_test_mode: enabled={}", enabled);
    return 1;
}

int tim2tox_ffi_set_test_mode(int64_t instance_id, int enabled) {
    V2TIMManagerImpl* impl = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_test_instances_mutex);
        auto it = g_test_instances.find(instance_id);
        if (it == g_test_instances.end()) {
            V2TIM_LOG(kError, "[ffi] set_test_mode: instance {} not found", (long long)instance_id);
            return 0;
        }
        impl = it->second;
    }
    if (!impl) return 0;
    impl->setTestMode(enabled != 0);
    V2TIM_LOG(kInfo, "[ffi] set_test_mode: instance_id={}, enabled={}", (long long)instance_id, enabled);
    return 1;
}

int tim2tox_ffi_iterate_instance(int64_t instance_id) {
    V2TIMManagerImpl* impl = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_test_instances_mutex);
        auto it = g_test_instances.find(instance_id);
        if (it != g_test_instances.end()) impl = it->second;
    }
    if (!impl) return 0;
    // Drain task_queue first: in test mode there is no event_thread, so
    // PostToEventThread tasks (signaling dispatch etc.) only run when the
    // Dart-side tick loop pumps them through here.
    impl->DrainTaskQueue();
    ToxManager* tm = impl->GetToxManager();
    if (!tm || tm->isShuttingDown()) return 0;
    tm->iterate(0);
    // Iterate-driven signaling timeout dispatch. In test mode the deadline is
    // measured against the virtual clock, so OnInvitationTimeout fires when
    // pumpTestTick has advanced enough virtual ms — no wall-clock dependency.
    {
        V2TIMSignalingManager* sig = impl->GetSignalingManager();
        if (sig) {
            static_cast<V2TIMSignalingManagerImpl*>(sig)->CheckTimeouts();
        }
    }
    return 1;
}

int tim2tox_ffi_iterate_all_instances(int count) {
    if (!IsCurrentInstanceInited() || count <= 0) return 0;
    std::vector<V2TIMManagerImpl*> copy;
    {
        std::lock_guard<std::mutex> lock(g_test_instances_mutex);
        copy.reserve(g_test_instances.size());
        for (const auto& kv : g_test_instances) {
            if (kv.second) copy.push_back(kv.second);
        }
    }
    if (copy.empty()) return 0;
    for (int round = 0; round < count; ++round) {
        for (V2TIMManagerImpl* manager : copy) {
            ToxManager* tox_manager = manager->GetToxManager();
            if (tox_manager && !tox_manager->isShuttingDown())
                tox_manager->iterate(0);
        }
    }
    return static_cast<int>(copy.size());
}

int tim2tox_ffi_get_self_connection_status(void) {
    if (!IsCurrentInstanceInited()) return 0;
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    if (!manager_impl) return 0;
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) return 0;
    Tox* tox = tox_manager->getTox();
    if (!tox) return 0;
    TOX_CONNECTION status = tox_self_get_connection_status(tox);
    return (int)status;
}

int tim2tox_ffi_get_udp_port(int64_t instance_id) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] get_udp_port: instance_id={} V2TIMManagerImpl instance is null", (long long)instance_id);
        return 0;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[ffi] get_udp_port: ToxManager instance is null");
        return 0;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[ffi] get_udp_port: Tox instance is null");
        return 0;
    }
    
    Tox_Err_Get_Port err;
    uint16_t port = tox_self_get_udp_port(tox, &err);

    if (err != TOX_ERR_GET_PORT_OK) {
        V2TIM_LOG(kError, "[ffi] get_udp_port: instance_id={} error {} (TOX_ERR_GET_PORT_OK={}, TOX_ERR_GET_PORT_NOT_BOUND={})",
                  (long long)instance_id, err, TOX_ERR_GET_PORT_OK, TOX_ERR_GET_PORT_NOT_BOUND);
        return 0;
    }

    V2TIM_LOG(kInfo, "[Bootstrap] get_udp_port instance_id={} port={}", (long long)instance_id, (unsigned)port);
    return (int)port;
}

int tim2tox_ffi_get_dht_id(char* out_dht_id, int out_len) {
    if (!out_dht_id || out_len < 65) return 0;
    // Get ToxManager from current V2TIMManagerImpl instance
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] get_dht_id: V2TIMManagerImpl instance is null");
        return 0;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[ffi] get_dht_id: ToxManager instance is null");
        return 0;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[ffi] get_dht_id: Tox instance is null");
        return 0;
    }
    
    uint8_t dht_id[TOX_PUBLIC_KEY_SIZE];
    tox_self_get_dht_id(tox, dht_id);
    
    // Convert to hex string
    std::string dht_id_hex = ToxUtil::tox_bytes_to_hex(dht_id, TOX_PUBLIC_KEY_SIZE);
    
    if (dht_id_hex.length() >= (size_t)out_len) {
        V2TIM_LOG(kError, "[ffi] get_dht_id: buffer too small (need {}, got {})", dht_id_hex.length(), out_len);
        return 0;
    }
    
    strncpy(out_dht_id, dht_id_hex.c_str(), out_len - 1);
    out_dht_id[out_len - 1] = '\0';
    
    return (int)dht_id_hex.length();
}

int tim2tox_ffi_add_bootstrap_node(int64_t instance_id, const char* host, int port, const char* public_key_hex) {
    if (!host || !public_key_hex) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] add_bootstrap_node: instance_id={} V2TIMManagerImpl instance is null", (long long)instance_id);
        return 0;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[ffi] add_bootstrap_node: ToxManager instance is null");
        return 0;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[ffi] add_bootstrap_node: Tox instance is null");
        return 0;
    }
    
    uint8_t key_bin[TOX_PUBLIC_KEY_SIZE];
    if (!ToxUtil::tox_hex_to_bytes(public_key_hex, strlen(public_key_hex), key_bin, TOX_PUBLIC_KEY_SIZE)) {
        V2TIM_LOG(kError, "[ffi] add_bootstrap_node: Failed to convert public key hex");
        return 0;
    }
    
    // Add bootstrap node
    // Reference: c-toxcore's tox_node_bootstrap only calls tox_bootstrap
    // We also add TCP relay for better connectivity
    Tox_Err_Bootstrap bootstrap_err;
    bool bootstrap_ok = tox_bootstrap(tox, host, (uint16_t)port, key_bin, &bootstrap_err);
    if (!bootstrap_ok || bootstrap_err != TOX_ERR_BOOTSTRAP_OK) {
        V2TIM_LOG(kError, "[ffi] add_bootstrap_node: tox_bootstrap failed with error {}", bootstrap_err);
        // Continue anyway, as TCP relay might still work
    }
    
    // Add TCP relay on same port (helps with connectivity)
    Tox_Err_Bootstrap relay_err;
    tox_add_tcp_relay(tox, host, (uint16_t)port, key_bin, &relay_err);
    // Try common alternate ports
    tox_add_tcp_relay(tox, host, 443, key_bin, nullptr);
    tox_add_tcp_relay(tox, host, 3389, key_bin, nullptr);
    
    V2TIM_LOG(kInfo, "[Bootstrap] add_bootstrap_node instance_id={} host={} port={} bootstrap_ok={} err={} (0=OK)",
            (long long)instance_id, host, port, bootstrap_ok ? 1 : 0, bootstrap_err);

    return bootstrap_ok ? 1 : 0;
}

// Flutter SDK binding functions
// These functions are called by Flutter SDK's native binding layer
// They need to be exported from the dynamic library

extern "C" {
// Note: Dart* functions (DartInitSDK, DartDeleteFromFriendList, DartFindMessages, etc.)
// are now implemented in dart_compat_layer.cpp to avoid duplicate symbols.
// The old implementations have been removed from this file.

int tim2tox_ffi_file_control(int64_t instance_id, const char* user_id, uint32_t file_number, int control) {
    int64_t id = (instance_id == 0) ? GetCurrentInstanceId() : instance_id;
    if (!IsInstanceInited(id) || !user_id) {
        V2TIM_LOG(kError, "[ffi] file_control: invalid arguments");
        return -1;
    }
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] file_control: manager_impl is null");
        return -1;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[ffi] file_control: tox_manager is null");
        return -1;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[ffi] file_control: tox instance is null");
        return -1;
    }
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE] = {0};
    if (!ToxUtil::tox_hex_to_bytes(user_id, strlen(user_id), pubkey, TOX_PUBLIC_KEY_SIZE)) {
        V2TIM_LOG(kError, "[ffi] file_control: failed to parse user_id");
        return -2;
    }
    TOX_ERR_FRIEND_BY_PUBLIC_KEY err;
    uint32_t friend_no = tox_friend_by_public_key(tox, pubkey, &err);
    if (err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        V2TIM_LOG(kError, "[ffi] file_control: friend {} not found (err={})", user_id, err);
        return -2;
    }
    // Map control value to TOX_FILE_CONTROL
    TOX_FILE_CONTROL tox_control;
    switch (control) {
        case 0: tox_control = TOX_FILE_CONTROL_RESUME; break;
        case 1: tox_control = TOX_FILE_CONTROL_PAUSE; break;
        case 2: tox_control = TOX_FILE_CONTROL_CANCEL; break;
        default:
            V2TIM_LOG(kError, "[ffi] file_control: invalid control value {}", control);
            return -1;
    }
    TOX_ERR_FILE_CONTROL f_err;
    bool success = tox_file_control(tox, friend_no, file_number, tox_control, &f_err);
    if (!success) {
        V2TIM_LOG(kError, "[ffi] file_control: tox_file_control failed (err={}) for friend={}, file={}, control={}", f_err, friend_no, file_number, control);
        return -4;
    }
    V2TIM_LOG(kInfo, "[ffi] file_control: tox_file_control succeeded for friend={}, file={}, control={} (TOX_FILE_CONTROL_RESUME={})",
              friend_no, file_number, control, TOX_FILE_CONTROL_RESUME);
    // If accepting (RESUME), open file for writing
    if (control == 0) { // RESUME
        uint64_t key = (static_cast<uint64_t>(friend_no) << 32) | file_number;
        std::lock_guard<std::mutex> lk(G.send_mtx);
        auto instance_it = G.recv_files.find(instance_id);
        if (instance_it != G.recv_files.end()) {
            auto it = instance_it->second.find(key);
            if (it != instance_it->second.end() && it->second.fp == nullptr) {
                // Ensure directory exists before opening file (use configured directory)
                std::string dir = G.file_recv_dir;
                int mkdir_result = tim2tox_mkdir(dir.c_str(), 0755);
                if (mkdir_result != 0 && errno != EEXIST) {
                    V2TIM_LOG(kError, "[ffi] file_control: failed to create directory {} (errno: {})", dir, errno);
                }
                // File request was stored but not accepted yet - open file now
                FILE* fp = fopen(it->second.path.c_str(), "wb");
                if (fp) {
                    it->second.fp = fp;
                    V2TIM_LOG(kInfo, "[ffi] file_control: successfully opened file {}", it->second.path);
                } else {
                    V2TIM_LOG(kError, "[ffi] file_control: failed to open file {} (errno: {})", it->second.path, errno);
                    // Try to create parent directory if it doesn't exist
                    std::string::size_type last_slash = it->second.path.find_last_of('/');
                    if (last_slash != std::string::npos) {
                        std::string parent_dir = it->second.path.substr(0, last_slash);
                        if (!parent_dir.empty()) {
                            mkdir_result = tim2tox_mkdir(parent_dir.c_str(), 0755);
                            if (mkdir_result == 0 || errno == EEXIST) {
                                // Retry opening file after creating parent directory
                                fp = fopen(it->second.path.c_str(), "wb");
                                if (fp) {
                                    it->second.fp = fp;
                                    V2TIM_LOG(kInfo, "[ffi] file_control: successfully opened file after creating parent directory: {}", it->second.path);
                                } else {
                                    V2TIM_LOG(kError, "[ffi] file_control: still failed to open file after creating parent directory (errno: {}): {}", errno, it->second.path);
                                }
                            } else {
                                V2TIM_LOG(kError, "[ffi] file_control: failed to create parent directory (errno: {}): {}", errno, parent_dir);
                            }
                        }
                    } else {
                        V2TIM_LOG(kError, "[ffi] file_control: no parent directory found in path: {}", it->second.path);
                    }
                }
            }
        }
    }
    if (control == 2) { // CANCEL
        // Clean up file context
        uint64_t key = (static_cast<uint64_t>(friend_no) << 32) | file_number;
        std::lock_guard<std::mutex> lk(G.send_mtx);
        auto instance_it = G.recv_files.find(instance_id);
        if (instance_it != G.recv_files.end()) {
            auto it = instance_it->second.find(key);
            if (it != instance_it->second.end()) {
                if (it->second.fp) {
                    fclose(it->second.fp);
                }
                // Remove file if it exists
                unlink(it->second.path.c_str());
                instance_it->second.erase(it);
            }
        }
    }
    return 1; // success
}

int tim2tox_ffi_set_file_recv_dir(const char* dir_path) {
    if (!dir_path) return 0;
    G.file_recv_dir = std::string(dir_path);
    // Ensure directory exists
    int mkdir_result = tim2tox_mkdir(G.file_recv_dir.c_str(), 0755);
    if (mkdir_result != 0 && errno != EEXIST) {
        V2TIM_LOG(kError, "[ffi] set_file_recv_dir: failed to create directory {} (errno: {})", G.file_recv_dir.c_str(), errno);
        return 0;
    }
    V2TIM_LOG(kInfo, "[ffi] set_file_recv_dir: set to {}", G.file_recv_dir.c_str());
    return 1;
}

void tim2tox_ffi_set_log_file(const char* path) {
    if (!path) return;
    V2TIMLog::getInstance().setLogFile(path);
    V2TIMLog::getInstance().enableConsoleOutput(false);
}

// IRC Dynamic Library Management Functions
int tim2tox_ffi_irc_load_library(const char* library_path) {
    std::lock_guard<std::mutex> lock(g_irc_lib_mutex);
    
    if (g_irc_lib_loaded) {
        V2TIM_LOG(kInfo, "[ffi] IRC library already loaded");
        return 1;
    }
    
    if (!library_path) {
        V2TIM_LOG(kError, "[ffi] irc_load_library: library_path is null");
        return 0;
    }
    
    V2TIM_LOG(kInfo, "[ffi] Loading IRC library from: {}", library_path);
    
    void* handle = dlopen(library_path, RTLD_LAZY);
    if (!handle) {
        V2TIM_LOG(kError, "[ffi] Failed to load IRC library: {}", dlerror());
        return 0;
    }
    
    // Load function symbols
    g_irc_init = (irc_init_t)dlsym(handle, "irc_client_init");
    g_irc_shutdown = (irc_shutdown_t)dlsym(handle, "irc_client_shutdown");
    g_irc_connect_channel = (irc_connect_channel_t)dlsym(handle, "irc_client_connect_channel");
    g_irc_disconnect_channel = (irc_disconnect_channel_t)dlsym(handle, "irc_client_disconnect_channel");
    g_irc_send_message = (irc_send_message_t)dlsym(handle, "irc_client_send_message");
    g_irc_is_connected = (irc_is_connected_t)dlsym(handle, "irc_client_is_connected");
    g_irc_set_message_callback = (irc_set_message_callback_t)dlsym(handle, "irc_client_set_message_callback");
    g_irc_set_tox_message_callback = (irc_set_tox_message_callback_t)dlsym(handle, "irc_client_set_tox_message_callback");
    g_irc_forward_tox_message = (irc_forward_tox_message_t)dlsym(handle, "irc_client_forward_tox_message");
    
    // Check required symbols (new callbacks are optional)
    if (!g_irc_init || !g_irc_shutdown || !g_irc_connect_channel || !g_irc_disconnect_channel || 
        !g_irc_send_message || !g_irc_is_connected || !g_irc_set_message_callback || !g_irc_set_tox_message_callback || !g_irc_forward_tox_message) {
        V2TIM_LOG(kError, "[ffi] Failed to load required IRC library symbols: {}", dlerror());
        dlclose(handle);
        return 0;
    }
    
    // New callbacks are optional - log warning if not found but continue
    
    g_irc_lib_handle = handle;
    
    // Initialize library
    if (g_irc_init() != 1) {
        V2TIM_LOG(kError, "[ffi] Failed to initialize IRC library");
        dlclose(handle);
        g_irc_lib_handle = nullptr;
        return 0;
    }
    
    // Set up callbacks
    g_irc_set_message_callback([](const char* group_id, const char* sender_nick, const char* message, void* user_data) {
        // Send message to Tox group via V2TIMManager
        V2TIMManagerImpl* manager_impl = GetCurrentInstance();
        V2TIMManager* manager = manager_impl;
        if (!manager) return;
        
        V2TIMString groupID(group_id);
        V2TIMString text(message);
        
        // Send message to group (async, no callback needed)
        manager->SendGroupTextMessage(text, groupID, V2TIM_PRIORITY_NORMAL, nullptr);
        
        V2TIM_LOG(kInfo, "[ffi] IRC message forwarded to Tox group {}: {}: {}", 
                group_id, sender_nick, message);
    }, nullptr);
    
    // Note: tox_message_callback is not needed here because forwarding happens
    // directly in IrcClientManager::onToxGroupMessage which is called from V2TIMManagerImpl
    // We just need to ensure the library is loaded and initialized
    
    // Set up connection status, user list, and join/part callbacks
    // These will be set from Flutter layer via FFI functions
    
    g_irc_lib_loaded = true;
    V2TIM_LOG(kInfo, "[ffi] IRC library loaded successfully");
    
    return 1;
}

int tim2tox_ffi_irc_unload_library(void) {
    std::lock_guard<std::mutex> lock(g_irc_lib_mutex);
    
    if (!g_irc_lib_loaded) {
        return 1; // Already unloaded
    }
    
    if (g_irc_shutdown) {
        g_irc_shutdown();
    }
    
    if (g_irc_lib_handle) {
        dlclose(g_irc_lib_handle);
        g_irc_lib_handle = nullptr;
    }
    
    // Clear function pointers
    g_irc_init = nullptr;
    g_irc_shutdown = nullptr;
    g_irc_connect_channel = nullptr;
    g_irc_disconnect_channel = nullptr;
    g_irc_send_message = nullptr;
    g_irc_is_connected = nullptr;
    g_irc_set_message_callback = nullptr;
    g_irc_set_tox_message_callback = nullptr;
    g_irc_forward_tox_message = nullptr;
    g_irc_set_connection_status_callback = nullptr;
    g_irc_set_user_list_callback = nullptr;
    g_irc_set_user_join_part_callback = nullptr;
    
    g_irc_lib_loaded = false;
    V2TIM_LOG(kInfo, "[ffi] IRC library unloaded");
    
    return 1;
}

int tim2tox_ffi_irc_is_library_loaded(void) {
    std::lock_guard<std::mutex> lock(g_irc_lib_mutex);
    return g_irc_lib_loaded ? 1 : 0;
}

// IRC Channel Management Functions (delegate to dynamic library)
int tim2tox_ffi_irc_connect_channel(const char* server, int port, const char* channel, const char* password, const char* group_id, const char* sasl_username, const char* sasl_password, int use_ssl, const char* custom_nickname) {
    std::lock_guard<std::mutex> lock(g_irc_lib_mutex);
    if (!g_irc_lib_loaded || !g_irc_connect_channel) {
        V2TIM_LOG(kError, "[ffi] IRC library not loaded");
        return 0;
    }
    return g_irc_connect_channel(server, port, channel, password, group_id, sasl_username, sasl_password, use_ssl, custom_nickname);
}

int tim2tox_ffi_irc_disconnect_channel(const char* channel) {
    std::lock_guard<std::mutex> lock(g_irc_lib_mutex);
    if (!g_irc_lib_loaded || !g_irc_disconnect_channel) {
        return 0;
    }
    return g_irc_disconnect_channel(channel);
}

int tim2tox_ffi_irc_send_message(const char* channel, const char* message) {
    std::lock_guard<std::mutex> lock(g_irc_lib_mutex);
    if (!g_irc_lib_loaded || !g_irc_send_message) {
        return 0;
    }
    return g_irc_send_message(channel, message);
}

int tim2tox_ffi_irc_is_connected(const char* channel) {
    std::lock_guard<std::mutex> lock(g_irc_lib_mutex);
    if (!g_irc_lib_loaded || !g_irc_is_connected) {
        return 0;
    }
    return g_irc_is_connected(channel);
}

int tim2tox_ffi_irc_forward_tox_message(const char* group_id, const char* sender, const char* message) {
    std::lock_guard<std::mutex> lock(g_irc_lib_mutex);
    if (!g_irc_lib_loaded || !g_irc_forward_tox_message) {
        return 0; // Library not loaded
    }
    return g_irc_forward_tox_message(group_id, sender, message);
}

// ============================================================================
// Signaling (Call Invitation) Implementation
// ============================================================================

namespace {
    // Signaling callback storage
    struct SignalingCallbacks {
        tim2tox_signaling_invitation_callback_t on_invitation = nullptr;
        tim2tox_signaling_cancel_callback_t on_cancel = nullptr;
        tim2tox_signaling_accept_callback_t on_accept = nullptr;
        tim2tox_signaling_reject_callback_t on_reject = nullptr;
        tim2tox_signaling_timeout_callback_t on_timeout = nullptr;
        void* user_data = nullptr;
    } g_signaling_callbacks;
    std::mutex g_signaling_callbacks_mutex;
    
    // Signaling listener implementation
    class SignalingListenerImpl : public V2TIMSignalingListener {
    public:
        void OnReceiveNewInvitation(const V2TIMString& inviteID, const V2TIMString& inviter,
                                     const V2TIMString& groupID, const V2TIMStringVector& inviteeList,
                                     const V2TIMString& data) override {
            std::lock_guard<std::mutex> lock(g_signaling_callbacks_mutex);
            if (g_signaling_callbacks.on_invitation) {
                g_signaling_callbacks.on_invitation(
                    inviteID.CString(), inviter.CString(), groupID.CString(),
                    data.CString(), g_signaling_callbacks.user_data);
            }
        }
        
        void OnInvitationCancelled(const V2TIMString& inviteID, const V2TIMString& inviter,
                                    const V2TIMString& data) override {
            std::lock_guard<std::mutex> lock(g_signaling_callbacks_mutex);
            if (g_signaling_callbacks.on_cancel) {
                g_signaling_callbacks.on_cancel(
                    inviteID.CString(), inviter.CString(), data.CString(),
                    g_signaling_callbacks.user_data);
            }
        }
        
        void OnInviteeAccepted(const V2TIMString& inviteID, const V2TIMString& invitee,
                                const V2TIMString& data) override {
            std::lock_guard<std::mutex> lock(g_signaling_callbacks_mutex);
            if (g_signaling_callbacks.on_accept) {
                g_signaling_callbacks.on_accept(
                    inviteID.CString(), invitee.CString(), data.CString(),
                    g_signaling_callbacks.user_data);
            }
        }
        
        void OnInviteeRejected(const V2TIMString& inviteID, const V2TIMString& invitee,
                                const V2TIMString& data) override {
            std::lock_guard<std::mutex> lock(g_signaling_callbacks_mutex);
            if (g_signaling_callbacks.on_reject) {
                g_signaling_callbacks.on_reject(
                    inviteID.CString(), invitee.CString(), data.CString(),
                    g_signaling_callbacks.user_data);
            }
        }
        
        void OnInvitationTimeout(const V2TIMString& inviteID, const V2TIMStringVector& inviteeList) override {
            std::lock_guard<std::mutex> lock(g_signaling_callbacks_mutex);
            if (g_signaling_callbacks.on_timeout) {
                // Get inviter from active invites if available
                // For simplicity, we'll pass empty string if not found
                g_signaling_callbacks.on_timeout(
                    inviteID.CString(), "", g_signaling_callbacks.user_data);
            }
        }
    };
    
    SignalingListenerImpl g_tim2tox_signaling_listener;  // Renamed to avoid conflict with dart_compat_utils.cpp
}

int tim2tox_ffi_signaling_add_listener(
    tim2tox_signaling_invitation_callback_t on_invitation,
    tim2tox_signaling_cancel_callback_t on_cancel,
    tim2tox_signaling_accept_callback_t on_accept,
    tim2tox_signaling_reject_callback_t on_reject,
    tim2tox_signaling_timeout_callback_t on_timeout,
    void* user_data) {
    
    if (!IsCurrentInstanceInited()) return 0;
    
    std::lock_guard<std::mutex> lock(g_signaling_callbacks_mutex);
    g_signaling_callbacks.on_invitation = on_invitation;
    g_signaling_callbacks.on_cancel = on_cancel;
    g_signaling_callbacks.on_accept = on_accept;
    g_signaling_callbacks.on_reject = on_reject;
    g_signaling_callbacks.on_timeout = on_timeout;
    g_signaling_callbacks.user_data = user_data;
    
    auto* signaling_mgr = GetCurrentInstance()->GetSignalingManager();
    if (signaling_mgr) {
        signaling_mgr->AddSignalingListener(&g_tim2tox_signaling_listener);
        return 1;
    }
    return 0;
}

void tim2tox_ffi_signaling_remove_listener(void) {
    if (!IsCurrentInstanceInited()) return;
    
    auto* signaling_mgr = GetCurrentInstance()->GetSignalingManager();
    if (signaling_mgr) {
        signaling_mgr->RemoveSignalingListener(&g_tim2tox_signaling_listener);
    }
    
    std::lock_guard<std::mutex> lock(g_signaling_callbacks_mutex);
    g_signaling_callbacks = SignalingCallbacks();
}

int tim2tox_ffi_signaling_invite(const char* invitee, const char* data, int online_user_only, int timeout, char* out_invite_id, int out_invite_id_len) {
    V2TIM_LOG(kInfo, "[ffi] signaling_invite: called with invitee={}, data={}, timeout={}",
              invitee ? invitee : "(null)", data ? data : "(null)", timeout);

    if (!IsCurrentInstanceInited()) {
        V2TIM_LOG(kError, "[ffi] signaling_invite: current instance not inited");
        return 0;
    }

    if (!invitee || !out_invite_id || out_invite_id_len < 1) {
        V2TIM_LOG(kError, "[ffi] signaling_invite: invalid parameters (invitee={}, out_invite_id={}, len={})",
                  (void*)invitee, (void*)out_invite_id, out_invite_id_len);
        return 0;
    }

    auto* signaling_mgr = GetCurrentInstance()->GetSignalingManager();
    if (!signaling_mgr) {
        V2TIM_LOG(kError, "[ffi] signaling_invite: signaling manager is null");
        return 0;
    }
    
    V2TIMString invitee_str(invitee);
    V2TIMString data_str(data ? data : "");
    V2TIMOfflinePushInfo offline_push;
    
    class CallbackImpl : public V2TIMCallback {
    public:
        bool success = false;
        int error_code = 0;
        V2TIMString error_desc;
        void OnSuccess() override {
            success = true;
            V2TIM_LOG(kInfo, "[ffi] signaling_invite: callback OnSuccess");
        }
        void OnError(int code, const V2TIMString& desc) override {
            success = false;
            error_code = code;
            error_desc = desc;
            V2TIM_LOG(kError, "[ffi] signaling_invite: callback OnError code={}, desc={}", code, desc.CString());
        }
    } callback;

    V2TIM_LOG(kInfo, "[ffi] signaling_invite: calling signaling_mgr->Invite");

    V2TIMString invite_id = signaling_mgr->Invite(invitee_str, data_str, online_user_only != 0, offline_push, timeout, &callback);

    V2TIM_LOG(kInfo, "[ffi] signaling_invite: Invite returned invite_id='{}' (length={}), callback.success={}",
              invite_id.CString(), invite_id.Length(), callback.success ? 1 : 0);

    if (invite_id.Length() > 0 && callback.success) {
        int len = std::min((int)invite_id.Length(), out_invite_id_len - 1);
        memcpy(out_invite_id, invite_id.CString(), len);
        out_invite_id[len] = '\0';
        V2TIM_LOG(kInfo, "[ffi] signaling_invite: success, returning invite_id='{}'", out_invite_id);
        return 1;
    } else {
        V2TIM_LOG(kError, "[ffi] signaling_invite: failed - invite_id empty or callback failed");
    }
    return 0;
}

int tim2tox_ffi_signaling_invite_in_group(const char* group_id, const char* invitee_list, const char* data, int online_user_only, int timeout, char* out_invite_id, int out_invite_id_len) {
    if (!IsCurrentInstanceInited() || !group_id || !invitee_list || !out_invite_id || out_invite_id_len < 1) return 0;
    
    auto* signaling_mgr = GetCurrentInstance()->GetSignalingManager();
    if (!signaling_mgr) return 0;
    
    V2TIMString group_id_str(group_id);
    V2TIMString data_str(data ? data : "");
    
    // Parse comma-separated invitee list
    V2TIMStringVector invitee_vec;
    std::string invitee_str(invitee_list);
    size_t pos = 0;
    while (pos < invitee_str.length()) {
        size_t comma = invitee_str.find(',', pos);
        if (comma == std::string::npos) comma = invitee_str.length();
        std::string user_id = invitee_str.substr(pos, comma - pos);
        if (!user_id.empty()) {
            invitee_vec.PushBack(V2TIMString(user_id.c_str()));
        }
        pos = comma + 1;
    }
    
    class CallbackImpl : public V2TIMCallback {
    public:
        bool success = false;
        void OnSuccess() override { success = true; }
        void OnError(int code, const V2TIMString& desc) override { success = false; }
    } callback;
    
    V2TIMString invite_id = signaling_mgr->InviteInGroup(group_id_str, invitee_vec, data_str, online_user_only != 0, timeout, &callback);
    
    if (invite_id.Length() > 0 && callback.success) {
        int len = std::min((int)invite_id.Length(), out_invite_id_len - 1);
        memcpy(out_invite_id, invite_id.CString(), len);
        out_invite_id[len] = '\0';
        return 1;
    }
    return 0;
}

int tim2tox_ffi_signaling_cancel(const char* invite_id, const char* data) {
    if (!IsCurrentInstanceInited() || !invite_id) return 0;
    
    auto* signaling_mgr = GetCurrentInstance()->GetSignalingManager();
    if (!signaling_mgr) return 0;
    
    V2TIMString invite_id_str(invite_id);
    V2TIMString data_str(data ? data : "");
    
    class CallbackImpl : public V2TIMCallback {
    public:
        bool success = false;
        void OnSuccess() override { success = true; }
        void OnError(int code, const V2TIMString& desc) override { success = false; }
    } callback;
    
    signaling_mgr->Cancel(invite_id_str, data_str, &callback);
    return callback.success ? 1 : 0;
}

int tim2tox_ffi_signaling_accept(const char* invite_id, const char* data) {
    if (!IsCurrentInstanceInited() || !invite_id) return 0;
    
    auto* signaling_mgr = GetCurrentInstance()->GetSignalingManager();
    if (!signaling_mgr) return 0;
    
    V2TIMString invite_id_str(invite_id);
    V2TIMString data_str(data ? data : "");
    
    class CallbackImpl : public V2TIMCallback {
    public:
        bool success = false;
        void OnSuccess() override { success = true; }
        void OnError(int code, const V2TIMString& desc) override { success = false; }
    } callback;
    
    signaling_mgr->Accept(invite_id_str, data_str, &callback);
    return callback.success ? 1 : 0;
}

int tim2tox_ffi_signaling_reject(const char* invite_id, const char* data) {
    if (!IsCurrentInstanceInited() || !invite_id) return 0;
    
    auto* signaling_mgr = GetCurrentInstance()->GetSignalingManager();
    if (!signaling_mgr) return 0;
    
    V2TIMString invite_id_str(invite_id);
    V2TIMString data_str(data ? data : "");
    
    class CallbackImpl : public V2TIMCallback {
    public:
        bool success = false;
        void OnSuccess() override { success = true; }
        void OnError(int code, const V2TIMString& desc) override { success = false; }
    } callback;
    
    signaling_mgr->Reject(invite_id_str, data_str, &callback);
    return callback.success ? 1 : 0;
}

// ============================================================================
// Audio/Video (ToxAV) Implementation
// ============================================================================

#ifdef BUILD_TOXAV

namespace {
    // AV callback storage per instance
    struct AVCallbacks {
        tim2tox_av_call_callback_t on_call = nullptr;
        tim2tox_av_call_state_callback_t on_call_state = nullptr;
        tim2tox_av_audio_receive_callback_t on_audio_receive = nullptr;
        tim2tox_av_video_receive_callback_t on_video_receive = nullptr;
        tim2tox_av_audio_bitrate_callback_t on_audio_bitrate = nullptr;
        tim2tox_av_video_bitrate_callback_t on_video_bitrate = nullptr;
        void* user_data = nullptr;
    };
    
    // Map instance ID to callbacks (for multi-instance support)
    std::unordered_map<int64_t, AVCallbacks> g_instance_av_callbacks;
    std::mutex g_av_callbacks_mutex;
    
    // Track which instances have initialized ToxAV
    std::unordered_set<int64_t> g_av_initialized_instances;
    
    static AVCallbacks* GetCallbacksForInstance(int64_t instance_id) {
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        auto it = g_instance_av_callbacks.find(instance_id);
        if (it == g_instance_av_callbacks.end()) {
            g_instance_av_callbacks[instance_id] = AVCallbacks();
            it = g_instance_av_callbacks.find(instance_id);
        }
        return &it->second;
    }
    // Helper to get callbacks for current instance
    AVCallbacks* GetCurrentInstanceCallbacks() {
        int64_t instance_id = GetCurrentInstanceId();
        return GetCallbacksForInstance(instance_id);
    }
}

int tim2tox_ffi_av_initialize(int64_t instance_id) {
    int64_t id = (instance_id == 0) ? GetCurrentInstanceId() : instance_id;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_initialize() called, instance_id={}, inited={}", (long long)id, IsInstanceInited(id) ? 1 : 0);
    bool inited = IsInstanceInited(id);
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_initialize() IsCurrentInstanceInited() returned {}", inited ? 1 : 0);
    if (!inited) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_initialize() failed: instance not inited");
        return 0;
    }
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_initialize() instance_id={}", (long long)instance_id);
    
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) != g_av_initialized_instances.end()) {
            V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_initialize() instance {} already initialized, returning 1", (long long)instance_id);
            return 1;
        }
    }
    
    try {
        V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_initialize() initializing ToxAVManager for instance {}", (long long)instance_id);
        
        V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
        if (!manager_impl) {
            V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_initialize() GetInstanceFromId() returned null");
            return 0;
        }
        
        // Get per-instance ToxAVManager (may create ToxAVManager on first access)
        ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
        if (!av_mgr) {
            V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_initialize() GetToxAVManager() returned null");
            return 0;
        }
        
        // Pass manager_impl so ToxAVManager does not call GetCurrentInstance() again (avoids multi-instance race/segfault)
        av_mgr->initialize(manager_impl);
        
        // Set up callbacks (capture instance_id for routing)
        int64_t captured_instance_id = instance_id;
        av_mgr->setCallCallback([captured_instance_id](uint32_t friend_number, bool audio_enabled, bool video_enabled) {
            V2TIM_LOG(kInfo, "[ffi] ToxAV on_call callback: instance_id={}, friend_number={}, audio={}, video={} (posting to Dart)",
                      (long long)captured_instance_id, friend_number, audio_enabled ? 1 : 0, video_enabled ? 1 : 0);
            std::map<std::string, std::string> fields;
            fields["friend_number"] = std::to_string(friend_number);
            fields["audio_enabled"] = audio_enabled ? "1" : "0";
            fields["video_enabled"] = video_enabled ? "1" : "0";
            std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ToxAVCall, fields, "", captured_instance_id);
            SendCallbackToDart("globalCallback", json_msg, nullptr);
        });
        
        av_mgr->setCallStateCallback([captured_instance_id](uint32_t friend_number, uint32_t state) {
            V2TIM_LOG(kInfo, "[ffi] ToxAV on_call_state callback: instance_id={}, friend_number={}, state={} (posting to Dart)",
                      (long long)captured_instance_id, friend_number, state);
            std::map<std::string, std::string> fields;
            fields["friend_number"] = std::to_string(friend_number);
            fields["state"] = std::to_string(state);
            std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ToxAVCallState, fields, "", captured_instance_id);
            SendCallbackToDart("globalCallback", json_msg, nullptr);
        });
        
        av_mgr->setAudioReceiveFrameCallback([captured_instance_id](uint32_t friend_number, const int16_t* pcm, size_t sample_count, uint8_t channels, uint32_t sampling_rate) {
            std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
            auto it = g_instance_av_callbacks.find(captured_instance_id);
            if (it != g_instance_av_callbacks.end() && it->second.on_audio_receive) {
                it->second.on_audio_receive(friend_number, pcm, sample_count, channels, sampling_rate, it->second.user_data);
            }
        });
        
        av_mgr->setVideoReceiveFrameCallback([captured_instance_id](uint32_t friend_number, uint16_t width, uint16_t height, const uint8_t* y, const uint8_t* u, const uint8_t* v) {
            std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
            auto it = g_instance_av_callbacks.find(captured_instance_id);
            if (it != g_instance_av_callbacks.end() && it->second.on_video_receive) {
                it->second.on_video_receive(friend_number, width, height, y, u, v, it->second.user_data);
            }
        });

        // Bitrate-change suggestions from c-toxcore. These fire when the peer
        // requests a different audio/video bit rate (e.g. on congestion or
        // when audio/video is toggled). Dispatch via the same direct
        // function-pointer pattern as the receive callbacks — we do NOT want
        // these queued through SendCallbackToDart because Dart-side handlers
        // are cheap and we want to reflect quality changes promptly.
        av_mgr->setAudioBitrateCallback([captured_instance_id](uint32_t friend_number, uint32_t audio_bit_rate) {
            std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
            auto it = g_instance_av_callbacks.find(captured_instance_id);
            if (it != g_instance_av_callbacks.end() && it->second.on_audio_bitrate) {
                it->second.on_audio_bitrate(friend_number, audio_bit_rate, it->second.user_data);
            }
        });

        av_mgr->setVideoBitrateCallback([captured_instance_id](uint32_t friend_number, uint32_t video_bit_rate) {
            std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
            auto it = g_instance_av_callbacks.find(captured_instance_id);
            if (it != g_instance_av_callbacks.end() && it->second.on_video_bitrate) {
                it->second.on_video_bitrate(friend_number, video_bit_rate, it->second.user_data);
            }
        });

        {
            std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
            g_av_initialized_instances.insert(instance_id);
        }
        V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_initialize() succeeded");
        return 1;
    } catch (const std::exception& e) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_initialize() exception: {}", e.what());
        return 0;
    } catch (...) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_initialize() unknown exception");
        return 0;
    }
}

void tim2tox_ffi_av_shutdown(int64_t instance_id) {
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_shutdown() called");
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_shutdown() instance_id={}", (long long)instance_id);

    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_shutdown() instance {} not initialized, skipping", (long long)instance_id);
            return;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (manager_impl) {
        ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
        if (av_mgr) {
            av_mgr->shutdown();
        }
    }
    
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        g_av_initialized_instances.erase(instance_id);
        g_instance_av_callbacks.erase(instance_id);
    }
    
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_shutdown() completed for instance {}", (long long)instance_id);
}

void tim2tox_ffi_av_iterate(int64_t instance_id) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            return;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (manager_impl) {
        ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
        if (av_mgr) {
            av_mgr->iterate();
        }
    }
}

int tim2tox_ffi_av_start_call(int64_t instance_id, uint32_t friend_number, uint32_t audio_bit_rate, uint32_t video_bit_rate) {
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_start_call() called: friend_number={}, audio_bit_rate={}, video_bit_rate={}",
              friend_number, audio_bit_rate, video_bit_rate);
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_start_call() failed: ToxAV not initialized for instance {}", (long long)instance_id);
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_start_call() GetCurrentInstance() returned null");
        return 0;
    }

    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_start_call() GetToxAVManager() returned null");
        return 0;
    }

    int result = av_mgr->startCall(friend_number, audio_bit_rate, video_bit_rate) ? 1 : 0;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_start_call() result: {}", result);
    return result;
}

int tim2tox_ffi_av_answer_call(int64_t instance_id, uint32_t friend_number, uint32_t audio_bit_rate, uint32_t video_bit_rate) {
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_answer_call() called: friend_number={}, audio_bit_rate={}, video_bit_rate={}",
              friend_number, audio_bit_rate, video_bit_rate);
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_answer_call() failed: ToxAV not initialized for instance {}", (long long)instance_id);
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_answer_call() GetCurrentInstance() returned null");
        return 0;
    }

    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_answer_call() GetToxAVManager() returned null");
        return 0;
    }

    int result = av_mgr->answerCall(friend_number, audio_bit_rate, video_bit_rate) ? 1 : 0;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_answer_call() result: {}", result);
    return result;
}

int tim2tox_ffi_av_end_call(int64_t instance_id, uint32_t friend_number) {
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_end_call() called: friend_number={}", friend_number);
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_end_call() failed: ToxAV not initialized for instance {}", (long long)instance_id);
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_end_call() GetCurrentInstance() returned null");
        return 0;
    }

    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) {
        V2TIM_LOG(kError, "[ffi] tim2tox_ffi_av_end_call() GetToxAVManager() returned null");
        return 0;
    }

    int result = av_mgr->endCall(friend_number) ? 1 : 0;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_end_call() result: {}", result);
    return result;
}

int tim2tox_ffi_av_mute_audio(int64_t instance_id, uint32_t friend_number, int mute) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return 0;
    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) return 0;
    return av_mgr->muteAudio(friend_number, mute != 0) ? 1 : 0;
}

int tim2tox_ffi_av_mute_video(int64_t instance_id, uint32_t friend_number, int hide) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return 0;
    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) return 0;
    return av_mgr->muteVideo(friend_number, hide != 0) ? 1 : 0;
}

int tim2tox_ffi_av_send_audio_frame(int64_t instance_id, uint32_t friend_number, const int16_t* pcm, size_t sample_count, uint8_t channels, uint32_t sampling_rate) {
    if (!pcm) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return 0;
    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) return 0;
    return av_mgr->sendAudioFrame(friend_number, pcm, sample_count, channels, sampling_rate) ? 1 : 0;
}

int tim2tox_ffi_av_send_video_frame(int64_t instance_id, uint32_t friend_number, uint16_t width, uint16_t height,
                                     const uint8_t* y, const uint8_t* u, const uint8_t* v,
                                     int32_t y_stride, int32_t u_stride, int32_t v_stride) {
    if (!y || !u || !v) return 0;
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return 0;
    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) return 0;
    return av_mgr->sendVideoFrame(friend_number, width, height, y, u, v) ? 1 : 0;
}

int tim2tox_ffi_av_set_audio_bit_rate(int64_t instance_id, uint32_t friend_number, uint32_t audio_bit_rate) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return 0;
    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) return 0;
    return av_mgr->setAudioBitRate(friend_number, audio_bit_rate) ? 1 : 0;
}

int tim2tox_ffi_av_set_video_bit_rate(int64_t instance_id, uint32_t friend_number, uint32_t video_bit_rate) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    {
        std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
        if (g_av_initialized_instances.find(instance_id) == g_av_initialized_instances.end()) {
            return 0;
        }
    }
    
    V2TIMManagerImpl* manager_impl = GetInstanceFromId(instance_id);
    if (!manager_impl) return 0;
    ToxAVManager* av_mgr = manager_impl->GetToxAVManager();
    if (!av_mgr) return 0;
    return av_mgr->setVideoBitRate(friend_number, video_bit_rate) ? 1 : 0;
}

void tim2tox_ffi_av_set_call_callback(int64_t instance_id, tim2tox_av_call_callback_t callback, void* user_data) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
    AVCallbacks* callbacks = GetCallbacksForInstance(instance_id);
    callbacks->on_call = callback;
    callbacks->user_data = user_data;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_set_call_callback() set for instance {}", (long long)instance_id);
}

void tim2tox_ffi_av_set_call_state_callback(int64_t instance_id, tim2tox_av_call_state_callback_t callback, void* user_data) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
    AVCallbacks* callbacks = GetCallbacksForInstance(instance_id);
    callbacks->on_call_state = callback;
    callbacks->user_data = user_data;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_set_call_state_callback() set for instance {}", (long long)instance_id);
}

void tim2tox_ffi_av_set_audio_receive_callback(int64_t instance_id, tim2tox_av_audio_receive_callback_t callback, void* user_data) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
    AVCallbacks* callbacks = GetCallbacksForInstance(instance_id);
    callbacks->on_audio_receive = callback;
    callbacks->user_data = user_data;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_set_audio_receive_callback() set for instance {}", (long long)instance_id);
}

void tim2tox_ffi_av_set_video_receive_callback(int64_t instance_id, tim2tox_av_video_receive_callback_t callback, void* user_data) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
    AVCallbacks* callbacks = GetCallbacksForInstance(instance_id);
    callbacks->on_video_receive = callback;
    callbacks->user_data = user_data;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_set_video_receive_callback() set for instance {}", (long long)instance_id);
}

void tim2tox_ffi_av_set_audio_bitrate_callback(int64_t instance_id, tim2tox_av_audio_bitrate_callback_t callback, void* user_data) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
    AVCallbacks* callbacks = GetCallbacksForInstance(instance_id);
    callbacks->on_audio_bitrate = callback;
    callbacks->user_data = user_data;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_set_audio_bitrate_callback() set for instance {}", (long long)instance_id);
}

void tim2tox_ffi_av_set_video_bitrate_callback(int64_t instance_id, tim2tox_av_video_bitrate_callback_t callback, void* user_data) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    std::lock_guard<std::mutex> lock(g_av_callbacks_mutex);
    AVCallbacks* callbacks = GetCallbacksForInstance(instance_id);
    callbacks->on_video_bitrate = callback;
    callbacks->user_data = user_data;
    V2TIM_LOG(kInfo, "[ffi] tim2tox_ffi_av_set_video_bitrate_callback() set for instance {}", (long long)instance_id);
}

#endif // BUILD_TOXAV

// Helper function: Get friend number by user ID
// This function is always available, not just when BUILD_TOXAV is enabled
// It's moved outside BUILD_TOXAV block because it doesn't depend on ToxAV
uint32_t tim2tox_ffi_get_friend_number_by_user_id(const char* user_id) {
    V2TIM_LOG(kInfo, "[ffi] get_friend_number_by_user_id: called with user_id={}", user_id ? user_id : "(null)");
    
    if (!IsCurrentInstanceInited()) {
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: current instance not inited");
        return UINT32_MAX;
    }
    
    if (!user_id) {
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: user_id is null");
        return UINT32_MAX;
    }
    
    // Use ToxManager to get friend number
    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: V2TIMManagerImpl instance not available");
        return UINT32_MAX;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: ToxManager instance not available");
        return UINT32_MAX;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: Tox instance not available");
        return UINT32_MAX;
    }
    
    // Convert user_id (hex string) to public key bytes
    // user_id can be either 64 chars (public key) or 76 chars (full address)
    // First, trim whitespace and validate
    const char* trimmed_start = user_id;
    while (*trimmed_start == ' ' || *trimmed_start == '\t' || *trimmed_start == '\n' || *trimmed_start == '\r') {
        trimmed_start++;
    }
    size_t user_id_len = strlen(trimmed_start);
    while (user_id_len > 0 && (trimmed_start[user_id_len - 1] == ' ' || trimmed_start[user_id_len - 1] == '\t' || 
                               trimmed_start[user_id_len - 1] == '\n' || trimmed_start[user_id_len - 1] == '\r')) {
        user_id_len--;
    }
    
    V2TIM_LOG(kInfo, "[ffi] get_friend_number_by_user_id: original user_id='{}', trimmed length={} (expected 64 or 76)", user_id, user_id_len);
    
    if (user_id_len == 0) {
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: user_id is empty after trimming");
        return UINT32_MAX;
    }
    
    uint8_t public_key[TOX_PUBLIC_KEY_SIZE] = {0};
    bool converted = false;
    
    if (user_id_len == TOX_PUBLIC_KEY_SIZE * 2) {
        // Direct public key (64 hex chars = 32 bytes)
        V2TIM_LOG(kInfo, "[ffi] get_friend_number_by_user_id: treating as public key (64 chars)");
        converted = ToxUtil::tox_hex_to_bytes(trimmed_start, user_id_len, public_key, TOX_PUBLIC_KEY_SIZE);
        if (!converted) {
            V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: failed to convert 64-char hex string to bytes (invalid hex)");
        }
    } else if (user_id_len == TOX_ADDRESS_SIZE * 2) {
        // Full address (76 hex chars = 38 bytes), extract first 32 bytes (public key)
        V2TIM_LOG(kInfo, "[ffi] get_friend_number_by_user_id: treating as full address (76 chars), extracting public key");
        uint8_t address[TOX_ADDRESS_SIZE] = {0};
        if (ToxUtil::tox_hex_to_bytes(trimmed_start, user_id_len, address, TOX_ADDRESS_SIZE)) {
            memcpy(public_key, address, TOX_PUBLIC_KEY_SIZE);
            converted = true;
        } else {
            V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: failed to convert 76-char hex string to bytes (invalid hex)");
        }
    } else {
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: invalid user_id length {} (expected {} or {}). first 20 chars: {}",
                  user_id_len, (int)(TOX_PUBLIC_KEY_SIZE * 2), (int)(TOX_ADDRESS_SIZE * 2),
                  user_id_len > 20 ? std::string(trimmed_start, 20) : std::string(trimmed_start));
    }
    
    if (!converted) {
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: hex conversion failed for user_id={}", user_id);
        return UINT32_MAX;
    }
    
    // Debug: print first few bytes of converted public key
    V2TIM_LOG(kInfo, "[ffi] get_friend_number_by_user_id: converted public_key (first 4 bytes): {} {} {} {}",
              (int)public_key[0], (int)public_key[1], (int)public_key[2], (int)public_key[3]);
    
    // Check friend list size for debugging
    size_t friend_count = tox_self_get_friend_list_size(tox);
    V2TIM_LOG(kInfo, "[ffi] get_friend_number_by_user_id: current friend list size={}", friend_count);
    
    // Use tox_friend_by_public_key to find friend number directly
    TOX_ERR_FRIEND_BY_PUBLIC_KEY err;
    uint32_t friend_number = tox_friend_by_public_key(tox, public_key, &err);
    
    if (err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        const char* errorStr = "UNKNOWN";
        switch (err) {
            case TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK: errorStr = "OK"; break;
            case TOX_ERR_FRIEND_BY_PUBLIC_KEY_NULL: errorStr = "NULL"; break;
            case TOX_ERR_FRIEND_BY_PUBLIC_KEY_NOT_FOUND: errorStr = "NOT_FOUND"; break;
            default: errorStr = "UNKNOWN"; break;
        }
        V2TIM_LOG(kError, "[ffi] get_friend_number_by_user_id: tox_friend_by_public_key failed with error {} ({}) for user_id={}",
                  err, errorStr, user_id);
        return UINT32_MAX;
    }
    
    V2TIM_LOG(kInfo, "[ffi] get_friend_number_by_user_id: successfully found friend_number={} for user_id={}", friend_number, user_id);
    return friend_number;
}

// Helper function: Get user ID (public key hex string) by friend number
// This is the reverse of get_friend_number_by_user_id
// Returns pointer to a static buffer containing the 64-char hex string, or nullptr on failure
const char* tim2tox_ffi_get_user_id_by_friend_number(uint32_t friend_number) {
    V2TIM_LOG(kInfo, "[ffi] get_user_id_by_friend_number: called with friend_number={}", friend_number);

    if (!IsCurrentInstanceInited()) {
        V2TIM_LOG(kError, "[ffi] get_user_id_by_friend_number: current instance not inited");
        return nullptr;
    }

    V2TIMManagerImpl* manager_impl = GetCurrentInstance();
    if (!manager_impl) {
        V2TIM_LOG(kError, "[ffi] get_user_id_by_friend_number: V2TIMManagerImpl instance not available");
        return nullptr;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[ffi] get_user_id_by_friend_number: ToxManager instance not available");
        return nullptr;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[ffi] get_user_id_by_friend_number: Tox instance not available");
        return nullptr;
    }

    uint8_t public_key[TOX_PUBLIC_KEY_SIZE] = {0};
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err;
    bool ok = tox_friend_get_public_key(tox, friend_number, public_key, &err);

    if (!ok || err != TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        V2TIM_LOG(kError, "[ffi] get_user_id_by_friend_number: tox_friend_get_public_key failed for friend_number={}, err={}", friend_number, (int)err);
        return nullptr;
    }

    // Convert 32-byte public key to 64-char hex string
    std::string hex = ToxUtil::tox_bytes_to_hex(public_key, TOX_PUBLIC_KEY_SIZE);
    if (hex.empty()) {
        V2TIM_LOG(kError, "[ffi] get_user_id_by_friend_number: tox_bytes_to_hex returned empty for friend_number={}", friend_number);
        return nullptr;
    }

    // Use thread-local static buffer to avoid memory management issues
    static thread_local char result_buf[TOX_PUBLIC_KEY_SIZE * 2 + 1];
    memset(result_buf, 0, sizeof(result_buf));
    strncpy(result_buf, hex.c_str(), TOX_PUBLIC_KEY_SIZE * 2);

    V2TIM_LOG(kInfo, "[ffi] get_user_id_by_friend_number: successfully found user_id={} for friend_number={}", result_buf, friend_number);
    return result_buf;
}

#ifdef BUILD_TOXAV
#else // BUILD_TOXAV not enabled

// Stub implementations when BUILD_TOXAV is disabled
int tim2tox_ffi_av_initialize(int64_t) { return 0; }
void tim2tox_ffi_av_shutdown(int64_t) {}
void tim2tox_ffi_av_iterate(int64_t) {}
int tim2tox_ffi_av_start_call(int64_t, uint32_t, uint32_t, uint32_t) { return 0; }
int tim2tox_ffi_av_answer_call(int64_t, uint32_t, uint32_t, uint32_t) { return 0; }
int tim2tox_ffi_av_end_call(int64_t, uint32_t) { return 0; }
int tim2tox_ffi_av_mute_audio(int64_t, uint32_t, int) { return 0; }
int tim2tox_ffi_av_mute_video(int64_t, uint32_t, int) { return 0; }
int tim2tox_ffi_av_send_audio_frame(int64_t, uint32_t, const int16_t*, size_t, uint8_t, uint32_t) { return 0; }
int tim2tox_ffi_av_send_video_frame(int64_t, uint32_t, uint16_t, uint16_t, const uint8_t*, const uint8_t*, const uint8_t*, int32_t, int32_t, int32_t) { return 0; }
int tim2tox_ffi_av_set_audio_bit_rate(int64_t, uint32_t, uint32_t) { return 0; }
int tim2tox_ffi_av_set_video_bit_rate(int64_t, uint32_t, uint32_t) { return 0; }
void tim2tox_ffi_av_set_call_callback(int64_t, tim2tox_av_call_callback_t, void*) {}
void tim2tox_ffi_av_set_call_state_callback(int64_t, tim2tox_av_call_state_callback_t, void*) {}
void tim2tox_ffi_av_set_audio_receive_callback(int64_t, tim2tox_av_audio_receive_callback_t, void*) {}
void tim2tox_ffi_av_set_video_receive_callback(int64_t, tim2tox_av_video_receive_callback_t, void*) {}
void tim2tox_ffi_av_set_audio_bitrate_callback(int64_t, tim2tox_av_audio_bitrate_callback_t, void*) {}
void tim2tox_ffi_av_set_video_bitrate_callback(int64_t, tim2tox_av_video_bitrate_callback_t, void*) {}

#endif // BUILD_TOXAV

// ============================================================================
// DHT Nodes API Implementation
// ============================================================================

// Global DHT nodes response callback (for backward compatibility)
static tim2tox_dht_nodes_response_callback_t g_dht_nodes_response_callback = nullptr;
static void* g_dht_nodes_response_user_data = nullptr;
static std::mutex g_dht_nodes_response_callback_mutex;

// Per-instance DHT nodes response callbacks (instance_id -> callback)
static std::unordered_map<int64_t, tim2tox_dht_nodes_response_callback_t> g_instance_dht_callbacks;
static std::unordered_map<int64_t, void*> g_instance_dht_user_data;
static std::mutex g_instance_dht_callbacks_mutex;

// Internal callback handler (called from Tox callback system)
// This matches tox_dht_nodes_response_cb signature
// Note: This is called from Tox's background thread, so we need to be careful about thread safety
static void on_dht_nodes_response_internal(Tox* tox, const uint8_t* public_key, const char* ip, uint32_t ip_length, uint16_t port, void* user_data) {
    // Convert public_key (32 bytes) to hex string (64 chars) - do this before locking
    char public_key_hex[65] = {0};
    for (int i = 0; i < 32; i++) {
        snprintf(public_key_hex + i * 2, 3, "%02x", public_key[i]);
    }
    
    // IP is already a null-terminated string from Tox, but ip_length tells us the actual length
    // Create a safe copy
    std::string ip_str;
    if (ip && ip_length > 0) {
        ip_str = std::string(ip, ip_length);
    } else if (ip) {
        ip_str = std::string(ip); // Fallback to null-terminated string
    }
    
    // Try to find the instance ID for this Tox instance
    // Note: This lookup is safe because we're only reading from the map
    int64_t instance_id = 0;
    {
        std::lock_guard<std::mutex> lock(g_test_instances_mutex);
        // Find which instance this Tox belongs to
        for (const auto& pair : g_test_instances) {
            V2TIMManagerImpl* manager = pair.second;
            if (!manager) continue;
            
            // Safely get ToxManager - don't call methods that might throw
            ToxManager* tox_manager = nullptr;
            try {
                tox_manager = manager->GetToxManager();
            } catch (...) {
                // Skip this instance if there's an error
                continue;
            }
            
            if (!tox_manager) continue;
            
            // Safely get Tox pointer
            Tox* manager_tox = nullptr;
            try {
                manager_tox = tox_manager->getTox();
            } catch (...) {
                // Skip this instance if there's an error
                continue;
            }
            
            if (manager_tox && manager_tox == tox) {
                instance_id = pair.first;
                break;
            }
        }
    }
    
    // Try per-instance callback first, then fall back to global callback
    tim2tox_dht_nodes_response_callback_t callback = nullptr;
    void* callback_user_data = nullptr;
    
    if (instance_id != 0) {
        // Try per-instance callback
        std::lock_guard<std::mutex> lock(g_instance_dht_callbacks_mutex);
        auto it = g_instance_dht_callbacks.find(instance_id);
        if (it != g_instance_dht_callbacks.end()) {
            callback = it->second;
            auto user_it = g_instance_dht_user_data.find(instance_id);
            if (user_it != g_instance_dht_user_data.end()) {
                callback_user_data = user_it->second;
            } else {
                // If no user_data stored, use instance_id pointer for routing
                // This ensures Dart trampoline can route to the correct service instance
                // Note: Dart side should have passed instance_id as user_data when registering
                // But if it's missing, we'll create a temporary pointer (Dart side should handle this)
                static thread_local int64_t fallback_instance_id = 0;
                fallback_instance_id = instance_id;
                callback_user_data = &fallback_instance_id;
            }
        }
    }
    
    // Fall back to global callback if no per-instance callback found
    if (!callback) {
        std::lock_guard<std::mutex> lock(g_dht_nodes_response_callback_mutex);
        if (g_dht_nodes_response_callback) {
            callback = g_dht_nodes_response_callback;
            callback_user_data = g_dht_nodes_response_user_data;
        } else {
            return; // No callback registered
        }
    }
    
    // Call FFI callback outside the lock to avoid deadlock.
    //
    // IMPORTANT: This handler runs on Tox's event_thread (background, no Dart
    // isolate). The Dart side now binds via NativeCallable.listener, which
    // posts the call to the registering isolate. Marshalling copies argument
    // values (pointers, ints) but NOT what pointers refer to. Stack-allocated
    // strings would be freed before Dart reads them. So we allocate heap copies
    // and the Dart trampoline frees them via package:ffi's calloc/malloc.free.
    if (callback) {
        char* public_key_dup = strdup(public_key_hex);
        char* ip_dup = strdup(ip_str.c_str());
        if (!public_key_dup || !ip_dup) {
            // Out of memory — clean up partial allocation and skip this callback.
            if (public_key_dup) free(public_key_dup);
            if (ip_dup) free(ip_dup);
            V2TIM_LOG(kError, "[ffi] on_dht_nodes_response_internal: strdup failed, dropping callback");
            return;
        }
        // Wrap callback invocation in try-catch to prevent crashes if Dart isolate is closed
        // or if the callback pointer is invalid.
        try {
            callback(public_key_dup, ip_dup, port, callback_user_data);
            // Ownership of public_key_dup and ip_dup is now transferred to the
            // Dart-side trampoline, which must free() them after copying.
        } catch (...) {
            // If the post itself throws, we own the buffers — free here to avoid leak.
            free(public_key_dup);
            free(ip_dup);
            V2TIM_LOG(kError, "[ffi] on_dht_nodes_response_internal: Exception caught while calling callback, ignoring");
        }
    }
}

int tim2tox_ffi_dht_send_nodes_request(const char* public_key, const char* ip, uint16_t port, const char* target_public_key) {
    if (!IsCurrentInstanceInited()) {
        V2TIM_LOG(kError, "[ffi] dht_send_nodes_request: SDK not initialized");
        return 0;
    }
    
    if (!public_key || !ip || !target_public_key) {
        V2TIM_LOG(kError, "[ffi] dht_send_nodes_request: null parameter");
        return 0;
    }
    
    // Get current Tox instance
    V2TIMManagerImpl* manager = GetCurrentInstance();
    if (!manager) {
        V2TIM_LOG(kError, "[ffi] dht_send_nodes_request: failed to get current instance");
        return 0;
    }
    
    ToxManager* tox_manager = manager->GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[ffi] dht_send_nodes_request: ToxManager is null");
        return 0;
    }
    
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[ffi] dht_send_nodes_request: Tox instance is null");
        return 0;
    }
    
    // Convert hex strings to binary
    uint8_t public_key_bin[TOX_PUBLIC_KEY_SIZE] = {0};
    uint8_t target_public_key_bin[TOX_PUBLIC_KEY_SIZE] = {0};
    
    // Parse public_key (64 hex chars = 32 bytes)
    if (strlen(public_key) != 64) {
        V2TIM_LOG(kError, "[ffi] dht_send_nodes_request: invalid public_key length (expected 64 hex chars)");
        return 0;
    }
    
    for (int i = 0; i < 32; i++) {
        char hex_byte[3] = {public_key[i*2], public_key[i*2+1], 0};
        public_key_bin[i] = (uint8_t)strtoul(hex_byte, nullptr, 16);
    }
    
    // Parse target_public_key (64 hex chars = 32 bytes)
    if (strlen(target_public_key) != 64) {
        V2TIM_LOG(kError, "[ffi] dht_send_nodes_request: invalid target_public_key length (expected 64 hex chars)");
        return 0;
    }
    
    for (int i = 0; i < 32; i++) {
        char hex_byte[3] = {target_public_key[i*2], target_public_key[i*2+1], 0};
        target_public_key_bin[i] = (uint8_t)strtoul(hex_byte, nullptr, 16);
    }
    
    // Call tox_dht_send_nodes_request
    Tox_Err_Dht_Send_Nodes_Request error;
    bool success = tox_dht_send_nodes_request(tox, public_key_bin, ip, port, target_public_key_bin, &error);
    
    if (!success) {
        V2TIM_LOG(kError, "[ffi] dht_send_nodes_request: tox_dht_send_nodes_request failed with error {}", error);
        return 0;
    }
    
    V2TIM_LOG(kInfo, "[ffi] dht_send_nodes_request: success (ip={}, port={})", ip, port);
    return 1;
}

void tim2tox_ffi_set_dht_nodes_response_callback(int64_t instance_id, tim2tox_dht_nodes_response_callback_t callback, void* user_data) {
    if (instance_id == 0) instance_id = GetCurrentInstanceId();
    
    if (instance_id != 0) {
        // Register per-instance callback
        {
            std::lock_guard<std::mutex> lock(g_instance_dht_callbacks_mutex);
            if (callback) {
                g_instance_dht_callbacks[instance_id] = callback;
                g_instance_dht_user_data[instance_id] = user_data;
                V2TIM_LOG(kInfo, "[ffi] set_dht_nodes_response_callback: registered per-instance callback for instance_id={}", 
                        (long long)instance_id);
            } else {
                g_instance_dht_callbacks.erase(instance_id);
                g_instance_dht_user_data.erase(instance_id);
                V2TIM_LOG(kInfo, "[ffi] set_dht_nodes_response_callback: unregistered per-instance callback for instance_id={}", 
                        (long long)instance_id);
            }
        }
    } else {
        // Fall back to global callback for default instance
        {
            std::lock_guard<std::mutex> lock(g_dht_nodes_response_callback_mutex);
            g_dht_nodes_response_callback = callback;
            g_dht_nodes_response_user_data = user_data;
            V2TIM_LOG(kInfo, "[ffi] set_dht_nodes_response_callback: registered global callback (default instance)");
        }
    }
    
    // Register/unregister internal callback with Tox for this instance
    V2TIMManagerImpl* manager = GetInstanceFromId(instance_id);
    if (manager) {
        ToxManager* tox_manager = manager->GetToxManager();
        if (tox_manager) {
            Tox* tox = tox_manager->getTox();
            if (tox) {
                if (callback) {
                    // Register callback using tox_callback_dht_nodes_response
                    // The callback signature matches tox_dht_nodes_response_cb
                    tox_callback_dht_nodes_response(tox, on_dht_nodes_response_internal);
                    V2TIM_LOG(kInfo, "[ffi] set_dht_nodes_response_callback: callback registered for current instance (instance_id={})", 
                            (long long)instance_id);
                } else {
                    // Unregister by passing NULL
                    tox_callback_dht_nodes_response(tox, nullptr);
                    V2TIM_LOG(kInfo, "[ffi] set_dht_nodes_response_callback: callback unregistered for current instance");
                }
            } else {
                V2TIM_LOG(kError, "[ffi] set_dht_nodes_response_callback: Tox instance is null (will register later when Tox is created)");
            }
        } else {
            V2TIM_LOG(kError, "[ffi] set_dht_nodes_response_callback: ToxManager is null (will register later when ToxManager is created)");
        }
    } else {
        V2TIM_LOG(kError, "[ffi] set_dht_nodes_response_callback: failed to get current instance (will register later)");
    }
}

// ============================================================================
// Tox Profile Encryption/Decryption APIs
// ============================================================================

int tim2tox_ffi_is_data_encrypted(const uint8_t* data, size_t data_len) {
    if (!data || data_len < TOX_PASS_ENCRYPTION_EXTRA_LENGTH) {
        return -1;
    }
    return tox_is_data_encrypted(data) ? 1 : 0;
}

int tim2tox_ffi_pass_encrypt(
    const uint8_t* plaintext, size_t plaintext_len,
    const uint8_t* passphrase, size_t passphrase_len,
    uint8_t* ciphertext, size_t ciphertext_capacity
) {
    if (!plaintext || plaintext_len == 0 || !ciphertext) {
        return -1;
    }
    
    size_t required_size = plaintext_len + TOX_PASS_ENCRYPTION_EXTRA_LENGTH;
    if (ciphertext_capacity < required_size) {
        return -1;
    }
    
    Tox_Err_Encryption error;
    bool success = tox_pass_encrypt(
        plaintext, plaintext_len,
        passphrase, passphrase_len,
        ciphertext, &error
    );
    
    if (!success || error != TOX_ERR_ENCRYPTION_OK) {
        return -1;
    }
    
    return required_size;
}

int tim2tox_ffi_pass_decrypt(
    const uint8_t* ciphertext, size_t ciphertext_len,
    const uint8_t* passphrase, size_t passphrase_len,
    uint8_t* plaintext, size_t plaintext_capacity
) {
    if (!ciphertext || ciphertext_len < TOX_PASS_ENCRYPTION_EXTRA_LENGTH || !plaintext) {
        return -1;
    }
    
    size_t required_size = ciphertext_len - TOX_PASS_ENCRYPTION_EXTRA_LENGTH;
    if (plaintext_capacity < required_size) {
        return -1;
    }
    
    Tox_Err_Decryption error;
    bool success = tox_pass_decrypt(
        ciphertext, ciphertext_len,
        passphrase, passphrase_len,
        plaintext, &error
    );
    
    if (!success || error != TOX_ERR_DECRYPTION_OK) {
        return -1;
    }
    
    return required_size;
}

int tim2tox_ffi_extract_tox_id_from_profile(
    const uint8_t* profile_data, size_t profile_len,
    const uint8_t* passphrase, size_t passphrase_len,
    char* out_tox_id, size_t out_tox_id_len
) {
    if (!profile_data || profile_len == 0 || !out_tox_id || out_tox_id_len < 65) {
        return -1; // Need at least 64 chars + null terminator
    }
    
    // Decrypt if encrypted
    std::vector<uint8_t> decrypted_data;
    const uint8_t* data_to_load = profile_data;
    size_t data_len = profile_len;
    
    if (profile_len >= TOX_PASS_ENCRYPTION_EXTRA_LENGTH && tox_is_data_encrypted(profile_data)) {
        // File is encrypted, need to decrypt first
        if (!passphrase) {
            return -1; // Encrypted but no passphrase provided
        }
        
        size_t decrypted_size = profile_len - TOX_PASS_ENCRYPTION_EXTRA_LENGTH;
        decrypted_data.resize(decrypted_size);
        
        Tox_Err_Decryption error;
        bool success = tox_pass_decrypt(
            profile_data, profile_len,
            passphrase, passphrase_len,
            decrypted_data.data(), &error
        );
        
        if (!success || error != TOX_ERR_DECRYPTION_OK) {
            return -1; // Decryption failed
        }
        
        data_to_load = decrypted_data.data();
        data_len = decrypted_size;
    }
    
    // Create temporary Tox instance to extract public key
    Tox_Options* options = tox_options_new(nullptr);
    if (!options) {
        return -1;
    }
    
    tox_options_default(options);
    tox_options_set_savedata_type(options, TOX_SAVEDATA_TYPE_TOX_SAVE);
    tox_options_set_savedata_data(options, data_to_load, data_len);
    tox_options_set_savedata_length(options, data_len);
    
    TOX_ERR_NEW error_new;
    Tox* tox = tox_new(options, &error_new);
    tox_options_free(options);
    
    if (!tox || error_new != TOX_ERR_NEW_OK) {
        return -1; // Failed to create Tox instance
    }
    
    // Get public key
    uint8_t public_key[TOX_PUBLIC_KEY_SIZE];
    tox_self_get_public_key(tox, public_key);
    
    // Convert to hex string
    for (size_t i = 0; i < TOX_PUBLIC_KEY_SIZE; i++) {
        snprintf(out_tox_id + i * 2, 3, "%02X", public_key[i]);
    }
    out_tox_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
    
    tox_kill(tox);
    
    return TOX_PUBLIC_KEY_SIZE * 2; // Return length of hex string
}

int tim2tox_ffi_inject_callback(const char* json_callback) {
    if (!json_callback) return 0;
    if (!IsDartPortRegistered()) return 0;

    // Send the JSON string directly to the Dart ReceivePort, exactly as
    // SendCallbackToDart does, but without any additional formatting.
    std::string message(json_callback);
    SendCallbackToDart("inject_test", message, nullptr);
    return 1;
}

} // extern "C"
