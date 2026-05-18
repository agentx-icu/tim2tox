// Minimal C FFI for tim2tox using V2TIM* APIs only
#pragma once
#include <stdint.h>
#include <stddef.h>  // For size_t

#ifdef __cplusplus
extern "C" {
#endif

// Initialize SDK; returns 1 on success, 0 on failure
int tim2tox_ffi_init(void);

// Initialize SDK with profile directory path (for multi-account).
// init_path: directory for storing tox profile (e.g. "<persistent_root>/p_<toxId_first16>");
//            if null or empty, behaves like tim2tox_ffi_init() (default path).
// Returns 1 on success, 0 on failure
int tim2tox_ffi_init_with_path(const char* init_path);

// Test-only: Create a new V2TIMManagerImpl instance for testing
// init_path: path for storing Tox profile (e.g., "/tmp/test_node_alice/init")
// local_discovery_enabled: enable local network discovery (1 = enabled, 0 = disabled)
// ipv6_enabled: enable IPv6 (1 = enabled, 0 = disabled)
// Returns: instance handle (pointer as int64_t) on success, 0 on failure
// Note: This function is for testing only and allows multiple independent instances
int64_t tim2tox_ffi_create_test_instance_ex(const char* init_path, int local_discovery_enabled, int ipv6_enabled);

// Test-only: Create a new V2TIMManagerImpl instance for testing (backward compatibility)
// init_path: path for storing Tox profile (e.g., "/tmp/test_node_alice/init")
// Returns: instance handle (pointer as int64_t) on success, 0 on failure
// Note: This function is for testing only and allows multiple independent instances
// Uses default options (local_discovery_enabled=1, ipv6_enabled=1)
int64_t tim2tox_ffi_create_test_instance(const char* init_path);

// Test-only: Set current instance for FFI operations
// instance_handle: handle returned by tim2tox_ffi_create_test_instance
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_set_current_instance(int64_t instance_handle);

// Test-only: Destroy a test instance
// instance_handle: handle returned by tim2tox_ffi_create_test_instance
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_destroy_test_instance(int64_t instance_handle);

// Get current instance ID
// Returns: instance ID (>0 for test instances, 0 for default instance)
int64_t tim2tox_ffi_get_current_instance_id(void);

// Run N iterations on current instance (for tests: accelerate Tox group peer discovery).
// Call from test with set_current_instance set to founder then member1 in turn.
// Returns 1 on success, 0 if current instance or ToxManager is null.
int tim2tox_ffi_iterate_current_instance(int count);

// Run N round-robin iterations on all test instances (for multi-instance tests).
// Each instance is iterated once per round; total rounds = count. Use this to advance
// all instances in one FFI call (e.g. friend connection, group peer discovery).
// Returns number of instances iterated (>= 1 on success), or 0 if none.
int tim2tox_ffi_iterate_all_instances(int count);

// Test-only: Enable/disable test mode for a single instance.
// Must be called AFTER tim2tox_ffi_create_test_instance(...) and BEFORE tim2tox_ffi_login*.
// When enabled=1:
//   1. The instance's event_thread will NOT auto-start in InitSDK.
//   2. The underlying Tox's mono_time will read from a process-global virtual clock.
// Returns 1 on success, 0 if instance not found or mode change rejected.
int tim2tox_ffi_set_test_mode(int64_t instance_id, int enabled);

// Test-only: Set the process-global virtual clock value (milliseconds).
// All instances currently in test mode share this clock.
// Caller must ensure monotonic increase.
// Returns 1 always (no failure mode).
int tim2tox_ffi_set_virtual_time_ms(uint64_t time_ms);

// Test-only: Set the process-global default test_mode flag. New
// V2TIMManagerImpl instances created AFTER this call (via
// tim2tox_ffi_create_test_instance_ex) will inherit this flag in their
// constructor, so InitSDK skips spawning event_thread. Required for tests
// that need task_queue-based flows (signaling, etc.) to be driven by the
// Dart-side tick loop instead of the wall-clock event thread.
// Returns 1 always.
int tim2tox_ffi_set_default_test_mode(int enabled);

// Test-only: Iterate exactly once for the given instance.
// Equivalent to one round of the event_thread "ToxManager::iterate()" body,
// minus the sleep. Use with tim2tox_ffi_set_virtual_time_ms() to drive Tox
// from a virtual clock under the auto_tests harness.
// Returns 1 on success, 0 if instance not found or shutting down.
int tim2tox_ffi_iterate_instance(int64_t instance_id);

// Set file receive directory (should be called before receiving files)
// dir_path: path to directory for storing received files
// Returns 1 on success, 0 on failure
int tim2tox_ffi_set_file_recv_dir(const char* dir_path);

// Set unified log file path (should be called before tim2tox_ffi_init).
// C++ logs will be written in unified format to this file; console output is disabled.
void tim2tox_ffi_set_log_file(const char* path);

// Login; returns 1 on async start; completion is signaled by connection status and subsequent ops
int tim2tox_ffi_login(const char* user_id, const char* user_sig);

// R-08: Async login with explicit instance_id and completion callback.
// callback(success, error_code, error_message, user_data): success=1 on success, 0 on failure; error_message valid only during callback.
// Returns: 1 if login was started, 0 if instance not found / not inited / invalid args.
typedef void (*tim2tox_login_callback_t)(int success, int error_code, const char* error_message, void* user_data);
int tim2tox_ffi_login_async(int64_t instance_id, const char* user_id, const char* user_sig, tim2tox_login_callback_t callback, void* user_data);

// Add friend; returns 1 if request submitted
int tim2tox_ffi_add_friend(const char* user_id, const char* wording);

// Send C2C text; returns 1 if submitted
int tim2tox_ffi_send_c2c_text(const char* user_id, const char* text);

// Send C2C custom message; returns 1 if submitted
// data: raw bytes of custom data
// data_len: length of data in bytes
int tim2tox_ffi_send_c2c_custom(const char* user_id, const unsigned char* data, int data_len);

// Send group custom message; returns 1 if submitted
// data: raw bytes of custom data
// data_len: length of data in bytes
int tim2tox_ffi_send_group_custom(const char* group_id, const unsigned char* data, int data_len);

// Poll next received text message for the given instance (or broadcast events with instance_id 0).
// instance_id: current instance; only events for this instance or broadcast (id 0) are returned.
// Returns number of bytes written (excluding terminating 0), or 0 if none.
int tim2tox_ffi_poll_text(int64_t instance_id, char* buffer, int buffer_len);

// Poll next received custom/binary message. Returns bytes written into buffer or 0 if none.
int tim2tox_ffi_poll_custom(unsigned char* buffer, int buffer_len);

// Get current login user id into buffer; returns bytes written
int tim2tox_ffi_get_login_user(char* buffer, int buffer_len);

// Get the self Tox address (76-hex public key + nospam + checksum) for the
// current instance into buffer; returns bytes written, or 0 if the address
// is not yet known (e.g. before the first DHT connection establishes).
// Distinct from tim2tox_ffi_get_login_user, which returns the login alias.
int tim2tox_ffi_get_self_tox_id(char* buffer, int buffer_len);

// Shutdown SDK
void tim2tox_ffi_uninit(void);

// Save tox profile to disk (same path as init). Call periodically or on app pause to reduce data loss on crash.
void tim2tox_ffi_save_tox_profile(void);

// Get friend list as newline-separated lines:
// "<userID>\t<nickName>\t<online>\n"
// nickName may be empty; online is 0 or 1.
// Returns number of bytes written, or 0 on error.
int tim2tox_ffi_get_friend_list(char* buffer, int buffer_len);

// Update self profile (nickname and status message). Returns 1 if request submitted.
int tim2tox_ffi_set_self_info(const char* nickname, const char* status_message);

// Save friend nickname to local cache (called from C++ when friend name changes)
// friend_id: friend's user ID (hex string)
// nickname: friend's nickname
// Returns 1 on success, 0 on failure
int tim2tox_ffi_save_friend_nickname(const char* friend_id, const char* nickname);

// Save friend status message to local cache (called from C++ when friend status message changes)
// friend_id: friend's user ID (hex string)
// status_message: friend's status message
// Returns 1 on success, 0 on failure
int tim2tox_ffi_save_friend_status_message(const char* friend_id, const char* status_message);

// Friend applications list as lines:
// "<userID>\t<addWording>\n"
int tim2tox_ffi_get_friend_applications(char* buffer, int buffer_len);
// Same but for a specific instance_id (avoids GetCurrentInstance() being changed before native runs)
int tim2tox_ffi_get_friend_applications_for_instance(int64_t instance_id, char* buffer, int buffer_len);

// Accept a friend application by userID; returns 1 if submitted
int tim2tox_ffi_accept_friend(const char* user_id);

// Delete friend by userID; returns 1 if submitted
int tim2tox_ffi_delete_friend(const char* user_id);

// Typing indicator
int tim2tox_ffi_set_typing(const char* user_id, int typing_on);

// Groups (text)
// Create group with optional name; writes groupID into out buffer; returns bytes written
// group_type: "group" for new Tox Group API, "conference" for old Conference API
int tim2tox_ffi_create_group(const char* group_name, const char* group_type, char* out_group_id, int out_len);
int tim2tox_ffi_join_group(const char* group_id, const char* request_msg);
int tim2tox_ffi_send_group_text(const char* group_id, const char* text);
// Update known groups list from Dart layer
// groups_str: newline-separated list of group IDs (e.g., "tox_0\ntox_1\ntox_2\n")
// This should be called by Dart layer whenever knownGroups changes
// Returns number of groups updated
int tim2tox_ffi_update_known_groups(int64_t instance_id, const char* groups_str);

// Get known group IDs from global list (synchronized from Dart layer)
// Writes group IDs as newline-separated lines into buffer; returns bytes written, or 0 on error
int tim2tox_ffi_get_known_groups(int64_t instance_id, char* buffer, int buffer_len);

// Get full tox group chat_id from groupID
// group_id: group ID like "tox_6"
// out_chat_id: output buffer for chat_id (64-char hex string, TOX_GROUP_CHAT_ID_SIZE * 2)
// out_len: size of output buffer (should be at least 65 for null terminator)
// Returns: 1 on success, 0 on error
int tim2tox_ffi_get_group_chat_id(int64_t instance_id, const char* group_id, char* out_chat_id, int out_len);

// Store group chat_id to persistence (called from C++ when group is created)
// group_id: group ID like "tox_6"
// chat_id: 64-char hex string chat_id
// Returns: 1 on success, 0 on error
int tim2tox_ffi_set_group_chat_id(int64_t instance_id, const char* group_id, const char* chat_id);

// Store group type to persistence (called from C++ when group is created)
// group_id: group ID like "tox_6"
// group_type: "group" (new API) or "conference" (old API)
// Returns: 1 on success, 0 on error
int tim2tox_ffi_set_group_type(int64_t instance_id, const char* group_id, const char* group_type);

// Get group type from global storage (called from C++ to determine group type)
// group_id: group ID like "tox_6"
// out_group_type: output buffer (at least 16 bytes)
// out_len: size of output buffer
// Returns: 1 if found, 0 if not found
int tim2tox_ffi_get_group_type_from_storage(int64_t instance_id, const char* group_id, char* out_group_type, int out_len);

// Get group chat_id from persistence (called from C++ to rebuild mapping)
// group_id: group ID like "tox_6"
// out_chat_id: output buffer for chat_id (64-char hex string)
// out_len: size of output buffer (should be at least 65 for null terminator)
// Returns: 1 on success, 0 on error
int tim2tox_ffi_get_group_chat_id_from_storage(int64_t instance_id, const char* group_id, char* out_chat_id, int out_len);

// Get count of conferences restored from savedata (for Dart to discover and assign group_ids)
// instance_id: 0 = current instance
// Returns: count (>= 0), or -1 on error
int tim2tox_ffi_get_restored_conference_count(int64_t instance_id);

// Get list of conference numbers restored from savedata
// instance_id: 0 = current instance
// out_list: buffer to receive conference numbers (uint32_t each)
// max_count: maximum number of entries to write
// Returns: number of entries written (0..max_count), or -1 on error
int tim2tox_ffi_get_restored_conference_list(int64_t instance_id, uint32_t* out_list, int max_count);

// Rejoin all known groups using stored chat_id (c-toxcore recommended approach)
// This should be called from Dart layer after init() completes and known groups are synced
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_rejoin_known_groups(void);

// Auto-accept group invites setting
// Set auto-accept group invites setting (called from Dart when setting changes)
// enabled: 1 to enable auto-accept, 0 to disable
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_set_auto_accept_group_invites(int64_t instance_id, int enabled);

// Get auto-accept group invites setting (called from C++ before accepting invites)
// Returns: 1 if enabled, 0 if disabled
int tim2tox_ffi_get_auto_accept_group_invites(int64_t instance_id);

// File transfer (peer to peer): send a file to a friend
int tim2tox_ffi_send_file(int64_t instance_id, const char* user_id, const char* file_path);

// File transfer control: control a file transfer
// user_id: friend's user ID (hex string)
// file_number: file number from file request event
// control: 0=RESUME (accept/continue), 1=PAUSE, 2=CANCEL (reject/abort)
// Returns: 1 on success, negative on error (-1=invalid args, -2=friend not found, -3=file not found, -4=control failed)
int tim2tox_ffi_file_control(int64_t instance_id, const char* user_id, uint32_t file_number, int control);

// Get self connection status: returns 0=NONE, 1=TCP, 2=UDP
int tim2tox_ffi_get_self_connection_status(void);

// Get UDP port this Tox instance is bound to
// Returns port number on success, 0 on failure
int tim2tox_ffi_get_udp_port(int64_t instance_id);

// Get DHT ID (public key) of this Tox instance
// out_dht_id: output buffer for DHT ID (hex string, 64 characters)
// out_len: size of output buffer (should be at least 65 for null terminator)
// Returns: length of DHT ID string on success, 0 on error
int tim2tox_ffi_get_dht_id(char* out_dht_id, int out_len);

// Add bootstrap node and re-login: host, port, public_key_hex (64-char string)
// Returns 1 on success, 0 on failure
int tim2tox_ffi_add_bootstrap_node(int64_t instance_id, const char* host, int port, const char* public_key_hex);

// Callback-based notification (called from background native thread):
// event_type: 0=text, 1=custom
// sender: null-terminated UTF-8
// payload: UTF-8 bytes for text (without terminator), raw bytes for custom
// payload_len: number of bytes in payload
typedef void (*tim2tox_event_cb)(int event_type, const char* sender, const unsigned char* payload, int payload_len, void* user_data);

// Register callback; pass NULL to disable. user_data will be forwarded when invoking cb.
void tim2tox_ffi_set_callback(tim2tox_event_cb cb, void* user_data);

// IRC Channel Management
// Connect to IRC server and join a channel
// server: IRC server address (e.g., "irc.libera.chat")
// port: IRC server port (default 6667)
// channel: channel name (e.g., "#libera")
// password: channel password (optional, can be NULL or empty)
// group_id: corresponding Tox group ID
// sasl_username: SASL authentication username (optional, can be NULL)
// sasl_password: SASL authentication password (optional, can be NULL)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_irc_connect_channel(const char* server, int port, const char* channel, const char* password, const char* group_id, const char* sasl_username, const char* sasl_password, int use_ssl, const char* custom_nickname);

// Disconnect from an IRC channel
// channel: channel name
// Returns: 1 on success, 0 if channel not found
int tim2tox_ffi_irc_disconnect_channel(const char* channel);

// Send a message to an IRC channel
// channel: channel name
// message: message content
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_irc_send_message(const char* channel, const char* message);

// Check if an IRC channel is connected
// channel: channel name
// Returns: 1 if connected, 0 otherwise
int tim2tox_ffi_irc_is_connected(const char* channel);

// Load IRC client dynamic library
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_irc_load_library(const char* library_path);

// Unload IRC client dynamic library
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_irc_unload_library(void);

// Check if IRC library is loaded
// Returns: 1 if loaded, 0 otherwise
int tim2tox_ffi_irc_is_library_loaded(void);

// Forward Tox group message to IRC (called from V2TIMManagerImpl)
// group_id: Tox group ID
// sender: sender nickname
// message: message content
// Returns: 1 if forwarded, 0 if not an IRC channel or library not loaded
int tim2tox_ffi_irc_forward_tox_message(const char* group_id, const char* sender, const char* message);

// Connection status enumeration
typedef enum {
    TIM2TOX_IRC_CONNECTION_DISCONNECTED = 0,
    TIM2TOX_IRC_CONNECTION_CONNECTING = 1,
    TIM2TOX_IRC_CONNECTION_CONNECTED = 2,
    TIM2TOX_IRC_CONNECTION_AUTHENTICATING = 3,
    TIM2TOX_IRC_CONNECTION_RECONNECTING = 4,
    TIM2TOX_IRC_CONNECTION_ERROR = 5
} tim2tox_irc_connection_status_t;

// Connection status callback
// channel: channel name
// status: connection status
// message: status message (optional, can be NULL)
// user_data: user data passed to callback
typedef void (*tim2tox_irc_connection_status_callback_t)(const char* channel, tim2tox_irc_connection_status_t status, const char* message, void* user_data);

// Register connection status callback
// callback: callback function (can be NULL to disable)
// user_data: user data passed to callback
void tim2tox_ffi_irc_set_connection_status_callback(tim2tox_irc_connection_status_callback_t callback, void* user_data);

// User list callback
// channel: channel name
// users: comma-separated list of user nicknames (can be NULL if empty)
// user_data: user data passed to callback
typedef void (*tim2tox_irc_user_list_callback_t)(const char* channel, const char* users, void* user_data);

// Register user list callback
// callback: callback function (can be NULL to disable)
// user_data: user data passed to callback
void tim2tox_ffi_irc_set_user_list_callback(tim2tox_irc_user_list_callback_t callback, void* user_data);

// User join/part callback
// channel: channel name
// nickname: user nickname
// joined: 1 if joined, 0 if parted
// user_data: user data passed to callback
typedef void (*tim2tox_irc_user_join_part_callback_t)(const char* channel, const char* nickname, int joined, void* user_data);

// Register user join/part callback
// callback: callback function (can be NULL to disable)
// user_data: user data passed to callback
void tim2tox_ffi_irc_set_user_join_part_callback(tim2tox_irc_user_join_part_callback_t callback, void* user_data);

// ============================================================================
// Signaling (Call Invitation) APIs
// ============================================================================

// Signaling callback types
typedef void (*tim2tox_signaling_invitation_callback_t)(const char* invite_id, const char* inviter, const char* group_id, const char* data, void* user_data);
typedef void (*tim2tox_signaling_cancel_callback_t)(const char* invite_id, const char* inviter, const char* data, void* user_data);
typedef void (*tim2tox_signaling_accept_callback_t)(const char* invite_id, const char* invitee, const char* data, void* user_data);
typedef void (*tim2tox_signaling_reject_callback_t)(const char* invite_id, const char* invitee, const char* data, void* user_data);
typedef void (*tim2tox_signaling_timeout_callback_t)(const char* invite_id, const char* inviter, void* user_data);

// Add signaling listener (callbacks)
// Returns 1 on success, 0 on failure
int tim2tox_ffi_signaling_add_listener(
    tim2tox_signaling_invitation_callback_t on_invitation,
    tim2tox_signaling_cancel_callback_t on_cancel,
    tim2tox_signaling_accept_callback_t on_accept,
    tim2tox_signaling_reject_callback_t on_reject,
    tim2tox_signaling_timeout_callback_t on_timeout,
    void* user_data
);

// Remove signaling listener
void tim2tox_ffi_signaling_remove_listener(void);

// Invite a user (1-on-1 call)
// invitee: user ID of the person to invite
// data: custom data (JSON string, can be NULL)
// online_user_only: 1 if only online users should receive, 0 otherwise
// timeout: timeout in seconds (0 = no timeout)
// Returns: invite ID on success (written to out_invite_id), empty string on failure
// out_invite_id: buffer to write invite ID (should be at least 64 bytes)
// out_invite_id_len: size of out_invite_id buffer
int tim2tox_ffi_signaling_invite(const char* invitee, const char* data, int online_user_only, int timeout, char* out_invite_id, int out_invite_id_len);

// Invite users in a group
// group_id: group ID
// invitee_list: comma-separated list of user IDs
// data: custom data (JSON string, can be NULL)
// online_user_only: 1 if only online users should receive, 0 otherwise
// timeout: timeout in seconds (0 = no timeout)
// Returns: invite ID on success (written to out_invite_id), empty string on failure
int tim2tox_ffi_signaling_invite_in_group(const char* group_id, const char* invitee_list, const char* data, int online_user_only, int timeout, char* out_invite_id, int out_invite_id_len);

// Cancel an invitation
// invite_id: invite ID returned from invite
// data: custom data (JSON string, can be NULL)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_signaling_cancel(const char* invite_id, const char* data);

// Accept an invitation
// invite_id: invite ID from invitation callback
// data: custom data (JSON string, can be NULL)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_signaling_accept(const char* invite_id, const char* data);

// Reject an invitation
// invite_id: invite ID from invitation callback
// data: custom data (JSON string, can be NULL)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_signaling_reject(const char* invite_id, const char* data);

// ============================================================================
// Audio/Video (ToxAV) APIs
// ============================================================================

// Initialize ToxAV (must be called after SDK init and login)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_initialize(int64_t instance_id);

// Shutdown ToxAV
void tim2tox_ffi_av_shutdown(int64_t instance_id);

// Iterate ToxAV (must be called regularly in main loop)
void tim2tox_ffi_av_iterate(int64_t instance_id);

// Start a call
// friend_number: Tox friend number (use tim2tox_ffi_get_friend_number_by_user_id to convert)
// audio_bit_rate: audio bit rate (0 = disable audio, recommended: 64000)
// video_bit_rate: video bit rate (0 = disable video, recommended: 5000000)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_start_call(int64_t instance_id, uint32_t friend_number, uint32_t audio_bit_rate, uint32_t video_bit_rate);

// Answer an incoming call
// friend_number: Tox friend number
// audio_bit_rate: audio bit rate (0 = disable audio, recommended: 64000)
// video_bit_rate: video bit rate (0 = disable video, recommended: 5000000)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_answer_call(int64_t instance_id, uint32_t friend_number, uint32_t audio_bit_rate, uint32_t video_bit_rate);

// End a call
// friend_number: Tox friend number
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_end_call(int64_t instance_id, uint32_t friend_number);

// Mute/unmute audio
// friend_number: Tox friend number
// mute: 1 to mute, 0 to unmute
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_mute_audio(int64_t instance_id, uint32_t friend_number, int mute);

// Hide/show video
// friend_number: Tox friend number
// hide: 1 to hide, 0 to show
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_mute_video(int64_t instance_id, uint32_t friend_number, int hide);

// Send audio frame
// friend_number: Tox friend number
// pcm: PCM audio data (int16_t samples)
// sample_count: number of samples
// channels: number of channels (1 = mono, 2 = stereo)
// sampling_rate: sampling rate in Hz (e.g., 48000)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_send_audio_frame(int64_t instance_id, uint32_t friend_number, const int16_t* pcm, size_t sample_count, uint8_t channels, uint32_t sampling_rate);

// Send video frame (YUV420 format)
// friend_number: Tox friend number
// width: frame width
// height: frame height
// y: Y plane data
// u: U plane data
// v: V plane data
// y_stride: Y plane stride
// u_stride: U plane stride
// v_stride: V plane stride
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_send_video_frame(int64_t instance_id, uint32_t friend_number, uint16_t width, uint16_t height,
                                     const uint8_t* y, const uint8_t* u, const uint8_t* v,
                                     int32_t y_stride, int32_t u_stride, int32_t v_stride);

// Set audio bit rate
// friend_number: Tox friend number
// audio_bit_rate: audio bit rate in kbit/sec (0 = disable)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_set_audio_bit_rate(int64_t instance_id, uint32_t friend_number, uint32_t audio_bit_rate);

// Set video bit rate
// friend_number: Tox friend number
// video_bit_rate: video bit rate in kbit/sec (0 = disable)
// Returns: 1 on success, 0 on failure
int tim2tox_ffi_av_set_video_bit_rate(int64_t instance_id, uint32_t friend_number, uint32_t video_bit_rate);

// AV callback types
typedef void (*tim2tox_av_call_callback_t)(uint32_t friend_number, int audio_enabled, int video_enabled, void* user_data);
typedef void (*tim2tox_av_call_state_callback_t)(uint32_t friend_number, uint32_t state, void* user_data);
typedef void (*tim2tox_av_audio_receive_callback_t)(uint32_t friend_number, const int16_t* pcm, size_t sample_count, uint8_t channels, uint32_t sampling_rate, void* user_data);
typedef void (*tim2tox_av_video_receive_callback_t)(uint32_t friend_number, uint16_t width, uint16_t height, const uint8_t* y, const uint8_t* u, const uint8_t* v, void* user_data);
// Bitrate-change suggestions delivered by c-toxcore (toxav_audio_bit_rate_cb /
// toxav_video_bit_rate_cb). bit_rate is in kbit/sec; 0 means the corresponding
// media has been disabled (audio or video off).
typedef void (*tim2tox_av_audio_bitrate_callback_t)(uint32_t friend_number, uint32_t audio_bit_rate, void* user_data);
typedef void (*tim2tox_av_video_bitrate_callback_t)(uint32_t friend_number, uint32_t video_bit_rate, void* user_data);

// Set AV callbacks
// Pass NULL to disable a callback
void tim2tox_ffi_av_set_call_callback(int64_t instance_id, tim2tox_av_call_callback_t callback, void* user_data);
void tim2tox_ffi_av_set_call_state_callback(int64_t instance_id, tim2tox_av_call_state_callback_t callback, void* user_data);
void tim2tox_ffi_av_set_audio_receive_callback(int64_t instance_id, tim2tox_av_audio_receive_callback_t callback, void* user_data);
void tim2tox_ffi_av_set_video_receive_callback(int64_t instance_id, tim2tox_av_video_receive_callback_t callback, void* user_data);
void tim2tox_ffi_av_set_audio_bitrate_callback(int64_t instance_id, tim2tox_av_audio_bitrate_callback_t callback, void* user_data);
void tim2tox_ffi_av_set_video_bitrate_callback(int64_t instance_id, tim2tox_av_video_bitrate_callback_t callback, void* user_data);

// Helper: Get friend number by user ID
// user_id: user ID (hex string)
// Returns: friend number on success, UINT32_MAX on failure
uint32_t tim2tox_ffi_get_friend_number_by_user_id(const char* user_id);

// Helper: Get user ID (public key hex string) by friend number
// friend_number: Tox friend number
// Returns: pointer to 64-char hex string on success, NULL on failure
// Note: returned pointer is valid until the next call from the same thread
const char* tim2tox_ffi_get_user_id_by_friend_number(uint32_t friend_number);

// ============================================================================
// DHT Nodes API
// ============================================================================

// Send DHT nodes request
// public_key: public key of the node to query (32 bytes, hex string)
// ip: IP address of the node to query (e.g., "127.0.0.1")
// port: UDP port of the node to query
// target_public_key: public key of the node we're looking for (32 bytes, hex string)
// Returns: 1 on success, 0 on failure
// Note: This function sends a request to the specified node asking for nodes close to target_public_key
int tim2tox_ffi_dht_send_nodes_request(const char* public_key, const char* ip, uint16_t port, const char* target_public_key);

// DHT nodes response callback type
// public_key: public key of the responding node (32 bytes, hex string)
// ip: IP address of the node (null-terminated string)
// port: UDP port of the node
// user_data: user data passed to callback
typedef void (*tim2tox_dht_nodes_response_callback_t)(const char* public_key, const char* ip, uint16_t port, void* user_data);

// Set DHT nodes response callback
// instance_id: instance ID (0 = use current instance)
// callback: callback function (can be NULL to disable)
// user_data: user data passed to callback
void tim2tox_ffi_set_dht_nodes_response_callback(int64_t instance_id, tim2tox_dht_nodes_response_callback_t callback, void* user_data);

// ============================================================================
// Tox Profile Encryption/Decryption APIs (for .tox file import/export)
// ============================================================================

// Check if data is encrypted (checks magic number in first TOX_PASS_ENCRYPTION_EXTRA_LENGTH bytes)
// data: data to check
// data_len: length of data (must be at least TOX_PASS_ENCRYPTION_EXTRA_LENGTH)
// Returns: 1 if encrypted, 0 if not encrypted, -1 on error
int tim2tox_ffi_is_data_encrypted(const uint8_t* data, size_t data_len);

// Encrypt data with passphrase
// plaintext: plaintext data to encrypt
// plaintext_len: length of plaintext data
// passphrase: encryption passphrase (can be NULL or empty for no encryption)
// passphrase_len: length of passphrase
// ciphertext: output buffer for encrypted data (must be at least plaintext_len + TOX_PASS_ENCRYPTION_EXTRA_LENGTH)
// ciphertext_capacity: capacity of ciphertext buffer
// Returns: encrypted data length on success, -1 on error
int tim2tox_ffi_pass_encrypt(
    const uint8_t* plaintext, size_t plaintext_len,
    const uint8_t* passphrase, size_t passphrase_len,
    uint8_t* ciphertext, size_t ciphertext_capacity
);

// Decrypt data with passphrase
// ciphertext: encrypted data to decrypt
// ciphertext_len: length of encrypted data
// passphrase: decryption passphrase (can be NULL or empty if not encrypted)
// passphrase_len: length of passphrase
// plaintext: output buffer for decrypted data (must be at least ciphertext_len - TOX_PASS_ENCRYPTION_EXTRA_LENGTH)
// plaintext_capacity: capacity of plaintext buffer
// Returns: decrypted data length on success, -1 on error
int tim2tox_ffi_pass_decrypt(
    const uint8_t* ciphertext, size_t ciphertext_len,
    const uint8_t* passphrase, size_t passphrase_len,
    uint8_t* plaintext, size_t plaintext_capacity
);

// Extract Tox ID (public key) from toxProfile data
// profile_data: toxProfile binary data (may be encrypted)
// profile_len: length of profile data
// passphrase: decryption passphrase if encrypted (can be NULL if not encrypted)
// passphrase_len: length of passphrase
// out_tox_id: output buffer for Tox ID (hex string, 64 characters)
// out_tox_id_len: capacity of out_tox_id buffer
// Returns: length of Tox ID string on success, -1 on error
int tim2tox_ffi_extract_tox_id_from_profile(
    const uint8_t* profile_data, size_t profile_len,
    const uint8_t* passphrase, size_t passphrase_len,
    char* out_tox_id, size_t out_tox_id_len
);

// Get the number of peers in a conference (for Dart to set memberCount)
// instance_id: 0 = current instance
// conference_number: the conference index
// Returns: peer count (>= 0), or -1 on error
int tim2tox_ffi_get_conference_peer_count(int64_t instance_id, uint32_t conference_number);

// Get the public keys (hex) of all peers in a conference
// instance_id: 0 = current instance
// conference_number: the conference index
// out_buf: buffer to receive comma-separated 64-char hex public keys
// buf_size: size of output buffer in bytes
// Returns: number of peers written, or -1 on error
int tim2tox_ffi_get_conference_peer_pubkeys(int64_t instance_id, uint32_t conference_number, char* out_buf, int buf_size);

// Test-only: Inject a raw JSON callback string directly into the Dart ReceivePort.
// This simulates native callbacks for testing the binary replacement path
// (NativeLibraryManager._handleNativeMessage → _handleNativeCallback → listener dispatch).
// json_callback: JSON string matching the expected format, e.g.:
//   {"callback":"globalCallback","callbackType":2,"instance_id":0,"status":0,"code":0,"desc":""}
// Returns: 1 on success (posted to Dart port), 0 on failure (port not registered, etc.)
int tim2tox_ffi_inject_callback(const char* json_callback);

#ifdef __cplusplus
}
#endif


