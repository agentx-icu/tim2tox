#include <set>
#include "V2TIMGroupManagerImpl.h"
#include "ToxManager.h"
#include "V2TIMLog.h"
#include "TIMResultDefine.h"
#include "ToxUtil.h"
#include "V2TIMManagerImpl.h"
#include "toxcore/tox.h"
#include <sstream>
#include <mutex>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <sstream>
#include <algorithm>
#include <cctype>
#include <thread>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>

// Forward declaration for instance id (defined in tim2tox_ffi.cpp)
extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);

// Forward declaration for tim2tox_ffi functions
// Forward declaration for FFI functions
// NOTE: All tim2tox_ffi_* functions are defined in extern "C" blocks in tim2tox_ffi.cpp
// They MUST be declared here with extern "C" to avoid C++ name mangling issues
// DO NOT redeclare these functions inside other functions - use the declarations here
extern "C" {
int tim2tox_ffi_get_known_groups(int64_t instance_id, char* buffer, int buffer_len);
int tim2tox_ffi_get_group_chat_id_from_storage(int64_t instance_id, const char* group_id, char* out_chat_id, int out_len);
int tim2tox_ffi_set_group_chat_id(int64_t instance_id, const char* group_id, const char* chat_id);
int tim2tox_ffi_set_group_type(int64_t instance_id, const char* group_id, const char* group_type);
int tim2tox_ffi_get_group_type_from_storage(int64_t instance_id, const char* group_id, char* out_group_type, int out_len);
// Forward declaration for Dart notification function (stamped with the
// emitting session; see the DartNotifyGroup* note in V2TIMManagerImpl.cpp)
void DartNotifyGroupQuit(const char* group_id, int64_t instance_id, int64_t session_epoch);
}

namespace {
// V2TIMErrorCode.h's ERR_SVR_GROUP_PERMISSION_DENY: the caller's role in the
// group does not allow the action (toxcore's *_PERMISSIONS errors). This file
// builds against TIMResultDefine.h, whose macros collide with that enum, so it
// cannot be included here. Kept distinct from ERR_SDK_INTERFACE_NOT_SUPPORT
// (7013 = this KIND of group cannot do it at all, e.g. a legacy conference):
// the UI tells the user different things for the two.
constexpr int kErrSvrGroupPermissionDeny = 10007;
}  // namespace

// Thread-local flag to prevent recursion when GetJoinedGroupList is called from tim2tox_ffi_get_known_groups
// This is defined here so it can be accessed from tim2tox_ffi.cpp
thread_local bool V2TIMGroupManagerImpl_in_get_known_groups_call = false;

// Constructor (R-06: owned by V2TIMManagerImpl, no singleton)
V2TIMGroupManagerImpl::V2TIMGroupManagerImpl(V2TIMManagerImpl* owner) : manager_impl_(owner) {
    V2TIM_LOG(kInfo, "[V2TIMGroupManagerImpl] Constructor ENTRY this={} owner={}", static_cast<void*>(this), static_cast<void*>(owner));

    // Store reference to manager_impl for accessing group mappings
    // Note: group_mutex_, member_mutex_, mute_mutex_ are automatically initialized by default constructor

    V2TIM_LOG(kInfo, "[V2TIMGroupManagerImpl] Constructor Mutexes initialized");
    V2TIM_LOG(kInfo, "[V2TIMGroupManagerImpl] Constructor COMPLETE this={}", static_cast<void*>(this));
}

// Helper function to get ToxManager from manager_impl_ or default instance
static ToxManager* GetToxManagerFromImpl(V2TIMManagerImpl* manager_impl) {
    if (manager_impl) {
        return manager_impl->GetToxManager();
    }
    return ToxManager::getDefaultInstance();
}

// The live NGC group name, or "" when it cannot be read.
//
// WHY THIS EXISTS: `group_info_` only learns a real name on the node that
// CREATED the group (CreateGroup caches it) or after something explicitly
// fetches group info. A node that JOINED holds whatever EnsureGroupInfoExists
// seeded — `groupName = groupID` — so searching by the name every member can
// plainly see in the UI matched nothing, and the group only surfaced through
// the conversation fallback section (the product debt recorded in toxee
// PR #80). toxcore has had the real name the entire time; read it.
// Takes the group NUMBER rather than the id: `group_id_to_group_number_` is
// private to V2TIMManagerImpl and only its friends (the member functions of
// this class) may look it up, so the caller resolves it.
static std::string GetLiveGroupName(V2TIMManagerImpl* manager_impl,
                                    Tox_Group_Number group_number) {
    ToxManager* tox_manager = GetToxManagerFromImpl(manager_impl);
    if (!tox_manager) return std::string();
    // Call toxcore directly instead of ToxManager::getGroupName: that wrapper
    // takes ToxManager's mutex, which this call path can already hold, and the
    // search then deadlocks (observed: searchGroups never returned). Every
    // other tox_* use in this file goes through the raw handle the same way.
    Tox* tox = tox_manager->getTox();
    if (!tox) return std::string();
    if (IsConferenceMapKey(group_number)) {
        // A legacy conference's shared name is its title.
        const uint32_t conference_number = ConferenceNumberFromKey(group_number);
        Tox_Err_Conference_Title err_title = TOX_ERR_CONFERENCE_TITLE_OK;
        const size_t title_size =
            tox_conference_get_title_size(tox, conference_number, &err_title);
        if (err_title != TOX_ERR_CONFERENCE_TITLE_OK || title_size == 0 ||
            title_size > TOX_MAX_NAME_LENGTH) {
            return std::string();
        }
        std::vector<uint8_t> title_buf(title_size);
        if (!tox_conference_get_title(tox, conference_number, title_buf.data(),
                                      &err_title) ||
            err_title != TOX_ERR_CONFERENCE_TITLE_OK) {
            return std::string();
        }
        return std::string(reinterpret_cast<const char*>(title_buf.data()),
                           title_size);
    }
    Tox_Err_Group_State_Query err = TOX_ERR_GROUP_STATE_QUERY_OK;
    const size_t name_size = tox_group_get_name_size(tox, group_number, &err);
    if (err != TOX_ERR_GROUP_STATE_QUERY_OK || name_size == 0 ||
        name_size > TOX_GROUP_MAX_GROUP_NAME_LENGTH) {
        return std::string();
    }
    std::vector<uint8_t> name_buf(name_size);
    if (!tox_group_get_name(tox, group_number, name_buf.data(), &err) ||
        err != TOX_ERR_GROUP_STATE_QUERY_OK) {
        return std::string();
    }
    return std::string(reinterpret_cast<const char*>(name_buf.data()),
                       name_size);
}

////////////////////////////// 群组管理接口 //////////////////////////////
void V2TIMGroupManagerImpl::CreateGroup(const V2TIMGroupInfo& info,
                                      const V2TIMCreateGroupMemberInfoVector& memberList,
                                      V2TIMValueCallback<V2TIMString>* callback) {
    // Log which instance is creating group (for multi-instance debugging)
    // Note: GetCurrentInstanceId is defined in tim2tox_ffi.cpp as a C++ function
    extern int64_t GetCurrentInstanceId();
    int64_t current_instance_id = GetCurrentInstanceId();
    // [tim2tox-debug] Record instance ID and parameter validation for V2TIMGroupManagerImpl::CreateGroup
    V2TIM_LOG(kInfo, "[V2TIMGroupManagerImpl::CreateGroup] Creating instance_id={} groupID={} groupName={}",
             current_instance_id, info.groupID.CString() ? info.groupID.CString() : "null",
             info.groupName.CString() ? info.groupName.CString() : "null");
    V2TIM_LOG(kInfo, "CreateGroup: Starting for groupID={}, groupName={}",
             info.groupID.CString(), info.groupName.CString());

    if (!callback) {
        V2TIM_LOG(kError, "CreateGroup: callback is null");
        return;
    }

    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "CreateGroup: Tox not initialized");
        callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }
    
    // Determine final Group ID
    V2TIMString finalGroupID = info.groupID;
    if (finalGroupID.Empty()) {
        // Generate a unique ID if none provided
        std::vector<std::string> existingIDs = GetAllGroupIDsSync();
        std::unordered_set<std::string> idSet(existingIDs.begin(), existingIDs.end());
        
        uint64_t counter = 0;
        char generated_id[64];
        do {
            snprintf(generated_id, sizeof(generated_id), "tox_group_%llu", (unsigned long long)counter++);
        } while (idSet.find(generated_id) != idSet.end());
        
        finalGroupID = V2TIMString(generated_id);
        V2TIM_LOG(kInfo, "CreateGroup: Generated groupID={}", finalGroupID.CString());
    }
    
    // Get group name
    std::string group_name = info.groupName.CString();
    if (group_name.empty()) {
        group_name = finalGroupID.CString();
    }
    
    // Get self name for creating group
    std::string self_name = GetToxManagerFromImpl(manager_impl_)->getName();
    if (self_name.empty()) {
        self_name = "User";
    }
    
    // Determine group type: "group" (new API) or "conference" (old API)
    std::string group_type = info.groupType.CString();
    bool is_conference = (group_type == "conference");
    
    if (is_conference) {
        // Create conference using tox_conference_new (old API)
        V2TIM_LOG(kInfo, "CreateGroup: Creating conference (old API)");
        Tox_Err_Conference_New err_new;
        Tox_Conference_Number conference_number = tox_conference_new(tox, &err_new);
        
        if (err_new != TOX_ERR_CONFERENCE_NEW_OK || conference_number == UINT32_MAX) {
            V2TIM_LOG(kError, "CreateGroup: Failed to create conference, error={}", err_new);
            callback->OnError(ERR_INVALID_PARAMETERS, "Failed to create Tox conference");
            return;
        }
        
        V2TIM_LOG(kInfo, "CreateGroup: Successfully created conference, conference_number={}", conference_number);
        
        // Store conference mappings (treating conference_number as group_number for compatibility)
        if (manager_impl_) {
            std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
            manager_impl_->group_id_to_group_number_[finalGroupID] = ConferenceMapKey(conference_number);
            manager_impl_->group_number_to_group_id_[ConferenceMapKey(conference_number)] = finalGroupID;
            V2TIM_LOG(kInfo, "CreateGroup: Stored conference mapping: groupID={} <-> conference_number={}",
                     finalGroupID.CString(), conference_number);
        }

        if (manager_impl_ &&
            !manager_impl_->StoreConferenceIdentity(finalGroupID,
                                                     conference_number)) {
            V2TIM_LOG(kWarning,
                      "CreateGroup: Failed to persist stable conference identity");
        }
    } else {
        // Create group using tox_group_new (new API)
        V2TIM_LOG(kInfo, "CreateGroup: Creating group (new API)");
        
        // "Private" (kTIMGroup_Private) -> PRIVATE (friend-based peer discovery)
        // "conference" -> PRIVATE; "Public" or "Meeting" -> PUBLIC; default -> PUBLIC
        Tox_Group_Privacy_State privacy_state = TOX_GROUP_PRIVACY_STATE_PUBLIC;
        if (group_type == "Private" || group_type == "conference") {
            privacy_state = TOX_GROUP_PRIVACY_STATE_PRIVATE;
            V2TIM_LOG(kInfo, "[V2TIMGroupManagerImpl::CreateGroup] Setting privacy_state to PRIVATE (group_type={})", group_type);
        } else if (group_type == "Public" || group_type == "Meeting") {
            privacy_state = TOX_GROUP_PRIVACY_STATE_PUBLIC;
            V2TIM_LOG(kInfo, "[V2TIMGroupManagerImpl::CreateGroup] Setting privacy_state to PUBLIC (group_type={})", group_type);
        } else {
            V2TIM_LOG(kInfo, "[V2TIMGroupManagerImpl::CreateGroup] Using default privacy_state PUBLIC (group_type={})", group_type);
        }
        
        Tox_Err_Group_New err_new;
        Tox_Group_Number group_number = GetToxManagerFromImpl(manager_impl_)->createGroup(
            privacy_state,
            reinterpret_cast<const uint8_t*>(group_name.c_str()), group_name.length(),
            reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
            &err_new
        );
        
        if (err_new != TOX_ERR_GROUP_NEW_OK || group_number == UINT32_MAX) {
            // Map Tox error to specific error messages for better debugging
            const char* tox_error_name = "UNKNOWN";
            std::string detailed_msg = "Failed to create Tox group";
            
            switch (err_new) {
                case TOX_ERR_GROUP_NEW_OK:
                    tox_error_name = "OK";
                    break;
                case TOX_ERR_GROUP_NEW_TOO_LONG:
                    tox_error_name = "TOO_LONG";
                    detailed_msg = "Group name or self name exceeds maximum length";
                    break;
                case TOX_ERR_GROUP_NEW_EMPTY:
                    tox_error_name = "EMPTY";
                    detailed_msg = "Group name or self name is empty";
                    break;
                case TOX_ERR_GROUP_NEW_INIT:
                    tox_error_name = "INIT";
                    detailed_msg = "Group instance failed to initialize (Tox may not be ready)";
                    break;
                case TOX_ERR_GROUP_NEW_STATE:
                    tox_error_name = "STATE";
                    detailed_msg = "Group state failed to initialize (cryptographic signing error)";
                    break;
                case TOX_ERR_GROUP_NEW_ANNOUNCE:
                    tox_error_name = "ANNOUNCE";
                    detailed_msg = "Group failed to announce to DHT (network error, may need connection)";
                    break;
                default:
                    tox_error_name = "UNKNOWN";
                    detailed_msg = "Unknown error from tox_group_new";
                    break;
            }
            
            V2TIM_LOG(kError, "CreateGroup: Failed to create group, error={} ({}), group_number={}, group_name_len={}, self_name_len={}",
                      err_new, tox_error_name, group_number, group_name.length(), self_name.length());
            V2TIM_LOG(kError, "CreateGroup: Detailed message: {}", detailed_msg);
            
            // Check connection status for network-related errors
            if (err_new == TOX_ERR_GROUP_NEW_ANNOUNCE || err_new == TOX_ERR_GROUP_NEW_INIT) {
                Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
                if (tox) {
                    TOX_CONNECTION connection = tox_self_get_connection_status(tox);
                    V2TIM_LOG(kError, "CreateGroup: Tox connection status: {} (0=NONE, 1=UDP, 2=TCP)", static_cast<int>(connection));
                    if (connection == TOX_CONNECTION_NONE) {
                        detailed_msg += " (Tox not connected to network)";
                    }
                }
            }
            
            callback->OnError(ERR_INVALID_PARAMETERS, detailed_msg.c_str());
            return;
        }
        
        V2TIM_LOG(kInfo, "CreateGroup: Successfully created group, group_number={}", group_number);
        
        // Get chat_id for persistent storage (only for group type)
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat_id;
        if (!GetToxManagerFromImpl(manager_impl_)->getGroupChatId(group_number, chat_id, &err_chat_id) ||
            err_chat_id != TOX_ERR_GROUP_STATE_QUERY_OK) {
            V2TIM_LOG(kError, "CreateGroup: Failed to get chat_id");
            // Still continue, but chat_id won't be stored
        } else {
            // Store chat_id mapping
            std::string chat_id_hex = chatIdToHexString(chat_id);
            if (manager_impl_) {
                std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
                manager_impl_->group_id_to_chat_id_[finalGroupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                manager_impl_->chat_id_to_group_id_[chat_id_hex] = finalGroupID;
                V2TIM_LOG(kInfo, "CreateGroup: Stored chat_id mapping for groupID={}", finalGroupID.CString());
            }
            
            // CRITICAL: Also store to persistent storage via FFI
            // This ensures chat_id is available after app restart
            // Function is already declared with extern "C" at file scope
            manager_impl_->SetGroupChatIdInStorage(finalGroupID.CString(), chat_id_hex);
            V2TIM_LOG(kInfo, "CreateGroup: Stored chat_id to persistent storage for groupID={}, chat_id={}…",
                     finalGroupID.CString(), chat_id_hex.substr(0, 8));
        }
        
        // Store group mappings
        if (manager_impl_) {
            std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
            manager_impl_->group_id_to_group_number_[finalGroupID] = group_number;
            manager_impl_->group_number_to_group_id_[group_number] = finalGroupID;
            V2TIM_LOG(kInfo, "CreateGroup: Stored group mapping: groupID={} <-> group_number={}",
                     finalGroupID.CString(), group_number);
        }
    }
    
    // Store groupType to persistent storage
    // Function is already declared with extern "C" at file scope
    manager_impl_->SetGroupTypeInStorage(finalGroupID.CString(), group_type);
    V2TIM_LOG(kInfo, "CreateGroup: Stored groupType to persistent storage for groupID={}, groupType={}",
             finalGroupID.CString(), group_type);
    
    // Store group info locally
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        V2TIMGroupInfo groupInfo = info;
        groupInfo.groupID = finalGroupID;
        // Ensure groupType is set correctly
        if (groupInfo.groupType.Empty()) {
            groupInfo.groupType = V2TIMString(is_conference ? "conference" : "group");
        }
        // Store creator as owner - needed for conference groups which lack role APIs
        {
            Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
            if (tox) {
                uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                tox_self_get_public_key(tox, self_pubkey);
                std::string self_hex = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                groupInfo.owner = V2TIMString(self_hex.c_str());
                groupInfo.role = V2TIM_GROUP_MEMBER_ROLE_SUPER; // Creator is owner
            }
        }
        group_info_[finalGroupID.CString()] = groupInfo;
        // Get the number (group_number or conference_number) from mapping
        uint32_t number = UINT32_MAX;
        if (manager_impl_) {
            std::lock_guard<std::mutex> lock2(manager_impl_->mutex_);
            auto it = manager_impl_->group_id_to_group_number_.find(finalGroupID);
            if (it != manager_impl_->group_id_to_group_number_.end()) {
                number = it->second;
            }
        }
        groups_[finalGroupID.CString()] = number;
    }
    
    // Invite initial members if provided
    if (memberList.Size() > 0) {
        V2TIM_LOG(kInfo, "CreateGroup: Inviting {} initial members", memberList.Size());
        // Note: We'll handle invitations after group is created
        // For now, just log - actual invitation will be handled separately
    }
    
    // Manually trigger HandleGroupSelfJoin to notify listeners about group creation
    // This is necessary because tox_group_new/createGroup may not immediately trigger
    // the on_group_self_join callback, but we need to notify listeners via OnGroupCreated
    if (manager_impl_) {
        uint32_t group_number = UINT32_MAX;
        {
            std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
            auto it = manager_impl_->group_id_to_group_number_.find(finalGroupID);
            if (it != manager_impl_->group_id_to_group_number_.end()) {
                group_number = it->second;
            }
        }
        
        if (group_number != UINT32_MAX) {
            V2TIM_LOG(kInfo, "[V2TIMGroupManagerImpl::CreateGroup] Manually calling HandleGroupSelfJoin(group_number={}) to trigger OnGroupCreated", group_number);
            manager_impl_->HandleGroupSelfJoin(group_number);
            V2TIM_LOG(kInfo, "[tim2tox-debug] V2TIMGroupManagerImpl::CreateGroup: HandleGroupSelfJoin completed");
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: Could not find group_number for groupID={}, skipping HandleGroupSelfJoin", finalGroupID.CString());
        }
    }
    
    // [tim2tox-debug] Record callback trigger for V2TIMGroupManagerImpl::CreateGroup
    V2TIM_LOG(kInfo, "[tim2tox-debug] V2TIMGroupManagerImpl::CreateGroup: Triggering callback->OnSuccess with groupID={}", 
             finalGroupID.CString());
    callback->OnSuccess(finalGroupID);
    V2TIM_LOG(kInfo, "[tim2tox-debug] V2TIMGroupManagerImpl::CreateGroup: Callback triggered successfully");
}

void V2TIMGroupManagerImpl::GetGroupsInfo(const V2TIMStringVector& groupIDList,
                      V2TIMValueCallback<V2TIMGroupInfoResultVector>* callback) {
    if (!callback) {
        V2TIM_LOG(kError, "[V2TIMGroupManagerImpl] GetGroupsInfo: callback is null");
        return;
    }

    if (groupIDList.Size() == 0) {
        V2TIM_LOG(kWarning, "[V2TIMGroupManagerImpl] GetGroupsInfo: groupIDList is empty");
        callback->OnError(ERR_INVALID_PARAMETERS, "Group ID list is empty");
        return;
    }
    
    V2TIMGroupInfoResultVector resultVector;
    
    // Lock to access group_info_ map
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        
        // Iterate through requested group IDs
        for (size_t i = 0; i < groupIDList.Size(); i++) {
            V2TIMGroupInfoResult result;
            
            // CRITICAL: Access groupIDList[i] and call CString() with safety checks
            const V2TIMString& groupIDStr = groupIDList[i];
            std::string groupID = groupIDStr.CString();
            
            // Try to find group info in group_info_ map
            auto it = group_info_.find(groupID);
            bool found_in_map = (it != group_info_.end());
            
            if (found_in_map) {
                // Group found, set success result
                result.resultCode = 0;
                result.resultMsg = "";
                result.info = it->second; // Copy group info

                // Reconcile the in-memory cached groupType against persistent storage.
                // The cached entry may have been initialised by EnsureGroupInfoExists()
                // with the generic placeholder "group" before the original label
                // (e.g. "Meeting", "Public", "Work") was propagated to this instance's
                // type storage via the cross-instance DartStringCallback handler.
                // Without this reconciliation, getGroupsInfo would return "group" and
                // the JSON serializer's int-mapping would fall back to 0 (Public),
                // losing the caller-supplied label end-to-end.
                if (manager_impl_) {
                    std::string cached_type = result.info.groupType.Empty()
                                                  ? std::string()
                                                  : std::string(result.info.groupType.CString());
                    // Treat "group" as a generic placeholder; any specific label in
                    // storage should win over it. "conference" is a real, specific
                    // type (old Tox conference API) and must not be overwritten.
                    bool is_placeholder = cached_type.empty() || cached_type == "group";
                    if (is_placeholder) {
                        char stored_type[64] = {};
                        if (manager_impl_->GetGroupTypeFromStorage(groupID, stored_type, sizeof(stored_type))) {
                            std::string st(stored_type);
                            if (!st.empty() && st != "group") {
                                result.info.groupType = V2TIMString(stored_type);
                                V2TIM_LOG(kInfo,
                                          "GetGroupsInfo: overriding cached groupType '{}' with stored '{}' for group {}",
                                          cached_type, st, groupID);
                            }
                        }
                    }
                }

                // Try to get group topic from Tox if notification is empty and group type is "group"
                if (result.info.notification.Empty()) {
                    // Get group_number to query topic
                    Tox_Group_Number group_number = UINT32_MAX;
                    if (manager_impl_) {
                        std::lock_guard<std::mutex> lock2(manager_impl_->mutex_);
                        auto num_it = manager_impl_->group_id_to_group_number_.find(V2TIMString(groupID.c_str()));
                        if (num_it != manager_impl_->group_id_to_group_number_.end()) {
                            group_number = num_it->second;
                        }
                    }
                    
                    // Only NGC groups have a topic. The KIND comes from the map
                    // key, not the type label: a label can be a caller-supplied
                    // NGC name ("Work", "Public"...) that skipped the topic, or a
                    // stale "group" that sent a tagged conference key to NGC.
                    if (group_number != UINT32_MAX && !IsConferenceMapKey(group_number)) {
                        // Get topic from Tox (NGC only)
                        uint8_t topic[TOX_GROUP_MAX_TOPIC_LENGTH];
                        Tox_Err_Group_State_Query err_topic;
                        if (GetToxManagerFromImpl(manager_impl_)->getGroupTopic(group_number, topic, sizeof(topic), &err_topic) &&
                            err_topic == TOX_ERR_GROUP_STATE_QUERY_OK) {
                            // Find null terminator
                            size_t topic_len = 0;
                            for (size_t i = 0; i < sizeof(topic) && topic[i] != 0; ++i) {
                                topic_len++;
                            }
                            if (topic_len > 0) {
                                result.info.notification = std::string(reinterpret_cast<const char*>(topic), topic_len);
                                V2TIM_LOG(kInfo, "GetGroupsInfo: Retrieved topic for group {} (length={})", groupID, topic_len);
                            }
                        }
                    }
                }
            } else {
                // R-07: Check if groupID is in Core known groups list
                bool found_in_known = false;
                if (manager_impl_) {
                    std::vector<std::string> known = manager_impl_->GetKnownGroupIDs();
                    for (const auto& g : known) {
                        if (g == groupID) { found_in_known = true; break; }
                    }
                }
                
                if (found_in_known) {
                    // Group is in known groups list: rebuild the mapping from the
                    // stored identity, resolved by the stored KIND (a conference
                    // identity only via tox_conference_by_id, stored as
                    // ConferenceMapKey; never looked up as an NGC chat id, and an
                    // unmapped NGC group is never bound to a conference id).
                    Tox_Group_Number matched_group_number = UINT32_MAX;
                    if (manager_impl_) {
                        matched_group_number = manager_impl_->RecoverGroupMapping(
                            groupID, /*allow_unmapped_ngc_bind=*/true);
                    }

                    // Group is in known groups list, create basic group info
                    result.resultCode = 0;
                    result.resultMsg = "";
                    result.info = V2TIMGroupInfo();
                    result.info.groupID = groupID.c_str();
                    result.info.groupName = groupID.c_str(); // Use groupID as default name

                    // Group type from storage; the buffer is only read on success.
                    char stored_type[16] = {};
                    if (manager_impl_ &&
                        manager_impl_->GetGroupTypeFromStorage(groupID, stored_type, sizeof(stored_type))) {
                        result.info.groupType = V2TIMString(stored_type);
                    } else {
                        result.info.groupType = V2TIMString("group"); // Default to group type
                    }

                    // Topic: NGC only, decided by the map key (not the label).
                    if (matched_group_number != UINT32_MAX &&
                        !IsConferenceMapKey(matched_group_number)) {
                        const Tox_Group_Number group_number = matched_group_number;
                        {
                            // Get topic from Tox
                            uint8_t topic[TOX_GROUP_MAX_TOPIC_LENGTH];
                            Tox_Err_Group_State_Query err_topic;
                            if (GetToxManagerFromImpl(manager_impl_)->getGroupTopic(group_number, topic, sizeof(topic), &err_topic) &&
                                err_topic == TOX_ERR_GROUP_STATE_QUERY_OK) {
                                // Find null terminator
                                size_t topic_len = 0;
                                for (size_t i = 0; i < sizeof(topic) && topic[i] != 0; ++i) {
                                    topic_len++;
                                }
                                if (topic_len > 0) {
                                    result.info.notification = std::string(reinterpret_cast<const char*>(topic), topic_len);
                                    V2TIM_LOG(kInfo, "GetGroupsInfo: Retrieved topic for group {} (length={})", groupID, topic_len);
                                }
                            }
                        }
                    }
                } else {
                    // Group not found, set error result
                    result.resultCode = ERR_SDK_GROUP_INVALID_ID;
                    result.resultMsg = "Group not found";
                    result.info = V2TIMGroupInfo(); // Empty group info
                    result.info.groupID = groupID.c_str();
                    
                    V2TIM_LOG(kWarning, "GetGroupsInfo: group {} not found", groupID);
                }
            }
            
            // Add result to vector
            resultVector.PushBack(result);
        }
    }
    
    if (!callback) {
        V2TIM_LOG(kError, "[V2TIMGroupManagerImpl] GetGroupsInfo: callback is null before OnSuccess");
        return;
    }
    callback->OnSuccess(resultVector);
}


void V2TIMGroupManagerImpl::QuitGroup(const V2TIMString& groupID, V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: ENTRY - groupID={}", groupID.CString());
    
    // Get group_number from groupID
    Tox_Group_Number group_number = UINT32_MAX;
    if (manager_impl_) {
        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
        auto it = manager_impl_->group_id_to_group_number_.find(groupID);
        if (it != manager_impl_->group_id_to_group_number_.end()) {
            group_number = it->second;
            V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Found group_number={} from manager_impl_ mapping", group_number);
        }
    }
    
    // Fallback to local groups_ map
    if (group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = groups_.find(groupID.CString());
        if (it != groups_.end()) {
            group_number = it->second;
            V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Found group_number={} from local groups_ map", group_number);
        }
    }

    std::string group_type;
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = group_info_.find(groupID.CString());
        if (it != group_info_.end() && !it->second.groupType.Empty()) {
            group_type = it->second.groupType.CString();
        }
    }
    if (manager_impl_) {
        char stored_type[16] = {};
        if (manager_impl_->GetGroupTypeFromStorage(
                groupID.CString(), stored_type, sizeof(stored_type))) {
            group_type = stored_type;
        }
    }
    if (group_type.empty()) {
        group_type = "group";
    }
    
    // Recovery mechanism: try to rebuild mapping if not found (e.g., after client restart)
    if (group_number == UINT32_MAX && manager_impl_) {
        std::string groupID_str = groupID.CString();
        V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Group {} not found in mappings, attempting recovery via stored chat_id", groupID_str);
        
        // Try to get stored chat_id for this groupID
        // Function is already declared with extern "C" at file scope
        char stored_chat_id[65];
        bool has_stored_chat_id = manager_impl_->GetGroupChatIdFromStorage(groupID_str, stored_chat_id, sizeof(stored_chat_id));
        
        if (has_stored_chat_id) {
            V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Found stored native identity");

            Tox_Group_Number matched_group_number = UINT32_MAX;
            const bool is_conference = group_type == "conference" ||
                                       group_type == "av_conference";
            if (is_conference) {
                const std::size_t identity_length = std::strlen(stored_chat_id);
                uint8_t conference_id[TOX_CONFERENCE_ID_SIZE];
                if (identity_length == TOX_CONFERENCE_ID_SIZE * 2 &&
                    ToxUtil::tox_hex_to_bytes(
                        stored_chat_id, identity_length, conference_id,
                        TOX_CONFERENCE_ID_SIZE)) {
                    Tox_Err_Conference_By_Id lookup_error;
                    ToxManager* tox_manager =
                        GetToxManagerFromImpl(manager_impl_);
                    const Tox_Conference_Number conference_number =
                        tox_manager->getConferenceById(conference_id,
                                                       &lookup_error);
                    if (lookup_error == TOX_ERR_CONFERENCE_BY_ID_OK &&
                        conference_number != UINT32_MAX) {
                        Tox_Err_Conference_Get_Type type_error;
                        const Tox_Conference_Type native_type =
                            tox_manager->getConferenceType(conference_number,
                                                           &type_error);
                        const bool type_matches =
                            type_error == TOX_ERR_CONFERENCE_GET_TYPE_OK &&
                            ((group_type == "av_conference" &&
                              native_type == TOX_CONFERENCE_TYPE_AV) ||
                             (group_type == "conference" &&
                              native_type == TOX_CONFERENCE_TYPE_TEXT));
                        if (type_matches) {
                            matched_group_number = ConferenceMapKey(conference_number);
                        }
                    }
                }
            } else {
                uint8_t target_chat_id[TOX_GROUP_CHAT_ID_SIZE];
                if (hexStringToChatId(std::string(stored_chat_id),
                                      target_chat_id)) {
                    matched_group_number =
                        GetToxManagerFromImpl(manager_impl_)
                            ->getGroupByChatId(target_chat_id);
                }
            }

            if (matched_group_number != UINT32_MAX) {
                {
                    std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
                    manager_impl_->group_id_to_group_number_[groupID] =
                        matched_group_number;
                    manager_impl_->group_number_to_group_id_[
                        matched_group_number] = groupID;
                }
                group_number = matched_group_number;
                V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Rebuilt mapping: groupID={} <-> group_number={}", groupID_str, group_number);
            } else {
                V2TIM_LOG(kWarning, "V2TIMGroupManagerImpl::QuitGroup: Stored identity not found in Tox, group may not be restored yet");
            }
        } else {
            V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: No stored chat_id found for groupID={}, trying fallback matching", groupID_str);
        }
    }
    
    if (group_number == UINT32_MAX) {
        V2TIM_LOG(kError, "V2TIMGroupManagerImpl::QuitGroup: Group {} not found in mappings after recovery attempt", groupID.CString());
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Group number not found");
        }
        return;
    }

    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "V2TIMGroupManagerImpl::QuitGroup: Tox instance not available");
        if (callback) {
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        }
        return;
    }


    // The map key decides the kind (see ConferenceMapKey); the stored type
    // label only distinguishes text from AV. A stale label must never send a
    // leave to the other kind's object with the same number.
    if (IsConferenceMapKey(group_number)) {
        if (group_type != "av_conference") group_type = "conference";
    } else if (group_type == "conference" || group_type == "av_conference") {
        group_type = "group";
    }

    bool deleted = false;
    if (group_type == "av_conference") {
        Tox_Err_Conference_Delete error;
        deleted = tox_conference_delete(
            tox, ConferenceNumberFromKey(group_number), &error);
        if (!deleted) {
            V2TIM_LOG(kWarning, "V2TIMGroupManagerImpl::QuitGroup: Failed to delete AV conference from Tox, error: {}", error);
        }
    } else if (group_type == "conference") {
        V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Calling tox_conference_delete for conference_number={}", group_number);
        Tox_Err_Conference_Delete error;
        deleted = tox_conference_delete(tox, ConferenceNumberFromKey(group_number), &error);
        if (!deleted) {
            V2TIM_LOG(kWarning, "V2TIMGroupManagerImpl::QuitGroup: Failed to delete conference from Tox, error: {}", error);
        } else {
            V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Successfully called tox_conference_delete for group {} (conference_number {})", groupID.CString(), group_number);
        }
    } else {
        V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Calling ToxManager::deleteGroup for group_number={}", group_number);
        Tox_Err_Group_Leave error;
        deleted = GetToxManagerFromImpl(manager_impl_)->deleteGroup(group_number, &error);
        if (!deleted) {
            V2TIM_LOG(kWarning, "V2TIMGroupManagerImpl::QuitGroup: Failed to leave group from Tox, error: {}", error);
        } else {
            V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Successfully called tox_group_leave for group {} (group_number {})", groupID.CString(), group_number);
        }
    }

    if (!deleted) {
        V2TIM_LOG(kError, "V2TIMGroupManagerImpl::QuitGroup: Native delete failed for group {}", groupID.CString());
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Failed to delete group from Tox");
        }
        return;
    }

    // Remove from local group members map if exists
    {
        std::lock_guard<std::mutex> lock(member_mutex_);
        auto it = group_members_.find(groupID.CString());
        if (it != group_members_.end()) {
            group_members_.erase(it);
            V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Removed group {} from group_members_ map", groupID.CString());
        } else {
            V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Group {} not found in group_members_ map", groupID.CString());
        }
        member_name_card_overrides_.erase(groupID.CString());
    }
    
    // Also remove from groups_ and group_info_ maps
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        size_t groups_erased = groups_.erase(groupID.CString());
        size_t group_info_erased = group_info_.erase(groupID.CString());
        V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Removed from groups_ map (erased={}) and group_info_ map (erased={})",
                  groups_erased, group_info_erased);
    }
    
    // Clear conversation cache for this group
    // This ensures the conversation is removed from the conversation list
    // Always delete conversation cache, even if group_number is not found
    // This handles cases where the group mapping is missing but we still need to clean up
    std::string conv_id = "group_" + std::string(groupID.CString());
    V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Deleting conversation {} from cache", conv_id);
    // Use manager_impl_ instead of V2TIMManager::GetInstance() for multi-instance support
    if (manager_impl_) {
        manager_impl_->GetConversationManager()->DeleteConversation(
            V2TIMString(conv_id.c_str()),
            nullptr  // No callback needed for conversation deletion
        );
    }
    V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Deleted conversation {} from cache", conv_id);
    
    // Notify Dart layer to clean up group state (knownGroups, quitGroups, etc.)
    // This ensures Dart layer state is synchronized even when quitGroup is called directly from C++ layer
    // Note: DartNotifyGroupQuit is already declared with extern "C" at file scope (line 27)
    // Stamped with the owning session so the process-global Dart handler can
    // ignore it on any other instance / after an account switch. Without an
    // owner there is no session to attribute it to (-1 / 0 never match one);
    // GetInstanceIdFromManager(nullptr) would claim the default instance.
    DartNotifyGroupQuit(groupID.CString(),
                        manager_impl_ ? GetInstanceIdFromManager(manager_impl_) : -1,
                        manager_impl_ ? manager_impl_->GetSessionEpoch() : 0);
    V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Notified Dart layer to clean up group state");
    
    // Notify listeners through V2TIMManagerImpl
    // Note: We can't directly access private listeners, so we'll rely on V2TIMManagerImpl::QuitGroup
    // to handle the notification. For now, just return success.
    V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: Calling callback->OnSuccess()");
    if (callback) callback->OnSuccess();
    V2TIM_LOG(kInfo, "V2TIMGroupManagerImpl::QuitGroup: EXIT - Completed for groupID={}", groupID.CString());
}

void V2TIMGroupManagerImpl::DismissGroup(const V2TIMString& groupID, V2TIMCallback* callback) {
    // Tox has no "dismiss": a group lives on while any member remains, so the
    // founder dismissing it is the founder leaving it. Share QuitGroup's whole
    // path instead of keeping a weaker copy: this one had no stored-identity
    // recovery (so it failed right after a restart, where quit succeeded), no
    // conversation removal and no Dart cleanup notification. V2TIMManagerImpl
    // ::DismissGroup still announces OnGroupDismissed to listeners.
    V2TIM_LOG(kInfo, "DismissGroup: ENTRY groupID={} -> QuitGroup path", groupID.CString());
    QuitGroup(groupID, callback);
}

void V2TIMGroupManagerImpl::GetJoinedGroupList(V2TIMValueCallback<V2TIMGroupInfoVector>* callback) {
    V2TIM_LOG(kInfo, "GetJoinedGroupList: getting joined group list");
    
    if (!callback) {
        V2TIM_LOG(kWarning, "GetJoinedGroupList: callback is null");
        return;
    }
    
    V2TIMGroupInfoVector resultList;
    std::vector<std::string> groupIDs;
    
    // Get all known groups from manager_impl_'s mapping first (most reliable source)
    // This ensures we use the correct group IDs (from next_group_id_counter_) instead of
    // directly generating from conference_number (which may be reused)
    if (manager_impl_) {
        // Use helper method to get all group IDs from V2TIMManagerImpl's mapping
        std::vector<V2TIMString> managerGroupIDs = manager_impl_->GetAllGroupIDs();
        for (const auto& gid : managerGroupIDs) {
            groupIDs.push_back(gid.CString());
        }
        V2TIM_LOG(kInfo, "GetJoinedGroupList: got {} groups from manager_impl_ mapping", groupIDs.size());
    }
    
    // Fall back to groups_ map if manager_impl_ mapping is empty
    if (groupIDs.empty()) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        for (const auto& groupPair : groups_) {
            groupIDs.push_back(groupPair.first);
        }
        V2TIM_LOG(kInfo, "GetJoinedGroupList: got {} groups from groups_ map", groupIDs.size());
    }
    
    // NOTE: We do NOT call tim2tox_ffi_get_known_groups here to avoid infinite recursion:
    // - tim2tox_ffi_get_known_groups calls GetJoinedGroupList
    // - GetJoinedGroupList would call tim2tox_ffi_get_known_groups again
    // Instead, when GetJoinedGroupList is called from Dart layer (via DartGetJoinedGroupList),
    // it will go through tim2tox_sdk_platform.dart which gets groups from ffiService.knownGroups.
    // If mappings are empty, we rely on the Dart layer to populate them via CreateGroup/JoinGroup operations.
    // However, if we're NOT in a recursion call (recursion flag not set) and mappings are empty,
    // we should route to Dart layer by calling DartGetJoinedGroupList, which will route to
    // tim2tox_sdk_platform.dart -> ffiService.knownGroups
    if (groupIDs.empty()) {
        // Check if we're in a recursion call - if not, route to Dart layer
        extern thread_local bool V2TIMGroupManagerImpl_in_get_known_groups_call;
        if (!V2TIMGroupManagerImpl_in_get_known_groups_call) {
            V2TIM_LOG(kInfo, "GetJoinedGroupList: mappings empty and not in recursion, routing to Dart layer");
            // We're not in a recursion call, so we can safely route to Dart layer
            // This happens when GetJoinedGroupList is called directly (not from tim2tox_ffi_get_known_groups)
            // and mappings are empty. In this case, we should route to Dart layer to get groups
            // from ffiService.knownGroups. However, we can't directly call Dart code from C++,
            // so we rely on the fact that when GetJoinedGroupList is called from Dart layer
            // (via DartGetJoinedGroupList), it will go through tim2tox_sdk_platform.dart.
            // For now, if mappings are empty and we're not in recursion, we'll try to get
            // groups from Tox conferences as fallback, but this won't include persisted groups
            // that haven't been loaded into mappings yet.
        }
        
        // Try to rebuild mappings for all known groups from Dart layer
        // This is critical for startup when groups are restored from persistence but mappings are empty
        if (manager_impl_) {
            std::vector<std::string> known_list = manager_impl_->GetKnownGroupIDs();
            if (!known_list.empty()) {
                int rebuilt_count = 0;
                V2TIM_LOG(kInfo, "GetJoinedGroupList: Attempting to rebuild mappings for known groups (R-07: Core metadata)");
                
                for (const auto& line : known_list) {
                    std::string line_trimmed = line;
                    while (!line_trimmed.empty() && line_trimmed.back() == '\n') line_trimmed.pop_back();
                    if (line_trimmed.empty()) continue;
                    
                    // Check if this groupID already has a mapping
                    {
                        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
                        if (manager_impl_->group_id_to_group_number_.find(V2TIMString(line_trimmed.c_str())) != manager_impl_->group_id_to_group_number_.end()) {
                            continue;
                        }
                    }
                    
                    // Resolve by the stored KIND: a conference identity only via
                    // tox_conference_by_id (ConferenceMapKey), never as an NGC chat
                    // id. Identity-only here: no unmapped-group binding.
                    bool has_stored_identity = false;
                    const Tox_Group_Number matched_group_number = manager_impl_->RecoverGroupMapping(
                        line_trimmed, /*allow_unmapped_ngc_bind=*/false, &has_stored_identity);
                    if (matched_group_number != UINT32_MAX) {
                        rebuilt_count++;
                        V2TIM_LOG(kInfo, "GetJoinedGroupList: Rebuilt mapping for groupID={} <-> key={} ({})",
                                  line_trimmed, matched_group_number,
                                  IsConferenceMapKey(matched_group_number) ? "conference" : "ngc");
                        groupIDs.push_back(line_trimmed);
                    } else if (has_stored_identity) {
                        V2TIM_LOG(kInfo, "GetJoinedGroupList: GroupID={} has a stored identity but the group is not live in Tox yet",
                                  line_trimmed);
                    } else {
                        V2TIM_LOG(kInfo, "GetJoinedGroupList: GroupID={} has no stored chat_id, cannot rebuild mapping", line_trimmed);
                    }
                }
                
                V2TIM_LOG(kInfo, "GetJoinedGroupList: Rebuilt {} mappings for known groups from Dart layer", rebuilt_count);
            }
        }
        
        // Try to get groups from Tox groups as fallback
        if (manager_impl_) {
            size_t group_count = GetToxManagerFromImpl(manager_impl_)->getGroupListSize();
            V2TIM_LOG(kInfo, "GetJoinedGroupList: groups_ empty, found {} groups in Tox, looking up group IDs from mapping", group_count);
            if (group_count > 0) {
                // Allocate array for group numbers
                std::vector<Tox_Group_Number> group_list(group_count);
                GetToxManagerFromImpl(manager_impl_)->getGroupList(group_list.data(), group_count);
                
                // Look up group IDs from manager_impl_'s group_number_to_group_id_ mapping
                // This ensures we use the correct IDs instead of generating from group_number
                // IMPORTANT: If mapping is empty, we need to rebuild it from Dart layer's persistence
                // Note: We can access manager_impl_'s private members because V2TIMGroupManagerImpl is a friend class
                std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
                for (Tox_Group_Number group_number : group_list) {
                    // Try to find groupID from manager_impl_'s mapping
                    auto it = manager_impl_->group_number_to_group_id_.find(group_number);
                    if (it != manager_impl_->group_number_to_group_id_.end()) {
                        groupIDs.push_back(it->second.CString());
                        V2TIM_LOG(kInfo, "GetJoinedGroupList: found groupID {} for group_number {}", it->second.CString(), group_number);
                    } else {
                        // Group exists but not in mapping - this happens on startup when
                        // groups are restored from persistence but mapping is empty
                        // We should NOT generate IDs here to avoid conflicts
                        // Instead, the mapping should be rebuilt when Dart layer calls GetJoinedGroupList
                        V2TIM_LOG(kWarning, "GetJoinedGroupList: group_number {} not in mapping, skipping (mapping will be rebuilt by Dart layer)", group_number);
                    }
                }
            }
        }
    }
    
    V2TIM_LOG(kInfo, "GetJoinedGroupList: found {} groups", groupIDs.size());
    
    // Build group info list
    for (const std::string& groupID : groupIDs) {
        V2TIMGroupInfo groupInfo;
        
        // Try to get group info from group_info_ map
        {
            std::lock_guard<std::mutex> lock(group_mutex_);
            auto it = group_info_.find(groupID);
            if (it != group_info_.end()) {
                groupInfo = it->second;
                // Ensure groupID is set
                if (groupInfo.groupID.Empty()) {
                    groupInfo.groupID = V2TIMString(groupID.c_str());
                }
            } else {
                // Create basic group info
                groupInfo.groupID = V2TIMString(groupID.c_str());
                groupInfo.groupName = V2TIMString(groupID.c_str()); // Use groupID as default name
                groupInfo.groupType = V2TIMString("Work"); // Default to Work group type
            }
        }
        
        resultList.PushBack(groupInfo);
    }
    
    V2TIM_LOG(kInfo, "GetJoinedGroupList: returning {} groups", resultList.Size());
    callback->OnSuccess(resultList);
}

////////////////////////////// 群资料和高级设置项 //////////////////////////////
void V2TIMGroupManagerImpl::SearchGroups(const V2TIMGroupSearchParam& searchParam,
                                         V2TIMValueCallback<V2TIMGroupInfoVector>* callback) {
    V2TIM_LOG(kInfo, "SearchGroups: searching with {} keywords", searchParam.keywordList.Size());
    
    if (!callback) {
        V2TIM_LOG(kWarning, "SearchGroups: callback is null");
        return;
    }
    
    if (searchParam.keywordList.Size() == 0) {
        V2TIM_LOG(kWarning, "SearchGroups: no keywords provided");
        V2TIMGroupInfoVector emptyResult;
        callback->OnSuccess(emptyResult);
        return;
    }
    
    V2TIMGroupInfoVector resultList;
    
    // Get all known groups from V2TIMManagerImpl if available
    // Otherwise fall back to groups_ map
    std::vector<std::string> groupIDs;
    
    // The candidate set is the UNION of both registries, not "groups_ unless
    // it happens to be empty".
    //
    // `groups_` is written by CreateGroup; a group this node JOINED is only
    // registered in the manager's group_id_to_group_number_ mapping. Consulting
    // the manager just when `groups_` was empty therefore hid every joined
    // group from a node that had also created one — the empty case was the only
    // reason the joiner path ever worked.
    std::set<std::string> seen;
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        for (const auto& groupPair : groups_) {
            if (seen.insert(groupPair.first).second) {
                groupIDs.push_back(groupPair.first);
            }
        }
    }
    if (manager_impl_) {
        // GetAllGroupIDs takes the manager's own lock internally.
        for (const auto& gid : manager_impl_->GetAllGroupIDs()) {
            const std::string id = gid.CString();
            if (seen.insert(id).second) {
                groupIDs.push_back(id);
            }
        }
    } else {
        V2TIM_LOG(kWarning,
                  "SearchGroups: manager_impl_ not available; only created groups are searchable");
    }
    
    V2TIM_LOG(kInfo, "SearchGroups: searching through {} groups", groupIDs.size());
    
    // Search through all groups
    for (const std::string& groupID : groupIDs) {
        // `tox_inv_<friend>_<ms>` is an internal placeholder an invitee holds
        // until the invite is promoted to a stable id; it maps to the same tox
        // group, so resolving live names made it match the same keyword as the
        // real entry and the user saw the group twice. It is never something to
        // offer as a search result.
        if (manager_impl_ &&
            manager_impl_->IsTemporaryInviteGroupID(
                V2TIMString(groupID.c_str()))) {
            continue;
        }
        bool matched = false;
        
        // Check each keyword
        for (size_t i = 0; i < searchParam.keywordList.Size(); ++i) {
            const V2TIMString& keyword = searchParam.keywordList[i];
            const std::string keywordStr = keyword.CString();
            
            // Search by group ID if enabled
            if (searchParam.isSearchGroupID) {
                if (groupID.find(keywordStr) != std::string::npos) {
                    matched = true;
                    break;
                }
            }
            
            // Search by group name if enabled (default to true if not specified)
            // Note: Group names are stored in Flutter Prefs, so we can only search by ID here
            // For name search, we need to implement FFI interface to get group names from Flutter
            // For now, we'll search by ID as a fallback when name is not available
            // Also search by group ID even when searching by name, as group ID might match
            if (searchParam.isSearchGroupName || !searchParam.isSearchGroupID) {
                // Cached name first, then the LIVE tox name. A node that joined
                // rather than created the group holds only the
                // EnsureGroupInfoExists placeholder (`groupName == groupID`),
                // which would silently reduce a name search to an id search.
                const std::string resolvedName = ResolveGroupName(groupID);
                if (!resolvedName.empty() &&
                    resolvedName.find(keywordStr) != std::string::npos) {
                    matched = true;
                    break;
                }
                // Also check if group ID matches (as fallback when name is not available)
                if (groupID.find(keywordStr) != std::string::npos) {
                    matched = true;
                    break;
                }
            }
        }
        
        if (matched) {
            V2TIMGroupInfo groupInfo;
            groupInfo.groupID = V2TIMString(groupID.c_str());
            
            // Copy the cached info UNDER the lock — group_info_ is mutated by
            // the join/topic/info paths while a search can be running.
            {
                std::lock_guard<std::mutex> lock(group_mutex_);
                auto it = group_info_.find(groupID);
                if (it != group_info_.end()) {
                    groupInfo = it->second;
                } else {
                    // Create minimal group info
                    groupInfo.groupID = V2TIMString(groupID.c_str());
                    groupInfo.groupName = V2TIMString(groupID.c_str()); // default
                }
            }
            // Report the name the user actually sees, not the placeholder: a
            // result row labelled with the raw group id is indistinguishable
            // from a different group to whoever is reading the search list.
            const std::string resolvedName = ResolveGroupName(groupID);
            if (!resolvedName.empty()) {
                groupInfo.groupName = V2TIMString(resolvedName.c_str());
            }
            
            resultList.PushBack(groupInfo);
        }
    }
    
    V2TIM_LOG(kInfo, "SearchGroups: found {} matching groups", resultList.Size());
    callback->OnSuccess(resultList);
}

void V2TIMGroupManagerImpl::SearchCloudGroups(const V2TIMGroupSearchParam& searchParam,
                                              V2TIMValueCallback<V2TIMGroupSearchResult>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::SetGroupInfo(const V2TIMGroupInfo& info,
                                     V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "SetGroupInfo: setting info for group {}", info.groupID.CString());
    
    if (info.groupID.Empty()) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Group ID cannot be empty");
        }
        return;
    }
    
    // Get group_number from groupID
    Tox_Group_Number group_number = UINT32_MAX;
    if (manager_impl_) {
        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
        auto it = manager_impl_->group_id_to_group_number_.find(info.groupID);
        if (it != manager_impl_->group_id_to_group_number_.end()) {
            group_number = it->second;
        }
    }
    
    // Fallback to local groups_ map
    if (group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = groups_.find(info.groupID.CString());
        if (it != groups_.end()) {
            group_number = it->second;
        }
    }
    
    if (group_number == UINT32_MAX) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Group not found");
        }
        return;
    }
    
    // Wire semantics (one mapping for every client that talks to this group):
    //  - NGC name is fixed at creation (toxcore has no rename API), so a
    //    rename is a local alias only. It used to be broadcast as the TOPIC,
    //    which every other client (qTox, Toxic, ...) shows as the topic, and
    //    which then overwrote the announcement below.
    //  - NGC topic <-> group notification (announcement).
    //  - Legacy conference title <-> group name; conferences have no topic, so
    //    their notification stays local.
    const bool is_conference = IsConferenceMapKey(group_number);
    if (is_conference && !info.groupName.Empty()) {
        Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
        const std::string title = info.groupName.CString();
        Tox_Err_Conference_Title err_title = TOX_ERR_CONFERENCE_TITLE_OK;
        if (!tox || !tox_conference_set_title(
                        tox, ConferenceNumberFromKey(group_number),
                        reinterpret_cast<const uint8_t*>(title.c_str()),
                        title.length(), &err_title)) {
            V2TIM_LOG(kError, "SetGroupInfo: conference title update failed for {} (error {})",
                      info.groupID.CString(), static_cast<int>(err_title));
            if (callback) {
                callback->OnError(ERR_INVALID_PARAMETERS, "Failed to set conference title");
            }
            return;
        }
    }

    if (!is_conference && !info.notification.Empty()) {
        std::string topic = info.notification.CString();
        Tox_Err_Group_Topic_Set error;
        bool success = GetToxManagerFromImpl(manager_impl_)->setGroupTopic(
            group_number,
            reinterpret_cast<const uint8_t*>(topic.c_str()),
            topic.length(),
            &error
        );

        if (!success) {
            V2TIM_LOG(kError, "SetGroupInfo: Failed to set group topic, error: {}", static_cast<int>(error));
            if (callback) {
                // PERMISSIONS: topic lock is on and we are not a moderator
                // (or we are an observer). That is a role refusal, not an
                // unsupported group kind.
                callback->OnError(error == TOX_ERR_GROUP_TOPIC_SET_PERMISSIONS
                                      ? kErrSvrGroupPermissionDeny
                                      : ERR_INVALID_PARAMETERS,
                                  error == TOX_ERR_GROUP_TOPIC_SET_PERMISSIONS
                                      ? "No permission to change the group announcement"
                                      : "Failed to set group announcement");
            }
            return;
        }
        V2TIM_LOG(kInfo, "SetGroupInfo: Broadcast notification as topic for {}", info.groupID.CString());
    }

    // Note: Tox only supports setting group title; other fields are stored in local cache only
    // Update local cache for groupName, notification, introduction, and other in-memory fields
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = group_info_.find(info.groupID.CString());
        if (it != group_info_.end()) {
            if (!info.groupID.Empty()) it->second.groupID = info.groupID;
            if (!info.groupType.Empty()) it->second.groupType = info.groupType;
            if (!info.groupName.Empty()) it->second.groupName = info.groupName;
            if (!info.notification.Empty()) it->second.notification = info.notification;
            if (!info.introduction.Empty()) it->second.introduction = info.introduction;
        } else {
            group_info_[info.groupID.CString()] = info;
        }
    }
    
    if (callback) {
        callback->OnSuccess();
    }
}

// An NGC topic is the group's announcement (see SetGroupInfo), not its name.
void V2TIMGroupManagerImpl::UpdateGroupInfoFromTopic(const V2TIMString& groupID, const std::string& topic_value) {
    if (groupID.Empty()) return;
    std::lock_guard<std::mutex> lock(group_mutex_);
    auto it = group_info_.find(groupID.CString());
    if (it != group_info_.end()) {
        it->second.notification = V2TIMString(topic_value.c_str());
    } else {
        V2TIMGroupInfo info;
        info.groupID = groupID;
        info.notification = V2TIMString(topic_value.c_str());
        group_info_[groupID.CString()] = info;
    }
}

// Best-known display name for a group: the cached one when it is a REAL name,
// otherwise the live NGC name. EnsureGroupInfoExists seeds `groupName ==
// groupID` as a placeholder, so treating the cache as authoritative turns a
// name search into an id search on every node that joined instead of created.
std::string V2TIMGroupManagerImpl::ResolveGroupName(const std::string& groupID) {
    std::string cached;
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = group_info_.find(groupID);
        if (it != group_info_.end()) {
            cached = it->second.groupName.CString();
        }
    }
    if (!cached.empty() && cached != groupID) {
        return cached;
    }
    if (!manager_impl_) return cached;
    // Through the locked accessor, not the raw map: join/quit/invite promotion
    // mutate group_id_to_group_number_ under the manager's mutex, and a search
    // running concurrently would otherwise race an unordered_map.
    Tox_Group_Number group_number = 0;
    if (!manager_impl_->GetGroupNumberFromID(V2TIMString(groupID.c_str()),
                                             group_number)) {
        return cached;
    }
    const std::string live = GetLiveGroupName(manager_impl_, group_number);
    return live.empty() ? cached : live;
}

void V2TIMGroupManagerImpl::ClearAllState() {
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        groups_.clear();
        group_info_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(member_mutex_);
        group_members_.clear();
        member_name_card_overrides_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(mute_mutex_);
        muted_members_.clear();
        // Pending timed mutes stay on disk for this profile's next login; the
        // in-memory copy must not reach the next account (group IDs repeat).
        timed_mutes_.clear();
        timed_mutes_loaded_for_.clear();
    }
}

void V2TIMGroupManagerImpl::EnsureGroupInfoExists(const V2TIMString& groupID) {
    if (groupID.Empty()) return;
    std::lock_guard<std::mutex> lock(group_mutex_);
    auto it = group_info_.find(groupID.CString());
    if (it == group_info_.end()) {
        V2TIMGroupInfo info;
        info.groupID = groupID;
        info.groupName = groupID;  // default name
        info.groupType = V2TIMString("group");
        group_info_[groupID.CString()] = info;
        V2TIM_LOG(kInfo, "EnsureGroupInfoExists: added group info for {}", groupID.CString());
    }
}

void V2TIMGroupManagerImpl::InitGroupAttributes(const V2TIMString& groupID,
                            const V2TIMGroupAttributeMap& attributes,
                            V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::SetGroupAttributes(const V2TIMString& groupID,
                           const V2TIMGroupAttributeMap& attributes,
                           V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::DeleteGroupAttributes(const V2TIMString& groupID, const V2TIMStringVector& keys,
                                                  V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::GetGroupAttributes(const V2TIMString& groupID, const V2TIMStringVector& keys,
                                               V2TIMValueCallback<V2TIMGroupAttributeMap>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::GetGroupOnlineMemberCount(const V2TIMString& groupID,
                                  V2TIMValueCallback<uint32_t>* callback) {
    // 模拟在线人数（Tox 会议无法直接获取）
    if (group_members_.find(groupID.CString()) != group_members_.end()) {
        if (callback) callback->OnSuccess(group_members_[groupID.CString()].Size());
    } else {
        if (callback) callback->OnError(ERR_SDK_GROUP_INVALID_ID, "Group not found");
    }
}

void V2TIMGroupManagerImpl::SetGroupCounters(const V2TIMString& groupID, const V2TIMStringToInt64Map& counters,
                                             V2TIMValueCallback<V2TIMStringToInt64Map>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::GetGroupCounters(const V2TIMString& groupID, const V2TIMStringVector& keys,
                                             V2TIMValueCallback<V2TIMStringToInt64Map>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::IncreaseGroupCounter(const V2TIMString& groupID, const V2TIMString& key, int64_t value,
                                                 V2TIMValueCallback<V2TIMStringToInt64Map>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::DecreaseGroupCounter(const V2TIMString& groupID, const V2TIMString& key, int64_t value,
                                                 V2TIMValueCallback<V2TIMStringToInt64Map>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

////////////////////////////// 群成员管理 //////////////////////////////
void V2TIMGroupManagerImpl::GetGroupMemberList(
    const V2TIMString& groupID, uint32_t filter, uint64_t nextSeq,
    V2TIMValueCallback<V2TIMGroupMemberInfoResult>* callback) {
    // [tim2tox-debug] Record query parameters for GetGroupMemberList
    V2TIM_LOG(kInfo, "[tim2tox-debug] GetGroupMemberList: Query parameters - groupID={}, filter={}, nextSeq={}", 
             groupID.CString(), filter, nextSeq);
    V2TIM_LOG(kInfo, "GetGroupMemberList: getting members for group {}, filter={}, nextSeq={}", 
              groupID.CString(), filter, nextSeq);
    
    if (!callback) {
        V2TIM_LOG(kWarning, "GetGroupMemberList: callback is null");
        return;
    }
    
    // Get ToxManager and verify it's valid
    // For multi-instance support, try to get from current instance first
    extern V2TIMManagerImpl* GetCurrentInstance();
    V2TIMManagerImpl* current_manager_impl = GetCurrentInstance();
    
    // Use current instance if available, otherwise fall back to manager_impl_
    V2TIMManagerImpl* target_manager_impl = current_manager_impl ? current_manager_impl : manager_impl_;
    
    // Note: GetCurrentInstanceId is defined in tim2tox_ffi.cpp as a C++ function
    extern int64_t GetCurrentInstanceId();
    int64_t current_instance_id = GetCurrentInstanceId();
    V2TIM_LOG(kInfo, "[GetGroupMemberList] Using manager_impl: current={} stored={} target={} instance_id={}",
              static_cast<void*>(current_manager_impl), static_cast<void*>(manager_impl_), static_cast<void*>(target_manager_impl), current_instance_id);

    ToxManager* tox_manager = GetToxManagerFromImpl(target_manager_impl);
    if (!tox_manager) {
        V2TIM_LOG(kError, "[GetGroupMemberList] ToxManager is null for groupID={} instance_id={}", groupID.CString(), current_instance_id);
        callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not available");
        return;
    }

    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "[GetGroupMemberList] Tox instance is null for groupID={} instance_id={} ToxManager={}",
                  groupID.CString(), current_instance_id, static_cast<void*>(tox_manager));
        callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
        return;
    }
    
    // Get group_number from groupID - use current instance's mapping for multi-instance (target_manager_impl)
    // so that when Bob calls getGroupMemberList(groupId), we resolve groupId using Bob's group_number mapping.
    Tox_Group_Number group_number = UINT32_MAX;
    bool has_stored_chat_id = false;  // Initialize here so it's available in the entire function
    V2TIMManagerImpl* lookup_impl = target_manager_impl ? target_manager_impl : manager_impl_;
    
    if (lookup_impl) {
        std::lock_guard<std::mutex> lock(lookup_impl->mutex_);
        auto it = lookup_impl->group_id_to_group_number_.find(groupID);
        if (it != lookup_impl->group_id_to_group_number_.end()) {
            group_number = it->second;
        }
    }
    
    // Fallback to local groups_ map
    if (group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = groups_.find(groupID.CString());
        if (it != groups_.end()) {
            group_number = it->second;
        }
    }
    
    // Recovery mechanism: rebuild the mapping if not found (current instance's
    // Tox and mapping). The stored identity is resolved by its stored KIND: a
    // conference identity only through tox_conference_by_id (-> ConferenceMapKey),
    // never as an NGC chat id, and an unmapped NGC group is never bound to it.
    if (group_number == UINT32_MAX && lookup_impl) {
        V2TIM_LOG(kInfo, "GetGroupMemberList: Group {} not found in mappings, attempting recovery", groupID.CString());
        group_number = lookup_impl->RecoverGroupMapping(
            groupID.CString(), /*allow_unmapped_ngc_bind=*/true, &has_stored_chat_id);
    }
    
    if (group_number == UINT32_MAX) {
        // When we have stored chat_id but group not in Tox yet (rejoin pending), return self-only list
        // so the user at least sees themselves in the member list (fixes "CF02 still can't see myself" after restart)
        if (has_stored_chat_id && tox_manager && tox) {
            uint8_t self_pubkey_fallback[TOX_PUBLIC_KEY_SIZE];
            tox_self_get_public_key(tox, self_pubkey_fallback);
            std::string self_userID_fallback = ToxUtil::tox_bytes_to_hex(self_pubkey_fallback, TOX_PUBLIC_KEY_SIZE);
            V2TIMGroupMemberFullInfoVector selfOnlyList;
            V2TIMGroupMemberFullInfo selfInfoFallback;
            selfInfoFallback.userID = self_userID_fallback.c_str();
            selfInfoFallback.nameCard = "";
            selfInfoFallback.nickName = self_userID_fallback.c_str();
            selfInfoFallback.role = toxRoleToV2timRole(TOX_GROUP_ROLE_USER);
            selfInfoFallback.joinTime = static_cast<int64_t>(std::time(nullptr));
            selfOnlyList.PushBack(selfInfoFallback);
            V2TIMGroupMemberInfoResult resultFallback;
            resultFallback.memberInfoList = selfOnlyList;
            resultFallback.nextSequence = 0;
            {
                std::lock_guard<std::mutex> lock(member_mutex_);
                V2TIMGroupMemberInfoVector cachedList;
                V2TIMGroupMemberInfo mi;
                mi.userID = self_userID_fallback.c_str();
                mi.nickName = self_userID_fallback.c_str();
                cachedList.PushBack(mi);
                group_members_[groupID.CString()] = cachedList;
            }
            V2TIM_LOG(kInfo, "[GetGroupMemberList] Group {} not in Tox yet (rejoin pending), returning self-only list so user sees themselves", groupID.CString());
            callback->OnSuccess(resultFallback);
            return;
        }
        // No stored chat_id or no tox - return error
        std::string error_msg = "Group " + std::string(groupID.CString()) + " not found in Tox";
        if (has_stored_chat_id) {
            error_msg += " (stored chat_id exists but group not restored yet)";
        } else {
            error_msg += " (no stored chat_id)";
        }
        V2TIMManagerImpl* err_lookup = target_manager_impl ? target_manager_impl : manager_impl_;
        size_t group_count = err_lookup ? GetToxManagerFromImpl(err_lookup)->getGroupListSize() : 0;
        error_msg += ". Total groups in Tox: " + std::to_string(group_count);
        
        if (group_count == 0) {
            V2TIM_LOG(kWarning, "[GetGroupMemberList] {} (Tox may not be connected yet)", error_msg);
        } else {
            V2TIM_LOG(kError, "[GetGroupMemberList] {}", error_msg);
        }
        callback->OnError(ERR_INVALID_PARAMETERS, error_msg.c_str());
        return;
    }
    
    V2TIM_LOG(kInfo, "GetGroupMemberList: Getting members for group {} (group_number={})", groupID.CString(), group_number);
    
    TOX_CONNECTION self_connection = tox_self_get_connection_status(tox);
    uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
    tox_self_get_public_key(tox, self_pubkey);
    std::string self_userID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
    size_t friend_count = tox_self_get_friend_list_size(tox);

    V2TIM_LOG(kInfo, "[GetGroupMemberList] ENTRY instance_id={} groupID={} group_number={}", current_instance_id, groupID.CString(), group_number);
    V2TIM_LOG(kInfo, "[GetGroupMemberList] Self connection={} (0=NONE,1=TCP,2=UDP) Self userID={} Friend count={}",
              static_cast<int>(self_connection), self_userID, friend_count);
    if (friend_count > 0) {
        std::vector<uint32_t> friend_list(friend_count);
        tox_self_get_friend_list(tox, friend_list.data());
        for (size_t i = 0; i < friend_count; i++) {
            uint8_t friend_pubkey[TOX_PUBLIC_KEY_SIZE];
            TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
            if (tox_friend_get_public_key(tox, friend_list[i], friend_pubkey, &err_key) &&
                err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
                std::string friend_userID = ToxUtil::tox_bytes_to_hex(friend_pubkey, TOX_PUBLIC_KEY_SIZE);
                TOX_ERR_FRIEND_QUERY err_conn;
                TOX_CONNECTION friend_conn = tox_friend_get_connection_status(tox, friend_list[i], &err_conn);
                V2TIM_LOG(kInfo, "[GetGroupMemberList] Friend[{}]: userID={} connection={} err={}", i, friend_userID, static_cast<int>(friend_conn), static_cast<int>(err_conn));
            }
        }
    }
    
    V2TIMGroupMemberFullInfoVector memberList;
    
    // Note: tox group doesn't have a direct peer_count API
    // We need to iterate through peer IDs. Since peer IDs may not be sequential,
    // we'll try a range and handle errors. Alternatively, we can track peers via callbacks.
    // For now, we'll try a reasonable range (0-1000) and stop when we get errors.
    // TODO: Implement proper peer tracking via callbacks for better performance
    
    // The kind is decided by the map key. A conference key never reaches a
    // tox_group_* API (it would only fail, dropping the self name/role and the
    // peer details); conferences are enumerated below with tox_conference_* on
    // the untagged number: members = conference peers + self.
    const bool is_conference_key = IsConferenceMapKey(group_number);
    Tox_Err_Group_State_Query err_privacy = TOX_ERR_GROUP_STATE_QUERY_GROUP_NOT_FOUND;
    Tox_Group_Privacy_State privacy_state = TOX_GROUP_PRIVACY_STATE_PUBLIC;
    bool is_connected = false;
    Tox_Err_Group_Self_Query err_self = TOX_ERR_GROUP_SELF_QUERY_GROUP_NOT_FOUND;
    Tox_Group_Peer_Number self_peer_id = UINT32_MAX;
    Tox_Group_Role self_role = TOX_GROUP_ROLE_USER;
    if (!is_conference_key) {
        privacy_state = tox_group_get_privacy_state(tox, group_number, &err_privacy);
        if (err_privacy == TOX_ERR_GROUP_STATE_QUERY_OK) {
            V2TIM_LOG(kInfo, "[GetGroupMemberList] Privacy state: group_number={} privacy_state={} (0=PUBLIC,1=PRIVATE)", group_number, static_cast<int>(privacy_state));
            if (privacy_state == TOX_GROUP_PRIVACY_STATE_PRIVATE) {
                V2TIM_LOG(kWarning, "[GetGroupMemberList] Group is PRIVATE - requires friend connection; friend_count={}", friend_count);
            } else if (privacy_state == TOX_GROUP_PRIVACY_STATE_PUBLIC) {
                V2TIM_LOG(kInfo, "[GetGroupMemberList] Group is PUBLIC - peers discoverable via DHT");
            }
        } else {
            V2TIM_LOG(kInfo, "[GetGroupMemberList] Failed to get privacy state err={}", static_cast<int>(err_privacy));
        }

        Tox_Err_Group_Is_Connected err_connected;
        is_connected = GetToxManagerFromImpl(target_manager_impl)->isGroupConnected(group_number, &err_connected);
        V2TIM_LOG(kInfo, "[GetGroupMemberList] Group connection: is_connected={} err={}", is_connected ? 1 : 0, static_cast<int>(err_connected));
        if (!is_connected) {
            V2TIM_LOG(kWarning, "[GetGroupMemberList] Group is NOT connected - peer discovery may not work");
        }

        self_peer_id = tox_group_self_get_peer_id(tox, group_number, &err_self);
        if (err_self == TOX_ERR_GROUP_SELF_QUERY_OK && self_peer_id != UINT32_MAX) {
            self_role = tox_group_self_get_role(tox, group_number, &err_self);
            V2TIM_LOG(kInfo, "[GetGroupMemberList] Self peer_id={} in group_number={} role={}", self_peer_id, group_number, static_cast<int>(self_role));
        } else {
            V2TIM_LOG(kInfo, "[GetGroupMemberList] Failed to get self peer_id err={}", static_cast<int>(err_self));
        }
    }

    // Tox NGCv2 peer_ids are dynamically assigned and non-sequential — sequential 0..N iteration
    // reliably misses all peers. Instead, use the peer_id set populated by HandleGroupPeerJoin
    // callbacks (group_peer_id_cache_: group_number -> public_key_hex -> peer_id).
    std::vector<Tox_Group_Peer_Number> cached_peer_ids;
    if (!is_conference_key) {  // NGC peer ids only; conferences are enumerated below
        std::lock_guard<std::mutex> lock(target_manager_impl->mutex_);
        auto cache_it = target_manager_impl->group_peer_id_cache_.find(group_number);
        if (cache_it != target_manager_impl->group_peer_id_cache_.end()) {
            for (const auto& kv : cache_it->second) {
                cached_peer_ids.push_back(kv.second);
            }
        }
    }
    V2TIM_LOG(kInfo, "[GetGroupMemberList] Using callback-tracked peers: {} cached peer_ids for group_number={} groupID={}",
              cached_peer_ids.size(), group_number, groupID.CString());
    V2TIM_LOG(kInfo, "[GetGroupMemberList] peer cache diagnostic: cached_peer_count={} self_conn={} group_connected={} privacy={}",
              cached_peer_ids.size(), static_cast<int>(tox_self_get_connection_status(tox)),
              is_connected ? 1 : 0, static_cast<int>(privacy_state));

    int total_peers_found = 0;
    for (Tox_Group_Peer_Number peer_id : cached_peer_ids) {
        // Verify peer is still present; cache may contain stale entries if exit cleanup was missed.
        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Peer_Query err_key;
        bool got_key = GetToxManagerFromImpl(target_manager_impl)->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key);

        if (!got_key || err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
            V2TIM_LOG(kInfo, "[GetGroupMemberList] Cached peer_id={} no longer valid (err={}), skipping",
                      peer_id, static_cast<int>(err_key));
            V2TIM_LOG(kInfo, "[GetGroupMemberList] stale cached peer skipped: err={}",
                      static_cast<int>(err_key));
            continue;
        }

        total_peers_found++;
        
        // Convert public key to userID (hex string)
        std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
        
        // Get peer name (buffer may not be NUL-terminated; use strnlen to avoid OOB read)
        uint8_t name_buffer[TOX_MAX_NAME_LENGTH + 1] = {};
        std::string peer_name;
        Tox_Err_Group_Peer_Query err_name;
        if (GetToxManagerFromImpl(target_manager_impl)->getGroupPeerName(group_number, peer_id, name_buffer, TOX_MAX_NAME_LENGTH, &err_name) &&
            err_name == TOX_ERR_GROUP_PEER_QUERY_OK) {
            size_t name_len = strnlen(reinterpret_cast<const char*>(name_buffer), TOX_MAX_NAME_LENGTH);
            peer_name = std::string(reinterpret_cast<const char*>(name_buffer), name_len);
        }
        
        // Get peer role
        Tox_Group_Role peer_role = tox_group_peer_get_role(tox, group_number, peer_id, &err_key);
        uint32_t v2tim_role = toxRoleToV2timRole(peer_role);
        
        // Get peer connection status for DHT diagnosis
        Tox_Err_Group_Peer_Query err_conn;
        Tox_Connection peer_conn = tox_group_peer_get_connection_status(tox, group_number, peer_id, &err_conn);
        const char* conn_str = "UNKNOWN";
        if (err_conn == TOX_ERR_GROUP_PEER_QUERY_OK) {
            if (peer_conn == TOX_CONNECTION_NONE) conn_str = "NONE";
            else if (peer_conn == TOX_CONNECTION_TCP) conn_str = "TCP";
            else if (peer_conn == TOX_CONNECTION_UDP) conn_str = "UDP";
        }
        
        // Skip self: when peer_id == self_peer_id treat as self (we add self explicitly at the end).
        // Prefer peer_id match so we don't depend on Tox always returning matching keys for self.
        if (err_self == TOX_ERR_GROUP_SELF_QUERY_OK && self_peer_id != UINT32_MAX && peer_id == self_peer_id) {
            V2TIM_LOG(kInfo, "[GetGroupMemberList] Found peer #{}: peer_id={} is SELF (skipping)", total_peers_found, peer_id);
            continue;
        }
        uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, self_pubkey);
        if (memcmp(peer_pubkey, self_pubkey, TOX_PUBLIC_KEY_SIZE) == 0) {
            V2TIM_LOG(kInfo, "[GetGroupMemberList] Found peer #{}: peer_id={} is SELF by key (skipping)", total_peers_found, peer_id);
            continue;
        }

        V2TIM_LOG(kInfo, "[GetGroupMemberList] Found peer #{}: peer_id={} userID={} nickName={} role={} connection={}",
                  total_peers_found, peer_id, userID, peer_name, v2tim_role, conn_str);
        
        // Create member info
        V2TIMGroupMemberFullInfo memberInfo;
        memberInfo.userID = userID;
        // Set nameCard to peer_name (group-specific nickname)
        memberInfo.nameCard = peer_name;
        // Set nickName to userID as fallback (or could be from friend info)
        memberInfo.nickName = peer_name.empty() ? userID : peer_name;
        memberInfo.role = v2tim_role;
        // joinTime is in seconds; Tox has no peer join timestamp, use current time so UI does not show 1970-01-01
        memberInfo.joinTime = static_cast<int64_t>(std::time(nullptr));

        memberList.PushBack(memberInfo);
    }

    // Conference (legacy API, tagged map key): enumerate the peers with
    // tox_conference_* on the UNTAGGED number (dense 0..count-1). Self is one of
    // those peers: its conference name becomes the self entry's name below.
    const bool is_conference_group = is_conference_key;
    // Look up stored owner userID for conference role assignment
    std::string stored_owner_userID;
    {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto info_it = group_info_.find(groupID.CString());
        if (info_it != group_info_.end() && !info_it->second.owner.Empty()) {
            stored_owner_userID = info_it->second.owner.CString();
        }
    }
    std::string self_name_in_group;
    if (is_conference_group) {
        const uint32_t conference_number = ConferenceNumberFromKey(group_number);
        auto conference_peer_name = [&](uint32_t peer) {
            Tox_Err_Conference_Peer_Query err_name = TOX_ERR_CONFERENCE_PEER_QUERY_OK;
            const size_t name_sz = tox_conference_peer_get_name_size(tox, conference_number, peer, &err_name);
            if (err_name != TOX_ERR_CONFERENCE_PEER_QUERY_OK || name_sz == 0 || name_sz > TOX_MAX_NAME_LENGTH) {
                return std::string();
            }
            uint8_t name_buf[TOX_MAX_NAME_LENGTH + 1] = {};
            if (!tox_conference_peer_get_name(tox, conference_number, peer, name_buf, &err_name) ||
                err_name != TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
                return std::string();
            }
            return std::string(reinterpret_cast<const char*>(name_buf), name_sz);
        };
        Tox_Err_Conference_Peer_Query err_conf_count = TOX_ERR_CONFERENCE_PEER_QUERY_OK;
        const uint32_t conf_peer_count = tox_conference_peer_count(tox, conference_number, &err_conf_count);
        V2TIM_LOG(kInfo, "[GetGroupMemberList] Conference key={} (conference_number={}): peer_count={} err={}",
                  group_number, conference_number, conf_peer_count, static_cast<int>(err_conf_count));
        if (err_conf_count == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
            for (uint32_t ci = 0; ci < conf_peer_count; ++ci) {
                uint8_t peer_pubkey_c[TOX_PUBLIC_KEY_SIZE];
                Tox_Err_Conference_Peer_Query err_ckey = TOX_ERR_CONFERENCE_PEER_QUERY_OK;
                if (!tox_conference_peer_get_public_key(tox, conference_number, ci, peer_pubkey_c, &err_ckey)
                    || err_ckey != TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
                    continue;
                }
                Tox_Err_Conference_Peer_Query err_ours = TOX_ERR_CONFERENCE_PEER_QUERY_OK;
                const bool is_self_peer =
                    (tox_conference_peer_number_is_ours(tox, conference_number, ci, &err_ours) &&
                     err_ours == TOX_ERR_CONFERENCE_PEER_QUERY_OK) ||
                    memcmp(peer_pubkey_c, self_pubkey, TOX_PUBLIC_KEY_SIZE) == 0;
                if (is_self_peer) {
                    // Added once, explicitly, below.
                    self_name_in_group = conference_peer_name(ci);
                    continue;
                }
                std::string c_userID = ToxUtil::tox_bytes_to_hex(peer_pubkey_c, TOX_PUBLIC_KEY_SIZE);
                const std::string c_name = conference_peer_name(ci);
                V2TIMGroupMemberFullInfo confInfo;
                confInfo.userID = c_userID;
                confInfo.nameCard = c_name;
                confInfo.nickName = c_name.empty() ? c_userID : c_name;
                // For conference groups, use stored owner info to assign creator role
                if (!stored_owner_userID.empty() && c_userID == stored_owner_userID) {
                    confInfo.role = V2TIM_GROUP_MEMBER_ROLE_SUPER; // Owner
                } else {
                    confInfo.role = V2TIM_GROUP_MEMBER_ROLE_MEMBER;
                }
                confInfo.joinTime = static_cast<int64_t>(std::time(nullptr));
                memberList.PushBack(confInfo);
                total_peers_found++;
                V2TIM_LOG(kInfo, "[GetGroupMemberList] Conference peer #{}: userID={} nickName={}", ci, c_userID, c_name);
            }
        }
    } else {
        // Include self in member list so "getGroupMemberList" returns both self and others (matches IM SDK / test expectations)
        // Get self name in group (nameCard set via SetGroupMemberInfo / tox_group_self_set_name)
        Tox_Err_Group_Self_Query err_self_name;
        size_t self_name_size = tox_group_self_get_name_size(tox, group_number, &err_self_name);
        if (err_self_name == TOX_ERR_GROUP_SELF_QUERY_OK && self_name_size > 0 && self_name_size <= 256) {
            uint8_t self_name_buf[257];
            memset(self_name_buf, 0, sizeof(self_name_buf));
            if (tox_group_self_get_name(tox, group_number, self_name_buf, &err_self_name) &&
                err_self_name == TOX_ERR_GROUP_SELF_QUERY_OK) {
                self_name_in_group = std::string(reinterpret_cast<const char*>(self_name_buf));
            }
        }
    }
    V2TIMGroupMemberFullInfo selfInfo;
    selfInfo.userID = self_userID;
    selfInfo.nameCard = self_name_in_group.empty() ? "" : self_name_in_group.c_str();
    selfInfo.nickName = self_name_in_group.empty() ? self_userID : self_name_in_group.c_str();
    if (is_conference_group) {
        // Conferences have no roles: the stored creator is the owner.
        selfInfo.role = (!stored_owner_userID.empty() && self_userID == stored_owner_userID)
                            ? V2TIM_GROUP_MEMBER_ROLE_SUPER
                            : V2TIM_GROUP_MEMBER_ROLE_MEMBER;
    } else {
        selfInfo.role = toxRoleToV2timRole(self_role);
    }
    selfInfo.joinTime = static_cast<int64_t>(std::time(nullptr));
    memberList.PushBack(selfInfo);
    
    V2TIM_LOG(kInfo, "[GetGroupMemberList] Peer iteration completed: total_peers_found={} memberList.Size()={} instance_id={} groupID={} group_number={}",
              total_peers_found, memberList.Size(), current_instance_id, groupID.CString(), group_number);

    if (total_peers_found == 1 && !is_conference_group) {
        V2TIM_LOG(kWarning, "[GetGroupMemberList] Only 1 peer found - DHT sync may be incomplete or peers not visible");
        TOX_CONNECTION self_conn = tox_self_get_connection_status(tox);
        Tox_Err_Group_Is_Connected err_conn_check;
        bool is_connected_check = GetToxManagerFromImpl(target_manager_impl)->isGroupConnected(group_number, &err_conn_check);
        Tox_Err_Group_Self_Query err_self_check;
        Tox_Group_Peer_Number self_peer_id_check = tox_group_self_get_peer_id(tox, group_number, &err_self_check);
        V2TIM_LOG(kInfo, "[GetGroupMemberList] DEBUG: self_conn={} group_connected={} err_conn={} self_peer_id={} friend_count={} privacy={}",
                  static_cast<int>(self_conn), is_connected_check ? 1 : 0, static_cast<int>(err_conn_check), self_peer_id_check, friend_count, static_cast<int>(privacy_state));
        if (memberList.Size() > 0) {
            std::string first_userID = memberList[0].userID.CString();
            if (first_userID == self_userID) {
                V2TIM_LOG(kWarning, "[GetGroupMemberList] Only peer found is self - other peers not visible yet");
            }
        }
    }

    V2TIM_LOG(kInfo, "[GetGroupMemberList] EXIT Found {} peers in group {}", memberList.Size(), groupID.CString());
    for (size_t i = 0; i < memberList.Size(); i++) {
        const V2TIMGroupMemberFullInfo& member = memberList[i];
        V2TIM_LOG(kInfo, "[GetGroupMemberList] Member {}: userID={} nickName={} role={}", i, member.userID.CString(), member.nickName.CString(), member.role);
    }
    
    // Apply nameCard overrides (for other users set via SetGroupMemberInfo; Tox only allows self name)
    {
        std::lock_guard<std::mutex> lock(member_mutex_);
        auto ov_it = member_name_card_overrides_.find(groupID.CString());
        if (ov_it != member_name_card_overrides_.end()) {
            const auto& overrides = ov_it->second;
            for (size_t i = 0; i < memberList.Size(); i++) {
                std::string uid = memberList[i].userID.CString();
                auto o = overrides.find(uid);
                if (o != overrides.end()) {
                    memberList[i].nameCard = o->second.c_str();
                }
                // Also match 64-char prefix (userID may be 76-char Tox ID)
                if (uid.length() >= 64) {
                    std::string prefix64 = uid.substr(0, 64);
                    auto o64 = overrides.find(prefix64);
                    if (o64 != overrides.end()) {
                        memberList[i].nameCard = o64->second.c_str();
                    }
                }
            }
        }
    }
    
    // Create result
    V2TIMGroupMemberInfoResult result;
    result.memberInfoList = memberList;
    result.nextSequence = 0; // Tox doesn't support pagination, so always return 0
    
    // [tim2tox-debug] Record member list building for GetGroupMemberList
    V2TIM_LOG(kInfo, "[tim2tox-debug] GetGroupMemberList: Member list built - groupID={}, memberCount={}", 
             groupID.CString(), result.memberInfoList.Size());
    V2TIM_LOG(kInfo, "[GetGroupMemberList] Calling callback->OnSuccess with {} members", result.memberInfoList.Size());
    
    // Store member list in cache (we'll store full info, but convert to basic info for compatibility)
    {
        std::lock_guard<std::mutex> lock(member_mutex_);
        // Convert V2TIMGroupMemberFullInfoVector to V2TIMGroupMemberInfoVector for storage
        V2TIMGroupMemberInfoVector cachedList;
        for (size_t i = 0; i < memberList.Size(); i++) {
            V2TIMGroupMemberInfo memberInfo;
            const V2TIMGroupMemberFullInfo& fullInfo = memberList[i];
            memberInfo.userID = fullInfo.userID;
            memberInfo.nickName = fullInfo.nickName;
            // Note: V2TIMGroupMemberInfo doesn't have role field, only V2TIMGroupMemberFullInfo does
            cachedList.PushBack(memberInfo);
        }
        group_members_[groupID.CString()] = cachedList;
    }
    
    callback->OnSuccess(result);
}

void V2TIMGroupManagerImpl::GetGroupMembersInfo(
    const V2TIMString& groupID, V2TIMStringVector memberList,
    V2TIMValueCallback<V2TIMGroupMemberFullInfoVector>* callback) {
    // CRITICAL: Extract groupID C-string immediately to avoid lifetime issues
    std::string group_id_str;
    try {
        const char* group_id_cstr = groupID.CString();
        if (group_id_cstr) {
            group_id_str = std::string(group_id_cstr);
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid group ID");
        return;
    }
    
    // CRITICAL: Copy memberList immediately to avoid lifetime issues
    std::vector<std::string> member_id_strings;  // Store C-strings safely
    try {
        for (size_t i = 0; i < memberList.Size(); i++) {
            try {
                const V2TIMString& userID = memberList[i];
                const char* user_id_cstr = nullptr;
                size_t user_id_len = 0;
                try {
                    user_id_len = userID.Length();
                    user_id_cstr = userID.CString();
                } catch (...) {
                    continue;
                }
                if (!user_id_cstr || user_id_len == 0) {
                    continue;
                }
                member_id_strings.push_back(std::string(user_id_cstr, user_id_len));
            } catch (...) {
                continue;
            }
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to copy member ID list");
        return;
    }
    
    V2TIM_LOG(kInfo, "GetGroupMembersInfo: getting info for {} members in group {}", 
              member_id_strings.size(), group_id_str.c_str());
    
    if (!callback) {
        V2TIM_LOG(kWarning, "GetGroupMembersInfo: callback is null");
        return;
    }
    
    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "GetGroupMembersInfo: Tox instance not available");
        callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
        return;
    }
    
    // Get group_number from groupID
    Tox_Group_Number group_number = UINT32_MAX;
    if (manager_impl_) {
        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
        auto it = manager_impl_->group_id_to_group_number_.find(V2TIMString(group_id_str.c_str()));
        if (it != manager_impl_->group_id_to_group_number_.end()) {
            group_number = it->second;
        }
    }
    
    // Fallback to local groups_ map
    if (group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = groups_.find(group_id_str);
        if (it != groups_.end()) {
            group_number = it->second;
        }
    }
    
    if (group_number == UINT32_MAX) {
        V2TIM_LOG(kError, "GetGroupMembersInfo: Group {} not found", group_id_str);
        callback->OnError(ERR_INVALID_PARAMETERS, "Group not found");
        return;
    }
    
    V2TIMGroupMemberFullInfoVector resultList;

    // [tim2tox-debug] Record query parameters for GetGroupMembersInfo
    V2TIM_LOG(kInfo, "[tim2tox-debug] GetGroupMembersInfo: Query parameters - groupID={}, group_number={}, memberCount={}",
             group_id_str.c_str(), group_number, member_id_strings.size());
    V2TIM_LOG(kInfo, "[GetGroupMembersInfo] ENTRY groupID={} group_number={} memberCount={}", group_id_str, group_number, member_id_strings.size());
    for (size_t i = 0; i < member_id_strings.size() && i < 5; ++i) {
        V2TIM_LOG(kInfo, "[GetGroupMembersInfo] requested_member[{}]={}", i, member_id_strings[i]);
    }

    // Check if this is a conference group: the map key is authoritative for
    // the kind (see ConferenceMapKey); the type label missed AV conferences.
    const bool is_conference = IsConferenceMapKey(group_number);

    for (const auto& requested_user_id_str : member_id_strings) {
        V2TIMString requested_userID(requested_user_id_str.c_str());
        V2TIM_LOG(kInfo, "[GetGroupMembersInfo] Searching for member requested_userID={} length={} is_conference={}", requested_user_id_str, requested_user_id_str.length(), is_conference ? 1 : 0);

        // Search for this user in the group peers
        bool found = false;
        int peer_iteration_count = 0;

        if (is_conference) {
            // For conference groups, enumerate sequentially
            Tox_Err_Conference_Peer_Query err_count;
            uint32_t peer_count = tox_conference_peer_count(tox, ConferenceNumberFromKey(group_number), &err_count);
            if (err_count == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
                for (uint32_t peer_num = 0; peer_num < peer_count; ++peer_num) {
                    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                    Tox_Err_Conference_Peer_Query err_key;
                    if (!tox_conference_peer_get_public_key(tox, ConferenceNumberFromKey(group_number), peer_num, peer_pubkey, &err_key)
                        || err_key != TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
                        continue;
                    }

                    peer_iteration_count++;
                    std::string peer_userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);

                    std::string peer_userID_upper = peer_userID;
                    std::string requested_userID_upper = requested_user_id_str;
                    std::transform(peer_userID_upper.begin(), peer_userID_upper.end(), peer_userID_upper.begin(), ::toupper);
                    std::transform(requested_userID_upper.begin(), requested_userID_upper.end(), requested_userID_upper.begin(), ::toupper);

                    if (peer_userID_upper == requested_userID_upper) {
                        V2TIM_LOG(kInfo, "[GetGroupMembersInfo] MATCH FOUND (conference) peer_num={} peer_userID={}", peer_num, peer_userID);

                        // Get peer name
                        std::string peer_name;
                        size_t name_sz = tox_conference_peer_get_name_size(tox, ConferenceNumberFromKey(group_number), peer_num, &err_key);
                        if (err_key == TOX_ERR_CONFERENCE_PEER_QUERY_OK && name_sz > 0 && name_sz <= TOX_MAX_NAME_LENGTH) {
                            uint8_t name_buf[TOX_MAX_NAME_LENGTH + 1] = {};
                            if (tox_conference_peer_get_name(tox, ConferenceNumberFromKey(group_number), peer_num, name_buf, &err_key)
                                && err_key == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
                                peer_name = std::string(reinterpret_cast<const char*>(name_buf), strlen(reinterpret_cast<const char*>(name_buf)));
                            }
                        }

                        // Get stored owner for role assignment
                        std::string stored_owner_userID;
                        {
                            std::lock_guard<std::mutex> lock(group_mutex_);
                            auto info_it = group_info_.find(group_id_str);
                            if (info_it != group_info_.end() && !info_it->second.owner.Empty()) {
                                stored_owner_userID = info_it->second.owner.CString();
                            }
                        }

                        V2TIMGroupMemberFullInfo memberInfo;
                        memberInfo.userID = V2TIMString(requested_user_id_str.c_str());
                        memberInfo.nameCard = peer_name;
                        memberInfo.nickName = peer_name.empty() ? requested_user_id_str : peer_name;
                        if (!stored_owner_userID.empty() && requested_user_id_str == stored_owner_userID) {
                            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_SUPER;
                        } else {
                            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_MEMBER;
                        }
                        memberInfo.joinTime = static_cast<int64_t>(std::time(nullptr));

                        V2TIM_LOG(kInfo, "[GetGroupMembersInfo] Returning conference member - userID={}, nickName={}, role={}",
                                 memberInfo.userID.CString(), memberInfo.nickName.CString(), memberInfo.role);

                        resultList.PushBack(memberInfo);
                        found = true;
                        break;
                    }
                }
            }
        } else {
            // Self-lookup short-circuit. tox_group_peer_get_name() for the
            // self peer_id does NOT reflect the value just set via
            // tox_group_self_set_name() until a full iterate cycle has run
            // (and even then, conferences gate self-name on a network round
            // trip that virtual-clock tests don't drive). The fix is to call
            // tox_group_self_get_name directly when the requested userID
            // matches our own public key — that path is purely local and
            // reflects writes immediately. Also honour any nameCard override
            // that SetGroupMemberInfo stored locally for non-self peers.
            uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
            tox_self_get_public_key(tox, self_pubkey);
            std::string self_pk_hex = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
            std::string self_pk_upper = self_pk_hex;
            std::transform(self_pk_upper.begin(), self_pk_upper.end(), self_pk_upper.begin(), ::toupper);
            std::string requested_upper_for_self = requested_user_id_str;
            std::transform(requested_upper_for_self.begin(), requested_upper_for_self.end(), requested_upper_for_self.begin(), ::toupper);
            // requested ID may be 76-char address (first 64 chars are pubkey)
            std::string requested_pk_prefix = (requested_upper_for_self.length() >= 64)
                ? requested_upper_for_self.substr(0, 64)
                : requested_upper_for_self;
            if (requested_pk_prefix == self_pk_upper) {
                // Self path
                Tox_Err_Group_Self_Query err_self;
                size_t name_sz = tox_group_self_get_name_size(tox, group_number, &err_self);
                std::string self_name;
                if (err_self == TOX_ERR_GROUP_SELF_QUERY_OK && name_sz > 0 && name_sz <= TOX_MAX_NAME_LENGTH) {
                    uint8_t name_buf[TOX_MAX_NAME_LENGTH + 1] = {};
                    if (tox_group_self_get_name(tox, group_number, name_buf, &err_self) &&
                        err_self == TOX_ERR_GROUP_SELF_QUERY_OK) {
                        self_name = std::string(reinterpret_cast<const char*>(name_buf), name_sz);
                    }
                }
                Tox_Err_Group_Self_Query err_role;
                Tox_Group_Role self_role = tox_group_self_get_role(tox, group_number, &err_role);
                // Note: branches must share a type — toxRoleToV2timRole returns
                // uint32_t while V2TIM_GROUP_MEMBER_ROLE_MEMBER is an enum, so
                // a `?:` would trip -Wextra (enumerated vs. non-enumerated).
                uint32_t v2tim_role = static_cast<uint32_t>(V2TIM_GROUP_MEMBER_ROLE_MEMBER);
                if (err_role == TOX_ERR_GROUP_SELF_QUERY_OK) {
                    v2tim_role = toxRoleToV2timRole(self_role);
                }

                V2TIMGroupMemberFullInfo memberInfo;
                memberInfo.userID = V2TIMString(requested_user_id_str.c_str());
                memberInfo.nameCard = self_name;
                memberInfo.nickName = self_name.empty() ? requested_user_id_str : self_name;
                memberInfo.role = v2tim_role;
                memberInfo.joinTime = static_cast<int64_t>(std::time(nullptr));

                V2TIM_LOG(kInfo, "[GetGroupMembersInfo] Returning SELF member - userID={}, nameCard={}, role={}",
                         memberInfo.userID.CString(), memberInfo.nameCard.CString(), memberInfo.role);

                resultList.PushBack(memberInfo);
                found = true;
                // fall through to next requested member
                continue;
            }
            // For NGCv2 groups, try peer iteration
            for (Tox_Group_Peer_Number peer_id = 0; peer_id < 1000; ++peer_id) {
                uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                Tox_Err_Group_Peer_Query err_key;
                bool got_key = GetToxManagerFromImpl(manager_impl_)->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key);

                if (!got_key || err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
                    continue;
                }

                peer_iteration_count++;
                std::string peer_userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);

                std::string peer_userID_upper = peer_userID;
                std::string requested_userID_upper = requested_user_id_str;
                std::transform(peer_userID_upper.begin(), peer_userID_upper.end(), peer_userID_upper.begin(), ::toupper);
                std::transform(requested_userID_upper.begin(), requested_userID_upper.end(), requested_userID_upper.begin(), ::toupper);

                if (peer_userID_upper == requested_userID_upper) {
                    V2TIM_LOG(kInfo, "[GetGroupMembersInfo] MATCH FOUND peer_id={} peer_userID={}", peer_id, peer_userID);

                    // Get peer name (buffer may not be NUL-terminated; use strnlen to avoid OOB read)
                    uint8_t name_buffer[TOX_MAX_NAME_LENGTH + 1] = {};
                    std::string peer_name;
                    Tox_Err_Group_Peer_Query err_name;
                    if (GetToxManagerFromImpl(manager_impl_)->getGroupPeerName(group_number, peer_id, name_buffer, TOX_MAX_NAME_LENGTH, &err_name) &&
                        err_name == TOX_ERR_GROUP_PEER_QUERY_OK) {
                        size_t name_len = strnlen(reinterpret_cast<const char*>(name_buffer), TOX_MAX_NAME_LENGTH);
                        peer_name = std::string(reinterpret_cast<const char*>(name_buffer), name_len);
                    }

                    // Honour any stored nameCard override for this peer (set
                    // via SetGroupMemberInfo before the peer was visible). The
                    // override is the source of truth for non-self peers since
                    // Tox doesn't propagate nameCard changes for them.
                    {
                        std::lock_guard<std::mutex> ov_lock(member_mutex_);
                        auto group_it = member_name_card_overrides_.find(group_id_str);
                        if (group_it != member_name_card_overrides_.end()) {
                            auto user_it = group_it->second.find(requested_user_id_str);
                            if (user_it != group_it->second.end() && !user_it->second.empty()) {
                                peer_name = user_it->second;
                            }
                        }
                    }

                    // Get peer role
                    Tox_Group_Role peer_role = tox_group_peer_get_role(tox, group_number, peer_id, &err_key);
                    uint32_t v2tim_role = toxRoleToV2timRole(peer_role);

                    V2TIMGroupMemberFullInfo memberInfo;
                    memberInfo.userID = V2TIMString(requested_user_id_str.c_str());
                    memberInfo.nameCard = peer_name;
                    memberInfo.nickName = peer_name.empty() ? requested_user_id_str : peer_name;
                    memberInfo.role = v2tim_role;
                    memberInfo.joinTime = static_cast<int64_t>(std::time(nullptr));

                    V2TIM_LOG(kInfo, "[GetGroupMembersInfo] Returning NGCv2 member - userID={}, nickName={}, role={}",
                             memberInfo.userID.CString(), memberInfo.nickName.CString(), memberInfo.role);

                    resultList.PushBack(memberInfo);
                    found = true;
                    break;
                }
            }
        }

        V2TIM_LOG(kInfo, "[GetGroupMembersInfo] Search completed requested_userID={} found={} peer_iteration_count={}", requested_user_id_str, found ? 1 : 0, peer_iteration_count);

        // DO NOT add fallback entries - if member not found, don't add anything
        if (!found) {
            V2TIM_LOG(kWarning, "[GetGroupMembersInfo] Member not found requested_userID={} groupID={} - NOT adding fallback entry",
                      requested_user_id_str, group_id_str);
        }
    }

    V2TIM_LOG(kInfo, "[GetGroupMembersInfo] EXIT groupID={} resultCount={}", group_id_str, resultList.Size());
    for (size_t i = 0; i < resultList.Size() && i < 5; ++i) {
        const V2TIMGroupMemberFullInfo& member = resultList[i];
        V2TIM_LOG(kInfo, "[GetGroupMembersInfo] result[{}]: userID={} nickName={} role={}", i, member.userID.CString(), member.nickName.CString(), member.role);
    }
    callback->OnSuccess(resultList);
}

void V2TIMGroupManagerImpl::SearchGroupMembers(const V2TIMGroupMemberSearchParam& param,
                                               V2TIMValueCallback<V2TIMGroupSearchGroupMembersMap>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::SearchCloudGroupMembers(const V2TIMGroupMemberSearchParam& param,
                                                    V2TIMValueCallback<V2TIMGroupMemberSearchResult>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::SetGroupMemberInfo(const V2TIMString& groupID,
                                            const V2TIMGroupMemberFullInfo& info,
                                            V2TIMCallback* callback) {
    // Get timestamp for detailed timing
    auto start_timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    
    // Note: GetCurrentInstanceId is defined in tim2tox_ffi.cpp as a C++ function
    extern int64_t GetCurrentInstanceId();
    int64_t current_instance_id = GetCurrentInstanceId();
    
    V2TIM_LOG(kInfo, "[SetGroupMemberInfo] ENTRY start_timestamp_ms={} instance_id={} groupID={} userID={}",
              start_timestamp_ms, current_instance_id, groupID.CString(), info.userID.CString());
    
    if (groupID.Empty() || info.userID.Empty()) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Group ID or user ID cannot be empty");
        }
        return;
    }
    
    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        if (callback) {
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        }
        return;
    }
    
    // Get group_number from groupID
    Tox_Group_Number group_number = UINT32_MAX;
    if (manager_impl_) {
        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
        auto it = manager_impl_->group_id_to_group_number_.find(groupID);
        if (it != manager_impl_->group_id_to_group_number_.end()) {
            group_number = it->second;
        }
    }
    
    if (group_number == UINT32_MAX) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Group not found");
        }
        return;
    }
    
    std::string userID_str = info.userID.CString();
    
    // If setting another user's nameCard: store in local override (no need for peer to be in list yet)
    if (!info.nameCard.Empty()) {
        std::string name_card = info.nameCard.CString();
        // Compare by public key (64 hex chars): Dart may pass 64-char public key; getAddress() returns 76-char address; compare case-insensitive
        uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, self_pubkey);
        std::string self_pk_hex = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
        std::string user_pk = (userID_str.length() >= 64) ? userID_str.substr(0, 64) : userID_str;
        std::string self_pk_lower = self_pk_hex;
        std::string user_pk_lower = user_pk;
        std::transform(self_pk_lower.begin(), self_pk_lower.end(), self_pk_lower.begin(), ::tolower);
        std::transform(user_pk_lower.begin(), user_pk_lower.end(), user_pk_lower.begin(), ::tolower);
        bool is_self = (self_pk_lower == user_pk_lower);
        if (!is_self) {
            std::lock_guard<std::mutex> lock(member_mutex_);
            member_name_card_overrides_[groupID.CString()][userID_str] = name_card;
            V2TIM_LOG(kInfo, "SetGroupMemberInfo: Stored nameCard override for user {} in group {}", info.userID.CString(), groupID.CString());
            if (callback) callback->OnSuccess();
            return;
        }
        // A conference has no per-group self name (tox_group_self_set_name is
        // NGC-only; a tagged key would only fail): refuse explicitly.
        if (IsConferenceMapKey(group_number)) {
            V2TIM_LOG(kWarning, "SetGroupMemberInfo: {} is a conference; a per-group self nameCard is not supported",
                      groupID.CString());
            if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Conferences do not support a per-group nameCard");
            return;
        }
        // Self nameCard: set via tox_group_self_set_name (no peer_id needed)
        Tox_Err_Group_Self_Name_Set error;
        bool success = tox_group_self_set_name(
            tox,
            group_number,
            reinterpret_cast<const uint8_t*>(name_card.c_str()),
            name_card.length(),
            &error
        );
        if (!success) {
            V2TIM_LOG(kError, "SetGroupMemberInfo: Failed to set self name, error: {}", error);
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to set self name");
            return;
        }
        V2TIM_LOG(kInfo, "SetGroupMemberInfo: Successfully set self name in group {}", groupID.CString());
        if (callback) callback->OnSuccess();
        return;
    }
    
    // Non-nameCard member info (e.g. role) is NGC-only: conferences have no
    // member roles, and the NGC peer lookup below must never see a tagged key.
    if (IsConferenceMapKey(group_number)) {
        V2TIM_LOG(kWarning, "SetGroupMemberInfo: {} is a conference; only another member's local nameCard is supported",
                  groupID.CString());
        if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Conferences do not support this member info");
        return;
    }

    // Non-nameCard path (e.g. role) or need peer_id for cache: get peer_id from userID
    uint8_t target_pubkey[TOX_PUBLIC_KEY_SIZE];
    if (!ToxUtil::tox_hex_to_bytes(userID_str.c_str(), userID_str.length(), target_pubkey, TOX_PUBLIC_KEY_SIZE)) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid user ID format");
        return;
    }
    
    Tox_Group_Peer_Number peer_id = UINT32_MAX;
    int peer_search_count = 0;
    for (Tox_Group_Peer_Number p = 0; p < 1000; ++p) {
        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Peer_Query err_key;
        if (GetToxManagerFromImpl(manager_impl_)->getGroupPeerPublicKey(group_number, p, peer_pubkey, &err_key) &&
            err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
            peer_search_count++;
            if (memcmp(peer_pubkey, target_pubkey, TOX_PUBLIC_KEY_SIZE) == 0) {
                peer_id = p;
                break;
            }
        } else {
            break;
        }
    }
    
    if (peer_id == UINT32_MAX) {
        V2TIM_LOG(kError, "SetGroupMemberInfo: User not found in group (searched {} peers)", peer_search_count);
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "User not found in group");
        return;
    }
    
    // Update local cache (for non-nameCard paths; nameCard paths already returned above)
    {
        std::lock_guard<std::mutex> lock(member_mutex_);
        auto it = group_members_.find(groupID.CString());
        if (it != group_members_.end()) {
            // Update member info in cache
            for (size_t i = 0; i < it->second.Size(); i++) {
                if (it->second[i].userID.CString() == userID_str) {
                    if (!info.nameCard.Empty()) {
                        // Note: V2TIMGroupMemberInfo doesn't have nameCard field,
                        // but we can update nickName as a workaround
                        // The full info will be updated when GetGroupMemberList is called
                    }
                    break;
                }
            }
        }
    }
    
    auto end_timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    auto total_duration_ms = end_timestamp_ms - start_timestamp_ms;
    
    V2TIM_LOG(kInfo, "[SetGroupMemberInfo] EXIT total_duration_ms={}", total_duration_ms);
    if (callback) callback->OnSuccess();
}

void V2TIMGroupManagerImpl::MuteGroupMember(const V2TIMString& groupID, const V2TIMString& userID,
                                        uint32_t seconds, V2TIMCallback* callback) {
    // NGC has no timed mute, but it has the OBSERVER role: an observer stays
    // in the group and can read, and toxcore refuses their sends (the
    // moderator's client enforces nothing — every peer drops an observer's
    // messages). That IS a mute. This used to report success while doing
    // nothing, so "Mute" in the member menu confirmed and the member kept
    // talking.
    //
    // V2TIM contract: seconds == 0 unmutes (OBSERVER back to USER); seconds > 0
    // mutes for that long. NGC has no expiry of its own, so the deadline is
    // recorded here (and persisted next to the profile) and
    // CheckMuteExpiries() lifts the OBSERVER role once it passes. Muting again
    // resets the deadline; kMutePermanentSeconds mutes with no expiry.
    V2TIM_LOG(kInfo, "MuteGroupMember: group={} user={} seconds={} -> role {}",
              groupID.CString(), userID.CString(), seconds, seconds > 0 ? "OBSERVER" : "USER");
    SetGroupMemberToxRole(groupID, userID,
                          seconds > 0 ? TOX_GROUP_ROLE_OBSERVER : TOX_GROUP_ROLE_USER,
                          callback, /*mute_toggle=*/true, seconds);
}

// ---------------------------------------------------------------------------
// Timed mute expiry
//
// Only the client that imposed a timed mute knows its deadline, so only it can
// lift the mute, and only while it is still a moderator/founder of the group.
// Lifting needs the member's live peer number: while the member is absent
// (left, offline, group not yet reconnected after a restart) the entry stays
// and is retried every kMuteRetryIntervalMs, because the OBSERVER sanction is
// keyed by their group key and would otherwise outlive the mute when they come
// back. An entry is dropped when the group is gone (quit/dismiss), when this
// client lost moderator rights, when tox_group_set_role refuses, or
// kMutePendingHorizonMs after the deadline.
//
// Persistence: <profile>.timed_mutes, one "groupID\tKEY\tdeadline_unix_ms" per
// line, rewritten on every change. A restart therefore keeps the deadline;
// time spent offline counts toward it, and an entry already past its deadline
// is lifted as soon as the group reconnects and the member is visible.
// ---------------------------------------------------------------------------

// Defined in ffi/tim2tox_ffi.cpp; the process-global virtual clock in ms.
extern "C" uint64_t tim2tox_virtual_time_cb(void* user_data);

namespace {
constexpr uint64_t kMuteRetryIntervalMs = 5000;
constexpr int64_t kMutePendingHorizonMs = 7LL * 24 * 60 * 60 * 1000;
constexpr size_t kMaxPersistedTimedMutes = 4096;

int64_t NowUnixMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

bool IsHexKey64(const std::string& s) {
    return s.size() == static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2) &&
           std::all_of(s.begin(), s.end(), [](unsigned char c) { return std::isxdigit(c) != 0; });
}
}  // namespace

uint64_t V2TIMGroupManagerImpl::NowMonoMs() const {
    // Same clock as V2TIMSignalingManagerImpl's invite timeouts: the shared
    // virtual clock in auto_tests (advanced by pumpTestTick), steady_clock
    // otherwise (immune to wall-clock adjustments).
    if (manager_impl_ && manager_impl_->isTestMode()) {
        return tim2tox_virtual_time_cb(nullptr);
    }
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

std::string V2TIMGroupManagerImpl::TimedMuteStorePath() const {
    if (!manager_impl_ || manager_impl_->save_path_.empty()) return std::string();
    return manager_impl_->save_path_ + ".timed_mutes";
}

void V2TIMGroupManagerImpl::EnsureTimedMutesLoadedLocked() {
    const std::string path = TimedMuteStorePath();
    if (path.empty() || path == timed_mutes_loaded_for_) return;
    if (!timed_mutes_loaded_for_.empty()) {
        // Another profile's entries: never act on them in this session.
        timed_mutes_.clear();
    }
    timed_mutes_loaded_for_ = path;
    std::ifstream in(path);
    if (!in) return;
    const int64_t now_unix = NowUnixMs();
    const uint64_t now_mono = NowMonoMs();
    std::string line;
    size_t loaded = 0;
    while (loaded < kMaxPersistedTimedMutes && std::getline(in, line)) {
        const size_t t1 = line.find('\t');
        const size_t t2 = t1 == std::string::npos ? std::string::npos : line.find('\t', t1 + 1);
        if (t1 == 0 || t2 == std::string::npos) continue;
        const std::string group_id = line.substr(0, t1);
        std::string key = line.substr(t1 + 1, t2 - t1 - 1);
        if (!IsHexKey64(key)) continue;
        std::transform(key.begin(), key.end(), key.begin(), ::toupper);
        int64_t deadline_unix = 0;
        try {
            deadline_unix = std::stoll(line.substr(t2 + 1));
        } catch (...) {
            continue;
        }
        auto& slot = timed_mutes_[group_id];
        if (slot.count(key)) continue;  // an in-session mute is newer
        TimedMute m;
        m.deadline_unix_ms = deadline_unix;
        m.deadline_mono_ms = now_mono + (deadline_unix > now_unix
                                             ? static_cast<uint64_t>(deadline_unix - now_unix)
                                             : 0);
        slot[key] = m;
        ++loaded;
    }
    V2TIM_LOG(kInfo, "[TimedMute] Loaded {} pending timed mute(s) from {}", loaded, path);
}

void V2TIMGroupManagerImpl::SaveTimedMutesLocked() {
    const std::string path = TimedMuteStorePath();
    if (path.empty()) return;
    std::error_code ec;
    size_t count = 0;
    for (const auto& g : timed_mutes_) count += g.second.size();
    if (count == 0) {
        std::filesystem::remove(path, ec);
        return;
    }
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::trunc);
        if (!out) {
            V2TIM_LOG(kWarning, "[TimedMute] Cannot write {}; pending expiries will not survive a restart", tmp);
            return;
        }
        for (const auto& g : timed_mutes_) {
            if (g.first.find_first_of("\t\r\n") != std::string::npos) continue;
            for (const auto& m : g.second) {
                out << g.first << '\t' << m.first << '\t' << m.second.deadline_unix_ms << '\n';
            }
        }
        out.flush();
        if (!out) {
            V2TIM_LOG(kWarning, "[TimedMute] Failed writing {}", tmp);
            return;
        }
    }
    std::filesystem::rename(tmp, path, ec);
    if (ec) {
        // Windows refuses to rename over an existing file.
        std::filesystem::remove(path, ec);
        std::filesystem::rename(tmp, path, ec);
    }
    if (ec) {
        V2TIM_LOG(kWarning, "[TimedMute] Failed replacing {}: {}", path, ec.message());
    }
}

void V2TIMGroupManagerImpl::RecordTimedMute(const std::string& groupID, const std::string& member_key_upper,
                                            uint32_t seconds) {
    std::lock_guard<std::mutex> lock(mute_mutex_);
    EnsureTimedMutesLoadedLocked();
    TimedMute m;
    m.deadline_mono_ms = NowMonoMs() + static_cast<uint64_t>(seconds) * 1000ULL;
    m.deadline_unix_ms = NowUnixMs() + static_cast<int64_t>(seconds) * 1000LL;
    timed_mutes_[groupID][member_key_upper] = m;  // re-mute resets the deadline
    SaveTimedMutesLocked();
    V2TIM_LOG(kInfo, "[TimedMute] group={} member={} muted for {}s", groupID, member_key_upper.substr(0, 16), seconds);
}

void V2TIMGroupManagerImpl::ForgetTimedMute(const std::string& groupID, const std::string& member_key_upper) {
    std::lock_guard<std::mutex> lock(mute_mutex_);
    EnsureTimedMutesLoadedLocked();
    auto g = timed_mutes_.find(groupID);
    if (g == timed_mutes_.end() || g->second.erase(member_key_upper) == 0) return;
    if (g->second.empty()) timed_mutes_.erase(g);
    SaveTimedMutesLocked();
}

void V2TIMGroupManagerImpl::CheckMuteExpiries() {
    struct Due {
        std::string group_id;
        std::string key;
        TimedMute snapshot;
    };
    std::vector<Due> due;
    const uint64_t now = NowMonoMs();
    {
        std::lock_guard<std::mutex> lock(mute_mutex_);
        EnsureTimedMutesLoadedLocked();
        if (timed_mutes_.empty()) return;
        for (const auto& g : timed_mutes_) {
            for (const auto& m : g.second) {
                if (now >= m.second.deadline_mono_ms && now >= m.second.next_attempt_mono_ms) {
                    due.push_back({g.first, m.first, m.second});
                }
            }
        }
    }
    if (due.empty()) return;

    // Tox work runs without mute_mutex_ held; the outcome is applied afterwards
    // only if the entry was not re-armed (re-mute / unmute) in the meantime.
    ToxManager* tm = GetToxManagerFromImpl(manager_impl_);
    Tox* tox = tm ? tm->getTox() : nullptr;
    const int64_t now_unix = NowUnixMs();
    std::vector<std::pair<Due, bool>> outcomes;  // bool: true = drop, false = retry later
    for (const Due& d : due) {
        const std::string tag = d.group_id + "/" + d.key.substr(0, 16);
        bool drop = true;
        Tox_Group_Number group_number = UINT32_MAX;
        if (!tox) {
            drop = false;  // not logged in (yet)
        } else if (now_unix - d.snapshot.deadline_unix_ms > kMutePendingHorizonMs) {
            V2TIM_LOG(kWarning, "[TimedMute] {}: member absent for too long after the deadline; giving up (they stay muted)", tag);
        } else if (!manager_impl_ || !manager_impl_->GetGroupNumberFromID(V2TIMString(d.group_id.c_str()), group_number) ||
                   IsConferenceMapKey(group_number)) {
            V2TIM_LOG(kInfo, "[TimedMute] {}: group no longer joined; dropping", tag);
        } else {
            Tox_Err_Group_Is_Connected err_conn;
            const bool connected = tox_group_is_connected(tox, group_number, &err_conn);
            Tox_Err_Group_Self_Query err_self;
            const Tox_Group_Role self_role = tm->getSelfRole(group_number, &err_self);
            if (err_conn != TOX_ERR_GROUP_IS_CONNECTED_OK || err_self != TOX_ERR_GROUP_SELF_QUERY_OK) {
                V2TIM_LOG(kInfo, "[TimedMute] {}: group {} not found in tox; dropping", tag, group_number);
            } else if (!connected) {
                drop = false;  // roles cannot be changed before the group reconnects
            } else if (self_role != TOX_GROUP_ROLE_FOUNDER && self_role != TOX_GROUP_ROLE_MODERATOR) {
                V2TIM_LOG(kWarning, "[TimedMute] {}: this client is no longer a moderator (role={}); cannot lift the mute",
                          tag, static_cast<int>(self_role));
            } else {
                const Tox_Group_Peer_Number peer_id = manager_impl_->ResolveGroupPeerIdForKey(group_number, d.key);
                Tox_Err_Group_Peer_Query err_role = TOX_ERR_GROUP_PEER_QUERY_PEER_NOT_FOUND;
                const Tox_Group_Role current = peer_id == UINT32_MAX
                    ? TOX_GROUP_ROLE_USER
                    : tm->getGroupMemberRole(group_number, peer_id, &err_role);
                if (peer_id == UINT32_MAX || err_role != TOX_ERR_GROUP_PEER_QUERY_OK) {
                    drop = false;  // member not in the group right now: lift when they are back
                } else if (current != TOX_GROUP_ROLE_OBSERVER) {
                    V2TIM_LOG(kInfo, "[TimedMute] {}: already role {}; nothing to lift", tag, static_cast<int>(current));
                } else {
                    Tox_Err_Group_Set_Role err_set;
                    if (tm->setGroupMemberRole(group_number, peer_id, TOX_GROUP_ROLE_USER, &err_set) &&
                        err_set == TOX_ERR_GROUP_SET_ROLE_OK) {
                        V2TIM_LOG(kInfo, "[TimedMute] {}: mute expired; restored USER (peer_id={})", tag, peer_id);
                    } else {
                        V2TIM_LOG(kError, "[TimedMute] {}: tox_group_set_role(USER) failed at expiry, err={}; dropping",
                                  tag, static_cast<int>(err_set));
                    }
                }
            }
        }
        outcomes.emplace_back(d, drop);
    }

    std::lock_guard<std::mutex> lock(mute_mutex_);
    bool changed = false;
    for (const auto& [d, drop] : outcomes) {
        auto g = timed_mutes_.find(d.group_id);
        if (g == timed_mutes_.end()) continue;
        auto m = g->second.find(d.key);
        if (m == g->second.end() || m->second.deadline_mono_ms != d.snapshot.deadline_mono_ms) continue;
        if (drop) {
            g->second.erase(m);
            if (g->second.empty()) timed_mutes_.erase(g);
            changed = true;
        } else {
            m->second.next_attempt_mono_ms = now + kMuteRetryIntervalMs;
        }
    }
    if (changed) SaveTimedMutesLocked();
}

void V2TIMGroupManagerImpl::MuteAllGroupMembers(const V2TIMString& groupID, bool isMute, V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::InviteUserToGroup(
    const V2TIMString& groupID, const V2TIMStringVector& userList,
    V2TIMValueCallback<V2TIMGroupMemberOperationResultVector>* callback) {
    V2TIM_LOG(kInfo, "[InviteUserToGroup] ENTRY groupID={} userList.Size()={}", groupID.CString() ? groupID.CString() : "null", userList.Size());
    
    // CRITICAL: Extract groupID C-string immediately to avoid lifetime issues
    std::string group_id_str;
    try {
        const char* group_id_cstr = groupID.CString();
        if (group_id_cstr) {
            group_id_str = std::string(group_id_cstr);
        }
    } catch (...) {
        V2TIM_LOG(kError, "[InviteUserToGroup] Failed to extract groupID");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid group ID");
        return;
    }
    
    // CRITICAL: Copy userList immediately to avoid lifetime issues
    std::vector<std::string> user_id_strings;  // Store C-strings safely
    try {
        for (size_t i = 0; i < userList.Size(); i++) {
            try {
                const V2TIMString& userID = userList[i];
                const char* user_id_cstr = nullptr;
                size_t user_id_len = 0;
                try {
                    user_id_len = userID.Length();
                    user_id_cstr = userID.CString();
                } catch (...) {
                    continue;
                }
                if (!user_id_cstr || user_id_len == 0) {
                    continue;
                }
                user_id_strings.push_back(std::string(user_id_cstr, user_id_len));
            } catch (...) {
                continue;
            }
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to copy user ID list");
        return;
    }
    
    V2TIM_LOG(kInfo, "InviteUserToGroup: inviting {} users to group {}", user_id_strings.size(), group_id_str);
    // [tim2tox-debug] Record invite parameters for V2TIMGroupManagerImpl::InviteUserToGroup
    V2TIM_LOG(kInfo, "[tim2tox-debug] InviteUserToGroup: Parameters - groupID={}, userCount={}", 
             group_id_str.c_str(), user_id_strings.size());
    for (size_t i = 0; i < user_id_strings.size() && i < 5; ++i) { // Log first 5 users
        V2TIM_LOG(kInfo, "[tim2tox-debug] InviteUserToGroup: user[{}]={}", i, user_id_strings[i].substr(0, 20).c_str());
    }
    
    if (!callback) {
        V2TIM_LOG(kError, "InviteUserToGroup: callback is null");
        return;
    }
    
    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "InviteUserToGroup: Tox instance not available for group {}", group_id_str);
        callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
        return;
    }
    
    // Get group_number from groupID
    Tox_Group_Number group_number = UINT32_MAX;
    bool has_stored_chat_id = false;  // Initialize here so it's available in the entire function
    
    if (manager_impl_) {
        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
        auto it = manager_impl_->group_id_to_group_number_.find(V2TIMString(group_id_str.c_str()));
        if (it != manager_impl_->group_id_to_group_number_.end()) {
            group_number = it->second;
            V2TIM_LOG(kInfo, "InviteUserToGroup: Found group {} with group_number={}", group_id_str, group_number);
        }
    }
    
    // Fallback to local groups_ map
    if (group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = groups_.find(group_id_str);
        if (it != groups_.end()) {
            group_number = it->second;
            V2TIM_LOG(kInfo, "InviteUserToGroup: Found group {} with group_number={} from local map", group_id_str, group_number);
        } else {
            V2TIM_LOG(kWarning, "InviteUserToGroup: Group {} not found in groups_ map. Total groups: {}", group_id_str, groups_.size());
        }
    }
    
    // Recovery mechanism: rebuild the mapping if not found, resolving the stored
    // identity by its stored KIND (a conference identity never as an NGC chat id).
    if (group_number == UINT32_MAX && manager_impl_) {
        V2TIM_LOG(kInfo, "InviteUserToGroup: Group {} not found in mappings, attempting recovery", group_id_str);
        group_number = manager_impl_->RecoverGroupMapping(
            group_id_str, /*allow_unmapped_ngc_bind=*/true, &has_stored_chat_id);
    }
    
    if (group_number == UINT32_MAX) {
        // Provide more detailed error message
        std::string error_msg = "Group " + group_id_str + " not found in Tox";
        if (has_stored_chat_id) {
            error_msg += " (stored chat_id exists but group not restored yet)";
        } else {
            error_msg += " (no stored chat_id)";
        }
        size_t group_count = GetToxManagerFromImpl(manager_impl_)->getGroupListSize();
        error_msg += ". Total groups in Tox: " + std::to_string(group_count);
        
        V2TIM_LOG(kError, "[InviteUserToGroup] {}", error_msg);
        callback->OnError(ERR_INVALID_PARAMETERS, error_msg.c_str());
        return;
    }
    
    V2TIMGroupMemberOperationResultVector resultList;
    
    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    for (size_t i = 0; i < user_id_strings.size(); i++) {
        const std::string& user_id_str = user_id_strings[i];
        V2TIM_LOG(kInfo, "[InviteUserToGroup] Processing user {}/{}: {}", i+1, user_id_strings.size(), user_id_str);

        uint32_t friend_number = GetFriendNumber(user_id_str.c_str());

        if (friend_number == UINT32_MAX) {
            V2TIM_LOG(kError, "[InviteUserToGroup] Failed to get friend number for user {} (length={})", user_id_str, user_id_str.length());
            V2TIMGroupMemberOperationResult result;
            // Create new V2TIMString directly from the safe std::string
            result.userID = V2TIMString(user_id_str.c_str());
            result.result = V2TIM_GROUP_MEMBER_RESULT_FAIL;
            resultList.PushBack(result);
            continue;
        }
        
        V2TIM_LOG(kInfo, "[InviteUserToGroup] Got friend_number={} for user {}, inviting to group_number={}", friend_number, user_id_str, group_number);

        Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
        if (tox) {
            TOX_CONNECTION friend_conn = tox_friend_get_connection_status(tox, friend_number, nullptr);
            V2TIM_LOG(kInfo, "[InviteUserToGroup] Friend {} connection status: {} (0=NONE,1=UDP,2=TCP)", friend_number, static_cast<int>(friend_conn));
            if (friend_conn == TOX_CONNECTION_NONE) {
                V2TIM_LOG(kWarning, "[InviteUserToGroup] Friend {} not connected, invite may fail", friend_number);
            }
        }
        
        // Determine if this is a conference (old API) or group (new API)
        // Conferences need tox_conference_invite; groups need tox_group_invite_friend
        // The map key is authoritative (see ConferenceMapKey): a type label
        // alone could send a conference invite for an NGC group's number.
        const bool is_conference_group = IsConferenceMapKey(group_number);

        V2TIMGroupMemberOperationResult result;
        // Create new V2TIMString directly from the safe std::string
        result.userID = V2TIMString(user_id_str.c_str());

        if (is_conference_group) {
            // Conference (old API): use tox_conference_invite
            V2TIM_LOG(kInfo, "[tim2tox-debug] InviteUserToGroup: Group {} is conference type, using tox_conference_invite", group_id_str);
            V2TIM_LOG(kInfo, "[InviteUserToGroup] Group {} is conference, using tox_conference_invite group_number={} friend_number={}", group_id_str, group_number, friend_number);

            TOX_ERR_CONFERENCE_INVITE conf_error;
            bool success = GetToxManagerFromImpl(manager_impl_)->inviteToConference(friend_number, group_number, &conf_error);

            if (success && conf_error == TOX_ERR_CONFERENCE_INVITE_OK) {
                V2TIM_LOG(kInfo, "[InviteUserToGroup] Successfully invited user {} to conference {} (conference_number={})", user_id_str, group_id_str, group_number);
                result.result = V2TIM_GROUP_MEMBER_RESULT_SUCC;
            } else {
                const char* errorStr = "UNKNOWN";
                switch (conf_error) {
                    case TOX_ERR_CONFERENCE_INVITE_OK: errorStr = "OK"; break;
                    case TOX_ERR_CONFERENCE_INVITE_CONFERENCE_NOT_FOUND: errorStr = "CONFERENCE_NOT_FOUND"; break;
                    case TOX_ERR_CONFERENCE_INVITE_FAIL_SEND: errorStr = "FAIL_SEND"; break;
                    case TOX_ERR_CONFERENCE_INVITE_NO_CONNECTION: errorStr = "NO_CONNECTION"; break;
                    default: break;
                }
                V2TIM_LOG(kError, "[InviteUserToGroup] Failed to invite user {} to conference {}. success={} error={} ({})",
                         user_id_str, group_id_str, success, static_cast<int>(conf_error), errorStr);
                result.result = V2TIM_GROUP_MEMBER_RESULT_FAIL;
            }
        } else {
            Tox_Err_Group_Invite_Friend error;
            bool success = GetToxManagerFromImpl(manager_impl_)->inviteToGroup(group_number, friend_number, &error);

            if (success && error == TOX_ERR_GROUP_INVITE_FRIEND_OK) {
                V2TIM_LOG(kInfo, "[InviteUserToGroup] Successfully invited user {} (friend_number={}) to group {} (group_number={})", user_id_str, friend_number, group_id_str, group_number);
                result.result = V2TIM_GROUP_MEMBER_RESULT_SUCC;
            } else {
                const char* errorStr = "UNKNOWN";
                switch (error) {
                    case TOX_ERR_GROUP_INVITE_FRIEND_OK: errorStr = "OK"; break;
                    case TOX_ERR_GROUP_INVITE_FRIEND_GROUP_NOT_FOUND: errorStr = "GROUP_NOT_FOUND"; break;
                    case TOX_ERR_GROUP_INVITE_FRIEND_FRIEND_NOT_FOUND: errorStr = "FRIEND_NOT_FOUND"; break;
                    case TOX_ERR_GROUP_INVITE_FRIEND_INVITE_FAIL: errorStr = "INVITE_FAIL"; break;
                    default: break;
                }
                V2TIM_LOG(kError, "[InviteUserToGroup] Failed to invite user {} to group {}. success={} error={} ({})",
                         user_id_str, group_id_str, success, error, errorStr);
                result.result = V2TIM_GROUP_MEMBER_RESULT_FAIL;
            }
        }

        V2TIM_LOG(kInfo, "[InviteUserToGroup] Result: userID={} result={}", result.userID.CString(), result.result);
        resultList.PushBack(result);
    }

    V2TIM_LOG(kInfo, "[InviteUserToGroup] Completed Total results: {}", resultList.Size());
    for (size_t i = 0; i < resultList.Size(); i++) {
        const V2TIMGroupMemberOperationResult& r = resultList[i];
        V2TIM_LOG(kInfo, "[InviteUserToGroup] Result[{}]: userID={} result={}", i, r.userID.CString(), r.result);
    }
    callback->OnSuccess(resultList);
}

void V2TIMGroupManagerImpl::KickGroupMember(
    const V2TIMString& groupID, const V2TIMStringVector& memberList,
    const V2TIMString& reason, V2TIMValueCallback<V2TIMGroupMemberOperationResultVector>* callback) {
    // CRITICAL: Extract groupID C-string immediately to avoid lifetime issues
    std::string group_id_str;
    try {
        const char* group_id_cstr = groupID.CString();
        if (group_id_cstr) {
            group_id_str = std::string(group_id_cstr);
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid group ID");
        return;
    }
    
    V2TIM_LOG(kInfo, "KickGroupMember: starting for group {}", group_id_str);
    
    // CRITICAL: Copy memberList immediately to avoid lifetime issues
    std::vector<std::string> member_id_strings;  // Store C-strings safely
    try {
        for (size_t i = 0; i < memberList.Size(); i++) {
            try {
                const V2TIMString& userID = memberList[i];
                const char* user_id_cstr = nullptr;
                size_t user_id_len = 0;
                try {
                    user_id_len = userID.Length();
                    user_id_cstr = userID.CString();
                } catch (...) {
                    continue;
                }
                if (!user_id_cstr || user_id_len == 0) {
                    continue;
                }
                member_id_strings.push_back(std::string(user_id_cstr, user_id_len));
            } catch (...) {
                continue;
            }
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to copy member ID list");
        return;
    }
    
    // Get group_number from groupID
    Tox_Group_Number group_number = UINT32_MAX;
    if (manager_impl_) {
        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
        auto it = manager_impl_->group_id_to_group_number_.find(V2TIMString(group_id_str.c_str()));
        if (it != manager_impl_->group_id_to_group_number_.end()) {
            group_number = it->second;
        }
    }
    
    // Fallback to local groups_ map
    if (group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = groups_.find(group_id_str);
        if (it != groups_.end()) {
            group_number = it->second;
        }
    }
    
    if (group_number == UINT32_MAX) {
        V2TIM_LOG(kError, "KickGroupMember: Group {} not found", group_id_str);
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group not found");
        return;
    }

    // Legacy conferences have no moderation. Their numbers share the integer
    // space of NGC group numbers, so falling through would hand a CONFERENCE
    // number to tox_group_kick_peer and kick someone out of an unrelated NGC
    // group that happens to own the same number.
    //
    // The KIND comes from the map key alone, as everywhere else here: a stale
    // "conference" type label on an untagged (NGC) key must not refuse a real
    // NGC kick with 7013.
    if (IsConferenceMapKey(group_number)) {
        V2TIM_LOG(kWarning, "KickGroupMember: group {} is a conference; kicking is not supported", group_id_str);
        if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Conferences do not support removing members");
        return;
    }
    
    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "KickGroupMember: Tox instance not available");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
        return;
    }
    
    V2TIMGroupMemberOperationResultVector resultList;
    V2TIMGroupMemberInfoVector kickedMembers; // For listener notification
    std::unordered_set<std::string> kicked_ids; // userIDs actually removed
    bool permission_denied = false;
    
    // Kick members using tox_group_kick_peer
    for (const auto& user_id_str : member_id_strings) {
        V2TIM_LOG(kInfo, "KickGroupMember: kicking member {} from group {}", user_id_str, group_id_str);
        
        // Find peer_id by userID (public key)
        uint8_t target_pubkey[TOX_PUBLIC_KEY_SIZE];
        if (!ToxUtil::tox_hex_to_bytes(user_id_str.c_str(), user_id_str.length(), target_pubkey, TOX_PUBLIC_KEY_SIZE)) {
            V2TIM_LOG(kError, "KickGroupMember: Failed to convert userID {} to public key", user_id_str);
            V2TIMGroupMemberOperationResult result;
            result.userID = V2TIMString(user_id_str.c_str());
            result.result = V2TIM_GROUP_MEMBER_RESULT_FAIL;
            resultList.PushBack(result);
            continue;
        }
        
        // Find peer_id by public key. PRIMARY source is the callback-populated
        // group_peer_id_cache_ (the SAME map GetGroupMemberList uses): the
        // founder learns a joiner's (pubkey -> peer_id) only via the
        // HandleGroupPeerJoin callback that fires as the Tox loop iterates.
        // Sequential 0..N probing is an unreliable fallback. (S37 fix.)
        Tox_Group_Peer_Number target_peer_id = UINT32_MAX;
        {
            std::string key_lower = user_id_str;
            std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(),
                           [](unsigned char c) { return std::tolower(c); });
            std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
            auto cache_it = manager_impl_->group_peer_id_cache_.find(group_number);
            if (cache_it != manager_impl_->group_peer_id_cache_.end()) {
                auto peer_it = cache_it->second.find(key_lower);
                if (peer_it != cache_it->second.end()) {
                    target_peer_id = peer_it->second;
                    V2TIM_LOG(kInfo, "KickGroupMember: resolved peer_id={} from cache for userID {}", target_peer_id, user_id_str);
                }
            }
        }
        if (target_peer_id != UINT32_MAX) {
            // toxcore re-issues the lowest free peer_id, so a cached id is only
            // trustworthy if that id STILL belongs to the requested key. Acting
            // on a stale entry would kick whoever inherited the number.
            uint8_t current_pubkey[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_Peer_Query err_current;
            if (!GetToxManagerFromImpl(manager_impl_)->getGroupPeerPublicKey(group_number, target_peer_id, current_pubkey, &err_current) ||
                err_current != TOX_ERR_GROUP_PEER_QUERY_OK ||
                memcmp(current_pubkey, target_pubkey, TOX_PUBLIC_KEY_SIZE) != 0) {
                V2TIM_LOG(kWarning, "KickGroupMember: cached peer_id={} no longer belongs to userID {}; dropping stale cache entry",
                          target_peer_id, user_id_str);
                manager_impl_->ErasePeerIdCacheEntry(group_number, user_id_str);
                target_peer_id = UINT32_MAX;
            }
        }
        if (target_peer_id == UINT32_MAX) {
            for (Tox_Group_Peer_Number peer_id = 0; peer_id < 1000; ++peer_id) {
                uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                Tox_Err_Group_Peer_Query err_key;
                if (GetToxManagerFromImpl(manager_impl_)->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) &&
                    err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
                    if (memcmp(peer_pubkey, target_pubkey, TOX_PUBLIC_KEY_SIZE) == 0) {
                        target_peer_id = peer_id;
                        break;
                    }
                }
            }
        }
        
        V2TIMGroupMemberOperationResult result;
        result.userID = V2TIMString(user_id_str.c_str());
        
        if (target_peer_id == UINT32_MAX) {
            V2TIM_LOG(kError, "KickGroupMember: Peer not found for userID {}", user_id_str);
            result.result = V2TIM_GROUP_MEMBER_RESULT_FAIL;
        } else {
            // Kick peer using tox_group_kick_peer
            Tox_Err_Group_Kick_Peer err_kick;
            bool success = GetToxManagerFromImpl(manager_impl_)->kickGroupMember(group_number, target_peer_id, &err_kick);
            
            if (success && err_kick == TOX_ERR_GROUP_KICK_PEER_OK) {
                V2TIM_LOG(kInfo, "KickGroupMember: Successfully kicked member {} (peer_id={}) from group {}",
                         user_id_str, target_peer_id, group_id_str);
                result.result = V2TIM_GROUP_MEMBER_RESULT_SUCC;
                
                // Add to kicked members list for notification
                V2TIMGroupMemberInfo memberInfo;
                memberInfo.userID = V2TIMString(user_id_str.c_str());
                kickedMembers.PushBack(memberInfo);
                kicked_ids.insert(user_id_str);
                // toxcore deletes a peer WE kicked with GC_EXIT_TYPE_NO_CALLBACK:
                // no peer_exit reaches HandleGroupPeerExit on the kicker, so the
                // cache entry has to be dropped here.
                manager_impl_->ErasePeerIdCacheEntry(group_number, user_id_str);
            } else {
                V2TIM_LOG(kError, "KickGroupMember: Failed to kick member {}, error: {}", user_id_str, err_kick);
                result.result = V2TIM_GROUP_MEMBER_RESULT_FAIL;
                if (err_kick == TOX_ERR_GROUP_KICK_PEER_PERMISSIONS) {
                    permission_denied = true;
                }
            }
        }
        
        resultList.PushBack(result);
    }
    
    // Remove from local group member list
    {
        std::lock_guard<std::mutex> lock(member_mutex_);
        auto it = group_members_.find(group_id_str);
        if (it != group_members_.end()) {
            V2TIMGroupMemberInfoVector& members = it->second;
            V2TIMGroupMemberInfoVector newMembers;
            for (size_t j = 0; j < members.Size(); j++) {
                const char* member_user_id_cstr = members[j].userID.CString();
                const bool should_remove = member_user_id_cstr &&
                    kicked_ids.find(std::string(member_user_id_cstr)) != kicked_ids.end();
                if (!should_remove) {
                    newMembers.PushBack(members[j]);
                }
            }
            members = newMembers;
        }
    }

    // Nothing was removed: report it as a failure. The Dart adapter collapses
    // the per-member result list to a bare code, and the member list UI drops
    // the row on code 0 — so "success with every entry FAIL" showed a removal
    // that never happened.
    if (kickedMembers.Size() == 0 && !member_id_strings.empty()) {
        if (callback) {
            if (permission_denied) {
                callback->OnError(kErrSvrGroupPermissionDeny, "No permission to remove group members");
            } else {
                callback->OnError(ERR_INVALID_PARAMETERS, "Failed to remove group members");
            }
        }
        return;
    }

    // Notify listeners, then complete — exactly once each. (Both used to be
    // duplicated: every kick produced two KICK tips and a second OnSuccess.)
    if (manager_impl_ && kickedMembers.Size() > 0) {
        manager_impl_->NotifyGroupMemberKicked(V2TIMString(group_id_str.c_str()), kickedMembers);
    }

    if (callback) callback->OnSuccess(resultList);
}

void V2TIMGroupManagerImpl::KickGroupMember(
    const V2TIMString& groupID, const V2TIMStringVector& memberList,
    const V2TIMString& reason, uint32_t duration,
    V2TIMValueCallback<V2TIMGroupMemberOperationResultVector>* callback) {
    V2TIM_LOG(kInfo, "KickGroupMember (with duration {}): starting for group {}", duration, groupID.CString());
    
    // Just call the regular version
    KickGroupMember(groupID, memberList, reason, callback);
}

void V2TIMGroupManagerImpl::SetGroupMemberRole(
    const V2TIMString& groupID, const V2TIMString& userID, uint32_t role,
    V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "SetGroupMemberRole: setting role {} for member {} in group {}", role, userID.CString(), groupID.CString());
    SetGroupMemberToxRole(groupID, userID, v2timRoleToToxRole(role), callback);
}

void V2TIMGroupManagerImpl::SetGroupMemberToxRole(
    const V2TIMString& groupID, const V2TIMString& userID, Tox_Group_Role tox_role,
    V2TIMCallback* callback, bool mute_toggle, uint32_t mute_seconds) {
    const uint32_t role = static_cast<uint32_t>(tox_role); // for the existing log lines
    
    if (!callback) {
        V2TIM_LOG(kWarning, "SetGroupMemberRole: callback is null");
        return;
    }
    
    // Get group_number from groupID
    Tox_Group_Number group_number = UINT32_MAX;
    if (manager_impl_) {
        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
        auto it = manager_impl_->group_id_to_group_number_.find(groupID);
        if (it != manager_impl_->group_id_to_group_number_.end()) {
            group_number = it->second;
        }
    }
    
    // Fallback to local groups_ map
    if (group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = groups_.find(groupID.CString());
        if (it != groups_.end()) {
            group_number = it->second;
        }
    }
    
    if (group_number == UINT32_MAX) {
        V2TIM_LOG(kError, "SetGroupMemberRole: Group {} not found", groupID.CString());
        callback->OnError(ERR_INVALID_PARAMETERS, "Group not found");
        return;
    }
    
    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "SetGroupMemberRole: Tox instance not available");
        callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
        return;
    }
    
    // Normalize userID: trim whitespace, use for comparison (match GetGroupMembersInfo behaviour)
    std::string user_id_str = userID.CString();
    auto trim = [](std::string& s) {
        s.erase(s.begin(), std::find_if(s.begin(), s.end(), [](unsigned char c) { return !std::isspace(c); }));
        s.erase(std::find_if(s.rbegin(), s.rend(), [](unsigned char c) { return !std::isspace(c); }).base(), s.end());
    };
    trim(user_id_str);
    if (user_id_str.length() != TOX_PUBLIC_KEY_SIZE * 2) {
        V2TIM_LOG(kError, "SetGroupMemberRole: userID length {} invalid (expected {} hex chars)", user_id_str.length(), static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2));
        callback->OnError(ERR_INVALID_PARAMETERS, "Invalid userID length");
        return;
    }
    std::string user_id_upper = user_id_str;
    std::transform(user_id_upper.begin(), user_id_upper.end(), user_id_upper.begin(), ::toupper);
    
    // Legacy conferences have no roles; their numbers share the NGC number
    // space, so probing tox_group_* with a conference number would act on an
    // unrelated NGC group.
    // The map key decides the kind (see ConferenceMapKey), not a type label.
    if (IsConferenceMapKey(group_number)) {
        callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Conferences have no member roles");
        return;
    }

    // Find peer_id by public key. PRIMARY source: the callback-populated cache
    // (validated against the peer's CURRENT key — toxcore re-issues ids).
    Tox_Group_Peer_Number target_peer_id = UINT32_MAX;
    {
        std::string key_lower = user_id_str.substr(0, std::min<size_t>(64, user_id_str.size()));
        std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        Tox_Group_Peer_Number cached = UINT32_MAX;
        {
            std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
            auto cache_it = manager_impl_->group_peer_id_cache_.find(group_number);
            if (cache_it != manager_impl_->group_peer_id_cache_.end()) {
                auto peer_it = cache_it->second.find(key_lower);
                if (peer_it != cache_it->second.end()) cached = peer_it->second;
            }
        }
        if (cached != UINT32_MAX) {
            uint8_t current_pubkey[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_Peer_Query err_current;
            if (GetToxManagerFromImpl(manager_impl_)->getGroupPeerPublicKey(group_number, cached, current_pubkey, &err_current) &&
                err_current == TOX_ERR_GROUP_PEER_QUERY_OK) {
                std::string current_upper = ToxUtil::tox_bytes_to_hex(current_pubkey, TOX_PUBLIC_KEY_SIZE);
                if (current_upper.substr(0, std::min(current_upper.size(), user_id_upper.size())) == user_id_upper) {
                    target_peer_id = cached;
                }
            }
            if (target_peer_id == UINT32_MAX) {
                manager_impl_->ErasePeerIdCacheEntry(group_number, key_lower);
            }
        }
    }

    // Fallback: probe peer ids. The sleep-and-retry exists for auto_tests with
    // no event thread (nothing else advances the peer list). In the product
    // this runs on the Flutter UI thread — retrying there froze the UI for
    // 2.4 s whenever the target could not be resolved (already gone, stale
    // row) before the error came back.
    const bool retry_with_sleep = manager_impl_->test_mode_.load(std::memory_order_acquire) ||
                                  !manager_impl_->IsEventThreadRunning();
    const int kRetryAttempts = retry_with_sleep ? 5 : 1;
    constexpr int kRetryDelayMs = 600;
    for (int attempt = 0; attempt < kRetryAttempts && target_peer_id == UINT32_MAX; ++attempt) {
        if (attempt > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(kRetryDelayMs));
            V2TIM_LOG(kInfo, "SetGroupMemberRole: Retry attempt {}/{} for userID {}", attempt + 1, kRetryAttempts, user_id_str);
        }
        int consecutive_errors = 0;
        constexpr Tox_Group_Peer_Number kMaxPeerId = 500;
        constexpr int kMaxConsecutiveErrors = 100;
        for (Tox_Group_Peer_Number peer_id = 0; peer_id < kMaxPeerId; ++peer_id) {
            uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_Peer_Query err_key;
            if (!GetToxManagerFromImpl(manager_impl_)->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
                err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
                consecutive_errors++;
                if (consecutive_errors >= kMaxConsecutiveErrors) {
                    V2TIM_LOG(kInfo, "SetGroupMemberRole: Stopping peer iteration after {} consecutive errors (last peer_id={})",
                              consecutive_errors, peer_id);
                    break;
                }
                continue;
            }
            consecutive_errors = 0;
            std::string peer_hex = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
            std::string peer_hex_upper = peer_hex;
            std::transform(peer_hex_upper.begin(), peer_hex_upper.end(), peer_hex_upper.begin(), ::toupper);
            if (peer_hex_upper == user_id_upper ||
                (peer_hex.size() >= user_id_str.size() && peer_hex_upper.substr(0, user_id_str.size()) == user_id_upper)) {
                target_peer_id = peer_id;
                break;
            }
        }
    }
    
    if (target_peer_id == UINT32_MAX) {
        V2TIM_LOG(kError, "SetGroupMemberRole: Peer not found for userID {} (group_number={}) after {} attempts", user_id_str, group_number, kRetryAttempts);
        callback->OnError(ERR_INVALID_PARAMETERS, "Member not found in group");
        return;
    }
    
    // Timed-mute bookkeeping once the role is in place: a finite mute (re)arms
    // the expiry, anything else (unmute, permanent mute, explicit role change)
    // cancels a pending one so it cannot later undo the newer decision.
    const std::string group_id_key = groupID.CString();
    auto update_timed_mute = [&]() {
        if (mute_toggle && tox_role == TOX_GROUP_ROLE_OBSERVER && mute_seconds != kMutePermanentSeconds) {
            RecordTimedMute(group_id_key, user_id_upper, mute_seconds);
        } else {
            ForgetTimedMute(group_id_key, user_id_upper);
        }
    };

    if (mute_toggle) {
        // Mute = OBSERVER. Muting a moderator (or the founder) would demote
        // them, and a later unmute to USER could never give the role back, so
        // it is refused; and unmute only lifts an OBSERVER, never demotes.
        Tox_Err_Group_Peer_Query err_role;
        const Tox_Group_Role current = tox_group_peer_get_role(tox, group_number, target_peer_id, &err_role);
        if (err_role != TOX_ERR_GROUP_PEER_QUERY_OK) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Member not found in group");
            return;
        }
        if (tox_role == TOX_GROUP_ROLE_OBSERVER &&
            (current == TOX_GROUP_ROLE_FOUNDER || current == TOX_GROUP_ROLE_MODERATOR)) {
            callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Moderators cannot be muted");
            return;
        }
        if (tox_role == TOX_GROUP_ROLE_USER && current != TOX_GROUP_ROLE_OBSERVER) {
            update_timed_mute();
            callback->OnSuccess();  // not muted: nothing to lift
            return;
        }
        if (tox_role == TOX_GROUP_ROLE_OBSERVER && current == TOX_GROUP_ROLE_OBSERVER) {
            // Already muted: toxcore rejects a same-role assignment, but a
            // re-mute is how V2TIM changes the duration. Just re-arm it —
            // provided this client could have muted them at all, since only
            // a moderator can lift the mute when it expires.
            Tox_Err_Group_Self_Query err_self;
            const Tox_Group_Role self_role =
                GetToxManagerFromImpl(manager_impl_)->getSelfRole(group_number, &err_self);
            if (err_self != TOX_ERR_GROUP_SELF_QUERY_OK ||
                (self_role != TOX_GROUP_ROLE_FOUNDER && self_role != TOX_GROUP_ROLE_MODERATOR)) {
                callback->OnError(kErrSvrGroupPermissionDeny, "Only moderators can mute members");
                return;
            }
            update_timed_mute();
            callback->OnSuccess();
            return;
        }
    }

    // Set role using tox_group_set_role
    Tox_Err_Group_Set_Role err_set_role;
    bool success = GetToxManagerFromImpl(manager_impl_)->setGroupMemberRole(group_number, target_peer_id, tox_role, &err_set_role);

    if (success && err_set_role == TOX_ERR_GROUP_SET_ROLE_OK) {
        V2TIM_LOG(kInfo, "SetGroupMemberRole: Successfully set role {} for member {} (peer_id={}) in group {}",
                 role, user_id_str, target_peer_id, groupID.CString());
        update_timed_mute();
        callback->OnSuccess();
    } else {
        V2TIM_LOG(kError, "SetGroupMemberRole: Failed to set role, error: {}", err_set_role);
        // Keep toxcore's reasons apart: a role refusal (a member / moderator
        // acting above its role, or any change to the founder) is what the UI
        // explains as "no permission"; the rest stay generic failures, each
        // with its own desc.
        switch (err_set_role) {
            case TOX_ERR_GROUP_SET_ROLE_PERMISSIONS:
                callback->OnError(kErrSvrGroupPermissionDeny, "No permission to change this member's role");
                break;
            case TOX_ERR_GROUP_SET_ROLE_PEER_NOT_FOUND:
                callback->OnError(ERR_INVALID_PARAMETERS, "Member not found in group");
                break;
            case TOX_ERR_GROUP_SET_ROLE_GROUP_NOT_FOUND:
                callback->OnError(ERR_INVALID_PARAMETERS, "Group not found");
                break;
            case TOX_ERR_GROUP_SET_ROLE_ASSIGNMENT:
                // Same role again, or FOUNDER as the target role.
                callback->OnError(ERR_INVALID_PARAMETERS, "Invalid role assignment");
                break;
            case TOX_ERR_GROUP_SET_ROLE_SELF:
                callback->OnError(ERR_INVALID_PARAMETERS, "Cannot change your own role");
                break;
            default:
                callback->OnError(ERR_INVALID_PARAMETERS, "Failed to set member role");
                break;
        }
    }
}

void V2TIMGroupManagerImpl::MarkGroupMemberList(const V2TIMString& groupID, const V2TIMStringVector& memberList,
                                                uint32_t markType, bool enableMark, V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::TransferGroupOwner(const V2TIMString& groupID, const V2TIMString& userID,
                                             V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "TransferGroupOwner: transferring ownership of group {} to {}", groupID.CString(), userID.CString());
    
    if (!callback) {
        V2TIM_LOG(kWarning, "TransferGroupOwner: callback is null");
        return;
    }
    
    // Get group_number from groupID
    Tox_Group_Number group_number = UINT32_MAX;
    if (manager_impl_) {
        std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
        auto it = manager_impl_->group_id_to_group_number_.find(groupID);
        if (it != manager_impl_->group_id_to_group_number_.end()) {
            group_number = it->second;
        }
    }
    
    // Fallback to local groups_ map
    if (group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        auto it = groups_.find(groupID.CString());
        if (it != groups_.end()) {
            group_number = it->second;
        }
    }
    
    if (group_number == UINT32_MAX) {
        V2TIM_LOG(kError, "TransferGroupOwner: Group {} not found", groupID.CString());
        callback->OnError(ERR_INVALID_PARAMETERS, "Group not found");
        return;
    }
    
    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "TransferGroupOwner: Tox instance not available");
        callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
        return;
    }
    
    // Check if we are the current founder
    Tox_Err_Group_Self_Query err_self;
    Tox_Group_Role self_role = GetToxManagerFromImpl(manager_impl_)->getSelfRole(group_number, &err_self);
    if (err_self != TOX_ERR_GROUP_SELF_QUERY_OK || self_role != TOX_GROUP_ROLE_FOUNDER) {
        V2TIM_LOG(kError, "TransferGroupOwner: Current user is not the founder (role={})", static_cast<int>(self_role));
        callback->OnError(ERR_INVALID_PARAMETERS, "Only founder can transfer ownership");
        return;
    }
    
    // Convert userID to public key
    std::string user_id_str = userID.CString();
    uint8_t target_pubkey[TOX_PUBLIC_KEY_SIZE];
    if (!ToxUtil::tox_hex_to_bytes(user_id_str.c_str(), user_id_str.length(), target_pubkey, TOX_PUBLIC_KEY_SIZE)) {
        V2TIM_LOG(kError, "TransferGroupOwner: Failed to convert userID {} to public key", user_id_str);
        callback->OnError(ERR_INVALID_PARAMETERS, "Invalid userID");
        return;
    }
    
    // Find peer_id by public key
    Tox_Group_Peer_Number target_peer_id = UINT32_MAX;
    for (Tox_Group_Peer_Number peer_id = 0; peer_id < 1000; ++peer_id) {
        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Peer_Query err_key;
        if (GetToxManagerFromImpl(manager_impl_)->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) &&
            err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
            if (memcmp(peer_pubkey, target_pubkey, TOX_PUBLIC_KEY_SIZE) == 0) {
                target_peer_id = peer_id;
                break;
            }
        }
    }
    
    if (target_peer_id == UINT32_MAX) {
        V2TIM_LOG(kError, "TransferGroupOwner: Peer not found for userID {}", user_id_str);
        callback->OnError(ERR_INVALID_PARAMETERS, "Member not found in group");
        return;
    }
    
    // Set target peer as FOUNDER
    Tox_Err_Group_Set_Role err_set_role;
    bool success = GetToxManagerFromImpl(manager_impl_)->setGroupMemberRole(group_number, target_peer_id, TOX_GROUP_ROLE_FOUNDER, &err_set_role);
    
    if (success && err_set_role == TOX_ERR_GROUP_SET_ROLE_OK) {
        V2TIM_LOG(kInfo, "TransferGroupOwner: Successfully transferred ownership to {} (peer_id={}) in group {}",
                 user_id_str, target_peer_id, groupID.CString());
        
        // Note: In tox group, when we set someone else as FOUNDER, our role is automatically changed
        // We don't need to explicitly set our own role
        
        callback->OnSuccess();
    } else {
        V2TIM_LOG(kError, "TransferGroupOwner: Failed to transfer ownership, error: {}", err_set_role);
        callback->OnError(ERR_INVALID_PARAMETERS, "Failed to transfer ownership");
    }
}

////////////////////////////// 加群申请 //////////////////////////////
void V2TIMGroupManagerImpl::GetGroupApplicationList(V2TIMValueCallback<V2TIMGroupApplicationResult>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::AcceptGroupApplication(const V2TIMGroupApplication& application, const V2TIMString& reason,
                                                   V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::RefuseGroupApplication(const V2TIMGroupApplication& application, const V2TIMString& reason,
                                                   V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::SetGroupApplicationRead(V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

////////////////////////////// 社群-话题 //////////////////////////////
void V2TIMGroupManagerImpl::GetJoinedCommunityList(V2TIMValueCallback<V2TIMGroupInfoVector>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::CreateTopicInCommunity(const V2TIMString& groupID, const V2TIMTopicInfo& topicInfo,
                               V2TIMValueCallback<V2TIMString>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::DeleteTopicFromCommunity(const V2TIMString& groupID, const V2TIMStringVector& topicIDList,
                                                     V2TIMValueCallback<V2TIMTopicOperationResultVector>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::SetTopicInfo(const V2TIMTopicInfo& topicInfo, V2TIMCallback* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

void V2TIMGroupManagerImpl::GetTopicInfoList(const V2TIMString& groupID, const V2TIMStringVector& topicIDList,
                         V2TIMValueCallback<V2TIMTopicInfoResultVector>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Not supported");
}

////////////////////////////// 工具函数 //////////////////////////////
uint32_t V2TIMGroupManagerImpl::GetFriendNumber(const std::string& userID) {
    V2TIM_LOG(kInfo, "GetFriendNumber: Looking up friend number for userID: {} (length={})", userID, userID.length());
    
    Tox* tox = GetToxManagerFromImpl(manager_impl_)->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "GetFriendNumber: Tox instance not available for userID: {}", userID);
        return UINT32_MAX;
    }
    
    // userID 是 Tox 公钥的十六进制表示（至少 64 字符；若更长则取前 64 字符）
    size_t keyHexLen = TOX_PUBLIC_KEY_SIZE * 2;
    if (userID.length() < keyHexLen) {
        V2TIM_LOG(kError, "GetFriendNumber: Invalid UserID length: {} (need at least {}) for userID: {}", userID.length(), keyHexLen, userID);
        return UINT32_MAX;
    }
    size_t useLen = (userID.length() > keyHexLen) ? keyHexLen : userID.length();
    const char* usePtr = userID.c_str();
    uint8_t public_key[TOX_PUBLIC_KEY_SIZE];
    if (!ToxUtil::tox_hex_to_bytes(usePtr, useLen, public_key, TOX_PUBLIC_KEY_SIZE)) {
        V2TIM_LOG(kError, "GetFriendNumber: Failed to convert UserID to public key for userID: {}", userID);
        return UINT32_MAX;
    }
    
    // 通过公钥查找friend_number
    TOX_ERR_FRIEND_BY_PUBLIC_KEY err;
    uint32_t friend_num = tox_friend_by_public_key(tox, public_key, &err);
    if (err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        const char* errorStr = "UNKNOWN";
        switch (err) {
            case TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK: errorStr = "OK"; break;
            case TOX_ERR_FRIEND_BY_PUBLIC_KEY_NULL: errorStr = "NULL"; break;
            case TOX_ERR_FRIEND_BY_PUBLIC_KEY_NOT_FOUND: errorStr = "NOT_FOUND"; break;
            default: errorStr = "UNKNOWN"; break;
        }
        V2TIM_LOG(kError, "GetFriendNumber: Failed to find friend for userID: {}. Error code: {} ({}). User may not be in friend list.", userID, err, errorStr);
        return UINT32_MAX;
    }
    
    V2TIM_LOG(kInfo, "GetFriendNumber: Successfully found friend_number={} for userID: {}", friend_num, userID);
    return friend_num;
}

std::vector<std::string> V2TIMGroupManagerImpl::GetAllGroupIDsSync() {
    std::vector<std::string> groupIDs;
    
    // Get all known groups from manager_impl_'s mapping first (most reliable source)
    if (manager_impl_) {
        std::vector<V2TIMString> managerGroupIDs = manager_impl_->GetAllGroupIDs();
        for (const auto& gid : managerGroupIDs) {
            groupIDs.push_back(gid.CString());
        }
        V2TIM_LOG(kInfo, "GetAllGroupIDsSync: got {} groups from manager_impl_ mapping", groupIDs.size());
    }
    
    // Fall back to groups_ map if manager_impl_ mapping is empty
    if (groupIDs.empty()) {
        std::lock_guard<std::mutex> lock(group_mutex_);
        for (const auto& groupPair : groups_) {
            groupIDs.push_back(groupPair.first);
        }
        V2TIM_LOG(kInfo, "GetAllGroupIDsSync: got {} groups from groups_ map", groupIDs.size());
    }
    
    // If still empty, try to get groups from Tox groups and use group_number as fallback
    // This is critical for startup when groups are restored from persistence but mappings are empty
    // We'll generate temporary IDs from group numbers, but this should be rare
    if (groupIDs.empty()) {
        size_t group_count = GetToxManagerFromImpl(manager_impl_)->getGroupListSize();
        V2TIM_LOG(kInfo, "GetAllGroupIDsSync: both mappings empty, found {} groups in Tox", group_count);
        if (group_count > 0) {
            std::vector<Tox_Group_Number> group_list(group_count);
            GetToxManagerFromImpl(manager_impl_)->getGroupList(group_list.data(), group_count);
            
            // Generate temporary IDs from group numbers as fallback
            // This is not ideal, but necessary when mappings are empty on startup
            for (Tox_Group_Number group_number : group_list) {
                // Generate a temporary ID - this will be replaced when GetJoinedGroupList is called
                char temp_id[32];
                snprintf(temp_id, sizeof(temp_id), "tox_%u", group_number);
                groupIDs.push_back(temp_id);
                V2TIM_LOG(kInfo, "GetAllGroupIDsSync: generated temp ID {} for group_number {}", temp_id, group_number);
            }
        }
    }
    
    V2TIM_LOG(kInfo, "GetAllGroupIDsSync: returning {} total groups", groupIDs.size());
    return groupIDs;
}

// Helper functions for role mapping
Tox_Group_Role V2TIMGroupManagerImpl::v2timRoleToToxRole(uint32_t v2tim_role) {
    switch (v2tim_role) {
        case V2TIM_GROUP_MEMBER_ROLE_SUPER: return TOX_GROUP_ROLE_FOUNDER;
        case V2TIM_GROUP_MEMBER_ROLE_ADMIN: return TOX_GROUP_ROLE_MODERATOR;
        case V2TIM_GROUP_MEMBER_ROLE_MEMBER: return TOX_GROUP_ROLE_USER;
        default: return TOX_GROUP_ROLE_USER;
    }
}

uint32_t V2TIMGroupManagerImpl::toxRoleToV2timRole(Tox_Group_Role tox_role) {
    switch (tox_role) {
        case TOX_GROUP_ROLE_FOUNDER: return V2TIM_GROUP_MEMBER_ROLE_SUPER;
        case TOX_GROUP_ROLE_MODERATOR: return V2TIM_GROUP_MEMBER_ROLE_ADMIN;
        case TOX_GROUP_ROLE_USER: return V2TIM_GROUP_MEMBER_ROLE_MEMBER;
        case TOX_GROUP_ROLE_OBSERVER: return V2TIM_GROUP_MEMBER_ROLE_MEMBER;
        default: return V2TIM_GROUP_MEMBER_ROLE_MEMBER;
    }
}

// Helper function to convert chat_id to hex string
std::string V2TIMGroupManagerImpl::chatIdToHexString(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]) {
    std::ostringstream oss;
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
    }
    return oss.str();
}

// Helper function to convert hex string to chat_id
bool V2TIMGroupManagerImpl::hexStringToChatId(const std::string& hex_str, uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]) {
    if (hex_str.length() != TOX_GROUP_CHAT_ID_SIZE * 2) {
        return false;
    }
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        std::string byte_str = hex_str.substr(i * 2, 2);
        char* endptr;
        unsigned long byte_val = strtoul(byte_str.c_str(), &endptr, 16);
        if (*endptr != '\0' || byte_val > 255) {
            return false;
        }
        chat_id[i] = static_cast<uint8_t>(byte_val);
    }
    return true;
}
