// tox_manager.h
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include "toxcore/tox.h"
#include <functional>
#include <stdexcept>
#include <vector>

// Legacy conferences and NGC groups are numbered by toxcore in two independent
// spaces that both start at 0, so conference #0 and NGC group #0 routinely
// coexist. Tim2Tox keeps one groupID <-> number map for both kinds; to keep the
// keys disjoint, a conference is stored under its number with the high bit set.
// A tagged key handed to a tox_group_* API fails its lookup (NGC numbers are
// small indices), so a kind mix-up degrades to an error instead of acting on
// the other group. Conference wrappers below strip the tag, and every direct
// tox_conference_* / toxav_group* call must pass ConferenceNumberFromKey().
constexpr uint32_t kConferenceMapKeyTag = 0x80000000u;
inline uint32_t ConferenceMapKey(uint32_t conference_number) {
    return conference_number == UINT32_MAX ? UINT32_MAX
                                           : (conference_number | kConferenceMapKeyTag);
}
inline bool IsConferenceMapKey(uint32_t key) {
    return key != UINT32_MAX && (key & kConferenceMapKeyTag) != 0;
}
inline uint32_t ConferenceNumberFromKey(uint32_t key) {
    return key == UINT32_MAX ? UINT32_MAX : (key & ~kConferenceMapKeyTag);
}

// Marks "this thread is inside a tox_iterate()/toxav_iterate()" and carries a
// per-thread queue of work that must not run from inside a callback. Tox and
// ToxAV callbacks run synchronously on the iterating thread while it holds the
// iterate's NON-recursive lock and while toxcore is still walking the objects
// that fired them. A callback that tears down (UnInitSDK, ToxManager/
// ToxAVManager::shutdown) would re-lock that mutex, join its own thread, or
// free the Tox/ToxAV under the running iterate. Such calls Defer() themselves
// instead; the queue runs on the same thread as soon as its OUTERMOST scope
// exits. Every iterate()/shutdown() that sets an iterate owner declares a
// scope as its FIRST local, so the deferred work runs after all of that
// function's locks are released and after its last member access.
class IterateReentryScope {
public:
    IterateReentryScope();
    ~IterateReentryScope();
    IterateReentryScope(const IterateReentryScope&) = delete;
    IterateReentryScope& operator=(const IterateReentryScope&) = delete;

    // True while the calling thread is inside any scope.
    static bool Active();
    // Queue fn to run on this thread once its outermost scope exits. Returns
    // false (fn dropped) when no scope is active on this thread.
    static bool Defer(std::function<void()> fn);
};

class ToxManager {
public:
    // 删除拷贝构造函数和赋值运算符
    ToxManager(const ToxManager&) = delete;
    ToxManager& operator=(const ToxManager&) = delete;

    // 构造函数（现在是 public，支持多实例）
    ToxManager();
    
    // 析构函数
    ~ToxManager();

    // 向后兼容：获取默认实例（用于现有代码）
    // 注意：在生产环境中，建议使用实例化对象而不是默认实例
    static ToxManager* getDefaultInstance();

    // 初始化/关闭方法
    void initialize(const Tox_Options* options = nullptr,
                   const uint8_t* savedata = nullptr,
                   size_t savedata_length = 0);
    void shutdown();

    // A fixed TCP-relay-server port (TOX_TCP_RELAY_PORT / debug.toxee.tcp_relay_port)
    // is a PER-PROCESS resource: only one Tox in the process can bind it, and a
    // second one fails tox_new outright with TOX_ERR_NEW_PORT_ALLOC. Auxiliary
    // instances (e.g. a short-lived bootstrap-node reachability probe) neither
    // need nor may run a relay server, so the session instance keeps the port
    // and everyone else silently runs without one. Default true so the ordinary
    // single-instance path is unchanged.
    void setTcpRelayServerAllowed(bool allowed) { tcp_relay_server_allowed_ = allowed; }

    // Preferred UDP bind range for this instance's tox_new (start..end,
    // inclusive; toxcore binds the first free port). 0/0 = toxcore default.
    // Lives HERE, next to the other tox_new-time knobs, because both
    // initialize() and loadFrom() reach tox_new and loadFrom builds its own
    // Tox_Options — an option set only on the caller's Tox_Options would be
    // dropped on every profile reload. Used by LAN bootstrap nodes to honour
    // the user's chosen port.
    void setUdpPortRange(uint16_t start_port, uint16_t end_port) {
        udp_start_port_ = start_port;
        udp_end_port_ = end_port;
    }

    // 核心功能接口
    // Raw, UNPINNED handle. Valid only for as long as the caller can prove the
    // session cannot end underneath it — i.e. from inside a tox callback (the
    // iterating thread; teardown defers, see IterateReentryScope) or while a
    // pin from acquireTox() is alive. Anything reachable from another thread
    // (the FFI surface) must use acquireTox()/V2TIMManagerImpl::AcquireToxSession
    // instead: shutdown() can otherwise tox_kill() the instance between two
    // consecutive tox_*() calls of the same operation.
    Tox* getTox() const;
    // Pin the live Tox for the duration of a call sequence. Returns null while
    // shutting down / before initialize (the operation must then refuse).
    //
    // Why a shared_ptr and not a lock: a lock held across a whole operation
    // would have to be ranked against iterate_mutex_ (which shutdown() takes
    // FIRST and which callers legitimately take via lockIterate()), and either
    // ranking deadlocks one of the two. A refcount cannot deadlock: shutdown()
    // still returns immediately, it just hands the last reference — and with it
    // the tox_kill() — to whoever is still inside an operation. tox_iterate()
    // is already stopped by then (UnInitSDK joins the event thread before
    // ToxManager::shutdown), so the pinned instance has exactly one user left.
    std::shared_ptr<Tox> acquireTox() const;
    void iterate(uint32_t timeout = 0);
    bool isShuttingDown() const;
    // Serialize a toxcore entry point that BYPASSES the per-instance lock
    // (tox_callback_* registration, toxav_new/toxav_kill's per-pktid handler
    // registration) with tox_iterate(). NOT for ordinary tox_*() calls — those
    // are serialized inside toxcore (experimental_thread_safety, see
    // initialize()). Never call from a tox callback: the event thread holds
    // this NON-recursive mutex for the whole iterate — so when called ON that
    // thread (from inside a tox callback) it returns an unowned lock: the
    // caller is already serialized with the iterate by construction.
    std::unique_lock<std::mutex> lockIterate() const {
        if (isIterateOwner()) {
            return std::unique_lock<std::mutex>();
        }
        return std::unique_lock<std::mutex>(iterate_mutex_);
    }
    // True when the calling thread holds iterate_mutex_ inside iterate() or
    // shutdown(), i.e. it is running a tox callback of this instance.
    bool isIterateOwner() const {
        return iterate_owner_.load(std::memory_order_acquire) == std::this_thread::get_id();
    }

    // 数据保存和加载
    //
    // getSaveData() is ATOMIC with respect to every mutator Tim2Tox has.
    // WHY: toxcore takes its instance mutex separately in
    // tox_get_savedata_size() and in tox_get_savedata() (which re-reads the
    // size for its own memzero), and that mutex is NOT recursive, so a caller
    // cannot hold it across the pair. Anything that enlarges the savedata
    // between the two — a conference/NGC join, a friend add, a self-name
    // change — then makes toxcore write MORE bytes than the buffer we sized:
    // a heap overflow (codex 2026-09-24). So instead of toxcore's lock we
    // quiesce OUR mutators: the pin gate below stops every acquireTox()
    // operation and iterate_mutex_ stops tox_iterate -- IN THAT ORDER, because
    // callers legitimately hold a pin and then wait for iterate_mutex_ (the
    // poll loop did it every round), and a saver holding the iterate lock while
    // waiting for those pins deadlocks against them until the timeout
    // (codex 2026-09-26). When they still do not drain the save is REFUSED
    // (returns {}) rather than risking the overflow; the previously written
    // profile stays valid and saveTo() returns false so the caller retries.
    //
    // The ordering rule this implies, for anything added later: NEVER take
    // iterate_mutex_ and then wait for a pin. Taking a pin and then
    // iterate_mutex_ is fine and is what callers do.
    std::vector<uint8_t> getSaveData() const;
    bool saveTo(const std::string& path) const;
    static constexpr std::chrono::seconds kSaveQuiesceTimeout{5};
    bool loadFrom(const std::string& path);

    // 基本功能接口
    // 用户信息相关
    bool setName(const std::string& name);
    std::string getName() const;
    bool setStatusMessage(const std::string& message);
    std::string getStatusMessage() const;
    bool setStatus(TOX_USER_STATUS status);
    TOX_USER_STATUS getStatus() const;
    std::string getAddress() const;

    // 好友相关
    uint32_t addFriend(const uint8_t* address, const uint8_t* message, size_t length, TOX_ERR_FRIEND_ADD* error = nullptr);
    bool deleteFriend(uint32_t friend_number, TOX_ERR_FRIEND_DELETE* error = nullptr);
    bool sendMessage(uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, uint32_t* message_id = nullptr);
    bool getFriendPublicKey(uint32_t friend_number, uint8_t* public_key) const;
    std::string getFriendName(uint32_t friend_number) const;
    std::string getFriendStatusMessage(uint32_t friend_number) const;
    TOX_CONNECTION getFriendConnectionStatus(uint32_t friend_number) const;
    TOX_USER_STATUS getFriendStatus(uint32_t friend_number) const;
    bool getFriendLastOnline(uint32_t friend_number, time_t* last_online) const;

    // 文件传输相关
    uint32_t sendFile(uint32_t friend_number, uint32_t kind, uint64_t file_size,
                     const uint8_t* file_id, const uint8_t* filename, size_t filename_length,
                     TOX_ERR_FILE_SEND* error = nullptr);
    bool sendFileChunk(uint32_t friend_number, uint32_t file_number,
                      uint64_t position, const uint8_t* data, size_t length,
                      TOX_ERR_FILE_SEND_CHUNK* error = nullptr);
    bool fileControl(uint32_t friend_number, uint32_t file_number,
                    TOX_FILE_CONTROL control, TOX_ERR_FILE_CONTROL* error = nullptr);
    bool fileSeek(uint32_t friend_number, uint32_t file_number,
                 uint64_t position, TOX_ERR_FILE_SEEK* error = nullptr);

    // 群组相关 (tox group API)
    Tox_Group_Number createGroup(Tox_Group_Privacy_State privacy_state,
                                 const uint8_t* group_name, size_t group_name_length,
                                 const uint8_t* name, size_t name_length,
                                 Tox_Err_Group_New* error = nullptr);
    bool deleteGroup(Tox_Group_Number group_number, Tox_Err_Group_Leave* error = nullptr);
    Tox_Group_Number joinGroup(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE],
                               const uint8_t* name, size_t name_length,
                               const uint8_t* password, size_t password_length,
                               Tox_Err_Group_Join* error = nullptr);
    bool groupSendMessage(Tox_Group_Number group_number, TOX_MESSAGE_TYPE type,
                         const uint8_t* message, size_t length,
                         Tox_Group_Message_Id* message_id = nullptr,
                         Tox_Err_Group_Send_Message* error = nullptr);
    bool setGroupTopic(Tox_Group_Number group_number, const uint8_t* topic, size_t length,
                      Tox_Err_Group_Topic_Set* error = nullptr);
    bool getGroupTopic(Tox_Group_Number group_number, uint8_t* topic, size_t max_length,
                      Tox_Err_Group_State_Query* error = nullptr);
    bool getGroupName(Tox_Group_Number group_number, uint8_t* name, size_t max_length,
                     Tox_Err_Group_State_Query* error = nullptr);
    bool getGroupPeerName(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                         uint8_t* name, size_t max_length,
                         Tox_Err_Group_Peer_Query* error = nullptr);
    uint32_t getGroupPeerCount(Tox_Group_Number group_number, Tox_Err_Group_Peer_Query* error = nullptr);
    bool isGroupConnected(Tox_Group_Number group_number, Tox_Err_Group_Is_Connected* error = nullptr);
    bool getGroupChatId(Tox_Group_Number group_number, uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE],
                       Tox_Err_Group_State_Query* error = nullptr);
    // Note: There's no direct tox_group_by_chat_id API, need to iterate groups and compare chat_id
    Tox_Group_Number getGroupByChatId(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]);
    bool inviteToGroup(Tox_Group_Number group_number, Tox_Friend_Number friend_number,
                      Tox_Err_Group_Invite_Friend* error = nullptr);
    bool kickGroupMember(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                        Tox_Err_Group_Kick_Peer* error = nullptr);
    bool setGroupMemberRole(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                           Tox_Group_Role role, Tox_Err_Group_Set_Role* error = nullptr);
    Tox_Group_Role getGroupMemberRole(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                     Tox_Err_Group_Peer_Query* error = nullptr);
    Tox_Group_Role getSelfRole(Tox_Group_Number group_number, Tox_Err_Group_Self_Query* error = nullptr);
    Tox_Group_Topic_Lock getGroupTopicLock(Tox_Group_Number group_number,
                                           Tox_Err_Group_State_Query* error = nullptr);
    bool getGroupPeerPublicKey(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                              uint8_t public_key[TOX_PUBLIC_KEY_SIZE],
                              Tox_Err_Group_Peer_Query* error = nullptr);
    bool isGroupPeerOurs(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                        Tox_Err_Group_Peer_Query* error = nullptr);
    size_t getGroupListSize() const;
    void getGroupList(Tox_Group_Number* group_list, size_t list_size) const;
    
    // 群聊ID相关
    bool getConferenceId(uint32_t conference_number, uint8_t id[TOX_CONFERENCE_ID_SIZE]);
    uint32_t getConferenceById(const uint8_t id[TOX_CONFERENCE_ID_SIZE], TOX_ERR_CONFERENCE_BY_ID* error);
    Tox_Conference_Type getConferenceType(uint32_t conference_number, TOX_ERR_CONFERENCE_GET_TYPE* error);
    
    // 封装直接调用的API
    bool inviteToConference(uint32_t friend_number, uint32_t conference_number, TOX_ERR_CONFERENCE_INVITE* error = nullptr);
    size_t getConferenceListSize() const;
    void getConferenceList(uint32_t* chatlist, size_t list_size) const;
    bool getConferencePeerPublicKey(uint32_t conference_number, uint32_t peer_number, uint8_t public_key[TOX_PUBLIC_KEY_SIZE], TOX_ERR_CONFERENCE_PEER_QUERY* error) const;
    bool isConferencePeerOurs(uint32_t conference_number, uint32_t peer_number, TOX_ERR_CONFERENCE_PEER_QUERY* error) const;
    bool getConferenceTitle(uint32_t conference_number, uint8_t* title, size_t max_length, TOX_ERR_CONFERENCE_TITLE* error) const;
    
    // 离线成员相关
    uint32_t getConferenceOfflinePeerCount(uint32_t conference_number, TOX_ERR_CONFERENCE_PEER_QUERY* error) const;
    size_t getConferenceOfflinePeerNameSize(uint32_t conference_number, uint32_t offline_peer_number, TOX_ERR_CONFERENCE_PEER_QUERY* error) const;
    bool getConferenceOfflinePeerName(uint32_t conference_number, uint32_t offline_peer_number, uint8_t* name, size_t max_length, TOX_ERR_CONFERENCE_PEER_QUERY* error) const;
    bool getConferenceOfflinePeerPublicKey(uint32_t conference_number, uint32_t offline_peer_number, uint8_t public_key[TOX_PUBLIC_KEY_SIZE], TOX_ERR_CONFERENCE_PEER_QUERY* error) const;
    uint64_t getConferenceOfflinePeerLastActive(uint32_t conference_number, uint32_t offline_peer_number, TOX_ERR_CONFERENCE_PEER_QUERY* error) const;
    bool setConferenceMaxOffline(uint32_t conference_number, uint32_t max_offline, TOX_ERR_CONFERENCE_SET_MAX_OFFLINE* error);

    // 回调类型定义
    using SelfConnectionStatusCallback = std::function<void(TOX_CONNECTION)>;
    using FriendRequestCallback = std::function<void(const uint8_t*, const uint8_t*, size_t)>;
    using FriendMessageCallback = std::function<void(uint32_t, TOX_MESSAGE_TYPE, const uint8_t*, size_t)>;
    using FriendNameCallback = std::function<void(uint32_t, const uint8_t*, size_t)>;
    using FriendStatusMessageCallback = std::function<void(uint32_t, const uint8_t*, size_t)>;
    using FriendStatusCallback = std::function<void(uint32_t, TOX_USER_STATUS)>;
    using FriendConnectionStatusCallback = std::function<void(uint32_t, TOX_CONNECTION)>;
    using FriendReadReceiptCallback = std::function<void(uint32_t, uint32_t)>;
    using FriendTypingCallback = std::function<void(uint32_t, bool)>;
    using FileRecvCallback = std::function<void(uint32_t, uint32_t, uint32_t, uint64_t, const uint8_t*, size_t)>;
    using FileControlCallback = std::function<void(uint32_t friend_number, uint32_t file_number, TOX_FILE_CONTROL control)>;
    using FileChunkRequestCallback = std::function<void(uint32_t, uint32_t, uint64_t, size_t)>;
    using FileRecvChunkCallback = std::function<void(uint32_t, uint32_t, uint64_t, const uint8_t*, size_t)>;
    // Conference callbacks (deprecated, kept for compatibility)
    using GroupInviteCallback = std::function<void(uint32_t, TOX_CONFERENCE_TYPE, const uint8_t*, size_t)>;
    using GroupMessageCallback = std::function<void(uint32_t, uint32_t, TOX_MESSAGE_TYPE, const uint8_t*, size_t)>;
    using GroupTitleCallback = std::function<void(uint32_t, uint32_t, const uint8_t*, size_t)>;
    using GroupPeerNameCallback = std::function<void(uint32_t, uint32_t, const uint8_t*, size_t)>;
    using GroupPeerListChangedCallback = std::function<void(uint32_t)>;
    using GroupConnectedCallback = std::function<void(uint32_t)>;
    
    // Tox group callbacks
    // (friend_number, invite_data, invite_data_length, group_name)
    using GroupInviteGroupCallback = std::function<void(Tox_Friend_Number, const uint8_t*, size_t, const std::string&)>;
    using GroupMessageGroupCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number, TOX_MESSAGE_TYPE, const uint8_t*, size_t, Tox_Group_Message_Id)>;
    using GroupCustomPacketCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number, const uint8_t*, size_t)>;
    using GroupPrivateMessageGroupCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number, TOX_MESSAGE_TYPE, const uint8_t*, size_t, Tox_Group_Message_Id)>;
    using GroupTopicCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number, const uint8_t*, size_t)>;
    using GroupPeerNameGroupCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number, const uint8_t*, size_t)>;
    using GroupPeerJoinCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number)>;
    using GroupPeerExitCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number, Tox_Group_Exit_Type, const uint8_t*, size_t)>;
    using GroupModerationCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number, Tox_Group_Peer_Number, Tox_Group_Mod_Event)>;
    using GroupSelfJoinCallback = std::function<void(Tox_Group_Number)>;
    using GroupJoinFailCallback = std::function<void(Tox_Group_Number, Tox_Group_Join_Fail)>;
    using GroupPrivacyStateCallback = std::function<void(Tox_Group_Number, Tox_Group_Privacy_State)>;
    using GroupVoiceStateCallback = std::function<void(Tox_Group_Number, Tox_Group_Voice_State)>;
    using GroupPeerStatusCallback = std::function<void(Tox_Group_Number, Tox_Group_Peer_Number, TOX_USER_STATUS)>;
    using FriendLossyPacketCallback = std::function<void(uint32_t, const uint8_t*, size_t)>;
    using FriendLosslessPacketCallback = std::function<void(uint32_t, const uint8_t*, size_t)>;
    using AudioReceiveCallback = std::function<void(uint32_t, const int16_t*, size_t, uint8_t, uint32_t)>;

    // 设置回调的方法
    void setSelfConnectionStatusCallback(SelfConnectionStatusCallback cb);
    void setFriendRequestCallback(FriendRequestCallback cb);
    void setFriendMessageCallback(FriendMessageCallback cb);
    void setFriendNameCallback(FriendNameCallback cb);
    void setFriendStatusMessageCallback(FriendStatusMessageCallback cb);
    void setFriendStatusCallback(FriendStatusCallback cb);
    void setFriendConnectionStatusCallback(FriendConnectionStatusCallback cb);
    void setFriendReadReceiptCallback(FriendReadReceiptCallback cb);
    void setFriendTypingCallback(FriendTypingCallback cb);
    void setFileRecvCallback(FileRecvCallback cb);
    void setFileControlCallback(FileControlCallback cb);
    FileControlCallback getFileControlCallback() const;
    void setFileChunkRequestCallback(FileChunkRequestCallback cb);
    void setFileRecvChunkCallback(FileRecvChunkCallback cb);
    void setGroupInviteCallback(GroupInviteCallback cb);
    void setGroupMessageCallback(GroupMessageCallback cb);
    void setGroupTitleCallback(GroupTitleCallback cb);
    void setGroupPeerNameCallback(GroupPeerNameCallback cb);
    void setGroupPeerListChangedCallback(GroupPeerListChangedCallback cb);
    void setGroupConnectedCallback(GroupConnectedCallback cb);
    
    // Tox group callback setters
    void setGroupInviteGroupCallback(GroupInviteGroupCallback cb);
    void setGroupMessageGroupCallback(GroupMessageGroupCallback cb);
    void setGroupCustomPacketCallback(GroupCustomPacketCallback cb);
    // Same shape as the broadcast custom packet, addressed to us alone.
    void setGroupCustomPrivatePacketCallback(GroupCustomPacketCallback cb);
    void setGroupPrivateMessageGroupCallback(GroupPrivateMessageGroupCallback cb);
    void setGroupTopicCallback(GroupTopicCallback cb);
    void setGroupPeerNameGroupCallback(GroupPeerNameGroupCallback cb);
    void setGroupPeerJoinCallback(GroupPeerJoinCallback cb);
    void setGroupPeerExitCallback(GroupPeerExitCallback cb);
    void setGroupModerationCallback(GroupModerationCallback cb);
    void setGroupSelfJoinCallback(GroupSelfJoinCallback cb);
    void setGroupJoinFailCallback(GroupJoinFailCallback cb);
    void setGroupPrivacyStateCallback(GroupPrivacyStateCallback cb);
    void setGroupVoiceStateCallback(GroupVoiceStateCallback cb);
    void setGroupPeerStatusCallback(GroupPeerStatusCallback cb);
    void setFriendLossyPacketCallback(FriendLossyPacketCallback cb);
    void setFriendLosslessPacketCallback(FriendLosslessPacketCallback cb);
    void setAudioReceiveCallback(AudioReceiveCallback cb);

    // 静态回调函数声明
    static void onSelfConnectionStatus(Tox* tox, TOX_CONNECTION connection_status, void* user_data);
    static void onFriendRequest(Tox* tox, const uint8_t* public_key, const uint8_t* message, size_t length, void* user_data);
    static void onFriendMessage(Tox* tox, uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, void* user_data);
    static void onFriendName(Tox* tox, uint32_t friend_number, const uint8_t* name, size_t length, void* user_data);
    static void onFriendStatusMessage(Tox* tox, uint32_t friend_number, const uint8_t* message, size_t length, void* user_data);
    static void onFriendStatus(Tox* tox, uint32_t friend_number, TOX_USER_STATUS status, void* user_data);
    static void onFriendConnectionStatus(Tox* tox, uint32_t friend_number, TOX_CONNECTION connection_status, void* user_data);
    static void onFriendReadReceipt(Tox* tox, uint32_t friend_number, uint32_t message_id, void* user_data);
    static void onFriendTyping(Tox* tox, uint32_t friend_number, bool typing, void* user_data);
    static void onFileRecv(Tox* tox, uint32_t friend_number, uint32_t file_number, uint32_t kind, uint64_t file_size, const uint8_t* filename, size_t filename_length, void* user_data);
    static void onFileControl(Tox* tox, uint32_t friend_number, uint32_t file_number, TOX_FILE_CONTROL control, void* user_data);
    static void onFileChunkRequest(Tox* tox, uint32_t friend_number, uint32_t file_number, uint64_t position, size_t length, void* user_data);
    static void onFileRecvChunk(Tox* tox, uint32_t friend_number, uint32_t file_number, uint64_t position, const uint8_t* data, size_t length, void* user_data);
    static void onGroupInvite(Tox* tox, uint32_t friend_number, TOX_CONFERENCE_TYPE type, const uint8_t* cookie, size_t length, void* user_data);
    static void onGroupMessage(Tox* tox, uint32_t conference_number, uint32_t peer_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, void* user_data);
    static void onGroupTitle(Tox* tox, uint32_t conference_number, uint32_t peer_number, const uint8_t* title, size_t length, void* user_data);
    static void onGroupPeerName(Tox* tox, uint32_t conference_number, uint32_t peer_number, const uint8_t* name, size_t length, void* user_data);
    static void onGroupPeerListChanged(Tox* tox, uint32_t conference_number, void* user_data);
    static void onGroupConnected(Tox* tox, uint32_t conference_number, void* user_data);
    
    // Tox group static callbacks
    static void onGroupInviteGroup(Tox* tox, Tox_Friend_Number friend_number, const uint8_t* invite_data, size_t invite_data_length, const uint8_t* group_name, size_t group_name_length, void* user_data);
    static void onGroupMessageGroup(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id, void* user_data);
    static void onGroupCustomPacket(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* data, size_t length, void* user_data);
    static void onGroupCustomPrivatePacket(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* data, size_t length, void* user_data);
    static void onGroupPrivateMessage(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t message_length, Tox_Group_Message_Id message_id, void* user_data);
    static void onGroupTopic(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* topic, size_t length, void* user_data);
    static void onGroupPeerNameGroup(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* name, size_t length, void* user_data);
    static void onGroupPeerJoin(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, void* user_data);
    static void onGroupPeerExit(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, Tox_Group_Exit_Type exit_type, const uint8_t* name, size_t name_length, const uint8_t* part_message, size_t part_message_length, void* user_data);
    static void onGroupModeration(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number source_peer_id, Tox_Group_Peer_Number target_peer_id, Tox_Group_Mod_Event mod_type, void* user_data);
    static void onGroupSelfJoin(Tox* tox, Tox_Group_Number group_number, void* user_data);
    static void onGroupJoinFail(Tox* tox, Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type, void* user_data);
    static void onGroupPrivacyState(Tox* tox, Tox_Group_Number group_number, Tox_Group_Privacy_State privacy_state, void* user_data);
    static void onGroupVoiceState(Tox* tox, Tox_Group_Number group_number, Tox_Group_Voice_State voice_state, void* user_data);
    static void onGroupPeerStatus(Tox* tox, Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_USER_STATUS status, void* user_data);
    static void onFriendLossyPacket(Tox* tox, uint32_t friend_number, const uint8_t* data, size_t length, void* user_data);
    static void onFriendLosslessPacket(Tox* tox, uint32_t friend_number, const uint8_t* data, size_t length, void* user_data);

private:
    friend void onSelfConnectionStatus(Tox* tox, TOX_CONNECTION connection_status, void* user_data);
    friend void onFriendRequest(Tox* tox, const uint8_t* public_key, const uint8_t* message, size_t length, void* user_data);
    friend void onFriendMessage(Tox* tox, uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, void* user_data);
    friend void onFriendName(Tox* tox, uint32_t friend_number, const uint8_t* name, size_t length, void* user_data);
    friend void onFriendStatusMessage(Tox* tox, uint32_t friend_number, const uint8_t* message, size_t length, void* user_data);
    friend void onFriendStatus(Tox* tox, uint32_t friend_number, TOX_USER_STATUS status, void* user_data);
    friend void onFriendConnectionStatus(Tox* tox, uint32_t friend_number, TOX_CONNECTION connection_status, void* user_data);
    friend void onFriendReadReceipt(Tox* tox, uint32_t friend_number, uint32_t message_id, void* user_data);
    friend void onFriendTyping(Tox* tox, uint32_t friend_number, bool typing, void* user_data);
    friend void onFileRecv(Tox* tox, uint32_t friend_number, uint32_t file_number, uint32_t kind, uint64_t file_size, const uint8_t* filename, size_t filename_length, void* user_data);
    friend void onFileControl(Tox* tox, uint32_t friend_number, uint32_t file_number, TOX_FILE_CONTROL control, void* user_data);
    friend void onFileChunkRequest(Tox* tox, uint32_t friend_number, uint32_t file_number, uint64_t position, size_t length, void* user_data);
    friend void onFileRecvChunk(Tox* tox, uint32_t friend_number, uint32_t file_number, uint64_t position, const uint8_t* data, size_t length, void* user_data);
    friend void onGroupInvite(Tox* tox, uint32_t friend_number, TOX_CONFERENCE_TYPE type, const uint8_t* cookie, size_t length, void* user_data);
    friend void onGroupMessage(Tox* tox, uint32_t conference_number, uint32_t peer_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, void* user_data);
    friend void onGroupTitle(Tox* tox, uint32_t conference_number, uint32_t peer_number, const uint8_t* title, size_t length, void* user_data);
    friend void onGroupPeerName(Tox* tox, uint32_t conference_number, uint32_t peer_number, const uint8_t* name, size_t length, void* user_data);
    friend void onGroupPeerListChanged(Tox* tox, uint32_t conference_number, void* user_data);
    friend void onGroupConnected(Tox* tox, uint32_t conference_number, void* user_data);
    friend void onFriendLossyPacket(Tox* tox, uint32_t friend_number, const uint8_t* data, size_t length, void* user_data);
    friend void onFriendLosslessPacket(Tox* tox, uint32_t friend_number, const uint8_t* data, size_t length, void* user_data);

    // 构造函数和析构函数现在是 public（支持多实例）
    // 已在上面声明

    // 自定义删除器
    static void toxDeleter(Tox* tox);

    // 成员变量
    // shared_ptr (not unique_ptr) so acquireTox() can hand out a pin that
    // outlives shutdown()'s reset; the tox_kill() in toxDeleter then runs when
    // the last pin is dropped. See acquireTox().
    std::shared_ptr<Tox> tox_;
    mutable std::mutex mutex_;
    mutable std::mutex iterate_mutex_;  // Serialize tox_iterate - toxcore requires single-threaded access per instance
    std::atomic<std::thread::id> iterate_owner_{};  // thread holding iterate_mutex_ inside iterate()/shutdown() (see lockIterate)
    std::shared_ptr<int> alive_token_ = std::make_shared<int>(0);  // lets a deferred shutdown() see that this object is gone

    // --- savedata quiescence (see getSaveData) ------------------------------
    // Accounting for the pins acquireTox() hands out. Held in its own
    // heap object so the pin's deleter never touches the ToxManager, which a
    // long-lived pin can outlive.
    struct PinState {
        std::mutex mutex;
        std::condition_variable cv;
        int count = 0;  // live pins
        // Per-thread depth. A thread that already holds a pin must not wait on
        // its own quiesce, and the quiescing thread must not wait for the pins
        // IT holds (a save from inside a tox callback on the manually-iterating
        // FFI thread holds one).
        std::unordered_map<std::thread::id, int> depth;
        bool quiescing = false;
        std::thread::id quiescing_owner{};
    };
    std::shared_ptr<PinState> pin_state_ = std::make_shared<PinState>();
    // RAII: blocks new pins from other threads, waits (bounded) for the live
    // ones to drain, and releases the block on destruction.
    class SaveQuiesce {
    public:
        explicit SaveQuiesce(std::shared_ptr<PinState> state);
        ~SaveQuiesce();
        SaveQuiesce(const SaveQuiesce&) = delete;
        SaveQuiesce& operator=(const SaveQuiesce&) = delete;
        bool drained() const { return drained_; }
        // See ToxManager::getSaveData: re-confirm after tox_iterate is stopped.
        bool rewait();

    private:
        std::shared_ptr<PinState> state_;
        bool drained_ = false;
    };
    // getSaveData()'s critical section, split out so the retry above reads as
    // one statement. Requires the quiesce AND iterate_mutex_.
    std::vector<uint8_t> readSaveDataQuiesced() const;
    std::atomic<bool> is_shutting_down_{false};  // Flag to prevent double cleanup; atomic for lock-free read in iterate()
    bool tcp_relay_server_allowed_{true};  // see setTcpRelayServerAllowed
    uint16_t udp_start_port_{0};  // see setUdpPortRange
    uint16_t udp_end_port_{0};

    // 回调存储
    SelfConnectionStatusCallback self_connection_status_cb_;
    FriendRequestCallback friend_request_cb_;
    FriendMessageCallback friend_message_cb_;
    FriendNameCallback friend_name_cb_;
    FriendStatusMessageCallback friend_status_message_cb_;
    FriendStatusCallback friend_status_cb_;
    FriendConnectionStatusCallback friend_connection_status_cb_;
    FriendReadReceiptCallback friend_read_receipt_cb_;
    FriendTypingCallback friend_typing_cb_;
    FileRecvCallback file_recv_cb_;
    FileControlCallback file_control_cb_;
    FileChunkRequestCallback file_chunk_request_cb_;
    FileRecvChunkCallback file_recv_chunk_cb_;
    GroupInviteCallback group_invite_cb_;
    GroupMessageCallback group_message_cb_;
    GroupTitleCallback group_title_cb_;
    GroupPeerNameCallback group_peer_name_cb_;
    GroupPeerListChangedCallback group_peer_list_changed_cb_;
    GroupConnectedCallback group_connected_cb_;
    
    // Tox group callbacks
    GroupInviteGroupCallback group_invite_group_cb_;
    GroupMessageGroupCallback group_message_group_cb_;
    GroupCustomPacketCallback group_custom_packet_cb_;
    GroupCustomPacketCallback group_custom_private_packet_cb_;
    GroupPrivateMessageGroupCallback group_private_message_group_cb_;
    GroupTopicCallback group_topic_cb_;
    GroupPeerNameGroupCallback group_peer_name_group_cb_;
    GroupPeerJoinCallback group_peer_join_cb_;
    GroupPeerExitCallback group_peer_exit_cb_;
    GroupModerationCallback group_moderation_cb_;
    GroupSelfJoinCallback group_self_join_cb_;
    GroupJoinFailCallback group_join_fail_cb_;
    GroupPrivacyStateCallback group_privacy_state_cb_;
    GroupVoiceStateCallback group_voice_state_cb_;
    GroupPeerStatusCallback group_peer_status_cb_;
    FriendLossyPacketCallback friend_lossy_packet_cb_;
    FriendLosslessPacketCallback friend_lossless_packet_cb_;
    AudioReceiveCallback audio_receive_cb_;
};
