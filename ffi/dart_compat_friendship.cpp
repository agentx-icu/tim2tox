// Friendship Functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"

// Forward declaration for multi-instance support
extern int64_t GetCurrentInstanceId();

// Include callback implementations (needed for callback class definitions)
// Note: We can't include the .cpp file directly, so we need to ensure callbacks.cpp is compiled
// and linked. The forward declarations in dart_compat_internal.h should be sufficient,
// but we may need to add inline definitions or move callback classes to a header.
// For now, we'll rely on the linker to resolve symbols from dart_compat_callbacks.cpp

extern "C" {
    // ============================================================================
    // Friendship Functions
    // ============================================================================
    
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
    
    // Helper class for V2TIMValueCallback<V2TIMFriendInfoVector>
    // Captures instance_id at request time so callback returns data to the correct instance
    class DartFriendInfoVectorCallback : public V2TIMValueCallback<V2TIMFriendInfoVector> {
    private:
        void* user_data_;
        int64_t instance_id_;
        
    public:
        DartFriendInfoVectorCallback(void* user_data, int64_t instance_id)
            : user_data_(user_data), instance_id_(instance_id) {}
        
        void OnSuccess(const V2TIMFriendInfoVector& friends) override {
            std::string friends_json = FriendInfoVectorToJson(friends);
            
            // V2TimValueCallback expects json_param field at top level as a JSON string
            // Use captured instance_id (request-time) so callback is routed to correct instance
            std::string user_data_str = UserDataToString(user_data_);
            std::ostringstream json_msg;
            json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id_ << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
            json_msg << "\"code\":0,\"desc\":\"\",";
            json_msg << "\"json_param\":\"" << EscapeJsonString(friends_json) << "\"}";
            
            SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
        }
        
        void OnError(int error_code, const V2TIMString& error_message) override {
            std::string error_msg = error_message.CString();
            SendApiCallbackResult(user_data_, error_code, error_msg);
        }
    };
    
    // DartGetFriendList: Get friend list
    // Signature: int DartGetFriendList(Pointer<Void> user_data)
    int DartGetFriendList(void* user_data) {
        
        if (!user_data) {
            return 1; // Error
        }
        
        // Capture instance_id at request time so async callback is routed to correct instance
        int64_t instance_id = GetCurrentInstanceId();
        
        // Call V2TIM GetFriendList (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->GetFriendList(
            new DartFriendInfoVectorCallback(user_data, instance_id)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    } // extern "C"

    // Helper: Parse JSON array of strings (reused from message module)
    static std::vector<std::string> ParseJsonStringArray(const std::string& json_str) {
        std::vector<std::string> result;
        std::string array_str = json_str;
        
        // Try to find array in JSON
        size_t array_start = array_str.find('[');
        if (array_start == std::string::npos) {
            // Maybe it's a JSON object with an array field
            std::string array_field = ExtractJsonValue(json_str, "identifier_array", true);
            if (array_field.empty()) {
                array_field = ExtractJsonValue(json_str, "friend_id_list", true);
            }
            if (!array_field.empty() && array_field[0] == '[') {
                array_str = array_field;
                array_start = 0;
            } else {
                return result;
            }
        }
        
        // Simple parser for string array
        size_t i = array_start + 1; // Skip '['
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
    // DartAddFriend: Add friend
    // Signature: int DartAddFriend(Pointer<Char> json_add_friend_param, Pointer<Void> user_data)
    int DartAddFriend(const char* json_add_friend_param, void* user_data) {
        if (!json_add_friend_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }

        std::string json_str = json_add_friend_param;
        V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: json_param (full length={}, first 500 chars)={}",
                  json_str.length(), json_str.substr(0, 500));

        std::string user_id = ExtractJsonValue(json_str, "friendship_add_friend_param_identifier");
        if (user_id.empty()) {
            user_id = ExtractJsonValue(json_str, "add_friend_param_identifier");
        }

        auto parsed = ParseJsonString(json_str);
        V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: Parsed JSON has {} keys", parsed.size());
        for (const auto& pair : parsed) {
            std::string val_preview = (pair.first.find("wording") != std::string::npos || pair.first.find("Wording") != std::string::npos)
                ? pair.second.substr(0, 100) : "";
            V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend:   key='{}', value.length()={}{}",
                      pair.first, pair.second.length(), val_preview.empty() ? "" : ", value='" + val_preview + "'");
        }

        std::string add_wording = ExtractJsonValue(json_str, "friendship_add_friend_param_add_wording");
        V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: After first ExtractJsonValue('friendship_add_friend_param_add_wording'), add_wording.length()={}", add_wording.length());
        if (add_wording.empty()) {
            add_wording = ExtractJsonValue(json_str, "add_friend_param_add_wording");
            V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: After second ExtractJsonValue('add_friend_param_add_wording'), add_wording.length()={}", add_wording.length());
        }
        if (add_wording.empty()) {
            add_wording = ExtractJsonValue(json_str, "addWording");
            V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: After ExtractJsonValue('addWording'), add_wording.length()={}", add_wording.length());
        }
        if (add_wording.empty()) {
            add_wording = ExtractJsonValue(json_str, "add_wording");
            V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: After ExtractJsonValue('add_wording'), add_wording.length()={}", add_wording.length());
        }

        std::string add_source = ExtractJsonValue(json_str, "friendship_add_friend_param_add_source");
        if (add_source.empty()) {
            add_source = ExtractJsonValue(json_str, "add_friend_param_add_source");
        }

        int add_type = ExtractJsonInt(json_str, "friendship_add_friend_param_friend_type", 0);
        if (add_type == 0) {
            add_type = ExtractJsonInt(json_str, "add_friend_param_add_type", 0);
        }

        V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: user_id.length()={}, add_wording.length()={}, add_source.length()={}, add_type={}",
                  user_id.length(), add_wording.length(), add_source.length(), add_type);
        if (add_wording.length() > 0) {
            V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: add_wording (first 50 chars)={}", add_wording.substr(0, 50));
        }
        if (user_id.length() > 0) {
            V2TIM_LOG(kInfo, "[DEBUG] DartAddFriend: user_id (first 20 chars)={}", user_id.substr(0, 20));
        }

        if (user_id.empty()) {
            V2TIM_LOG(kError, "[DEBUG] DartAddFriend: user_id is required (json_str length={})", json_str.length());
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id is required");
            return 1;
        }
        
        // Create V2TIMFriendAddApplication
        V2TIMFriendAddApplication application;
        application.userID = V2TIMString(user_id.c_str());
        application.addWording = V2TIMString(add_wording.c_str());
        application.addSource = V2TIMString(add_source.c_str());
        application.addType = static_cast<V2TIMFriendType>(add_type);
        
        // Get current instance (for multi-instance support)
        // Use SafeGetV2TIMManager() which respects current instance setting
        V2TIMManager* manager = SafeGetV2TIMManager();
        if (!manager) {
            V2TIM_LOG(kError, "[dart_compat] DartAddFriend: V2TIMManager instance is null");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_SDK_NOT_INITIALIZED, "V2TIMManager not initialized");
            return 1; // Error
        }
        
        // Call V2TIM AddFriend (async)
        manager->GetFriendshipManager()->AddFriend(
            application,
            new DartFriendOperationResultCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartDeleteFromFriendList: Delete from friend list
    // Signature: int DartDeleteFromFriendList(Pointer<Char> json_delete_friend_param, Pointer<Void> user_data)
    int DartDeleteFromFriendList(const char* json_delete_friend_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartDeleteFromFriendList");
        fflush(stdout);
        
        if (!json_delete_friend_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON delete friend parameter (keys match tencent SDK V2TimFriendDeleteFriendParam)
        std::string json_str = json_delete_friend_param;
        std::string user_id_list_str = ExtractJsonValue(json_str, "friendship_delete_friend_param_identifier_array");
        if (user_id_list_str.empty()) {
            user_id_list_str = ExtractJsonValue(json_str, "delete_friend_param_identifier_array");  // fallback
        }
        int delete_type = ExtractJsonInt(json_str, "friendship_delete_friend_param_friend_type", 0);
        if (delete_type == 0) {
            delete_type = ExtractJsonInt(json_str, "delete_friend_param_delete_type", 0);
        }
        
        // Parse user ID list (JSON array)
        std::vector<std::string> user_ids = ParseJsonStringArray(user_id_list_str);
        
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartDeleteFromFriendList: user_id list is empty");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Call V2TIM DeleteFromFriendList (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->DeleteFromFriendList(
            user_id_vector,
            static_cast<V2TIMFriendType>(delete_type),
            new DartFriendOperationResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetFriendsInfo: Get friends info
    // Signature: int DartGetFriendsInfo(Pointer<Char> friend_id_list, Pointer<Void> user_data)
    int DartGetFriendsInfo(const char* friend_id_list, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartGetFriendsInfo");
        fflush(stdout);
        
        if (!friend_id_list || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse friend ID list (JSON array)
        std::string json_str = friend_id_list;
        std::vector<std::string> friend_ids = ParseJsonStringArray(json_str);
        
        if (friend_ids.empty()) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "friend_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector friend_id_vector;
        for (const auto& friend_id : friend_ids) {
            friend_id_vector.PushBack(V2TIMString(friend_id.c_str()));
        }
        
        // Call V2TIM GetFriendsInfo (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->GetFriendsInfo(
            friend_id_vector,
            new DartFriendInfoResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSetFriendInfo: Set friend info
    // Signature: int DartSetFriendInfo(Pointer<Char> json_modify_friend_info_param, Pointer<Void> user_data)
    int DartSetFriendInfo(const char* json_modify_friend_info_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSetFriendInfo");
        fflush(stdout);
        
        if (!json_modify_friend_info_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON modify friend info parameter
        std::string json_str = json_modify_friend_info_param;
        std::string user_id = ExtractJsonValue(json_str, "modify_friend_info_param_identifier");
        std::string friend_remark = ExtractJsonValue(json_str, "modify_friend_info_param_friend_remark");
        
        if (user_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartSetFriendInfo: user_id is required");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id is required");
            return 1; // Error
        }
        
        // Create V2TIMFriendInfo
        V2TIMFriendInfo friend_info;
        friend_info.userID = V2TIMString(user_id.c_str());
        friend_info.friendRemark = V2TIMString(friend_remark.c_str());
        
        // Call V2TIM SetFriendInfo (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->SetFriendInfo(
            friend_info,
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
    
    // DartGetFriendApplicationList: Get friend application list
    // Signature: int DartGetFriendApplicationList(Pointer<Char> json_get_pendency_list_param, Pointer<Void> user_data)
    // Note: json_get_pendency_list_param is not used in tim2tox implementation, but required by Dart binding
    int DartGetFriendApplicationList(const char* json_get_pendency_list_param, void* user_data) {
        if (!user_data) {
            V2TIM_LOG(kError, "[dart_compat] DartGetFriendApplicationList: ERROR - user_data is null");
            fflush(stderr);
            return 1; // Error
        }
        
        // Helper class for V2TIMValueCallback<V2TIMFriendApplicationResult>
        class DartFriendApplicationResultCallback : public V2TIMValueCallback<V2TIMFriendApplicationResult> {
        private:
            void* user_data_;
            
        public:
            DartFriendApplicationResultCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMFriendApplicationResult& result) override {
                // Convert to JSON
                std::ostringstream json;
                json << "{";
                json << "\"unreadCount\":" << result.unreadCount << ",";
                json << "\"applicationList\":[";
                for (size_t i = 0; i < result.applicationList.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMFriendApplication& app = result.applicationList[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    std::string user_id = app.userID.CString();
                    std::string add_wording = app.addWording.CString();
                    json << "\"userID\":\"" << EscapeJsonString(user_id) << "\",";
                    json << "\"type\":" << static_cast<int>(app.type) << ",";
                    json << "\"addWording\":\"" << EscapeJsonString(add_wording) << "\"";
                    // TODO: Add more application fields
                    json << "}";
                }
                json << "]";
                json << "}";
                
                std::map<std::string, std::string> result_fields;
                result_fields["friendApplicationResult"] = json.str();
                std::string data_json = BuildJsonObject(result_fields);
                SendApiCallbackResult(user_data_, 0, "", data_json);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetFriendApplicationList (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->GetFriendApplicationList(
            new DartFriendApplicationResultCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartAcceptFriendApplication: Accept friend application
    // Signature: int DartAcceptFriendApplication(Pointer<Char> json_accept_friend_param, Pointer<Void> user_data)
    int DartAcceptFriendApplication(const char* json_accept_friend_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartAcceptFriendApplication");
        fflush(stdout);
        
        if (!json_accept_friend_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON accept friend parameter
        std::string json_str = json_accept_friend_param;
        std::string user_id = ExtractJsonValue(json_str, "accept_friend_param_identifier");
        int response_type = ExtractJsonInt(json_str, "accept_friend_param_response_type", 0);
        std::string remark = ExtractJsonValue(json_str, "accept_friend_param_remark");
        
        if (user_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartAcceptFriendApplication: user_id is required");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id is required");
            return 1; // Error
        }
        
        // Create V2TIMFriendApplication
        V2TIMFriendApplication application;
        application.userID = V2TIMString(user_id.c_str());
        
        // Parse accept type (0 = single, 1 = both)
        V2TIMFriendAcceptType accept_type = static_cast<V2TIMFriendAcceptType>(response_type);
        V2TIMString remark_str(remark.c_str());
        
        // Call V2TIM AcceptFriendApplication (async)
        if (!remark.empty()) {
            SafeGetV2TIMManager()->GetFriendshipManager()->AcceptFriendApplication(
                application,
                accept_type,
                remark_str,
                new DartFriendOperationResultCallback(user_data)
            );
        } else {
            SafeGetV2TIMManager()->GetFriendshipManager()->AcceptFriendApplication(
                application,
                accept_type,
                new DartFriendOperationResultCallback(user_data)
            );
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartHandleFriendAddRequest: Alias for DartAcceptFriendApplication
    // This is the function name expected by the Dart SDK bindings
    // Signature: int DartHandleFriendAddRequest(Pointer<Char> json_handle_friend_add_param, Pointer<Void> user_data)
    int DartHandleFriendAddRequest(const char* json_handle_friend_add_param, void* user_data) {
        // The Dart SDK sends "handle_friend_add_param_identifier" and "handle_friend_add_param_response_type"
        // but DartAcceptFriendApplication expects "accept_friend_param_identifier" and "accept_friend_param_response_type"
        // So we need to parse and convert the parameter names
        V2TIM_LOG(kInfo, "[dart_compat] DartHandleFriendAddRequest (alias for DartAcceptFriendApplication)");
        fflush(stdout);
        
        if (!json_handle_friend_add_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON handle friend add parameter
        std::string json_str = json_handle_friend_add_param;
        V2TIM_LOG(kInfo, "[dart_compat] DartHandleFriendAddRequest: json_str='{}'", json_str);
        fflush(stdout);
        
        // Try multiple possible field names (Dart SDK may use different names)
        // The actual format from V2TimFriendApplicationHandleParam.toJson() is:
        // {"friend_response_identifier":"...","friend_response_action":1}
        std::string user_id = ExtractJsonValue(json_str, "friend_response_identifier");
        if (user_id.empty()) {
            user_id = ExtractJsonValue(json_str, "handle_friend_add_param_identifier");
        }
        if (user_id.empty()) {
            user_id = ExtractJsonValue(json_str, "accept_friend_param_identifier");
        }
        if (user_id.empty()) {
            user_id = ExtractJsonValue(json_str, "userID");
        }
        if (user_id.empty()) {
            user_id = ExtractJsonValue(json_str, "user_id");
        }
        
        int response_type = ExtractJsonInt(json_str, "friend_response_action", 0);
        if (response_type == 0) {
            response_type = ExtractJsonInt(json_str, "handle_friend_add_param_response_type", 0);
        }
        if (response_type == 0) {
            response_type = ExtractJsonInt(json_str, "accept_friend_param_response_type", 0);
        }
        if (response_type == 0) {
            response_type = ExtractJsonInt(json_str, "responseType", 0);
        }
        
        std::string remark = ExtractJsonValue(json_str, "handle_friend_add_param_remark");
        if (remark.empty()) {
            remark = ExtractJsonValue(json_str, "accept_friend_param_remark");
        }
        if (remark.empty()) {
            remark = ExtractJsonValue(json_str, "remark");
        }
        
        V2TIM_LOG(kInfo, "[dart_compat] DartHandleFriendAddRequest: parsed user_id='{}', response_type={}, remark='{}'",
                  user_id, response_type, remark);

        if (user_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartHandleFriendAddRequest: user_id is required (json_str='{}')", json_str);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id is required");
            return 1; // Error
        }

        // Create V2TIMFriendApplication
        V2TIMFriendApplication application;
        application.userID = V2TIMString(user_id.c_str());

        // friend_response_action mirrors the Dart SDK's CFriendResponseAction:
        //   0 = agree, 1 = agreeAndAdd, 2 = REJECT.
        // refuseFriendApplication() funnels through THIS same unified handle
        // binding with action=2, so a reject MUST route to RefuseFriendApplication.
        // The previous code cast the action straight to V2TIMFriendAcceptType and
        // unconditionally called AcceptFriendApplication, so DECLINING a friend
        // request silently added the friend (tox_friend_add_norequest) — the
        // request was accepted instead of refused.
        constexpr int kFriendResponseActionReject = 2;
        if (response_type == kFriendResponseActionReject) {
            V2TIM_LOG(kInfo, "[dart_compat] DartHandleFriendAddRequest: response_type=2 (reject) -> RefuseFriendApplication");
            fflush(stdout);
            SafeGetV2TIMManager()->GetFriendshipManager()->RefuseFriendApplication(
                application,
                new DartFriendOperationResultCallback(user_data)
            );
            return 0; // TIM_SUCC (request refused)
        }

        // Parse accept type (0 = single, 1 = both)
        V2TIMFriendAcceptType accept_type = static_cast<V2TIMFriendAcceptType>(response_type);
        V2TIMString remark_str(remark.c_str());
        
        // Call V2TIM AcceptFriendApplication (async)
        if (!remark.empty()) {
            SafeGetV2TIMManager()->GetFriendshipManager()->AcceptFriendApplication(
                application,
                accept_type,
                remark_str,
                new DartFriendOperationResultCallback(user_data)
            );
        } else {
            SafeGetV2TIMManager()->GetFriendshipManager()->AcceptFriendApplication(
                application,
                accept_type,
                new DartFriendOperationResultCallback(user_data)
            );
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartRefuseFriendApplication: Refuse friend application
    // Signature: int DartRefuseFriendApplication(Pointer<Char> json_refuse_friend_param, Pointer<Void> user_data)
    int DartRefuseFriendApplication(const char* json_refuse_friend_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartRefuseFriendApplication");
        fflush(stdout);
        
        if (!json_refuse_friend_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON refuse friend parameter
        std::string json_str = json_refuse_friend_param;
        std::string user_id = ExtractJsonValue(json_str, "refuse_friend_param_identifier");
        std::string remark = ExtractJsonValue(json_str, "refuse_friend_param_remark");
        
        if (user_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartRefuseFriendApplication: user_id is required");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id is required");
            return 1; // Error
        }
        
        // Create V2TIMFriendApplication
        V2TIMFriendApplication application;
        application.userID = V2TIMString(user_id.c_str());
        
        // Call V2TIM RefuseFriendApplication (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->RefuseFriendApplication(
            application,
            new DartFriendOperationResultCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartCheckFriend: Check friend
    // Signature: int DartCheckFriend(Pointer<Char> json_check_friend_list_param, Pointer<Void> user_data)
    int DartCheckFriend(const char* json_check_friend_list_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartCheckFriend");
        fflush(stdout);
        
        if (!json_check_friend_list_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse user ID list (JSON array)
        std::string json_str = json_check_friend_list_param;
        std::vector<std::string> user_ids = ParseJsonStringArray(json_str);
        
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartCheckFriend: user_id list is empty");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Helper class for V2TIMValueCallback<V2TIMFriendCheckResultVector>
        class DartFriendCheckResultVectorCallback : public V2TIMValueCallback<V2TIMFriendCheckResultVector> {
        private:
            void* user_data_;
            
        public:
            DartFriendCheckResultVectorCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMFriendCheckResultVector& results) override {
                // Convert to JSON
                std::ostringstream json;
                json << "[";
                for (size_t i = 0; i < results.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMFriendCheckResult& result = results[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    std::string user_id = result.userID.CString();
                    json << "\"userID\":\"" << EscapeJsonString(user_id) << "\",";
                    json << "\"resultCode\":" << result.resultCode << ",";
                    json << "\"relationType\":" << static_cast<int>(result.relationType);
                    json << "}";
                }
                json << "]";
                
                std::map<std::string, std::string> result_fields;
                result_fields["friendCheckResultList"] = json.str();
                std::string data_json = BuildJsonObject(result_fields);
                SendApiCallbackResult(user_data_, 0, "", data_json);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM CheckFriend (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->CheckFriend(
            user_id_vector,
            V2TIMFriendType::V2TIM_FRIEND_TYPE_BOTH,
            new DartFriendCheckResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartAddToBlackList: Add to black list
    // Signature: int DartAddToBlackList(Pointer<Char> json_user_id_list, Pointer<Void> user_data)
    int DartAddToBlackList(const char* json_user_id_list, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartAddToBlackList");
        fflush(stdout);
        
        if (!json_user_id_list || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse user ID list (JSON array)
        std::string json_str = json_user_id_list;
        std::vector<std::string> user_ids = ParseJsonStringArray(json_str);
        
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartAddToBlackList: user_id list is empty");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Call V2TIM AddToBlackList (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->AddToBlackList(
            user_id_vector,
            new DartFriendOperationResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartDeleteFromBlackList: Delete from black list
    // Signature: int DartDeleteFromBlackList(Pointer<Char> json_user_id_list, Pointer<Void> user_data)
    int DartDeleteFromBlackList(const char* json_user_id_list, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartDeleteFromBlackList");
        fflush(stdout);
        
        if (!json_user_id_list || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse user ID list (JSON array)
        std::string json_str = json_user_id_list;
        std::vector<std::string> user_ids = ParseJsonStringArray(json_str);
        
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartDeleteFromBlackList: user_id list is empty");
            fflush(stderr);
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Call V2TIM DeleteFromBlackList (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->DeleteFromBlackList(
            user_id_vector,
            new DartFriendOperationResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetBlackList: Get black list
    // Signature: int DartGetBlackList(Pointer<Void> user_data)
    int DartGetBlackList(void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartGetBlackList");
        fflush(stdout);
        
        if (!user_data) {
            return 1; // Error
        }
        
        int64_t instance_id = GetCurrentInstanceId();
        SafeGetV2TIMManager()->GetFriendshipManager()->GetBlackList(
            new DartFriendInfoVectorCallback(user_data, instance_id)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSearchFriends: Search friends
    // Signature: int DartSearchFriends(Pointer<Char> json_search_friends_param, Pointer<Void> user_data)
    int DartSearchFriends(const char* json_search_friends_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSearchFriends");
        fflush(stdout);
        
        if (!json_search_friends_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON search parameter
        std::string json_str = json_search_friends_param;
        V2TIMFriendSearchParam searchParam;
        
        // Parse keyword list
        std::string keyword_list_str = ExtractJsonValue(json_str, "friend_search_param_keyword_list");
        if (!keyword_list_str.empty()) {
            std::vector<std::string> keywords = ParseJsonStringArray(keyword_list_str);
            for (const auto& keyword : keywords) {
                searchParam.keywordList.PushBack(V2TIMString(keyword.c_str()));
            }
        }
        
        // Parse search flags (default to true if not specified)
        searchParam.isSearchUserID = ExtractJsonBool(json_str, "friend_search_param_is_search_user_id", true);
        searchParam.isSearchNickName = ExtractJsonBool(json_str, "friend_search_param_is_search_nick_name", true);
        searchParam.isSearchRemark = ExtractJsonBool(json_str, "friend_search_param_is_search_remark", true);
        
        // Call V2TIM SearchFriends (async)
        SafeGetV2TIMManager()->GetFriendshipManager()->SearchFriends(
            searchParam,
            new DartFriendInfoResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
} // extern "C"

