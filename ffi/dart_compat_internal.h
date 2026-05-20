// Internal shared declarations for dart_compat_layer modules
#pragma once

#include "dart_compat_layer.h"
#include "callback_bridge.h"
#include "json_parser.h"
#include <V2TIMManager.h>
#include <V2TIMListener.h>
#include <V2TIMFriendshipManager.h>
#include <V2TIMMessageManager.h>
#include <V2TIMConversationManager.h>
#include <V2TIMGroupManager.h>
#include <V2TIMSignalingManager.h>
#include <V2TIMCommunityManager.h>
#include <V2TIMOfflinePushManager.h>
#include <V2TIMCallback.h>
#include <V2TIMString.h>
#include <V2TIMMessage.h>
#include <V2TIMCommon.h>
#include <V2TIMBuffer.h>
#include <V2TIMErrorCode.h>
#include "V2TIMLog.h"
#include <mutex>
#include <map>
#include <string>
#include <vector>
#include <sstream>
#include <iomanip>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <memory>
#include <exception>
#include <stdexcept>

// Forward declarations for listener implementations
class DartSDKListenerImpl;
class DartAdvancedMsgListenerImpl;
class DartConversationListenerImpl;
class DartGroupListenerImpl;
class DartFriendshipListenerImpl;
class DartSignalingListenerImpl;
class DartCommunityListenerImpl;

// Forward declarations for callback class implementations
// Full definitions are in dart_compat_callbacks.cpp and dart_compat_callbacks.h
// Note: dart_compat_callbacks.h is included after utility function declarations
// to avoid circular dependency
class DartCallback;
class DartSendCallback;
class DartMessageVectorCallback;
class DartRevokeMessageCallback;
class DartFriendInfoVectorCallback;
class DartConversationResultCallback;
class DartStringCallback;
class DartGroupInfoVectorCallback;
class DartConversationOperationResultVectorCallback;
class DartFriendOperationResultCallback;
class DartFriendOperationResultVectorCallback;
class DartFriendInfoResultVectorCallback;
class DartMessageCompleteCallback;
class DartMessageSearchResultCallback;

// Per-instance listener storage (extern declarations)
// Note: These are now maps keyed by instance_id, not single global instances
extern std::map<int64_t, DartSDKListenerImpl*> g_sdk_listeners;
extern std::map<int64_t, DartAdvancedMsgListenerImpl*> g_advanced_msg_listeners;
extern std::map<int64_t, DartConversationListenerImpl*> g_conversation_listeners;
extern std::map<int64_t, DartGroupListenerImpl*> g_group_listeners;
extern std::map<int64_t, DartFriendshipListenerImpl*> g_friendship_listeners;
extern std::map<int64_t, DartSignalingListenerImpl*> g_signaling_listeners;
extern std::map<int64_t, DartCommunityListenerImpl*> g_community_listeners;
extern std::mutex g_listeners_mutex;

// Helper function to cleanup listeners for a specific instance
extern void CleanupInstanceListeners(int64_t instance_id);

// Receiver instance override: when set (e.g. in file recv callback), OnRecvNewMessage uses this
// instead of GetInstanceIdForListener so the message is routed to the correct receiver instance.
// Thread-local; set before NotifyAdvancedListenersReceivedMessage, cleared after.
int64_t GetReceiverInstanceOverride(void);
void SetReceiverInstanceOverride(int64_t id);
void ClearReceiverInstanceOverride(void);

// Global callback user_data storage (extern declarations)
// Key: (instance_id, callback_name) for per-instance storage
extern std::map<std::pair<int64_t, std::string>, void*> g_callback_user_data;
extern std::mutex g_callback_user_data_mutex;

// Utility functions (implemented in dart_compat_utils.cpp)
void StoreCallbackUserData(int64_t instance_id, const std::string& callback_name, void* user_data);
void* GetCallbackUserData(int64_t instance_id, const std::string& callback_name);
std::string UserDataToString(void* user_data);
V2TIMManager* SafeGetV2TIMManager();
std::string CStringToString(const char* str);
void SendApiCallbackResultWithString(const std::string& user_data_str, int code, const std::string& desc, const std::string& data_json = "");
void SendApiCallbackResult(void* user_data, int code, const std::string& desc, const std::string& data_json = "");
std::map<std::string, std::string> ParseJsonConfig(const char* json_str);
// SafeGetCString is deprecated - use .CString() directly (it has built-in protection)
std::string SafeGetCString(const V2TIMString& str);  // Kept for backward compatibility
std::string ConversationVectorToJson(const V2TIMConversationVector& conversations);

// Per-instance listener management functions (implemented in dart_compat_utils.cpp)
DartSDKListenerImpl* GetOrCreateSDKListener();
DartAdvancedMsgListenerImpl* GetOrCreateAdvancedMsgListener();
DartConversationListenerImpl* GetOrCreateConversationListener();
DartGroupListenerImpl* GetOrCreateGroupListener();
DartFriendshipListenerImpl* GetOrCreateFriendshipListener();
DartSignalingListenerImpl* GetOrCreateSignalingListener();
DartCommunityListenerImpl* GetOrCreateCommunityListener();

// Get current instance's Friendship listener (returns nullptr if not found)
// This is used by V2TIMManagerImpl::HandleFriendRequest to notify only the current instance's listener
DartFriendshipListenerImpl* GetCurrentInstanceFriendshipListener();

// Get Friendship listener for a specific V2TIMManagerImpl instance
// This is used by V2TIMManagerImpl::HandleFriendRequest to notify only the current instance's listener
class V2TIMManagerImpl;
DartFriendshipListenerImpl* GetFriendshipListenerForManager(V2TIMManagerImpl* manager);

// Get or create Friendship listener for a specific instance_id
DartFriendshipListenerImpl* GetOrCreateFriendshipListenerForInstance(int64_t instance_id);

// Register a Dart friendship listener with the instance's friendship manager (R-06: pass manager)
void RegisterFriendshipListenerWithManager(DartFriendshipListenerImpl* listener, V2TIMManagerImpl* manager);

// Get or create Group listener for a specific instance_id (used when registering with all instances)
DartGroupListenerImpl* GetOrCreateGroupListenerForInstance(int64_t instance_id);

// Replay previously-registered listener callbacks on a newly-created test instance.
// Called from create_test_instance_ex after a new test instance finishes InitSDK so that
// listeners which were registered before this instance existed (via the Tencent SDK's
// singleton-guarded initSDK path) are also wired up here. Without this, only the first
// node's V2TIMManagerImpl receives group/friendship callbacks and multi-node tests
// time out waiting for events on subsequent nodes. See the doc comment in
// dart_compat_listeners.cpp for the full rationale.
void ReplayListenersForNewInstance(int64_t instance_id, V2TIMManagerImpl* manager);

// Iterate all (instance_id, V2TIMManagerImpl*) pairs. Implemented in tim2tox_ffi.cpp.
// Used to register group/friendship listeners with every instance when addGroupListener is called.
extern "C" void Tim2ToxFfiForEachInstanceManager(void (*cb)(int64_t id, void* manager, void* user), void* user);

// Helper function to notify friend application list added
// This allows V2TIMManagerImpl to call OnFriendApplicationListAdded without including the full class definition
// Forward declaration for V2TIMFriendApplicationVector (it's a typedef, but we can use void* to avoid including headers)
void NotifyFriendApplicationListAddedToListener(DartFriendshipListenerImpl* listener, const void* applications_ptr);

// Notify friendship listener of friend info changed (avoids incomplete type in V2TIMManagerImpl.cpp)
void NotifyFriendInfoChangedToListener(DartFriendshipListenerImpl* listener, const void* friendInfoList_ptr);

// Conversation ID conversion utilities
// Build full conversationID from base ID and type (for conversation-related functions)
// Input: base_conv_id (e.g., "75C785AF..."), conv_type (1=C2C, 2=GROUP)
// Output: full conversationID (e.g., "c2c_75C785AF...")
std::string BuildFullConversationID(const char* base_conv_id, unsigned int conv_type);

// Extract base ID from conversationID (remove prefix if present, for message-related functions)
// Input: conv_id (may be "c2c_75C785AF..." or "75C785AF...")
// Output: base ID (e.g., "75C785AF...")
std::string ExtractBaseConversationID(const char* conv_id);

// Include callback class definitions after utility function declarations
// This ensures SendApiCallbackResult and BuildJsonObject are declared before use
#include "dart_compat_callbacks.h"

