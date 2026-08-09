// SDK Management and Authentication Functions
// Extracted from dart_compat_layer.cpp for modularization
#include "dart_compat_internal.h"

extern "C" {
    // DartInitSDK: Initialize SDK
    // Signature: int DartInitSDK(uint64_t sdk_app_id, Pointer<Char> json_sdk_config)
    // Note: Dart native function uses ffi.Uint64, so we use uint64_t to match
    int DartInitSDK(uint64_t sdk_app_id, const char* json_sdk_config) {
        // Parse JSON config
        std::string config_str = json_sdk_config ? std::string(json_sdk_config) : "{}";
        std::map<std::string, std::string> config = ParseJsonString(config_str);
        
        // Create V2TIMSDKConfig
        V2TIMSDKConfig sdk_config;
        
        // Parse config fields from JSON
        // Expected fields: sdk_config_config_file_path, sdk_config_log_file_path, sdk_config_api_type, etc.
        std::string init_path = ExtractJsonValue(config_str, "sdk_config_config_file_path");
        std::string log_path = ExtractJsonValue(config_str, "sdk_config_log_file_path");
        
        if (!init_path.empty()) {
            sdk_config.initPath = V2TIMString(init_path.c_str());
        }
        if (!log_path.empty()) {
            sdk_config.logPath = V2TIMString(log_path.c_str());
        }
        
        // Set log level (default to DEBUG) - use silent=true as this field is optional
        int log_level = ExtractJsonInt(config_str, "sdk_config_log_level", 3, true); // 3 = V2TIM_LOG_DEBUG
        sdk_config.logLevel = static_cast<V2TIMLogLevel>(log_level);
        
        // logListener is optional, leave as nullptr for now
        sdk_config.logListener = nullptr;
        
        // Initialize SDK
        // Note: V2TIMManager::InitSDK expects uint32_t, but Dart native function uses uint64_t
        // Convert uint64_t to uint32_t (SDK app IDs are typically within 32-bit range)
        uint32_t sdk_app_id_32 = static_cast<uint32_t>(sdk_app_id);
        bool result = SafeGetV2TIMManager()->InitSDK(sdk_app_id_32, sdk_config);
        
        return result ? 0 : 1;
    }
    
    // DartUnitSDK: Uninitialize SDK
    // Signature: int DartUnitSDK()
    int DartUnitSDK() {
        SafeGetV2TIMManager()->UnInitSDK();
        return 0; // TIM_SUCC
    }
    
    // DartGetSDKVersion: Get SDK version
    // Signature: Pointer<Char> DartGetSDKVersion()
    const char* DartGetSDKVersion() {
        V2TIMString version = SafeGetV2TIMManager()->GetVersion();
        static std::string version_str = version.CString();
        return version_str.c_str();
    }
    
    // DartGetServerTime: Get server time
    // Signature: Uint64 DartGetServerTime()
    // ABI note: the binding declares a Uint64 return. Returning `int` here
    // truncated the int64 timestamp to 32 bits — the high half of the value the
    // caller read was whatever the register happened to hold, and even the low
    // half overflows a signed 32-bit second count in 2038 (immediately, for a
    // millisecond count). Return the full width.
    uint64_t DartGetServerTime() {
        int64_t server_time = SafeGetV2TIMManager()->GetServerTime();
        return static_cast<uint64_t>(server_time);
    }
    
    // DartSetConfig: Set SDK config
    // Signature: int DartSetConfig(Pointer<Char> json_config, Pointer<Void> user_data)
    int DartSetConfig(const char* json_config, void* user_data) {
        if (!json_config) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        // Parse JSON config
        std::string config_str = json_config;
        std::map<std::string, std::string> config = ParseJsonString(config_str);
        
        // Expected fields: set_config_log_level, set_config_callback_log_level, set_config_is_log_output_console
        int log_level = ExtractJsonInt(config_str, "set_config_log_level", -1);
        int callback_log_level = ExtractJsonInt(config_str, "set_config_callback_log_level", -1);
        bool is_log_output_console = ExtractJsonBool(config_str, "set_config_is_log_output_console", true);
        
        // TODO: Apply config to SDK
        // Note: V2TIMManager doesn't have a direct SetConfig method
        // Config is typically set during InitSDK
        // For now, we'll just acknowledge the config request
        
        SendApiCallbackResult(user_data, 0, "");
        return 0; // TIM_SUCC
    }
    
    // DartLogin: Login
    // Signature: int DartLogin(Pointer<Char> user_id, Pointer<Char> user_sig, Pointer<Void> user_data)
    int DartLogin(const char* user_id, const char* user_sig, void* user_data) {
        if (!user_id || !user_sig) {
            SendApiCallbackResult(user_data, ERR_INVALID_PARAMETERS, "Invalid parameters");
            return 1; // Error
        }
        
        std::string user_id_str = CStringToString(user_id);
        std::string user_sig_str = CStringToString(user_sig);
        
        // Use SafeGetV2TIMManager() to get the current instance (for multi-instance support)
        V2TIMManager* manager = SafeGetV2TIMManager();
        if (!manager) {
            SendApiCallbackResult(user_data, ERR_SDK_NOT_INITIALIZED, "V2TIMManager not available");
            return 1; // Error
        }
        
        // Call V2TIM Login (async) on the current instance
        manager->Login(
            V2TIMString(user_id_str.c_str()),
            V2TIMString(user_sig_str.c_str()),
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
    
    // DartLogout: Logout
    // Signature: int DartLogout(Pointer<Void> user_data)
    int DartLogout(void* user_data) {
        
        // Call V2TIM Logout (async)
        SafeGetV2TIMManager()->Logout(
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
    
    // DartGetLoginUserID: Get login user ID
    // Signature: Pointer<Char> DartGetLoginUserID()
    // Note: Returned string must remain valid until next call
    const char* DartGetLoginUserID() {
        // Use SafeGetV2TIMManager() for multi-instance support
        V2TIMManager* manager = SafeGetV2TIMManager();
        if (!manager) {
            static std::string empty_str;
            empty_str = "";
            return empty_str.c_str();
        }
        V2TIMString user_id = manager->GetLoginUser();
        static std::string user_id_str;
        user_id_str = user_id.CString();
        V2TIM_LOG(kInfo, "[DEBUG] DartGetLoginUserID: user_id.length()={}", user_id.Length());
        if (user_id.Length() > 0) {
            V2TIM_LOG(kInfo, "[DEBUG] DartGetLoginUserID: user_id (first 20 chars)={}", user_id_str.substr(0, 20));
        }
        return user_id_str.c_str();
    }
}


