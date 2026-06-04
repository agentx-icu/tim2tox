#ifndef __V2TIM_CONVERSATION_MANAGER_IMPL_H__
#define __V2TIM_CONVERSATION_MANAGER_IMPL_H__

#include "V2TIMConversationManager.h"
#include "tox.h"
#include <vector>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <chrono>
#include <string>
#include "V2TIMString.h"

// Forward declaration
class V2TIMManagerImpl;

// Value-type cache entry; no raw lastMessage pointer (by design).
struct ConversationSnapshot {
    std::string conversation_id;
    std::string user_id;
    std::string group_id;
    std::string group_type;
    std::string show_name;
    std::string face_url;
    std::string draft_text;
    int unread_count = 0;
    int recv_opt = 0;
    uint64_t draft_timestamp = 0;
    uint64_t order_key = 0;
    uint64_t c2c_read_timestamp = 0;
    uint64_t group_read_sequence = 0;
    bool is_pinned = false;
    int type = 0;
};

class V2TIMConversationManagerImpl : public V2TIMConversationManager {
public:
    explicit V2TIMConversationManagerImpl(V2TIMManagerImpl* owner);
    ~V2TIMConversationManagerImpl() override;

    // 会话监听器管理
    void AddConversationListener(V2TIMConversationListener* listener) override;
    void RemoveConversationListener(V2TIMConversationListener* listener) override;

    // 会话列表操作
    void GetConversationList(uint64_t nextSeq, uint32_t count,
                             V2TIMValueCallback<V2TIMConversationResult>* callback) override;
    void GetConversation(const V2TIMString& conversationID,
                         V2TIMValueCallback<V2TIMConversation>* callback) override;
    void GetConversationList(const V2TIMStringVector& conversationIDList,
                             V2TIMValueCallback<V2TIMConversationVector>* callback) override;
    void GetConversationListByFilter(const V2TIMConversationListFilter &filter,
                                     uint64_t nextSeq, uint32_t count,
                                     V2TIMValueCallback<V2TIMConversationResult>* callback) override;

    // 会话删除
    void DeleteConversation(const V2TIMString& conversationID, V2TIMCallback* callback) override;
    void DeleteConversationList(const V2TIMStringVector& conversationIDList, bool clearMessage,
                                V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) override;

    // 会话属性设置
    void SetConversationDraft(const V2TIMString& conversationID,
                              const V2TIMString& draftText, V2TIMCallback* callback) override;
    void SetConversationCustomData(const V2TIMStringVector &conversationIDList, const V2TIMBuffer &customData,
                                   V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) override;
    void PinConversation(const V2TIMString& conversationID, bool isPinned,
                         V2TIMCallback* callback) override;
    void MarkConversation(const V2TIMStringVector &conversationIDList, uint64_t markType, bool enableMark,
                          V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) override;

    // 未读计数管理
    void GetTotalUnreadMessageCount(V2TIMValueCallback<uint64_t>* callback) override;
    void GetUnreadMessageCountByFilter(const V2TIMConversationListFilter &filter,
                                       V2TIMValueCallback<uint64_t>* callback) override;
    void SubscribeUnreadMessageCountByFilter(const V2TIMConversationListFilter &filter) override;
    void UnsubscribeUnreadMessageCountByFilter(const V2TIMConversationListFilter &filter) override;
    void CleanConversationUnreadMessageCount(const V2TIMString& conversationID, uint64_t cleanTimestamp, uint64_t cleanSequence,
                                             V2TIMCallback* callback) override;

    // 会话分组管理（空实现）
    void CreateConversationGroup(const V2TIMString &groupName, const V2TIMStringVector &conversationIDList,
                                 V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) override;
    void GetConversationGroupList(V2TIMValueCallback<V2TIMStringVector>* callback) override;
    void DeleteConversationGroup(const V2TIMString &groupName, V2TIMCallback* callback) override;
    void RenameConversationGroup(const V2TIMString &oldName, const V2TIMString &newName,
                                 V2TIMCallback* callback) override;
    void AddConversationsToGroup(const V2TIMString &groupName, const V2TIMStringVector &conversationIDList,
                                 V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) override;
    void DeleteConversationsFromGroup(const V2TIMString &groupName, const V2TIMStringVector &conversationIDList,
                                      V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) override;

    // Public method to refresh cache and notify listeners (for use when new conversations appear)
    void RefreshCache() {
        RefreshConversationCache();
        // Notify listeners about new conversations after refresh
        NotifyNewConversations();
    }

    // Refresh cache only without notifying OnNewConversation listeners.
    // Use this after deletions — OnNewConversation would re-add deleted conversations in Dart.
    void RefreshConversationCacheOnly() {
        RefreshConversationCache();
    }

    // Fire OnConversationChanged on all listeners with the conversation
    // identified by `conversationID`. If a cached snapshot exists it's used,
    // otherwise a minimal V2TIMConversation with just the ID is materialized.
    // Called from V2TIMMessageManagerImpl::SendMessage post-success so the
    // binary-replacement send path mirrors the Platform path's
    // `notifyConversationChangedForC2C` semantic — V2TIM clients expect a
    // successful send to refresh the sender's conversation row.
    void NotifyConversationChangedForConvID(const V2TIMString& conversationID);

    // Update the cached C2C conversation's receive option (mute/DND state) and
    // fire OnConversationChanged carrying that recvOpt, so the Dart binary-
    // replacement path learns a real-UI mute immediately (the message manager's
    // SetC2CReceiveMessageOpt only writes an in-memory opt map otherwise, which
    // never reached toxee's conversation cache / notification suppression).
    // If no cached snapshot exists, emits a fully-initialized minimal C2C
    // conversation with the recvOpt WITHOUT creating a phantom cache row.
    void UpdateC2CReceiveOptAndNotify(const std::string& userID, int opt);

private:
    std::vector<V2TIMConversationListener*> listeners_;
    std::mutex listeners_mutex_;

    // 本地会话缓存（值类型，不持有 lastMessage 裸指针）
    std::vector<ConversationSnapshot> cached_conversations_;
    std::mutex cache_mutex_;
    
    // Track last known friend count to detect changes
    size_t last_friend_count_;
    
    // Debounce mechanism for RefreshConversationCache
    // Prevents excessive cache refreshes (e.g., when multiple friend operations happen quickly)
    std::chrono::steady_clock::time_point last_refresh_time_;
    std::mutex refresh_debounce_mutex_;
    static constexpr std::chrono::milliseconds REFRESH_DEBOUNCE_MS{200}; // 200ms debounce
    
    // 置顶状态存储
    std::unordered_map<std::string, bool> pinned_conversations_;
    std::mutex pinned_mutex_;

    // Track explicitly deleted conversation IDs so RefreshConversationCache won't re-add them
    std::unordered_set<std::string> deleted_conversation_ids_;
    std::mutex deleted_ids_mutex_;

    // Reference to V2TIMManagerImpl for multi-instance support
    V2TIMManagerImpl* manager_impl_;
    std::mutex manager_impl_mutex_;

    void RefreshConversationCache();
    V2TIMConversation CreateConversationFromFriend(uint32_t friend_number);
    void NotifyNewConversations();
};

#endif // V2TIM_CONVERSATION_MANAGER_IMPL_H