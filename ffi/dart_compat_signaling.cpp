// Signaling Functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"
#include "dart_send_message_contract.h"
#include "V2TIMManagerImpl.h"

namespace {

const char* StoreDartInviteReturnId(std::string invite_id) {
    thread_local std::string stored_invite_id;
    stored_invite_id = std::move(invite_id);
    return stored_invite_id.empty() ? nullptr : stored_invite_id.c_str();
}

void SendNoTerminalCallbackFailure(void* user_data, const char* operation) {
    V2TIM_LOG(kError, "[dart_compat] {} returned without terminal callback", operation);
    if (user_data) {
        SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR, "Signaling operation returned without terminal callback");
    }
}

}

extern "C" {
    // ============================================================================
    // Signaling Functions
    // ============================================================================
    
    // DartInvite: Invite user for signaling
    // Signature: Pointer<Char> DartInvite(Pointer<Char> invitee, Pointer<Char> data, Bool online_user_only, Pointer<Char> json_offline_push_info, Int timeout, Pointer<Char> invite_id_buffer, Pointer<Void> user_data)
    const char* DartInvite(const char* invitee, const char* data, bool online_user_only, const char* json_offline_push_info, int timeout, const char* invite_id_buffer, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartInvite: timeout={}", timeout);
        fflush(stdout);
        
        if (!invitee) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Invalid parameters");
            }
            return nullptr;
        }
        // invite_id_buffer may be null (adapter passes Pointer.fromAddress(0)); we still proceed and return stored invite_id pointer
        
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            }
            return nullptr;
        }
        
        auto* signaling_mgr = manager->GetSignalingManager();
        if (!signaling_mgr) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Signaling manager not available");
            }
            return nullptr;
        }
        
        V2TIMString invitee_str(invitee);
        V2TIMString data_str(data ? data : "");
        
        // Parse offline push info if provided
        V2TIMOfflinePushInfo offline_push;
        if (json_offline_push_info) {
            // TODO: Parse offline push info from JSON
            // For now, use default offline push info
        }
        
        class DartInviteCallback : public V2TIMCallback {
        public:
            void* user_data_;
            std::atomic<bool> success_;
            TerminalCallbackGate terminal_gate_;
            
            DartInviteCallback(void* user_data) : user_data_(user_data), success_(false) {}
            
            void OnSuccess() override {
                if (terminal_gate_.TryComplete()) {
                    success_.store(true, std::memory_order_release);
                }
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                if (!terminal_gate_.TryComplete()) return;
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }

            auto success() const -> bool { return success_.load(std::memory_order_acquire); }
            uint32_t terminal_attempt_count() const { return terminal_gate_.attempt_count(); }
        };
        
        std::shared_ptr<DartInviteCallback> callback = std::make_shared<DartInviteCallback>(user_data);
        auto* manager_impl = static_cast<V2TIMManagerImpl*>(manager);
        V2TIMString invite_id = manager_impl->RunOnEventThread<V2TIMString>([signaling_mgr, invitee_str, data_str,
                                                                             online_user_only, offline_push, timeout,
                                                                             callback]() -> V2TIMString {
            return signaling_mgr->Invite(invitee_str, data_str, online_user_only, offline_push, timeout, callback.get());
        });
        
        std::string invite_id_str = invite_id.CString();
        
        if (user_data && callback->success() && !invite_id_str.empty()) {
            std::ostringstream json;
            json << "{\"invite_id\":\"" << EscapeJsonString(invite_id_str) << "\"}";
            SendApiCallbackResult(user_data, 0, "", json.str());
        }
        if (callback->terminal_attempt_count() == 0) {
            if (callback->terminal_gate_.TryComplete()) {
                SendNoTerminalCallbackFailure(user_data, "DartInvite");
            }
        }
        
        // Copy to buffer if provided
        if (invite_id_buffer && !invite_id_str.empty()) {
            // Note: invite_id_buffer is const char* in signature, but we need to write to it
            // This is a limitation - we'll return the stored string pointer instead
        }
        
        return StoreDartInviteReturnId(invite_id_str);
    }
    
    // DartInviteInGroup: Invite users in group for signaling
    // Signature: Pointer<Char> DartInviteInGroup(Pointer<Char> group_id, Pointer<Char> json_invitee_array, Pointer<Char> data, Bool online_user_only, Int timeout, Pointer<Char> invite_id_buffer, Pointer<Void> user_data)
    const char* DartInviteInGroup(const char* group_id, const char* json_invitee_array, const char* data, bool online_user_only, int timeout, const char* invite_id_buffer, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartInviteInGroup: timeout={}", timeout);
        fflush(stdout);
        
        if (!group_id || !json_invitee_array) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Invalid parameters");
            }
            return nullptr;
        }
        
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            }
            return nullptr;
        }
        
        auto* signaling_mgr = manager->GetSignalingManager();
        if (!signaling_mgr) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Signaling manager not available");
            }
            return nullptr;
        }
        
        V2TIMString group_id_str(group_id);
        V2TIMString data_str(data ? data : "");
        
        // Parse invitee array from JSON
        std::string json_str = json_invitee_array;
        V2TIMStringVector invitee_vec;
        
        // Simple JSON array parsing (e.g., ["user1", "user2"])
        // Find array content between [ and ]
        size_t start = json_str.find('[');
        size_t end = json_str.rfind(']');
        if (start != std::string::npos && end != std::string::npos && end > start) {
            std::string array_content = json_str.substr(start + 1, end - start - 1);
            // Split by comma
            size_t pos = 0;
            while (pos < array_content.length()) {
                // Skip whitespace
                while (pos < array_content.length() && (array_content[pos] == ' ' || array_content[pos] == '\t')) {
                    pos++;
                }
                if (pos >= array_content.length()) break;
                
                // Find next comma or end
                size_t comma = array_content.find(',', pos);
                if (comma == std::string::npos) comma = array_content.length();
                
                // Extract user ID (remove quotes if present)
                std::string user_id = array_content.substr(pos, comma - pos);
                // Remove quotes
                if (user_id.length() >= 2 && user_id[0] == '"' && user_id[user_id.length() - 1] == '"') {
                    user_id = user_id.substr(1, user_id.length() - 2);
                }
                // Trim whitespace
                while (!user_id.empty() && (user_id[0] == ' ' || user_id[0] == '\t')) {
                    user_id = user_id.substr(1);
                }
                while (!user_id.empty() && (user_id[user_id.length() - 1] == ' ' || user_id[user_id.length() - 1] == '\t')) {
                    user_id = user_id.substr(0, user_id.length() - 1);
                }
                
                if (!user_id.empty()) {
                    invitee_vec.PushBack(V2TIMString(user_id.c_str()));
                }
                
                pos = comma + 1;
            }
        }
        
        if (invitee_vec.Size() == 0) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Invitee list is empty");
            }
            return nullptr;
        }
        
        class DartInviteInGroupCallback : public V2TIMCallback {
        public:
            void* user_data_;
            bool success_;
            TerminalCallbackGate terminal_gate_;
            
            DartInviteInGroupCallback(void* user_data) : user_data_(user_data), success_(false) {}
            
            void OnSuccess() override {
                if (terminal_gate_.TryComplete()) {
                    success_ = true;
                }
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                if (!terminal_gate_.TryComplete()) return;
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }

            bool success() const { return success_; }
            uint32_t terminal_attempt_count() const { return terminal_gate_.attempt_count(); }
        };
        
        DartInviteInGroupCallback callback(user_data);
        
        // Call InviteInGroup (synchronous call that returns invite_id immediately)
        V2TIMString invite_id = signaling_mgr->InviteInGroup(group_id_str, invitee_vec, data_str, online_user_only, timeout, &callback);
        
        std::string invite_id_str = invite_id.CString();
        
        // Always send callback to Dart so adapter's completer completes (group invite returns empty invite_id)
        if (user_data && callback.success()) {
            std::ostringstream json;
            json << "{\"invite_id\":\"" << EscapeJsonString(invite_id_str) << "\"}";
            SendApiCallbackResult(user_data, 0, "", json.str());
        }
        if (callback.terminal_attempt_count() == 0) {
            SendNoTerminalCallbackFailure(user_data, "DartInviteInGroup");
        }
        
        return StoreDartInviteReturnId(invite_id_str);
    }
    
    // DartCancel: Cancel signaling invitation
    // Signature: int DartCancel(Pointer<Char> invite_id, Pointer<Char> data, Pointer<Void> user_data)
    int DartCancel(const char* invite_id, const char* data, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartCancel");
        
        if (!invite_id) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Invalid parameters");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            }
            return V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED;
        }
        
        auto* signaling_mgr = manager->GetSignalingManager();
        if (!signaling_mgr) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Signaling manager not available");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        V2TIMString invite_id_str(invite_id);
        V2TIMString data_str(data ? data : "");
        
        class DartCancelCallback : public V2TIMCallback {
        public:
            void* user_data_;
            TerminalCallbackGate terminal_gate_;
            
            DartCancelCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess() override {
                if (!terminal_gate_.TryComplete()) return;
                SendApiCallbackResult(user_data_, 0, "");
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                if (!terminal_gate_.TryComplete()) return;
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }

            uint32_t terminal_attempt_count() const { return terminal_gate_.attempt_count(); }
        };
        
        DartCancelCallback callback(user_data);
        signaling_mgr->Cancel(invite_id_str, data_str, &callback);
        if (callback.terminal_attempt_count() == 0) {
            SendNoTerminalCallbackFailure(user_data, "DartCancel");
            return V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR;
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartAccept: Accept signaling invitation
    // Signature: int DartAccept(Pointer<Char> invite_id, Pointer<Char> data, Pointer<Void> user_data)
    int DartAccept(const char* invite_id, const char* data, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartAccept");
        
        if (!invite_id) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Invalid parameters");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            }
            return V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED;
        }
        
        auto* signaling_mgr = manager->GetSignalingManager();
        if (!signaling_mgr) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Signaling manager not available");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        V2TIMString invite_id_str(invite_id);
        V2TIMString data_str(data ? data : "");
        
        class DartAcceptCallback : public V2TIMCallback {
        public:
            void* user_data_;
            TerminalCallbackGate terminal_gate_;
            
            DartAcceptCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess() override {
                if (!terminal_gate_.TryComplete()) return;
                SendApiCallbackResult(user_data_, 0, "");
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                if (!terminal_gate_.TryComplete()) return;
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }

            uint32_t terminal_attempt_count() const { return terminal_gate_.attempt_count(); }
        };
        
        DartAcceptCallback callback(user_data);
        signaling_mgr->Accept(invite_id_str, data_str, &callback);
        if (callback.terminal_attempt_count() == 0) {
            SendNoTerminalCallbackFailure(user_data, "DartAccept");
            return V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR;
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartReject: Reject signaling invitation
    // Signature: int DartReject(Pointer<Char> invite_id, Pointer<Char> data, Pointer<Void> user_data)
    int DartReject(const char* invite_id, const char* data, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartReject");
        
        if (!invite_id) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Invalid parameters");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            }
            return V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED;
        }
        
        auto* signaling_mgr = manager->GetSignalingManager();
        if (!signaling_mgr) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Signaling manager not available");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        V2TIMString invite_id_str(invite_id);
        V2TIMString data_str(data ? data : "");
        
        class DartRejectCallback : public V2TIMCallback {
        public:
            void* user_data_;
            TerminalCallbackGate terminal_gate_;
            
            DartRejectCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess() override {
                if (!terminal_gate_.TryComplete()) return;
                SendApiCallbackResult(user_data_, 0, "");
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                if (!terminal_gate_.TryComplete()) return;
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }

            uint32_t terminal_attempt_count() const { return terminal_gate_.attempt_count(); }
        };
        
        DartRejectCallback callback(user_data);
        signaling_mgr->Reject(invite_id_str, data_str, &callback);
        if (callback.terminal_attempt_count() == 0) {
            SendNoTerminalCallbackFailure(user_data, "DartReject");
            return V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR;
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartGetSignalingInfo: Get signaling info from message
    // Signature: int DartGetSignalingInfo(Pointer<Char> json_msg, Pointer<Void> user_data)
    int DartGetSignalingInfo(const char* json_msg, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartGetSignalingInfo");
        
        if (!json_msg) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Invalid parameters");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            }
            return V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED;
        }
        
        auto* signaling_mgr = manager->GetSignalingManager();
        if (!signaling_mgr) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Signaling manager not available");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        // Parse message ID from JSON
        // json_msg might be a JSON object with message_msg_id field, or just a message ID string
        std::string json_str = json_msg;
        std::string msg_id = ExtractJsonValue(json_str, "message_msg_id");
        if (msg_id.empty()) {
            // Try to treat json_msg as a direct message ID string
            msg_id = json_str;
            // Remove quotes if present
            if (msg_id.length() >= 2 && msg_id[0] == '"' && msg_id[msg_id.length() - 1] == '"') {
                msg_id = msg_id.substr(1, msg_id.length() - 2);
            }
        }
        
        if (msg_id.empty()) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Message ID not found in JSON");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        // Find message by ID. The current FindMessages implementation completes inline.
        // We need to use FindMessages to get the message, then call GetSignalingInfo
        class DartGetSignalingInfoCallback : public V2TIMValueCallback<V2TIMMessageVector> {
        public:
            void* user_data_;
            V2TIMSignalingManager* signaling_mgr_;
            TerminalCallbackGate terminal_gate_;
            
            DartGetSignalingInfoCallback(void* user_data, V2TIMSignalingManager* signaling_mgr) 
                : user_data_(user_data), signaling_mgr_(signaling_mgr) {}
            
            void OnSuccess(const V2TIMMessageVector& messages) override {
                if (!terminal_gate_.TryComplete()) return;
                if (messages.Size() == 0) {
                    SendApiCallbackResult(user_data_, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Message not found");
                    return;
                }
                
                // Get signaling info from the first message
                const V2TIMMessage& msg = messages[0];
                V2TIMSignalingInfo signaling_info = signaling_mgr_->GetSignalingInfo(msg);
                
                // Convert signaling info to JSON
                std::ostringstream json;
                json << "{";
                json << "\"inviteID\":\"" << EscapeJsonString(signaling_info.inviteID.CString()) << "\",";
                json << "\"groupID\":\"" << EscapeJsonString(signaling_info.groupID.CString()) << "\",";
                json << "\"inviter\":\"" << EscapeJsonString(signaling_info.inviter.CString()) << "\",";
                json << "\"inviteeList\":[";
                for (size_t i = 0; i < signaling_info.inviteeList.Size(); i++) {
                    if (i > 0) json << ",";
                    json << "\"" << EscapeJsonString(signaling_info.inviteeList[i].CString()) << "\"";
                }
                json << "],";
                json << "\"data\":\"" << EscapeJsonString(signaling_info.data.CString()) << "\",";
                json << "\"actionType\":" << static_cast<int>(signaling_info.actionType) << ",";
                json << "\"timeout\":" << signaling_info.timeout;
                json << "}";
                
                SendApiCallbackResult(user_data_, 0, "", json.str());
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                if (!terminal_gate_.TryComplete()) return;
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }

            uint32_t terminal_attempt_count() const { return terminal_gate_.attempt_count(); }
        };
        
        // Find message by ID using V2TIMStringVector
        V2TIMStringVector message_id_vector;
        message_id_vector.PushBack(V2TIMString(msg_id.c_str()));
        
        DartGetSignalingInfoCallback callback(user_data, signaling_mgr);
        manager->GetMessageManager()->FindMessages(message_id_vector, &callback);
        if (callback.terminal_attempt_count() == 0) {
            SendNoTerminalCallbackFailure(user_data, "DartGetSignalingInfo");
            return V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR;
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
    // DartModifyInvitation: Modify signaling invitation
    // Signature: int DartModifyInvitation(Pointer<Char> invite_id, Pointer<Char> data, Pointer<Void> user_data)
    int DartModifyInvitation(const char* invite_id, const char* data, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartModifyInvitation");
        
        if (!invite_id) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Invalid parameters");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        auto* manager = SafeGetV2TIMManager();
        if (!manager) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED, "SDK not initialized");
            }
            return V2TIMErrorCode::ERR_SDK_NOT_INITIALIZED;
        }
        
        auto* signaling_mgr = manager->GetSignalingManager();
        if (!signaling_mgr) {
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Signaling manager not available");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        V2TIMString invite_id_str(invite_id);
        V2TIMString data_str(data ? data : "");
        
        class DartModifyInvitationCallback : public V2TIMCallback {
        public:
            void* user_data_;
            TerminalCallbackGate terminal_gate_;
            
            DartModifyInvitationCallback(void* user_data) : user_data_(user_data) {}
            
            void OnSuccess() override {
                if (!terminal_gate_.TryComplete()) return;
                SendApiCallbackResult(user_data_, 0, "");
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                if (!terminal_gate_.TryComplete()) return;
                std::string error_msg = error_message.CString();
                SendApiCallbackResult(user_data_, error_code, error_msg);
            }

            uint32_t terminal_attempt_count() const { return terminal_gate_.attempt_count(); }
        };
        
        DartModifyInvitationCallback callback(user_data);
        signaling_mgr->ModifyInvitation(invite_id_str, data_str, &callback);
        if (callback.terminal_attempt_count() == 0) {
            SendNoTerminalCallbackFailure(user_data, "DartModifyInvitation");
            return V2TIMErrorCode::ERR_SDK_INTERNAL_ERROR;
        }
        
        return 0; // TIM_SUCC (request accepted)
    }
    
} // extern "C"
