/// Tim2Tox FFI Bindings
/// 
/// This file provides Dart FFI bindings to the tim2tox C library.
/// It directly maps to the C functions defined in tim2tox_ffi.h.

import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart' as pkgffi;

// FFI function type definitions
typedef _init_c = ffi.Int32 Function();
typedef _init_with_path_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _set_file_recv_dir_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _set_log_file_c = ffi.Void Function(ffi.Pointer<pkgffi.Utf8>);
typedef _login_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
// R-08: Async login callback (success, error_code, error_message, user_data); error_message valid only during callback.
typedef _login_callback_native = ffi.Void Function(ffi.Int32 success, ffi.Int32 error_code, ffi.Pointer<pkgffi.Utf8> error_message, ffi.Pointer<ffi.Void> user_data);
typedef _login_async_c = ffi.Int32 Function(ffi.Int64 instance_id, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.NativeFunction<_login_callback_native>>, ffi.Pointer<ffi.Void>);
typedef _add_friend_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _send_text_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _poll_text_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _poll_custom_c = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _get_login_user_c = ffi.Int32 Function(ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _uninit_c = ffi.Void Function();
typedef _save_tox_profile_c = ffi.Void Function();
typedef _get_friend_list_c = ffi.Int32 Function(ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _set_self_info_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _get_friend_apps_c = ffi.Int32 Function(ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _get_friend_apps_for_instance_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _accept_friend_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _delete_friend_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _set_callback_c = ffi.Void Function(ffi.Pointer<ffi.NativeFunction<_event_cb_native>>, ffi.Pointer<ffi.Void>);
typedef _event_cb_native = ffi.Void Function(
  ffi.Int32, // event_type
  ffi.Pointer<pkgffi.Utf8>, // sender
  ffi.Pointer<ffi.Uint8>, // payload
  ffi.Int32, // payload_len
  ffi.Pointer<ffi.Void> // user
);
typedef _set_typing_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Int32);
typedef _create_group_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _join_group_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _send_group_text_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _update_known_groups_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<pkgffi.Utf8>);
typedef _get_known_groups_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _get_group_chat_id_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _set_group_chat_id_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _get_group_chat_id_from_storage_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _rejoin_known_groups_c = ffi.Int32 Function();
typedef _get_restored_conference_count_c = ffi.Int32 Function(ffi.Int64);
typedef _get_restored_conference_list_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Uint32>, ffi.Int32);
typedef _get_conference_peer_count_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32);
typedef _get_conference_peer_pubkeys_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _set_group_type_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _set_auto_accept_group_invites_c = ffi.Int32 Function(ffi.Int64, ffi.Int32);
typedef _get_auto_accept_group_invites_c = ffi.Int32 Function(ffi.Int64);
typedef _send_c2c_custom_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _send_group_custom_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _send_file_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _file_control_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<pkgffi.Utf8>, ffi.Uint32, ffi.Int32);
typedef _get_self_connection_status_c = ffi.Int32 Function();
typedef _get_udp_port_c = ffi.Int32 Function(ffi.Int64);
typedef _get_dht_id_c = ffi.Int32 Function(ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _add_bootstrap_node_c = ffi.Int32 Function(ffi.Int64, ffi.Pointer<pkgffi.Utf8>, ffi.Int32, ffi.Pointer<pkgffi.Utf8>);
// Test instance management functions
typedef _create_test_instance_c = ffi.Int64 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _create_test_instance_ex_c = ffi.Int64 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Int32, ffi.Int32);
typedef _set_current_instance_c = ffi.Int32 Function(ffi.Int64);
typedef _destroy_test_instance_c = ffi.Int32 Function(ffi.Int64);
typedef _get_current_instance_id_c = ffi.Int64 Function();
typedef _iterate_current_instance_c = ffi.Int32 Function(ffi.Int32);
typedef _iterate_all_instances_c = ffi.Int32 Function(ffi.Int32);
// DHT nodes API
typedef _dht_send_nodes_request_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Uint16, ffi.Pointer<pkgffi.Utf8>);
typedef _dht_nodes_response_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // public_key (hex string)
  ffi.Pointer<pkgffi.Utf8>, // ip
  ffi.Uint16, // port
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _set_dht_nodes_response_callback_c = ffi.Void Function(
  ffi.Int64,
  ffi.Pointer<ffi.NativeFunction<_dht_nodes_response_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _irc_connect_channel_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Int32, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Int32, ffi.Pointer<pkgffi.Utf8>);
typedef _irc_disconnect_channel_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _irc_send_message_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _irc_is_connected_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _irc_load_library_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _irc_unload_library_c = ffi.Int32 Function();
typedef _irc_is_library_loaded_c = ffi.Int32 Function();

// IRC callback types
typedef _irc_connection_status_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // channel
  ffi.Int32, // status
  ffi.Pointer<pkgffi.Utf8>, // message
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _irc_user_list_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // channel
  ffi.Pointer<pkgffi.Utf8>, // users (comma-separated)
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _irc_user_join_part_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // channel
  ffi.Pointer<pkgffi.Utf8>, // nickname
  ffi.Int32, // joined (1 if joined, 0 if parted)
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _irc_set_connection_status_callback_c = ffi.Void Function(
  ffi.Pointer<ffi.NativeFunction<_irc_connection_status_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _irc_set_user_list_callback_c = ffi.Void Function(
  ffi.Pointer<ffi.NativeFunction<_irc_user_list_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _irc_set_user_join_part_callback_c = ffi.Void Function(
  ffi.Pointer<ffi.NativeFunction<_irc_user_join_part_callback_native>>,
  ffi.Pointer<ffi.Void>,
);

// Signaling callback types
typedef _signaling_invitation_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // invite_id
  ffi.Pointer<pkgffi.Utf8>, // inviter
  ffi.Pointer<pkgffi.Utf8>, // group_id
  ffi.Pointer<pkgffi.Utf8>, // data
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _signaling_cancel_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // invite_id
  ffi.Pointer<pkgffi.Utf8>, // inviter
  ffi.Pointer<pkgffi.Utf8>, // data
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _signaling_accept_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // invite_id
  ffi.Pointer<pkgffi.Utf8>, // invitee
  ffi.Pointer<pkgffi.Utf8>, // data
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _signaling_reject_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // invite_id
  ffi.Pointer<pkgffi.Utf8>, // invitee
  ffi.Pointer<pkgffi.Utf8>, // data
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _signaling_timeout_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // invite_id
  ffi.Pointer<pkgffi.Utf8>, // inviter
  ffi.Pointer<ffi.Void>, // user_data
);

typedef _signaling_add_listener_c = ffi.Int32 Function(
  ffi.Pointer<ffi.NativeFunction<_signaling_invitation_callback_native>>,
  ffi.Pointer<ffi.NativeFunction<_signaling_cancel_callback_native>>,
  ffi.Pointer<ffi.NativeFunction<_signaling_accept_callback_native>>,
  ffi.Pointer<ffi.NativeFunction<_signaling_reject_callback_native>>,
  ffi.Pointer<ffi.NativeFunction<_signaling_timeout_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _signaling_invite_c = ffi.Int32 Function(
  ffi.Pointer<pkgffi.Utf8>, // invitee
  ffi.Pointer<pkgffi.Utf8>, // data
  ffi.Int32, // online_user_only
  ffi.Int32, // timeout
  ffi.Pointer<ffi.Int8>, // out_invite_id
  ffi.Int32, // out_invite_id_len
);
typedef _signaling_invite_in_group_c = ffi.Int32 Function(
  ffi.Pointer<pkgffi.Utf8>, // group_id
  ffi.Pointer<pkgffi.Utf8>, // invitee_list
  ffi.Pointer<pkgffi.Utf8>, // data
  ffi.Int32, // online_user_only
  ffi.Int32, // timeout
  ffi.Pointer<ffi.Int8>, // out_invite_id
  ffi.Int32, // out_invite_id_len
);
typedef _signaling_cancel_c = ffi.Int32 Function(
  ffi.Pointer<pkgffi.Utf8>, // invite_id
  ffi.Pointer<pkgffi.Utf8>, // data
);
typedef _signaling_accept_c = ffi.Int32 Function(
  ffi.Pointer<pkgffi.Utf8>, // invite_id
  ffi.Pointer<pkgffi.Utf8>, // data
);
typedef _signaling_reject_c = ffi.Int32 Function(
  ffi.Pointer<pkgffi.Utf8>, // invite_id
  ffi.Pointer<pkgffi.Utf8>, // data
);
typedef _signaling_remove_listener_c = ffi.Void Function();

// Dart-compat per-instance signaling callback setter (C/Dart)
typedef _dart_set_signaling_cb_c = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _dart_set_signaling_cb_d = void Function(ffi.Pointer<ffi.Void>);

// Audio/Video (ToxAV) types (instance_id first; 0 = use current)
typedef _av_initialize_c = ffi.Int32 Function(ffi.Int64);
typedef _av_shutdown_c = ffi.Void Function(ffi.Int64);
typedef _av_iterate_c = ffi.Void Function(ffi.Int64);
typedef _av_start_call_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef _av_answer_call_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef _av_end_call_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32);
typedef _av_mute_audio_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Int32);
typedef _av_mute_video_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Int32);
typedef _av_send_audio_frame_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Pointer<ffi.Int16>, ffi.Size, ffi.Uint8, ffi.Uint32);
typedef _av_send_video_frame_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Uint16, ffi.Uint16, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Int32, ffi.Int32, ffi.Int32);
typedef _av_set_audio_bit_rate_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Uint32);
typedef _av_set_video_bit_rate_c = ffi.Int32 Function(ffi.Int64, ffi.Uint32, ffi.Uint32);
typedef _av_call_callback_native = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Int32, // audio_enabled
  ffi.Int32, // video_enabled
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _av_call_state_callback_native = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Uint32, // state
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _av_audio_receive_callback_native = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Pointer<ffi.Int16>, // pcm
  ffi.Size, // sample_count
  ffi.Uint8, // channels
  ffi.Uint32, // sampling_rate
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _av_video_receive_callback_native = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Uint16, // width
  ffi.Uint16, // height
  ffi.Pointer<ffi.Uint8>, // y
  ffi.Pointer<ffi.Uint8>, // u
  ffi.Pointer<ffi.Uint8>, // v
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _av_set_call_callback_c = ffi.Void Function(
  ffi.Int64,
  ffi.Pointer<ffi.NativeFunction<_av_call_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _av_set_call_state_callback_c = ffi.Void Function(
  ffi.Int64,
  ffi.Pointer<ffi.NativeFunction<_av_call_state_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _av_set_audio_receive_callback_c = ffi.Void Function(
  ffi.Int64,
  ffi.Pointer<ffi.NativeFunction<_av_audio_receive_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _av_set_video_receive_callback_c = ffi.Void Function(
  ffi.Int64,
  ffi.Pointer<ffi.NativeFunction<_av_video_receive_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _av_audio_bitrate_callback_native = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Uint32, // audio_bit_rate
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _av_video_bitrate_callback_native = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Uint32, // video_bit_rate
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _av_set_audio_bitrate_callback_c = ffi.Void Function(
  ffi.Int64,
  ffi.Pointer<ffi.NativeFunction<_av_audio_bitrate_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _av_set_video_bitrate_callback_c = ffi.Void Function(
  ffi.Int64,
  ffi.Pointer<ffi.NativeFunction<_av_video_bitrate_callback_native>>,
  ffi.Pointer<ffi.Void>,
);
typedef _get_friend_number_by_user_id_c = ffi.Uint32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _get_user_id_by_friend_number_c = ffi.Pointer<pkgffi.Utf8> Function(ffi.Uint32);

// Tox encryption/decryption function types
typedef _is_data_encrypted_c = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _pass_encrypt_c = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>, ffi.Size, // plaintext, plaintext_len
  ffi.Pointer<ffi.Uint8>, ffi.Size, // passphrase, passphrase_len
  ffi.Pointer<ffi.Uint8>, ffi.Size, // ciphertext, ciphertext_capacity
);
typedef _pass_decrypt_c = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>, ffi.Size, // ciphertext, ciphertext_len
  ffi.Pointer<ffi.Uint8>, ffi.Size, // passphrase, passphrase_len
  ffi.Pointer<ffi.Uint8>, ffi.Size, // plaintext, plaintext_capacity
);
typedef _extract_tox_id_from_profile_c = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>, ffi.Size, // profile_data, profile_len
  ffi.Pointer<ffi.Uint8>, ffi.Size, // passphrase, passphrase_len
  ffi.Pointer<ffi.Int8>, ffi.Size, // out_tox_id, out_tox_id_len
);
// Test-only: inject a raw JSON callback string into the Dart ReceivePort
typedef _inject_callback_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);

// ============================================================================
// Test-only: virtual clock + manual iteration FFI bindings.
// These map to tim2tox_ffi_set_test_mode / tim2tox_ffi_set_virtual_time_ms /
// tim2tox_ffi_iterate_instance. The C side suspends per-instance event_thread
// pumping when test mode is enabled, so the Dart harness can drive iteration
// against a shared virtual clock instead of wall time.
// ============================================================================
typedef _set_test_mode_c = ffi.Int32 Function(ffi.Int64, ffi.Int32);
typedef _set_virtual_time_ms_c = ffi.Int32 Function(ffi.Uint64);
typedef _iterate_instance_c = ffi.Int32 Function(ffi.Int64);
typedef _set_default_test_mode_c = ffi.Int32 Function(ffi.Int32);

/// Low-level FFI bindings to tim2tox C library
class Tim2ToxFfi {
  Tim2ToxFfi._(this._lib);
  final ffi.DynamicLibrary _lib;
  
  late final int Function() init = _lib.lookupFunction<_init_c, int Function()>('tim2tox_ffi_init');
  late final int Function(ffi.Pointer<pkgffi.Utf8>) initWithPath =
      _lib.lookupFunction<_init_with_path_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_init_with_path');
  late final int Function(ffi.Pointer<pkgffi.Utf8>) setFileRecvDir = _lib.lookupFunction<_set_file_recv_dir_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_set_file_recv_dir');
  late final void Function(ffi.Pointer<pkgffi.Utf8>) setLogFileNative = _lib.lookupFunction<_set_log_file_c, void Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_set_log_file');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) login =
      _lib.lookupFunction<_login_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_login');
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.NativeFunction<_login_callback_native>>, ffi.Pointer<ffi.Void>) loginAsync =
      _lib.lookupFunction<_login_async_c, int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.NativeFunction<_login_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_login_async');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) addFriend =
      _lib.lookupFunction<_add_friend_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_add_friend');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) sendText =
      _lib.lookupFunction<_send_text_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_send_c2c_text');
  late final int Function(int, ffi.Pointer<ffi.Int8>, int) pollText =
      _lib.lookupFunction<_poll_text_c, int Function(int, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_poll_text');
  late final int Function(ffi.Pointer<ffi.Uint8>, int) pollCustom =
      _lib.lookupFunction<_poll_custom_c, int Function(ffi.Pointer<ffi.Uint8>, int)>('tim2tox_ffi_poll_custom');
  late final int Function(ffi.Pointer<ffi.Int8>, int) getLoginUser =
      _lib.lookupFunction<_get_login_user_c, int Function(ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_login_user');
  /// Returns the 76-hex-char Tox address (self public key + nospam + checksum)
  /// for the current instance, or empty until the first DHT connection lands.
  /// Use this — not [getLoginUser] — when callers need the Tox identity.
  late final int Function(ffi.Pointer<ffi.Int8>, int) getSelfToxId =
      _lib.lookupFunction<_get_login_user_c, int Function(ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_self_tox_id');
  late final void Function() uninit = _lib.lookupFunction<_uninit_c, void Function()>('tim2tox_ffi_uninit');
  late final void Function() saveToxProfile = _lib.lookupFunction<_save_tox_profile_c, void Function()>('tim2tox_ffi_save_tox_profile');
  late final int Function(ffi.Pointer<ffi.Int8>, int) getFriendList =
      _lib.lookupFunction<_get_friend_list_c, int Function(ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_friend_list');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) setSelfInfo =
      _lib.lookupFunction<_set_self_info_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_set_self_info');
  late final int Function(ffi.Pointer<ffi.Int8>, int) getFriendApplications =
      _lib.lookupFunction<_get_friend_apps_c, int Function(ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_friend_applications');
  late final int Function(int, ffi.Pointer<ffi.Int8>, int) getFriendApplicationsForInstance =
      _lib.lookupFunction<_get_friend_apps_for_instance_c, int Function(int, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_friend_applications_for_instance');
  late final int Function(ffi.Pointer<pkgffi.Utf8>) acceptFriend =
      _lib.lookupFunction<_accept_friend_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_accept_friend');
  late final int Function(ffi.Pointer<pkgffi.Utf8>) deleteFriend =
      _lib.lookupFunction<_delete_friend_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_delete_friend');
  late final void Function(ffi.Pointer<ffi.NativeFunction<_event_cb_native>>, ffi.Pointer<ffi.Void>) setCallback =
      _lib.lookupFunction<_set_callback_c, void Function(ffi.Pointer<ffi.NativeFunction<_event_cb_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_set_callback');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, int) setTyping =
      _lib.lookupFunction<_set_typing_c, int Function(ffi.Pointer<pkgffi.Utf8>, int)>('tim2tox_ffi_set_typing');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, int) createGroup =
      _lib.lookupFunction<_create_group_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_create_group');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) joinGroup =
      _lib.lookupFunction<_join_group_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_join_group');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) sendGroupText =
      _lib.lookupFunction<_send_group_text_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_send_group_text');
  late final int Function(int, ffi.Pointer<ffi.Int8>, int) getKnownGroups =
      _lib.lookupFunction<_get_known_groups_c, int Function(int, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_known_groups');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, int) sendC2CCustomNative =
      _lib.lookupFunction<_send_c2c_custom_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, int)>('tim2tox_ffi_send_c2c_custom');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, int) sendGroupCustomNative =
      _lib.lookupFunction<_send_group_custom_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, int)>('tim2tox_ffi_send_group_custom');
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) sendFileNative =
      _lib.lookupFunction<_send_file_c, int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_send_file');
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>, int, int) fileControlNative =
      _lib.lookupFunction<_file_control_c, int Function(int, ffi.Pointer<pkgffi.Utf8>, int, int)>('tim2tox_ffi_file_control');
  late final int Function() getSelfConnectionStatus =
      _lib.lookupFunction<_get_self_connection_status_c, int Function()>('tim2tox_ffi_get_self_connection_status');
  late final int Function(int) getUdpPort =
      _lib.lookupFunction<_get_udp_port_c, int Function(int)>('tim2tox_ffi_get_udp_port');
  late final int Function(ffi.Pointer<ffi.Int8>, int) getDhtIdNative =
      _lib.lookupFunction<_get_dht_id_c, int Function(ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_dht_id');
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>, int, ffi.Pointer<pkgffi.Utf8>) addBootstrapNode =
      _lib.lookupFunction<_add_bootstrap_node_c, int Function(int, ffi.Pointer<pkgffi.Utf8>, int, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_add_bootstrap_node');
  // DHT nodes API
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, int, ffi.Pointer<pkgffi.Utf8>) dhtSendNodesRequestNative =
      _lib.lookupFunction<_dht_send_nodes_request_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, int, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_dht_send_nodes_request');
  late final void Function(int, ffi.Pointer<ffi.NativeFunction<_dht_nodes_response_callback_native>>, ffi.Pointer<ffi.Void>) setDhtNodesResponseCallbackNative =
      _lib.lookupFunction<_set_dht_nodes_response_callback_c, void Function(int, ffi.Pointer<ffi.NativeFunction<_dht_nodes_response_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_set_dht_nodes_response_callback');
  
  // Test instance management functions
  late final int Function(ffi.Pointer<pkgffi.Utf8>) createTestInstanceNative =
      _lib.lookupFunction<_create_test_instance_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_create_test_instance');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, int, int) createTestInstanceExNative =
      _lib.lookupFunction<_create_test_instance_ex_c, int Function(ffi.Pointer<pkgffi.Utf8>, int, int)>('tim2tox_ffi_create_test_instance_ex');
  late final int Function(int) setCurrentInstance =
      _lib.lookupFunction<_set_current_instance_c, int Function(int)>('tim2tox_ffi_set_current_instance');
  late final int Function(int) destroyTestInstance =
      _lib.lookupFunction<_destroy_test_instance_c, int Function(int)>('tim2tox_ffi_destroy_test_instance');
  late final int Function() getCurrentInstanceId =
      _lib.lookupFunction<_get_current_instance_id_c, int Function()>('tim2tox_ffi_get_current_instance_id');
  late final int Function(int) iterateCurrentInstance =
      _lib.lookupFunction<_iterate_current_instance_c, int Function(int)>('tim2tox_ffi_iterate_current_instance');
  late final int Function(int) iterateAllInstances =
      _lib.lookupFunction<_iterate_all_instances_c, int Function(int)>('tim2tox_ffi_iterate_all_instances');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, int, ffi.Pointer<pkgffi.Utf8>) ircConnectChannel =
      _lib.lookupFunction<_irc_connect_channel_c, int Function(ffi.Pointer<pkgffi.Utf8>, int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, int, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_irc_connect_channel');
  late final int Function(ffi.Pointer<pkgffi.Utf8>) ircDisconnectChannel =
      _lib.lookupFunction<_irc_disconnect_channel_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_irc_disconnect_channel');
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) ircSendMessage =
      _lib.lookupFunction<_irc_send_message_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_irc_send_message');
  late final int Function(ffi.Pointer<pkgffi.Utf8>) ircIsConnected =
      _lib.lookupFunction<_irc_is_connected_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_irc_is_connected');
  late final int Function(ffi.Pointer<pkgffi.Utf8>) ircLoadLibrary =
      _lib.lookupFunction<_irc_load_library_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_irc_load_library');
  late final int Function() ircUnloadLibrary =
      _lib.lookupFunction<_irc_unload_library_c, int Function()>('tim2tox_ffi_irc_unload_library');
  late final int Function() ircIsLibraryLoaded =
      _lib.lookupFunction<_irc_is_library_loaded_c, int Function()>('tim2tox_ffi_irc_is_library_loaded');
  late final void Function(ffi.Pointer<ffi.NativeFunction<_irc_connection_status_callback_native>>, ffi.Pointer<ffi.Void>) ircSetConnectionStatusCallback =
      _lib.lookupFunction<_irc_set_connection_status_callback_c, void Function(ffi.Pointer<ffi.NativeFunction<_irc_connection_status_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_irc_set_connection_status_callback');
  late final void Function(ffi.Pointer<ffi.NativeFunction<_irc_user_list_callback_native>>, ffi.Pointer<ffi.Void>) ircSetUserListCallback =
      _lib.lookupFunction<_irc_set_user_list_callback_c, void Function(ffi.Pointer<ffi.NativeFunction<_irc_user_list_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_irc_set_user_list_callback');
  late final void Function(ffi.Pointer<ffi.NativeFunction<_irc_user_join_part_callback_native>>, ffi.Pointer<ffi.Void>) ircSetUserJoinPartCallback =
      _lib.lookupFunction<_irc_set_user_join_part_callback_c, void Function(ffi.Pointer<ffi.NativeFunction<_irc_user_join_part_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_irc_set_user_join_part_callback');

  // ============================================================================
  // Signaling (Call Invitation) FFI Bindings
  // ============================================================================
  
  late final int Function(
    ffi.Pointer<ffi.NativeFunction<_signaling_invitation_callback_native>>,
    ffi.Pointer<ffi.NativeFunction<_signaling_cancel_callback_native>>,
    ffi.Pointer<ffi.NativeFunction<_signaling_accept_callback_native>>,
    ffi.Pointer<ffi.NativeFunction<_signaling_reject_callback_native>>,
    ffi.Pointer<ffi.NativeFunction<_signaling_timeout_callback_native>>,
    ffi.Pointer<ffi.Void>,
  ) signalingAddListenerNative = _lib.lookupFunction<_signaling_add_listener_c, int Function(
    ffi.Pointer<ffi.NativeFunction<_signaling_invitation_callback_native>>,
    ffi.Pointer<ffi.NativeFunction<_signaling_cancel_callback_native>>,
    ffi.Pointer<ffi.NativeFunction<_signaling_accept_callback_native>>,
    ffi.Pointer<ffi.NativeFunction<_signaling_reject_callback_native>>,
    ffi.Pointer<ffi.NativeFunction<_signaling_timeout_callback_native>>,
    ffi.Pointer<ffi.Void>,
  )>('tim2tox_ffi_signaling_add_listener');
  
  late final void Function() signalingRemoveListener = _lib.lookupFunction<_signaling_remove_listener_c, void Function()>('tim2tox_ffi_signaling_remove_listener');

  // Dart-compat per-instance signaling (sends via globalCallback with instance_id)
  late final void Function(ffi.Pointer<ffi.Void>) dartSetSignalingReceiveNewInvitationCallback =
      _lib.lookupFunction<_dart_set_signaling_cb_c, _dart_set_signaling_cb_d>('DartSetSignalingReceiveNewInvitationCallback');
  late final void Function(ffi.Pointer<ffi.Void>) dartSetSignalingInvitationCancelledCallback =
      _lib.lookupFunction<_dart_set_signaling_cb_c, _dart_set_signaling_cb_d>('DartSetSignalingInvitationCancelledCallback');
  late final void Function(ffi.Pointer<ffi.Void>) dartSetSignalingInviteeAcceptedCallback =
      _lib.lookupFunction<_dart_set_signaling_cb_c, _dart_set_signaling_cb_d>('DartSetSignalingInviteeAcceptedCallback');
  late final void Function(ffi.Pointer<ffi.Void>) dartSetSignalingInviteeRejectedCallback =
      _lib.lookupFunction<_dart_set_signaling_cb_c, _dart_set_signaling_cb_d>('DartSetSignalingInviteeRejectedCallback');
  late final void Function(ffi.Pointer<ffi.Void>) dartSetSignalingInvitationTimeoutCallback =
      _lib.lookupFunction<_dart_set_signaling_cb_c, _dart_set_signaling_cb_d>('DartSetSignalingInvitationTimeoutCallback');
  late final void Function(ffi.Pointer<ffi.Void>) dartSetSignalingInvitationModifiedCallback =
      _lib.lookupFunction<_dart_set_signaling_cb_c, _dart_set_signaling_cb_d>('DartSetSignalingInvitationModifiedCallback');
  late final void Function() dartRemoveSignalingListenerForCurrentInstance =
      _lib.lookupFunction<ffi.Void Function(), void Function()>('DartRemoveSignalingListenerForCurrentInstance');

  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, int, int, ffi.Pointer<ffi.Int8>, int) signalingInviteNative =
      _lib.lookupFunction<_signaling_invite_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, int, int, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_signaling_invite');
  
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, int, int, ffi.Pointer<ffi.Int8>, int) signalingInviteInGroupNative =
      _lib.lookupFunction<_signaling_invite_in_group_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>, int, int, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_signaling_invite_in_group');
  
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) signalingCancelNative =
      _lib.lookupFunction<_signaling_cancel_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_signaling_cancel');
  
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) signalingAcceptNative =
      _lib.lookupFunction<_signaling_accept_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_signaling_accept');
  
  late final int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) signalingRejectNative =
      _lib.lookupFunction<_signaling_reject_c, int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_signaling_reject');
  
  // ============================================================================
  // Audio/Video (ToxAV) FFI Bindings
  // ============================================================================
  
  late final int Function(int) avInitialize = _lib.lookupFunction<_av_initialize_c, int Function(int)>('tim2tox_ffi_av_initialize');
  late final void Function(int) avShutdown = _lib.lookupFunction<_av_shutdown_c, void Function(int)>('tim2tox_ffi_av_shutdown');
  late final void Function(int) avIterate = _lib.lookupFunction<_av_iterate_c, void Function(int)>('tim2tox_ffi_av_iterate');
  late final int Function(int, int, int, int) avStartCallNative = _lib.lookupFunction<_av_start_call_c, int Function(int, int, int, int)>('tim2tox_ffi_av_start_call');
  late final int Function(int, int, int, int) avAnswerCallNative = _lib.lookupFunction<_av_answer_call_c, int Function(int, int, int, int)>('tim2tox_ffi_av_answer_call');
  late final int Function(int, int) avEndCallNative = _lib.lookupFunction<_av_end_call_c, int Function(int, int)>('tim2tox_ffi_av_end_call');
  late final int Function(int, int, int) avMuteAudioNative = _lib.lookupFunction<_av_mute_audio_c, int Function(int, int, int)>('tim2tox_ffi_av_mute_audio');
  late final int Function(int, int, int) avMuteVideoNative = _lib.lookupFunction<_av_mute_video_c, int Function(int, int, int)>('tim2tox_ffi_av_mute_video');
  late final int Function(int, int, ffi.Pointer<ffi.Int16>, int, int, int) avSendAudioFrameNative = _lib.lookupFunction<_av_send_audio_frame_c, int Function(int, int, ffi.Pointer<ffi.Int16>, int, int, int)>('tim2tox_ffi_av_send_audio_frame');
  late final int Function(int, int, int, int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, int, int, int) avSendVideoFrameNative = _lib.lookupFunction<_av_send_video_frame_c, int Function(int, int, int, int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, int, int, int)>('tim2tox_ffi_av_send_video_frame');
  late final int Function(int, int, int) avSetAudioBitRateNative = _lib.lookupFunction<_av_set_audio_bit_rate_c, int Function(int, int, int)>('tim2tox_ffi_av_set_audio_bit_rate');
  late final int Function(int, int, int) avSetVideoBitRateNative = _lib.lookupFunction<_av_set_video_bit_rate_c, int Function(int, int, int)>('tim2tox_ffi_av_set_video_bit_rate');
  late final void Function(int, ffi.Pointer<ffi.NativeFunction<_av_call_callback_native>>, ffi.Pointer<ffi.Void>) avSetCallCallbackNative = _lib.lookupFunction<_av_set_call_callback_c, void Function(int, ffi.Pointer<ffi.NativeFunction<_av_call_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_av_set_call_callback');
  late final void Function(int, ffi.Pointer<ffi.NativeFunction<_av_call_state_callback_native>>, ffi.Pointer<ffi.Void>) avSetCallStateCallbackNative = _lib.lookupFunction<_av_set_call_state_callback_c, void Function(int, ffi.Pointer<ffi.NativeFunction<_av_call_state_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_av_set_call_state_callback');
  late final void Function(int, ffi.Pointer<ffi.NativeFunction<_av_audio_receive_callback_native>>, ffi.Pointer<ffi.Void>) avSetAudioReceiveCallbackNative = _lib.lookupFunction<_av_set_audio_receive_callback_c, void Function(int, ffi.Pointer<ffi.NativeFunction<_av_audio_receive_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_av_set_audio_receive_callback');
  late final void Function(int, ffi.Pointer<ffi.NativeFunction<_av_video_receive_callback_native>>, ffi.Pointer<ffi.Void>) avSetVideoReceiveCallbackNative = _lib.lookupFunction<_av_set_video_receive_callback_c, void Function(int, ffi.Pointer<ffi.NativeFunction<_av_video_receive_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_av_set_video_receive_callback');
  late final void Function(int, ffi.Pointer<ffi.NativeFunction<_av_audio_bitrate_callback_native>>, ffi.Pointer<ffi.Void>) avSetAudioBitrateCallbackNative = _lib.lookupFunction<_av_set_audio_bitrate_callback_c, void Function(int, ffi.Pointer<ffi.NativeFunction<_av_audio_bitrate_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_av_set_audio_bitrate_callback');
  late final void Function(int, ffi.Pointer<ffi.NativeFunction<_av_video_bitrate_callback_native>>, ffi.Pointer<ffi.Void>) avSetVideoBitrateCallbackNative = _lib.lookupFunction<_av_set_video_bitrate_callback_c, void Function(int, ffi.Pointer<ffi.NativeFunction<_av_video_bitrate_callback_native>>, ffi.Pointer<ffi.Void>)>('tim2tox_ffi_av_set_video_bitrate_callback');
  late final int Function(ffi.Pointer<pkgffi.Utf8>) getFriendNumberByUserIdNative = _lib.lookupFunction<_get_friend_number_by_user_id_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_get_friend_number_by_user_id');
  late final ffi.Pointer<pkgffi.Utf8> Function(int) getUserIdByFriendNumberNative = _lib.lookupFunction<_get_user_id_by_friend_number_c, ffi.Pointer<pkgffi.Utf8> Function(int)>('tim2tox_ffi_get_user_id_by_friend_number');
  
  // Update known groups list in C++ layer (called when knownGroups changes in Dart)
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>) updateKnownGroupsNative = 
      _lib.lookupFunction<_update_known_groups_c, int Function(int, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_update_known_groups');
  
  // Get known groups from C++ layer
  late final int Function(int, ffi.Pointer<ffi.Int8>, int) getKnownGroupsNative = 
      _lib.lookupFunction<_get_known_groups_c, int Function(int, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_known_groups');
  
  // Get full tox group chat_id from groupID
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, int) getGroupChatIdNative = 
      _lib.lookupFunction<_get_group_chat_id_c, int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_group_chat_id');
  
  // Store/Get group chat_id from persistence
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) setGroupChatIdNative = 
      _lib.lookupFunction<_set_group_chat_id_c, int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_set_group_chat_id');
  
  // Get count of conferences restored from savedata (for discovering and assigning group_ids)
  late final int Function(int) getRestoredConferenceCountNative = 
      _lib.lookupFunction<_get_restored_conference_count_c, int Function(int)>('tim2tox_ffi_get_restored_conference_count');
  
  // Get list of conference numbers restored from savedata
  late final int Function(int, ffi.Pointer<ffi.Uint32>, int) getRestoredConferenceListNative =
      _lib.lookupFunction<_get_restored_conference_list_c, int Function(int, ffi.Pointer<ffi.Uint32>, int)>('tim2tox_ffi_get_restored_conference_list');

  // Get peer count for a specific conference
  late final int Function(int, int) getConferencePeerCountNative =
      _lib.lookupFunction<_get_conference_peer_count_c, int Function(int, int)>('tim2tox_ffi_get_conference_peer_count');

  // Get comma-separated hex pubkeys of all peers in a conference
  late final int Function(int, int, ffi.Pointer<ffi.Int8>, int) getConferencePeerPubkeysNative =
      _lib.lookupFunction<_get_conference_peer_pubkeys_c, int Function(int, int, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_conference_peer_pubkeys');

  // Set group type in C++ storage (e.g. "conference") so RejoinKnownGroups can match
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>) setGroupTypeNative = 
      _lib.lookupFunction<_set_group_type_c, int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_set_group_type');
  
  // Rejoin all known groups using stored chat_id (c-toxcore recommended approach)
  late final int Function() rejoinKnownGroupsNative = 
      _lib.lookupFunction<_rejoin_known_groups_c, int Function()>('tim2tox_ffi_rejoin_known_groups');
  
  // Auto-accept group invites setting
  late final int Function(int, int) setAutoAcceptGroupInvitesNative = 
      _lib.lookupFunction<_set_auto_accept_group_invites_c, int Function(int, int)>('tim2tox_ffi_set_auto_accept_group_invites');
  late final int Function(int) getAutoAcceptGroupInvitesNative = 
      _lib.lookupFunction<_get_auto_accept_group_invites_c, int Function(int)>('tim2tox_ffi_get_auto_accept_group_invites');
  
  late final int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, int) getGroupChatIdFromStorageNative = 
      _lib.lookupFunction<_get_group_chat_id_from_storage_c, int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_get_group_chat_id_from_storage');

  // ============================================================================
  // Tox Profile Encryption/Decryption FFI Bindings
  // ============================================================================
  
  late final int Function(ffi.Pointer<ffi.Uint8>, int) isDataEncryptedNative = 
      _lib.lookupFunction<_is_data_encrypted_c, int Function(ffi.Pointer<ffi.Uint8>, int)>('tim2tox_ffi_is_data_encrypted');
  
  late final int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int) passEncryptNative = 
      _lib.lookupFunction<_pass_encrypt_c, int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int)>('tim2tox_ffi_pass_encrypt');
  
  late final int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int) passDecryptNative = 
      _lib.lookupFunction<_pass_decrypt_c, int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int)>('tim2tox_ffi_pass_decrypt');
  
  late final int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Int8>, int) extractToxIdFromProfileNative =
      _lib.lookupFunction<_extract_tox_id_from_profile_c, int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Int8>, int)>('tim2tox_ffi_extract_tox_id_from_profile');

  /// Test-only: Inject a raw JSON callback string into the Dart ReceivePort.
  /// The JSON must match the format expected by NativeLibraryManager._handleNativeMessage.
  /// Returns 1 on success, 0 on failure.
  late final int Function(ffi.Pointer<pkgffi.Utf8>) injectCallbackNative =
      _lib.lookupFunction<_inject_callback_c, int Function(ffi.Pointer<pkgffi.Utf8>)>('tim2tox_ffi_inject_callback');

  // ============================================================================
  // Test-only: virtual clock + manual iteration.
  //
  // [setTestMode] enables/disables test mode for a specific instance. While
  // enabled, the C++ side suspends the instance's per-instance event_thread so
  // the test harness can drive iteration directly via [iterateInstance].
  //
  // [setVirtualTimeMs] sets the process-global virtual clock value consulted
  // by the C++ layer instead of wall time. Always pass a monotonically
  // non-decreasing value.
  //
  // [iterateInstance] runs one iteration of the given Tox instance under the
  // current virtual clock value.
  //
  // All three return 0 on success, non-zero on failure (e.g. unknown
  // instance_id).
  // ============================================================================
  late final int Function(int, int) setTestModeNative =
      _lib.lookupFunction<_set_test_mode_c, int Function(int, int)>('tim2tox_ffi_set_test_mode');
  late final int Function(int) setVirtualTimeMsNative =
      _lib.lookupFunction<_set_virtual_time_ms_c, int Function(int)>('tim2tox_ffi_set_virtual_time_ms');
  late final int Function(int) iterateInstanceNative =
      _lib.lookupFunction<_iterate_instance_c, int Function(int)>('tim2tox_ffi_iterate_instance');
  late final int Function(int) setDefaultTestModeNative =
      _lib.lookupFunction<_set_default_test_mode_c, int Function(int)>('tim2tox_ffi_set_default_test_mode');

  /// Enable or disable test mode for [instanceId]. When enabled, the C++ side
  /// suspends that instance's event_thread; the test harness must drive
  /// iteration manually via [iterateInstance] and advance the virtual clock
  /// via [setVirtualTimeMs]. Returns 0 on success.
  int setTestMode(int instanceId, bool enabled) =>
      setTestModeNative(instanceId, enabled ? 1 : 0);

  /// Set the process-global virtual clock value (milliseconds). Must be
  /// monotonically non-decreasing across calls. Returns 0 on success.
  ///
  /// Note: the C export takes a uint64. Dart [int] is 64-bit signed on the VM
  /// but the FFI marshalling treats this slot as unsigned, so callers can pass
  /// any non-negative value safely without manual bigint handling.
  int setVirtualTimeMs(int timeMs) => setVirtualTimeMsNative(timeMs);

  /// Run one iteration of [instanceId] under the current virtual clock value.
  /// Returns 0 on success.
  int iterateInstance(int instanceId) => iterateInstanceNative(instanceId);

  /// Set the process-global default test_mode flag. New instances created
  /// AFTER this call inherit the flag, so InitSDK never spawns event_thread.
  /// Required for tests whose flows depend on event_thread's task_queue
  /// (signaling, etc.) — they must be driven entirely from Dart.
  /// Returns 0 on success.
  int setDefaultTestMode(bool enabled) =>
      setDefaultTestModeNative(enabled ? 1 : 0);

  /// Convenience wrapper for injectCallbackNative that handles string conversion.
  int injectCallback(String jsonCallback) {
    final ptr = jsonCallback.toNativeUtf8();
    try {
      return injectCallbackNative(ptr);
    } finally {
      pkgffi.malloc.free(ptr);
    }
  }

  /// Set unified log file path for C++ layer (call before init). Disables C++ console output.
  void setLogFile(String path) {
    final ptr = path.toNativeUtf8();
    try {
      setLogFileNative(ptr);
    } finally {
      pkgffi.malloc.free(ptr);
    }
  }

  /// Open the tim2tox FFI library
  /// 
  /// Tries to load the library from the executable directory first,
  /// then falls back to system library search path.
  /// Supports multiple platforms: macOS, Linux, Windows, Android, iOS
  static Tim2ToxFfi open() {
    if (Platform.isMacOS) {
      return _openMacOS();
    } else if (Platform.isLinux) {
      return _openLinux();
    } else if (Platform.isWindows) {
      return _openWindows();
    } else if (Platform.isAndroid) {
      return _openAndroid();
    } else if (Platform.isIOS) {
      return _openIOS();
    } else {
      throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
    }
  }

  /// Open library on macOS
  static Tim2ToxFfi _openMacOS() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final libName = 'libtim2tox_ffi.dylib';
    
    // Try absolute path from project root (for development/testing)
    final projectRootPaths = [
      '/Users/bin.gao/chat-uikit/tim2tox/build/ffi/$libName',
      '${exeDir.path}/../../tim2tox/build/ffi/$libName',
      '${exeDir.path}/../../../tim2tox/build/ffi/$libName',
    ];
    
    for (final libPath in projectRootPaths) {
      final libFile = File(libPath);
      if (libFile.existsSync()) {
        try {
          return Tim2ToxFfi._(ffi.DynamicLibrary.open(libFile.absolute.path));
        } catch (e) {
          // Continue to next path if this one fails
          continue;
        }
      }
    }
    
    // Try executable directory first
    final exeLib = File('${exeDir.path}/$libName');
    if (exeLib.existsSync()) {
      return Tim2ToxFfi._(ffi.DynamicLibrary.open(exeLib.path));
    }
    
    // Try application bundle (for packaged apps)
    try {
      final bundlePath = '${exeDir.path}/../Frameworks/$libName';
      final bundleLib = File(bundlePath);
      if (bundleLib.existsSync()) {
        return Tim2ToxFfi._(ffi.DynamicLibrary.open(bundleLib.path));
      }
    } catch (_) {}
    
    // Fallback to system library search path
    return Tim2ToxFfi._(ffi.DynamicLibrary.open(libName));
  }

  /// Open library on Linux
  static Tim2ToxFfi _openLinux() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final libName = 'libtim2tox_ffi.so';
    
    // Try executable directory first
    final exeLib = File('${exeDir.path}/$libName');
    if (exeLib.existsSync()) {
      return Tim2ToxFfi._(ffi.DynamicLibrary.open(exeLib.path));
    }
    
    // Try lib directory next to executable
    try {
      final libPath = '${exeDir.path}/../lib/$libName';
      final libFile = File(libPath);
      if (libFile.existsSync()) {
        return Tim2ToxFfi._(ffi.DynamicLibrary.open(libFile.path));
      }
    } catch (_) {}
    
    // Fallback to system library search path
    return Tim2ToxFfi._(ffi.DynamicLibrary.open(libName));
  }

  /// Open library on Windows
  static Tim2ToxFfi _openWindows() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final libName = 'tim2tox_ffi.dll';
    
    // Try executable directory first
    final exeLib = File('${exeDir.path}/$libName');
    if (exeLib.existsSync()) {
      return Tim2ToxFfi._(ffi.DynamicLibrary.open(exeLib.path));
    }
    
    // Try lib directory next to executable
    try {
      final libPath = '${exeDir.path}/../lib/$libName';
      final libFile = File(libPath);
      if (libFile.existsSync()) {
        return Tim2ToxFfi._(ffi.DynamicLibrary.open(libFile.path));
      }
    } catch (_) {}
    
    // Fallback to system library search path
    return Tim2ToxFfi._(ffi.DynamicLibrary.open(libName));
  }

  /// Open library on Android
  static Tim2ToxFfi _openAndroid() {
    final libName = 'libtim2tox_ffi.so';
    
    // On Android, libraries are typically in the app's native library directory
    // Flutter will handle this automatically, but we can also try explicit paths
    try {
      // Try system library path (Flutter's default)
      return Tim2ToxFfi._(ffi.DynamicLibrary.open(libName));
    } catch (e) {
      // If that fails, try generic system/vendor paths only (no app-specific path;
      // this library must not hardcode any client app package name).
      final possiblePaths = [
        '/system/lib/$libName',
        '/vendor/lib/$libName',
      ];
      
      for (final path in possiblePaths) {
        try {
          final libFile = File(path);
          if (libFile.existsSync()) {
            return Tim2ToxFfi._(ffi.DynamicLibrary.open(libFile.path));
          }
        } catch (_) {}
      }
      
      // Re-throw original error if all paths fail
      throw Exception('Failed to load $libName on Android: $e');
    }
  }

  /// Open library on iOS
  static Tim2ToxFfi _openIOS() {
    final libName = 'libtim2tox_ffi.dylib';
    
    // On iOS, libraries are typically in the app bundle's Frameworks directory
    try {
      // Try framework first (preferred for iOS)
      final frameworkPath = 'tim2tox_ffi.framework/tim2tox_ffi';
      try {
        return Tim2ToxFfi._(ffi.DynamicLibrary.open(frameworkPath));
      } catch (_) {}
      
      // Fallback to dylib
      return Tim2ToxFfi._(ffi.DynamicLibrary.open(libName));
    } catch (e) {
      throw Exception('Failed to load tim2tox_ffi on iOS: $e');
    }
  }
}

