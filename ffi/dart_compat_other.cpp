// Other Miscellaneous Functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"

extern "C" {
    // ============================================================================
    // Other Functions
    // ============================================================================
    
    // DartCallExperimentalAPI: Call experimental API
    // This function handles experimental/internal operations like setUIPlatform, setNetworkInfo, etc.
    // For Tox implementation, most of these operations are not needed, but we need to implement
    // the function to avoid symbol lookup errors.
    int DartCallExperimentalAPI(const char* json_param, void* user_data) {
        if (!json_param) {
            V2TIM_LOG(kError, "[dart_compat] DartCallExperimentalAPI: json_param is null");
            if (user_data) {
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "json_param is null");
            }
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        
        if (!user_data) {
            V2TIM_LOG(kError, "[dart_compat] DartCallExperimentalAPI: user_data is null");
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
        try {
            // Parse JSON parameters
            std::map<std::string, std::string> params = ParseJsonString(std::string(json_param));
            
            // Get the operation type
            std::string operation = params.count("request_internal_operation") > 0 
                ? params["request_internal_operation"] 
                : "";
            if (operation != "internal_operation_write_log") {
                V2TIM_LOG(kInfo, "[dart_compat] DartCallExperimentalAPI: operation={}", operation);
            }
            // Handle different operations
            if (operation == "internal_operation_set_ui_platform") {
                // setUIPlatform - not needed for Tox, just return success
                V2TIM_LOG(kInfo, "[dart_compat] DartCallExperimentalAPI: setUIPlatform (ignored for Tox)");
                SendApiCallbackResult(user_data, 0, "");
                return 0;
            } else if (operation == "internal_operation_set_network_info") {
                // setNetworkInfo - not needed for Tox, just return success
                V2TIM_LOG(kInfo, "[dart_compat] DartCallExperimentalAPI: setNetworkInfo (ignored for Tox)");
                SendApiCallbackResult(user_data, 0, "");
                return 0;
            } else if (operation == "internal_operation_write_log") {
                // writeLog - not needed for Tox, just return success (no log to avoid flooding)
                SendApiCallbackResult(user_data, 0, "");
                return 0;
            } else if (operation == "internal_operation_is_commercial_ability_enabled") {
                // checkAbility - return false (no commercial ability)
                V2TIM_LOG(kInfo, "[dart_compat] DartCallExperimentalAPI: checkAbility (returning false)");
                std::map<std::string, std::string> result_fields;
                result_fields["result"] = "false";
                std::string data_json = BuildJsonObject(result_fields);
                SendApiCallbackResult(user_data, 0, "", data_json);
                return 0;
            } else if (!operation.empty()) {
                // Unknown operation - log and return success (to avoid breaking the app)
                V2TIM_LOG(kInfo, "[dart_compat] DartCallExperimentalAPI: Unknown operation '{}' (returning success)", operation);
                SendApiCallbackResult(user_data, 0, "");
                return 0;
            } else {
                // No operation specified - return error
                V2TIM_LOG(kError, "[dart_compat] DartCallExperimentalAPI: No operation specified");
                SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "No operation specified");
                return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
            }
        } catch (const std::exception& e) {
            // Safely get exception message
            const char* what_msg = e.what();
            if (!what_msg) {
                what_msg = "Unknown exception (e.what() returned null)";
            }
            V2TIM_LOG(kError, "[dart_compat] DartCallExperimentalAPI: Exception: {}", what_msg);
            // Safely construct error message
            std::string error_msg = "Exception: ";
            error_msg += what_msg;
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, error_msg);
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        } catch (...) {
            V2TIM_LOG(kError, "[dart_compat] DartCallExperimentalAPI: Unknown exception");
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_INVALID_PARAMETERS, "Unknown exception");
            return V2TIMErrorCode::ERR_INVALID_PARAMETERS;
        }
    }
    
    // ============================================================================
    // Explicit "not supported on Tox" stubs
    // ============================================================================
    //
    // These four symbols are declared AND called by the patched Tencent SDK
    // adapter, but have no meaning on a Tox P2P backend (there is no push
    // gateway, no app-lifecycle server session, and no cloud translation /
    // speech-to-text service). Until 2026-08-08 they were simply absent.
    //
    // Absence is the worst of the three options. `_lookup` in
    // native_imsdk_bindings_generated.dart is `late final`, so nothing fails at
    // startup: the FIRST call throws `ArgumentError: Failed to lookup symbol`
    // out of the FFI trampoline, which is not the error shape any caller
    // handles — the Future completes with an unexpected error type and the
    // feature dies silently. Note toxee registers the two plugins that reach
    // DartTranslateText / DartConvertVoiceToText (tencent_cloud_chat_text_translate
    // and tencent_cloud_chat_sound_to_text, wired in HomePage).
    //
    // So: define them, and report the failure through the NORMAL async callback
    // contract with ERR_SDK_INTERFACE_NOT_SUPPORT. Callers already handle a
    // non-zero code + message. This follows the precedent DartCallExperimentalAPI
    // set above ("we need to implement the function to avoid symbol lookup
    // errors"). If any of these ever gains a real Tox-side implementation,
    // replace the body — the ABI is already correct.

    // Signature: int DartSetOfflinePushToken(Pointer<Char> json_token, Pointer<Void> user_data)
    int DartSetOfflinePushToken(const char* json_token, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartSetOfflinePushToken: not supported on Tox");
        (void)json_token;
        if (user_data) {
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERFACE_NOT_SUPPORT,
                                  "Offline push is not supported on the Tox backend");
        }
        return 0; // request accepted; outcome delivered via the callback
    }

    // Signature: int DartDoForeground(Pointer<Void> user_data)
    int DartDoForeground(void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartDoForeground: no-op on Tox");
        if (user_data) {
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERFACE_NOT_SUPPORT,
                                  "Foreground/background push state is not supported on the Tox backend");
        }
        return 0;
    }

    // Signature: int DartTranslateText(Pointer<Char> json_texts, Pointer<Char> source_language,
    //                                  Pointer<Char> target_language, Pointer<Void> user_data)
    int DartTranslateText(const char* json_texts, const char* source_language,
                          const char* target_language, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartTranslateText: not supported on Tox");
        (void)json_texts;
        (void)source_language;
        (void)target_language;
        if (user_data) {
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERFACE_NOT_SUPPORT,
                                  "Text translation requires a cloud service and is not available on the Tox backend");
        }
        return 0;
    }

    // Signature: int DartConvertVoiceToText(Pointer<Char> msg_id, Pointer<Char> language, Pointer<Void> user_data)
    int DartConvertVoiceToText(const char* msg_id, const char* language, void* user_data) {
        V2TIM_LOG(kInfo, "[dart_compat] DartConvertVoiceToText: not supported on Tox");
        (void)msg_id;
        (void)language;
        if (user_data) {
            SendApiCallbackResult(user_data, V2TIMErrorCode::ERR_SDK_INTERFACE_NOT_SUPPORT,
                                  "Speech-to-text requires a cloud service and is not available on the Tox backend");
        }
        return 0;
    }

} // extern "C"

