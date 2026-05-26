// Listener implementations and callback registration functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"
#include "V2TIMManagerImpl.h"
#include "V2TIMFriendshipManagerImpl.h"
#include <chrono>

// Forward declaration for GetCurrentInstanceId (defined in tim2tox_ffi.cpp)
extern int64_t GetCurrentInstanceId();

// ============================================================================
// Resolve instance_id from listener pointer for strict multi-instance routing.
// Used in On* callbacks so the event is attributed to the instance that owns
// this listener. Fallback to GetCurrentInstanceId() only when not found.
// ============================================================================
static int64_t GetInstanceIdForListener(DartSDKListenerImpl* p) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    for (const auto& kv : g_sdk_listeners) if (kv.second == p) return kv.first;
    return 0;
}
static int64_t GetInstanceIdForListener(DartAdvancedMsgListenerImpl* p) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    for (const auto& kv : g_advanced_msg_listeners) if (kv.second == p) return kv.first;
    return 0;
}
static int64_t GetInstanceIdForListener(DartFriendshipListenerImpl* p) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    for (const auto& kv : g_friendship_listeners) if (kv.second == p) return kv.first;
    return 0;
}
static int64_t GetInstanceIdForListener(DartConversationListenerImpl* p) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    for (const auto& kv : g_conversation_listeners) if (kv.second == p) return kv.first;
    return 0;
}
static int64_t GetInstanceIdForListener(DartSignalingListenerImpl* p) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    for (const auto& kv : g_signaling_listeners) if (kv.second == p) return kv.first;
    return 0;
}
static int64_t GetInstanceIdForListener(DartCommunityListenerImpl* p) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    for (const auto& kv : g_community_listeners) if (kv.second == p) return kv.first;
    return 0;
}

// ============================================================================
// Helper Functions for JSON Conversion
// ============================================================================

// Helper: Convert V2TIMCustomInfo to JSON array (for user_profile_custom_string_array)
static std::string CustomInfoToJsonArray(const V2TIMCustomInfo& customInfo) {
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
        json << "\"user_profile_custom_string_info_key\":\"" << EscapeJsonString(key_str) << "\",";
        
        // Convert V2TIMBuffer to string
        if (value.Size() > 0) {
            std::string valueStr(reinterpret_cast<const char*>(value.Data()), value.Size());
            json << "\"user_profile_custom_string_info_value\":\"" << EscapeJsonString(valueStr) << "\"";
        } else {
            json << "\"user_profile_custom_string_info_value\":\"\"";
        }
        json << "}";
    }
    
    json << "]";
    return json.str();
}

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

// Helper: Convert V2TIMFriendAllowType to add_permission integer
static int AllowTypeToAddPermission(V2TIMFriendAllowType allowType) {
    // V2TIMFriendAllowType maps to CFriendAddPermission:
    // V2TIM_FRIEND_ALLOW_ANY = 0 (AllowAny)
    // V2TIM_FRIEND_NEED_CONFIRM = 1 (NeedConfirm)
    // V2TIM_FRIEND_DENY_ANY = 2 (DenyAny)
    return static_cast<int>(allowType);
}

// Helper: Convert V2TIMUserFullInfo to JSON object (for OnSelfInfoUpdated)
static std::string UserFullInfoToJson(const V2TIMUserFullInfo& user_info) {
    std::ostringstream json;
    json << "{";
    
    // Get CString() (has built-in protection)
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
    json << "\"user_profile_add_permission\":" << AllowTypeToAddPermission(user_info.allowType) << ",";
    json << "\"user_profile_role\":" << user_info.role << ",";
    json << "\"user_profile_level\":" << user_info.level << ",";
    json << "\"user_profile_custom_string_array\":" << CustomInfoToJsonArray(user_info.customInfo);
    
    json << "}";
    return json.str();
}

// Helper: Convert V2TIMUserFullInfoVector to JSON array (for OnUserInfoChanged)
static std::string UserFullInfoVectorToJson(const V2TIMUserFullInfoVector& users) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < users.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        
        try {
            const V2TIMUserFullInfo& user_info = users[i];
            
            // Get CString() (has built-in protection)
            std::string user_id_str = user_info.userID.CString();
            std::string nick_name_str = user_info.nickName.CString();
            std::string face_url_str = user_info.faceURL.CString();
            std::string self_signature_str = user_info.selfSignature.CString();
            
            json << "{";
            json << "\"user_profile_identifier\":\"" << EscapeJsonString(user_id_str) << "\",";
            json << "\"user_profile_nick_name\":\"" << EscapeJsonString(nick_name_str) << "\",";
            json << "\"user_profile_face_url\":\"" << EscapeJsonString(face_url_str) << "\",";
            json << "\"user_profile_self_signature\":\"" << EscapeJsonString(self_signature_str) << "\",";
            json << "\"user_profile_gender\":" << static_cast<int>(user_info.gender) << ",";
            json << "\"user_profile_birthday\":" << user_info.birthday << ",";
            json << "\"user_profile_add_permission\":" << AllowTypeToAddPermission(user_info.allowType) << ",";
            json << "\"user_profile_role\":" << user_info.role << ",";
            json << "\"user_profile_level\":" << user_info.level << ",";
            json << "\"user_profile_custom_string_array\":" << CustomInfoToJsonArray(user_info.customInfo);
            json << "}";
        } catch (...) {
            // Skip invalid user_info, add empty object with required fields
            json << "{\"user_profile_identifier\":\"\",\"user_profile_nick_name\":\"\",\"user_profile_face_url\":\"\",\"user_profile_custom_string_array\":[]}";
        }
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMUserStatusVector to JSON array (for OnUserStatusChanged)
static std::string UserStatusVectorToJson(const V2TIMUserStatusVector& status_vector) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < status_vector.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        
        try {
            const V2TIMUserStatus& status = status_vector[i];
            std::string user_id = status.userID.CString();
            std::string custom_status = status.customStatus.CString();
            
            json << "{";
            json << "\"user_status_identifier\":\"" << EscapeJsonString(user_id) << "\",";
            json << "\"user_status_status_type\":" << static_cast<int>(status.statusType) << ",";
            json << "\"user_status_custom_status\":\"" << EscapeJsonString(custom_status) << "\",";
            json << "\"user_status_online_devices\":[]";
            json << "}";
        } catch (const std::exception& e) {
            V2TIM_LOG(kError, "[dart_compat] UserStatusVectorToJson: EXCEPTION processing status[{}]: {}", i, e.what());
            json << "{\"user_status_identifier\":\"\",\"user_status_status_type\":0,\"user_status_custom_status\":\"\",\"user_status_online_devices\":[]}";
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] UserStatusVectorToJson: UNKNOWN EXCEPTION processing status[{}]", i);
            json << "{\"user_status_identifier\":\"\",\"user_status_status_type\":0,\"user_status_custom_status\":\"\",\"user_status_online_devices\":[]}";
        }
    }
    
    json << "]";
    std::string result = json.str();
    return result;
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

// Helper: Convert V2TIMElem to JSON object
static std::string ElemToJson(const V2TIMElem* elem) {
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
            // Convert V2TIMBuffer to string for JSON
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
            case V2TIM_ELEM_TYPE_FILE: {
                const V2TIMFileElem* fileElem = static_cast<const V2TIMFileElem*>(elem);
                json << ",\"file_elem_file_path\":\"" << EscapeJsonString(fileElem->path.CString()) << "\"";
                json << ",\"file_elem_file_name\":\"" << EscapeJsonString(fileElem->filename.CString()) << "\"";
                json << ",\"file_elem_file_size\":" << fileElem->fileSize;
                break;
            }
            // Add more element types as needed
            default:
                // For other types, just include elem_type
                break;
        }
    } catch (...) {
        // If conversion fails, just return elem_type
    }
    
    json << "}";
    return json.str();
}

// Helper: Convert V2TIMElemVector to JSON array
static std::string ElemListToJsonArray(const V2TIMElemVector& elemList) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < elemList.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        try {
            const V2TIMElem* elem = elemList[i];
            json << ElemToJson(elem);
        } catch (...) {
            json << "{\"elem_type\":0}";
        }
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert single V2TIMMessage to JSON array (for OnRecvNewMessage and OnRecvMessageModified)
static std::string MessageToJsonArray(const V2TIMMessage& msg) {
    std::ostringstream json;
    json << "[";
    
    try {
        // Get CString() (has built-in protection)
        std::string msg_id = msg.msgID.CString();
        std::string sender = msg.sender.CString();
        std::string user_id = msg.userID.CString();
        std::string group_id = msg.groupID.CString();
        std::string nick_name = msg.nickName.CString();
        std::string friend_remark = msg.friendRemark.CString();
        std::string name_card = msg.nameCard.CString();
        std::string face_url = msg.faceURL.CString();
        
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
        // V2TIMMessage::random is uint64_t and is NEVER set by Tim2Tox's C++
        // core (V2TIMMessage::V2TIMMessage() = default; no member init),
        // so it carries uninitialized stack bytes. When emitted as a JSON
        // number, large values overflow Dart's int53 safe range and parse as
        // `double`, which then trips `V2TimMessage.fromJson` (line `random =
        // json['message_rand'];`) with "'double' is not a subtype of type
        // 'int?'". Clamp to 0 here so the parsed value is always int-safe.
        // The field is informational only — no Tim2Tox code path reads it.
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
        
        // Add optional string fields with null-safe defaults
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
        // Add groupAtUserList
        for (size_t i = 0; i < msg.groupAtUserList.Size(); i++) {
            if (i > 0) json << ",";
            json << "\"" << EscapeJsonString(msg.groupAtUserList[i].CString()) << "\"";
        }
        json << "],";
        json << "\"message_sender_group_member_info\":null,";
        json << "\"message_offline_push_config\":null,";
        
        // Add elem_array
        json << "\"message_elem_array\":" << ElemListToJsonArray(msg.elemList);
        
        json << "}";
    } catch (...) {
        json << "{}";
    }
    
    json << "]";
    return json.str();
}

// Helper: Convert V2TIMCustomInfo to JSON array (for friend_profile_custom_string_array)
static std::string FriendCustomInfoToJsonArrayForCallback(const V2TIMCustomInfo& customInfo) {
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
static std::string FriendUserFullInfoToJsonForCallback(const V2TIMUserFullInfo& user_info) {
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

// Helper: Convert V2TIMFriendInfoVector to JSON array (for OnFriendInfoChanged)
static std::string FriendInfoVectorToJsonForCallback(const V2TIMFriendInfoVector& friends) {
    std::ostringstream json;
    json << "[";
    
    for (size_t i = 0; i < friends.Size(); i++) {
        if (i > 0) {
            json << ",";
        }
        
        try {
            const V2TIMFriendInfo& friend_info = friends[i];
            std::string user_id = friend_info.userID.CString();
            std::string friend_remark = friend_info.friendRemark.CString();
            
            json << "{";
            // Both `friend_profile_identifier` and `friend_profile_update_identifier`
            // are emitted: Dart's `_handleGlobalCallback` case
            // `UpdateFriendProfile` reads the `_update_identifier` form (line 917
            // of native_library_manager.dart), but other consumers expect the
            // plain `_identifier` form. Both point at the same userID.
            json << "\"friend_profile_identifier\":\"" << EscapeJsonString(user_id) << "\",";
            json << "\"friend_profile_update_identifier\":\"" << EscapeJsonString(user_id) << "\",";
            json << "\"friend_profile_remark\":\"" << EscapeJsonString(friend_remark) << "\",";
            
            // friend_profile_group_name_array
            json << "\"friend_profile_group_name_array\":[";
            for (size_t j = 0; j < friend_info.friendGroups.Size(); j++) {
                if (j > 0) json << ",";
                json << "\"" << EscapeJsonString(friend_info.friendGroups[j].CString()) << "\"";
            }
            json << "],";
            
            // friend_profile_custom_string_array
            json << "\"friend_profile_custom_string_array\":" << FriendCustomInfoToJsonArrayForCallback(friend_info.friendCustomInfo) << ",";
            
            // friend_profile_user_profile
            json << "\"friend_profile_user_profile\":" << FriendUserFullInfoToJsonForCallback(friend_info.userFullInfo);
            
            json << "}";
        } catch (...) {
            json << "{\"friend_profile_identifier\":\"\",\"friend_profile_remark\":\"\",\"friend_profile_group_name_array\":[],\"friend_profile_custom_string_array\":[],\"friend_profile_user_profile\":null}";
        }
    }
    
    json << "]";
    return json.str();
}

// ============================================================================
// SDK Global Callbacks
// ============================================================================

// SDK Listener Implementation
class DartSDKListenerImpl : public V2TIMSDKListener {
public:
    void OnConnectSuccess() override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        std::map<std::string, std::string> fields;
        fields["status"] = "0";  // 0 = connected
        fields["code"] = "0";
        fields["desc"] = "";
        
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "NetworkStatus"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::NetworkStatus, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "NetworkStatus"));
    }
    
    void OnConnectFailed(int code, const V2TIMString& desc) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        std::map<std::string, std::string> fields;
        fields["status"] = "1";  // 1 = failed
        fields["code"] = std::to_string(code);
        fields["desc"] = desc.CString();
        
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "NetworkStatus"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::NetworkStatus, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "NetworkStatus"));
    }
    
    void OnKickedOffline() override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        std::map<std::string, std::string> fields;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "KickedOffline"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::KickedOffline, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "KickedOffline"));
    }
    
    void OnUserSigExpired() override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        std::map<std::string, std::string> fields;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "UserSigExpired"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::UserSigExpired, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "UserSigExpired"));
    }
    
    void OnSelfInfoUpdated(const V2TIMUserFullInfo& info) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        // Convert V2TIMUserFullInfo to JSON
        std::string user_profile_json = UserFullInfoToJson(info);
        std::map<std::string, std::string> fields;
        fields["json_user_profile"] = user_profile_json;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "SelfInfoUpdated"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::SelfInfoUpdated, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "SelfInfoUpdated"));
    }
    
    void OnUserStatusChanged(const V2TIMUserStatusVector& statusVector) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();

        std::string status_array_json = UserStatusVectorToJson(statusVector);
        std::map<std::string, std::string> fields;
        fields["json_user_status_array"] = status_array_json;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "UserStatusChanged"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::UserStatusChanged, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "UserStatusChanged"));
    }
    
    void OnUserInfoChanged(const V2TIMUserFullInfoVector& infoVector) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        // Convert V2TIMUserFullInfoVector to JSON
        std::string user_info_array_json = UserFullInfoVectorToJson(infoVector);
        std::map<std::string, std::string> fields;
        fields["json_user_info_array"] = user_info_array_json;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "UserInfoChanged"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::UserInfoChanged, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "UserInfoChanged"));
    }
    
    void OnLog(V2TIMLogLevel logLevel, const V2TIMString& logContent) {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        // Log callback - can be called frequently, so we might want to throttle
        std::map<std::string, std::string> fields;
        fields["level"] = std::to_string(static_cast<int>(logLevel));
        fields["log"] = logContent.CString();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "LogCallback"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::LogCallback, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "LogCallback"));
    }
};

extern "C" {
    void DartSetNetworkStatusListenerCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "NetworkStatus", user_data);
        
        // Register SDK listener for current instance
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartSDKListenerImpl* listener = GetOrCreateSDKListener();
        manager->AddSDKListener(listener);
    }
    
    void DartSetKickedOfflineCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "KickedOffline", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartSDKListenerImpl* listener = GetOrCreateSDKListener();
        manager->AddSDKListener(listener);
    }
    
    void DartSetUserSigExpiredCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "UserSigExpired", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartSDKListenerImpl* listener = GetOrCreateSDKListener();
        manager->AddSDKListener(listener);
    }
    
    void DartSetSelfInfoUpdatedCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "SelfInfoUpdated", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartSDKListenerImpl* listener = GetOrCreateSDKListener();
        manager->AddSDKListener(listener);
    }
    
    void DartSetUserStatusChangedCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "UserStatusChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            V2TIM_LOG(kWarning, "[dart_compat] DartSetUserStatusChangedCallback: SafeGetV2TIMManager() returned null, skipping listener registration");
            return;
        }
        DartSDKListenerImpl* listener = GetOrCreateSDKListener();
        manager->AddSDKListener(listener);
    }
    
    void DartSetUserInfoChangedCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "UserInfoChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartSDKListenerImpl* listener = GetOrCreateSDKListener();
        manager->AddSDKListener(listener);
    }
    
    void DartSetLogCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "LogCallback", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartSDKListenerImpl* listener = GetOrCreateSDKListener();
        manager->AddSDKListener(listener);
    }
    
    void DartSetMsgAllMessageReceiveOptionCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "AllMessageReceiveOption", user_data);
        // This callback is handled by SDK listener
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartSDKListenerImpl* listener = GetOrCreateSDKListener();
        manager->AddSDKListener(listener);
    }

    // Introduced in tencent_cloud_chat_sdk 8.9.7540+3. Tim2Tox doesn't have an
    // analogue of Tencent's "experimental notify" channel, but the SDK calls
    // this unconditionally during TIMManager._initInternalSDKListener() and
    // crashes if the symbol is missing. Store the user_data for symmetry with
    // the other SDK-listener callbacks; no V2TIM listener is registered.
    void DartSetExperimentalNotifyCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "ExperimentalNotify", user_data);
    }
}

// ============================================================================
// Message Callbacks
// ============================================================================

// Advanced Message Listener Implementation
class DartAdvancedMsgListenerImpl : public V2TIMAdvancedMsgListener {
public:
    void OnRecvNewMessage(const V2TIMMessage& message) override {
        int64_t instance_id = GetReceiverInstanceOverride();
        if (instance_id != 0) {
            ClearReceiverInstanceOverride();
        } else {
            instance_id = GetInstanceIdForListener(this);
            if (instance_id == 0) instance_id = GetCurrentInstanceId();
        }
        std::string msg_array_json = MessageToJsonArray(message);
        std::map<std::string, std::string> fields;
        fields["json_msg_array"] = msg_array_json;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ReceiveNewMessage"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ReceiveNewMessage, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ReceiveNewMessage"));
    }
    
    void OnRecvMessageModified(const V2TIMMessage& message) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        // Convert V2TIMMessage to JSON array (single message wrapped in array)
        std::string msg_array_json = MessageToJsonArray(message);
        std::map<std::string, std::string> fields;
        fields["json_msg_array"] = msg_array_json;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "MessageUpdate"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::MessageUpdate, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "MessageUpdate"));
    }
    
    void OnRecvMessageRevoked(const V2TIMString& msgID) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        std::map<std::string, std::string> fields;
        fields["json_msg_locator_array"] = "[{\"message_msg_id\":\"" + std::string(msgID.CString()) + "\"}]";  // Placeholder
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "MessageRevoke"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::MessageRevoke, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "MessageRevoke"));
    }
    
    // Other methods will be implemented in phase4
};

extern "C" {
    void DartAddReceiveNewMsgCallback(void* user_data) {
        int64_t instance_id = GetCurrentInstanceId();
        StoreCallbackUserData(instance_id, "ReceiveNewMessage", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            V2TIM_LOG(kError, "[dart_compat] DartAddReceiveNewMsgCallback: manager is null");
            return;
        }
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartAddReceiveNewMsgCallback: GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }
    
    // Placeholder implementations for other message callbacks
    void DartSetMsgElemUploadProgressCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MessageElemUploadProgress", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }

    void DartSetMsgReadReceiptCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MessageReadReceipt", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return;
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }

    void DartSetMsgRevokeCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MessageRevoke", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }

    void DartSetMsgUpdateCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MessageUpdate", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }

    void DartSetMsgExtensionsChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MessageExtensionsChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }

    void DartSetMsgExtensionsDeletedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MessageExtensionsDeleted", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }

    void DartSetMsgReactionsChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MessageReactionChange", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }

    void DartSetMsgGroupPinnedMessageChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "GroupPinnedMessageChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* msg_manager = manager->GetMessageManager();
        if (!msg_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetMessageManager() returned nullptr");
            return;
        }
        DartAdvancedMsgListenerImpl* listener = GetOrCreateAdvancedMsgListener();
        msg_manager->AddAdvancedMsgListener(listener);
    }
}

// ============================================================================
// Friendship Callbacks
// ============================================================================

class DartFriendshipListenerImpl : public V2TIMFriendshipListener {
public:
    void OnFriendListAdded(const V2TIMFriendInfoVector& userIDList) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        // Convert V2TIMFriendInfoVector to JSON array of user IDs
        // Note: userID should be 64-character public key (TOX_PUBLIC_KEY_SIZE * 2)
        std::ostringstream json;
        json << "[";
        for (size_t i = 0; i < userIDList.Size(); i++) {
            if (i > 0) {
                json << ",";
            }
            const V2TIMFriendInfo& friendInfo = userIDList[i];
            std::string user_id = friendInfo.userID.CString();
            json << "\"" << EscapeJsonString(user_id) << "\"";
        }
        json << "]";
        
        std::map<std::string, std::string> fields;
        fields["json_identifier_array"] = json.str();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "AddFriend"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::AddFriend, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "AddFriend"));
    }
    
    void OnFriendListDeleted(const V2TIMStringVector& userIDList) override {
        // Convert V2TIMStringVector to JSON array
        // Note: userID should be 64-character public key (TOX_PUBLIC_KEY_SIZE * 2)
        std::ostringstream json;
        json << "[";
        for (size_t i = 0; i < userIDList.Size(); i++) {
            if (i > 0) {
                json << ",";
            }
            std::string user_id = userIDList[i].CString();
            json << "\"" << EscapeJsonString(user_id) << "\"";
        }
        json << "]";
        
        std::map<std::string, std::string> fields;
        fields["json_identifier_array"] = json.str();
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "DeleteFriend"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::DeleteFriend, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "DeleteFriend"));
    }
    
    void OnFriendInfoChanged(const V2TIMFriendInfoVector& infoList) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        // Convert V2TIMFriendInfoVector to JSON
        // Note: userID should be 64-character public key (TOX_PUBLIC_KEY_SIZE * 2)
        std::string friend_profile_array_json = FriendInfoVectorToJsonForCallback(infoList);
        std::map<std::string, std::string> fields;
        // Dart side (NativeLibraryManager._handleGlobalCallback case
        // GlobalCallbackType.UpdateFriendProfile, line 921) reads
        // "friend_info_update_array". Previously we sent under
        // "json_friend_profile_update_array" which Dart silently ignored,
        // _getGlobalCallbackJsonString returned "" for the missing key, and
        // json.decode("") threw FormatException in setUpAll for any test
        // that registered a friendship listener (group_multi, group_state_changes).
        fields["friend_info_update_array"] = friend_profile_array_json;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "UpdateFriendProfile"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::UpdateFriendProfile, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "UpdateFriendProfile"));
    }
    
    void OnFriendApplicationListAdded(const V2TIMFriendApplicationVector& applicationList) override {
        // Find the instance_id for this listener by searching g_friendship_listeners
        // This ensures we use the correct instance_id even if GetCurrentInstanceId() returns wrong value
        int64_t instance_id = 0;
        {
            std::lock_guard<std::mutex> lock(g_listeners_mutex);
            for (const auto& pair : g_friendship_listeners) {
                if (pair.second == this) {
                    instance_id = pair.first;
                    break;
                }
            }
        }
        
        if (instance_id == 0) {
            instance_id = GetCurrentInstanceId();
            V2TIM_LOG(kWarning, "[DartFriendshipListenerImpl] OnFriendApplicationListAdded: listener not found in map, using GetCurrentInstanceId()={}", (long long)instance_id);
        }

        // Convert V2TIMFriendApplicationVector to JSON array
        // Note: Field names must match V2TimFriendApplication.fromJsonForCallback expectations:
        // - friend_add_pendency_identifier (not userID)
        // - friend_add_pendency_type (not type)
        // - friend_add_pendency_add_wording (not addWording)
        // - friend_add_pendency_add_source (not addSource)
        std::ostringstream json;
        json << "[";
        for (size_t i = 0; i < applicationList.Size(); i++) {
            if (i > 0) {
                json << ",";
            }
            const V2TIMFriendApplication& app = applicationList[i];
            json << "{";
            std::string user_id = app.userID.CString();
            std::string add_wording = app.addWording.CString();
            std::string add_source = app.addSource.CString();
            json << "\"friend_add_pendency_identifier\":\"" << EscapeJsonString(user_id) << "\",";
            json << "\"friend_add_pendency_type\":" << static_cast<int>(app.type) << ",";
            json << "\"friend_add_pendency_add_wording\":\"" << EscapeJsonString(add_wording) << "\",";
            json << "\"friend_add_pendency_add_source\":\"" << EscapeJsonString(add_source) << "\"";
            json << "}";
        }
        json << "]";
        
        std::map<std::string, std::string> fields;
        // Note: Field name must match what NativeLibraryManager expects: "json_application_array"
        std::string json_array_str = json.str();
        fields["json_application_array"] = json_array_str;
        void* user_data_ptr = GetCallbackUserData(instance_id, "FriendAddRequest");
        std::string user_data = UserDataToString(user_data_ptr);
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::FriendAddRequest, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, user_data_ptr);
    }
    
    void OnFriendApplicationListDeleted(const V2TIMStringVector& userIDList) override {
        // Convert V2TIMStringVector to JSON array
        // Note: userID should be 64-character public key (TOX_PUBLIC_KEY_SIZE * 2)
        std::ostringstream json;
        json << "[";
        for (size_t i = 0; i < userIDList.Size(); i++) {
            if (i > 0) {
                json << ",";
            }
            std::string user_id = userIDList[i].CString();
            json << "\"" << EscapeJsonString(user_id) << "\"";
        }
        json << "]";
        
        std::map<std::string, std::string> fields;
        fields["json_identifier_array"] = json.str();
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "FriendApplicationListDeleted"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::FriendApplicationListDeleted, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "FriendApplicationListDeleted"));
    }
    
    void OnFriendApplicationListRead() override {
        std::map<std::string, std::string> fields;
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "FriendApplicationListRead"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::FriendApplicationListRead, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "FriendApplicationListRead"));
    }
    
    void OnBlackListAdded(const V2TIMFriendInfoVector& infoList) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        // Convert V2TIMFriendInfoVector to JSON array
        // Note: userID should be 64-character public key (TOX_PUBLIC_KEY_SIZE * 2)
        std::ostringstream json;
        json << "[";
        for (size_t i = 0; i < infoList.Size(); i++) {
            if (i > 0) {
                json << ",";
            }
            const V2TIMFriendInfo& friendInfo = infoList[i];
            std::string user_id = friendInfo.userID.CString();
            json << "\"" << EscapeJsonString(user_id) << "\"";
        }
        json << "]";
        
        std::map<std::string, std::string> fields;
        fields["json_identifier_array"] = json.str();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "FriendBlackListAdded"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::FriendBlackListAdded, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "FriendBlackListAdded"));
    }
    
    void OnBlackListDeleted(const V2TIMStringVector& userIDList) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        
        // Convert V2TIMStringVector to JSON array
        // Note: userID should be 64-character public key (TOX_PUBLIC_KEY_SIZE * 2)
        std::ostringstream json;
        json << "[";
        for (size_t i = 0; i < userIDList.Size(); i++) {
            if (i > 0) {
                json << ",";
            }
            std::string user_id = userIDList[i].CString();
            json << "\"" << EscapeJsonString(user_id) << "\"";
        }
        json << "]";
        
        std::map<std::string, std::string> fields;
        fields["json_identifier_array"] = json.str();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "FriendBlackListDeleted"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::FriendBlackListDeleted, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "FriendBlackListDeleted"));
    }
};

extern "C" {
    void DartSetOnAddFriendCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "AddFriend", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetOnAddFriendCallback: GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    // Placeholder implementations for other friendship callbacks
    void DartSetOnDeleteFriendCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "DeleteFriend", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetOnDeleteFriendCallback: GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetUpdateFriendProfileCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "UpdateFriendProfile", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetUpdateFriendProfileCallback: GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    // Continue with remaining friendship callbacks...
    void DartSetFriendAddRequestCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendAddRequest", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendApplicationListDeletedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendApplicationListDeleted", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendApplicationListReadCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendApplicationListRead", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendBlackListAddedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendBlackListAdded", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendBlackListDeletedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendBlackListDeleted", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendGroupCreatedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendGroupCreated", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendGroupDeletedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendGroupDeleted", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendGroupNameChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendGroupNameChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendsAddedToGroupCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendsAddedToGroup", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetFriendsDeletedFromGroupCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "FriendsDeletedFromGroup", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetOfficialAccountSubscribedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "OfficialAccountSubscribed", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetOfficialAccountUnsubscribedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "OfficialAccountUnsubscribed", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetOfficialAccountDeletedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "OfficialAccountDeleted", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetOfficialAccountInfoChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "OfficialAccountInfoChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetMyFollowingListChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MyFollowingListChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetMyFollowersListChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MyFollowersListChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
    
    void DartSetMutualFollowersListChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "MutualFollowersListChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* friendship_manager = manager->GetFriendshipManager();
        if (!friendship_manager) {
            V2TIM_LOG(kError, "[dart_compat] GetFriendshipManager() returned nullptr");
            return;
        }
        DartFriendshipListenerImpl* listener = GetOrCreateFriendshipListener();
        friendship_manager->AddFriendListener(listener);
    }
}

// ============================================================================
// Conversation Callbacks
// ============================================================================

class DartConversationListenerImpl : public V2TIMConversationListener {
public:
    void OnNewConversation(const V2TIMConversationVector& conversationList) override {
        // Convert V2TIMConversationVector to JSON using ConversationVectorToJson
        std::string conv_json = ConversationVectorToJson(conversationList);
        std::map<std::string, std::string> fields;
        fields["json_conv_array"] = conv_json;
        // Set conv_event to conversationEventAdd (0) for OnNewConversation
        fields["conv_event"] = "0";
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ConversationEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvEvent"));
    }

    void OnConversationChanged(const V2TIMConversationVector& conversationList) override {
        try {
            // Convert V2TIMConversationVector to JSON using ConversationVectorToJson
            std::string conv_json = ConversationVectorToJson(conversationList);
            std::map<std::string, std::string> fields;
            fields["json_conv_array"] = conv_json;
            fields["conv_event"] = "2";
            int64_t instance_id = GetInstanceIdForListener(this);
            if (instance_id == 0) instance_id = GetCurrentInstanceId();
            std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvEvent"));
            std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ConversationEvent, fields, user_data, instance_id);
            SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvEvent"));
        } catch (const std::exception& e) {
            V2TIM_LOG(kError, "[dart_compat] DartConversationListenerImpl::OnConversationChanged: exception {}", e.what());
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] DartConversationListenerImpl::OnConversationChanged: unknown exception");
        }
    }
    
    void OnConversationDeleted(const V2TIMStringVector& conversationIDList) override {
        try {
            // Build a JSON array of conversation ID strings: ["id1", "id2", ...]
            std::ostringstream json;
            json << "[";
            for (size_t i = 0; i < conversationIDList.Size(); i++) {
                if (i > 0) json << ",";
                json << "\"" << EscapeJsonString(std::string(conversationIDList[i].CString())) << "\"";
            }
            json << "]";
            std::map<std::string, std::string> fields;
            fields["json_conv_array"] = json.str();
            // conv_event = 1 means conversationEventDel
            fields["conv_event"] = "1";
            int64_t instance_id = GetInstanceIdForListener(this);
            if (instance_id == 0) instance_id = GetCurrentInstanceId();
            std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvEvent"));
            std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ConversationEvent, fields, user_data, instance_id);
            SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvEvent"));
        } catch (const std::exception& e) {
            V2TIM_LOG(kError, "[dart_compat] DartConversationListenerImpl::OnConversationDeleted: exception {}", e.what());
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] DartConversationListenerImpl::OnConversationDeleted: unknown exception");
        }
    }

    void OnTotalUnreadMessageCountChanged(uint64_t totalUnreadCount) override {
        std::map<std::string, std::string> fields;
        fields["total_unread_count"] = std::to_string(totalUnreadCount);
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvTotalUnreadMessageCountChanged"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::TotalUnreadMessageCountChanged, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvTotalUnreadMessageCountChanged"));
    }
    
    void OnUnreadMessageCountChangedByFilter(const V2TIMConversationListFilter& filter, uint64_t totalUnreadCount) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::map<std::string, std::string> fields;
        fields["total_unread_count"] = std::to_string(totalUnreadCount);
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvUnreadMessageCountChangedByFilter"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::TotalUnreadMessageCountChangedByFilter, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvUnreadMessageCountChangedByFilter"));
    }
    
    void OnConversationGroupCreated(const V2TIMString& groupName, const V2TIMConversationVector& conversationList) override {
        // Convert V2TIMConversationVector to JSON using ConversationVectorToJson
        std::string conv_json = ConversationVectorToJson(conversationList);
        std::map<std::string, std::string> fields;
        fields["group_name"] = groupName.CString();
        fields["json_conv_array"] = conv_json;
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvConversationGroupCreated"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ConversationGroupCreated, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvConversationGroupCreated"));
    }
    
    void OnConversationGroupDeleted(const V2TIMString& groupName) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::map<std::string, std::string> fields;
        fields["group_name"] = groupName.CString();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvConversationGroupDeleted"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ConversationGroupDeleted, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvConversationGroupDeleted"));
    }
    
    void OnConversationGroupNameChanged(const V2TIMString& oldName, const V2TIMString& newName) override {
        std::map<std::string, std::string> fields;
        fields["old_name"] = oldName.CString();
        fields["new_name"] = newName.CString();
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvConversationGroupNameChanged"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ConversationGroupNameChanged, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvConversationGroupNameChanged"));
    }
    
    void OnConversationsAddedToGroup(const V2TIMString& groupName, const V2TIMConversationVector& conversationList) override {
        // Convert V2TIMConversationVector to JSON using ConversationVectorToJson
        std::string conv_json = ConversationVectorToJson(conversationList);
        std::map<std::string, std::string> fields;
        fields["group_name"] = groupName.CString();
        fields["json_conv_array"] = conv_json;
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvConversationsAddedToGroup"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ConversationsAddedToGroup, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvConversationsAddedToGroup"));
    }
    
    void OnConversationsDeletedFromGroup(const V2TIMString& groupName, const V2TIMConversationVector& conversationList) override {
        // Convert V2TIMConversationVector to JSON using ConversationVectorToJson
        std::string conv_json = ConversationVectorToJson(conversationList);
        std::map<std::string, std::string> fields;
        fields["group_name"] = groupName.CString();
        fields["json_conv_array"] = conv_json;
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "ConvConversationsDeletedFromGroup"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ConversationsDeletedFromGroup, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "ConvConversationsDeletedFromGroup"));
    }
};

// Conversation callbacks
extern "C" {
    void DartSetConvEventCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "ConvEvent", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetConvEventCallback: GetConversationManager() returned nullptr");
            return;
        }
        DartConversationListenerImpl* listener = GetOrCreateConversationListener();
        conv_manager->AddConversationListener(listener);
    }
    
    void DartSetConvTotalUnreadMessageCountChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "ConvTotalUnreadMessageCountChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetConvTotalUnreadMessageCountChangedCallback: GetConversationManager() returned nullptr");
            return;
        }
        DartConversationListenerImpl* listener = GetOrCreateConversationListener();
        conv_manager->AddConversationListener(listener);
    }
    
    void DartSetConvUnreadMessageCountChangedByFilterCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "ConvUnreadMessageCountChangedByFilter", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetConvUnreadMessageCountChangedByFilterCallback: GetConversationManager() returned nullptr");
            return;
        }
        DartConversationListenerImpl* listener = GetOrCreateConversationListener();
        conv_manager->AddConversationListener(listener);
    }
    
    void DartSetConvConversationGroupCreatedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "ConvConversationGroupCreated", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetConvConversationGroupCreatedCallback: GetConversationManager() returned nullptr");
            return;
        }
        DartConversationListenerImpl* listener = GetOrCreateConversationListener();
        conv_manager->AddConversationListener(listener);
    }
    
    void DartSetConvConversationGroupDeletedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "ConvConversationGroupDeleted", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetConvConversationGroupDeletedCallback: GetConversationManager() returned nullptr");
            return;
        }
        DartConversationListenerImpl* listener = GetOrCreateConversationListener();
        conv_manager->AddConversationListener(listener);
    }
    
    void DartSetConvConversationGroupNameChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "ConvConversationGroupNameChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetConvConversationGroupNameChangedCallback: GetConversationManager() returned nullptr");
            return;
        }
        DartConversationListenerImpl* listener = GetOrCreateConversationListener();
        conv_manager->AddConversationListener(listener);
    }
    
    void DartSetConvConversationsAddedToGroupCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "ConvConversationsAddedToGroup", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetConvConversationsAddedToGroupCallback: GetConversationManager() returned nullptr");
            return;
        }
        DartConversationListenerImpl* listener = GetOrCreateConversationListener();
        conv_manager->AddConversationListener(listener);
    }
    
    void DartSetConvConversationsDeletedFromGroupCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "ConvConversationsDeletedFromGroup", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetConvConversationsDeletedFromGroupCallback: GetConversationManager() returned nullptr");
            return;
        }
        DartConversationListenerImpl* listener = GetOrCreateConversationListener();
        conv_manager->AddConversationListener(listener);
    }
}

// ============================================================================
// Group Callbacks
// ============================================================================

// Helper function to convert V2TIMGroupMemberInfo to JSON (generic keys)
static std::string GroupMemberInfoToJson(const V2TIMGroupMemberInfo& member) {
    std::ostringstream json;
    json << "{";
    json << "\"userID\":\"" << EscapeJsonString(member.userID.CString()) << "\",";
    json << "\"nickName\":\"" << EscapeJsonString(member.nickName.CString()) << "\",";
    json << "\"friendRemark\":\"" << EscapeJsonString(member.friendRemark.CString()) << "\",";
    json << "\"nameCard\":\"" << EscapeJsonString(member.nameCard.CString()) << "\",";
    json << "\"faceURL\":\"" << EscapeJsonString(member.faceURL.CString()) << "\"";
    json << "}";
    return json.str();
}

// Dart V2TimGroupMemberInfo.fromJson expects group_member_info_identifier, group_member_info_nick_name, etc.
// Use this when building group_tips_elem_changed_group_memberinfo_array and group_tips_elem_op_group_memberinfo.
static std::string GroupMemberInfoToJsonForDart(const V2TIMGroupMemberInfo& member) {
    std::ostringstream json;
    json << "{";
    json << "\"group_member_info_identifier\":\"" << EscapeJsonString(member.userID.CString()) << "\",";
    json << "\"group_member_info_nick_name\":\"" << EscapeJsonString(member.nickName.CString()) << "\",";
    json << "\"group_member_info_friend_remark\":\"" << EscapeJsonString(member.friendRemark.CString()) << "\",";
    json << "\"group_member_info_name_card\":\"" << EscapeJsonString(member.nameCard.CString()) << "\",";
    json << "\"group_member_info_face_url\":\"" << EscapeJsonString(member.faceURL.CString()) << "\"";
    json << "}";
    return json.str();
}

// Helper function to convert V2TIMGroupMemberInfoVector to JSON array (generic keys)
static std::string GroupMemberInfoVectorToJson(const V2TIMGroupMemberInfoVector& members) {
    std::ostringstream json;
    json << "[";
    for (size_t i = 0; i < members.Size(); i++) {
        if (i > 0) json << ",";
        json << GroupMemberInfoToJson(members[i]);
    }
    json << "]";
    return json.str();
}

// For GroupTipsEvent: Dart V2TimGroupTipsElem parses group_tips_elem_changed_group_memberinfo_array
// with V2TimGroupMemberInfo.fromJson, which expects group_member_info_identifier etc.
static std::string GroupMemberInfoVectorToJsonForDart(const V2TIMGroupMemberInfoVector& members) {
    std::ostringstream json;
    json << "[";
    for (size_t i = 0; i < members.Size(); i++) {
        if (i > 0) json << ",";
        json << GroupMemberInfoToJsonForDart(members[i]);
    }
    json << "]";
    return json.str();
}

// Helper function to convert V2TIMGroupChangeInfo to JSON
static std::string GroupChangeInfoToJson(const V2TIMGroupChangeInfo& change) {
    std::ostringstream json;
    json << "{";
    json << "\"type\":" << static_cast<int>(change.type) << ",";
    json << "\"value\":\"" << EscapeJsonString(change.value.CString()) << "\",";
    json << "\"key\":\"" << EscapeJsonString(change.key.CString()) << "\",";
    json << "\"boolValue\":" << std::boolalpha << (change.boolValue ? true : false) << ",";
    json << "\"intValue\":" << change.intValue << ",";
    json << "\"uint64Value\":" << change.uint64Value;
    json << "}";
    return json.str();
}

// Helper function to convert V2TIMGroupChangeInfoVector to JSON array
static std::string GroupChangeInfoVectorToJson(const V2TIMGroupChangeInfoVector& changes) {
    std::ostringstream json;
    json << "[";
    for (size_t i = 0; i < changes.Size(); i++) {
        if (i > 0) json << ",";
        json << GroupChangeInfoToJson(changes[i]);
    }
    json << "]";
    return json.str();
}

// Helper function to convert V2TIMGroupMemberChangeInfo to JSON
static std::string GroupMemberChangeInfoToJson(const V2TIMGroupMemberChangeInfo& change) {
    // Field names MUST match Dart's V2TimGroupMemberChangeInfo.fromJson, which reads
    // group_tips_member_change_info_identifier / _shutupTime — NOT userID / muteTime.
    // Emitting the wrong keys made Dart parse an empty userID, so onMemberInfoChanged
    // listeners could not tell which member changed (e.g. scenario_group_state_changes_test's
    // role-change notification fired but carried no identity). Mirrors the correct names
    // already used by dart_compat_group.cpp's NotifyTargetUserMemberInfoChanged.
    std::ostringstream json;
    json << "{";
    json << "\"group_tips_member_change_info_identifier\":\"" << EscapeJsonString(change.userID.CString()) << "\",";
    json << "\"group_tips_member_change_info_shutupTime\":" << change.muteTime;
    json << "}";
    return json.str();
}

// Helper function to convert V2TIMGroupMemberChangeInfoVector to JSON array
static std::string GroupMemberChangeInfoVectorToJson(const V2TIMGroupMemberChangeInfoVector& changes) {
    std::ostringstream json;
    json << "[";
    for (size_t i = 0; i < changes.Size(); i++) {
        if (i > 0) json << ",";
        json << GroupMemberChangeInfoToJson(changes[i]);
    }
    json << "]";
    return json.str();
}

// Dart CGroupTipsType (tencent_cloud_chat_sdk tim_c_enum.dart) - group_tips_elem_tip_type must use these values.
// C++ V2TIM_GROUP_TIPS_TYPE_* (V2TIMMessage.h) uses a different mapping; we send Dart values to Dart SDK.
// Dart: JOIN=1, QUIT=2, KICK=3, GRANT_ADMINISTRATOR=4, REVOKE_ADMINISTRATOR=5, GROUP_INFO_CHANGE=6,
//       GROUP_MEMBER_INFO_CHANGE=7, TOPIC_INFO_CHANGE=9, PINNED_*=10,11.
static const int kDartTipTypeJoin = 1;
static const int kDartTipTypeQuit = 2;
static const int kDartTipTypeKick = 3;
static const int kDartTipTypeGrantAdministrator = 4;
static const int kDartTipTypeRevokeAdministrator = 5;
static const int kDartTipTypeGroupInfoChange = 6;
static const int kDartTipTypeGroupMemberInfoChange = 7;
static const int kDartTipTypeTopicInfoChange = 9;
static const int kDartTipTypePinnedMessageAdded = 10;
static const int kDartTipTypePinnedMessageDeleted = 11;
// join_type for invite: GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_INVITE = 2
static const int kDartJoinTypeInvite = 2;

// Helper function to build V2TIMGroupTipsElem JSON for GroupTipsEvent
// joinType: when >= 0, emit group_tips_elem_join_type (Dart uses tip_type=JOIN + join_type=INVITE for invites)
static std::string BuildGroupTipsElemJson(
    const V2TIMString& groupID,
    int tipsType,
    const V2TIMGroupMemberInfo& opMember,
    const V2TIMGroupMemberInfoVector& memberList,
    const V2TIMGroupChangeInfoVector& groupChangeInfoList,
    const V2TIMGroupMemberChangeInfoVector& memberChangeInfoList,
    uint32_t memberCount = 0,
    int joinType = -1) {
    std::ostringstream json;
    json << "{";
    json << "\"elem_type\":" << 8 << ","; // V2TIM_ELEM_TYPE_GROUP_TIPS
    json << "\"group_tips_elem_group_id\":\"" << EscapeJsonString(groupID.CString()) << "\",";
    json << "\"group_tips_elem_tip_type\":" << tipsType << ",";
    if (joinType >= 0) {
        json << "\"group_tips_elem_join_type\":" << joinType << ",";
    }
    json << "\"group_tips_elem_op_group_memberinfo\":" << GroupMemberInfoToJsonForDart(opMember) << ",";
    json << "\"group_tips_elem_changed_group_memberinfo_array\":" << GroupMemberInfoVectorToJsonForDart(memberList) << ",";
    json << "\"group_tips_elem_group_change_info_array\":" << GroupChangeInfoVectorToJson(groupChangeInfoList) << ",";
    json << "\"group_tips_elem_member_change_info_array\":" << GroupMemberChangeInfoVectorToJson(memberChangeInfoList) << ",";
    json << "\"group_tips_elem_member_num\":" << memberCount;
    json << "}";
    return json.str();
}

class DartGroupListenerImpl : public V2TIMGroupListener {
    int64_t instance_id_;
public:
    explicit DartGroupListenerImpl(int64_t instance_id) : instance_id_(instance_id) {}
    void OnMemberEnter(const V2TIMString& groupID, const V2TIMGroupMemberInfoVector& memberList) override {
        // Build GroupTipsElem JSON for join; tip_type must be Dart CGroupTipsType.GROUP_TIPS_TYPE_JOIN(1)
        V2TIMGroupMemberInfo opMember;
        opMember.userID = V2TIMString(""); // No operator for join
        V2TIMGroupChangeInfoVector emptyChanges;
        V2TIMGroupMemberChangeInfoVector emptyMemberChanges;
        
        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID, 
            kDartTipTypeJoin,
            opMember,
            memberList,
            emptyChanges,
            emptyMemberChanges,
            memberList.Size());
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }

    void OnMemberLeave(const V2TIMString& groupID, const V2TIMGroupMemberInfo& member) override {
        // Build GroupTipsElem JSON for quit; tip_type must be Dart CGroupTipsType.GROUP_TIPS_TYPE_QUIT(2)
        V2TIMGroupMemberInfoVector memberList;
        memberList.PushBack(member);
        V2TIMGroupMemberInfo opMember = member; // Operator is the leaving member
        V2TIMGroupChangeInfoVector emptyChanges;
        V2TIMGroupMemberChangeInfoVector emptyMemberChanges;
        
        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID, 
            kDartTipTypeQuit,
            opMember,
            memberList,
            emptyChanges,
            emptyMemberChanges,
            0);
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }

    void OnMemberInvited(const V2TIMString& groupID, const V2TIMGroupMemberInfo& opUser, 
                         const V2TIMGroupMemberInfoVector& memberList) override {
        // Build GroupTipsElem JSON for invite. Dart expects tip_type=JOIN(1) + join_type=INVITE(2).
        V2TIMGroupChangeInfoVector emptyChanges;
        V2TIMGroupMemberChangeInfoVector emptyMemberChanges;
        
        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID, 
            kDartTipTypeJoin,
            opUser,
            memberList,
            emptyChanges,
            emptyMemberChanges,
            static_cast<uint32_t>(memberList.Size()),
            kDartJoinTypeInvite);
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }
    
    void OnMemberKicked(const V2TIMString& groupID, const V2TIMGroupMemberInfo& opUser, 
                        const V2TIMGroupMemberInfoVector& memberList) override {
        // Build GroupTipsElem JSON for kicked; tip_type must be Dart CGroupTipsType.GROUP_TIPS_TYPE_KICK(3)
        V2TIMGroupChangeInfoVector emptyChanges;
        V2TIMGroupMemberChangeInfoVector emptyMemberChanges;
        
        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID, 
            kDartTipTypeKick,
            opUser,
            memberList,
            emptyChanges,
            emptyMemberChanges,
            memberList.Size());
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }
    
    void OnMemberInfoChanged(const V2TIMString& groupID,
                             const V2TIMGroupMemberChangeInfoVector& v2TIMGroupMemberChangeInfoList) override {
        // Build GroupTipsElem JSON for member info change; tip_type must be Dart CGroupTipsType.GROUP_TIPS_TYPE_GROUP_MEMBER_INFO_CHANGE(7)
        V2TIMGroupMemberInfo opMember;
        opMember.userID = V2TIMString(""); // No operator info available
        // Populate the tip's member list with the changed members. Dart's
        // native_library_manager only delivers onMemberInfoChanged when the tip's
        // memberList is non-empty (`if (groupMemberList.isNotEmpty)`); a member-info
        // change with an empty member list is silently dropped. Real Tencent IM tips
        // carry the affected members here too, so mirror that.
        V2TIMGroupMemberInfoVector changedMembers;
        for (size_t i = 0; i < v2TIMGroupMemberChangeInfoList.Size(); i++) {
            V2TIMGroupMemberInfo m;
            m.userID = v2TIMGroupMemberChangeInfoList[i].userID;
            changedMembers.PushBack(m);
        }
        V2TIMGroupChangeInfoVector emptyChanges;

        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID,
            kDartTipTypeGroupMemberInfoChange,
            opMember,
            changedMembers,
            emptyChanges,
            v2TIMGroupMemberChangeInfoList,
            0);
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }

    void OnGroupInfoChanged(const V2TIMString& groupID, const V2TIMGroupChangeInfoVector& changeInfos) override {
        // Build GroupTipsElem JSON for group info change; tip_type must be Dart CGroupTipsType.GROUP_TIPS_TYPE_GROUP_INFO_CHANGE(6)
        V2TIMGroupMemberInfo opMember;
        opMember.userID = V2TIMString(""); // No operator info available
        V2TIMGroupMemberInfoVector emptyMemberList;
        V2TIMGroupMemberChangeInfoVector emptyMemberChanges;
        
        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID, 
            kDartTipTypeGroupInfoChange,
            opMember,
            emptyMemberList,
            changeInfos,
            emptyMemberChanges,
            0);
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }
    
    void OnGrantAdministrator(const V2TIMString& groupID, const V2TIMGroupMemberInfo& opUser,
                              const V2TIMGroupMemberInfoVector& memberList) override {
        // Build GroupTipsElem JSON for set admin; tip_type must be Dart CGroupTipsType.GROUP_TIPS_TYPE_GRANT_ADMINISTRATOR(4)
        V2TIMGroupChangeInfoVector emptyChanges;
        V2TIMGroupMemberChangeInfoVector emptyMemberChanges;
        
        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID, 
            kDartTipTypeGrantAdministrator,
            opUser,
            memberList,
            emptyChanges,
            emptyMemberChanges,
            0);
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }
    
    void OnRevokeAdministrator(const V2TIMString& groupID, const V2TIMGroupMemberInfo& opUser,
                               const V2TIMGroupMemberInfoVector& memberList) override {
        // Build GroupTipsElem JSON for cancel admin; tip_type must be Dart CGroupTipsType.GROUP_TIPS_TYPE_REVOKE_ADMINISTRATOR(5)
        V2TIMGroupChangeInfoVector emptyChanges;
        V2TIMGroupMemberChangeInfoVector emptyMemberChanges;
        
        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID, 
            kDartTipTypeRevokeAdministrator,
            opUser,
            memberList,
            emptyChanges,
            emptyMemberChanges,
            0);
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }
    
    void OnGroupCreated(const V2TIMString& groupID) override {
        // Send OnGroupCreated callback to Dart layer via GroupTipsEvent
        // Dart SDK treats tip_type=JOIN(1) + empty memberList/opUser as onGroupCreated
        V2TIMGroupMemberInfoVector emptyMemberList;
        V2TIMGroupMemberInfo opMember;
        opMember.userID = V2TIMString(""); // No operator for group creation
        V2TIMGroupChangeInfoVector emptyChanges;
        V2TIMGroupMemberChangeInfoVector emptyMemberChanges;
        
        std::string groupTipsJson = BuildGroupTipsElemJson(
            groupID, 
            kDartTipTypeJoin,
            opMember,
            emptyMemberList,
            emptyChanges,
            emptyMemberChanges,
            0);
        
        std::map<std::string, std::string> fields;
        fields["json_group_tip"] = groupTipsJson;
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupTipsEvent"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupTipsEvent, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupTipsEvent"));
    }
    
    void OnGroupDismissed(const V2TIMString& groupID, const V2TIMGroupMemberInfo& opUser) override {
        // OnGroupDismissed is not a GroupTipsEvent, handle separately if needed
        // For now, we'll skip sending this via GroupTipsEvent
    }
    
    void OnGroupRecycled(const V2TIMString& groupID, const V2TIMGroupMemberInfo& opUser) override {
        // OnGroupRecycled is not a GroupTipsEvent, handle separately if needed
        // For now, we'll skip sending this via GroupTipsEvent
    }
    
    void OnGroupAttributeChanged(const V2TIMString& groupID, const V2TIMGroupAttributeMap& groupAttributeMap) override {
        // Convert groupAttributeMap to JSON array using AllKeys() and Get(key)
        std::ostringstream attrJson;
        attrJson << "[";
        bool first = true;
        V2TIMStringVector keys = groupAttributeMap.AllKeys();
        for (size_t i = 0; i < keys.Size(); i++) {
            if (!first) attrJson << ",";
            first = false;
            const V2TIMString& key = keys[i];
            const V2TIMString& value = groupAttributeMap.Get(key);
            attrJson << "{\"group_attribute_key\":\"" << EscapeJsonString(key.CString()) << "\",";
            attrJson << "\"group_attribute_value\":\"" << EscapeJsonString(value.CString()) << "\"}";
        }
        attrJson << "]";
        
        std::map<std::string, std::string> fields;
        fields["group_id"] = groupID.CString();
        fields["json_group_attribute_array"] = attrJson.str();
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupAttributeChanged"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupAttributeChanged, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupAttributeChanged"));
    }
    
    void OnGroupCounterChanged(const V2TIMString& groupID, const V2TIMString& key, int64_t newValue) override {
        int64_t instance_id = instance_id_;
        
        std::map<std::string, std::string> fields;
        fields["group_id"] = groupID.CString();
        fields["group_counter_key"] = key.CString();
        fields["group_counter_new_value"] = std::to_string(newValue);
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "GroupCounterChanged"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::GroupCounterChanged, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "GroupCounterChanged"));
    }
    
    // Other callbacks that are less commonly used - implement as needed
    void OnAllGroupMembersMuted(const V2TIMString& groupID, bool isMute) override {
        // Not typically sent via GroupTipsEvent, handle separately if needed
    }
    
    void OnMemberMarkChanged(const V2TIMString& groupID, const V2TIMStringVector& memberIDList, 
                            uint32_t markType, bool enableMark) override {
        // Not typically sent via GroupTipsEvent, handle separately if needed
    }
    
    void OnReceiveJoinApplication(const V2TIMString& groupID, const V2TIMGroupMemberInfo& member,
                                  const V2TIMString& opReason) override {
        // Not typically sent via GroupTipsEvent, handle separately if needed
    }
    
    void OnApplicationProcessed(const V2TIMString& groupID, const V2TIMGroupMemberInfo& opUser, 
                               bool isAgreeJoin, const V2TIMString& opReason) override {
        // Not typically sent via GroupTipsEvent, handle separately if needed
    }
    
    void OnQuitFromGroup(const V2TIMString& groupID) override {
        // Not typically sent via GroupTipsEvent, handle separately if needed
    }
    
    void OnReceiveRESTCustomData(const V2TIMString& groupID, const V2TIMBuffer& customData) override {
        // Not typically sent via GroupTipsEvent, handle separately if needed
    }
    
    void OnTopicCreated(const V2TIMString& groupID, const V2TIMString& topicID) override {
        // Handled by TopicCreated callback type; use instance_id_ for strict multi-instance routing
        std::map<std::string, std::string> fields;
        fields["group_id"] = groupID.CString();
        fields["topic_id"] = topicID.CString();
        int64_t instance_id = instance_id_;
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "TopicCreated"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::TopicCreated, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "TopicCreated"));
    }
    
    void OnTopicDeleted(const V2TIMString& groupID, const V2TIMStringVector& topicIDList) override {
        int64_t instance_id = instance_id_;
        
        // Handled by TopicDeleted callback type
        std::ostringstream topicJson;
        topicJson << "[";
        for (size_t i = 0; i < topicIDList.Size(); i++) {
            if (i > 0) topicJson << ",";
            topicJson << "\"" << EscapeJsonString(topicIDList[i].CString()) << "\"";
        }
        topicJson << "]";
        
        std::map<std::string, std::string> fields;
        fields["group_id"] = groupID.CString();
        fields["topic_id_array"] = topicJson.str();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "TopicDeleted"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::TopicDeleted, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "TopicDeleted"));
    }
    
    void OnTopicChanged(const V2TIMString& groupID, const V2TIMTopicInfo& topicInfo) override {
        int64_t instance_id = instance_id_;
        
        // Handled by TopicChanged callback type
        // TODO: Convert V2TIMTopicInfo to JSON
        std::map<std::string, std::string> fields;
        fields["group_id"] = groupID.CString();
        fields["topic_info"] = "{}"; // Placeholder - need to implement topicInfo to JSON conversion
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "TopicChanged"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::TopicChanged, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "TopicChanged"));
    }
};

// Group callbacks
extern "C" {
    void DartSetGroupTipsEventCallback(void* user_data) {
        int64_t current_instance_id = GetCurrentInstanceId();
        
        StoreCallbackUserData(GetCurrentInstanceId(), "GroupTipsEvent", user_data);
        
        // Register group listener with ALL known instances, not just current.
        // This fixes onGroupInvited timeout when multiple nodes (e.g. Bob, Charlie) login in
        // parallel: each had called addGroupListener with setCurrentInstance(self), but only
        // the last current instance was getting the listener; now every instance gets it.
        Tim2ToxFfiForEachInstanceManager([](int64_t id, void* manager, void* user) {
            StoreCallbackUserData(id, "GroupTipsEvent", user);
            DartGroupListenerImpl* listener = GetOrCreateGroupListenerForInstance(id);
            if (listener && manager) {
                static_cast<V2TIMManagerImpl*>(manager)->AddGroupListener(listener);
            }
        }, user_data);

        // Also register for current instance (covers default instance when not in g_test_instances)
        auto* manager = SafeGetV2TIMManager();
        if (manager) {
            DartGroupListenerImpl* listener = GetOrCreateGroupListener();
            manager->AddGroupListener(listener);
        }
    }

    void DartSetGroupAttributeChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "GroupAttributeChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartGroupListenerImpl* listener = GetOrCreateGroupListener();
        manager->AddGroupListener(listener);
    }
    
    void DartSetGroupCounterChangedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "GroupCounterChanged", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        DartGroupListenerImpl* listener = GetOrCreateGroupListener();
        manager->AddGroupListener(listener);
    }
}

// ============================================================================
// Signaling Callbacks
// ============================================================================

// Helper: Convert V2TIMStringVector to JSON array string for json_invitee_list
static std::string StringVectorToJsonArray(const V2TIMStringVector& vec) {
    std::ostringstream json;
    json << "[";
    for (size_t i = 0; i < vec.Size(); i++) {
        if (i > 0) json << ",";
        json << "\"" << EscapeJsonString(vec[i].CString()) << "\"";
    }
    json << "]";
    return json.str();
}

class DartSignalingListenerImpl : public V2TIMSignalingListener {
public:
    void OnReceiveNewInvitation(const V2TIMString& inviteID, const V2TIMString& inviter,
                               const V2TIMString& groupID, const V2TIMStringVector& inviteeList,
                               const V2TIMString& data) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::map<std::string, std::string> fields;
        fields["invite_id"] = inviteID.CString();
        fields["inviter"] = inviter.CString();
        fields["group_id"] = groupID.CString();
        fields["data"] = data.CString();
        fields["json_invitee_list"] = StringVectorToJsonArray(inviteeList);
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "SignalingReceiveNewInvitation"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::SignalingReceiveNewInvitation, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "SignalingReceiveNewInvitation"));
    }

    void OnInvitationCancelled(const V2TIMString& inviteID, const V2TIMString& inviter,
                               const V2TIMString& data) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::map<std::string, std::string> fields;
        fields["invite_id"] = inviteID.CString();
        fields["inviter"] = inviter.CString();
        fields["data"] = data.CString();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "SignalingInvitationCancelled"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::SignalingInvitationCancelled, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "SignalingInvitationCancelled"));
    }

    void OnInviteeAccepted(const V2TIMString& inviteID, const V2TIMString& invitee,
                           const V2TIMString& data) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::map<std::string, std::string> fields;
        fields["invite_id"] = inviteID.CString();
        fields["invitee"] = invitee.CString();
        fields["data"] = data.CString();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "SignalingInviteeAccepted"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::SignalingInviteeAccepted, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "SignalingInviteeAccepted"));
    }

    void OnInviteeRejected(const V2TIMString& inviteID, const V2TIMString& invitee,
                           const V2TIMString& data) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::map<std::string, std::string> fields;
        fields["invite_id"] = inviteID.CString();
        fields["invitee"] = invitee.CString();
        fields["data"] = data.CString();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "SignalingInviteeRejected"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::SignalingInviteeRejected, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "SignalingInviteeRejected"));
    }

    void OnInvitationTimeout(const V2TIMString& inviteID, const V2TIMStringVector& inviteeList) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::map<std::string, std::string> fields;
        fields["invite_id"] = inviteID.CString();
        fields["json_invitee_list"] = StringVectorToJsonArray(inviteeList);
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "SignalingInvitationTimeout"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::SignalingInvitationTimeout, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "SignalingInvitationTimeout"));
    }

    void OnInvitationModified(const V2TIMString& inviteID, const V2TIMString& data) override {
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::map<std::string, std::string> fields;
        fields["invite_id"] = inviteID.CString();
        fields["data"] = data.CString();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "SignalingInvitationModified"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::SignalingInvitationModified, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "SignalingInvitationModified"));
    }
};

// Signaling callbacks
extern "C" {
    void DartSetSignalingReceiveNewInvitationCallback(void* user_data) {
        int64_t current_id = GetCurrentInstanceId();
        StoreCallbackUserData(current_id, "SignalingReceiveNewInvitation", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetSignalingReceiveNewInvitationCallback: current_id={}, manager=null", (long long)current_id);
            return;
        }
        auto* signaling_manager = manager->GetSignalingManager();
        if (!signaling_manager) {
            V2TIM_LOG(kError, "[dart_compat] DartSetSignalingReceiveNewInvitationCallback: current_id={}, signaling_manager=null", (long long)current_id);
            return;
        }
        DartSignalingListenerImpl* listener = GetOrCreateSignalingListener();
        signaling_manager->AddSignalingListener(listener);
    }
    
    void DartSetSignalingInvitationCancelledCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "SignalingInvitationCancelled", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* signaling_manager = manager->GetSignalingManager();
        if (!signaling_manager) {
            // GetSignalingManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartSignalingListenerImpl* listener = GetOrCreateSignalingListener();
        signaling_manager->AddSignalingListener(listener);
    }
    
    void DartSetSignalingInviteeAcceptedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "SignalingInviteeAccepted", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* signaling_manager = manager->GetSignalingManager();
        if (!signaling_manager) {
            // GetSignalingManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartSignalingListenerImpl* listener = GetOrCreateSignalingListener();
        signaling_manager->AddSignalingListener(listener);
    }
    
    void DartSetSignalingInviteeRejectedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "SignalingInviteeRejected", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* signaling_manager = manager->GetSignalingManager();
        if (!signaling_manager) {
            // GetSignalingManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartSignalingListenerImpl* listener = GetOrCreateSignalingListener();
        signaling_manager->AddSignalingListener(listener);
    }
    
    void DartSetSignalingInvitationTimeoutCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "SignalingInvitationTimeout", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* signaling_manager = manager->GetSignalingManager();
        if (!signaling_manager) {
            // GetSignalingManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartSignalingListenerImpl* listener = GetOrCreateSignalingListener();
        signaling_manager->AddSignalingListener(listener);
    }
    
    void DartSetSignalingInvitationModifiedCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "SignalingInvitationModified", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* signaling_manager = manager->GetSignalingManager();
        if (!signaling_manager) {
            // GetSignalingManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartSignalingListenerImpl* listener = GetOrCreateSignalingListener();
        signaling_manager->AddSignalingListener(listener);
    }

    void DartRemoveSignalingListenerForCurrentInstance(void) {
        int64_t instance_id = GetCurrentInstanceId();
        std::lock_guard<std::mutex> lock(g_listeners_mutex);
        auto it = g_signaling_listeners.find(instance_id);
        if (it == g_signaling_listeners.end()) return;
        DartSignalingListenerImpl* listener = it->second;
        V2TIMManager* manager = SafeGetV2TIMManager();
        if (!manager) return;
        V2TIMSignalingManager* sig_mgr = manager->GetSignalingManager();
        if (sig_mgr) sig_mgr->RemoveSignalingListener(listener);
    }
}

// ============================================================================
// Community Callbacks
// ============================================================================

class DartCommunityListenerImpl : public V2TIMCommunityListener {
public:
    void OnCreateTopic(const V2TIMString& groupID, const V2TIMString& topicID) override {
        std::map<std::string, std::string> fields;
        fields["group_id"] = groupID.CString();
        fields["topic_id"] = topicID.CString();
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "CommunityTopicCreated"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::TopicCreated, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "CommunityTopicCreated"));
    }
    
    void OnDeleteTopic(const V2TIMString& groupID, const V2TIMStringVector& topicIDList) override {
        std::map<std::string, std::string> fields;
        fields["group_id"] = groupID.CString();
        fields["json_topic_id_array"] = "[]";  // Placeholder
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "CommunityTopicDeleted"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::TopicDeleted, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "CommunityTopicDeleted"));
    }
    
    void OnChangeTopicInfo(const V2TIMString& groupID, const V2TIMTopicInfo& topicInfo) override {
        std::map<std::string, std::string> fields;
        fields["group_id"] = groupID.CString();
        fields["json_topic_info"] = "{}";  // Placeholder - will convert topicInfo to JSON
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "CommunityTopicChanged"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::TopicChanged, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "CommunityTopicChanged"));
    }
    
    void OnReceiveTopicRESTCustomData(const V2TIMString& topicID, const V2TIMBuffer& customData) override {
        std::map<std::string, std::string> fields;
        fields["topic_id"] = topicID.CString();
        fields["json_custom_data"] = "{}";  // Placeholder
        int64_t instance_id = GetInstanceIdForListener(this);
        if (instance_id == 0) instance_id = GetCurrentInstanceId();
        std::string user_data = UserDataToString(GetCallbackUserData(instance_id, "CommunityReceiveTopicRESTCustomData"));
        std::string json_msg = BuildGlobalCallbackJson(GlobalCallbackType::ReceiveTopicRESTCustomData, fields, user_data, instance_id);
        SendCallbackToDart("globalCallback", json_msg, GetCallbackUserData(instance_id, "CommunityReceiveTopicRESTCustomData"));
    }
};

// Community callbacks
extern "C" {
    void DartSetCommunityCreateTopicCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityCreateTopic", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityDeleteTopicCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityDeleteTopic", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityChangeTopicInfoCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityChangeTopicInfo", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityReceiveTopicRESTCustomDataCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityReceiveTopicRESTCustomData", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityCreatePermissionGroupCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityCreatePermissionGroup", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityDeletePermissionGroupCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityDeletePermissionGroup", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityChangePermissionGroupInfoCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityChangePermissionGroupInfo", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityAddMembersToPermissionGroupCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityAddMembersToPermissionGroup", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityRemoveMembersFromPermissionGroupCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityRemoveMembersFromPermissionGroup", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityAddTopicPermissionCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityAddTopicPermission", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityDeleteTopicPermissionCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityDeleteTopicPermission", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
    
    void DartSetCommunityModifyTopicPermissionCallback(void* user_data) {
        StoreCallbackUserData(GetCurrentInstanceId(), "CommunityModifyTopicPermission", user_data);
        auto* manager = SafeGetV2TIMManager();
        if (!manager) return; // SDK not initialized, skip listener registration
        auto* community_manager = manager->GetCommunityManager();
        if (!community_manager) {
            // GetCommunityManager() returns nullptr because it's not implemented yet - this is expected
            return;
        }
        DartCommunityListenerImpl* listener = GetOrCreateCommunityListener();
        community_manager->AddCommunityListener(listener);
    }
}

// ============================================================================
// Per-Instance Listener Management
// ============================================================================
// These functions must be defined after all listener class definitions
// so they can create instances of the complete types

// Helper function to get or create SDK listener for current instance
DartSDKListenerImpl* GetOrCreateSDKListener() {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    int64_t instance_id = GetCurrentInstanceId();
    auto it = g_sdk_listeners.find(instance_id);
    if (it != g_sdk_listeners.end()) {
        return it->second;
    }
    DartSDKListenerImpl* listener = new DartSDKListenerImpl();
    g_sdk_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create AdvancedMsg listener for current instance
DartAdvancedMsgListenerImpl* GetOrCreateAdvancedMsgListener() {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    int64_t instance_id = GetCurrentInstanceId();
    auto it = g_advanced_msg_listeners.find(instance_id);
    if (it != g_advanced_msg_listeners.end()) {
        return it->second;
    }
    DartAdvancedMsgListenerImpl* listener = new DartAdvancedMsgListenerImpl();
    g_advanced_msg_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create AdvancedMsg listener for a specific instance_id.
// Used by ReplayListenersForNewInstance when registering advanced-msg listener on a
// newly-created test instance whose current_instance pointer may not yet be set.
DartAdvancedMsgListenerImpl* GetOrCreateAdvancedMsgListenerForInstance(int64_t instance_id) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    auto it = g_advanced_msg_listeners.find(instance_id);
    if (it != g_advanced_msg_listeners.end()) {
        return it->second;
    }
    DartAdvancedMsgListenerImpl* listener = new DartAdvancedMsgListenerImpl();
    g_advanced_msg_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create SDK listener for a specific instance_id.
// Mirror of GetOrCreateAdvancedMsgListenerForInstance for SDK listeners (network
// status, user info changed, user status changed, self info updated, etc.).
DartSDKListenerImpl* GetOrCreateSDKListenerForInstance(int64_t instance_id) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    auto it = g_sdk_listeners.find(instance_id);
    if (it != g_sdk_listeners.end()) {
        return it->second;
    }
    DartSDKListenerImpl* listener = new DartSDKListenerImpl();
    g_sdk_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create Conversation listener for current instance
DartConversationListenerImpl* GetOrCreateConversationListener() {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    int64_t instance_id = GetCurrentInstanceId();
    auto it = g_conversation_listeners.find(instance_id);
    if (it != g_conversation_listeners.end()) {
        return it->second;
    }
    DartConversationListenerImpl* listener = new DartConversationListenerImpl();
    g_conversation_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create Conversation listener for a specific
// instance_id. Mirror of GetOrCreateAdvancedMsgListenerForInstance /
// GetOrCreateSDKListenerForInstance — used by ReplayListenersForNewInstance
// so the new instance's V2TIMConversationManagerImpl has at least one
// listener registered to receive NotifyConversationChangedForConvID etc.
// from V2TIMMessageManagerImpl::SendMessage success paths.
DartConversationListenerImpl* GetOrCreateConversationListenerForInstance(int64_t instance_id) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    auto it = g_conversation_listeners.find(instance_id);
    if (it != g_conversation_listeners.end()) {
        return it->second;
    }
    DartConversationListenerImpl* listener = new DartConversationListenerImpl();
    g_conversation_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create Group listener for current instance
DartGroupListenerImpl* GetOrCreateGroupListener() {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    int64_t instance_id = GetCurrentInstanceId();
    auto it = g_group_listeners.find(instance_id);
    if (it != g_group_listeners.end()) {
        return it->second;
    }
    DartGroupListenerImpl* listener = new DartGroupListenerImpl(instance_id);
    g_group_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create Group listener for a specific instance_id
// Used when registering group listener with all instances (multi-instance support).
DartGroupListenerImpl* GetOrCreateGroupListenerForInstance(int64_t instance_id) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    auto it = g_group_listeners.find(instance_id);
    if (it != g_group_listeners.end()) {
        return it->second;
    }
    DartGroupListenerImpl* listener = new DartGroupListenerImpl(instance_id);
    g_group_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create Friendship listener for current instance
DartFriendshipListenerImpl* GetOrCreateFriendshipListener() {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    int64_t instance_id = GetCurrentInstanceId();
    auto it = g_friendship_listeners.find(instance_id);
    if (it != g_friendship_listeners.end()) {
        return it->second;
    }
    DartFriendshipListenerImpl* listener = new DartFriendshipListenerImpl();
    g_friendship_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get current instance's Friendship listener (returns nullptr if not found)
// This is used by V2TIMManagerImpl::HandleFriendRequest to notify only the current instance's listener
DartFriendshipListenerImpl* GetCurrentInstanceFriendshipListener() {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    int64_t instance_id = GetCurrentInstanceId();
    auto it = g_friendship_listeners.find(instance_id);
    if (it != g_friendship_listeners.end()) {
        return it->second;
    }
    return nullptr;
}

// Get Friendship listener for a specific V2TIMManagerImpl instance
// This is used by V2TIMManagerImpl::HandleFriendRequest to notify only the current instance's listener
// Forward declaration
class V2TIMManagerImpl;
extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
DartFriendshipListenerImpl* GetFriendshipListenerForManager(V2TIMManagerImpl* manager) {
    if (!manager) return nullptr;
    int64_t instance_id = GetInstanceIdFromManager(manager);
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    auto it = g_friendship_listeners.find(instance_id);
    if (it != g_friendship_listeners.end()) {
        return it->second;
    }
    return nullptr;
}

// Get or create Friendship listener for a specific instance_id
// This is used by V2TIMManagerImpl::HandleFriendRequest when no listener exists yet
DartFriendshipListenerImpl* GetOrCreateFriendshipListenerForInstance(int64_t instance_id) {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    auto it = g_friendship_listeners.find(instance_id);
    if (it != g_friendship_listeners.end()) {
        return it->second;
    }
    DartFriendshipListenerImpl* listener = new DartFriendshipListenerImpl();
    g_friendship_listeners[instance_id] = listener;
    return listener;
}

// Register a Dart friendship listener with the instance's friendship manager (R-06: no singleton).
// Used by V2TIMManagerImpl when it creates a listener via GetOrCreateFriendshipListenerForInstance.
void RegisterFriendshipListenerWithManager(DartFriendshipListenerImpl* listener, V2TIMManagerImpl* manager) {
    if (!listener || !manager) return;
    V2TIMFriendshipManager* fm = manager->GetFriendshipManager();
    if (!fm) return;
    fm->AddFriendListener(static_cast<V2TIMFriendshipListener*>(listener));
}

// Notify friendship listener of friend info changed (called from V2TIMManagerImpl where DartFriendshipListenerImpl is incomplete)
void NotifyFriendInfoChangedToListener(DartFriendshipListenerImpl* listener, const void* friendInfoList_ptr) {
    if (!listener || !friendInfoList_ptr) return;
    const V2TIMFriendInfoVector& list = *static_cast<const V2TIMFriendInfoVector*>(friendInfoList_ptr);
    listener->OnFriendInfoChanged(list);
}

// Helper function to notify friend application list added
// This allows V2TIMManagerImpl to call OnFriendApplicationListAdded without including the full class definition
void NotifyFriendApplicationListAddedToListener(DartFriendshipListenerImpl* listener, const void* applications_ptr) {
    if (!listener || !applications_ptr) {
        V2TIM_LOG(kWarning, "[NotifyFriendApplicationListAddedToListener] listener or applications_ptr is null");
        return;
    }
    const V2TIMFriendApplicationVector& applications = *static_cast<const V2TIMFriendApplicationVector*>(applications_ptr);
    listener->OnFriendApplicationListAdded(applications);
}

// Helper function to get or create Signaling listener for current instance
DartSignalingListenerImpl* GetOrCreateSignalingListener() {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    int64_t instance_id = GetCurrentInstanceId();
    auto it = g_signaling_listeners.find(instance_id);
    if (it != g_signaling_listeners.end()) {
        return it->second;
    }
    DartSignalingListenerImpl* listener = new DartSignalingListenerImpl();
    g_signaling_listeners[instance_id] = listener;
    return listener;
}

// Helper function to get or create Community listener for current instance
DartCommunityListenerImpl* GetOrCreateCommunityListener() {
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    int64_t instance_id = GetCurrentInstanceId();
    auto it = g_community_listeners.find(instance_id);
    if (it != g_community_listeners.end()) {
        return it->second;
    }
    DartCommunityListenerImpl* listener = new DartCommunityListenerImpl();
    g_community_listeners[instance_id] = listener;
    return listener;
}

// Helper function to replay previously-registered listener callbacks on a newly-created
// test instance. The Tencent SDK's TIMManager.initSDK is a Dart-side singleton with an
// early-return guard (`if (_isInitSDK) return true`), so when a multi-instance test creates
// a second test instance and calls initSDK on it, the SDK's internal listener wiring
// (TIMGroupManager.init -> setGroupListener -> DartSetGroupTipsEventCallback, etc.) is
// silently skipped. The result was that only the FIRST node's V2TIMManagerImpl had
// listeners registered; the SECOND node received Tox callbacks (e.g. group invite,
// member-info-change) but had an empty group_listeners_ set, so the events never
// reached Dart. Symptom: tests waiting for `onGroupInvited` time out.
//
// Fix: after a new test instance finishes InitSDK, replay any callback user_data that
// was already registered for instance_id 0 (default singleton) or any earlier instance,
// and register the matching DartListenerImpl on this new instance's manager.
//
// This is the per-instance mirror of the loop inside DartSetGroupTipsEventCallback that
// iterates all instances when Dart calls it explicitly. Together they guarantee:
//   - Listener registered before this instance existed -> picked up here (this function)
//   - Listener registered after this instance exists  -> picked up by the existing loop
void ReplayListenersForNewInstance(int64_t instance_id, V2TIMManagerImpl* manager) {
    if (!manager) return;

    // Forward declaration for callback user_data map (defined in dart_compat_utils.cpp).
    // We scan the map directly here instead of going through GetCallbackUserData() because
    // GetCallbackUserData only falls back instance_id != 0 -> 0; in the multi-instance
    // test case the user_data is actually stored under instance_id == 1 (the first test
    // instance whose Dart-side initSDK ran the singleton DartSet*Callback registration),
    // and there is no entry under instance_id == 0 to fall back to.
    extern std::map<std::pair<int64_t, std::string>, void*> g_callback_user_data;
    extern std::mutex g_callback_user_data_mutex;
    extern void StoreCallbackUserData(int64_t instance_id, const std::string& callback_name, void* user_data);

    // Look up the most-recently-registered user_data for a callback name across all
    // instances. We prefer the first non-self entry to avoid replaying our own
    // freshly-stored value (which would be a no-op anyway, but cleaner).
    auto find_existing_user_data = [&](const std::string& name) -> void* {
        std::lock_guard<std::mutex> lock(g_callback_user_data_mutex);
        for (const auto& kv : g_callback_user_data) {
            if (kv.first.second == name && kv.first.first != instance_id && kv.second) {
                return kv.second;
            }
        }
        return nullptr;
    };

    // Group listener: needed for onMemberInvited, onGroupCreated, onMemberEnter, etc.
    bool group_registered = false;
    auto register_group_listener = [&]() {
        if (group_registered) return;
        DartGroupListenerImpl* listener = GetOrCreateGroupListenerForInstance(instance_id);
        if (listener) {
            manager->AddGroupListener(listener);
            group_registered = true;
        }
    };
    if (void* group_ud = find_existing_user_data("GroupTipsEvent")) {
        StoreCallbackUserData(instance_id, "GroupTipsEvent", group_ud);
        register_group_listener();
    }
    if (void* group_attr_ud = find_existing_user_data("GroupAttributeChanged")) {
        StoreCallbackUserData(instance_id, "GroupAttributeChanged", group_attr_ud);
        register_group_listener();
    }
    if (void* group_ctr_ud = find_existing_user_data("GroupCounterChanged")) {
        StoreCallbackUserData(instance_id, "GroupCounterChanged", group_ctr_ud);
        register_group_listener();
    }

    // Friendship listener: friend tests already have an on-demand fallback in
    // V2TIMManagerImpl::HandleFriendRequest (GetOrCreateFriendshipListenerForInstance),
    // but other friendship events (HandleFriendConnectionStatus, HandleFriendStatus,
    // HandleFriendName) only iterate already-registered listeners and do not auto-create.
    // Mirror the same replay here so they fire on the new instance.
    {
        bool friend_registered = false;
        auto register_friend_listener = [&]() {
            if (friend_registered) return;
            DartFriendshipListenerImpl* listener =
                GetOrCreateFriendshipListenerForInstance(instance_id);
            if (listener) {
                auto* fm = manager->GetFriendshipManager();
                if (fm) {
                    fm->AddFriendListener(listener);
                    friend_registered = true;
                }
            }
        };
        static const char* kFriendCallbackNames[] = {
            "AddFriend",          "FriendInfoChanged",
            "FriendListAdded",    "FriendListDeleted",
            "FriendApplicationListAdded",
            "FriendApplicationListDeleted",
            "FriendApplicationListRead",
            "BlackListAdded",     "BlackListDeleted",
        };
        for (const char* name : kFriendCallbackNames) {
            if (void* ud = find_existing_user_data(name)) {
                StoreCallbackUserData(instance_id, name, ud);
                register_friend_listener();
            }
        }
        // Defense in depth: even if no prior user_data was found for any
        // friendship callback (test registers via Dart-side addFriendListener
        // only, which doesn't go through DartSet*Callback), still register the
        // listener so HandleFriendName / HandleFriendStatus / HandleFriendConnectionStatus
        // can dispatch to bob's V2TIM listener — Dart-side NativeLibraryManager
        // fans out to the singleton v2TimFriendshipListenerList without needing
        // a matching user_data in the C++ map.
        if (!friend_registered) {
            DartFriendshipListenerImpl* listener =
                GetOrCreateFriendshipListenerForInstance(instance_id);
            if (listener) {
                auto* fm = manager->GetFriendshipManager();
                if (fm) {
                    fm->AddFriendListener(listener);
                    V2TIM_LOG(kInfo,
                              "[ReplayListenersForNewInstance] Unconditionally registered Friendship listener={} on instance_id={} fm={} (no prior user_data found)",
                              (void*)listener, (long long)instance_id, (void*)fm);
                }
            }
        }
    }

    // SDK listener: register only once for this instance regardless of how many
    // SDK-listener-class callbacks were previously stored (NetworkStatus,
    // UserStatusChanged, SelfInfoUpdated, UserInfoChanged, KickedOffline,
    // UserSigExpired, LogCallback, AllMessageReceiveOption). Each
    // DartSet*Callback above calls manager->AddSDKListener with the SAME
    // DartSDKListenerImpl singleton; we mirror that here so the new instance
    // receives every SDK-listener-class callback.
    //
    // Symptom without this: scenario_user_status_virtual_test,
    // scenario_events_virtual_test, scenario_message_virtual_test,
    // scenario_message_overflow_virtual_test, scenario_avatar_virtual_test,
    // scenario_group_message_virtual_test all hang/timeout — the receiver
    // node is instance 2, but the SDK listener was only registered on
    // instance 1 (the first node whose Dart-side TIMManager.initSDK ran).
    {
        bool sdk_registered = false;
        auto register_sdk_listener = [&]() {
            if (sdk_registered) return;
            DartSDKListenerImpl* listener = GetOrCreateSDKListenerForInstance(instance_id);
            if (listener) {
                manager->AddSDKListener(listener);
                sdk_registered = true;
            }
        };
        static const char* kSDKCallbackNames[] = {
            "NetworkStatus",     "KickedOffline",        "UserSigExpired",
            "SelfInfoUpdated",   "UserStatusChanged",    "UserInfoChanged",
            "LogCallback",       "AllMessageReceiveOption",
        };
        for (const char* name : kSDKCallbackNames) {
            if (void* ud = find_existing_user_data(name)) {
                StoreCallbackUserData(instance_id, name, ud);
                register_sdk_listener();
            }
        }
    }

    // Advanced-message listener: register only once for this instance regardless
    // of how many AdvancedMsg-listener-class callbacks were previously stored
    // (ReceiveNewMessage, MessageElemUploadProgress, MessageReadReceipt,
    // MessageRevoke, MessageUpdate, MessageExtensionsChanged,
    // MessageExtensionsDeleted, MessageReactionChange, GroupPinnedMessageChanged).
    // Each DartSet*MsgCallback / DartAddReceiveNewMsgCallback above calls
    // GetMessageManager()->AddAdvancedMsgListener with the SAME
    // DartAdvancedMsgListenerImpl singleton; mirror that here so the new
    // instance receives every advanced-msg-listener-class callback. Without
    // this, the receiver node's V2TIMMessageManagerImpl.listeners_ is empty
    // and V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage
    // logs "Found 0 listeners to notify" — every message-receiving test on
    // the second instance times out.
    {
        bool adv_registered = false;
        auto register_adv_listener = [&]() {
            if (adv_registered) return;
            DartAdvancedMsgListenerImpl* listener =
                GetOrCreateAdvancedMsgListenerForInstance(instance_id);
            if (listener) {
                auto* mm = manager->GetMessageManager();
                if (mm) {
                    mm->AddAdvancedMsgListener(listener);
                    adv_registered = true;
                    V2TIM_LOG(kInfo, "[ReplayListenersForNewInstance] Registered AdvancedMsg listener={} on instance_id={} msgManager={}",
                              (void*)listener, (long long)instance_id, (void*)mm);
                }
            }
        };
        static const char* kAdvMsgCallbackNames[] = {
            "ReceiveNewMessage",         "MessageElemUploadProgress",
            "MessageReadReceipt",        "MessageRevoke",
            "MessageUpdate",             "MessageExtensionsChanged",
            "MessageExtensionsDeleted",  "MessageReactionChange",
            "GroupPinnedMessageChanged",
        };
        for (const char* name : kAdvMsgCallbackNames) {
            if (void* ud = find_existing_user_data(name)) {
                StoreCallbackUserData(instance_id, name, ud);
                register_adv_listener();
            }
        }

        // Defense in depth: even if no prior user_data was found for any
        // advanced-msg callback (e.g. timing window where the first instance's
        // _internalInitMessageListener hadn't completed before this replay ran,
        // or first instance never went through Dart-side TIMManager.initSDK
        // for some reason), still register the listener so
        // V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage can
        // dispatch. The callback bridge tolerates empty user_data (only the
        // JSON payload + instance_id matter for NativeLibraryManager dispatch
        // on the Dart side). Without this, group-message receivers on the
        // second/third test instances see "Found 0 listeners to notify" and
        // every multi-peer message test (group_general, group_large,
        // group_message_types text/multi-type/conference, group_multi,
        // group_state_changes, group_vs_conference) times out.
        if (!adv_registered) {
            DartAdvancedMsgListenerImpl* listener =
                GetOrCreateAdvancedMsgListenerForInstance(instance_id);
            if (listener) {
                auto* mm = manager->GetMessageManager();
                if (mm) {
                    mm->AddAdvancedMsgListener(listener);
                    V2TIM_LOG(kInfo, "[ReplayListenersForNewInstance] Unconditionally registered AdvancedMsg listener={} on instance_id={} msgManager={} (no prior user_data found)",
                              (void*)listener, (long long)instance_id, (void*)mm);
                }
            }
        }
    }

    // Conversation listener: V2TIMMessageManagerImpl::SendMessage success
    // path now calls V2TIMConversationManagerImpl::NotifyConversationChangedForConvID
    // which iterates the per-instance V2TIMConversationManagerImpl::listeners_
    // set. That set is only populated when DartSetConv*Callback ran on this
    // instance — which only happens on instance 1 (the first node whose
    // Dart-side TIMManager.initSDK ran). Without this replay, send-success
    // onConversationChanged dispatch is a no-op on instance 2/3 and the
    // scenario_conversation_callback_virtual_test + scenario_conversation_test
    // "Conversation callback - onConversationChanged" assertions time out
    // on the receiver node.
    //
    // Mirrors the AdvancedMsg pattern above: scan prior user_data for known
    // conversation-callback names, register on first hit, plus a defense-in-
    // depth unconditional registration when nothing was found (the C++
    // SendMessage notification doesn't actually need user_data — only the
    // listener has to exist on the manager).
    {
        bool conv_registered = false;
        auto register_conv_listener = [&]() {
            if (conv_registered) return;
            DartConversationListenerImpl* listener =
                GetOrCreateConversationListenerForInstance(instance_id);
            if (listener) {
                auto* cm = manager->GetConversationManager();
                if (cm) {
                    cm->AddConversationListener(listener);
                    conv_registered = true;
                    V2TIM_LOG(kInfo, "[ReplayListenersForNewInstance] Registered Conversation listener={} on instance_id={} convManager={}",
                              (void*)listener, (long long)instance_id, (void*)cm);
                }
            }
        };
        static const char* kConvCallbackNames[] = {
            "ConvEvent",
            "ConvTotalUnreadMessageCountChanged",
            "ConvUnreadMessageCountChangedByFilter",
            "ConvConversationGroupCreated",
            "ConvConversationGroupDeleted",
            "ConvConversationGroupNameChanged",
            "ConvConversationsAddedToGroup",
            "ConvConversationsDeletedFromGroup",
        };
        for (const char* name : kConvCallbackNames) {
            if (void* ud = find_existing_user_data(name)) {
                StoreCallbackUserData(instance_id, name, ud);
                register_conv_listener();
            }
        }
        if (!conv_registered) {
            DartConversationListenerImpl* listener =
                GetOrCreateConversationListenerForInstance(instance_id);
            if (listener) {
                auto* cm = manager->GetConversationManager();
                if (cm) {
                    cm->AddConversationListener(listener);
                    V2TIM_LOG(kInfo, "[ReplayListenersForNewInstance] Unconditionally registered Conversation listener={} on instance_id={} convManager={} (no prior user_data found)",
                              (void*)listener, (long long)instance_id, (void*)cm);
                }
            }
        }
    }
}

// Helper function to cleanup listeners for a specific instance
// Note: This should be called before destroying the instance to remove listeners from managers
// This function is defined here (not in dart_compat_utils.cpp) because it needs access to the complete listener class definitions
void CleanupInstanceListeners(int64_t instance_id) {
    // Forward declarations
    extern int64_t GetCurrentInstanceId();
    extern int tim2tox_ffi_set_current_instance(int64_t instance_handle);
    extern V2TIMManager* SafeGetV2TIMManager();

    // Simply remove listeners from map without deleting them
    // The listener objects will be cleaned up when the instance is destroyed
    // This avoids potential crashes from accessing partially destroyed objects
    std::lock_guard<std::mutex> lock(g_listeners_mutex);
    
    g_sdk_listeners.erase(instance_id);
    g_advanced_msg_listeners.erase(instance_id);
    g_conversation_listeners.erase(instance_id);
    g_group_listeners.erase(instance_id);
    g_friendship_listeners.erase(instance_id);
    g_signaling_listeners.erase(instance_id);
    g_community_listeners.erase(instance_id);
}
