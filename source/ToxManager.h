// tox_manager.h
#pragma once

#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include "toxcore/tox.h"
#include <functional>
#include <stdexcept>
#include <vector>

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

    // 核心功能接口
    Tox* getTox() const;
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
    std::unique_lock<std::mutex> lockIterate() {
        if (iterate_owner_.load(std::memory_order_acquire) == std::this_thread::get_id()) {
            return std::unique_lock<std::mutex>();
        }
        return std::unique_lock<std::mutex>(iterate_mutex_);
    }

    // 数据保存和加载
    std::vector<uint8_t> getSaveData() const;
    bool saveTo(const std::string& path) const;
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
    using GroupInviteGroupCallback = std::function<void(Tox_Friend_Number, const uint8_t*, size_t)>;
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
    std::unique_ptr<Tox, decltype(&toxDeleter)> tox_;
    mutable std::mutex mutex_;
    std::mutex iterate_mutex_;  // Serialize tox_iterate - toxcore requires single-threaded access per instance
    std::atomic<std::thread::id> iterate_owner_{};  // thread holding iterate_mutex_ inside iterate()/shutdown() (see lockIterate)
    std::atomic<bool> is_shutting_down_{false};  // Flag to prevent double cleanup; atomic for lock-free read in iterate()
    bool tcp_relay_server_allowed_{true};  // see setTcpRelayServerAllowed

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
