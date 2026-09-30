#ifndef __V2TIM_FRIENDSHIP_MANAGER_IMPL_H__
#define __V2TIM_FRIENDSHIP_MANAGER_IMPL_H__

#include "V2TIMFriendshipManager.h"
#include "tox.h"
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>
#include "V2TIMLog.h" // Optional for logging
#include "V2TIMFriendship.h"

class V2TIMManagerImpl;
class ToxManager;

class V2TIMFriendshipManagerImpl : public V2TIMFriendshipManager {
public:
    explicit V2TIMFriendshipManagerImpl(V2TIMManagerImpl* owner);

    // Destructor
    ~V2TIMFriendshipManagerImpl() override;

    // Listener Management
    void AddFriendListener(V2TIMFriendshipListener* listener) override;
    void RemoveFriendListener(V2TIMFriendshipListener* listener) override;

    // --- Friend List Management ---
    void GetFriendList(V2TIMValueCallback<V2TIMFriendInfoVector>* callback) override;
    void GetFriendsInfo(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendInfoResultVector>* callback) override;
    void SetFriendInfo(const V2TIMFriendInfo& info, V2TIMCallback* callback) override;
    void SearchFriends(const V2TIMFriendSearchParam& searchParam, V2TIMValueCallback<V2TIMFriendInfoResultVector>* callback) override;
    void AddFriend(const V2TIMFriendAddApplication& application, V2TIMValueCallback<V2TIMFriendOperationResult>* callback) override;
    void DeleteFromFriendList(const V2TIMStringVector& userIDList, V2TIMFriendType deleteType, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) override;
    void CheckFriend(const V2TIMStringVector& userIDList, V2TIMFriendType checkType, V2TIMValueCallback<V2TIMFriendCheckResultVector>* callback) override;
    
    // --- Friend Application Management ---
    void GetFriendApplicationList(V2TIMValueCallback<V2TIMFriendApplicationResult>* callback) override;
    void AcceptFriendApplication(const V2TIMFriendApplication& application, V2TIMFriendAcceptType acceptType, V2TIMValueCallback<V2TIMFriendOperationResult>* callback) override;
    void AcceptFriendApplication(const V2TIMFriendApplication& application, V2TIMFriendAcceptType acceptType, const V2TIMString& remark, V2TIMValueCallback<V2TIMFriendOperationResult>* callback) override;
    void RefuseFriendApplication(const V2TIMFriendApplication& application, V2TIMValueCallback<V2TIMFriendOperationResult>* callback) override;
    void DeleteFriendApplication(const V2TIMFriendApplication& application, V2TIMCallback* callback) override;
    void SetFriendApplicationRead(V2TIMCallback* callback) override;

    // --- Blacklist Management ---
    void AddToBlackList(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) override;
    void DeleteFromBlackList(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) override;
    void GetBlackList(V2TIMValueCallback<V2TIMFriendInfoVector>* callback) override;

    // --- Friend Group Management ---
    void CreateFriendGroup(const V2TIMString& groupName, const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) override;
    void GetFriendGroups(const V2TIMStringVector& groupNameList, V2TIMValueCallback<V2TIMFriendGroupVector>* callback) override;
    void DeleteFriendGroup(const V2TIMStringVector& groupNameList, V2TIMCallback* callback) override;
    void RenameFriendGroup(const V2TIMString& oldName, const V2TIMString& newName, V2TIMCallback* callback) override;
    void AddFriendsToFriendGroup(const V2TIMString& groupName, const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) override;
    void DeleteFriendsFromFriendGroup(const V2TIMString& groupName, const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) override;

    // --- Official Account Management (Placeholders) ---
    void SubscribeOfficialAccount(const V2TIMString& officialAccountID, V2TIMCallback* callback) override;
    void UnsubscribeOfficialAccount(const V2TIMString& officialAccountID, V2TIMCallback* callback) override;
    void GetOfficialAccountsInfo(const V2TIMStringVector& officialAccountIDList, 
                               V2TIMValueCallback<V2TIMOfficialAccountInfoResultVector>* callback) override;
    
    // --- Follow Management (Placeholders) ---
    void FollowUser(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFollowOperationResultVector>* callback) override;
    void UnfollowUser(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFollowOperationResultVector>* callback) override;
    void GetMyFollowingList(const V2TIMString& nextCursor, V2TIMValueCallback<V2TIMUserInfoResult>* callback) override;
    void GetMyFollowersList(const V2TIMString& nextCursor, V2TIMValueCallback<V2TIMUserInfoResult>* callback) override;
    void GetMutualFollowersList(const V2TIMString& nextCursor, V2TIMValueCallback<V2TIMUserInfoResult>* callback) override;
    void GetUserFollowInfo(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFollowInfoVector>* callback) override;
    void CheckFollowType(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFollowTypeCheckResultVector>* callback) override;

    // NO GetToxManager() here on purpose. It handed out an UNPINNED raw
    // ToxManager*, which is precisely how an operation ends up making a sequence
    // of tox_*() calls that a concurrent UnInitSDK can tox_kill() halfway
    // through. Its last two callers were converted to AcquireToxSession() and it
    // was removed, so the footgun cannot be picked up again by accident: use
    // manager_impl_->AcquireToxSession() and read through the guard.

    // --- Internal methods for V2TIMManagerImpl to call ---
    void NotifyFriendApplicationListAdded(const V2TIMFriendApplicationVector& applicationList);
    void NotifyFriendApplicationListDeleted(const V2TIMStringVector& userIDList);
    void NotifyFriendInfoChanged(const V2TIMFriendInfoResultVector& infoList); // Placeholder for info changes
    void NotifyFriendListAdded(const V2TIMFriendInfoVector& infoList);      // Placeholder for when friends are added
    void NotifyFriendListDeleted(const V2TIMStringVector& userIDList);     // Placeholder for when friends are deleted
    void NotifyBlackListAdded(const V2TIMFriendInfoVector& infoList);       // Placeholder for blacklist add
    void NotifyBlackListDeleted(const V2TIMStringVector& userIDList);      // Placeholder for blacklist delete

private:

    // Delete copy/move constructors and assignment operators
    V2TIMFriendshipManagerImpl(const V2TIMFriendshipManagerImpl&) = delete;
    V2TIMFriendshipManagerImpl& operator=(const V2TIMFriendshipManagerImpl&) = delete;
    V2TIMFriendshipManagerImpl(V2TIMFriendshipManagerImpl&&) = delete;
    V2TIMFriendshipManagerImpl& operator=(V2TIMFriendshipManagerImpl&&) = delete;

    // Callback with appropriate error for unimplemented features
    void ReportNotImplemented(V2TIMCallback* callback);
    template <typename T> void ReportNotImplemented(V2TIMValueCallback<T>* callback);
    template <typename T> void ReportNotImplemented(V2TIMCompleteCallback<T>* callback);

    std::mutex mutex_;
    std::mutex listener_mutex_;
    std::vector<V2TIMFriendshipListener*> listeners_;
    
    // 本地存储结构
    // UNUSED: friend_id_map_ is declared but never used in .cpp; remove or implement when needed.
    std::unordered_map<std::string, uint32_t> friend_id_map_; // Tox ID到friend_number的映射
    std::vector<std::string> blacklist_;
    std::unordered_map<std::string, std::vector<std::string>> friend_groups_; // 分组管理
    std::unordered_map<std::string, V2TIMFriendInfo> friend_info_db_;

    // 申请列表本地缓存
    std::mutex application_mutex_;
    V2TIMFriendApplicationVector pending_applications_;

    // Joinable thread for delayed RefreshCache after AcceptFriendApplication (no detach to avoid UAF).
    std::thread refresh_after_accept_thread_;

    // Owner (R-06: set in constructor, no singleton)
    V2TIMManagerImpl* manager_impl_;
};

#endif // __V2TIM_FRIENDSHIP_MANAGER_IMPL_H__
