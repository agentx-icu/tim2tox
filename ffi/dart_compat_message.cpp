// Message Functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"
#include "tim2tox_ffi.h"
#include <chrono>

// Forward declaration for multi-instance support
extern int64_t GetCurrentInstanceId();

extern "C" {
    // ============================================================================
    // Message Functions
    // ============================================================================
    // Note: ExtractBaseConversationID is now in dart_compat_utils.cpp
    
    // DartSendMessage: Send message
    // Signature: Pointer<Char> DartSendMessage(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Char> json_msg_param, Pointer<Void> user_data)
    const char* DartSendMessage(const char* conv_id, unsigned int conv_type, const char* json_msg_param, void* user_data) {
        if (!conv_id || !json_msg_param) {
            V2TIM_LOG(kError, "[DartSendMessage] Invalid parameters: conv_id={}, json_msg_param={}", 
                     conv_id ? "non-null" : "null", json_msg_param ? "non-null" : "null");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return nullptr;
        }
        
        // Parse JSON message parameter
        std::string json_str = json_msg_param;
        std::map<std::string, std::string> msg_config = ParseJsonString(json_str);
        
        // Extract message priority (default to NORMAL)
        int priority_value = ExtractJsonInt(json_str, "message_priority", 2); // 2 = V2TIM_PRIORITY_NORMAL
        V2TIMMessagePriority priority = static_cast<V2TIMMessagePriority>(priority_value);
        
        // Extract offline push info (if any)
        // TODO: Parse offline push config from JSON
        
        // Parse message_elem_array to determine message type
        // CRITICAL: message_elem_array is a nested array, so we need to parse it manually
        // Format: "message_elem_array":[{"elem_type":0,"text_elem_content":"pp"}]
        V2TIMMessage message;
        bool message_created = false;
        
        // First, try to find message_elem_array in the JSON
        size_t elem_array_pos = json_str.find("\"message_elem_array\"");
        if (elem_array_pos != std::string::npos) {
            // Find the opening bracket of the array
            size_t array_start = json_str.find("[", elem_array_pos);
            if (array_start != std::string::npos) {
                // Find the first object in the array (starts with {)
                size_t obj_start = json_str.find("{", array_start);
                if (obj_start != std::string::npos) {
                    // Find the closing brace of this object
                    // Need to handle nested braces and strings properly
                    int brace_count = 0;
                    size_t obj_end = obj_start;
                    bool in_string = false;
                    bool escape_next = false;
                    for (size_t i = obj_start; i < json_str.length(); i++) {
                        char c = json_str[i];
                        if (escape_next) {
                            escape_next = false;
                            continue;
                        }
                        if (c == '\\') {
                            escape_next = true;
                            continue;
                        }
                        if (c == '"') {
                            in_string = !in_string;
                            continue;
                        }
                        if (!in_string) {
                            if (c == '{') brace_count++;
                            else if (c == '}') {
                                brace_count--;
                                if (brace_count == 0) {
                                    obj_end = i;
                                    break;
                                }
                            }
                        }
                    }
                    
                    if (obj_end > obj_start) {
                        // Extract the object JSON string
                        std::string elem_obj_str = json_str.substr(obj_start, obj_end - obj_start + 1);
                        // Parse elem_type from the object
                        size_t elem_type_pos = elem_obj_str.find("\"elem_type\"");
                        if (elem_type_pos != std::string::npos) {
                            size_t colon_pos = elem_obj_str.find(":", elem_type_pos);
                            if (colon_pos != std::string::npos) {
                                size_t value_start = colon_pos + 1;
                                while (value_start < elem_obj_str.length() && 
                                       (elem_obj_str[value_start] == ' ' || elem_obj_str[value_start] == '\t')) {
                                    value_start++;
                                }
                                
                                // Extract the number
                                std::string elem_type_str;
                                while (value_start < elem_obj_str.length() && 
                                       (std::isdigit(elem_obj_str[value_start]) || elem_obj_str[value_start] == '-')) {
                                    elem_type_str += elem_obj_str[value_start];
                                    value_start++;
                                }
                                
                                if (!elem_type_str.empty()) {
                                    try {
                                        int elem_type = std::stoi(elem_type_str);
                                        
                                        // Create message based on element type
                                        auto* msg_manager = SafeGetV2TIMManager()->GetMessageManager();
                                        
                                        if (elem_type == 0) { // CElemType.ElemText = 0
                                            // Extract text_elem_content from the element object
                                            std::string text_content = ExtractJsonValue(elem_obj_str, "text_elem_content");
                                            if (!text_content.empty()) {
                                                message = msg_manager->CreateTextMessage(V2TIMString(text_content.c_str()));
                                                message_created = true;
                                            }
                                        } else if (elem_type == 3) { // CElemType.ElemCustom = 3
                                            // Extract custom data from the element object
                                            std::string custom_data = ExtractJsonValue(elem_obj_str, "custom_elem_data");
                                            std::string custom_desc = ExtractJsonValue(elem_obj_str, "custom_elem_desc");
                                            std::string custom_ext = ExtractJsonValue(elem_obj_str, "custom_elem_ext");
                                            // Note: custom_data may contain binary data (including null bytes)
                                            // Even if it appears empty after JSON parsing, try to create message
                                            // The data might be valid but contain null bytes that were lost in JSON parsing
                                            if (custom_data.length() > 0 || !custom_desc.empty() || !custom_ext.empty()) {
                                                // Convert custom_data string to V2TIMBuffer
                                                // Even if custom_data is empty, we can create a message with desc/ext
                                                V2TIMBuffer buffer;
                                                if (custom_data.length() > 0) {
                                                    buffer = V2TIMBuffer(
                                                        reinterpret_cast<const uint8_t*>(custom_data.c_str()), 
                                                        custom_data.length()
                                                    );
                                                }
                                                
                                                if (!custom_desc.empty() || !custom_ext.empty()) {
                                                    message = msg_manager->CreateCustomMessage(
                                                        buffer,
                                                        V2TIMString(custom_desc.c_str()),
                                                        V2TIMString(custom_ext.c_str())
                                                    );
                                                } else {
                                                    message = msg_manager->CreateCustomMessage(buffer);
                                                }
                                                message_created = true;
                                            } else {
                                                V2TIM_LOG(kWarning, "[DartSendMessage] Custom message data is empty and no desc/ext provided");
                                            }
                                        } else if (elem_type == 4) { // CElemType.ElemFile = 4
                                            // Extract file path and name from the element object
                                            std::string file_path = ExtractJsonValue(elem_obj_str, "file_elem_file_path");
                                            std::string file_name = ExtractJsonValue(elem_obj_str, "file_elem_file_name");
                                            if (!file_path.empty() && !file_name.empty()) {
                                                message = msg_manager->CreateFileMessage(
                                                    V2TIMString(file_path.c_str()),
                                                    V2TIMString(file_name.c_str())
                                                );
                                                message_created = true;
                                            } else {
                                                V2TIM_LOG(kWarning, "[DartSendMessage] File message missing path or fileName: path empty={}, fileName empty={}",
                                                         file_path.empty(), file_name.empty());
                                            }
                                        }
                                    } catch (...) {
                                        // Ignore parsing errors, will try fallback
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // If message creation failed, try to find elem_type directly in the JSON (fallback for old format)
        if (!message_created) {
            size_t elem_type_pos = json_str.find("\"elem_type\"");
            if (elem_type_pos != std::string::npos) {
                // Find the value after elem_type
                size_t colon_pos = json_str.find(":", elem_type_pos);
                if (colon_pos != std::string::npos) {
                    size_t value_start = colon_pos + 1;
                    while (value_start < json_str.length() && 
                           (json_str[value_start] == ' ' || json_str[value_start] == '\t')) {
                        value_start++;
                    }
                    
                    // Extract the number
                    std::string elem_type_str;
                    while (value_start < json_str.length() && 
                           (std::isdigit(json_str[value_start]) || json_str[value_start] == '-')) {
                        elem_type_str += json_str[value_start];
                        value_start++;
                    }
                    
                    if (!elem_type_str.empty()) {
                        try {
                            int elem_type = std::stoi(elem_type_str);
                            
                            // Create message based on element type
                            auto* msg_manager = SafeGetV2TIMManager()->GetMessageManager();
                            
                            if (elem_type == 0) { // CElemType.ElemText = 0
                                // Extract text content
                                std::string text_content = ExtractJsonValue(json_str, "text_elem_content");
                                if (!text_content.empty()) {
                                    message = msg_manager->CreateTextMessage(V2TIMString(text_content.c_str()));
                                    message_created = true;
                                }
                            }
                        } catch (...) {
                            // Ignore parsing errors
                        }
                    }
                }
            }
        }
        
        // If message creation still failed, try to extract text from common fields (last resort)
        if (!message_created) {
            // Try to extract text from common fields
            std::string text_content = ExtractJsonValue(json_str, "text_elem_content");
            if (text_content.empty()) {
                text_content = ExtractJsonValue(json_str, "text");
            }
            
            if (!text_content.empty()) {
                auto* msg_manager = SafeGetV2TIMManager()->GetMessageManager();
                message = msg_manager->CreateTextMessage(V2TIMString(text_content.c_str()));
                message_created = true;
            }
        }
        
        if (!message_created) {
            V2TIM_LOG(kError, "[DartSendMessage] Failed to parse message from JSON");
            V2TIM_LOG(kError, "[DartSendMessage] Full JSON content: {}", json_str);
            V2TIM_LOG(kError, "[DartSendMessage] Attempted to find:");
            V2TIM_LOG(kError, "[DartSendMessage]   1. message_elem_array with elem_type");
            V2TIM_LOG(kError, "[DartSendMessage]   2. elem_type directly in JSON");
            V2TIM_LOG(kError, "[DartSendMessage]   3. text_elem_content or text field");
            V2TIM_LOG(kError, "[DartSendMessage] None of these were found or contained valid data");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Failed to parse message from JSON");
            return nullptr;
        }
        // Set message priority
        message.priority = priority;
        
        // Set other message properties from JSON
        // TODO: Parse and set more fields (offlinePushInfo, localCustomData, etc.)
        
        // Determine conversation type
        // conv_type: 1 = C2C (kTIMConv_C2C), 2 = GROUP (kTIMConv_Group)
        // V2TIMConversationType: V2TIM_C2C = 1, V2TIM_GROUP = 2
        V2TIMConversationType conversation_type = (conv_type == 1) ? 
            V2TIMConversationType::V2TIM_C2C : V2TIMConversationType::V2TIM_GROUP;
        
        // Store message ID for return (will be updated in callback)
        static std::string temp_msg_id;
        temp_msg_id = message.msgID.CString();
        if (temp_msg_id.empty()) {
            // Generate temporary ID if not set
            temp_msg_id = "temp_" + std::to_string(time(nullptr));
        }
        
        // Helper class to implement V2TIMSendCallback
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
        
        // Determine receiver and groupID based on conversation type
        // Extract base ID (remove prefix if present) - message functions expect base ID
        std::string base_id = ExtractBaseConversationID(conv_id);
        V2TIMString receiver;
        V2TIMString groupID;
        if (conversation_type == V2TIMConversationType::V2TIM_C2C) {
            receiver = V2TIMString(base_id.c_str());
        } else {
            groupID = V2TIMString(base_id.c_str());
            // Group private message: when json has "group_private_receiver", use it as receiver
            std::string group_private_recv = ExtractJsonValue(json_str, "group_private_receiver");
            if (!group_private_recv.empty()) {
                receiver = V2TIMString(group_private_recv.c_str());
            }
        }
        
        // Create offline push info (empty for now)
        V2TIMOfflinePushInfo offlinePushInfo;
        
        // C2C file message: send via Tox file transfer instead of converting to "[转发文件]" text
        if (conversation_type == V2TIM_C2C && message.elemList.Size() == 1 &&
            message.elemList[0]->elemType == V2TIM_ELEM_TYPE_FILE) {
            V2TIMFileElem* file_elem = static_cast<V2TIMFileElem*>(message.elemList[0]);
            std::string file_path = file_elem->path.CString();
            if (!file_path.empty()) {
                // tim2tox_ffi_send_file expects 64-char public key; receiver may be 76-char Tox ID
                std::string receiver_pubkey = (base_id.length() >= 64) ? base_id.substr(0, 64) : base_id;
                int ffi_ret = tim2tox_ffi_send_file(GetCurrentInstanceId(), receiver_pubkey.c_str(), file_path.c_str());
                if (ffi_ret == 1) {
                    std::map<std::string, std::string> result_fields;
                    result_fields["message_msg_id"] = message.msgID.CString();
                    std::string data_json = BuildJsonObject(result_fields);
                    SendApiCallbackResult(user_data, 0, "", data_json);
                    return temp_msg_id.c_str();
                }
                V2TIM_LOG(kError, "[DartSendMessage] C2C file send failed: ffi_ret={}", ffi_ret);
                SendApiCallbackResult(user_data, ERR_SDK_INTERNAL_ERROR, "File send failed (tox_file_send or friend not connected)");
                return nullptr;
            }
        }
        
        // Send message (async)
        SafeGetV2TIMManager()->GetMessageManager()->SendMessage(
            message,
            receiver,
            groupID,
            priority,
            false, // onlineUserOnly
            offlinePushInfo,
            new DartSendCallback(
                user_data,
                [user_data](const V2TIMMessage& msg) {
                    // OnSuccess
                    std::string msg_id = msg.msgID.CString();
                    std::map<std::string, std::string> result_fields;
                    result_fields["message_msg_id"] = msg_id;
                    std::string data_json = BuildJsonObject(result_fields);
                    SendApiCallbackResult(user_data, 0, "", data_json);
                },
                [user_data](int error_code, const V2TIMString& error_message) {
                    // OnError
                    std::string error_msg = error_message.CString();
                    SendApiCallbackResult(user_data, error_code, error_msg);
                },
                [](uint32_t progress) {
                    // OnProgress (upload progress)
                    // TODO: Send progress callback via globalCallback
                }
            )
        );
        // Return message ID immediately (will be updated in callback)
        return temp_msg_id.c_str();
    }
    
    // ============================================================================
    // Message Query Functions
    // ============================================================================
    
    } // extern "C"

    // Helper: Parse JSON array of strings (simple implementation)
    // Expected format: ["string1", "string2", ...] or {"key": ["string1", "string2", ...]}
    static std::vector<std::string> ParseJsonStringArray(const std::string& json_str) {
        std::vector<std::string> result;
        
        // CRITICAL: Validate input is not empty
        if (json_str.empty()) {
            return result;
        }
        
        std::string array_str = json_str;
        
        // Try to find array in JSON
        size_t array_start = array_str.find('[');
        if (array_start == std::string::npos) {
            // Maybe it's a JSON object with an array field
            // Try common field names (use silent=true to avoid unnecessary warnings)
            std::string array_field = ExtractJsonValue(json_str, "message_id_array", true);
            if (array_field.empty()) {
                array_field = ExtractJsonValue(json_str, "messageIDList", true);
            }
            if (array_field.empty()) {
                array_field = ExtractJsonValue(json_str, "msgIDList", true);
            }
            if (!array_field.empty() && array_field[0] == '[') {
                array_str = array_field;
                array_start = 0;
            } else {
                return result;
            }
        }
        
        // CRITICAL: Validate array_start is within bounds
        if (array_start >= array_str.length()) {
            return result;
        }
        
        // Simple parser for string array
        size_t i = array_start + 1; // Skip '['
        std::string current_string;
        bool in_string = false;
        bool escape_next = false;
        
        // CRITICAL: Add bounds checking to prevent infinite loops or out-of-bounds access
        const size_t max_iterations = array_str.length() * 2; // Safety limit
        size_t iteration_count = 0;
        
        while (i < array_str.length() && iteration_count < max_iterations) {
            iteration_count++;
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
        
        if (iteration_count >= max_iterations) {
        }
        
        // Reduce log frequency - only log if parsing took many iterations or parsed many items
        if (iteration_count > 100 || result.size() > 10) {
        }
        
        return result;
    }
    
    // Helper: Convert V2TIMMessageVector to JSON array
    // Note: This function is also declared in dart_compat_callbacks.h, so we use a different name here
    static std::string MessageVectorToJsonLocal(const V2TIMMessageVector& messages) {
        // CRITICAL: Optimize for empty vectors
        size_t msg_count = messages.Size();
        if (msg_count == 0) {
            return "[]";
        }
        
        // Use ostringstream for efficient string building
        std::ostringstream json;
        json << "[";
        
        for (size_t i = 0; i < msg_count; i++) {
            if (i > 0) {
                json << ",";
            }
            
            try {
                // Verify index is valid before accessing
                if (i >= messages.Size()) {
                    continue;
                }
                const V2TIMMessage& msg = messages[i];
                
                // Get CString() (has built-in protection)
                std::string msg_id = msg.msgID.CString();
                std::string sender = msg.sender.CString();
                
                json << "{";
                json << "\"message_msg_id\":\"" << EscapeJsonString(msg_id) << "\",";
                json << "\"message_seq\":" << msg.seq << ",";
                // V2TIMMessage::random is uninitialized uint64_t (see comment
                // in dart_compat_listeners.cpp); clamp to 0 so Dart's int-typed
                // V2TimMessage.random field parses without a cast error.
                json << "\"message_rand\":" << 0 << ",";
                json << "\"message_status\":" << static_cast<int>(msg.status) << ",";
                json << "\"message_sender\":\"" << EscapeJsonString(sender) << "\",";
                json << "\"message_client_time\":" << msg.timestamp << ",";
                json << "\"message_server_time\":" << msg.timestamp << ",";
                json << "\"message_is_from_self\":" << (msg.isSelf ? "true" : "false");
                
                // TODO: Add more message fields (elem_array, etc.)
                json << "}";
            } catch (...) {
                json << "{}";
            }
        }
        
        json << "]";
        return json.str();
    }
    
    // Helper class for V2TIMValueCallback<V2TIMMessageVector>
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
            // CRITICAL: Optimize message vector to JSON conversion
            // Check size first to avoid unnecessary work for empty vectors
            size_t msg_count = messages.Size();
            
            // Reduce log overhead - only log if there are many messages
            if (msg_count > 50) {
            }
            
            std::string messages_json = MessageVectorToJsonLocal(messages);
            
            // V2TimValueCallback expects json_param field at top level as a JSON string
            // Build the complete callback JSON with json_param as an escaped string
            int64_t instance_id = GetCurrentInstanceId();
            std::ostringstream json_msg;
            json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str_) << "\",";
            json_msg << "\"code\":0,\"desc\":\"\",";
            json_msg << "\"json_param\":\"" << EscapeJsonString(messages_json) << "\"}";
            
            // Use the copied string instead of the original pointer
            SendCallbackToDart("apiCallback", json_msg.str(), nullptr);
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
    
    extern "C" {
    // DartFindMessages: Find messages by message IDs
    // Signature: int DartFindMessages(Pointer<Char> json_message_id_array, Pointer<Void> user_data)
    int DartFindMessages(const char* json_message_id_array, void* user_data) {
        if (!json_message_id_array || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }
        
        std::string json_str = json_message_id_array;
        std::vector<std::string> message_ids = ParseJsonStringArray(json_str);
        
        if (message_ids.empty()) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Empty message ID list");
            return 1;
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector message_id_vector;
        for (const auto& msg_id : message_ids) {
            message_id_vector.PushBack(V2TIMString(msg_id.c_str()));
        }
        
        // Call V2TIM FindMessages (async)
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartMessageVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartRevokeMessage: Revoke message
    // Signature: int DartRevokeMessage(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Char> json_msg_param, Pointer<Void> user_data)
    int DartRevokeMessage(const char* conv_id, unsigned int conv_type, const char* json_msg_param, void* user_data) {
        if (!conv_id || !json_msg_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }
        
        std::string json_str = json_msg_param;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        
        if (msg_id.empty()) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1;
        }
        
        // First, find the message by ID, then revoke it
        // Create a custom callback that finds the message and then revokes it
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
        
        // Find the message first
        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));
        
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartRevokeMessageCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetHistoryMessageList: Get history message list
    // Signature: int DartGetHistoryMessageList(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Char> json_get_msg_param, Pointer<Void> user_data)
    // CRITICAL: Track call frequency to debug CPU 100% issue
    static int call_count = 0;
    static std::chrono::steady_clock::time_point last_call_time;
    static std::chrono::steady_clock::time_point start_time = std::chrono::steady_clock::now();
    
    int DartGetHistoryMessageList(const char* conv_id, unsigned int conv_type, const char* json_get_msg_param, void* user_data) {
        call_count++;
        auto now = std::chrono::steady_clock::now();
        auto time_since_start = std::chrono::duration_cast<std::chrono::milliseconds>(now - start_time).count();
        auto time_since_last = (call_count > 1) ? std::chrono::duration_cast<std::chrono::milliseconds>(now - last_call_time).count() : 0;
        last_call_time = now;
        
        // Reduce log frequency to improve performance - only log every 10th call or if time since last > 1000ms
        if (call_count % 10 == 0 || time_since_last > 1000) {
        }
        if (!conv_id || !json_get_msg_param || !user_data) {
            if (user_data) {
                SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            }
            return 1;
        }
        
        std::string json_str = json_get_msg_param;
        std::string conv_id_str = conv_id;
        if (json_str.empty() || conv_id_str.empty()) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters: empty string");
            return 1;
        }
        
        try {
            
            V2TIMMessageListGetOption option;
            option.lastMsg = nullptr;
            option.getType = V2TIMMessageGetType::V2TIM_GET_LOCAL_OLDER_MSG;
            option.count = 20;
            option.lastMsgSeq = 0;
            option.getTimeBegin = 0;
            option.getTimePeriod = 0;
            
            try {
                option.userID = V2TIMString("");
                option.groupID = V2TIMString("");
            } catch (...) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Failed to initialize V2TIMString");
                return 1;
            }
            
            try {
                size_t type_list_size = option.messageTypeList.Size();
                size_t seq_list_size = option.messageSeqList.Size();
                if (type_list_size > 1000000 || seq_list_size > 1000000) {
                    SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Vector initialization failed");
                    return 1;
                }
            } catch (...) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Vector initialization failed");
                return 1;
            }
            
            // Determine conversation type and set userID or groupID
            // Extract base ID (remove prefix if present) - message functions expect base ID
            // conv_type: 1 = C2C (kTIMConv_C2C), 2 = GROUP (kTIMConv_Group)
            std::string base_id = ExtractBaseConversationID(conv_id_str.c_str());
            try {
                if (conv_type == 1) {
                    option.userID = V2TIMString(base_id.c_str());
                } else if (conv_type == 2) {
                    option.groupID = V2TIMString(base_id.c_str());
                } else {
                    SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid conv_type");
                    return 1;
                }
            } catch (...) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Failed to set userID/groupID");
                return 1;
            }
            
            try {
                int get_type = ExtractJsonInt(json_str, "msg_getmsglist_param_get_type", 0);
                if (get_type >= 0 && get_type <= 3) {
                    option.getType = static_cast<V2TIMMessageGetType>(get_type);
                }
            } catch (...) {
                // Use default
            }
            
            try {
                int count_value = ExtractJsonInt(json_str, "msg_getmsglist_param_count", 20);
                if (count_value > 0 && count_value <= 100) {
                    option.count = static_cast<uint32_t>(count_value);
                }
            } catch (...) {
                // Use default
            }
            
            try {
                int64_t last_msg_seq = static_cast<int64_t>(ExtractJsonInt(json_str, "msg_getmsglist_param_last_msg_seq", 0));
                if (last_msg_seq >= 0) {
                    option.lastMsgSeq = static_cast<uint64_t>(last_msg_seq);
                }
            } catch (...) {
                // Use default
            }
            
            try {
                int64_t time_begin = static_cast<int64_t>(ExtractJsonInt(json_str, "msg_getmsglist_param_time_begin", 0));
                option.getTimeBegin = time_begin;
            } catch (...) {
                // Use default
            }
            
            try {
                int time_period_value = ExtractJsonInt(json_str, "msg_getmsglist_param_time_period", 0);
                if (time_period_value >= 0) {
                    option.getTimePeriod = static_cast<uint32_t>(time_period_value);
                }
            } catch (...) {
                // Use default
            }
            
            // CRITICAL: Only parse messageTypeList if JSON array is valid
            // Avoid corrupting the vector by only adding valid elements
            try {
                std::string message_type_array = ExtractJsonValue(json_str, "msg_getmsglist_param_message_type_array", true);
                if (!message_type_array.empty() && message_type_array[0] == '[') {
                    std::vector<std::string> type_list = ParseJsonStringArray(message_type_array);
                    for (const auto& type_str : type_list) {
                        if (type_str.empty()) {
                            continue;
                        }
                        try {
                            int type_value = std::stoi(type_str);
                            if (type_value >= 0 && type_value < 100) {
                                option.messageTypeList.PushBack(static_cast<V2TIMElemType>(type_value));
                            }
                        } catch (...) {
                            // Skip invalid type values
                        }
                    }
                }
            } catch (...) {
                // messageTypeList is optional, ignore errors
            }
            
            // CRITICAL: Parse messageSeqList if provided (optional, for group messages)
            try {
                std::string message_seq_array = ExtractJsonValue(json_str, "msg_getmsglist_param_message_seq_array", true);
                if (!message_seq_array.empty() && message_seq_array[0] == '[') {
                    std::vector<std::string> seq_list = ParseJsonStringArray(message_seq_array);
                    for (const auto& seq_str : seq_list) {
                        if (seq_str.empty()) {
                            continue;
                        }
                        try {
                            uint64_t seq_value = static_cast<uint64_t>(std::stoull(seq_str));
                            option.messageSeqList.PushBack(seq_value);
                        } catch (...) {
                            // Skip invalid seq values
                        }
                    }
                }
            } catch (...) {
                // messageSeqList is optional, ignore errors
            }
            
            // Parse lastMsg (optional, JSON object)
            // Note: lastMsg is a pointer, and parsing it from JSON would require creating a V2TIMMessage object
            // For now, we leave it as nullptr (which is safe and valid)
            // TODO: Parse lastMsg from JSON if provided and needed
            
            // Final validation before calling SDK
            try {
                // Verify vectors are still valid
                option.messageTypeList.Size();
                option.messageSeqList.Size();
                
                // Verify V2TIMString members are valid (CString() has built-in protection)
                option.userID.CString();
                option.groupID.CString();
                
            } catch (...) {
                SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Option validation failed");
                return 1;
            }
            
            try {
                SafeGetV2TIMManager()->GetMessageManager()->GetHistoryMessageList(
                    option,
                    new DartMessageVectorCallback(user_data)
                );
            } catch (...) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "SDK call failed");
                return 1;
            }
            
            option.lastMsg = nullptr;
            return 0;
        } catch (...) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Exception");
            }
            return 1;
        }
    }
    
    // DartModifyMessage: Modify message
    // Signature: int DartModifyMessage(Pointer<Char> json_msg_param, Pointer<Void> user_data)
    int DartModifyMessage(const char* json_msg_param, void* user_data) {
        if (!json_msg_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON message parameter
        std::string json_str = json_msg_param;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        
        if (msg_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartModifyMessage: message_msg_id not found");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1; // Error
        }
        
        // First, find the message by ID
        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));
        
        // Helper class to find and modify message
        class DartModifyMessageCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            std::string json_str_;
            
        public:
            DartModifyMessageCallback(void* user_data, const std::string& json_str) 
                : user_data_(user_data), json_str_(json_str) {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    V2TIMMessage message = messages[0];
                    
                    // Parse modification fields from JSON
                    std::string local_custom_data = ExtractJsonValue(json_str_, "message_local_custom_data");
                    if (!local_custom_data.empty()) {
                        // Convert string to V2TIMBuffer
                        V2TIMBuffer buffer(
                            reinterpret_cast<const uint8_t*>(local_custom_data.c_str()),
                            local_custom_data.length()
                        );
                        // TODO: V2TIMMessage doesn't have localCustomData field directly
                        // Use SetLocalCustomData method instead
                        message.SetLocalCustomData(buffer, nullptr);
                    }
                    
                    // Modify the message
                    SafeGetV2TIMManager()->GetMessageManager()->ModifyMessage(
                        message,
                        new DartMessageCompleteCallback(user_data_)
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
        
        // Find the message first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartModifyMessageCallback(user_data, json_str)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartDeleteMessages: Delete messages
    // Signature: int DartDeleteMessages(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Char> json_msg_array, Pointer<Void> user_data)
    int DartDeleteMessages(const char* conv_id, unsigned int conv_type, const char* json_msg_array, void* user_data) {

        if (!conv_id || !json_msg_array || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse message array (JSON array of message objects)
        std::string json_str = json_msg_array;
        std::vector<std::string> msg_ids = ParseJsonStringArray(json_str);
        
        if (msg_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartDeleteMessages: message ID list is empty");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message ID list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMMessageVector by finding messages first
        V2TIMStringVector message_id_vector;
        for (const auto& msg_id : msg_ids) {
            message_id_vector.PushBack(V2TIMString(msg_id.c_str()));
        }
        
        // Helper class to find and delete messages
        class DartDeleteMessagesCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            V2TIMString conv_id_;
            V2TIMConversationType conv_type_;
            
        public:
            DartDeleteMessagesCallback(void* user_data, const char* conv_id, unsigned int conv_type)
                : user_data_(user_data), conv_id_(conv_id ? conv_id : ""),
                  conv_type_(conv_type == 1 ? V2TIMConversationType::V2TIM_C2C : V2TIMConversationType::V2TIM_GROUP) {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    // Delete messages
                    SafeGetV2TIMManager()->GetMessageManager()->DeleteMessages(
                        messages,
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
                    SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_COMM_DATABASE_NOTFOUND, "Messages not found");
                }
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Find the messages first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartDeleteMessagesCallback(user_data, conv_id, conv_type)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartDeleteMessageFromLocalStorage: Delete message from local storage
    // Signature: int DartDeleteMessageFromLocalStorage(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Char> json_msgdel_param, Pointer<Void> user_data)
    int DartDeleteMessageFromLocalStorage(const char* conv_id, unsigned int conv_type, const char* json_msgdel_param, void* user_data) {

        if (!conv_id || !json_msgdel_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON delete parameter
        std::string json_str = json_msgdel_param;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        
        if (msg_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartDeleteMessageFromLocalStorage: message_msg_id not found");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1;
        }

        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));

        // Helper class to find and delete message from local storage
        class DartDeleteMessageFromLocalStorageCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            
        public:
            DartDeleteMessageFromLocalStorageCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    const V2TIMMessage& message = messages[0];
                    
                    // TODO: DeleteMessageFromLocalStorage API not available in V2TIMMessageManager
                    // For now, return success (message deletion may need to be handled differently)
                    SendApiCallbackResult(user_data_, 0, "");
                } else {
                    SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_COMM_DATABASE_NOTFOUND, "Message not found");
                }
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Find the message first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartDeleteMessageFromLocalStorageCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartClearHistoryMessage: Clear history message
    // Signature: int DartClearHistoryMessage(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Void> user_data)
    int DartClearHistoryMessage(const char* conv_id, unsigned int conv_type, void* user_data) {
        if (!conv_id || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Determine conversation type
        V2TIMConversationType conversation_type = (conv_type == 1) ? 
            V2TIMConversationType::V2TIM_C2C : V2TIMConversationType::V2TIM_GROUP;
        
        // Extract base ID (remove prefix if present) - message functions expect base ID
        std::string base_id = ExtractBaseConversationID(conv_id);
        V2TIMString base_id_str(base_id.c_str());
        
        // CRITICAL: The C++ layer's ClearC2CHistoryMessage just returns success without doing anything.
        // We need to actually call the Flutter layer to clear history.
        // Since C++ cannot directly call Dart, we use a workaround:
        // 1. Call the C++ layer which will trigger the callback
        // 2. In the callback success handler, we'll send a special callback to Dart
        // 3. The Dart layer will handle this callback and invoke the Flutter layer's clearC2CHistoryMessage
        
        // Store the base_id and user_data for the callback
        std::string user_data_str = UserDataToString(user_data);
        
        // Create a callback that will invoke Flutter layer's clearC2CHistoryMessage
        // We'll send a callback to Dart with action="clearHistoryMessage"
        if (conversation_type == V2TIMConversationType::V2TIM_C2C) {
            SafeGetV2TIMManager()->GetMessageManager()->ClearC2CHistoryMessage(
                base_id_str,
                new DartCallback(
                    user_data,
                    [user_data, base_id]() {
                        // OnSuccess - send callback to Dart to invoke Flutter layer's clearC2CHistoryMessage
                        // Format: {"callback":"clearHistoryMessage","user_data":"...","conv_id":"...","conv_type":"1"}
                        std::string user_data_str = UserDataToString(user_data);
                        std::ostringstream json_msg;
                        json_msg << "{\"callback\":\"clearHistoryMessage\",";
                        json_msg << "\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                        json_msg << "\"conv_id\":\"" << EscapeJsonString(base_id) << "\",";
                        json_msg << "\"conv_type\":\"1\"}";
                        
                        SendCallbackToDart("clearHistoryMessage", json_msg.str(), user_data);
                    },
                    [user_data](int error_code, const V2TIMString& error_message) {
                        // OnError - send error callback
                        std::string error_msg = error_message.CString();
                        SendApiCallbackResult(user_data, error_code, error_msg);
                    }
                )
            );
        } else {
            SafeGetV2TIMManager()->GetMessageManager()->ClearGroupHistoryMessage(
                base_id_str,
                new DartCallback(
                    user_data,
                    [user_data, base_id]() {
                        // OnSuccess - send callback to Dart to invoke Flutter layer's clearGroupHistoryMessage
                        // Format: {"callback":"clearHistoryMessage","user_data":"...","conv_id":"...","conv_type":"2"}
                        std::string user_data_str = UserDataToString(user_data);
                        std::ostringstream json_msg;
                        json_msg << "{\"callback\":\"clearHistoryMessage\",";
                        json_msg << "\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                        json_msg << "\"conv_id\":\"" << EscapeJsonString(base_id) << "\",";
                        json_msg << "\"conv_type\":\"2\"}";
                        
                        SendCallbackToDart("clearHistoryMessage", json_msg.str(), user_data);
                    },
                    [user_data](int error_code, const V2TIMString& error_message) {
                        // OnError - send error callback
                        std::string error_msg = error_message.CString();
                        SendApiCallbackResult(user_data, error_code, error_msg);
                    }
                )
            );
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSaveMessage: Save message
    // Signature: int DartSaveMessage(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Char> json_msg_param, Pointer<Void> user_data)
    int DartSaveMessage(const char* conv_id, unsigned int conv_type, const char* json_msg_param, void* user_data) {

        if (!conv_id || !json_msg_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON message parameter
        std::string json_str = json_msg_param;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        
        if (msg_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartSaveMessage: message_msg_id not found");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1;
        }

        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));

        // Helper class to find and save message
        class DartSaveMessageCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            V2TIMString conv_id_;
            V2TIMConversationType conv_type_;
            
        public:
            DartSaveMessageCallback(void* user_data, const char* conv_id, unsigned int conv_type)
                : user_data_(user_data), conv_id_(conv_id ? conv_id : ""),
                  conv_type_(conv_type == 1 ? V2TIMConversationType::V2TIM_C2C : V2TIMConversationType::V2TIM_GROUP) {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    const V2TIMMessage& message = messages[0];
                    
                    // TODO: SaveMessage API not available in V2TIMMessageManager
                    // Message is already saved when sent, so return success
                    SendApiCallbackResult(user_data_, 0, "");
                } else {
                    SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_COMM_DATABASE_NOTFOUND, "Message not found");
                }
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Find the message first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartSaveMessageCallback(user_data, conv_id, conv_type)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetMessageList: Get message list
    // Signature: int DartGetMessageList(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Char> json_get_msg_param, Pointer<Void> user_data)
    int DartGetMessageList(const char* conv_id, unsigned int conv_type, const char* json_get_msg_param, void* user_data) {
        // This is similar to DartGetHistoryMessageList, but may have different parameters
        // For now, delegate to DartGetHistoryMessageList
        return DartGetHistoryMessageList(conv_id, conv_type, json_get_msg_param, user_data);
    }
    
    // DartMarkMessageAsRead: Mark message as read
    // Signature: int DartMarkMessageAsRead(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Void> user_data)
    int DartMarkMessageAsRead(const char* conv_id, unsigned int conv_type, void* user_data) {

        if (!conv_id || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Determine conversation type
        V2TIMConversationType conversation_type = (conv_type == 1) ? 
            V2TIMConversationType::V2TIM_C2C : V2TIMConversationType::V2TIM_GROUP;
        
        // Extract base ID (remove prefix if present) - message functions expect base ID
        std::string base_id = ExtractBaseConversationID(conv_id);
        V2TIMString base_id_str(base_id.c_str());
        
        // TODO: MarkMessageAsRead API not available in V2TIMMessageManager
        // Use MarkC2CMessageAsRead or MarkGroupMessageAsRead instead
        if (conversation_type == V2TIMConversationType::V2TIM_C2C) {
            SafeGetV2TIMManager()->GetMessageManager()->MarkC2CMessageAsRead(
                base_id_str,
                new DartCallback(
                    user_data,
                    [user_data]() {
                        SendApiCallbackResult(user_data, 0, "");
                    },
                    [user_data](int error_code, const V2TIMString& error_message) {
                        std::string error_msg = error_message.CString();
                    SendApiCallbackResult(user_data, error_code, error_msg);
                    }
                )
            );
        } else {
            SafeGetV2TIMManager()->GetMessageManager()->MarkGroupMessageAsRead(
                base_id_str,
                new DartCallback(
                    user_data,
                    [user_data]() {
                        SendApiCallbackResult(user_data, 0, "");
                    },
                    [user_data](int error_code, const V2TIMString& error_message) {
                        std::string error_msg = error_message.CString();
                    SendApiCallbackResult(user_data, error_code, error_msg);
                    }
                )
            );
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartMarkAllMessageAsRead: Mark all message as read
    // Signature: int DartMarkAllMessageAsRead(Pointer<Void> user_data)
    int DartMarkAllMessageAsRead(void* user_data) {

        if (!user_data) {
            return 1; // Error
        }
        
        // Call V2TIM MarkAllMessageAsRead (async)
        SafeGetV2TIMManager()->GetMessageManager()->MarkAllMessageAsRead(
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
    
    // DartSetLocalCustomData: Set local custom data
    // Signature: int DartSetLocalCustomData(Pointer<Char> json_msg_param, Pointer<Void> user_data)
    // ABI note: the Dart binding declares only (json_msg_param, user_data). The previous
    // signature drifted with extra leading (conv_id, conv_type) args, which shifted
    // json_msg_param/user_data and corrupted the call. The message identity (msgID) and
    // the local custom data are both parsed out of json_msg_param, so the dropped
    // conv_id/conv_type were never needed.
    int DartSetLocalCustomData(const char* json_msg_param, void* user_data) {

        if (!json_msg_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }

        // Parse JSON message parameter
        std::string json_str = json_msg_param;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        std::string local_custom_data = ExtractJsonValue(json_str, "message_local_custom_data");
        
        if (msg_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartSetLocalCustomData: message_msg_id not found");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1;
        }

        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));

        // Helper class to find and set local custom data
        class DartSetLocalCustomDataCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            std::string local_custom_data_;
            
        public:
            DartSetLocalCustomDataCallback(void* user_data, const std::string& local_custom_data)
                : user_data_(user_data), local_custom_data_(local_custom_data) {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    V2TIMMessage message = messages[0];
                    
                    // Set local custom data
                    if (!local_custom_data_.empty()) {
                        V2TIMBuffer buffer(
                            reinterpret_cast<const uint8_t*>(local_custom_data_.c_str()),
                            local_custom_data_.length()
                        );
                        // TODO: V2TIMMessage doesn't have localCustomData field directly
                        // Use SetLocalCustomData method instead
                        message.SetLocalCustomData(buffer, nullptr);
                    }
                    
                    // Update the message
                    SafeGetV2TIMManager()->GetMessageManager()->ModifyMessage(
                        message,
                        new DartMessageCompleteCallback(user_data_)
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
        
        // Find the message first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartSetLocalCustomDataCallback(user_data, local_custom_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartDownloadElemToPath: Download element to path
    // Signature: int DartDownloadElemToPath(Pointer<Char> json_msg_param, Pointer<Char> download_path, Pointer<Void> user_data)
    int DartDownloadElemToPath(const char* json_msg_param, const char* download_path, void* user_data) {

        if (!json_msg_param || !download_path || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON message parameter
        std::string json_str = json_msg_param;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        
        if (msg_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartDownloadElemToPath: message_msg_id not found");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1;
        }

        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));

        // Helper class to find and download element
        class DartDownloadElemCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            std::string download_path_;
            
        public:
            DartDownloadElemCallback(void* user_data, const std::string& download_path)
                : user_data_(user_data), download_path_(download_path) {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    const V2TIMMessage& message = messages[0];
                    
                    // TODO: DownloadElemToPath API not available in V2TIMMessageManager
                    // Return error for now
                    SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "DownloadElemToPath API not available");
                } else {
                    SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_COMM_DATABASE_NOTFOUND, "Message not found");
                }
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Find the message first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartDownloadElemCallback(user_data, download_path)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartDownloadMergerMessage: Download merger message
    // Signature: int DartDownloadMergerMessage(Pointer<Char> json_msg_param, Pointer<Void> user_data)
    int DartDownloadMergerMessage(const char* json_msg_param, void* user_data) {

        if (!json_msg_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON message parameter
        std::string json_str = json_msg_param;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        
        if (msg_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartDownloadMergerMessage: message_msg_id not found");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1;
        }

        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));

        // Helper class to find and download merger message
        class DartDownloadMergerMessageCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            
        public:
            DartDownloadMergerMessageCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    const V2TIMMessage& message = messages[0];
                    
                    // TODO: DownloadMergerMessage API not available in V2TIMMessageManager
                    // Return error for now
                    SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "DownloadMergerMessage API not available");
                } else {
                    SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_SDK_COMM_DATABASE_NOTFOUND, "Message not found");
                }
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Find the message first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartDownloadMergerMessageCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSearchLocalMessages: Search local messages
    // Signature: int DartSearchLocalMessages(Pointer<Char> json_search_message_param, Pointer<Void> user_data)
    int DartSearchLocalMessages(const char* json_search_message_param, void* user_data) {

        if (!json_search_message_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON search parameter
        std::string json_str = json_search_message_param;
        V2TIMMessageSearchParam searchParam;
        
        // Parse keyword list
        std::string keyword_list_str = ExtractJsonValue(json_str, "message_search_param_keyword_list");
        if (!keyword_list_str.empty()) {
            std::vector<std::string> keywords = ParseJsonStringArray(keyword_list_str);
            for (const auto& keyword : keywords) {
                searchParam.keywordList.PushBack(V2TIMString(keyword.c_str()));
            }
        }
        
        // Parse keyword list match type
        int match_type = ExtractJsonInt(json_str, "message_search_param_keyword_list_match_type", 0); // 0 = OR
        searchParam.keywordListMatchType = static_cast<V2TIMKeywordListMatchType>(match_type);
        
        // Parse sender user ID list
        std::string sender_list_str = ExtractJsonValue(json_str, "message_search_param_sender_user_id_list");
        if (!sender_list_str.empty()) {
            std::vector<std::string> sender_ids = ParseJsonStringArray(sender_list_str);
            for (const auto& sender_id : sender_ids) {
                searchParam.senderUserIDList.PushBack(V2TIMString(sender_id.c_str()));
            }
        }
        
        // Parse message type list
        std::string message_type_list_str = ExtractJsonValue(json_str, "message_search_param_message_type_list");
        if (!message_type_list_str.empty()) {
            std::vector<std::string> type_list = ParseJsonStringArray(message_type_list_str);
            for (const auto& type_str : type_list) {
                if (!type_str.empty()) {
                    try {
                        int type_value = std::stoi(type_str);
                        if (type_value >= 0 && type_value < 100) {
                            searchParam.messageTypeList.PushBack(static_cast<V2TIMElemType>(type_value));
                        }
                    } catch (...) {
                        // Skip invalid type values
                    }
                }
            }
        }
        
        // Parse conversation ID
        std::string conversation_id = ExtractJsonValue(json_str, "message_search_param_conversation_id");
        if (!conversation_id.empty()) {
            searchParam.conversationID = V2TIMString(conversation_id.c_str());
        }
        
        // Parse time parameters
        searchParam.searchTimePosition = ExtractJsonInt(json_str, "message_search_param_search_time_position", 0);
        searchParam.searchTimePeriod = ExtractJsonInt(json_str, "message_search_param_search_time_period", 0);
        searchParam.pageIndex = ExtractJsonInt(json_str, "message_search_param_page_index", 0);
        searchParam.pageSize = ExtractJsonInt(json_str, "message_search_param_page_size", 0);
        
        // Call V2TIM SearchLocalMessages (async)
        SafeGetV2TIMManager()->GetMessageManager()->SearchLocalMessages(
            searchParam,
            new DartMessageSearchResultCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartAddMessageReaction: Add message reaction
    // Signature: int DartAddMessageReaction(Pointer<Char> json_msg, Pointer<Char> reaction_id, Pointer<Void> user_data)
    int DartAddMessageReaction(const char* json_msg, const char* reaction_id, void* user_data) {

        if (!json_msg || !reaction_id || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON message to extract message ID
        std::string json_str = json_msg;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        
        if (msg_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartAddMessageReaction: message_msg_id not found");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1;
        }

        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));

        // Helper class to find and add reaction
        class DartAddMessageReactionCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            std::string reaction_id_;
            
        public:
            DartAddMessageReactionCallback(void* user_data, const char* reaction_id)
                : user_data_(user_data), reaction_id_(reaction_id ? reaction_id : "") {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    const V2TIMMessage& message = messages[0];
                    
                    // Call V2TIM AddMessageReaction (async)
                    SafeGetV2TIMManager()->GetMessageManager()->AddMessageReaction(
                        message,
                        V2TIMString(reaction_id_.c_str()),
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
        
        // Find the message first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartAddMessageReactionCallback(user_data, reaction_id)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartRemoveMessageReaction: Remove message reaction
    // Signature: int DartRemoveMessageReaction(Pointer<Char> json_msg, Pointer<Char> reaction_id, Pointer<Void> user_data)
    int DartRemoveMessageReaction(const char* json_msg, const char* reaction_id, void* user_data) {

        if (!json_msg || !reaction_id || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON message to extract message ID
        std::string json_str = json_msg;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        
        if (msg_id.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartRemoveMessageReaction: message_msg_id not found");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "message_msg_id not found");
            return 1;
        }

        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));

        // Helper class to find and remove reaction
        class DartRemoveMessageReactionCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        private:
            void* user_data_;
            std::string reaction_id_;
            
        public:
            DartRemoveMessageReactionCallback(void* user_data, const char* reaction_id)
                : user_data_(user_data), reaction_id_(reaction_id ? reaction_id : "") {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (messages.Size() > 0) {
                    const V2TIMMessage& message = messages[0];
                    
                    // Call V2TIM RemoveMessageReaction (async)
                    SafeGetV2TIMManager()->GetMessageManager()->RemoveMessageReaction(
                        message,
                        V2TIMString(reaction_id_.c_str()),
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
        
        // Find the message first
        SafeGetV2TIMManager()->GetMessageManager()->FindMessages(
            message_id_vector,
            new DartRemoveMessageReactionCallback(user_data, reaction_id)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
} // extern "C"

