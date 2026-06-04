// Conversation Functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"
#include <thread>

// Forward declaration for multi-instance support
extern int64_t GetCurrentInstanceId();
extern void SendCallbackToDart(const char* callback_type, const std::string& json_data, void* user_data);

extern "C" {
    // ============================================================================
    // Conversation Functions
    // ============================================================================
    // Note: BuildFullConversationID is now in dart_compat_utils.cpp
    
} // extern "C"

    // Helper: Parse JSON string array
    static std::vector<std::string> ParseJsonStringArray(const std::string& json_str) {
        std::vector<std::string> result;
        std::string array_str = json_str;
        
        // Try to find array in JSON
        size_t array_start = array_str.find('[');
        if (array_start == std::string::npos) {
            return result;
        }
        
        // Simple parser for string array
        size_t i = array_start + 1; // Skip '['
        std::string current_string;
        bool in_string = false;
        bool escape_next = false;
        
        while (i < array_str.length()) {
            char c = array_str[i];
            
            if (escape_next) {
                current_string += c;
                escape_next = false;
            } else if (c == '\\') {
                escape_next = true;
            } else if (c == '"') {
                in_string = !in_string;
            } else if (in_string) {
                current_string += c;
            } else if (c == ',' || c == ']') {
                if (!current_string.empty()) {
                    result.push_back(current_string);
                    current_string.clear();
                }
                if (c == ']') {
                    break;
                }
            }
            i++;
        }
        
        return result;
    }
    
    // Helper: Convert V2TIMConversationResult to JSON
    // Note: Field names must match Dart SDK expectations: conversation_list_result_next_seq, conversation_list_result_is_finished, conversation_list_result_conv_list
    static std::string ConversationResultToJson(const V2TIMConversationResult& result) {
        std::ostringstream json;
        json << "{";
        json << "\"conversation_list_result_next_seq\":" << result.nextSeq << ",";
        json << "\"conversation_list_result_is_finished\":" << (result.isFinished ? "true" : "false") << ",";
        json << "\"conversation_list_result_conv_list\":" << ConversationVectorToJson(result.conversationList);
        json << "}";
        return json.str();
    }
    
    // Helper class for V2TIMValueCallback<V2TIMConversationResult>
    class DartConversationResultCallback : public V2TIMValueCallback<V2TIMConversationResult> {
    private:
        void* user_data_;
        
    public:
        DartConversationResultCallback(void* user_data) : user_data_(user_data) {}
        
        void OnSuccess(const V2TIMConversationResult& result) override {
            try {
                // Build result JSON (includes conversationList). Capture user_data_str and instance_id
                // on the calling thread to avoid use-after-free when detached thread runs after test/teardown.
                std::string result_json = ConversationResultToJson(result);
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(result_json) << "\"}";
                SendCallbackToDart("apiCallback", json_msg.str(), nullptr);
            } catch (const std::exception& e) {
                // Safely get exception message
                const char* what_msg = e.what();
                if (!what_msg) {
                    what_msg = "Unknown exception (e.what() returned null)";
                }
                V2TIM_LOG(kError, "[dart_compat] DartConversationResultCallback::OnSuccess: Exception: {}", what_msg);
                // Safely construct error message
                std::string error_msg = "Exception: ";
                error_msg += what_msg;
                SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_INVALID_PARAMETERS, error_msg);
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
    
    extern "C" {
    // DartGetConversationList: Get conversation list
    // Signature: int DartGetConversationList(Pointer<Void> user_data)
    // Note: This function doesn't take nextSeq and count parameters, so we use defaults (0, 100)
    int DartGetConversationList(void* user_data) {
        if (!user_data) {
            return 1; // Error
        }
        
        // Call V2TIM GetConversationList (async) with default pagination (nextSeq=0, count=100)
        SafeGetV2TIMManager()->GetConversationManager()->GetConversationList(
            0,  // nextSeq
            100, // count
            new DartConversationResultCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetConversationListByFilter: Get conversation list by filter
    // Signature: int DartGetConversationListByFilter(Pointer<Char> json_filter, int next_seq, int count, Pointer<Void> user_data)
    int DartGetConversationListByFilter(const char* json_filter, int next_seq, int count, void* user_data) {
        if (!user_data) {
            return 1;
        }
        // Avoid touching json_filter or constructing V2TIMConversationListFilter (can SIGSEGV at +52).
        // Call GetConversationList directly so we never touch filter or json_filter.
        V2TIMManager* manager = SafeGetV2TIMManager();
        if (!manager) {
            SendApiCallbackResult(user_data, ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            return 1;
        }
        V2TIMConversationManager* conv_manager = manager->GetConversationManager();
        if (!conv_manager) {
            SendApiCallbackResult(user_data, ERR_SDK_NOT_INITIALIZED, "Conversation manager not initialized");
            return 1;
        }
        conv_manager->GetConversationList(
            static_cast<uint64_t>(next_seq),
            static_cast<uint32_t>(count),
            new DartConversationResultCallback(user_data)
        );
        (void)json_filter;
        return 0;
    }
    
    // DartGetConversation: Get conversation
    // Signature: int DartGetConversation(Pointer<Char> json_get_conv_list_param, Pointer<Void> user_data)
    // Note: The actual signature matches the native SDK: json_get_conv_list_param is a JSON array string
    int DartGetConversation(const char* json_get_conv_list_param, void* user_data) {
        if (!json_get_conv_list_param || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1;
        }
        
        std::string json_str = json_get_conv_list_param;
        size_t array_start = json_str.find('[');
        if (array_start == std::string::npos) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Failed to find array start in JSON");
            return 1;
        }
        
        size_t obj_start = json_str.find('{', array_start);
        if (obj_start == std::string::npos) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Failed to find object start in JSON");
            return 1;
        }
        
        int brace_count = 0;
        size_t obj_end = obj_start;
        for (size_t i = obj_start; i < json_str.length(); i++) {
            if (json_str[i] == '{') {
                brace_count++;
            } else if (json_str[i] == '}') {
                brace_count--;
                if (brace_count == 0) {
                    obj_end = i;
                    break;
                }
            }
        }
        
        if (brace_count != 0) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Unmatched braces in JSON");
            return 1;
        }
        
        std::string obj_str = json_str.substr(obj_start, obj_end - obj_start + 1);
        int conv_type = ExtractJsonInt(obj_str, "get_conversation_list_param_conv_type", 0, true);
        std::string conv_id = ExtractJsonValue(obj_str, "get_conversation_list_param_conv_id", true);
        
        if (conv_id.empty()) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Failed to extract conv_id from JSON");
            return 1;
        }
        
        // Build full conversationID with prefix
        // conv_id from JSON is the base ID (without c2c_ or group_ prefix)
        // GetConversation expects the full conversationID (with prefix)
        std::string full_conv_id = BuildFullConversationID(conv_id.c_str(), conv_type);
        V2TIMString conv_id_str(full_conv_id.c_str());
        
        // Helper class for V2TIMValueCallback<V2TIMConversation>
        class DartConversationCallback : public V2TIMValueCallback<V2TIMConversation> {
        private:
            void* user_data_;
            
        public:
            DartConversationCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMConversation& conversation) override {
                // Use ConversationVectorToJson helper to ensure consistent format
                // This ensures conv_id format matches V2TimConversation.fromJson expectations
                // Dart layer expects List<V2TimConversation>, so we return an array with a single conversation
                V2TIMConversationVector convVector;
                convVector.PushBack(conversation);
                std::string conv_json = ConversationVectorToJson(convVector);
                
                // V2TimValueCallback expects json_param field at top level as a JSON string
                // Build the complete callback JSON with json_param as an escaped string
                std::string user_data_str = UserDataToString(user_data_);
                int64_t instance_id = GetCurrentInstanceId();
                std::ostringstream json_msg;
                json_msg << "{\"callback\":\"apiCallback\",\"instance_id\":" << instance_id << ",\"user_data\":\"" << EscapeJsonString(user_data_str) << "\",";
                json_msg << "\"code\":0,\"desc\":\"\",";
                json_msg << "\"json_param\":\"" << EscapeJsonString(conv_json) << "\"}";
                
                SendCallbackToDart("apiCallback", json_msg.str(), user_data_);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        SafeGetV2TIMManager()->GetConversationManager()->GetConversation(
            conv_id_str,
            new DartConversationCallback(user_data)
        );
        return 0;
    }
    
    // DartDeleteConversation: Delete conversation
    // Signature: int DartDeleteConversation(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Void> user_data)
    int DartDeleteConversation(const char* conv_id, unsigned int conv_type, void* user_data) {
        if (!conv_id || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Build full conversationID with prefix
        std::string full_conv_id = BuildFullConversationID(conv_id, conv_type);
        V2TIMString conv_id_str(full_conv_id.c_str());
        
        // Call V2TIM DeleteConversation (async)
        // Note: DeleteConversation only takes conversationID, not conversation_type
        SafeGetV2TIMManager()->GetConversationManager()->DeleteConversation(
            conv_id_str,
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
    
    // DartDeleteConversationList: Delete conversation list
    // Signature: int DartDeleteConversationList(Pointer<Char> conversation_id_array, bool clear_message, Pointer<Void> user_data)
    // Note: conversation_id_array is a JSON array string (e.g., "[\"c2c_user1\",\"group_group1\"]")
    int DartDeleteConversationList(const char* conversation_id_array, bool clear_message, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartDeleteConversationList: conversation_id_array={}, clear_message={}",
                  conversation_id_array ? conversation_id_array : "null", clear_message);
        
        if (!conversation_id_array || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON array string to get conversation ID list
        std::string json_str = conversation_id_array;
        std::vector<std::string> conversation_ids = ParseJsonStringArray(json_str);
        
        if (conversation_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartDeleteConversationList: conversation_id list is empty");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "conversation_id list is empty");
            return 1; // Error
        }
        
        // Convert to V2TIMStringVector
        V2TIMStringVector conversation_id_vector;
        for (const auto& conv_id : conversation_ids) {
            conversation_id_vector.PushBack(V2TIMString(conv_id.c_str()));
        }
        
        // Helper class for V2TIMValueCallback<V2TIMConversationOperationResultVector>
        class DartConversationOperationResultVectorCallback : public V2TIMValueCallback<V2TIMConversationOperationResultVector> {
        private:
            void* user_data_;
            
        public:
            DartConversationOperationResultVectorCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMConversationOperationResultVector& results) override {
                // Convert to JSON
                std::ostringstream json;
                json << "[";
                for (size_t i = 0; i < results.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMConversationOperationResult& result = results[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    // Note: conversation_operation_result_conversation_id expects the full conversationID (with prefix)
                    // This is different from conv_id in ConversationVectorToJson which expects base ID
                    std::string conv_id = result.conversationID.CString();
                    json << "\"conversation_operation_result_conversation_id\":\"" << EscapeJsonString(conv_id) << "\",";
                    json << "\"conversation_operation_result_result_code\":" << result.resultCode;
                    if (!result.resultInfo.Empty()) {
                        std::string result_info = result.resultInfo.CString();
                        json << ",\"conversation_operation_result_result_info\":\"" << EscapeJsonString(result_info) << "\"";
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
        
        // Call V2TIM DeleteConversationList (async)
        SafeGetV2TIMManager()->GetConversationManager()->DeleteConversationList(
            conversation_id_vector,
            clear_message,
            new DartConversationOperationResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartSetConversationDraft: Set conversation draft
    // Signature: int DartSetConversationDraft(Pointer<Char> conv_id, TIMConvType conv_type, Pointer<Char> json_draft_param)
    // ABI note: the Dart binding (native_imsdk_bindings_generated.dart) declares NO
    // user_data argument, so this call is SYNCHRONOUS from Dart's point of view. The
    // previous 4-arg signature (with a trailing void* user_data) drifted from the ABI
    // and would read garbage in the user_data slot. We therefore do NOT send an async
    // api callback; we pass a no-op V2TIMCallback to the underlying V2TIM method and
    // return the int result directly. `json_draft_param` is the draft text (may be a
    // plain string or a JSON wrapper); we pass it through to SetConversationDraft as
    // the draft text, matching the previous behavior of `draft_text`.
    int DartSetConversationDraft(const char* conv_id, unsigned int conv_type, const char* json_draft_param) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSetConversationDraft: conv_id={}, conv_type={}",
                  conv_id ? conv_id : "null", conv_type);

        if (!conv_id) {
            return 1; // Error
        }

        // Build full conversationID with prefix
        std::string full_conv_id = BuildFullConversationID(conv_id, conv_type);
        V2TIMString conv_id_str(full_conv_id.c_str());
        V2TIMString draft_text_str(json_draft_param ? json_draft_param : "");

        // Call V2TIM SetConversationDraft.
        // Note: SetConversationDraft only takes conversationID and draftText, not conversation_type.
        // Synchronous from Dart's perspective (no user_data). Pass nullptr for the callback:
        // V2TIMConversationManagerImpl::SetConversationDraft null-guards it (`if (callback)`),
        // so a heap `new DartCallback(...)` here would only leak (nothing deletes it).
        SafeGetV2TIMManager()->GetConversationManager()->SetConversationDraft(
            conv_id_str,
            draft_text_str,
            nullptr
        );

        return 0; // TIM_SUCC (request accepted)
    }

    // DartCancelConversationDraft: Cancel conversation draft
    // Signature: int DartCancelConversationDraft(Pointer<Char> conv_id, TIMConvType conv_type)
    int DartCancelConversationDraft(const char* conv_id, unsigned int conv_type) {
        // Cancel draft is same as setting draft to empty
        return DartSetConversationDraft(conv_id, conv_type, "");
    }
    
    // DartPinConversation: Pin conversation
    // Signature: int DartPinConversation(Pointer<Char> conv_id, TIMConvType conv_type, int is_pinned, Pointer<Void> user_data)
    int DartPinConversation(const char* conv_id, unsigned int conv_type, int is_pinned, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartPinConversation: conv_id={}, conv_type={}, is_pinned={}",
                  conv_id ? conv_id : "null", conv_type, is_pinned);
        
        if (!conv_id || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Build full conversationID with prefix
        // conv_id from Dart is the base ID (without c2c_ or group_ prefix)
        // PinConversation expects the full conversationID (with prefix)
        std::string full_conv_id = BuildFullConversationID(conv_id, conv_type);
        V2TIMString conv_id_str(full_conv_id.c_str());
        bool is_pinned_bool = (is_pinned != 0);
        
        // Call V2TIM PinConversation (async)
        // Note: PinConversation only takes conversationID and isPinned, not conversation_type
        SafeGetV2TIMManager()->GetConversationManager()->PinConversation(
            conv_id_str,
            is_pinned_bool,
            new DartCallback(
                user_data,
                [user_data]() {
                    // OnSuccess - send API callback result
                    // OnConversationChanged event will be triggered by PinConversation
                    // The Dart layer listens to OnConversationChanged and calls setPinned
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
    
    // DartMarkConversation: Mark conversation
    // Signature: int DartMarkConversation(Pointer<Char> conversation_id_array, Uint64 mark_type, bool enable_mark, Pointer<Void> user_data)
    // ABI note: arg1 is a JSON ARRAY of FULL (already-prefixed) conversation IDs, not a
    // single base id + conv_type. The previous 5-arg signature drifted from the ABI
    // (an extra conv_type slot shifted mark_type/enable_mark/user_data). Parse the JSON
    // array into the V2TIMStringVector instead of building one id from conv_id+conv_type.
    // mark_type is Uint64 in the binding (matches V2TIM markType uint64_t); a 32-bit int
    // here truncates the value on ARM64 (mobile) — keep it uint64_t.
    int DartMarkConversation(const char* conversation_id_array, uint64_t mark_type, bool enable_mark, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartMarkConversation: conversation_id_array={}, mark_type={}, enable_mark={}",
                  conversation_id_array ? conversation_id_array : "null", mark_type, enable_mark);

        if (!conversation_id_array || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }

        // Parse the JSON array of full conversation IDs into a V2TIMStringVector.
        std::vector<std::string> conversation_ids = ParseJsonStringArray(conversation_id_array);
        if (conversation_ids.empty()) {
            V2TIM_LOG(kError, "[dart_compat] DartMarkConversation: conversation id list is empty");
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "conversation id list is empty");
            return 1; // Error
        }

        bool enable_mark_bool = enable_mark;

        // Call V2TIM MarkConversation (async)
        // Note: MarkConversation takes conversationIDList (vector), markType, and enableMark
        V2TIMStringVector conv_id_vector;
        for (const auto& conv_id : conversation_ids) {
            conv_id_vector.PushBack(V2TIMString(conv_id.c_str()));
        }

        // Helper class for V2TIMValueCallback<V2TIMConversationOperationResultVector>
        class DartConversationOperationResultVectorCallback : public V2TIMValueCallback<V2TIMConversationOperationResultVector> {
        private:
            void* user_data_;
            
        public:
            DartConversationOperationResultVectorCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const V2TIMConversationOperationResultVector& results) override {
                // Convert to JSON
                std::ostringstream json;
                json << "[";
                for (size_t i = 0; i < results.Size(); i++) {
                    if (i > 0) {
                        json << ",";
                    }
                    const V2TIMConversationOperationResult& result = results[i];
                    json << "{";
                    // Get CString() (has built-in protection)
                    // Note: conversation_operation_result_conversation_id expects the full conversationID (with prefix)
                    // This is different from conv_id in ConversationVectorToJson which expects base ID
                    std::string conv_id = result.conversationID.CString();
                    json << "\"conversation_operation_result_conversation_id\":\"" << EscapeJsonString(conv_id) << "\",";
                    json << "\"conversation_operation_result_result_code\":" << result.resultCode;
                    if (!result.resultInfo.Empty()) {
                        std::string result_info = result.resultInfo.CString();
                        json << ",\"conversation_operation_result_result_info\":\"" << EscapeJsonString(result_info) << "\"";
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
        
        SafeGetV2TIMManager()->GetConversationManager()->MarkConversation(
            conv_id_vector,
            static_cast<uint64_t>(mark_type),
            enable_mark_bool,
            new DartConversationOperationResultVectorCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetTotalUnreadMessageCount: Get total unread message count
    // Signature: int DartGetTotalUnreadMessageCount(Pointer<Void> user_data)
    int DartGetTotalUnreadMessageCount(void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartGetTotalUnreadMessageCount");
        
        if (!user_data) {
            return 1; // Error
        }
        
        // Helper class for V2TIMValueCallback<uint64_t>
        class DartUint64Callback : public V2TIMValueCallback<uint64_t> {
        private:
            void* user_data_;
            
        public:
            DartUint64Callback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const uint64_t& count) override {
                std::map<std::string, std::string> result_fields;
                result_fields["totalUnreadCount"] = std::to_string(count);
                std::string data_json = BuildJsonObject(result_fields);
                SendApiCallbackResult(user_data_, 0, "", data_json);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetTotalUnreadMessageCount (async)
        SafeGetV2TIMManager()->GetConversationManager()->GetTotalUnreadMessageCount(
            new DartUint64Callback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetUnreadMessageCountByFilter: Get unread message count by filter
    // Signature: int DartGetUnreadMessageCountByFilter(Pointer<Char> json_filter, Pointer<Void> user_data)
    int DartGetUnreadMessageCountByFilter(const char* json_filter, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartGetUnreadMessageCountByFilter");
        
        if (!json_filter || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON filter parameter
        std::string json_str = json_filter;
        // TODO: Parse filter parameters from JSON
        
        // Create a basic conversation list filter
        V2TIMConversationListFilter filter;
        // Set default filter type (all conversations)
        filter.filterType = V2TIMConversationFilterType::V2TIM_CONVERSATION_FILTER_TYPE_NONE;
        
        // Helper class for V2TIMValueCallback<uint64_t>
        class DartUint64Callback : public V2TIMValueCallback<uint64_t> {
        private:
            void* user_data_;
            
        public:
            DartUint64Callback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess(const uint64_t& count) override {
                std::map<std::string, std::string> result_fields;
                result_fields["unreadCount"] = std::to_string(count);
                std::string data_json = BuildJsonObject(result_fields);
                SendApiCallbackResult(user_data_, 0, "", data_json);
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM GetUnreadMessageCountByFilter (async)
        SafeGetV2TIMManager()->GetConversationManager()->GetUnreadMessageCountByFilter(
            filter,
            new DartUint64Callback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartCleanConversationUnreadMessageCount: Clean conversation unread message count
    // Signature: int DartCleanConversationUnreadMessageCount(Pointer<Char> conversation_id, int64_t clean_timestamp, int64_t clean_sequence, Pointer<Void> user_data)
    int DartCleanConversationUnreadMessageCount(const char* conversation_id, int64_t clean_timestamp, int64_t clean_sequence, void* user_data) {
        
        if (!conversation_id || !user_data) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Note: Dart layer passes full conversationID (with prefix) directly
        // We use it as is, but BuildFullConversationID provides defensive check
        // If conversation_id already has prefix, it will be used as is
        // If not, we can't determine type, so we use it as is (should not happen)
        std::string conv_id_str(conversation_id);
        // Defensive check: if no prefix, assume it's already base ID and we can't determine type
        // In practice, Dart layer should always pass full ID, so this is just for safety
        V2TIMString conv_id(conv_id_str.c_str());
        
        // Helper class for V2TIMCallback
        class DartCleanUnreadCallback : public V2TIMCallback {
        private:
            void* user_data_;
            
        public:
            DartCleanUnreadCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess() override {
                SendApiCallbackResult(user_data_, 0, "");
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }
        };
        
        // Call V2TIM CleanConversationUnreadMessageCount (async)
        SafeGetV2TIMManager()->GetConversationManager()->CleanConversationUnreadMessageCount(
            conv_id,
            static_cast<uint64_t>(clean_timestamp),
            static_cast<uint64_t>(clean_sequence),
            new DartCleanUnreadCallback(user_data)
        );
        
        return 0; // TIM_SUCC (request accepted)
    }
    
} // extern "C"

