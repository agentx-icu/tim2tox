# Tim2Tox API 参考 — C FFI
> 语言 / Language: [中文](API_REFERENCE_FFI.md) | [English](API_REFERENCE_FFI.en.md)

本文档为 [API_REFERENCE.md](API_REFERENCE.md) 的 C FFI 部分，覆盖 `ffi/tim2tox_ffi.h` 中以 `tim2tox_ffi_` 前缀暴露的 C API（**Platform 路径**使用）。**Binary Replacement 路径**使用的 `Dart*` 兼容符号在 `ffi/dart_compat_layer.h` 与 `ffi/dart_compat_*.cpp` 中实现，是另一组接口（约 150+ 个 `extern "C"` 符号，与 Tencent Cloud SDK 的 `native_imsdk_bindings_generated.dart` 保持二进制兼容）—— 本文件不展开 `Dart*`，请直接查头文件或 `doc/architecture/FFI_COMPAT_LAYER.md`。

## 通用约定

- 头文件：`ffi/tim2tox_ffi.h`
- 调用约定：所有函数都是 `extern "C"`，无 C++ 类型穿透 ABI 边界。
- **返回值**：除非另行说明，函数返回 `int`，**`1 = 成功`，`0 = 失败`**；少数文件控制接口返回负值表示具体错误（`-1`/`-2`/`-3`/`-4`）。
- **缓冲区写入**：形如 `char* buffer, int buffer_len` 的接口，由调用方提供缓冲；返回写入字节数（含/不含 `\0` 视接口而定，详见头文件注释）。
- **多实例**：很多接口的首参是 `int64_t instance_id`。生产单例下使用 `0`（默认实例）；测试场景下使用 `tim2tox_ffi_create_test_instance*` 返回的句柄。详见 [doc/development/MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md)。
- **事件投递**：C++ 事件通过 `callback_bridge` 的 `SendCallbackToDart` 经 `SendPort` 投递到 Dart；轮询接口 (`poll_text`/`poll_custom`) 则用于显式从 C 侧拉取队列里的事件。

## 实例与生命周期

```c
int  tim2tox_ffi_init(void);
int  tim2tox_ffi_init_with_path(const char* init_path);
void tim2tox_ffi_uninit(void);
void tim2tox_ffi_set_log_file(const char* path);
int  tim2tox_ffi_set_file_recv_dir(const char* dir_path);
void tim2tox_ffi_save_tox_profile(void);
```

### 测试 / 多实例

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

> `set_virtual_time_ms` 与 `iterate_instance` 联合驱动 auto_tests 的虚拟时钟（见 `auto_tests/VIRTUAL_CLOCK.md`）；生产代码不需要使用。

## 登录与身份

```c
int  tim2tox_ffi_login(const char* user_id, const char* user_sig);
int  tim2tox_ffi_login_async(int64_t instance_id,
                             const char* user_id, const char* user_sig,
                             tim2tox_login_callback_t callback, void* user_data);
int  tim2tox_ffi_get_login_user(char* buffer, int buffer_len);
int  tim2tox_ffi_get_self_tox_id(char* buffer, int buffer_len);          // 76 字符十六进制
int  tim2tox_ffi_get_self_connection_status(void);                       // 0/1/2 = none/TCP/UDP
int  tim2tox_ffi_get_udp_port(int64_t instance_id);
int  tim2tox_ffi_get_dht_id(char* out_dht_id, int out_len);
int  tim2tox_ffi_set_self_info(const char* nickname, const char* status_message);
```

## 消息

```c
int tim2tox_ffi_send_c2c_text(const char* user_id, const char* text);
int tim2tox_ffi_send_c2c_custom(const char* user_id, const unsigned char* data, int data_len);
int tim2tox_ffi_send_group_text(const char* group_id, const char* text);
int tim2tox_ffi_send_group_custom(const char* group_id, const unsigned char* data, int data_len);

// 轮询：注意 poll_text 的首参是 int64_t instance_id
int tim2tox_ffi_poll_text(int64_t instance_id, char* buffer, int buffer_len);
int tim2tox_ffi_poll_custom(unsigned char* buffer, int buffer_len);

int tim2tox_ffi_set_typing(const char* user_id, int typing_on);
```

## 好友

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

## 群组

```c
int tim2tox_ffi_create_group(const char* group_name, const char* group_type,
                             char* out_group_id, int out_len);
int tim2tox_ffi_join_group(const char* group_id, const char* request_msg);
int tim2tox_ffi_rejoin_known_groups(void);

// 多实例：以下接口首参都是 int64_t instance_id（早期版本曾省略，现已要求）
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

// 旧 conference API 支持（兼容性留存）
int tim2tox_ffi_get_restored_conference_count(int64_t instance_id);
int tim2tox_ffi_get_restored_conference_list(int64_t instance_id, uint32_t* out_list, int max_count);
int tim2tox_ffi_get_conference_peer_count(int64_t instance_id, uint32_t conference_number);
```

> tim2tox 没有"通用"的 `set_group_info`：群类型（`"group"` vs `"conference"`）由 `create_group` 时决定，并持久化进存储；后续按 group_id 查询。`chat_id` 仅 `"group"` 类型可用。

## 文件传输

```c
int tim2tox_ffi_send_file(int64_t instance_id, const char* user_id, const char* file_path);
int tim2tox_ffi_file_control(int64_t instance_id, const char* user_id,
                             uint32_t file_number, int control);
```

> `file_control` 是少数返回**负值**的接口：`-1`/`-2`/`-3`/`-4` 对应不同错误，详见头文件注释。

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

## 信令

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

## IRC 通道桥接

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

## Profile 加解密

```c
int tim2tox_ffi_is_data_encrypted(const uint8_t* data, size_t data_len);
int tim2tox_ffi_pass_encrypt(/* 详见头文件 */);
int tim2tox_ffi_pass_decrypt(/* 详见头文件 */);
int tim2tox_ffi_extract_tox_id_from_profile(/* 详见头文件 */);
```

## 通用事件回调

```c
typedef void (*tim2tox_event_cb)(int event_type,
                                 const char* sender,
                                 const unsigned char* payload, int payload_len,
                                 void* user_data);

void tim2tox_ffi_set_callback(tim2tox_event_cb cb, void* user_data);
```

> 实际业务事件通常**不**通过这个 C 回调，而是经 `callback_bridge` 的 `Dart_PostCObject_DL` 投递到 Dart 的 `SendPort`（参见 [doc/architecture/ARCHITECTURE.md §7](../architecture/ARCHITECTURE.md)）。`tim2tox_ffi_set_callback` 主要用于不持有 Dart isolate 的纯 C 调用方。

## 相关文档

- [API_REFERENCE.md](API_REFERENCE.md) — 总索引、数据类型、错误码、示例
- [API_REFERENCE_V2TIM.md](API_REFERENCE_V2TIM.md) — V2TIM C++ 接口
- [API_REFERENCE_DART.md](API_REFERENCE_DART.md) — Dart 包 API
- [FFI_COMPAT_LAYER.md](../architecture/FFI_COMPAT_LAYER.md) — Binary Replacement 路径的 `Dart*` 兼容层（另一组 FFI）
- [MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md) — 多实例与 `int64_t instance_id`
