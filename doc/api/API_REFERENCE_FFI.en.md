# Tim2Tox API Reference — C FFI
> Language: [Chinese](API_REFERENCE_FFI.md) | [English](API_REFERENCE_FFI.en.md)

This document is the C FFI sub-volume of [API_REFERENCE.en.md](API_REFERENCE.en.md). It covers the C API exposed under the `tim2tox_ffi_` prefix in `ffi/tim2tox_ffi.h` (used by the **Platform path**). The **binary-replacement path** uses a separate set of `Dart*` compatibility symbols implemented in `ffi/dart_compat_layer.h` and `ffi/dart_compat_*.cpp` (~150 `extern "C"` symbols kept binary-compatible with the Tencent Cloud SDK's `native_imsdk_bindings_generated.dart`). This file does not enumerate them — see the headers or [doc/architecture/FFI_COMPAT_LAYER.en.md](../architecture/FFI_COMPAT_LAYER.en.md).

## Conventions

- Header: `ffi/tim2tox_ffi.h`
- Linkage: every function is `extern "C"`; no C++ type ever crosses the ABI boundary.
- **Return convention**: unless noted otherwise, functions return `int` with **`1 = success`, `0 = failure`**. A few file-control functions return negative error codes (`-1`/`-2`/`-3`/`-4`).
- **Buffer-write functions** (`char* buffer, int buffer_len`): caller-owned buffer; return value is the number of bytes written (inclusion of trailing NUL depends on the function — see header comments).
- **Multi-instance**: many functions take `int64_t instance_id` as the first parameter. Pass `0` for the default singleton in production; pass the handle returned by `tim2tox_ffi_create_test_instance*` in tests. See [doc/development/MULTI_INSTANCE_SUPPORT.en.md](../development/MULTI_INSTANCE_SUPPORT.en.md).
- **Event delivery**: C++ events are delivered to Dart through `callback_bridge`'s `SendCallbackToDart` (via a `SendPort`). The polling functions (`poll_text`/`poll_custom`) are an alternative path for pulling queued events from C.

## Lifecycle

```c
int  tim2tox_ffi_init(void);
int  tim2tox_ffi_init_with_path(const char* init_path);
void tim2tox_ffi_uninit(void);
void tim2tox_ffi_set_log_file(const char* path);
int  tim2tox_ffi_set_file_recv_dir(const char* dir_path);
void tim2tox_ffi_save_tox_profile(void);
```

### Test / multi-instance

```c
int64_t tim2tox_ffi_create_test_instance(const char* init_path);
int64_t tim2tox_ffi_create_test_instance_ex(const char* init_path,
                                            int local_discovery_enabled,
                                            int ipv6_enabled);
int     tim2tox_ffi_set_current_instance(int64_t instance_handle);
int64_t tim2tox_ffi_get_current_instance_id(void);
int     tim2tox_ffi_destroy_test_instance(int64_t instance_handle);

int     tim2tox_ffi_iterate_current_instance(int count);
int     tim2tox_ffi_iterate_all_instances(int count);
int     tim2tox_ffi_iterate_instance(int64_t instance_id);

int     tim2tox_ffi_set_test_mode(int64_t instance_id, int enabled);
int     tim2tox_ffi_set_default_test_mode(int enabled);
int     tim2tox_ffi_set_virtual_time_ms(uint64_t time_ms);
```

> `set_virtual_time_ms` together with `iterate_instance` drives the virtual clock used by `auto_tests/` (see `auto_tests/VIRTUAL_CLOCK.md`); production code does not need this.

## Login and identity

```c
int  tim2tox_ffi_login(const char* user_id, const char* user_sig);
int  tim2tox_ffi_login_async(int64_t instance_id,
                             const char* user_id, const char* user_sig,
                             tim2tox_login_callback_t callback, void* user_data);
int  tim2tox_ffi_get_login_user(char* buffer, int buffer_len);
int  tim2tox_ffi_get_self_tox_id(char* buffer, int buffer_len);          // 76-char hex
int  tim2tox_ffi_get_self_connection_status(void);                       // 0/1/2 = none/TCP/UDP
int  tim2tox_ffi_get_udp_port(int64_t instance_id);
int  tim2tox_ffi_get_dht_id(char* out_dht_id, int out_len);
int  tim2tox_ffi_set_self_info(const char* nickname, const char* status_message);
```

## Messaging

```c
int tim2tox_ffi_send_c2c_text(const char* user_id, const char* text);
int tim2tox_ffi_send_c2c_custom(const char* user_id, const unsigned char* data, int data_len);
int tim2tox_ffi_send_group_text(const char* group_id, const char* text);
int tim2tox_ffi_send_group_custom(const char* group_id, const unsigned char* data, int data_len);

// Polling: note poll_text takes int64_t instance_id as the first parameter
int tim2tox_ffi_poll_text(int64_t instance_id, char* buffer, int buffer_len);
int tim2tox_ffi_poll_custom(unsigned char* buffer, int buffer_len);

int tim2tox_ffi_set_typing(const char* user_id, int typing_on);
```

## Friends

```c
int tim2tox_ffi_add_friend(const char* user_id, const char* wording);
int tim2tox_ffi_get_friend_list(char* buffer, int buffer_len);
int tim2tox_ffi_get_friend_applications(char* buffer, int buffer_len);
int tim2tox_ffi_get_friend_applications_for_instance(int64_t instance_id,
                                                     char* buffer, int buffer_len);
int tim2tox_ffi_accept_friend(const char* user_id);
int tim2tox_ffi_delete_friend(const char* user_id);

int tim2tox_ffi_save_friend_nickname(const char* friend_id, const char* nickname);
int tim2tox_ffi_save_friend_status_message(const char* friend_id, const char* status_message);
```

## Groups

```c
int tim2tox_ffi_create_group(const char* group_name, const char* group_type,
                             char* out_group_id, int out_len);
int tim2tox_ffi_join_group(const char* group_id, const char* request_msg);
int tim2tox_ffi_rejoin_known_groups(void);

// Multi-instance: every function below takes int64_t instance_id as first parameter
// (earlier versions omitted it; current API requires it).
int tim2tox_ffi_update_known_groups(int64_t instance_id, const char* groups_str);
int tim2tox_ffi_get_known_groups(int64_t instance_id, char* buffer, int buffer_len);
int tim2tox_ffi_get_group_chat_id(int64_t instance_id, const char* group_id,
                                  char* out_chat_id, int out_len);
int tim2tox_ffi_set_group_chat_id(int64_t instance_id, const char* group_id,
                                  const char* chat_id);
int tim2tox_ffi_set_group_type(int64_t instance_id, const char* group_id,
                               const char* group_type);
int tim2tox_ffi_get_group_type_from_storage(int64_t instance_id, const char* group_id,
                                            char* out_group_type, int out_len);
int tim2tox_ffi_get_group_chat_id_from_storage(int64_t instance_id, const char* group_id,
                                               char* out_chat_id, int out_len);

int tim2tox_ffi_set_auto_accept_group_invites(int64_t instance_id, int enabled);
int tim2tox_ffi_get_auto_accept_group_invites(int64_t instance_id);

// Legacy conference API (compatibility only)
int tim2tox_ffi_get_restored_conference_count(int64_t instance_id);
int tim2tox_ffi_get_restored_conference_list(int64_t instance_id,
                                             uint32_t* out_list, int max_count);
int tim2tox_ffi_get_conference_peer_count(int64_t instance_id, uint32_t conference_number);
```

> There is no generic `set_group_info`. Group type (`"group"` vs `"conference"`) is decided at `create_group` time and written to storage; subsequent queries go by `group_id`. `chat_id` is only meaningful for the `"group"` type.

## File transfer

```c
int tim2tox_ffi_send_file(int64_t instance_id, const char* user_id, const char* file_path);
int tim2tox_ffi_file_control(int64_t instance_id, const char* user_id,
                             uint32_t file_number, int control);
```

> `file_control` is one of the few functions that returns **negative** error codes: `-1`/`-2`/`-3`/`-4`. See the header for the meanings.

## DHT / Bootstrap

```c
int  tim2tox_ffi_add_bootstrap_node(int64_t instance_id,
                                    const char* host, int port,
                                    const char* public_key_hex);
int  tim2tox_ffi_dht_send_nodes_request(const char* public_key, const char* ip,
                                        uint16_t port, const char* target_public_key);
void tim2tox_ffi_set_dht_nodes_response_callback(int64_t instance_id,
                                                 tim2tox_dht_nodes_response_callback_t callback,
                                                 void* user_data);
```

## Signaling

```c
int  tim2tox_ffi_signaling_add_listener(
    tim2tox_signaling_invitation_callback_t on_invitation,
    tim2tox_signaling_cancel_callback_t     on_cancel,
    tim2tox_signaling_accept_callback_t     on_accept,
    tim2tox_signaling_reject_callback_t     on_reject,
    tim2tox_signaling_timeout_callback_t    on_timeout,
    void* user_data);
void tim2tox_ffi_signaling_remove_listener(void);

int  tim2tox_ffi_signaling_invite(const char* invitee, const char* data,
                                  int online_user_only, int timeout,
                                  char* out_invite_id, int out_invite_id_len);
int  tim2tox_ffi_signaling_invite_in_group(const char* group_id,
                                           const char* invitee_list, const char* data,
                                           int online_user_only, int timeout,
                                           char* out_invite_id, int out_invite_id_len);

int  tim2tox_ffi_signaling_cancel(const char* invite_id, const char* data);
int  tim2tox_ffi_signaling_accept(const char* invite_id, const char* data);
int  tim2tox_ffi_signaling_reject(const char* invite_id, const char* data);
```

## ToxAV

```c
int  tim2tox_ffi_av_initialize(int64_t instance_id);
void tim2tox_ffi_av_shutdown(int64_t instance_id);
void tim2tox_ffi_av_iterate(int64_t instance_id);

int  tim2tox_ffi_av_start_call(int64_t instance_id, uint32_t friend_number,
                               uint32_t audio_bit_rate, uint32_t video_bit_rate);
int  tim2tox_ffi_av_answer_call(int64_t instance_id, uint32_t friend_number,
                                uint32_t audio_bit_rate, uint32_t video_bit_rate);
int  tim2tox_ffi_av_end_call(int64_t instance_id, uint32_t friend_number);

int  tim2tox_ffi_av_mute_audio(int64_t instance_id, uint32_t friend_number, int mute);
int  tim2tox_ffi_av_mute_video(int64_t instance_id, uint32_t friend_number, int hide);

int  tim2tox_ffi_av_send_audio_frame(int64_t instance_id, uint32_t friend_number,
                                     const int16_t* pcm, size_t sample_count,
                                     uint8_t channels, uint32_t sampling_rate);
int  tim2tox_ffi_av_send_video_frame(int64_t instance_id, uint32_t friend_number,
                                     uint16_t width, uint16_t height,
                                     const uint8_t* y, const uint8_t* u, const uint8_t* v,
                                     int32_t y_stride, int32_t u_stride, int32_t v_stride);

int  tim2tox_ffi_av_set_audio_bit_rate(int64_t instance_id, uint32_t friend_number,
                                       uint32_t audio_bit_rate);
int  tim2tox_ffi_av_set_video_bit_rate(int64_t instance_id, uint32_t friend_number,
                                       uint32_t video_bit_rate);

void tim2tox_ffi_av_set_call_callback(int64_t instance_id,
                                      tim2tox_av_call_callback_t callback, void* user_data);
void tim2tox_ffi_av_set_call_state_callback(int64_t instance_id,
                                            tim2tox_av_call_state_callback_t callback, void* user_data);
void tim2tox_ffi_av_set_audio_receive_callback(int64_t instance_id,
                                               tim2tox_av_audio_receive_callback_t callback, void* user_data);
void tim2tox_ffi_av_set_video_receive_callback(int64_t instance_id,
                                               tim2tox_av_video_receive_callback_t callback, void* user_data);

uint32_t tim2tox_ffi_get_friend_number_by_user_id(const char* user_id);
```

## IRC channel bridge

```c
int  tim2tox_ffi_irc_load_library(const char* library_path);
int  tim2tox_ffi_irc_unload_library(void);
int  tim2tox_ffi_irc_is_library_loaded(void);

int  tim2tox_ffi_irc_connect_channel(const char* server, int port,
                                     const char* channel, const char* password,
                                     const char* group_id,
                                     const char* sasl_username, const char* sasl_password,
                                     int use_ssl, const char* custom_nickname);
int  tim2tox_ffi_irc_disconnect_channel(const char* channel);
int  tim2tox_ffi_irc_send_message(const char* channel, const char* message);
int  tim2tox_ffi_irc_is_connected(const char* channel);
int  tim2tox_ffi_irc_forward_tox_message(const char* group_id, const char* sender, const char* message);

void tim2tox_ffi_irc_set_connection_status_callback(
    tim2tox_irc_connection_status_callback_t callback, void* user_data);
void tim2tox_ffi_irc_set_user_list_callback(
    tim2tox_irc_user_list_callback_t callback, void* user_data);
void tim2tox_ffi_irc_set_user_join_part_callback(
    tim2tox_irc_user_join_part_callback_t callback, void* user_data);
```

## Profile encryption

```c
int tim2tox_ffi_is_data_encrypted(const uint8_t* data, size_t data_len);
int tim2tox_ffi_pass_encrypt(/* see header */);
int tim2tox_ffi_pass_decrypt(/* see header */);
int tim2tox_ffi_extract_tox_id_from_profile(/* see header */);
```

## Generic event callback

```c
typedef void (*tim2tox_event_cb)(int event_type,
                                 const char* sender,
                                 const unsigned char* payload, int payload_len,
                                 void* user_data);

void tim2tox_ffi_set_callback(tim2tox_event_cb cb, void* user_data);
```

> Most production events do **not** go through this C callback — they are delivered via `callback_bridge`'s `Dart_PostCObject_DL` to a Dart `SendPort` (see [doc/architecture/ARCHITECTURE.en.md §7](../architecture/ARCHITECTURE.en.md)). `tim2tox_ffi_set_callback` is for pure-C callers that don't own a Dart isolate.

## Related documents

- [API_REFERENCE.en.md](API_REFERENCE.en.md) — index, data types, error codes, examples
- [API_REFERENCE_V2TIM.en.md](API_REFERENCE_V2TIM.en.md) — V2TIM C++ interface
- [API_REFERENCE_DART.en.md](API_REFERENCE_DART.en.md) — Dart package API
- [FFI_COMPAT_LAYER.en.md](../architecture/FFI_COMPAT_LAYER.en.md) — Binary-replacement `Dart*` compat layer (the other FFI surface)
- [MULTI_INSTANCE_SUPPORT.en.md](../development/MULTI_INSTANCE_SUPPORT.en.md) — multi-instance and `int64_t instance_id`
