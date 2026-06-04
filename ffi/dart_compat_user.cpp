// User Functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"

// Forward declaration for multi-instance support
extern int64_t GetCurrentInstanceId();

extern "C" {
    // ============================================================================
    // User Functions
    // ============================================================================
    
} // extern "C"

    // Helper: Parse JSON array of strings (reused from message module)
    static std::vector<std::string> ParseJsonStringArray(const std::string& json_str) {
        std::vector<std::string> result;
        std::string array_str = json_str;
        
        size_t array_start = array_str.find('[');
        if (array_start == std::string::npos) {
            std::string array_field = ExtractJsonValue(json_str, "user_id_list", true);
            if (array_field.empty()) {
                array_field = ExtractJsonValue(json_str, "identifier_array", true);
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
    
    // Helper: Convert V2TIMFriendAllowType to add_permission integer
    static int AllowTypeToAddPermission(V2TIMFriendAllowType allowType) {
        return static_cast<int>(allowType);
    }
    
    // Helper: Convert V2TIMUserFullInfoVector to JSON array
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
                
                const char* user_id_cstr = user_id_str.c_str();
                const char* nick_name_cstr = nick_name_str.c_str();
                const char* face_url_cstr = face_url_str.c_str();
                const char* self_signature_cstr = self_signature_str.c_str();
                
                json << "{";
                json << "\"user_profile_identifier\":\"" << EscapeJsonString(user_id_cstr) << "\",";
                json << "\"user_profile_nick_name\":\"" << EscapeJsonString(nick_name_cstr) << "\",";
                json << "\"user_profile_face_url\":\"" << EscapeJsonString(face_url_cstr) << "\",";
                json << "\"user_profile_self_signature\":\"" << EscapeJsonString(self_signature_cstr) << "\",";
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
    
    // Helper class for V2TIMValueCallback<V2TIMUserFullInfoVector>
    class DartUserFullInfoVectorCallback : public V2TIMValueCallback<V2TIMUserFullInfoVector> {
    private:
        void* user_data_;
        
    public:
        DartUserFullInfoVectorCallback(void* user_data) : user_data_(user_data) {}
        
        void OnSuccess(const V2TIMUserFullInfoVector& users) override {
            std::string users_json = UserFullInfoVectorToJson(users);
            
            // V2TimValueCallback expects json_param field at top level as a JSON string
            // Build the complete callback JSON with json_param as an escaped string
            std::string user_data_str = UserDataToString(user_data_);
            int64_t instance_id = GetCurrentInstanceId();
            std::ostringstream json_msg;
            json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
            json_msg << "\"code\":0,\"desc\":\"\",";
            json_msg << "\"json_param\":\"" << EscapeJsonString(users_json) << "\"}";
            
            SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
        }
        
        void OnError(int error_code, const V2TIMString& error_message) override {
            std::string error_msg = error_message.CString();
            SendApiCallbackResult(user_data_, error_code, error_msg);
        }
    };
    
    extern "C" {
    // DartGetUsersInfo: Get users info
    // Signature: int DartGetUsersInfo(Pointer<Char> json_get_user_profile_list_param, Pointer<Void> user_data)
    int DartGetUsersInfo(const char* json_get_user_profile_list_param, void* user_data) {
        
        if (!json_get_user_profile_list_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse user ID list (JSON array)
        std::string json_str = json_get_user_profile_list_param;
        std::vector<std::string> user_ids = ParseJsonStringArray(json_str);
        
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartGetUsersInfo: user_id list is empty");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Call V2TIM GetUsersInfo (async)
        SafeGetV2TIMManager()->GetUsersInfo(
            user_id_vector,
            new DartUserFullInfoVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSetSelfInfo: Set self info
    // Signature: int DartSetSelfInfo(Pointer<Char> json_modify_self_user_profile_param, Pointer<Void> user_data)
    int DartSetSelfInfo(const char* json_modify_self_user_profile_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSetSelfInfo");
        
        if (!json_modify_self_user_profile_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON modify self user profile parameter
        // Dart toSetUserInfoParam() sends user_profile_item_* keys; accept both item_ and non-item_ keys
        std::string json_str = json_modify_self_user_profile_param;
        
        // Create V2TIMUserFullInfo
        V2TIMUserFullInfo user_info;
        std::string nick_name = ExtractJsonValue(json_str, "user_profile_item_nick_name");
        if (nick_name.empty()) nick_name = ExtractJsonValue(json_str, "user_profile_nick_name");
        std::string face_url = ExtractJsonValue(json_str, "user_profile_item_face_url");
        if (face_url.empty()) face_url = ExtractJsonValue(json_str, "user_profile_face_url");
        std::string self_signature = ExtractJsonValue(json_str, "user_profile_item_self_signature");
        if (self_signature.empty()) self_signature = ExtractJsonValue(json_str, "user_profile_self_signature");
        int gender = ExtractJsonInt(json_str, "user_profile_item_gender", ExtractJsonInt(json_str, "user_profile_gender", 0));
        int birthday = ExtractJsonInt(json_str, "user_profile_item_birthday", ExtractJsonInt(json_str, "user_profile_birthday", 0));
        int allow_type = ExtractJsonInt(json_str, "user_profile_item_add_permission", ExtractJsonInt(json_str, "user_profile_allow_type", 0));
        
        if (!nick_name.empty()) {
            user_info.nickName = V2TIMString(nick_name.c_str());
        }
        if (!face_url.empty()) {
            user_info.faceURL = V2TIMString(face_url.c_str());
        }
        if (!self_signature.empty()) {
            user_info.selfSignature = V2TIMString(self_signature.c_str());
        }
        user_info.gender = static_cast<V2TIMGender>(gender);
        user_info.birthday = birthday;
        user_info.allowType = static_cast<V2TIMFriendAllowType>(allow_type);
        
        // Call V2TIM SetSelfInfo (async)
        SafeGetV2TIMManager()->SetSelfInfo(
            user_info,
            new DartCallback(
                user_data,
                [user_data]() {
                    // OnSuccess
                    SendApiCallbackResult(user_data, 0, "");
                },
                [user_data](int error_code, const V2TIMString& error_message) {
                    // OnError
                    // Get CString() (has built-in protection)
                    const char* error_msg_cstr = nullptr;
                    try {
                        error_msg_cstr = error_message.CString();
                    } catch (...) {
                        error_msg_cstr = nullptr;
                    }
                    std::string error_msg = error_msg_cstr ? std::string(error_msg_cstr) : "";
                    SendApiCallbackResult(user_data, error_code, error_msg);
                }
            )
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSubscribeUserInfo: Subscribe user info
    // Signature: int DartSubscribeUserInfo(Pointer<Char> json_user_id_list, Pointer<Void> user_data)
    int DartSubscribeUserInfo(const char* json_user_id_list, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSubscribeUserInfo");
        
        if (!json_user_id_list || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse user ID list (JSON array)
        std::string json_str = json_user_id_list;
        std::vector<std::string> user_ids = ParseJsonStringArray(json_str);
        
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartSubscribeUserInfo: user_id list is empty");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Call V2TIM SubscribeUserInfo (async)
        SafeGetV2TIMManager()->SubscribeUserInfo(
            user_id_vector,
            new DartCallback(
                user_data,
                [user_data]() {
                    // OnSuccess
                    SendApiCallbackResult(user_data, 0, "");
                },
                [user_data](int error_code, const V2TIMString& error_message) {
                    // OnError
                    // Get CString() (has built-in protection)
                    const char* error_msg_cstr = nullptr;
                    try {
                        error_msg_cstr = error_message.CString();
                    } catch (...) {
                        error_msg_cstr = nullptr;
                    }
                    std::string error_msg = error_msg_cstr ? std::string(error_msg_cstr) : "";
                    SendApiCallbackResult(user_data, error_code, error_msg);
                }
            )
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartUnsubscribeUserInfo: Unsubscribe user info
    // Signature: int DartUnsubscribeUserInfo(Pointer<Char> json_user_id_list, Pointer<Void> user_data)
    int DartUnsubscribeUserInfo(const char* json_user_id_list, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartUnsubscribeUserInfo");
        
        if (!json_user_id_list || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse user ID list (JSON array)
        std::string json_str = json_user_id_list;
        std::vector<std::string> user_ids = ParseJsonStringArray(json_str);
        
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartUnsubscribeUserInfo: user_id list is empty");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Call V2TIM UnsubscribeUserInfo (async)
        SafeGetV2TIMManager()->UnsubscribeUserInfo(
            user_id_vector,
            new DartCallback(
                user_data,
                [user_data]() {
                    // OnSuccess
                    SendApiCallbackResult(user_data, 0, "");
                },
                [user_data](int error_code, const V2TIMString& error_message) {
                    // OnError
                    // Get CString() (has built-in protection)
                    const char* error_msg_cstr = nullptr;
                    try {
                        error_msg_cstr = error_message.CString();
                    } catch (...) {
                        error_msg_cstr = nullptr;
                    }
                    std::string error_msg = error_msg_cstr ? std::string(error_msg_cstr) : "";
                    SendApiCallbackResult(user_data, error_code, error_msg);
                }
            )
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetUserStatus: Get user status
    // Signature: int DartGetUserStatus(Pointer<Char> json_user_id_list, Pointer<Void> user_data)
    int DartGetUserStatus(const char* json_user_id_list, void* user_data) {
        
        if (!json_user_id_list || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse user ID list (JSON array)
        std::string json_str = json_user_id_list;
        std::vector<std::string> user_ids = ParseJsonStringArray(json_str);
        
        if (user_ids.empty()) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Helper class for V2TIMValueCallback<V2TIMUserStatusVector>
        class DartUserStatusVectorCallback : public V2TIMValueCallback<V2TIMUserStatusVector> {
        private:
            void* user_data_;
            
        public:
            DartUserStatusVectorCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMUserStatusVector& status_vector) override {
                // Convert to JSON
                std::ostringstream json;
                json << "[";
                for (size_t i = 0; i < status_vector.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMUserStatus& status = status_vector[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    std::string user_id = status.userID.CString();
                    json << "\"userID\":\"" << EscapeJsonString(user_id) << "\",";
                    json << "\"statusType\":" << static_cast<int>(status.statusType);
                    json << "}";
                }
                json << "]";
                std::string status_json = json.str();
                
                // V2TimValueCallback expects json_param field at top level as a JSON string
                // Build the complete callback JSON with json_param as an escaped string
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(status_json) << "\"}";
                
                SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetUserStatus (async)
        SafeGetV2TIMManager()->GetUserStatus(
            user_id_vector,
            new DartUserStatusVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSetSelfStatus: Set self status
    // Signature: int DartSetSelfStatus(Pointer<Char> json_user_status, Pointer<Void> user_data)
    int DartSetSelfStatus(const char* json_user_status, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSetSelfStatus");
        
        if (!json_user_status || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON user status parameter
        std::string json_str = json_user_status;
        int status_type = ExtractJsonInt(json_str, "user_status_status_type", 0);
        std::string custom_status = ExtractJsonValue(json_str, "user_status_custom_status");
        
        // Create V2TIMUserStatus
        V2TIMUserStatus status;
        status.statusType = static_cast<V2TIMUserStatusType>(status_type);
        if (!custom_status.empty()) {
            status.customStatus = V2TIMString(custom_status.c_str());
        }
        
        // Call V2TIM SetSelfStatus (async)
        SafeGetV2TIMManager()->SetSelfStatus(
            status,
            new DartCallback(
                user_data,
                [user_data]() {
                    // OnSuccess
                    SendApiCallbackResult(user_data, 0, "");
                },
                [user_data](int error_code, const V2TIMString& error_message) {
                    // OnError
                    // Get CString() (has built-in protection)
                    const char* error_msg_cstr = nullptr;
                    try {
                        error_msg_cstr = error_message.CString();
                    } catch (...) {
                        error_msg_cstr = nullptr;
                    }
                    std::string error_msg = error_msg_cstr ? std::string(error_msg_cstr) : "";
                    SendApiCallbackResult(user_data, error_code, error_msg);
                }
            )
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSetC2CReceiveMessageOpt: Set C2C receive message option
    // Signature: int DartSetC2CReceiveMessageOpt(Pointer<Char> json_identifier_array, UnsignedInt opt, Pointer<Void> user_data)
    int DartSetC2CReceiveMessageOpt(const char* json_identifier_array, unsigned int opt, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSetC2CReceiveMessageOpt");

        if (!json_identifier_array || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }

        // ABI: the Dart binding (native_imsdk_bindings_generated.dart) calls this
        // with THREE args — (Pointer<Char> json_identifier_array, UnsignedInt opt,
        // Pointer<Void> user_data). The previous 2-arg signature drifted from that
        // ABI: `opt` (an int) was read in the `user_data` slot and dereferenced as
        // a pointer (SIGSEGV in SendApiCallbackResult -> UserDataToString), and the
        // userID-array JSON was parsed as a nested object so the list was always
        // empty. `json_identifier_array` is a plain string array ["userid1",...];
        // `opt` arrives directly as the second argument.
        std::vector<std::string> user_ids = ParseJsonStringArray(json_identifier_array);
        
        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartSetC2CReceiveMessageOpt: user_id list is empty");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Capture user_data as a STRING now, while the pointer is still valid.
        // The callback may fire after Dart has freed the user_data pointer, and
        // dereferencing the raw pointer then (SendApiCallbackResult ->
        // UserDataToString -> str[0]) is a use-after-free that SIGSEGVs the
        // callback bridge (the volatile-read in UserDataToString cannot catch a
        // SEGV). Mirror the safe pattern used by DartCallback /
        // DartMessageVectorCallback: copy the string up front and pass it via
        // SendApiCallbackResultWithString instead of the raw pointer.
        const std::string user_data_str = UserDataToString(user_data);

        // Call V2TIM SetC2CReceiveMessageOpt (async)
        SafeGetV2TIMManager()->GetMessageManager()->SetC2CReceiveMessageOpt(
            user_id_vector,
            static_cast<V2TIMReceiveMessageOpt>(opt),
            new DartCallback(
                user_data,
                [user_data_str]() {
                    // OnSuccess
                    SendApiCallbackResultWithString(user_data_str, 0, "");
                },
                [user_data_str](int error_code, const V2TIMString& error_message) {
                    // OnError
                    // Get CString() (has built-in protection)
                    const char* error_msg_cstr = nullptr;
                    try {
                        error_msg_cstr = error_message.CString();
                    } catch (...) {
                        error_msg_cstr = nullptr;
                    }
                    std::string error_msg = error_msg_cstr ? std::string(error_msg_cstr) : "";
                    SendApiCallbackResultWithString(user_data_str, error_code, error_msg);
                }
            )
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetC2CReceiveMessageOpt: Get C2C receive message option
    // Signature: int DartGetC2CReceiveMessageOpt(Pointer<Char> json_opt_param, Pointer<Void> user_data)
    int DartGetC2CReceiveMessageOpt(const char* json_opt_param, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartGetC2CReceiveMessageOpt");
        
        if (!json_opt_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // ABI: the Dart binding passes a FLAT JSON string array ["userid1",...] as
        // json_opt_param (the same shape DartSetC2CReceiveMessageOpt receives), NOT
        // a nested {"opt_param_identifier_array":[...]} object. Parse it directly;
        // the previous ExtractJsonValue("opt_param_identifier_array") always returned
        // empty, so this getter never resolved any user and always failed. Keep a
        // fallback to the legacy nested shape for backward compatibility.
        std::string json_str = json_opt_param;
        std::vector<std::string> user_ids = ParseJsonStringArray(json_str);
        if (user_ids.empty()) {
            std::string nested = ExtractJsonValue(json_str, "opt_param_identifier_array");
            user_ids = ParseJsonStringArray(nested);
        }

        if (user_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartGetC2CReceiveMessageOpt: user_id list is empty");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "user_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector user_id_vector;
        for (const auto& user_id : user_ids) {
            user_id_vector.PushBack(V2TIMString(user_id.c_str()));
        }
        
        // Helper class for V2TIMValueCallback<V2TIMReceiveMessageOptInfoVector>
        class DartReceiveMessageOptInfoVectorCallback : public V2TIMValueCallback<V2TIMReceiveMessageOptInfoVector> {
        private:
            void* user_data_;
            
        public:
            DartReceiveMessageOptInfoVectorCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMReceiveMessageOptInfoVector& opt_info_vector) override {
                // Convert to JSON
                std::ostringstream json;
                json << "[";
                for (size_t i = 0; i < opt_info_vector.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMReceiveMessageOptInfo& opt_info = opt_info_vector[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    std::string user_id = opt_info.userID.CString();
                    json << "\"userID\":\"" << EscapeJsonString(user_id) << "\",";
                    json << "\"c2CReceiveMessageOpt\":" << static_cast<int>(opt_info.receiveOpt);
                    json << "}";
                }
                json << "]";
                std::string opt_json = json.str();
                
                // V2TimValueCallback expects json_param field at top level as a JSON string
                // Build the complete callback JSON with json_param as an escaped string
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(opt_json) << "\"}";
                
                SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetC2CReceiveMessageOpt (async)
        SafeGetV2TIMManager()->GetMessageManager()->GetC2CReceiveMessageOpt(
            user_id_vector,
            new DartReceiveMessageOptInfoVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSetAllReceiveMessageOpt: Set all receive message option
    // Signature: int DartSetAllReceiveMessageOpt(unsigned int opt, int start_hour, int start_minute, int start_second, unsigned int duration, Pointer<Void> user_data)
    // ABI note: the Dart binding declares the do-not-disturb time window as
    // (UnsignedInt opt, Int32 startHour, Int32 startMinute, Int32 startSecond, Uint32 duration, user_data).
    // duration is Uint32 in the binding (and uint32 in V2TIM) — keep it unsigned here so the
    // declared ABI matches. The previous 2-arg signature drifted from the ABI (the 4 time ints
    // were ignored / read as garbage). Pass the time-window args through to the matching V2TIM overload
    //   SetAllReceiveMessageOpt(opt, int32 startHour, int32 startMinute, int32 startSecond, uint32 duration, callback).
    int DartSetAllReceiveMessageOpt(unsigned int opt, int start_hour, int start_minute, int start_second, unsigned int duration, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSetAllReceiveMessageOpt: opt={}, start_hour={}, start_minute={}, start_second={}, duration={}",
                  opt, start_hour, start_minute, start_second, duration);

        if (!user_data) {
            return 1; // Error
        }

        // Capture user_data as a STRING now, while the pointer is still valid, to avoid a
        // use-after-free if the async callback fires after Dart has freed the pointer.
        const std::string user_data_str = UserDataToString(user_data);

        // Call V2TIM SetAllReceiveMessageOpt (async) with the do-not-disturb time window.
        SafeGetV2TIMManager()->GetMessageManager()->SetAllReceiveMessageOpt(
            static_cast<V2TIMReceiveMessageOpt>(opt),
            static_cast<int32_t>(start_hour),
            static_cast<int32_t>(start_minute),
            static_cast<int32_t>(start_second),
            static_cast<uint32_t>(duration),
            new DartCallback(
                user_data,
                [user_data_str]() {
                    // OnSuccess
                    SendApiCallbackResultWithString(user_data_str, 0, "");
                },
                [user_data_str](int error_code, const V2TIMString& error_message) {
                    // OnError
                    // Get CString() (has built-in protection)
                    const char* error_msg_cstr = nullptr;
                    try {
                        error_msg_cstr = error_message.CString();
                    } catch (...) {
                        error_msg_cstr = nullptr;
                    }
                    std::string error_msg = error_msg_cstr ? std::string(error_msg_cstr) : "";
                    SendApiCallbackResultWithString(user_data_str, error_code, error_msg);
                }
            )
        );

        return 0; // TIM_SUCC (request accepted)
    }

    // DartSetAllReceiveMessageOpt2: set all-receive-message DND by absolute window.
    // Signature: int DartSetAllReceiveMessageOpt2(unsigned int opt, uint32_t start_time_stamp, uint32_t duration, Pointer<Void> user_data)
    // ABI: the Dart binding (native_imsdk_bindings_generated.dart) declares this symbol
    // (UnsignedInt, Uint32, Uint32, Pointer<Void>) and the SDK resolves it via dlsym; it
    // was previously NOT exported by the native layer, so a lookup/call would fail (a
    // latent crash in the same class as the other ABI drifts). Forward to the matching
    // V2TIM overload SetAllReceiveMessageOpt(opt, uint32 startTimeStamp, uint32 duration, cb).
    int DartSetAllReceiveMessageOpt2(unsigned int opt, uint32_t start_time_stamp, uint32_t duration, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSetAllReceiveMessageOpt2: opt={}, start_time_stamp={}, duration={}",
                  opt, start_time_stamp, duration);

        if (!user_data) {
            return 1; // Error
        }

        // Capture user_data as a STRING now (avoid use-after-free if the async
        // callback fires after Dart frees the pointer) — same pattern as the siblings.
        const std::string user_data_str = UserDataToString(user_data);

        SafeGetV2TIMManager()->GetMessageManager()->SetAllReceiveMessageOpt(
            static_cast<V2TIMReceiveMessageOpt>(opt),
            static_cast<uint32_t>(start_time_stamp),
            static_cast<uint32_t>(duration),
            new DartCallback(
                user_data,
                [user_data_str]() {
                    SendApiCallbackResultWithString(user_data_str, 0, "");
                },
                [user_data_str](int error_code, const V2TIMString& error_message) {
                    const char* error_msg_cstr = nullptr;
                    try {
                        error_msg_cstr = error_message.CString();
                    } catch (...) {
                        error_msg_cstr = nullptr;
                    }
                    std::string error_msg = error_msg_cstr ? std::string(error_msg_cstr) : "";
                    SendApiCallbackResultWithString(user_data_str, error_code, error_msg);
                }
            )
        );

        return 0; // TIM_SUCC (request accepted)
    }

    // DartGetAllReceiveMessageOpt: Get all receive message option
    // Signature: int DartGetAllReceiveMessageOpt(Pointer<Void> user_data)
    int DartGetAllReceiveMessageOpt(void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartGetAllReceiveMessageOpt");
        
        if (!user_data) {
            return 1; // Error
        }
        
        // Helper class for V2TIMValueCallback<V2TIMReceiveMessageOptInfo>
        class DartReceiveMessageOptInfoCallback : public V2TIMValueCallback<V2TIMReceiveMessageOptInfo> {
        private:
            void* user_data_;
            
        public:
            DartReceiveMessageOptInfoCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMReceiveMessageOptInfo& opt_info) override {
                std::map<std::string, std::string> result_fields;
                result_fields["opt"] = std::to_string(static_cast<int>(opt_info.receiveOpt));
                std::string data_json = BuildJsonObject(result_fields);
                SendApiCallbackResult(user_data_, 0, "", data_json);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetAllReceiveMessageOpt (async)
        SafeGetV2TIMManager()->GetMessageManager()->GetAllReceiveMessageOpt(
            new DartReceiveMessageOptInfoCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetLoginStatus: Get login status
    // Signature: int DartGetLoginStatus()
    int DartGetLoginStatus() {
        // Use SafeGetV2TIMManager() for multi-instance support
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            return 0; // Not initialized
        }
        
        V2TIMString login_user = manager->GetLoginUser();
        bool is_empty = login_user.Empty();
        int result = is_empty ? 0 : 1;
        
        return result; // 0 = not logged in, 1 = logged in
    }
    
} // extern "C"

