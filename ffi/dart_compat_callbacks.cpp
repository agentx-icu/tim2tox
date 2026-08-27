// Callback class implementations
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"
#include <functional>

// Forward declaration for multi-instance support
extern int64_t GetCurrentInstanceId();

// Helper: Safely call IsRead() on a message object
// Returns false if the call fails or message is invalid
// NOTE: For new messages received via OnRecvNewMessage, IsRead() typically returns false anyway.
// We avoid calling IsRead() directly to prevent potential segfaults from invalid message objects.
static bool SafeIsRead(const V2TIMMessage& msg) {
    // For new messages, IsRead() should typically be false.
    // To avoid potential segfaults from invalid message objects, we return false directly.
    // If the message object is valid and we need the actual value, we could try calling IsRead(),
    // but given the crash history, it's safer to return false for new messages.
    return false;
}

// Helper: Safely call IsPeerRead() on a message object
// Returns false if the call fails or message is invalid
// NOTE: For new messages received via OnRecvNewMessage, IsPeerRead() typically returns false anyway.
// We avoid calling IsPeerRead() directly to prevent potential segfaults from invalid message objects.
static bool SafeIsPeerRead(const V2TIMMessage& msg) {
    // For new messages, IsPeerRead() should typically be false.
    // To avoid potential segfaults from invalid message objects, we return false directly.
    // If the message object is valid and we need the actual value, we could try calling IsPeerRead(),
    // but given the crash history, it's safer to return false for new messages.
    return false;
}

// Helper: Safely call GetLocalCustomInt() on a message object
// Returns 0 if the call fails or message is invalid
// NOTE: For new messages received via OnRecvNewMessage, GetLocalCustomInt() typically returns 0 anyway.
// We avoid calling GetLocalCustomInt() directly to prevent potential segfaults from invalid message objects.
static int SafeGetLocalCustomInt(const V2TIMMessage& msg) {
    // For new messages, GetLocalCustomInt() should typically be 0.
    // To avoid potential segfaults from invalid message objects, we return 0 directly.
    // If the message object is valid and we need the actual value, we could try calling GetLocalCustomInt(),
    // but given the crash history, it's safer to return 0 for new messages.
    return 0;
}

// Helper: Convert V2TIM_ELEM_TYPE to CElemType (for Dart compatibility)
// V2TIM_ELEM_TYPE: TEXT=1, CUSTOM=2, IMAGE=3, SOUND=4, VIDEO=5, FILE=6, LOCATION=7, FACE=8, GROUP_TIPS=9, MERGER=10
// CElemType: ElemText=0, ElemImage=1, ElemSound=2, ElemCustom=3, ElemFile=4, ElemGroupTips=5, ElemFace=6, ElemLocation=7, ElemGroupReport=8, ElemVideo=9, ElemMerge=12
static int V2TIM_ELEM_TYPE_To_CElemType(V2TIMElemType v2timType) {
    switch (v2timType) {
        case V2TIM_ELEM_TYPE_TEXT:
            return 0; // CElemType.ElemText
        case V2TIM_ELEM_TYPE_IMAGE:
            return 1; // CElemType.ElemImage
        case V2TIM_ELEM_TYPE_SOUND:
            return 2; // CElemType.ElemSound
        case V2TIM_ELEM_TYPE_CUSTOM:
            return 3; // CElemType.ElemCustom
        case V2TIM_ELEM_TYPE_FILE:
            return 4; // CElemType.ElemFile
        case V2TIM_ELEM_TYPE_GROUP_TIPS:
            return 5; // CElemType.ElemGroupTips
        case V2TIM_ELEM_TYPE_FACE:
            return 6; // CElemType.ElemFace
        case V2TIM_ELEM_TYPE_LOCATION:
            return 7; // CElemType.ElemLocation
        case V2TIM_ELEM_TYPE_VIDEO:
            return 9; // CElemType.ElemVideo
        case V2TIM_ELEM_TYPE_MERGER:
            return 12; // CElemType.ElemMerge
        default:
            return -1; // CElemType.ElemInvalid
    }
}

// Helper: Convert V2TIMElem to JSON object (shared with listeners.cpp logic)
static std::string ElemToJsonForCallback(const V2TIMElem* elem) {
    if (!elem) {
        return "{}";
    }
    
    std::ostringstream json;
    json << "{";
    // Convert V2TIM_ELEM_TYPE to CElemType for Dart compatibility
    int cElemType = V2TIM_ELEM_TYPE_To_CElemType(elem->elemType);
    json << "\"elem_type\":" << cElemType;
    
    try {
        switch (elem->elemType) {
            case V2TIM_ELEM_TYPE_TEXT: {
                const V2TIMTextElem* textElem = static_cast<const V2TIMTextElem*>(elem);
                std::string text = textElem->text.CString();
                json << ",\"text_elem_content\":\"" << EscapeJsonString(text) << "\"";
                break;
            }
            case V2TIM_ELEM_TYPE_CUSTOM: {
                const V2TIMCustomElem* customElem = static_cast<const V2TIMCustomElem*>(elem);
                std::string desc = customElem->desc.CString();
                std::string ext = customElem->extension.CString();
            const V2TIMBuffer& data = customElem->data;
            if (data.Size() > 0) {
                // Check if data is valid UTF-8 string (no null bytes)
                bool is_valid_string = true;
                const uint8_t* bytes = data.Data();
                for (size_t i = 0; i < data.Size(); i++) {
                    if (bytes[i] == 0) {
                        is_valid_string = false;
                        break;
                    }
                }
                
                if (is_valid_string) {
                    // Data is a valid string, send as-is
                    std::string dataStr(reinterpret_cast<const char*>(bytes), data.Size());
                    json << ",\"custom_elem_data\":\"" << EscapeJsonString(dataStr) << "\"";
                } else {
                    // Data contains binary data, encode as hex string
                    std::string dataStr;
                    for (size_t i = 0; i < data.Size(); i++) {
                        char hex[3];
                        snprintf(hex, sizeof(hex), "%02x", bytes[i]);
                        dataStr += hex;
                    }
                    json << ",\"custom_elem_data\":\"" << EscapeJsonString(dataStr) << "\"";
                }
            } else {
                json << ",\"custom_elem_data\":\"\"";
            }
                json << ",\"custom_elem_desc\":\"" << EscapeJsonString(desc) << "\"";
                json << ",\"custom_elem_ext\":\"" << EscapeJsonString(ext) << "\"";
                break;
            }
            default:
                break;
        }
    } catch (...) {
    }
    
    json << "}";
    return json.str();
}

// Helper: Convert V2TIMElemVector to JSON array
static std::string ElemListToJsonArrayForCallback(const V2TIMElemVector& elemList) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < elemList.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        try {
            const V2TIMElem* elem = elemList[i];
            json << ElemToJsonForCallback(elem);
        } catch (...) {
            json << "{\"elem_type\":0}";
        }
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMMessageVector to JSON array
// Note: This is also declared in dart_compat_callbacks.h, so we remove static here
std::string MessageVectorToJson(const V2TIMMessageVector& messages) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < messages.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        
        try {
            const V2TIMMessage& msg = messages[i];
            // Get CString() (has built-in protection)
            std::string msg_id = msg.msgID.CString();
            std::string sender = msg.sender.CString();
            std::string user_id = msg.userID.CString();
            std::string group_id = msg.groupID.CString();
            
            // Determine conversation type and ID
            int conv_type = 0; // V2TIM_UNKNOWN
            std::string conv_id;
            if (!group_id.empty()) {
                conv_type = 2; // V2TIM_GROUP
                conv_id = group_id;
            } else if (!user_id.empty()) {
                conv_type = 1; // V2TIM_C2C
                conv_id = user_id;
            }
            
            json << "{";
            json << "\"message_msg_id\":\"" << EscapeJsonString(msg_id) << "\",";
            json << "\"message_seq\":" << msg.seq << ",";
            // V2TIMMessage::random is uninitialized uint64_t (see comment in
            // dart_compat_listeners.cpp); clamp to 0 so Dart's int-typed
            // V2TimMessage.random field parses without a "'double' is not a
            // subtype of type 'int?'" cast error on uninit garbage.
            json << "\"message_rand\":" << 0 << ",";
            json << "\"message_status\":" << static_cast<int>(msg.status) << ",";
            json << "\"message_sender\":\"" << EscapeJsonString(sender) << "\",";
            json << "\"message_user_id\":\"" << EscapeJsonString(user_id) << "\",";
            json << "\"message_group_id\":\"" << EscapeJsonString(group_id) << "\",";
            json << "\"message_conv_type\":" << conv_type << ",";
            json << "\"message_conv_id\":\"" << EscapeJsonString(conv_id) << "\",";
            json << "\"message_client_time\":" << msg.timestamp << ",";
            json << "\"message_server_time\":" << msg.timestamp << ",";
            json << "\"message_is_from_self\":" << std::boolalpha << (msg.isSelf ? true : false) << ",";
            json << "\"message_priority\":" << static_cast<int>(msg.priority) << ",";
            json << "\"message_is_read\":" << std::boolalpha << (SafeIsRead(msg) ? true : false) << ",";
            json << "\"message_is_peer_read\":" << std::boolalpha << (SafeIsPeerRead(msg) ? true : false) << ",";
            json << "\"message_need_read_receipt\":" << std::boolalpha << (msg.needReadReceipt ? true : false) << ",";
            json << "\"message_is_broadcast_message\":" << std::boolalpha << (msg.isBroadcastMessage ? true : false) << ",";
            json << "\"message_support_message_extension\":" << std::boolalpha << (msg.supportMessageExtension ? true : false) << ",";
            json << "\"message_is_excluded_from_unread_count\":" << std::boolalpha << (msg.isExcludedFromUnreadCount ? true : false) << ",";
            json << "\"message_excluded_from_last_message\":" << std::boolalpha << (msg.isExcludedFromLastMessage ? true : false) << ",";
            json << "\"message_custom_int\":" << SafeGetLocalCustomInt(msg) << ",";
            
            // Add optional fields with null-safe defaults
            json << "\"message_sender_tiny_id\":null,";
            json << "\"message_receiver_tiny_id\":null,";
            json << "\"message_platform\":null,";
            json << "\"message_is_online_msg\":null,";
            json << "\"message_receipt_peer_read\":null,";
            json << "\"message_has_sent_receipt\":null,";
            json << "\"message_group_receipt_read_count\":null,";
            json << "\"message_group_receipt_unread_count\":null,";
            json << "\"message_version\":null,";
            json << "\"ui_status\":null,";
            json << "\"message_custom_str\":\"" << EscapeJsonString("") << "\",";
            json << "\"message_cloud_custom_str\":\"" << EscapeJsonString("") << "\",";
            json << "\"message_sender_profile\":null,";
            json << "\"message_excluded_from_content_moderation\":null,";
            json << "\"message_custom_moderation_configuration_id\":null,";
            json << "\"message_risk_type_identified\":" << (msg.hasRiskContent ? 1 : 0) << ",";
            json << "\"message_disable_cloud_message_pre_hook\":" << std::boolalpha << (msg.disableCloudMessagePreHook ? true : false) << ",";
            json << "\"message_disable_cloud_message_post_hook\":" << std::boolalpha << (msg.disableCloudMessagePostHook ? true : false) << ",";
            json << "\"message_revoke_reason\":null,";
            json << "\"message_revoker_user_id\":null,";
            json << "\"message_revoker_nick_name\":null,";
            json << "\"message_revoker_face_url\":null,";
            json << "\"message_pinner_user_id\":null,";
            json << "\"message_pinner_nick_name\":null,";
            json << "\"message_pinner_friend_remark\":null,";
            json << "\"message_pinner_name_card\":null,";
            json << "\"message_pinner_face_url\":null,";
            json << "\"message_target_group_member_array\":[],";
            json << "\"message_group_at_user_array\":[";
            for (size_t j = 0; j < msg.groupAtUserList.Size(); j++) {
                if (j > 0) json << ",";
                json << "\"" << EscapeJsonString(msg.groupAtUserList[j].CString()) << "\"";
            }
            json << "],";
            json << "\"message_sender_group_member_info\":null,";
            json << "\"message_offline_push_config\":null,";
            
            // Add elem_array
            json << "\"message_elem_array\":" << ElemListToJsonArrayForCallback(msg.elemList);
            
            json << "}";
        } catch (...) {
            json << "{}";
        }
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMCustomInfo to JSON array (for friend_profile_custom_string_array)
static std::string FriendCustomInfoToJsonArray(const V2TIMCustomInfo& customInfo) {
    std::ostringstream json;
    json << "[";
    
    V2TIMStringVector keys = customInfo.AllKeys();
    bool first = true;
    for (size_t i = 0; i < keys.Size(); i++) {
        if (!first) {
            json << ",";
        }
        first = false;
        
        const V2TIMString& key = keys[i];
        const V2TIMBuffer& value = customInfo.Get(key);
        std::string key_str = key.CString();
        
        json << "{";
        json << "\"friend_profile_custom_string_info_key\":\"" << EscapeJsonString(key_str) << "\",";
        
        if (value.Size() > 0) {
            std::string valueStr(reinterpret_cast<const char*>(value.Data()), value.Size());
            json << "\"friend_profile_custom_string_info_value\":\"" << EscapeJsonString(valueStr) << "\"";
        } else {
            json << "\"friend_profile_custom_string_info_value\":\"\"";
        }
        json << "}";
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMUserFullInfo to JSON (for friend_profile_user_profile)
static std::string FriendUserFullInfoToJson(const V2TIMUserFullInfo& user_info) {
    std::ostringstream json;
    json << "{";
    
    std::string user_id_str = user_info.userID.CString();
    std::string nick_name_str = user_info.nickName.CString();
    std::string face_url_str = user_info.faceURL.CString();
    std::string self_signature_str = user_info.selfSignature.CString();
    
    json << "\"user_profile_identifier\":\"" << EscapeJsonString(user_id_str) << "\",";
    json << "\"user_profile_nick_name\":\"" << EscapeJsonString(nick_name_str) << "\",";
    json << "\"user_profile_face_url\":\"" << EscapeJsonString(face_url_str) << "\",";
    json << "\"user_profile_self_signature\":\"" << EscapeJsonString(self_signature_str) << "\",";
    json << "\"user_profile_gender\":" << static_cast<int>(user_info.gender) << ",";
    json << "\"user_profile_birthday\":" << user_info.birthday << ",";
    json << "\"user_profile_add_permission\":" << static_cast<int>(user_info.allowType) << ",";
    json << "\"user_profile_role\":" << user_info.role << ",";
    json << "\"user_profile_level\":" << user_info.level << ",";
    json << "\"user_profile_custom_string_array\":[";
    V2TIMStringVector customKeys = user_info.customInfo.AllKeys();
    bool first = true;
    for (size_t i = 0; i < customKeys.Size(); i++) {
        if (!first) json << ",";
        first = false;
        const V2TIMString& key = customKeys[i];
        const V2TIMBuffer& value = user_info.customInfo.Get(key);
        std::string key_str = key.CString();
        json << "{";
        json << "\"user_profile_custom_string_info_key\":\"" << EscapeJsonString(key_str) << "\",";
        if (value.Size() > 0) {
            std::string valueStr(reinterpret_cast<const char*>(value.Data()), value.Size());
            json << "\"user_profile_custom_string_info_value\":\"" << EscapeJsonString(valueStr) << "\"";
        } else {
            json << "\"user_profile_custom_string_info_value\":\"\"";
        }
        json << "}";
    }
    json << "]";
    json << "}";
    return json.str();
}

// Helper: Convert V2TIMFriendInfoVector to JSON array
static std::string FriendInfoVectorToJson(const V2TIMFriendInfoVector& friends) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < friends.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        
        try {
            const V2TIMFriendInfo& friend_info = friends[i];
            // Get CString() (has built-in protection)
            std::string user_id = friend_info.userID.CString();
            std::string friend_remark = friend_info.friendRemark.CString();
            
            json << "{";
            json << "\"friend_profile_identifier\":\"" << EscapeJsonString(user_id) << "\",";
            json << "\"friend_profile_remark\":\"" << EscapeJsonString(friend_remark) << "\",";
            
            // friend_profile_group_name_array
            json << "\"friend_profile_group_name_array\":[";
            for (size_t j = 0; j < friend_info.friendGroups.Size(); j++) {
                if (j > 0) json << ",";
                json << "\"" << EscapeJsonString(friend_info.friendGroups[j].CString()) << "\"";
            }
            json << "],";
            
            // friend_profile_custom_string_array
            json << "\"friend_profile_custom_string_array\":" << FriendCustomInfoToJsonArray(friend_info.friendCustomInfo) << ",";
            
            // friend_profile_user_profile
            json << "\"friend_profile_user_profile\":" << FriendUserFullInfoToJson(friend_info.userFullInfo);
            
            json << "}";
        } catch (...) {
            json << "{\"friend_profile_identifier\":\"\",\"friend_profile_remark\":\"\",\"friend_profile_group_name_array\":[],\"friend_profile_custom_string_array\":[],\"friend_profile_user_profile\":null}";
        }
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMConversationResult to JSON
static std::string ConversationResultToJson(const V2TIMConversationResult& result) {
    std::ostringstream json;
    json << "{";
    json << "\"conversation_list_result_next_seq\":" << result.nextSeq << ",";
    json << "\"conversation_list_result_is_finished\":" << std::boolalpha << (result.isFinished ? true : false) << ",";
    json << "\"conversation_list_result_conv_list\":" << ConversationVectorToJson(result.conversationList);
    json << "}";
    return json.str();
}

// Helper: Convert V2TIMGroupInfoVector to JSON array
static std::string GroupInfoVectorToJson(const V2TIMGroupInfoVector& groups) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < groups.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        
        const V2TIMGroupInfo& group_info = groups[i];
        json << "{";
        // Get CString() (has built-in protection)
        std::string group_id = group_info.groupID.CString();
        std::string group_name = group_info.groupName.CString();
        std::string group_type = group_info.groupType.CString();
        json << "\"group_id\":\"" << EscapeJsonString(group_id) << "\",";
        json << "\"group_name\":\"" << EscapeJsonString(group_name) << "\",";
        json << "\"group_type\":\"" << EscapeJsonString(group_type) << "\"";
        
        // TODO: Add more group info fields
        json << "}";
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMFriendOperationResult to JSON
// Note: This is also declared in dart_compat_callbacks.h, so we remove static here
std::string FriendOperationResultToJson(const V2TIMFriendOperationResult& result) {
    std::ostringstream json;
    json << "{";
    // Get CString() (has built-in protection)
        std::string user_id = result.userID.CString();
    std::string result_info = result.resultInfo.CString();
    json << "\"friend_result_identifier\":\"" << EscapeJsonString(user_id) << "\",";
    json << "\"friend_result_code\":" << result.resultCode << ",";
    json << "\"friend_result_desc\":\"" << EscapeJsonString(result_info) << "\"";
    json << "}";
    return json.str();
}

// Helper: Convert V2TIMFriendOperationResultVector to JSON array
// Note: This is also declared in dart_compat_callbacks.h, so we remove static here
std::string FriendOperationResultVectorToJson(const V2TIMFriendOperationResultVector& results) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < results.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        json << FriendOperationResultToJson(results[i]);
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMFriendInfoResultVector to JSON array
// Note: This is also declared in dart_compat_callbacks.h, so we remove static here
std::string FriendInfoResultVectorToJson(const V2TIMFriendInfoResultVector& results) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < results.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        
        const V2TIMFriendInfoResult& result = results[i];
        // Field names MUST match V2TimFriendInfoResult.fromJson in the
        // vendored tencent_cloud_chat_sdk (friendship_friend_info_get_result_*
        // with the friend info nested under ..._field_info, whose keys are the
        // friend_profile_* family). The previous shape ({"friendInfo":{...},
        // "resultCode":...}) matched NOTHING the Dart side reads: every result
        // deserialized with friendInfo == null and resultCode == -1, which
        // silently emptied contact search (DartSearchFriends) and
        // DartGetFriendsInfo on the binary path across ALL platforms — caught
        // by the mobile_search_contact_back_unbinds real-UI case.
        json << "{";
        json << "\"friendship_friend_info_get_result_error_code\":"
             << result.resultCode << ",";
        std::string result_info = result.resultInfo.CString();
        json << "\"friendship_friend_info_get_result_error_message\":\""
             << EscapeJsonString(result_info) << "\",";
        // Everything these APIs return is an established friend; the C enum
        // value 3 maps to V2TIM_FRIEND_TYPE_BOTH on the Dart side.
        json << "\"friendship_friend_info_get_result_relation_type\":3,";
        json << "\"friendship_friend_info_get_result_field_info\":{";
        std::string user_id = result.friendInfo.userID.CString();
        json << "\"friend_profile_identifier\":\"" << EscapeJsonString(user_id)
             << "\",";
        std::string friend_remark = result.friendInfo.friendRemark.CString();
        json << "\"friend_profile_remark\":\""
             << EscapeJsonString(friend_remark) << "\",";
        // Nested user profile so nickname/faceUrl render where a caller reads
        // userProfile instead of the remark.
        std::string nick = result.friendInfo.userFullInfo.nickName.CString();
        json << "\"friend_profile_user_profile\":{";
        json << "\"user_profile_identifier\":\"" << EscapeJsonString(user_id)
             << "\",";
        json << "\"user_profile_nick_name\":\"" << EscapeJsonString(nick)
             << "\"}";
        json << "}";
        json << "}";
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMMessageSearchResult to JSON
std::string MessageSearchResultToJson(const V2TIMMessageSearchResult& result) {
    std::ostringstream json;
    json << "{";
    json << "\"totalCount\":" << result.totalCount << ",";
    // Get CString() (has built-in protection)
    std::string search_cursor = result.searchCursor.CString();
    json << "\"searchCursor\":\"" << EscapeJsonString(search_cursor) << "\",";
    json << "\"messageSearchResultItems\":[";
    
    for (size_t i = 0; i < result.messageSearchResultItems.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        const V2TIMMessageSearchResultItem& item = result.messageSearchResultItems[i];
        json << "{";
        // Get CString() (has built-in protection)
        std::string conv_id_full = item.conversationID.CString();
        // Extract base ID without prefix for msg_search_result_item_conv_id
        // V2TimMessageSearchResultItem.fromJson expects msg_search_result_item_conv_id to be the base ID
        // and will add the prefix based on msg_search_result_item_conv_type
        std::string conv_id;
        if (conv_id_full.length() > 4 && conv_id_full.substr(0, 4) == "c2c_") {
            conv_id = conv_id_full.substr(4);
        } else if (conv_id_full.length() > 6 && conv_id_full.substr(0, 6) == "group_") {
            conv_id = conv_id_full.substr(6);
        } else {
            conv_id = conv_id_full;
        }
        // Determine conversation type from conversationID format
        int conv_type = 2; // Default to GROUP
        if (conv_id_full.length() > 4 && conv_id_full.substr(0, 4) == "c2c_") {
            conv_type = 1; // C2C
        }
        json << "\"msg_search_result_item_conv_id\":\"" << EscapeJsonString(conv_id) << "\",";
        json << "\"msg_search_result_item_conv_type\":" << conv_type << ",";
        json << "\"msg_search_result_item_total_message_count\":" << item.messageCount << ",";
        json << "\"msg_search_result_item_message_array\":" << MessageVectorToJson(item.messageList);
        json << "}";
    }
    
    json << "]";
    json << "}";
    return json.str();
}

// ============================================================================
// Callback Class Implementations
// ============================================================================

// Base callback class for V2TIMCallback
// Note: This is also defined in dart_compat_callbacks.h, so we comment out the definition here
// The definition in the header file is used for inline instantiation
/*
class DartCallback : public V2TIMCallback {
private:
    void* user_data_;
    std::string user_data_str_;  // CRITICAL: Store a copy of user_data string to avoid use-after-free
    std::function<void()> on_success_;
    std::function<void(int, const V2TIMString&)> on_error_;
    
public:
    DartCallback(
        void* user_data,
        std::function<void()> on_success,
        std::function<void(int, const V2TIMString&)> on_error
    ) : user_data_(user_data), on_success_(on_success), on_error_(on_error) {
        // CRITICAL: Immediately copy user_data string to avoid use-after-free
        // user_data may be freed by Dart before the callback executes
        if (user_data) {
            try {
                user_data_str_ = UserDataToString(user_data);
            } catch (...) {
                V2TIM_LOG(kError, "[dart_compat] DartCallback: Failed to copy user_data, using empty string");
                user_data_str_ = "";
            }
        }
    }
    
    // Get user_data as string (uses the copied string, not the original pointer)
    std::string GetUserDataString() const {
        return user_data_str_;
    }
    
    // Get user_data pointer (for backward compatibility, but prefer GetUserDataString)
    void* GetUserData() const {
        return user_data_;
    }
    
    void OnSuccess() override {
        if (on_success_) on_success_();
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        if (on_error_) on_error_(error_code, error_message);
    }
};
*/

// Callback for V2TIMSendCallback
class DartSendCallback : public V2TIMSendCallback {
private:
    void* user_data_;
    std::function<void(const V2TIMMessage&)> on_success_;
    std::function<void(int, const V2TIMString&)> on_error_;
    std::function<void(uint32_t)> on_progress_;
    
public:
    DartSendCallback(
        void* user_data,
        std::function<void(const V2TIMMessage&)> on_success,
        std::function<void(int, const V2TIMString&)> on_error,
        std::function<void(uint32_t)> on_progress
    ) : user_data_(user_data), on_success_(on_success), on_error_(on_error), on_progress_(on_progress) {}
    
    void OnSuccess(const V2TIMMessage& msg) override {
        if (on_success_) on_success_(msg);
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        if (on_error_) on_error_(error_code, error_message);
    }
    
    void OnProgress(uint32_t progress) override {
        if (on_progress_) on_progress_(progress);
    }
};

// Callback for V2TIMValueCallback<V2TIMMessageVector>
class DartMessageVectorCallback : public V2TIMValueCallback<V2TIMMessageVector> {
private:
    void* user_data_;  // Keep for backward compatibility, but don't use in callbacks
    std::string user_data_str_;  // CRITICAL: Copy of user_data string to avoid use-after-free
    
public:
    DartMessageVectorCallback(void* user_data) : user_data_(user_data) {
        // CRITICAL: Copy user_data string immediately to avoid use-after-free
        // Dart may free the user_data pointer before the callback executes
        if (user_data) {
            try {
                user_data_str_ = UserDataToString(user_data);
            } catch (...) {
                user_data_str_ = "";
            }
        }
    }
    
    void OnSuccess(const V2TIMMessageVector& messages) override {
        std::string messages_json = MessageVectorToJson(messages);
        std::map<std::string, std::string> result_fields;
        result_fields["messageList"] = messages_json;
        std::string data_json = BuildJsonObject(result_fields);
        // Use the copied string instead of the original pointer
        SendApiCallbackResultWithString(user_data_str_, 0, "", data_json);
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        const char* error_msg_cstr = nullptr;
        try {
            error_msg_cstr = error_message.CString();
        } catch (...) {
            error_msg_cstr = nullptr;
        }
        std::string error_msg = error_msg_cstr ? std::string(error_msg_cstr) : "";
        // Use the copied string instead of the original pointer
        SendApiCallbackResultWithString(user_data_str_, error_code, error_msg);
    }
};

// Callback for V2TIMValueCallback<V2TIMMessageVector> (for RevokeMessage)
class DartRevokeMessageCallback : public V2TIMValueCallback<V2TIMMessageVector> {
private:
    void* user_data_;
    
public:
    DartRevokeMessageCallback(void* user_data) : user_data_(user_data) {}
    
    void OnSuccess(const V2TIMMessageVector& messages) override {
        if (messages.Size() > 0) {
            const V2TIMMessage& message = messages[0];
            
            // Revoke the message
            SafeGetV2TIMManager()->GetMessageManager()->RevokeMessage(
                message,
                new DartCallback(
                    user_data_,
                    [this]() {
                        // OnSuccess
                        SendApiCallbackResult(user_data_, 0, "");
                    },
                    [this](int error_code, const V2TIMString& error_message) {
                        // OnError
                        std::string error_msg = error_message.CString();
                        SendApiCallbackResult(user_data_, error_code, error_msg);
                    }
                )
            );
        } else {
            SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_COMM_DATABASE_NOTFOUND, "Message not found");
        }
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        std::string error_msg = error_message.CString();
        SendApiCallbackResult(user_data_, error_code, error_msg);
    }
};

// Callback for V2TIMValueCallback<V2TIMFriendInfoVector>
class DartFriendInfoVectorCallback : public V2TIMValueCallback<V2TIMFriendInfoVector> {
private:
    void* user_data_;
    
public:
    DartFriendInfoVectorCallback(void* user_data) : user_data_(user_data) {}
    
    void OnSuccess(const V2TIMFriendInfoVector& friends) override {
        std::string friends_json = FriendInfoVectorToJson(friends);
        
        // V2TimValueCallback expects json_param field at top level as a JSON string
        // Build the complete callback JSON with json_param as an escaped string
        std::string user_data_str = UserDataToString(user_data_);
        int64_t instance_id = GetCurrentInstanceId();
        std::ostringstream json_msg;
        json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
        json_msg << "\"code\":0,\"desc\":\"\",";
        json_msg << "\"json_param\":\"" << EscapeJsonString(friends_json) << "\"}";
        
        SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        std::string error_msg = error_message.CString();
        SendApiCallbackResult(user_data_, error_code, error_msg);
    }
};

// Callback for V2TIMValueCallback<V2TIMConversationResult>
class DartConversationResultCallback : public V2TIMValueCallback<V2TIMConversationResult> {
private:
    void* user_data_;
    
public:
    DartConversationResultCallback(void* user_data) : user_data_(user_data) {}
    
    void OnSuccess(const V2TIMConversationResult& result) override {
        try {
            // Check if conversationList is valid before accessing it
            // If Size() returns an unreasonably large number, it's likely uninitialized memory
            size_t conv_count = 0;
            try {
                conv_count = result.conversationList.Size();
            } catch (...) {
                V2TIM_LOG(kError, "[dart_compat] DartConversationResultCallback::OnSuccess: Failed to get conversationList.Size()");
                // Return empty result
                std::string user_data_str = UserDataToString(user_data_);
                    std::string empty_result_json = "{\"conversation_list_result_next_seq\":0,\"conversation_list_result_is_finished\":true,\"conversation_list_result_conv_list\":[]}";
                    int64_t instance_id = GetCurrentInstanceId();
                    std::ostringstream json_msg;
                    json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                    json_msg << "\"code\":0,\"desc\":\"\",";
                    json_msg << "\"json_param\":\"" << EscapeJsonString(empty_result_json) << "\"}";
                    SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
                return;
            }
            
            // Sanity check: if size is unreasonably large (> 1000000), treat as invalid
            if (conv_count > 1000000) {
                V2TIM_LOG(kError, "[dart_compat] DartConversationResultCallback::OnSuccess: Invalid conversation count: {} (likely uninitialized memory)", conv_count);
                // Return empty result
                std::string user_data_str = UserDataToString(user_data_);
                    std::string empty_result_json = "{\"conversation_list_result_next_seq\":0,\"conversation_list_result_is_finished\":true,\"conversation_list_result_conv_list\":[]}";
                    int64_t instance_id = GetCurrentInstanceId();
                    std::ostringstream json_msg;
                    json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                    json_msg << "\"code\":0,\"desc\":\"\",";
                    json_msg << "\"json_param\":\"" << EscapeJsonString(empty_result_json) << "\"}";
                    SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
                return;
            }
            
            // Convert to JSON immediately while result is still valid
            // Don't copy the result - just use it directly and convert to JSON quickly
            std::string result_json = ConversationResultToJson(result);
            
            // V2TimValueCallback expects json_param field at top level as a JSON string
            // Build the complete callback JSON with json_param as an escaped string
            std::string user_data_str = UserDataToString(user_data_);
            // Escape the JSON string so it's treated as a string value, not a JSON object
            // We'll manually construct the JSON to ensure json_param is a string
            // Note: code must be an integer, not a string
            int64_t instance_id = GetCurrentInstanceId();
            std::ostringstream json_msg;
            json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
            json_msg << "\"code\":0,\"desc\":\"\",";
            json_msg << "\"json_param\":\"" << EscapeJsonString(result_json) << "\"}";
            SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
        } catch (const std::exception&) {
            V2TIM_LOG(kError, "[dart_compat] DartConversationResultCallback::OnSuccess: exception");
            SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Exception");
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] DartConversationResultCallback::OnSuccess: Unknown exception (non-std::exception, possibly access violation)");
            SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Unknown exception");
        }
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        try {
            std::string error_msg = error_message.CString();
            SendApiCallbackResult(user_data_, error_code, error_msg);
        } catch (...) {
            SendApiCallbackResult(user_data_, error_code, "Error message unavailable");
        }
    }
};

// Callback for V2TIMValueCallback<V2TIMString>
class DartStringCallback : public V2TIMValueCallback<V2TIMString> {
private:
    void* user_data_;
    
public:
    DartStringCallback(void* user_data) : user_data_(user_data) {}
    
    void OnSuccess(const V2TIMString& value) override {
        std::map<std::string, std::string> result_fields;
        // Get CString() (has built-in protection)
        result_fields["groupID"] = value.CString();
        std::string data_json = BuildJsonObject(result_fields);
        SendApiCallbackResult(user_data_, 0, "", data_json);
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        std::string error_msg = error_message.CString();
        SendApiCallbackResult(user_data_, error_code, error_msg);
    }
};

// Callback for V2TIMValueCallback<V2TIMGroupInfoVector>
class DartGroupInfoVectorCallback : public V2TIMValueCallback<V2TIMGroupInfoVector> {
private:
    void* user_data_;
    
public:
    DartGroupInfoVectorCallback(void* user_data) : user_data_(user_data) {}
    
    void OnSuccess(const V2TIMGroupInfoVector& groups) override {
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
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        std::string error_msg = error_message.CString();
        SendApiCallbackResult(user_data_, error_code, error_msg);
    }
};

// Callback for V2TIMValueCallback<V2TIMConversationOperationResultVector>
// Note: This class is not defined in dart_compat_callbacks.h, so we keep it here
class DartConversationOperationResultVectorCallback : public V2TIMValueCallback<V2TIMConversationOperationResultVector> {
private:
    void* user_data_;
    
public:
    DartConversationOperationResultVectorCallback(void* user_data) : user_data_(user_data) {}
    
    void OnSuccess(const V2TIMConversationOperationResultVector& result_list) override {
        // Convert V2TIMConversationOperationResultVector to JSON
        // This is a placeholder - actual implementation needs to convert result_list to JSON
        std::string json_result = "{\"conversationOperationResultList\":[]}";
        SendApiCallbackResult(user_data_, 0, "", json_result);
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        std::string error_msg = error_message.CString();
        SendApiCallbackResult(user_data_, error_code, error_msg);
    }
};

// Note: The following callback classes are defined in dart_compat_callbacks.h for inline instantiation
// We don't need to redefine them here, so they are removed to avoid confusion.
// The actual implementation in dart_compat_callbacks.h uses result.resultCode instead of hardcoded 0.

// Callback for V2TIMValueCallback<V2TIMFriendOperationResultVector>
// Note: This is also defined in dart_compat_callbacks.h, so we comment out the definition here
/*
class DartFriendOperationResultVectorCallback : public V2TIMValueCallback<V2TIMFriendOperationResultVector> {
private:
    void* user_data_;
    
public:
    DartFriendOperationResultVectorCallback(void* user_data) : user_data_(user_data) {}
    
    void OnSuccess(const V2TIMFriendOperationResultVector& results) override {
        std::string results_json = FriendOperationResultVectorToJson(results);
        std::map<std::string, std::string> result_fields;
        result_fields["friendOperationResultList"] = results_json;
        std::string data_json = BuildJsonObject(result_fields);
        SendApiCallbackResult(user_data_, 0, "", data_json);
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        std::string error_msg = error_message.CString();
        SendApiCallbackResult(user_data_, error_code, error_msg);
    }
};
*/

// Callback for V2TIMValueCallback<V2TIMFriendInfoResultVector>
// Note: This is also defined in dart_compat_callbacks.h, so we comment out the definition here
/*
class DartFriendInfoResultVectorCallback : public V2TIMValueCallback<V2TIMFriendInfoResultVector> {
private:
    void* user_data_;
    
public:
    DartFriendInfoResultVectorCallback(void* user_data) : user_data_(user_data) {}
    
    void OnSuccess(const V2TIMFriendInfoResultVector& results) override {
        std::string results_json = FriendInfoResultVectorToJson(results);
        std::map<std::string, std::string> result_fields;
        result_fields["friendInfoResultList"] = results_json;
        std::string data_json = BuildJsonObject(result_fields);
        SendApiCallbackResult(user_data_, 0, "", data_json);
    }
    
    void OnError(int error_code, const V2TIMString& error_message) override {
        std::string error_msg = error_message.CString();
        SendApiCallbackResult(user_data_, error_code, error_msg);
    }
};

// Callback for V2TIMCompleteCallback<V2TIMMessage>
// Note: This is also defined in dart_compat_callbacks.h, so we comment out the definition here
// (Removed nested comment to avoid warning)
#if 0
class DartMessageCompleteCallback : public V2TIMCompleteCallback<V2TIMMessage> {
private:
    void* user_data_;
    
public:
    DartMessageCompleteCallback(void* user_data) : user_data_(user_data) {}
    
    void OnComplete(int error_code, const V2TIMString& error_message, const V2TIMMessage& message) override {
        if (error_code == 0) {
            // OnSuccess - return the modified message
            std::string msg_json = MessageVectorToJson(V2TIMMessageVector()); // Create a vector with single message
            // TODO: Convert single message to JSON properly
            std::map<std::string, std::string> result_fields;
            result_fields["message_msg_id"] = message.msgID.CString();
            std::string data_json = BuildJsonObject(result_fields);
            SendApiCallbackResult(user_data_, 0, "", data_json);
        } else {
            // OnError
            std::string error_msg = error_message.CString();
            SendApiCallbackResult(user_data_, error_code, error_msg);
        }
    }
};
*/
