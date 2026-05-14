#ifndef __V2TIM_MANAGER_IMPL_H__
#define __V2TIM_MANAGER_IMPL_H__

#include <mutex>
#include <condition_variable>
#include <atomic>
#include <functional>
#include <future>
#include <queue>
#include "toxcore/tox_struct.h"
#include "V2TIMManager.h"
#include "V2TIMMessageManager.h"
#include "V2TIMGroupManager.h"
#include "V2TIMConversationManager.h"
#include "V2TIMFriendshipManager.h"
#include "V2TIMOfflinePushManager.h"
#include "V2TIMSignalingManager.h"
#include "V2TIMCommunityManager.h"

class V2TIMSignalingManagerImpl;
class V2TIMMessageManagerImpl;
class V2TIMGroupManagerImpl;
class V2TIMConversationManagerImpl;
class V2TIMCommunityManagerImpl;
class V2TIMFriendshipManagerImpl;
#include "ToxManager.h"
#include <memory>
#include <vector>
#include <unordered_set>
#include <thread>
#include "V2TIMStringHash.h"
#include <unordered_map>
#include <vector>
#include <string>

#ifdef BUILD_TOXAV
#include "ToxAVManager.h"
#endif

class V2TIMManagerImpl : public V2TIMManager {
public:
    // Constructor (now public for multi-instance support)
    V2TIMManagerImpl();
    
    // Destructor
    ~V2TIMManagerImpl();
    
    // Backward compatibility: Get default instance
    static V2TIMManagerImpl* GetInstance();

    // SDK Listener Management
    void AddSDKListener(V2TIMSDKListener* listener) override;
    void RemoveSDKListener(V2TIMSDKListener* listener) override;

    // SDK Initialization and Cleanup
    bool InitSDK(uint32_t sdkAppID, const V2TIMSDKConfig& config) override;
    void UnInitSDK() override;

    // SDK Information
    V2TIMString GetVersion() override;
    int64_t GetServerTime() override;

    // User Authentication
    void Login(const V2TIMString& userID, const V2TIMString& userSig, V2TIMCallback* callback) override;
    void Logout(V2TIMCallback* callback) override;
    V2TIMString GetLoginUser() override;
    V2TIMLoginStatus GetLoginStatus() override;

    /// Returns the actual self Tox address (76-hex-char public key + nospam +
    /// checksum), populated by HandleSelfConnectionStatus once the Tox stack
    /// establishes a connection. Distinct from GetLoginUser(), which returns
    /// the login alias (the userID passed to Login). Returns an empty string
    /// when not yet known.
    V2TIMString GetSelfToxAddress();

    /** Return true if this instance has group_id in its group mapping (used for join/peer sync). */
    bool HasGroup(const V2TIMString& group_id) const;

    // Messaging
    void AddSimpleMsgListener(V2TIMSimpleMsgListener* listener) override;
    void RemoveSimpleMsgListener(V2TIMSimpleMsgListener* listener) override;
    V2TIMString SendC2CTextMessage(const V2TIMString& text, const V2TIMString& userID, V2TIMSendCallback* callback) override;
    V2TIMString SendC2CTextMessage(const V2TIMString& text, const V2TIMString& userID, const V2TIMBuffer& cloudCustomData, V2TIMSendCallback* callback) override;
    V2TIMString SendC2CCustomMessage(const V2TIMBuffer& customData, const V2TIMString& userID, V2TIMSendCallback* callback) override;
    V2TIMString SendGroupTextMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback) override;
    V2TIMString SendGroupTextMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, const V2TIMBuffer& cloudCustomData, V2TIMSendCallback* callback) override;
    V2TIMString SendGroupPrivateTextMessage(const V2TIMString& groupID, const V2TIMString& receiverPublicKey64, const V2TIMString& text, V2TIMSendCallback* callback);
    V2TIMString SendGroupCustomMessage(const V2TIMBuffer& customData, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback) override;

    // Group Management
    void AddGroupListener(V2TIMGroupListener* listener) override;
    void RemoveGroupListener(V2TIMGroupListener* listener) override;
    void CreateGroup(const V2TIMString& groupType, const V2TIMString& groupID, const V2TIMString& groupName, V2TIMValueCallback<V2TIMString>* callback) override;
    void JoinGroup(const V2TIMString& groupID, const V2TIMString& message, V2TIMCallback* callback) override;
    void QuitGroup(const V2TIMString& groupID, V2TIMCallback* callback) override;
    void DismissGroup(const V2TIMString& groupID, V2TIMCallback* callback) override;

    // User Info
    void GetUsersInfo(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMUserFullInfoVector>* callback) override;
    void SetSelfInfo(const V2TIMUserFullInfo& info, V2TIMCallback* callback) override;

    // Search & Status
    void SearchUsers(const V2TIMUserSearchParam& param, V2TIMValueCallback<V2TIMUserSearchResult>* callback) override;
    void GetUserStatus(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMUserStatusVector>* callback) override;
    void SetSelfStatus(const V2TIMUserStatus& status, V2TIMCallback* callback) override;
    void SubscribeUserStatus(const V2TIMStringVector& userIDList, V2TIMCallback* callback) override;
    void UnsubscribeUserStatus(const V2TIMStringVector& userIDList, V2TIMCallback* callback) override;
    void SubscribeUserInfo(const V2TIMStringVector& userIDList, V2TIMCallback* callback) override;
    void UnsubscribeUserInfo(const V2TIMStringVector& userIDList, V2TIMCallback* callback) override;

    // Advanced Managers
    V2TIMMessageManager* GetMessageManager() override;
    V2TIMGroupManager* GetGroupManager() override;
    V2TIMCommunityManager* GetCommunityManager() override;
    V2TIMConversationManager* GetConversationManager() override;
    V2TIMFriendshipManager* GetFriendshipManager() override;
    V2TIMOfflinePushManager* GetOfflinePushManager() override;
    V2TIMSignalingManager* GetSignalingManager() override;

    // Experimental API
    void CallExperimentalAPI(const V2TIMString& api, const void* param, V2TIMValueCallback<V2TIMBaseObject>* callback) override;

    // Helper methods for accessing private data
    bool GetGroupNumberFromID(const V2TIMString& groupID, Tox_Group_Number& group_number);
    bool GetChatIdFromGroupID(const V2TIMString& groupID, uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]);
    bool GetGroupIDFromChatId(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE], V2TIMString& groupID);
    bool IsRunning() const;  // Implementation in .cpp file to avoid inline optimization issues
    
    // Helper method to notify group listeners about member kicked
    void NotifyGroupMemberKicked(const V2TIMString& groupID, const V2TIMGroupMemberInfoVector& memberList);
    
    // Helper method to get all group IDs from mapping (for GetJoinedGroupList)
    std::vector<V2TIMString> GetAllGroupIDs();

    // R-07: Instance metadata (Core-owned; FFI forwards to these)
    std::vector<std::string> GetKnownGroupIDs();
    void SetKnownGroupIDs(const std::vector<std::string>& group_ids);
    bool GetGroupChatIdFromStorage(const std::string& group_id, char* out_chat_id_hex, int out_len);
    void SetGroupChatIdInStorage(const std::string& group_id, const std::string& chat_id_hex);
    bool GetGroupTypeFromStorage(const std::string& group_id, char* out_type, int out_len);
    void SetGroupTypeInStorage(const std::string& group_id, const std::string& group_type);
    bool GetAutoAcceptGroupInvites();
    void SetAutoAcceptGroupInvites(bool enabled);
    
#ifdef BUILD_TOXAV
    // Helper to resolve group_number (e.g. conference_number) to groupID (for AV callbacks)
    bool GetGroupIDFromGroupNumber(Tox_Group_Number group_number, V2TIMString& out_group_id);
#endif
    
    // Helper method to get ToxManager instance (for internal use)
    ToxManager* GetToxManager() { return tox_manager_.get(); }

    /** Generate a unique message ID (instance + time + seq). Safe for multi-instance. */
    std::string MakeMessageId();
    /** Generate a unique group/send ID (instance + seq). Safe for multi-instance. */
    std::string MakeGroupId();

    // Save Tox profile to disk (call after friend list changes to persist state)
    void SaveToxProfile();
    
    /** Run a function on the event thread (tox iterate loop). Use to avoid deadlock when calling tox API from another thread.
     *  If already on the event thread, runs f() inline to avoid self-deadlock. */
    template<typename R>
    R RunOnEventThread(std::function<R()> f) {
        if (std::this_thread::get_id() == event_thread_id_) {
            return f();
        }
        auto promise = std::make_shared<std::promise<R>>();
        auto future = promise->get_future();
        std::function<void()> task = [f, promise]() {
            try {
                promise->set_value(f());
            } catch (...) {
                promise->set_exception(std::current_exception());
            }
        };
        {
            std::lock_guard<std::mutex> lock(task_mutex_);
            task_queue_.push(task);
        }
        task_cv_.notify_one();
        return future.get();
    }

    /** Post a void task to the event thread without waiting. Safe to call from within event thread (e.g. Tox callbacks). */
    void PostToEventThread(std::function<void()> task) {
        std::lock_guard<std::mutex> lock(task_mutex_);
        task_queue_.push(std::move(task));
        task_cv_.notify_one();
    }
    
#ifdef BUILD_TOXAV
    // Helper method to get ToxAVManager instance (for internal use)
    ToxAVManager* GetToxAVManager();
#endif
    
    // Rejoin all known groups using stored chat_id (c-toxcore recommended approach)
    // This can be called from InitSDK or from Dart layer after init() completes
    // Should be called after Tox connection is established for best success rate
    void RejoinKnownGroups();

    // Stop background tasks (refresh cache, rejoin groups). Called from UnInitSDK and destructor.
    void StopBackgroundTasks();

private:
    struct PendingInvite {
        uint32_t friend_number;
        std::vector<uint8_t> cookie;
        Tox_Group_Number group_number;  // Store group_number after accepting invite
        std::string inviter_userID;     // Store inviter's userID for onMemberInvited callback
    };
    // Tox profile path used in InitSDK; UnInitSDK and SaveToxProfile use this instead of recomputing
    std::string save_path_;

    // ToxManager instance (owned by this V2TIMManagerImpl instance)
    std::unique_ptr<ToxManager> tox_manager_;
    
#ifdef BUILD_TOXAV
    // ToxAVManager instance (owned by this V2TIMManagerImpl instance).
    // Custom deleter required because ToxAVManager has a private destructor.
    std::unique_ptr<ToxAVManager, void(*)(ToxAVManager*)> toxav_manager_;
#endif
    
    std::thread event_thread_;
    std::thread::id event_thread_id_;  // Set by event thread at start; used to avoid deadlock when RunOnEventThread is called from event thread
    std::atomic<bool> running_{true};  // Use atomic to prevent compiler optimization issues
    // Joinable background tasks (no detach) to avoid UAF when instance is destroyed.
    // Use std::thread + atomic stop flag for compatibility (std::jthread is C++20 and not on all toolchains).
    std::thread refresh_task_;
    std::thread rejoin_task_;
    std::atomic<bool> refresh_task_running_{false};
    std::atomic<bool> refresh_stop_requested_{false};
    std::atomic<bool> rejoin_stop_requested_{false};
    std::mutex task_mutex_;
    std::queue<std::function<void()>> task_queue_;
    std::condition_variable task_cv_;  // Signalled when a task is pushed so event thread can process
    V2TIMString logged_in_user_;
    std::mutex mutex_;

    // --- Listener Sets ---
    std::unordered_set<V2TIMSDKListener*> sdk_listeners_;
    std::unordered_set<V2TIMSimpleMsgListener*> simple_msg_listeners_;
    std::unordered_set<V2TIMGroupListener*> group_listeners_;

    // --- Mappings ---
    // Map V2TIM GroupID string to Tox group_number
    std::unordered_map<V2TIMString, Tox_Group_Number> group_id_to_group_number_;
    // Map Tox group_number back to V2TIM GroupID string (for receiving messages)
    std::unordered_map<Tox_Group_Number, V2TIMString> group_number_to_group_id_;
    // Map V2TIM GroupID string to Tox chat_id (stable identifier, 32 bytes)
    std::unordered_map<V2TIMString, std::vector<uint8_t>> group_id_to_chat_id_;
    // Map Tox chat_id (as hex string) back to V2TIM GroupID string
    std::unordered_map<std::string, V2TIMString> chat_id_to_group_id_;
    // Map V2TIM GroupID string to group type ("group" or "conference")
    std::unordered_map<V2TIMString, std::string> group_id_to_type_;
    // R-07: Instance metadata (known groups list + auto-accept; chat_id/type use maps above)
    std::vector<std::string> known_groups_;
    bool auto_accept_group_invites_{false};
    std::mutex metadata_mutex_;
    // Pending group invites awaiting JoinGroup
    std::unordered_map<V2TIMString, PendingInvite> pending_group_invites_;
    // Flag to track if RejoinKnownGroups has been triggered after connection establishment
    std::atomic<bool> rejoin_triggered_{false};
    // User-facing login alias (from Login(userID)); GetLoginUser() returns this
    V2TIMString login_user_alias_;
    // Member list snapshots for each group (for detecting join/leave)
    std::unordered_map<Tox_Group_Number, std::unordered_set<std::string>> group_peer_snapshots_;
    // (group_number, peer_public_key_hex_lower) -> peer_id, populated from HandleGroupPeerJoin for group private send
    std::unordered_map<Tox_Group_Number, std::unordered_map<std::string, Tox_Group_Peer_Number>> group_peer_id_cache_;
    // Global counter for generating unique group IDs (to avoid reusing IDs from deleted groups)
    uint64_t next_group_id_counter_;
    std::atomic<uint64_t> next_message_seq_{1};
    std::atomic<uint64_t> next_group_seq_{1};
    // Per-instance sub-managers (R-06: owned by this instance, no singleton)
    std::unique_ptr<V2TIMMessageManagerImpl> message_manager_;
    std::unique_ptr<V2TIMGroupManagerImpl> group_manager_;
    std::unique_ptr<V2TIMConversationManagerImpl> conversation_manager_;
    std::unique_ptr<V2TIMCommunityManagerImpl> community_manager_;
    std::unique_ptr<V2TIMFriendshipManagerImpl> friendship_manager_;
    // Per-instance signaling manager (multi-instance support)
    std::unique_ptr<V2TIMSignalingManagerImpl> signaling_manager_;
    
    // TODO: Consider mapping for friend numbers to UserIDs if needed frequently
    // std::unordered_map<uint32_t, V2TIMString> friend_number_to_user_id_;
    // std::unordered_map<V2TIMString, uint32_t> user_id_to_friend_number_;

    // --- Internal Handler Methods ---
    void HandleGroupMessage(uint32_t conference_number, uint32_t peer_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length);
    void HandleFriendMessage(uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length);
    void HandleSelfConnectionStatus(TOX_CONNECTION connection_status);
    void HandleFriendRequest(const uint8_t* public_key, const uint8_t* message, size_t length);
    void HandleFriendName(uint32_t friend_number, const uint8_t* name, size_t length);
    void HandleFriendStatusMessage(uint32_t friend_number, const uint8_t* message, size_t length);
    void HandleFriendStatus(uint32_t friend_number, TOX_USER_STATUS status);
    void HandleFriendConnectionStatus(uint32_t friend_number, TOX_CONNECTION connection_status);
    void HandleGroupTitle(uint32_t conference_number, uint32_t peer_number, const uint8_t* title, size_t length);
    void HandleGroupPeerName(uint32_t conference_number, uint32_t peer_number, const uint8_t* name, size_t length);
    void HandleGroupPeerListChanged(uint32_t conference_number);
    void HandleGroupConnected(uint32_t conference_number);
    
    // Tox group handlers
    void HandleGroupMessageGroup(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id);
    void HandleGroupPrivateMessage(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id);
    void HandleGroupTopic(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* topic, size_t length);
    void HandleGroupPeerNameGroup(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* name, size_t length);
    void HandleGroupPeerJoin(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id);
    void HandleGroupPeerExit(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, Tox_Group_Exit_Type exit_type, const uint8_t* name, size_t name_length);
    void HandleGroupModeration(Tox_Group_Number group_number, Tox_Group_Peer_Number source_peer_id, Tox_Group_Peer_Number target_peer_id, Tox_Group_Mod_Event mod_type);
    void HandleGroupSelfJoin(Tox_Group_Number group_number);
    void HandleGroupJoinFail(Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type);
    void HandleGroupPrivacyState(Tox_Group_Number group_number, Tox_Group_Privacy_State privacy_state);
    void HandleGroupVoiceState(Tox_Group_Number group_number, Tox_Group_Voice_State voice_state);
    void HandleGroupPeerStatus(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_USER_STATUS status);
    // TODO: Add handlers for other Tox callbacks (read receipts, file transfer, etc.)

    // Constructor and destructor are now public (declared above)

    // Delete copy constructor and assignment operator
    V2TIMManagerImpl(const V2TIMManagerImpl&) = delete;
    V2TIMManagerImpl& operator=(const V2TIMManagerImpl&) = delete;

    friend class V2TIMManager; // Allow V2TIMManager::GetInstance() potentially
    friend class V2TIMGroupManagerImpl; // Allow V2TIMGroupManagerImpl to access private members
    // Allow tim2tox_ffi functions to access private members for chat ID lookup
    friend int tim2tox_ffi_get_group_chat_id(int64_t instance_id, const char* group_id, char* out_chat_id, int out_len);
};

#endif // __V2TIM_MANAGER_IMPL_H__
