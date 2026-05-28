// tox_manager.cpp
#include <iostream>
#include "ToxManager.h"
#include "V2TIMLog.h"
#include "toxcore/tox.h"
#include <fstream>
#include <filesystem> // For std::filesystem::rename (Windows atomic-replace fallback)
#include <chrono>
#include <string> // Required for std::to_string
#include <vector> // Required for std::vector
#include <system_error> // For std::system_error
#include <sstream> // For std::ostringstream
#include <iomanip> // For std::setw, std::setfill
#include <cstring> // For memcmp
#include <cstdio> // For std::remove
#include <cerrno> // For errno, EINTR
#ifndef _WIN32
#include <unistd.h> // For ::write, ::fsync, ::close
#include <fcntl.h>  // For ::open, O_* flags
#include <sys/stat.h> // For ::chmod, mode constants
#endif

// 默认实例（用于向后兼容）
static ToxManager* g_default_instance = nullptr;
static std::mutex g_default_instance_mutex;

// 全局映射：Tox* -> ToxManager*（用于不支持 user_data 的回调）
static std::unordered_map<Tox*, ToxManager*> g_tox_to_manager;
static std::mutex g_tox_to_manager_mutex;

ToxManager* ToxManager::getDefaultInstance() {
    std::lock_guard<std::mutex> lock(g_default_instance_mutex);
    if (!g_default_instance) {
        g_default_instance = new ToxManager();
    }
    return g_default_instance;
}

// 辅助函数：从 Tox* 获取 ToxManager*。找不到映射时返回 nullptr，不再 fallback 到默认实例，避免错误路由。
static ToxManager* getManagerFromTox(Tox* tox) {
    if (!tox) {
        V2TIM_LOG(kWarning, "[getManagerFromTox] WARNING: tox is null");
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(g_tox_to_manager_mutex);
    auto it = g_tox_to_manager.find(tox);
    if (it != g_tox_to_manager.end()) {
        V2TIM_LOG(kDebug, "[getManagerFromTox] Found manager={} for tox={}", (void*)it->second, (void*)tox);
        return it->second;
    }
    V2TIM_LOG(kError, "[getManagerFromTox] No manager found for tox={}, total mappings={}", (void*)tox, g_tox_to_manager.size());
    return nullptr;
}

// 构造函数（现在是 public，支持多实例）
ToxManager::ToxManager() : tox_(nullptr, &toxDeleter) {}

// 析构函数
ToxManager::~ToxManager() {
    // Explicitly shutdown to ensure proper cleanup order
    // This prevents issues during static destruction at application termination
    // Use try-catch to prevent exceptions during termination from causing crashes
    try {
        shutdown();
    } catch (...) {
        // Silently ignore exceptions during static destruction
        // The application is terminating anyway
    }
}

// 自定义删除器实现
void ToxManager::toxDeleter(Tox* tox) {
    if (tox != nullptr) {
        // During application termination, socket cleanup may fail.
        // We use signal handling to prevent crashes from close() on invalid sockets.
        // Note: This is a best-effort cleanup during termination.
        // Use try-catch to handle any exceptions during tox_kill
        // This prevents crashes when group chats are in an invalid state during shutdown
        try {
            tox_kill(tox);
        } catch (...) {
            // Silently ignore exceptions during tox_kill
            // This can happen during application termination when resources are being cleaned up
            // The exception is caught to prevent crashes, but we don't log it
            // as it's expected during application termination
        }
    }
}

// Static Toxcore internal log callback – forwards WARNING and ERROR messages
// to stdout so we can see conference reconnection events, ONLINE_PACKET issues, etc.
static void toxcore_log_callback(Tox * /*tox*/, Tox_Log_Level level, const char *file,
                                 uint32_t line, const char *func, const char *message,
                                 void * /*user_data*/) {
    if (level >= TOX_LOG_LEVEL_WARNING) {
        const char *lvl_str = (level == TOX_LOG_LEVEL_ERROR) ? "ERR" : "WRN";
        // Route c-toxcore's internal log through the project logger at kDebug so it
        // is gated rather than written to raw stdout.
        V2TIM_LOG(kDebug, "[Toxcore-{}] {}:{} {}: {}", lvl_str, file, line, func, message);
    }
}

// 初始化实现
void ToxManager::initialize(const Tox_Options* options,
                           const uint8_t* savedata,
                           size_t savedata_length) {
    V2TIM_LOG(kDebug, "[ToxManager] initialize: ENTRY - this={}, options={}", (void*)this, (void*)options);
    std::lock_guard<std::mutex> lock(mutex_);
    V2TIM_LOG(kDebug, "[ToxManager] initialize: Acquired mutex");

    // Allow reinitialization if tox_ is null (e.g., after shutdown)
    // Reset shutdown flag when reinitializing
    // This allows reinitialization after shutdown
    if (tox_) {
        throw std::runtime_error("Tox instance already initialized");
    }
    
    // Reset shutdown flag when reinitializing
    is_shutting_down_.store(false, std::memory_order_release);

    // Allocate options using tox API to avoid freeing invalid pointers in defaults.
    Tox_Err_Options_New opt_err;
    Tox_Options* opts = tox_options_new(&opt_err);
    if (!opts || opt_err != TOX_ERR_OPTIONS_NEW_OK) {
        return;
    }
    // tox_options_new returns defaults; calling default again is safe but unnecessary.
    // Keep behaviour explicit in case headers change.
    tox_options_default(opts);
    
    // If options parameter is provided, copy its settings (but allow savedata to override)
    if (options) {
        // Copy all option settings from provided options
        tox_options_set_local_discovery_enabled(opts, tox_options_get_local_discovery_enabled(options));
        tox_options_set_ipv6_enabled(opts, tox_options_get_ipv6_enabled(options));
        tox_options_set_udp_enabled(opts, tox_options_get_udp_enabled(options));
        tox_options_set_hole_punching_enabled(opts, tox_options_get_hole_punching_enabled(options));
        tox_options_set_dht_announcements_enabled(opts, tox_options_get_dht_announcements_enabled(options));
    }
    
    if (savedata && savedata_length > 0) {
        tox_options_set_savedata_type(opts, TOX_SAVEDATA_TYPE_TOX_SAVE);
        // Set both data and length; set_data copies or references based on ownership flag.
        tox_options_set_savedata_data(opts, savedata, savedata_length);
        tox_options_set_savedata_length(opts, savedata_length);
    }

    // Enable Toxcore internal logging (WARNING + ERROR) to capture conference events
    tox_options_set_log_callback(opts, toxcore_log_callback);

    V2TIM_LOG(kDebug, "[ToxManager] initialize: About to call tox_new with options");
    TOX_ERR_NEW err_new;
    Tox* tox_instance = tox_new(opts, &err_new);
    V2TIM_LOG(kDebug, "[ToxManager] initialize: tox_new returned: tox_instance={}, err_new={}", (void*)tox_instance, static_cast<int>(err_new));
    tox_options_free(opts);
    if (tox_instance == nullptr || err_new != TOX_ERR_NEW_OK) {
        const char* err_str = tox_err_new_to_string(err_new);
        V2TIM_LOG(kError, "[ToxManager] initialize: Failed to create Tox instance, error: {} ({})",
                  static_cast<int>(err_new), err_str ? err_str : "unknown");
        throw std::runtime_error(err_str && *err_str ? err_str : "tox_new failed");
    }
    V2TIM_LOG(kInfo, "[ToxManager] initialize: Tox instance created successfully");
    
    // 使用reset来设置unique_ptr
    tox_.reset(tox_instance);

    // Register Tox* -> ToxManager* mapping for callbacks that don't support user_data
    {
        std::lock_guard<std::mutex> lock(g_tox_to_manager_mutex);
        g_tox_to_manager[tox_instance] = this;
        V2TIM_LOG(kDebug, "[ToxManager] initialize: Registered mapping: tox={} -> manager={}", (void*)tox_instance, (void*)this);
        V2TIM_LOG(kDebug, "[ToxManager] initialize: Total mappings: {}", g_tox_to_manager.size());
    }

    // Register file receive chunk callback if it was set before initialization
    // This ensures the callback is registered even if setFileRecvChunkCallback was called before initialize
    if (file_recv_chunk_cb_) {
        tox_callback_file_recv_chunk(tox_.get(), onFileRecvChunk);
    }
    // Register group callbacks if they were set before initialization (e.g. from InitSDK before create)
    if (group_message_group_cb_) {
        tox_callback_group_message(tox_.get(), onGroupMessageGroup);
    }
    if (group_private_message_group_cb_) {
        tox_callback_group_private_message(tox_.get(), onGroupPrivateMessage);
    }
    // Conference (old API) message callback so receivers get group messages from conferences
    if (group_message_cb_) {
        tox_callback_conference_message(tox_.get(), onGroupMessage);
    }

    // Store the instance pointer for use in iterate
    // tox_self_set_user_data(tox_.get(), this);
    // Note: We'll pass 'this' directly to tox_iterate instead of using tox_self_set_user_data

    // Bootstrap (Example - replace with actual node)
    // TODO: Move bootstrap logic to V2TIMManagerImpl::Login or a dedicated connection manager
    // const char* bootstrap_node = "tox.ngc.zone";
    // uint16_t port = 33445;
    // uint8_t public_key_bytes[TOX_PUBLIC_KEY_SIZE];
    // TODO: Replace with actual public key hex string and convert
    // const char* public_key_hex = "F404ABAA1C99A9D37D61AB54898F56793E1DEF8BD46B1038B9D82258460A593D";
    // if (tox_hex_to_bytes(public_key_hex, strlen(public_key_hex), public_key_bytes, TOX_PUBLIC_KEY_SIZE)) {
    //     TOX_ERR_BOOTSTRAP err_bootstrap;
    //     tox_bootstrap(tox_, bootstrap_node, port, public_key_bytes, &err_bootstrap);
    //     if (err_bootstrap != TOX_ERR_BOOTSTRAP_OK) {
    //         V2TIMLog(kError, "Bootstrap failed with error: {}", err_bootstrap);
    //     }
    // } else {
    //     V2TIMLog(kError, "Failed to convert bootstrap public key hex string.");
    // }

    // V2TIMLog(kInfo, "ToxManager initialized successfully.");
}

// 关闭实现：与 iterate() 使用相同锁顺序 (iterate_mutex_ 再 mutex_) 避免 UAF 竞态
void ToxManager::shutdown() {
    std::scoped_lock lock(iterate_mutex_, mutex_);

    if (is_shutting_down_.load(std::memory_order_acquire) || !tox_) {
        return;
    }

    is_shutting_down_.store(true, std::memory_order_release);

    if (Tox* tox_to_remove = tox_.get()) {
        std::lock_guard<std::mutex> map_lock(g_tox_to_manager_mutex);
        g_tox_to_manager.erase(tox_to_remove);
    }

    tox_.reset();
}

// 获取Tox实例
Tox* ToxManager::getTox() const {
    // Use try-catch to handle cases where mutex is invalid during static destruction
    // This can happen when the application is terminating and static objects are being destroyed
    try {
        std::lock_guard<std::mutex> lock(mutex_);
        // Check if shutting down to avoid accessing tox_ during destruction
        if (is_shutting_down_.load(std::memory_order_acquire) || !tox_) {
            return nullptr;
        }
        return tox_.get();
    } catch (const std::system_error& e) {
        // Mutex may be invalid during static destruction
        // Return nullptr to indicate Tox instance is not available
        return nullptr;
    } catch (...) {
        // Catch any other exception during mutex lock
        return nullptr;
    }
}

// 检查是否正在关闭
bool ToxManager::isShuttingDown() const {
    try {
        return is_shutting_down_.load(std::memory_order_acquire);
    } catch (...) {
        // Mutex may be invalid during static destruction
        // Return true to indicate shutdown to prevent further operations
        return true;
    }
}

// 迭代实现：先取 iterate_mutex_ 再 mutex_，与 shutdown() 一致；不在锁外使用裸 tox 指针
void ToxManager::iterate(uint32_t /*timeout*/) {
    std::unique_lock<std::mutex> iter_lock(iterate_mutex_);
    Tox* tox_ptr = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (is_shutting_down_.load(std::memory_order_acquire) || !tox_) {
            return;
        }
        tox_ptr = tox_.get();
    }
    if (!tox_ptr) {
        return;
    }
    // Call tox_iterate while holding iterate_mutex_ so shutdown() cannot reset tox_ until we return
    try {
        tox_iterate(tox_ptr, this);
    } catch (...) {
        // Silently ignore exceptions during tox_iterate
    }
}

// 回调函数实现
void ToxManager::onSelfConnectionStatus(Tox* tox, TOX_CONNECTION connection_status, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager] onSelfConnectionStatus: called with connection_status={} (0=NONE, 1=TCP, 2=UDP), user_data={}", connection_status, user_data);

    if (!user_data) {
        V2TIM_LOG(kWarning, "[ToxManager] onSelfConnectionStatus: WARNING - user_data is null");
        return;
    }

    ToxManager* manager = static_cast<ToxManager*>(user_data);

    SelfConnectionStatusCallback cb;
    {
        std::lock_guard<std::mutex> lock(manager->mutex_);
        if (!manager->tox_ || !manager->self_connection_status_cb_) {
            V2TIM_LOG(kWarning, "[ToxManager] onSelfConnectionStatus: WARNING - tox_={}, self_connection_status_cb_={}", manager->tox_.get(), manager->self_connection_status_cb_ ? (void*)1 : (void*)0);
            return;
        }
        cb = manager->self_connection_status_cb_;
    }

    if (cb) {
        try {
            V2TIM_LOG(kDebug, "[ToxManager] onSelfConnectionStatus: Calling callback with connection_status={}", connection_status);
            cb(connection_status);
        } catch (...) {
            V2TIM_LOG(kError, "[ToxManager] onSelfConnectionStatus: Exception in callback");
        }
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] onSelfConnectionStatus: WARNING - callback is null");
    }
}

void ToxManager::onFriendRequest(Tox* tox, const uint8_t* public_key, const uint8_t* message, size_t length, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager::onFriendRequest] ENTRY - Friend request RECEIVED by Tox");
    V2TIM_LOG(kDebug, "[ToxManager::onFriendRequest] manager={}, has_callback={}", user_data, user_data ? (static_cast<ToxManager*>(user_data)->friend_request_cb_ ? 1 : 0) : 0);
    std::ostringstream hex_ss;
    for (int i = 0; i < 20 && i < TOX_PUBLIC_KEY_SIZE; ++i) {
        hex_ss << std::hex << std::setw(2) << std::setfill('0') << static_cast<unsigned>(public_key[i]);
    }
    V2TIM_LOG(kDebug, "[ToxManager::onFriendRequest] public_key (first 20 bytes): {}...", hex_ss.str());
    V2TIM_LOG(kDebug, "[ToxManager::onFriendRequest] message length: {}", length);

    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_request_cb_) {
        V2TIM_LOG(kDebug, "[ToxManager::onFriendRequest] Calling friend_request_cb_, message length: {}", length);
        manager->friend_request_cb_(public_key, message, length);
        V2TIM_LOG(kDebug, "[ToxManager::onFriendRequest] friend_request_cb_ completed");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager::onFriendRequest] WARNING: manager={} or callback not set! (manager exists: {}, callback exists: {})", (void*)manager, manager ? 1 : 0, manager && manager->friend_request_cb_ ? 1 : 0);
    }
    V2TIM_LOG(kDebug, "[ToxManager::onFriendRequest] EXIT");
}

void ToxManager::onFriendMessage(Tox* tox, uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager::onFriendMessage] ENTRY - friend_number={}, type={}, length={}, manager={}", friend_number, type, length, user_data);
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_message_cb_) {
        V2TIM_LOG(kDebug, "[ToxManager::onFriendMessage] Calling friend_message_cb_");
        manager->friend_message_cb_(friend_number, type, message, length);
        V2TIM_LOG(kDebug, "[ToxManager::onFriendMessage] friend_message_cb_ completed");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager::onFriendMessage] WARNING: manager={} or callback not set! (has_cb={})", (void*)manager, manager ? (manager->friend_message_cb_ ? 1 : 0) : 0);
    }
    V2TIM_LOG(kDebug, "[ToxManager::onFriendMessage] EXIT");
}

void ToxManager::onFriendName(Tox* tox, uint32_t friend_number, const uint8_t* name, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_name_cb_) {
        manager->friend_name_cb_(friend_number, name, length);
    }
}

void ToxManager::onFriendStatusMessage(Tox* tox, uint32_t friend_number, const uint8_t* message, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_status_message_cb_) {
        manager->friend_status_message_cb_(friend_number, message, length);
    }
}

void ToxManager::onFriendStatus(Tox* tox, uint32_t friend_number, TOX_USER_STATUS status, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_status_cb_) {
        manager->friend_status_cb_(friend_number, status);
    }
}

void ToxManager::onFriendConnectionStatus(Tox* tox, uint32_t friend_number, TOX_CONNECTION connection_status, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_connection_status_cb_) {
        manager->friend_connection_status_cb_(friend_number, connection_status);
    }
}

void ToxManager::onFriendReadReceipt(Tox* tox, uint32_t friend_number, uint32_t message_id, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_read_receipt_cb_) {
        manager->friend_read_receipt_cb_(friend_number, message_id);
    }
}

void ToxManager::onFriendTyping(Tox* tox, uint32_t friend_number, bool typing, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_typing_cb_) {
        manager->friend_typing_cb_(friend_number, typing);
    }
}

void ToxManager::onFileRecv(Tox* tox, uint32_t friend_number, uint32_t file_number, uint32_t kind, uint64_t file_size, const uint8_t* filename, size_t filename_length, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager] onFileRecv: ENTRY tox={} friend={} file={} kind={} size={} manager={} has_cb={}",
            (void*)tox, friend_number, file_number, kind, (unsigned long long)file_size, (void*)user_data,
            (user_data && static_cast<ToxManager*>(user_data)->file_recv_cb_) ? 1 : 0);
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->file_recv_cb_) {
        manager->file_recv_cb_(friend_number, file_number, kind, file_size, filename, filename_length);
    }
}

void ToxManager::onFileControl(Tox* tox, uint32_t friend_number, uint32_t file_number, TOX_FILE_CONTROL control, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->file_control_cb_) {
        manager->file_control_cb_(friend_number, file_number, control);
    }
}

void ToxManager::onFileChunkRequest(Tox* tox, uint32_t friend_number, uint32_t file_number, uint64_t position, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->file_chunk_request_cb_) {
        manager->file_chunk_request_cb_(friend_number, file_number, position, length);
    }
}

void ToxManager::onFileRecvChunk(Tox* tox, uint32_t friend_number, uint32_t file_number, uint64_t position, const uint8_t* data, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->file_recv_chunk_cb_) {
        manager->file_recv_chunk_cb_(friend_number, file_number, position, data, length);
    }
}

void ToxManager::onGroupInvite(Tox* tox, uint32_t friend_number, TOX_CONFERENCE_TYPE type, const uint8_t* cookie, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->group_invite_cb_) {
        manager->group_invite_cb_(friend_number, type, cookie, length);
    }
}

void ToxManager::onGroupMessage(Tox* tox, uint32_t conference_number, uint32_t peer_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager] onGroupMessage: ENTRY conference_number={} peer_number={} type={} length={} tox={}",
            conference_number, peer_number, static_cast<int>(type), length, (void*)tox);
    ToxManager* manager = getManagerFromTox(tox);
    V2TIM_LOG(kDebug, "[ToxManager] onGroupMessage: manager={} has_cb={}", (void*)manager, manager && manager->group_message_cb_ ? 1 : 0);
    if (manager && manager->group_message_cb_) {
        manager->group_message_cb_(conference_number, peer_number, type, message, length);
    }
}

void ToxManager::onGroupTitle(Tox* tox, uint32_t conference_number, uint32_t peer_number, const uint8_t* title, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->group_title_cb_) {
        manager->group_title_cb_(conference_number, peer_number, title, length);
    }
}

void ToxManager::onGroupPeerName(Tox* tox, uint32_t conference_number, uint32_t peer_number, const uint8_t* name, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->group_peer_name_cb_) {
        manager->group_peer_name_cb_(conference_number, peer_number, name, length);
    }
}

void ToxManager::onGroupPeerListChanged(Tox* tox, uint32_t conference_number, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->group_peer_list_changed_cb_) {
        manager->group_peer_list_changed_cb_(conference_number);
    }
}

void ToxManager::onGroupConnected(Tox* tox, uint32_t conference_number, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->group_connected_cb_) {
        manager->group_connected_cb_(conference_number);
    }
}

void ToxManager::onFriendLossyPacket(Tox* tox, uint32_t friend_number, const uint8_t* data, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_lossy_packet_cb_) {
        manager->friend_lossy_packet_cb_(friend_number, data, length);
    }
}

void ToxManager::onFriendLosslessPacket(Tox* tox, uint32_t friend_number, const uint8_t* data, size_t length, void* user_data) {
    ToxManager* manager = static_cast<ToxManager*>(user_data);
    if (manager && manager->friend_lossless_packet_cb_) {
        manager->friend_lossless_packet_cb_(friend_number, data, length);
    }
}

// 更新回调设置方法
void ToxManager::setSelfConnectionStatusCallback(SelfConnectionStatusCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    self_connection_status_cb_ = std::move(cb);
    if (tox_) {
        tox_callback_self_connection_status(tox_.get(), onSelfConnectionStatus);
        V2TIM_LOG(kDebug, "[ToxManager] setSelfConnectionStatusCallback: Registered callback, tox_=non-null");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] setSelfConnectionStatusCallback: WARNING - tox_ is null, callback not registered");
    }
}

void ToxManager::setFriendRequestCallback(FriendRequestCallback cb) {
    V2TIM_LOG(kDebug, "[ToxManager::setFriendRequestCallback] ENTRY - this={}, has_cb={}, tox_={}", (void*)this, cb ? 1 : 0, (void*)tox_.get());
    std::lock_guard<std::mutex> lock(mutex_);
    friend_request_cb_ = std::move(cb);
    if (tox_) {
        V2TIM_LOG(kDebug, "[ToxManager::setFriendRequestCallback] Registering tox_callback_friend_request");
        tox_callback_friend_request(tox_.get(), onFriendRequest);
        V2TIM_LOG(kDebug, "[ToxManager::setFriendRequestCallback] tox_callback_friend_request registered");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager::setFriendRequestCallback] WARNING: tox_ is null, callback not registered yet");
    }
    V2TIM_LOG(kDebug, "[ToxManager::setFriendRequestCallback] EXIT");
}

void ToxManager::setFriendMessageCallback(FriendMessageCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_message_cb_ = std::move(cb);
    if (tox_) tox_callback_friend_message(tox_.get(), onFriendMessage);
}

void ToxManager::setFriendNameCallback(FriendNameCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_name_cb_ = std::move(cb);
    if (tox_) tox_callback_friend_name(tox_.get(), onFriendName);
}

void ToxManager::setFriendStatusMessageCallback(FriendStatusMessageCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_status_message_cb_ = std::move(cb);
    if (tox_) tox_callback_friend_status_message(tox_.get(), onFriendStatusMessage);
}

void ToxManager::setFriendStatusCallback(FriendStatusCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_status_cb_ = std::move(cb);
    if (tox_) tox_callback_friend_status(tox_.get(), onFriendStatus);
}

void ToxManager::setFriendConnectionStatusCallback(FriendConnectionStatusCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_connection_status_cb_ = std::move(cb);
    if (tox_) tox_callback_friend_connection_status(tox_.get(), onFriendConnectionStatus);
}

void ToxManager::setFriendReadReceiptCallback(FriendReadReceiptCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_read_receipt_cb_ = std::move(cb);
    if (tox_) tox_callback_friend_read_receipt(tox_.get(), onFriendReadReceipt);
}

void ToxManager::setFriendTypingCallback(FriendTypingCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_typing_cb_ = std::move(cb);
    if (tox_) tox_callback_friend_typing(tox_.get(), onFriendTyping);
}

void ToxManager::setFileRecvCallback(FileRecvCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    file_recv_cb_ = std::move(cb);
    if (tox_) tox_callback_file_recv(tox_.get(), onFileRecv);
}

void ToxManager::setFileControlCallback(FileControlCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    file_control_cb_ = std::move(cb);
    if (tox_) tox_callback_file_recv_control(tox_.get(), onFileControl);
}

void ToxManager::setFileChunkRequestCallback(FileChunkRequestCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    file_chunk_request_cb_ = std::move(cb);
    if (tox_) tox_callback_file_chunk_request(tox_.get(), onFileChunkRequest);
}

void ToxManager::setFileRecvChunkCallback(FileRecvChunkCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    file_recv_chunk_cb_ = std::move(cb);
    // Register callback with Tox if instance exists
    if (tox_) {
        tox_callback_file_recv_chunk(tox_.get(), onFileRecvChunk);
    }
}

void ToxManager::setGroupInviteCallback(GroupInviteCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_invite_cb_ = std::move(cb);
    if (tox_) tox_callback_conference_invite(tox_.get(), onGroupInvite);
}

void ToxManager::setGroupMessageCallback(GroupMessageCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_message_cb_ = std::move(cb);
    if (tox_) tox_callback_conference_message(tox_.get(), onGroupMessage);
}

void ToxManager::setGroupTitleCallback(GroupTitleCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_title_cb_ = std::move(cb);
    if (tox_) tox_callback_conference_title(tox_.get(), onGroupTitle);
}

void ToxManager::setGroupPeerNameCallback(GroupPeerNameCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_peer_name_cb_ = std::move(cb);
    if (tox_) tox_callback_conference_peer_name(tox_.get(), onGroupPeerName);
}

void ToxManager::setGroupPeerListChangedCallback(GroupPeerListChangedCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_peer_list_changed_cb_ = std::move(cb);
    if (tox_) tox_callback_conference_peer_list_changed(tox_.get(), onGroupPeerListChanged);
}

void ToxManager::setGroupConnectedCallback(GroupConnectedCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_connected_cb_ = std::move(cb);
    if (tox_) tox_callback_conference_connected(tox_.get(), onGroupConnected);
}

void ToxManager::setFriendLossyPacketCallback(FriendLossyPacketCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_lossy_packet_cb_ = std::move(cb);
    // Registration moved to initialize
    // tox_callback_friend_lossy_packet(tox_.get(), onFriendLossyPacket);
}

void ToxManager::setFriendLosslessPacketCallback(FriendLosslessPacketCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    friend_lossless_packet_cb_ = std::move(cb);
    if (tox_) tox_callback_friend_lossless_packet(tox_.get(), onFriendLosslessPacket);
}

// 用户信息相关实现
bool ToxManager::setName(const std::string& name) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return false;
    TOX_ERR_SET_INFO error;
    return tox_self_set_name(tox_.get(), 
        reinterpret_cast<const uint8_t*>(name.c_str()), 
        name.length(), &error) && error == TOX_ERR_SET_INFO_OK;
}

std::string ToxManager::getName() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return "";
    size_t length = tox_self_get_name_size(tox_.get());
    std::vector<uint8_t> name(length);
    tox_self_get_name(tox_.get(), name.data());
    return std::string(reinterpret_cast<char*>(name.data()), length);
}

bool ToxManager::setStatusMessage(const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return false;
    TOX_ERR_SET_INFO error;
    return tox_self_set_status_message(tox_.get(),
        reinterpret_cast<const uint8_t*>(message.c_str()),
        message.length(), &error) && error == TOX_ERR_SET_INFO_OK;
}

std::string ToxManager::getStatusMessage() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return "";
    size_t length = tox_self_get_status_message_size(tox_.get());
    std::vector<uint8_t> message(length);
    tox_self_get_status_message(tox_.get(), message.data());
    return std::string(reinterpret_cast<char*>(message.data()), length);
}

bool ToxManager::setStatus(TOX_USER_STATUS status) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        return false;
    }
    tox_self_set_status(tox_.get(), status);
    return true;
}

TOX_USER_STATUS ToxManager::getStatus() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return TOX_USER_STATUS_NONE;
    return tox_self_get_status(tox_.get());
}

std::string ToxManager::getAddress() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        return "";
    }
    std::vector<uint8_t> address(TOX_ADDRESS_SIZE);
    tox_self_get_address(tox_.get(), address.data());
    // Convert binary address to hexadecimal string
    std::string hex_address;
    hex_address.reserve(TOX_ADDRESS_SIZE * 2);
    for (uint8_t byte : address) {
        char hex[3];
        snprintf(hex, sizeof(hex), "%02X", byte);
        hex_address += hex;
    }
    return hex_address;
}

// 好友相关实现
uint32_t ToxManager::addFriend(const uint8_t* address, const uint8_t* message,
                              size_t length, TOX_ERR_FRIEND_ADD* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_FRIEND_ADD_NULL;
        return UINT32_MAX;
    }
    return tox_friend_add(tox_.get(), address, message, length, error);
}

bool ToxManager::deleteFriend(uint32_t friend_number, TOX_ERR_FRIEND_DELETE* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_FRIEND_DELETE_FRIEND_NOT_FOUND;
        return false;
    }
    return tox_friend_delete(tox_.get(), friend_number, error);
}

bool ToxManager::sendMessage(uint32_t friend_number, TOX_MESSAGE_TYPE type,
                           const uint8_t* message, size_t length, uint32_t* message_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return false;
    TOX_ERR_FRIEND_SEND_MESSAGE error;
    uint32_t res = tox_friend_send_message(tox_.get(), friend_number, type,
                                         message, length, &error);
    if (error != TOX_ERR_FRIEND_SEND_MESSAGE_OK) return false;
    if (message_id) *message_id = res;
    return true;
}

bool ToxManager::getFriendPublicKey(uint32_t friend_number, uint8_t* public_key) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return false;
    TOX_ERR_FRIEND_GET_PUBLIC_KEY error;
    return tox_friend_get_public_key(tox_.get(), friend_number, public_key, &error) &&
           error == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK;
}

std::string ToxManager::getFriendName(uint32_t friend_number) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return "";
    TOX_ERR_FRIEND_QUERY error;
    size_t length = tox_friend_get_name_size(tox_.get(), friend_number, &error);
    if (error != TOX_ERR_FRIEND_QUERY_OK) return "";
    std::vector<uint8_t> name(length);
    if (!tox_friend_get_name(tox_.get(), friend_number, name.data(), &error) ||
        error != TOX_ERR_FRIEND_QUERY_OK) return "";
    return std::string(reinterpret_cast<char*>(name.data()), length);
}

std::string ToxManager::getFriendStatusMessage(uint32_t friend_number) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return "";
    TOX_ERR_FRIEND_QUERY error;
    size_t length = tox_friend_get_status_message_size(tox_.get(), friend_number, &error);
    if (error != TOX_ERR_FRIEND_QUERY_OK) return "";
    std::vector<uint8_t> message(length);
    if (!tox_friend_get_status_message(tox_.get(), friend_number, message.data(), &error) ||
        error != TOX_ERR_FRIEND_QUERY_OK) return "";
    return std::string(reinterpret_cast<char*>(message.data()), length);
}

TOX_CONNECTION ToxManager::getFriendConnectionStatus(uint32_t friend_number) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return TOX_CONNECTION_NONE;
    TOX_ERR_FRIEND_QUERY error;
    return tox_friend_get_connection_status(tox_.get(), friend_number, &error);
}

TOX_USER_STATUS ToxManager::getFriendStatus(uint32_t friend_number) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return TOX_USER_STATUS_NONE;
    TOX_ERR_FRIEND_QUERY error;
    return tox_friend_get_status(tox_.get(), friend_number, &error);
}

bool ToxManager::getFriendLastOnline(uint32_t friend_number, time_t* last_online) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !last_online) return false;
    TOX_ERR_FRIEND_GET_LAST_ONLINE error;
    *last_online = tox_friend_get_last_online(tox_.get(), friend_number, &error);
    return error == TOX_ERR_FRIEND_GET_LAST_ONLINE_OK;
}

// 文件传输相关实现
uint32_t ToxManager::sendFile(uint32_t friend_number, uint32_t kind,
                            uint64_t file_size, const uint8_t* file_id,
                            const uint8_t* filename, size_t filename_length,
                            TOX_ERR_FILE_SEND* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_FILE_SEND_NULL;
        return UINT32_MAX;
    }
    return tox_file_send(tox_.get(), friend_number, kind, file_size,
                        file_id, filename, filename_length, error);
}

bool ToxManager::sendFileChunk(uint32_t friend_number, uint32_t file_number,
                             uint64_t position, const uint8_t* data, size_t length,
                             TOX_ERR_FILE_SEND_CHUNK* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_FILE_SEND_CHUNK_NULL;
        return false;
    }
    return tox_file_send_chunk(tox_.get(), friend_number, file_number,
                              position, data, length, error);
}

bool ToxManager::fileControl(uint32_t friend_number, uint32_t file_number,
                           TOX_FILE_CONTROL control, TOX_ERR_FILE_CONTROL* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_FILE_CONTROL_FRIEND_NOT_FOUND;
        return false;
    }
    return tox_file_control(tox_.get(), friend_number, file_number, control, error);
}

// 群组相关实现 (tox group API)
Tox_Group_Number ToxManager::createGroup(Tox_Group_Privacy_State privacy_state,
                                         const uint8_t* group_name, size_t group_name_length,
                                         const uint8_t* name, size_t name_length,
                                         Tox_Err_Group_New* error) {
    V2TIM_LOG(kDebug, "[ToxManager::createGroup] ENTRY - privacy_state={} (0=PUBLIC, 1=PRIVATE), group_name_length={}, name_length={}", static_cast<int>(privacy_state), group_name_length, name_length);
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_NEW_INIT;
        V2TIM_LOG(kError, "[ToxManager::createGroup] ERROR - tox_ is null");
        return UINT32_MAX;
    }
    Tox_Group_Number group_number = tox_group_new(tox_.get(), privacy_state, group_name, group_name_length, name, name_length, error);
    V2TIM_LOG(kDebug, "[ToxManager::createGroup] EXIT - group_number={}, error={}", group_number, error ? static_cast<int>(*error) : -1);
    if (error && *error == TOX_ERR_GROUP_NEW_OK && group_number != UINT32_MAX) {
        Tox_Err_Group_State_Query err_verify;
        Tox_Group_Privacy_State verify_state = tox_group_get_privacy_state(tox_.get(), group_number, &err_verify);
        V2TIM_LOG(kDebug, "[ToxManager::createGroup] Verified privacy_state after creation: {} (0=PUBLIC, 1=PRIVATE), err={}", static_cast<int>(verify_state), static_cast<int>(err_verify));
    }
    return group_number;
}

bool ToxManager::deleteGroup(Tox_Group_Number group_number, Tox_Err_Group_Leave* error) {
    V2TIM_LOG(kInfo, "ToxManager::deleteGroup: ENTRY - group_number=%u", group_number);
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        V2TIM_LOG(kError, "ToxManager::deleteGroup: ERROR - tox_ is null");
        if (error) *error = TOX_ERR_GROUP_LEAVE_GROUP_NOT_FOUND;
        return false;
    }
    V2TIM_LOG(kInfo, "ToxManager::deleteGroup: Calling tox_group_leave for group_number=%u", group_number);
    bool result = tox_group_leave(tox_.get(), group_number, nullptr, 0, error);
    if (result) {
        V2TIM_LOG(kInfo, "ToxManager::deleteGroup: SUCCESS - tox_group_leave returned true for group_number=%u", group_number);
    } else {
        int error_code = error ? *error : -1;
        V2TIM_LOG(kWarning, "ToxManager::deleteGroup: FAILED - tox_group_leave returned false for group_number=%u, error=%d", group_number, error_code);
    }
    V2TIM_LOG(kInfo, "ToxManager::deleteGroup: EXIT - result=%s", result ? "true" : "false");
    return result;
}

Tox_Group_Number ToxManager::joinGroup(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE],
                                      const uint8_t* name, size_t name_length,
                                      const uint8_t* password, size_t password_length,
                                      Tox_Err_Group_Join* error) {
    V2TIM_LOG(kDebug, "[ToxManager] joinGroup: ENTRY - chat_id={}, name_length={}, password_length={}", (void*)chat_id, name_length, password_length);

    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        V2TIM_LOG(kError, "[ToxManager] joinGroup: ERROR - tox_ is null");
        if (error) *error = TOX_ERR_GROUP_JOIN_INIT;
        return UINT32_MAX;
    }

    V2TIM_LOG(kDebug, "[ToxManager] joinGroup: Calling tox_group_join...");
    Tox_Group_Number group_number = tox_group_join(tox_.get(), chat_id, name, name_length, password, password_length, error);

    if (error) {
        V2TIM_LOG(kDebug, "[ToxManager] joinGroup: tox_group_join returned group_number={}, error={}", group_number, static_cast<int>(*error));
    } else {
        V2TIM_LOG(kDebug, "[ToxManager] joinGroup: tox_group_join returned group_number={}, error pointer is null", group_number);
    }

    V2TIM_LOG(kDebug, "[ToxManager] joinGroup: EXIT - group_number={}", group_number);
    return group_number;
}

bool ToxManager::groupSendMessage(Tox_Group_Number group_number, TOX_MESSAGE_TYPE type,
                                 const uint8_t* message, size_t length,
                                 Tox_Group_Message_Id* message_id,
                                 Tox_Err_Group_Send_Message* error) {
    V2TIM_LOG(kDebug, "[ToxManager] groupSendMessage: ENTRY - group_number={}, type={}, length={}", group_number, static_cast<int>(type), length);

    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        V2TIM_LOG(kError, "[ToxManager] groupSendMessage: ERROR - tox_ is null");
        if (error) *error = TOX_ERR_GROUP_SEND_MESSAGE_GROUP_NOT_FOUND;
        return false;
    }

    V2TIM_LOG(kDebug, "[ToxManager] groupSendMessage: About to call tox_group_send_message");

    Tox_Group_Message_Id msg_id = tox_group_send_message(tox_.get(), group_number, type, message, length, error);

    V2TIM_LOG(kDebug, "[ToxManager] groupSendMessage: tox_group_send_message returned: msg_id={}, error={}", (unsigned long long)msg_id, error ? static_cast<int>(*error) : -1);
    
    if (message_id && error && *error == TOX_ERR_GROUP_SEND_MESSAGE_OK) {
        *message_id = msg_id;
        V2TIM_LOG(kDebug, "[ToxManager] groupSendMessage: SUCCESS - message_id set to {}", (unsigned long long)msg_id);
    } else if (error) {
        V2TIM_LOG(kError, "[ToxManager] groupSendMessage: ERROR - error code={}", static_cast<int>(*error));
    }

    bool result = (error && *error == TOX_ERR_GROUP_SEND_MESSAGE_OK);
    V2TIM_LOG(kDebug, "[ToxManager] groupSendMessage: EXIT - returning {}", result ? 1 : 0);
    
    return result;
}

bool ToxManager::setGroupTopic(Tox_Group_Number group_number, const uint8_t* topic, size_t length,
                              Tox_Err_Group_Topic_Set* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_TOPIC_SET_GROUP_NOT_FOUND;
        return false;
    }
    return tox_group_set_topic(tox_.get(), group_number, topic, length, error);
}

bool ToxManager::getGroupTopic(Tox_Group_Number group_number, uint8_t* topic, size_t max_length,
                              Tox_Err_Group_State_Query* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !topic || max_length == 0) {
        if (error) *error = TOX_ERR_GROUP_STATE_QUERY_GROUP_NOT_FOUND;
        return false;
    }
    
    Tox_Err_Group_State_Query local_error = TOX_ERR_GROUP_STATE_QUERY_OK;
    Tox_Err_Group_State_Query* err = error ? error : &local_error;

    size_t topic_size = tox_group_get_topic_size(tox_.get(), group_number, err);
    if (topic_size == 0 || *err != TOX_ERR_GROUP_STATE_QUERY_OK) {
        return false;
    }

    if (topic_size > max_length) {
        *err = TOX_ERR_GROUP_STATE_QUERY_GROUP_NOT_FOUND;
        return false;
    }

    return tox_group_get_topic(tox_.get(), group_number, topic, err);
}

bool ToxManager::getGroupName(Tox_Group_Number group_number, uint8_t* name, size_t max_length,
                             Tox_Err_Group_State_Query* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !name || max_length == 0) {
        if (error) *error = TOX_ERR_GROUP_STATE_QUERY_GROUP_NOT_FOUND;
        return false;
    }
    
    Tox_Err_Group_State_Query local_error = TOX_ERR_GROUP_STATE_QUERY_OK;
    Tox_Err_Group_State_Query* err = error ? error : &local_error;

    size_t name_size = tox_group_get_name_size(tox_.get(), group_number, err);
    if (name_size == 0 || *err != TOX_ERR_GROUP_STATE_QUERY_OK) {
        return false;
    }

    if (name_size > max_length) {
        *err = TOX_ERR_GROUP_STATE_QUERY_GROUP_NOT_FOUND;
        return false;
    }

    return tox_group_get_name(tox_.get(), group_number, name, err);
}

bool ToxManager::getGroupPeerName(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                  uint8_t* name, size_t max_length,
                                  Tox_Err_Group_Peer_Query* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !name || max_length == 0) {
        if (error) *error = TOX_ERR_GROUP_PEER_QUERY_PEER_NOT_FOUND;
        return false;
    }
    
    Tox_Err_Group_Peer_Query local_error = TOX_ERR_GROUP_PEER_QUERY_OK;
    Tox_Err_Group_Peer_Query* err = error ? error : &local_error;

    size_t name_size = tox_group_peer_get_name_size(tox_.get(), group_number, peer_id, err);
    if (name_size == 0 || *err != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return false;
    }

    if (name_size > max_length) {
        *err = TOX_ERR_GROUP_PEER_QUERY_PEER_NOT_FOUND;
        return false;
    }

    return tox_group_peer_get_name(tox_.get(), group_number, peer_id, name, err);
}

uint32_t ToxManager::getGroupPeerCount(Tox_Group_Number group_number, Tox_Err_Group_Peer_Query* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_PEER_QUERY_GROUP_NOT_FOUND;
        return 0;
    }
    // toxcore's NGCv2 group API exposes no direct peer-count or peer-list function, so we
    // enumerate by probing peer ids with tox_group_peer_get_public_key (the same per-peer
    // validation GetGroupMemberList uses). toxcore assigns the lowest currently-unused id
    // (get_new_peer_id), so an active peer's id is always < the group's peer limit — probing
    // the full [0, peer_limit) range therefore covers every assignable id and makes the count
    // authoritative rather than an undercounting guess. (V2TIMGroupManagerImpl still keeps the
    // live peer set in a callback-populated cache — see GetGroupMemberList — as the primary
    // source; this is the fallback path.)
    Tox_Err_Group_Self_Query self_error = TOX_ERR_GROUP_SELF_QUERY_OK;
    Tox_Group_Peer_Number self_peer_id = tox_group_self_get_peer_id(tox_.get(), group_number, &self_error);
    if (self_error != TOX_ERR_GROUP_SELF_QUERY_OK) {
        if (error) *error = TOX_ERR_GROUP_PEER_QUERY_GROUP_NOT_FOUND;
        return 0;
    }

    // Probe the FULL assignable peer-id space, not [0, peer_limit). toxcore
    // assigns each peer the lowest currently-free id (get_new_peer_id), so a
    // live id is bounded only by the peak number of peers ever concurrently in
    // the group — which is bounded by max-peers, a uint16 (<= 65535). The
    // founder can LOWER max-peers below ids already handed out without
    // renumbering or evicting anyone (gc_founder_set_max_peers), so the current
    // peer_limit is NOT an upper bound on live ids; nor is a join-callback
    // high-water mark, since tox_group_peer_get_public_key also returns
    // not-yet-confirmed peers that never fired peer_join. UINT16_MAX+1 is the
    // only bound guaranteed to see every live peer. This is O(65536 * numpeers)
    // and is a fallback path — the authoritative member count is the
    // callback-populated cache in V2TIMGroupManagerImpl (GetGroupMemberList).
    constexpr uint32_t kMaxGroupPeerIdProbe = 65536u;

    uint32_t count = 1; // self is always a member of a group we belong to
    for (Tox_Group_Peer_Number peer_id = 0; peer_id < kMaxGroupPeerIdProbe; ++peer_id) {
        if (peer_id == self_peer_id) continue; // already counted as self
        uint8_t public_key[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Peer_Query peer_error = TOX_ERR_GROUP_PEER_QUERY_OK;
        if (tox_group_peer_get_public_key(tox_.get(), group_number, peer_id, public_key, &peer_error) &&
            peer_error == TOX_ERR_GROUP_PEER_QUERY_OK) {
            ++count;
        }
    }

    if (error) *error = TOX_ERR_GROUP_PEER_QUERY_OK;
    return count;
}

bool ToxManager::isGroupConnected(Tox_Group_Number group_number, Tox_Err_Group_Is_Connected* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_IS_CONNECTED_GROUP_NOT_FOUND;
        return false;
    }
    return tox_group_is_connected(tox_.get(), group_number, error);
}

// 群聊ID相关实现
bool ToxManager::getConferenceId(uint32_t conference_number, uint8_t id[TOX_CONFERENCE_ID_SIZE]) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !id) return false;
    return tox_conference_get_id(tox_.get(), conference_number, id);
}

uint32_t ToxManager::getConferenceById(const uint8_t id[TOX_CONFERENCE_ID_SIZE], TOX_ERR_CONFERENCE_BY_ID* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_CONFERENCE_BY_ID_NULL;
        return UINT32_MAX;
    }
    return tox_conference_by_id(tox_.get(), id, error);
}

Tox_Conference_Type ToxManager::getConferenceType(uint32_t conference_number, TOX_ERR_CONFERENCE_GET_TYPE* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_CONFERENCE_GET_TYPE_CONFERENCE_NOT_FOUND;
        return TOX_CONFERENCE_TYPE_TEXT; // Default
    }
    return tox_conference_get_type(tox_.get(), conference_number, error);
}

// Tox group API 实现
bool ToxManager::getGroupChatId(Tox_Group_Number group_number, uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE],
                                Tox_Err_Group_State_Query* error) {
    V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: ENTRY - group_number={}, chat_id={}, error={}", 
              group_number, (void*)chat_id, (void*)error);
    
    std::lock_guard<std::mutex> lock(mutex_);
    V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: Acquired mutex");
    
    V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: Checking tox_ and chat_id pointers");
    V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: tox_={}, chat_id={}", (void*)tox_.get(), (void*)chat_id);
    
    if (!tox_ || !chat_id) {
        V2TIM_LOG(kError, "ToxManager::getGroupChatId: ERROR - Invalid pointers: tox_={}, chat_id={}", 
                  (void*)tox_.get(), (void*)chat_id);
        if (error) {
            *error = TOX_ERR_GROUP_STATE_QUERY_GROUP_NOT_FOUND;
            V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: Set error to TOX_ERR_GROUP_STATE_QUERY_GROUP_NOT_FOUND");
        }
        V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: EXIT - Returning false due to invalid pointers");
        return false;
    }
    
    V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: Calling tox_group_get_chat_id");
    V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: Parameters: tox_={}, group_number={}, chat_id={}, error={}", 
              (void*)tox_.get(), group_number, (void*)chat_id, (void*)error);
    
    bool result = tox_group_get_chat_id(tox_.get(), group_number, chat_id, error);
    
    if (error) {
        V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: tox_group_get_chat_id returned: result={}, error={}", 
                  result, static_cast<int>(*error));
    } else {
        V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: tox_group_get_chat_id returned: result={}, error pointer is null", result);
    }
    
    if (result && error && *error == TOX_ERR_GROUP_STATE_QUERY_OK) {
        // Log first few bytes of chat_id for debugging (without exposing full value)
        std::ostringstream oss;
        size_t bytes_to_log = std::min(static_cast<size_t>(4), static_cast<size_t>(TOX_GROUP_CHAT_ID_SIZE));
        for (size_t i = 0; i < bytes_to_log; ++i) {
            oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
        }
        V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: Successfully retrieved chat_id, first {} bytes: {}", bytes_to_log, oss.str());
    }
    
    V2TIM_LOG(kInfo, "ToxManager::getGroupChatId: EXIT - Returning result={}", result);
    return result;
}

Tox_Group_Number ToxManager::getGroupByChatId(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !chat_id) {
        V2TIM_LOG(kDebug, "[ToxManager] getGroupByChatId: tox_={}, chat_id={}", (void*)tox_.get(), (void*)chat_id);
        return UINT32_MAX;
    }
    // toxcore does NOT guarantee group numbers are dense/sequential. Use the real
    // group-list API to obtain the actual valid group numbers and iterate only those.
    uint32_t group_count = tox_group_get_group_list_size(tox_.get());
    V2TIM_LOG(kDebug, "[ToxManager] getGroupByChatId: Searching through {} groups", group_count);

    std::ostringstream target_oss;
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        target_oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
    }
    std::string target_chat_id_hex = target_oss.str();
    V2TIM_LOG(kDebug, "[ToxManager] getGroupByChatId: Looking for chat_id={}", target_chat_id_hex.c_str());

    if (group_count == 0) {
        V2TIM_LOG(kDebug, "[ToxManager] getGroupByChatId: No groups present");
        return UINT32_MAX;
    }

    std::vector<Tox_Group_Number> group_numbers(group_count);
    tox_group_get_group_list(tox_.get(), group_numbers.data());

    for (uint32_t i = 0; i < group_count; ++i) {
        Tox_Group_Number group_number = group_numbers[i]; // real, possibly non-sequential group number
        uint8_t group_chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query error;
        if (tox_group_get_chat_id(tox_.get(), group_number, group_chat_id, &error)) {
            if (error == TOX_ERR_GROUP_STATE_QUERY_OK) {
                // Convert group chat_id to hex for logging
                std::ostringstream group_oss;
                for (size_t j = 0; j < TOX_GROUP_CHAT_ID_SIZE; ++j) {
                    group_oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(group_chat_id[j]);
                }
                std::string group_chat_id_hex = group_oss.str();

                if (memcmp(chat_id, group_chat_id, TOX_GROUP_CHAT_ID_SIZE) == 0) {
                    V2TIM_LOG(kDebug, "[ToxManager] getGroupByChatId: Found match! group_number={}, chat_id={}", group_number, group_chat_id_hex.c_str());
                    return group_number;
                }
            } else {
                V2TIM_LOG(kDebug, "[ToxManager] getGroupByChatId: Failed to get chat_id for group_number={}, error={}", group_number, static_cast<int>(error));
            }
        } else {
            V2TIM_LOG(kDebug, "[ToxManager] getGroupByChatId: tox_group_get_chat_id returned false for group_number={}", group_number);
        }
    }
    V2TIM_LOG(kDebug, "[ToxManager] getGroupByChatId: No match found for chat_id={} after checking {} groups", target_chat_id_hex.c_str(), group_count);
    return UINT32_MAX;
}

bool ToxManager::inviteToGroup(Tox_Group_Number group_number, Tox_Friend_Number friend_number,
                               Tox_Err_Group_Invite_Friend* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_INVITE_FRIEND_GROUP_NOT_FOUND;
        V2TIM_LOG(kError, "[ToxManager::inviteToGroup] ERROR: tox_ is null");
        return false;
    }

    TOX_CONNECTION friend_conn = tox_friend_get_connection_status(tox_.get(), friend_number, nullptr);
    V2TIM_LOG(kDebug, "[ToxManager::inviteToGroup] Friend {} connection status: {} (0=NONE, 1=UDP, 2=TCP) before invite", friend_number, static_cast<int>(friend_conn));

    bool result = tox_group_invite_friend(tox_.get(), group_number, friend_number, error);

    if (error) {
        const char* errorStr = "UNKNOWN";
        switch (*error) {
            case TOX_ERR_GROUP_INVITE_FRIEND_OK: errorStr = "OK"; break;
            case TOX_ERR_GROUP_INVITE_FRIEND_GROUP_NOT_FOUND: errorStr = "GROUP_NOT_FOUND"; break;
            case TOX_ERR_GROUP_INVITE_FRIEND_FRIEND_NOT_FOUND: errorStr = "FRIEND_NOT_FOUND"; break;
            case TOX_ERR_GROUP_INVITE_FRIEND_INVITE_FAIL: errorStr = "INVITE_FAIL"; break;
            case TOX_ERR_GROUP_INVITE_FRIEND_DISCONNECTED: errorStr = "DISCONNECTED"; break;
            case TOX_ERR_GROUP_INVITE_FRIEND_FAIL_SEND: errorStr = "FAIL_SEND"; break;
            default: errorStr = "UNKNOWN"; break;
        }
        V2TIM_LOG(kDebug, "[ToxManager::inviteToGroup] Result: success={}, error={} ({}), group_number={}, friend_number={}", result ? 1 : 0, static_cast<int>(*error), errorStr, group_number, friend_number);
    }
    
    return result;
}

bool ToxManager::kickGroupMember(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                 Tox_Err_Group_Kick_Peer* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_KICK_PEER_GROUP_NOT_FOUND;
        return false;
    }
    return tox_group_kick_peer(tox_.get(), group_number, peer_id, error);
}

bool ToxManager::setGroupMemberRole(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                    Tox_Group_Role role, Tox_Err_Group_Set_Role* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_SET_ROLE_GROUP_NOT_FOUND;
        return false;
    }
    return tox_group_set_role(tox_.get(), group_number, peer_id, role, error);
}

Tox_Group_Role ToxManager::getGroupMemberRole(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                              Tox_Err_Group_Peer_Query* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_PEER_QUERY_GROUP_NOT_FOUND;
        return TOX_GROUP_ROLE_USER;
    }
    return tox_group_peer_get_role(tox_.get(), group_number, peer_id, error);
}

Tox_Group_Role ToxManager::getSelfRole(Tox_Group_Number group_number, Tox_Err_Group_Self_Query* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_SELF_QUERY_GROUP_NOT_FOUND;
        return TOX_GROUP_ROLE_USER;
    }
    return tox_group_self_get_role(tox_.get(), group_number, error);
}

bool ToxManager::getGroupPeerPublicKey(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                      uint8_t public_key[TOX_PUBLIC_KEY_SIZE],
                                      Tox_Err_Group_Peer_Query* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !public_key) {
        if (error) *error = TOX_ERR_GROUP_PEER_QUERY_PEER_NOT_FOUND;
        return false;
    }
    return tox_group_peer_get_public_key(tox_.get(), group_number, peer_id, public_key, error);
}

bool ToxManager::isGroupPeerOurs(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                 Tox_Err_Group_Peer_Query* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_GROUP_PEER_QUERY_GROUP_NOT_FOUND;
        return false;
    }
    Tox_Err_Group_Self_Query self_error;
    Tox_Group_Peer_Number self_peer_id = tox_group_self_get_peer_id(tox_.get(), group_number, &self_error);
    if (self_error != TOX_ERR_GROUP_SELF_QUERY_OK) {
        if (error) *error = TOX_ERR_GROUP_PEER_QUERY_GROUP_NOT_FOUND;
        return false;
    }
    bool ours = (self_peer_id == peer_id);
    if (ours && error) *error = TOX_ERR_GROUP_PEER_QUERY_OK;
    return ours;
}

size_t ToxManager::getGroupListSize() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return 0;
    return tox_group_get_number_groups(tox_.get());
}

void ToxManager::getGroupList(Tox_Group_Number* group_list, size_t list_size) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !group_list || list_size == 0) return;
    // Group numbers are NOT guaranteed dense/sequential; obtain the real valid group
    // numbers via the toxcore list API, then copy up to list_size into the caller buffer.
    uint32_t count = tox_group_get_group_list_size(tox_.get());
    if (count == 0) return;
    std::vector<Tox_Group_Number> group_numbers(count);
    tox_group_get_group_list(tox_.get(), group_numbers.data());
    for (size_t i = 0; i < list_size && i < count; ++i) {
        group_list[i] = group_numbers[i];
    }
}

// 保留旧的 conference API 用于兼容性（已废弃）
bool ToxManager::inviteToConference(uint32_t friend_number, uint32_t conference_number, TOX_ERR_CONFERENCE_INVITE* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_CONFERENCE_INVITE_CONFERENCE_NOT_FOUND;
        return false;
    }
    return tox_conference_invite(tox_.get(), friend_number, conference_number, error);
}

size_t ToxManager::getConferenceListSize() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return 0;
    return tox_conference_get_chatlist_size(tox_.get());
}

void ToxManager::getConferenceList(uint32_t* chatlist, size_t list_size) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !chatlist || list_size == 0) return;
    tox_conference_get_chatlist(tox_.get(), chatlist);
}

bool ToxManager::getConferencePeerPublicKey(uint32_t conference_number, uint32_t peer_number, uint8_t public_key[TOX_PUBLIC_KEY_SIZE], TOX_ERR_CONFERENCE_PEER_QUERY* error) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !public_key) {
        if (error) *error = TOX_ERR_CONFERENCE_PEER_QUERY_PEER_NOT_FOUND;
        return false;
    }
    return tox_conference_peer_get_public_key(tox_.get(), conference_number, peer_number, public_key, error);
}

bool ToxManager::isConferencePeerOurs(uint32_t conference_number, uint32_t peer_number, TOX_ERR_CONFERENCE_PEER_QUERY* error) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_CONFERENCE_PEER_QUERY_NO_CONNECTION;
        return false;
    }
    return tox_conference_peer_number_is_ours(tox_.get(), conference_number, peer_number, error);
}

bool ToxManager::getConferenceTitle(uint32_t conference_number, uint8_t* title, size_t max_length, TOX_ERR_CONFERENCE_TITLE* error) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !title || max_length == 0) {
        if (error) *error = TOX_ERR_CONFERENCE_TITLE_CONFERENCE_NOT_FOUND;
        return false;
    }
    
    TOX_ERR_CONFERENCE_TITLE local_error = TOX_ERR_CONFERENCE_TITLE_OK;
    TOX_ERR_CONFERENCE_TITLE* err = error ? error : &local_error;

    // Get title size first
    size_t title_size = tox_conference_get_title_size(tox_.get(), conference_number, err);
    if (title_size == 0 || *err != TOX_ERR_CONFERENCE_TITLE_OK) {
        return false;
    }

    // Check if buffer is large enough
    if (title_size > max_length) {
        *err = TOX_ERR_CONFERENCE_TITLE_INVALID_LENGTH;
        return false;
    }

    // Get the actual title
    return tox_conference_get_title(tox_.get(), conference_number, title, err);
}

// 离线成员相关实现
uint32_t ToxManager::getConferenceOfflinePeerCount(uint32_t conference_number, TOX_ERR_CONFERENCE_PEER_QUERY* error) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_CONFERENCE_PEER_QUERY_CONFERENCE_NOT_FOUND;
        return 0;
    }
    return tox_conference_offline_peer_count(tox_.get(), conference_number, error);
}

size_t ToxManager::getConferenceOfflinePeerNameSize(uint32_t conference_number, uint32_t offline_peer_number, TOX_ERR_CONFERENCE_PEER_QUERY* error) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_CONFERENCE_PEER_QUERY_CONFERENCE_NOT_FOUND;
        return 0;
    }
    return tox_conference_offline_peer_get_name_size(tox_.get(), conference_number, offline_peer_number, error);
}

bool ToxManager::getConferenceOfflinePeerName(uint32_t conference_number, uint32_t offline_peer_number, uint8_t* name, size_t max_length, TOX_ERR_CONFERENCE_PEER_QUERY* error) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !name || max_length == 0) {
        if (error) *error = TOX_ERR_CONFERENCE_PEER_QUERY_PEER_NOT_FOUND;
        return false;
    }
    
    TOX_ERR_CONFERENCE_PEER_QUERY local_error = TOX_ERR_CONFERENCE_PEER_QUERY_OK;
    TOX_ERR_CONFERENCE_PEER_QUERY* err = error ? error : &local_error;

    // Get name size first
    size_t name_size = tox_conference_offline_peer_get_name_size(tox_.get(), conference_number, offline_peer_number, err);
    if (name_size == 0 || *err != TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
        return false;
    }

    // Check if buffer is large enough
    if (name_size > max_length) {
        *err = TOX_ERR_CONFERENCE_PEER_QUERY_PEER_NOT_FOUND;
        return false;
    }

    // Get the actual name
    return tox_conference_offline_peer_get_name(tox_.get(), conference_number, offline_peer_number, name, err);
}

bool ToxManager::getConferenceOfflinePeerPublicKey(uint32_t conference_number, uint32_t offline_peer_number, uint8_t public_key[TOX_PUBLIC_KEY_SIZE], TOX_ERR_CONFERENCE_PEER_QUERY* error) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_ || !public_key) {
        if (error) *error = TOX_ERR_CONFERENCE_PEER_QUERY_PEER_NOT_FOUND;
        return false;
    }
    return tox_conference_offline_peer_get_public_key(tox_.get(), conference_number, offline_peer_number, public_key, error);
}

uint64_t ToxManager::getConferenceOfflinePeerLastActive(uint32_t conference_number, uint32_t offline_peer_number, TOX_ERR_CONFERENCE_PEER_QUERY* error) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_CONFERENCE_PEER_QUERY_CONFERENCE_NOT_FOUND;
        return 0;
    }
    return tox_conference_offline_peer_get_last_active(tox_.get(), conference_number, offline_peer_number, error);
}

bool ToxManager::setConferenceMaxOffline(uint32_t conference_number, uint32_t max_offline, TOX_ERR_CONFERENCE_SET_MAX_OFFLINE* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) {
        if (error) *error = TOX_ERR_CONFERENCE_SET_MAX_OFFLINE_CONFERENCE_NOT_FOUND;
        return false;
    }
    return tox_conference_set_max_offline(tox_.get(), conference_number, max_offline, error);
}

// 数据保存和加载实现
std::vector<uint8_t> ToxManager::getSaveData() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tox_) return {};
    
    size_t size = tox_get_savedata_size(tox_.get());
    std::vector<uint8_t> data(size);
    tox_get_savedata(tox_.get(), data.data());
    return data;
}

bool ToxManager::saveTo(const std::string& path) const {
    try {
        auto data = getSaveData();
        if (data.empty()) return false;

        // Atomic, durable save: write to a temp file, flush to disk, restrict
        // permissions to 0600, then atomically rename over the destination. On any
        // failure the temp file is removed and the existing valid file is left intact.
        const std::string tmp_path = path + ".tmp";

#ifndef _WIN32
        // POSIX atomic + durable save.
        // Open with O_TRUNC so a stale temp from a previous crash is overwritten.
        int fd = ::open(tmp_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) {
            return false;
        }

        // Ensure mode is 0600 even if a restrictive umask altered the open() mode.
        if (::chmod(tmp_path.c_str(), 0600) != 0) {
            ::close(fd);
            ::remove(tmp_path.c_str());
            return false;
        }

        const char* buf = reinterpret_cast<const char*>(data.data());
        size_t remaining = data.size();
        size_t offset = 0;
        while (remaining > 0) {
            ssize_t written = ::write(fd, buf + offset, remaining);
            if (written < 0) {
                if (errno == EINTR) continue; // interrupted, retry
                ::close(fd);
                ::remove(tmp_path.c_str());
                return false;
            }
            offset += static_cast<size_t>(written);
            remaining -= static_cast<size_t>(written);
        }

        // Flush file contents to disk before rename so the rename can't expose a
        // truncated/empty file after a crash.
        if (::fsync(fd) != 0) {
            ::close(fd);
            ::remove(tmp_path.c_str());
            return false;
        }
        if (::close(fd) != 0) {
            ::remove(tmp_path.c_str());
            return false;
        }

        // Atomic replace of the destination.
        if (::rename(tmp_path.c_str(), path.c_str()) != 0) {
            ::remove(tmp_path.c_str());
            return false;
        }

        // Flush the parent directory so the rename's directory entry is itself
        // durable. Without this, a crash right after rename() can lose the new
        // name even though the file contents were fsync'd. Best-effort: the
        // data is already atomically in place, so a failure here is non-fatal.
        {
            const auto slash = path.find_last_of('/');
            const std::string dir = (slash == std::string::npos)
                                        ? std::string(".")
                                        : path.substr(0, slash == 0 ? 1 : slash);
            int dir_fd = ::open(dir.c_str(), O_RDONLY
#ifdef O_DIRECTORY
                                    | O_DIRECTORY
#endif
            );
            if (dir_fd >= 0) {
                ::fsync(dir_fd);
                ::close(dir_fd);
            }
        }

        return true;
#else
        // Windows fallback: the POSIX fd/fsync/chmod headers are excluded under
        // _WIN32, so write via ofstream, flush, then atomically replace with
        // std::filesystem::rename (MoveFileEx + REPLACE_EXISTING underneath).
        // File permissions are governed by the user profile's ACLs.
        {
            std::ofstream out(tmp_path, std::ios::binary | std::ios::trunc);
            if (!out) return false;
            out.write(reinterpret_cast<const char*>(data.data()),
                      static_cast<std::streamsize>(data.size()));
            out.flush();
            if (!out) {
                out.close();
                std::remove(tmp_path.c_str());
                return false;
            }
            out.close();
        }
        std::error_code ec;
        std::filesystem::rename(tmp_path, path, ec);
        if (ec) {
            std::remove(tmp_path.c_str());
            return false;
        }
        return true;
#endif
    } catch (const std::exception&) {
        return false;
    }
}

bool ToxManager::loadFrom(const std::string& path) {
    try {
        std::ifstream file(path, std::ios::binary | std::ios::ate);
        if (!file) return false;

        auto size = file.tellg();
        if (size <= 0) return false;

        std::vector<uint8_t> data(size);
        file.seekg(0);
        file.read(reinterpret_cast<char*>(data.data()), size);

        // 创建新的 Tox 选项。
        // 必须零初始化：新版 c-toxcore 的 tox_options_default() 在赋默认值之前
        // 会先调用 tox_options_set_proxy_host(options, nullptr)，该函数读取
        // options->experimental_owned_data，若为真还会 free(options->owned_proxy_host)。
        // 未初始化的栈内存会让这两个字段是垃圾值，从而 free() 野指针导致 SIGSEGV。
        // tox_options_new() 走 calloc 不受影响，唯独这里的栈分配需要显式清零。
        Tox_Options options{};
        tox_options_default(&options);
        options.savedata_type = TOX_SAVEDATA_TYPE_TOX_SAVE;
        options.savedata_data = data.data();
        options.savedata_length = data.size();

        // 初始化 Tox（若存档加密或损坏会抛异常，此处捕获并返回 false）
        initialize(&options, data.data(), data.size());
        return getTox() != nullptr;
    } catch (const std::exception&) {
        return false;
    }
}

// Tox group 回调实现
void ToxManager::onGroupInviteGroup(Tox* tox, Tox_Friend_Number friend_number, const uint8_t* invite_data, size_t invite_data_length, const uint8_t* group_name, size_t group_name_length, void* user_data) {
    // Use global mapping since tox_callback_group_invite doesn't support user_data
    ToxManager* manager = getManagerFromTox(tox);
    if (manager && manager->group_invite_group_cb_) {
        manager->group_invite_group_cb_(friend_number, invite_data, invite_data_length);
    }
}

void ToxManager::onGroupMessageGroup(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id, void* user_data) {
    // Use global mapping since tox_callback_group_message doesn't support user_data
    // [tim2tox-debug] Record callback trigger and message parameters for ToxManager::onGroupMessageGroup
    V2TIM_LOG(kInfo, "[tim2tox-debug] ToxManager::onGroupMessageGroup: Callback triggered - group_number={}, peer_id={}, type={}, length={}, message_id={}", 
             group_number, peer_id, static_cast<int>(type), length, message_id);
    V2TIM_LOG(kDebug, "[ToxManager] onGroupMessageGroup: ENTRY - group_number={}, peer_id={}, type={}, length={}, message_id={}", group_number, peer_id, static_cast<int>(type), length, (unsigned long long)message_id);

    ToxManager* manager = getManagerFromTox(tox);
    V2TIM_LOG(kDebug, "[ToxManager] onGroupMessageGroup: manager={}, callback={}", (void*)manager, manager && manager->group_message_group_cb_ ? (void*)1 : (void*)0);

    if (manager && manager->group_message_group_cb_) {
        V2TIM_LOG(kInfo, "[tim2tox-debug] ToxManager::onGroupMessageGroup: Calling callback - manager={}, has_callback=1", (void*)manager);
        manager->group_message_group_cb_(group_number, peer_id, type, message, length, message_id);
        V2TIM_LOG(kInfo, "[tim2tox-debug] ToxManager::onGroupMessageGroup: Callback completed");
    } else {
        V2TIM_LOG(kError, "[tim2tox-debug] ToxManager::onGroupMessageGroup: ERROR - manager={}, has_callback={}", (void*)manager, manager && manager->group_message_group_cb_ ? 1 : 0);
    }
}

void ToxManager::onGroupPrivateMessage(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t message_length, Tox_Group_Message_Id message_id, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager] onGroupPrivateMessage: group_number={} peer_id={} type={} len={}", group_number, peer_id, type, message_length);
    ToxManager* manager = getManagerFromTox(tox);
    if (manager && manager->group_private_message_group_cb_) {
        manager->group_private_message_group_cb_(group_number, peer_id, type, message, message_length, message_id);
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] onGroupPrivateMessage: manager={} has_cb={}", (void*)manager, manager ? (manager->group_private_message_group_cb_ ? 1 : 0) : 0);
    }
}

void ToxManager::onGroupTopic(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* topic, size_t length, void* user_data) {
    // Use global mapping since tox_callback_group_topic doesn't support user_data
    ToxManager* manager = getManagerFromTox(tox);
    if (manager && manager->group_topic_cb_) {
        manager->group_topic_cb_(group_number, peer_id, topic, length);
    }
}

void ToxManager::onGroupPeerNameGroup(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* name, size_t length, void* user_data) {
    // Use global mapping since tox_callback_group_peer_name doesn't support user_data
    ToxManager* manager = getManagerFromTox(tox);
    if (manager && manager->group_peer_name_group_cb_) {
        manager->group_peer_name_group_cb_(group_number, peer_id, name, length);
    }
}

void ToxManager::onGroupPeerJoin(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, void* user_data) {
    // Get timestamp for detailed timing
    auto callback_timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    
    // Log which instance is receiving peer join callback (for multi-instance debugging)
    // Note: GetCurrentInstanceId is defined in tim2tox_ffi.cpp as a C++ function
    extern int64_t GetCurrentInstanceId();
    int64_t current_instance_id = GetCurrentInstanceId();
    V2TIM_LOG(kDebug, "[ToxManager] onGroupPeerJoin: ENTRY - callback_timestamp_ms={}, instance_id={}, group_number={}, peer_id={}, user_data={}", (long long)callback_timestamp_ms, (long long)current_instance_id, group_number, peer_id, user_data);
    ToxManager* manager = getManagerFromTox(tox);
    V2TIM_LOG(kDebug, "[ToxManager] onGroupPeerJoin: manager={}, group_peer_join_cb_={}", (void*)manager, manager && manager->group_peer_join_cb_ ? (void*)1 : (void*)0);
    V2TIM_LOG(kDebug, "[ToxManager] onGroupPeerJoin: tox={}, current_instance_id={}", (void*)tox, (long long)current_instance_id);
    if (manager && manager->group_peer_join_cb_) {
        V2TIM_LOG(kDebug, "[ToxManager] onGroupPeerJoin: Calling callback for group_number={}, peer_id={}", group_number, peer_id);
        manager->group_peer_join_cb_(group_number, peer_id);
        V2TIM_LOG(kDebug, "[ToxManager] onGroupPeerJoin: Callback completed for group_number={}, peer_id={}", group_number, peer_id);
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] onGroupPeerJoin: WARNING - manager={} or callback is null", (void*)manager);
    }
}

void ToxManager::onGroupPeerExit(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, Tox_Group_Exit_Type exit_type, const uint8_t* name, size_t name_length, const uint8_t* part_message, size_t part_message_length, void* user_data) {
    // Use global mapping since tox_callback_group_peer_exit doesn't support user_data
    ToxManager* manager = getManagerFromTox(tox);
    if (manager && manager->group_peer_exit_cb_) {
        manager->group_peer_exit_cb_(group_number, peer_id, exit_type, name, name_length);
    }
}

void ToxManager::onGroupModeration(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number source_peer_id, Tox_Group_Peer_Number target_peer_id, Tox_Group_Mod_Event mod_type, void* user_data) {
    // Use global mapping since tox_callback_group_moderation doesn't support user_data
    ToxManager* manager = getManagerFromTox(tox);
    if (manager && manager->group_moderation_cb_) {
        manager->group_moderation_cb_(group_number, source_peer_id, target_peer_id, mod_type);
    }
}

void ToxManager::onGroupSelfJoin(Tox* tox, Tox_Group_Number group_number, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager] onGroupSelfJoin: called with group_number={}, user_data={}", group_number, user_data);
    ToxManager* manager = getManagerFromTox(tox);
    V2TIM_LOG(kDebug, "[ToxManager] onGroupSelfJoin: manager={}, group_self_join_cb_={}", (void*)manager, manager && manager->group_self_join_cb_ ? (void*)1 : (void*)0);
    if (manager && manager->group_self_join_cb_) {
        V2TIM_LOG(kDebug, "[ToxManager] onGroupSelfJoin: Calling callback for group_number={}", group_number);
        manager->group_self_join_cb_(group_number);
        V2TIM_LOG(kDebug, "[ToxManager] onGroupSelfJoin: Callback completed for group_number={}", group_number);
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] onGroupSelfJoin: WARNING - manager={} or callback is null", (void*)manager);
    }
}

void ToxManager::onGroupJoinFail(Tox* tox, Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager] onGroupJoinFail: called with group_number={}, fail_type={}, user_data={}", group_number, static_cast<int>(fail_type), user_data);
    ToxManager* manager = getManagerFromTox(tox);
    V2TIM_LOG(kDebug, "[ToxManager] onGroupJoinFail: manager={}, group_join_fail_cb_={}", (void*)manager, manager && manager->group_join_fail_cb_ ? (void*)1 : (void*)0);
    if (manager && manager->group_join_fail_cb_) {
        V2TIM_LOG(kDebug, "[ToxManager] onGroupJoinFail: Calling callback for group_number={}, fail_type={}", group_number, static_cast<int>(fail_type));
        manager->group_join_fail_cb_(group_number, fail_type);
        V2TIM_LOG(kDebug, "[ToxManager] onGroupJoinFail: Callback completed for group_number={}", group_number);
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] onGroupJoinFail: WARNING - manager={} or callback is null", (void*)manager);
    }
}

void ToxManager::onGroupPrivacyState(Tox* tox, Tox_Group_Number group_number, Tox_Group_Privacy_State privacy_state, void* user_data) {
    V2TIM_LOG(kDebug, "[ToxManager] onGroupPrivacyState: ENTRY - group_number={}, privacy_state={} (0=PUBLIC, 1=PRIVATE)", group_number, static_cast<int>(privacy_state));
    ToxManager* manager = getManagerFromTox(tox);
    V2TIM_LOG(kDebug, "[ToxManager] onGroupPrivacyState: manager={}, group_privacy_state_cb_={}", (void*)manager, manager && manager->group_privacy_state_cb_ ? (void*)1 : (void*)0);
    if (manager && manager->group_privacy_state_cb_) {
        V2TIM_LOG(kDebug, "[ToxManager] onGroupPrivacyState: Calling callback for group_number={}, privacy_state={}", group_number, static_cast<int>(privacy_state));
        manager->group_privacy_state_cb_(group_number, privacy_state);
        V2TIM_LOG(kDebug, "[ToxManager] onGroupPrivacyState: Callback completed");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] onGroupPrivacyState: WARNING - manager={} or callback is null", (void*)manager);
    }
}

void ToxManager::onGroupVoiceState(Tox* tox, Tox_Group_Number group_number, Tox_Group_Voice_State voice_state, void* user_data) {
    // Use global mapping since tox_callback_group_voice_state doesn't support user_data
    ToxManager* manager = getManagerFromTox(tox);
    if (manager && manager->group_voice_state_cb_) {
        manager->group_voice_state_cb_(group_number, voice_state);
    }
}

void ToxManager::onGroupPeerStatus(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_USER_STATUS status, void* user_data) {
    // Use global mapping since tox_callback_group_peer_status doesn't support user_data
    ToxManager* manager = getManagerFromTox(tox);
    if (manager && manager->group_peer_status_cb_) {
        manager->group_peer_status_cb_(group_number, peer_id, status);
    }
}

// Tox group 回调设置函数
void ToxManager::setGroupInviteGroupCallback(GroupInviteGroupCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_invite_group_cb_ = std::move(cb);
    if (tox_) tox_callback_group_invite(tox_.get(), onGroupInviteGroup);
}

void ToxManager::setGroupMessageGroupCallback(GroupMessageGroupCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_message_group_cb_ = std::move(cb);
    V2TIM_LOG(kDebug, "[ToxManager] setGroupMessageGroupCallback: ENTRY - tox_={}, callback={}", (void*)tox_.get(), group_message_group_cb_ ? (void*)1 : (void*)0);
    if (tox_) {
        V2TIM_LOG(kDebug, "[ToxManager] setGroupMessageGroupCallback: Registering tox_callback_group_message");
        tox_callback_group_message(tox_.get(), onGroupMessageGroup);
        V2TIM_LOG(kDebug, "[ToxManager] setGroupMessageGroupCallback: tox_callback_group_message registered");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] setGroupMessageGroupCallback: WARNING - tox_ is null, callback will be registered when tox_ is created");
    }
}

void ToxManager::setGroupPrivateMessageGroupCallback(GroupPrivateMessageGroupCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_private_message_group_cb_ = std::move(cb);
    if (tox_) {
        tox_callback_group_private_message(tox_.get(), onGroupPrivateMessage);
    }
}

void ToxManager::setGroupTopicCallback(GroupTopicCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_topic_cb_ = std::move(cb);
    if (tox_) tox_callback_group_topic(tox_.get(), onGroupTopic);
}

void ToxManager::setGroupPeerNameGroupCallback(GroupPeerNameGroupCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_peer_name_group_cb_ = std::move(cb);
    if (tox_) tox_callback_group_peer_name(tox_.get(), onGroupPeerNameGroup);
}

void ToxManager::setGroupPeerJoinCallback(GroupPeerJoinCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_peer_join_cb_ = std::move(cb);
    V2TIM_LOG(kDebug, "[ToxManager] setGroupPeerJoinCallback: ENTRY - cb={}, tox_={}", cb ? (void*)1 : (void*)0, (void*)tox_.get());
    if (tox_) {
        tox_callback_group_peer_join(tox_.get(), onGroupPeerJoin);
        V2TIM_LOG(kDebug, "[ToxManager] setGroupPeerJoinCallback: Registered callback with tox_callback_group_peer_join");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] setGroupPeerJoinCallback: WARNING - tox_ is null, callback not registered");
    }
    V2TIM_LOG(kDebug, "[ToxManager] setGroupPeerJoinCallback: EXIT");
}

void ToxManager::setGroupPeerExitCallback(GroupPeerExitCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_peer_exit_cb_ = std::move(cb);
    if (tox_) tox_callback_group_peer_exit(tox_.get(), onGroupPeerExit);
}

void ToxManager::setGroupModerationCallback(GroupModerationCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_moderation_cb_ = std::move(cb);
    if (tox_) tox_callback_group_moderation(tox_.get(), onGroupModeration);
}

void ToxManager::setGroupSelfJoinCallback(GroupSelfJoinCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_self_join_cb_ = std::move(cb);
    V2TIM_LOG(kDebug, "[ToxManager] setGroupSelfJoinCallback: ENTRY - cb={}, tox_={}", cb ? (void*)1 : (void*)0, (void*)tox_.get());
    if (tox_) {
        tox_callback_group_self_join(tox_.get(), onGroupSelfJoin);
        V2TIM_LOG(kDebug, "[ToxManager] setGroupSelfJoinCallback: Registered callback with tox_callback_group_self_join");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] setGroupSelfJoinCallback: WARNING - tox_ is null, callback not registered");
    }
    V2TIM_LOG(kDebug, "[ToxManager] setGroupSelfJoinCallback: EXIT");
}

void ToxManager::setGroupJoinFailCallback(GroupJoinFailCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_join_fail_cb_ = std::move(cb);
    V2TIM_LOG(kDebug, "[ToxManager] setGroupJoinFailCallback: ENTRY - cb={}, tox_={}", cb ? (void*)1 : (void*)0, (void*)tox_.get());
    if (tox_) {
        tox_callback_group_join_fail(tox_.get(), onGroupJoinFail);
        V2TIM_LOG(kDebug, "[ToxManager] setGroupJoinFailCallback: Registered callback with tox_callback_group_join_fail");
    } else {
        V2TIM_LOG(kWarning, "[ToxManager] setGroupJoinFailCallback: WARNING - tox_ is null, callback not registered");
    }
    V2TIM_LOG(kDebug, "[ToxManager] setGroupJoinFailCallback: EXIT");
}

void ToxManager::setGroupPrivacyStateCallback(GroupPrivacyStateCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_privacy_state_cb_ = std::move(cb);
    if (tox_) tox_callback_group_privacy_state(tox_.get(), onGroupPrivacyState);
}

void ToxManager::setGroupVoiceStateCallback(GroupVoiceStateCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_voice_state_cb_ = std::move(cb);
    if (tox_) tox_callback_group_voice_state(tox_.get(), onGroupVoiceState);
}

void ToxManager::setGroupPeerStatusCallback(GroupPeerStatusCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_peer_status_cb_ = std::move(cb);
    if (tox_) tox_callback_group_peer_status(tox_.get(), onGroupPeerStatus);
}