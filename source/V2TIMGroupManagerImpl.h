#ifndef __V2TIM_GROUP_MANAGER_IMPL_H__
#define __V2TIM_GROUP_MANAGER_IMPL_H__

#include "V2TIMGroupManager.h"
#include "tox.h"
#include <unordered_map>
#include <vector>
#include <mutex>
#include <unordered_set>
#include "V2TIMString.h"

// 前向声明
class V2TIMManagerImpl;

class V2TIMGroupManagerImpl : public V2TIMGroupManager {
public:
    explicit V2TIMGroupManagerImpl(V2TIMManagerImpl* owner);

    ////////////////////////////// 群组管理接口 //////////////////////////////
    void CreateGroup(const V2TIMGroupInfo& info,
                    const V2TIMCreateGroupMemberInfoVector& memberList,
                    V2TIMValueCallback<V2TIMString>* callback) override;
    void GetJoinedGroupList(V2TIMValueCallback<V2TIMGroupInfoVector>* callback) override;

    ////////////////////////////// 群资料和高级设置项 //////////////////////////////
    void GetGroupsInfo(const V2TIMStringVector& groupIDList,
                      V2TIMValueCallback<V2TIMGroupInfoResultVector>* callback) override;
    void SearchGroups(const V2TIMGroupSearchParam& searchParam,
                      V2TIMValueCallback<V2TIMGroupInfoVector>* callback) override;
    void SearchCloudGroups(const V2TIMGroupSearchParam& searchParam,
                           V2TIMValueCallback<V2TIMGroupSearchResult>* callback) override;
    void SetGroupInfo(const V2TIMGroupInfo& info, V2TIMCallback* callback) override;
    /// Called when group topic is received from Tox (e.g. name broadcast); updates local cache and GetGroupsInfo.
    void UpdateGroupInfoFromTopic(const V2TIMString& groupID, const std::string& topic_value);
    /// Ensure group_info_ has an entry for groupID (e.g. when joining so GetGroupsInfo finds it before topic arrives).
    void EnsureGroupInfoExists(const V2TIMString& groupID);

    // Best-known display name for a group: cached when real, live NGC name
    // otherwise. See the definition for why the cache alone is not enough.
    std::string ResolveGroupName(const std::string& groupID);
    void InitGroupAttributes(const V2TIMString& groupID,
                            const V2TIMGroupAttributeMap& attributes,
                            V2TIMCallback* callback) override;
    void SetGroupAttributes(const V2TIMString& groupID,
                           const V2TIMGroupAttributeMap& attributes,
                           V2TIMCallback* callback) override;
    void DeleteGroupAttributes(const V2TIMString& groupID, const V2TIMStringVector& keys,
                               V2TIMCallback* callback) override;
    void GetGroupAttributes(const V2TIMString& groupID, const V2TIMStringVector& keys,
                            V2TIMValueCallback<V2TIMGroupAttributeMap>* callback) override;
    void GetGroupOnlineMemberCount(const V2TIMString& groupID,
                                  V2TIMValueCallback<uint32_t>* callback) override;
    void SetGroupCounters(const V2TIMString& groupID, const V2TIMStringToInt64Map& counters,
                          V2TIMValueCallback<V2TIMStringToInt64Map>* callback) override;
    void GetGroupCounters(const V2TIMString& groupID, const V2TIMStringVector& keys,
                          V2TIMValueCallback<V2TIMStringToInt64Map>* callback) override;
    void IncreaseGroupCounter(const V2TIMString& groupID, const V2TIMString& key, int64_t value,
                              V2TIMValueCallback<V2TIMStringToInt64Map>* callback) override;
    void DecreaseGroupCounter(const V2TIMString& groupID, const V2TIMString& key, int64_t value,
                              V2TIMValueCallback<V2TIMStringToInt64Map>* callback) override;

    ////////////////////////////// 群成员管理 //////////////////////////////
    void GetGroupMemberList(const V2TIMString& groupID, uint32_t filter,
                           uint64_t nextSeq,
                           V2TIMValueCallback<V2TIMGroupMemberInfoResult>* callback) override;
    void GetGroupMembersInfo(const V2TIMString& groupID, V2TIMStringVector memberList,
                             V2TIMValueCallback<V2TIMGroupMemberFullInfoVector>* callback) override;
    void SearchGroupMembers(const V2TIMGroupMemberSearchParam& param,
                            V2TIMValueCallback<V2TIMGroupSearchGroupMembersMap>* callback) override;
    void SearchCloudGroupMembers(const V2TIMGroupMemberSearchParam& param,
                                 V2TIMValueCallback<V2TIMGroupMemberSearchResult>* callback) override;
    void SetGroupMemberInfo(const V2TIMString& groupID, const V2TIMGroupMemberFullInfo& info,
                            V2TIMCallback* callback) override;
    void MuteGroupMember(const V2TIMString& groupID, const V2TIMString& userID,
                        uint32_t seconds, V2TIMCallback* callback) override;
    void MuteAllGroupMembers(const V2TIMString& groupID, bool isMute, V2TIMCallback* callback) override;
    void InviteUserToGroup(const V2TIMString& groupID, const V2TIMStringVector& userList,
                          V2TIMValueCallback<V2TIMGroupMemberOperationResultVector>* callback) override;
    void KickGroupMember(const V2TIMString& groupID, const V2TIMStringVector& memberList,
                         const V2TIMString& reason, uint32_t duration,
                         V2TIMValueCallback<V2TIMGroupMemberOperationResultVector>* callback) override;
    void KickGroupMember(const V2TIMString& groupID, const V2TIMStringVector& memberList,
                         const V2TIMString& reason,
                         V2TIMValueCallback<V2TIMGroupMemberOperationResultVector>* callback) override;
    void SetGroupMemberRole(const V2TIMString& groupID, const V2TIMString& userID, uint32_t role,
                            V2TIMCallback* callback) override;
    void MarkGroupMemberList(const V2TIMString& groupID, const V2TIMStringVector& memberList,
                             uint32_t markType, bool enableMark, V2TIMCallback* callback) override;
    void TransferGroupOwner(const V2TIMString& groupID, const V2TIMString& userID,
                           V2TIMCallback* callback) override;

    ////////////////////////////// 加群申请 //////////////////////////////
    void GetGroupApplicationList(V2TIMValueCallback<V2TIMGroupApplicationResult>* callback) override;
    void AcceptGroupApplication(const V2TIMGroupApplication& application, const V2TIMString& reason,
                                V2TIMCallback* callback) override;
    void RefuseGroupApplication(const V2TIMGroupApplication& application, const V2TIMString& reason,
                                V2TIMCallback* callback) override;
    void SetGroupApplicationRead(V2TIMCallback* callback) override;

    ////////////////////////////// 社群-话题 //////////////////////////////
    void GetJoinedCommunityList(V2TIMValueCallback<V2TIMGroupInfoVector>* callback) override;
    void CreateTopicInCommunity(const V2TIMString& groupID, const V2TIMTopicInfo& topicInfo,
                               V2TIMValueCallback<V2TIMString>* callback) override;
    void DeleteTopicFromCommunity(const V2TIMString& groupID, const V2TIMStringVector& topicIDList,
                                  V2TIMValueCallback<V2TIMTopicOperationResultVector>* callback) override;
    void SetTopicInfo(const V2TIMTopicInfo& topicInfo, V2TIMCallback* callback) override;
    void GetTopicInfoList(const V2TIMString& groupID, const V2TIMStringVector& topicIDList,
                         V2TIMValueCallback<V2TIMTopicInfoResultVector>* callback) override;

    // Internal methods for V2TIMManagerImpl to call
    void QuitGroup(const V2TIMString& groupID, V2TIMCallback* callback);
    void DismissGroup(const V2TIMString& groupID, V2TIMCallback* callback);
    
    // Helper method to get all group IDs (for CreateGroup to avoid ID conflicts)
    std::vector<std::string> GetAllGroupIDsSync();

private:
    std::mutex group_mutex_, member_mutex_, mute_mutex_;
    std::unordered_map<std::string, Tox_Group_Number> groups_;          // groupID -> group_number
    std::unordered_map<std::string, V2TIMGroupInfo> group_info_; // 本地存储群资料
    std::unordered_map<std::string, V2TIMGroupMemberInfoVector> group_members_; // 群成员列表
    std::unordered_map<std::string, std::unordered_set<std::string>> muted_members_; // 禁言列表
    // nameCard overrides for other users (Tox only allows setting self name; we store others locally)
    std::unordered_map<std::string, std::unordered_map<std::string, std::string>> member_name_card_overrides_;
    V2TIMManagerImpl* manager_impl_; // Reference to V2TIMManagerImpl to access group mappings
    // Tox工具函数
    uint32_t GetFriendNumber(const std::string& userID);
    // Helper functions for role mapping
    Tox_Group_Role v2timRoleToToxRole(uint32_t v2tim_role);
    uint32_t toxRoleToV2timRole(Tox_Group_Role tox_role);
    // Helper function to convert chat_id to hex string
    std::string chatIdToHexString(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]);
    // Helper function to convert hex string to chat_id
    bool hexStringToChatId(const std::string& hex_str, uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]);
};

#endif // __V2TIM_GROUP_MANAGER_IMPL_H__
