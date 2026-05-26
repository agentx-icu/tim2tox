#include "V2TIMManagerImpl.h"
#include "PathUtils.h"
#include "V2TIMUtils.h"
#include "version.h"
#include <V2TIMErrorCode.h>
#include "ToxManager.h"
#include "tox.h"
#include "tox_options.h"
#include "toxcore/mono_time.h"
#include "ToxUtil.h"
#include <cstdlib>
#include <ctime>
#include <cstdio>
#include <cstring>
#include <unordered_map>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <atomic>
#include <sstream>
#include <iomanip>
#include "V2TIMLog.h" // Updated include
#include <vector> // For buffer operations
#include <algorithm> // For std::all_of

// Global group-id counter so "tox_0","tox_1",... are unique across instances.
// Avoids cross-instance collision when one instance's "tox_0" is used by
// another instance's JoinGroup (e.g. "Join private group" test).
static std::atomic<uint64_t> g_next_group_id_global{0};

// Forward declaration for GetTestInstanceOptions (defined in tim2tox_ffi.cpp with extern "C" linkage)
extern "C" bool GetTestInstanceOptions(int64_t instance_id, int* out_local_discovery, int* out_ipv6);

// Forward declaration for the process-global virtual-clock callback
// (defined in tim2tox_ffi.cpp). Used when test_mode_ is enabled to make
// mono_time read from the auto_tests harness's virtual clock instead of
// the wall clock.
extern "C" uint64_t tim2tox_virtual_time_cb(void* user_data);

// Forward declarations for instance management functions (defined in tim2tox_ffi.cpp as C++ functions)
// Note: These are NOT extern "C" because they are defined as regular C++ functions in tim2tox_ffi.cpp
extern int64_t GetCurrentInstanceId();
extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
// Receiver instance override: set before NotifyAdvancedListenersReceivedMessage so OnRecvNewMessage routes to correct instance
extern void SetReceiverInstanceOverride(int64_t id);
extern void ClearReceiverInstanceOverride(void);
#include <string> // For std::string
#include <filesystem>
#include <sys/stat.h>
#include <sys/types.h>
#ifndef _WIN32
#include <unistd.h>
#endif
#include <fstream>
#include <thread>
#include <system_error> // For std::system_error
#include <stdexcept> // For std::runtime_error
#include "MessageReplyUtil.h"
#include "MergerMessageUtil.h"
#include "RevokeMessageUtil.h"
#include "V2TIMMessageManagerImpl.h"
#include "V2TIMGroupManagerImpl.h"
#include "V2TIMConversationManagerImpl.h"
#include "V2TIMCommunityManagerImpl.h"
#include "V2TIMFriendshipManagerImpl.h"

#ifdef BUILD_TOXAV
#include "ToxAVManager.h"
#include "toxav/toxav.h"
#endif

// Forward declaration for FFI functions
// NOTE: All tim2tox_ffi_* functions are defined in extern "C" blocks in tim2tox_ffi.cpp
// They MUST be declared here with extern "C" to avoid C++ name mangling issues
extern "C" {
int tim2tox_ffi_save_friend_nickname(const char* friend_id, const char* nickname);
int tim2tox_ffi_save_friend_status_message(const char* friend_id, const char* status_message);
int tim2tox_ffi_irc_forward_tox_message(const char* group_id, const char* sender, const char* message);
int tim2tox_ffi_set_current_instance(int64_t instance_handle);
// Note: GetCurrentInstanceId is declared above at line 27, not in extern "C" block
}

// Forward declaration for Dart listener (to avoid circular dependency)
class DartFriendshipListenerImpl;
extern DartFriendshipListenerImpl* GetCurrentInstanceFriendshipListener();
extern DartFriendshipListenerImpl* GetFriendshipListenerForManager(V2TIMManagerImpl* manager);
extern DartFriendshipListenerImpl* GetOrCreateFriendshipListenerForInstance(int64_t instance_id);
extern void RegisterFriendshipListenerWithManager(DartFriendshipListenerImpl* listener, V2TIMManagerImpl* manager);
extern void NotifyFriendInfoChangedToListener(DartFriendshipListenerImpl* listener, const void* friendInfoList_ptr);

namespace {
void NotSupported(V2TIMCallback* callback, const char* api_name) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, api_name);
}
template <typename T>
void NotSupportedValue(V2TIMValueCallback<T>* callback, const char* api_name) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, api_name);
}
}  // namespace

#ifdef BUILD_TOXAV
// Static callback function for AV conference audio data
// This is called when audio data is received from peers in an AV conference
static void HandleAVConferenceAudio(void* tox_ptr, Tox_Conference_Number conference_number,
                                    Tox_Conference_Peer_Number peer_number,
                                    const int16_t* pcm, uint32_t samples,
                                    uint8_t channels, uint32_t sample_rate,
                                    void* userdata) {
    // userdata points to V2TIMManagerImpl instance
    V2TIMManagerImpl* manager_impl = static_cast<V2TIMManagerImpl*>(userdata);
    if (!manager_impl) {
        return;
    }
    
    // Try to find the groupID for this conference_number
    V2TIMString groupID;
    manager_impl->GetGroupIDFromGroupNumber(static_cast<Tox_Group_Number>(conference_number), groupID);
    
    // Audio data received from a peer in AV conference
    // For now, we just log it. In the future, this could be forwarded to Dart layer
    if (!groupID.Empty()) {
        V2TIM_LOG(kInfo, "[AVConference-Audio] Received audio from groupID={}, conference_number={}, peer_number={}, samples={}, channels={}, sample_rate={}",
                 groupID.CString(), conference_number, peer_number, samples, channels, sample_rate);
    } else {
        V2TIM_LOG(kInfo, "[AVConference-Audio] Received audio from conference_number={} (groupID not found), peer_number={}, samples={}, channels={}, sample_rate={}",
                 conference_number, peer_number, samples, channels, sample_rate);
    }
    // TODO: Forward audio data to Dart layer if needed
}
#endif // BUILD_TOXAV

// Forward declaration for helper function to notify friend application list added
// This avoids including the full DartFriendshipListenerImpl definition
extern void NotifyFriendApplicationListAddedToListener(DartFriendshipListenerImpl* listener, const void* applications_ptr);

// Include implementation headers for sub-managers
#include "V2TIMMessageManagerImpl.h"
#include "V2TIMGroupManagerImpl.h"
#include "V2TIMCommunityManagerImpl.h"
#include "V2TIMConversationManagerImpl.h"
#include "V2TIMFriendshipManagerImpl.h"
#include "V2TIMSignalingManagerImpl.h"

// V2TIMManager::GetInstance() 实现，转发到 V2TIMManagerImpl
V2TIMManager* V2TIMManager::GetInstance() {
    return V2TIMManagerImpl::GetInstance();
}

// Default instance (for backward compatibility)
static V2TIMManagerImpl* g_default_instance = nullptr;
static std::mutex g_default_instance_mutex;

V2TIMManagerImpl* V2TIMManagerImpl::GetInstance() {
    std::lock_guard<std::mutex> lock(g_default_instance_mutex);
    if (!g_default_instance) {
        g_default_instance = new V2TIMManagerImpl();
    }
    return g_default_instance;
}

// Process-global default test_mode flag. New V2TIMManagerImpl instances
// inherit this in their constructor, so tim2tox_ffi_set_default_test_mode(1)
// can be called BEFORE the test creates any instance to ensure event_thread
// is never spawned by InitSDK.
std::atomic<bool> g_default_test_mode{false};

// Constructor (now public for multi-instance support)
V2TIMManagerImpl::V2TIMManagerImpl()
#ifdef BUILD_TOXAV
    : toxav_manager_(nullptr, &ToxAVManager::Destroy), running_(true), next_group_id_counter_(0)
#else
    : running_(true), next_group_id_counter_(0)
#endif
{
    // running_ is initialized to true via member initializer list (atomic)
    // tox_manager_ will be created in InitSDK
    // Inherit process-global default test_mode (set by FFI before instance creation).
    test_mode_.store(g_default_test_mode.load(std::memory_order_acquire),
                     std::memory_order_release);
}

V2TIMManagerImpl::~V2TIMManagerImpl() {
    // Stop background tasks first so no detach'd thread holds raw this
    try {
        StopBackgroundTasks();
    } catch (...) {
    }
    // Signal event thread to stop and join it without busy-wait polling.
    try {
        running_.store(false, std::memory_order_release);
        task_cv_.notify_all();
        if (event_thread_.joinable()) {
            event_thread_.join();
        }
    } catch (const std::system_error&) {
        // Thread may have already exited or mutex is invalid - ignore.
    } catch (...) {
        // Swallow any exception at process exit.
    }
}

void V2TIMManagerImpl::StopBackgroundTasks() {
    refresh_stop_requested_.store(true, std::memory_order_release);
    rejoin_stop_requested_.store(true, std::memory_order_release);
    if (refresh_task_.joinable()) {
        refresh_task_.join();
    }
    refresh_task_running_.store(false, std::memory_order_release);
    if (rejoin_task_.joinable()) {
        rejoin_task_.join();
    }
}

// SDK Listener methods
void V2TIMManagerImpl::AddSDKListener(V2TIMSDKListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    sdk_listeners_.insert(listener);
}

void V2TIMManagerImpl::RemoveSDKListener(V2TIMSDKListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    sdk_listeners_.erase(listener);
}

// SDK initialization and shutdown
bool V2TIMManagerImpl::InitSDK(uint32_t sdkAppID, const V2TIMSDKConfig& config) {
    int64_t this_instance_id = GetInstanceIdFromManager(this);
    if (tox_manager_) {
        return true;
    }

    V2TIM_LOG(kInfo, "[InitSDK] creating new ToxManager instance for this={} (instance_id={})",
              (void*)this, (long long)this_instance_id);
    tox_manager_ = std::make_unique<ToxManager>();
    V2TIM_LOG(kInfo, "[InitSDK] Created ToxManager={} for this={} (instance_id={})",
              (void*)tox_manager_.get(), (void*)this, (long long)this_instance_id);
#ifdef BUILD_TOXAV
    toxav_manager_.reset(new ToxAVManager());
    V2TIM_LOG(kInfo, "[InitSDK] Created ToxAVManager={} for this={} (instance_id={})",
              (void*)toxav_manager_.get(), (void*)this, (long long)this_instance_id);
#endif
    V2TIM_LOG(kInfo, "[InitSDK] Step 1: Computing save path...");
    // Compute save path using config.initPath if provided; otherwise platform default
    std::filesystem::path save_dir = config.initPath.Empty()
        ? tim2tox::path::GetDefaultDataDir()
        : std::filesystem::path(config.initPath.CString());
    V2TIM_LOG(kInfo, "[InitSDK] Using data dir: {}", save_dir.string());

    std::string mkdir_err;
    if (!tim2tox::path::EnsureDirectoryExists(save_dir, &mkdir_err)) {
        V2TIM_LOG(kError, "[InitSDK] Failed to create data dir: {}", mkdir_err);
        return false;
    }

    int64_t instance_id = GetInstanceIdFromManager(this);
    std::string save_path = tim2tox::path::BuildProfilePath(save_dir, instance_id).string();
    V2TIM_LOG(kInfo, "[InitSDK] Save path: {}", save_path);
    save_path_ = save_path;

    V2TIM_LOG(kInfo, "[InitSDK] Step 4: Checking for saved profile...");
    bool loaded = false;
    {
        std::ifstream f(save_path, std::ios::binary);
        loaded = f.good();
        V2TIM_LOG(kInfo, "[InitSDK] Profile loaded check: {}", loaded ? "true" : "false");
    }
    // Test-instance reload fallback: when auto_tests do unInitSDK/initSDK in
    // sequence, the new test instance gets a fresh instance_id, so the
    // BuildProfilePath above yields a `tox_profile_<new_id>.tox` path that
    // doesn't exist on disk. The previous instance saved its profile under
    // `tox_profile_<old_id>.tox` in the same directory. Tests use one
    // instance per init_path (per-userId subdir), so we can safely fall back
    // to *any* `tox_profile_*.tox` in the directory. Production (instance_id
    // 0 with the stable `tox_profile.tox` name) never enters this branch.
    if (!loaded && instance_id != 0) {
        try {
            std::filesystem::path dir(save_dir);
            std::error_code ec;
            std::filesystem::path fallback;
            std::filesystem::directory_iterator it(dir, ec);
            if (!ec) {
                for (const auto& entry : it) {
                    const auto& p = entry.path();
                    const auto fn = p.filename().string();
                    if (fn.rfind("tox_profile", 0) == 0 &&
                        p.extension() == ".tox" &&
                        fn.find(".corrupted") == std::string::npos) {
                        fallback = p;
                        break;
                    }
                }
            }
            if (!fallback.empty()) {
                V2TIM_LOG(kInfo,
                    "[InitSDK] Reload fallback: instance-id-keyed profile missing; loading sibling {}",
                    fallback.string());
                save_path = fallback.string();
                save_path_ = save_path;
                std::ifstream f2(save_path, std::ios::binary);
                loaded = f2.good();
            }
        } catch (const std::exception& e) {
            V2TIM_LOG(kWarning, "[InitSDK] Reload fallback failed: {}", e.what());
        }
    }
    V2TIM_LOG(kInfo, "[InitSDK] Step 5: Getting test instance options...");
    V2TIM_LOG(kInfo, "[InitSDK] About to call GetTestInstanceOptions with instance_id={}", (long long)this_instance_id);
    int local_discovery = 1;
    int ipv6 = 1;
    bool has_options = GetTestInstanceOptions(this_instance_id, &local_discovery, &ipv6);
    V2TIM_LOG(kInfo, "[InitSDK] GetTestInstanceOptions returned: has_options={}, local_discovery={}, ipv6={}",
              has_options ? "true" : "false", local_discovery, ipv6);
    V2TIM_LOG(kInfo, "[InitSDK] Test options: has_options={}, local_discovery={}, ipv6={}",
              has_options ? "true" : "false", local_discovery, ipv6);

    V2TIM_LOG(kInfo, "[InitSDK] Step 6: Creating Tox_Options...");
    Tox_Options* tox_options = nullptr;
    Tox_Err_Options_New opt_err;
    V2TIM_LOG(kInfo, "[InitSDK] About to call tox_options_new...");
    tox_options = tox_options_new(&opt_err);
    V2TIM_LOG(kInfo, "[InitSDK] tox_options_new returned: options={}, err={}", (void*)tox_options, opt_err);
    if (tox_options && opt_err == TOX_ERR_OPTIONS_NEW_OK) {
        tox_options_default(tox_options);
        tox_options_set_udp_enabled(tox_options, true);
        tox_options_set_hole_punching_enabled(tox_options, true);
        tox_options_set_local_discovery_enabled(tox_options, has_options ? (local_discovery != 0) : true);
        tox_options_set_dht_announcements_enabled(tox_options, true);
        tox_options_set_ipv6_enabled(tox_options, has_options ? (ipv6 != 0) : true);
        V2TIM_LOG(kInfo, "[InitSDK] Using tox options: udp_enabled=1, hole_punching_enabled=1, local_discovery_enabled={}, dht_announcements_enabled=1, ipv6_enabled={}",
                  has_options ? local_discovery : 1, has_options ? ipv6 : 1);
    } else {
        V2TIM_LOG(kError, "[InitSDK] Failed to create Tox_Options, using defaults");
        tox_options = nullptr;
    }

    V2TIM_LOG(kInfo, "[InitSDK] Step 7: Checking loaded status...");
    
    // CRITICAL: Set running_ flag BEFORE calling tox_manager_->initialize()
    // This ensures that connection status callbacks triggered during initialization
    // can be properly handled (they check IsRunning() before processing)
    // Note: We set it early to handle callbacks that may be triggered during initialize()
    running_.store(true, std::memory_order_release);
    // Register group message callbacks BEFORE initialize/loadFrom so ToxManager::initialize()
    // can register them on the new tox instance. Otherwise group_private_message may never fire.
    tox_manager_->setGroupMessageGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id) {
            this->HandleGroupMessageGroup(group_number, peer_id, type, message, length, message_id);
        }
    );
    tox_manager_->setGroupPrivateMessageGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id) {
            this->HandleGroupPrivateMessage(group_number, peer_id, type, message, length, message_id);
        }
    );
    
    if (loaded) {
        V2TIM_LOG(kInfo, "[InitSDK] Profile exists, loading from {}", save_path);
        if (!tox_manager_->loadFrom(save_path)) {
            V2TIM_LOG(kWarning, "[InitSDK] Profile load failed (encrypted or corrupted), creating new profile and backing up old file");
            std::string backup_path = save_path + ".corrupted";
            if (std::rename(save_path.c_str(), backup_path.c_str()) == 0) {
                V2TIM_LOG(kInfo, "[InitSDK] Backed up unloadable profile to {}", backup_path);
            } else {
                V2TIM_LOG(kWarning, "[InitSDK] Could not rename profile to backup, new profile will overwrite");
            }
            try {
                tox_manager_->initialize(tox_options);
                tox_manager_->saveTo(save_path);
            } catch (const std::runtime_error& e) {
                V2TIM_LOG(kError, "InitSDK: Tox initialization failed - {}", e.what());
                if (tox_options) tox_options_free(tox_options);
                return false;
            }
        }
    } else {
        try {
            tox_manager_->initialize(tox_options);
            tox_manager_->saveTo(save_path);
        } catch (const std::runtime_error& e) {
            V2TIM_LOG(kError, "InitSDK: Tox initialization failed - {}", e.what());
            if (tox_options) tox_options_free(tox_options);
            return false;
        }
    }

    if (tox_options) {
        tox_options_free(tox_options);
        tox_options = nullptr;
    }
    if (tox_options) {
        tox_options_free(tox_options);
    }
    V2TIM_LOG(kInfo, "InitSDK: after initialize");
    Tox* tox = tox_manager_->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "InitSDK: tox is null");
        return false;
    }

    // Test-mode hook: route mono_time off the virtual clock owned by tim2tox_ffi.cpp.
    // No-op for production callers (test_mode_ defaults to false).
    if (test_mode_.load(std::memory_order_acquire)) {
        if (tox->mono_time) {
            mono_time_set_current_time_callback(tox->mono_time, &tim2tox_virtual_time_cb, nullptr);
            fprintf(stdout, "InitSDK: test mode mono_time callback installed\n");
            fflush(stdout);
        } else {
            fprintf(stdout, "InitSDK: test mode requested but tox->mono_time is null; skipping\n");
            fflush(stdout);
        }
    }

    tox_manager_->setGroupMessageGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id) {
            this->HandleGroupMessageGroup(group_number, peer_id, type, message, length, message_id);
        }
    );
    tox_manager_->setGroupPrivateMessageGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id) {
            this->HandleGroupPrivateMessage(group_number, peer_id, type, message, length, message_id);
        }
    );
    fprintf(stdout, "[InitSDK] setGroupMessageGroupCallback and setGroupPrivateMessageGroupCallback registered for this=%p (instance_id=%lld)\n", 
            (void*)this, (long long)this_instance_id);
    fflush(stdout);
    tox_manager_->setGroupTopicCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* topic, size_t length) {
            this->HandleGroupTopic(group_number, peer_id, topic, length);
        }
    );
    tox_manager_->setGroupPeerNameGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* name, size_t length) {
            this->HandleGroupPeerNameGroup(group_number, peer_id, name, length);
        }
    );
    fprintf(stdout, "[InitSDK] Registering setGroupPeerJoinCallback for this=%p (instance_id=%lld)\n", 
            (void*)this, (long long)this_instance_id);
    fflush(stdout);
    tox_manager_->setGroupPeerJoinCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id) {
            // Note: GetCurrentInstanceId and GetInstanceIdFromManager are already declared at file scope (lines 27-28)
            int64_t current_instance_id = GetCurrentInstanceId();
            int64_t this_instance_id = GetInstanceIdFromManager(this);
            fprintf(stdout, "[V2TIMManagerImpl] GroupPeerJoinCallback triggered: instance_id=%lld, group_number=%u, peer_id=%u\n", 
                    (long long)current_instance_id, group_number, peer_id);
            fprintf(stdout, "[V2TIMManagerImpl] GroupPeerJoinCallback: this=%p, this_instance_id=%lld, current_instance_id=%lld\n", 
                    (void*)this, (long long)this_instance_id, (long long)current_instance_id);
            fprintf(stdout, "[V2TIMManagerImpl] GroupPeerJoinCallback: Lambda captured 'this'=%p, about to call HandleGroupPeerJoin\n", 
                    (void*)this);
            fflush(stdout);
            this->HandleGroupPeerJoin(group_number, peer_id);
        }
    );
    fprintf(stdout, "[InitSDK] setGroupPeerJoinCallback registered for this=%p (instance_id=%lld)\n", 
            (void*)this, (long long)this_instance_id);
    fflush(stdout);
    tox_manager_->setGroupPeerExitCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, Tox_Group_Exit_Type exit_type, const uint8_t* name, size_t name_length) {
            this->HandleGroupPeerExit(group_number, peer_id, exit_type, name, name_length);
        }
    );
    tox_manager_->setGroupModerationCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number source_peer_id, Tox_Group_Peer_Number target_peer_id, Tox_Group_Mod_Event mod_type) {
            this->HandleGroupModeration(group_number, source_peer_id, target_peer_id, mod_type);
        }
    );
    // CRITICAL: Before registering callbacks, query existing groups and conferences from Tox
    // and manually trigger HandleGroupSelfJoin/HandleConferenceSelfJoin for each to rebuild mappings.
    // This is necessary because callbacks are NOT triggered for groups/conferences
    // that are restored from savedata - they only trigger for newly joined ones.
    // By manually querying and processing existing groups/conferences, we ensure mappings are
    // rebuilt immediately after Tox initialization.
    {
        Tox* tox = tox_manager_->getTox();
        if (tox) {
            // Restore groups (new API)
            size_t group_count = tox_manager_->getGroupListSize();
            if (group_count > 0) {
                std::vector<Tox_Group_Number> group_list(group_count);
                tox_manager_->getGroupList(group_list.data(), group_count);
                for (Tox_Group_Number group_number : group_list) {
                    this->HandleGroupSelfJoin(group_number);
                }
            }
            // Restore conferences (old API) - they are automatically restored from savedata
            (void)tox_conference_get_chatlist_size(tox);
            // Conference mappings will be rebuilt in RejoinKnownGroups when known groups are synced
        }
    }
    
    // Register callback for future group joins (new groups will trigger this callback)
    tox_manager_->setGroupSelfJoinCallback(
        [this](Tox_Group_Number group_number) {
            this->HandleGroupSelfJoin(group_number);
        }
    );
    tox_manager_->setGroupJoinFailCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type) {
            this->HandleGroupJoinFail(group_number, fail_type);
        }
    );
    tox_manager_->setGroupPrivacyStateCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Privacy_State privacy_state) {
            this->HandleGroupPrivacyState(group_number, privacy_state);
        }
    );
    tox_manager_->setGroupVoiceStateCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Voice_State voice_state) {
            this->HandleGroupVoiceState(group_number, voice_state);
        }
    );
    tox_manager_->setGroupPeerStatusCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_USER_STATUS status) {
            this->HandleGroupPeerStatus(group_number, peer_id, status);
        }
    );
    
    // Register group invite handling: automatically accept invite and join group
    // NOTE: Register both new group API and old conference API for compatibility
    // Register new group API callback (tox_callback_group_invite)
    tox_manager_->setGroupInviteGroupCallback(
        [this](Tox_Friend_Number friend_number, const uint8_t* invite_data, size_t invite_data_length) {
            V2TIM_LOG(kInfo, "[GroupInvite] ========== Received group invite ==========");
            V2TIM_LOG(kInfo, "[GroupInvite] friend_number={}, invite_data_length={}", friend_number, invite_data_length);
            
            // Log first few bytes of invite_data for debugging
            if (invite_data && invite_data_length > 0) {
                std::ostringstream invite_hex;
                size_t bytes_to_log = std::min(invite_data_length, static_cast<size_t>(16));
                for (size_t i = 0; i < bytes_to_log; ++i) {
                    invite_hex << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(invite_data[i]);
                }
                V2TIM_LOG(kInfo, "[GroupInvite] invite_data (first {} bytes): {}", bytes_to_log, invite_hex.str());
            }
            
            // Get inviter's public key for onMemberInvited callback
            std::string inviterUserID;
            Tox* tox_for_inviter = GetToxManager()->getTox();
            if (tox_for_inviter) {
                uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox_friend_get_public_key(tox_for_inviter, friend_number, inviter_pubkey, nullptr)) {
                    inviterUserID = ToxUtil::tox_bytes_to_hex(inviter_pubkey, TOX_PUBLIC_KEY_SIZE);
                    V2TIM_LOG(kInfo, "[GroupInvite] Got inviter public key: {} (length={})", inviterUserID, inviterUserID.length());
                } else {
                    V2TIM_LOG(kWarning, "[GroupInvite] Failed to get inviter public key for friend_number={}", friend_number);
                }
            }
            
            // Generate a temporary groupID for this invite (before accepting)
            char gid[64];
            auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            snprintf(gid, sizeof(gid), "tox_inv_%u_%llu", friend_number, (unsigned long long)now_ms);
            V2TIMString tempGroupID(gid);
            
            // When auto-accept is disabled: store pending BEFORE notifying listeners, so that when
            // Dart's waitForCallback('onGroupInvited') returns and the test calls joinGroup, the
            // pending is already present on this instance (avoids 6017 "Pending invite not found").
            bool auto_accept_enabled = GetAutoAcceptGroupInvites();
            V2TIM_LOG(kInfo, "[GroupInvite] Auto-accept group invites setting: {}", auto_accept_enabled);
            if (!auto_accept_enabled) {
                V2TIM_LOG(kInfo, "[GroupInvite] Auto-accept is disabled, storing as pending invite before notifying");
                PendingInvite inv;
                inv.friend_number = friend_number;
                inv.cookie.assign(invite_data, invite_data + invite_data_length);
                inv.group_number = UINT32_MAX;  // Not yet accepted
                inv.inviter_userID = inviterUserID;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[tempGroupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite] Stored pending group invite as ID {} for manual join later", gid);
            }
            
            // Trigger onMemberInvited callback when invite is received (after pending is stored when !auto_accept)
            // This notifies listeners that we received an invitation
            // Note: We use temporary groupID here, and will trigger again with actual groupID in HandleGroupSelfJoin
            if (!inviterUserID.empty()) {
                V2TIM_LOG(kInfo, "[GroupInvite] Triggering onMemberInvited callback immediately: tempGroupID={}, inviter={}", gid, inviterUserID);
                fprintf(stdout, "[GroupInvite] Triggering onMemberInvited callback immediately: tempGroupID=%s, inviter=%s\n", gid, inviterUserID.c_str());
                fflush(stdout);
                
                // Build member list (contains self, as we are being invited)
                V2TIMGroupMemberInfoVector memberList;
                V2TIMGroupMemberInfo selfMember;
                // Get self public key
                uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox_for_inviter) {
                    tox_self_get_public_key(tox_for_inviter, self_pubkey);
                    std::string selfUserID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                    selfMember.userID = V2TIMString(selfUserID.c_str());
                    memberList.PushBack(selfMember);
                    V2TIM_LOG(kInfo, "[GroupInvite] Added self to member list: {}", selfUserID);
                }
                
                // Build opUser (inviter)
                V2TIMGroupMemberInfo opUser;
                opUser.userID = V2TIMString(inviterUserID.c_str());
                
                // Notify group listeners with temporary groupID
                std::vector<V2TIMGroupListener*> listeners_copy;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
                }
                
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        fprintf(stdout, "[GroupInvite] Calling OnMemberInvited immediately with tempGroupID=%s, inviter=%s, memberCount=%zu\n",
                                gid, inviterUserID.c_str(), memberList.Size());
                        fflush(stdout);
                        V2TIM_LOG(kInfo, "[GroupInvite] Calling OnMemberInvited immediately: tempGroupID={}, inviter={}, memberCount={}",
                                 gid, inviterUserID, memberList.Size());
                        listener->OnMemberInvited(tempGroupID, opUser, memberList);
                    }
                }
            }
            
            // If auto-accept is disabled, we already stored pending and notified; nothing more to do.
            if (!auto_accept_enabled) {
                return;
            }
            
            Tox* tox = GetToxManager()->getTox();
            if (!tox) {
                V2TIM_LOG(kError, "[GroupInvite] ERROR: Tox instance not available, cannot accept invite");
                return;
            }
            V2TIM_LOG(kInfo, "[GroupInvite] Tox instance available, proceeding with auto-accept");
            // tempGroupID already generated above
            V2TIM_LOG(kInfo, "[GroupInvite] Using temporary groupID: {}", gid);
            
            // Accept invite using tox_group_invite_accept
            std::string self_name = GetToxManager()->getName();
            if (self_name.empty()) {
                self_name = "User";
            }
            V2TIM_LOG(kInfo, "[GroupInvite] Using self_name: {} (length={})", self_name, self_name.length());
            
            V2TIM_LOG(kInfo, "[GroupInvite] Calling tox_group_invite_accept: friend_number={}, invite_data_length={}, self_name_length={}", 
                     friend_number, invite_data_length, self_name.length());
            
            Tox_Err_Group_Invite_Accept err_accept;
            Tox_Group_Number group_number = tox_group_invite_accept(
                tox,
                friend_number,
                invite_data, invite_data_length,
                reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
                nullptr, 0, // No password
                &err_accept
            );
            
            V2TIM_LOG(kInfo, "[GroupInvite] tox_group_invite_accept returned: group_number={}, err_accept={}", 
                     group_number, static_cast<int>(err_accept));
            
            if (err_accept != TOX_ERR_GROUP_INVITE_ACCEPT_OK || group_number == UINT32_MAX) {
                V2TIM_LOG(kError, "[GroupInvite] FAILED to accept group invite");
                V2TIM_LOG(kError, "[GroupInvite] Error code: {} (0=OK, 1=BAD_INVITE, 2=INIT_FAILED, 3=TOO_LONG, 4=EMPTY, 5=PASSWORD, 6=FRIEND_NOT_FOUND, 7=FAIL_SEND, 8=NULL)", 
                         static_cast<int>(err_accept));
                V2TIM_LOG(kError, "[GroupInvite] group_number={} (UINT32_MAX={})", group_number, UINT32_MAX);
                
                // Store as pending invite for manual join later
                PendingInvite inv;
                inv.friend_number = friend_number;
                inv.cookie.assign(invite_data, invite_data + invite_data_length);
                inv.group_number = UINT32_MAX;  // Not yet accepted
                inv.inviter_userID = inviterUserID;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[tempGroupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite] Stored pending group invite as ID {} for manual join later", gid);
                V2TIM_LOG(kInfo, "[GroupInvite] Pending invite stored: friend_number={}, cookie_size={}", 
                         inv.friend_number, inv.cookie.size());
                return;
            }
            
            V2TIM_LOG(kInfo, "[GroupInvite] ✅ Successfully accepted group invite");
            V2TIM_LOG(kInfo, "[GroupInvite] group_number={}, tempGroupID={}", group_number, gid);
            
            // Store temporary group mapping (will be updated to actual groupID in HandleGroupSelfJoin)
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_group_number_[tempGroupID] = group_number;
                group_number_to_group_id_[group_number] = tempGroupID;
                
                // Update pending invite with group_number
                auto it = pending_group_invites_.find(tempGroupID);
                if (it != pending_group_invites_.end()) {
                    it->second.group_number = group_number;
                    V2TIM_LOG(kInfo, "[GroupInvite] Updated pending invite with group_number={}", group_number);
                } else {
                    // Create new pending invite entry
                    PendingInvite inv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(invite_data, invite_data + invite_data_length);
                    inv.group_number = group_number;
                    inv.inviter_userID = inviterUserID;
                    pending_group_invites_[tempGroupID] = std::move(inv);
                    V2TIM_LOG(kInfo, "[GroupInvite] Created pending invite entry with group_number={}", group_number);
                }
                
                V2TIM_LOG(kInfo, "[GroupInvite] Stored temporary group mapping: tempGroupID={} <-> group_number={}", gid, group_number);
                V2TIM_LOG(kInfo, "[GroupInvite] Total groups in mapping: {}", group_id_to_group_number_.size());
            }
            
            // Get chat_id and store it for persistence
            V2TIM_LOG(kInfo, "[GroupInvite] Attempting to get chat_id for group_number={}", group_number);
            uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
            Tox_Err_Group_State_Query err_chat_id;
            bool got_chat_id = GetToxManager()->getGroupChatId(group_number, chat_id, &err_chat_id);
            V2TIM_LOG(kInfo, "[GroupInvite] getGroupChatId returned: got_chat_id={}, err_chat_id={}", 
                     got_chat_id, static_cast<int>(err_chat_id));
            
            if (got_chat_id && err_chat_id == TOX_ERR_GROUP_STATE_QUERY_OK) {
                // Convert to hex string
                std::ostringstream oss;
                for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                    oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
                }
                std::string chat_id_hex = oss.str();
                V2TIM_LOG(kInfo, "[GroupInvite] Retrieved chat_id (hex): {} (length={})", chat_id_hex, chat_id_hex.length());
                
                // Store chat_id via FFI for persistence (using tempGroupID for now, will be updated in HandleGroupSelfJoin)
                SetGroupChatIdInStorage(tempGroupID.CString(), chat_id_hex);
                int ffi_result = 1;
                V2TIM_LOG(kInfo, "[GroupInvite] SetGroupChatIdInStorage completed (1=success)", ffi_result);
                V2TIM_LOG(kInfo, "[GroupInvite] Stored chat_id for auto-joined group {}: {}", gid, chat_id_hex);
                
                // Store in memory mapping (using tempGroupID for now, will be updated in HandleGroupSelfJoin)
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    group_id_to_chat_id_[tempGroupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                    chat_id_to_group_id_[chat_id_hex] = tempGroupID;
                    V2TIM_LOG(kInfo, "[GroupInvite] Stored chat_id mapping: tempGroupID={} <-> chat_id={}", gid, chat_id_hex);
                    V2TIM_LOG(kInfo, "[GroupInvite] Total chat_id mappings: {}", group_id_to_chat_id_.size());
                }
            } else {
                V2TIM_LOG(kWarning, "[GroupInvite] ⚠️ Failed to get chat_id for group_number={}", group_number);
                V2TIM_LOG(kWarning, "[GroupInvite] Error details: got_chat_id={}, err_chat_id={} (0=OK, 1=GROUP_NOT_FOUND, 2=INVALID_POINTER)", 
                         got_chat_id, static_cast<int>(err_chat_id));
                V2TIM_LOG(kWarning, "[GroupInvite] chat_id will be retrieved later when group is fully connected");
            }
            
            // HandleGroupSelfJoin will be triggered by Tox callback when group is fully joined
            // This will notify listeners about the new group
            V2TIM_LOG(kInfo, "[GroupInvite] Group invite accepted successfully, HandleGroupSelfJoin will be triggered when group is fully joined");
            V2TIM_LOG(kInfo, "[GroupInvite] ========== Group invite processing completed ==========");
        }
    );
    
    // Also register old conference API callback for backward compatibility
    // Some clients may still use tox_conference_invite (old API)
    tox_manager_->setGroupInviteCallback(
        [this](uint32_t friend_number, TOX_CONFERENCE_TYPE type, const uint8_t* cookie, size_t length) {
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== Received conference invite (old API) ==========");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] friend_number={}, cookie_length={}", friend_number, length);
            
            // Detailed type analysis
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== TOX_CONFERENCE_TYPE ANALYSIS ==========");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Raw type value: {} (as int)", static_cast<int>(type));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] TOX_CONFERENCE_TYPE_TEXT enum value: {} (as int)", static_cast<int>(TOX_CONFERENCE_TYPE_TEXT));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] TOX_CONFERENCE_TYPE_AV enum value: {} (as int)", static_cast<int>(TOX_CONFERENCE_TYPE_AV));
            
            // Check conference type with detailed comparison
            const char* type_name = "UNKNOWN";
            bool is_text = (type == TOX_CONFERENCE_TYPE_TEXT);
            bool is_av = (type == TOX_CONFERENCE_TYPE_AV);
            
            if (is_text) {
                type_name = "TEXT";
            } else if (is_av) {
                type_name = "AV";
            }
            
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Type comparison results:");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   type == TOX_CONFERENCE_TYPE_TEXT ? {}", is_text ? "YES" : "NO");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   type == TOX_CONFERENCE_TYPE_AV ? {}", is_av ? "YES" : "NO");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Determined type: {} (value={})", type_name, static_cast<int>(type));
            
            // Also check cookie type byte for comparison
            if (length > 2) {
                uint8_t cookie_type_byte = cookie[2];
                const char* cookie_type_name = (cookie_type_byte == 0) ? "TEXT (GROUPCHAT_TYPE_TEXT)" : 
                                               (cookie_type_byte == 1) ? "AV (GROUPCHAT_TYPE_AV)" : "UNKNOWN";
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie type byte (offset 2): {} ({})", 
                         static_cast<int>(cookie_type_byte), cookie_type_name);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Type consistency check: callback type={} ({}), cookie type={} ({})", 
                         static_cast<int>(type), type_name, 
                         static_cast<int>(cookie_type_byte), cookie_type_name);
                
                if (static_cast<int>(type) != static_cast<int>(cookie_type_byte)) {
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] WARNING: Type mismatch! Callback type ({}) != cookie type byte ({})", 
                             static_cast<int>(type), static_cast<int>(cookie_type_byte));
                } else {
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Type consistency: callback type matches cookie type byte");
                }
            }
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] =================================================");
            
            Tox* tox = GetToxManager()->getTox();
            if (!tox) {
                V2TIM_LOG(kError, "[GroupInvite-Conference] ERROR: Tox instance not available, cannot join conference");
                return;
            }
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Tox instance available, proceeding with auto-join");
            
            // Generate a temporary groupID for this invite
            char gid[64];
            auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            snprintf(gid, sizeof(gid), "tox_conf_%u_%llu", friend_number, (unsigned long long)now_ms);
            V2TIMString groupID(gid);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Generated groupID: {}", gid);
            
            // Notify UI: trigger OnMemberInvited so the interface can show "XXX invited you to the group"
            // (Text group path always does this; conference path was missing it, so invite had no notification.)
            std::string inviterUserID;
            if (tox) {
                uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox_friend_get_public_key(tox, friend_number, inviter_pubkey, nullptr)) {
                    inviterUserID = ToxUtil::tox_bytes_to_hex(inviter_pubkey, TOX_PUBLIC_KEY_SIZE);
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Got inviter public key: {} (length={})", inviterUserID, inviterUserID.length());
                } else {
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] Failed to get inviter public key for friend_number={}", friend_number);
                }
            }
            if (!inviterUserID.empty()) {
                V2TIMGroupMemberInfoVector memberList;
                V2TIMGroupMemberInfo selfMember;
                uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox) {
                    tox_self_get_public_key(tox, self_pubkey);
                    std::string selfUserID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                    selfMember.userID = V2TIMString(selfUserID.c_str());
                    memberList.PushBack(selfMember);
                }
                V2TIMGroupMemberInfo opUser;
                opUser.userID = V2TIMString(inviterUserID.c_str());
                std::vector<V2TIMGroupListener*> listeners_copy;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
                }
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        V2TIM_LOG(kInfo, "[GroupInvite-Conference] Triggering OnMemberInvited: tempGroupID={}, inviter={}, memberCount={}",
                                 gid, inviterUserID, memberList.Size());
                        listener->OnMemberInvited(groupID, opUser, memberList);
                    }
                }
            }
            
            // Handle AV type conference (requires toxav support)
            if (type == TOX_CONFERENCE_TYPE_AV) {
#ifdef BUILD_TOXAV
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Received AV type conference invite, attempting to join");
                
                // Get ToxAVManager instance
                ToxAVManager* av_mgr = GetToxAVManager();
                if (!av_mgr) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Failed to get ToxAVManager instance");
                    // Store as pending invite
                    PendingInvite inv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(cookie, cookie + length);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_group_invites_[groupID] = std::move(inv);
                    }
                    return;
                }
                
                // Ensure ToxAV is initialized (pass this so ToxAVManager does not call GetCurrentInstance() again)
                bool toxav_ready = false;
                try {
                    av_mgr->initialize(this);
                    toxav_ready = true;
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] ToxAV initialized successfully");
                } catch (const std::runtime_error& e) {
                    // Check if the error is because it's already initialized
                    std::string error_msg = e.what();
                    if (error_msg.find("already initialized") != std::string::npos) {
                        toxav_ready = true;
                        V2TIM_LOG(kInfo, "[GroupInvite-Conference] ToxAV already initialized");
                    } else {
                        V2TIM_LOG(kError, "[GroupInvite-Conference] ToxAV initialization failed: {}", error_msg);
                    }
                } catch (const std::exception& e) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ToxAV initialization exception: {}", e.what());
                }
                
                if (!toxav_ready) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ToxAV is not ready, cannot join AV conference");
                    // Store as pending invite
                    PendingInvite inv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(cookie, cookie + length);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_group_invites_[groupID] = std::move(inv);
                    }
                    return;
                }
                
                // Get Tox instance
                Tox* tox = tox_manager_->getTox();
                if (!tox) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Tox instance is null, cannot join AV conference");
                    // Store as pending invite
                    PendingInvite inv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(cookie, cookie + length);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_group_invites_[groupID] = std::move(inv);
                    }
                    return;
                }
                
                // Set up audio callback for AV conference
                // The callback will be called when audio data is received from peers
                // Use the static function HandleAVConferenceAudio defined above
                toxav_audio_data_cb* audio_callback = HandleAVConferenceAudio;
                
                // Validate cookie length
                // AV conference cookie should have the same format as TEXT conference
                const size_t expected_length = sizeof(uint16_t) + 1 + 32; // 2 + 1 + 32 = 35
                if (length != expected_length) {
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] AV conference cookie length mismatch: got {}, expected {}", length, expected_length);
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] Will attempt to join anyway with actual length");
                }
                
                // Log cookie details for debugging
                if (length > 0) {
                    std::ostringstream cookie_hex;
                    size_t log_len = std::min(length, size_t(16)); // Log first 16 bytes
                    for (size_t i = 0; i < log_len; ++i) {
                        cookie_hex << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(cookie[i]);
                        if (i < log_len - 1) cookie_hex << " ";
                    }
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] AV conference cookie first {} bytes (hex): {}", log_len, cookie_hex.str());
                }
                
                // Join AV conference using toxav_join_av_groupchat
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Calling toxav_join_av_groupchat: friend_number={}, cookie_length={}",
                         friend_number, length);
                
                int32_t conference_number = toxav_join_av_groupchat(
                    tox,
                    friend_number,
                    cookie,
                    static_cast<uint16_t>(length),
                    audio_callback,
                    this  // userdata
                );
                
                if (conference_number < 0) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Failed to join AV conference, toxav_join_av_groupchat returned {}", conference_number);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Possible reasons: friend not found, invalid cookie, or network issue");
                    // Store as pending invite for manual join later
                    PendingInvite inv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(cookie, cookie + length);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_group_invites_[groupID] = std::move(inv);
                    }
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending AV conference invite as ID {} for manual join later", gid);
                    return;
                }
                
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] ✅ Successfully joined AV conference");
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] conference_number={}, groupID={}", conference_number, gid);
                
                // Store conference mapping (treating conference_number as group_number for compatibility)
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    // Map conference_number to groupID
                    group_id_to_group_number_[groupID] = static_cast<Tox_Group_Number>(conference_number);
                    group_number_to_group_id_[static_cast<Tox_Group_Number>(conference_number)] = groupID;
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored AV conference mapping: groupID={} <-> conference_number={}", gid, conference_number);
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Total groups in mapping: {}", group_id_to_group_number_.size());
                }
                
                // Note: AV conference doesn't support chat_id, so we don't store it
                // The conference will be restored from savedata automatically
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] AV conference joined successfully, HandleGroupConnected will be triggered when connected");

                // Store group type for this conference (both in memory and persistent)
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    group_id_to_type_[groupID] = "conference";
                }
                SetGroupTypeInStorage(gid, "conference");
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored group type 'conference' for groupID={}", gid);

                // Notify Dart layer about the new conference so UI can update group list
                // HandleGroupSelfJoin will look up groupID from the mapping we just stored
                HandleGroupSelfJoin(static_cast<Tox_Group_Number>(conference_number));
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Called HandleGroupSelfJoin for conference_number={}", conference_number);

                V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== AV Conference invite processing completed ==========");
                return;
#else // BUILD_TOXAV not enabled
                V2TIM_LOG(kWarning, "[GroupInvite-Conference] Received AV type conference invite, but BUILD_TOXAV is not enabled");
                V2TIM_LOG(kWarning, "[GroupInvite-Conference] AV conferences require toxav_join_av_groupchat, which needs BUILD_TOXAV=ON");
                V2TIM_LOG(kWarning, "[GroupInvite-Conference] Storing as pending invite - AV conference join not available");
                
                // Store as pending invite for manual join later
                PendingInvite inv;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[groupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending AV conference invite as ID {} for manual join later", gid);
                return;
#endif // BUILD_TOXAV
            }
            
            // For TEXT type, use tox_conference_join
            // Note: join_groupchat expects length to be exactly sizeof(uint16_t) + 1 + GROUP_ID_LENGTH = 35 bytes
            // GROUP_ID_LENGTH = CRYPTO_SYMMETRIC_KEY_SIZE = 32 bytes
            const size_t expected_length = sizeof(uint16_t) + 1 + 32; // 2 + 1 + 32 = 35
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] TEXT type conference, calling tox_conference_join: friend_number={}, cookie_length={}, expected_length={}", 
                     friend_number, length, expected_length);
            
            // Log first few bytes of cookie for debugging
            if (length > 0) {
                std::ostringstream cookie_hex;
                size_t log_len = std::min(length, size_t(16)); // Log first 16 bytes
                for (size_t i = 0; i < log_len; ++i) {
                    cookie_hex << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(cookie[i]);
                    if (i < log_len - 1) cookie_hex << " ";
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie first {} bytes (hex): {}", log_len, cookie_hex.str());
            }
            
            if (length != expected_length) {
                V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie length mismatch: got {}, expected {}", length, expected_length);
                // Store as pending invite for manual join later
                PendingInvite inv;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[groupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending conference invite as ID {} for manual join later", gid);
                return;
            }
            
            // Check cookie type byte (at offset sizeof(uint16_t) = 2)
            // GROUPCHAT_TYPE_TEXT = 0, GROUPCHAT_TYPE_AV = 1
            if (length > 2) {
                uint8_t cookie_type = cookie[2];
                const char* cookie_type_name = (cookie_type == 0) ? "TEXT" : 
                                               (cookie_type == 1) ? "AV" : "UNKNOWN";
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie type byte at offset 2: {} ({}) - expected 0 (GROUPCHAT_TYPE_TEXT) for TEXT conference", 
                         static_cast<int>(cookie_type), cookie_type_name);
                
                // Log the uint16_t value at the beginning of cookie (groupchat_num)
                if (length >= sizeof(uint16_t)) {
                    uint16_t groupchat_num = 0;
                    memcpy(&groupchat_num, cookie, sizeof(uint16_t));
                    // Note: may need to handle endianness, but for logging purposes this is fine
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie groupchat_num (first 2 bytes): {} (raw bytes: {:02x} {:02x})", 
                             groupchat_num, cookie[0], cookie[1]);
                }
                
                // Warn if type mismatch
                if (cookie_type != 0) {
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] WARNING: Cookie type byte is {} ({}), but tox_conference_join expects 0 (TEXT)", 
                             static_cast<int>(cookie_type), cookie_type_name);
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] This will cause WRONG_TYPE error - cookie may be for AV conference");
                }
            }
            
            // Verify length can fit in uint16_t (join_groupchat expects uint16_t)
            if (length > UINT16_MAX) {
                V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie length {} exceeds UINT16_MAX ({})", length, UINT16_MAX);
                PendingInvite inv;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[groupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending conference invite as ID {} for manual join later", gid);
                return;
            }
            
            // Log all cookie bytes for detailed debugging
            std::ostringstream cookie_full_hex;
            for (size_t i = 0; i < length; ++i) {
                cookie_full_hex << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(cookie[i]);
                if (i < length - 1) cookie_full_hex << " ";
            }
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Full cookie ({} bytes, hex): {}", length, cookie_full_hex.str());
            
            // Detailed pre-call validation and logging
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== PRE-CALL VALIDATION ==========");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] tox pointer: {}", static_cast<void*>(tox));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] friend_number: {} (uint32_t)", friend_number);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] cookie pointer: {}", static_cast<const void*>(cookie));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] length: {} (size_t)", length);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] length as uint16_t: {} (cast)", static_cast<uint16_t>(length));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] expected_length: {} (size_t)", expected_length);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] sizeof(uint16_t): {}", sizeof(uint16_t));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Expected: sizeof(uint16_t) + 1 + GROUP_ID_LENGTH = {} + 1 + 32 = {}", 
                     sizeof(uint16_t), sizeof(uint16_t) + 1 + 32);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Length match check: {} == {} ? {}", length, expected_length, (length == expected_length ? "YES" : "NO"));
            
            // Verify cookie structure
            if (length >= 3) {
                uint16_t groupchat_num_le = 0;
                memcpy(&groupchat_num_le, cookie, sizeof(uint16_t));
                uint8_t type_byte = cookie[2];
                const char* type_byte_name = (type_byte == 0) ? "TEXT" : 
                                            (type_byte == 1) ? "AV" : "UNKNOWN";
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie structure: bytes[0-1]={:02x} {:02x} (groupchat_num={}), byte[2]={:02x} (type={}, {}), bytes[3-34]=GROUP_ID (32 bytes)", 
                         cookie[0], cookie[1], groupchat_num_le, type_byte, static_cast<int>(type_byte), type_byte_name);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Expected type byte: {} (GROUPCHAT_TYPE_TEXT = 0)", 0);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Type byte match: {} == 0 ? {} ({} vs TEXT)", 
                         static_cast<int>(type_byte), (type_byte == 0 ? "YES" : "NO"), type_byte_name);
                
                if (type_byte != 0) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ERROR: Cookie type byte mismatch! Cookie has type {} ({}), but tox_conference_join expects 0 (TEXT)", 
                             static_cast<int>(type_byte), type_byte_name);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] This will cause WRONG_TYPE error. Cookie is for {} conference, but we're trying to join as TEXT", type_byte_name);
                }
            }
            
            // Check friend connection status
            TOX_CONNECTION friend_conn = TOX_CONNECTION_NONE;
            try {
                friend_conn = tox_friend_get_connection_status(tox, friend_number, nullptr);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Friend {} connection status: {} (0=NONE, 1=UDP, 2=TCP)", 
                         friend_number, static_cast<int>(friend_conn));
            } catch (...) {
                V2TIM_LOG(kWarning, "[GroupInvite-Conference] Failed to get friend connection status");
            }
            
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== CALLING tox_conference_join ==========");
            // [tim2tox-debug] Record invite receive and cookie parsing for HandleGroupInvite
            V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupInvite: Received conference invite - friend_number={}, type={}, cookie_length={}", 
                     friend_number, static_cast<int>(type), length);
            if (length >= 3) {
                uint16_t groupchat_num = 0;
                memcpy(&groupchat_num, cookie, sizeof(uint16_t));
                uint8_t cookie_type = cookie[2];
                V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupInvite: Cookie parsed - groupchat_num={}, type_byte={}", 
                         groupchat_num, static_cast<int>(cookie_type));
            }
            Tox_Err_Conference_Join err_join = TOX_ERR_CONFERENCE_JOIN_OK;
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Parameters before call:");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   tox={}", static_cast<void*>(tox));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   friend_number={} (uint32_t)", friend_number);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   cookie={}", static_cast<const void*>(cookie));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   length={} (size_t) = {} (uint16_t)", length, static_cast<uint16_t>(length));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   error_ptr={}", static_cast<void*>(&err_join));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Calling tox_conference_join now...");
            // [tim2tox-debug] Record tox_conference_join call
            V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupInvite: Calling tox_conference_join");
            
            Tox_Conference_Number conference_number = tox_conference_join(
                tox,
                friend_number,
                cookie, length,
                &err_join
            );
            
            V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupInvite: tox_conference_join returned: conference_number={}, err_join={}", 
                     conference_number, static_cast<int>(err_join));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] tox_conference_join call completed");
            
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== tox_conference_join RETURNED ==========");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Return value: conference_number={}", conference_number);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Error code: {} (enum value)", static_cast<int>(err_join));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] UINT32_MAX: {}", UINT32_MAX);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] conference_number == UINT32_MAX ? {}", (conference_number == UINT32_MAX ? "YES" : "NO"));
            
            // Map error code to string
            const char* err_name = "UNKNOWN";
            switch (err_join) {
                case TOX_ERR_CONFERENCE_JOIN_OK: err_name = "OK"; break;
                case TOX_ERR_CONFERENCE_JOIN_NULL: err_name = "NULL"; break;
                case TOX_ERR_CONFERENCE_JOIN_INVALID_LENGTH: err_name = "INVALID_LENGTH"; break;
                case TOX_ERR_CONFERENCE_JOIN_WRONG_TYPE: err_name = "WRONG_TYPE"; break;
                case TOX_ERR_CONFERENCE_JOIN_FRIEND_NOT_FOUND: err_name = "FRIEND_NOT_FOUND"; break;
                case TOX_ERR_CONFERENCE_JOIN_DUPLICATE: err_name = "DUPLICATE"; break;
                case TOX_ERR_CONFERENCE_JOIN_INIT_FAIL: err_name = "INIT_FAIL"; break;
                case TOX_ERR_CONFERENCE_JOIN_FAIL_SEND: err_name = "FAIL_SEND"; break;
            }
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Error name: {}", err_name);
            
            if (err_join != TOX_ERR_CONFERENCE_JOIN_OK || conference_number == UINT32_MAX) {
                V2TIM_LOG(kError, "[GroupInvite-Conference] ========== JOIN FAILED ==========");
                V2TIM_LOG(kError, "[GroupInvite-Conference] Error code: {} ({})", static_cast<int>(err_join), err_name);
                V2TIM_LOG(kError, "[GroupInvite-Conference] Error code meanings: 0=OK, 1=NULL, 2=INVALID_LENGTH, 3=WRONG_TYPE, 4=FRIEND_NOT_FOUND, 5=DUPLICATE, 6=INIT_FAIL, 7=FAIL_SEND");
                V2TIM_LOG(kError, "[GroupInvite-Conference] conference_number={} (UINT32_MAX={})", conference_number, UINT32_MAX);
                
                // Detailed diagnostics for each error type
                if (err_join == TOX_ERR_CONFERENCE_JOIN_INVALID_LENGTH) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== INVALID_LENGTH DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie length received: {} (size_t)", length);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie length as uint16_t: {} (cast)", static_cast<uint16_t>(length));
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Expected length: {} (size_t)", expected_length);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] sizeof(uint16_t): {}", sizeof(uint16_t));
                    V2TIM_LOG(kError, "[GroupInvite-Conference] GROUP_ID_LENGTH (CRYPTO_SYMMETRIC_KEY_SIZE): 32");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] join_groupchat check: length != sizeof(uint16_t) + 1 + GROUP_ID_LENGTH");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] join_groupchat check: {} != {} + 1 + 32", length, sizeof(uint16_t));
                    V2TIM_LOG(kError, "[GroupInvite-Conference] join_groupchat check: {} != {}", length, sizeof(uint16_t) + 1 + 32);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Length difference: {} - {} = {}", 
                             length, sizeof(uint16_t) + 1 + 32, static_cast<long long>(length) - static_cast<long long>(sizeof(uint16_t) + 1 + 32));
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_WRONG_TYPE) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== WRONG_TYPE DIAGNOSTICS ==========");
                    if (length > 2) {
                        uint8_t cookie_type = cookie[2];
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie type byte at offset 2: {} (received)", static_cast<int>(cookie_type));
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Expected type: {} (GROUPCHAT_TYPE_TEXT)", 1);
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Type mismatch: {} != 1", static_cast<int>(cookie_type));
                    } else {
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie too short to check type byte (length={})", length);
                    }
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_FRIEND_NOT_FOUND) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== FRIEND_NOT_FOUND DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] friend_number: {}", friend_number);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Friend connection status: {} (0=NONE, 1=UDP, 2=TCP)", static_cast<int>(friend_conn));
                    if (friend_conn == TOX_CONNECTION_NONE) {
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Friend is not connected - this may cause FRIEND_NOT_FOUND error");
                    }
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_DUPLICATE) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== DUPLICATE DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Client may already be in this conference");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] join_groupchat check: get_group_num() != -1 (group already exists)");
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_INIT_FAIL) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== INIT_FAIL DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] create_group_chat() returned -1 (group instance failed to initialize)");
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_FAIL_SEND) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== FAIL_SEND DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] send_invite_response() returned false (join packet failed to send)");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Friend connection status: {} (0=NONE, 1=UDP, 2=TCP)", static_cast<int>(friend_conn));
                    if (friend_conn == TOX_CONNECTION_NONE) {
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Friend is not connected - this may cause FAIL_SEND error");
                    }
                }
                
                // Store as pending invite for manual join later
                PendingInvite inv;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[groupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending conference invite as ID {} for manual join later", gid);
                return;
            }
            
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ✅ Successfully joined conference");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] conference_number={}, groupID={}", conference_number, gid);
            
            // Store conference mapping (old API uses conference_number, which may be same as group_number in some cases)
            // Note: In modern c-toxcore, conference_number and group_number may be the same value
            // We'll treat conference_number as group_number for mapping purposes
            {
                std::lock_guard<std::mutex> lock(mutex_);
                // Map conference_number to groupID (treating it as group_number for compatibility)
                group_id_to_group_number_[groupID] = conference_number;
                group_number_to_group_id_[conference_number] = groupID;
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored conference mapping: groupID={} <-> conference_number={}", gid, conference_number);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Total groups in mapping: {}", group_id_to_group_number_.size());
            }
            
            // Note: Old conference API doesn't have chat_id, so we can't persist it
            // The conference will be restored from savedata if available

            // Store group type for this conference (both in memory and persistent)
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_type_[groupID] = "conference";
            }
            SetGroupTypeInStorage(gid, "conference");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored group type 'conference' for groupID={}", gid);

            // Notify Dart layer about the new conference so UI can update group list
            // HandleGroupSelfJoin will look up groupID from the mapping we just stored
            HandleGroupSelfJoin(conference_number);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Called HandleGroupSelfJoin for conference_number={}", conference_number);

            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Conference joined successfully, HandleGroupConnected will be triggered when connected");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== Conference invite processing completed ==========");
        }
    );
    
    // CRITICAL: Rejoin all known groups using stored chat_id (c-toxcore recommended approach)
    // This ensures groups are properly restored after client restart, even if they're not in savedata
    // The onGroupSelfJoin callback will be triggered for each successfully joined group to rebuild mappings
    // Note: This may be called before Dart layer has synced known groups, so it may find no groups.
    // Dart layer will call RejoinKnownGroups() again after init() completes.
    // IMPORTANT: Don't call RejoinKnownGroups here during InitSDK - it will be called when connection is established
    // This prevents crashes during initialization when objects may not be fully ready
    
    // Conference (old API) messages: route to same handler as group messages so receivers get OnRecvNewMessage.
    // tox_callback_conference_message fires for conferences; tox_callback_group_message for new groups only.
    tox_manager_->setGroupMessageCallback(
        [this](uint32_t conference_number, uint32_t peer_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length) {
            this->HandleGroupMessageGroup(static_cast<Tox_Group_Number>(conference_number),
                    static_cast<Tox_Group_Peer_Number>(peer_number), type, message, length, static_cast<Tox_Group_Message_Id>(0));
        }
    );
    tox_manager_->setFriendMessageCallback(
        [this](uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length) {
            this->HandleFriendMessage(friend_number, type, message, length);
        }
    );
    // Signaling: route lossless packets to this instance's signaling manager
    tox_manager_->setFriendLosslessPacketCallback(
        [this](uint32_t friend_number, const uint8_t* data, size_t length) {
            V2TIMSignalingManager* sig = GetSignalingManager();
            if (sig) {
                static_cast<V2TIMSignalingManagerImpl*>(sig)->OnToxMessage(friend_number, data, length);
            }
        }
    );
    // Use callback that captures 'this' directly (safe now that we have instance-specific ToxManager)
    tox_manager_->setSelfConnectionStatusCallback(
        [this](TOX_CONNECTION connection_status) {
            // DEBUG: Detailed analysis in callback
            fprintf(stdout, "[SelfConnectionStatusCallback] ========== RUNNING_FLAG_DEBUG ==========\n");
            fprintf(stdout, "[SelfConnectionStatusCallback] this=%p\n", (void*)this);
            fprintf(stdout, "[SelfConnectionStatusCallback] &running_=%p\n", &(this->running_));
            fprintf(stdout, "[SelfConnectionStatusCallback] offset of running_=%ld bytes\n", 
                    (char*)&(this->running_) - (char*)this);
            fprintf(stdout, "[SelfConnectionStatusCallback] running_ value (direct access)=%d\n", 
                    this->running_.load() ? 1 : 0);
            fprintf(stdout, "[SelfConnectionStatusCallback] IsRunning()=%d\n", 
                    this->IsRunning() ? 1 : 0);
            
            // Note: Cannot access memory directly for atomic, removed
            
            // Try calling IsRunning() multiple times
            bool test1 = this->IsRunning();
            bool test2 = this->IsRunning();
            bool test3 = this->IsRunning();
            fprintf(stdout, "[SelfConnectionStatusCallback] IsRunning() calls: test1=%d, test2=%d, test3=%d\n",
                    test1 ? 1 : 0, test2 ? 1 : 0, test3 ? 1 : 0);
            
            fprintf(stdout, "[SelfConnectionStatusCallback] =========================================\n");
            fflush(stdout);
            
            // Use atomic load for thread safety
            bool is_running = this->running_.load(std::memory_order_acquire);
            extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
            int64_t instance_id = GetInstanceIdFromManager(this);
            // connection_status: 0=NONE, 1=TCP, 2=UDP
            V2TIM_LOG(kInfo, "SelfConnectionStatusCallback: instance_id={}, connection_status={}, IsRunning()={}", 
                     instance_id, connection_status, is_running ? 1 : 0);
            if (is_running) {
                this->HandleSelfConnectionStatus(connection_status);
            } else {
                V2TIM_LOG(kWarning, "SelfConnectionStatusCallback: SDK not running (instance_id={}), skipping HandleSelfConnectionStatus", instance_id);
            }
        }
    );
    tox_manager_->setFriendRequestCallback(
        [this](const uint8_t* public_key, const uint8_t* message, size_t length) {
            this->HandleFriendRequest(public_key, message, length);
        }
    );
    tox_manager_->setFriendNameCallback(
        [this](uint32_t friend_number, const uint8_t* name, size_t length) {
            this->HandleFriendName(friend_number, name, length);
        }
    );
    tox_manager_->setFriendStatusMessageCallback(
        [this](uint32_t friend_number, const uint8_t* message, size_t length) {
            this->HandleFriendStatusMessage(friend_number, message, length);
        }
    );
    tox_manager_->setFriendStatusCallback(
        [this](uint32_t friend_number, TOX_USER_STATUS status) {
            int64_t this_instance_id = GetInstanceIdFromManager(this);
            fprintf(stdout, "[V2TIMManagerImpl] FriendStatusCallback: ENTRY - instance_id=%lld, friend_number=%u, status=%d\n",
                    (long long)this_instance_id, friend_number, status);
            fflush(stdout);
            this->HandleFriendStatus(friend_number, status);
            fprintf(stdout, "[V2TIMManagerImpl] FriendStatusCallback: EXIT - instance_id=%lld\n",
                    (long long)this_instance_id);
            fflush(stdout);
        }
    );
    tox_manager_->setFriendConnectionStatusCallback(
        [this](uint32_t friend_number, TOX_CONNECTION connection_status) {
            int64_t this_instance_id = GetInstanceIdFromManager(this);
            // connection_status: 0=NONE, 1=TCP, 2=UDP - when non-NONE, friend P2P is established
            fprintf(stdout, "[Bootstrap] FriendConnectionStatusCallback instance_id=%lld friend_number=%u connection_status=%d (0=NONE,1=TCP,2=UDP)\n",
                    (long long)this_instance_id, friend_number, connection_status);
            fflush(stdout);
            fprintf(stdout, "[V2TIMManagerImpl] FriendConnectionStatusCallback: ENTRY - instance_id=%lld, friend_number=%u, connection_status=%d\n",
                    (long long)this_instance_id, friend_number, connection_status);
            fflush(stdout);
            this->HandleFriendConnectionStatus(friend_number, connection_status);
            fprintf(stdout, "[V2TIMManagerImpl] FriendConnectionStatusCallback: EXIT - instance_id=%lld\n",
                    (long long)this_instance_id);
            fflush(stdout);
        }
    );
    tox_manager_->setGroupTitleCallback(
        [this](uint32_t conference_number, uint32_t peer_number, const uint8_t* title, size_t length) {
            this->HandleGroupTitle(conference_number, peer_number, title, length);
        }
    );
    tox_manager_->setGroupPeerNameCallback(
        [this](uint32_t conference_number, uint32_t peer_number, const uint8_t* name, size_t length) {
            this->HandleGroupPeerName(conference_number, peer_number, name, length);
        }
    );
    tox_manager_->setGroupPeerListChangedCallback(
        [this](uint32_t conference_number) {
            this->HandleGroupPeerListChanged(conference_number);
        }
    );
    tox_manager_->setGroupConnectedCallback(
        [this](uint32_t conference_number) {
            this->HandleGroupConnected(conference_number);
        }
    );
    // TODO: Register handlers for other callbacks (read receipts, file transfer, etc.)

    // CRITICAL: Set running_ flag AFTER all callbacks are registered
    // Note: running_ was already set to true before initialize() to handle early callbacks
    // This ensures consistency and that all callbacks are ready before processing events
    // running_ is already true, so we just log here for clarity
    fprintf(stdout, "[InitSDK] Callbacks registered, running_=%d (already set before initialize)\n", running_.load() ? 1 : 0);
    fflush(stdout);
    
    // Start the Tox event loop thread.
    // In test mode, the auto_tests harness drives iteration manually via
    // tim2tox_ffi_iterate_instance() with a shared virtual clock, so we skip
    // starting the per-instance event_thread entirely.
    if (!test_mode_.load(std::memory_order_acquire)) {
        fprintf(stdout, "InitSDK: starting event thread\n");
        event_thread_ = std::thread([this] {
            event_thread_id_ = std::this_thread::get_id();
            while (running_.load(std::memory_order_acquire)) {
                try {
                    // Process pending tasks first (Invite/signaling etc. run on this thread to avoid tox lock deadlock)
                    {
                        std::unique_lock<std::mutex> lock(task_mutex_);
                        task_cv_.wait_for(lock, std::chrono::milliseconds(50),
                            [this] { return !task_queue_.empty() || !running_.load(std::memory_order_relaxed); });
                        while (!task_queue_.empty()) {
                            auto task = std::move(task_queue_.front());
                            task_queue_.pop();
                            lock.unlock();
                            task();
                            lock.lock();
                        }
                    }
                    if (!running_.load(std::memory_order_acquire)) break;
                    if (!tox_manager_ || tox_manager_->isShuttingDown()) break;
                    // Centralized iterate through ToxManager to ensure correct user_data
                    int64_t current_instance_id = GetCurrentInstanceId();
                    static int event_thread_iterate_count = 0;
                    event_thread_iterate_count++;
                    if (event_thread_iterate_count % 500 == 0) {
                        fprintf(stdout, "[V2TIMManagerImpl] event_thread: instance_id=%lld, iterate #%d\n",
                                (long long)current_instance_id, event_thread_iterate_count);
                        fflush(stdout);
                    }
                    tox_manager_->iterate();
                    if (!running_.load(std::memory_order_acquire)) break;
                    if (!tox_manager_ || tox_manager_->isShuttingDown()) break;
                    // Dispatch any expired signaling invite timeouts. Iterate-driven
                    // (replaces the per-invite std::thread that used to back
                    // OnInvitationTimeout) so virtual-clock tests work and a
                    // long-timeout invite no longer blocks a subsequent short-
                    // timeout Invite() from firing on schedule.
                    if (signaling_manager_) {
                        signaling_manager_->CheckTimeouts();
                    }
                    Tox* t = tox_manager_->getTox();
                    uint32_t interval = t ? tox_iteration_interval(t) : 50;
                    std::this_thread::sleep_for(std::chrono::milliseconds(interval));
                } catch (...) {
                    break;
                }
            }
        });
    } else {
        fprintf(stdout, "InitSDK: SKIP event thread (test mode)\n");
        fflush(stdout);
    }

    fprintf(stdout, "InitSDK: returning true\n");
    return true;
}

void V2TIMManagerImpl::UnInitSDK() {
    // Stop background tasks (refresh/rejoin threads) so they don't access this after shutdown
    StopBackgroundTasks();
    // First, stop the event thread and wait for it to exit
    // This MUST happen before calling ToxManager::shutdown() to prevent race conditions
    running_.store(false, std::memory_order_release);
    task_cv_.notify_all();  // Wake event thread so it exits promptly
    if (event_thread_.joinable()) {
        try {
            event_thread_.join();
        } catch (const std::system_error&) {
            // Thread may have already exited - ignore
        } catch (...) {
            // Ignore any other exception during thread join
        }
    }
    // Now that event thread has exited, it's safe to shutdown ToxManager
    // Persist tox profile on shutdown using path from InitSDK
    std::string save_path = save_path_;
    if (save_path.empty()) {
        std::filesystem::path save_dir = tim2tox::path::GetDefaultDataDir();
        std::string mkdir_err;
        (void)tim2tox::path::EnsureDirectoryExists(save_dir, &mkdir_err);
        save_path = tim2tox::path::BuildProfilePath(save_dir, GetInstanceIdFromManager(this)).string();
    }
    try {
#ifdef BUILD_TOXAV
        if (toxav_manager_) {
            toxav_manager_->shutdown();
            toxav_manager_.reset();
        }
#endif
        if (tox_manager_) {
            tox_manager_->saveTo(save_path);
            tox_manager_->shutdown();
            tox_manager_.reset();
        }
    } catch (...) {
        // Ignore exceptions during shutdown
    }
    save_path_.clear();
}

void V2TIMManagerImpl::SaveToxProfile() {
    if (!tox_manager_) {
        V2TIM_LOG(kWarning, "[SaveToxProfile] tox_manager_ is null, skipping");
        return;
    }
    std::string save_path = save_path_;
    if (save_path.empty()) {
        std::filesystem::path save_dir = tim2tox::path::GetDefaultDataDir();
        std::string mkdir_err;
        (void)tim2tox::path::EnsureDirectoryExists(save_dir, &mkdir_err);
        save_path = tim2tox::path::BuildProfilePath(save_dir, GetInstanceIdFromManager(this)).string();
    }
    if (tox_manager_->saveTo(save_path)) {
        V2TIM_LOG(kInfo, "[SaveToxProfile] Saved tox profile to {}", save_path);
    } else {
        V2TIM_LOG(kError, "[SaveToxProfile] Failed to save tox profile to {}", save_path);
    }
}

// SDK Information
V2TIMString V2TIMManagerImpl::GetVersion() {
    return TIM2TOX_VERSION_STRING;
}

std::string V2TIMManagerImpl::MakeMessageId() {
    int64_t instance_id = GetInstanceIdFromManager(this);
    auto now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    uint64_t seq = next_message_seq_.fetch_add(1, std::memory_order_relaxed);
    std::ostringstream oss;
    oss << "msg_" << instance_id << "_" << now_ns << "_" << seq;
    return oss.str();
}

std::string V2TIMManagerImpl::MakeGroupId() {
    int64_t instance_id = GetInstanceIdFromManager(this);
    uint64_t seq = next_group_seq_.fetch_add(1, std::memory_order_relaxed);
    std::ostringstream oss;
    oss << "group_" << instance_id << "_" << seq;
    return oss.str();
}

int64_t V2TIMManagerImpl::GetServerTime() {
    return std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()
    ).count();
}

// User Authentication: Login completes locally; connection state is reported via SDK listeners.
void V2TIMManagerImpl::Login(const V2TIMString& userID, const V2TIMString& userSig, V2TIMCallback* callback) {
    if (!tox_manager_) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    if (userID.Empty()) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "userID is empty");
        return;
    }
    // TIM 风格的 userSig 在 tim2tox 中不会被验证，只作兼容透传；这里忽略非空 userSig，
    // 保持登录流程继续，以便沿用上层现有调用约定。

    {
        std::lock_guard<std::mutex> lock(mutex_);
        login_user_alias_ = userID;
    }

    // Set logged_in_user_ from tox when available (used for status/self identity in callbacks)
    Tox* tox = tox_manager_->getTox();
    if (tox) {
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, pubkey);
        std::string pk_hex = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        std::string address = tox_manager_->getAddress();
        if (address.length() >= 76) {
            logged_in_user_ = (pk_hex + address.substr(64, 12)).c_str();
        } else {
            logged_in_user_ = pk_hex.c_str();
        }
    } else {
        std::string address = tox_manager_->getAddress();
        if (address.length() > 0) {
            logged_in_user_ = address.c_str();
        }
    }

    if (callback) callback->OnSuccess();
}

void V2TIMManagerImpl::Logout(V2TIMCallback* callback) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        login_user_alias_ = "";
    }
    logged_in_user_ = "";
    if (callback) callback->OnSuccess();
}

V2TIMString V2TIMManagerImpl::GetLoginUser() {
    std::lock_guard<std::mutex> lock(mutex_);
    return login_user_alias_;
}

V2TIMString V2TIMManagerImpl::GetSelfToxAddress() {
    std::lock_guard<std::mutex> lock(mutex_);
    return logged_in_user_;
}

V2TIMLoginStatus V2TIMManagerImpl::GetLoginStatus() {
    std::lock_guard<std::mutex> lock(mutex_);
    bool is_empty = login_user_alias_.Empty();
    return is_empty ? V2TIMLoginStatus::V2TIM_STATUS_LOGOUT : V2TIMLoginStatus::V2TIM_STATUS_LOGINED;
}

bool V2TIMManagerImpl::HasGroup(const V2TIMString& group_id) const {
    return group_id_to_group_number_.find(group_id) != group_id_to_group_number_.end();
}

// IsRunning() implementation - moved to .cpp to avoid inline optimization issues
bool V2TIMManagerImpl::IsRunning() const {
    return running_.load(std::memory_order_acquire);
}

// Messaging
void V2TIMManagerImpl::AddSimpleMsgListener(V2TIMSimpleMsgListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    simple_msg_listeners_.insert(listener);
}

void V2TIMManagerImpl::RemoveSimpleMsgListener(V2TIMSimpleMsgListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    simple_msg_listeners_.erase(listener);
}

V2TIMString V2TIMManagerImpl::SendC2CTextMessage(
    const V2TIMString& text, 
    const V2TIMString& userID,
    V2TIMSendCallback* callback) {
    // 调用带cloudCustomData的版本，传入空的cloudCustomData
    return SendC2CTextMessage(text, userID, V2TIMBuffer(), callback);
}

V2TIMString V2TIMManagerImpl::SendC2CTextMessage(
    const V2TIMString& text, 
    const V2TIMString& userID,
    const V2TIMBuffer& cloudCustomData,
    V2TIMSendCallback* callback) {
    // ===================================================================
    // Step 1: Validate parameters
    // ===================================================================
    if (text.Empty()) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, 
                            "Message text cannot be empty");
        }
        return "";
    }

    if (userID.Empty()) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, 
                            "UserID cannot be empty");
        }
        return "";
    }

    // ===================================================================
    // Step 2: Convert UserID (assuming hex public key) to Tox public key bytes
    // ===================================================================
    uint8_t public_key[TOX_PUBLIC_KEY_SIZE] = {0};
    bool convert_result = false;
    if (userID.Length() == TOX_PUBLIC_KEY_SIZE * 2) {
        convert_result = ToxUtil::tox_hex_to_bytes(userID.CString(), userID.Length(), public_key, TOX_PUBLIC_KEY_SIZE);
    } else if (userID.Length() == TOX_ADDRESS_SIZE * 2) {
        uint8_t address[TOX_ADDRESS_SIZE] = {0};
        if (ToxUtil::tox_hex_to_bytes(userID.CString(), userID.Length(), address, TOX_ADDRESS_SIZE)) {
            memcpy(public_key, address, TOX_PUBLIC_KEY_SIZE);
            convert_result = true;
        }
    }

    if (!convert_result) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS,
                            "Invalid userID format (must be hex Tox ID)");
        }
        return "";
    }

    // ===================================================================
    // Step 3: Look up friend number by public key
    // ===================================================================
    std::unique_lock<std::mutex> lock(mutex_); // Use the main mutex
    Tox* tox = GetToxManager()->getTox();
    if (!tox) {
         if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
         return "";
    }
    
    TOX_ERR_FRIEND_BY_PUBLIC_KEY find_err;
    uint32_t friend_number = tox_friend_by_public_key(
        tox, 
        public_key, 
        &find_err
    );

    if (find_err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        lock.unlock();
        fprintf(stdout, "[SendC2CTextMessage] ERROR: Friend not found: userID=%.64s, find_err=%d\n", userID.CString(), find_err);
        fflush(stdout);
        if (callback) {
            // Use appropriate error code based on V2TIMErrorCode.h
            int v2_err = (find_err == TOX_ERR_FRIEND_BY_PUBLIC_KEY_NOT_FOUND)
                       ? ERR_SVR_FRIENDSHIP_ACCOUNT_NOT_FOUND
                       : ERR_INVALID_PARAMETERS;
            const char* err_msg = (find_err == TOX_ERR_FRIEND_BY_PUBLIC_KEY_NOT_FOUND)
                                ? "Target user is not your friend"
                                : "Friend lookup failed";
            V2TIM_LOG(kError, "SendC2CTextMessage failed: userID=%s, error=%d (%s)", userID.CString(), v2_err, err_msg);
            callback->OnError(v2_err, err_msg);
        }
        return "";
    }
    
    // Check friend connection status before sending
    TOX_CONNECTION connection_status = tox_friend_get_connection_status(tox, friend_number, nullptr);
    fprintf(stdout, "[SendC2CTextMessage] Friend found: friend_number=%u, connection_status=%d (0=NONE, 1=TCP, 2=UDP)\n", 
            friend_number, connection_status);
    fflush(stdout);
    
    // If friend is not connected, wait a bit and retry once (for test scenarios)
    if (connection_status == TOX_CONNECTION_NONE) {
        fprintf(stdout, "[SendC2CTextMessage] Friend not connected, waiting 2 seconds and retrying...\n");
        fflush(stdout);
        lock.unlock(); // Release lock before waiting
        std::this_thread::sleep_for(std::chrono::seconds(2));
        lock.lock(); // Re-acquire lock
        
        // Re-check connection status
        connection_status = tox_friend_get_connection_status(tox, friend_number, nullptr);
        fprintf(stdout, "[SendC2CTextMessage] After wait: connection_status=%d\n", connection_status);
        fflush(stdout);
        
        if (connection_status == TOX_CONNECTION_NONE) {
            lock.unlock();
            fprintf(stdout, "[SendC2CTextMessage] ERROR: Friend still not connected after wait: userID=%.64s, friend_number=%u\n", 
                    userID.CString(), friend_number);
            fflush(stdout);
            if (callback) callback->OnError(ERR_SDK_NET_DISCONNECT, "Friend not connected");
            return "";
        }
    }

    // ===================================================================
    // Step 4: Process reply reference if present
    // ===================================================================
    std::string finalMessageText(text.CString());
    
    // 检查是否有引用回复信息
    std::string replyJson = MessageReplyUtil::ExtractReplyJsonFromCloudCustomData(cloudCustomData);
    if (!replyJson.empty()) {
        // 构建包含引用回复的消息
        std::string messageWithReply = MessageReplyUtil::BuildMessageWithReply(replyJson, finalMessageText);
        
        // 检查消息长度
        if (MessageReplyUtil::IsMessageTooLong(messageWithReply)) {
            // 如果消息过长，尝试压缩引用信息
            std::string compressedReply = MessageReplyUtil::CompressReplyJson(replyJson);
            messageWithReply = MessageReplyUtil::BuildMessageWithReply(compressedReply, finalMessageText);
            
            // 如果还是太长，只保留messageID
            if (MessageReplyUtil::IsMessageTooLong(messageWithReply)) {
                // 提取messageID
                std::string messageID = MessageReplyUtil::ExtractJsonValue(replyJson, "messageID");
                if (!messageID.empty()) {
                    std::string minimalReply = "{\"version\":1,\"messageID\":\"" + messageID + "\"}";
                    messageWithReply = MessageReplyUtil::BuildMessageWithReply(minimalReply, finalMessageText);
                }
            }
        }
        
        finalMessageText = messageWithReply;
    }
    
    // ===================================================================
    // Step 5: Send the message
    // ===================================================================
    V2TIMString msg_id = MakeMessageId().c_str();

    const size_t max_msg_len = TOX_MAX_MESSAGE_LENGTH;
    if (finalMessageText.length() > max_msg_len) {
        lock.unlock();
        if (callback) {
            callback->OnError(ERR_SDK_MSG_BODY_SIZE_LIMIT,
                              "Message exceeds max length");
        }
        return "";
    }

    TOX_ERR_FRIEND_SEND_MESSAGE send_err;
    fprintf(stdout, "[SendC2CTextMessage] About to send message: friend_number=%u, message_len=%zu\n", 
            friend_number, finalMessageText.length());
    fflush(stdout);
    // Note: message_return_id is the internal tox id, might be useful for receipts
    /*uint32_t message_return_id =*/ tox_friend_send_message(
        tox,
        friend_number,
        TOX_MESSAGE_TYPE_NORMAL,
        reinterpret_cast<const uint8_t*>(finalMessageText.c_str()),
        finalMessageText.length(),
        &send_err
    );
    fprintf(stdout, "[SendC2CTextMessage] tox_friend_send_message returned: send_err=%d (0=OK, 1=FRIEND_NOT_FOUND, 2=FRIEND_NOT_CONNECTED, 3=NULL, 4=FRIEND_NOT_CONFIRMED, 5=SENDQ, 6=TOO_LONG, 7=EMPTY)\n", send_err);
    fflush(stdout);

    lock.unlock();

    // ===================================================================
    // Step 5: Handle send result
    // ===================================================================
    if (send_err == TOX_ERR_FRIEND_SEND_MESSAGE_OK) {
        // TODO: Implement message status tracking/receipts using message_return_id if needed
        if (callback) {
            // Create a V2TIMMessage from the message ID
            V2TIMMessage resultMsg;
            resultMsg.msgID = msg_id;
            // Add a text elem to the message (使用原始text，不包含引用标记)
            V2TIMTextElem* textElem = new V2TIMTextElem();
            textElem->text = text;
            resultMsg.elemList.PushBack(textElem);
            // Set basic message properties
            resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
            resultMsg.userID = userID;
            resultMsg.sender = GetToxManager()->getAddress();
            // 保留cloudCustomData
            resultMsg.cloudCustomData = cloudCustomData;
            
            // Pass the V2TIMMessage to the callback
            callback->OnSuccess(resultMsg);
        }
        return msg_id;
    }
    else {
         // Map Tox error to V2TIM error code
        int v2_err_code = ERR_INVALID_PARAMETERS; // Default
        const char* v2_err_msg = "Unknown Tox error during send";

        switch (send_err) {
            case TOX_ERR_FRIEND_SEND_MESSAGE_FRIEND_NOT_FOUND:
                 v2_err_code = ERR_SVR_FRIENDSHIP_ACCOUNT_NOT_FOUND; // Should not happen if lookup succeeded
                 v2_err_msg = "Friend not found internally";
                 break;
            case TOX_ERR_FRIEND_SEND_MESSAGE_FRIEND_NOT_CONNECTED:
                 v2_err_code = ERR_SDK_NET_DISCONNECT;
                 v2_err_msg = "Friend not connected";
                 break;
            case TOX_ERR_FRIEND_SEND_MESSAGE_SENDQ:
                 v2_err_code = ERR_INVALID_PARAMETERS; // Or ERR_SDK_NET_REQ_COUNT_LIMIT?
                 v2_err_msg = "Send queue full";
                 break;
             case TOX_ERR_FRIEND_SEND_MESSAGE_TOO_LONG:
                 v2_err_code = ERR_SDK_MSG_BODY_SIZE_LIMIT;
                 v2_err_msg = "Message too long (Tox limit)";
                 break;
             case TOX_ERR_FRIEND_SEND_MESSAGE_EMPTY:
                  v2_err_code = ERR_INVALID_PARAMETERS;
                  v2_err_msg = "Message text cannot be empty (Tox check)";
                  break;
            default:
                  v2_err_code = ERR_INVALID_PARAMETERS;
                  v2_err_msg = "Unknown Tox error during send";
                  break;
            // Add other specific Tox errors if needed
        }
        V2TIM_LOG(kError, "SendC2CTextMessage failed: userID=%s, error=%d (%s), tox_err=%d", userID.CString(), v2_err_code, v2_err_msg, send_err);
        if (callback) callback->OnError(v2_err_code, v2_err_msg);
        return "";
    }
}

// Send C2C custom message
V2TIMString V2TIMManagerImpl::SendC2CCustomMessage(const V2TIMBuffer& customData, const V2TIMString& userID, V2TIMSendCallback* callback) {
    // Validate
    if (customData.Data() == nullptr || customData.Size() == 0) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Custom data cannot be empty");
        return "";
    }
    if (userID.Empty()) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "UserID cannot be empty");
        return "";
    }

    // Resolve friend number
    Tox* tox = GetToxManager()->getTox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
        return "";
    }

    uint8_t public_key[TOX_PUBLIC_KEY_SIZE] = {0};
    bool converted = false;
    if (userID.Length() == TOX_PUBLIC_KEY_SIZE * 2) {
        converted = ToxUtil::tox_hex_to_bytes(userID.CString(), userID.Length(), public_key, TOX_PUBLIC_KEY_SIZE);
    } else if (userID.Length() == TOX_ADDRESS_SIZE * 2) {
        uint8_t address[TOX_ADDRESS_SIZE] = {0};
        if (ToxUtil::tox_hex_to_bytes(userID.CString(), userID.Length(), address, TOX_ADDRESS_SIZE)) {
            memcpy(public_key, address, TOX_PUBLIC_KEY_SIZE);
            converted = true;
        }
    }
    if (!converted) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid userID format (must be hex Tox ID)");
        return "";
    }

    TOX_ERR_FRIEND_BY_PUBLIC_KEY find_err;
    uint32_t friend_number = tox_friend_by_public_key(tox, public_key, &find_err);
    if (find_err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        fprintf(stdout, "[SendC2CCustomMessage] ERROR: Friend not found: userID=%.64s, find_err=%d\n", userID.CString(), find_err);
        fflush(stdout);
        if (callback) callback->OnError(ERR_SVR_FRIENDSHIP_ACCOUNT_NOT_FOUND, "Target user is not your friend");
        return "";
    }
    
    // Check friend connection status before sending
    TOX_CONNECTION connection_status = tox_friend_get_connection_status(tox, friend_number, nullptr);
    fprintf(stdout, "[SendC2CCustomMessage] Friend found: friend_number=%u, connection_status=%d (0=NONE, 1=TCP, 2=UDP)\n", 
            friend_number, connection_status);
    fflush(stdout);
    
    // If friend is not connected, wait a bit and retry once (for test scenarios)
    if (connection_status == TOX_CONNECTION_NONE) {
        fprintf(stdout, "[SendC2CCustomMessage] Friend not connected, waiting 2 seconds and retrying...\n");
        fflush(stdout);
        std::this_thread::sleep_for(std::chrono::seconds(2));
        
        // Re-check connection status
        connection_status = tox_friend_get_connection_status(tox, friend_number, nullptr);
        fprintf(stdout, "[SendC2CCustomMessage] After wait: connection_status=%d\n", connection_status);
        fflush(stdout);
        
        if (connection_status == TOX_CONNECTION_NONE) {
            fprintf(stdout, "[SendC2CCustomMessage] ERROR: Friend still not connected after wait: userID=%.64s, friend_number=%u\n", 
                    userID.CString(), friend_number);
            fflush(stdout);
            if (callback) callback->OnError(ERR_SDK_NET_DISCONNECT, "Friend not connected");
            return "";
        }
    }

    V2TIMString msg_id = MakeMessageId().c_str();

    // Send as ACTION type to distinguish from text
    TOX_ERR_FRIEND_SEND_MESSAGE send_err;
    fprintf(stdout, "[SendC2CCustomMessage] About to send message: friend_number=%u, data_len=%zu\n", 
            friend_number, customData.Size());
    fflush(stdout);
    tox_friend_send_message(
        tox,
        friend_number,
        TOX_MESSAGE_TYPE_ACTION,
        reinterpret_cast<const uint8_t*>(customData.Data()),
        customData.Size(),
        &send_err
    );
    fprintf(stdout, "[SendC2CCustomMessage] tox_friend_send_message returned: send_err=%d (0=OK, 1=FRIEND_NOT_FOUND, 2=FRIEND_NOT_CONNECTED, 3=NULL, 4=FRIEND_NOT_CONFIRMED, 5=SENDQ, 6=TOO_LONG, 7=EMPTY)\n", send_err);
    fflush(stdout);

    if (send_err == TOX_ERR_FRIEND_SEND_MESSAGE_OK) {
        if (callback) {
            V2TIMMessage resultMsg;
            resultMsg.msgID = msg_id;
            V2TIMCustomElem* customElem = new V2TIMCustomElem();
            customElem->data = customData;
            resultMsg.elemList.PushBack(customElem);
            resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
            resultMsg.userID = userID;
            resultMsg.sender = GetToxManager()->getAddress();
            callback->OnSuccess(resultMsg);
        }
        return msg_id;
    } else {
        int v2_err_code = ERR_INVALID_PARAMETERS;
        const char* v2_err_msg = "Unknown Tox error during send";
        switch (send_err) {
            case TOX_ERR_FRIEND_SEND_MESSAGE_FRIEND_NOT_FOUND:
                v2_err_code = ERR_SVR_FRIENDSHIP_ACCOUNT_NOT_FOUND;
                v2_err_msg = "Friend not found internally";
                break;
            case TOX_ERR_FRIEND_SEND_MESSAGE_FRIEND_NOT_CONNECTED:
                v2_err_code = ERR_SDK_NET_DISCONNECT;
                v2_err_msg = "Friend not connected";
                break;
            case TOX_ERR_FRIEND_SEND_MESSAGE_SENDQ:
                v2_err_code = ERR_INVALID_PARAMETERS;
                v2_err_msg = "Send queue full";
                break;
            case TOX_ERR_FRIEND_SEND_MESSAGE_TOO_LONG:
                v2_err_code = ERR_SDK_MSG_BODY_SIZE_LIMIT;
                v2_err_msg = "Message too long (Tox limit)";
                break;
            case TOX_ERR_FRIEND_SEND_MESSAGE_EMPTY:
                v2_err_code = ERR_INVALID_PARAMETERS;
                v2_err_msg = "Custom data cannot be empty";
                break;
            default:
                break;
        }
        if (callback) callback->OnError(v2_err_code, v2_err_msg);
        return "";
    }
}

// Send group text message
V2TIMString V2TIMManagerImpl::SendGroupTextMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback) {
    // 调用带cloudCustomData的版本，传入空的cloudCustomData
    return SendGroupTextMessage(text, groupID, priority, V2TIMBuffer(), callback);
}

V2TIMString V2TIMManagerImpl::SendGroupTextMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, const V2TIMBuffer& cloudCustomData, V2TIMSendCallback* callback) {
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] ========== ENTRY ==========");
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] groupID={}, text_length={}", groupID.CString(), text.Length());
    
    // ===================================================================
    // Step 1: Validate parameters
    // ===================================================================
    if (text.Empty()) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupTextMessage] Message text is empty");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Message text cannot be empty");
        return "";
    }
    if (groupID.Empty()) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupTextMessage] Group ID is empty");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group ID cannot be empty");
        return "";
    }

    // Ignore priority for now, as Tox core doesn't directly support it for group messages

    // ===================================================================
    // Step 2: Find the group number for the group ID
    // ===================================================================
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_); // Protect access to the map
        auto it = group_id_to_group_number_.find(groupID);
        if (it == group_id_to_group_number_.end()) {
            V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupTextMessage] Group not found in map: groupID={}", groupID.CString());
            V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupTextMessage] Available groups in map: {}", group_id_to_group_number_.size());
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group not found or user not in group");
            return "";
        }
        group_number = it->second;
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Found group_number={} for groupID={}", group_number, groupID.CString());
    }

    // ===================================================================
    // Step 3: Process reply reference if present
    // ===================================================================
    std::string finalMessageText(text.CString());
    
    // 检查是否有引用回复信息
    std::string replyJson = MessageReplyUtil::ExtractReplyJsonFromCloudCustomData(cloudCustomData);
    if (!replyJson.empty()) {
        // 构建包含引用回复的消息
        std::string messageWithReply = MessageReplyUtil::BuildMessageWithReply(replyJson, finalMessageText);
        
        // 检查消息长度
        if (MessageReplyUtil::IsMessageTooLong(messageWithReply)) {
            // 如果消息过长，尝试压缩引用信息
            std::string compressedReply = MessageReplyUtil::CompressReplyJson(replyJson);
            messageWithReply = MessageReplyUtil::BuildMessageWithReply(compressedReply, finalMessageText);
            
            // 如果还是太长，只保留messageID
            if (MessageReplyUtil::IsMessageTooLong(messageWithReply)) {
                // 提取messageID
                std::string messageID = MessageReplyUtil::ExtractJsonValue(replyJson, "messageID");
                if (!messageID.empty()) {
                    std::string minimalReply = "{\"version\":1,\"messageID\":\"" + messageID + "\"}";
                    messageWithReply = MessageReplyUtil::BuildMessageWithReply(minimalReply, finalMessageText);
                }
            }
        }
        
        finalMessageText = messageWithReply;
    }

    // ===================================================================
    // Step 4: Check message length against Tox limit
    // ===================================================================
    // Note: V2TIM API implies single message. We'll check against the general Tox limit.
    const size_t max_msg_len = TOX_MAX_MESSAGE_LENGTH; // Use general constant
    if (finalMessageText.length() > max_msg_len) {
       V2TIM_LOG(kError, "SendGroupTextMessage failed: groupID=%s, message too long (%zu > %zu)", groupID.CString(), finalMessageText.length(), max_msg_len);
       if (callback) callback->OnError(ERR_SDK_MSG_BODY_SIZE_LIMIT, "Message exceeds max length");
       return "";
    }

    // ===================================================================
    // Step 5: Send the message using ToxManager
    V2TIMString msgID = MakeMessageId().c_str();

    // Check group connection status before sending
    Tox_Err_Group_Is_Connected err_conn;
    bool group_connected = GetToxManager()->isGroupConnected(group_number, &err_conn);
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Group connection status: connected={}, err={}", 
             group_connected, static_cast<int>(err_conn));
    fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: Group connection status: connected=%d, err=%d\n",
            group_connected ? 1 : 0, static_cast<int>(err_conn));
    fflush(stdout);
    
    // Check self connection status
    Tox* tox = GetToxManager()->getTox();
    if (tox) {
        TOX_CONNECTION self_conn = tox_self_get_connection_status(tox);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Self connection status: {}", static_cast<int>(self_conn));
        fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: Self connection status: %d (0=NONE, 1=TCP, 2=UDP)\n",
                static_cast<int>(self_conn));
        fflush(stdout);
        
        // Check group peer count (approximate by trying to get peer IDs)
        int peer_count = 0;
        Tox_Err_Group_Self_Query err_self;
        Tox_Group_Peer_Number self_peer_id = tox_group_self_get_peer_id(tox, group_number, &err_self);
        
        // Get self public key for comparison
        uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, self_pubkey);
        std::string self_pubkey_hex = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
        
        if (err_self == TOX_ERR_GROUP_SELF_QUERY_OK) {
            fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: Self peer_id in group: %u, self_public_key=%s\n", 
                    self_peer_id, self_pubkey_hex.c_str());
            fflush(stdout);
            
            // Try to count peers by iterating
            for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                Tox_Err_Group_Peer_Query err_peer;
                if (tox_group_peer_get_public_key(tox, group_number, peer_id, peer_pubkey, &err_peer) &&
                    err_peer == TOX_ERR_GROUP_PEER_QUERY_OK) {
                    peer_count++;
                    std::string peer_userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
                    bool is_self = (memcmp(peer_pubkey, self_pubkey, TOX_PUBLIC_KEY_SIZE) == 0);
                    if (peer_count <= 3) { // Log first 3 peers
                        fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: Found peer[%u]: userID=%s, is_self=%d\n", 
                                peer_id, peer_userID.c_str(), is_self ? 1 : 0);
                        fflush(stdout);
                    }
                    // Check if self_peer_id matches actual self peer
                    if (is_self && peer_id != self_peer_id) {
                        fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: ⚠️  WARNING: Found self at peer_id=%u but self_peer_id=%u! This indicates peer_id mapping issue.\n",
                                peer_id, self_peer_id);
                        fflush(stdout);
                    }
                } else if (peer_id > 10) {
                    // Stop after 10 consecutive errors
                    break;
                }
            }
            fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: Total peers found in group: %d\n", peer_count);
            fflush(stdout);
        }
    }
    
    // Check if this is a conference-type group (needs different send API)
    std::string group_type_val;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto type_it = group_id_to_type_.find(groupID);
        if (type_it != group_id_to_type_.end()) {
            group_type_val = type_it->second;
        }
    }

    Tox_Group_Message_Id message_id = 0;
    Tox_Err_Group_Send_Message send_err = TOX_ERR_GROUP_SEND_MESSAGE_OK;
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] About to send: group_number={}, message_length={}, group_type='{}'",
             group_number, finalMessageText.length(), group_type_val);
    fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: About to call groupSendMessage: group_number=%u, message_length=%zu\n",
            group_number, finalMessageText.length());
    fflush(stdout);

    bool success = false;

    if (group_type_val == "conference" && tox) {
        // Conference group (old Tox API): use tox_conference_send_message
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Conference group: routing to tox_conference_send_message, conference_number={}",
                  group_number);
        fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: Conference group, using tox_conference_send_message: conference_number=%u\n",
                group_number);
        fflush(stdout);
        Tox_Err_Conference_Send_Message conf_err;
        success = tox_conference_send_message(
            tox,
            static_cast<uint32_t>(group_number),
            TOX_MESSAGE_TYPE_NORMAL,
            reinterpret_cast<const uint8_t*>(finalMessageText.c_str()),
            finalMessageText.length(),
            &conf_err);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] tox_conference_send_message returned: success={}, conf_err={}",
                  success, static_cast<int>(conf_err));
        fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: tox_conference_send_message returned: success=%d, conf_err=%d\n",
                success ? 1 : 0, static_cast<int>(conf_err));
        fflush(stdout);

        // --- Conference diagnostic: log conference peer state ---
        {
            Tox_Err_Conference_Peer_Query err_cpeer;
            uint32_t active_peer_count = tox_conference_peer_count(tox, static_cast<uint32_t>(group_number), &err_cpeer);
            uint32_t offline_peer_count = 0;
            Tox_Err_Conference_Peer_Query err_offline;
            offline_peer_count = tox_conference_offline_peer_count(tox, static_cast<uint32_t>(group_number), &err_offline);
            V2TIM_LOG(kInfo, "[Conference-Diag] conf={} active_peers={} (err={}) offline_peers={} (err={})",
                      group_number, active_peer_count, static_cast<int>(err_cpeer),
                      offline_peer_count, static_cast<int>(err_offline));
            fprintf(stdout, "[Conference-Diag] conf=%u active_peers=%u (err=%d) offline_peers=%u (err=%d)\n",
                    group_number, active_peer_count, static_cast<int>(err_cpeer),
                    offline_peer_count, static_cast<int>(err_offline));
            fflush(stdout);
            // Log active peer public keys
            if (err_cpeer == TOX_ERR_CONFERENCE_PEER_QUERY_OK && active_peer_count > 0) {
                for (uint32_t pi = 0; pi < active_peer_count && pi < 8; ++pi) {
                    uint8_t ppk[TOX_PUBLIC_KEY_SIZE];
                    Tox_Err_Conference_Peer_Query err_pk;
                    bool is_ours = false;
                    Tox_Err_Conference_Peer_Query err_ours;
                    bool pk_ok = tox_conference_peer_get_public_key(tox, static_cast<uint32_t>(group_number), pi, ppk, &err_pk);
                    if (pk_ok) {
                        is_ours = tox_conference_peer_number_is_ours(tox, static_cast<uint32_t>(group_number), pi, &err_ours);
                        std::string pk_hex = ToxUtil::tox_bytes_to_hex(ppk, TOX_PUBLIC_KEY_SIZE);
                        fprintf(stdout, "[Conference-Diag]   active_peer[%u] pk=%s is_ours=%d\n",
                                pi, pk_hex.c_str(), is_ours ? 1 : 0);
                        fflush(stdout);
                    }
                }
            }
            // Log offline (frozen) peer public keys
            if (err_offline == TOX_ERR_CONFERENCE_PEER_QUERY_OK && offline_peer_count > 0) {
                for (uint32_t pi = 0; pi < offline_peer_count && pi < 8; ++pi) {
                    uint8_t ppk[TOX_PUBLIC_KEY_SIZE];
                    Tox_Err_Conference_Peer_Query err_pk;
                    bool pk_ok = tox_conference_offline_peer_get_public_key(tox, static_cast<uint32_t>(group_number), pi, ppk, &err_pk);
                    if (pk_ok) {
                        std::string pk_hex = ToxUtil::tox_bytes_to_hex(ppk, TOX_PUBLIC_KEY_SIZE);
                        fprintf(stdout, "[Conference-Diag]   offline_peer[%u] pk=%s\n", pi, pk_hex.c_str());
                        fflush(stdout);
                    }
                }
            }
        }
        // --- End conference diagnostic ---

        if (!success) {
            send_err = TOX_ERR_GROUP_SEND_MESSAGE_FAIL_SEND; // Map to recognizable error
        }
    } else {
        // NGCv2 group: use existing path
        success = GetToxManager()->groupSendMessage(
            group_number,
            TOX_MESSAGE_TYPE_NORMAL, // For text messages
            reinterpret_cast<const uint8_t*>(finalMessageText.c_str()),
            finalMessageText.length(),
            &message_id,
            &send_err);

        // If NGCv2 send fails with GROUP_NOT_FOUND, fall back to conference API.
        // This handles synthetic groupIDs (e.g. tox_group_1) created for groups that are
        // actually Tox conferences loaded from save data but not yet registered as type="conference".
        if (!success && send_err == TOX_ERR_GROUP_SEND_MESSAGE_GROUP_NOT_FOUND && tox) {
            Tox_Err_Conference_Peer_Query err_conf_check;
            tox_conference_peer_count(tox, static_cast<uint32_t>(group_number), &err_conf_check);
            if (err_conf_check == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
                V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] NGCv2 GROUP_NOT_FOUND, falling back to conference API: conference_number={}",
                          group_number);
                fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: NGCv2 failed, falling back to tox_conference_send_message: conference_number=%u\n",
                        group_number);
                fflush(stdout);
                // Also register the type so future sends skip the NGCv2 path
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    group_id_to_type_[groupID] = "conference";
                }
                Tox_Err_Conference_Send_Message conf_err;
                success = tox_conference_send_message(
                    tox,
                    static_cast<uint32_t>(group_number),
                    TOX_MESSAGE_TYPE_NORMAL,
                    reinterpret_cast<const uint8_t*>(finalMessageText.c_str()),
                    finalMessageText.length(),
                    &conf_err);
                V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Conference fallback result: success={}, conf_err={}",
                          success, static_cast<int>(conf_err));
                fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: Conference fallback result: success=%d, conf_err=%d\n",
                        success ? 1 : 0, static_cast<int>(conf_err));
                fflush(stdout);
                if (!success) {
                    send_err = TOX_ERR_GROUP_SEND_MESSAGE_FAIL_SEND;
                }
            }
        }
    }

    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] groupSendMessage returned: success={}, message_id={}, send_err={}",
             success, message_id, static_cast<int>(send_err));
    fprintf(stdout, "[V2TIMManagerImpl] SendGroupTextMessage: groupSendMessage returned: success=%d, message_id=%llu, send_err=%d\n",
            success ? 1 : 0, (unsigned long long)message_id, static_cast<int>(send_err));
    fflush(stdout);

    // ===================================================================
    // Step 5: Forward to IRC if this is an IRC channel (handled by dynamic library)
    // ===================================================================
    // Forward Tox message to IRC via FFI (if library is loaded)
    std::string sender_nick = GetToxManager()->getName();
    if (sender_nick.empty()) {
        sender_nick = "ToxUser";
    }
    tim2tox_ffi_irc_forward_tox_message(groupID.CString(), sender_nick.c_str(), finalMessageText.c_str());

    // ===================================================================
    // Step 6: Handle the result
    // ===================================================================
    if (success) {
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Message sent successfully, msgID: {}", msgID.CString());
        // Tox group send is fire-and-forget, success means it was queued.
        if (callback) {
             // Create a V2TIMMessage
             V2TIMMessage resultMsg;
             resultMsg.msgID = msgID;
             
             // Add text element
             V2TIMTextElem* textElem = new V2TIMTextElem();
             textElem->text = text;
             resultMsg.elemList.PushBack(textElem);
             
             // Set basic message properties
             resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                 std::chrono::system_clock::now().time_since_epoch()).count();
             resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
             resultMsg.groupID = groupID;
             resultMsg.sender = GetToxManager()->getAddress();
             // 保留cloudCustomData
             resultMsg.cloudCustomData = cloudCustomData;
             
             // Pass the message to the callback
             callback->OnSuccess(resultMsg);
        }
        return msgID;
    } else {
        // Map Tox error to V2TIM error code
        int v2_err_code = ERR_INVALID_PARAMETERS; // Default error
        const char* v2_err_msg = "Failed to send group message";
        switch (send_err) {
            case TOX_ERR_GROUP_SEND_MESSAGE_GROUP_NOT_FOUND:
                 // This implies the group_number became invalid between lookup and send,
                 // or the ToxManager instance disappeared.
                 v2_err_code = ERR_INVALID_PARAMETERS; // Or perhaps ERR_SDK_NOT_INITIALIZED
                 v2_err_msg = "Internal error: Group number invalid or Tox instance gone";
                 break;
            case TOX_ERR_GROUP_SEND_MESSAGE_TOO_LONG:
                 v2_err_code = ERR_SDK_MSG_BODY_SIZE_LIMIT;
                 v2_err_msg = "Message too long";
                 break;
            case TOX_ERR_GROUP_SEND_MESSAGE_DISCONNECTED:
                  v2_err_code = ERR_SDK_NET_DISCONNECT; // Map to general network error
                  v2_err_msg = "Not connected to the group chat network";
                  break;
            case TOX_ERR_GROUP_SEND_MESSAGE_FAIL_SEND:
                  v2_err_code = ERR_INVALID_PARAMETERS;
                  v2_err_msg = "Failed to send message to group";
                  break;
            default:
                  v2_err_code = ERR_INVALID_PARAMETERS;
                  v2_err_msg = "Unknown error sending group message";
                  break;
             // Add more cases as needed based on toxcore version/errors
        }
        V2TIM_LOG(kError, "SendGroupTextMessage failed: groupID=%s, error=%d (%s), tox_err=%d", groupID.CString(), v2_err_code, v2_err_msg, send_err);
        if (callback) callback->OnError(v2_err_code, v2_err_msg);
        return "";
    }
}

V2TIMString V2TIMManagerImpl::SendGroupPrivateTextMessage(const V2TIMString& groupID, const V2TIMString& receiverPublicKey64, const V2TIMString& text, V2TIMSendCallback* callback) {
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] groupID={}, receiver_len={}, text_length={}", groupID.CString(), receiverPublicKey64.Length(), text.Length());
    if (groupID.Empty() || receiverPublicKey64.Empty() || text.Empty()) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Empty groupID, receiver or text");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "GroupID, receiver and text cannot be empty");
        return "";
    }
    std::string receiver_hex(receiverPublicKey64.CString());
    if (receiver_hex.size() != static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2)) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Receiver must be 64-char hex public key, got length {}", receiver_hex.size());
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Receiver must be 64-char hex public key");
        return "";
    }
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it == group_id_to_group_number_.end()) {
            V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Group not found: groupID={}", groupID.CString());
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group not found or user not in group");
            return "";
        }
        group_number = it->second;
    }
    Tox* tox = GetToxManager()->getTox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NET_DISCONNECT, "Tox not available");
        return "";
    }
    // Resolve receiver (64-char hex) to Tox_Group_Peer_Number: try cache from HandleGroupPeerJoin first
    Tox_Group_Peer_Number peer_id = UINT32_MAX;
    {
        std::string key_lower = receiver_hex;
        std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(), ::tolower);
        std::lock_guard<std::mutex> lock(mutex_);
        auto it_grp = group_peer_id_cache_.find(group_number);
        if (it_grp != group_peer_id_cache_.end()) {
            auto it_pk = it_grp->second.find(key_lower);
            if (it_pk != it_grp->second.end()) {
                peer_id = it_pk->second;
                V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Resolved peer_id={} from cache for receiver {}", peer_id, receiver_hex);
            }
        }
    }
    if (peer_id == UINT32_MAX) {
        // Fallback: iterate group peers by public key
        uint8_t target_pubkey[TOX_PUBLIC_KEY_SIZE];
        if (!ToxUtil::tox_hex_to_bytes(receiver_hex.c_str(), receiver_hex.size(), target_pubkey, TOX_PUBLIC_KEY_SIZE)) {
            V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Invalid receiver hex");
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid receiver public key hex");
            return "";
        }
        uint32_t consecutive_fail = 0;
        for (Tox_Group_Peer_Number p = 0; p < 256; ++p) {
            uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_Peer_Query err;
            if (GetToxManager()->getGroupPeerPublicKey(group_number, p, peer_pubkey, &err) && err == TOX_ERR_GROUP_PEER_QUERY_OK) {
                consecutive_fail = 0;
                if (memcmp(peer_pubkey, target_pubkey, TOX_PUBLIC_KEY_SIZE) == 0) {
                    peer_id = p;
                    break;
                }
            } else {
                if (++consecutive_fail > 48) break;
            }
        }
    }
    if (peer_id == UINT32_MAX) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Peer not found in group for receiver {}", receiver_hex);
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Receiver not found in group");
        return "";
    }
    Tox_Err_Group_Send_Private_Message err_priv;
    Tox_Group_Message_Id msg_id = tox_group_send_private_message(
        tox, group_number, peer_id, TOX_MESSAGE_TYPE_NORMAL,
        reinterpret_cast<const uint8_t*>(text.CString()), text.Length(), &err_priv);
    if (err_priv != TOX_ERR_GROUP_SEND_PRIVATE_MESSAGE_OK) {
        const char* err_msg = "Failed to send group private message";
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, err_msg);
        return "";
    }
    uint64_t ts = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    char msg_id_buf[80];
    snprintf(msg_id_buf, sizeof(msg_id_buf), "gp%llu-%llu", ts, (unsigned long long)msg_id);
    V2TIMString msgID = msg_id_buf;
    if (callback) {
        V2TIMMessage resultMsg;
        resultMsg.msgID = msgID;
        V2TIMTextElem* textElem = new V2TIMTextElem();
        textElem->text = text;
        resultMsg.elemList.PushBack(textElem);
        resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
        resultMsg.groupID = groupID;
        resultMsg.sender = GetToxManager()->getAddress();
        callback->OnSuccess(resultMsg);
    }
    return msgID;
}

// Send group custom message
V2TIMString V2TIMManagerImpl::SendGroupCustomMessage(const V2TIMBuffer& customData, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback) {
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupCustomMessage] ========== ENTRY ==========");
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupCustomMessage] groupID={}, data_length={}", 
             groupID.CString(), customData.Size());
    fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: ENTRY - groupID=%s, data_length=%zu\n",
            groupID.CString(), customData.Size());
    fflush(stdout);
    
    if (customData.Data() == nullptr || customData.Size() == 0) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupCustomMessage] Custom data is empty");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Custom data cannot be empty");
        return "";
    }
    if (groupID.Empty()) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupCustomMessage] Group ID is empty");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group ID cannot be empty");
        return "";
    }

    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it == group_id_to_group_number_.end()) {
            V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupCustomMessage] Group not found: groupID={}", groupID.CString());
            fprintf(stderr, "[V2TIMManagerImpl] SendGroupCustomMessage: ERROR - Group not found: groupID=%s\n", groupID.CString());
            fflush(stderr);
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group not found or user not in group");
            return "";
        }
        group_number = it->second;
    }
    
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupCustomMessage] Found group_number={} for groupID={}", 
             group_number, groupID.CString());
    fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: Found group_number=%u for groupID=%s\n",
            group_number, groupID.CString());
    fflush(stdout);

    V2TIMString msgID = MakeMessageId().c_str();

    Tox_Err_Group_Send_Message send_err;
    Tox_Group_Message_Id message_id;
    
    // Check group connection status before sending
    Tox_Err_Group_Is_Connected err_conn;
    bool group_connected = GetToxManager()->isGroupConnected(group_number, &err_conn);
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupCustomMessage] Group connection status: connected={}, err={}", 
             group_connected, static_cast<int>(err_conn));
    fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: Group connection status: connected=%d, err=%d\n",
            group_connected ? 1 : 0, static_cast<int>(err_conn));
    fflush(stdout);
    
    // Check self connection status
    Tox* tox = GetToxManager()->getTox();
    if (tox) {
        TOX_CONNECTION self_conn = tox_self_get_connection_status(tox);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupCustomMessage] Self connection status: {}", static_cast<int>(self_conn));
        fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: Self connection status: %d (0=NONE, 1=TCP, 2=UDP)\n",
                static_cast<int>(self_conn));
        fflush(stdout);
        
        // Check group peer count (approximate by trying to get peer IDs)
        int peer_count = 0;
        Tox_Err_Group_Self_Query err_self;
        Tox_Group_Peer_Number self_peer_id = tox_group_self_get_peer_id(tox, group_number, &err_self);
        if (err_self == TOX_ERR_GROUP_SELF_QUERY_OK) {
            fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: Self peer_id in group: %u\n", self_peer_id);
            fflush(stdout);
            
            // Try to count peers by iterating
            for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                Tox_Err_Group_Peer_Query err_peer;
                if (tox_group_peer_get_public_key(tox, group_number, peer_id, peer_pubkey, &err_peer) &&
                    err_peer == TOX_ERR_GROUP_PEER_QUERY_OK) {
                    peer_count++;
                    if (peer_count <= 3) { // Log first 3 peers
                        std::string peer_userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
                        fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: Found peer[%u]: userID=%s\n", 
                                peer_id, peer_userID.c_str());
                        fflush(stdout);
                    }
                } else if (peer_id > 10) {
                    // Stop after 10 consecutive errors
                    break;
                }
            }
            fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: Total peers found in group: %d\n", peer_count);
            fflush(stdout);
        }
    }
    
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupCustomMessage] About to call groupSendMessage: group_number={}, data_length={}", 
             group_number, customData.Size());
    fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: About to call groupSendMessage: group_number=%u, data_length=%zu\n",
            group_number, customData.Size());
    fflush(stdout);
    
    bool success = GetToxManager()->groupSendMessage(
        group_number,
        TOX_MESSAGE_TYPE_ACTION,
        reinterpret_cast<const uint8_t*>(customData.Data()),
        customData.Size(),
        &message_id,
        &send_err);
    
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupCustomMessage] groupSendMessage returned: success={}, message_id={}, send_err={}", 
             success, message_id, static_cast<int>(send_err));
    fprintf(stdout, "[V2TIMManagerImpl] SendGroupCustomMessage: groupSendMessage returned: success=%d, message_id=%llu, send_err=%d\n",
            success ? 1 : 0, (unsigned long long)message_id, static_cast<int>(send_err));
    fflush(stdout);

    if (success) {
        if (callback) {
            V2TIMMessage resultMsg;
            resultMsg.msgID = msgID;
            V2TIMCustomElem* customElem = new V2TIMCustomElem();
            customElem->data = customData;
            resultMsg.elemList.PushBack(customElem);
            resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
            resultMsg.groupID = groupID;
            resultMsg.sender = GetToxManager()->getAddress();
            callback->OnSuccess(resultMsg);
        }
        return msgID;
    } else {
        int v2_err_code = ERR_INVALID_PARAMETERS;
        const char* v2_err_msg = "Failed to send group custom message";
        switch (send_err) {
            case TOX_ERR_GROUP_SEND_MESSAGE_GROUP_NOT_FOUND:
                v2_err_code = ERR_INVALID_PARAMETERS;
                v2_err_msg = "Group not found";
                break;
            case TOX_ERR_GROUP_SEND_MESSAGE_TOO_LONG:
                v2_err_code = ERR_SDK_MSG_BODY_SIZE_LIMIT;
                v2_err_msg = "Message too long";
                break;
            case TOX_ERR_GROUP_SEND_MESSAGE_DISCONNECTED:
                v2_err_code = ERR_SDK_NET_DISCONNECT;
                v2_err_msg = "No connection to group";
                break;
            case TOX_ERR_GROUP_SEND_MESSAGE_FAIL_SEND:
                v2_err_code = ERR_INVALID_PARAMETERS;
                v2_err_msg = "Failed to send to group";
                break;
            default:
                break;
        }
        if (callback) callback->OnError(v2_err_code, v2_err_msg);
        return "";
    }
}

// Group Management
void V2TIMManagerImpl::AddGroupListener(V2TIMGroupListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_listeners_.insert(listener);
}

void V2TIMManagerImpl::RemoveGroupListener(V2TIMGroupListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_listeners_.erase(listener);
}

void V2TIMManagerImpl::CreateGroup(const V2TIMString& groupType, const V2TIMString& groupID, const V2TIMString& groupName, V2TIMValueCallback<V2TIMString>* callback) {
    V2TIM_LOG(kInfo, "CreateGroup: ENTRY - groupType={}, groupID={}, groupName={}, callback={}", 
              groupType.CString() ? groupType.CString() : "null", 
              groupID.CString() ? groupID.CString() : "null",
              groupName.CString() ? groupName.CString() : "null",
              (void*)callback);
    
    // Step 1: Get ToxManager
    V2TIM_LOG(kInfo, "CreateGroup: Step 1 - Getting ToxManager");
    ToxManager* tox_manager = GetToxManager();
    V2TIM_LOG(kInfo, "CreateGroup: Step 1 - GetToxManager() returned {}", (void*)tox_manager);
    
    if (!tox_manager) {
        V2TIM_LOG(kError, "CreateGroup: ERROR - ToxManager is null, cannot proceed");
        if (callback) {
            V2TIM_LOG(kInfo, "CreateGroup: Calling callback->OnError with ERR_SDK_NOT_INITIALIZED");
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: callback is null, cannot report error");
        }
        V2TIM_LOG(kInfo, "CreateGroup: EXIT - Early return due to null ToxManager");
        return;
    }
    
    // Step 2: Get Tox instance
    V2TIM_LOG(kInfo, "CreateGroup: Step 2 - Getting Tox instance from ToxManager");
    Tox* tox = tox_manager->getTox();
    V2TIM_LOG(kInfo, "CreateGroup: Step 2 - tox_manager->getTox() returned {}", (void*)tox);
    
    if (!tox) {
        V2TIM_LOG(kError, "CreateGroup: ERROR - Tox instance is null, cannot proceed");
        if (callback) {
            V2TIM_LOG(kInfo, "CreateGroup: Calling callback->OnError with ERR_SDK_NOT_INITIALIZED");
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: callback is null, cannot report error");
        }
        V2TIM_LOG(kInfo, "CreateGroup: EXIT - Early return due to null Tox instance");
        return;
    }

    // Step 3: Check group type and determine privacy state
    V2TIM_LOG(kInfo, "CreateGroup: Step 3 - Checking group type");
    std::string group_type_str = groupType.CString() ? std::string(groupType.CString()) : "";
    V2TIM_LOG(kInfo, "CreateGroup: Step 3 - group_type_str={}", group_type_str);
    bool is_conference = (group_type_str == "conference");
    
    // "Private" (kTIMGroup_Private) -> PRIVATE: peer discovery via friend connections (faster in test)
    // "conference" -> PRIVATE (invite-only)
    // "Public" or "Meeting" -> PUBLIC (DHT discovery)
    // "group" (default) -> PUBLIC
    Tox_Group_Privacy_State privacy_state = TOX_GROUP_PRIVACY_STATE_PUBLIC;
    if (group_type_str == "Private" || is_conference) {
        privacy_state = TOX_GROUP_PRIVACY_STATE_PRIVATE;
        fprintf(stdout, "[CreateGroup] Setting privacy_state to PRIVATE (groupType=%s)\n", group_type_str.c_str());
        fflush(stdout);
        V2TIM_LOG(kInfo, "CreateGroup: Step 3 - Setting privacy_state to PRIVATE");
    } else if (group_type_str == "Public" || group_type_str == "Meeting") {
        privacy_state = TOX_GROUP_PRIVACY_STATE_PUBLIC;
        fprintf(stdout, "[CreateGroup] Setting privacy_state to PUBLIC (groupType=%s)\n", group_type_str.c_str());
        fflush(stdout);
        V2TIM_LOG(kInfo, "CreateGroup: Step 3 - Setting privacy_state to PUBLIC");
    } else {
        fprintf(stdout, "[CreateGroup] Using default privacy_state PUBLIC (groupType=%s)\n", group_type_str.c_str());
        fflush(stdout);
        V2TIM_LOG(kInfo, "CreateGroup: Step 3 - Using default privacy_state PUBLIC");
    }
    
    // Step 4: Get group name and self name
    V2TIM_LOG(kInfo, "CreateGroup: Step 4 - Getting group name and self name");
    std::string group_name_str = groupName.Empty() ? "Group" : (groupName.CString() ? std::string(groupName.CString()) : "Group");
    V2TIM_LOG(kInfo, "CreateGroup: Step 4 - group_name_str={}, length={}", group_name_str, group_name_str.length());
    
    std::string self_name = tox_manager->getName();
    V2TIM_LOG(kInfo, "CreateGroup: Step 4 - Initial self_name={}, length={}", self_name, self_name.length());
    if (self_name.empty()) {
        self_name = "User";
        V2TIM_LOG(kInfo, "CreateGroup: Step 4 - self_name was empty, using default 'User'");
    }
    V2TIM_LOG(kInfo, "CreateGroup: Step 4 - Final self_name={}, length={}", self_name, self_name.length());
    
    // Step 5: Create group or conference based on type
    uint32_t group_number = UINT32_MAX;
    bool creation_success = false;
    Tox_Err_Group_New err_new = TOX_ERR_GROUP_NEW_OK; // Initialize for group type
    
    if (is_conference) {
        // Create conference using tox_conference_new (old API)
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - Creating conference (old API) using tox_conference_new");
        Tox_Err_Conference_New err_conf;
        // [tim2tox-debug] Record tox_conference_new call for conference creation
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: Calling tox_conference_new for conference creation");
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: tox={}, err_conf_ptr={}", (void*)tox, (void*)&err_conf);
        Tox_Conference_Number conference_number = tox_conference_new(tox, &err_conf);
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: tox_conference_new returned: conference_number={}, err_conf={}", 
                 conference_number, static_cast<int>(err_conf));
        
        if (err_conf != TOX_ERR_CONFERENCE_NEW_OK || conference_number == UINT32_MAX) {
            V2TIM_LOG(kError, "CreateGroup: ERROR - Failed to create conference: err_conf={}, conference_number={}", 
                     static_cast<int>(err_conf), conference_number);
            if (callback) {
                callback->OnError(ERR_INVALID_PARAMETERS, "Failed to create Tox conference");
            }
            V2TIM_LOG(kInfo, "CreateGroup: EXIT - Early return due to conference creation failure");
            return;
        }
        
        group_number = conference_number;
        creation_success = true;
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - SUCCESS - Conference created with conference_number={}", conference_number);
    } else {
        // Create group using tox_group_new (new API)
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - Creating group (new API) using tox_manager->createGroup");
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - Parameters: privacy_state={}, group_name_len={}, self_name_len={}", 
                  privacy_state, group_name_str.length(), self_name.length());
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - group_name_str.c_str()={}, self_name.c_str()={}", 
                  (void*)group_name_str.c_str(), (void*)self_name.c_str());
        
        // [tim2tox-debug] Record tox_group_new call for group creation
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: Calling tox_manager->createGroup (tox_group_new)");
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: privacy_state={}, group_name_len={}, self_name_len={}", 
                 privacy_state, group_name_str.length(), self_name.length());
        Tox_Group_Number created_group_number = tox_manager->createGroup(
            privacy_state,
            reinterpret_cast<const uint8_t*>(group_name_str.c_str()), group_name_str.length(),
            reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
            &err_new
        );
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: tox_manager->createGroup returned: group_number={}, err_new={}", 
                 created_group_number, static_cast<int>(err_new));
        
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - createGroup returned: group_number={}, err_new={}", 
                  created_group_number, static_cast<int>(err_new));

        if (err_new != TOX_ERR_GROUP_NEW_OK || created_group_number == UINT32_MAX) {
            group_number = UINT32_MAX;
            creation_success = false;
        } else {
            group_number = created_group_number;
            creation_success = true;
        }
    }
    
    if (!creation_success || group_number == UINT32_MAX) {
        // Map Tox error to specific error messages for better debugging
        const char* tox_error_name = "UNKNOWN";
        std::string detailed_msg = "Failed to create Tox group";
        
        switch (err_new) {
            case TOX_ERR_GROUP_NEW_OK:
                tox_error_name = "OK";
                break;
            case TOX_ERR_GROUP_NEW_TOO_LONG:
                tox_error_name = "TOO_LONG";
                detailed_msg = "Group name or self name exceeds maximum length";
                break;
            case TOX_ERR_GROUP_NEW_EMPTY:
                tox_error_name = "EMPTY";
                detailed_msg = "Group name or self name is empty";
                break;
            case TOX_ERR_GROUP_NEW_INIT:
                tox_error_name = "INIT";
                detailed_msg = "Group instance failed to initialize (Tox may not be ready)";
                break;
            case TOX_ERR_GROUP_NEW_STATE:
                tox_error_name = "STATE";
                detailed_msg = "Group state failed to initialize (cryptographic signing error)";
                break;
            case TOX_ERR_GROUP_NEW_ANNOUNCE:
                tox_error_name = "ANNOUNCE";
                detailed_msg = "Group failed to announce to DHT (network error, may need connection)";
                break;
            default:
                tox_error_name = "UNKNOWN";
                detailed_msg = "Unknown error from tox_group_new";
                break;
        }
        
        V2TIM_LOG(kError, "CreateGroup: ERROR - Failed to create group: err_new={} ({}), group_number={}, group_name_len={}, self_name_len={}", 
                  static_cast<int>(err_new), tox_error_name, group_number, group_name_str.length(), self_name.length());
        V2TIM_LOG(kError, "CreateGroup: ERROR - Detailed message: {}", detailed_msg);
        
        // Check connection status for network-related errors
        if (err_new == TOX_ERR_GROUP_NEW_ANNOUNCE || err_new == TOX_ERR_GROUP_NEW_INIT) {
            TOX_CONNECTION connection = tox_self_get_connection_status(tox);
            V2TIM_LOG(kError, "CreateGroup: ERROR - Tox connection status: {} (0=NONE, 1=UDP, 2=TCP)", static_cast<int>(connection));
            if (connection == TOX_CONNECTION_NONE) {
                detailed_msg += " (Tox not connected to network)";
            }
        }
        
        // Map Tox error to V2TIM error
        int v2_err = ERR_INVALID_PARAMETERS;
        if (callback) {
            V2TIM_LOG(kInfo, "CreateGroup: Calling callback->OnError with v2_err={}, detailed_msg={}", v2_err, detailed_msg);
            callback->OnError(v2_err, detailed_msg.c_str());
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: callback is null, cannot report error");
        }
        V2TIM_LOG(kInfo, "CreateGroup: EXIT - Early return due to createGroup failure");
        return;
    }
    
    V2TIM_LOG(kInfo, "CreateGroup: Step 5 - SUCCESS - Group created with group_number={}", group_number);

    // Determine the final Group ID
    V2TIMString finalGroupID = groupID;
    if (finalGroupID.Empty()) {
        // Generate a unique ID if none provided.
        // IMPORTANT: Do NOT use conference_number directly, as Tox may reuse conference numbers
        // when groups are deleted. Instead, use a global counter to ensure uniqueness.
        
        // First, find the maximum ID number from all existing group IDs to avoid conflicts
        // This handles the case where groups were restored from persistence but mappings were cleared
        // We scan both the mapping and V2TIMGroupManagerImpl to find the highest numeric ID
        uint64_t max_existing_id = 0;
        
        // Scan the mapping (need to lock for this)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto& pair : group_id_to_group_number_) {
                const std::string& existing_id = pair.first.CString();
                // Check if it matches "tox_<number>" pattern
                if (existing_id.length() > 4 && existing_id.substr(0, 4) == "tox_") {
                    try {
                        uint64_t id_num = std::stoull(existing_id.substr(4));
                        if (id_num > max_existing_id) {
                            max_existing_id = id_num;
                        }
                    } catch (...) {
                        // Ignore parsing errors for non-numeric IDs (e.g., "tox_community_123")
                    }
                }
            }
        }
        
        // Also check from Dart layer's persistence storage to get groups that might be restored
        // but not yet in the mapping (e.g., during startup before GetJoinedGroupList is called)
        // This is critical to avoid ID conflicts with restored groups
        // Note: We call this OUTSIDE the mutex lock to avoid deadlock
        // R-07: Use Core metadata (known groups)
        std::vector<std::string> known = GetKnownGroupIDs();
        if (!known.empty()) {
            V2TIM_LOG(kInfo, "CreateGroup: GetKnownGroupIDs returned {} group IDs", known.size());
            for (const auto& line : known) {
                if (line.empty()) continue;
                V2TIM_LOG(kInfo, "CreateGroup: checking existing group ID: {}", line);
                if (line.length() > 4 && line.substr(0, 4) == "tox_") {
                    try {
                        uint64_t id_num = std::stoull(line.substr(4));
                        if (id_num > max_existing_id) {
                            max_existing_id = id_num;
                            V2TIM_LOG(kInfo, "CreateGroup: updated max_existing_id to {}", max_existing_id);
                        }
                    } catch (...) {
                        V2TIM_LOG(kWarning, "CreateGroup: failed to parse ID number from {}", line);
                    }
                }
            }
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: GetKnownGroupIDs returned 0, falling back to GetAllGroupIDsSync");
            // Fallback to GetAllGroupIDsSync if FFI call fails
            V2TIMGroupManagerImpl* groupManagerImpl = static_cast<V2TIMGroupManagerImpl*>(GetGroupManager());
            if (groupManagerImpl) {
                std::vector<std::string> all_group_ids = groupManagerImpl->GetAllGroupIDsSync();
                V2TIM_LOG(kInfo, "CreateGroup: GetAllGroupIDsSync returned {} group IDs", all_group_ids.size());
                for (const auto& existing_id : all_group_ids) {
                    V2TIM_LOG(kInfo, "CreateGroup: checking existing group ID: {}", existing_id);
                    // Check if it matches "tox_<number>" pattern
                    if (existing_id.length() > 4 && existing_id.substr(0, 4) == "tox_") {
                        try {
                            uint64_t id_num = std::stoull(existing_id.substr(4));
                            V2TIM_LOG(kInfo, "CreateGroup: parsed ID number: {} from {}", id_num, existing_id);
                            if (id_num > max_existing_id) {
                                max_existing_id = id_num;
                                V2TIM_LOG(kInfo, "CreateGroup: updated max_existing_id to {}", max_existing_id);
                            }
                        } catch (...) {
                            // Ignore parsing errors for non-numeric IDs
                            V2TIM_LOG(kWarning, "CreateGroup: failed to parse ID number from {}", existing_id);
                        }
                    }
                }
            }
        }
        
        // Now lock again to update the counter and generate the new ID
        {
            std::lock_guard<std::mutex> lock(mutex_);
            // Use global counter so "tox_0","tox_1",... are unique across all instances.
            // Prevents JoinGroup(on instance B) from matching stored_chat_id from instance A
            // when both use the same string "tox_0" for different groups.
            uint64_t candidate_id = g_next_group_id_global.fetch_add(1);
            next_group_id_counter_ = candidate_id + 1; // Keep per-instance in sync for local use

            // CRITICAL FIX: Ensure candidate_id is at least max_existing_id + 1
            // Without this, the global counter may start at 0 and generate "tox_0" which
            // already exists in Dart persistence (from a previous session), causing ID reuse
            // and historical messages being loaded for the new group.
            if (candidate_id <= max_existing_id) {
                candidate_id = max_existing_id + 1;
                // Update global counter so subsequent calls also start from the right place
                uint64_t expected = g_next_group_id_global.load();
                while (expected <= candidate_id) {
                    if (g_next_group_id_global.compare_exchange_weak(expected, candidate_id + 1)) {
                        break;
                    }
                }
                next_group_id_counter_ = candidate_id + 1;
                V2TIM_LOG(kInfo, "CreateGroup: Bumped candidate_id to {} (was <= max_existing_id={})",
                          candidate_id, max_existing_id);
            }

            V2TIM_LOG(kInfo, "CreateGroup: max_existing_id={}, candidate_id={} (global)",
                      max_existing_id, candidate_id);

            char generated_id_buf[32]; // Enough for "tox_" + uint64_t
            snprintf(generated_id_buf, sizeof(generated_id_buf), "tox_%llu", (unsigned long long)candidate_id);

            // Double-check: collect known group IDs for collision check (R-07: Core metadata)
            std::unordered_set<std::string> dart_known_ids;
            for (const auto& g : GetKnownGroupIDs()) dart_known_ids.insert(g);
            while (group_id_to_group_number_.find(generated_id_buf) != group_id_to_group_number_.end() ||
                   dart_known_ids.count(std::string(generated_id_buf)) > 0) {
                candidate_id = g_next_group_id_global.fetch_add(1);
                if (candidate_id <= max_existing_id) candidate_id = max_existing_id + 1;
                snprintf(generated_id_buf, sizeof(generated_id_buf), "tox_%llu", (unsigned long long)candidate_id);
            }
            
            finalGroupID = generated_id_buf;
            // [tim2tox-debug] Record groupID generation
            V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: Generated groupID={} from candidate_id={}, max_existing_id={}", 
                     finalGroupID.CString(), candidate_id, max_existing_id);
        }
    } else {
        // Validate provided groupID uniqueness
        std::lock_guard<std::mutex> lock(mutex_);
        if (group_id_to_group_number_.find(finalGroupID) != group_id_to_group_number_.end()) {
            V2TIM_LOG(kWarning, "CreateGroup: Provided groupID {} already exists, will overwrite mapping", finalGroupID.CString());
        }
    }

    // Step 8: Get chat_id and store it for persistence (only for group type, not conference)
    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Attempting to get chat_id and store for persistence");
    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Pre-check: is_conference={}, group_number={}, finalGroupID.Empty()={}, tox_manager={}", 
              is_conference, group_number, finalGroupID.Empty(), (void*)tox_manager);
    
    // Note: Only attempt to get chat_id for group type (not conference)
    // Conference doesn't support chat_id, it will be restored from savedata automatically
    if (!is_conference && group_number != UINT32_MAX && !finalGroupID.Empty() && tox_manager) {
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - All pre-checks passed, proceeding to get chat_id");
        
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat_id;
        
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Calling tox_manager->getGroupChatId for group_number={}", group_number);
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - chat_id buffer address={}, size={}", (void*)chat_id, TOX_GROUP_CHAT_ID_SIZE);
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - err_chat_id pointer={}", (void*)&err_chat_id);
        
        bool get_chat_id_result = tox_manager->getGroupChatId(group_number, chat_id, &err_chat_id);
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - getGroupChatId returned: result={}, err_chat_id={}", 
                  get_chat_id_result, static_cast<int>(err_chat_id));
        
        if (get_chat_id_result && err_chat_id == TOX_ERR_GROUP_STATE_QUERY_OK) {
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Successfully retrieved chat_id");
            
            // Convert to hex string (32 bytes = 64 hex characters)
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Converting chat_id to hex string");
            std::ostringstream oss;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
            }
            std::string chat_id_hex = oss.str();
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - chat_id_hex length={}, first 16 chars={}", 
                      chat_id_hex.length(), chat_id_hex.substr(0, std::min<size_t>(16, chat_id_hex.length())));
            
            // Validate finalGroupID before using CString()
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Validating finalGroupID before calling CString()");
            const char* group_id_cstr = finalGroupID.CString();
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - finalGroupID.CString() returned: {}", (void*)group_id_cstr);
            
            if (group_id_cstr) {
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - group_id_cstr is valid, value={}", group_id_cstr);
            } else {
                V2TIM_LOG(kError, "CreateGroup: Step 8 - ERROR - group_id_cstr is NULL!");
            }
            
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - chat_id_hex.empty()={}", chat_id_hex.empty());
            
            if (group_id_cstr && !chat_id_hex.empty()) {
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - All validations passed, storing chat_id");
                
                // Store chat_id via FFI for persistence
                // Note: Function is already declared with extern "C" at file scope (line 38)
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Calling tim2tox_ffi_set_group_chat_id");
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Parameters: group_id={}, chat_id={}", 
                          group_id_cstr, chat_id_hex.substr(0, std::min<size_t>(16, chat_id_hex.length())));
                
                // Add protection around FFI call
                try {
                    SetGroupChatIdInStorage(group_id_cstr, chat_id_hex.c_str());
                    int ffi_result = 1;
                    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - tim2tox_ffi_set_group_chat_id returned: {}", ffi_result);
                } catch (...) {
                    V2TIM_LOG(kError, "CreateGroup: Step 8 - EXCEPTION caught in tim2tox_ffi_set_group_chat_id!");
                    // Continue execution even if FFI call fails
                }
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - tim2tox_ffi_set_group_chat_id completed");
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Stored chat_id for group {}: {}", group_id_cstr, chat_id_hex.c_str());
                
                // Store in memory mapping
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Storing chat_id in memory mapping");
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Acquired mutex for memory mapping");
                    group_id_to_chat_id_[finalGroupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                    chat_id_to_group_id_[chat_id_hex] = finalGroupID;
                    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Memory mapping updated successfully");
                }
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Released mutex");
            } else {
                V2TIM_LOG(kWarning, "CreateGroup: Step 8 - Skipping chat_id storage - group_id_cstr={}, chat_id_hex.empty()={}", 
                         (void*)group_id_cstr, chat_id_hex.empty());
            }
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: Step 8 - Failed to get chat_id for group_number={}, get_result={}, error={}", 
                     group_number, get_chat_id_result, static_cast<int>(err_chat_id));
        }
    } else {
        V2TIM_LOG(kWarning, "CreateGroup: Step 8 - Skipping chat_id retrieval - group_number={}, finalGroupID.Empty()={}, tox_manager={}", 
                 group_number, finalGroupID.Empty(), (void*)tox_manager);
    }
    
    // Step 9: Store the mapping (both ways)
    V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Storing group mapping");
    V2TIM_LOG(kInfo, "CreateGroup: Step 9 - finalGroupID={}, group_number={}", 
              finalGroupID.CString() ? finalGroupID.CString() : "null", group_number);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Acquired mutex for mapping storage");
        // Check if groupID already exists? V2TIM allows providing ID, Tox assigns number.
        // If finalGroupID exists in group_id_to_conference_number_, maybe error? Or overwrite?
        // For now, assume overwrite is fine or provided IDs are unique.
        auto existing_it = group_id_to_group_number_.find(finalGroupID);
        if (existing_it != group_id_to_group_number_.end()) {
            V2TIM_LOG(kWarning, "CreateGroup: Step 9 - finalGroupID {} already exists in mapping with group_number {}, overwriting", 
                     finalGroupID.CString() ? finalGroupID.CString() : "null", existing_it->second);
        }
        
        group_id_to_group_number_[finalGroupID] = group_number;
        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Stored group_id_to_group_number_ mapping");
        
        group_number_to_group_id_[group_number] = finalGroupID;
        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Stored group_number_to_group_id_ mapping");
        
        // Store group type mapping.
        // Preserve the original group_type_str supplied by the caller (e.g. 'Meeting',
        // 'Public', 'Private', 'Work', 'AVChatRoom', 'Community') so that
        // GetGroupsInfo/JSON-serialization round-trips return the same label the
        // caller created the group with. Old API (Tox conference) is always tagged
        // as "conference"; new API groups fall back to "group" only when the
        // caller did not supply a more specific label.
        std::string type_for_map;
        if (is_conference) {
            type_for_map = "conference";
        } else if (!group_type_str.empty()) {
            type_for_map = group_type_str;
        } else {
            type_for_map = "group";
        }
        group_id_to_type_[finalGroupID] = type_for_map;
        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Stored group type: {}", type_for_map);

        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Mapping storage completed");
    }
    V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Released mutex");

    // Step 9.5: Store group type to persistent storage. Mirrors the in-memory
    // mapping above so that joiner instances and post-restart lookups can recover
    // the original label.
    if (!finalGroupID.Empty()) {
        const char* group_id_cstr = finalGroupID.CString();
        if (group_id_cstr) {
            std::string type_to_store;
            if (is_conference) {
                type_to_store = "conference";
            } else if (!group_type_str.empty()) {
                type_to_store = group_type_str;
            } else {
                type_to_store = "group";
            }
            V2TIM_LOG(kInfo, "CreateGroup: Step 9.5 - Storing group type to persistent storage: group_id={}, type={}",
                     group_id_cstr, type_to_store);
            try {
                SetGroupTypeInStorage(group_id_cstr, type_to_store);
                V2TIM_LOG(kInfo, "CreateGroup: Step 9.5 - Successfully stored group type");
            } catch (...) {
                V2TIM_LOG(kError, "CreateGroup: Step 9.5 - EXCEPTION caught in tim2tox_ffi_set_group_type!");
            }
        }
    }

    V2TIM_LOG(kInfo, "CreateGroup: Step 10 - Calling success callback");
    V2TIM_LOG(kInfo, "CreateGroup: Created group {} (group_number {})", 
              finalGroupID.CString() ? finalGroupID.CString() : "null", group_number);
    
    // Log group info for debugging: check if founder can see itself in member list
    // Note: GetCurrentInstanceId is already declared at file scope (line 27)
    int64_t current_instance_id = GetCurrentInstanceId();
    fprintf(stdout, "[CreateGroup] ========== Group Created ==========\n");
    fprintf(stdout, "[CreateGroup] instance_id=%lld, groupID=%s, group_number=%u\n", 
            (long long)current_instance_id, finalGroupID.CString() ? finalGroupID.CString() : "null", group_number);
    
    // Check if founder can see itself in the group immediately after creation
    Tox* tox_for_check = tox_manager_ ? tox_manager_->getTox() : nullptr;
    if (tox_for_check && group_number != UINT32_MAX) {
        int founder_peer_count = 0;
        for (Tox_Group_Peer_Number peer_id = 0; peer_id < 10; ++peer_id) {
            uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_Peer_Query err_key;
            if (tox_manager_ && tox_manager_->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) &&
                err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
                founder_peer_count++;
                std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
                fprintf(stdout, "[CreateGroup] Founder sees peer_id=%u, userID=%s\n", peer_id, userID.c_str());
            } else {
                break;
            }
        }
        fprintf(stdout, "[CreateGroup] Founder sees %d peer(s) immediately after creation\n", founder_peer_count);
        
        // Check group connection status
        Tox_Err_Group_Is_Connected err_conn = TOX_ERR_GROUP_IS_CONNECTED_GROUP_NOT_FOUND;
        bool group_connected = false;
        if (tox_manager_) {
            group_connected = tox_manager_->isGroupConnected(group_number, &err_conn);
        }
        fprintf(stdout, "[CreateGroup] Group connection status: connected=%d, err=%d\n", 
                group_connected ? 1 : 0, static_cast<int>(err_conn));
    }
    fprintf(stdout, "[CreateGroup] ====================================\n");
    fflush(stdout);
    
    // Step 10.5: Manually trigger HandleGroupSelfJoin to notify listeners about group creation
    // This is necessary because tox_group_new/createGroup may not immediately trigger
    // the on_group_self_join callback, but we need to notify listeners via OnGroupCreated
    V2TIM_LOG(kInfo, "CreateGroup: Step 10.5 - Manually calling HandleGroupSelfJoin to trigger OnGroupCreated callback");
    fprintf(stdout, "[CreateGroup] Step 10.5: Manually calling HandleGroupSelfJoin(group_number=%u) to trigger OnGroupCreated\n", group_number);
    fflush(stdout);
    HandleGroupSelfJoin(group_number);
    V2TIM_LOG(kInfo, "CreateGroup: Step 10.5 - HandleGroupSelfJoin completed");
    
    if (callback) {
        V2TIM_LOG(kInfo, "CreateGroup: Step 10 - callback is valid, calling OnSuccess");
        const char* final_group_id_cstr = finalGroupID.CString();
        V2TIM_LOG(kInfo, "CreateGroup: Step 10 - finalGroupID.CString()={}", (void*)final_group_id_cstr);
        if (final_group_id_cstr) {
            V2TIM_LOG(kInfo, "CreateGroup: Step 10 - Calling callback->OnSuccess with groupID={}", final_group_id_cstr);
            callback->OnSuccess(finalGroupID);
            V2TIM_LOG(kInfo, "CreateGroup: Step 10 - callback->OnSuccess completed");
        } else {
            V2TIM_LOG(kError, "CreateGroup: Step 10 - ERROR - finalGroupID.CString() returned NULL, cannot call OnSuccess");
        }
    } else {
        V2TIM_LOG(kWarning, "CreateGroup: Step 10 - callback is null, skipping OnSuccess");
    }
    
    V2TIM_LOG(kInfo, "CreateGroup: EXIT - Successfully completed");
}

void V2TIMManagerImpl::JoinGroup(const V2TIMString& groupID, const V2TIMString& message, V2TIMCallback* callback) {
    // Get start timestamp for detailed timing
    auto start_time = std::chrono::steady_clock::now();
    auto start_timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    
    fprintf(stdout, "[JoinGroup] ========== JoinGroup called ==========\n");
    fprintf(stdout, "[JoinGroup] start_timestamp_ms=%lld\n", (long long)start_timestamp_ms);
    fprintf(stdout, "[JoinGroup] this=%p\n", (void*)this);
    // Note: GetCurrentInstanceId and GetInstanceIdFromManager are already declared at file scope (lines 27-28)
    int64_t current_instance_id = GetCurrentInstanceId();
    int64_t this_instance_id = GetInstanceIdFromManager(this);
    fprintf(stdout, "[JoinGroup] current_instance_id=%lld, this_instance_id=%lld\n", 
            (long long)current_instance_id, (long long)this_instance_id);
    fflush(stdout);
    V2TIM_LOG(kInfo, "[JoinGroup] ========== JoinGroup called ==========");
    V2TIM_LOG(kInfo, "[JoinGroup] this=%p, current_instance_id=%lld, this_instance_id=%lld", 
              (void*)this, (long long)current_instance_id, (long long)this_instance_id);
    V2TIM_LOG(kInfo, "[JoinGroup] groupID: {}", groupID.CString() ? groupID.CString() : "null");
    V2TIM_LOG(kInfo, "[JoinGroup] message: {}", message.CString() ? message.CString() : "null");
    V2TIM_LOG(kInfo, "[JoinGroup] callback: {}", (void*)callback);
    
    // Get ToxManager and verify it's valid
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        fprintf(stderr, "[JoinGroup] ERROR: ToxManager is null for groupID=%s, instance_id=%lld\n", 
                groupID.CString(), (long long)current_instance_id);
        fflush(stderr);
        V2TIM_LOG(kError, "[JoinGroup] ERROR: ToxManager is null");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not available");
        return;
    }
    
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        fprintf(stderr, "[JoinGroup] ERROR: Tox instance is null for groupID=%s, instance_id=%lld, tox_manager=%p\n", 
                groupID.CString(), (long long)current_instance_id, (void*)tox_manager);
        fflush(stderr);
        V2TIM_LOG(kError, "[JoinGroup] ERROR: Tox instance not available");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }
    fprintf(stdout, "[JoinGroup] ✅ ToxManager and Tox instance available\n");
    fflush(stdout);
    V2TIM_LOG(kInfo, "[JoinGroup] Tox instance available");

    // Idempotent join for conferences: AV/text conferences auto-join inside the
    // invite callback (see the conference invite handler's toxav_join_av_groupchat /
    // tox_conference_join path) and then map the invite's tox_conf_<friend>_<ts> ID
    // with type "conference". A caller that then follows V2TIM semantics — join with
    // the groupID it received in onMemberInvited — would fall through to the pending
    // path, find no pending (we auto-joined, so none was stored) and a non-creator
    // ID, and fail with 6017 ERR_INVALID_PARAMETERS. For an already-joined conference
    // the join is a no-op success. Scoped to conference type so NGCv2 ("group") join
    // flows keep their existing pending/chat_id behaviour untouched.
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const bool already_mapped =
            group_id_to_group_number_.find(groupID) != group_id_to_group_number_.end();
        auto type_it = group_id_to_type_.find(groupID);
        const bool is_conference =
            type_it != group_id_to_type_.end() && type_it->second == "conference";
        if (already_mapped && is_conference) {
            V2TIM_LOG(kInfo, "[JoinGroup] conference groupID {} already mapped (already a member) — returning success (idempotent join)",
                      groupID.CString());
            if (callback) callback->OnSuccess();
            return;
        }
    }

    // Single-instance real client: allow joining a public group by passing chat_id (64-char hex) as groupID
    // so the creator can share the chat_id (e.g. link/QR) and others join without invite or cross-instance storage.
    char stored_chat_id[65]; // 32 bytes * 2 (hex) + 1 (null terminator)
    bool has_stored_chat_id = false;
    std::string groupID_str(groupID.CString() ? groupID.CString() : "");
    if (groupID_str.length() == 64) {
        bool all_hex = true;
        for (size_t i = 0; i < 64; ++i) {
            char c = groupID_str[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
                all_hex = false;
                break;
            }
        }
        if (all_hex) {
            memcpy(stored_chat_id, groupID_str.c_str(), 64);
            stored_chat_id[64] = '\0';
            has_stored_chat_id = true;
            V2TIM_LOG(kInfo, "[JoinGroup] groupID is 64-char hex, using as chat_id for join (single-instance join public group)");
        }
    }
    if (!has_stored_chat_id) {
        // Try to get chat_id from storage (or cross-instance in tests)
        V2TIM_LOG(kInfo, "[JoinGroup] Checking for stored chat_id for groupID: {}", groupID.CString());
        has_stored_chat_id = GetGroupChatIdFromStorage(groupID.CString(), stored_chat_id, sizeof(stored_chat_id));
        V2TIM_LOG(kInfo, "[JoinGroup] has_stored_chat_id: {}", has_stored_chat_id);
    }
    if (has_stored_chat_id) {
        V2TIM_LOG(kInfo, "[JoinGroup] Found stored chat_id: {} (length={})", stored_chat_id, strlen(stored_chat_id));
    } else {
        V2TIM_LOG(kInfo, "[JoinGroup] No stored chat_id found, will check for pending invite");
    }
    
    Tox_Group_Number group_number = UINT32_MAX;
    
    if (has_stored_chat_id) {
        V2TIM_LOG(kInfo, "[JoinGroup] Path 1: Joining group using stored chat_id");
        // Convert hex string to binary chat_id
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        std::string chat_id_hex(stored_chat_id);
        V2TIM_LOG(kInfo, "[JoinGroup] Converting chat_id hex to binary: {}", chat_id_hex);
        std::istringstream iss(chat_id_hex);
        for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
            std::string byte_str = chat_id_hex.substr(i * 2, 2);
            char* endptr;
            unsigned long byte_val = strtoul(byte_str.c_str(), &endptr, 16);
            if (*endptr != '\0' || byte_val > 255) {
                V2TIM_LOG(kError, "[JoinGroup] ERROR: Invalid chat_id hex string at byte {}, byte_str={}, byte_val={}", i, byte_str, byte_val);
                if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid chat_id");
                return;
            }
            chat_id[i] = static_cast<uint8_t>(byte_val);
        }
        V2TIM_LOG(kInfo, "[JoinGroup] Successfully converted chat_id hex to binary");
        
        // Join group using chat_id
        std::string self_name = GetToxManager()->getName();
        if (self_name.empty()) {
            self_name = "User";
        }
        V2TIM_LOG(kInfo, "[JoinGroup] Using self_name: {} (length={})", self_name, self_name.length());
        
        // Log self connection status and public key before joining
        TOX_CONNECTION self_connection = tox_self_get_connection_status(tox);
        fprintf(stdout, "[JoinGroup] Self connection status before join: %d (0=NONE, 1=TCP, 2=UDP)\n", 
                static_cast<int>(self_connection));
        fflush(stdout);
        
        // Get self public key for debugging
        uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, self_pubkey);
        std::string self_userID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
        fprintf(stdout, "[JoinGroup] Self userID (public key): %s\n", self_userID.c_str());
        fflush(stdout);
        
        // Get friend count
        size_t friend_count = tox_self_get_friend_list_size(tox);
        fprintf(stdout, "[JoinGroup] Friend count before join: %zu\n", friend_count);
        fflush(stdout);
        
        // Log friend connection statuses
        if (friend_count > 0) {
            std::vector<uint32_t> friend_list(friend_count);
            tox_self_get_friend_list(tox, friend_list.data());
            fprintf(stdout, "[JoinGroup] Friend connection statuses:\n");
            for (size_t i = 0; i < friend_count; i++) {
                uint8_t friend_pubkey[TOX_PUBLIC_KEY_SIZE];
                TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
                if (tox_friend_get_public_key(tox, friend_list[i], friend_pubkey, &err_key) &&
                    err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
                    std::string friend_userID = ToxUtil::tox_bytes_to_hex(friend_pubkey, TOX_PUBLIC_KEY_SIZE);
                    TOX_ERR_FRIEND_QUERY err_conn;
                    TOX_CONNECTION friend_conn = tox_friend_get_connection_status(tox, friend_list[i], &err_conn);
                    fprintf(stdout, "[JoinGroup]   Friend[%zu]: userID=%s, connection=%d (0=NONE, 1=TCP, 2=UDP), err=%d\n", 
                            i, friend_userID.c_str(), static_cast<int>(friend_conn), static_cast<int>(err_conn));
                }
            }
            fflush(stdout);
        }
        
        V2TIM_LOG(kInfo, "[JoinGroup] Calling GetToxManager()->joinGroup with chat_id");
        auto before_join_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        fprintf(stdout, "[JoinGroup] About to call joinGroup (timestamp_ms=%lld)\n", (long long)before_join_ms);
        fflush(stdout);
        
        Tox_Err_Group_Join err_join;
        group_number = GetToxManager()->joinGroup(
            chat_id,
            reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
            nullptr, 0, // No password for now
            &err_join
        );
        
        auto after_join_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        auto join_duration_ms = after_join_ms - before_join_ms;
        
        fprintf(stdout, "[JoinGroup] joinGroup returned: group_number=%u, err_join=%d (duration=%lld ms)\n", 
                group_number, static_cast<int>(err_join), (long long)join_duration_ms);
        fflush(stdout);
        V2TIM_LOG(kInfo, "[JoinGroup] joinGroup returned: group_number={}, err_join={}", group_number, static_cast<int>(err_join));
        if (err_join != TOX_ERR_GROUP_JOIN_OK || group_number == UINT32_MAX) {
            fprintf(stdout, "[JoinGroup] FAILED to join group using chat_id: err_join=%d, group_number=%u\n", 
                    static_cast<int>(err_join), group_number);
            fflush(stdout);
            V2TIM_LOG(kError, "[JoinGroup] FAILED to join group using chat_id");
            V2TIM_LOG(kError, "[JoinGroup] Error code: {} (0=OK, 1=INVALID_CHAT_ID, 2=TOO_LONG, 3=FAIL)", static_cast<int>(err_join));
            V2TIM_LOG(kError, "[JoinGroup] group_number={} (UINT32_MAX={})", group_number, UINT32_MAX);
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to join Tox group");
            return;
        }
        fprintf(stdout, "[JoinGroup] ✅ Successfully joined group using chat_id, group_number=%u\n", group_number);
        fflush(stdout);
        V2TIM_LOG(kInfo, "[JoinGroup] ✅ Successfully joined group using chat_id, group_number={}", group_number);
        // Persist chat_id for this instance (groupID may be 64-char chat_id when joining public group)
        SetGroupChatIdInStorage(groupID.CString(), stored_chat_id);
    } else {
        V2TIM_LOG(kInfo, "[JoinGroup] Path 2: Joining group using pending invite");
        // Try to use pending invite if available
        PendingInvite inv;
        V2TIMString used_pending_id;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            V2TIM_LOG(kInfo, "[JoinGroup] Checking pending invites, total pending: {}", pending_group_invites_.size());
            auto it = pending_group_invites_.find(groupID);
            if (it == pending_group_invites_.end()) {
                // No exact match: use first pending only when groupID looks like creator-assigned (tox_group_*).
                // Invite flow: app passes creator's groupID e.g. tox_group_0, tox_group_1, pending is stored as tox_inv_%u_%llu.
                // Do not use first pending for custom IDs (e.g. tox_private_*) so "join without invite" fails with 6017.
                // Note: "tox_group_0" has 11 chars; prefix "tox_group_" is 10 chars, digit at index 10.
                std::string gidStr(groupID.CString());
                bool isCreatorStyleGroupId = (gidStr.size() >= 11 && gidStr.substr(0, 10) == "tox_group_" && gidStr[10] >= '0' && gidStr[10] <= '9');
                if (pending_group_invites_.size() >= 1 && isCreatorStyleGroupId) {
                    V2TIM_LOG(kInfo, "[JoinGroup] No exact match for groupID: {}, but {} pending invite(s), using first (creator-style ID)",
                              groupID.CString(), pending_group_invites_.size());
                    it = pending_group_invites_.begin();
                    used_pending_id = it->first;
                    V2TIM_LOG(kInfo, "[JoinGroup] Using pending invite with ID: {}", used_pending_id.CString());
                } else if (pending_group_invites_.size() >= 1 && !isCreatorStyleGroupId) {
                    int64_t join_instance_id = GetInstanceIdFromManager(this);
                    V2TIM_LOG(kError, "[JoinGroup] ERROR: No exact match for groupID: {} (custom ID, not using first pending), instance_id={}",
                              groupID.CString(), (long long)join_instance_id);
                    if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Pending invite not found for groupID and no chat_id stored");
                    return;
                } else {
                    int64_t join_instance_id = GetInstanceIdFromManager(this);
                    V2TIM_LOG(kError, "[JoinGroup] ERROR: Pending invite not found for groupID: {} (pending count=0, instance_id={})",
                              groupID.CString(), (long long)join_instance_id);
                    fprintf(stderr, "[JoinGroup] Pending count=0 for groupID=%s, instance_id=%lld (invitee never received invite or wrong instance)\n",
                            groupID.CString(), (long long)join_instance_id);
                    fflush(stderr);
                    if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Pending invite not found for groupID and no chat_id stored");
                    return;
                }
            } else {
                used_pending_id = it->first;
            }
            inv = it->second;
            V2TIM_LOG(kInfo, "[JoinGroup] Found pending invite: friend_number={}, cookie_size={}, pending_id={}", 
                     inv.friend_number, inv.cookie.size(), used_pending_id.CString());
        }
        
        // Accept invite using tox_group_invite_accept
        std::string self_name = GetToxManager()->getName();
        if (self_name.empty()) {
            self_name = "User";
        }
        V2TIM_LOG(kInfo, "[JoinGroup] Using self_name: {} (length={})", self_name, self_name.length());
        V2TIM_LOG(kInfo, "[JoinGroup] Calling tox_group_invite_accept: friend_number={}, cookie_size={}", 
                 inv.friend_number, inv.cookie.size());
        
        Tox_Err_Group_Invite_Accept err_accept;
        group_number = tox_group_invite_accept(
            tox,
            inv.friend_number,
            inv.cookie.data(), inv.cookie.size(),
            reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
            nullptr, 0, // No password
            &err_accept
        );
        
        V2TIM_LOG(kInfo, "[JoinGroup] tox_group_invite_accept returned: group_number={}, err_accept={}", 
                 group_number, static_cast<int>(err_accept));
        if (err_accept != TOX_ERR_GROUP_INVITE_ACCEPT_OK || group_number == UINT32_MAX) {
            V2TIM_LOG(kError, "[JoinGroup] FAILED to accept invite");
            V2TIM_LOG(kError, "[JoinGroup] Error code: {} (0=OK, 1=FRIEND_NOT_FOUND, 2=INVALID_LENGTH, 3=INVITE_FAIL)", 
                     static_cast<int>(err_accept));
            V2TIM_LOG(kError, "[JoinGroup] group_number={} (UINT32_MAX={})", group_number, UINT32_MAX);
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to accept Tox group invite");
            return;
        }
        V2TIM_LOG(kInfo, "[JoinGroup] ✅ Successfully accepted invite, group_number={}", group_number);
        
        // Get chat_id and store it for persistence
        V2TIM_LOG(kInfo, "[JoinGroup] Attempting to get chat_id for group_number={}", group_number);
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat_id;
        bool got_chat_id = GetToxManager()->getGroupChatId(group_number, chat_id, &err_chat_id);
        V2TIM_LOG(kInfo, "[JoinGroup] getGroupChatId returned: got_chat_id={}, err_chat_id={}", 
                 got_chat_id, static_cast<int>(err_chat_id));
        
        if (got_chat_id && err_chat_id == TOX_ERR_GROUP_STATE_QUERY_OK) {
            // Convert to hex string
            std::ostringstream oss;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
            }
            std::string chat_id_hex = oss.str();
            V2TIM_LOG(kInfo, "[JoinGroup] Retrieved chat_id (hex): {} (length={})", chat_id_hex, chat_id_hex.length());
            
            // Store chat_id via FFI for persistence
            // Note: Function is already declared with extern "C" at file scope (line 38)
            SetGroupChatIdInStorage(groupID.CString(), chat_id_hex);
            V2TIM_LOG(kInfo, "[JoinGroup] SetGroupChatIdInStorage completed");
            V2TIM_LOG(kInfo, "[JoinGroup] Stored chat_id for joined group {}: {}", groupID.CString(), chat_id_hex.c_str());
            
            // Store in memory mapping
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_chat_id_[groupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                chat_id_to_group_id_[chat_id_hex] = groupID;
                V2TIM_LOG(kInfo, "[JoinGroup] Stored chat_id mapping: groupID={} <-> chat_id={}", groupID.CString(), chat_id_hex);
            }
        } else {
            V2TIM_LOG(kWarning, "[JoinGroup] ⚠️ Failed to get chat_id for group_number={}, error={}", 
                     group_number, static_cast<int>(err_chat_id));
        }
        
        // Before removing pending invite, trigger onMemberInvited callback with actual groupID
        // This handles the case where JoinGroup was called with actual groupID but pending invite has temp ID
        if (!used_pending_id.Empty() && used_pending_id != groupID) {
            V2TIM_LOG(kInfo, "[JoinGroup] Triggering onMemberInvited with actual groupID={} (was temp={})", 
                     groupID.CString(), used_pending_id.CString());
            fprintf(stdout, "[JoinGroup] Triggering onMemberInvited with actual groupID=%s (was temp=%s)\n", 
                    groupID.CString(), used_pending_id.CString());
            fflush(stdout);
            
            // Get inviter info from pending invite
            PendingInvite* pending_inv = nullptr;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = pending_group_invites_.find(used_pending_id);
                if (it != pending_group_invites_.end()) {
                    pending_inv = &it->second;
                }
            }
            
            if (pending_inv) {
                // Build member list (contains self)
                V2TIMGroupMemberInfoVector memberList;
                V2TIMGroupMemberInfo selfMember;
                Tox* tox = GetToxManager()->getTox();
                if (tox) {
                    uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                    tox_self_get_public_key(tox, self_pubkey);
                    std::string selfUserID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                    selfMember.userID = V2TIMString(selfUserID.c_str());
                    memberList.PushBack(selfMember);
                }
                
                // Build opUser (inviter)
                V2TIMGroupMemberInfo opUser;
                if (!pending_inv->inviter_userID.empty()) {
                    opUser.userID = V2TIMString(pending_inv->inviter_userID.c_str());
                } else {
                    // Fallback: get inviter's public key from friend_number
                    Tox* tox = GetToxManager()->getTox();
                    if (tox) {
                        uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
                        if (tox_friend_get_public_key(tox, pending_inv->friend_number, inviter_pubkey, nullptr)) {
                            std::string inviterUserID = ToxUtil::tox_bytes_to_hex(inviter_pubkey, TOX_PUBLIC_KEY_SIZE);
                            opUser.userID = V2TIMString(inviterUserID.c_str());
                        }
                    }
                }
                
                // Notify listeners with actual groupID
                std::vector<V2TIMGroupListener*> listeners_copy;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
                }
                
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        fprintf(stdout, "[JoinGroup] Calling OnMemberInvited with actual groupID=%s\n", groupID.CString());
                        fflush(stdout);
                        V2TIM_LOG(kInfo, "[JoinGroup] Calling OnMemberInvited: groupID={}, inviter={}, memberCount={}",
                                 groupID.CString(), opUser.userID.CString(), memberList.Size());
                        listener->OnMemberInvited(groupID, opUser, memberList);
                    }
                }
            }
        }
        
        // Remove pending invite (use the ID that was actually used, not necessarily groupID)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            size_t erased = 0;
            if (!used_pending_id.Empty()) {
                erased = pending_group_invites_.erase(used_pending_id);
                V2TIM_LOG(kInfo, "[JoinGroup] Removed pending invite with ID: {} (erased={})", used_pending_id.CString(), erased);
            } else {
                erased = pending_group_invites_.erase(groupID);
                V2TIM_LOG(kInfo, "[JoinGroup] Removed pending invite for groupID: {} (erased={})", groupID.CString(), erased);
            }
        }
    }
    
    // Store group mappings IMMEDIATELY after tox_group_join succeeds
    // This ensures the mapping exists even if onGroupSelfJoin hasn't been triggered yet
    // Note: onGroupSelfJoin will be triggered later when DHT discovers peers
    {
        std::lock_guard<std::mutex> lock(mutex_);
        group_id_to_group_number_[groupID] = group_number;
        group_number_to_group_id_[group_number] = groupID;
        fprintf(stdout, "[JoinGroup] Stored group mapping IMMEDIATELY: groupID=%s <-> group_number=%u\n", 
                groupID.CString(), group_number);
        fprintf(stdout, "[JoinGroup] Total groups in mapping: %zu\n", group_id_to_group_number_.size());
        fflush(stdout);
        // [tim2tox-debug] Record conference_number mapping for JoinGroup
        V2TIM_LOG(kInfo, "[tim2tox-debug] JoinGroup: Stored conference_number mapping: groupID={} <-> group_number={}", 
                 groupID.CString(), group_number);
        V2TIM_LOG(kInfo, "[JoinGroup] Stored group mapping: groupID={} <-> group_number={}", groupID.CString(), group_number);
        V2TIM_LOG(kInfo, "[JoinGroup] Total groups in mapping: {}", group_id_to_group_number_.size());
    }
    
    // Ensure group_info_ has an entry so GetGroupsInfo finds the group before topic/name broadcast arrives
    V2TIMGroupManager* grp_mgr = GetGroupManager();
    if (grp_mgr) {
        V2TIMGroupManagerImpl* grp_impl = static_cast<V2TIMGroupManagerImpl*>(grp_mgr);
        grp_impl->EnsureGroupInfoExists(groupID);
    }
    
    V2TIM_LOG(kInfo, "[JoinGroup] ✅ Successfully joined group {} (group_number={})", groupID.CString(), group_number);
    
    // CRITICAL: tox_group_join is asynchronous and requires DHT peer discovery
    // We need to wait for network synchronization and trigger tox_iterate multiple times
    // to ensure callbacks (onGroupSelfJoin, onGroupPeerJoin) are processed
    // With local bootstrap, this should be much faster - reduce wait time
    // We'll wait up to 1 second for the group to become connected
    if (tox_manager_) {
        V2TIM_LOG(kInfo, "[JoinGroup] Waiting for group to become connected (up to 1 second)...");
        fprintf(stdout, "[JoinGroup] Waiting for group_number=%u to become connected\n", group_number);
        fflush(stdout);
        
        bool is_connected = false;
        const int max_wait_iterations = 20; // 20 * 50ms = 1 second (reduced from 2 seconds)
        TOX_CONNECTION self_connection_start = tox_self_get_connection_status(tox);
        fprintf(stdout, "[JoinGroup] Self connection status at start of wait: %d (0=NONE, 1=TCP, 2=UDP)\n", 
                static_cast<int>(self_connection_start));
        fflush(stdout);
        
        auto wait_start_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        fprintf(stdout, "[JoinGroup] Starting wait loop (timestamp_ms=%lld)\n", (long long)wait_start_ms);
        fflush(stdout);
        
        for (int i = 0; i < max_wait_iterations; i++) {
            auto iteration_start_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            
            // Check if group is connected
            Tox_Err_Group_Is_Connected err_connected;
            is_connected = tox_manager_->isGroupConnected(group_number, &err_connected);
            
            // Log connection status every 5 iterations (more frequent for debugging)
            if (i % 5 == 0 || is_connected) {
                TOX_CONNECTION current_self_conn = tox_self_get_connection_status(tox);
                auto elapsed_ms = iteration_start_ms - wait_start_ms;
                fprintf(stdout, "[JoinGroup] Iteration %d (elapsed=%lld ms): group_connected=%d, self_connection=%d, err_connected=%d\n", 
                        i, (long long)elapsed_ms, is_connected ? 1 : 0, static_cast<int>(current_self_conn), static_cast<int>(err_connected));
                
                // Also check peer count by iterating
                uint32_t peer_count = 0;
                for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                    Tox_Err_Group_Peer_Query err_key;
                    if (tox_group_peer_get_public_key(tox, group_number, peer_id, peer_pubkey, &err_key) &&
                        err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
                        peer_count++;
                    } else {
                        break; // Stop after first error (peers are sequential)
                    }
                }
                fprintf(stdout, "[JoinGroup]   peer_count=%u\n", peer_count);
                fflush(stdout);
            }
            
            if (is_connected) {
                auto connected_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::system_clock::now().time_since_epoch()).count();
                auto wait_duration_ms = connected_ms - wait_start_ms;
                fprintf(stdout, "[JoinGroup] ✅ Group is now connected after %d iterations (%lld ms total wait)\n", 
                        i + 1, (long long)wait_duration_ms);
                fflush(stdout);
                V2TIM_LOG(kInfo, "[JoinGroup] Group is now connected after {} iterations ({} ms)", i + 1, wait_duration_ms);
                break;
            }
            
            // Trigger tox_iterate to process network events
            tox_manager_->iterate(0);
            
            // Small delay between iterations
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        
        if (!is_connected) {
            fprintf(stdout, "[JoinGroup] WARNING: Group is not connected after %d iterations, but continuing anyway\n", 
                    max_wait_iterations);
            fflush(stdout);
            V2TIM_LOG(kWarning, "[JoinGroup] Group is not connected after {} iterations, but continuing anyway", max_wait_iterations);
        }
        
        // Continue iterating a few more times to ensure callbacks are processed
        // With local bootstrap, this should be much faster - reduce to 10 iterations (0.5 seconds)
        fprintf(stdout, "[JoinGroup] Triggering additional tox_iterate calls to process callbacks\n");
        fflush(stdout);
        for (int i = 0; i < 10; i++) {  // Reduced to 10 iterations (0.5 seconds) for local bootstrap
            // Note: GetCurrentInstanceId is already declared at file scope (line 27)
            int64_t current_instance_id = GetCurrentInstanceId();
            if (i == 0 || i == 4 || i == 9) {
                fprintf(stdout, "[JoinGroup] Iteration %d/%d: instance_id=%lld, calling tox_manager_->iterate(0)\n", 
                        i + 1, 10, (long long)current_instance_id);
                fflush(stdout);
            }
            tox_manager_->iterate(0);
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            
            // Check if onGroupSelfJoin was triggered by checking if group_number is in mapping
            // This is a workaround since we can't directly check if callback was called
            bool mapping_exists = false;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                mapping_exists = (group_number_to_group_id_.find(group_number) != group_number_to_group_id_.end());
            }
            
            if (mapping_exists && i > 0 && i % 10 == 0) {
                fprintf(stdout, "[JoinGroup] Mapping exists after %d iterations, callback may have been triggered\n", i + 1);
                fflush(stdout);
            }
            
            // Check peer count in group to see if peers are being discovered
            if (i % 5 == 0 || i < 10) {  // Check more frequently in first 10 iterations
                // Try to count peers by iterating
                int peer_count = 0;
                std::vector<std::string> peer_userids;
                for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                    Tox_Err_Group_Peer_Query err_key;
                    if (GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) &&
                        err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
                        peer_count++;
                        std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
                        peer_userids.push_back(userID);
                    } else {
                        // Stop after first error (peers are sequential)
                        break;
                    }
                }
                fprintf(stdout, "[JoinGroup] After %d iterations: peer_count=%d in group_number=%u", 
                        i + 1, peer_count, group_number);
                if (peer_count > 0) {
                    fprintf(stdout, ", peer_userids=[");
                    for (size_t j = 0; j < peer_userids.size(); j++) {
                        if (j > 0) fprintf(stdout, ", ");
                        fprintf(stdout, "%s", peer_userids[j].c_str());
                    }
                    fprintf(stdout, "]");
                }
                fprintf(stdout, "\n");
                fflush(stdout);
            }
        }
        fprintf(stdout, "[JoinGroup] Completed additional tox_iterate iterations\n");
        fflush(stdout);
        
        // Final check: verify if mapping exists (indicates onGroupSelfJoin was called)
        bool final_mapping_exists = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            final_mapping_exists = (group_number_to_group_id_.find(group_number) != group_number_to_group_id_.end());
        }
        fprintf(stdout, "[JoinGroup] Final mapping check: group_number=%u, mapping_exists=%d\n", 
                group_number, final_mapping_exists ? 1 : 0);
        fflush(stdout);
        
        // Final peer count check after all iterations
        int final_peer_count = 0;
        std::vector<std::pair<Tox_Group_Peer_Number, std::string>> final_peers;
        for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
            uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_Peer_Query err_key;
            if (GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) &&
                err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
                final_peer_count++;
                std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
                final_peers.push_back({peer_id, userID});
                fprintf(stdout, "[JoinGroup] Final peer check: peer_id=%u, userID=%s\n", peer_id, userID.c_str());
                fflush(stdout);
            } else {
                break;
            }
        }
        fprintf(stdout, "[JoinGroup] Final peer count after all iterations: %d in group_number=%u", 
                final_peer_count, group_number);
        if (final_peer_count > 0) {
            fprintf(stdout, ", peers=[");
            for (size_t i = 0; i < final_peers.size(); i++) {
                if (i > 0) fprintf(stdout, ", ");
                fprintf(stdout, "peer_id=%u:userID=%s", final_peers[i].first, final_peers[i].second.c_str());
            }
            fprintf(stdout, "]");
        }
        fprintf(stdout, "\n");
        fflush(stdout);
        
        // Check if we can see other peers (this instance just joined, so we should see founder)
        if (final_peer_count == 1) {
            fprintf(stdout, "[JoinGroup] WARNING: Only 1 peer found after joining. This might indicate:\n");
            fprintf(stdout, "[JoinGroup]   1. Network sync not complete yet\n");
            fprintf(stdout, "[JoinGroup]   2. Founder not visible from this instance\n");
            fprintf(stdout, "[JoinGroup]   3. Need more time for DHT peer discovery\n");
            fprintf(stdout, "[JoinGroup]   4. Group privacy state might be PRIVATE (requires friend connection)\n");
            
            // Check group privacy state
            Tox_Err_Group_State_Query err_privacy;
            Tox_Group_Privacy_State privacy_state = tox_group_get_privacy_state(tox, group_number, &err_privacy);
            fprintf(stdout, "[JoinGroup] Privacy state query: group_number=%u, privacy_state=%d, err=%d\n", 
                    group_number, static_cast<int>(privacy_state), static_cast<int>(err_privacy));
            if (err_privacy == TOX_ERR_GROUP_STATE_QUERY_OK) {
                fprintf(stdout, "[JoinGroup]   Group privacy state: %d (0=PUBLIC, 1=PRIVATE)\n", 
                        static_cast<int>(privacy_state));
                if (privacy_state == TOX_GROUP_PRIVACY_STATE_PRIVATE) {
                    size_t current_friend_count = tox_self_get_friend_list_size(tox);
                    fprintf(stdout, "[JoinGroup]   ⚠️  Group is PRIVATE - requires friend connection to see peers!\n");
                    fprintf(stdout, "[JoinGroup]   ⚠️  Friend count: %zu (need at least 1 friend to see peers in PRIVATE group)\n", current_friend_count);
                    fprintf(stdout, "[JoinGroup]   ⚠️  This explains why only 1 peer is visible - PRIVATE groups need friend connections!\n");
                } else if (privacy_state == TOX_GROUP_PRIVACY_STATE_PUBLIC) {
                    fprintf(stdout, "[JoinGroup]   ✅ Group is PUBLIC - peers should be discoverable via DHT\n");
                } else {
                    fprintf(stdout, "[JoinGroup]   ⚠️  Unknown privacy state: %d\n", static_cast<int>(privacy_state));
                }
            } else {
                fprintf(stdout, "[JoinGroup]   Failed to get privacy state, err=%d\n", 
                        static_cast<int>(err_privacy));
            }
            fflush(stdout);
            
            // Additional wait and iteration for DHT peer discovery (PUBLIC groups need time for DHT sync)
            // With local bootstrap, this should be much faster - reduce wait time
            if (err_privacy == TOX_ERR_GROUP_STATE_QUERY_OK && 
                privacy_state == TOX_GROUP_PRIVACY_STATE_PUBLIC && final_peer_count == 1) {
            fprintf(stdout, "[JoinGroup] ⚠️  PUBLIC group but only 1 peer found. Waiting additional time for DHT sync...\n");
            fflush(stdout);
            // Wait additional 1 second (reduced from 2 seconds) with more iterations for DHT peer discovery
            for (int i = 0; i < 10; i++) {
                GetToxManager()->iterate();
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                
                // Check peer count every 3 iterations (more frequent for faster detection)
                if (i % 3 == 0) {
                    int current_peer_count = 0;
                    for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                        Tox_Err_Group_Peer_Query err_key;
                        if (GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) &&
                            err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
                            current_peer_count++;
                        } else {
                            break;
                        }
                    }
                    fprintf(stdout, "[JoinGroup] Additional wait iteration %d/%d: peer_count=%d\n", 
                            i + 1, 10, current_peer_count);
                    fflush(stdout);
                    if (current_peer_count > 1) {
                        fprintf(stdout, "[JoinGroup] ✅ Found %d peers after additional wait!\n", current_peer_count);
                        fflush(stdout);
                        break;
                    }
                }
            }
            }
        }
        
        // CRITICAL: If mapping exists but onGroupSelfJoin hasn't been triggered yet,
        // manually call HandleGroupSelfJoin to ensure listeners are notified.
        // This is necessary because tox_group_join is asynchronous and onGroupSelfJoin
        // may not be triggered immediately, but we've already stored the mapping.
        if (final_mapping_exists) {
            fprintf(stdout, "[JoinGroup] Mapping exists, manually calling HandleGroupSelfJoin to notify listeners\n");
            fflush(stdout);
            V2TIM_LOG(kInfo, "[JoinGroup] Manually calling HandleGroupSelfJoin for group_number={}", group_number);
            HandleGroupSelfJoin(group_number);
        }
        
        // CRITICAL: For local bootstrap, we need to ensure other peers can see this peer join
        // Check if there are other peers in the group and manually trigger HandleGroupPeerJoin
        // for those peers if DHT discovery hasn't completed yet
        // This helps with local bootstrap where DHT sync should be fast
        fprintf(stdout, "[JoinGroup] Checking for existing peers to notify about this join...\n");
        fflush(stdout);
        
        // Get self peer_id to identify which peer we are
        Tox_Err_Group_Self_Query err_self_final;
        Tox_Group_Peer_Number self_peer_id_final = tox_group_self_get_peer_id(tox, group_number, &err_self_final);
        if (err_self_final == TOX_ERR_GROUP_SELF_QUERY_OK) {
            fprintf(stdout, "[JoinGroup] Self peer_id in group: %u\n", self_peer_id_final);
            fflush(stdout);
            
            // Check all peers in the group
            // If we see other peers, they should see us join via onGroupPeerJoin callback
            // But if DHT sync is slow, we can help by ensuring tox_iterate is called
            // The callback will be triggered automatically when tox_iterate processes the event
            int visible_peer_count = 0;
            for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                Tox_Err_Group_Peer_Query err_peer_check;
                if (tox_group_peer_get_public_key(tox, group_number, peer_id, peer_pubkey, &err_peer_check) &&
                    err_peer_check == TOX_ERR_GROUP_PEER_QUERY_OK) {
                    visible_peer_count++;
                    if (peer_id != self_peer_id_final) {
                        fprintf(stdout, "[JoinGroup] Found other peer: peer_id=%u (self=%u)\n", peer_id, self_peer_id_final);
                        fprintf(stdout, "[JoinGroup] Other peer should see us join via onGroupPeerJoin callback\n");
                        fflush(stdout);
                    }
                } else {
                    break; // Stop after first error
                }
            }
            fprintf(stdout, "[JoinGroup] Visible peer count: %d (including self)\n", visible_peer_count);
            fflush(stdout);
            
            // If we only see ourselves, DHT sync hasn't completed yet
            // Continue iterating to help DHT discovery
            if (visible_peer_count == 1) {
                fprintf(stdout, "[JoinGroup] ⚠️  Only self visible, DHT sync may be incomplete\n");
                fprintf(stdout, "[JoinGroup] DHT Discovery Diagnosis:\n");
                fprintf(stdout, "[JoinGroup]   - Self DHT connection: %d (0=NONE, 1=TCP, 2=UDP)\n", 
                        static_cast<int>(tox_self_get_connection_status(tox)));
                
                // Check group connection status
                Tox_Err_Group_Is_Connected err_conn_diag;
                bool group_connected = GetToxManager()->isGroupConnected(group_number, &err_conn_diag);
                fprintf(stdout, "[JoinGroup]   - Group connected: %d (err=%d)\n", 
                        group_connected ? 1 : 0, static_cast<int>(err_conn_diag));
                
                // Check privacy state
                Tox_Err_Group_State_Query err_privacy_diag;
                Tox_Group_Privacy_State privacy_diag = tox_group_get_privacy_state(tox, group_number, &err_privacy_diag);
                fprintf(stdout, "[JoinGroup]   - Group privacy: %d (0=PUBLIC, 1=PRIVATE, err=%d)\n", 
                        static_cast<int>(privacy_diag), static_cast<int>(err_privacy_diag));
                
                // For PUBLIC groups, DHT discovery should work but may take time
                // For local bootstrap, we can try to accelerate by:
                // 1. Ensuring both instances are iterating
                // 2. Checking if we need to wait longer
                // 3. Verifying bootstrap configuration
                fprintf(stdout, "[JoinGroup] Continuing to iterate to help DHT discovery...\n");
                fflush(stdout);
                
                // Do more iterations to help DHT discovery (increased from 5 to 20 for better discovery)
                // With local bootstrap, this should help peers discover each other faster
                // Note: DHT discovery for PUBLIC groups can take time even with local bootstrap
                // c-toxcore tests use WAIT_UNTIL which continuously iterates until peers are found
                fprintf(stdout, "[JoinGroup] Starting extended DHT discovery iterations (20 iterations, 100ms each)...\n");
                fflush(stdout);
                
                for (int i = 0; i < 20; i++) {
                    // Call iterate on both instances to help DHT discovery
                    // The event_thread_ should be doing this, but we can help by calling it directly
                    tox_manager_->iterate(0);
                    
                    // Also try to iterate on the other instance if we can identify it
                    // For now, just iterate on current instance
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    
                    // Check peer count every 5 iterations to see if discovery progressed
                    if (i % 5 == 0 && i > 0) {
                        int check_peer_count = 0;
                        for (Tox_Group_Peer_Number check_peer_id = 0; check_peer_id < 100; ++check_peer_id) {
                            uint8_t check_pubkey[TOX_PUBLIC_KEY_SIZE];
                            Tox_Err_Group_Peer_Query err_check;
                            if (tox_group_peer_get_public_key(tox, group_number, check_peer_id, check_pubkey, &err_check) &&
                                err_check == TOX_ERR_GROUP_PEER_QUERY_OK) {
                                check_peer_count++;
                            } else {
                                break;
                            }
                        }
                        fprintf(stdout, "[JoinGroup] DHT discovery check (iteration %d/20): peer_count=%d\n", i + 1, check_peer_count);
                        fflush(stdout);
                        if (check_peer_count > 1) {
                            fprintf(stdout, "[JoinGroup] ✅ Found %d peers after %d iterations!\n", check_peer_count, i + 1);
                            fflush(stdout);
                            break;
                        }
                    }
                }
                fprintf(stdout, "[JoinGroup] Completed extended DHT discovery iterations\n");
                fflush(stdout);
            }
        }
    } else {
        fprintf(stdout, "[JoinGroup] WARNING: tox_manager_ is null, cannot check connection status\n");
        fflush(stdout);
    }
    
    // Calculate total duration
    auto end_time = std::chrono::steady_clock::now();
    auto total_duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        end_time - start_time).count();
    auto end_timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    
    fprintf(stdout, "[JoinGroup] ========== JoinGroup completing ==========\n");
    fprintf(stdout, "[JoinGroup] Total duration: %lld ms\n", (long long)total_duration_ms);
    fprintf(stdout, "[JoinGroup] end_timestamp_ms=%lld\n", (long long)end_timestamp_ms);
    fflush(stdout);
    
    V2TIM_LOG(kInfo, "[JoinGroup] Calling callback->OnSuccess");
    if (callback) {
        callback->OnSuccess();
        V2TIM_LOG(kInfo, "[JoinGroup] callback->OnSuccess completed");
    } else {
        V2TIM_LOG(kWarning, "[JoinGroup] callback is null, skipping OnSuccess");
    }
    
    fprintf(stdout, "[JoinGroup] ========== JoinGroup completed (total=%lld ms) ==========\n", 
            (long long)total_duration_ms);
    fflush(stdout);
    V2TIM_LOG(kInfo, "[JoinGroup] ========== JoinGroup completed (total={} ms) ==========", total_duration_ms);
}

void V2TIMManagerImpl::QuitGroup(const V2TIMString& groupID, V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: ENTRY - groupID=%s", groupID.CString());
    
    // Clean up mappings before calling GroupManagerImpl
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it != group_id_to_group_number_.end()) {
            group_number = it->second;
            V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Found group_number=%u in group_id_to_group_number_ mapping", group_number);
            // Remove both mappings to prevent ID reuse conflicts
            group_id_to_group_number_.erase(it);
            group_number_to_group_id_.erase(group_number);
            V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Removed group_id_to_group_number_ and group_number_to_group_id_ mappings");
            // Also remove chat_id mapping if exists
            auto chat_it = group_id_to_chat_id_.find(groupID);
            if (chat_it != group_id_to_chat_id_.end()) {
                std::ostringstream oss;
                for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                    oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_it->second[i]);
                }
                std::string chat_id_hex = oss.str();
                group_id_to_chat_id_.erase(chat_it);
                chat_id_to_group_id_.erase(chat_id_hex);
                V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Removed chat_id mappings (chat_id_hex=%s)", chat_id_hex.c_str());
            }
            V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Cleaned up all mappings for group %s (group_number %u)", groupID.CString(), group_number);
        } else {
            V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Group %s not found in group_id_to_group_number_ mapping", groupID.CString());
        }
    }
    
    // Call GroupManagerImpl directly to remove from local state
    V2TIMGroupManagerImpl* groupManagerImpl = static_cast<V2TIMGroupManagerImpl*>(GetGroupManager());
    if (groupManagerImpl) {
        V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Calling V2TIMGroupManagerImpl::QuitGroup");
        // Use a helper method to quit the group (remove from local state)
        // We'll call the internal implementation directly
        groupManagerImpl->QuitGroup(groupID, callback);
        // Notify group listeners after successful quit
        std::vector<V2TIMGroupListener*> listeners_copy;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
        }
        V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Notifying %zu group listeners", listeners_copy.size());
        for (auto* listener : listeners_copy) {
            if (listener) {
                listener->OnQuitFromGroup(groupID);
            }
        }
        V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: EXIT - Completed for groupID=%s", groupID.CString());
    } else {
        V2TIM_LOG(kError, "V2TIMManagerImpl::QuitGroup: ERROR - GroupManagerImpl not available");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "GroupManager not available");
    }
}

void V2TIMManagerImpl::DismissGroup(const V2TIMString& groupID, V2TIMCallback* callback) {
    std::string group_id_str = groupID.CString();
    fprintf(stdout, "[V2TIMManagerImpl] DismissGroup: ENTRY - groupID=%s, callback=%p\n", 
            group_id_str.c_str(), callback);
    fflush(stdout);
    V2TIM_LOG(kInfo, "DismissGroup: dismissing group %s", group_id_str.c_str());
    
    // Get group_number from mapping BEFORE cleaning up (needed for GroupManagerImpl)
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it != group_id_to_group_number_.end()) {
            group_number = it->second;
            fprintf(stdout, "[V2TIMManagerImpl] DismissGroup: Found group_number=%u in mapping\n", group_number);
            fflush(stdout);
        } else {
            fprintf(stdout, "[V2TIMManagerImpl] DismissGroup: groupID=%s not found in mapping (size=%zu)\n", 
                    group_id_str.c_str(), group_id_to_group_number_.size());
            fflush(stdout);
        }
    }
    
    // Call GroupManagerImpl BEFORE cleaning up mappings (so it can find group_number)
    // This allows GroupManagerImpl to delete the group from Tox if needed
    V2TIMGroupManagerImpl* groupManagerImpl = static_cast<V2TIMGroupManagerImpl*>(GetGroupManager());
    if (groupManagerImpl) {
        fprintf(stdout, "[V2TIMManagerImpl] DismissGroup: Calling GroupManagerImpl::DismissGroup (group_number=%u)\n", 
                group_number);
        fflush(stdout);
        
        // Pass group_number to GroupManagerImpl via a temporary callback that preserves it
        // Create a wrapper callback that will clean up mappings after GroupManagerImpl completes
        class DismissGroupCallbackWrapper : public V2TIMCallback {
        private:
            V2TIMCallback* original_callback_;
            V2TIMManagerImpl* manager_impl_;
            V2TIMString group_id_;
            Tox_Group_Number group_number_;
            
        public:
            DismissGroupCallbackWrapper(V2TIMCallback* original, V2TIMManagerImpl* manager, 
                                       const V2TIMString& groupID, Tox_Group_Number group_number)
                : original_callback_(original), manager_impl_(manager), 
                  group_id_(groupID), group_number_(group_number) {}
            
            void OnSuccess() override {
                fprintf(stdout, "[V2TIMManagerImpl] DismissGroup: GroupManagerImpl::DismissGroup succeeded, cleaning up mappings\n");
                fflush(stdout);
                
                // Clean up mappings AFTER GroupManagerImpl has completed
                {
                    std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
                    manager_impl_->group_id_to_group_number_.erase(group_id_);
                    manager_impl_->group_number_to_group_id_.erase(group_number_);
                    // Also remove chat_id mapping if exists
                    auto chat_it = manager_impl_->group_id_to_chat_id_.find(group_id_);
                    if (chat_it != manager_impl_->group_id_to_chat_id_.end()) {
                        std::ostringstream oss;
                        for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                            oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_it->second[i]);
                        }
                        std::string chat_id_hex = oss.str();
                        manager_impl_->group_id_to_chat_id_.erase(chat_it);
                        manager_impl_->chat_id_to_group_id_.erase(chat_id_hex);
                    }
                    fprintf(stdout, "[V2TIMManagerImpl] DismissGroup: Cleaned up mappings for group %s (group_number %u)\n", 
                            group_id_.CString(), group_number_);
                    fflush(stdout);
                }
                
                // Notify group listeners after successful dismissal
                std::vector<V2TIMGroupListener*> listeners_copy;
                {
                    std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
                    listeners_copy.assign(manager_impl_->group_listeners_.begin(), manager_impl_->group_listeners_.end());
                }
                for (auto* listener : listeners_copy) {
                    if (listener) {
                        V2TIMGroupMemberInfo opUser;
                        opUser.userID = manager_impl_->GetLoginUser(); // Use current user as operator
                        listener->OnGroupDismissed(group_id_, opUser);
                    }
                }
                
                // Call original callback
                if (original_callback_) {
                    original_callback_->OnSuccess();
                }
            }
            
            void OnError(int error_code, const V2TIMString& error_message) override {
                fprintf(stderr, "[V2TIMManagerImpl] DismissGroup: GroupManagerImpl::DismissGroup failed, error_code=%d, error_msg=%s\n", 
                        error_code, error_message.CString());
                fflush(stderr);
                
                // Still clean up mappings even on error (group may have been partially dismissed)
                {
                    std::lock_guard<std::mutex> lock(manager_impl_->mutex_);
                    manager_impl_->group_id_to_group_number_.erase(group_id_);
                    manager_impl_->group_number_to_group_id_.erase(group_number_);
                    auto chat_it = manager_impl_->group_id_to_chat_id_.find(group_id_);
                    if (chat_it != manager_impl_->group_id_to_chat_id_.end()) {
                        std::ostringstream oss;
                        for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                            oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_it->second[i]);
                        }
                        std::string chat_id_hex = oss.str();
                        manager_impl_->group_id_to_chat_id_.erase(chat_it);
                        manager_impl_->chat_id_to_group_id_.erase(chat_id_hex);
                    }
                }
                
                // Call original callback
                if (original_callback_) {
                    original_callback_->OnError(error_code, error_message);
                }
            }
        };
        
        // Use wrapper callback that will clean up mappings after GroupManagerImpl completes
        DismissGroupCallbackWrapper* wrapper_callback = new DismissGroupCallbackWrapper(callback, this, groupID, group_number);
        groupManagerImpl->DismissGroup(groupID, wrapper_callback);
        
        fprintf(stdout, "[V2TIMManagerImpl] DismissGroup: EXIT - Request forwarded to GroupManagerImpl\n");
        fflush(stdout);
    } else {
        fprintf(stderr, "[V2TIMManagerImpl] DismissGroup: ERROR - GroupManagerImpl not available\n");
        fflush(stderr);
        if (callback) {
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "GroupManager not available");
        }
    }
}

// User Info
void V2TIMManagerImpl::GetUsersInfo(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMUserFullInfoVector>* callback) {
    V2TIMUserFullInfoVector infos; // Corrected typo: TXV2TIMUserFullInfoVector -> V2TIMUserFullInfoVector
    Tox* tox = GetToxManager()->getTox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }

    // CRITICAL: Copy userIDList immediately to avoid lifetime issues
    // The userIDList reference may point to a temporary that gets destroyed
    // before this async function executes
    // Extract C-strings first and store them in std::string to avoid
    // accessing potentially invalid impl_ pointers from V2TIMString objects
    std::vector<std::string> user_id_strings;  // Store C-strings safely
    try {
        for (size_t i = 0; i < userIDList.Size(); i++) {
            try {
                const V2TIMString& userID = userIDList[i];
                // CRITICAL: Extract C-string immediately before copying
                // This avoids accessing potentially invalid impl_ pointers
                const char* user_id_cstr = nullptr;
                size_t user_id_len = 0;
                try {
                    user_id_len = userID.Length();
                    user_id_cstr = userID.CString();
                } catch (...) {
                    // Skip invalid userID
                    continue;
                }
                if (!user_id_cstr || user_id_len == 0) {
                    continue;
                }
                // Store C-string in std::string for safety (thread-safe copy)
                user_id_strings.push_back(std::string(user_id_cstr, user_id_len));
            } catch (...) {
                // Skip invalid userID
            }
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to copy user ID list");
        return;
    }

    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    // This avoids any potential race conditions or invalid pointer access
    for (const auto& user_id_str : user_id_strings) {
        V2TIMUserFullInfo info;
        try {
            // Create new V2TIMString directly from the safe std::string
            // This avoids accessing potentially invalid impl_ pointers
            info.userID = V2TIMString(user_id_str.c_str());
        } catch (...) {
            // Skip invalid userID
            continue;
        }

        // Assume userID is the hex public key string
        uint8_t pub_key[TOX_PUBLIC_KEY_SIZE];
        // CRITICAL: Use the safe std::string directly instead of accessing V2TIMString
        const char* user_id_cstr = user_id_str.c_str();
        size_t user_id_len = user_id_str.length();
        if (!user_id_cstr || user_id_len == 0) {
            continue;
        }
        // if (V2TIMUtils::HexToBytes(userID.CString(), pub_key, TOX_PUBLIC_KEY_SIZE)) {
        if (ToxUtil::tox_hex_to_bytes(user_id_cstr, user_id_len, pub_key, TOX_PUBLIC_KEY_SIZE)) {
            TOX_ERR_FRIEND_BY_PUBLIC_KEY err_find;
            uint32_t friend_number = tox_friend_by_public_key(tox, pub_key, &err_find);
            if (err_find == TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
                // Get Nickname from Tox
                TOX_ERR_FRIEND_QUERY err_name;
                size_t name_size = tox_friend_get_name_size(tox, friend_number, &err_name);
                if (err_name == TOX_ERR_FRIEND_QUERY_OK && name_size > 0) {
                    std::vector<uint8_t> name_buffer(name_size);
                    tox_friend_get_name(tox, friend_number, name_buffer.data(), &err_name);
                    if (err_name == TOX_ERR_FRIEND_QUERY_OK) {
                        try {
                            info.nickName = V2TIMString(reinterpret_cast<const char*>(name_buffer.data()), name_size);
                            // CRITICAL: Use the safe std::string directly instead of accessing V2TIMString
                            const char* nick_cstr = info.nickName.CString();
                            if (user_id_cstr && nick_cstr) {
                                tim2tox_ffi_save_friend_nickname(user_id_cstr, nick_cstr);
                            }
                        } catch (...) {
                            // Skip nickname assignment on error
                        }
                    }
                }
                // Note: If nickname is not available from Tox, Flutter layer will load from local cache
                // Get status message (selfSignature)
                TOX_ERR_FRIEND_QUERY err_status;
                size_t status_size = tox_friend_get_status_message_size(tox, friend_number, &err_status);
                if (err_status == TOX_ERR_FRIEND_QUERY_OK && status_size > 0) {
                    std::vector<uint8_t> status_buffer(status_size);
                    tox_friend_get_status_message(tox, friend_number, status_buffer.data(), &err_status);
                    if (err_status == TOX_ERR_FRIEND_QUERY_OK) {
                        try {
                            info.selfSignature = V2TIMString(reinterpret_cast<const char*>(status_buffer.data()), status_size);
                            // CRITICAL: Use the safe std::string directly instead of accessing V2TIMString
                            const char* sig_cstr = info.selfSignature.CString();
                            if (user_id_cstr && sig_cstr) {
                                tim2tox_ffi_save_friend_status_message(user_id_cstr, sig_cstr);
                            }
                        } catch (...) {
                            // Skip status message assignment on error
                        }
                    }
                }
                // Note: If status message is not available from Tox, Flutter layer will load from local cache
                // TODO: Get other fields like faceURL etc. (Tox has limited profile data)
                // info.status = ...; // V2TIMUserFullInfo doesn't have status. Use GetUserStatus instead.
            }
        }
        try {
            infos.PushBack(info);
        } catch (...) {
            // Skip invalid info on error
        }
    }
    if (callback) callback->OnSuccess(infos);
}

// Commented out SetSelfStatus due to cast issue
// void V2TIMManagerImpl::SetSelfStatus(const V2TIMUserStatus& status, V2TIMCallback* callback) {
//     // TODO: Need mapping from V2TIMUserStatus to TOX_USER_STATUS
//     // tox_self_set_status(GetToxManager()->getTox(), (TOX_USER_STATUS)status);
//     if (callback) callback->OnSuccess();
// }

void V2TIMManagerImpl::SubscribeUserInfo(const V2TIMStringVector& userIDList, V2TIMCallback* callback) {
    NotSupported(callback, "SubscribeUserInfo");
}

void V2TIMManagerImpl::UnsubscribeUserInfo(const V2TIMStringVector& userIDList, V2TIMCallback* callback) {
    NotSupported(callback, "UnsubscribeUserInfo");
}

void V2TIMManagerImpl::SetSelfInfo(const V2TIMUserFullInfo& info, V2TIMCallback* callback) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }

    bool has_nickname = !info.nickName.Empty();
    bool has_status = !info.selfSignature.Empty();
    
    if (!has_nickname && !has_status) {
        if (callback) callback->OnSuccess();
        return;
    }

    if (has_nickname) {
        const char* nick_cstr = info.nickName.CString();
        if (nick_cstr) {
            TOX_ERR_SET_INFO err_name;
            tox_self_set_name(tox, reinterpret_cast<const uint8_t*>(nick_cstr), info.nickName.Length(), &err_name);
            if (err_name != TOX_ERR_SET_INFO_OK) {
                if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Set self nickname failed");
                return;
            }
        }
    }

    if (has_status) {
        const char* status_cstr = info.selfSignature.CString();
        if (status_cstr) {
            TOX_ERR_SET_INFO err_status;
            tox_self_set_status_message(tox, reinterpret_cast<const uint8_t*>(status_cstr), info.selfSignature.Length(), &err_status);
            if (err_status != TOX_ERR_SET_INFO_OK) {
                if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Set self status message failed");
                return;
            }
        }
    }

    // Notify SDK listeners of self info update (so onSelfInfoUpdated fires in Dart)
    {
        std::vector<V2TIMSDKListener*> listeners_to_notify;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            listeners_to_notify.assign(sdk_listeners_.begin(), sdk_listeners_.end());
        }
        for (V2TIMSDKListener* listener : listeners_to_notify) {
            if (listener) {
                listener->OnSelfInfoUpdated(info);
            }
        }
    }

    if (callback) callback->OnSuccess();
}

// Search & Status
void V2TIMManagerImpl::SearchUsers(const V2TIMUserSearchParam& param, V2TIMValueCallback<V2TIMUserSearchResult>* callback) {
    NotSupportedValue(callback, "SearchUsers");
}

void V2TIMManagerImpl::GetUserStatus(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMUserStatusVector>* callback) {
    NotSupportedValue(callback, "GetUserStatus");
}

void V2TIMManagerImpl::SetSelfStatus(const V2TIMUserStatus& status, V2TIMCallback* callback) {
    auto fail = [&](int code, const char* msg) {
        if (callback) {
            callback->OnError(code, msg);
        }
    };

    if (!tox_manager_) {
        fail(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }

    const char* custom_cstr = status.customStatus.CString();
    const std::string custom = custom_cstr ? custom_cstr : "";

    TOX_USER_STATUS tox_status = TOX_USER_STATUS_NONE;
    switch (status.statusType) {
        case V2TIM_USER_STATUS_ONLINE:
            // Online in TIM terms maps to \"no special\" status in tox.
            tox_status = TOX_USER_STATUS_NONE;
            break;
        case V2TIM_USER_STATUS_OFFLINE:
            // Offline is represented by connection state; keep status \"none\".
            tox_status = TOX_USER_STATUS_NONE;
            break;
        default:
            if (custom == "BUSY") {
                tox_status = TOX_USER_STATUS_BUSY;
            } else if (custom == "AWAY") {
                tox_status = TOX_USER_STATUS_AWAY;
            } else {
                tox_status = TOX_USER_STATUS_NONE;
            }
            break;
    }

    if (!tox_manager_->setStatus(tox_status)) {
        fail(ERR_IO_OPERATION_FAILED, "SetSelfStatus failed");
        return;
    }

    if (callback) {
        callback->OnSuccess();
    }
}

void V2TIMManagerImpl::SubscribeUserStatus(const V2TIMStringVector& userIDList, V2TIMCallback* callback) {
    NotSupported(callback, "SubscribeUserStatus");
}

void V2TIMManagerImpl::UnsubscribeUserStatus(const V2TIMStringVector& userIDList, V2TIMCallback* callback) {
    NotSupported(callback, "UnsubscribeUserStatus");
}

// Advanced Managers (R-06: owned by this instance, lazy-created)
V2TIMMessageManager* V2TIMManagerImpl::GetMessageManager() {
    if (!message_manager_) {
        message_manager_ = std::make_unique<V2TIMMessageManagerImpl>(this);
    }
    return message_manager_.get();
}

V2TIMGroupManager* V2TIMManagerImpl::GetGroupManager() {
    if (!group_manager_) {
        group_manager_ = std::make_unique<V2TIMGroupManagerImpl>(this);
    }
    std::atomic_thread_fence(std::memory_order_acquire);
    return group_manager_.get();
}

V2TIMCommunityManager* V2TIMManagerImpl::GetCommunityManager() {
    if (!community_manager_) {
        community_manager_ = std::make_unique<V2TIMCommunityManagerImpl>(this);
    }
    return community_manager_.get();
}

V2TIMConversationManager* V2TIMManagerImpl::GetConversationManager() {
    if (!conversation_manager_) {
        conversation_manager_ = std::make_unique<V2TIMConversationManagerImpl>(this);
    }
    return conversation_manager_.get();
}

V2TIMFriendshipManager* V2TIMManagerImpl::GetFriendshipManager() {
    if (!friendship_manager_) {
        friendship_manager_ = std::make_unique<V2TIMFriendshipManagerImpl>(this);
    }
    return friendship_manager_.get();
}

V2TIMOfflinePushManager* V2TIMManagerImpl::GetOfflinePushManager() {
    return nullptr;  // Unsupported; do not fake success elsewhere
}

V2TIMSignalingManager* V2TIMManagerImpl::GetSignalingManager() {
    // Per-instance signaling manager for multi-instance support
    if (!signaling_manager_) {
        signaling_manager_ = std::make_unique<V2TIMSignalingManagerImpl>();
        if (signaling_manager_) {
            signaling_manager_->SetManagerImpl(this);
        }
    }
    return signaling_manager_.get();
}

// Experimental API
void V2TIMManagerImpl::CallExperimentalAPI(const V2TIMString& api, const void* param, V2TIMValueCallback<V2TIMBaseObject>* callback) {
    NotSupportedValue(callback, "CallExperimentalAPI");
}

// Remove find_conference_by_id helper for now, will be handled within JoinGroup/Map logic
// uint32_t V2TIMManagerImpl::find_conference_by_id(const V2TIMString& groupID) { ... }

// Helper method to get all group IDs from mapping
std::vector<V2TIMString> V2TIMManagerImpl::GetAllGroupIDs() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<V2TIMString> groupIDs;
    for (const auto& pair : group_id_to_group_number_) {
        groupIDs.push_back(pair.first);
    }
    return groupIDs;
}

// R-07: Instance metadata (Core-owned; FFI forwards to these)
std::vector<std::string> V2TIMManagerImpl::GetKnownGroupIDs() {
    std::lock_guard<std::mutex> lock(metadata_mutex_);
    return known_groups_;
}

void V2TIMManagerImpl::SetKnownGroupIDs(const std::vector<std::string>& group_ids) {
    std::lock_guard<std::mutex> lock(metadata_mutex_);
    known_groups_ = group_ids;
}

bool V2TIMManagerImpl::GetGroupChatIdFromStorage(const std::string& group_id, char* out_chat_id_hex, int out_len) {
    if (!out_chat_id_hex || out_len < 65) return false;
    V2TIMString gid(group_id.c_str());
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_chat_id_.find(gid);
    if (it == group_id_to_chat_id_.end() || it->second.size() != TOX_GROUP_CHAT_ID_SIZE) return false;
    std::ostringstream oss;
    for (size_t i = 0; i < it->second.size(); ++i)
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(it->second[i]);
    std::string hex = oss.str();
    int n = (int)std::min(hex.size(), (size_t)(out_len - 1));
    memcpy(out_chat_id_hex, hex.c_str(), n);
    out_chat_id_hex[n] = '\0';
    return true;
}

void V2TIMManagerImpl::SetGroupChatIdInStorage(const std::string& group_id, const std::string& chat_id_hex) {
    if (chat_id_hex.length() != TOX_GROUP_CHAT_ID_SIZE * 2) return;
    std::vector<uint8_t> bin(TOX_GROUP_CHAT_ID_SIZE);
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        unsigned long byte_val = strtoul(chat_id_hex.substr(i * 2, 2).c_str(), nullptr, 16);
        if (byte_val > 255) return;
        bin[i] = (uint8_t)byte_val;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    group_id_to_chat_id_[V2TIMString(group_id.c_str())] = std::move(bin);
}

bool V2TIMManagerImpl::GetGroupTypeFromStorage(const std::string& group_id, char* out_type, int out_len) {
    if (!out_type || out_len < 16) return false;
    V2TIMString gid(group_id.c_str());
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_type_.find(gid);
    if (it == group_id_to_type_.end()) return false;
    int n = (int)std::min(it->second.size(), (size_t)(out_len - 1));
    memcpy(out_type, it->second.c_str(), n);
    out_type[n] = '\0';
    return true;
}

void V2TIMManagerImpl::SetGroupTypeInStorage(const std::string& group_id, const std::string& group_type) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_id_to_type_[V2TIMString(group_id.c_str())] = group_type;
}

bool V2TIMManagerImpl::GetAutoAcceptGroupInvites() {
    std::lock_guard<std::mutex> lock(metadata_mutex_);
    return auto_accept_group_invites_;
}

void V2TIMManagerImpl::SetAutoAcceptGroupInvites(bool enabled) {
    std::lock_guard<std::mutex> lock(metadata_mutex_);
    auto_accept_group_invites_ = enabled;
}

// --- Implementation of Internal Handlers ---

void V2TIMManagerImpl::HandleGroupMessageGroup(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message_data, size_t length, Tox_Group_Message_Id message_id) {
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] ========== ENTRY ==========");
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] group_number={}, peer_id={}, type={}, length={}, message_id={}", 
             group_number, peer_id, static_cast<int>(type), length, message_id);
    
    Tox* tox = GetToxManager()->getTox();
    V2TIMMessageManagerImpl* msgManager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !msgManager || !running_) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::HandleGroupMessageGroup] Skipped: Dependencies missing or shutting down. tox={}, msgManager={}, running_={}", 
                 tox ? "non-null" : "null", msgManager ? "non-null" : "null", running_ ? "true" : "false");
        return; // Not initialized or shutting down
    }

    V2TIMString groupID;
    V2TIMString senderUserID;

    // Avoid self-messages by checking if peer_id is ours (group API; fallback to conference API for old conferences)
    Tox_Err_Group_Peer_Query err_self;
    bool is_ours = GetToxManager()->isGroupPeerOurs(group_number, peer_id, &err_self);
    if (err_self == TOX_ERR_GROUP_PEER_QUERY_GROUP_NOT_FOUND) {
        TOX_ERR_CONFERENCE_PEER_QUERY err_c_ours;
        is_ours = GetToxManager()->isConferencePeerOurs(static_cast<uint32_t>(group_number), static_cast<uint32_t>(peer_id), &err_c_ours);
        err_self = TOX_ERR_GROUP_PEER_QUERY_OK; // so (is_ours && err_self == OK) below uses conference result
    }
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Self-check: is_ours={}, err_self={}", 
             is_ours, static_cast<int>(err_self));
    fprintf(stdout, "[HandleGroupMessageGroup] Self-check: is_ours=%d, err_self=%d\n", 
            is_ours ? 1 : 0, static_cast<int>(err_self));
    fflush(stdout);
    
    // Ignore self-messages whenever we determined the sender is us (do not rely on err_self being OK,
    // since isGroupPeerOurs may return true without setting error in some code paths).
    if (is_ours) {
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Ignoring self-message in group.");
        fprintf(stdout, "[HandleGroupMessageGroup] Ignoring self-message: group_number=%u, peer_id=%u\n", 
                group_number, peer_id);
        fflush(stdout);
        return; // Don't process messages sent by self
    }
    
    // Get sender public key (group API; fallback to conference API for old conferences)
    uint8_t sender_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_peer;
    bool got_key = GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, sender_pubkey, &err_peer);
    // For old Tox conferences: try conference API when NGCv2 can't find the peer.
    // GROUP_NOT_FOUND: no NGCv2 group with this number (pure conference).
    // PEER_NOT_FOUND: NGCv2 group exists but peer is only in the conference (mixed number space).
    if (!got_key && (err_peer == TOX_ERR_GROUP_PEER_QUERY_GROUP_NOT_FOUND ||
                     err_peer == TOX_ERR_GROUP_PEER_QUERY_PEER_NOT_FOUND)) {
        TOX_ERR_CONFERENCE_PEER_QUERY err_c_peer;
        got_key = GetToxManager()->getConferencePeerPublicKey(static_cast<uint32_t>(group_number), static_cast<uint32_t>(peer_id), sender_pubkey, &err_c_peer);
        if (got_key && err_c_peer == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
            err_peer = TOX_ERR_GROUP_PEER_QUERY_OK;
        }
    }

    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] getGroupPeerPublicKey: group_number={}, peer_id={}, got_key={}, err_peer={}", 
             group_number, peer_id, got_key ? 1 : 0, static_cast<int>(err_peer));
    fprintf(stdout, "[HandleGroupMessageGroup] getGroupPeerPublicKey: group_number=%u, peer_id=%u, got_key=%d, err_peer=%d\n",
            group_number, peer_id, got_key ? 1 : 0, static_cast<int>(err_peer));
    fflush(stdout);
    
    // Get self public key for comparison
    uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
    tox_self_get_public_key(tox, self_pubkey);
    std::string self_pubkey_hex = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
    fprintf(stdout, "[HandleGroupMessageGroup] Self public key: %s\n", self_pubkey_hex.c_str());
    fflush(stdout);
    
    if (!got_key || err_peer != TOX_ERR_GROUP_PEER_QUERY_OK) {
        if (err_peer == TOX_ERR_GROUP_PEER_QUERY_PEER_NOT_FOUND) {
            // Peer is temporarily not found in Tox state (e.g., just joined, state not yet stable).
            // Use a synthetic sender ID based on peer_id so the message is still delivered instead of dropped.
            V2TIM_LOG(kWarning, "HandleGroupMessage: Peer not found (err_peer=PEER_NOT_FOUND), using synthetic sender for group_number={}, peer_id={}", group_number, peer_id);
            fprintf(stdout, "[HandleGroupMessageGroup] Peer not found temporarily, using synthetic sender: group_number=%u, peer_id=%u\n",
                    group_number, peer_id);
            fflush(stdout);
            // Fill sender_pubkey with synthetic value: 0xFF + peer_id bytes so it's distinct
            memset(sender_pubkey, 0xFF, TOX_PUBLIC_KEY_SIZE);
            sender_pubkey[0] = static_cast<uint8_t>((peer_id >> 24) & 0xFF);
            sender_pubkey[1] = static_cast<uint8_t>((peer_id >> 16) & 0xFF);
            sender_pubkey[2] = static_cast<uint8_t>((peer_id >> 8) & 0xFF);
            sender_pubkey[3] = static_cast<uint8_t>(peer_id & 0xFF);
        } else {
            V2TIM_LOG(kError, "HandleGroupMessage: Failed to get peer public key: got_key={}, err_peer={}", got_key ? 1 : 0, static_cast<int>(err_peer));
            fprintf(stderr, "[HandleGroupMessageGroup] ERROR: Failed to get peer public key: got_key=%d, err_peer=%d\n",
                    got_key ? 1 : 0, static_cast<int>(err_peer));
            fflush(stderr);
            return;
        }
    }

    // --- Find GroupID --- 
    {
        std::lock_guard<std::mutex> lock(mutex_);
        V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupMessageGroup: Received message - group_number={}, peer_id={}, type={}, length={}, message_id={}", 
                 group_number, peer_id, static_cast<int>(type), length, message_id);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Looking up groupID for group_number={}, map size={}", 
                 group_number, group_number_to_group_id_.size());
        auto it = group_number_to_group_id_.find(group_number);
        if (it != group_number_to_group_id_.end()) {
            groupID = it->second;
            V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Found groupID={} for group_number={}", 
                     groupID.CString(), group_number);
        }
    }
    // If not in map, try to resolve on-the-fly. Two strategies:
    // (1) Get chat_id from Tox for this group_number and match to stored group_id (getGroupChatId can fail for some group states).
    // (2) Iterate known_groups, get stored chat_id, getGroupByChatId(stored_chat_id); if result == group_number, we found group_id.
    if (groupID.Empty()) {
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Unknown group_number {}, attempting on-the-fly resolve", group_number);
        uint8_t chat_id_bin[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat;
        if (GetToxManager()->getGroupChatId(group_number, chat_id_bin, &err_chat) && err_chat == TOX_ERR_GROUP_STATE_QUERY_OK) {
            std::string chat_id_hex;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                char buf[4];
                snprintf(buf, sizeof(buf), "%02x", chat_id_bin[i]);
                chat_id_hex += buf;
            }
            std::vector<std::string> known = GetKnownGroupIDs();
            if (!known.empty()) {
                for (const auto& line : known) {
                    if (line.empty()) continue;
                    char stored_chat_id[65];
                    if (!GetGroupChatIdFromStorage(line, stored_chat_id, sizeof(stored_chat_id))) continue;
                    #if defined(_WIN32) || defined(_WIN64)
                    if (strlen(stored_chat_id) == chat_id_hex.size() && _strnicmp(stored_chat_id, chat_id_hex.c_str(), chat_id_hex.size()) == 0) {
                    #else
                    if (strlen(stored_chat_id) == chat_id_hex.size() && strncasecmp(stored_chat_id, chat_id_hex.c_str(), chat_id_hex.size()) == 0) {
                    #endif
                        V2TIMString resolvedID(line.c_str());
                        {
                            std::lock_guard<std::mutex> lock(mutex_);
                            group_number_to_group_id_[group_number] = resolvedID;
                            group_id_to_group_number_[resolvedID] = group_number;
                        }
                        groupID = resolvedID;
                        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Resolved unknown group_number {} -> groupID={} (via getGroupChatId)", group_number, groupID.CString());
                        fprintf(stdout, "[HandleGroupMessageGroup] Resolved unknown group_number %u -> groupID=%s\n", (unsigned)group_number, groupID.CString());
                        fflush(stdout);
                        break;
                    }
                }
            }
        }
        // Strategy 2: iterate known_groups, getGroupByChatId(stored_chat_id) and match to group_number (works when getGroupChatId(group_number) fails)
        if (groupID.Empty() && tox_manager_) {
            std::vector<std::string> known2 = GetKnownGroupIDs();
            if (!known2.empty()) {
                for (const auto& line2 : known2) {
                    if (line2.empty()) continue;
                    char stored_chat_id[65];
                    if (!GetGroupChatIdFromStorage(line2, stored_chat_id, sizeof(stored_chat_id))) continue;
                    size_t len = strlen(stored_chat_id);
                    if (len != static_cast<size_t>(TOX_GROUP_CHAT_ID_SIZE * 2)) continue;
                    uint8_t cid_bin[TOX_GROUP_CHAT_ID_SIZE];
                    bool ok = true;
                    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                        char byte_str[3] = { stored_chat_id[i*2], stored_chat_id[i*2+1], '\0' };
                        char* end = nullptr;
                        unsigned long v = strtoul(byte_str, &end, 16);
                        if (!end || *end || v > 255) { ok = false; break; }
                        cid_bin[i] = static_cast<uint8_t>(v);
                    }
                    if (!ok) continue;
                    Tox_Group_Number actual = tox_manager_->getGroupByChatId(cid_bin);
                    if (actual != group_number) continue;
                    V2TIMString resolvedID(line2.c_str());
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        group_number_to_group_id_[group_number] = resolvedID;
                        group_id_to_group_number_[resolvedID] = group_number;
                    }
                    groupID = resolvedID;
                    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Resolved unknown group_number {} -> groupID={} (via getGroupByChatId)", group_number, groupID.CString());
                    fprintf(stdout, "[HandleGroupMessageGroup] Resolved unknown group_number %u -> groupID=%s (via getGroupByChatId)\n", (unsigned)group_number, groupID.CString());
                    fflush(stdout);
                    break;
                }
            }
        }
        // Fallback: use synthetic groupID so the message is still delivered (e.g. group has no stored chat_id or Tox returns error for getGroupChatId)
        if (groupID.Empty()) {
            char synthetic_buf[32];
            snprintf(synthetic_buf, sizeof(synthetic_buf), "tox_group_%u", (unsigned)group_number);
            V2TIMString syntheticID(synthetic_buf);
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_number_to_group_id_[group_number] = syntheticID;
                group_id_to_group_number_[syntheticID] = group_number;
            }
            groupID = syntheticID;
            V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Using synthetic groupID {} for unknown group_number {}", groupID.CString(), group_number);
            fprintf(stdout, "[HandleGroupMessageGroup] Using synthetic groupID %s for group_number %u (message will be delivered)\n", groupID.CString(), (unsigned)group_number);
            fflush(stdout);
        }
    }

    // --- Find Sender UserID (Public Key Hex) --- 
    char sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
    std::string hex_id = ToxUtil::tox_bytes_to_hex(sender_pubkey, TOX_PUBLIC_KEY_SIZE);
    strcpy(sender_hex_id, hex_id.c_str());
    sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0'; 
    senderUserID = sender_hex_id;

    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Sender public key hex: {}", senderUserID.CString());
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Received group msg type {} in group {} from {}",
             type, groupID.CString(), senderUserID.CString());
    fprintf(stdout, "[HandleGroupMessageGroup] Sender UserID: %s, GroupID: %s, Type: %d, Length: %zu\n",
            senderUserID.CString(), groupID.CString(), static_cast<int>(type), length);
    fflush(stdout);

    // Populate the peer_id cache so GetGroupMemberList can list this peer even if
    // HandleGroupPeerJoin never fired (e.g. because the group join never fully completed).
    if (got_key && err_peer == TOX_ERR_GROUP_PEER_QUERY_OK) {
        std::string key_lower = std::string(senderUserID.CString());
        std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(), ::tolower);
        std::lock_guard<std::mutex> lock(mutex_);
        group_peer_id_cache_[group_number][key_lower] = peer_id;
        fprintf(stdout, "[HandleGroupMessageGroup] Cached peer group_number=%u peer_id=%u pubkey=%s\n",
                group_number, peer_id, key_lower.c_str());
        fflush(stdout);
    }

    // --- Create V2TIMMessage Object --- 
    V2TIMMessage v2_message; // Will be populated based on type
    bool message_created = false;

    if (type == TOX_MESSAGE_TYPE_NORMAL) {
        // 解析消息，检查是否包含引用回复或合并消息
        std::string messageStr(reinterpret_cast<const char*>(message_data), length);
        std::string replyJson;
        std::string mergerJson;
        std::string actualText;
        std::string compatibleText;
        
        // 先检查合并消息
        bool hasMerger = MergerMessageUtil::ParseMessageWithMerger(messageStr, mergerJson, compatibleText);
        
        if (hasMerger && !mergerJson.empty()) {
            // 有合并消息，创建合并消息对象
            // 使用CreateTextMessage创建基础消息，然后替换元素
            V2TIMMessage mergerMsg = msgManager->CreateTextMessage("");
            // 清空文本元素，添加合并元素
            mergerMsg.elemList.Clear();
            V2TIMMergerElem* mergerElem = new V2TIMMergerElem();
            mergerElem->elemType = V2TIM_ELEM_TYPE_MERGER;
            
            // 从JSON中提取title
            std::string title = MessageReplyUtil::ExtractJsonValue(mergerJson, "title");
            mergerElem->title = title.c_str();
            
            // 提取abstractList
            std::vector<std::string> abstractVec = MergerMessageUtil::ExtractAbstractList(mergerJson);
            for (const auto& abstract : abstractVec) {
                mergerElem->abstractList.PushBack(abstract.c_str());
            }
            
            // 如果没有abstractList，使用兼容文本
            if (mergerElem->abstractList.Empty() && !compatibleText.empty()) {
                mergerElem->abstractList.PushBack(compatibleText.c_str());
            }
            
            mergerElem->layersOverLimit = false;
            
            mergerMsg.elemList.PushBack(mergerElem);
            v2_message = mergerMsg;
            message_created = true;
        } else {
            // 检查引用回复
            bool hasReply = MessageReplyUtil::ParseMessageWithReply(messageStr, replyJson, actualText);
            
            if (hasReply && !replyJson.empty()) {
                // 有引用回复，使用实际文本创建消息
                V2TIMString messageText(actualText.c_str());
                v2_message = msgManager->CreateTextMessage(messageText);
                // 设置cloudCustomData
                v2_message.cloudCustomData = MessageReplyUtil::BuildCloudCustomDataFromReplyJson(replyJson);
            } else {
                // 没有特殊标记，正常处理
                V2TIMString messageText(reinterpret_cast<const char*>(message_data), length);
                v2_message = msgManager->CreateTextMessage(messageText);
            }
            message_created = true;
        }
    } else if (type == TOX_MESSAGE_TYPE_ACTION) {
        V2TIMBuffer customData(message_data, length);
        
        // 检查是否是撤回通知
        std::string msgID, revoker, reason;
        if (RevokeMessageUtil::ParseRevokeMessage(customData, msgID, revoker, reason)) {
            // 这是撤回通知，触发撤回回调
            V2TIMString revokedMsgID(msgID.c_str());
            V2TIMString revokerID(revoker.c_str());
            V2TIMString revokeReason(reason.c_str());
            
            V2TIMMessageManagerImpl* msgMgr = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
            if (msgMgr) {
                msgMgr->NotifyMessageRevoked(revokedMsgID, revokerID, revokeReason);
            }
            
            V2TIM_LOG(kInfo, "Received revoke notification for message: %s from: %s in group: %s", 
                      msgID.c_str(), revoker.c_str(), groupID.CString());
            return; // 撤回通知不需要创建消息对象
        }
        
        v2_message = msgManager->CreateCustomMessage(customData);
        message_created = true;
    } else {
        V2TIM_LOG(kWarning, "Received unhandled group message type {}", type);
        return; // Don't notify for unsupported types
    }

    if (message_created) {
        // --- Populate received message fields --- 
        v2_message.sender = senderUserID;
        v2_message.userID = senderUserID; // So Dart/listeners can match sender (e.g. message.userID == alicePublicKey)
        v2_message.groupID = groupID;
        v2_message.isSelf = false; // Message received from others
        v2_message.status = V2TIM_MSG_STATUS_SEND_SUCC; // Mark as received successfully
        // Use current time as Tox doesn't provide a timestamp for received messages
        v2_message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                                    std::chrono::system_clock::now().time_since_epoch()).count();
        // TODO: Potentially retrieve sender Nickname/FaceURL here if needed/cached
        // v2_message.nickName = ... 
        // v2_message.faceURL = ...
        
        // [tim2tox-debug] Record message creation completion
        V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupMessageGroup: Message creation completed - msgID={}, groupID={}, sender={}, elemCount={}", 
                 v2_message.msgID.CString(), groupID.CString(), senderUserID.CString(), v2_message.elemList.Size());
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Message created: msgID={}, groupID={}, sender={}, timestamp={}", 
                 v2_message.msgID.CString(), groupID.CString(), senderUserID.CString(), v2_message.timestamp);
        fprintf(stdout, "[HandleGroupMessageGroup] Message created - msgID: %s, groupID: %s, sender: %s, isSelf: %d\n",
                v2_message.msgID.CString(), groupID.CString(), senderUserID.CString(), v2_message.isSelf ? 1 : 0);
        if (v2_message.elemList.Size() > 0 && v2_message.elemList[0]->elemType == V2TIM_ELEM_TYPE_TEXT) {
            V2TIMTextElem* textElem = static_cast<V2TIMTextElem*>(v2_message.elemList[0]);
            fprintf(stdout, "[HandleGroupMessageGroup] Message text: %s\n", textElem->text.CString());
        }
        fflush(stdout);
        
        // --- Notify Advanced Listeners --- 
        // Set receiver instance override so OnRecvNewMessage (in dart_compat_listeners) routes to this instance.
        int64_t receiver_instance_id = GetInstanceIdFromManager(this);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] About to notify advanced listeners, msgManager={}, receiver_instance_id={}", 
                 (void*)msgManager, (long long)receiver_instance_id);
        fprintf(stdout, "[HandleGroupMessageGroup] About to notify advanced listeners for message from %s in group %s (receiver_instance_id=%lld)\n",
                senderUserID.CString(), groupID.CString(), (long long)receiver_instance_id);
        fflush(stdout);
        SetReceiverInstanceOverride(receiver_instance_id);
        msgManager->NotifyAdvancedListenersReceivedMessage(v2_message);
        ClearReceiverInstanceOverride();
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Advanced listeners notified");
        fprintf(stdout, "[HandleGroupMessageGroup] Advanced listeners notified successfully\n");
        fflush(stdout);

        // --- Notify Simple Listeners (Optional - Keep for now) --- 
        std::vector<V2TIMSimpleMsgListener*> listeners_to_notify;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            listeners_to_notify.assign(simple_msg_listeners_.begin(), simple_msg_listeners_.end());
        }
        
        // Check message type from the message's elemList first element
        if (!v2_message.elemList.Empty()) {
            V2TIMElem* elem = v2_message.elemList[0];
            if (elem->elemType == V2TIM_ELEM_TYPE_TEXT) {
                V2TIMTextElem* textElem = static_cast<V2TIMTextElem*>(elem);
                
                // Create simplified member info for the notification
                V2TIMGroupMemberFullInfo senderInfo;
                senderInfo.userID = senderUserID;
                // TODO: Add more sender info if available
                
                for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
                    if (listener) listener->OnRecvGroupTextMessage(v2_message.msgID, groupID, senderInfo, textElem->text);
                }
            } else if (elem->elemType == V2TIM_ELEM_TYPE_CUSTOM) {
                V2TIMCustomElem* customElem = static_cast<V2TIMCustomElem*>(elem);
                
                // Create simplified member info for the notification
                V2TIMGroupMemberFullInfo senderInfo;
                senderInfo.userID = senderUserID;
                // TODO: Add more sender info if available
                
                for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
                    if (listener) listener->OnRecvGroupCustomMessage(v2_message.msgID, groupID, senderInfo, customElem->data);
                }
            }
        }
    }
}

void V2TIMManagerImpl::HandleGroupPrivateMessage(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message_data, size_t length, Tox_Group_Message_Id message_id) {
    fprintf(stdout, "[HandleGroupPrivateMessage] ENTRY group_number=%u peer_id=%u type=%d len=%zu\n", group_number, peer_id, type, length);
    fflush(stdout);
    Tox* tox = GetToxManager()->getTox();
    V2TIMMessageManagerImpl* msgManager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !msgManager || !running_) return;
    Tox_Err_Group_Peer_Query err_self;
    if (GetToxManager()->isGroupPeerOurs(group_number, peer_id, &err_self) && err_self == TOX_ERR_GROUP_PEER_QUERY_OK) return;
    uint8_t sender_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_peer;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, sender_pubkey, &err_peer) || err_peer != TOX_ERR_GROUP_PEER_QUERY_OK) return;
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) return;
        groupID = it->second;
    }
    V2TIMString senderUserID(ToxUtil::tox_bytes_to_hex(sender_pubkey, TOX_PUBLIC_KEY_SIZE).c_str());
    std::string text_str(reinterpret_cast<const char*>(message_data), length);
    V2TIMMessage v2_message = msgManager->CreateTextMessage(V2TIMString(text_str.c_str()));
    v2_message.sender = senderUserID;
    v2_message.userID = senderUserID; // So Dart/listeners can match sender
    v2_message.groupID = groupID;
    v2_message.isSelf = false;
    v2_message.status = V2TIM_MSG_STATUS_SEND_SUCC;
    v2_message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    // Set receiver instance override so OnRecvNewMessage routes to this instance (group private message).
    int64_t receiver_instance_id = GetInstanceIdFromManager(this);
    SetReceiverInstanceOverride(receiver_instance_id);
    msgManager->NotifyAdvancedListenersReceivedMessage(v2_message);
    ClearReceiverInstanceOverride();
}

void V2TIMManagerImpl::HandleFriendMessage(uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message_data, size_t length) {
    fprintf(stdout, "[HandleFriendMessage] ========== ENTRY ==========\n");
    fprintf(stdout, "[HandleFriendMessage] friend_number=%u, type=%d, length=%zu\n", friend_number, type, length);
    fflush(stdout);
    
    Tox* tox = GetToxManager()->getTox();
    V2TIMMessageManagerImpl* msgManager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !msgManager || !running_) {
        fprintf(stdout, "[HandleFriendMessage] ERROR: Dependencies missing or shutting down: tox=%p, msgManager=%p, running_=%d\n",
                (void*)tox, (void*)msgManager, running_ ? 1 : 0);
        fflush(stdout);
        V2TIM_LOG(kError, "HandleFriendMessage skipped: Dependencies missing or shutting down.");
        return; // Not initialized or shutting down
    }

    V2TIMString senderUserID;

    // --- Find Sender UserID (Public Key Hex) --- 
    uint8_t sender_pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    bool got_key = tox_friend_get_public_key(tox, friend_number, sender_pubkey, &err_key);
    if (!got_key || err_key != TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        V2TIM_LOG(kError, "Failed to get public key for friend number {}", friend_number);
        return;
    }
    char sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
    std::string hex_id = ToxUtil::tox_bytes_to_hex(sender_pubkey, TOX_PUBLIC_KEY_SIZE);
    strcpy(sender_hex_id, hex_id.c_str());
    sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
    senderUserID = sender_hex_id;

    V2TIM_LOG(kInfo, "Received C2C msg type {} from {} (friend {})", type, senderUserID.CString(), friend_number);
    fprintf(stdout, "[HandleFriendMessage] Received C2C msg: type=%d, sender=%s, friend_number=%u, length=%zu\n",
            type, senderUserID.CString(), friend_number, length);
    fflush(stdout);

    // --- Create V2TIMMessage Object --- 
    V2TIMMessage v2_message; // Will be populated based on type
    bool message_created = false;

    if (type == TOX_MESSAGE_TYPE_NORMAL) {
        // 解析消息，检查是否包含引用回复或合并消息
        std::string messageStr(reinterpret_cast<const char*>(message_data), length);
        std::string replyJson;
        std::string mergerJson;
        std::string actualText;
        std::string compatibleText;
        
        // 先检查合并消息
        bool hasMerger = MergerMessageUtil::ParseMessageWithMerger(messageStr, mergerJson, compatibleText);
        
        if (hasMerger && !mergerJson.empty()) {
            // 有合并消息，创建合并消息对象
            // 使用CreateTextMessage创建基础消息，然后替换元素
            V2TIMMessage mergerMsg = msgManager->CreateTextMessage("");
            // 清空文本元素，添加合并元素
            mergerMsg.elemList.Clear();
            V2TIMMergerElem* mergerElem = new V2TIMMergerElem();
            mergerElem->elemType = V2TIM_ELEM_TYPE_MERGER;
            
            // 从JSON中提取title
            std::string title = MessageReplyUtil::ExtractJsonValue(mergerJson, "title");
            mergerElem->title = title.c_str();
            
            // 提取abstractList
            std::vector<std::string> abstractVec = MergerMessageUtil::ExtractAbstractList(mergerJson);
            for (const auto& abstract : abstractVec) {
                mergerElem->abstractList.PushBack(abstract.c_str());
            }
            
            // 如果没有abstractList，使用兼容文本
            if (mergerElem->abstractList.Empty() && !compatibleText.empty()) {
                mergerElem->abstractList.PushBack(compatibleText.c_str());
            }
            
            mergerElem->layersOverLimit = false;
            
            mergerMsg.elemList.PushBack(mergerElem);
            v2_message = mergerMsg;
            message_created = true;
        } else {
            // 检查引用回复
            bool hasReply = MessageReplyUtil::ParseMessageWithReply(messageStr, replyJson, actualText);
            
            if (hasReply && !replyJson.empty()) {
                // 有引用回复，使用实际文本创建消息
                V2TIMString messageText(actualText.c_str());
                v2_message = msgManager->CreateTextMessage(messageText);
                // 设置cloudCustomData
                v2_message.cloudCustomData = MessageReplyUtil::BuildCloudCustomDataFromReplyJson(replyJson);
            } else {
                // 没有特殊标记，正常处理
                V2TIMString messageText(reinterpret_cast<const char*>(message_data), length);
                v2_message = msgManager->CreateTextMessage(messageText);
            }
            message_created = true;
        }
    } else if (type == TOX_MESSAGE_TYPE_ACTION) {
        V2TIMBuffer customData(message_data, length);
        
        // 检查是否是撤回通知
        std::string msgID, revoker, reason;
        if (RevokeMessageUtil::ParseRevokeMessage(customData, msgID, revoker, reason)) {
            // 这是撤回通知，触发撤回回调
            V2TIMString revokedMsgID(msgID.c_str());
            V2TIMString revokerID(revoker.c_str());
            V2TIMString revokeReason(reason.c_str());
            
            V2TIMMessageManagerImpl* msgMgr = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
            if (msgMgr) {
                msgMgr->NotifyMessageRevoked(revokedMsgID, revokerID, revokeReason);
            }
            
            V2TIM_LOG(kInfo, "Received revoke notification for message: %s from: %s", msgID.c_str(), revoker.c_str());
            return; // 撤回通知不需要创建消息对象
        }
        
        v2_message = msgManager->CreateCustomMessage(customData);
        fprintf(stdout, "[HandleFriendMessage] Created custom message, data_length=%zu\n", customData.Size());
        fflush(stdout);
        message_created = true;
    } else {
        V2TIM_LOG(kWarning, "Received unhandled C2C message type {}", type);
        fprintf(stdout, "[HandleFriendMessage] WARNING: Unhandled message type %d\n", type);
        fflush(stdout);
        return; // Don't notify for unsupported types
    }

    if (message_created) {
         // --- Populate received message fields --- 
        v2_message.sender = senderUserID;
        v2_message.userID = senderUserID; // For C2C, userID is the sender
        v2_message.groupID = ""; // Clear groupID for C2C
        
        // Check if message is from self by comparing sender's public key with our own
        uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, self_pubkey);
        bool is_self_sent = (memcmp(sender_pubkey, self_pubkey, TOX_PUBLIC_KEY_SIZE) == 0);
        v2_message.isSelf = is_self_sent;
        
        // Debug: Print both public keys for comparison
        char self_hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string self_hex_id_str = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(self_hex_id, self_hex_id_str.c_str());
        self_hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        
        fprintf(stdout, "[HandleFriendMessage] Checking if self-sent: sender_pubkey=%.64s, self_pubkey=%.64s, is_self=%d\n",
                senderUserID.CString(), self_hex_id, is_self_sent ? 1 : 0);
        fflush(stdout);
        
        v2_message.status = V2TIM_MSG_STATUS_SEND_SUCC;
        v2_message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                                    std::chrono::system_clock::now().time_since_epoch()).count();
        // TODO: Potentially retrieve sender Nickname/FaceURL here if needed/cached

        fprintf(stdout, "[HandleFriendMessage] Message created: msgID=%s, sender=%s, userID=%s, timestamp=%lld, elemCount=%zu\n",
                v2_message.msgID.CString(), v2_message.sender.CString(), v2_message.userID.CString(), 
                v2_message.timestamp, v2_message.elemList.Size());
        fflush(stdout);
        
        // Log message content
        if (!v2_message.elemList.Empty()) {
            V2TIMElem* firstElem = v2_message.elemList[0];
            if (firstElem->elemType == V2TIM_ELEM_TYPE_TEXT) {
                V2TIMTextElem* textElem = static_cast<V2TIMTextElem*>(firstElem);
                fprintf(stdout, "[HandleFriendMessage] Text message content: %s\n", textElem->text.CString());
                fflush(stdout);
            } else if (firstElem->elemType == V2TIM_ELEM_TYPE_CUSTOM) {
                V2TIMCustomElem* customElem = static_cast<V2TIMCustomElem*>(firstElem);
                fprintf(stdout, "[HandleFriendMessage] Custom message data length: %zu\n", customElem->data.Size());
                fflush(stdout);
            }
        }

        // --- Notify Advanced Listeners --- 
        // Set receiver instance override so OnRecvNewMessage routes to this instance.
        int64_t receiver_instance_id = GetInstanceIdFromManager(this);
        fprintf(stdout, "[HandleFriendMessage] About to notify advanced listeners, msgManager=%p, receiver_instance_id=%lld\n", 
                (void*)msgManager, (long long)receiver_instance_id);
        fflush(stdout);
        SetReceiverInstanceOverride(receiver_instance_id);
        msgManager->NotifyAdvancedListenersReceivedMessage(v2_message);
        fprintf(stdout, "[HandleFriendMessage] Advanced listeners notified\n");
        fflush(stdout);

        // --- Notify Simple Listeners (Optional - Keep for now) --- 
        // Keep receiver instance override set so c2c: lines are enqueued with receiver instance_id for poll routing
        std::vector<V2TIMSimpleMsgListener*> listeners_to_notify;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            listeners_to_notify.assign(simple_msg_listeners_.begin(), simple_msg_listeners_.end());
        }
        
        // Check message type from the message's elemList first element
        if (!v2_message.elemList.Empty()) {
            V2TIMElem* elem = v2_message.elemList[0];
            if (elem->elemType == V2TIM_ELEM_TYPE_TEXT) {
                V2TIMTextElem* textElem = static_cast<V2TIMTextElem*>(elem);
                
                // Create simplified user info for the notification
                V2TIMUserFullInfo senderInfo;
                senderInfo.userID = senderUserID;
                // TODO: Add more sender info if available
                
                for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
                    if (listener) listener->OnRecvC2CTextMessage(v2_message.msgID, senderInfo, textElem->text);
                }
            } else if (elem->elemType == V2TIM_ELEM_TYPE_CUSTOM) {
                V2TIMCustomElem* customElem = static_cast<V2TIMCustomElem*>(elem);
                
                // Create simplified user info for the notification
                V2TIMUserFullInfo senderInfo;
                senderInfo.userID = senderUserID;
                // TODO: Add more sender info if available
                
                for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
                    if (listener) listener->OnRecvC2CCustomMessage(v2_message.msgID, senderInfo, customElem->data);
                }
            }
        }
        ClearReceiverInstanceOverride();
    }
}

void V2TIMManagerImpl::HandleSelfConnectionStatus(TOX_CONNECTION connection_status) {
    extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
    int64_t instance_id = GetInstanceIdFromManager(this);
    V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: ENTRY - instance_id={}, connection_status={}, running_={}", 
              instance_id, connection_status, running_.load() ? 1 : 0);
    
    // CRITICAL: Check if SDK is fully initialized before processing connection status
    // This prevents crashes during startup when callbacks are triggered before initialization completes
    if (!running_.load(std::memory_order_acquire)) {
        V2TIM_LOG(kWarning, "HandleSelfConnectionStatus: SDK not running (instance_id={}), ignoring connection status", instance_id);
        return;
    }
    
    // Additional check: Ensure tox_manager_ is valid
    if (!tox_manager_) {
        V2TIM_LOG(kWarning, "HandleSelfConnectionStatus: tox_manager_ is null, SDK may not be fully initialized");
        return;
    }
    
    // When connection is established, ensure logged_in_user_ is set for status/callbacks
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if ((connection_status == TOX_CONNECTION_TCP || connection_status == TOX_CONNECTION_UDP) && logged_in_user_.Empty() && tox_manager_) {
            Tox* tox = tox_manager_->getTox();
            if (tox) {
                uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
                tox_self_get_public_key(tox, pubkey);
                std::string pk_hex = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
                std::string address = tox_manager_->getAddress();
                if (address.length() >= 76) {
                    logged_in_user_ = (pk_hex + address.substr(64, 12)).c_str();
                } else {
                    logged_in_user_ = pk_hex.c_str();
                }
            } else {
                std::string address = tox_manager_->getAddress();
                if (address.length() > 0) {
                    logged_in_user_ = address.c_str();
                }
            }
        }
    }
    
    std::vector<V2TIMSDKListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_); // Protect listener access
        listeners_to_notify.assign(sdk_listeners_.begin(), sdk_listeners_.end());
    }

    for (V2TIMSDKListener* listener : listeners_to_notify) {
        if (!listener) {
            continue;
        }
        
        switch (connection_status) {
            case TOX_CONNECTION_NONE:
                listener->OnConnectFailed(ERR_SDK_NET_DISCONNECT, "Disconnected from Tox network");
                break;
            case TOX_CONNECTION_TCP:
            case TOX_CONNECTION_UDP:
                GetToxManager()->setStatus(TOX_USER_STATUS_NONE);
                listener->OnConnectSuccess();
                
                // OPTIMIZATION: Immediately refresh cache on connection, then schedule periodic refreshes.
                // Use per-instance joinable jthread (no detach) so StopBackgroundTasks() can join before destroy.
                refresh_stop_requested_.store(false, std::memory_order_release);
                bool expected = false;
                if (refresh_task_running_.compare_exchange_strong(expected, true)) {
                    V2TIMConversationManagerImpl* cm = static_cast<V2TIMConversationManagerImpl*>(GetConversationManager());
                    if (cm) {
                        cm->RefreshCache();
                        // Reap the previous run's thread handle. The worker resets
                        // refresh_task_running_ at the very end, so the thread has
                        // either already exited or is unwinding — but the std::thread
                        // object is still joinable, and operator= on a joinable
                        // target calls std::terminate.
                        if (refresh_task_.joinable()) {
                            refresh_task_.join();
                        }
                        refresh_task_ = std::thread([this]() {
                            auto refresh_once = [this]() {
                                if (!running_.load(std::memory_order_acquire)) return;
                                V2TIMConversationManagerImpl* c = static_cast<V2TIMConversationManagerImpl*>(GetConversationManager());
                                if (c) c->RefreshCache();
                            };
                            const long delays_ms[] = { 500, 1000, 2000 };
                            for (long delay_ms : delays_ms) {
                                for (long elapsed = 0; elapsed < delay_ms && !refresh_stop_requested_.load(std::memory_order_acquire); elapsed += 10) {
                                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                                }
                                if (refresh_stop_requested_.load(std::memory_order_acquire)) break;
                                refresh_once();
                            }
                            refresh_task_running_.store(false, std::memory_order_release);
                        });
                    } else {
                        refresh_task_running_.store(false, std::memory_order_release);
                    }
                } else {
                    V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: RefreshCache task already running, skipping");
                }
                break;
        }
        // TODO: Map other V2TIMSDKListener connection callbacks like OnConnecting, OnKickedOffline?
        // OnKickedOffline might need a specific signal/callback from Tox, not just connection status.
    }
    
    // Notify self online status change when connection is established
    // This ensures the UI layer knows the user is online
    // Note: Use full address (76 chars) for self status to match currentUser.userID in Dart layer
    if (connection_status == TOX_CONNECTION_TCP || connection_status == TOX_CONNECTION_UDP) {
        if (!logged_in_user_.Empty()) {
            std::string user_id_str = logged_in_user_.CString();
            // Use full address (76 chars) for self status to match currentUser.userID
            // This ensures buildUserStatusList can correctly match and update self status
            
            V2TIMUserStatus self_status;
            self_status.userID = user_id_str.c_str();
            self_status.statusType = V2TIM_USER_STATUS_ONLINE;
            
            V2TIMUserStatusVector statusVector;
            statusVector.PushBack(self_status);
            
            // Notify all SDK listeners about self status change
            for (V2TIMSDKListener* listener : listeners_to_notify) {
                if (listener) {
                    listener->OnUserStatusChanged(statusVector);
                }
            }
            
            V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: Notified self online status (userID={}, length={})", 
                     user_id_str.c_str(), user_id_str.length());
        }
        
        // CRITICAL: Rejoin known groups after connection is established and online status is set
        // This ensures tox_group_join has network connectivity and is more likely to succeed
        // We use a flag to avoid multiple rejoin attempts
        // IMPORTANT: Only trigger rejoin if SDK is fully initialized (running_ is true and tox_manager_ is valid)
        {
            bool expected = false;
            if (rejoin_triggered_.compare_exchange_strong(expected, true)) {
                // Double-check that SDK is still running before creating thread
                if (!running_.load(std::memory_order_acquire) || !tox_manager_) {
                    V2TIM_LOG(kWarning, "HandleSelfConnectionStatus: SDK not fully initialized, skipping RejoinKnownGroups");
                    rejoin_triggered_.store(false); // Reset flag so it can be retried later
                    return;
                }
                
                V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: Connection established, triggering RejoinKnownGroups");
                rejoin_stop_requested_.store(false, std::memory_order_release);
                // Reap the previous run's thread handle before reassigning;
                // assigning to a joinable std::thread calls std::terminate.
                // The previous task may have finished long ago (rejoin_triggered_
                // is reset on disconnect, so a reconnect re-enters this branch).
                if (rejoin_task_.joinable()) {
                    rejoin_task_.join();
                }
                rejoin_task_ = std::thread([this]() {
                    for (int i = 0; i < 50 && !rejoin_stop_requested_.load(std::memory_order_acquire); ++i) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    }
                    if (rejoin_stop_requested_.load(std::memory_order_acquire)) return;
                    try {
                        if (!running_.load(std::memory_order_acquire) || !tox_manager_) return;
                        RejoinKnownGroups();
                    } catch (const std::bad_alloc&) {
                    } catch (const std::exception&) {
                    } catch (...) {
                    }
                });
                V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: RejoinKnownGroups task started (joinable)");
            } else {
                V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: RejoinKnownGroups already triggered, skipping");
            }
        }
    } else if (connection_status == TOX_CONNECTION_NONE) {
        // Reset rejoin flag when disconnected, so it can be triggered again on reconnect
        rejoin_triggered_.store(false);
        // Notify self offline status when disconnected
        // Note: Use full address (76 chars) for self status to match currentUser.userID in Dart layer
        if (!logged_in_user_.Empty()) {
            std::string user_id_str = logged_in_user_.CString();
            // Use full address (76 chars) for self status to match currentUser.userID
            // This ensures buildUserStatusList can correctly match and update self status
            
            V2TIMUserStatus self_status;
            self_status.userID = user_id_str.c_str();
            self_status.statusType = V2TIM_USER_STATUS_OFFLINE;
            
            V2TIMUserStatusVector statusVector;
            statusVector.PushBack(self_status);
            
            // Notify all SDK listeners about self status change
            for (V2TIMSDKListener* listener : listeners_to_notify) {
                if (listener) {
                    listener->OnUserStatusChanged(statusVector);
                }
            }
            
            V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: Notified self offline status (userID={}, length={})", 
                     user_id_str.c_str(), user_id_str.length());
        }
    }
}

void V2TIMManagerImpl::HandleFriendRequest(const uint8_t* public_key, const uint8_t* message_data, size_t length) {
    extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
    int64_t instance_id = GetInstanceIdFromManager(this);
    fprintf(stdout, "[HandleFriendRequest] ========== ENTRY ==========\n");
    fprintf(stderr, "[HandleFriendRequest] ========== ENTRY ==========\n");
    fprintf(stdout, "[HandleFriendRequest] this=%p, instance_id=%lld\n", (void*)this, (long long)instance_id);
    fprintf(stderr, "[HandleFriendRequest] this=%p, instance_id=%lld\n", (void*)this, (long long)instance_id);
    fprintf(stdout, "[HandleFriendRequest] public_key (first 20 chars): ");
    fprintf(stderr, "[HandleFriendRequest] public_key (first 20 chars): ");
    for (int i = 0; i < 20 && i < TOX_PUBLIC_KEY_SIZE; ++i) {
        fprintf(stdout, "%02X", public_key[i]);
        fprintf(stderr, "%02X", public_key[i]);
    }
    fprintf(stdout, "...\n");
    fprintf(stderr, "...\n");
    fprintf(stdout, "[HandleFriendRequest] message length: %zu\n", length);
    fprintf(stderr, "[HandleFriendRequest] message length: %zu\n", length);
    fflush(stdout);
    fflush(stderr);
    
    char sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
    std::string hex_id = ToxUtil::tox_bytes_to_hex(public_key, TOX_PUBLIC_KEY_SIZE);
    strcpy(sender_hex_id, hex_id.c_str());
    sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
    V2TIMString senderUserID = sender_hex_id;
    V2TIMString requestMessage(reinterpret_cast<const char*>(message_data), length);

    V2TIM_LOG(kInfo, "HandleFriendRequest from {} with message: {}", senderUserID.CString(), requestMessage.CString());
    fprintf(stdout, "[HandleFriendRequest] Received friend request from: %.64s, message length: %zu, message (first 40 chars): %.40s\n",
            senderUserID.CString(), length, requestMessage.CString());
    fprintf(stderr, "[HandleFriendRequest] Received friend request from: %.64s, message length: %zu, message (first 40 chars): %.40s\n",
            senderUserID.CString(), length, requestMessage.CString());
    fflush(stdout);
    fflush(stderr);

    // Create the friend application
    V2TIMFriendApplication application;
    application.userID = senderUserID;
    application.addWording = requestMessage;
    application.addSource = "Tox"; // Default source
    application.type = V2TIM_FRIEND_APPLICATION_COME_IN; 
    // TODO: Get nickname/faceURL for the application if possible via GetUsersInfo?
    // Requires potentially making GetUsersInfo synchronous or caching.
    
    V2TIMFriendApplicationVector applications;
    applications.PushBack(application);
    
    fprintf(stdout, "[HandleFriendRequest] Created application: userID=%.64s, addWording=%.40s\n",
            application.userID.CString(), application.addWording.CString());
    fflush(stdout);
    
    // Notify only the current instance's listener (not all instances)
    // This is critical for multi-instance support, as each instance should only
    // receive friend requests intended for it
    // Use GetFriendshipListenerForManager(this) instead of GetCurrentInstanceFriendshipListener()
    // because HandleFriendRequest is called from Tox callback thread, where g_current_instance_id
    // may not be set correctly. Using 'this' pointer ensures we get the correct instance.
    V2TIM_LOG(kInfo, "HandleFriendRequest: Calling GetFriendshipListenerForManager(this={})", (void*)this);
    fprintf(stdout, "[HandleFriendRequest] Calling GetFriendshipListenerForManager(this=%p)\n", (void*)this);
    fflush(stdout);
    DartFriendshipListenerImpl* listener = GetFriendshipListenerForManager(this);
    V2TIM_LOG(kInfo, "HandleFriendRequest: GetFriendshipListenerForManager() returned: {}", (void*)listener);
    fprintf(stdout, "[HandleFriendRequest] GetFriendshipListenerForManager() returned: %p\n", (void*)listener);
    fflush(stdout);
    
    // If no listener found, try to get or create one for this instance
    if (!listener) {
        int64_t this_instance_id = GetInstanceIdFromManager(this);
        
        V2TIM_LOG(kInfo, "HandleFriendRequest: No listener found, creating one for instance {}", this_instance_id);
        fprintf(stdout, "[HandleFriendRequest] No listener found, creating one for instance %lld\n", 
                (long long)this_instance_id);
        fflush(stdout);
        
        // Create listener directly for this instance_id
        listener = GetOrCreateFriendshipListenerForInstance(this_instance_id);
        
        // Note: The listener is already stored in g_friendship_listeners map by GetOrCreateFriendshipListenerForInstance
        // We don't need to register it with friendship manager here, as it will be used directly
        if (listener) {
            V2TIM_LOG(kInfo, "HandleFriendRequest: Created friendship listener for instance {}", this_instance_id);
            fprintf(stdout, "[HandleFriendRequest] Created friendship listener for instance %lld\n", (long long)this_instance_id);
            fflush(stdout);
        }
    }
    
    if (listener) {
        V2TIM_LOG(kInfo, "HandleFriendRequest: Notifying current instance's listener about friend request from {}", senderUserID.CString());
        V2TIM_LOG(kInfo, "HandleFriendRequest: Calling NotifyFriendApplicationListAddedToListener with {} applications", applications.Size());
        fprintf(stdout, "[HandleFriendRequest] Calling NotifyFriendApplicationListAddedToListener with %zu applications\n", applications.Size());
        fflush(stdout);
        NotifyFriendApplicationListAddedToListener(listener, &applications);
        V2TIM_LOG(kInfo, "HandleFriendRequest: NotifyFriendApplicationListAddedToListener completed");
        fprintf(stdout, "[HandleFriendRequest] NotifyFriendApplicationListAddedToListener completed\n");
        fflush(stdout);
        
        // CRITICAL: Also store the application in pending_applications_ so GetFriendApplicationList works
        // This is needed because NotifyFriendApplicationListAddedToListener only notifies listeners,
        // but doesn't store applications in the pending list
        V2TIMFriendshipManagerImpl* fm = static_cast<V2TIMFriendshipManagerImpl*>(GetFriendshipManager());
        if (fm) {
            V2TIM_LOG(kInfo, "HandleFriendRequest: Storing application in pending_applications_ for GetFriendApplicationList");
            fprintf(stdout, "[HandleFriendRequest] Storing application in pending_applications_ for GetFriendApplicationList\n");
            fflush(stdout);
            fm->NotifyFriendApplicationListAdded(applications);
            fprintf(stdout, "[HandleFriendRequest] Application stored in pending_applications_\n");
            fflush(stdout);
        } else {
            fprintf(stdout, "[HandleFriendRequest] ERROR: GetFriendshipManager() returned null!\n");
            fflush(stdout);
        }
    } else {
        V2TIM_LOG(kWarning, "HandleFriendRequest: No listener found for current instance, friend request from {} will not be notified", senderUserID.CString());
        fprintf(stdout, "[HandleFriendRequest] WARNING: No listener found for current instance!\n");
        fflush(stdout);
        // Fallback: Also notify through the global FriendshipManagerImpl for backward compatibility
        // This ensures that if no per-instance listener is registered, the request is still processed
        V2TIMFriendshipManagerImpl* fm = static_cast<V2TIMFriendshipManagerImpl*>(GetFriendshipManager());
        if (fm) {
            V2TIM_LOG(kInfo, "HandleFriendRequest: Falling back to global FriendshipManagerImpl");
            fprintf(stdout, "[HandleFriendRequest] Falling back to global FriendshipManagerImpl\n");
            fflush(stdout);
            fm->NotifyFriendApplicationListAdded(applications);
        }
    }
    fprintf(stdout, "[HandleFriendRequest] ========== EXIT ==========\n");
    fprintf(stderr, "[HandleFriendRequest] ========== EXIT ==========\n");
    fflush(stdout);
    fflush(stderr);
}

void V2TIMManagerImpl::HandleFriendName(uint32_t friend_number, const uint8_t* name_data, size_t length) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;
    V2TIMFriendshipManagerImpl* fm = static_cast<V2TIMFriendshipManagerImpl*>(GetFriendshipManager());
    if (!fm) return;

    // CRITICAL: Safely construct V2TIMString objects with exception handling
    V2TIMString friendUserID;
    V2TIMString friendName;
    
    try {
        // CRITICAL: Verify name_data is valid before constructing V2TIMString
        if (name_data && length > 0 && length < 10000) { // Reasonable length limit
            friendName = V2TIMString(reinterpret_cast<const char*>(name_data), length);
        } else {
            friendName = V2TIMString("");
        }
    } catch (const std::exception& e) {
        friendName = V2TIMString("");
    } catch (...) {
        friendName = V2TIMString("");
    }
    
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (tox_friend_get_public_key(tox, friend_number, pubkey, &err_key) && err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendUserID = hex_id;

        V2TIM_LOG(kInfo, "HandleFriendName: Friend {} ({}) changed name to: {}", friendUserID.CString(), friend_number, friendName.CString());
        
        // Notify Flutter layer to save nickname to local cache via FFI
        tim2tox_ffi_save_friend_nickname(friendUserID.CString(), friendName.CString());
        
        // CRITICAL: Safely construct V2TIMFriendInfoResult with exception handling
        V2TIMFriendInfoResult infoResult;
        try {
            infoResult.resultCode = 0;
            
            // CRITICAL: Verify friendUserID and friendName are valid before assignment
            try {
                const char* user_id_cstr = friendUserID.CString();
                const char* friend_name_cstr = friendName.CString();
                
                if (user_id_cstr && friend_name_cstr) {
                    infoResult.friendInfo.userID = friendUserID;
                    infoResult.friendInfo.userFullInfo.nickName = friendName;
                } else {
                    return;
                }
            } catch (...) {
                return;
            }
            
            V2TIMFriendInfoResultVector infoResultVector;
            try {
                infoResultVector.PushBack(infoResult);
            } catch (...) {
                return;
            }
            
            // Notify the friendship listener for THIS instance (receiver of the name change),
            // so the callback is sent with the correct instance_id (e.g. bob=2).
            V2TIMFriendInfoVector friendInfoList;
            for (size_t i = 0; i < infoResultVector.Size(); i++) {
                const V2TIMFriendInfoResult& r = infoResultVector[i];
                if (r.resultCode == 0) friendInfoList.PushBack(r.friendInfo);
            }
            if (!friendInfoList.Empty()) {
                DartFriendshipListenerImpl* listener = GetFriendshipListenerForManager(this);
                if (!listener) {
                    int64_t inst_id = GetInstanceIdFromManager(this);
                    listener = GetOrCreateFriendshipListenerForInstance(inst_id);
                    if (listener) RegisterFriendshipListenerWithManager(listener, this);
                }
                if (listener) NotifyFriendInfoChangedToListener(listener, &friendInfoList);
            }
        } catch (const std::exception& e) {
        } catch (...) {
            // Skip notification on error
        }

    } else {
        V2TIM_LOG(kError, "HandleFriendName: Failed to get public key for friend number {}", friend_number);
    }
}

void V2TIMManagerImpl::HandleFriendStatusMessage(uint32_t friend_number, const uint8_t* message_data, size_t length) {
     Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;
    V2TIMFriendshipManagerImpl* fm = static_cast<V2TIMFriendshipManagerImpl*>(GetFriendshipManager());
    if (!fm) return;

    // CRITICAL: Safely construct V2TIMString objects with exception handling
    V2TIMString friendUserID;
    V2TIMString statusMessage;
    
    try {
        // CRITICAL: Verify message_data is valid before constructing V2TIMString
        if (message_data && length > 0 && length < 10000) { // Reasonable length limit
            statusMessage = V2TIMString(reinterpret_cast<const char*>(message_data), length);
        } else {
            statusMessage = V2TIMString("");
        }
    } catch (const std::exception& e) {
        statusMessage = V2TIMString("");
    } catch (...) {
        statusMessage = V2TIMString("");
    }
    
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (tox_friend_get_public_key(tox, friend_number, pubkey, &err_key) && err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendUserID = hex_id;

        V2TIM_LOG(kInfo, "HandleFriendStatusMessage: Friend {} ({}) changed status message to: {}", friendUserID.CString(), friend_number, statusMessage.CString());

        // Notify Flutter layer to save status message to local cache via FFI
        tim2tox_ffi_save_friend_status_message(friendUserID.CString(), statusMessage.CString());

        // CRITICAL: Safely construct V2TIMFriendInfoResult with exception handling
        V2TIMFriendInfoResult infoResult;
        try {
            infoResult.resultCode = 0;
            
            // CRITICAL: Verify friendUserID and statusMessage are valid before assignment
            try {
                const char* user_id_cstr = friendUserID.CString();
                const char* status_msg_cstr = statusMessage.CString();
                
                if (user_id_cstr && status_msg_cstr) {
                    infoResult.friendInfo.userID = friendUserID;
                    infoResult.friendInfo.userFullInfo.selfSignature = statusMessage; // Map Tox status message to V2TIM selfSignature
                } else {
                    return;
                }
            } catch (...) {
                return;
            }
            
            V2TIMFriendInfoResultVector infoResultVector;
            try {
                infoResultVector.PushBack(infoResult);
            } catch (...) {
                return;
            }
            
            // Notify the friendship listener for THIS instance (receiver of the status message change)
            V2TIMFriendInfoVector friendInfoList;
            for (size_t i = 0; i < infoResultVector.Size(); i++) {
                const V2TIMFriendInfoResult& r = infoResultVector[i];
                if (r.resultCode == 0) friendInfoList.PushBack(r.friendInfo);
            }
            if (!friendInfoList.Empty()) {
                DartFriendshipListenerImpl* listener = GetFriendshipListenerForManager(this);
                if (!listener) {
                    int64_t inst_id = GetInstanceIdFromManager(this);
                    listener = GetOrCreateFriendshipListenerForInstance(inst_id);
                    if (listener) RegisterFriendshipListenerWithManager(listener, this);
                }
                if (listener) NotifyFriendInfoChangedToListener(listener, &friendInfoList);
            }
        } catch (const std::exception& e) {
        } catch (...) {
            // Skip notification on error
        }
    } else {
        V2TIM_LOG(kError, "HandleFriendStatusMessage: Failed to get public key for friend number {}", friend_number);
    }
}

void V2TIMManagerImpl::HandleFriendConnectionStatus(uint32_t friend_number, TOX_CONNECTION connection_status) {
    fprintf(stdout, "[V2TIMManagerImpl] HandleFriendConnectionStatus: ENTRY - friend_number=%u, connection_status=%d\n", 
            friend_number, connection_status);
    fflush(stdout);
    
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) {
        fprintf(stdout, "[V2TIMManagerImpl] HandleFriendConnectionStatus: EXIT early - tox=%p, running_=%d\n", 
                (void*)tox, running_ ? 1 : 0);
        fflush(stdout);
        return;
    }

    V2TIMString friendUserID;

    // Get UserID from friend_number
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (tox_friend_get_public_key(tox, friend_number, pubkey, &err_key) && err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendUserID = hex_id;
    } else {
        V2TIM_LOG(kError, "HandleFriendConnectionStatus: Failed to get public key for friend number {}", friend_number);
        return;
    }

    // Map TOX_CONNECTION to V2TIMUserStatusType
    // In Tox, online status is determined by connection status, not user status
    V2TIMUserStatus v2_status;
    v2_status.userID = friendUserID;
    v2_status.statusType = (connection_status != TOX_CONNECTION_NONE) ? V2TIM_USER_STATUS_ONLINE : V2TIM_USER_STATUS_OFFLINE;

    V2TIM_LOG(kInfo, "HandleFriendConnectionStatus: Friend {} ({}) connection status changed to: {} (V2TIM type: {})", 
              friendUserID.CString(), friend_number, connection_status, v2_status.statusType);

    // Notify SDK Listeners
    std::vector<V2TIMSDKListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(sdk_listeners_.begin(), sdk_listeners_.end());
    }
    
    int64_t this_instance_id = GetInstanceIdFromManager(this);
    fprintf(stdout, "[V2TIMManagerImpl] HandleFriendConnectionStatus: Notifying %zu SDK listeners (instance_id=%lld, friendUserID=%s, friend_number=%u, connection_status=%d, statusType=%d)\n", 
            listeners_to_notify.size(), (long long)this_instance_id, friendUserID.CString(), friend_number, connection_status, v2_status.statusType);
    fflush(stdout);
    
    V2TIMUserStatusVector statusVector;
    statusVector.PushBack(v2_status);
    
    fprintf(stdout, "[V2TIMManagerImpl] HandleFriendConnectionStatus: statusVector.Size()=%zu before calling listeners\n",
            statusVector.Size());
    fflush(stdout);
    
    for (size_t i = 0; i < listeners_to_notify.size(); i++) {
        V2TIMSDKListener* listener = listeners_to_notify[i];
        if (listener) {
            fprintf(stdout, "[V2TIMManagerImpl] HandleFriendConnectionStatus: Calling OnUserStatusChanged on listener[%zu]=%p (instance_id=%lld)\n", 
                    i, (void*)listener, (long long)this_instance_id);
            fflush(stdout);
            try {
                listener->OnUserStatusChanged(statusVector);
                fprintf(stdout, "[V2TIMManagerImpl] HandleFriendConnectionStatus: Successfully called OnUserStatusChanged on listener[%zu]\n", i);
            } catch (const std::exception& e) {
                fprintf(stderr, "[V2TIMManagerImpl] HandleFriendConnectionStatus: EXCEPTION calling OnUserStatusChanged on listener[%zu]: %s\n",
                        i, e.what());
                fflush(stderr);
            } catch (...) {
                fprintf(stderr, "[V2TIMManagerImpl] HandleFriendConnectionStatus: UNKNOWN EXCEPTION calling OnUserStatusChanged on listener[%zu]\n", i);
                fflush(stderr);
            }
            fflush(stdout);
        } else {
            fprintf(stderr, "[V2TIMManagerImpl] HandleFriendConnectionStatus: WARNING - listener[%zu] is null\n", i);
            fflush(stderr);
        }
    }
    
    fprintf(stdout, "[V2TIMManagerImpl] HandleFriendConnectionStatus: Finished notifying all listeners (instance_id=%lld)\n",
            (long long)this_instance_id);
    fflush(stdout);
    
    // When a friend connects, ensure our status is set so they can see us as online
    // This is especially important for newly added friends
    if (connection_status != TOX_CONNECTION_NONE) {
        // Ensure our status is set to online when a friend connects
        // This ensures newly added friends can see us as online immediately
        Tox* our_tox = GetToxManager()->getTox();
        if (our_tox) {
            TOX_CONNECTION our_status = tox_self_get_connection_status(our_tox);
            if (our_status != TOX_CONNECTION_NONE) {
                // We're connected, ensure status is set to online
                GetToxManager()->setStatus(TOX_USER_STATUS_NONE);
                fprintf(stdout, "[V2TIMManagerImpl] HandleFriendConnectionStatus: Re-set status to ensure friend %s can see us as online\n", friendUserID.CString());            }
        }
        
        // NOTE: Do NOT call NotifyFriendListAdded here.
        // OnFriendListAdded should only fire when a NEW friend is actually added (via AddFriend
        // or AcceptFriendApplication), not when an existing friend's connection status changes.
        // Firing it on every connection change causes the Dart UI to re-add deleted friends
        // and write them back into local persistence, preventing proper deletion.
        // The OnUserStatusChanged callback (already fired above) handles status updates.
    }
}

void V2TIMManagerImpl::HandleFriendStatus(uint32_t friend_number, TOX_USER_STATUS status) {
    fprintf(stdout, "[V2TIMManagerImpl] HandleFriendStatus: ENTRY - friend_number=%u, status=%d\n", 
            friend_number, status);
    fflush(stdout);
    
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) {
        fprintf(stdout, "[V2TIMManagerImpl] HandleFriendStatus: EXIT early - tox=%p, running_=%d\n", 
                (void*)tox, running_ ? 1 : 0);
        fflush(stdout);
        return;
    }

    V2TIMString friendUserID;

    // Get UserID from friend_number
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (tox_friend_get_public_key(tox, friend_number, pubkey, &err_key) && err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendUserID = hex_id;
    } else {
        V2TIM_LOG(kError, "HandleFriendStatus: Failed to get public key for friend number {}", friend_number);
        return;
    }

    // Map TOX_USER_STATUS to V2TIMUserStatusType
    V2TIMUserStatus v2_status;
    v2_status.userID = friendUserID;
    switch (status) {
        case TOX_USER_STATUS_NONE:
            v2_status.statusType = V2TIM_USER_STATUS_OFFLINE;
            break;
        case TOX_USER_STATUS_AWAY:
            v2_status.statusType = V2TIM_USER_STATUS_OFFLINE; // Or map to a custom status? V2TIM only has Online/Offline/Unkown.
            break;
        case TOX_USER_STATUS_BUSY:
             v2_status.statusType = V2TIM_USER_STATUS_ONLINE; // Map Busy to Online for simplicity?
            break;
        default: // Includes TOX_USER_STATUS_INVALID and any others
             v2_status.statusType = V2TIM_USER_STATUS_UNKNOWN;
             break;
    }
     // v2_status.customStatus = ...; // Tox doesn't provide custom status string in this callback

    V2TIM_LOG(kInfo, "HandleFriendStatus: Friend {} ({}) changed status to: {} (V2TIM type: {})", friendUserID.CString(), friend_number, status, v2_status.statusType);

    // Notify SDK Listeners
    std::vector<V2TIMSDKListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(sdk_listeners_.begin(), sdk_listeners_.end());
    }
    
    int64_t this_instance_id = GetInstanceIdFromManager(this);
    fprintf(stdout, "[V2TIMManagerImpl] HandleFriendStatus: Notifying %zu SDK listeners (instance_id=%lld, friendUserID=%s, statusType=%d, tox_status=%d)\n", 
            listeners_to_notify.size(), (long long)this_instance_id, friendUserID.CString(), v2_status.statusType, status);
    fflush(stdout);
    
    V2TIMUserStatusVector statusVector;
    statusVector.PushBack(v2_status);
    
    fprintf(stdout, "[V2TIMManagerImpl] HandleFriendStatus: statusVector.Size()=%zu before calling listeners\n",
            statusVector.Size());
    fflush(stdout);
    
    for (size_t i = 0; i < listeners_to_notify.size(); i++) {
        V2TIMSDKListener* listener = listeners_to_notify[i];
        if (listener) {
            fprintf(stdout, "[V2TIMManagerImpl] HandleFriendStatus: Calling OnUserStatusChanged on listener[%zu]=%p (instance_id=%lld)\n", 
                    i, (void*)listener, (long long)this_instance_id);
            fflush(stdout);
            try {
                listener->OnUserStatusChanged(statusVector); // Notify with the status vector
                fprintf(stdout, "[V2TIMManagerImpl] HandleFriendStatus: Successfully called OnUserStatusChanged on listener[%zu]\n", i);
            } catch (const std::exception& e) {
                fprintf(stderr, "[V2TIMManagerImpl] HandleFriendStatus: EXCEPTION calling OnUserStatusChanged on listener[%zu]: %s\n",
                        i, e.what());
                fflush(stderr);
            } catch (...) {
                fprintf(stderr, "[V2TIMManagerImpl] HandleFriendStatus: UNKNOWN EXCEPTION calling OnUserStatusChanged on listener[%zu]\n", i);
                fflush(stderr);
            }
            fflush(stdout);
        } else {
            fprintf(stderr, "[V2TIMManagerImpl] HandleFriendStatus: WARNING - listener[%zu] is null\n", i);
            fflush(stderr);
        }
    }
    
    fprintf(stdout, "[V2TIMManagerImpl] HandleFriendStatus: Finished notifying all listeners (instance_id=%lld)\n",
            (long long)this_instance_id);
    fflush(stdout);
}

void V2TIMManagerImpl::HandleGroupTitle(uint32_t conference_number, uint32_t peer_number, const uint8_t* title_data, size_t length) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;

    V2TIMString groupID;
    V2TIMString groupName(reinterpret_cast<const char*>(title_data), length);
    V2TIMString opUserID;

    // Find GroupID
    {
        std::lock_guard<std::mutex> lock(mutex_); 
        auto it = group_number_to_group_id_.find(conference_number);
        if (it == group_number_to_group_id_.end()) return; // Unknown group
        groupID = it->second;
    }

    // Find Operator UserID (who changed the title)
    uint8_t op_pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_CONFERENCE_PEER_QUERY err_peer;
    if (GetToxManager()->getConferencePeerPublicKey(conference_number, peer_number, op_pubkey, &err_peer) && err_peer == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
         char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(op_pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0'; 
        opUserID = hex_id;
    } else {
        V2TIM_LOG(kWarning, "HandleGroupTitle: Could not get operator user ID for peer {} in group {}", peer_number, groupID.CString());
        // Continue, but opUserID will be empty
    }
    
    V2TIM_LOG(kInfo, "HandleGroupTitle: Group {} title changed to '{}' by {} ({})", groupID.CString(), groupName.CString(), opUserID.CString(), peer_number);

    // Notify Listeners
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }

    // Construct V2TIMGroupChangeInfo for the name change
    V2TIMGroupChangeInfo changeInfo;
    changeInfo.type = V2TIM_GROUP_INFO_CHANGE_TYPE_NAME;
    changeInfo.value = groupName;
    
    // Create a vector for group changes
    V2TIMGroupChangeInfoVector changeInfoVector;
    changeInfoVector.PushBack(changeInfo);

    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            // Construct V2TIMGroupMemberInfo for the operator
            V2TIMGroupMemberInfo opMemberInfo;
            opMemberInfo.userID = opUserID;
            // TODO: Fill other opMemberInfo fields if possible (nickname, role etc.)
            
            // OnGroupInfoChanged only takes two parameters
            listener->OnGroupInfoChanged(groupID, changeInfoVector);
            
            // Note: If you need to pass the operator info, consider adding it to your own field
            // or using a different callback that accepts the operator parameter
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerName(uint32_t conference_number, uint32_t peer_number, const uint8_t* name_data, size_t length) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;

    V2TIMString groupID;
    V2TIMString memberUserID;
    V2TIMString memberName(reinterpret_cast<const char*>(name_data), length);

    // Find GroupID
    {
        std::lock_guard<std::mutex> lock(mutex_); 
        auto it = group_number_to_group_id_.find(conference_number);
        if (it == group_number_to_group_id_.end()) return; // Unknown group
        groupID = it->second;
    }

    // Find Member UserID 
    uint8_t member_pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_CONFERENCE_PEER_QUERY err_peer;
    if (GetToxManager()->getConferencePeerPublicKey(conference_number, peer_number, member_pubkey, &err_peer) && err_peer == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
         char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(member_pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0'; 
        memberUserID = hex_id;
    } else {
        V2TIM_LOG(kError, "HandleGroupPeerName: Could not get user ID for peer {} in group {}", peer_number, groupID.CString());
        return;
    }

    V2TIM_LOG(kInfo, "HandleGroupPeerName: Member {} in group {} changed name to '{}'", memberUserID.CString(), groupID.CString(), memberName.CString());

    // Notify Listeners
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }

    V2TIMGroupMemberChangeInfo changeInfo;
    changeInfo.userID = memberUserID;
    changeInfo.muteTime = 0; // Name change doesn't involve mute time
    
    V2TIMGroupMemberChangeInfoVector changeInfoVector;
    changeInfoVector.PushBack(changeInfo);

    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
             // V2TIM lacks a specific "member name changed" callback. 
             // Use OnMemberInfoChanged, but it requires a list of changes.
             // For simplicity, we send just the name change.
             V2TIM_LOG(kWarning, "Mapping PeerName change to OnMemberInfoChanged (may lack other details).");
            listener->OnMemberInfoChanged(groupID, changeInfoVector);
            // Ideally, fetch full member info and send that?
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerListChanged(uint32_t conference_number) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;
    V2TIM_LOG(kInfo, "HandleGroupPeerListChanged called for conference {}", conference_number);
    
    // Find GroupID for this conference
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(conference_number);
        if (it == group_number_to_group_id_.end()) {
            // Conference not yet mapped. Before creating a new synthetic ID,
            // check g_known_groups_list for an existing ID (e.g. tox_conf_N)
            // to avoid duplicating IDs for the same conference.
            V2TIMString resolvedGroupID;

            // Strategy 1: Check if tox_conf_<N> exists in known_groups (R-07: Core metadata)
            {
                char conf_id[64];
                snprintf(conf_id, sizeof(conf_id), "tox_conf_%u", conference_number);
                std::vector<std::string> known_conf = GetKnownGroupIDs();
                if (!known_conf.empty()) {
                    for (const auto& line : known_conf) {
                        if (line.empty()) continue;
                        if (line == conf_id) {
                            resolvedGroupID = V2TIMString(line.c_str());
                            V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Found existing known group '{}' for conference {}", line.c_str(), conference_number);
                            break;
                        }
                    }
                    if (resolvedGroupID.Empty()) {
                        for (const auto& line : known_conf) {
                            if (line.empty()) continue;
                            if (line.substr(0, 9) == "tox_conf_") {
                                V2TIMString candidate(line.c_str());
                                if (group_id_to_group_number_.find(candidate) == group_id_to_group_number_.end()) {
                                    resolvedGroupID = candidate;
                                    V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Matched unmapped known group '{}' to conference {}", line.c_str(), conference_number);
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Fallback: create synthetic tox_group_N only if no known group found
            if (resolvedGroupID.Empty()) {
                char synthetic_id[64];
                snprintf(synthetic_id, sizeof(synthetic_id), "tox_group_%u", conference_number);
                resolvedGroupID = V2TIMString(synthetic_id);
                V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: No known group found, auto-registered conference {} as groupID={}", conference_number, synthetic_id);
            }

            group_number_to_group_id_[conference_number] = resolvedGroupID;
            group_id_to_group_number_[resolvedGroupID] = conference_number;
            group_id_to_type_[resolvedGroupID] = "conference";
            groupID = resolvedGroupID;
        } else {
            groupID = it->second;
            // Ensure the type is registered as "conference" even when the groupID
            // was previously registered by RejoinKnownGroups as an NGCv2 group.
            // The two number spaces (NGCv2 group_number / conference_number) can
            // collide on the same integer; when HandleGroupPeerListChanged fires it
            // is always for a conference, so force the type here.
            auto& type_ref = group_id_to_type_[groupID];
            if (type_ref != "conference") {
                V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Updating groupID={} type to 'conference' (was '{}')",
                          groupID.CString(), type_ref.c_str());
                type_ref = "conference";
            }
        }
    }

    // Get current peer list
    TOX_ERR_CONFERENCE_PEER_QUERY err_peer;
    uint32_t peer_count = tox_conference_peer_count(tox, conference_number, &err_peer);
    if (err_peer != TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
        V2TIM_LOG(kError, "HandleGroupPeerListChanged: Failed to get peer count, error: %d", err_peer);
        return;
    }
    
    // Build current peer set (by public key hex)
    std::unordered_set<std::string> current_peers;
    for (uint32_t peer_number = 0; peer_number < peer_count; peer_number++) {
        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
        TOX_ERR_CONFERENCE_PEER_QUERY err_key;
        if (GetToxManager()->getConferencePeerPublicKey(conference_number, peer_number, peer_pubkey, &err_key) &&
            err_key == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
            std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
            current_peers.insert(userID);
        }
    }
    
    // Get previous snapshot
    std::unordered_set<std::string> previous_peers;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_peer_snapshots_.find(conference_number);
        if (it != group_peer_snapshots_.end()) {
            previous_peers = it->second;
        }
        // Update snapshot
        group_peer_snapshots_[conference_number] = current_peers;
    }
    
    // Find new members (in current but not in previous)
    std::vector<std::string> new_members;
    for (const auto& userID : current_peers) {
        if (previous_peers.find(userID) == previous_peers.end()) {
            new_members.push_back(userID);
        }
    }
    
    // Find left members (in previous but not in current)
    std::vector<std::string> left_members;
    for (const auto& userID : previous_peers) {
        if (current_peers.find(userID) == current_peers.end()) {
            left_members.push_back(userID);
        }
    }
    
    // Get listeners
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    // Notify about new members
    if (!new_members.empty()) {
        V2TIMGroupMemberInfoVector newMemberList;
        for (const auto& userID : new_members) {
            V2TIMGroupMemberInfo memberInfo;
            memberInfo.userID = V2TIMString(userID.c_str());
            newMemberList.PushBack(memberInfo);
            V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Member {} joined group {}", userID, groupID.CString());
        }
        
        for (V2TIMGroupListener* listener : listeners_copy) {
            if (listener) {
                listener->OnMemberEnter(groupID, newMemberList);
            }
        }
    }
    
    // Notify about left members
    for (const auto& userID : left_members) {
        V2TIMGroupMemberInfo memberInfo;
        memberInfo.userID = V2TIMString(userID.c_str());
        V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Member {} left group {}", userID, groupID.CString());
        
        for (V2TIMGroupListener* listener : listeners_copy) {
            if (listener) {
                listener->OnMemberLeave(groupID, memberInfo);
            }
        }
    }
    
    // If this is the first time (previous_peers was empty), don't notify
    // This prevents false notifications when the snapshot is first created
    if (previous_peers.empty() && !current_peers.empty()) {
        V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Initial snapshot created for conference {}, skipping notifications", conference_number);
    }
}

void V2TIMManagerImpl::HandleGroupConnected(uint32_t conference_number) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;
    
    V2TIM_LOG(kInfo, "HandleGroupConnected: Conference {} connected successfully", conference_number);
    
    // Find GroupID for this conference
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(conference_number);
        if (it == group_number_to_group_id_.end()) {
            // Conference not yet mapped, might be from a join operation
            // Generate a temporary ID or wait for JoinGroup to complete
            V2TIM_LOG(kWarning, "HandleGroupConnected: Conference {} not found in mapping, may be from join operation", conference_number);
            return;
        }
        groupID = it->second;
    }
    
    // Notify group listeners about connection
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            // V2TIM doesn't have a specific "group connected" callback
            // We can use OnGroupInfoChanged or just log it
            // For now, we'll trigger a refresh of group info
            V2TIM_LOG(kInfo, "HandleGroupConnected: Notifying listeners for group {}", groupID.CString());
            // Note: V2TIM API doesn't have a direct "connected" event, so we'll just log
            // In a real implementation, you might want to refresh group info here
        }
    }
}

// Helper method to access private data
bool V2TIMManagerImpl::GetGroupNumberFromID(const V2TIMString& groupID, Tox_Group_Number& group_number) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_group_number_.find(groupID);
    if (it == group_id_to_group_number_.end()) {
        return false;
    }
    group_number = it->second;
    return true;
}

bool V2TIMManagerImpl::GetChatIdFromGroupID(const V2TIMString& groupID, uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_chat_id_.find(groupID);
    if (it == group_id_to_chat_id_.end() || it->second.size() != TOX_GROUP_CHAT_ID_SIZE) {
        return false;
    }
    memcpy(chat_id, it->second.data(), TOX_GROUP_CHAT_ID_SIZE);
    return true;
}

bool V2TIMManagerImpl::GetGroupIDFromChatId(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE], V2TIMString& groupID) {
    std::lock_guard<std::mutex> lock(mutex_);
    // Convert chat_id to hex string for lookup
    std::ostringstream oss;
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
    }
    std::string chat_id_hex = oss.str();
    
    auto it = chat_id_to_group_id_.find(chat_id_hex);
    if (it == chat_id_to_group_id_.end()) {
        return false;
    }
    groupID = it->second;
    return true;
}

#ifdef BUILD_TOXAV
bool V2TIMManagerImpl::GetGroupIDFromGroupNumber(Tox_Group_Number group_number, V2TIMString& out_group_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_number_to_group_id_.find(group_number);
    if (it == group_number_to_group_id_.end()) {
        return false;
    }
    out_group_id = it->second;
    return true;
}
#endif

// Helper method to notify group listeners about member kicked
void V2TIMManagerImpl::NotifyGroupMemberKicked(const V2TIMString& groupID, const V2TIMGroupMemberInfoVector& memberList) {
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    // Get current user as operator
    V2TIMGroupMemberInfo opUser;
    opUser.userID = GetLoginUser();
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnMemberKicked(groupID, opUser, memberList);
        }
    }
}

// Tox group callback handlers
// HandleGroupMessageGroup is already defined above at line 1878

void V2TIMManagerImpl::HandleGroupTopic(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* topic, size_t length) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            V2TIM_LOG(kWarning, "HandleGroupTopic: Unknown group_number {}", group_number);
            return;
        }
        groupID = it->second;
    }
    
    std::string topic_value(reinterpret_cast<const char*>(topic), length);
    // Update local group_info_ cache so GetGroupsInfo returns the new name (SetGroupInfo broadcasts name via topic)
    V2TIMGroupManager* grp_mgr = GetGroupManager();
    if (grp_mgr) {
        V2TIMGroupManagerImpl* grp_impl = static_cast<V2TIMGroupManagerImpl*>(grp_mgr);
        grp_impl->UpdateGroupInfoFromTopic(groupID, topic_value);
    }
    
    // Notify group listeners about topic/name change (use NAME type when topic carries group name)
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    V2TIMGroupChangeInfo changeInfo;
    changeInfo.type = V2TIM_GROUP_INFO_CHANGE_TYPE_NAME;
    changeInfo.value = topic_value;
    
    V2TIMGroupChangeInfoVector changeList;
    changeList.PushBack(changeInfo);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnGroupInfoChanged(groupID, changeList);
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerNameGroup(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* name, size_t length) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }
    
    // Get peer public key to find userID
    Tox* tox = GetToxManager()->getTox();
    if (!tox) return;
    
    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
        err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }
    
    std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
    
    // Notify group listeners about member info change
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    V2TIMGroupMemberChangeInfo changeInfo;
    changeInfo.userID = userID;
    // Note: V2TIMGroupMemberChangeInfo doesn't have nickName field, only userID and muteTime
    
    V2TIMGroupMemberChangeInfoVector changeList;
    changeList.PushBack(changeInfo);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnMemberInfoChanged(groupID, changeList);
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerJoin(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id) {
    // Get timestamp for detailed timing
    auto callback_timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    
    // Log which instance is handling peer join (for multi-instance debugging)
    // Note: GetCurrentInstanceId is already declared at file scope (line 27)
    int64_t current_instance_id = GetCurrentInstanceId();
    fprintf(stdout, "[HandleGroupPeerJoin] ========== ENTRY ==========\n");
    fprintf(stdout, "[HandleGroupPeerJoin] callback_timestamp_ms=%lld, instance_id=%lld, group_number=%u, peer_id=%u\n", 
            (long long)callback_timestamp_ms, (long long)current_instance_id, group_number, peer_id);
    
    // Get peer information for debugging
    if (tox_manager_ && tox_manager_->getTox()) {
        Tox* tox = tox_manager_->getTox();
        
        // Get peer public key
        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Peer_Query err_key;
        bool got_key = tox_group_peer_get_public_key(tox, group_number, peer_id, peer_pubkey, &err_key);
        if (got_key && err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
            std::string peer_userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
            fprintf(stdout, "[HandleGroupPeerJoin] Peer userID: %s (length=%zu)\n", 
                    peer_userID.c_str(), peer_userID.length());
        } else {
            fprintf(stdout, "[HandleGroupPeerJoin] Failed to get peer public key, err=%d\n", 
                    static_cast<int>(err_key));
        }
        
        // Get peer name (buffer may not be NUL-terminated; use strnlen to avoid OOB read)
        uint8_t name_buffer[TOX_MAX_NAME_LENGTH + 1] = {};
        Tox_Err_Group_Peer_Query err_name;
        if (tox_group_peer_get_name(tox, group_number, peer_id, name_buffer, &err_name) &&
            err_name == TOX_ERR_GROUP_PEER_QUERY_OK) {
            size_t name_len = strnlen(reinterpret_cast<const char*>(name_buffer), TOX_MAX_NAME_LENGTH);
            fprintf(stdout, "[HandleGroupPeerJoin] Peer name: %.*s (length=%zu)\n",
                    static_cast<int>(name_len), reinterpret_cast<const char*>(name_buffer), name_len);
        }
        
        // Get peer role
        Tox_Err_Group_Peer_Query err_role;
        Tox_Group_Role peer_role = tox_group_peer_get_role(tox, group_number, peer_id, &err_role);
        if (err_role == TOX_ERR_GROUP_PEER_QUERY_OK) {
            fprintf(stdout, "[HandleGroupPeerJoin] Peer role: %d (0=USER, 1=MODERATOR, 2=FOUNDER, 3=OBSERVER)\n", 
                    static_cast<int>(peer_role));
        }
        
        // Check if this is ourselves
        Tox_Err_Group_Self_Query err_self;
        Tox_Group_Peer_Number self_peer_id = tox_group_self_get_peer_id(tox, group_number, &err_self);
        if (err_self == TOX_ERR_GROUP_SELF_QUERY_OK && self_peer_id == peer_id) {
            fprintf(stdout, "[HandleGroupPeerJoin] ⚠️  NOTE: This is our own peer join event (self_peer_id=%u)\n", 
                    self_peer_id);
        } else {
            fprintf(stdout, "[HandleGroupPeerJoin] ✅ This is a different peer joining (self_peer_id=%u, peer_id=%u)\n", 
                    self_peer_id, peer_id);
        }
    }
    fflush(stdout);
    V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] ENTRY - instance_id=%lld, group_number=%u, peer_id=%u", 
              (long long)current_instance_id, group_number, peer_id);
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            fprintf(stdout, "[HandleGroupPeerJoin] ERROR: Group_number=%u not found in mapping (size=%zu)\n", 
                    group_number, group_number_to_group_id_.size());
            fflush(stdout);
            V2TIM_LOG(kWarning, "[HandleGroupPeerJoin] Group_number=%u not found in mapping (size=%zu), cannot notify listeners", 
                     group_number, group_number_to_group_id_.size());
            // Print all mappings for debugging
            fprintf(stdout, "[HandleGroupPeerJoin] Current mappings:\n");
            for (const auto& pair : group_number_to_group_id_) {
                fprintf(stdout, "[HandleGroupPeerJoin]   group_number=%u -> groupID=%s\n", 
                        pair.first, pair.second.CString());
                V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Mapping: group_number=%u -> groupID=%s", 
                         pair.first, pair.second.CString());
            }
            fflush(stdout);
            return;
        }
        groupID = it->second;
        fprintf(stdout, "[HandleGroupPeerJoin] Found mapping: group_number=%u -> groupID=%s\n", 
                group_number, groupID.CString());
        fflush(stdout);
        V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Found mapping: group_number=%u -> groupID=%s", group_number, groupID.CString());
    }
    
    // Get peer public key to find userID
    Tox* tox = GetToxManager()->getTox();
    if (!tox) {
        fprintf(stderr, "[HandleGroupPeerJoin] ERROR: Tox instance is null\n");
        fflush(stderr);
        V2TIM_LOG(kError, "[HandleGroupPeerJoin] Tox instance is null");
        return;
    }
    
    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
        err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
        fprintf(stderr, "[HandleGroupPeerJoin] ERROR: Failed to get peer public key: group_number=%u, peer_id=%u, err=%d\n", 
                group_number, peer_id, err_key);
        fflush(stderr);
        V2TIM_LOG(kError, "[HandleGroupPeerJoin] Failed to get peer public key: group_number=%u, peer_id=%u, err=%d", 
                 group_number, peer_id, err_key);
        return;
    }
    
    std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
    fprintf(stdout, "[HandleGroupPeerJoin] Peer userID=%s (length=%zu)\n", userID.c_str(), userID.length());
    fflush(stdout);
    V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Peer userID=%s (length=%zu)", userID.c_str(), userID.length());
    // Cache (group_number, public_key_hex) -> peer_id for SendGroupPrivateTextMessage peer lookup
    {
        std::string key_lower = userID;
        std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(), ::tolower);
        std::lock_guard<std::mutex> lock(mutex_);
        group_peer_id_cache_[group_number][key_lower] = peer_id;
    }
    
    // Get peer name (buffer may not be NUL-terminated; use strnlen to avoid OOB read)
    uint8_t name_buffer[TOX_MAX_NAME_LENGTH + 1] = {};
    std::string peer_name;
    Tox_Err_Group_Peer_Query err_name;
    if (GetToxManager()->getGroupPeerName(group_number, peer_id, name_buffer, TOX_MAX_NAME_LENGTH, &err_name) &&
        err_name == TOX_ERR_GROUP_PEER_QUERY_OK) {
        size_t name_len = strnlen(reinterpret_cast<const char*>(name_buffer), TOX_MAX_NAME_LENGTH);
        peer_name = std::string(reinterpret_cast<const char*>(name_buffer), name_len);
        fprintf(stdout, "[HandleGroupPeerJoin] Peer name=%.*s (length=%zu)\n", static_cast<int>(name_len), reinterpret_cast<const char*>(name_buffer), name_len);
        fflush(stdout);
    } else {
        fprintf(stdout, "[HandleGroupPeerJoin] Failed to get peer name, err=%d\n", static_cast<int>(err_name));
        fflush(stdout);
    }
    
    // Get peer role
    Tox_Group_Role peer_role = tox_group_peer_get_role(tox, group_number, peer_id, &err_key);
    fprintf(stdout, "[HandleGroupPeerJoin] Peer role=%d (Tox role)\n", static_cast<int>(peer_role));
    fflush(stdout);
    
    // Notify group listeners about member enter
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        // Note: GetInstanceIdFromManager is already declared at file scope (line 28)
        int64_t this_instance_id = GetInstanceIdFromManager(this);
        fprintf(stdout, "[HandleGroupPeerJoin] ========== Checking Listeners ==========\n");
        fprintf(stdout, "[HandleGroupPeerJoin] this=%p, this_instance_id=%lld, current_instance_id=%lld, group_listeners_.size()=%zu\n", 
                (void*)this, (long long)this_instance_id, (long long)current_instance_id, group_listeners_.size());
        fprintf(stdout, "[HandleGroupPeerJoin] DEBUG: Checking if this instance is in g_instance_to_id map...\n");
        if (this_instance_id == 0) {
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  CRITICAL: this_instance_id=0 means this V2TIMManagerImpl is NOT in g_instance_to_id map!\n");
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  This could mean:\n");
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  1. This is the default instance (GetInstance())\n");
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  2. This instance was not registered via create_test_instance\n");
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  3. This instance was removed from the map\n");
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  But the callback was triggered, so this instance has a ToxManager with registered callbacks!\n");
        }
        if (group_listeners_.size() > 0) {
            fprintf(stdout, "[HandleGroupPeerJoin] ✅ Found %zu listeners in this instance:\n", group_listeners_.size());
            size_t idx = 0;
            for (auto* listener : group_listeners_) {
                fprintf(stdout, "[HandleGroupPeerJoin]   [%zu] listener=%p\n", idx++, (void*)listener);
            }
        } else {
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  WARNING: group_listeners_ is empty for this instance (instance_id=%lld)!\n", 
                    (long long)this_instance_id);
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  This means no listeners were registered on this instance!\n");
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  The callback is being triggered on instance_id=%lld, but listeners are registered on a different instance!\n", 
                    (long long)current_instance_id);
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  This is a multi-instance issue - listeners need to be registered on the same instance that receives callbacks!\n");
            fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  DEBUG: Checking if listeners were registered on a different instance...\n");
        }
        fflush(stdout);
        fflush(stderr);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
        fprintf(stdout, "[HandleGroupPeerJoin] Found %zu group listeners in this instance\n", listeners_copy.size());
        fprintf(stdout, "[HandleGroupPeerJoin] =========================================\n");
        fflush(stdout);
    }
    
    // Build member list for OnMemberEnter callback
    V2TIMGroupMemberFullInfo memberInfo;
    memberInfo.userID = V2TIMString(userID.c_str());
    memberInfo.nickName = peer_name.empty() ? V2TIMString(userID.c_str()) : V2TIMString(peer_name.c_str());
    
    // Map Tox role to V2TIM role
    switch (peer_role) {
        case TOX_GROUP_ROLE_FOUNDER:
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_SUPER;
            break;
        case TOX_GROUP_ROLE_MODERATOR:
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_ADMIN;
            break;
        case TOX_GROUP_ROLE_USER:
        case TOX_GROUP_ROLE_OBSERVER:
        default:
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_MEMBER;
            break;
    }
    
    V2TIMGroupMemberInfoVector memberList;
    V2TIMGroupMemberInfo memberInfoBasic;
    memberInfoBasic.userID = memberInfo.userID;
    // Note: V2TIMGroupMemberInfo doesn't have role or muteUntil fields
    memberList.PushBack(memberInfoBasic);
    
    fprintf(stdout, "[HandleGroupPeerJoin] About to notify %zu listeners about member enter (groupID=%s, userID=%s)\n", 
            listeners_copy.size(), groupID.CString(), userID.c_str());
    fflush(stdout);
    V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Notifying %zu listeners about member enter", listeners_copy.size());
    
    if (listeners_copy.empty()) {
        fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  WARNING: No listeners registered! This means OnMemberEnter callback will not be triggered!\n");
        fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  This might explain why the test fails - peer join event is not being notified to Dart layer!\n");
        fprintf(stderr, "[HandleGroupPeerJoin] ⚠️  instance_id=%lld, groupID=%s, userID=%s\n", 
                (long long)current_instance_id, groupID.CString(), userID.c_str());
        fflush(stderr);
    } else {
        fprintf(stdout, "[HandleGroupPeerJoin] ✅ Found %zu listeners, will notify them about peer join\n", listeners_copy.size());
        fflush(stdout);
    }
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            fprintf(stdout, "[HandleGroupPeerJoin] Calling OnMemberEnter for listener=%p, groupID=%s, memberCount=%zu\n", 
                    listener, groupID.CString(), memberList.Size());
            fflush(stdout);
            V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Calling OnMemberEnter for listener=%p, groupID=%s, memberCount=%zu", 
                     listener, groupID.CString(), memberList.Size());
            listener->OnMemberEnter(groupID, memberList);
        }
    }
    
    auto after_notify_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    auto notify_duration_ms = after_notify_ms - callback_timestamp_ms;
    
    fprintf(stdout, "[HandleGroupPeerJoin] ========== EXIT ==========\n");
    fprintf(stdout, "[HandleGroupPeerJoin] Total duration: %lld ms (from callback start to notify complete)\n", 
            (long long)notify_duration_ms);
    fflush(stdout);
    V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] EXIT - Completed notification");
}

void V2TIMManagerImpl::HandleGroupPeerExit(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, Tox_Group_Exit_Type exit_type, const uint8_t* name, size_t name_length) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }
    
    // Get peer public key to find userID
    Tox* tox = GetToxManager()->getTox();
    if (!tox) return;
    
    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
        err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }
    
    std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);

    // Remove peer from peer_id cache so GetGroupMemberList no longer sees stale entries.
    {
        std::string key_lower = userID;
        std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(), ::tolower);
        std::lock_guard<std::mutex> lock(mutex_);
        auto cache_it = group_peer_id_cache_.find(group_number);
        if (cache_it != group_peer_id_cache_.end()) {
            cache_it->second.erase(key_lower);
        }
    }

    // Notify group listeners about member leave
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }

    V2TIMGroupMemberFullInfo memberInfo;
    memberInfo.userID = userID;
    if (name_length > 0) {
        memberInfo.nickName = std::string(reinterpret_cast<const char*>(name), name_length);
    }
    
    V2TIMGroupMemberInfo memberInfoBasic;
    memberInfoBasic.userID = memberInfo.userID;
    // Note: V2TIMGroupMemberInfo doesn't have role or muteUntil fields
    
    // Check if this is a self disconnect (which may indicate group disband)
    // In Tox, when a group is disbanded, all members receive SELF_DISCONNECTED event
    // We also check if the exiting peer is the founder (group owner)
    bool is_founder = false;
    if (peer_id != UINT32_MAX) {
        Tox_Group_Role peer_role = tox_group_peer_get_role(tox, group_number, peer_id, &err_key);
        if (err_key == TOX_ERR_GROUP_PEER_QUERY_OK && peer_role == TOX_GROUP_ROLE_FOUNDER) {
            is_founder = true;
        }
    }
    
    // If founder left or self disconnected, it might indicate group disband
    // Note: Tox doesn't have explicit disband event, so we check for these conditions
    if (exit_type == TOX_GROUP_EXIT_TYPE_SELF_DISCONNECTED || is_founder) {
        V2TIM_LOG(kInfo, "HandleGroupPeerExit: Group {} may be disbanded (founder left or self disconnected)", groupID.CString());
        // Note: We don't call OnGroupDismissed here because Tox doesn't guarantee disband event
        // The group will be cleaned up when all members leave
    }
    
    // Normal member leave notification
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnMemberLeave(groupID, memberInfoBasic);
        }
    }
}

void V2TIMManagerImpl::HandleGroupModeration(Tox_Group_Number group_number, Tox_Group_Peer_Number source_peer_id, Tox_Group_Peer_Number target_peer_id, Tox_Group_Mod_Event mod_type) {
    V2TIM_LOG(kInfo, "[HandleGroupModeration] ENTRY instance_id={} group_number={} source_peer={} target_peer={} mod_type={}",
              (long long)GetInstanceIdFromManager(this), group_number, source_peer_id, target_peer_id, static_cast<int>(mod_type));
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            V2TIM_LOG(kWarning, "[HandleGroupModeration] group_number={} not in mapping (size={}) — returning early",
                      group_number, group_number_to_group_id_.size());
            return;
        }
        groupID = it->second;
    }

    Tox* tox = GetToxManager()->getTox();
    if (!tox) { V2TIM_LOG(kWarning, "[HandleGroupModeration] tox null — returning early"); return; }

    // Resolve whether this moderation targets our own peer FIRST. The self peer is
    // not reachable through tox_group_peer_get_public_key — it resolves peers via
    // their GC_Connection, and a peer has no connection to itself, so the peer API
    // returns PEER_NOT_FOUND for the self peer_id. When the founder grants/revokes
    // OUR role, the moderation event arrives with target_peer_id == self_peer_id, so
    // we must take the self public-key path. Doing the self check before the key
    // lookup is what lets the "my role changed" notification below actually fire;
    // previously the early return on the failed peer lookup swallowed it (the cause
    // of scenario_group_state_changes_test's role-change timeout).
    Tox_Err_Group_Self_Query err_self;
    Tox_Group_Peer_Number self_peer_id = tox_group_self_get_peer_id(tox, group_number, &err_self);
    const bool self_is_target =
        (err_self == TOX_ERR_GROUP_SELF_QUERY_OK && target_peer_id == self_peer_id);

    // Get target peer public key (self vs. other-peer path).
    uint8_t target_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key = TOX_ERR_GROUP_PEER_QUERY_OK;
    bool got_target_key = false;
    if (self_is_target) {
        Tox_Err_Group_Self_Query err_self_key;
        got_target_key = tox_group_self_get_public_key(tox, group_number, target_pubkey, &err_self_key)
                         && err_self_key == TOX_ERR_GROUP_SELF_QUERY_OK;
    } else {
        got_target_key = GetToxManager()->getGroupPeerPublicKey(group_number, target_peer_id, target_pubkey, &err_key)
                         && err_key == TOX_ERR_GROUP_PEER_QUERY_OK;
    }
    if (!got_target_key) {
        V2TIM_LOG(kWarning, "[HandleGroupModeration] could not resolve target pubkey (self_is_target={}, err_key={}) — returning early",
                  self_is_target ? 1 : 0, static_cast<int>(err_key));
        return;
    }

    std::string target_userID = ToxUtil::tox_bytes_to_hex(target_pubkey, TOX_PUBLIC_KEY_SIZE);

    // Get target peer role after moderation (for future use if needed). Only meaningful
    // for non-self peers; the self role would use tox_group_self_get_role.
    if (!self_is_target) {
        Tox_Group_Role new_role = tox_group_peer_get_role(tox, group_number, target_peer_id, &err_key);
        (void)new_role; // Suppress unused variable warning
    }

    // Notify group listeners based on moderation type
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }

    // When this client is the target of the moderation (e.g. role changed by someone else),
    // notify listeners with OnMemberInfoChanged so the app sees "my role changed".
    V2TIM_LOG(kInfo, "[HandleGroupModeration] self_is_target={} listeners={} — {} OnMemberInfoChanged",
              self_is_target ? 1 : 0, listeners_copy.size(),
              (self_is_target && !listeners_copy.empty()) ? "firing" : "skipping");
    if (self_is_target && !listeners_copy.empty()) {
        V2TIMGroupMemberChangeInfo changeInfo;
        changeInfo.userID = V2TIMString(target_userID.c_str());
        changeInfo.muteTime = 0;
        V2TIMGroupMemberChangeInfoVector changeList;
        changeList.PushBack(changeInfo);
        for (V2TIMGroupListener* listener : listeners_copy) {
            if (listener) {
                listener->OnMemberInfoChanged(groupID, changeList);
            }
        }
    }
    
    V2TIMGroupMemberFullInfo memberInfo;
    memberInfo.userID = target_userID;
    
    switch (mod_type) {
        case TOX_GROUP_MOD_EVENT_KICK:
            // Already handled by HandleGroupPeerExit
            break;
        case TOX_GROUP_MOD_EVENT_MODERATOR:
            // Grant administrator
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_ADMIN;
            {
                V2TIMGroupMemberInfo memberInfoBasic;
                memberInfoBasic.userID = memberInfo.userID;
                V2TIMGroupMemberInfoVector memberList;
                memberList.PushBack(memberInfoBasic);
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        listener->OnGrantAdministrator(groupID, V2TIMGroupMemberInfo(), memberList);
                    }
                }
            }
            break;
        case TOX_GROUP_MOD_EVENT_USER:
            // Revoke administrator
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_MEMBER;
            {
                V2TIMGroupMemberInfo memberInfoBasic;
                memberInfoBasic.userID = memberInfo.userID;
                V2TIMGroupMemberInfoVector memberList;
                memberList.PushBack(memberInfoBasic);
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        listener->OnRevokeAdministrator(groupID, V2TIMGroupMemberInfo(), memberList);
                    }
                }
            }
            break;
        case TOX_GROUP_MOD_EVENT_OBSERVER:
            // Similar to USER role
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_MEMBER;
            {
                V2TIMGroupMemberInfo memberInfoBasic;
                memberInfoBasic.userID = memberInfo.userID;
                V2TIMGroupMemberInfoVector memberList;
                memberList.PushBack(memberInfoBasic);
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        listener->OnRevokeAdministrator(groupID, V2TIMGroupMemberInfo(), memberList);
                    }
                }
            }
            break;
        default:
            break;
    }
}

void V2TIMManagerImpl::HandleGroupSelfJoin(Tox_Group_Number group_number) {
    fprintf(stdout, "[HandleGroupSelfJoin] ========== ENTRY ==========\n");
    fprintf(stdout, "[HandleGroupSelfJoin] group_number=%u\n", group_number);
    fprintf(stdout, "[HandleGroupSelfJoin] this=%p\n", (void*)this);
    // Get current instance ID for debugging
    // Note: GetCurrentInstanceId and GetInstanceIdFromManager are already declared at file scope (lines 27-28)
    int64_t current_instance_id = GetCurrentInstanceId();
    fprintf(stdout, "[HandleGroupSelfJoin] current_instance_id=%lld\n", (long long)current_instance_id);
    // Get instance ID from manager
    int64_t this_instance_id = GetInstanceIdFromManager(this);
    fprintf(stdout, "[HandleGroupSelfJoin] this_instance_id=%lld (from GetInstanceIdFromManager)\n", (long long)this_instance_id);
    fflush(stdout);
    V2TIM_LOG(kInfo, "HandleGroupSelfJoin: ENTRY - group_number=%u, this=%p, current_instance_id=%lld, this_instance_id=%lld", 
              group_number, (void*)this, (long long)current_instance_id, (long long)this_instance_id);
    V2TIMString groupID;
    bool found_in_mapping = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it != group_number_to_group_id_.end()) {
            groupID = it->second;
            found_in_mapping = true;
            fprintf(stdout, "[HandleGroupSelfJoin] Group_number=%u already mapped to groupID=%s\n", 
                    group_number, groupID.CString());
            fflush(stdout);
            V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Group_number=%u already mapped to groupID=%s", group_number, groupID.CString());
        } else {
            fprintf(stdout, "[HandleGroupSelfJoin] Group_number=%u NOT in mapping, will try to rebuild\n", group_number);
            fflush(stdout);
        }
    }
    
    // If not in mapping, try to rebuild it from stored chat_id
    if (!found_in_mapping) {
        // Get chat_id for this group_number
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat_id;
        if (GetToxManager()->getGroupChatId(group_number, chat_id, &err_chat_id) &&
            err_chat_id == TOX_ERR_GROUP_STATE_QUERY_OK) {
            // Convert to hex string
            std::ostringstream oss;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
            }
            std::string chat_id_hex = oss.str();
            
            // Try to find groupID by checking stored chat_id for all known groups (R-07: Core metadata)
            std::vector<std::string> known_groups_vec = GetKnownGroupIDs();
            if (!known_groups_vec.empty()) {
                for (const auto& line : known_groups_vec) {
                    if (line.empty()) continue;
                    char stored_chat_id[65];
                    if (!GetGroupChatIdFromStorage(line, stored_chat_id, sizeof(stored_chat_id))) continue;
                    std::string stored_hex(stored_chat_id);
                    if (stored_hex == chat_id_hex) {
                            // Found matching groupID!
                            groupID = V2TIMString(line.c_str());
                            found_in_mapping = true;
                            
                            // Rebuild the mapping
                            std::lock_guard<std::mutex> lock(mutex_);
                            group_id_to_group_number_[groupID] = group_number;
                            group_number_to_group_id_[group_number] = groupID;
                            
                            // Also store chat_id mapping
                            group_id_to_chat_id_[groupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                            chat_id_to_group_id_[chat_id_hex] = groupID;
                            
                            V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Rebuilt mapping from stored chat_id: groupID=%s <-> group_number=%u, chat_id=%s", 
                                     groupID.CString(), group_number, chat_id_hex.c_str());
                            
                            // Check if this was from a pending invite by looking for group_number match
                            // If so, trigger onMemberInvited callback with the actual groupID
                            V2TIMString temp_groupID;
                            PendingInvite* pending_inv = nullptr;
                            {
                                std::lock_guard<std::mutex> lock(mutex_);
                                // Find pending invite with matching group_number
                                for (auto it = pending_group_invites_.begin(); it != pending_group_invites_.end(); ++it) {
                                    if (it->second.group_number == group_number) {
                                        temp_groupID = it->first;
                                        pending_inv = &it->second;
                                        V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Found pending invite: temp_groupID={}, group_number={}", 
                                                 temp_groupID.CString(), group_number);
                                        break;
                                    }
                                }
                            }
                            
                            // If this was from a pending invite, trigger onMemberInvited with actual groupID
                            if (pending_inv && !temp_groupID.Empty()) {
                                V2TIM_LOG(kInfo, "HandleGroupSelfJoin: This group was from a pending invite, triggering onMemberInvited with actual groupID=%s", groupID.CString());
                                fprintf(stdout, "[HandleGroupSelfJoin] Triggering onMemberInvited with actual groupID=%s (was temp=%s)\n", 
                                        groupID.CString(), temp_groupID.CString());
                                fflush(stdout);
                                
                                // Get inviter info from pending invite
                                V2TIMGroupMemberInfo opUser;
                                if (!pending_inv->inviter_userID.empty()) {
                                    opUser.userID = V2TIMString(pending_inv->inviter_userID.c_str());
                                    V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Using stored inviter userID: {}", pending_inv->inviter_userID);
                                } else {
                                    // Fallback: get inviter's public key from friend_number
                                    Tox* tox = GetToxManager()->getTox();
                                    if (tox) {
                                        uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
                                        if (tox_friend_get_public_key(tox, pending_inv->friend_number, inviter_pubkey, nullptr)) {
                                            std::string inviterUserID = ToxUtil::tox_bytes_to_hex(inviter_pubkey, TOX_PUBLIC_KEY_SIZE);
                                            opUser.userID = V2TIMString(inviterUserID.c_str());
                                            V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Got inviter public key: {}", inviterUserID);
                                        }
                                    }
                                }
                                
                                // Build member list (contains self)
                                V2TIMGroupMemberInfoVector memberList;
                                V2TIMGroupMemberInfo selfMember;
                                Tox* tox = GetToxManager()->getTox();
                                if (tox) {
                                    uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                                    tox_self_get_public_key(tox, self_pubkey);
                                    std::string selfUserID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                                    selfMember.userID = V2TIMString(selfUserID.c_str());
                                    memberList.PushBack(selfMember);
                                }
                                
                                // Notify listeners with actual groupID
                                std::vector<V2TIMGroupListener*> listeners_copy;
                                {
                                    std::lock_guard<std::mutex> lock(mutex_);
                                    listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
                                }
                                
                                for (V2TIMGroupListener* listener : listeners_copy) {
                                    if (listener) {
                                        fprintf(stdout, "[HandleGroupSelfJoin] Calling OnMemberInvited with actual groupID=%s\n", groupID.CString());
                                        fflush(stdout);
                                        V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Calling OnMemberInvited: groupID={}, inviter={}, memberCount={}",
                                                 groupID.CString(), opUser.userID.CString(), memberList.Size());
                                        listener->OnMemberInvited(groupID, opUser, memberList);
                                    }
                                }
                                
                                // Remove pending invite and update mapping
                                {
                                    std::lock_guard<std::mutex> lock(mutex_);
                                    // Remove temporary groupID mapping
                                    group_id_to_group_number_.erase(temp_groupID);
                                    // Update to actual groupID
                                    group_id_to_group_number_[groupID] = group_number;
                                    group_number_to_group_id_[group_number] = groupID;
                                    // Remove pending invite
                                    pending_group_invites_.erase(temp_groupID);
                                    V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Updated mapping from temp_groupID={} to actual groupID={}", 
                                             temp_groupID.CString(), groupID.CString());
                                }
                            }
                            
                            break;
                    }
                }
            }
            
            if (!found_in_mapping) {
                // No stored groupID for this chat_id, might be a new group or group without stored chat_id
                // Store the chat_id anyway so it can be used later for mapping recovery
                // Note: Function is already declared with extern "C" at file scope (line 38)
                // We don't have a groupID yet, but we can store the chat_id with a temporary key
                // or wait for GetGroupsInfo to assign a groupID. For now, we'll just log it.
                V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Group_number=%u not in mapping and no stored groupID found for chat_id=%s, will be handled by GetGroupsInfo", 
                         group_number, chat_id_hex.c_str());
                // Note: chat_id will be stored when GetGroupsInfo assigns a groupID to this group
                return;
            }
        } else {
            V2TIM_LOG(kWarning, "HandleGroupSelfJoin: Group_number=%u not in mapping and failed to get chat_id, error=%d", 
                     group_number, err_chat_id);
            return;
        }
    }
    
    // Notify group listeners about self join
    std::vector<V2TIMGroupListener*> listeners_copy;
    size_t total_listeners = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        total_listeners = group_listeners_.size();
        fprintf(stdout, "[HandleGroupSelfJoin] Total listeners in group_listeners_: %zu\n", total_listeners);
        fflush(stdout);
        
        // Print all listener pointers for debugging
        if (total_listeners > 0) {
            fprintf(stdout, "[HandleGroupSelfJoin] Listener pointers:\n");
            size_t idx = 0;
            for (auto* listener : group_listeners_) {
                fprintf(stdout, "[HandleGroupSelfJoin]   [%zu] listener=%p\n", idx++, (void*)listener);
            }
            fflush(stdout);
        } else {
            fprintf(stderr, "[HandleGroupSelfJoin] WARNING: group_listeners_ is empty!\n");
            fprintf(stderr, "[HandleGroupSelfJoin] Checking if this instance has listeners registered elsewhere...\n");
            fflush(stderr);
        }
        
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
        fprintf(stdout, "[HandleGroupSelfJoin] Copied %zu listeners to listeners_copy\n", listeners_copy.size());
        fflush(stdout);
    }
    
    fprintf(stdout, "[HandleGroupSelfJoin] Notifying %zu listeners about groupID=%s\n", 
            listeners_copy.size(), groupID.CString());
    fflush(stdout);
    
    if (listeners_copy.empty()) {
        fprintf(stderr, "[HandleGroupSelfJoin] WARNING: No listeners registered! Total listeners in map: %zu\n", total_listeners);
        fflush(stderr);
    }
    
    for (size_t i = 0; i < listeners_copy.size(); i++) {
        V2TIMGroupListener* listener = listeners_copy[i];
        if (listener) {
            fprintf(stdout, "[HandleGroupSelfJoin] [%zu/%zu] Calling OnGroupCreated for listener=%p, groupID=%s\n", 
                    i + 1, listeners_copy.size(), (void*)listener, groupID.CString());
            fflush(stdout);
            try {
                listener->OnGroupCreated(groupID);
                fprintf(stdout, "[HandleGroupSelfJoin] [%zu/%zu] OnGroupCreated completed for listener=%p\n", 
                        i + 1, listeners_copy.size(), (void*)listener);
                fflush(stdout);
            } catch (const std::exception& e) {
                fprintf(stderr, "[HandleGroupSelfJoin] [%zu/%zu] EXCEPTION in OnGroupCreated for listener=%p: %s\n", 
                        i + 1, listeners_copy.size(), (void*)listener, e.what());
                fflush(stderr);
            } catch (...) {
                fprintf(stderr, "[HandleGroupSelfJoin] [%zu/%zu] UNKNOWN EXCEPTION in OnGroupCreated for listener=%p\n", 
                        i + 1, listeners_copy.size(), (void*)listener);
                fflush(stderr);
            }
        } else {
            fprintf(stderr, "[HandleGroupSelfJoin] [%zu/%zu] WARNING: listener is null\n", i + 1, listeners_copy.size());
            fflush(stderr);
        }
    }
    
    fprintf(stdout, "[HandleGroupSelfJoin] ========== EXIT ==========\n");
    fflush(stdout);
}

void V2TIMManagerImpl::HandleGroupJoinFail(Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type) {
    V2TIM_LOG(kError, "HandleGroupJoinFail: Failed to join group_number {}, fail_type: {}", group_number, fail_type);
    // Notify listeners if needed
}

void V2TIMManagerImpl::HandleGroupPrivacyState(Tox_Group_Number group_number, Tox_Group_Privacy_State privacy_state) {
    fprintf(stdout, "[HandleGroupPrivacyState] ========== ENTRY ==========\n");
    fprintf(stdout, "[HandleGroupPrivacyState] group_number=%u, privacy_state=%d (0=PUBLIC, 1=PRIVATE)\n", 
            group_number, static_cast<int>(privacy_state));
    fflush(stdout);
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            fprintf(stdout, "[HandleGroupPrivacyState] ERROR: group_number=%u not found in mapping\n", group_number);
            fflush(stdout);
            return;
        }
        groupID = it->second;
        fprintf(stdout, "[HandleGroupPrivacyState] Found mapping: group_number=%u -> groupID=%s\n", 
                group_number, groupID.CString());
        fflush(stdout);
    }
    
    // Notify group listeners about privacy state change
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    V2TIMGroupChangeInfo changeInfo;
    changeInfo.type = V2TIM_GROUP_INFO_CHANGE_TYPE_CUSTOM; // Privacy state is a custom change
    
    V2TIMGroupChangeInfoVector changeList;
    changeList.PushBack(changeInfo);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnGroupInfoChanged(groupID, changeList);
        }
    }
}

void V2TIMManagerImpl::HandleGroupVoiceState(Tox_Group_Number group_number, Tox_Group_Voice_State voice_state) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }
    
    // Notify group listeners about voice state change (maps to mute all)
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    bool isMuted = (voice_state == TOX_GROUP_VOICE_STATE_MODERATOR || voice_state == TOX_GROUP_VOICE_STATE_FOUNDER);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnAllGroupMembersMuted(groupID, isMuted);
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerStatus(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_USER_STATUS status) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }
    
    // Get peer public key to find userID
    Tox* tox = GetToxManager()->getTox();
    if (!tox) return;
    
    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
        err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }
    
    std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
    
    // Notify group listeners about member status change
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    V2TIMGroupMemberChangeInfo changeInfo;
    changeInfo.userID = userID;
    // Note: V2TIM doesn't have a direct status field in GroupMemberChangeInfo
    // We'll just notify that member info changed
    
    V2TIMGroupMemberChangeInfoVector changeList;
    changeList.PushBack(changeInfo);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnMemberInfoChanged(groupID, changeList);
        }
    }
}

#ifdef BUILD_TOXAV
// Helper method to get ToxAVManager instance (for internal use).
// ToxAVManager is created in InitSDK (same as ToxManager), not lazily, to avoid
// crashes when first creating it from FFI callback context.
ToxAVManager* V2TIMManagerImpl::GetToxAVManager() {
    return toxav_manager_.get();
}
#endif

void V2TIMManagerImpl::RejoinKnownGroups() {
    // Check if manager is still valid
    if (!tox_manager_) {
        fprintf(stderr, "[RejoinKnownGroups] WARNING: tox_manager_ is null, skipping\n");
        fflush(stderr);
        return;
    }
    
    // R-07: Get known groups from Core metadata
    std::vector<std::string> known_groups_list = GetKnownGroupIDs();
    if (known_groups_list.empty()) {
        return;
    }
    
    int rejoin_attempts = 0;
    int rejoin_successes = 0;
    int conference_restored = 0;
    
    // First, restore conferences from savedata (they are automatically restored by Tox)
    Tox* tox = nullptr;
    try {
        tox = tox_manager_->getTox();
    } catch (const std::exception& e) {
        fprintf(stderr, "[RejoinKnownGroups] Exception getting Tox instance: %s\n", e.what());
        fflush(stderr);
        return;
    } catch (...) {
        fprintf(stderr, "[RejoinKnownGroups] Unknown exception getting Tox instance\n");
        fflush(stderr);
        return;
    }
    
    if (tox) {
        size_t conference_count = 0;
        try {
            conference_count = tox_conference_get_chatlist_size(tox);
        } catch (const std::exception& e) {
            fprintf(stderr, "[RejoinKnownGroups] Exception querying conference count: %s\n", e.what());
            fflush(stderr);
            conference_count = 0;
        } catch (...) {
            fprintf(stderr, "[RejoinKnownGroups] Unknown exception querying conference count\n");
            fflush(stderr);
            conference_count = 0;
        }
        
        if (conference_count > 0) {
            std::vector<Tox_Conference_Number> conference_list(conference_count);
            try {
                tox_conference_get_chatlist(tox, conference_list.data());
            } catch (const std::exception& e) {
                fprintf(stderr, "[RejoinKnownGroups] Exception in tox_conference_get_chatlist: %s\n", e.what());
                fflush(stderr);
                conference_count = 0;
            } catch (...) {
                fprintf(stderr, "[RejoinKnownGroups] Unknown exception in tox_conference_get_chatlist\n");
                fflush(stderr);
                conference_count = 0;
            }
            
            if (conference_count > 0) {
                for (const auto& line : known_groups_list) {
                    try {
                        std::string line_trim = line;
                        while (!line_trim.empty() && line_trim.back() == '\n') line_trim.pop_back();
                        if (line_trim.empty()) continue;
                        
                        // Check group type
                        char stored_type[16];
                        std::string group_type = "group"; // Default
                        if (GetGroupTypeFromStorage(line_trim, stored_type, sizeof(stored_type))) {
                            group_type = std::string(stored_type);
                        }
                        
                        if (group_type == "conference") {
                            bool already_mapped = false;
                            try {
                                std::lock_guard<std::mutex> lock(mutex_);
                                for (const auto& pair : group_number_to_group_id_) {
                                    std::string pair_str = pair.second.CString();
                                    if (pair_str == line_trim) {
                                        already_mapped = true;
                                        break;
                                    }
                                }
                            } catch (const std::exception& e) {
                                fprintf(stderr, "[RejoinKnownGroups] Exception while checking conference mapping: %s\n", e.what());
                                fflush(stderr);
                                continue;
                            } catch (...) {
                                fprintf(stderr, "[RejoinKnownGroups] Unknown exception while checking conference mapping\n");
                                fflush(stderr);
                                continue;
                            }
                            
                            if (!already_mapped) {
                                for (Tox_Conference_Number conf_num : conference_list) {
                                    bool conf_mapped = false;
                                    try {
                                        std::lock_guard<std::mutex> lock(mutex_);
                                        if (group_number_to_group_id_.find(conf_num) != group_number_to_group_id_.end()) {
                                            conf_mapped = true;
                                        }
                                    } catch (...) {
                                        fprintf(stderr, "[RejoinKnownGroups] Exception while checking conference mapping, skipping\n");
                                        fflush(stderr);
                                        break;
                                    }
                                    
                                    if (!conf_mapped) {
                                        V2TIMString groupID(line_trim.c_str());
                                        try {
                                            std::lock_guard<std::mutex> lock(mutex_);
                                            group_id_to_group_number_[groupID] = conf_num;
                                            group_number_to_group_id_[conf_num] = groupID;
                                        } catch (...) {
                                            fprintf(stderr, "[RejoinKnownGroups] Exception while storing conference mapping, skipping\n");
                                            fflush(stderr);
                                            break;
                                        }
                                        conference_restored++;
                                        break; // Match one conference per groupID
                                    }
                                }
                            }
                        }
                    } catch (const std::exception& e) {
                        fprintf(stderr, "[RejoinKnownGroups] Exception processing line: %s\n", e.what());
                        fflush(stderr);
                        continue;
                    } catch (...) {
                        fprintf(stderr, "[RejoinKnownGroups] Unknown exception processing line\n");
                        fflush(stderr);
                        continue;
                    }
                }
            }
        }
    }
    
    // Now restore groups using chat_id (R-07: iterate known_groups_list)
    for (const auto& line : known_groups_list) {
        try {
            std::string line_trim = line;
            while (!line_trim.empty() && line_trim.back() == '\n') line_trim.pop_back();
            if (line_trim.empty()) continue;
            
            bool already_mapped = false;
            try {
                std::lock_guard<std::mutex> lock(mutex_);
                for (const auto& pair : group_number_to_group_id_) {
                    std::string pair_str = pair.second.CString();
                    if (pair_str == line_trim) {
                        already_mapped = true;
                        break;
                    }
                }
            } catch (const std::exception& e) {
                fprintf(stderr, "[RejoinKnownGroups] Exception while checking group mapping: %s\n", e.what());
                fflush(stderr);
                continue;
            } catch (...) {
                fprintf(stderr, "[RejoinKnownGroups] Unknown exception while checking group mapping\n");
                fflush(stderr);
                continue;
            }
            
            if (already_mapped) {
                continue;
            }
            
            // Check group type
            char stored_type[16];
            std::string group_type = "group"; // Default
            try {
                if (GetGroupTypeFromStorage(line_trim, stored_type, sizeof(stored_type))) {
                    group_type = std::string(stored_type);
                }
            } catch (const std::exception& e) {
                fprintf(stderr, "[RejoinKnownGroups] Exception in GetGroupTypeFromStorage for '%s': %s\n", line_trim.c_str(), e.what());
                fflush(stderr);
                group_type = "group"; // Use default on error
            } catch (...) {
                fprintf(stderr, "[RejoinKnownGroups] Unknown exception in GetGroupTypeFromStorage for '%s'\n", line_trim.c_str());
                fflush(stderr);
                group_type = "group"; // Use default on error
            }
            
            // Only process group type here (conference already handled above)
            if (group_type != "group") {
                continue;
            }
            
            // Get stored chat_id for this group
            char stored_chat_id[65];
            bool has_stored_chat_id = GetGroupChatIdFromStorage(line_trim, stored_chat_id, sizeof(stored_chat_id));
            if (!has_stored_chat_id) {
                continue;
            }
            
            // Convert hex string to binary chat_id
            std::string chat_id_hex(stored_chat_id);
            if (chat_id_hex.length() != TOX_GROUP_CHAT_ID_SIZE * 2) {
                fprintf(stderr, "[RejoinKnownGroups] Invalid chat_id length for group %s: %zu (expected %d)\n", 
                        line_trim.c_str(), chat_id_hex.length(), TOX_GROUP_CHAT_ID_SIZE * 2);
                fflush(stderr);
                continue;
            }
            
            uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
            bool conversion_success = true;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                std::string byte_str = chat_id_hex.substr(i * 2, 2);
                char* endptr;
                unsigned long byte_val = strtoul(byte_str.c_str(), &endptr, 16);
                if (*endptr != '\0' || byte_val > 255) {
                    fprintf(stderr, "[RejoinKnownGroups] Invalid chat_id hex string for group %s at byte %zu\n", 
                            line_trim.c_str(), i);
                    fflush(stderr);
                    conversion_success = false;
                    break;
                }
                chat_id[i] = static_cast<uint8_t>(byte_val);
            }
            
            if (!conversion_success) {
                continue;
            }
            
            // Check if tox_manager_ is still valid before calling joinGroup
            if (!tox_manager_) {
                fprintf(stderr, "[RejoinKnownGroups] tox_manager_ became null, skipping remaining groups\n");
                fflush(stderr);
                break;
            }

            // Before attempting to join, check if the group already exists in Tox (restored from savedata).
            // tox_group_join() on an already-existing group returns an unreliable group_number (often 0),
            // which causes all groups to get mapped to the same number. Use getGroupByChatId first.
            Tox_Group_Number existing_group_number = tox_manager_->getGroupByChatId(chat_id);
            if (existing_group_number != UINT32_MAX) {
                // Group already exists in Tox - just record the mapping, no need to join
                rejoin_successes++;
                V2TIMString groupID(line_trim.c_str());
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    group_id_to_group_number_[groupID] = existing_group_number;
                    group_number_to_group_id_[existing_group_number] = groupID;
                }
                rejoin_attempts++;
                continue;
            }

            // Group not found in Tox - attempt to join using chat_id
            // Get self name for joining
            std::string self_name = tox_manager_->getName();
            if (self_name.empty()) {
                self_name = "User";
            }

            // Attempt to rejoin group using chat_id
            rejoin_attempts++;
            Tox_Err_Group_Join err_join;
            Tox_Group_Number group_number = tox_manager_->joinGroup(
                chat_id,
                reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
                nullptr, 0, // No password
                &err_join
            );

            if (err_join == TOX_ERR_GROUP_JOIN_OK && group_number != UINT32_MAX) {
                rejoin_successes++;
                V2TIMString groupID(line_trim.c_str());
                // Strategy:
                // 1. Pre-register chat_id→groupID (first-wins) so HandleGroupSelfJoin can resolve.
                // 2. ALSO store group_number→groupID immediately as a fallback, because
                //    HandleGroupSelfJoin may never fire when the underlying group join does not
                //    complete on the network (e.g. corrupt/ghost chat_id with no live peers).
                // 3. For duplicate groupIDs with the same stored chat_id (data corruption), route
                //    them to the SAME canonical group_number as the first-wins owner so that sends
                //    to tox_2/tox_3 still reach the physical group.
                {
                    std::ostringstream oss;
                    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
                    }
                    std::string chat_id_hex = oss.str();
                    std::lock_guard<std::mutex> lock(mutex_);

                    // --- Step 1: resolve owner for this chat_id ---
                    V2TIMString owner_groupID;
                    auto chat_it = chat_id_to_group_id_.find(chat_id_hex);
                    if (chat_it == chat_id_to_group_id_.end()) {
                        // First group with this chat_id becomes the owner.
                        chat_id_to_group_id_[chat_id_hex] = groupID;
                        group_id_to_chat_id_[groupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                        owner_groupID = groupID;
                    } else {
                        owner_groupID = chat_it->second;
                        V2TIM_LOG(kWarning, "RejoinKnownGroups: Duplicate chat_id={} - owner={}, aliasing groupID={}",
                                  chat_id_hex, owner_groupID.CString(), groupID.CString());
                        fprintf(stderr, "[RejoinKnownGroups] WARNING: Duplicate chat_id, owner=%s, alias=%s\n",
                                owner_groupID.CString(), groupID.CString());
                    }

                    // --- Step 2: determine canonical group_number for this chat_id ---
                    // For the owner: use the returned group_number.
                    // For duplicates: reuse the owner's already-stored group_number if available.
                    Tox_Group_Number canonical_number = group_number;
                    if (groupID != owner_groupID) {
                        auto owner_num_it = group_id_to_group_number_.find(owner_groupID);
                        if (owner_num_it != group_id_to_group_number_.end()) {
                            canonical_number = owner_num_it->second;
                        }
                    }

                    // --- Step 3: store mappings ---
                    // Primary direction (group_number → groupID): first-wins to avoid overwrite.
                    if (group_number_to_group_id_.find(canonical_number) == group_number_to_group_id_.end()) {
                        group_number_to_group_id_[canonical_number] = owner_groupID;
                    }
                    // Reverse direction (groupID → group_number): update owner to latest join result.
                    group_id_to_group_number_[owner_groupID] = canonical_number;
                    // Alias groupIDs (duplicates) also point to canonical group_number.
                    if (groupID != owner_groupID) {
                        group_id_to_group_number_[groupID] = canonical_number;
                    }

                }
            } else {
                fprintf(stderr, "[RejoinKnownGroups] Failed to rejoin group %s, error=%d (group may not exist or may have been removed)\n",
                        line_trim.c_str(), err_join);
                fflush(stderr);
            }
        } catch (const std::exception& e) {
            fprintf(stderr, "[RejoinKnownGroups] Exception processing group line_trim: %s\n", e.what());
            fflush(stderr);
            continue;
        } catch (...) {
            fprintf(stderr, "[RejoinKnownGroups] Unknown exception processing group line_trim\n");
            fflush(stderr);
            continue;
        }
    }
    
    // Rebuild group_number <-> groupID mapping from current Tox state (R-07: iterate known_groups_list).
    for (const auto& line_rebuild : known_groups_list) {
        try {
            std::string lr = line_rebuild;
            while (!lr.empty() && lr.back() == '\n') lr.pop_back();
            if (lr.empty()) continue;
            char stored_type[16];
            std::string group_type = "group";
            if (GetGroupTypeFromStorage(lr, stored_type, sizeof(stored_type))) {
                group_type = std::string(stored_type);
            }
            if (group_type != "group") continue;
            char stored_chat_id[65];
            if (!GetGroupChatIdFromStorage(lr, stored_chat_id, sizeof(stored_chat_id))) continue;
            std::string chat_id_hex(stored_chat_id);
            if (chat_id_hex.length() != static_cast<size_t>(TOX_GROUP_CHAT_ID_SIZE * 2)) continue;
            uint8_t chat_id_bin[TOX_GROUP_CHAT_ID_SIZE];
            bool ok = true;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                std::string byte_str = chat_id_hex.substr(i * 2, 2);
                char* endptr = nullptr;
                unsigned long v = strtoul(byte_str.c_str(), &endptr, 16);
                if (!endptr || *endptr != '\0' || v > 255) { ok = false; break; }
                chat_id_bin[i] = static_cast<uint8_t>(v);
            }
            if (!ok || !tox_manager_) continue;
            Tox_Group_Number actual = tox_manager_->getGroupByChatId(chat_id_bin);
            if (actual == UINT32_MAX) continue;
            V2TIMString groupID(lr.c_str());
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_group_number_[groupID] = actual;
                group_number_to_group_id_[actual] = groupID;
            }
        } catch (...) { continue; }
    }
    
    V2TIM_LOG(kInfo, "[RejoinKnownGroups] attempts={}, successes={}, conferences_restored={}",
              rejoin_attempts, rejoin_successes, conference_restored);
}
