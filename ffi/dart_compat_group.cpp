// Group Functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"
#include "V2TIMManagerImpl.h"

// Forward declarations for multi-instance support
extern int64_t GetCurrentInstanceId();
extern V2TIMManager* GetManagerForInstanceId(int64_t instance_id);

extern "C" {
    // ============================================================================
    // Group Functions
    // ============================================================================
    
    // Map group_type string to SDK GroupTypeEnum index (V2TimGroupInfo.fromJson expects group_detail_info_group_type as int)
    // GroupTypeEnum: 0=Public, 1=Private/Work, 2=ChatRoom/Meeting, 3=BChatRoom, 4=AVChatRoom, 5=Community
    static int GroupTypeStringToEnumIndex(const std::string& group_type) {
        if (group_type == "Public") return 0;
        if (group_type == "Private" || group_type == "Work" || group_type == "group") return 1;
        if (group_type == "Meeting" || group_type == "conference") return 2;
        if (group_type == "AVChatRoom") return 4;
        if (group_type == "Community") return 5;
        return 1; // default Work/Private
    }

    // Helper: Convert V2TIMGroupInfoVector to JSON array using SDK schema (group_detail_info_*)
    // So that Dart V2TimGroupInfo.fromJson() parses groupID, groupType, groupName correctly.
    static std::string GroupInfoVectorToJson(const V2TIMGroupInfoVector& groups) {
        std::ostringstream json;
        json << "[";
        
        try {
            size_t size = groups.Size();
            for (size_t i = 0; i < size; i++) {
                if (i > 0) {
                    json << ",";
                }
                
                if (i >= size) {
                    V2TIM_LOG(kWarning, "GroupInfoVectorToJson: index {} out of bounds (size {})", i, size);
                    break;
                }
                
                const V2TIMGroupInfo& group_info = groups[i];
                std::string group_id = group_info.groupID.CString();
                std::string group_name = group_info.groupName.CString();
                std::string group_type = group_info.groupType.CString();
                if (group_name.empty()) {
                    group_name = group_id;
                }
                int group_type_index = GroupTypeStringToEnumIndex(group_type);
                
                json << "{";
                json << "\"group_detail_info_group_id\":\"" << EscapeJsonString(group_id) << "\",";
                json << "\"group_detail_info_group_type\":" << group_type_index << ",";
                json << "\"group_detail_info_group_name\":\"" << EscapeJsonString(group_name) << "\"";
                json << "}";
            }
        } catch (const std::exception& e) {
            V2TIM_LOG(kError, "GroupInfoVectorToJson: exception: {}", e.what());
            json << "]";
            return json.str();
        } catch (...) {
            V2TIM_LOG(kError, "GroupInfoVectorToJson: unknown exception");
            json << "]";
            return json.str();
        }
        
        json << "]";
        return json.str();
    }
    
    // Helper class for V2TIMValueCallback<V2TIMString> (for CreateGroup)
    class DartStringCallback : public V2TIMValueCallback<V2TIMString> {
    private:
        void* user_data_;
        // Optional original group_type string the caller created the group with
        // (e.g. "Meeting", "Public", "Private"). When non-empty and OnSuccess
        // fires, the callback propagates this label to every other instance's
        // group-type storage so joiner-side getGroupsInfo can recover it.
        std::string group_type_;

    public:
        DartStringCallback(void* user_data) : user_data_(user_data) {}
        DartStringCallback(void* user_data, const std::string& group_type)
            : user_data_(user_data), group_type_(group_type) {}

        void OnSuccess(const V2TIMString& value) override {
            std::string group_id = value.CString();

            // Propagate the original group_type label to all other instances'
            // in-memory storage. This is needed because Tox's group protocol
            // does not carry the tim2tox-specific "Meeting"/"Public"/"Private"
            // semantic across the wire — joiners would otherwise fall back to
            // a generic default and lose the original label on getGroupsInfo.
            // The auto_tests share a single process and rely on cross-instance
            // pushes (mirrors NotifyOtherInstancesMemberJoined for member events).
            if (!group_type_.empty()) {
                V2TIM_LOG(kInfo, "[DartStringCallback] Propagating group_type='{}' for group_id='{}' to all instances",
                          group_type_, group_id);
                struct Ctx { std::string group_id; std::string group_type; };
                Ctx ctx = { group_id, group_type_ };
                Tim2ToxFfiForEachInstanceManager([](int64_t id, void* manager, void* user) {
                    Ctx* p = static_cast<Ctx*>(user);
                    V2TIMManagerImpl* impl = static_cast<V2TIMManagerImpl*>(manager);
                    if (!impl) return;
                    impl->SetGroupTypeInStorage(p->group_id, p->group_type);
                    V2TIM_LOG(kInfo, "[DartStringCallback] SetGroupTypeInStorage on instance_id={}, group_id='{}', group_type='{}'",
                              id, p->group_id, p->group_type);
                }, &ctx);
            } else {
                V2TIM_LOG(kInfo, "[DartStringCallback] group_type_ is empty, not propagating (group_id='{}')", group_id);
            }

            std::map<std::string, std::string> result_fields;
            result_fields["create_group_result_groupid"] = group_id;
            std::string data_json = BuildJsonObject(result_fields);
            SendApiCallbackResult(user_data_, 0, "", data_json);
        }

        void OnError(int error_code, const V2TIMString& error_message) override {
            std::string error_msg = error_message.CString();
            SendApiCallbackResult(user_data_, error_code, error_msg);
        }
    };
    
    // Helper class for V2TIMValueCallback<V2TIMGroupInfoVector> (for GetJoinedGroupList)
    class DartGroupInfoVectorCallback : public V2TIMValueCallback<V2TIMGroupInfoVector> {
    private:
        void* user_data_;
        
    public:
        DartGroupInfoVectorCallback(void* user_data) : user_data_(user_data) {}
        
        void OnSuccess(const V2TIMGroupInfoVector& groups) override {
            try {
                std::string groups_json = GroupInfoVectorToJson(groups);
                
                // V2TimValueCallback expects json_param field at top level as a JSON string
                // Build the complete callback JSON with json_param as an escaped string
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(groups_json) << "\"}";
                
                SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
            } catch (const std::exception& e) {
                V2TIM_LOG(kError, "[dart_compat] DartGroupInfoVectorCallback::OnSuccess: exception: {}", e.what());
                SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, std::string("Exception: ") + e.what());
            } catch (...) {
                V2TIM_LOG(kError, "[dart_compat] DartGroupInfoVectorCallback::OnSuccess: unknown exception");
                SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Unknown exception");
            }
        }
        
        void OnError(int error_code, const V2TIMString& error_message) override {
            std::string error_msg = error_message.CString();
            SendApiCallbackResult(user_data_, error_code, error_msg);
        }
    };
    
    // DartCreateGroup: Create group
    // Signature: int DartCreateGroup(Pointer<Char> json_group_create_param, Pointer<Void> user_data)
    int DartCreateGroup(const char* json_group_create_param, void* user_data) {
        
        if (!json_group_create_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON group create parameter
        std::string json_str = json_group_create_param;
        // Try both field name formats for compatibility
        // V2TimGroupCreateParam.toJson() generates "create_group_param_*" format
        std::string group_type_str = ExtractJsonValue(json_str, "create_group_param_group_type");
        if (group_type_str.empty()) {
            group_type_str = ExtractJsonValue(json_str, "group_create_param_group_type");
        }
        
        // Convert group_type from integer (enum index) to string
        // Dart GroupTypeEnum: 0=kTIMGroup_Public, 1=kTIMGroup_Private, 2=kTIMGroup_ChatRoom (Meeting/conference)
        // Tox: "Public" -> TOX_GROUP_PRIVACY_STATE_PUBLIC (DHT/announce peer discovery); "Private" -> PRIVATE (friend-based).
        std::string group_type;
        if (!group_type_str.empty()) {
            try {
                int group_type_int = std::stoi(group_type_str);
                if (group_type_int == 0) {
                    group_type = "Public";   // kTIMGroup_Public -> Tox PUBLIC (DHT/announce)
                } else if (group_type_int == 1) {
                    group_type = "Private"; // kTIMGroup_Private -> Tox PRIVATE (friend-based)
                } else if (group_type_int == 2) {
                    group_type = "Meeting"; // conference
                } else {
                    group_type = "group";    // Default
                }
            } catch (...) {
                group_type = group_type_str;
            }
        }
        std::string group_id = ExtractJsonValue(json_str, "create_group_param_group_id");
        if (group_id.empty()) {
            group_id = ExtractJsonValue(json_str, "group_create_param_group_id");
        }
        if (group_id == "null") {
            group_id = "";
        }
        std::string group_name = ExtractJsonValue(json_str, "create_group_param_group_name");
        if (group_name.empty()) {
            group_name = ExtractJsonValue(json_str, "group_create_param_group_name");
        }
        if (group_name.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartCreateGroup: ERROR - group_name is required");
            V2TIM_LOG(kError, "[dart_compat] DartCreateGroup: Full JSON received: {}", json_str);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "group_name is required");
            return 1; // Error
        }
        
        // Use default group type if not provided
        if (group_type.empty()) {
            group_type = "group";
        }
        
        // Create V2TIMGroupInfo
        V2TIMGroupInfo group_info;
        group_info.groupID = V2TIMString(group_id.c_str());
        group_info.groupName = V2TIMString(group_name.c_str());
        group_info.groupType = V2TIMString(group_type.c_str());
        
        // Create empty member list (for now)
        V2TIMCreateGroupMemberInfoVector member_list;
        
        // Call V2TIM CreateGroup (async). Pass the original group_type label so
        // the callback can propagate it to other instances' storage on success
        // (see DartStringCallback::OnSuccess for rationale).
        SafeGetV2TIMManager()->GetGroupManager()->CreateGroup(
            group_info,
            member_list,
            new DartStringCallback(user_data, group_type)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // Notify every other instance that has this group when a user joins (JoinGroup success).
    // Pushes a synthetic GroupTipsEvent (JOIN, tip_type=1) so they see the new member without waiting for DHT.
    static void NotifyOtherInstancesMemberJoined(const std::string& group_id, const std::string& joiner_user_id) {
        static const int kDartTipTypeJoin = 1;
        struct Ctx { std::string group_id; std::string joiner_user_id; };
        Ctx ctx = { group_id, joiner_user_id };
        Tim2ToxFfiForEachInstanceManager([](int64_t id, void* manager, void* user) {
            Ctx* p = static_cast<Ctx*>(user);
            const std::string& group_id = p->group_id;
            const std::string& joiner_user_id = p->joiner_user_id;
            V2TIMManagerImpl* impl = static_cast<V2TIMManagerImpl*>(manager);
            if (!impl) return;
            if (!impl->HasGroup(V2TIMString(group_id.c_str()))) return;
            std::string login = impl->GetLoginUser().CString();
            if (login == joiner_user_id) return;  // do not notify the joiner's own instance
            // Build GroupTipsEvent JSON for JOIN (tip_type=1). Match BuildGroupTipsElemJson/GroupMemberInfoToJson layout.
            std::ostringstream tips;
            tips << "{";
            tips << "\"elem_type\":8,";
            tips << "\"group_tips_elem_group_id\":\"" << EscapeJsonString(group_id) << "\",";
            tips << "\"group_tips_elem_tip_type\":" << kDartTipTypeJoin << ",";
            tips << "\"group_tips_elem_op_group_memberinfo\":{\"group_member_info_identifier\":\"\",\"group_member_info_nick_name\":\"\",\"group_member_info_friend_remark\":\"\",\"group_member_info_name_card\":\"\",\"group_member_info_face_url\":\"\"},";
            tips << "\"group_tips_elem_changed_group_memberinfo_array\":[{\"group_member_info_identifier\":\"" << EscapeJsonString(joiner_user_id) << "\",\"group_member_info_nick_name\":\"\",\"group_member_info_friend_remark\":\"\",\"group_member_info_name_card\":\"\",\"group_member_info_face_url\":\"\"}],";
            tips << "\"group_tips_elem_group_change_info_array\":[],";
            tips << "\"group_tips_elem_member_change_info_array\":[],";
            tips << "\"group_tips_elem_member_num\":1";
            tips << "}";
            std::string group_tips_json = tips.str();
            std::map<std::string, std::string> fields;
            fields["json_group_tip"] = group_tips_json;
            std::string user_data = UserDataToString(GetCallbackUserData(id, "GroupTipsEvent"));
            std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, id);
            SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(id, "GroupTipsEvent"));
            V2TIM_LOG(kInfo, "NotifyOtherInstancesMemberJoined: sent JOIN to instance_id=%lld for joiner=%s",
                      (long long)id, joiner_user_id.c_str());
        }, &ctx);
    }
    
    // Notify every other instance that has this group when a user leaves (QuitGroup success).
    // Pushes a synthetic GroupTipsEvent (QUIT, tip_type=2) so they see the member leave.
    static void NotifyOtherInstancesMemberLeft(const std::string& group_id, const std::string& leaver_user_id) {
        static const int kDartTipTypeQuit = 2;
        struct Ctx { std::string group_id; std::string leaver_user_id; };
        Ctx ctx = { group_id, leaver_user_id };
        Tim2ToxFfiForEachInstanceManager([](int64_t id, void* manager, void* user) {
            Ctx* p = static_cast<Ctx*>(user);
            const std::string& group_id = p->group_id;
            const std::string& leaver_user_id = p->leaver_user_id;
            V2TIMManagerImpl* impl = static_cast<V2TIMManagerImpl*>(manager);
            if (!impl) return;
            if (!impl->HasGroup(V2TIMString(group_id.c_str()))) return;
            std::string login = impl->GetLoginUser().CString();
            if (login == leaver_user_id) return;  // do not notify the leaver's own instance
            std::ostringstream tips;
            tips << "{";
            tips << "\"elem_type\":8,";
            tips << "\"group_tips_elem_group_id\":\"" << EscapeJsonString(group_id) << "\",";
            tips << "\"group_tips_elem_tip_type\":" << kDartTipTypeQuit << ",";
            tips << "\"group_tips_elem_op_group_memberinfo\":{\"group_member_info_identifier\":\"" << EscapeJsonString(leaver_user_id) << "\",\"group_member_info_nick_name\":\"\",\"group_member_info_friend_remark\":\"\",\"group_member_info_name_card\":\"\",\"group_member_info_face_url\":\"\"},";
            tips << "\"group_tips_elem_changed_group_memberinfo_array\":[{\"group_member_info_identifier\":\"" << EscapeJsonString(leaver_user_id) << "\",\"group_member_info_nick_name\":\"\",\"group_member_info_friend_remark\":\"\",\"group_member_info_name_card\":\"\",\"group_member_info_face_url\":\"\"}],";
            tips << "\"group_tips_elem_group_change_info_array\":[],";
            tips << "\"group_tips_elem_member_change_info_array\":[],";
            tips << "\"group_tips_elem_member_num\":1";
            tips << "}";
            std::string group_tips_json = tips.str();
            std::map<std::string, std::string> fields;
            fields["json_group_tip"] = group_tips_json;
            std::string user_data = UserDataToString(GetCallbackUserData(id, "GroupTipsEvent"));
            std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, id);
            SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(id, "GroupTipsEvent"));
            V2TIM_LOG(kInfo, "NotifyOtherInstancesMemberLeft: sent QUIT to instance_id=%lld for leaver=%s",
                      (long long)id, leaver_user_id.c_str());
        }, &ctx);
    }
    
    // Notify every other instance that has this group when a member is kicked (KickGroupMember success).
    // Pushes a synthetic GroupTipsEvent (KICK, tip_type=3) so they see the kick.
    static void NotifyOtherInstancesMemberKicked(const std::string& group_id, const std::string& op_user_id,
                                                  const std::vector<std::string>& kicked_user_ids) {
        static const int kDartTipTypeKick = 3;
        struct Ctx {
            std::string group_id;
            std::string op_user_id;
            std::vector<std::string> kicked_user_ids;
        };
        Ctx ctx = { group_id, op_user_id, kicked_user_ids };
        Tim2ToxFfiForEachInstanceManager([](int64_t id, void* manager, void* user) {
            Ctx* p = static_cast<Ctx*>(user);
            const std::string& group_id = p->group_id;
            const std::string& op_user_id = p->op_user_id;
            const std::vector<std::string>& kicked = p->kicked_user_ids;
            V2TIMManagerImpl* impl = static_cast<V2TIMManagerImpl*>(manager);
            if (!impl) return;
            if (!impl->HasGroup(V2TIMString(group_id.c_str()))) return;
            std::string login = impl->GetLoginUser().CString();
            if (login == op_user_id) return;  // do not notify the operator's own instance
            std::ostringstream tips;
            tips << "{";
            tips << "\"elem_type\":8,";
            tips << "\"group_tips_elem_group_id\":\"" << EscapeJsonString(group_id) << "\",";
            tips << "\"group_tips_elem_tip_type\":" << kDartTipTypeKick << ",";
            tips << "\"group_tips_elem_op_group_memberinfo\":{\"group_member_info_identifier\":\"" << EscapeJsonString(op_user_id) << "\",\"group_member_info_nick_name\":\"\",\"group_member_info_friend_remark\":\"\",\"group_member_info_name_card\":\"\",\"group_member_info_face_url\":\"\"},";
            tips << "\"group_tips_elem_changed_group_memberinfo_array\":[";
            for (size_t i = 0; i < kicked.size(); i++) {
                if (i > 0) tips << ",";
                tips << "{\"group_member_info_identifier\":\"" << EscapeJsonString(kicked[i]) << "\",\"group_member_info_nick_name\":\"\",\"group_member_info_friend_remark\":\"\",\"group_member_info_name_card\":\"\",\"group_member_info_face_url\":\"\"}";
            }
            tips << "],";
            tips << "\"group_tips_elem_group_change_info_array\":[],";
            tips << "\"group_tips_elem_member_change_info_array\":[],";
            tips << "\"group_tips_elem_member_num\":" << kicked.size();
            tips << "}";
            std::string group_tips_json = tips.str();
            std::map<std::string, std::string> fields;
            fields["json_group_tip"] = group_tips_json;
            std::string user_data = UserDataToString(GetCallbackUserData(id, "GroupTipsEvent"));
            std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, id);
            SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(id, "GroupTipsEvent"));
            V2TIM_LOG(kInfo, "NotifyOtherInstancesMemberKicked: sent KICK to instance_id=%lld for op=%s, kicked_count=%zu",
                      (long long)id, op_user_id.c_str(), kicked.size());
        }, &ctx);
    }
    
    // DartJoinGroup: Join group
    // Signature: int DartJoinGroup(Pointer<Char> group_id, Pointer<Char> hello_msg, Pointer<Void> user_data)
    int DartJoinGroup(const char* group_id, const char* hello_msg, void* user_data) {
        
        if (!group_id || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        std::string group_id_str = CStringToString(group_id);
        std::string hello_msg_str = CStringToString(hello_msg);
        
        // Call V2TIM JoinGroup (async) - JoinGroup is in V2TIMManager, not V2TIMGroupManager
        // Use SafeGetV2TIMManager() for multi-instance support
        V2TIMManager* manager = SafeGetV2TIMManager();
        if (!manager) {
            SendApiCallbackResult(user_data, ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            return 1;
        }
        manager->JoinGroup(
            V2TIMString(group_id_str.c_str()),
            V2TIMString(hello_msg_str.c_str()),
            new DartCallback(
                user_data,
                [user_data, group_id_str]() {
                    // OnSuccess: notify other instances in this group so they see this user join (join/peer sync)
                    std::string joiner_user_id = SafeGetV2TIMManager() ? SafeGetV2TIMManager()->GetLoginUser().CString() : "";
                    if (!joiner_user_id.empty()) {
                        NotifyOtherInstancesMemberJoined(group_id_str, joiner_user_id);
                    }
                    SendApiCallbackResult(user_data, 0, "");
                },
                [user_data](int error_code, const V2TIMString& error_message) {
                    // OnError
                    std::string error_msg = error_message.CString();
                    SendApiCallbackResult(user_data, error_code, error_msg);
                }
            )
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetJoinedGroupList: Get joined group list
    // Signature: int DartGetJoinedGroupList(Pointer<Void> user_data)
    int DartGetJoinedGroupList(void* user_data) {
        
        if (!user_data) {
            return 1; // Error
        }
        
        // Call V2TIM GetJoinedGroupList (async)
        SafeGetV2TIMManager()->GetGroupManager()->GetJoinedGroupList(
            new DartGroupInfoVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // Notify the target user's instance when SetGroupMemberRole succeeds (Tox may only
    // deliver the moderation event to the initiator). Builds a GroupTipsEvent (MemberInfoChange)
    // and sends it to the instance where GetLoginUser() == target_user_id.
    static void NotifyTargetUserMemberInfoChanged(const std::string& group_id, const std::string& target_user_id) {
        struct Ctx { std::string group_id; std::string target_user_id; int64_t found_id; };
        Ctx ctx = { group_id, target_user_id, -1 };
        Tim2ToxFfiForEachInstanceManager([](int64_t id, void* manager, void* user) {
            Ctx* p = static_cast<Ctx*>(user);
            if (p->found_id >= 0) return;
            V2TIMManager* mgr = static_cast<V2TIMManager*>(manager);
            if (!mgr) return;
            std::string login = mgr->GetLoginUser().CString();
            if (login.empty()) return;
            // Match when equal, or when target is 64-char public key and login is 76-char Tox ID
            bool match = (login == p->target_user_id);
            if (!match && !p->target_user_id.empty()) {
                size_t tlen = p->target_user_id.size();
                if (login.size() >= tlen && login.substr(0, tlen) == p->target_user_id)
                    match = true;
                else if (login.size() >= 64 && tlen >= 64 && login.substr(0, 64) == p->target_user_id.substr(0, 64))
                    match = true;
            }
            if (match) {
                p->found_id = id;
            }
        }, &ctx);
        if (ctx.found_id < 0) {
            V2TIM_LOG(kInfo, "NotifyTargetUserMemberInfoChanged: no instance for target_user_id=%s", target_user_id.c_str());
            return;
        }
        // Build GroupTipsEvent JSON for MemberInfoChange (tip_type=7). Dart expects group_tips_elem_*
        // and V2TimGroupMemberChangeInfo.fromJson expects group_tips_member_change_info_identifier,
        // group_tips_member_change_info_shutupTime.
        std::ostringstream tips;
        tips << "{";
        tips << "\"elem_type\":8,";
        tips << "\"group_tips_elem_group_id\":\"" << EscapeJsonString(group_id) << "\",";
        tips << "\"group_tips_elem_tip_type\":7,";
        tips << "\"group_tips_elem_op_group_memberinfo\":{\"group_member_info_identifier\":\"\"},";
        tips << "\"group_tips_elem_changed_group_memberinfo_array\":[],";
        tips << "\"group_tips_elem_group_change_info_array\":[],";
        tips << "\"group_tips_elem_member_change_info_array\":[{\"group_tips_member_change_info_identifier\":\"" << EscapeJsonString(target_user_id) << "\",\"group_tips_member_change_info_shutupTime\":0}],";
        tips << "\"group_tips_elem_member_num\":0";
        tips << "}";
        std::string group_tips_json = tips.str();
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = group_tips_json;
        std::string user_data = UserDataToString(GetCallbackUserData(ctx.found_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, ctx.found_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(ctx.found_id, "GroupTipsEvent"));
        V2TIM_LOG(kInfo, "NotifyTargetUserMemberInfoChanged: sent MemberInfoChange to instance_id=%lld for user=%s",
                  (long long)ctx.found_id, target_user_id.c_str());
    }
    
    // DartModifyGroupMemberInfo: Modify group member info (set role or mute)
    // Used by setGroupMemberRole (role) and muteGroupMember (group_modify_member_info_shutup_time).
    // JSON from V2TimGroupMemberInfoModifyParam: group_modify_member_info_group_id, group_modify_member_info_identifier (userID),
    //   group_modify_member_info_member_role, group_modify_member_info_shutup_time
    int DartModifyGroupMemberInfo(const char* json_group_modify_meminfo_param, void* user_data) {
        if (!json_group_modify_meminfo_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }
        std::string json_str = json_group_modify_meminfo_param;
        std::string group_id = ExtractJsonValue(json_str, "group_modify_member_info_group_id");
        std::string user_id = ExtractJsonValue(json_str, "group_modify_member_info_identifier");
        std::string role_str = ExtractJsonValue(json_str, "group_modify_member_info_member_role");
        std::string name_card = ExtractJsonValue(json_str, "group_modify_member_info_name_card");
        if (name_card == "null") name_card.clear();
        int seconds_val = ExtractJsonInt(json_str, "group_modify_member_info_shutup_time", 0);
        if (seconds_val == 0) {
            std::string seconds_str = ExtractJsonValue(json_str, "group_modify_member_info_shutup_time");
            if (!seconds_str.empty() && seconds_str != "null") {
                try { seconds_val = static_cast<int>(std::stoul(seconds_str)); } catch (...) {}
            }
        }
        V2TIM_LOG(kInfo, "DartModifyGroupMemberInfo: group_id=%s, user_id=%s, name_card_len=%zu, role=%s, seconds=%d",
                  group_id.c_str(), user_id.c_str(), name_card.size(), role_str.c_str(), seconds_val);
        if (group_id.empty() || user_id.empty()) {
            V2TIM_LOG(kWarning, "DartModifyGroupMemberInfo: missing group_id or user_id (group_id=%s, user_id=%s)",
                      group_id.c_str(), user_id.c_str());
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "group_id and userID are required");
            return 1;
        }
        V2TIMManager* manager = SafeGetV2TIMManager();
        if (!manager) {
            SendApiCallbackResult(user_data, ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            return 1;
        }
        V2TIMGroupManager* grp_mgr = manager->GetGroupManager();
        if (!grp_mgr) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "GetGroupManager failed");
            return 1;
        }
        // Mute path: when shutup_time is present (muteGroupMember sends seconds, not role)
        if (!role_str.empty()) {
            uint32_t role = 0;
            try {
                role = static_cast<uint32_t>(std::stoul(role_str));
            } catch (...) {
                SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid role value");
                return 1;
            }
            grp_mgr->SetGroupMemberRole(
                V2TIMString(group_id.c_str()),
                V2TIMString(user_id.c_str()),
                role,
                new DartCallback(
                    user_data,
                    [user_data, group_id, user_id]() {
                        SendApiCallbackResult(user_data, 0, "");
                        NotifyTargetUserMemberInfoChanged(group_id, user_id);
                    },
                    [user_data](int error_code, const V2TIMString& error_message) {
                        std::string msg = error_message.CString();
                        SendApiCallbackResult(user_data, error_code, msg);
                    }
                )
            );
            return 0;
        }
        if (seconds_val > 0) {
            grp_mgr->MuteGroupMember(
                V2TIMString(group_id.c_str()),
                V2TIMString(user_id.c_str()),
                static_cast<uint32_t>(seconds_val),
                new DartCallback(
                    user_data,
                    [user_data]() { SendApiCallbackResult(user_data, 0, ""); },
                    [user_data](int error_code, const V2TIMString& error_message) {
                        SendApiCallbackResult(user_data, error_code, error_message.CString());
                    }
                )
            );
            return 0;
        }
        // nameCard path: setGroupMemberInfo with only nameCard (no role, no shutup_time)
        if (!name_card.empty()) {
            V2TIMGroupMemberFullInfo info;
            info.userID = user_id.c_str();
            info.nameCard = name_card.c_str();
            grp_mgr->SetGroupMemberInfo(
                V2TIMString(group_id.c_str()),
                info,
                new DartCallback(
                    user_data,
                    [user_data]() { SendApiCallbackResult(user_data, 0, ""); },
                    [user_data](int error_code, const V2TIMString& error_message) {
                        std::string msg = error_message.CString();
                        SendApiCallbackResult(user_data, error_code, msg);
                    }
                )
            );
            return 0;
        }
        V2TIM_LOG(kWarning, "DartModifyGroupMemberInfo: need role, shutup_time, or name_card (group_id=%s, user_id=%s)",
                  group_id.c_str(), user_id.c_str());
        SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "role, shutup_time, or name_card is required");
        return 1;
    }
    
    // DartQuitGroup: Quit group
    // Signature: int DartQuitGroup(Pointer<Char> group_id, Pointer<Void> user_data)
    int DartQuitGroup(const char* group_id, void* user_data) {
        V2TIM_LOG(kInfo, "DartQuitGroup: ENTRY - group_id=%s", group_id ? group_id : "null");
        
        if (!group_id || !user_data) {
            V2TIM_LOG(kError, "DartQuitGroup: ERROR - Invalid parameters (group_id=%p, user_data=%p)", group_id, user_data);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        std::string group_id_str = CStringToString(group_id);
        // Capture leaver_user_id at call time (current instance is the one calling quitGroup).
        // In async OnSuccess the "current instance" may have changed, so use captured value.
        std::string leaver_user_id = (SafeGetV2TIMManager() ? SafeGetV2TIMManager()->GetLoginUser().CString() : "");
        V2TIM_LOG(kInfo, "DartQuitGroup: Calling V2TIMManager::QuitGroup for group_id=%s, leaver_user_id=%.16s...", group_id_str.c_str(), leaver_user_id.empty() ? "(empty)" : leaver_user_id.c_str());
        
        // Call V2TIM QuitGroup (async)
        SafeGetV2TIMManager()->QuitGroup(
            V2TIMString(group_id_str.c_str()),
            new DartCallback(
                user_data,
                [user_data, group_id_str, leaver_user_id]() {
                    // OnSuccess: notify other instances in this group so they see this user leave
                    V2TIM_LOG(kInfo, "[CALL_PATH] DartQuitGroup OnSuccess: group_id={}, leaver_user_id={}, calling NotifyOtherInstancesMemberLeft",
                              group_id_str, leaver_user_id.empty() ? "(empty)" : leaver_user_id);
                    if (!leaver_user_id.empty()) {
                        NotifyOtherInstancesMemberLeft(group_id_str, leaver_user_id);
                    }
                    V2TIM_LOG(kInfo, "DartQuitGroup: OnSuccess callback for group_id=%s", group_id_str.c_str());
                    SendApiCallbackResult(user_data, 0, "");
                },
                [user_data, group_id_str](int error_code, const V2TIMString& error_message) {
                    // OnError
                    std::string error_msg = error_message.CString();
                    V2TIM_LOG(kError, "DartQuitGroup: OnError callback for group_id=%s, error_code=%d, error_msg=%s", 
                              group_id_str.c_str(), error_code, error_msg.c_str());
                    SendApiCallbackResult(user_data, error_code, error_msg);
                }
            )
        );
        
        V2TIM_LOG(kInfo, "DartQuitGroup: EXIT - Request accepted, waiting for async callback");
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartNotifyGroupQuit: Notify Dart layer to clean up group state after quit
    // This is called from C++ layer after QuitGroup completes successfully
    // Signature: void DartNotifyGroupQuit(const char* group_id)
    void DartNotifyGroupQuit(const char* group_id) {
        if (!group_id) {
            V2TIM_LOG(kWarning, "DartNotifyGroupQuit: group_id is null");
            return;
        }
        
        std::string group_id_str = CStringToString(group_id);
        V2TIM_LOG(kInfo, "DartNotifyGroupQuit: Notifying Dart layer to clean up group %s", group_id_str.c_str());
        
        // Build JSON message for Dart layer
        std::ostringstream json;
        json << "{";
        json << "\"callback\":\"groupQuitNotification\",";
        json << "\"group_id\":\"" << EscapeJsonString(group_id_str) << "\"";
        json << "}";
        
        // Send notification to Dart layer
        SendCallbackToDart("groupQuitNotification", json.str(), nullptr);
        V2TIM_LOG(kInfo, "DartNotifyGroupQuit: Notification sent for group %s", group_id_str.c_str());
    }
    
    // DartDeleteGroup: Delete group (dismiss group)
    // Signature: int DartDeleteGroup(Pointer<Char> group_id, Pointer<Void> user_data)
    int DartDeleteGroup(const char* group_id, void* user_data) {
        if (!group_id || !user_data) {
            V2TIM_LOG(kError, "[dart_compat] DartDeleteGroup: ERROR - Invalid parameters (group_id={}, user_data={})",
                      (void*)group_id, user_data);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }

        std::string group_id_str = CStringToString(group_id);
        SafeGetV2TIMManager()->DismissGroup(
            V2TIMString(group_id_str.c_str()),
            new DartCallback(
                user_data,
                [user_data, group_id_str]() {
                    SendApiCallbackResult(user_data, 0, "");
                },
                [user_data, group_id_str](int error_code, const V2TIMString& error_message) {
                    std::string error_msg = error_message.CString();
                    V2TIM_LOG(kError, "[dart_compat] DartDeleteGroup: OnError callback for group_id={}, error_code={}, error_msg={}",
                              group_id_str, error_code, error_msg);
                    SendApiCallbackResult(user_data, error_code, error_msg);
                }
            )
        );
        return 0;
    }
    
    // DartGetGroupsInfo: Get groups info
    // Signature: int DartGetGroupsInfo(Pointer<Char> json_group_getinfo_param, Pointer<Void> user_data)
    int DartGetGroupsInfo(const char* json_group_getinfo_param, void* user_data) {
        if (!json_group_getinfo_param || !user_data) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Invalid parameters");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }
        
        // Parse JSON group getinfo parameter
        std::string json_str = json_group_getinfo_param;
        // Helper function to parse JSON string array (defined locally)
        static auto ParseJsonStringArray = [](const std::string& json_str) -> std::vector<std::string> {
            std::vector<std::string> result;
            std::string array_str = json_str;
            
            size_t array_start = array_str.find('[');
            if (array_start == std::string::npos) {
                std::string array_field = ExtractJsonValue(json_str, "group_id_list", true);
                if (array_field.empty()) {
                    array_field = ExtractJsonValue(json_str, "groupIDList", true);
                }
                if (!array_field.empty() && array_field[0] == '[') {
                    array_str = array_field;
                    array_start = 0;
                } else {
                    return result;
                }
            }
            
            size_t i = array_start + 1;
            std::string current_string;
            bool in_string = false;
            bool escape_next = false;
            
            // Add bounds checking to prevent out-of-bounds access
            while (i < array_str.length()) {
                // Double-check bounds before accessing
                if (i >= array_str.length()) {
                    break;
                }
                
                char c = array_str[i];
                
                if (escape_next) {
                    if (in_string) {
                        current_string += c;
                    }
                    escape_next = false;
                    i++;
                    // Check bounds after increment
                    if (i > array_str.length()) {
                        break;
                    }
                    continue;
                }
                
                if (c == '\\') {
                    escape_next = true;
                    if (in_string) {
                        current_string += c;
                    }
                    i++;
                    // Check bounds after increment
                    if (i > array_str.length()) {
                        break;
                    }
                    continue;
                }
                
                if (c == '"') {
                    in_string = !in_string;
                    if (!in_string && !current_string.empty()) {
                        result.push_back(current_string);
                        current_string.clear();
                    }
                    i++;
                    // Check bounds after increment
                    if (i > array_str.length()) {
                        break;
                    }
                    continue;
                }
                
                if (in_string) {
                    current_string += c;
                } else if (c == ']') {
                    break;
                }
                
                i++;
                // Check bounds after increment to prevent infinite loop
                if (i > array_str.length()) {
                    break;
                }
            }
            
            return result;
        };
        
        std::vector<std::string> group_ids = ParseJsonStringArray(json_str);
        
        if (group_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: group_id list is empty");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "group_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector group_id_vector;
        
        for (size_t i = 0; i < group_ids.size(); i++) {
            V2TIMString group_id_str(group_ids[i].c_str());
            group_id_vector.PushBack(group_id_str);
        }
        
        // Helper class for V2TIMValueCallback<V2TIMGroupInfoResultVector>
        class DartGroupInfoResultVectorCallback : public V2TIMValueCallback<V2TIMGroupInfoResultVector> {
        private:
            void* user_data_;
            
        public:
            DartGroupInfoResultVectorCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMGroupInfoResultVector& results) override {
                // Convert to JSON
                std::ostringstream json;
                json << "[";
                bool first = true;
                for (size_t i = 0; i < results.Size(); i++) {
                    const V2TIMGroupInfoResult& result = results[i];
                    if (!first) {
                        json << ",";
                    }
                    first = false;
                    
                    // V2TimGroupInfoResult.fromJson expects:
                    // {
                    //   "get_groups_info_result_code": 0,
                    //   "get_groups_info_result_desc": "",
                    //   "get_groups_info_result_info": {...}
                    // }
                    json << "{";
                    json << "\"get_groups_info_result_code\":" << result.resultCode << ",";
                    std::string result_msg = result.resultMsg.CString();
                    json << "\"get_groups_info_result_desc\":\"" << EscapeJsonString(result_msg) << "\",";
                    
                    // Only include groupInfo if resultCode == 0
                    if (result.resultCode == 0) {
                        std::string group_id = result.info.groupID.CString();
                        std::string group_name = result.info.groupName.CString();
                        std::string group_type_str = result.info.groupType.CString();
                        // Convert groupType string to integer enum value
                        // CGroupType: groupPublic=0, groupPrivate=1, groupChatRoom=2, groupAVChatRoom=4, groupCommunity=5
                        // Note: the Dart side decodes the int back to a label via
                        // GroupType.convertGroupTypeEnum, so the int we emit must be
                        // the inverse of GroupType.convertGroupType for the round-trip
                        // assertion (groupType in == groupType out) to hold for
                        // Meeting/Work/Public/AVChatRoom/Community.
                        int group_type_enum = 0; // Default to Public
                        if (group_type_str == "Work") {
                            group_type_enum = 1; // groupPrivate -> "Work"
                        } else if (group_type_str == "Private") {
                            // Raw "Private" coming from internal createGroup paths
                            // (V2TIMManagerImpl) maps to kTIMGroup_Private, which the
                            // Dart layer surfaces as "Work" — keep this consistent so
                            // joiner-side queries never collapse to the Public default.
                            group_type_enum = 1; // groupPrivate -> "Work"
                        } else if (group_type_str == "Public") {
                            group_type_enum = 0; // groupPublic
                        } else if (group_type_str == "Meeting") {
                            group_type_enum = 2; // groupChatRoom
                        } else if (group_type_str == "AVChatRoom") {
                            group_type_enum = 4; // groupAVChatRoom
                        } else if (group_type_str == "Community") {
                            group_type_enum = 5; // groupCommunity
                        }
                        // V2TimGroupInfo.fromJson expects field names like "group_detail_info_group_id"
                        json << "\"get_groups_info_result_info\":{";
                        json << "\"group_detail_info_group_id\":\"" << EscapeJsonString(group_id) << "\",";
                        json << "\"group_detail_info_group_name\":\"" << EscapeJsonString(group_name) << "\",";
                        json << "\"group_detail_info_group_type\":" << group_type_enum;
                        
                        // Add optional fields with null-safe defaults to prevent null type errors
                        // These fields may not exist in V2TIMGroupInfo, so we provide defaults
                        json << ",\"group_detail_info_approve_option\":null";
                        json << ",\"group_detail_info_add_option\":null";
                        json << ",\"group_detail_info_create_time\":null";
                        json << ",\"group_detail_info_last_info_time\":null";
                        json << ",\"group_detail_info_last_msg_time\":null";
                        json << ",\"group_detail_info_member_num\":null";
                        json << ",\"group_detail_info_online_member_num\":null";
                        json << ",\"group_detail_info_is_support_topic\":null";
                        json << ",\"group_detail_info_enable_permission_group\":false";
                        json << ",\"group_detail_info_max_member_num\":0";
                        json << ",\"group_detail_info_default_permissions\":0";
                        if (!result.info.notification.Empty()) {
                            json << ",\"group_detail_info_notification\":\"" << EscapeJsonString(result.info.notification.CString()) << "\"";
                        } else {
                            json << ",\"group_detail_info_notification\":null";
                        }
                        if (!result.info.introduction.Empty()) {
                            json << ",\"group_detail_info_introduction\":\"" << EscapeJsonString(result.info.introduction.CString()) << "\"";
                        } else {
                            json << ",\"group_detail_info_introduction\":null";
                        }
                        if (!result.info.faceURL.Empty()) {
                            json << ",\"group_detail_info_face_url\":\"" << EscapeJsonString(result.info.faceURL.CString()) << "\"";
                        } else {
                            json << ",\"group_detail_info_face_url\":null";
                        }
                        json << ",\"group_detail_info_is_shutup_all\":null";
                        json << ",\"group_detail_info_owner_identifier\":null";
                        json << ",\"group_detail_info_custom_info\":[]";
                        json << ",\"group_modify_info_param_visible\":null";
                        json << ",\"group_modify_info_param_searchable\":null";
                        json << ",\"group_base_info_self_info\":null";
                        json << "}";
                    } else {
                        // For failed results, set groupInfo to empty object with minimal required fields
                        // Include all fields with null/default values to prevent null type errors
                        json << "\"get_groups_info_result_info\":{";
                        json << "\"group_detail_info_group_id\":\"\",";
                        json << "\"group_detail_info_group_type\":0";
                        json << ",\"group_detail_info_group_name\":null";
                        json << ",\"group_detail_info_approve_option\":null";
                        json << ",\"group_detail_info_add_option\":null";
                        json << ",\"group_detail_info_create_time\":null";
                        json << ",\"group_detail_info_last_info_time\":null";
                        json << ",\"group_detail_info_last_msg_time\":null";
                        json << ",\"group_detail_info_member_num\":null";
                        json << ",\"group_detail_info_online_member_num\":null";
                        json << ",\"group_detail_info_is_support_topic\":null";
                        json << ",\"group_detail_info_enable_permission_group\":false";
                        json << ",\"group_detail_info_max_member_num\":0";
                        json << ",\"group_detail_info_default_permissions\":0";
                        json << ",\"group_detail_info_notification\":null";
                        json << ",\"group_detail_info_introduction\":null";
                        json << ",\"group_detail_info_face_url\":null";
                        json << ",\"group_detail_info_is_shutup_all\":null";
                        json << ",\"group_detail_info_owner_identifier\":null";
                        json << ",\"group_detail_info_custom_info\":[]";
                        json << ",\"group_modify_info_param_visible\":null";
                        json << ",\"group_modify_info_param_searchable\":null";
                        json << ",\"group_base_info_self_info\":null";
                        json << "}";
                    }
                    json << "}";
                }
                json << "]";
                std::string results_json = json.str();
                
                // V2TimValueCallback expects json_param field at top level as a JSON string
                // Build the complete callback JSON with json_param as an escaped string
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(results_json) << "\"}";
                
                SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetGroupsInfo (async)
        // Add defensive checks to ensure objects are fully initialized before calling virtual functions
        // This prevents crashes due to null vtable pointers
        
        V2TIMManager* manager = nullptr;
        try {
            manager = SafeGetV2TIMManager();
        } catch (const std::exception& e) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Exception getting V2TIMManager: {}", e.what());
            fflush(stderr);
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, std::string("Exception getting V2TIMManager: ") + e.what());
            return 1; // Error
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Unknown exception getting V2TIMManager");
            fflush(stderr);
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Unknown exception getting V2TIMManager");
            return 1; // Error
        }
        
        if (!manager) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: SafeGetV2TIMManager() returned null");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_SDK_NOT_INITIALIZED, "V2TIMManager not initialized");
            return 1; // Error
        }
        
        V2TIMGroupManager* groupManager = nullptr;
        try {
            groupManager = manager->GetGroupManager();
        } catch (const std::exception& e) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Exception getting V2TIMGroupManager: {}", e.what());
            fflush(stderr);
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, std::string("Exception getting V2TIMGroupManager: ") + e.what());
            return 1; // Error
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Unknown exception getting V2TIMGroupManager");
            fflush(stderr);
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Unknown exception getting V2TIMGroupManager");
            return 1; // Error
        }
        
        if (!groupManager) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: GetGroupManager() returned null");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "V2TIMGroupManager not available");
            return 1; // Error
        }
        
        // Create callback object before calling GetGroupsInfo
        DartGroupInfoResultVectorCallback* callback = nullptr;
        try {
            callback = new DartGroupInfoResultVectorCallback(user_data);
        } catch (const std::exception& e) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Exception creating callback: {}", e.what());
            fflush(stderr);
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, std::string("Exception creating callback: ") + e.what());
            return 1; // Error
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Unknown exception creating callback");
            fflush(stderr);
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Unknown exception creating callback");
            return 1; // Error
        }
        
        if (!callback) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Failed to create callback object");
            fflush(stderr);
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Failed to create callback");
            return 1; // Error
        }
        
        // Now call GetGroupsInfo with all safety checks in place
        // Note: GetGroupsInfo is synchronous, so the callback will be executed immediately
        // and we need to delete it after the call completes
        try {
            // CRITICAL: This is where the crash happens - calling virtual function on groupManager
            // If groupManager's vtable is null, PC will be 0
            groupManager->GetGroupsInfo(
                group_id_vector,
                callback
            );
            
            // GetGroupsInfo is synchronous, so callback has been executed
            // Delete the callback object to prevent memory leak
            delete callback;
            callback = nullptr;
        } catch (const std::exception& e) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Exception calling GetGroupsInfo: {}", e.what());
            fflush(stderr);
            if (callback) {
                delete callback;
                callback = nullptr;
            }
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, std::string("Exception calling GetGroupsInfo: ") + e.what());
            return 1; // Error
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupsInfo: Unknown exception calling GetGroupsInfo");
            fflush(stderr);
            if (callback) {
                delete callback;
                callback = nullptr;
            }
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Unknown exception calling GetGroupsInfo");
            return 1; // Error
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    } // extern "C"

    // Helper: Parse JSON array of strings (reused from message module)
    static std::vector<std::string> ParseJsonStringArray(const std::string& json_str) {
        std::vector<std::string> result;
        std::string array_str = json_str;
        
        size_t array_start = array_str.find('[');
        if (array_start == std::string::npos) {
            std::string array_field = ExtractJsonValue(json_str, "group_id_list", true);
            if (array_field.empty()) {
                array_field = ExtractJsonValue(json_str, "groupIDList", true);
            }
            if (!array_field.empty() && array_field[0] == '[') {
                array_str = array_field;
                array_start = 0;
            } else {
                return result;
            }
        }
        
        size_t i = array_start + 1;
        std::string current_string;
        bool in_string = false;
        bool escape_next = false;
        
        while (i < array_str.length()) {
            char c = array_str[i];
            
            if (escape_next) {
                if (in_string) {
                    current_string += c;
                }
                escape_next = false;
                i++;
                continue;
            }
            
            if (c == '\\') {
                escape_next = true;
                if (in_string) {
                    current_string += c;
                }
                i++;
                continue;
            }
            
            if (c == '"') {
                in_string = !in_string;
                if (!in_string && !current_string.empty()) {
                    result.push_back(current_string);
                    current_string.clear();
                }
                i++;
                continue;
            }
            
            if (in_string) {
                current_string += c;
            } else if (c == ']') {
                break;
            }
            
            i++;
        }
        
        return result;
    }
    
    extern "C" {
    // DartSetGroupInfo: Set group info
    // Signature: int DartSetGroupInfo(Pointer<Char> json_modify_group_info_param, Pointer<Void> user_data)
    int DartSetGroupInfo(const char* json_modify_group_info_param, void* user_data) {
        
        if (!json_modify_group_info_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON modify group info parameter (Dart SDK sends group_modify_info_param_* keys from V2TimGroupInfoModifyParam.toJson())
        std::string json_str = json_modify_group_info_param;
        std::string group_id = ExtractJsonValue(json_str, "group_modify_info_param_group_id");
        if (group_id.empty()) group_id = ExtractJsonValue(json_str, "modify_group_info_param_group_id");
        std::string group_name = ExtractJsonValue(json_str, "group_modify_info_param_group_name");
        if (group_name.empty()) group_name = ExtractJsonValue(json_str, "modify_group_info_param_group_name");
        std::string group_introduction = ExtractJsonValue(json_str, "group_modify_info_param_introduction");
        if (group_introduction.empty()) group_introduction = ExtractJsonValue(json_str, "modify_group_info_param_group_introduction");
        std::string group_notification = ExtractJsonValue(json_str, "group_modify_info_param_notification");
        if (group_notification.empty()) group_notification = ExtractJsonValue(json_str, "modify_group_info_param_group_notification");
        std::string face_url = ExtractJsonValue(json_str, "group_modify_info_param_face_url");
        if (face_url.empty()) face_url = ExtractJsonValue(json_str, "modify_group_info_param_face_url");
        
        if (group_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartSetGroupInfo: group_id is required");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "group_id is required");
            return 1; // Error
        }
        
        // Create V2TIMGroupInfo
        V2TIMGroupInfo group_info;
        group_info.groupID = V2TIMString(group_id.c_str());
        if (!group_name.empty()) {
            group_info.groupName = V2TIMString(group_name.c_str());
        }
        if (!group_introduction.empty()) {
            group_info.introduction = V2TIMString(group_introduction.c_str());
        }
        if (!group_notification.empty()) {
            group_info.notification = V2TIMString(group_notification.c_str());
        }
        if (!face_url.empty()) {
            group_info.faceURL = V2TIMString(face_url.c_str());
        }
        
        // Call V2TIM SetGroupInfo (async)
        SafeGetV2TIMManager()->GetGroupManager()->SetGroupInfo(
            group_info,
            new DartCallback(
                user_data,
                [user_data]() {
                    // OnSuccess
                    SendApiCallbackResult(user_data, 0, "");
                },
                [user_data](int error_code, const V2TIMString& error_message) {
                    // OnError
                    std::string error_msg = error_message.CString();
                    SendApiCallbackResult(user_data, error_code, error_msg);
                }
            )
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetGroupMemberList: Get group member list
    // Signature: int DartGetGroupMemberList(Pointer<Char> json_group_get_member_infos_param, Pointer<Void> user_data)
    // Note: Dart layer passes a single JSON parameter containing both group_id and other params
    int DartGetGroupMemberList(const char* json_group_get_member_infos_param, void* user_data) {
        
        if (!json_group_get_member_infos_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON parameter to extract group_id and other params
        std::string json_str = json_group_get_member_infos_param;
        std::string group_id = ExtractJsonValue(json_str, "group_get_members_info_list_param_group_id");
        
        if (group_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupMemberList: group_id is required in JSON parameter");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "group_id is required");
            return 1; // Error
        }
        
        // Parse other JSON parameters
        int filter = ExtractJsonInt(json_str, "group_get_members_info_list_param_option", 0);
        // Try alternative field names
        if (filter == 0) {
            filter = ExtractJsonInt(json_str, "get_group_member_list_param_filter", 0);
        }
        uint64_t next_seq = static_cast<uint64_t>(ExtractJsonInt(json_str, "group_get_members_info_list_param_next_seq", 0));
        if (next_seq == 0) {
            next_seq = static_cast<uint64_t>(ExtractJsonInt(json_str, "get_group_member_list_param_next_seq", 0));
        }
        
        // Helper class for V2TIMValueCallback<V2TIMGroupMemberInfoResult>
        class DartGroupMemberInfoResultCallback : public V2TIMValueCallback<V2TIMGroupMemberInfoResult> {
        private:
            void* user_data_;
            
        public:
            DartGroupMemberInfoResultCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMGroupMemberInfoResult& result) override {
                // Convert to JSON format expected by V2TimGroupMemberInfoResult.fromJson
                // Expected fields: group_get_member_info_list_result_next_seq, group_get_member_info_list_result_info_array
                std::ostringstream json;
                json << "{";
                json << "\"group_get_member_info_list_result_next_seq\":" << result.nextSequence << ",";
                json << "\"group_get_member_info_list_result_info_array\":[";
                for (size_t i = 0; i < result.memberInfoList.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMGroupMemberFullInfo& member = result.memberInfoList[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    std::string user_id = member.userID.CString();
                    std::string nick_name = member.nickName.CString();
                    std::string name_card = member.nameCard.CString();
                    std::string face_url = member.faceURL.CString();
                    // Use the expected field names for V2TimGroupMemberFullInfo.fromJson
                    json << "\"group_member_info_identifier\":\"" << EscapeJsonString(user_id) << "\",";
                    json << "\"group_member_info_nick_name\":\"" << EscapeJsonString(nick_name) << "\",";
                    if (!name_card.empty()) {
                        json << "\"group_member_info_name_card\":\"" << EscapeJsonString(name_card) << "\",";
                    }
                    json << "\"group_member_info_face_url\":\"" << EscapeJsonString(face_url) << "\",";
                    json << "\"group_member_info_join_time\":" << static_cast<int64_t>(member.joinTime) << ",";
                    json << "\"group_member_info_member_role\":" << static_cast<int>(member.role);
                    json << "}";
                }
                json << "]";
                json << "}";
                std::string json_str = json.str();
                // Send as json_param (will be parsed by V2TimValueCallback.fromJson)
                SendApiCallbackResult(user_data_, 0, "", json_str);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetGroupMemberList (async)
        SafeGetV2TIMManager()->GetGroupManager()->GetGroupMemberList(
            V2TIMString(group_id.c_str()),
            static_cast<V2TIMGroupMemberFilter>(filter),
            next_seq,
            new DartGroupMemberInfoResultCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartInviteUserToGroup: Invite user to group
    // Signature: int DartInviteUserToGroup(Pointer<Char> json_group_invite_member_param, Pointer<Void> user_data)
    // Note: Dart layer passes a single JSON parameter containing both group_id and userList
    int DartInviteUserToGroup(const char* json_group_invite_member_param, void* user_data) {
        if (!json_group_invite_member_param || !user_data) {
            V2TIM_LOG(kError, "[dart_compat] DartInviteUserToGroup: Invalid parameters - json_param={}, user_data={}",
                      (void*)json_group_invite_member_param, (void*)user_data);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }

        std::string json_str = json_group_invite_member_param;
        std::string group_id = ExtractJsonValue(json_str, "group_invite_member_param_group_id");

        if (group_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartInviteUserToGroup: group_id is required in JSON parameter");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "group_id is required");
            return 1;
        }
        // Optional instance_id: use this instance for invite (inviter's instance) so we use the correct friend list
        int64_t invite_instance_id = 0;
        std::string instance_id_str = ExtractJsonValue(json_str, "group_invite_member_param_instance_id");
        if (instance_id_str.empty()) {
            instance_id_str = ExtractJsonValue(json_str, "instance_id");
        }
        if (!instance_id_str.empty()) {
            try {
                invite_instance_id = std::stoll(instance_id_str);
            } catch (...) {
                V2TIM_LOG(kWarning, "[dart_compat] DartInviteUserToGroup: Failed to parse instance_id '{}', using current instance", instance_id_str);
            }
        }
        
        // Parse user ID list from JSON
        // ExtractJsonValue cannot extract JSON arrays, so we need to extract the array directly from JSON string
        std::vector<std::string> user_ids;
        
        // Try to find the array field in the JSON string directly
        std::string array_field_name = "group_invite_member_param_identifier_array";
        size_t field_pos = json_str.find("\"" + array_field_name + "\"");
        if (field_pos != std::string::npos) {
            // Find the colon after the field name
            size_t colon_pos = json_str.find(':', field_pos);
            if (colon_pos != std::string::npos) {
                // Find the opening bracket
                size_t bracket_start = json_str.find('[', colon_pos);
                if (bracket_start != std::string::npos) {
                    // Find the matching closing bracket
                    int bracket_count = 1;
                    size_t bracket_end = bracket_start + 1;
                    while (bracket_end < json_str.length() && bracket_count > 0) {
                        if (json_str[bracket_end] == '[') bracket_count++;
                        else if (json_str[bracket_end] == ']') bracket_count--;
                        bracket_end++;
                    }
                    if (bracket_count == 0) {
                        std::string array_str = json_str.substr(bracket_start, bracket_end - bracket_start);
                        user_ids = ParseJsonStringArray(array_str);
                    }
                }
            }
        }
        
        // Fallback: Try other field names
        if (user_ids.empty()) {
            std::vector<std::string> fallback_names = {"identifier_array", "userList", "user_list"};
            for (const auto& field_name : fallback_names) {
                size_t field_pos = json_str.find("\"" + field_name + "\"");
                if (field_pos != std::string::npos) {
                    size_t colon_pos = json_str.find(':', field_pos);
                    if (colon_pos != std::string::npos) {
                        size_t bracket_start = json_str.find('[', colon_pos);
                        if (bracket_start != std::string::npos) {
                            int bracket_count = 1;
                            size_t bracket_end = bracket_start + 1;
                            while (bracket_end < json_str.length() && bracket_count > 0) {
                                if (json_str[bracket_end] == '[') bracket_count++;
                                else if (json_str[bracket_end] == ']') bracket_count--;
                                bracket_end++;
                            }
                            if (bracket_count == 0) {
                                std::string array_str = json_str.substr(bracket_start, bracket_end - bracket_start);
                                user_ids = ParseJsonStringArray(array_str);
                                if (!user_ids.empty()) break;
                            }
                        }
                    }
                }
            }
        }
        
        if (user_ids.empty() && json_str.length() > 0 && json_str[0] == '[') {
            user_ids = ParseJsonStringArray(json_str);
        }
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartInviteUserToGroup: user_id list is empty after parsing. JSON string was: {}", json_str);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Helper class for V2TIMValueCallback<V2TIMGroupMemberOperationResultVector>
        class DartGroupMemberOperationResultVectorCallback : public V2TIMValueCallback<V2TIMGroupMemberOperationResultVector> {
        private:
            void* user_data_;
            
        public:
            DartGroupMemberOperationResultVectorCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMGroupMemberOperationResultVector& results) override {
                // Convert to JSON
                std::ostringstream json;
                json << "[";
                for (size_t i = 0; i < results.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMGroupMemberOperationResult& result = results[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    std::string user_id = result.userID.CString();
                    // Use the expected field names for V2TimGroupMemberOperationResult.fromJson
                    json << "\"group_invite_member_result_identifier\":\"" << EscapeJsonString(user_id) << "\",";
                    json << "\"group_invite_member_result_result\":" << static_cast<int>(result.result);
                    json << "}";
                }
                json << "]";
                std::string results_json = json.str();
                
                // V2TimValueCallback expects json_param field at top level as a JSON string
                // Build the complete callback JSON with json_param as an escaped string
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(results_json) << "\"}";
                
                SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Use inviter's instance when instance_id is provided; otherwise use current instance
        V2TIMManager* manager = nullptr;
        if (invite_instance_id != 0) {
            manager = GetManagerForInstanceId(invite_instance_id);
        }
        if (!manager) {
            manager = SafeGetV2TIMManager();
        }
        if (!manager) {
            V2TIM_LOG(kError, "[dart_compat] DartInviteUserToGroup: No manager available");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "No manager available");
            return 1;
        }
        
        // Call V2TIM InviteUserToGroup (async)
        manager->GetGroupManager()->InviteUserToGroup(
            V2TIMString(group_id.c_str()),
            user_id_vector,
            new DartGroupMemberOperationResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartKickGroupMember: Kick group member
    // Signature: int DartKickGroupMember(Pointer<Char> json_group_delete_param, Pointer<Void> user_data)
    // SDK passes a single JSON object: group_delete_member_param_group_id, group_delete_member_param_identifier_array, group_delete_member_param_user_data (reason)
    int DartKickGroupMember(const char* json_group_delete_param, void* user_data) {
        if (!json_group_delete_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        std::string json_str = json_group_delete_param;
        std::string group_id = ExtractJsonValue(json_str, "group_delete_member_param_group_id");
        if (group_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartKickGroupMember: group_id required in JSON");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "group_id required");
            return 1; // Error
        }
        
        std::string reason_str = ExtractJsonValue(json_str, "group_delete_member_param_user_data");
        
        std::vector<std::string> user_ids;
        std::string array_field_name = "group_delete_member_param_identifier_array";
        size_t field_pos = json_str.find("\"" + array_field_name + "\"");
        if (field_pos != std::string::npos) {
            size_t colon_pos = json_str.find(':', field_pos);
            if (colon_pos != std::string::npos) {
                size_t bracket_start = json_str.find('[', colon_pos);
                if (bracket_start != std::string::npos) {
                    int bracket_count = 1;
                    size_t bracket_end = bracket_start + 1;
                    while (bracket_end < json_str.length() && bracket_count > 0) {
                        if (json_str[bracket_end] == '[') bracket_count++;
                        else if (json_str[bracket_end] == ']') bracket_count--;
                        bracket_end++;
                    }
                    if (bracket_count == 0) {
                        std::string array_str = json_str.substr(bracket_start, bracket_end - bracket_start);
                        user_ids = ParseJsonStringArray(array_str);
                    }
                }
            }
        }
        if (user_ids.empty()) {
            std::vector<std::string> fallback_names = {"identifier_array", "memberList", "user_list"};
            for (const auto& fn : fallback_names) {
                size_t fp = json_str.find("\"" + fn + "\"");
                if (fp != std::string::npos) {
                    size_t cp = json_str.find(':', fp);
                    if (cp != std::string::npos) {
                        size_t bs = json_str.find('[', cp);
                        if (bs != std::string::npos) {
                            int bc = 1;
                            size_t be = bs + 1;
                            while (be < json_str.length() && bc > 0) {
                                if (json_str[be] == '[') bc++;
                                else if (json_str[be] == ']') bc--;
                                be++;
                            }
                            if (bc == 0) {
                                user_ids = ParseJsonStringArray(json_str.substr(bs, be - bs));
                                if (!user_ids.empty()) break;
                            }
                        }
                    }
                }
            }
        }
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartKickGroupMember: user_id list is empty after parsing JSON");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        std::string op_user_id = SafeGetV2TIMManager() ? SafeGetV2TIMManager()->GetLoginUser().CString() : "";
        
        // Helper class for V2TIMValueCallback<V2TIMGroupMemberOperationResultVector>
        // OnSuccess notifies other instances (onMemberKicked) then sends api callback.
        class DartKickGroupMemberCallback : public V2TIMValueCallback<V2TIMGroupMemberOperationResultVector> {
        private:
            void* user_data_;
            std::string group_id_;
            std::string op_user_id_;
            std::vector<std::string> kicked_user_ids_;
            
        public:
            DartKickGroupMemberCallback(void* user_data, const std::string& group_id,
                                        const std::string& op_user_id, const std::vector<std::string>& kicked_user_ids)
                : user_data_(user_data), group_id_(group_id), op_user_id_(op_user_id), kicked_user_ids_(kicked_user_ids) {}
            
            void OnSuccess(const V2TIMGroupMemberOperationResultVector& results) override {
                V2TIM_LOG(kInfo, "[CALL_PATH] DartKickGroupMemberCallback OnSuccess: group_id={}, op={}, kicked_count={}, calling NotifyOtherInstancesMemberKicked",
                          group_id_, op_user_id_.empty() ? "(empty)" : op_user_id_, kicked_user_ids_.size());
                if (!op_user_id_.empty() && !kicked_user_ids_.empty()) {
                    NotifyOtherInstancesMemberKicked(group_id_, op_user_id_, kicked_user_ids_);
                }
                std::ostringstream json;
                json << "[";
                for (size_t i = 0; i < results.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMGroupMemberOperationResult& result = results[i];
                    json << "{";
                    std::string user_id = result.userID.CString();
                    json << "\"group_invite_member_result_identifier\":\"" << EscapeJsonString(user_id) << "\",";
                    json << "\"group_invite_member_result_result\":" << static_cast<int>(result.result);
                    json << "}";
                }
                json << "]";
                std::string results_json = json.str();
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(results_json) << "\"}";
                SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        SafeGetV2TIMManager()->GetGroupManager()->KickGroupMember(
            V2TIMString(group_id),
            user_id_vector,
            V2TIMString(reason_str.c_str()),
            new DartKickGroupMemberCallback(user_data, group_id, op_user_id, user_ids)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetGroupMembersInfo: Get specific group members info
    // Signature: int DartGetGroupMembersInfo(Pointer<Char> json_group_get_members_info_param, Pointer<Void> user_data)
    // Note: Dart layer passes a single JSON parameter containing group_id and memberList
    int DartGetGroupMembersInfo(const char* json_group_get_members_info_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartGetGroupMembersInfo: ENTRY json_str_first200={}",
                  json_group_get_members_info_param ? std::string(json_group_get_members_info_param).substr(0, 200) : std::string("<null>"));
        if (!json_group_get_members_info_param || !user_data) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupMembersInfo: Invalid parameters - json_param={}, user_data={}",
                      (void*)json_group_get_members_info_param, (void*)user_data);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }

        std::string json_str = json_group_get_members_info_param;
        // The Tencent SDK 8.9.x adapter (tim_group_manager.dart) and the
        // Tim2ToxSdkPlatform binding use slightly different JSON field names
        // for the same DartGetGroupMembersInfo entry point:
        //   • 8.9 native_im adapter (GroupGetMemberInfoListParam.toJson):
        //       group_get_members_info_list_param_group_id
        //       group_get_members_info_list_param_identifier_array
        //   • Tim2ToxSdkPlatform.getGroupMembersInfo:
        //       group_get_members_info_param_group_id
        //       group_get_members_info_param_identifier_array
        // Accept both so binary-replacement-path callers don't get a phantom
        // 6017 ("invalid parameter") that never reaches the C++ search loop.
        std::string group_id = ExtractJsonValue(json_str, "group_get_members_info_param_group_id");
        if (group_id.empty()) {
            group_id = ExtractJsonValue(json_str, "group_get_members_info_list_param_group_id");
        }

        if (group_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupMembersInfo: group_id is required in JSON parameter");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "group_id is required");
            return 1;
        }
        // Parse member ID list from JSON. Try both the platform-path
        // (`_param_identifier_array`) and the 8.9 native-adapter
        // (`_list_param_identifier_array`) names before falling back.
        std::vector<std::string> member_ids;

        auto try_extract_array = [&](const std::string& array_field_name) -> bool {
            size_t field_pos = json_str.find("\"" + array_field_name + "\"");
            if (field_pos == std::string::npos) return false;
            size_t colon_pos = json_str.find(':', field_pos);
            if (colon_pos == std::string::npos) return false;
            size_t bracket_start = json_str.find('[', colon_pos);
            if (bracket_start == std::string::npos) return false;
            int bracket_count = 1;
            size_t bracket_end = bracket_start + 1;
            while (bracket_end < json_str.length() && bracket_count > 0) {
                if (json_str[bracket_end] == '[') bracket_count++;
                else if (json_str[bracket_end] == ']') bracket_count--;
                bracket_end++;
            }
            if (bracket_count != 0) return false;
            std::string array_str = json_str.substr(bracket_start, bracket_end - bracket_start);
            member_ids = ParseJsonStringArray(array_str);
            return !member_ids.empty();
        };

        if (!try_extract_array("group_get_members_info_param_identifier_array")) {
            try_extract_array("group_get_members_info_list_param_identifier_array");
        }
        if (member_ids.empty()) {
            std::vector<std::string> fallback_names = {"identifier_array", "memberList", "member_list"};
            for (const auto& field_name : fallback_names) {
                size_t field_pos = json_str.find("\"" + field_name + "\"");
                if (field_pos != std::string::npos) {
                    size_t colon_pos = json_str.find(':', field_pos);
                    if (colon_pos != std::string::npos) {
                        size_t bracket_start = json_str.find('[', colon_pos);
                        if (bracket_start != std::string::npos) {
                            int bracket_count = 1;
                            size_t bracket_end = bracket_start + 1;
                            while (bracket_end < json_str.length() && bracket_count > 0) {
                                if (json_str[bracket_end] == '[') bracket_count++;
                                else if (json_str[bracket_end] == ']') bracket_count--;
                                bracket_end++;
                            }
                            if (bracket_count == 0) {
                                std::string array_str = json_str.substr(bracket_start, bracket_end - bracket_start);
                                member_ids = ParseJsonStringArray(array_str);
                                if (!member_ids.empty()) break;
                            }
                        }
                    }
                }
            }
        }
        if (member_ids.empty()) {
            member_ids = ParseJsonStringArray(json_str);
        }
        if (member_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartGetGroupMembersInfo: member_id list is empty after parsing. JSON string was: {}", json_str);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "member_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector member_id_vector;
        for (const auto& member_id : member_ids) {
            member_id_vector.PushBack(V2TIMString(member_id.c_str()));
        }
        
        // Helper class for V2TIMValueCallback<V2TIMGroupMemberFullInfoVector>
        class DartGroupMemberFullInfoVectorCallback : public V2TIMValueCallback<V2TIMGroupMemberFullInfoVector> {
        private:
            void* user_data_;
            
        public:
            DartGroupMemberFullInfoVectorCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMGroupMemberFullInfoVector& results) override {
                // Convert to JSON format expected by V2TimGroupMemberFullInfoVector.fromJson
                std::ostringstream json;
                json << "[";
                for (size_t i = 0; i < results.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMGroupMemberFullInfo& member = results[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    std::string user_id = member.userID.CString();
                    std::string nick_name = member.nickName.CString();
                    std::string name_card = member.nameCard.CString();
                    std::string face_url = member.faceURL.CString();
                    // Use the expected field names for V2TimGroupMemberFullInfo.fromJson
                    json << "\"group_member_info_identifier\":\"" << EscapeJsonString(user_id) << "\",";
                    json << "\"group_member_info_nick_name\":\"" << EscapeJsonString(nick_name) << "\",";
                    if (!name_card.empty()) {
                        json << "\"group_member_info_name_card\":\"" << EscapeJsonString(name_card) << "\",";
                    }
                    json << "\"group_member_info_face_url\":\"" << EscapeJsonString(face_url) << "\",";
                    json << "\"group_member_info_join_time\":" << static_cast<int64_t>(member.joinTime) << ",";
                    json << "\"group_member_info_member_role\":" << static_cast<int>(member.role);
                    json << "}";
                }
                json << "]";
                std::string results_json = json.str();
                // V2TimValueCallback expects json_param field at top level as a JSON string
                // Build the complete callback JSON with json_param as an escaped string
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(results_json) << "\"}";
                
                SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetGroupMembersInfo (async)
        SafeGetV2TIMManager()->GetGroupManager()->GetGroupMembersInfo(
            V2TIMString(group_id.c_str()),
            member_id_vector,
            new DartGroupMemberFullInfoVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSearchGroups: Search groups by keyword
    // Signature: int DartSearchGroups(Pointer<Char> json_search_groups_param, Pointer<Void> user_data)
    int DartSearchGroups(const char* json_search_groups_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSearchGroups");
        fflush(stdout);

        if (!json_search_groups_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }

        // Parse JSON search parameter
        std::string json_str = json_search_groups_param;
        V2TIMGroupSearchParam searchParam;

        // Parse keyword list
        std::string keyword_list_str = ExtractJsonValue(json_str, "group_search_params_keyword_list");
        if (!keyword_list_str.empty()) {
            std::vector<std::string> keywords = ParseJsonStringArray(keyword_list_str);
            for (const auto& keyword : keywords) {
                searchParam.keywordList.PushBack(V2TIMString(keyword.c_str()));
            }
        }

        // Parse search field flags
        std::string field_list_str = ExtractJsonValue(json_str, "group_search_params_field_list");
        if (!field_list_str.empty()) {
            // field_list is an array of ints: 1 = GroupId, 2 = GroupName
            std::vector<std::string> fields = ParseJsonStringArray(field_list_str);
            bool searchGroupID = false;
            bool searchGroupName = false;
            for (const auto& f : fields) {
                int val = 0;
                try { val = std::stoi(f); } catch (...) {}
                if (val == 0x01) searchGroupID = true;
                if (val == 0x02) searchGroupName = true;
            }
            searchParam.isSearchGroupID = searchGroupID;
            searchParam.isSearchGroupName = searchGroupName;
        } else {
            // Default to searching both
            searchParam.isSearchGroupID = true;
            searchParam.isSearchGroupName = true;
        }

        // Call V2TIM SearchGroups (async)
        SafeGetV2TIMManager()->GetGroupManager()->SearchGroups(
            searchParam,
            new DartGroupInfoVectorCallback(user_data)
        );

        return 0; // TIM_SUCC (request accepted)
    }

} // extern "C"

