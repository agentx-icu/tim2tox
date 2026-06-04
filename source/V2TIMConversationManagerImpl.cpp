#include "V2TIMConversationManagerImpl.h"
#include "toxcore/tox.h"
#include <algorithm>
#include "ToxManager.h"
#include "V2TIMManager.h"
#include "V2TIMManagerImpl.h"
#include "V2TIMMessageManager.h"
#include "V2TIMMessageManagerImpl.h" // C2CRecvOptForUser: authoritative mute/DND lookup
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <chrono>
#include <thread>
#include "V2TIMLog.h"
#include "TIMResultDefine.h"

// Conversation-specific error codes
namespace {
    constexpr int ERR_SDK_CONVERSATION_NOT_FOUND = 6010;
}

// Multi-instance-aware manager accessor (defined in V2TIMManagerImpl.cpp);
// also forward-declared further down for the older call sites.
extern V2TIMManager* SafeGetV2TIMManager(void);

// Authoritative C2C receive-option (mute/DND) lookup. Reads the message
// manager's in-memory opt map so EVERY C2C conversation emit/materialization
// carries the current value. Any path that hardcodes recvOpt=0 for a C2C
// conversation re-emits a stale "un-muted" state, which the Dart projection
// cache (C2CRecvOptCache) would treat as authoritative and persist — silently
// clearing a user's mute (the recvOpt "clobber" bug). Returns 0 on any failure.
static int C2CRecvOptForUser(const std::string& userID) {
    if (userID.empty()) return 0;
    try {
        V2TIMManager* mgr = SafeGetV2TIMManager();
        if (!mgr) return 0;
        auto* mm = dynamic_cast<V2TIMMessageManagerImpl*>(mgr->GetMessageManager());
        if (!mm) return 0;
        return mm->GetC2CReceiveOptSync(userID);
    } catch (...) {
        return 0;
    }
}

static ConversationSnapshot ToSnapshot(const V2TIMConversation& c) {
    ConversationSnapshot s;
    s.conversation_id = c.conversationID.CString() ? c.conversationID.CString() : "";
    s.user_id = c.userID.CString() ? c.userID.CString() : "";
    s.group_id = c.groupID.CString() ? c.groupID.CString() : "";
    s.group_type = c.groupType.CString() ? c.groupType.CString() : "";
    s.show_name = c.showName.CString() ? c.showName.CString() : "";
    s.face_url = c.faceUrl.CString() ? c.faceUrl.CString() : "";
    s.draft_text = c.draftText.CString() ? c.draftText.CString() : "";
    s.unread_count = c.unreadCount;
    s.recv_opt = static_cast<int>(c.recvOpt);
    s.draft_timestamp = c.draftTimestamp;
    s.order_key = c.orderKey;
    s.c2c_read_timestamp = c.c2cReadTimestamp;
    s.group_read_sequence = c.groupReadSequence;
    s.is_pinned = c.isPinned;
    s.type = static_cast<int>(c.type);
    return s;
}

static V2TIMConversation MaterializeConversation(const ConversationSnapshot& s) {
    V2TIMConversation conv;
    conv.conversationID = s.conversation_id.c_str();
    conv.userID = s.user_id.c_str();
    conv.groupID = s.group_id.c_str();
    conv.groupType = s.group_type.c_str();
    conv.showName = s.show_name.c_str();
    conv.faceUrl = s.face_url.c_str();
    conv.draftText = s.draft_text.c_str();
    conv.unreadCount = s.unread_count;
    // C2C recvOpt: the message manager's opt map is the single source of truth
    // (see C2CRecvOptForUser). Snapshots can be created or rebuilt with a default
    // recv_opt (CreateConversationFromFriend, RefreshConversationCache), so the
    // stored snapshot value may be stale — always read the live map for C2C.
    if (static_cast<V2TIMConversationType>(s.type) == V2TIM_C2C) {
        std::string uid = s.user_id;
        if (uid.empty() && s.conversation_id.rfind("c2c_", 0) == 0) {
            uid = s.conversation_id.substr(4);
        }
        conv.recvOpt = static_cast<V2TIMReceiveMessageOpt>(C2CRecvOptForUser(uid));
    } else {
        conv.recvOpt = static_cast<V2TIMReceiveMessageOpt>(s.recv_opt);
    }
    conv.draftTimestamp = s.draft_timestamp;
    conv.orderKey = s.order_key;
    conv.c2cReadTimestamp = s.c2c_read_timestamp;
    conv.groupReadSequence = s.group_read_sequence;
    conv.isPinned = s.is_pinned;
    conv.type = static_cast<V2TIMConversationType>(s.type);
    conv.lastMessage = nullptr;  // By design: cache does not own message pointers
    return conv;
}

// Constructor (R-06: owned by V2TIMManagerImpl, no singleton)
V2TIMConversationManagerImpl::V2TIMConversationManagerImpl(V2TIMManagerImpl* owner)
    : last_friend_count_(0), last_refresh_time_(std::chrono::steady_clock::now()), manager_impl_(owner) {
    RefreshConversationCache();
}

V2TIMConversationManagerImpl::~V2TIMConversationManagerImpl() {
    // 清理资源
}

// 监听器管理
void V2TIMConversationManagerImpl::AddConversationListener(V2TIMConversationListener* listener) {
    std::lock_guard<std::mutex> lock(listeners_mutex_);
    listeners_.push_back(listener);
}

void V2TIMConversationManagerImpl::RemoveConversationListener(V2TIMConversationListener* listener) {
    std::lock_guard<std::mutex> lock(listeners_mutex_);
    listeners_.erase(std::remove(listeners_.begin(), listeners_.end(), listener), listeners_.end());
}

void V2TIMConversationManagerImpl::NotifyConversationChangedForConvID(const V2TIMString& conversationID) {
    const char* cid_cstr = conversationID.CString();
    if (!cid_cstr || !*cid_cstr) return;
    const std::string conv_id(cid_cstr);

    V2TIMConversation conv;
    bool materialized = false;
    {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        auto it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                               [&](const ConversationSnapshot& s) { return s.conversation_id == conv_id; });
        if (it != cached_conversations_.end()) {
            conv = MaterializeConversation(*it);
            materialized = true;
        }
    }
    if (!materialized) {
        // Full minimal initialization — mirror MaterializeConversation so
        // ConversationVectorToJson's SafeGetCString calls all read valid
        // V2TIMString pointers (V2TIMConversation contains a raw
        // V2TIMMessage* lastMessage that is *not* zero-initialized by the
        // struct's default ctor; leaving it as garbage segfaulted the JSON
        // builder when called from a group/conference SendMessage path).
        conv.conversationID = conv_id.c_str();
        const bool is_c2c = conv_id.size() >= 4 && conv_id.substr(0, 4) == "c2c_";
        const std::string c2c_uid = is_c2c ? conv_id.substr(4) : std::string();
        conv.userID = c2c_uid.c_str();
        conv.groupID = "";
        conv.groupType = "";
        conv.showName = "";
        conv.faceUrl = "";
        conv.draftText = "";
        conv.unreadCount = 0;
        // C2C recvOpt must come from the authoritative opt map — a hardcoded 0
        // here re-announced a muted peer as un-muted on every post-send notify
        // (the recvOpt "clobber" bug); the Dart projection cache would persist it.
        conv.recvOpt = static_cast<V2TIMReceiveMessageOpt>(
            is_c2c ? C2CRecvOptForUser(c2c_uid) : 0);
        conv.draftTimestamp = 0;
        conv.orderKey = 0;
        conv.c2cReadTimestamp = 0;
        conv.groupReadSequence = 0;
        conv.isPinned = false;
        // Use C2C as default type for c2c_-prefixed IDs, GROUP otherwise.
        conv.type = is_c2c ? V2TIM_C2C : V2TIM_GROUP;
        conv.lastMessage = nullptr;
    }

    V2TIMConversationVector changed;
    changed.PushBack(conv);

    // Snapshot listener pointers under lock, then release before invoking.
    // Holding listeners_mutex_ across user-code callbacks deadlocks/crashes
    // when the callback path takes another manager-level lock (observed:
    // SIGSEGV in callback_bridge when group/conference tests send and the
    // bridge's per-instance dispatch contends with this lock).
    std::vector<V2TIMConversationListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listeners_mutex_);
        listeners_copy = listeners_;
    }
    for (auto* l : listeners_copy) {
        if (!l) continue;
        try { l->OnConversationChanged(changed); } catch (...) {}
    }
}

void V2TIMConversationManagerImpl::UpdateC2CReceiveOptAndNotify(const std::string& userID, int opt) {
    std::string uid = userID;
    if (uid.size() >= 64) uid = uid.substr(0, 64);
    if (uid.empty()) return;
    const std::string conv_id = std::string("c2c_") + uid;

    V2TIMConversation conv;
    {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        auto it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                               [&](const ConversationSnapshot& s) { return s.conversation_id == conv_id; });
        if (it != cached_conversations_.end()) {
            // Existing row: update the cached recvOpt so future getConversationList /
            // MaterializeConversation carry it too, then emit the full snapshot.
            it->recv_opt = opt;
            conv = MaterializeConversation(*it);
        } else {
            // No cached row (mute set from the friend profile before any message).
            // Emit a fully-initialized minimal C2C conversation WITH the recvOpt so
            // listeners learn the opt, but do NOT add a phantom row to the cache.
            // (Full init mirrors NotifyConversationChangedForConvID's not-materialized
            // branch so the JSON builder's SafeGetCString never reads garbage and the
            // raw lastMessage* is null.)
            conv.conversationID = conv_id.c_str();
            conv.userID = uid.c_str();
            conv.groupID = "";
            conv.groupType = "";
            conv.showName = "";
            conv.faceUrl = "";
            conv.draftText = "";
            conv.unreadCount = 0;
            conv.recvOpt = static_cast<V2TIMReceiveMessageOpt>(opt);
            conv.draftTimestamp = 0;
            conv.orderKey = 0;
            conv.c2cReadTimestamp = 0;
            conv.groupReadSequence = 0;
            conv.isPinned = false;
            conv.type = V2TIM_C2C;
            conv.lastMessage = nullptr;
        }
    }

    V2TIMConversationVector changed;
    changed.PushBack(conv);

    // Snapshot listener pointers under lock, then release before invoking (same
    // deadlock-avoidance rationale as NotifyConversationChangedForConvID).
    std::vector<V2TIMConversationListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listeners_mutex_);
        listeners_copy = listeners_;
    }
    for (auto* l : listeners_copy) {
        if (!l) continue;
        try { l->OnConversationChanged(changed); } catch (...) {}
    }
}

// Forward declaration for multi-instance: use current instance's manager when available
extern V2TIMManager* SafeGetV2TIMManager(void);

// 核心会话列表获取实现
void V2TIMConversationManagerImpl::GetConversationList(uint64_t nextSeq, uint32_t count,
                                                     V2TIMValueCallback<V2TIMConversationResult>* callback) {
    // Prefer current instance's manager (multi-instance safe); fallback to stored manager_impl_
    V2TIMManagerImpl* manager_impl = dynamic_cast<V2TIMManagerImpl*>(SafeGetV2TIMManager());
    if (!manager_impl) {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager_impl = manager_impl_;
    }
    if (!manager_impl) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
        return;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    Tox* tox = tox_manager->getTox();
    // Decide whether to refresh; must call RefreshConversationCache() WITHOUT holding cache_mutex_
    // (RefreshConversationCache locks cache_mutex_ internally — calling it under lock would deadlock).
    bool need_refresh = false;
    if (tox) {
        size_t current_friend_count = tox_self_get_friend_list_size(tox);
        {
            std::lock_guard<std::mutex> lock(cache_mutex_);
            bool cache_empty = cached_conversations_.empty();
            bool has_friends = current_friend_count > 0;
            need_refresh = (current_friend_count != last_friend_count_) || (cache_empty && has_friends);
        }
        if (need_refresh) {
            RefreshConversationCache();
        }
    } else {
        RefreshConversationCache();
    }
    
    V2TIMConversationResult result;
    result.nextSeq = 0;
    result.isFinished = true;
    {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        const size_t total = cached_conversations_.size();
        const size_t start = std::min(static_cast<size_t>(nextSeq), total);
        const size_t end = std::min(start + count, total);
        for (size_t i = start; i < end; ++i) {
            V2TIMConversation conv = MaterializeConversation(cached_conversations_[i]);
            {
                std::lock_guard<std::mutex> pin_lock(pinned_mutex_);
                auto it = pinned_conversations_.find(cached_conversations_[i].conversation_id);
                conv.isPinned = (it != pinned_conversations_.end() && it->second);
            }
            result.conversationList.PushBack(conv);
        }
    }
    if (callback) {
        callback->OnSuccess(result);
    }
}

// 创建会话对象（好友）
V2TIMConversation V2TIMConversationManagerImpl::CreateConversationFromFriend(uint32_t friend_number) {
    V2TIMConversation conv;
    std::string convID;
    
    // Initialize all string fields to empty strings first
    conv.conversationID = V2TIMString("");
    conv.userID = V2TIMString("");
    conv.groupID = V2TIMString("");
    conv.groupType = V2TIMString("");
    conv.showName = V2TIMString("");
    conv.faceUrl = V2TIMString("");
    conv.draftText = V2TIMString("");
    
    // Initialize other fields
    conv.type = V2TIM_C2C;
    conv.unreadCount = 0;
    conv.isPinned = false;
    conv.recvOpt = V2TIM_RECEIVE_MESSAGE; // Default: receive messages normally
    conv.lastMessage = nullptr;
    conv.draftTimestamp = 0;
    conv.orderKey = 0;
    conv.c2cReadTimestamp = 0;
    conv.groupReadSequence = 0;
    
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    V2TIMManagerImpl* manager_impl = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager_impl = manager_impl_;
    }
    if (!manager_impl) {
        convID = "c2c_" + std::to_string(friend_number);
        conv.userID = V2TIMString("");
        conv.conversationID = V2TIMString(convID.c_str());
        return conv;
    }
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        convID = "c2c_" + std::to_string(friend_number);
        conv.userID = V2TIMString("");
        conv.conversationID = V2TIMString(convID.c_str());
        return conv;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        convID = "c2c_" + std::to_string(friend_number);
        conv.userID = V2TIMString("");
        conv.conversationID = V2TIMString(convID.c_str());
        return conv;
    }
    if (tox_friend_get_public_key(tox, friend_number, pubkey, nullptr)) {
        // Convert binary pubkey to hex string
        char hex_pubkey[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        for (size_t i = 0; i < TOX_PUBLIC_KEY_SIZE; i++) {
            sprintf(hex_pubkey + i * 2, "%02X", pubkey[i]);
        }
        hex_pubkey[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        convID = std::string("c2c_") + hex_pubkey;
        conv.userID = V2TIMString(hex_pubkey);
    } else {
        convID = "c2c_" + std::to_string(friend_number);
        conv.userID = V2TIMString("");
    }
    
    conv.conversationID = V2TIMString(convID.c_str());

    // C2C recvOpt from the authoritative opt map — this conv seeds the snapshot
    // cache (RefreshConversationCache -> ToSnapshot), and a default 0 here would
    // rebuild a muted peer's snapshot as un-muted on every cache refresh.
    {
        const char* uid_cstr = conv.userID.CString();
        if (uid_cstr && *uid_cstr) {
            conv.recvOpt =
                static_cast<V2TIMReceiveMessageOpt>(C2CRecvOptForUser(uid_cstr));
        }
    }

    // 检查置顶状态
    {
        std::lock_guard<std::mutex> lock(pinned_mutex_);
        auto it = pinned_conversations_.find(convID);
        conv.isPinned = (it != pinned_conversations_.end() && it->second);
    }
    
    // 其他字段根据tox状态填充...
    return conv;
}

// 刷新本地缓存
void V2TIMConversationManagerImpl::RefreshConversationCache() {
    // OPTIMIZATION: Debounce mechanism to prevent excessive cache refreshes
    // This reduces CPU usage and improves performance when multiple friend operations happen quickly
    auto now = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> debounce_lock(refresh_debounce_mutex_);
        auto time_since_last_refresh = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_refresh_time_);
        if (time_since_last_refresh < REFRESH_DEBOUNCE_MS) {
            // Too soon since last refresh, skip this one
            // The cache will be refreshed when the debounce period expires
            return;
        }
        last_refresh_time_ = now;
    }
    
    // Take a snapshot of deleted IDs BEFORE locking cache_mutex_ to avoid deadlock
    // (DeleteConversation locks deleted_ids_mutex_ then cache_mutex_)
    std::unordered_set<std::string> deleted_snapshot;
    {
        std::lock_guard<std::mutex> del_lock(deleted_ids_mutex_);
        deleted_snapshot = deleted_conversation_ids_;
    }

    std::lock_guard<std::mutex> lock(cache_mutex_);
    cached_conversations_.clear();

    V2TIMManagerImpl* manager_impl = dynamic_cast<V2TIMManagerImpl*>(SafeGetV2TIMManager());
    if (!manager_impl) {
        std::lock_guard<std::mutex> lock_mgr(manager_impl_mutex_);
        manager_impl = manager_impl_;
    }
    if (!manager_impl) {
        return;
    }

    if (!manager_impl->IsRunning()) {
        return;
    }

    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        return;
    }

    Tox* tox = nullptr;
    try {
        tox = tox_manager->getTox();
    } catch (const std::exception& e) {
        V2TIM_LOG(kError, "[V2TIMConversationManagerImpl] RefreshConversationCache: Exception in getTox(): {}", e.what());
        return;
    } catch (...) {
        V2TIM_LOG(kError, "[V2TIMConversationManagerImpl] RefreshConversationCache: Unknown exception in getTox()");
        return;
    }

    if (!tox) {
        return;
    }

    const size_t friend_count = tox_self_get_friend_list_size(tox);
    std::vector<uint32_t> friends(friend_count);
    if (friend_count > 0) {
        tox_self_get_friend_list(tox, friends.data());
    }
    
    for (uint32_t friend_number : friends) {
        try {
            V2TIMConversation conv = CreateConversationFromFriend(friend_number);
            std::string conv_id_str(conv.conversationID.CString());
            if (deleted_snapshot.count(conv_id_str) > 0) {
                continue;
            }
            cached_conversations_.push_back(ToSnapshot(conv));
        } catch (...) {
            // Skip conversation on error
        }
    }
    
    // Update last known friend count
    last_friend_count_ = friend_count;
    
    // TODO: 添加群组会话（需要根据实际群组实现）
}

// 其他接口实现（部分示例）
void V2TIMConversationManagerImpl::DeleteConversation(const V2TIMString& conversationID, V2TIMCallback* callback) {
    std::string conv_id = conversationID.CString();

    // Track this conversation as explicitly deleted so RefreshConversationCache won't re-add it
    {
        std::lock_guard<std::mutex> lock(deleted_ids_mutex_);
        deleted_conversation_ids_.insert(conv_id);
    }

    if (conv_id.length() >= 4 && conv_id.substr(0, 4) == "c2c_") {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        auto it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                               [&](const ConversationSnapshot& s) { return s.conversation_id == conv_id; });
        if (it != cached_conversations_.end()) {
            cached_conversations_.erase(it);
        }
    } else if (conv_id.length() >= 6 && conv_id.substr(0, 6) == "group_") {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        auto it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                               [&](const ConversationSnapshot& s) { return s.conversation_id == conv_id; });
        if (it != cached_conversations_.end()) {
            cached_conversations_.erase(it);
        }
    }
    
    // Notify listeners that conversation was deleted so Dart side removes it from UI list
    {
        V2TIMStringVector deletedIDs;
        deletedIDs.PushBack(conversationID);
        std::vector<V2TIMConversationListener*> listeners_copy;
        {
            std::lock_guard<std::mutex> lock(listeners_mutex_);
            listeners_copy = listeners_;
        }
        for (auto* listener : listeners_copy) {
            if (listener) {
                try {
                    listener->OnConversationDeleted(deletedIDs);
                } catch (...) {
                    // Ignore listener errors
                }
            }
        }
    }

    if (callback) {
        callback->OnSuccess();
    }
}

// 未实现的功能保留空实现
void V2TIMConversationManagerImpl::CreateConversationGroup(const V2TIMString &groupName, 
                                                         const V2TIMStringVector &conversationIDList,
                                                         V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) {
    // 空实现
    if (callback) {
        V2TIMConversationOperationResultVector result;
        callback->OnSuccess(result);
    }
}

// ...existing code...

void V2TIMConversationManagerImpl::GetConversation(const V2TIMString& conversationID,
                                                   V2TIMValueCallback<V2TIMConversation>* callback) {
    // Refresh cache first to ensure it's up to date
    RefreshConversationCache();
    
    std::lock_guard<std::mutex> lock(cache_mutex_);
    std::string conv_id = conversationID.CString();
    
    auto it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                           [&](const ConversationSnapshot& s) { return s.conversation_id == conv_id; });
    if (it == cached_conversations_.end() && conv_id.substr(0, 4) != "c2c_") {
        std::string prefixed_id = "c2c_" + conv_id;
        it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                          [&](const ConversationSnapshot& s) { return s.conversation_id == prefixed_id; });
    }
    if (it == cached_conversations_.end() && conv_id.substr(0, 4) == "c2c_") {
        std::string unprefixed_id = conv_id.substr(4);
        it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                          [&](const ConversationSnapshot& s) { return s.user_id == unprefixed_id; });
    }
    if (it != cached_conversations_.end()) {
        if (callback) callback->OnSuccess(MaterializeConversation(*it));
    } else {
        // If still not found, try to create conversation on-the-fly for friend
        // This handles the case where conversation hasn't been cached yet
        if (conv_id.length() == 64) { // Hex pubkey length
            // Try to find friend by pubkey
            uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
            for (size_t i = 0; i < TOX_PUBLIC_KEY_SIZE && i * 2 < conv_id.length(); i++) {
                char hex_byte[3] = {conv_id[i * 2], conv_id[i * 2 + 1], '\0'};
                pubkey[i] = (uint8_t)strtoul(hex_byte, nullptr, 16);
            }
            
            V2TIMManagerImpl* manager_impl = nullptr;
            {
                std::lock_guard<std::mutex> lock(manager_impl_mutex_);
                manager_impl = manager_impl_;
            }
            if (!manager_impl) {
                if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
                return;
            }
            ToxManager* tox_manager = manager_impl->GetToxManager();
            if (!tox_manager) {
                if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
                return;
            }
            Tox* tox = tox_manager->getTox();
            if (!tox) {
                if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
                return;
            }
            const size_t friend_count = tox_self_get_friend_list_size(tox);
            std::vector<uint32_t> friends(friend_count);
            tox_self_get_friend_list(tox, friends.data());
            
            for (uint32_t friend_number : friends) {
                uint8_t friend_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox_friend_get_public_key(tox, friend_number, friend_pubkey, nullptr)) {
                    if (memcmp(pubkey, friend_pubkey, TOX_PUBLIC_KEY_SIZE) == 0) {
                        // Found friend, create conversation
                        V2TIMConversation conv = CreateConversationFromFriend(friend_number);
                        if (callback) callback->OnSuccess(conv);
                        return;
                    }
                }
            }
        }
        
        if (callback) callback->OnError(ERR_SDK_CONVERSATION_NOT_FOUND, "Conversation not found");
    }
}

void V2TIMConversationManagerImpl::GetConversationList(const V2TIMStringVector& conversationIDList,
                                                       V2TIMValueCallback<V2TIMConversationVector>* callback) {
    V2TIMConversationVector result;
    std::lock_guard<std::mutex> lock(cache_mutex_);
    
    // Use index-based iteration instead of range-for to avoid accessing invalid objects
    size_t list_size = conversationIDList.Size();
    for (size_t i = 0; i < list_size; i++) {
        try {
            std::string cid(conversationIDList[i].CString());
            auto it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                                   [&](const ConversationSnapshot& s) { return s.conversation_id == cid; });
            if (it != cached_conversations_.end()) {
                result.PushBack(MaterializeConversation(*it));
            }
        } catch (...) {
            continue;
        }
    }
    if (callback) callback->OnSuccess(result);
}

void V2TIMConversationManagerImpl::GetConversationListByFilter(const V2TIMConversationListFilter &filter,
                                                               uint64_t nextSeq, uint32_t count,
                                                               V2TIMValueCallback<V2TIMConversationResult>* callback) {
    // Implementation based on filter criteria
    // For simplicity, returning all conversations
    GetConversationList(nextSeq, count, callback);
}

void V2TIMConversationManagerImpl::DeleteConversationList(const V2TIMStringVector& conversationIDList, bool clearMessage,
                                                          V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) {
    V2TIMConversationOperationResultVector results;
    
    // Use index-based iteration instead of range-for to avoid accessing invalid objects
    size_t list_size = conversationIDList.Size();
    for (size_t i = 0; i < list_size; i++) {
        try {
            // Safely access conversationID using index
            const V2TIMString& conversationID = conversationIDList[i];
            
            // Safely extract conversation ID string
            const char* conv_id_cstr = conversationID.CString();
            if (!conv_id_cstr) {
                // Skip invalid conversation ID
                V2TIMConversationOperationResult result;
                result.conversationID = conversationID;
                result.resultCode = -1;
                result.resultInfo = "Invalid conversation ID";
                results.PushBack(result);
                continue;
            }
            
            std::string conv_id(conv_id_cstr);
            
            // If clearMessage is true, clear message history before deleting conversation
            if (clearMessage) {
                if (conv_id.length() >= 4 && conv_id.substr(0, 4) == "c2c_") {
                    // C2C conversation: extract userID and clear C2C history
                    std::string userID = conv_id.substr(4);
                    if (!userID.empty()) {
                        // Use manager_impl_ instead of V2TIMManager::GetInstance() for multi-instance support
                        V2TIMManagerImpl* manager = nullptr;
                        {
                            std::lock_guard<std::mutex> lock(manager_impl_mutex_);
                            manager = manager_impl_;
                        }
                        if (manager) {
                            manager->GetMessageManager()->ClearC2CHistoryMessage(
                                V2TIMString(userID.c_str()),
                                nullptr  // No callback needed for clearing history
                            );
                        }
                    }
                } else if (conv_id.length() >= 6 && conv_id.substr(0, 6) == "group_") {
                    // Group conversation: extract groupID and clear group history
                    std::string groupID = conv_id.substr(6);
                    if (!groupID.empty()) {
                        // Use manager_impl_ instead of V2TIMManager::GetInstance() for multi-instance support
                        V2TIMManagerImpl* manager = nullptr;
                        {
                            std::lock_guard<std::mutex> lock(manager_impl_mutex_);
                            manager = manager_impl_;
                        }
                        if (manager) {
                            manager->GetMessageManager()->ClearGroupHistoryMessage(
                                V2TIMString(groupID.c_str()),
                                nullptr  // No callback needed for clearing history
                            );
                        }
                    }
                }
            }
            
            // Delete the conversation
            DeleteConversation(conversationID, nullptr);
            
            V2TIMConversationOperationResult result;
            result.conversationID = conversationID;
            result.resultCode = 0;
            results.PushBack(result);
        } catch (const std::exception& e) {
            // Handle exception for this conversation ID
            V2TIMConversationOperationResult result;
            result.conversationID = conversationIDList[i];
            result.resultCode = -1;
            result.resultInfo = V2TIMString(e.what());
            results.PushBack(result);
        } catch (...) {
            // Handle unknown exception
            V2TIMConversationOperationResult result;
            result.conversationID = conversationIDList[i];
            result.resultCode = -1;
            result.resultInfo = "Unknown error";
            results.PushBack(result);
        }
    }
    
    if (callback) callback->OnSuccess(results);
}

void V2TIMConversationManagerImpl::SetConversationDraft(const V2TIMString& conversationID,
                                                        const V2TIMString& draftText, V2TIMCallback* callback) {
    std::string conv_id(conversationID.CString());
    // Update draft in cache
    {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        std::string cid(conversationID.CString());
        for (auto& s : cached_conversations_) {
            if (s.conversation_id == cid) {
                s.draft_text = draftText.CString() ? draftText.CString() : "";
                break;
            }
        }
    }

    // Notify OnConversationChanged so Dart UI updates draft display
    {
        V2TIMConversationVector convVector;
        V2TIMConversation conv;
        conv.conversationID = conversationID;
        conv.draftText = draftText;
        conv.lastMessage = nullptr;
        conv.isPinned = false;
        conv.unreadCount = 0;
        conv.recvOpt = V2TIM_RECEIVE_MESSAGE;
        conv.draftTimestamp = 0;
        conv.orderKey = 0;
        conv.c2cReadTimestamp = 0;
        conv.groupReadSequence = 0;
        if (conv_id.length() >= 4 && conv_id.substr(0, 4) == "c2c_") {
            conv.type = V2TIM_C2C;
            conv.userID = V2TIMString(conv_id.substr(4).c_str());
            conv.groupID = V2TIMString("");
            // Sparse emit: recvOpt must come from the authoritative opt map, not
            // a hardcoded 0 (would re-announce a muted peer as un-muted).
            conv.recvOpt = static_cast<V2TIMReceiveMessageOpt>(
                C2CRecvOptForUser(conv_id.substr(4)));
        } else if (conv_id.length() >= 6 && conv_id.substr(0, 6) == "group_") {
            conv.type = V2TIM_GROUP;
            conv.userID = V2TIMString("");
            conv.groupID = V2TIMString(conv_id.substr(6).c_str());
        }
        conv.groupType = V2TIMString("");
        conv.showName = V2TIMString("");
        conv.faceUrl = V2TIMString("");
        convVector.PushBack(conv);

        std::vector<V2TIMConversationListener*> listeners_copy;
        {
            std::lock_guard<std::mutex> lock(listeners_mutex_);
            listeners_copy = listeners_;
        }
        for (auto* listener : listeners_copy) {
            if (listener) {
                try {
                    listener->OnConversationChanged(convVector);
                } catch (...) {}
            }
        }
    }

    if (callback) callback->OnSuccess();
}

void V2TIMConversationManagerImpl::SetConversationCustomData(const V2TIMStringVector &conversationIDList, const V2TIMBuffer &customData,
                                                             V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) {
    // Implementation to set custom data
    V2TIMConversationOperationResultVector results;
    for (const auto& conversationID : conversationIDList) {
        V2TIMConversationOperationResult result;
        result.conversationID = conversationID;
        result.resultCode = 0;
        results.PushBack(result);
    }
    if (callback) callback->OnSuccess(results);
}

void V2TIMConversationManagerImpl::PinConversation(const V2TIMString& conversationID, bool isPinned,
                                                   V2TIMCallback* callback) {
    std::string convID(conversationID.CString());
    {
        std::lock_guard<std::mutex> lock(pinned_mutex_);
        // Store under given ID and under normalized C2C key (c2c_ + 64-char pubkey) so
        // GetConversationList (which uses c2c_ + pubkey from BuildConversationFromFriendNumber) finds it
        auto storePinned = [this, isPinned](const std::string& key) {
            if (isPinned) {
                pinned_conversations_[key] = true;
            } else {
                pinned_conversations_.erase(key);
            }
        };
        storePinned(convID);
        if (convID.length() >= 4 && convID.substr(0, 4) == "c2c_") {
            std::string suffix = convID.substr(4);
            if (suffix.length() >= TOX_PUBLIC_KEY_SIZE * 2) {
                std::string normalized = "c2c_" + suffix.substr(0, TOX_PUBLIC_KEY_SIZE * 2);
                storePinned(normalized);
            }
        }
    }
    // Notify listeners: always build a minimal conv from local strings only (convID already copied
    // at top). Never pass cache-backed conv to listener to avoid dangling pointers in JSON serialization.
    {
        V2TIMConversationVector convVector;
        V2TIMConversation conv;
        std::string fallback_conv_id, fallback_user_id, fallback_group_id;
        std::string fallback_group_type, fallback_show_name, fallback_face_url, fallback_draft_text;
        
        fallback_conv_id = convID;
        conv.conversationID = V2TIMString(fallback_conv_id.c_str());
        conv.isPinned = isPinned;
        conv.unreadCount = 0;
        conv.recvOpt = V2TIM_RECEIVE_MESSAGE;
        conv.lastMessage = nullptr;
        conv.draftTimestamp = 0;
        conv.orderKey = 0;
        conv.c2cReadTimestamp = 0;
        conv.groupReadSequence = 0;
        if (convID.length() >= 4 && convID.substr(0, 4) == "c2c_") {
            conv.type = V2TIM_C2C;
            fallback_user_id = convID.substr(4);
            conv.userID = V2TIMString(fallback_user_id.c_str());
            conv.groupID = V2TIMString(fallback_group_id.c_str());
            conv.groupType = V2TIMString(fallback_group_type.c_str());
            conv.showName = V2TIMString(fallback_show_name.c_str());
            conv.faceUrl = V2TIMString(fallback_face_url.c_str());
            conv.draftText = V2TIMString(fallback_draft_text.c_str());
            // Sparse emit: recvOpt from the authoritative opt map (see
            // C2CRecvOptForUser) — a hardcoded 0 would clobber a mute.
            conv.recvOpt = static_cast<V2TIMReceiveMessageOpt>(
                C2CRecvOptForUser(fallback_user_id));
        } else if (convID.length() >= 6 && convID.substr(0, 6) == "group_") {
            conv.type = V2TIM_GROUP;
            fallback_group_id = convID.substr(6);
            conv.userID = V2TIMString(fallback_user_id.c_str());
            conv.groupID = V2TIMString(fallback_group_id.c_str());
            conv.groupType = V2TIMString(fallback_group_type.c_str());
            conv.showName = V2TIMString(fallback_show_name.c_str());
            conv.faceUrl = V2TIMString(fallback_face_url.c_str());
            conv.draftText = V2TIMString(fallback_draft_text.c_str());
        } else {
            conv.type = V2TIM_C2C;
            fallback_user_id = convID;
            conv.userID = V2TIMString(fallback_user_id.c_str());
            conv.groupID = V2TIMString(fallback_group_id.c_str());
            conv.groupType = V2TIMString(fallback_group_type.c_str());
            conv.showName = V2TIMString(fallback_show_name.c_str());
            conv.faceUrl = V2TIMString(fallback_face_url.c_str());
            conv.draftText = V2TIMString(fallback_draft_text.c_str());
        }
        
        convVector.PushBack(conv);
        
        {
            std::lock_guard<std::mutex> lock(listeners_mutex_);
            for (auto* listener : listeners_) {
                if (listener) {
                    listener->OnConversationChanged(convVector);
                }
            }
        }
    }
    
    if (callback) callback->OnSuccess();
}

void V2TIMConversationManagerImpl::MarkConversation(const V2TIMStringVector &conversationIDList, uint64_t markType, bool enableMark,
                                                    V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) {
    V2TIMConversationOperationResultVector results;
    V2TIMConversationVector changedConvs;

    for (size_t i = 0; i < conversationIDList.Size(); i++) {
        const V2TIMString& conversationID = conversationIDList[i];
        V2TIMConversationOperationResult result;
        result.conversationID = conversationID;
        result.resultCode = 0;
        results.PushBack(result);

        {
            std::lock_guard<std::mutex> lock(cache_mutex_);
            std::string cid(conversationID.CString());
            auto it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                                   [&](const ConversationSnapshot& s) { return s.conversation_id == cid; });
            if (it != cached_conversations_.end()) {
                changedConvs.PushBack(MaterializeConversation(*it));
            }
        }
    }

    // Notify OnConversationChanged
    if (changedConvs.Size() > 0) {
        std::vector<V2TIMConversationListener*> listeners_copy;
        {
            std::lock_guard<std::mutex> lock(listeners_mutex_);
            listeners_copy = listeners_;
        }
        for (auto* listener : listeners_copy) {
            if (listener) {
                try {
                    listener->OnConversationChanged(changedConvs);
                } catch (...) {}
            }
        }
    }

    if (callback) callback->OnSuccess(results);
}

void V2TIMConversationManagerImpl::GetTotalUnreadMessageCount(V2TIMValueCallback<uint64_t>* callback) {
    // Implementation to get total unread message count
    uint64_t totalUnreadCount = 0;
    if (callback) callback->OnSuccess(totalUnreadCount);
}

void V2TIMConversationManagerImpl::GetUnreadMessageCountByFilter(const V2TIMConversationListFilter &filter,
                                                                 V2TIMValueCallback<uint64_t>* callback) {
    // Implementation to get unread message count by filter
    uint64_t unreadCount = 0;
    if (callback) callback->OnSuccess(unreadCount);
}

void V2TIMConversationManagerImpl::SubscribeUnreadMessageCountByFilter(const V2TIMConversationListFilter &filter) {
    // Implementation to subscribe unread message count by filter
}

void V2TIMConversationManagerImpl::UnsubscribeUnreadMessageCountByFilter(const V2TIMConversationListFilter &filter) {
    // Implementation to unsubscribe unread message count by filter
}

void V2TIMConversationManagerImpl::CleanConversationUnreadMessageCount(const V2TIMString& conversationID, uint64_t cleanTimestamp, uint64_t cleanSequence,
                                                                       V2TIMCallback* callback) {
    std::string conv_id(conversationID.CString());
    {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        for (auto& s : cached_conversations_) {
            if (s.conversation_id == conv_id) {
                s.unread_count = 0;
                break;
            }
        }
    }

    {
        V2TIMConversationVector convVector;
        {
            std::lock_guard<std::mutex> lock(cache_mutex_);
            auto it = std::find_if(cached_conversations_.begin(), cached_conversations_.end(),
                [&](const ConversationSnapshot& s) { return s.conversation_id == conv_id; });
            if (it != cached_conversations_.end()) {
                convVector.PushBack(MaterializeConversation(*it));
            } else {
                // Fallback: minimal conv when not in cache (e.g. race) so UI still gets unread=0
                V2TIMConversation conv;
                conv.conversationID = conversationID;
                conv.unreadCount = 0;
                conv.lastMessage = nullptr;
                conv.isPinned = false;
                conv.recvOpt = V2TIM_RECEIVE_MESSAGE;
                conv.draftTimestamp = 0;
                conv.orderKey = 0;
                conv.c2cReadTimestamp = 0;
                conv.groupReadSequence = 0;
                if (conv_id.length() >= 4 && conv_id.substr(0, 4) == "c2c_") {
                    conv.type = V2TIM_C2C;
                    conv.userID = V2TIMString(conv_id.substr(4).c_str());
                    conv.groupID = V2TIMString("");
                    conv.groupType = V2TIMString("");
                    // Sparse emit: recvOpt from the authoritative opt map (see
                    // C2CRecvOptForUser) — a hardcoded 0 would clobber a mute.
                    conv.recvOpt = static_cast<V2TIMReceiveMessageOpt>(
                        C2CRecvOptForUser(conv_id.substr(4)));
                } else if (conv_id.length() >= 6 && conv_id.substr(0, 6) == "group_") {
                    conv.type = V2TIM_GROUP;
                    conv.userID = V2TIMString("");
                    conv.groupID = V2TIMString(conv_id.substr(6).c_str());
                    conv.groupType = V2TIMString("");
                }
                conv.showName = V2TIMString("");
                conv.faceUrl = V2TIMString("");
                conv.draftText = V2TIMString("");
                convVector.PushBack(conv);
            }
        }

        std::vector<V2TIMConversationListener*> listeners_copy;
        {
            std::lock_guard<std::mutex> lock(listeners_mutex_);
            listeners_copy = listeners_;
        }
        for (auto* listener : listeners_copy) {
            if (listener) {
                try {
                    listener->OnConversationChanged(convVector);
                } catch (...) {}
            }
        }
    }

    // Notify OnTotalUnreadMessageCountChanged
    {
        // Calculate total unread from cache
        uint64_t totalUnread = 0;
        {
            std::lock_guard<std::mutex> lock(cache_mutex_);
            for (const auto& s : cached_conversations_) {
                totalUnread += static_cast<uint64_t>(s.unread_count);
            }
        }
        std::vector<V2TIMConversationListener*> listeners_copy;
        {
            std::lock_guard<std::mutex> lock(listeners_mutex_);
            listeners_copy = listeners_;
        }
        for (auto* listener : listeners_copy) {
            if (listener) {
                try {
                    listener->OnTotalUnreadMessageCountChanged(totalUnread);
                } catch (...) {}
            }
        }
    }

    if (callback) callback->OnSuccess();
}

void V2TIMConversationManagerImpl::GetConversationGroupList(V2TIMValueCallback<V2TIMStringVector>* callback) {
    // Empty implementation
    V2TIMStringVector result;
    if (callback) callback->OnSuccess(result);
}

void V2TIMConversationManagerImpl::DeleteConversationGroup(const V2TIMString &groupName, V2TIMCallback* callback) {
    // Empty implementation
    if (callback) callback->OnSuccess();
}

void V2TIMConversationManagerImpl::RenameConversationGroup(const V2TIMString &oldName, const V2TIMString &newName,
                                                           V2TIMCallback* callback) {
    // Empty implementation
    if (callback) callback->OnSuccess();
}

void V2TIMConversationManagerImpl::AddConversationsToGroup(const V2TIMString &groupName, const V2TIMStringVector &conversationIDList,
                                                           V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) {
    // Empty implementation
    V2TIMConversationOperationResultVector result;
    if (callback) callback->OnSuccess(result);
}

void V2TIMConversationManagerImpl::DeleteConversationsFromGroup(const V2TIMString &groupName, const V2TIMStringVector &conversationIDList,
                                                                V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) {
    // Empty implementation
    V2TIMConversationOperationResultVector result;
    if (callback) callback->OnSuccess(result);
}

// Notify listeners about new conversations
void V2TIMConversationManagerImpl::NotifyNewConversations() {
    std::vector<ConversationSnapshot> snapshots_copy;
    {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        snapshots_copy = cached_conversations_;
    }
    if (snapshots_copy.empty()) {
        return;
    }
    V2TIMConversationVector convVector;
    for (const auto& s : snapshots_copy) {
        try {
            convVector.PushBack(MaterializeConversation(s));
        } catch (...) {
            // Skip on error
        }
    }
    
    std::vector<V2TIMConversationListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listeners_mutex_);
        listeners_copy = listeners_;
    }
    
    for (auto* listener : listeners_copy) {
        if (listener) {
            try {
                listener->OnNewConversation(convVector);
            } catch (...) {
                // Ignore listener errors
            }
        }
    }
}

// Multi-instance support: Set the associated V2TIMManagerImpl instance