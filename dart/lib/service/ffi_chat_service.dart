import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:convert';
import 'package:ffi/ffi.dart' as pkgffi;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import '../ffi/tim2tox_ffi.dart';
import '../models/chat_message.dart';
import '../interfaces/preferences_service.dart';
import '../interfaces/extended_preferences_service.dart';
import '../interfaces/logger_service.dart';
import '../interfaces/bootstrap_service.dart';
import '../utils/conversation_id_utils.dart';
import '../utils/message_history_persistence.dart';
import '../utils/offline_message_queue_persistence.dart';
import 'package:tencent_cloud_chat_sdk/native_im/bindings/native_library_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/tools.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_callback.dart';

typedef _init_c = ffi.Int32 Function();
typedef _set_file_recv_dir_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _login_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
// R-08: Async login callback (C signature for NativeCallable)
typedef _login_callback_native = ffi.Void Function(
    ffi.Int32 success,
    ffi.Int32 error_code,
    ffi.Pointer<pkgffi.Utf8> error_message,
    ffi.Pointer<ffi.Void> user_data);
typedef _add_friend_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _send_text_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _poll_text_c = ffi.Int32 Function(ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _poll_custom_c = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _get_login_user_c = ffi.Int32 Function(
    ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _uninit_c = ffi.Void Function();
typedef _get_friend_list_c = ffi.Int32 Function(
    ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _set_self_info_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _get_friend_apps_c = ffi.Int32 Function(
    ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _accept_friend_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _delete_friend_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>);
typedef _set_callback_c = ffi.Void Function(
    ffi.Pointer<ffi.NativeFunction<_event_cb_native>>, ffi.Pointer<ffi.Void>);
typedef _event_cb_native = ffi.Void Function(
    ffi.Int32, // event_type
    ffi.Pointer<pkgffi.Utf8>, // sender
    ffi.Pointer<ffi.Uint8>, // payload
    ffi.Int32, // payload_len
    ffi.Pointer<ffi.Void> // user
    );
typedef _set_typing_c = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf8>, ffi.Int32);
typedef _create_group_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Int8>, ffi.Int32);
typedef _join_group_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _send_group_text_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _send_c2c_custom_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _send_group_custom_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _send_file_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _file_control_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Uint32, ffi.Int32);
typedef _get_self_connection_status_c = ffi.Int32 Function();
typedef _add_bootstrap_node_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Int32, ffi.Pointer<pkgffi.Utf8>);
typedef _irc_connect_channel_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Int32,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Int32,
    ffi.Pointer<pkgffi.Utf8>);
typedef _irc_disconnect_channel_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>);
typedef _irc_send_message_c = ffi.Int32 Function(
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
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

// Use Tim2ToxFfi from tim2tox_ffi.dart instead of defining a duplicate class here

// DHT nodes response callback type (matching tim2tox_ffi.dart)
typedef _dht_nodes_response_callback_native = ffi.Void Function(
  ffi.Pointer<pkgffi.Utf8>, // public_key (hex string)
  ffi.Pointer<pkgffi.Utf8>, // ip
  ffi.Uint16, // port
  ffi.Pointer<ffi.Void>, // user_data
);

// Global map for instance ID -> FfiChatService routing (for multi-instance support)
final Map<int, FfiChatService> _instanceServices = {};
final Object _instanceServicesLock = Object(); // Simple lock for thread safety
// Instance IDs that have registered (for multi-instance poll: single shared FfiChatService must poll all)
final Set<int> _knownInstanceIds = {};

// Single shared NativeCallable.listener for DHT nodes response. The C side is
// called on Tox's background event_thread, which has no Dart isolate; a
// synchronous Pointer.fromFunction would crash with "Cannot invoke native
// callback outside an isolate". A listener marshals the call to the isolate
// that created it. One instance is enough because the trampoline routes to
// the per-instance FfiChatService via the userData (instance_id) pointer.
ffi.NativeCallable<_dht_nodes_response_callback_native>?
    _dhtNodesResponseCallable;
ffi.Pointer<ffi.NativeFunction<_dht_nodes_response_callback_native>>
    _dhtNodesResponseNativeFunction() {
  _dhtNodesResponseCallable ??=
      ffi.NativeCallable<_dht_nodes_response_callback_native>.listener(
    _dhtNodesResponseTrampoline,
  );
  return _dhtNodesResponseCallable!.nativeFunction;
}

// Product decision: sync avatar between friends, but never expose it as chat messages.
const bool _avatarBroadcastAsChatFileEnabled = true;

// Trampoline for DHT nodes response callback.
//
// Invoked by NativeCallable.listener — runs on the registering isolate's event
// loop, NOT on Tox's background event_thread. Because of the async hop, the
// C-side allocates heap copies of the hex public_key and IP strings via
// strdup() and transfers ownership here; we must free() them after reading.
// userData is cast to int64_t (instance_id) for routing to the correct service
// instance.
@pragma('vm:entry-point')
void _dhtNodesResponseTrampoline(ffi.Pointer<pkgffi.Utf8> publicKeyPtr,
    ffi.Pointer<pkgffi.Utf8> ipPtr, int port, ffi.Pointer<ffi.Void> userData) {
  String? publicKey;
  String? ip;
  try {
    if (publicKeyPtr.address != 0) {
      publicKey = publicKeyPtr.cast<pkgffi.Utf8>().toDartString();
    }
    if (ipPtr.address != 0) {
      ip = ipPtr.cast<pkgffi.Utf8>().toDartString();
    }
    if (publicKey == null || ip == null) {
      return;
    }

    // Extract instance ID from userData (cast void* to int64_t).
    int instanceId = 0;
    if (userData.address != 0) {
      // userData points to an int64_t value (instance_id) allocated by Dart in
      // setDhtNodesResponseCallback; this pointer is heap-stable for the
      // lifetime of the callback registration.
      instanceId = userData.cast<ffi.Int64>().value;
    }

    // Route to the correct service instance based on instance ID.
    FfiChatService? targetService;
    synchronized(_instanceServicesLock, () {
      targetService = _instanceServices[instanceId];
    });

    if (targetService != null) {
      targetService!._onDhtNodesResponse(publicKey, ip, port);
    } else if (instanceId == 0) {
      // Fallback to global service for default instance (backward compatibility).
      _globalService?._onDhtNodesResponse(publicKey, ip, port);
    }
    // If instanceId != 0 and no service found, silently ignore (service may
    // have been disposed).
  } catch (_) {
    // Silently ignore errors in callback to prevent crashes. This can happen
    // if the service was disposed or if there's a race condition.
  } finally {
    // C side strdup'd these buffers; ownership was transferred to us. Free
    // with the matching libc free() to avoid leaks. package:ffi's calloc.free
    // dispatches to free() under the hood, which is the correct counterpart
    // of strdup().
    if (publicKeyPtr.address != 0) {
      pkgffi.calloc.free(publicKeyPtr);
    }
    if (ipPtr.address != 0) {
      pkgffi.calloc.free(ipPtr);
    }
  }
}

// Helper function for synchronized access (simple mutex-like behavior)
T synchronized<T>(Object lock, T Function() action) {
  return action(); // In Dart, we rely on single-threaded execution, but this provides structure for future thread safety
}

// Trampoline for native callback
FfiChatService?
    _globalService; // Kept for backward compatibility with default instance
void _nativeEventTrampoline(int eventType, ffi.Pointer<pkgffi.Utf8> sender,
    ffi.Pointer<ffi.Uint8> payload, int len, ffi.Pointer<ffi.Void> user) {
  final s = sender.cast<pkgffi.Utf8>().toDartString();
  final data = (len > 0) ? payload.cast<pkgffi.Utf8>().toDartString() : '';
  _globalService?._onNativeEvent(eventType, s, data);
}

final _nativeCbPtr =
    ffi.Pointer.fromFunction<_event_cb_native>(_nativeEventTrampoline);

// IRC callback trampolines
@pragma('vm:entry-point')
void _ircConnectionStatusTrampoline(ffi.Pointer<pkgffi.Utf8> channel,
    int status, ffi.Pointer<pkgffi.Utf8> message, ffi.Pointer<ffi.Void> user) {
  final ch = channel.cast<pkgffi.Utf8>().toDartString();
  final msg =
      message.address != 0 ? message.cast<pkgffi.Utf8>().toDartString() : null;
  _globalService?._onIrcConnectionStatus(ch, status, msg);
}

@pragma('vm:entry-point')
void _ircUserListTrampoline(ffi.Pointer<pkgffi.Utf8> channel,
    ffi.Pointer<pkgffi.Utf8> users, ffi.Pointer<ffi.Void> user) {
  final ch = channel.cast<pkgffi.Utf8>().toDartString();
  final usersStr =
      users.address != 0 ? users.cast<pkgffi.Utf8>().toDartString() : '';
  final usersList = usersStr.isEmpty ? <String>[] : usersStr.split(',');
  _globalService?._onIrcUserList(ch, usersList);
}

@pragma('vm:entry-point')
void _ircUserJoinPartTrampoline(ffi.Pointer<pkgffi.Utf8> channel,
    ffi.Pointer<pkgffi.Utf8> nickname, int joined, ffi.Pointer<ffi.Void> user) {
  final ch = channel.cast<pkgffi.Utf8>().toDartString();
  final nick = nickname.cast<pkgffi.Utf8>().toDartString();
  _globalService?._onIrcUserJoinPart(ch, nick, joined != 0);
}

final _ircConnectionStatusCbPtr =
    ffi.Pointer.fromFunction<_irc_connection_status_callback_native>(
        _ircConnectionStatusTrampoline);
final _ircUserListCbPtr =
    ffi.Pointer.fromFunction<_irc_user_list_callback_native>(
        _ircUserListTrampoline);
final _ircUserJoinPartCbPtr =
    ffi.Pointer.fromFunction<_irc_user_join_part_callback_native>(
        _ircUserJoinPartTrampoline);

/// Resolves on-disk paths for [FfiChatService] without coupling tim2tox to
/// any particular client (toxee, examples, auto_tests). When an integrator
/// wants paths routed through its own central path authority (e.g. toxee's
/// `AppPaths`), it implements this and passes it to the constructor.
///
/// Implementations must return **non-empty absolute directory paths**. The
/// caller will create the directory if it does not exist. Returning a
/// relative path, empty string, or null is a contract violation and triggers
/// an [ArgumentError] — this guards against path-traversal-shaped bugs (e.g.
/// `"../../etc"`) and silent fall-through to a misconfigured default.
///
/// Returning the [FfiChatPathResolver] argument as null (or omitting the
/// parameter entirely) makes [FfiChatService] fall back to its built-in
/// `getApplicationSupportDirectory()` defaults, so this stays optional for
/// tim2tox standalone tests.
///
/// Note for integrators upgrading from the legacy `_fileRecvPath` /
/// `_avatarsPath` constructor parameters: existing on-disk files at the old
/// location are **not** migrated automatically when a resolver is introduced.
/// If the resolver returns a different directory, surface the migration in
/// the integrator's account/bootstrap layer.
/// Sentinel raised by the offline-drain path when the friend goes offline
/// again between the trigger and our send call. The drain loop catches
/// this specifically so it can leave the queue item and pending bubble
/// untouched for the next online transition — distinct from a real send
/// failure which removes the item and marks the bubble failed.
class _OfflineDuringDrain implements Exception {
  const _OfflineDuringDrain();
}

abstract class FfiChatPathResolver {
  /// Directory where tox file_recv puts incoming file transfers.
  /// Default fallback: `<appSupport>/file_recv`.
  Future<String> resolveFileRecvDirectory();

  /// Directory where the service places avatar images it has copied.
  /// Default fallback: `<appSupport>/avatars`.
  Future<String> resolveAvatarsDirectory();
}

/// Validate a resolver-returned directory path. Throws [ArgumentError] if the
/// returned path is empty or not absolute — both are contract violations of
/// [FfiChatPathResolver]. Returns [path] unchanged on success.
String _assertResolverPath(String path, String which) {
  if (path.isEmpty) {
    throw ArgumentError(
      'FfiChatPathResolver.$which returned an empty string; '
      'must be a non-empty absolute directory path.',
    );
  }
  // p.isAbsolute is platform-aware and handles both POSIX and Windows roots.
  if (!p.isAbsolute(path)) {
    throw ArgumentError(
      'FfiChatPathResolver.$which returned a non-absolute path "$path"; '
      'must be an absolute directory path (e.g. /Users/.../foo or C:\\foo).',
    );
  }
  return path;
}

/// Result of a [FfiChatService.addFriend] call.
///
/// `resultCode == 0` is the only success signal. Non-zero codes come from the
/// V2TIMFriendOperationResult the C++ layer surfaces via the
/// `friendAddResult` Dart callback — most notably `6770` for
/// "Friend add requires full Tox address". `dispatched == false` means the
/// synchronous FFI dispatch failed (SDK not initialized, native lib not
/// loaded, etc.) and no async callback ever arrived; `resultCode == -1` and
/// [resultInfo] describes the failure.
class AddFriendResult {
  const AddFriendResult({
    required this.resultCode,
    required this.userId,
    required this.resultInfo,
    required this.dispatched,
  });

  /// 0 = success; non-zero = V2TIM operation failure code (e.g. 6770).
  /// `-1` means the call never reached the V2TIM layer.
  final int resultCode;

  /// The user_id the caller passed to [FfiChatService.addFriend]; echoed back
  /// from C++ so concurrent calls don't get crossed.
  final String userId;

  /// Human-readable description from V2TIMFriendOperationResult.resultInfo,
  /// or a Dart-side reason when [dispatched] is false. May be empty on
  /// success.
  final String resultInfo;

  /// `true` if the sync FFI dispatch returned non-zero (i.e. the request
  /// reached the V2TIM layer and an async result arrived).
  final bool dispatched;

  bool get isSuccess => dispatched && resultCode == 0;
}

class FfiChatService {
  // Static counter for msgID sequence to ensure uniqueness
  static int _msgIDSequence = 0;

  /// Register an instance ID for polling (e.g. test nodes). Ensures file_request and other
  /// instance-scoped events are consumed when using a single shared FfiChatService.
  static void registerInstanceForPolling(int instanceId) {
    if (instanceId != 0) {
      synchronized(_instanceServicesLock, () {
        _knownInstanceIds.add(instanceId);
      });
    }
  }

  /// Unregister an instance ID from polling.
  /// Important for tests: prevents poll loop from iterating destroyed instance IDs.
  static void unregisterInstanceForPolling(int instanceId) {
    if (instanceId != 0) {
      synchronized(_instanceServicesLock, () {
        _knownInstanceIds.remove(instanceId);
        _instanceServices.remove(instanceId);
      });
    }
  }

  /// Test-only helper: clear polling registry to avoid stale instance IDs between scenarios.
  static void clearPollingRegistryForTests() {
    synchronized(_instanceServicesLock, () {
      _knownInstanceIds.clear();
      _instanceServices.clear();
    });
  }

  FfiChatService({
    ExtendedPreferencesService? preferencesService,
    LoggerService? loggerService,
    BootstrapService? bootstrapService,
    MessageHistoryPersistence? messageHistoryPersistence,
    OfflineMessageQueuePersistence? offlineMessageQueuePersistence,
    String? historyDirectory,
    String? queueFilePath,
    String? fileRecvPath,
    String? avatarsPath,
    FfiChatPathResolver? pathResolver,
  })  : _ffi = Tim2ToxFfi.open(),
        _prefs = preferencesService,
        _logger = loggerService,
        _bootstrap = bootstrapService,
        // X11: forward the injected logger so the no-historyDirectory
        // warning emitted from MessageHistoryPersistence's constructor lands
        // in the integrator's structured log rather than just stderr.
        _messageHistoryPersistence = messageHistoryPersistence ??
            (historyDirectory != null && historyDirectory.isNotEmpty
                ? MessageHistoryPersistence(
                    historyDirectory: historyDirectory,
                    logger: loggerService,
                  )
                : _createMessageHistoryPersistence(logger: loggerService)),
        _offlineQueuePersistence = offlineMessageQueuePersistence ??
            (queueFilePath != null && queueFilePath.isNotEmpty
                ? OfflineMessageQueuePersistence(queueFilePath: queueFilePath)
                : OfflineMessageQueuePersistence()),
        _fileRecvPath = fileRecvPath,
        _avatarsPath = avatarsPath,
        _pathResolver = pathResolver {
    try {
      final id = _ffi.getCurrentInstanceId();
      if (id != 0) _instanceId = id;
    } catch (_) {}
  }

  /// Create MessageHistoryPersistence with instance ID support
  static MessageHistoryPersistence _createMessageHistoryPersistence(
      {LoggerService? logger}) {
    try {
      final ffi = Tim2ToxFfi.open();
      final instanceId = ffi.getCurrentInstanceId();
      // Use instanceId if it's not 0 (default instance), otherwise use null
      return MessageHistoryPersistence(
        instanceId: instanceId != 0 ? instanceId : null,
        logger: logger,
      );
    } catch (e) {
      // If we can't get instance ID, create without it (will use default directory)
      return MessageHistoryPersistence(logger: logger);
    }
  }

  final Tim2ToxFfi _ffi;
  final ExtendedPreferencesService? _prefs;
  final LoggerService? _logger;
  final BootstrapService? _bootstrap;
  final MessageHistoryPersistence _messageHistoryPersistence;
  final OfflineMessageQueuePersistence _offlineQueuePersistence;

  /// Per-account file receive directory (when set, used instead of app support file_recv).
  final String? _fileRecvPath;

  /// P1-2: Resolved file_recv directory once init has run (whatever path the
  /// constructor arg, resolver, or fallback ended up with). Used to anchor the
  /// "receiving_*" temp path on disk instead of hard-coding `/tmp`, which is
  /// world-writable on POSIX and the wrong shape on Windows.
  String? _fileRecvDir;

  /// Per-account avatars directory (when set, used instead of app support avatars).
  final String? _avatarsPath;

  /// Optional path resolver injected by the integrating client. When set,
  /// overrides the `getApplicationSupportDirectory()` defaults used for
  /// file_recv / avatars fallbacks. Lets toxee route these through `AppPaths`
  /// without tim2tox depending on toxee (X6 from the 2026-05-18 review).
  final FfiChatPathResolver? _pathResolver;

  /// Expose FFI instance for ToxAVService creation (named to avoid shadowing dart:ffi)
  Tim2ToxFfi get tim2toxFfi => _ffi;

  /// Instance ID for this service (set when registered); used for poll_text so the correct instance gets its events.
  int? _instanceId;

  /// R-08: Async login: completer completed when native login callback fires.
  Completer<({int success, int code, String message})>? _pendingLoginCompleter;
  ffi.NativeCallable<_login_callback_native>? _loginNativeCallable;

  /// Get the preferences service (for use by SDK Platform)
  ExtendedPreferencesService? get preferencesService => _prefs;

  /// Public accessor for the injected logger. Surfaces the same
  /// [LoggerService] used internally so collaborators like
  /// [Tim2ToxSdkPlatform] can route their errors through the host app's
  /// logging pipeline instead of plain print().
  LoggerService? get logger => _logger;

  /// Get the message history persistence service
  MessageHistoryPersistence get messageHistoryPersistence =>
      _messageHistoryPersistence;

  /// Get the offline message queue persistence service
  OfflineMessageQueuePersistence get offlineMessageQueuePersistence =>
      _offlineQueuePersistence;

  /// Normalizes a Tox friend/user ID to 64 characters (public key length).
  ///
  /// Preserves caller-provided casing (Tox IDs are hex; case-sensitive map
  /// lookups elsewhere depend on this), trims whitespace, and strips the
  /// nospam+checksum suffix when the input is a full 76-char Tox ID.
  /// New call sites that also want lowercase canonicalisation should use
  /// [toToxPublicKey].
  String normalizeToxId(String id) {
    final trimmed = id.trim();
    if (trimmed.length == 76) return trimmed.substring(0, 64);
    if (trimmed.length > 64) return trimmed.substring(0, 64);
    return trimmed;
  }

  final _messages = StreamController<ChatMessage>.broadcast();
  final _connectionStatus = StreamController<bool>.broadcast();
  Timer? _poller;

  /// Guards [startPolling] against being run twice in the same session.
  /// [Tim2ToxSdkPlatform.login] and toxee's [AppBootstrapCoordinator.boot]
  /// both end with `startPolling()`; without this guard the second call
  /// re-emits the current connection status (causing UI flicker) and
  /// re-creates the profile-save timer (leaking one Timer per call).
  bool _pollingStarted = false;

  /// Periodic save of tox_profile.tox to reduce data loss on crash (every 60s when running).
  Timer? _profileSaveTimer;
  // ---- X4 in-memory history cache (single source of truth) ----
  //
  // Previously this class kept its own `_historyByIdInternal` map and lazily
  // merged from MessageHistoryPersistence's cache, which let the two drift.
  // We now treat MessageHistoryPersistence as the sole owner of the in-memory
  // map and route all reads/writes through it.
  //
  // `_historyById` is kept as a private shim that returns the persistence
  // cache as a Map<String, List<ChatMessage>> view. Each contained list is
  // the persistence layer's actual mutable list (mutations are observable
  // through getHistory/cache). External callers should prefer
  // `getHistory(id)` for defensive-copy reads.
  Map<String, List<ChatMessage>> get _historyById =>
      _messageHistoryPersistence.cache;

  String _selfId = '';
  String get selfId => _selfId;

  /// Returns the 76-hex-char Tox address (self public key + nospam + checksum)
  /// for this account, or `null` when the underlying Tox instance has no
  /// identity yet (before [login] has resolved) or the FFI call fails.
  ///
  /// **Use this when persisting an account identity or showing the Tox ID to
  /// the user** — [selfId] returns the V2TIM login `userId` string passed to
  /// [login], which integrators commonly pass as a placeholder (e.g. toxee
  /// passes `'FlutterUIKitClient'`) and therefore does NOT identify the Tox
  /// account.
  ///
  /// Returning `null` (vs an empty string) forces callers to make the
  /// "missing identity" branch explicit — a silent empty value previously
  /// flowed through `Prefs.addAccount(toxId: '')` and downstream string
  /// comparisons as if it were a valid identifier.
  String? getSelfToxId() {
    final buf = pkgffi.malloc.allocate<ffi.Int8>(256);
    try {
      final n = _ffi.getSelfToxId(buf, 256);
      if (n <= 0) return null;
      final s = buf.cast<pkgffi.Utf8>().toDartString();
      return s.isEmpty ? null : s;
    } finally {
      pkgffi.malloc.free(buf);
    }
  }

  Stream<ChatMessage> get messages => _messages.stream;
  Stream<bool> get connectionStatusStream => _connectionStatus.stream;
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  final Map<String, ChatMessage> _lastByPeer = {};
  Map<String, ChatMessage> get lastMessages => _lastByPeer;
  final Map<String, int> _unreadByPeer = {};
  String? _activePeerId;
  String? get activePeerId => _activePeerId; // Expose activePeerId for FakeIM
  final Map<String, DateTime> _typingUntil = {}; // peerId -> expiry
  final Set<String> _knownGroups = {};
  Set<String> get knownGroups => Set.unmodifiable(_knownGroups);
  Set<String> _quitGroups =
      {}; // Cache of quit groups to avoid async calls in timer
  Set<String> get quitGroups => Set.unmodifiable(_quitGroups);

  /// S29 block/unblock: in-memory cache of blocked peer Tox IDs (normalized to
  /// 64-char) so the SYNCHRONOUS inbound paths can drop a blocked sender's
  /// message without an async Prefs read. Loaded at login from
  /// `_prefs.getBlackList(_selfId)` (the same account-scoped key the platform's
  /// addToBlackList writes) and refreshed by [refreshBlockedUsers] whenever the
  /// UI / L3 mutates the blacklist. Mirrors the `_quitGroups` cache pattern.
  /// NOTE: Tox has no network-layer block — this is a LOCAL receive-side hide.
  final Set<String> _blockedUsers = {};
  Set<String> get blockedUsers => Set.unmodifiable(_blockedUsers);

  /// True if [peerId] is on the local blacklist (normalized compare, so a
  /// 76-char inbound `from` matches a 64-char stored id and vice-versa).
  bool isBlocked(String peerId) {
    if (_blockedUsers.isEmpty || peerId.isEmpty) return false;
    return _blockedUsers.contains(normalizeToxId(peerId));
  }

  /// Reload the blocked-user cache from persistence. Called at the end of
  /// `login()` (selfId is known by then) and by the platform's add/delete
  /// FromBlackList so a UI / L3 block takes effect mid-session.
  Future<void> refreshBlockedUsers() async {
    if (_selfId.isEmpty) return;
    final stored = await _prefs?.getBlackList(_selfId) ?? const <String>{};
    _blockedUsers
      ..clear()
      ..addAll(stored.map(normalizeToxId));
    _logger?.log(
        '[FfiChatService] refreshBlockedUsers: ${_blockedUsers.length} blocked');
  }

  String?
      _lastCustomSender; // Track last custom message sender for reaction parsing
  String?
      _lastCustomGroupID; // Track last custom message groupID for reaction parsing
  final Set<String> _processingFileDone =
      {}; // Track files being processed to prevent duplicate handling
  final _progressCtrl = StreamController<
      ({
        int instanceId,
        String peerId,
        String? path,
        int received,
        int total,
        bool isSend,
        String? msgID
      })>.broadcast();
  Stream<
      ({
        int instanceId,
        String peerId,
        String? path,
        int received,
        int total,
        bool isSend,
        String? msgID
      })> get progressUpdates => _progressCtrl.stream;
  final Map<String, DateTime> _lastProgressEmitTime =
      {}; // peerId:path -> last emit time (throttle)
  static const _progressThrottleMs =
      200; // Min interval between progress emissions per transfer
  // P0-8: Upper bound for the "images bypass the auto-download size limit"
  // path. Images skip the user-configured threshold (photos are the
  // common case), but we still cap acceptance so a hostile peer can't push
  // an unbounded payload at us by spoofing an image extension.
  static const int _imageAutoAcceptLimitBytes = 50 * 1024 * 1024; // 50 MiB
  // P1-7: How long a receive transfer can sit without a progress update
  // before we treat it as dead and clean it up.
  // P1-7 refined (H-D): 180s + at-least-one-chunk heuristic. Tox onion
  // path rebuilds and legitimate "long pauses" can approach 60s; the old
  // window killed perfectly healthy transfers on flaky networks.
  static const Duration _fileTransferIdleTimeout = Duration(seconds: 180);
  final Map<String, (String, int)> _progressKeyCache =
      {}; // path -> (uid, fileNumber) cache for fast lookup
  DateTime? _lastPollActivity; // Track last activity time for adaptive polling
  // Avatar management
  final Map<String, String> _friendOnlineStatus =
      {}; // friendId -> 'online' | 'offline'
  String? _currentAvatarHash; // Current self avatar hash
  // File transfer management
  final _fileRequestCtrl = StreamController<
      ({
        String peerId,
        int fileNumber,
        int fileSize,
        String fileName
      })>.broadcast();
  Stream<({String peerId, int fileNumber, int fileSize, String fileName})>
      get fileRequests => _fileRequestCtrl.stream;

  // IRC callbacks
  final _ircConnectionStatusCtrl = StreamController<
      ({String channel, int status, String? message})>.broadcast();
  Stream<({String channel, int status, String? message})>
      get ircConnectionStatusStream => _ircConnectionStatusCtrl.stream;
  final _ircUserListCtrl =
      StreamController<({String channel, List<String> users})>.broadcast();
  Stream<({String channel, List<String> users})> get ircUserListStream =>
      _ircUserListCtrl.stream;
  final _ircUserJoinPartCtrl = StreamController<
      ({String channel, String nickname, bool joined})>.broadcast();
  Stream<({String channel, String nickname, bool joined})>
      get ircUserJoinPartStream => _ircUserJoinPartCtrl.stream;
  // Reaction events: (msgID, reactionID, action: 'add' or 'remove', sender)
  final _reactionCtrl = StreamController<
      ({
        String msgID,
        String reactionID,
        String action,
        String sender,
        String? groupID
      })>.broadcast();
  Stream<
      ({
        String msgID,
        String reactionID,
        String action,
        String sender,
        String? groupID
      })> get reactionEvents => _reactionCtrl.stream;
  // Avatar updated events: emits friendId when a friend's avatar is received and saved
  final _avatarUpdatedCtrl = StreamController<String>.broadcast();
  Stream<String> get avatarUpdated => _avatarUpdatedCtrl.stream;
  // Nickname updated events: emits friendId when a friend's nickname changes
  final _nicknameUpdatedCtrl = StreamController<String>.broadcast();
  Stream<String> get nicknameUpdated => _nicknameUpdatedCtrl.stream;
  final Map<(String peerId, int fileNumber), String> _pendingFileTransfers =
      {}; // Track pending file transfers
  // Track file receive progress: (peerId, fileNumber) -> (received, total, msgID, tempPath, actualPath)
  final Map<
      (String peerId, int fileNumber),
      ({
        int received,
        int total,
        String msgID,
        String? fileName,
        String? tempPath,
        String? actualPath
      })> _fileReceiveProgress = {};
  // Track msgID to fileNumber mapping for progress updates
  final Map<String, (String peerId, int fileNumber)> _msgIDToFileTransfer = {};
  // Track fileNumber to msgID mapping: (uid, fileNumber) -> msgID
  final Map<(String peerId, int fileNumber), String> _fileNumberToMsgID = {};
  // Track file path to msgID mapping for send progress correlation
  final Map<String, String> _pathToMsgID = {};
  // P1-7: per-transfer last-progress wall-clock so the poll loop can detect
  // stalled receives (no progress for [_fileTransferIdleTimeout]) and clean
  // them up instead of leaving them as zombie pending messages.
  final Map<(String peerId, int fileNumber), int> _lastProgressTs = {};
  // P1-6: set of transfers currently paused by the remote peer. Tracked so
  // the timeout sweeper doesn't mistakenly cancel a paused-but-healthy
  // transfer.
  final Set<(String peerId, int fileNumber)> _pausedTransfers = {};
  // P2-23: msgID -> outgoing file path. Replaces the previous
  // _lastSentPathByPeer (which was keyed by peer only and so could lose
  // track of concurrent sends to the same peer). The progress_send handler
  // can look up the original local path by msgID directly.
  final Map<String, String> _msgIDToSentPath = {};
  // P1-8: previously a file-level top-level variable shared across every
  // FfiChatService instance in the process (auto_tests run several). Moved
  // into the class so disposing one service doesn't blow away another's
  // mapping. Kept alongside [_msgIDToSentPath] which is the more precise
  // replacement; [_lastSentPathByPeer] remains for legacy progress_send
  // correlation that doesn't yet thread a msgID through.
  final Map<String, String> _lastSentPathByPeer = {};

  /// Poll timer callback stored so [triggerPollOnce] can run it immediately (e.g. when file message received).
  void Function()? _pollTimerCallback;

  /// P2-19: reentry guard. The poll callback awaits inside its body
  /// (acceptFileTransfer is awaited from file_request), so a second call
  /// arriving via [triggerPollOnce] while the first is still mid-flight
  /// used to interleave event drains and produce duplicate handling. This
  /// flag turns the second invocation into a no-op; the next timer tick
  /// (or the next triggerPollOnce after this one returns) will pick up
  /// any remaining work.
  bool _pollBusy = false;

  /// Reference to local scheduleNextPoll so [ _scheduleNextPoll] can schedule next poll from async callback.
  void Function()? _scheduleNextPollRef;
  // Offline message queue - use persistence service cache
  // Helper methods to access offline message queue through persistence service
  List<OfflineMessageItem> _getOfflineQueue(String peerId) {
    return _offlineQueuePersistence.getMessages(peerId);
  }

  void _addToOfflineQueue(String peerId, OfflineMessageItem item) {
    _offlineQueuePersistence.addMessage(peerId, item);
  }

  /// True if history [row] is the optimistic pending row that offline queue
  /// [item] created. Prefers the durable [OfflineMessageItem.msgID] (added
  /// 2026-05-29) — an exact identity that cannot cross two messages. Falls back
  /// to EXACT-ms timestamp equality for queue files written before the msgID
  /// field existed (msgID == null): the row and the item are stamped from one
  /// shared `now` at enqueue time (see the INVARIANT comments at the
  /// `_queueOffline*` sites), so [itemMs] (== item.timestamp in ms) pins the
  /// row. The remaining same-exact-ms ambiguity only affects those legacy
  /// no-msgID items; new items match by msgID and have no ambiguity.
  bool _offlineRowMatchesItem(
      ChatMessage row, OfflineMessageItem item, int itemMs) {
    final id = item.msgID;
    if (id != null && id.isNotEmpty) return row.msgID == id;
    return row.timestamp.millisecondsSinceEpoch == itemMs;
  }

  Future<void> _clearOfflineQueue(String peerId) async {
    print('[FfiChatService] _clearOfflineQueue: ENTRY - peerId=$peerId');
    await _offlineQueuePersistence.removeMessages(peerId);
    print(
        '[FfiChatService] _clearOfflineQueue: EXIT - Removed offline messages for peerId=$peerId');
  }

  Future<void> _clearAllOfflineQueue() async {
    await _offlineQueuePersistence.clearQueue();
  }

  /// Returns true if [messageFilePath] (e.g. temp path like /tmp/receiving_foo.txt in history)
  /// and [progressPath] (actual path from native progress) refer to the same received file.
  /// Used to match getHistory() messages (filePath: tempPath) with progressUpdates (path: actual path),
  /// for file/audio/video/avatar receive so that progress can be correlated to the correct history record.
  bool _isSameReceiveFile(String? messageFilePath, String? progressPath) {
    if (messageFilePath == null || progressPath == null) return false;
    if (messageFilePath == progressPath) return true;
    final msgBase = p.basename(messageFilePath);
    final progressBase = p.basename(progressPath);
    if (msgBase == progressBase) return true;
    // History uses temp path like <recvDir>/receiving_<msgID>_<filename>;
    // progress uses actual path (may have tox prefix). P1-2: we used to anchor
    // this on /tmp/receiving_; now anchor on basename so the comparison works
    // for any parent directory (per-account file_recv, /tmp fallback, etc.).
    if (msgBase.startsWith('receiving_')) {
      final nameAfterReceiving = msgBase.substring('receiving_'.length);
      if (progressBase == nameAfterReceiving ||
          progressBase.endsWith('_$nameAfterReceiving')) return true;
      // Strip the embedded msgID prefix (receiving_<msgID>_<filename>) if it
      // looks like one (digits_digits_hex...) — fall back to comparing just
      // the original filename portion.
      final underscoreIdx = nameAfterReceiving.indexOf('_');
      if (underscoreIdx > 0) {
        final afterMsgID = nameAfterReceiving.substring(underscoreIdx + 1);
        // afterMsgID may itself contain '_<peerUid>_filename' from inbound
        // generation, but the most precise match is filename equality at the
        // tail.
        if (progressBase == afterMsgID || progressBase.endsWith('_$afterMsgID'))
          return true;
      }
    }
    return false;
  }

  // Track group message receivers: msgID -> Set of userIDs who received it
  final Map<String, Set<String>> _messageReceivers = {};
  void setActivePeer(String? conversationId) {
    if (conversationId == null || conversationId.isEmpty) {
      _activePeerId = null;
      return;
    }
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    if (normalizedId.isEmpty) {
      _activePeerId = null;
      return;
    }
    _activePeerId = normalizedId;
    // CR-07: anchor the read barrier to the conversation's highest message
    // timestamp rather than the local wall clock, so clock drift/rollback
    // between this device and the remote peer can't inflate or zero the
    // unread count on restart.
    unawaited(
        _messageHistoryPersistence.markConversationViewed(conversationId));
    _unreadByPeer[normalizedId] = 0;
  }

  /// Mark a conversation read WITHOUT making it the active conversation.
  ///
  /// This is the "mark as read" action that does not open the conversation
  /// (e.g. the conversation-list context-menu item). It advances the
  /// persisted read barrier and flags the conversation's current non-self
  /// messages `isRead` — exactly like [setActivePeer] does on open, so the
  /// read state survives a restart — and zeroes the in-memory GROUP counter,
  /// but unlike [setActivePeer] it does NOT change [_activePeerId] (the user
  /// did not navigate into the conversation).
  ///
  /// C2C unread is derived from persistence ([getC2CUnreadCount] →
  /// [MessageHistoryPersistence.getUnreadCount]), so advancing the barrier +
  /// flagging messages read is sufficient to zero it. GROUP unread reads the
  /// in-memory `_unreadByPeer` counter, which is zeroed here.
  ///
  /// Awaitable so callers (the Platform `cleanConversationUnreadMessageCount`)
  /// can fire the conversation-list refresh only after the barrier is saved.
  Future<void> markConversationRead(String conversationId) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    if (normalizedId.isEmpty) return;
    // Zero the in-memory GROUP counter BEFORE the awaited barrier write below.
    // `markConversationViewed` can await disk I/O; if a group message arrived
    // DURING that await and we zeroed afterwards, we would clobber the
    // freshly-incremented unread (the group inbound path bumps `_unreadByPeer`
    // synchronously). Zeroing first means an inbound during the await leaves
    // the counter at the new (correct) value, not 0.
    if (_unreadByPeer.containsKey(normalizedId)) {
      _unreadByPeer[normalizedId] = 0;
    }
    await _messageHistoryPersistence.markConversationViewed(conversationId);
  }

  /// Unread count for the product sidebar / conversation list.
  ///
  /// #27 fix: C2C conversations route to the PATH-INDEPENDENT
  /// [getC2CUnreadCount] (persistence + lastView barrier) so the hybrid
  /// under-count is fixed for the product too — the in-memory `_unreadByPeer`
  /// counter is only bumped by FfiChatService's own inbound path, so when the
  /// binary-replacement hook persists an inbound C2C message first (and the
  /// poll path dedups it out before the bump) the counter under-counts.
  ///
  /// GROUPS stay on the in-memory counter (`incrementGroupUnread`): native
  /// group inbound increments `_unreadByPeer[gid]` directly and there is no
  /// equivalent persisted read-barrier reconciliation for groups, so deriving
  /// group unread from persistence would regress group badges (codex). Group
  /// ids are detected via the authoritative in-memory `_knownGroups` /
  /// `_quitGroups` sets (a quit group still isn't a C2C peer).
  int getUnreadOf(String peerId) {
    final norm = ConversationIdUtils.normalize(peerId);
    if (_knownGroups.contains(norm) || _quitGroups.contains(norm)) {
      // codex: read the NORMALIZED id (callers may pass a raw/prefixed gid),
      // falling back to the raw key for any pre-normalization writer.
      return _unreadByPeer[norm] ?? _unreadByPeer[peerId] ?? 0;
    }
    return getC2CUnreadCount(peerId);
  }

  /// Path-independent C2C unread count, read from persisted history + the
  /// lastView barrier ([MessageHistoryPersistence.getUnreadCount]) — the single
  /// store BOTH hybrid paths feed — rather than the in-memory `_unreadByPeer`
  /// counter, which only FfiChatService's own inbound path bumps. When the
  /// binary-replacement hook persists an inbound message first (and the poll
  /// path then dedups it out before the increment runs), the in-memory counter
  /// UNDER-counts; this reads the deduped ground truth instead.
  ///
  /// C2C-SCOPED ON PURPOSE: [getUnreadOf] (the product sidebar/conversation-list
  /// path) is intentionally left on the in-memory counter so native GROUP
  /// unread (`incrementGroupUnread`) is not regressed — codex flagged that
  /// switching the product path wholesale would drop group badges. Fixing the
  /// product C2C under-count without regressing groups is a separate tracked
  /// follow-up. This helper is used by the L3 debug/test surface (`l3_dump_state`
  /// / `l3_mark_read`), which is C2C-only.
  ///
  /// The active conversation reads 0 (mirrors [setActivePeer]'s synchronous
  /// zero) so an open/`l3_mark_read` reflects read immediately without waiting
  /// on the unawaited barrier-save round-trip.
  int getC2CUnreadCount(String peerId) {
    final normalizedId = ConversationIdUtils.normalize(peerId);
    if (_activePeerId == normalizedId) return 0;
    return _messageHistoryPersistence.getUnreadCount(normalizedId);
  }

  /// Refresh the in-memory last-message cache for a conversation from persisted history.
  /// This is used when a message is written through a native/UI path that bypasses
  /// [_appendHistory] but should still update conversation preview state immediately.
  void refreshConversationCacheFromHistory(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final history = getHistory(normalizedId);
    if (history.isEmpty) return;

    final sortedHistory = List<ChatMessage>.from(history)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    _lastByPeer[normalizedId] = sortedHistory.first;
  }

  /// Increment unread count for a group. Used when a group message is received via
  /// the native path (OnRecvNewMessage) so sidebar and conversation list show unread.
  void incrementGroupUnread(String groupId) {
    if (groupId.isEmpty) return;
    if (_quitGroups.contains(groupId)) return;
    if (_activePeerId == groupId) {
      _unreadByPeer[groupId] = 0;
    } else {
      _unreadByPeer.update(groupId, (v) => v + 1, ifAbsent: () => 1);
    }
  }

  bool isTyping(String peerId) {
    final t = _typingUntil[peerId];
    if (t == null) return false;
    if (DateTime.now().isAfter(t)) return false;
    return true;
  }

  Future<void> _persistKnownGroups() async {
    await _prefs?.setGroups(_knownGroups);
    // Synchronize to C++ layer for CreateGroup to use when generating new group IDs
    _syncKnownGroupsToNative();
  }

  // Synchronize knownGroups to C++ layer
  void _syncKnownGroupsToNative() {
    try {
      // Convert Set to newline-separated string
      final groupsList = _knownGroups.toList()..sort(); // Sort for consistency
      final groupsStr = groupsList.join('\n');
      if (groupsStr.isNotEmpty) {
        final groupsStrNative = groupsStr.toNativeUtf8();
        _ffi.updateKnownGroupsNative(
            _ffi.getCurrentInstanceId(), groupsStrNative);
        pkgffi.malloc.free(groupsStrNative);
      } else {
        // Empty string for empty list
        final emptyStr = ''.toNativeUtf8();
        _ffi.updateKnownGroupsNative(_ffi.getCurrentInstanceId(), emptyStr);
        pkgffi.malloc.free(emptyStr);
      }
    } catch (e) {
      // Ignore errors in synchronization
    }
  }

  /// Discover conferences restored from Tox savedata (e.g. after profile import) and assign group_ids.
  /// Adds each to _knownGroups with type "conference" in C++ so RejoinKnownGroups can match them.
  ///
  /// IMPORTANT: This method only creates new group IDs for conferences that are NOT already tracked
  /// in _knownGroups. On a normal restart, conferences in the Tox savedata are the same ones from
  /// the previous session — they already have IDs in _knownGroups (loaded from prefs).
  /// Without this deduplication, each restart would add N phantom group IDs for the same N conferences.
  Future<void> _discoverRestoredConferences() async {
    try {
      final instanceId = _ffi.getCurrentInstanceId();
      final count = _ffi.getRestoredConferenceCountNative(instanceId);
      if (count <= 0) return;

      // Count existing tox_conf_* entries already tracked in _knownGroups
      final confPattern = RegExp(r'^tox_conf_(\d+)$');
      final existingConfIds =
          _knownGroups.where((id) => confPattern.hasMatch(id)).toList();
      final existingCount = existingConfIds.length;

      // Cleanup: if we have MORE tracked conferences than actual restored ones,
      // remove the excess phantom entries (keep lowest-numbered ones which were the originals).
      if (existingCount > count) {
        existingConfIds.sort((a, b) {
          final numA =
              int.tryParse(confPattern.firstMatch(a)?.group(1) ?? '999') ?? 999;
          final numB =
              int.tryParse(confPattern.firstMatch(b)?.group(1) ?? '999') ?? 999;
          return numA.compareTo(numB);
        });
        final toRemove = existingConfIds.sublist(count);
        _knownGroups.removeAll(toRemove);
        if (_prefs != null) {
          await _prefs!.setGroups(_knownGroups);
        }
        print(
            '[FfiChatService] _discoverRestoredConferences: Cleaned up ${toRemove.length} phantom conference entries: $toRemove');
      }

      // Only create new IDs for conferences not yet tracked
      final trackedCount =
          _knownGroups.where((id) => confPattern.hasMatch(id)).length;
      final needed = count - trackedCount;
      if (needed <= 0) {
        // All conferences already tracked, just ensure C++ types are set
        for (final id in _knownGroups.where((id) => confPattern.hasMatch(id))) {
          final groupIdPtr = id.toNativeUtf8();
          final typePtr = 'conference'.toNativeUtf8();
          try {
            _ffi.setGroupTypeNative(instanceId, groupIdPtr, typePtr);
          } finally {
            pkgffi.malloc.free(groupIdPtr);
            pkgffi.malloc.free(typePtr);
          }
        }
        return;
      }

      final ptr = pkgffi.calloc<ffi.Uint32>(count);
      try {
        final written =
            _ffi.getRestoredConferenceListNative(instanceId, ptr, count);
        if (written <= 0) return;
        // Generate unique group_ids only for the NEW (untracked) conferences
        int startIndex = 0;
        for (final id in _knownGroups) {
          final m = confPattern.firstMatch(id);
          if (m != null) {
            final k = int.tryParse(m.group(1) ?? '') ?? -1;
            if (k >= 0 && k >= startIndex) startIndex = k + 1;
          }
        }
        final actualNeeded = needed.clamp(0, written);
        for (int i = 0; i < actualNeeded; i++) {
          final groupId = 'tox_conf_${startIndex + i}';
          _knownGroups.add(groupId);
          final groupIdPtr = groupId.toNativeUtf8();
          final typePtr = 'conference'.toNativeUtf8();
          try {
            _ffi.setGroupTypeNative(instanceId, groupIdPtr, typePtr);
          } finally {
            pkgffi.malloc.free(groupIdPtr);
            pkgffi.malloc.free(typePtr);
          }
        }
        // Also set type for existing conference entries
        for (final id in _knownGroups.where((id) => confPattern.hasMatch(id))) {
          final groupIdPtr = id.toNativeUtf8();
          final typePtr = 'conference'.toNativeUtf8();
          try {
            _ffi.setGroupTypeNative(instanceId, groupIdPtr, typePtr);
          } finally {
            pkgffi.malloc.free(groupIdPtr);
            pkgffi.malloc.free(typePtr);
          }
        }
        if (actualNeeded > 0 && _prefs != null) {
          await _prefs!.setGroups(_knownGroups);
        }
      } finally {
        pkgffi.calloc.free(ptr);
      }
    } catch (e) {
      // Non-fatal: skip discovery on error (e.g. FFI not ready)
    }
  }

  /// Sync group conference IDs from persistence to C++ layer
  /// This is called on startup to rebuild the mapping after restart
  Future<void> _syncGroupChatIdsToNative() async {
    if (_prefs == null) return;

    try {
      for (final groupId in _knownGroups) {
        try {
          final chatId = await _prefs!.getGroupChatId(groupId);
          if (chatId != null && chatId.isNotEmpty) {
            // Sync to C++ layer
            final groupIdNative = groupId.toNativeUtf8();
            final chatIdNative = chatId.toNativeUtf8();
            _ffi.setGroupChatIdNative(
                _ffi.getCurrentInstanceId(), groupIdNative, chatIdNative);
            pkgffi.malloc.free(groupIdNative);
            pkgffi.malloc.free(chatIdNative);
          }
        } catch (e) {
          // Ignore errors for individual groups
        }
      }
    } catch (e) {
      // Ignore sync errors
    }
  }

  // Save message history for a conversation (delegate to persistence service)
  Future<void> _saveHistory(String id) async {
    final list = _messageHistoryPersistence.getCachedList(id);
    if (list != null && list.isNotEmpty) {
      await _messageHistoryPersistence.saveHistory(id, list);
    }
  }

  // Load message history for a conversation (delegate to persistence service)
  Future<void> _loadHistory(String id) async {
    final quitGroups = _quitGroups.toSet();
    final messages = await _messageHistoryPersistence.loadHistory(id,
        quitGroups: quitGroups);
    if (messages.isNotEmpty) {
      // Persistence already owns the in-memory list; we only need to refresh
      // conversation-preview state here.
      messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final lastMsg = messages.first;
      _lastByPeer[id] = lastMsg;
    }
  }

  // Load all message histories (called on init) - delegate to persistence service
  Future<void> _loadAllHistories() async {
    try {
      final quitGroups = _quitGroups.toSet();
      final allHistories = await _messageHistoryPersistence.loadAllHistories(
          quitGroups: quitGroups);

      // Persistence already owns the in-memory map (each `loadHistory` call
      // inside `loadAllHistories` populates `_historyById` directly); we only
      // need to refresh conversation-preview state here.

      // Update lastMessages with the most recent message from each history
      for (final entry in allHistories.entries) {
        final conversationId = entry.key;
        final messages = entry.value;
        if (messages.isNotEmpty) {
          // Sort messages by timestamp to get the latest one
          messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
          final lastMsg = messages.first;
          _lastByPeer[conversationId] = lastMsg;
        }
      }
    } catch (e) {
      // Silently handle errors
    }
  }

  // Restore unread counts from message history on startup
  Future<void> _restoreUnreadCounts() async {
    try {
      // Clear existing unread counts
      _unreadByPeer.clear();

      // Get all conversation IDs from history
      final conversationIds = _messageHistoryPersistence.getConversationIds();

      // Calculate unread count for each conversation
      for (final conversationId in conversationIds) {
        final unreadCount =
            _messageHistoryPersistence.getUnreadCount(conversationId);
        if (unreadCount > 0) {
          _unreadByPeer[conversationId] = unreadCount;
        }
      }
    } catch (e) {
      // Silently handle errors to avoid breaking startup
    }
  }

  Future<void> init({String? profileDirectory}) async {
    if (profileDirectory != null && profileDirectory.isNotEmpty) {
      final pathPtr = profileDirectory.toNativeUtf8();
      try {
        final result = _ffi.initWithPath(pathPtr);
        if (result != 1) {
          throw Exception('initWithPath failed');
        }
      } finally {
        pkgffi.malloc.free(pathPtr);
      }
    } else {
      _ffi.init();
    }
    // Set file receive directory: per-account when _fileRecvPath is set, else
    // ask the injected resolver (X6), else fall back to app support file_recv.
    try {
      final String recvPath;
      if (_fileRecvPath != null && _fileRecvPath!.isNotEmpty) {
        recvPath = _fileRecvPath!;
      } else if (_pathResolver != null) {
        recvPath = _assertResolverPath(
          await _pathResolver!.resolveFileRecvDirectory(),
          'resolveFileRecvDirectory',
        );
      } else {
        final appDir = await getApplicationSupportDirectory();
        recvPath = '${appDir.path}/file_recv';
      }
      final recvDir = Directory(recvPath);
      if (!await recvDir.exists()) {
        await recvDir.create(recursive: true);
      }
      // P1-2: remember the resolved dir so the pending "receiving_*" temp
      // path lives in the same per-account location as the actual file_recv
      // output, instead of being hard-coded to `/tmp`.
      _fileRecvDir = recvDir.path;
      final dirPath = recvDir.path.toNativeUtf8();
      final result = _ffi.setFileRecvDir(dirPath);
      pkgffi.malloc.free(dirPath);
      if (result == 1) {
      } else {}
    } catch (e) {}
    // register callback mode (preferred)
    _globalService = this;
    _ffi.setCallback(_nativeCbPtr, ffi.Pointer.fromAddress(0));

    // Register IRC callbacks if library is loaded
    if (_ffi.ircIsLibraryLoaded() == 1) {
      _ffi.ircSetConnectionStatusCallback(
          _ircConnectionStatusCbPtr, ffi.Pointer.fromAddress(0));
      _ffi.ircSetUserListCallback(
          _ircUserListCbPtr, ffi.Pointer.fromAddress(0));
      _ffi.ircSetUserJoinPartCallback(
          _ircUserJoinPartCbPtr, ffi.Pointer.fromAddress(0));
    }
    final savedGroups = await _prefs?.getGroups() ?? <String>{};
    final quitGroups = await _prefs?.getQuitGroups() ?? <String>{};
    // Only load groups that are not in quit list
    _knownGroups
      ..clear()
      ..addAll(savedGroups.where((g) => !quitGroups.contains(g)));

    // Always discover conferences restored from Tox savedata (e.g. after load/restart).
    // This ensures conference-only accounts see their groups in the session list even when
    // Prefs had 0 groups (e.g. first load or conferences were never persisted).
    await _discoverRestoredConferences();

    // Synchronize to C++ layer after loading from persistence
    _syncKnownGroupsToNative();

    // Load and sync group conference IDs from persistence to C++ layer
    // This is critical for rebuilding the mapping after restart
    await _syncGroupChatIdsToNative();

    // CRITICAL: Rejoin all known groups using stored chat_id (c-toxcore recommended approach)
    // This ensures groups are properly restored after client restart, even if they're not in savedata
    // The onGroupSelfJoin callback will be triggered for each successfully joined group to rebuild mappings
    // NOTE: We should wait for Tox connection to be established before rejoining groups
    // to avoid tox_group_join failures. The C++ layer will trigger RejoinKnownGroups()
    // automatically when connection is established in HandleSelfConnectionStatus().
    // However, if connection is already established, we can trigger it immediately.
    try {
      final connectionStatus = _ffi.getSelfConnectionStatus();
      print(
          '[FfiChatService] init: Current connection status: $connectionStatus (0=NONE, 1=TCP, 2=UDP)');
      if (connectionStatus == 1 || connectionStatus == 2) {
        // Connection already established, trigger rejoin immediately
        print(
            '[FfiChatService] init: Connection already established, triggering RejoinKnownGroups immediately');
        final rejoinResult = _ffi.rejoinKnownGroupsNative();
        print(
            '[FfiChatService] init: RejoinKnownGroups returned: $rejoinResult');
      } else {
        // Connection not established yet, wait for HandleSelfConnectionStatus to trigger rejoin
        print(
            '[FfiChatService] init: Connection not established yet, will rejoin groups when connection is established');
      }
    } catch (e) {
      print(
          '[FfiChatService] init: Error checking connection status or calling rejoinKnownGroupsNative: $e');
    }

    // Load message histories - wait for completion to ensure history is available for queries
    // This is important for Platform interface mode where history queries happen immediately
    // In binary replacement mode, C++ layer returns empty list, so Platform interface is used for history
    await _loadAllHistories();

    // Restore unread counts from message history
    await _restoreUnreadCounts();

    // Cancel any pending file transfers from previous session
    // This prevents chat window from showing "receiving" status for incomplete transfers
    await _cancelPendingFileTransfers();
    // Load current avatar hash
    _currentAvatarHash = await _prefs?.getSelfAvatarHash();
    // Load offline message queue
    await _loadOfflineQueue();
    // Load and apply saved bootstrap node if exists
    await _loadAndApplySavedBootstrapNode();
  }

  Future<void> _loadAndApplySavedBootstrapNode() async {
    final mode = await _prefs?.getBootstrapNodeMode();

    if (mode == 'manual') {
      // Manual mode: use saved node if exists
      final node = await _prefs?.getCurrentBootstrapNode();
      if (node != null) {
        // Add the saved bootstrap node
        await addBootstrapNode(node.host, node.port, node.pubkey);
      }
    } else {
      // Auto mode: use bootstrap service to get nodes
      try {
        // Try to get a node from BootstrapService if available
        final host = await _bootstrap?.getBootstrapHost();
        final port = await _bootstrap?.getBootstrapPort();
        final pubkey = await _bootstrap?.getBootstrapPublicKey();
        if (host != null && port != null && pubkey != null) {
          await addBootstrapNode(host, port, pubkey);
        } else {
          // If no node from service, try to use saved node as fallback
          final node = await _prefs?.getCurrentBootstrapNode();
          if (node != null) {
            await addBootstrapNode(node.host, node.port, node.pubkey);
          }
          // Note: If no node is available, client should fetch and set nodes before calling init()
          // This ensures first-time startup has bootstrap nodes configured
        }
      } catch (e) {
        // If fetch fails, try to use saved node as fallback
        final node = await _prefs?.getCurrentBootstrapNode();
        if (node != null) {
          await addBootstrapNode(node.host, node.port, node.pubkey);
        }
        _logger?.log('[FfiChatService] Failed to load bootstrap node: $e');
      }
    }
  }

  Future<void> login({required String userId, required String userSig}) async {
    _pendingLoginCompleter =
        Completer<({int success, int code, String message})>();
    _loginNativeCallable ??=
        ffi.NativeCallable<_login_callback_native>.listener(_onLoginCallback);
    final instanceId = _ffi.getCurrentInstanceId();
    final puid = userId.toNativeUtf8();
    final psig = userSig.toNativeUtf8();
    final r = _ffi.loginAsync(instanceId, puid, psig,
        _loginNativeCallable!.nativeFunction, ffi.Pointer.fromAddress(0));
    pkgffi.malloc.free(puid);
    pkgffi.malloc.free(psig);
    if (r != 1) {
      _pendingLoginCompleter!.complete(
          (success: 0, code: -1, message: 'login_async did not start'));
    }
    final result = await _pendingLoginCompleter!.future;
    if (result.success != 1) {
      throw Exception('Login failed: ${result.message} (code ${result.code})');
    }
    // fetch self id
    final buf = pkgffi.malloc.allocate<ffi.Int8>(256);
    final n = _ffi.getLoginUser(buf, 256);
    if (n > 0) {
      _selfId = buf.cast<pkgffi.Utf8>().toDartString();
    }
    pkgffi.malloc.free(buf);
    // S29: hydrate the blocked-user cache now that selfId is known (the
    // blacklist key is account-scoped by full Tox ID). Best-effort.
    await refreshBlockedUsers();
    // Connection status will be updated via OnConnectSuccess/OnConnectFailed events
    final currentStatus = _ffi.getSelfConnectionStatus();
    if (currentStatus != 0) {
      _isConnected = true;
      _connectionStatus.add(true);
    } else {
      _isConnected = false;
      _connectionStatus.add(false);
    }
  }

  void _onLoginCallback(int success, int errorCode,
      ffi.Pointer<pkgffi.Utf8> errorMessage, ffi.Pointer<ffi.Void> userData) {
    final comp = _pendingLoginCompleter;
    _pendingLoginCompleter = null;
    if (comp != null && !comp.isCompleted) {
      String msg = '';
      if (errorMessage.address != 0) msg = errorMessage.toDartString();
      comp.complete((success: success, code: errorCode, message: msg));
    }
  }

  // Pending addFriend completers, keyed by the user_id the caller passed in
  // (C++ echoes it back via the `friendAddResult` callback's `user_id` field).
  // Using a List per key so concurrent retries with the same ID don't lose
  // the older Completer. A 30s safety timeout cleans up stale entries if the
  // native callback is ever dropped — the Future then resolves with
  // dispatched=true + resultCode=-2 + "timed out".
  final Map<String, List<Completer<AddFriendResult>>> _pendingAddFriend = {};

  /// Sends a friend request and returns when the V2TIM async result is in.
  ///
  /// Resolves with [AddFriendResult]; the Future never throws (failures are
  /// represented by [AddFriendResult.isSuccess] == false). Callers should
  /// check [AddFriendResult.isSuccess] before treating the request as sent.
  Future<AddFriendResult> addFriend(String serverId,
      {String? requestMessage}) async {
    final message = (requestMessage != null && requestMessage.trim().isNotEmpty)
        ? requestMessage.trim()
        : 'Hello from Flutter UIKit client';
    final psv = serverId.toNativeUtf8();
    final pword = message.toNativeUtf8();
    final completer = Completer<AddFriendResult>();
    _pendingAddFriend.putIfAbsent(serverId, () => []).add(completer);
    int result;
    try {
      result = _ffi.addFriend(psv, pword);
    } catch (e) {
      _pendingAddFriend[serverId]?.remove(completer);
      if (_pendingAddFriend[serverId]?.isEmpty ?? false) {
        _pendingAddFriend.remove(serverId);
      }
      pkgffi.malloc.free(psv);
      pkgffi.malloc.free(pword);
      return AddFriendResult(
        resultCode: -1,
        userId: serverId,
        resultInfo: 'addFriend dispatch threw: $e',
        dispatched: false,
      );
    } finally {
      pkgffi.malloc.free(psv);
      pkgffi.malloc.free(pword);
    }
    if (result == 0) {
      // Sync-dispatch failure (SDK not initialized, etc.). C++ also emits a
      // friendAddResult callback in this case, but don't rely on it — return
      // immediately. Clean up our completer registration so the (eventual)
      // callback doesn't double-complete.
      _pendingAddFriend[serverId]?.remove(completer);
      if (_pendingAddFriend[serverId]?.isEmpty ?? false) {
        _pendingAddFriend.remove(serverId);
      }
      return AddFriendResult(
        resultCode: -1,
        userId: serverId,
        resultInfo: 'addFriend dispatch returned 0',
        dispatched: false,
      );
    }
    return completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
      _pendingAddFriend[serverId]?.remove(completer);
      if (_pendingAddFriend[serverId]?.isEmpty ?? false) {
        _pendingAddFriend.remove(serverId);
      }
      return AddFriendResult(
        resultCode: -2,
        userId: serverId,
        resultInfo: 'addFriend timed out waiting for native result',
        dispatched: true,
      );
    });
  }

  /// Called by [Tim2ToxSdkPlatform] when a `friendAddResult` native callback
  /// arrives. Completes the oldest pending [Completer] for [userId].
  void handleFriendAddResultCallback({
    required String userId,
    required int resultCode,
    required String resultInfo,
  }) {
    final pending = _pendingAddFriend[userId];
    if (pending == null || pending.isEmpty) {
      _logger?.log(
          '[FfiChatService] friendAddResult callback for user_id=$userId with no pending completer (code=$resultCode)');
      return;
    }
    final completer = pending.removeAt(0);
    if (pending.isEmpty) {
      _pendingAddFriend.remove(userId);
    }
    if (!completer.isCompleted) {
      completer.complete(AddFriendResult(
        resultCode: resultCode,
        userId: userId,
        resultInfo: resultInfo,
        dispatched: true,
      ));
    }
  }

  /// Save tox profile to disk now. Call on app pause/lifecycle or use periodic save.
  void saveToxProfileNow() {
    try {
      _ffi.saveToxProfile();
    } catch (e) {
      _logger?.log('[FfiChatService] saveToxProfileNow error: $e');
    }
  }

  Future<void> startPolling() async {
    if (_pollingStarted) {
      _logger?.log(
          '[FfiChatService] startPolling: already started, ignoring duplicate call');
      return;
    }
    _pollingStarted = true;
    _logger?.log('[FfiChatService] ========== startPolling called ==========');
    _logger?.log(
        '[FfiChatService] startPolling: Service instance type: ${runtimeType}');
    _logger?.log(
        '[FfiChatService] startPolling: _ffi instance: ${_ffi.runtimeType}');
    _poller?.cancel();
    _profileSaveTimer?.cancel();
    // Periodic save of tox profile to reduce data loss on unexpected exit (e.g. crash, force quit)
    _profileSaveTimer =
        Timer.periodic(const Duration(seconds: 60), (_) => saveToxProfileNow());
    // Send initial connection status
    _connectionStatus.add(_isConnected);
    _lastPollActivity = DateTime.now();
    void scheduleNextPoll() {
      _poller?.cancel();
      // Adaptive interval: shorten during active file transfers, when shared (no _instanceId), or when test instances are registered
      final hasActiveFileTransfer =
          _fileReceiveProgress.isNotEmpty || _pendingFileTransfers.isNotEmpty;
      final hasKnownInstances = synchronized(
          _instanceServicesLock, () => _knownInstanceIds.isNotEmpty);
      final timeSinceActivity = _lastPollActivity != null
          ? DateTime.now().difference(_lastPollActivity!)
          : const Duration(seconds: 10);
      final pollInterval = hasActiveFileTransfer
          ? const Duration(
              milliseconds: 50) // Very frequent polling during file transfer
          : (hasKnownInstances || _instanceId == null)
              ? const Duration(
                  milliseconds:
                      50) // Test/multi-instance: poll very often so file_request is consumed promptly
              : (timeSinceActivity < const Duration(seconds: 2)
                  ? const Duration(milliseconds: 200)
                  : const Duration(milliseconds: 1000));
      _pollTimerCallback = () async {
        // P2-19: drop overlapping invocations. See _pollBusy doc.
        if (_pollBusy) {
          return;
        }
        _pollBusy = true;
        try {
          // Call toxav_iterate if AV is initialized
          try {
            _ffi.avIterate(_ffi.getCurrentInstanceId());
          } catch (e) {
            // AV not initialized yet, ignore
          }

          var bufCap = 4096;
          var buf = pkgffi.malloc.allocate<ffi.Int8>(bufCap);
          // Poll broadcast (0), registered service instances, and known instance IDs (e.g. test nodes)
          // so that file_request:2:... is consumed when only instance 1 has a service registered.
          final idsToPoll = [
            0,
            ...synchronized(_instanceServicesLock, () {
              final keys = List<int>.from(
                  {..._instanceServices.keys, ..._knownInstanceIds});
              keys.sort();
              return keys;
            }),
          ];
          // Prefer receiver instance first (e.g. 2 before 1) so file_request:2 is consumed promptly in file transfer tests.
          final nonZero = idsToPoll.where((id) => id != 0).toList();
          final pollOrder = idsToPoll.length > 1
              ? (hasKnownInstances && nonZero.length > 1
                  ? [
                      ...nonZero..sort((a, b) => b.compareTo(a)),
                      0
                    ] // [2, 1, 0] so Bob (receiver) gets file_request first
                  : [...nonZero, 0])
              : idsToPoll;
          // Batch drain: process up to 200 events per poll cycle to avoid queue buildup.
          // Without this, each poll cycle processes ONE event at 50ms intervals, so ~1779 progress
          // chunks for a 2.4MB file would take 1779×50ms = 89 seconds to drain.
          for (int _batchIdx = 0; _batchIdx < 200; _batchIdx++) {
            int n = 0;
            for (final id in pollOrder) {
              n = _ffi.pollText(id, buf, bufCap);
              // Negative => the front event is larger than the buffer. The
              // event was left queued (not dropped/truncated), so grow to the
              // required size and retry the same id. Terminates after one
              // retry since the new capacity is the exact size requested.
              while (n < 0) {
                pkgffi.malloc.free(buf);
                bufCap = -n;
                buf = pkgffi.malloc.allocate<ffi.Int8>(bufCap);
                n = _ffi.pollText(id, buf, bufCap);
              }
              if (n > 0) break;
            }
            if (n <= 0) break; // No more events in queue
            if (n > 0) {
              _lastPollActivity = DateTime.now(); // Mark activity
              String s;
              try {
                s = buf.cast<pkgffi.Utf8>().toDartString();
                // Debug: log important events (skip frequent progress_recv to reduce log spam)
                if (s.startsWith('file_done:')) {
                  _logger?.log(
                      '[FfiChatService] Polled file_done event (length=$n): $s');
                } else if (s.startsWith('file_request:')) {
                  // Log file_request events for debugging - CRITICAL for file receiving
                  _logger?.log(
                      '[FfiChatService] Polled file_request event (length=$n): $s');
                } else if (s.startsWith('progress_recv:')) {
                  // Skip logging progress_recv events - too frequent during file transfer
                } else if (s.startsWith('c2c:') || s.startsWith('gtext:')) {
                  // Log text messages to verify polling is working
                  _logger?.log(
                      '[FfiChatService] Polled message event (length=$n): $s');
                } else if (s.startsWith('conn:')) {
                  // Log connection events
                  _logger?.log(
                      '[FfiChatService] Polled conn event (length=$n): $s');
                } else {
                  // Log other events to see what's in the queue
                  _logger?.log(
                      '[FfiChatService] Polled other event (length=$n): $s');
                }
              } catch (e) {
                // Handle UTF-8 decoding errors gracefully
                // This can happen if file paths contain non-UTF-8 characters or if binary data is accidentally in the text queue
                // Try to read as bytes and convert with error handling
                try {
                  final bytes = buf.asTypedList(n);
                  // Check if this looks like a text event (starts with known prefixes)
                  final firstBytes = bytes.take(20).toList();
                  final firstChars = String.fromCharCodes(firstBytes.where(
                      (b) =>
                          b >= 32 && b <= 126 || b == 9 || b == 10 || b == 13));

                  // If it starts with a known event prefix, try to recover.
                  // The allowlist must cover EVERY prefix the dispatcher below handles,
                  // otherwise a genuine event carrying a non-UTF-8 byte (e.g. a TEXT
                  // message with an invalid/mid-codepoint-truncated byte) is silently
                  // dropped instead of recovered with replacement chars. Handled
                  // prefixes: conn:, typing:, c2c:, c2cbin:, gtext:, gcustom:,
                  // progress_recv:, progress_send:, file_request:, file_done: — plus
                  // msg:/nickname_/status_ kept from historic events.
                  // 'c2c:' also matches 'c2cbin:'; 'file_' matches file_request/file_done;
                  // 'progress_' matches progress_recv/progress_send.
                  if (firstChars.startsWith('conn:') ||
                      firstChars.startsWith('typing:') ||
                      firstChars.startsWith('c2c:') ||
                      firstChars.startsWith('gtext:') ||
                      firstChars.startsWith('file_') ||
                      firstChars.startsWith('msg:') ||
                      firstChars.startsWith('nickname_') ||
                      firstChars.startsWith('status_') ||
                      firstChars.startsWith('progress_') ||
                      firstChars.startsWith('gcustom:')) {
                    // Try to decode with replacement characters for invalid bytes
                    s = utf8.decode(bytes, allowMalformed: true);
                    // Debug: log file_done events even if they had decoding issues
                    if (s.startsWith('file_done:')) {
                      _logger?.log(
                          '[FfiChatService] Polled file_done event (after recovery): $s');
                    }
                  } else {
                    // P0-C2: log unrecognized payloads instead of silently
                    // dropping them. Used to be a silent return which masked
                    // FFI boundary corruption / new event types added on the
                    // C++ side that Dart didn't yet recognise.
                    final hexPreview = bytes
                        .take(64)
                        .map((b) => b.toRadixString(16).padLeft(2, '0'))
                        .join();
                    _logger?.log(
                        '[FfiChatService] Polled non-text payload, dropping (n=$n bytes=0x$hexPreview, asciiHead=${firstChars.substring(0, firstChars.length.clamp(0, 32))})');
                    pkgffi.malloc.free(buf);
                    _scheduleNextPoll();
                    return;
                  }
                } catch (e2) {
                  // P0-C2: log decode-recovery failures rather than swallowing.
                  final hexPreview = buf
                      .asTypedList(n)
                      .take(64)
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join();
                  _logger?.log(
                      '[FfiChatService] Polled event UTF-8 decode failed even with recovery (n=$n bytes=0x$hexPreview): $e $e2');
                  pkgffi.malloc.free(buf);
                  _scheduleNextPoll();
                  return;
                }
              }
              // Expected events via polling queue
              if (s.startsWith('conn:')) {
                // conn:success or conn:failed
                if (s == 'conn:success') {
                  final wasOffline = !_isConnected;
                  _isConnected = true;
                  _connectionStatus.add(true);
                  // When connected, send avatar to all online friends
                  unawaited(_sendAvatarToAllFriendsOnConnect());
                  // P0-C1: drain any group messages queued while offline.
                  if (wasOffline) {
                    unawaited(_drainAllPendingGroupMessages());
                  }
                } else if (s == 'conn:failed') {
                  _isConnected = false;
                  _connectionStatus.add(false);
                }
              } else if (s.startsWith('typing:')) {
                final parts = s.split(':');
                if (parts.length >= 3) {
                  final from = parts[1];
                  final on = parts[2] == '1';
                  if (on) {
                    _typingUntil[from] =
                        DateTime.now().add(const Duration(seconds: 3));
                  } else {
                    _typingUntil.remove(from);
                  }
                  // Don't add empty message for typing indicator - UI will show it separately
                }
              } else if (s.startsWith('c2c:')) {
                final idx = s.indexOf(':', 4);
                if (idx > 4 && idx + 1 < s.length) {
                  final from = s.substring(4, idx);
                  final text = s.substring(idx + 1);
                  // Normalize friend ID to ensure consistent storage and retrieval
                  final normalizedFrom =
                      from.length > 64 ? _normalizeFriendId(from) : from;
                  // Generate msgID for receipt tracking
                  final timestamp = DateTime.now().millisecondsSinceEpoch;
                  final sequence = _msgIDSequence++;
                  final msgID = '${timestamp}_${sequence}_${from}';
                  final msg = ChatMessage(
                    text: text,
                    fromUserId: from,
                    isSelf: from == _selfId,
                    timestamp: DateTime.now(),
                    msgID: msgID,
                  );
                  // S29: drop an inbound C2C message from a BLOCKED sender
                  // before ANY side-effect — not just persistence, but the
                  // unread bump, last-message preview, the `_messages` UI stream,
                  // and the delivery receipt (which would leak activity to a
                  // blocked peer). The _appendHistory guard is defense-in-depth;
                  // this call-site guard is the real suppression point.
                  if (from != _selfId && isBlocked(normalizedFrom)) {
                    _logger?.log(
                        '[FfiChatService] c2c: dropping blocked sender '
                        '${normalizedFrom.substring(0, normalizedFrom.length.clamp(0, 8))}..');
                  } else {
                    _lastByPeer[normalizedFrom] = msg;
                    if (_activePeerId != normalizedFrom && from != _selfId) {
                      _unreadByPeer.update(normalizedFrom, (v) => v + 1,
                          ifAbsent: () => 1);
                    }
                    _appendHistory(normalizedFrom, msg);
                    _messages.add(msg);
                    // Auto-send received receipt for received messages (not self-sent)
                    // Note: reaction messages are sent via custom messages and should not trigger receipts
                    // Regular text messages will trigger receipts here
                    if (!msg.isSelf && !_isReactionMessage(text)) {
                      unawaited(_sendReceipt(from, msgID, 'received'));
                    }
                  }
                }
              } else if (s.startsWith('gtext:')) {
                // gtext:<groupID>|<sender>:<text>
                final headerEnd = s.indexOf(':', 6);
                if (headerEnd > 6) {
                  final header = s.substring(6, headerEnd);
                  final text = s.substring(headerEnd + 1);
                  final sep = header.indexOf('|');
                  if (sep > 0) {
                    final gid = header.substring(0, sep);
                    final from = header.substring(sep + 1);
                    // Check if this group was quit - if so, don't add it back
                    if (!_quitGroups.contains(gid)) {
                      final ingested = ingestInboundGroupText(
                        gid: gid,
                        from: from,
                        text: text,
                      );
                      if (ingested && !_quitGroups.contains(gid)) {
                        _syncKnownGroupsToNative(); // Sync to C++ layer
                      }
                    }
                    // If group was quit, ignore this message
                  }
                }
              } else if (s.startsWith('progress_recv:')) {
                // progress_recv:[<instance_id>:]<uid>:<received>:<total>:<path>  (new: instance_id first; legacy: no instance_id)
                final parts = s.split(':');
                int instanceId = 0;
                int uidIdx = 1;
                if (parts.length >= 6) {
                  instanceId = int.tryParse(parts[1]) ?? 0;
                  uidIdx = 2;
                }
                if (parts.length >= uidIdx + 4) {
                  final uid = parts[uidIdx];
                  final rec = int.tryParse(parts[uidIdx + 1]) ?? 0;
                  final tot = int.tryParse(parts[uidIdx + 2]) ?? 0;
                  final path =
                      parts.sublist(uidIdx + 3).join(':'); // allow ':' in path
                  // Update last poll activity to keep polling interval short during file transfer
                  _lastPollActivity = DateTime.now();
                  // Skip logging progress_recv details - too frequent during file transfer

                  // Try to find the file transfer by path or by checking all pending transfers
                  String? foundMsgID;
                  int? foundFileNumber;
                  final normalizedUid =
                      uid.length > 64 ? _normalizeFriendId(uid) : uid;

                  // Fast path: check cache from previous chunk (same transfer)
                  final cachedKey = _progressKeyCache[path];
                  if (cachedKey != null) {
                    final progress = _fileReceiveProgress[cachedKey];
                    if (progress != null) {
                      _fileReceiveProgress[cachedKey] = (
                        received: rec,
                        total: tot,
                        msgID: progress.msgID,
                        fileName: progress.fileName,
                        tempPath: progress.tempPath,
                        actualPath: path,
                      );
                      // P1-7: stamp the last-progress epoch so the timeout
                      // sweeper can tell a stalled transfer from a healthy
                      // one that's mid-chunk.
                      _lastProgressTs[cachedKey] =
                          DateTime.now().millisecondsSinceEpoch;
                      foundMsgID = progress.msgID;
                      foundFileNumber = cachedKey.$2;
                    }
                  }

                  // Full scan only if cache miss
                  if (foundMsgID == null) {
                    for (final entry in _fileReceiveProgress.entries) {
                      final key = entry.key;
                      final progress = entry.value;
                      if ((key.$1 == normalizedUid || key.$1 == uid) &&
                          (progress.actualPath == path ||
                              progress.tempPath == path ||
                              _isSameReceiveFile(progress.tempPath, path))) {
                        _fileReceiveProgress[key] = (
                          received: rec,
                          total: tot,
                          msgID: progress.msgID,
                          fileName: progress.fileName,
                          tempPath: progress.tempPath,
                          actualPath: path,
                        );
                        // P1-7: see cache-hit branch above.
                        _lastProgressTs[key] =
                            DateTime.now().millisecondsSinceEpoch;
                        foundMsgID = progress.msgID;
                        foundFileNumber = key.$2;
                        _progressKeyCache[path] =
                            key; // Cache for subsequent chunks
                        break;
                      }
                    }
                  }

                  // If not found by path, try to find by matching path basename (for cases where path format differs)
                  if (foundMsgID == null) {
                    final pathBasename = p.basename(path);
                    // Extract original filename from path if it has ID prefix
                    // Format: <sender_hex>_<friend_number>_<file_number>_<originalFileName>
                    String? extractedFileName;
                    if (pathBasename.contains('_') &&
                        pathBasename.length > 64) {
                      final parts = pathBasename.split('_');
                      if (parts.length >= 4) {
                        // Extract original filename (everything after the first 3 parts)
                        extractedFileName = parts.sublist(3).join('_');
                      }
                    } else {
                      extractedFileName = pathBasename;
                    }

                    for (final entry in _fileReceiveProgress.entries) {
                      final key = entry.key;
                      final progress = entry.value;
                      if ((key.$1 == normalizedUid || key.$1 == uid)) {
                        // Try to match by basename, by extracted filename, or tempPath vs actual path
                        final actualBasename = progress.actualPath != null
                            ? p.basename(progress.actualPath!)
                            : null;
                        final tempBasename = progress.tempPath != null
                            ? p.basename(progress.tempPath!)
                            : null;
                        final basenameMatch = actualBasename == pathBasename ||
                            tempBasename == pathBasename ||
                            _isSameReceiveFile(progress.tempPath, path);
                        final fileNameMatch = extractedFileName != null &&
                            progress.fileName == extractedFileName;

                        if (basenameMatch || fileNameMatch) {
                          _fileReceiveProgress[key] = (
                            received: rec,
                            total: tot,
                            msgID: progress.msgID,
                            fileName: progress.fileName,
                            tempPath: progress.tempPath,
                            actualPath:
                                path, // Update actual path when we receive it
                          );
                          // P1-7: see other progress-update sites.
                          _lastProgressTs[key] =
                              DateTime.now().millisecondsSinceEpoch;
                          foundMsgID = progress.msgID;
                          foundFileNumber = key.$2;
                          // Do not log every progress match - would spam logs during file transfer
                          break;
                        }
                      }
                    }
                  }

                  // If still not found, log warning but don't update any record
                  // This prevents incorrect matching when fileNumber is reused
                  if (foundMsgID == null) {
                    _logger?.logWarning(
                        '[FfiChatService] progress_recv: WARNING - No matching file transfer found for path=$path, total=$tot, uid=$uid. This may indicate fileNumber reuse or file transfer not tracked.');
                  }

                  // Throttle progress emissions: only emit when >=200ms elapsed, or at 0%/100%
                  final isComplete = tot > 0 && rec >= tot;
                  final isFirstChunk = rec <= 1371; // tox chunk size
                  final throttleKey = '$uid:${foundFileNumber ?? path}';
                  final now = DateTime.now();
                  final lastEmit = _lastProgressEmitTime[throttleKey];
                  final elapsed = lastEmit == null
                      ? _progressThrottleMs
                      : now.difference(lastEmit).inMilliseconds;
                  if (isFirstChunk ||
                      isComplete ||
                      elapsed >= _progressThrottleMs) {
                    _lastProgressEmitTime[throttleKey] = now;
                    _progressCtrl.add((
                      instanceId: instanceId,
                      peerId: uid,
                      path: path,
                      received: rec,
                      total: tot,
                      isSend: false,
                      msgID: foundMsgID
                    ));
                  }
                  if (isComplete) {
                    _lastProgressEmitTime.remove(throttleKey);
                  }

                  // CRITICAL: If file transfer is 100% complete, trigger file_done handling immediately
                  // This avoids waiting for the file_done event which may be blocked in the queue
                  // IMPORTANT: Only trigger if we found a matching file transfer (foundMsgID != null)
                  // This prevents fileNumber reuse from causing incorrect file completion handling
                  if (tot > 0 && rec >= tot && foundMsgID != null) {
                    _logger?.log(
                        '[FfiChatService] progress_recv: File transfer 100% complete, triggering file_done handling immediately');
                    // Get the actual path from progress tracking if path is truncated or empty
                    String? actualPath = path;
                    if (actualPath.isEmpty || !actualPath.startsWith('/')) {
                      // Path may be truncated, try to get it from progress tracking
                      if (foundFileNumber != null) {
                        final normalizedUid =
                            uid.length > 64 ? _normalizeFriendId(uid) : uid;
                        final progress = _fileReceiveProgress[(
                          normalizedUid,
                          foundFileNumber
                        )];
                        if (progress == null && uid != normalizedUid) {
                          // Try original uid if normalized not found
                          final progress2 =
                              _fileReceiveProgress[(uid, foundFileNumber)];
                          if (progress2 != null &&
                              progress2.actualPath != null &&
                              progress2.actualPath!.isNotEmpty) {
                            actualPath = progress2.actualPath;
                          }
                        } else if (progress != null &&
                            progress.actualPath != null &&
                            progress.actualPath!.isNotEmpty) {
                          actualPath = progress.actualPath;
                        }
                      }
                    }
                    if (actualPath != null &&
                        actualPath.isNotEmpty &&
                        actualPath.startsWith('/')) {
                      // Call _handleFileDone with the same parameters as file_done event
                      _logger?.log(
                          '[FfiChatService] progress_recv: Calling _handleFileDone with actualPath=$actualPath, fileNumber=$foundFileNumber, msgID=$foundMsgID');
                      // P1-3: an exception inside _handleFileDone used to be
                      // dropped on the floor by unawaited() and the message would
                      // sit forever in pending state. Capture & log here, and
                      // mark the in-flight transfer as failed so the UI can
                      // recover instead of waiting.
                      unawaited(_handleFileDone(
                              uid, 0, actualPath, foundFileNumber, foundMsgID)
                          .catchError((e, StackTrace st) {
                        _logger?.logError(
                            '[FfiChatService] progress_recv: _handleFileDone failed',
                            e,
                            st);
                        _markFileTransferFailed(
                            uid, foundFileNumber, foundMsgID);
                      }));
                    } else {
                      _logger?.log(
                          '[FfiChatService] progress_recv: WARNING - actualPath is invalid, cannot trigger file_done handling');
                    }
                  } else if (tot > 0 && rec >= tot && foundMsgID == null) {
                    // File is complete but we couldn't find a matching file transfer by path
                    // Try to extract fileNumber from path and use _fileNumberToMsgID mapping
                    int? extractedFileNumber;
                    String? extractedFileName;
                    if (path.isNotEmpty && path.startsWith('/')) {
                      final pathBasename = p.basename(path);
                      // Check path format: <uid>_<fileKind>_<fileNumber>_<originalFileName>
                      if (pathBasename.contains('_') &&
                          pathBasename.length > 64) {
                        final parts = pathBasename.split('_');
                        if (parts.length >= 3) {
                          // Extract fileNumber (third part, index 2)
                          extractedFileNumber = int.tryParse(parts[2]);
                          // Extract original filename (everything after the first 3 parts)
                          if (parts.length >= 4) {
                            extractedFileName = parts.sublist(3).join('_');
                          }
                        }
                      } else {
                        extractedFileName = pathBasename;
                      }
                    }

                    // Try to find msgID using _fileNumberToMsgID mapping
                    // CRITICAL: When fileNumber is reused, we must also verify filename/path to avoid false matches
                    if (extractedFileNumber != null) {
                      final foundMsgIDByMapping = _fileNumberToMsgID[(
                            normalizedUid,
                            extractedFileNumber
                          )] ??
                          _fileNumberToMsgID[(uid, extractedFileNumber)];

                      // Verify that the found msgID is still valid AND matches the current file
                      if (foundMsgIDByMapping != null) {
                        MapEntry<
                            (String, int),
                            ({
                              String? actualPath,
                              String? fileName,
                              String msgID,
                              int received,
                              String? tempPath,
                              int total
                            })>? matchingProgressEntry;
                        for (final entry in _fileReceiveProgress.entries) {
                          if (entry.value.msgID == foundMsgIDByMapping &&
                              (entry.key.$1 == normalizedUid ||
                                  entry.key.$1 == uid) &&
                              entry.key.$2 == extractedFileNumber) {
                            matchingProgressEntry = entry;
                            break;
                          }
                        }

                        // CRITICAL: Also verify filename/path matches to prevent false matches when fileNumber is reused
                        // This ensures we match the correct file even when multiple files use the same fileNumber
                        bool filenameMatches = false;
                        if (matchingProgressEntry != null &&
                            extractedFileName != null &&
                            extractedFileName.isNotEmpty) {
                          final progress = matchingProgressEntry.value;
                          final progressFileName = progress.fileName;
                          filenameMatches = progressFileName ==
                                  extractedFileName ||
                              (progress.actualPath != null &&
                                  progress.actualPath!
                                      .contains(extractedFileName)) ||
                              (progress.tempPath != null &&
                                  progress.tempPath!
                                      .contains(extractedFileName));
                        }

                        final isValid = matchingProgressEntry != null &&
                            (extractedFileName == null ||
                                extractedFileName.isEmpty ||
                                filenameMatches);

                        if (isValid) {
                          foundMsgID = foundMsgIDByMapping;
                          foundFileNumber = extractedFileNumber;
                          _logger?.log(
                              '[FfiChatService] progress_recv: Found valid msgID by fileNumber mapping: fileNumber=$extractedFileNumber, msgID=$foundMsgID, filenameMatches=$filenameMatches');
                          // Trigger file_done handling with found msgID
                          if (path.isNotEmpty && path.startsWith('/')) {
                            _logger?.log(
                                '[FfiChatService] progress_recv: Calling _handleFileDone with extracted fileNumber=$extractedFileNumber, msgID=$foundMsgID');
                            // P1-3: catch async failures so they don't vanish
                            // into the void; same rationale as the sibling call
                            // above.
                            unawaited(_handleFileDone(uid, 0, path,
                                    extractedFileNumber, foundMsgID)
                                .catchError((e, StackTrace st) {
                              _logger?.logError(
                                  '[FfiChatService] progress_recv: _handleFileDone failed',
                                  e,
                                  st);
                              _markFileTransferFailed(
                                  uid, extractedFileNumber, foundMsgID);
                            }));
                          }
                        } else {
                          _logger?.logWarning(
                              '[FfiChatService] progress_recv: WARNING - Found stale or mismatched msgID in mapping: fileNumber=$extractedFileNumber, msgID=$foundMsgIDByMapping, extractedFileName=$extractedFileName, progressFileName=${matchingProgressEntry?.value.fileName}, cleaning up');
                          // Clean up stale mapping
                          _fileNumberToMsgID
                              .remove((normalizedUid, extractedFileNumber));
                          _fileNumberToMsgID.remove((uid, extractedFileNumber));
                          _logger?.logWarning(
                              '[FfiChatService] progress_recv: File transfer 100% complete but no valid matching file transfer found (path=$path, total=$tot). Waiting for file_done event.');
                        }
                      } else {
                        _logger?.logWarning(
                            '[FfiChatService] progress_recv: File transfer 100% complete but no matching file transfer found (path=$path, total=$tot, extractedFileNumber=$extractedFileNumber). Waiting for file_done event.');
                      }
                    } else {
                      // File is complete but we couldn't find a matching file transfer
                      // This may happen if fileNumber was reused or file transfer wasn't tracked
                      // Wait for file_done event instead of trying to match by total size (which can cause false matches)
                      _logger?.logWarning(
                          '[FfiChatService] progress_recv: File transfer 100% complete but no matching file transfer found (path=$path, total=$tot). Waiting for file_done event to avoid false matches.');
                    }
                  }

                  // Progress update will be handled by FakeChatMessageProvider via progressUpdates stream
                }
              } else if (s.startsWith('progress_send:')) {
                // progress_send:<uid>:<sent>:<total>
                final parts = s.split(':');
                if (parts.length >= 4) {
                  final uid = parts[1];
                  final sent = int.tryParse(parts[2]) ?? 0;
                  final tot = int.tryParse(parts[3]) ?? 0;
                  final path = _lastSentPathByPeer[uid];
                  // Find msgID for this send path.
                  // R-1: prefer the precise per-msgID reverse map first — it
                  // is populated on every send and is immune to the
                  // "concurrent send to same peer overwrites _lastSentPathByPeer"
                  // race that the legacy path-based lookup has.
                  String? sendMsgID;
                  if (path != null) {
                    for (final e in _msgIDToSentPath.entries) {
                      if (e.value == path) {
                        sendMsgID = e.key;
                        break;
                      }
                    }
                    sendMsgID ??= _pathToMsgID[path];
                  }
                  // If still not found, try to find from last message for this peer.
                  if (sendMsgID == null && path != null) {
                    final normalizedUid =
                        uid.length > 64 ? _normalizeFriendId(uid) : uid;
                    final lastMsg = _lastByPeer[normalizedUid];
                    if (lastMsg != null && lastMsg.filePath == path) {
                      sendMsgID = lastMsg.msgID;
                    }
                  }
                  _progressCtrl.add((
                    instanceId: 0,
                    peerId: uid,
                    path: path,
                    received: sent,
                    total: tot,
                    isSend: true,
                    msgID: sendMsgID
                  ));
                }
              } else if (s.startsWith('file_request:')) {
                // file_request:[<instance_id>:]<uid>:<file_number>:<size>:<kind>:<filename>  (new: instance_id first)
                // kind: 0=DATA, 1=AVATAR
                // PROTOCOL LIMITATION (tracked for the framing redesign): the event is ':'-delimited
                // and split() below treats every ':' as a field separator. The trailing filename is
                // rejoined with ':' (sublist(...).join(':')) so a ':' inside the FILENAME survives,
                // but a ':' appearing in an EARLIER field would still mis-parse. A correct fix needs
                // delimiter escaping or a length-prefixed/JSON reframe on the C++ encoder side — a
                // breaking ABI change, out of scope here. Do not change parsing to "fix" this.
                _logger
                    ?.log('[FfiChatService] Processing file_request event: $s');
                _logger?.log(
                    '[FfiChatService] file_request event received - this is critical for file receiving');
                final parts = s.split(':');
                int uidIdx = 1;
                int? fileRequestInstanceId;
                if (parts.length >= 7 && int.tryParse(parts[1]) != null) {
                  fileRequestInstanceId = int.tryParse(parts[1]);
                  uidIdx = 2; // new format with instance_id first
                }
                if (parts.length >= uidIdx + 5) {
                  final uid = parts[uidIdx];
                  final fileNumber = int.tryParse(parts[uidIdx + 1]) ?? 0;
                  final fileSize = int.tryParse(parts[uidIdx + 2]) ?? 0;
                  final fileKind = int.tryParse(parts[uidIdx + 3]) ?? 0;
                  final fileName = parts.sublist(uidIdx + 4).join(':');

                  final isAvatarTransfer = fileKind == 1 ||
                      FfiChatService.isAvatarSyncFilePath(fileName);

                  // S29: a BLOCKED sender's non-avatar file is dropped entirely
                  // — skipping this whole block means no pending message, no
                  // transfer-tracking maps, and no auto-accept/disk-write.
                  final senderBlocked = uid != _selfId && isBlocked(uid);
                  // For non-avatar files, create a pending message immediately to show "receiving" status.
                  // Avatar sync files must never appear in chat history.
                  if (!isAvatarTransfer && !senderBlocked) {
                    // Normalize friend ID to ensure consistent storage and retrieval
                    final normalizedUid =
                        uid.length > 64 ? _normalizeFriendId(uid) : uid;
                    // Use unified message ID format: timestamp_sequence_userID (same as other messages)
                    // Add sequence number to ensure uniqueness even in high concurrency scenarios
                    final timestamp = DateTime.now().millisecondsSinceEpoch;
                    final sequence = _msgIDSequence++;
                    final msgID = '${timestamp}_${sequence}_$normalizedUid';
                    // Create a pending file message with temporary path (will be updated when file_done)
                    // P1-2: anchor the temp path in the per-account file_recv dir
                    // when known. Includes msgID so concurrent transfers of the
                    // same filename from the same peer don't collide.
                    final tempPath =
                        '${_fileRecvDir ?? '/tmp'}/receiving_${msgID}_$fileName';
                    final kind = _detectKind(fileName);
                    final msg = ChatMessage(
                      text: '',
                      fromUserId: uid,
                      isSelf: false,
                      timestamp: DateTime.now(),
                      groupId: null,
                      filePath:
                          tempPath, // Temporary path, will be updated in file_done
                      fileName:
                          fileName, // Save original file name to avoid showing id-prefixed names
                      mediaKind: kind,
                      msgID: msgID,
                      isPending:
                          true, // Mark as pending to show receiving status
                    );
                    // Track this file transfer for progress updates (use normalized ID for consistency)
                    _fileReceiveProgress[(normalizedUid, fileNumber)] = (
                      received: 0,
                      total: fileSize,
                      msgID: msgID,
                      fileName: fileName,
                      tempPath: tempPath,
                      actualPath: null,
                    );
                    // P1-7: seed the idle clock at request-time so the
                    // timeout sweeper measures from "we saw the request"
                    // rather than from a never-set baseline.
                    _lastProgressTs[(normalizedUid, fileNumber)] =
                        DateTime.now().millisecondsSinceEpoch;
                    // Store pending file transfer mapping
                    _pendingFileTransfers[(normalizedUid, fileNumber)] = msgID;
                    // Store msgID to file transfer mapping for progress updates
                    _msgIDToFileTransfer[msgID] = (normalizedUid, fileNumber);
                    // Store fileNumber to msgID mapping for fast lookup in file_done event
                    _fileNumberToMsgID[(normalizedUid, fileNumber)] = msgID;
                    // Add message to history and stream immediately (use normalized ID)
                    _logger?.log(
                        '[FfiChatService] file_request: Created pending message: msgID=$msgID, fileName=$fileName, tempPath=$tempPath, isPending=${msg.isPending}');
                    _lastByPeer[normalizedUid] = msg;
                    _appendHistory(normalizedUid, msg);
                    _messages.add(msg);
                    _logger?.log(
                        '[FfiChatService] file_request: Message added to history and stream, will be picked up by FakeIM');
                  }

                  // Check if this is an image file
                  final kind = _detectKind(fileName);
                  final isImage = kind == 'image';

                  // If this is an avatar file, auto-accept it
                  // CRITICAL: Pass fileRequestInstanceId so we accept on the receiver's instance (e.g. Bob),
                  // and AWAIT so the file is opened before we process more events (progress_recv requires fp to be set).
                  if (isAvatarTransfer) {
                    try {
                      await acceptFileTransfer(uid, fileNumber,
                          instanceId: fileRequestInstanceId);
                      _logger?.log(
                          '[FfiChatService] file_request: acceptFileTransfer (avatar) completed successfully');
                    } catch (e, st) {
                      _logger?.logError(
                          '[FfiChatService] file_request: acceptFileTransfer (avatar) failed',
                          e,
                          st);
                    }
                  } else {
                    // For regular files (kind == 0), auto-accept small files and all images
                    // AWAIT so the file is opened before we process more events (progress_recv requires fp to be set).
                    final sizeLimitMB =
                        await (_prefs?.getAutoDownloadSizeLimit() ??
                            Future.value(30));
                    final autoAcceptThreshold =
                        sizeLimitMB * 1024 * 1024; // Convert MB to bytes
                    // P0-8: Images bypass the user-configured size limit but are
                    // still capped — an unbounded OR was a denial-of-service risk
                    // because a malicious peer could push an arbitrarily large
                    // "image" (or anything spoofed with an image extension) and
                    // we'd auto-accept it. 50 MiB is a sane upper bound for
                    // ordinary chat imagery (photos, screenshots).
                    if ((isImage && fileSize < _imageAutoAcceptLimitBytes) ||
                        fileSize < autoAcceptThreshold) {
                      if (isImage) {
                        _logger?.log(
                            '[FfiChatService] Auto-accepting image file: $fileName (${fileSize} bytes)');
                      } else {
                        _logger?.log(
                            '[FfiChatService] Auto-accepting small file: $fileName (${fileSize} bytes, limit: ${sizeLimitMB}MB)');
                      }
                      _logger?.log(
                          '[FfiChatService] file_request: Calling acceptFileTransfer(uid=$uid, fileNumber=$fileNumber, instanceId=$fileRequestInstanceId)');
                      try {
                        await acceptFileTransfer(uid, fileNumber,
                            instanceId: fileRequestInstanceId);
                        _logger?.log(
                            '[FfiChatService] file_request: acceptFileTransfer completed successfully');
                      } catch (e, st) {
                        _logger?.logError(
                            '[FfiChatService] file_request: acceptFileTransfer failed',
                            e,
                            st);
                      }
                    } else {
                      // Large file: don't auto-accept, let UIKit's download button handle it
                      _logger?.log(
                          '[FfiChatService] Large file requires manual download: $fileName (${fileSize} bytes, limit: ${sizeLimitMB}MB)');
                      _fileRequestCtrl.add((
                        peerId: uid,
                        fileNumber: fileNumber,
                        fileSize: fileSize,
                        fileName: fileName
                      ));
                    }
                  }
                }
              } else if (s.startsWith('file_done:')) {
                // file_done:[<instance_id>:]<uid>:<kind>:<path>  (new: instance_id first; legacy: no instance_id)
                _logger
                    ?.log('[FfiChatService] ===== file_done event START =====');
                _logger?.log('[FfiChatService] Raw file_done event string: $s');
                final parts = s.split(':');
                _logger?.log(
                    '[FfiChatService] file_done event split into ${parts.length} parts');
                int fileDoneInstanceId = 0;
                int uidIdx = 1;
                if (parts.length >= 5) {
                  fileDoneInstanceId = int.tryParse(parts[1]) ?? 0;
                  uidIdx = 2;
                }
                if (parts.length >= uidIdx + 3) {
                  final uid = parts[uidIdx];
                  final fileKindStr = parts[uidIdx + 1];
                  final fileKind = int.tryParse(fileKindStr) ?? 0;
                  final path = parts.sublist(uidIdx + 2).join(':');
                  // Optimization 11: Enhanced logging for file_done event
                  _logger?.log(
                      '[FfiChatService] file_done event parsed: uid=$uid, kindStr=$fileKindStr, kind=$fileKind, pathLength=${path.length}');
                  _logger?.log('[FfiChatService] file_done event path: $path');
                  // CRITICAL: Check if path is valid (not truncated)
                  String? actualPath = path;
                  int? fileNumber;
                  String? msgID;
                  final normalizedUid =
                      uid.length > 64 ? _normalizeFriendId(uid) : uid;

                  // Extract fileNumber from path if path format contains it
                  // Format: <uid>_<fileKind>_<fileNumber>_<originalFileName>
                  if (path.isNotEmpty && path.startsWith('/')) {
                    final pathBasename = p.basename(path);
                    // Check path format: <uid>_<fileKind>_<fileNumber>_<originalFileName>
                    if (pathBasename.contains('_') &&
                        pathBasename.length > 64) {
                      final parts = pathBasename.split('_');
                      if (parts.length >= 3) {
                        // Extract fileNumber (third part, index 2)
                        fileNumber = int.tryParse(parts[2]);
                        if (fileNumber != null) {
                          _logger?.log(
                              '[FfiChatService] file_done: Extracted fileNumber=$fileNumber from path basename');
                        }
                      }
                    }
                  }

                  // Priority 1: Find msgID by fileNumber using _fileNumberToMsgID mapping
                  if (fileNumber != null && msgID == null) {
                    final foundMsgID =
                        _fileNumberToMsgID[(normalizedUid, fileNumber)] ??
                            _fileNumberToMsgID[(uid, fileNumber)];

                    // CRITICAL: Verify that the found msgID is still valid (file transfer still in progress)
                    // This prevents using stale mappings when fileNumber is reused
                    if (foundMsgID != null) {
                      final isValid = _fileReceiveProgress.entries.any((e) =>
                          e.value.msgID == foundMsgID &&
                          (e.key.$1 == normalizedUid || e.key.$1 == uid) &&
                          e.key.$2 == fileNumber);

                      if (isValid) {
                        msgID = foundMsgID;
                        _logger?.log(
                            '[FfiChatService] file_done: Found valid msgID by fileNumber mapping: fileNumber=$fileNumber, msgID=$msgID');
                      } else {
                        _logger?.logWarning(
                            '[FfiChatService] file_done: WARNING - Found stale msgID in mapping: fileNumber=$fileNumber, msgID=$foundMsgID, cleaning up');
                        // Clean up stale mapping
                        _fileNumberToMsgID.remove((normalizedUid, fileNumber));
                        _fileNumberToMsgID.remove((uid, fileNumber));
                        // CRITICAL: If _fileReceiveProgress is empty, this file was already processed
                        // Skip processing to avoid false matches
                        if (_fileReceiveProgress.isEmpty) {
                          _logger?.logWarning(
                              '[FfiChatService] file_done: WARNING - _fileReceiveProgress is empty, file may have already been processed. Skipping to avoid false matches. path=$actualPath');
                          return;
                        }
                      }
                    } else {
                      // No mapping found, but check if _fileReceiveProgress is empty
                      // If empty, file may have already been processed OR file_request event was missed
                      // In case of missed file_request, we should still create a message for the file
                      if (_fileReceiveProgress.isEmpty) {
                        _logger?.logWarning(
                            '[FfiChatService] file_done: WARNING - No msgID mapping found and _fileReceiveProgress is empty. File may have already been processed OR file_request event was missed. path=$actualPath, fileNumber=$fileNumber');
                        // Continue processing - _handleFileDone will check if message already exists in history
                        // If not, it will create a new message (fallback for missed file_request events)
                      }
                    }
                  }

                  // Priority 2: If msgID still null, try basename matching
                  if (msgID == null &&
                      actualPath != null &&
                      actualPath.isNotEmpty &&
                      actualPath.startsWith('/')) {
                    final pathBasename = p.basename(actualPath);
                    for (final entry in _fileReceiveProgress.entries) {
                      if (entry.key.$1 == normalizedUid ||
                          entry.key.$1 == uid) {
                        final progress = entry.value;
                        final actualBasename = progress.actualPath != null
                            ? p.basename(progress.actualPath!)
                            : null;
                        final tempBasename = progress.tempPath != null
                            ? p.basename(progress.tempPath!)
                            : null;
                        if (actualBasename == pathBasename ||
                            tempBasename == pathBasename) {
                          actualPath = progress.actualPath ?? progress.tempPath;
                          fileNumber = entry.key.$2;
                          msgID = progress.msgID;
                          _logger?.log(
                              '[FfiChatService] file_done: Found matching file transfer by basename: basename=$pathBasename, fileNumber=$fileNumber, msgID=$msgID');
                          break;
                        }
                      }
                    }
                  } else if (path.isEmpty || !path.startsWith('/')) {
                    // Path is invalid, try to find from progress tracking by basename
                    _logger?.log(
                        '[FfiChatService] file_done: Path is empty or invalid, searching progress tracking');
                    final pathBasename =
                        path.isNotEmpty ? p.basename(path) : null;
                    if (pathBasename != null && pathBasename.isNotEmpty) {
                      for (final entry in _fileReceiveProgress.entries) {
                        if (entry.key.$1 == normalizedUid ||
                            entry.key.$1 == uid) {
                          final progress = entry.value;
                          final actualBasename = progress.actualPath != null
                              ? p.basename(progress.actualPath!)
                              : null;
                          final tempBasename = progress.tempPath != null
                              ? p.basename(progress.tempPath!)
                              : null;
                          if (actualBasename == pathBasename ||
                              tempBasename == pathBasename) {
                            actualPath =
                                progress.actualPath ?? progress.tempPath;
                            fileNumber = entry.key.$2;
                            msgID = progress.msgID;
                            _logger?.log(
                                '[FfiChatService] file_done: Found path in progress tracking by basename: actualPath=$actualPath, fileNumber=$fileNumber, msgID=$msgID');
                            break;
                          }
                        }
                      }
                    }
                  }
                  if (actualPath != null &&
                      actualPath.isNotEmpty &&
                      actualPath.startsWith('/')) {
                    final isAvatarTransfer = (fileKind == 1 ||
                            FfiChatService.isAvatarSyncFilePath(path) ||
                            FfiChatService.isAvatarSyncFilePath(actualPath)) &&
                        uid != _selfId;
                    // Handle file based on type
                    if (isAvatarTransfer) {
                      _logger?.log(
                          '[FfiChatService] file_done: Detected as AVATAR file (kind=$fileKind), uid=$uid, selfId=$_selfId');
                      _logger?.log(
                          '[FfiChatService] file_done: Calling _moveAvatarToAvatarsDir for avatar');
                      _moveAvatarToAvatarsDir(actualPath, uid)
                          .then((finalPath) async {
                        _logger?.log(
                            '[FfiChatService] file_done: _moveAvatarToAvatarsDir completed, finalPath=$finalPath');
                        if (finalPath != null) {
                          await _prefs?.setFriendAvatarPath(uid, finalPath);
                        } else {
                          _logger?.log(
                              '[FfiChatService] file_done: Avatar move failed, using original path');
                          await _prefs?.setFriendAvatarPath(uid, actualPath);
                        }
                        _avatarUpdatedCtrl.add(uid);
                        _cleanupReceiveTrackingForCompletedFile(
                            uid, fileNumber, msgID);
                      }).catchError((e) {
                        _logger?.logError(
                            '[FfiChatService] file_done: Error in _moveAvatarToAvatarsDir',
                            e,
                            StackTrace.current);
                      });
                    } else if (fileKind == 0) {
                      _logger?.log(
                          '[FfiChatService] file_done: Detected as REGULAR file (kind=0), calling _handleFileDone');
                      _logger?.log(
                          '[FfiChatService] file_done: Parameters - uid=$uid, fileKind=$fileKind, path=$actualPath, fileNumber=$fileNumber, existingMsgID=$msgID');
                      // Emit 100% progress so progress listener gets transferComplete (e.g. file_seek test)
                      final progressEntry = fileNumber != null
                          ? (_fileReceiveProgress[(
                                normalizedUid,
                                fileNumber
                              )] ??
                              _fileReceiveProgress[(uid, fileNumber)])
                          : null;
                      final totalSize = progressEntry?.total ?? 0;
                      if (totalSize > 0 && fileDoneInstanceId != 0) {
                        _progressCtrl.add((
                          instanceId: fileDoneInstanceId,
                          peerId: uid,
                          path: actualPath ?? path,
                          received: totalSize,
                          total: totalSize,
                          isSend: false,
                          msgID: msgID
                        ));
                      }
                      // Regular file: call unified handler
                      // P1-3: the bare try/catch here only caught synchronous
                      // failures (e.g. invalid argument) — async failures inside
                      // _handleFileDone disappeared because unawaited() doesn't
                      // forward them. Capture both paths explicitly and surface
                      // the failure to the transfer record so it doesn't get
                      // stuck pending.
                      try {
                        unawaited(_handleFileDone(
                                uid, fileKind, actualPath, fileNumber, msgID)
                            .catchError((e, StackTrace st) {
                          _logger?.logError(
                              '[FfiChatService] file_done: _handleFileDone failed (async)',
                              e,
                              st);
                          _markFileTransferFailed(uid, fileNumber, msgID);
                        }));
                        _logger?.log(
                            '[FfiChatService] file_done: _handleFileDone called (async)');
                      } catch (e, stackTrace) {
                        _logger?.logError(
                            '[FfiChatService] file_done: ERROR calling _handleFileDone',
                            e,
                            stackTrace);
                        _markFileTransferFailed(uid, fileNumber, msgID);
                      }
                    } else {
                      _logger?.log(
                          '[FfiChatService] file_done: WARNING - Unknown fileKind=$fileKind, uid=$uid, not handling');
                    }
                  } else {
                    _logger?.log(
                        '[FfiChatService] file_done: ERROR - Invalid path: actualPath=$actualPath');
                  }
                  _logger
                      ?.log('[FfiChatService] ===== file_done event END =====');
                } else {
                  _logger?.log(
                      '[FfiChatService] file_done: ERROR - Invalid format, expected at least 4 parts, got ${parts.length}');
                  _logger?.log(
                      '[FfiChatService] file_done: Parts: ${parts.join(" | ")}');
                }
              } else if (s.startsWith('file_canceled:') ||
                  s.startsWith('file_cancel:') ||
                  s.startsWith('file_paused:') ||
                  s.startsWith('file_resumed:')) {
                // P1-6: peer-initiated file control events.
                // TODO(P1-6): wire after FFI emits file_control events — the
                // native side does not currently publish these strings, so
                // this branch is dead code today. The handler lives here so
                // that once the FFI layer adds emission, no Dart change is
                // needed beyond confirming the exact event prefix.
                // Format: <event>:<uid>:<file_number>
                final colonIdx = s.indexOf(':');
                final prefix = s.substring(0, colonIdx);
                final rest = s.substring(colonIdx + 1);
                final parts = rest.split(':');
                if (parts.length >= 2) {
                  final uid = parts[0];
                  final fileNumber = int.tryParse(parts[1]);
                  if (fileNumber != null) {
                    final control =
                        (prefix == 'file_canceled' || prefix == 'file_cancel')
                            ? 'cancel'
                            : (prefix == 'file_paused' ? 'pause' : 'resume');
                    _handleFileControl(
                        uid: uid, fileNumber: fileNumber, control: control);
                  }
                }
              } else if (s.startsWith('nickname_changed:')) {
                // nickname_changed:<friend_id>:<nickname>
                final parts = s.split(':');
                if (parts.length >= 3) {
                  final friendId = parts[1];
                  final nickname =
                      parts.sublist(2).join(':'); // Allow ':' in nickname
                  if (friendId.isNotEmpty && nickname.isNotEmpty) {
                    unawaited(_prefs?.setFriendNickname(friendId, nickname));
                    _nicknameUpdatedCtrl.add(friendId);
                  }
                }
              } else if (s.startsWith('status_changed:')) {
                // status_changed:<friend_id>:<status_message>
                final parts = s.split(':');
                if (parts.length >= 3) {
                  final friendId = parts[1];
                  final statusMessage =
                      parts.sublist(2).join(':'); // Allow ':' in status message
                  if (friendId.isNotEmpty && statusMessage.isNotEmpty) {
                    unawaited(_prefs?.setFriendStatusMessage(
                        friendId, statusMessage));
                  }
                }
              } else if (s.startsWith('c2cbin:')) {
                // c2cbin:<sender>:<size> - notification that custom message is available
                // The actual data will be polled via pollCustom
                final parts = s.split(':');
                if (parts.length >= 3) {
                  final sender = parts[1];
                  final size = int.tryParse(parts[2]) ?? 0;
                  // Store sender for custom message parsing
                  _lastCustomSender = sender;
                  _lastCustomGroupID = null;
                }
              } else if (s.startsWith('gcustom:')) {
                // gcustom:<groupID>|<sender>:<size> - notification that group custom message is available
                final parts = s.split(':');
                if (parts.length >= 3) {
                  final header = parts[1];
                  final size = int.tryParse(parts[2]) ?? 0;
                  final sep = header.indexOf('|');
                  if (sep > 0) {
                    final gid = header.substring(0, sep);
                    final sender = header.substring(sep + 1);
                    // Store sender and groupID for custom message parsing
                    _lastCustomSender = sender;
                    _lastCustomGroupID = gid;
                  }
                }
              }
            }
          } // end batch drain loop
          pkgffi.malloc.free(buf);

          // Poll custom messages (reactions, etc.)
          final customBuf = pkgffi.malloc.allocate<ffi.Uint8>(4096);
          final customN = _ffi.pollCustom(customBuf, 4096);
          if (customN > 0 && _lastCustomSender != null) {
            _lastPollActivity = DateTime.now();
            // The custom data itself is the reaction JSON
            final customData = customBuf.asTypedList(customN);
            try {
              final jsonString = utf8.decode(customData);
              final json = jsonDecode(jsonString) as Map<String, dynamic>;
              if (json['type'] == 'reaction') {
                final msgID = json['msgID'] as String?;
                final reactionID = json['reactionID'] as String?;
                final action = json['action'] as String?; // 'add' or 'remove'
                final sender = _lastCustomSender!;
                final groupID = _lastCustomGroupID;
                if (msgID != null && reactionID != null && action != null) {
                  _reactionCtrl.add((
                    msgID: msgID,
                    reactionID: reactionID,
                    action: action,
                    sender: sender,
                    groupID: groupID
                  ));
                }
              } else if (json['type'] == 'receipt') {
                // Handle receipt (received or read)
                final msgID = json['msgID'] as String?;
                final receiptType =
                    json['receiptType'] as String?; // 'received' or 'read'
                final sender = _lastCustomSender!;
                final groupID = _lastCustomGroupID;
                if (msgID != null && receiptType != null) {
                  // Update message status in history (async, don't await)
                  unawaited(
                      _handleReceipt(msgID, receiptType, sender, groupID));
                }
              }
            } catch (e) {}
            // Clear sender after processing
            _lastCustomSender = null;
            _lastCustomGroupID = null;
          }
          pkgffi.malloc.free(customBuf);
          // P1-7: opportunistic stale-transfer sweep. Cheap when there are no
          // in-flight transfers; only does real work if one has gone quiet.
          try {
            _checkFileTransferTimeouts();
          } catch (e, st) {
            _logger?.logError(
                '[FfiChatService] _checkFileTransferTimeouts failed', e, st);
          }
          // Schedule next poll with adaptive interval
          _scheduleNextPoll();
        } finally {
          // P2-19: release the reentry guard regardless of how we exit.
          _pollBusy = false;
        }
      };
      _poller = Timer(pollInterval, _pollTimerCallback!);
    }

    _scheduleNextPollRef = scheduleNextPoll;
    // Start first poll
    scheduleNextPoll();
  }

  /// Schedules the next poll. Call from async callback so next poll runs after current one completes.
  void _scheduleNextPoll() {
    _scheduleNextPollRef?.call();
  }

  /// Trigger one poll cycle immediately. Call when a file message is received via global callback
  /// so file_request (enqueued in same native OnFileRecv) is consumed promptly and accept runs.
  /// Runs the poll callback immediately (async, not awaited) so the next event loop tick can process it.
  void triggerPollOnce() {
    if (_pollTimerCallback != null) {
      _poller?.cancel();
      _pollTimerCallback!();
      // Next poll is scheduled by the callback when it completes (scheduleNextPoll is local to startPolling)
    }
  }

  /// Handle file_done event - extracted to be callable from both file_done event and progress_recv when 100% complete
  Future<void> _handleFileDone(String uid, int fileKind, String path,
      int? fileNumber, String? existingMsgID) async {
    _logger
        ?.log('[FfiChatService] ========== _handleFileDone START ==========');
    _logger?.log(
        '[FfiChatService] _handleFileDone: Called with - uid=$uid, fileKind=$fileKind, fileNumber=$fileNumber, existingMsgID=$existingMsgID');
    _logger?.log(
        '[FfiChatService] _handleFileDone: path length=${path.length}, path=$path');
    final processingKey = '$uid:$path';
    try {
      // Optimization 11: Enhanced logging
      _logger?.log('[FfiChatService] _handleFileDone: Starting processing...');

      // CRITICAL: Check if path is valid (not truncated)
      if (path.isEmpty || !path.startsWith('/')) {
        _logger?.log(
            '[FfiChatService] _handleFileDone: ERROR - Invalid path (empty or not absolute)');
        return;
      }
      // CRITICAL: Prevent duplicate processing - use a set to track files being processed
      if (_processingFileDone.contains(processingKey)) {
        _logger?.log(
            '[FfiChatService] _handleFileDone: Already processing this file, skipping duplicate');
        return; // Already processing this file
      }
      _processingFileDone.add(processingKey);
      _logger?.log(
          '[FfiChatService] _handleFileDone: Added to processing set: $processingKey');

      final isAvatarTransfer =
          (fileKind == 1 || FfiChatService.isAvatarSyncFilePath(path)) &&
              uid != _selfId;

      // Handle file based on type
      if (isAvatarTransfer) {
        // Avatar file: persist into avatars dir and notify UI.
        final finalPath = await _moveAvatarToAvatarsDir(path, uid);
        await _prefs?.setFriendAvatarPath(uid, finalPath ?? path);
        _avatarUpdatedCtrl.add(uid);
        _cleanupReceiveTrackingForCompletedFile(uid, fileNumber, existingMsgID);
        return;
      } else if (fileKind == 0) {
        // Regular file: use original path (no longer moving to Downloads or avatars directory)
        // Normalize friend ID to ensure consistent storage and retrieval
        final normalizedUid = uid.length > 64 ? _normalizeFriendId(uid) : uid;
        _logger?.log(
            '[FfiChatService] _handleFileDone: Normalized uid: $normalizedUid (original length=${uid.length})');
        // Get original file name from progress tracking
        String? fileName;
        int? actualFileNumber = fileNumber;
        // Use existingMsgID if provided, otherwise try to find by path
        String? foundMsgID = existingMsgID;
        _logger?.log(
            '[FfiChatService] _handleFileDone: Initial lookup - fileNumber=$actualFileNumber, msgID=$foundMsgID');

        // Try to find by path first (check both actualPath and tempPath)
        // Use normalized ID for consistency
        _logger?.log(
            '[FfiChatService] _handleFileDone: Searching _fileReceiveProgress (size=${_fileReceiveProgress.length}) for path match');
        int progressSearchCount = 0;
        for (final entry in _fileReceiveProgress.entries) {
          progressSearchCount++;
          if (entry.key.$1 == normalizedUid || entry.key.$1 == uid) {
            final keyUid = entry.key.$1;
            final keyFileNumber = entry.key.$2;
            final progress = entry.value;
            _logger?.log(
                '[FfiChatService] _handleFileDone: Checking progress entry $progressSearchCount: keyUid=$keyUid, fileNumber=$keyFileNumber, actualPath=${progress.actualPath}, tempPath=${progress.tempPath}');
            // Match by actualPath, tempPath, or tempPath vs actual path via _isSameReceiveFile
            if (progress.actualPath == path ||
                progress.tempPath == path ||
                _isSameReceiveFile(progress.tempPath, path) ||
                (progress.tempPath != null &&
                    path.contains(progress.tempPath!)) ||
                (progress.actualPath != null &&
                    path.contains(progress.actualPath!))) {
              _logger?.log(
                  '[FfiChatService] _handleFileDone: Path match found! fileName=${progress.fileName}, fileNumber=$keyFileNumber, msgID=${progress.msgID}');
              fileName = progress.fileName;
              actualFileNumber = entry.key.$2;
              if (foundMsgID == null) {
                foundMsgID = progress.msgID;
              }
              break;
            }
          }
        }
        _logger?.log(
            '[FfiChatService] _handleFileDone: Progress search completed, checked $progressSearchCount entries, found: fileName=$fileName, actualFileNumber=$actualFileNumber, msgID=$foundMsgID');

        // If not found by path, try to find by matching the path basename or any entry for this uid
        if (fileName == null || actualFileNumber == null) {
          final pathBasename = p.basename(path);
          // Extract filename from path (remove the ID prefix if present)
          String? extractedFileName;
          if (pathBasename.contains('_') && pathBasename.length > 64) {
            // Likely has ID prefix, try to extract original filename
            final parts = pathBasename.split('_');
            if (parts.length >= 4) {
              // Format: <ID>_<fileNumber>_<chunkSize>_<originalFileName>
              extractedFileName = parts.sublist(3).join('_');
            }
          } else {
            extractedFileName = pathBasename;
          }
          for (final entry in _fileReceiveProgress.entries) {
            if (entry.key.$1 == uid) {
              // Try to match by filename or use the first entry for this uid
              if (entry.value.fileName == extractedFileName ||
                  entry.value.fileName == pathBasename ||
                  fileName == null) {
                fileName = entry.value.fileName;
                actualFileNumber = entry.key.$2;
                if (foundMsgID == null) {
                  foundMsgID = entry.value.msgID;
                }
                // If we found a match by filename, break; otherwise continue to find the best match
                if (entry.value.fileName == extractedFileName ||
                    entry.value.fileName == pathBasename) {
                  break;
                }
              }
            }
          }
        }

        if (fileName == null || fileName.isEmpty) {
          _logger?.log(
              '[FfiChatService] _handleFileDone: fileName is null/empty, extracting from path');
          // Extract original filename from path if it has ID prefix
          final pathBasename = p.basename(path);
          if (pathBasename.contains('_') && pathBasename.length > 64) {
            final parts = pathBasename.split('_');
            if (parts.length >= 4) {
              fileName = parts.sublist(3).join('_');
            } else {
              fileName = pathBasename;
            }
          } else {
            fileName = pathBasename;
          }
          _logger?.log(
              '[FfiChatService] _handleFileDone: Extracted fileName: $fileName');
        }

        _logger?.log(
            '[FfiChatService] _handleFileDone: After lookup - fileNumber=$actualFileNumber, fileName=$fileName, msgID=$foundMsgID');

        // Detect file kind for mediaKind field
        final kind = _detectKind(fileName);
        _logger?.log(
            '[FfiChatService] _handleFileDone: Detected file kind: $kind');

        // Move file to appropriate directory based on type
        // Images: move to avatars directory
        // Other files: move to Downloads directory (respects settings page configuration)
        Future<String> finalPathFuture;
        if (kind == 'image') {
          _logger?.log(
              '[FfiChatService] _handleFileDone: Moving image to avatars directory');
          finalPathFuture = _getAvatarsDir().then((avatarsDirPath) async {
            final actualFileName = fileName ?? p.basename(path);
            final ext = p.extension(actualFileName);
            final baseName = p.basenameWithoutExtension(actualFileName);
            final destPath = p.join(avatarsDirPath,
                '${baseName}_${DateTime.now().millisecondsSinceEpoch}$ext');
            // Verify source file exists before copying
            final sourceFile = File(path);
            if (!await sourceFile.exists()) {
              // Source file already moved/deleted, check if destPath exists
              final destFile = File(destPath);
              if (await destFile.exists()) {
                return destPath; // File already moved
              }
              // File doesn't exist, return original path
              return path;
            }
            await sourceFile.copy(destPath);
            if (path.contains('/file_recv/') || path.contains('/tmp/')) {
              try {
                await sourceFile.delete();
              } catch (e) {}
            }
            return destPath;
          });
        } else {
          // Non-image files: move to Downloads directory (respects settings page configuration)
          _logger?.log(
              '[FfiChatService] _handleFileDone: Moving file to Downloads directory');
          // Capture variables needed for progress update
          final capturedFileNumber = actualFileNumber;
          final capturedUid = uid;
          final capturedFoundMsgID = foundMsgID;
          finalPathFuture =
              _moveFileToDownloads(path, fileName ?? p.basename(path))
                  .then((movedPath) async {
            // P1-4: a null return from _moveFileToDownloads now means the
            // copy failed. Surface that as a failed transfer and stop the
            // history-write chain by returning an empty string sentinel.
            if (movedPath == null) {
              _logger?.log(
                  '[FfiChatService] _handleFileDone: file move to Downloads failed — marking transfer failed');
              _markFileTransferFailed(uid, actualFileNumber, foundMsgID);
              return '';
            }
            if (movedPath != path) {
              // File was successfully moved - update progress tracking with new path
              // This ensures subsequent progress updates use the correct path
              if (capturedFileNumber != null) {
                final normalizedUid = capturedUid.length > 64
                    ? _normalizeFriendId(capturedUid)
                    : capturedUid;
                int? totalSize;
                if (_fileReceiveProgress
                    .containsKey((normalizedUid, capturedFileNumber))) {
                  final progress = _fileReceiveProgress[(
                    normalizedUid,
                    capturedFileNumber
                  )]!;
                  totalSize = progress.total;
                  _fileReceiveProgress[(normalizedUid, capturedFileNumber)] = (
                    received: progress.received,
                    total: progress.total,
                    msgID: progress.msgID,
                    fileName: progress.fileName,
                    tempPath: progress.tempPath,
                    actualPath: movedPath, // Update to final moved path
                  );
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: Updated progress tracking with moved path: $movedPath');
                } else if (_fileReceiveProgress
                    .containsKey((capturedUid, capturedFileNumber))) {
                  final progress =
                      _fileReceiveProgress[(capturedUid, capturedFileNumber)]!;
                  totalSize = progress.total;
                  _fileReceiveProgress[(capturedUid, capturedFileNumber)] = (
                    received: progress.received,
                    total: progress.total,
                    msgID: progress.msgID,
                    fileName: progress.fileName,
                    tempPath: progress.tempPath,
                    actualPath: movedPath, // Update to final moved path
                  );
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: Updated progress tracking with moved path: $movedPath');
                }
                // Send a progress update with the new path to notify UI
                // This ensures UI knows the file has been moved and can update localUrl
                if (totalSize != null) {
                  _progressCtrl.add((
                    instanceId: 0,
                    peerId: capturedUid,
                    path: movedPath,
                    received: totalSize,
                    total: totalSize,
                    isSend: false,
                    msgID: capturedFoundMsgID
                  ));
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: Sent progress update with moved path to notify UI');
                }
              }
              return movedPath;
            } else {
              return path;
            }
          }).catchError((e) {
            // P1-4: same rationale as the null branch above — bail out and
            // mark the transfer failed instead of pretending the source
            // path is a final destination.
            _logger?.logError(
                '[FfiChatService] _handleFileDone: Error moving file to Downloads',
                e,
                StackTrace.current);
            _markFileTransferFailed(uid, actualFileNumber, foundMsgID);
            return '';
          });
        }

        // Update message with final path
        unawaited(finalPathFuture.then((finalPath) async {
          _logger?.log(
              '[FfiChatService] _handleFileDone: Processing file with final path: $finalPath');
          // P1-4: empty string is the sentinel _moveFileToDownloads uses to
          // signal that we already marked the transfer failed. Don't go on
          // to write history with an empty path.
          if (finalPath.isEmpty) {
            _logger?.log(
                '[FfiChatService] _handleFileDone: finalPath is empty (transfer failed earlier), aborting history update');
            // R-4: release the dedupe slot on this failure path — without
            // this, the same processingKey is stuck in the set forever and
            // a legitimate retry of the same (uid,path) gets dropped as a
            // duplicate.
            _processingFileDone.remove(processingKey);
            return;
          }
          // Verify file exists before updating message
          final file = File(finalPath);
          final exists = await file.exists();
          _logger
              ?.log('[FfiChatService] _handleFileDone: File exists: $exists');

          // Find existing message (use normalized ID for consistency)
          // CRITICAL: Try to find message even if file doesn't exist, to handle cases where
          // file was already processed by progress_recv but file_done event arrives later
          String? existingMsgID = foundMsgID;
          if (existingMsgID == null && actualFileNumber != null) {
            // Try normalized ID first
            if (_fileReceiveProgress
                .containsKey((normalizedUid, actualFileNumber))) {
              existingMsgID =
                  _fileReceiveProgress[(normalizedUid, actualFileNumber)]!
                      .msgID;
            } else if (_fileReceiveProgress
                .containsKey((uid, actualFileNumber))) {
              existingMsgID =
                  _fileReceiveProgress[(uid, actualFileNumber)]!.msgID;
            }
          }

          if (existingMsgID == null) {
            // Try to find by matching any entry for this uid
            for (final entry in _fileReceiveProgress.entries) {
              if (entry.key.$1 == normalizedUid || entry.key.$1 == uid) {
                existingMsgID = entry.value.msgID;
                actualFileNumber = entry.key.$2;
                break;
              }
            }
          }

          // CRITICAL: If existingMsgID is still null, try to find pending message in history
          // This handles cases where file_request event was missed but file_done event arrived
          // CRITICAL: Only try to find pending messages if _fileReceiveProgress is empty
          // If _fileReceiveProgress is not empty, we should have found the msgID already
          // If _fileReceiveProgress is empty, we should NOT match completed messages by fileNumber
          // because fileNumber may have been reused by a new file transfer
          if (existingMsgID == null) {
            var history = _historyById[normalizedUid];
            if (history == null && uid != normalizedUid) {
              history = _historyById[uid];
            }
            if (history != null) {
              // Extract original filename and fileNumber from path
              // Path format: .../file_recv/{uid}_{fileKind}_{fileNumber}_{fileName}
              final pathBasename = p.basename(path);
              String? extractedFileName;
              String? extractedFileNumber;
              if (pathBasename.contains('_') && pathBasename.length > 64) {
                final pathParts = pathBasename.split('_');
                if (pathParts.length >= 4) {
                  extractedFileNumber =
                      pathParts[2]; // fileNumber is the 3rd part (index 2)
                  extractedFileName = pathParts.sublist(3).join('_');
                }
              } else {
                extractedFileName = pathBasename;
              }

              // Search for message with matching filename
              // CRITICAL: When _fileReceiveProgress is empty, only match PENDING messages
              // Do NOT match completed messages by fileNumber because fileNumber may have been reused
              // This prevents false matches when fileNumber is reused (e.g., build.sh and toxid_qrcode.png both use fileNumber=65536)
              String? pendingMsgID;
              String? pendingMsgIDByFileNumber;
              String? completedMsgID;
              // Do NOT use completedMsgIDByFileNumber when _fileReceiveProgress is empty
              // because fileNumber may have been reused
              DateTime? mostRecentCompletedTimestamp;
              final now = DateTime.now();
              // Only match completed messages within the last 5 minutes to avoid matching old files
              final timeWindow = Duration(minutes: 5);
              // Track which messages we've already seen to avoid duplicate matching
              final Set<String> seenMsgIDs = {};
              final bool shouldMatchCompletedByFileNumber =
                  _fileReceiveProgress.isNotEmpty;
              for (final msg in history) {
                // Skip if message has no msgID or we've already processed this message
                final msgID = msg.msgID;
                if (msgID == null || seenMsgIDs.contains(msgID)) continue;
                seenMsgIDs.add(msgID);

                final extractedFileNameNonNull = extractedFileName ?? '';
                bool fileNameMatches = msg.fileName == extractedFileName ||
                    msg.fileName == fileName ||
                    (msg.filePath != null &&
                        extractedFileNameNonNull.isNotEmpty &&
                        msg.filePath!.contains(extractedFileNameNonNull));

                // Check if fileNumber matches (more precise matching)
                // CRITICAL: When fileNumber is reused, we must also check filename to avoid false matches
                bool fileNumberMatches = false;
                if (extractedFileNumber != null &&
                    actualFileNumber != null &&
                    msg.filePath != null) {
                  // Check if filePath contains the fileNumber
                  final fileNumberStr = actualFileNumber.toString();
                  final pathContainsFileNumber =
                      msg.filePath!.contains('_${fileNumberStr}_') ||
                          msg.filePath!
                              .endsWith('_${fileNumberStr}_$extractedFileName');
                  // CRITICAL: Also verify filename matches to prevent false matches when fileNumber is reused
                  // This ensures we match the correct file even when multiple files use the same fileNumber
                  final fileNameAlsoMatches = extractedFileName != null &&
                      extractedFileName.isNotEmpty &&
                      (msg.fileName == extractedFileName ||
                          (msg.filePath != null &&
                              msg.filePath!.contains(extractedFileName)));
                  fileNumberMatches =
                      pathContainsFileNumber && fileNameAlsoMatches;
                }

                if (fileNameMatches || fileNumberMatches) {
                  // CRITICAL: fileNumber match is most precise - prioritize it regardless of pending/completed status
                  // BUT: Only match completed messages by fileNumber if _fileReceiveProgress is not empty
                  // This prevents false matches when fileNumber is reused
                  if (fileNumberMatches) {
                    if (msg.isPending == true &&
                        pendingMsgIDByFileNumber == null) {
                      pendingMsgIDByFileNumber = msgID;
                      _logger?.log(
                          '[FfiChatService] _handleFileDone: Found pending message by fileNumber match: msgID=$pendingMsgIDByFileNumber, fileNumber=$actualFileNumber');
                    } else if (msg.isPending == false &&
                        shouldMatchCompletedByFileNumber) {
                      // Only match completed messages by fileNumber if _fileReceiveProgress is not empty
                      // This ensures fileNumber hasn't been reused
                      final timeDiff = now.difference(msg.timestamp);
                      if (timeDiff <= timeWindow) {
                        // FileNumber match for completed message - most precise, use it immediately
                        // But only if _fileReceiveProgress is not empty (fileNumber hasn't been reused)
                        _logger?.log(
                            '[FfiChatService] _handleFileDone: Skipping completed message by fileNumber match because _fileReceiveProgress is empty (fileNumber may have been reused): msgID=$msgID, fileNumber=$actualFileNumber');
                      }
                    }
                  } else if (fileNameMatches) {
                    // Only process filename matches if fileNumber didn't match (to avoid duplicate processing)
                    if (msg.isPending == true && pendingMsgID == null) {
                      pendingMsgID = msgID;
                      _logger?.log(
                          '[FfiChatService] _handleFileDone: Found pending message by filename match: msgID=$pendingMsgID, fileName=$extractedFileName');
                    } else if (msg.isPending == false) {
                      final timeDiff = now.difference(msg.timestamp);
                      if (timeDiff <= timeWindow) {
                        if (mostRecentCompletedTimestamp == null ||
                            msg.timestamp
                                .isAfter(mostRecentCompletedTimestamp)) {
                          completedMsgID = msgID;
                          mostRecentCompletedTimestamp = msg.timestamp;
                          _logger?.log(
                              '[FfiChatService] _handleFileDone: Found completed message by filename match: msgID=$completedMsgID, fileName=$extractedFileName');
                        }
                      }
                    }
                  }
                }
              }
              // Use fileNumber match first (most precise), then pending by filename, then completed
              // CRITICAL: Only use fileNumber match for pending messages when _fileReceiveProgress is empty
              // This prevents matching wrong messages when the same fileNumber is reused
              if (pendingMsgIDByFileNumber != null) {
                existingMsgID = pendingMsgIDByFileNumber;
                _logger?.log(
                    '[FfiChatService] _handleFileDone: Using pending message (fileNumber match, most precise): msgID=$existingMsgID');
              } else if (pendingMsgID != null) {
                existingMsgID = pendingMsgID;
                _logger?.log(
                    '[FfiChatService] _handleFileDone: Using pending message (filename match): msgID=$existingMsgID');
              } else if (completedMsgID != null) {
                // KNOWN-ACCEPTED last-resort heuristic (codex #24, assessed
                // 2026-05-30 — intentionally NOT tightened). Reached ONLY after
                // the precise resolutions above miss: exact fileNumber-handle
                // and filename+pending matches. Unlike the offline-drain
                // matchers, `file_done` carries no original-send timestamp, so
                // the #23 exact-ms/msgID discriminator can't apply here — the
                // time window is the only available tiebreak. Narrow failure
                // mode (two same-name files completing in-window with BOTH
                // precise matches missing); the log line below is the agreed
                // instrumentation. Do NOT swap in exact-ms: no exact id exists
                // in this receive path.
                existingMsgID = completedMsgID;
                _logger?.log(
                    '[FfiChatService] _handleFileDone: No pending message found, using most recent completed message within time window: msgID=$existingMsgID, timestamp=$mostRecentCompletedTimestamp');
              } else {
                _logger?.log(
                    '[FfiChatService] _handleFileDone: No matching message found (pending or recent completed) for fileName=$extractedFileName, fileNumber=$actualFileNumber');
              }
            }
          }

          if (exists) {
            // Verify source file still exists before processing
            final sourceFile = File(path);
            final sourceExists = await sourceFile.exists();
            if (!sourceExists) {
              // Source file already moved/deleted, but finalPath exists - continue processing
              // This happens when progress_recv triggers _handleFileDone and file is moved,
              // then file_done event arrives later with the original path
              _logger?.log(
                  '[FfiChatService] _handleFileDone: Source file already moved/deleted, but finalPath exists. Continuing with finalPath=$finalPath');
              // Continue processing with finalPath - don't return early
            } else {
              await file.length();
            }

            if (existingMsgID != null) {
              _logger?.log(
                  '[FfiChatService] _handleFileDone: Found existing message, msgID=$existingMsgID');
              // Use normalized ID for consistency. Persistence normalizes
              // internally; the legacy-uid fallback is preserved for callers
              // that may still query by raw id during the same tick.
              var history =
                  _messageHistoryPersistence.getCachedList(normalizedUid);
              if (history == null && uid != normalizedUid) {
                history = _messageHistoryPersistence.getCachedList(uid);
                // Migrate to normalized ID if found with original ID
                if (history != null && history.isNotEmpty) {
                  _messageHistoryPersistence.setCachedHistory(
                      normalizedUid, history);
                  _messageHistoryPersistence.removeCachedHistory(uid);
                  // Re-fetch the now-canonical list so mutations land in the
                  // persistence-owned instance (setCachedHistory copies).
                  history =
                      _messageHistoryPersistence.getCachedList(normalizedUid);
                }
              }
              _logger?.log(
                  '[FfiChatService] _handleFileDone: Checking history for msgID=$existingMsgID, history size=${history?.length ?? 0}, normalizedUid=$normalizedUid, uid=$uid');
              if (history != null) {
                final index =
                    history.indexWhere((m) => m.msgID == existingMsgID);
                _logger?.log(
                    '[FfiChatService] _handleFileDone: Message search result: index=$index (>=0 means found)');
                if (index >= 0) {
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: Found message at index $index in history');
                  final oldMsg = history[index];
                  String? originalFileName = oldMsg.fileName;
                  // Try both normalized and original ID for file progress
                  if (actualFileNumber != null) {
                    if (_fileReceiveProgress
                        .containsKey((normalizedUid, actualFileNumber))) {
                      originalFileName = _fileReceiveProgress[(
                        normalizedUid,
                        actualFileNumber
                      )]!
                          .fileName;
                    } else if (_fileReceiveProgress
                        .containsKey((uid, actualFileNumber))) {
                      originalFileName =
                          _fileReceiveProgress[(uid, actualFileNumber)]!
                              .fileName;
                    }
                  }
                  final updatedMsg = ChatMessage(
                    text: oldMsg.text,
                    fromUserId: oldMsg.fromUserId,
                    isSelf: oldMsg.isSelf,
                    timestamp: oldMsg.timestamp,
                    groupId: oldMsg.groupId,
                    filePath:
                        finalPath, // Use final path (Downloads or avatars)
                    fileName: originalFileName,
                    mediaKind: kind,
                    isPending: false,
                    isReceived: oldMsg.isReceived,
                    isRead: oldMsg.isRead,
                    msgID: existingMsgID,
                  );
                  // CRITICAL: Check if message was already updated to avoid duplicate messages in UI
                  // If message is already completed (isPending=false) and has a non-temp filePath,
                  // it means it was already processed by progress_recv, so we should skip emitting to stream
                  final wasAlreadyCompleted = !oldMsg.isPending &&
                      oldMsg.filePath != null &&
                      !oldMsg.filePath!.contains('/receiving_');

                  history[index] = updatedMsg;
                  _lastByPeer[normalizedUid] = updatedMsg;
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: Updated message in history, new filePath=$finalPath, wasAlreadyCompleted=$wasAlreadyCompleted');
                  if (actualFileNumber != null && existingMsgID != null) {
                    // CRITICAL: Check if other files are using the same fileNumber before cleaning up
                    // This prevents fileNumber reuse from causing state confusion
                    final otherFiles = _fileReceiveProgress.entries
                        .where((e) =>
                            e.key.$2 == actualFileNumber &&
                            (e.key.$1 == normalizedUid || e.key.$1 == uid))
                        .where((e) => e.value.msgID != existingMsgID)
                        .toList();

                    if (otherFiles.isNotEmpty) {
                      _logger?.logWarning(
                          '[FfiChatService] _handleFileDone: WARNING - Other files using same fileNumber=$actualFileNumber: ${otherFiles.map((e) => e.value.msgID).join(", ")}');
                      // Only remove entries for this specific msgID, not all entries with this fileNumber
                      _fileReceiveProgress.removeWhere((key, value) =>
                          key.$2 == actualFileNumber &&
                          (key.$1 == normalizedUid || key.$1 == uid) &&
                          value.msgID == existingMsgID);
                      _pendingFileTransfers.removeWhere((key, value) =>
                          key.$2 == actualFileNumber &&
                          (key.$1 == normalizedUid || key.$1 == uid) &&
                          value == existingMsgID);
                      // Only remove _fileNumberToMsgID mapping for this specific msgID
                      _fileNumberToMsgID.removeWhere((key, value) =>
                          key.$2 == actualFileNumber &&
                          (key.$1 == normalizedUid || key.$1 == uid) &&
                          value == existingMsgID);
                    } else {
                      // No other files using this fileNumber, safe to remove all entries
                      _fileReceiveProgress
                          .remove((normalizedUid, actualFileNumber));
                      _fileReceiveProgress.remove((uid, actualFileNumber));
                      _pendingFileTransfers
                          .remove((normalizedUid, actualFileNumber));
                      _pendingFileTransfers.remove((uid, actualFileNumber));
                      _fileNumberToMsgID
                          .remove((normalizedUid, actualFileNumber));
                      _fileNumberToMsgID.remove((uid, actualFileNumber));
                    }
                    _msgIDToFileTransfer.remove(existingMsgID);
                    _progressKeyCache.removeWhere((_, v) =>
                        v.$2 == actualFileNumber &&
                        (v.$1 == normalizedUid || v.$1 == uid));
                    _logger?.log(
                        '[FfiChatService] _handleFileDone: Cleaned up file transfer tracking for fileNumber=$actualFileNumber, msgID=$existingMsgID');
                  }
                  // CRITICAL: Always emit updated message to stream when isPending changes from true to false
                  // This ensures UI is notified when file transfer completes, even if file was already moved
                  // Check if isPending status changed (from true to false) - this is the key indicator
                  final isPendingStatusChanged =
                      oldMsg.isPending && !updatedMsg.isPending;
                  if (!wasAlreadyCompleted || isPendingStatusChanged) {
                    _messages.add(updatedMsg);
                    _logger?.log(
                        '[FfiChatService] _handleFileDone: Emitted updated message to stream (wasAlreadyCompleted=$wasAlreadyCompleted, isPendingStatusChanged=$isPendingStatusChanged)');
                  } else {
                    _logger?.log(
                        '[FfiChatService] _handleFileDone: Message was already completed, skipping stream emission to avoid duplicate');
                  }
                  unawaited(
                      _sendReceipt(normalizedUid, existingMsgID, 'received'));
                  // Save updated history
                  unawaited(_saveHistory(normalizedUid));
                  // Remove from processing set after successful completion
                  _processingFileDone.remove(processingKey);
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: ✅ Message updated successfully, msgID=$existingMsgID');
                } else {
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: ⚠️ Message not found in history, msgID=$existingMsgID, history size=${history.length}, history msgIDs=${history.map((m) => m.msgID).take(5).join(", ")}...');
                  // Message not found, remove from processing set
                  _processingFileDone.remove(processingKey);
                }
              }
            } else {
              // Try to find any pending file message for this uid and update it
              // Use normalized ID for consistency
              var history = _historyById[normalizedUid];
              if (history == null && uid != normalizedUid) {
                history = _historyById[uid];
              }
              if (history != null) {
                // Find the most recent pending file message
                for (int i = history.length - 1; i >= 0; i--) {
                  final msg = history[i];
                  // CRITICAL: Only update messages that are still pending to avoid duplicates
                  // If message is already completed, it means it was processed by progress_recv,
                  // so we should skip it to avoid creating duplicate messages
                  if (msg.isPending == true &&
                      msg.filePath != null &&
                      msg.filePath!.contains('/receiving_')) {
                    // Update this message
                    final updatedMsg = ChatMessage(
                      text: msg.text,
                      fromUserId: msg.fromUserId,
                      isSelf: msg.isSelf,
                      timestamp: msg.timestamp,
                      groupId: msg.groupId,
                      filePath: finalPath,
                      fileName: fileName ?? msg.fileName,
                      mediaKind: kind,
                      isPending: false,
                      isReceived: msg.isReceived,
                      isRead: msg.isRead,
                      msgID: msg.msgID,
                    );
                    history[i] = updatedMsg;
                    // Use normalized ID for consistency
                    _lastByPeer[normalizedUid] = updatedMsg;
                    _messages.add(updatedMsg);
                    _logger?.log(
                        '[FfiChatService] _handleFileDone: Updated pending message, msgID=${msg.msgID}');
                    if (msg.msgID != null) {
                      unawaited(
                          _sendReceipt(normalizedUid, msg.msgID!, 'received'));
                    }
                    // Save updated history
                    unawaited(_saveHistory(normalizedUid));
                    // Remove from processing set after successful completion
                    _processingFileDone.remove(processingKey);
                    break;
                  }
                }
              }
              // If no pending message found, remove from processing set
              if (_processingFileDone.contains(processingKey)) {
                _processingFileDone.remove(processingKey);
              }
            }
          } else {
            // File doesn't exist, but we should still try to find and update the message
            // This handles cases where file was already processed by progress_recv but file_done event arrives later
            _logger?.log(
                '[FfiChatService] _handleFileDone: Final file does not exist, but attempting to find and update message');
            if (existingMsgID != null) {
              _logger?.log(
                  '[FfiChatService] _handleFileDone: Found existing message (file doesn\'t exist), msgID=$existingMsgID');
              // Use normalized ID for consistency (see migration comment above).
              var history =
                  _messageHistoryPersistence.getCachedList(normalizedUid);
              if (history == null && uid != normalizedUid) {
                history = _messageHistoryPersistence.getCachedList(uid);
                if (history != null && history.isNotEmpty) {
                  _messageHistoryPersistence.setCachedHistory(
                      normalizedUid, history);
                  _messageHistoryPersistence.removeCachedHistory(uid);
                  history =
                      _messageHistoryPersistence.getCachedList(normalizedUid);
                }
              }
              _logger?.log(
                  '[FfiChatService] _handleFileDone: Checking history for msgID=$existingMsgID, history size=${history?.length ?? 0}, normalizedUid=$normalizedUid, uid=$uid');
              if (history != null) {
                final index =
                    history.indexWhere((m) => m.msgID == existingMsgID);
                _logger?.log(
                    '[FfiChatService] _handleFileDone: Message search result: index=$index (>=0 means found)');
                if (index >= 0) {
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: Found message at index $index in history (file doesn\'t exist)');
                  final oldMsg = history[index];
                  // If message is already completed (isPending=false), just ensure it's marked as complete
                  // Use the existing filePath if available, otherwise use finalPath even though file doesn't exist
                  String? messageFilePath = oldMsg.filePath;
                  if (messageFilePath == null ||
                      messageFilePath.contains('/receiving_')) {
                    // Message still has temp path, try to use finalPath even though file doesn't exist
                    // This ensures the message is marked as complete
                    messageFilePath = finalPath;
                  }
                  String? originalFileName = oldMsg.fileName;
                  // Try both normalized and original ID for file progress
                  if (actualFileNumber != null) {
                    if (_fileReceiveProgress
                        .containsKey((normalizedUid, actualFileNumber))) {
                      originalFileName = _fileReceiveProgress[(
                        normalizedUid,
                        actualFileNumber
                      )]!
                          .fileName;
                    } else if (_fileReceiveProgress
                        .containsKey((uid, actualFileNumber))) {
                      originalFileName =
                          _fileReceiveProgress[(uid, actualFileNumber)]!
                              .fileName;
                    }
                  }
                  // CRITICAL: Check if message was already updated to avoid duplicate messages in UI
                  // If message is already completed (isPending=false) and has a non-temp filePath,
                  // it means it was already processed by progress_recv, so we should skip emitting to stream
                  final wasAlreadyCompleted = !oldMsg.isPending &&
                      oldMsg.filePath != null &&
                      !oldMsg.filePath!.contains('/receiving_');

                  final updatedMsg = ChatMessage(
                    text: oldMsg.text,
                    fromUserId: oldMsg.fromUserId,
                    isSelf: oldMsg.isSelf,
                    timestamp: oldMsg.timestamp,
                    groupId: oldMsg.groupId,
                    filePath:
                        messageFilePath, // Use existing filePath or finalPath
                    fileName: originalFileName ?? oldMsg.fileName,
                    mediaKind: kind,
                    isPending:
                        false, // Mark as complete even if file doesn't exist
                    isReceived: oldMsg.isReceived,
                    isRead: oldMsg.isRead,
                    msgID: existingMsgID,
                  );
                  history[index] = updatedMsg;
                  _lastByPeer[normalizedUid] = updatedMsg;
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: Updated message in history (file doesn\'t exist), new filePath=$messageFilePath, isPending=false, wasAlreadyCompleted=$wasAlreadyCompleted');
                  if (actualFileNumber != null && existingMsgID != null) {
                    // Clean up file transfer tracking
                    final otherFiles = _fileReceiveProgress.entries
                        .where((e) =>
                            e.key.$2 == actualFileNumber &&
                            (e.key.$1 == normalizedUid || e.key.$1 == uid))
                        .where((e) => e.value.msgID != existingMsgID)
                        .toList();

                    if (otherFiles.isNotEmpty) {
                      _logger?.logWarning(
                          '[FfiChatService] _handleFileDone: WARNING - Other files using same fileNumber=$actualFileNumber: ${otherFiles.map((e) => e.value.msgID).join(", ")}');
                      // Only remove entries for this specific msgID
                      _fileReceiveProgress.removeWhere((key, value) =>
                          key.$2 == actualFileNumber &&
                          (key.$1 == normalizedUid || key.$1 == uid) &&
                          value.msgID == existingMsgID);
                      _pendingFileTransfers.removeWhere((key, value) =>
                          key.$2 == actualFileNumber &&
                          (key.$1 == normalizedUid || key.$1 == uid) &&
                          value == existingMsgID);
                      _fileNumberToMsgID.removeWhere((key, value) =>
                          key.$2 == actualFileNumber &&
                          (key.$1 == normalizedUid || key.$1 == uid) &&
                          value == existingMsgID);
                    } else {
                      // No other files using this fileNumber, safe to remove all entries
                      _fileReceiveProgress
                          .remove((normalizedUid, actualFileNumber));
                      _fileReceiveProgress.remove((uid, actualFileNumber));
                      _pendingFileTransfers
                          .remove((normalizedUid, actualFileNumber));
                      _pendingFileTransfers.remove((uid, actualFileNumber));
                      _fileNumberToMsgID
                          .remove((normalizedUid, actualFileNumber));
                      _fileNumberToMsgID.remove((uid, actualFileNumber));
                    }
                    _msgIDToFileTransfer.remove(existingMsgID);
                    _progressKeyCache.removeWhere((_, v) =>
                        v.$2 == actualFileNumber &&
                        (v.$1 == normalizedUid || v.$1 == uid));
                    _logger?.log(
                        '[FfiChatService] _handleFileDone: Cleaned up file transfer tracking for fileNumber=$actualFileNumber, msgID=$existingMsgID');
                  }
                  // CRITICAL: Only emit updated message to stream if it wasn't already completed
                  // This prevents duplicate messages in UI when progress_recv and file_done both trigger _handleFileDone
                  if (!wasAlreadyCompleted) {
                    _messages.add(updatedMsg);
                    _logger?.log(
                        '[FfiChatService] _handleFileDone: Emitted updated message to stream (file doesn\'t exist)');
                  } else {
                    _logger?.log(
                        '[FfiChatService] _handleFileDone: Message was already completed (file doesn\'t exist), skipping stream emission to avoid duplicate');
                  }
                  unawaited(
                      _sendReceipt(normalizedUid, existingMsgID, 'received'));
                  // Save updated history
                  unawaited(_saveHistory(normalizedUid));
                  // Remove from processing set after successful completion
                  _processingFileDone.remove(processingKey);
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: ✅ Message updated successfully (file doesn\'t exist), msgID=$existingMsgID');
                } else {
                  _logger?.log(
                      '[FfiChatService] _handleFileDone: ⚠️ Message not found in history (file doesn\'t exist), msgID=$existingMsgID, history size=${history.length}');
                  // Message not found, remove from processing set
                  _processingFileDone.remove(processingKey);
                }
              } else {
                _logger?.log(
                    '[FfiChatService] _handleFileDone: ⚠️ History not found (file doesn\'t exist), normalizedUid=$normalizedUid, uid=$uid');
                // History not found, remove from processing set
                _processingFileDone.remove(processingKey);
              }
            } else {
              _logger?.log(
                  '[FfiChatService] _handleFileDone: ⚠️ No message found and file doesn\'t exist, fileNumber=$actualFileNumber, fileName=$fileName');
              // No message found and file doesn't exist, remove from processing set
              _processingFileDone.remove(processingKey);
            }
          }
        }).catchError((e, stackTrace) {
          // Remove from processing set on error
          _logger?.logError(
              '[FfiChatService] _handleFileDone: ERROR in finalPathFuture.then',
              e,
              stackTrace);
          _processingFileDone.remove(processingKey);
        }));
      } else {
        _logger?.log(
            '[FfiChatService] _handleFileDone: Unknown file kind ($fileKind), verifying file exists');
        // Unknown file kind: just verify and update message
        final file = File(path);
        file.exists().then((exists) {
          _logger?.log(
              '[FfiChatService] _handleFileDone: File exists check: $exists');
          if (exists) {
            file.length().then((fileSize) {
              _logger?.log(
                  '[FfiChatService] _handleFileDone: File size: $fileSize bytes');
              String? existingMsgID;
              int? fileNumber;
              for (final entry in _fileReceiveProgress.entries) {
                if (entry.key.$1 == uid && entry.value.total == fileSize) {
                  existingMsgID = entry.value.msgID;
                  fileNumber = entry.key.$2;
                  break;
                }
              }
              if (existingMsgID != null) {
                final history = _historyById[uid];
                if (history != null) {
                  final index =
                      history.indexWhere((m) => m.msgID == existingMsgID);
                  if (index >= 0) {
                    final oldMsg = history[index];
                    String? originalFileName = oldMsg.fileName;
                    if (fileNumber != null &&
                        _fileReceiveProgress.containsKey((uid, fileNumber))) {
                      originalFileName =
                          _fileReceiveProgress[(uid, fileNumber)]!.fileName;
                    }
                    final kind = _detectKind(path);
                    final updatedMsg = ChatMessage(
                      text: oldMsg.text,
                      fromUserId: oldMsg.fromUserId,
                      isSelf: oldMsg.isSelf,
                      timestamp: oldMsg.timestamp,
                      groupId: oldMsg.groupId,
                      filePath: path,
                      fileName: originalFileName,
                      mediaKind: kind,
                      isPending: false,
                      isReceived: oldMsg.isReceived,
                      isRead: oldMsg.isRead,
                      msgID: existingMsgID,
                    );
                    history[index] = updatedMsg;
                    _lastByPeer[uid] = updatedMsg;
                    if (fileNumber != null) {
                      _fileReceiveProgress.remove((uid, fileNumber));
                      _pendingFileTransfers.remove((uid, fileNumber));
                      _msgIDToFileTransfer.remove(existingMsgID);
                    }
                    _messages.add(updatedMsg);
                    unawaited(_sendReceipt(uid, existingMsgID, 'received'));
                    // Remove from processing set after successful completion
                    _processingFileDone.remove(processingKey);
                  } else {
                    // Message not found, remove from processing set
                    _processingFileDone.remove(processingKey);
                  }
                } else {
                  // History not found, remove from processing set
                  _processingFileDone.remove(processingKey);
                }
              } else {
                // File size doesn't match, remove from processing set
                _processingFileDone.remove(processingKey);
              }
            }).catchError((e, stackTrace) {
              _logger?.logError(
                  '[FfiChatService] _handleFileDone: ERROR in file.exists().then',
                  e,
                  stackTrace);
              // Remove from processing set on error
              _processingFileDone.remove(processingKey);
            });
          } else {
            _logger
                ?.log('[FfiChatService] _handleFileDone: File does not exist');
            // File doesn't exist, remove from processing set
            _processingFileDone.remove(processingKey);
          }
        }).catchError((e) {
          // Remove from processing set on error
          _processingFileDone.remove(processingKey);
        });
      }
    } catch (e, stackTrace) {
      _logger?.log(
          '[FfiChatService] ========== _handleFileDone EXCEPTION ==========');
      _logger?.logError(
          '[FfiChatService] ERROR: Exception in _handleFileDone: $e',
          e,
          stackTrace);
      _logger?.log(
          '[FfiChatService] Exception details - uid=$uid, fileKind=$fileKind, path=$path');
      _processingFileDone.remove(processingKey);
      _logger?.log(
          '[FfiChatService] ========== _handleFileDone EXCEPTION END ==========');
    } finally {
      _logger
          ?.log('[FfiChatService] ========== _handleFileDone END ==========');
    }
  }

  /// Sends a C2C text. [cloudCustomData] (optional) is the structured V2TIM
  /// metadata the UIKit composer builds for a REPLY
  /// (`{"messageReply":{messageID,messageAbstract,...}}`); it is persisted on the
  /// sender-side ChatMessage so the quote survives a reload (previously the quote
  /// lived only on the in-memory message and was lost on cold start).
  ///
  /// SCOPE (deliberate, documented): it is NOT sent over Tox (`_ffi.sendText`
  /// carries plain text only — the peer never sees the quote) and it is NOT
  /// carried through the OFFLINE queue (a reply sent while the peer is offline
  /// persists as plain text). Both are out of scope for this sender-side
  /// persistence fix and are tracked follow-ups.
  Future<void> sendText(String peerId, String text,
      {String? cloudCustomData}) async {
    // Normalize friend ID to 64 characters (public key length)
    final normalizedPeerId = _normalizeFriendId(peerId);
    // Check if friend is online
    final friends = await getFriendList();
    final friend = friends.firstWhere((f) => f.userId == normalizedPeerId,
        orElse: () => (
              userId: normalizedPeerId,
              nickName: '',
              status: '',
              online: false
            ));
    final isOnline = friend.online;

    if (!isOnline) {
      await _queueOfflineText(normalizedPeerId, text,
          cloudCustomData: cloudCustomData);
      return;
    }

    // Friend is online - send immediately.
    // P1-1 (text-send): include the monotonic `_msgIDSequence` like the inbound
    // and file-send paths, so two C2C texts sent in the same millisecond don't
    // produce an identical `${ms}_$_selfId` msgID — the history-dedup path
    // treats msgID as primary identity and would silently drop the second send.
    // Mirrors the file-send fix below and the inbound format `${ms}_${seq}_x`.
    final msgID =
        '${DateTime.now().millisecondsSinceEpoch}_${_msgIDSequence++}_$_selfId';
    final pto = normalizedPeerId.toNativeUtf8();
    final pmsg = text.toNativeUtf8();
    _ffi.sendText(pto, pmsg);
    pkgffi.malloc.free(pto);
    pkgffi.malloc.free(pmsg);
    final msg = ChatMessage(
      text: text,
      fromUserId: _selfId,
      isSelf: true,
      timestamp: DateTime.now(),
      groupId: null,
      isPending: false,
      msgID: msgID,
      // Reply quote (sender-side persistence). Null for a plain send.
      cloudCustomData: cloudCustomData,
    );
    _lastByPeer[normalizedPeerId] = msg;
    _appendHistory(normalizedPeerId, msg);
    _messages.add(msg);
  }

  // Enqueue a text send for a friend that is offline (or that flipped offline
  // between the pre-check and the FFI call). The UI sees a pending bubble
  // immediately; drain on the next online transition resends and clears it.
  Future<void> _queueOfflineText(String normalizedPeerId, String text,
      {String? cloudCustomData}) async {
    // INVARIANT (drain depends on this): the queue item's `timestamp` and the
    // pending ChatMessage's `timestamp` MUST be the same instant. `_drainTextItem`
    // identifies this item's pending row by EXACT-ms timestamp equality
    // (item.timestamp == row.timestamp), so both are built from one `now` below.
    // If you ever split these into separate DateTime.now() calls, the drain
    // matcher will silently stop finding the row — keep them identical.
    final now = DateTime.now();
    // Compute the pending row's msgID BEFORE enqueuing so the queue item can
    // carry it (durable identity — the drain matchers prefer it over the
    // exact-ms timestamp fallback).
    final timestamp = now.millisecondsSinceEpoch;
    final sequence = _msgIDSequence++;
    final msgID = '${timestamp}_${sequence}_$_selfId';
    _addToOfflineQueue(normalizedPeerId, (
      kind: 'text',
      text: text,
      filePath: null,
      fileName: null,
      timestamp: now,
      msgID: msgID,
    ));
    final msg = ChatMessage(
      text: text,
      fromUserId: _selfId,
      isSelf: true,
      timestamp: now,
      groupId: null,
      isPending: true,
      msgID: msgID,
      // Reply/forward quote (sender-side persistence). Carried even while the
      // peer is offline so the local quote bubble survives reload; copyWith on
      // drain (`_drainTextItem`) preserves it. The offline queue item — which
      // drives the wire-resend — intentionally omits it (the quote is not sent
      // over Tox; documented S18 limitation).
      cloudCustomData: cloudCustomData,
    );
    _lastByPeer[normalizedPeerId] = msg;
    _appendHistory(normalizedPeerId, msg);
    _messages.add(msg);
    await _saveOfflineQueue();
  }

  // Enqueue a file send for a friend that is offline (or that flipped offline
  // mid-send). Surfaces a pending file bubble; drain replays via sendFile().
  Future<void> _queueOfflineFile(
      String normalizedPeerId, String filePath) async {
    // INVARIANT (drain depends on this): the queue item and the pending row
    // MUST share this one `now` — `_drainFileItem` / `_markPendingItemFailed`
    // identify this item's row by EXACT-ms timestamp equality. Don't split.
    final now = DateTime.now();
    final fileName = p.basename(filePath);
    // Compute msgID before enqueuing so the queue item carries the durable id.
    final timestamp = now.millisecondsSinceEpoch;
    final sequence = _msgIDSequence++;
    final msgID = '${timestamp}_${sequence}_$_selfId';
    _addToOfflineQueue(normalizedPeerId, (
      kind: 'file',
      text: '',
      filePath: filePath,
      fileName: fileName,
      timestamp: now,
      msgID: msgID,
    ));
    final kind = _detectKind(filePath);
    final msg = ChatMessage(
      text: '',
      fromUserId: _selfId,
      isSelf: true,
      timestamp: now,
      groupId: null,
      filePath: filePath,
      fileName: fileName,
      mediaKind: kind,
      isPending: true,
      msgID: msgID,
    );
    _lastByPeer[normalizedPeerId] = msg;
    _appendHistory(normalizedPeerId, msg);
    _messages.add(msg);
    await _saveOfflineQueue();
  }

  Future<void> updateSelfProfile(
      {required String nickname, required String statusMessage}) async {
    final pnick = nickname.toNativeUtf8();
    final pstat = statusMessage.toNativeUtf8();
    _ffi.setSelfInfo(pnick, pstat);
    pkgffi.malloc.free(pnick);
    pkgffi.malloc.free(pstat);
  }

  Future<List<({String userId, String nickName, String status, bool online})>>
      getFriendList() async {
    final buf = pkgffi.malloc.allocate<ffi.Int8>(64 * 1024);
    final n = _ffi.getFriendList(buf, 64 * 1024);
    final List<({String userId, String nickName, String status, bool online})>
        out = [];
    if (n > 0) {
      final s = buf.cast<pkgffi.Utf8>().toDartString();
      for (final line in s.split('\n')) {
        if (line.isEmpty) continue;
        final parts = line.split('\t');
        final uid = parts.isNotEmpty ? parts[0] : '';
        var nick = parts.length > 1 ? parts[1] : '';
        final online = (parts.length > 2 ? parts[2] : '0') == '1';
        if (uid.isNotEmpty) {
          // If nickname is empty from Tox, try to load from local cache
          if (nick.isEmpty) {
            final cachedNick = await _prefs?.getFriendNickname(uid);
            if (cachedNick != null && cachedNick.isNotEmpty) {
              nick = cachedNick;
            }
          } else {
            // Save nickname to local cache when we get it from Tox
            await _prefs?.setFriendNickname(uid, nick);
          }

          // Load status from cache (FFI doesn't return status, it comes via status_changed events)
          // On startup, use cached status; when friend comes online, status will be updated via status_changed event
          var status = '';
          final cachedStatus = await _prefs?.getFriendStatusMessage(uid);
          if (cachedStatus != null && cachedStatus.isNotEmpty) {
            status = cachedStatus;
          }

          out.add(
              (userId: uid, nickName: nick, status: status, online: online));
          // Track friend online status and send avatar when friend comes online
          final normalizedUid = _normalizeFriendId(uid);
          final previousStatus =
              _friendOnlineStatus[normalizedUid] ?? _friendOnlineStatus[uid];
          _friendOnlineStatus[normalizedUid] = online ? 'online' : 'offline';
          // If friend just came online, send avatar if needed and send pending messages
          if (online && previousStatus != 'online') {
            unawaited(_sendAvatarToFriendIfNeeded(uid));
            // Send pending offline messages - use normalized ID
            unawaited(_sendPendingMessages(normalizedUid));
            // Update nickname from Tox when friend comes online
            if (nick.isNotEmpty) {
              await _prefs?.setFriendNickname(uid, nick);
            }
            // Note: Contact refresh should be handled by the client layer
            // The framework no longer directly triggers UI updates
          }
        }
      }
    }
    pkgffi.malloc.free(buf);
    return out;
  }

  /// Preferences key for the set of dismissed friend-application fingerprints.
  /// The C++ layer has no native "drop application" call, so we filter
  /// dismissed entries out of [getFriendApplications] here. Stored via
  /// `getStringList`/`setStringList` on the injected
  /// [ExtendedPreferencesService]; the host's adapter is responsible for any
  /// per-account scoping it needs.
  ///
  /// Each entry is a fingerprint of `<userId>|<wording>` (see [_fingerprint]).
  /// Pinning to wording — not userId alone — is what makes a *new* application
  /// from the same peer surface again after the previous one was dismissed.
  /// The C++ queue re-emits the original entry on every poll with identical
  /// wording, so it still matches and stays filtered; a fresh request from
  /// the peer will typically carry different wording and bypass the filter.
  ///
  /// Visible-for-testing: exposed via [dismissedFriendApplicationsKey].
  static const String _kDismissedFriendApplicationsKey =
      'dismissed_friend_applications';

  /// Visible-for-testing accessor for [_kDismissedFriendApplicationsKey].
  static String get dismissedFriendApplicationsKey =>
      _kDismissedFriendApplicationsKey;

  /// Build the fingerprint stored in the dismissed set. The `|` separator
  /// cannot collide with the userId (64-char hex) and is distinct from the
  /// `\t` used by the FFI list encoding.
  static String _fingerprint(String userId, String wording) =>
      '$userId|$wording';

  /// Visible-for-testing: applies the dismissed-application filter to a raw
  /// list (the FFI-derived list, in the production path). Static and pure so
  /// it can be unit-tested without an FFI library or a running service.
  static List<({String userId, String wording})> filterDismissedApplications(
    List<({String userId, String wording})> raw,
    Set<String> dismissed,
  ) {
    if (dismissed.isEmpty) return raw;
    return raw.where((app) {
      final fp = _fingerprint(
        _normalizeApplicationUserIdValue(app.userId),
        app.wording,
      );
      return !dismissed.contains(fp);
    }).toList();
  }

  /// Visible-for-testing: remove every dismissed fingerprint belonging to an
  /// accepted peer while preserving unrelated peer entries.
  static Set<String> clearDismissedApplicationsForAcceptedUser(
    Set<String> dismissed,
    String userID,
  ) {
    if (dismissed.isEmpty) return dismissed;
    final normalized = _normalizeApplicationUserIdValue(userID);
    final prefix = '$normalized|';
    return dismissed.where((fp) => !fp.startsWith(prefix)).toSet();
  }

  /// Load the persisted set of dismissed friend-application fingerprints.
  /// Returns an empty set when no preferences service is attached or no
  /// entries exist. Legacy entries (pre-fingerprint format: bare userIds with
  /// no `|wording` suffix) are dropped on read — they were created with
  /// userId-only semantics that permanently filtered every future application
  /// from the same peer; treating them as stale once is the migration. The
  /// dropped entries are re-persisted so the migration only happens once.
  Future<Set<String>> _getDismissedFriendApplications() async {
    final prefs = _prefs;
    if (prefs == null) return <String>{};
    final list = await prefs.getStringList(_kDismissedFriendApplicationsKey);
    if (list == null || list.isEmpty) return <String>{};
    final fingerprints = list.where((s) => s.contains('|')).toList();
    if (fingerprints.length != list.length) {
      // Drop legacy bare-userId entries by re-saving the filtered list.
      await prefs.setStringList(
        _kDismissedFriendApplicationsKey,
        fingerprints,
      );
    }
    return fingerprints.toSet();
  }

  Future<void> _saveDismissedFriendApplications(
      Set<String> fingerprints) async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setStringList(
      _kDismissedFriendApplicationsKey,
      fingerprints.toList(),
    );
  }

  /// Normalize a friend-application user ID to its 64-char public key for
  /// stable comparison with native data (which always emits a 64-char key).
  static String _normalizeApplicationUserIdValue(String userID) =>
      userID.length > 64 ? userID.substring(0, 64) : userID;

  String _normalizeApplicationUserId(String userID) =>
      _normalizeApplicationUserIdValue(userID);

  /// Read the unfiltered friend-application list from the FFI layer.
  ///
  /// Production callers go through [getFriendApplications], which applies the
  /// dismissed-filter on top of this. Refuse/delete paths need the raw view
  /// so they can capture the current wording for each entry matching the
  /// target userId.
  Future<List<({String userId, String wording})>>
      _getFriendApplicationsUnfiltered() async {
    final buf = pkgffi.malloc.allocate<ffi.Int8>(32 * 1024);
    // Use current instance ID at call time so runWithInstanceAsync(Alice) gets Alice's list
    final instanceId = _ffi.getCurrentInstanceId();
    final n = _ffi.getFriendApplicationsForInstance(instanceId, buf, 32 * 1024);
    final out = <({String userId, String wording})>[];
    if (n > 0) {
      final s = buf.cast<pkgffi.Utf8>().toDartString();
      for (final line in s.split('\n')) {
        if (line.isEmpty) continue;
        final parts = line.split('\t');
        final uid = parts.isNotEmpty ? parts[0] : '';
        final words = parts.length > 1 ? parts[1] : '';
        if (uid.isNotEmpty) out.add((userId: uid, wording: words));
      }
    }
    pkgffi.malloc.free(buf);
    return out;
  }

  /// Wordings surfaced by [getFriendApplications] per userId since startup.
  ///
  /// Acts as a fallback source for [refuseFriendApplication]: if the C++
  /// queue has already been consumed between the most recent poll and the
  /// user's refuse tap, we can still record the right
  /// `(userId, wording)` fingerprint from what the UI was last shown.
  /// Without this, a refuse click after the C++ queue drains is a silent
  /// no-op and the refused application reappears on the next poll.
  ///
  /// Cleared per-userId on [acceptFriendRequest] (the user explicitly chose
  /// to accept, so old wordings are no longer interesting) and on dispose.
  final Map<String, Set<String>> _observedApplicationWordings = {};

  Future<List<({String userId, String wording})>>
      getFriendApplications() async {
    final raw = await _getFriendApplicationsUnfiltered();

    // Remember the wordings the UI is being shown so refuseFriendApplication
    // can fall back to them if the C++ queue clears the entry before the user
    // taps refuse. We snapshot from the unfiltered list because the dismissed
    // filter below removes entries the user has already refused — those are
    // already in the persisted dismissed set and don't need re-snapshotting.
    for (final app in raw) {
      final norm = _normalizeApplicationUserId(app.userId);
      _observedApplicationWordings
          .putIfAbsent(norm, () => <String>{})
          .add(app.wording);
    }

    // Filter out applications the user has explicitly refused/deleted. Without
    // this, the C++ application queue keeps returning the same entries every
    // 5s poll because there is no native "dismiss" call.
    final dismissed = await _getDismissedFriendApplications();
    final filtered = filterDismissedApplications(raw, dismissed);
    if (raw.isNotEmpty || dismissed.isNotEmpty) {
      _logger?.log(
        '[FfiChatService] getFriendApplications '
        'raw=${raw.map((a) => '${_normalizeApplicationUserId(a.userId)}:${a.wording}').toList()} '
        'dismissed=${dismissed.toList()} '
        'filtered=${filtered.map((a) => '${_normalizeApplicationUserId(a.userId)}:${a.wording}').toList()}',
      );
    }
    return filtered;
  }

  /// Mark all currently-pending friend applications from [userID] as dismissed
  /// (refused). Persists the `(userId, wording)` fingerprint of every matching
  /// entry the C++ queue is currently surfacing, so they no longer reappear in
  /// [getFriendApplications] across polls or restarts.
  ///
  /// A subsequent fresh application from the same peer with different wording
  /// surfaces again — that is the whole point of the wording-aware
  /// fingerprint. If the peer happens to re-send with identical wording the
  /// user can simply dismiss again.
  ///
  /// Idempotent. If the C++ queue no longer surfaces an entry for [userID] at
  /// call time, falls back to the wordings observed via [getFriendApplications]
  /// since startup ([_observedApplicationWordings]) — this covers the case
  /// where the poll has already consumed the C++ entry between the UI render
  /// and the user's refuse tap. Only a refuse click for a userId we've truly
  /// never seen is a no-op.
  Future<void> refuseFriendApplication(String userID) async {
    final normalized = _normalizeApplicationUserId(userID);
    final apps = await _getFriendApplicationsUnfiltered();
    final liveWordings = apps
        .where((a) => _normalizeApplicationUserId(a.userId) == normalized)
        .map((a) => a.wording)
        .toSet();

    final wordings = liveWordings.isNotEmpty
        ? liveWordings
        : (_observedApplicationWordings[normalized] ?? const <String>{});
    if (wordings.isEmpty) return;

    final dismissed = await _getDismissedFriendApplications();
    bool changed = false;
    for (final w in wordings) {
      if (dismissed.add(_fingerprint(normalized, w))) {
        changed = true;
      }
    }
    if (changed) {
      await _saveDismissedFriendApplications(dismissed);
    }
  }

  /// Mark a friend application as dismissed (deleted). Same semantics as
  /// [refuseFriendApplication] from Tim2Tox's perspective: both simply drop
  /// the entry from the local application queue.
  Future<void> deleteFriendApplication(String userID) async {
    await refuseFriendApplication(userID);
  }

  Future<void> acceptFriendRequest(String userId) async {
    final p = userId.toNativeUtf8();
    final int rc;
    try {
      // P0-A3: previously the return value was discarded, so a failed
      // tox_friend_add_norequest (own_key, malloc fail, etc.) was silently
      // dropped and the UI still treated the application as accepted. Now
      // we surface the failure so callers can show an error and the
      // application stays in the pending list for retry.
      rc = _ffi.acceptFriend(p);
    } finally {
      pkgffi.malloc.free(p);
    }
    if (rc != 1) {
      _logger?.log(
          '[FfiChatService] acceptFriendRequest: FFI returned rc=$rc for userId=$userId');
      throw StateError('acceptFriend failed (rc=$rc) for $userId');
    }
    // If this user was previously dismissed and is now being accepted, clear
    // every fingerprint for that userId so a future re-request from the same
    // peer surfaces regardless of wording.
    await clearDismissedApplicationsAfterAccept(userId);
  }

  /// Post-accept cleanup, factored out of [acceptFriendRequest] so the persist
  /// step can run — and be verified — independently of the FFI accept it
  /// follows (the FFI accept can't succeed in a unit test). Clears every
  /// dismissed fingerprint for [userId] so a future re-request from the same
  /// peer surfaces regardless of wording, drops the observed-wording snapshot,
  /// and persists the trimmed set only when it actually changed.
  Future<void> clearDismissedApplicationsAfterAccept(String userId) async {
    final normalized = _normalizeApplicationUserId(userId);
    final dismissed = await _getDismissedFriendApplications();
    final updated = clearDismissedApplicationsForAcceptedUser(
      dismissed,
      normalized,
    );
    if (updated.length != dismissed.length) {
      await _saveDismissedFriendApplications(updated);
    }
    // Once accepted, future requests from this peer are interesting again
    // regardless of past wording.
    _observedApplicationWordings.remove(normalized);
  }

  Future<void> removeFriend(String userId) async {
    // P0-A4: centralize on deleteFriend. Previously this method called the
    // FFI deleteFriend directly without writing the prefs side — the result
    // was a friend that disappeared from Tox but lingered in
    // Prefs.localFriends, surfacing as a ghost contact after restart. Now
    // we do the in-flight cleanup (formerly tracked under P2-21) and then
    // delegate to deleteFriend so both Tox state and local persistence are
    // updated atomically by the same code path.
    final normalizedUid =
        userId.length > 64 ? _normalizeFriendId(userId) : userId;
    bool matchesUid((String, int) key) =>
        key.$1 == normalizedUid || key.$1 == userId;

    final affectedTempPaths = <String>{};
    final affectedActualPaths = <String>{};
    for (final entry in _fileReceiveProgress.entries) {
      if (matchesUid(entry.key)) {
        final tp = entry.value.tempPath;
        final ap = entry.value.actualPath;
        if (tp != null && tp.isNotEmpty) affectedTempPaths.add(tp);
        if (ap != null && ap.isNotEmpty) affectedActualPaths.add(ap);
      }
    }
    _fileReceiveProgress.removeWhere((k, _) => matchesUid(k));
    _pendingFileTransfers.removeWhere((k, _) => matchesUid(k));
    _fileNumberToMsgID.removeWhere((k, _) => matchesUid(k));
    _lastProgressTs.removeWhere((k, _) => matchesUid(k));
    _pausedTransfers.removeWhere((k) => matchesUid(k));
    _msgIDToFileTransfer
        .removeWhere((_, v) => v.$1 == normalizedUid || v.$1 == userId);
    _friendOnlineStatus.remove(userId);
    _friendOnlineStatus.remove(normalizedUid);
    _lastSentPathByPeer.remove(userId);
    _lastSentPathByPeer.remove(normalizedUid);

    // Best-effort delete of half-received files belonging to this friend.
    for (final path in {...affectedTempPaths, ...affectedActualPaths}) {
      try {
        final f = File(path);
        if (await f.exists() && p.basename(path).startsWith('receiving_')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      } catch (_) {}
    }

    // Delegate the actual Tox + Prefs delete to the canonical writer.
    await deleteFriend(userId);
  }

  void _onNativeEvent(int type, String sender, String data) {
    // 0=c2c text, 1=custom, 2=typing, 10=group text, 11=group custom
    // 100=connect_success, 101=connect_failed
    if (type == 100) {
      // Connection success
      final wasOffline = !_isConnected;
      _isConnected = true;
      _connectionStatus.add(true);
      // When connected, send avatar to all online friends
      unawaited(_sendAvatarToAllFriendsOnConnect());
      // P0-C1: drain group offline queue on reconnect (parallel to the
      // C2C drain done per-friend in getFriendList).
      if (wasOffline) {
        unawaited(_drainAllPendingGroupMessages());
      }
      return;
    } else if (type == 101) {
      // Connection failed
      _isConnected = false;
      _connectionStatus.add(false);
      return;
    } else if (type == 0) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final sequence = _msgIDSequence++;
      final msgID = '${timestamp}_${sequence}_$sender';
      final msg = ChatMessage(
        text: data,
        fromUserId: sender,
        isSelf: sender == _selfId,
        timestamp: DateTime.now(),
        groupId: null,
        msgID: msgID,
      );
      // S29: drop an inbound C2C text from a BLOCKED sender before any
      // side-effect (unread / preview / `_messages` UI stream / receipt).
      if (sender != _selfId && isBlocked(sender)) {
        _logger?.log(
            '[FfiChatService] _onNativeEvent(0): dropping blocked sender');
      } else {
        _lastByPeer[sender] = msg;
        if (_activePeerId != sender && sender != _selfId) {
          _unreadByPeer.update(sender, (v) => v + 1, ifAbsent: () => 1);
        }
        _appendHistory(sender, msg);
        _messages.add(msg);
        // Auto-send received receipt for received messages (not self-sent)
        // Note: reaction messages are sent via custom messages and should not trigger receipts
        // Regular text messages will trigger receipts here
        if (!msg.isSelf && !_isReactionMessage(data)) {
          unawaited(_sendReceipt(sender, msgID, 'received'));
        }
      }
    } else if (type == 20) {
      // S29: drop an inbound file from a BLOCKED sender entirely (incl. avatar
      // sync) before any processing / auto-accept / disk-write.
      if (sender != _selfId && isBlocked(sender)) {
        _logger?.log(
            '[FfiChatService] _onNativeEvent(20): dropping blocked file sender');
        return;
      }
      // file received; sender=userID, data=local path
      // NOTE: This event may be redundant if file_done already handled the message
      // Check if we already have a message for this file path to avoid duplicates
      final kind = _detectKind(data);
      final isAvatarFile =
          sender != _selfId && FfiChatService.isAvatarSyncFilePath(data);
      // Check if this might be an avatar file (image file from a friend)
      // We'll store it as friend avatar if it's an image and matches the expected avatar pattern
      if (isAvatarFile) {
        // Store as friend avatar and notify UI refresh; avatar sync must not appear in chat history.
        unawaited(_prefs?.setFriendAvatarPath(sender, data));
        _avatarUpdatedCtrl.add(sender);
        return;
      }
      // Check if this file was already handled by file_done event
      bool alreadyHandled = false;
      final history = _historyById[sender];
      if (history != null) {
        // Check if we already have a message with this file path
        for (final msg in history) {
          if (msg.filePath == data && msg.fromUserId == sender) {
            alreadyHandled = true;
            break;
          }
        }
      }
      // Only create new message if not already handled
      if (!alreadyHandled) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final sequence = _msgIDSequence++;
        final msgID = '${timestamp}_${sequence}_$sender';
        final msg = ChatMessage(
          text: '',
          fromUserId: sender,
          isSelf: false,
          timestamp: DateTime.now(),
          groupId: null,
          filePath: data,
          mediaKind: kind,
          msgID: msgID,
        );
        _lastByPeer[sender] = msg;
        if (_activePeerId != sender) {
          _unreadByPeer.update(sender, (v) => v + 1, ifAbsent: () => 1);
        }
        _appendHistory(sender, msg);
        _messages.add(msg);
        // Auto-send received receipt for received file messages
        // Note: file messages are not reaction messages, so always send receipt
        unawaited(_sendReceipt(sender, msgID, 'received'));
      }
    } else if (type == 2) {
      // typing
      _typingUntil[sender] = DateTime.now().add(const Duration(seconds: 3));
      // Don't add empty message for typing indicator - UI will show it separately
    } else if (type == 21) {
      // recv progress: payload "received\t total\t path"
      final parts = data.split('\t');
      final rec = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
      final tot = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
      final path = parts.length > 2 ? parts[2] : null;
      // For custom event progress, try to find msgID from path or history
      String? customMsgID;
      if (path != null) {
        // Try to find from path mapping first
        customMsgID = _pathToMsgID[path];
        // If not found, try to find from file receive progress (use _isSameReceiveFile for tempPath vs actual path)
        if (customMsgID == null) {
          final normalizedSender =
              sender.length > 64 ? _normalizeFriendId(sender) : sender;
          for (final entry in _fileReceiveProgress.entries) {
            if ((entry.key.$1 == normalizedSender || entry.key.$1 == sender) &&
                (entry.value.actualPath == path ||
                    entry.value.tempPath == path ||
                    _isSameReceiveFile(entry.value.tempPath, path))) {
              customMsgID = entry.value.msgID;
              break;
            }
          }
        }
      }
      _progressCtrl.add((
        instanceId: 0,
        peerId: sender,
        path: path,
        received: rec,
        total: tot,
        isSend: false,
        msgID: customMsgID
      ));
    } else if (type == 22) {
      // send progress: payload "sent\t total"
      final parts = data.split('\t');
      final sent = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
      final tot = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
      final path = _lastSentPathByPeer[sender];
      // Find msgID for this send path.
      // R-1: prefer the precise per-msgID reverse map first (see
      // progress_send polling branch above for the rationale).
      String? sendMsgID;
      if (path != null) {
        for (final e in _msgIDToSentPath.entries) {
          if (e.value == path) {
            sendMsgID = e.key;
            break;
          }
        }
        sendMsgID ??= _pathToMsgID[path];
      }
      // If still not found, try to find from last message for this peer.
      if (sendMsgID == null && path != null) {
        final normalizedSender =
            sender.length > 64 ? _normalizeFriendId(sender) : sender;
        final lastMsg = _lastByPeer[normalizedSender];
        if (lastMsg != null && lastMsg.filePath == path) {
          sendMsgID = lastMsg.msgID;
        }
      }
      _progressCtrl.add((
        instanceId: 0,
        peerId: sender,
        path: path,
        received: sent,
        total: tot,
        isSend: true,
        msgID: sendMsgID
      ));
    } else if (type == 10) {
      // sender format: "g|<groupID>|<senderID>"
      final parts = sender.split('|');
      if (parts.length >= 3) {
        ingestInboundGroupText(gid: parts[1], from: parts[2], text: data);
      }
    }
  }

  /// Materialize one inbound group text message — the SINGLE ingestion seam
  /// shared by the native type==10 event (real NGC delivery) and the L3
  /// test harness (`l3_inject_group_text`), which uses it to seed
  /// deterministic multi-sender group views: same-host NGC peer links are
  /// not reliably establishable (NAT-hairpin announces), while this seam
  /// drives the exact dedup → history → unread → stream pipeline real
  /// traffic drives, so persistence and rendering are indistinguishable.
  /// Returns true when the message was ingested (false: quit group / dup).
  bool ingestInboundGroupText({
    required String gid,
    required String from,
    required String text,
  }) {
    // Check if this group was quit - if so, don't add it back
    if (_quitGroups.contains(gid)) return false;
    // Deduplicate: same message can be delivered twice (conference + group callback in C++)
    final duplicate = _findRecentGroupHistoryMessage(gid, from, text);
    if (duplicate != null) {
      final last = _lastByPeer[gid];
      final alreadyReflected = last != null &&
          last.fromUserId == duplicate.fromUserId &&
          last.text == duplicate.text &&
          last.groupId == gid;
      if (!alreadyReflected) {
        _knownGroups.add(gid);
        _lastByPeer[gid] = duplicate;
        if (_activePeerId == gid) {
          _unreadByPeer[gid] = 0;
        } else {
          _unreadByPeer.update(gid, (v) => v + 1, ifAbsent: () => 1);
        }
        _messages.add(duplicate);
      }
      _logger?.log(
          '[FfiChatService] ingestInboundGroupText: Skipping duplicate group message: gid=$gid, from=$from');
      return !alreadyReflected;
    }
    final added = _knownGroups.add(gid);
    if (added) {
      unawaited(
          _persistKnownGroups()); // This will call _syncKnownGroupsToNative()
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sequence = _msgIDSequence++;
    final msgID = '${timestamp}_${sequence}_${from}_$gid';
    final msg = ChatMessage(
      text: text,
      fromUserId: from,
      isSelf: from == _selfId,
      timestamp: DateTime.now(),
      groupId: gid,
      msgID: msgID,
    );
    _lastByPeer[gid] = msg; // reuse for group last message
    if (_activePeerId == gid) {
      _unreadByPeer[gid] = 0;
    } else {
      _unreadByPeer.update(gid, (v) => v + 1, ifAbsent: () => 1);
    }
    _appendHistory(gid, msg);
    _messages.add(msg);
    // Auto-send received receipt for received group messages (not self-sent)
    // Note: reaction messages are sent via custom messages and should not trigger receipts
    if (!msg.isSelf && !_isReactionMessage(text)) {
      unawaited(_sendReceipt(from, msgID, 'received', groupID: gid));
    }
    return true;
  }

  /// Materialize one inbound C2C custom message through the same local
  /// history, unread, preview, and UI-stream pipeline as native C2C delivery.
  /// This is intentionally radio-free and test-harness friendly: the sender's
  /// customElem.data is stored as [ChatMessage.text] with mediaKind=custom so
  /// SDK conversion produces a real V2TIM custom elem for UIKit menus.
  /// Returns true when the message was ingested (false: blocked sender).
  bool ingestInboundC2cCustom({
    required String from,
    required String data,
  }) {
    final normalizedFrom = from.length > 64 ? _normalizeFriendId(from) : from;
    if (from != _selfId && isBlocked(normalizedFrom)) {
      _logger?.log(
          '[FfiChatService] ingestInboundC2cCustom: dropping blocked sender');
      return false;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sequence = _msgIDSequence++;
    final msgID = '${timestamp}_${sequence}_$from';
    final msg = ChatMessage(
      text: data,
      fromUserId: from,
      isSelf: from == _selfId,
      timestamp: DateTime.now(),
      msgID: msgID,
      mediaKind: 'custom',
    );
    _lastByPeer[normalizedFrom] = msg;
    if (_activePeerId != normalizedFrom && from != _selfId) {
      _unreadByPeer.update(normalizedFrom, (v) => v + 1, ifAbsent: () => 1);
    }
    _appendHistory(normalizedFrom, msg);
    _messages.add(msg);
    return true;
  }

  ChatMessage? _findRecentGroupHistoryMessage(
      String gid, String from, String text) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    const windowMs = 5000;
    final list = _messageHistoryPersistence.getCachedList(gid);
    if (list == null || list.isEmpty) return null;
    for (var i = list.length - 1; i >= 0 && i >= list.length - 20; i--) {
      final m = list[i];
      if (m.fromUserId == from &&
          m.text == text &&
          (m.timestamp.millisecondsSinceEpoch - nowMs).abs() < windowMs) {
        return m;
      }
    }
    return null;
  }

  /// Returns true if we already have a recent group message with the same (gid, from, text).
  /// Used to deduplicate when both conference and group callbacks fire for the same message (tox_conf_*).
  bool _isDuplicateGroupTextMessage(String gid, String from, String text) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    const windowMs = 5000; // 5 seconds

    // Primary: scan the in-memory history tail. After a process restart this
    // is empty until `loadHistory(gid)` runs, so the conference vs group
    // duplicate could slip through the very first delivery — see the
    // _lastByPeer fallback below.
    final list = _messageHistoryPersistence.getCachedList(gid);
    if (list != null && list.isNotEmpty) {
      for (var i = list.length - 1; i >= 0 && i >= list.length - 20; i--) {
        final m = list[i];
        if (m.fromUserId == from &&
            m.text == text &&
            (m.timestamp.millisecondsSinceEpoch - nowMs).abs() < windowMs) {
          return true;
        }
      }
    }

    // Do NOT use _lastByPeer alone as a duplicate signal for groups. In the
    // real NGC path the native advanced-listener and the polled `gtext:` path
    // can race each other: one path may update `_lastByPeer` before the other
    // path materializes history, which would make the very first real inbound
    // group message of the session look like a duplicate and get dropped. The
    // authoritative duplicate check is the cached history tail above.
    return false;
  }

  void _appendHistory(String id, ChatMessage msg) {
    // S29 block enforcement: drop an inbound C2C message from a blocked sender
    // BEFORE it reaches persistence/lastByPeer — a local receive-side hide.
    // This is the single FfiChatService chokepoint for every inbound text/file
    // path (poll `c2c:` + `_onNativeEvent` type 0/20), so one guard covers them
    // all. Self-sends (isSelf) and groups (groupId != null) are never blocked;
    // the binary-replacement hook is guarded separately (it persists directly).
    if (!msg.isSelf && msg.groupId == null && isBlocked(msg.fromUserId)) {
      _logger?.log('[FfiChatService] _appendHistory: dropping blocked sender '
          '${msg.fromUserId.substring(0, msg.fromUserId.length.clamp(0, 8))}..');
      return;
    }
    // Persistence is the single owner of the in-memory list; it also applies
    // the 1000-message memory cap and dedup-by-msgID inside `appendHistory`.
    // Fire-and-forget by design: callers of _appendHistory expect a
    // synchronous void; on-disk save races continue in the background.
    unawaited(_messageHistoryPersistence.appendHistory(id, msg));
    // Also update lastByPeer for immediate access
    _lastByPeer[id] = msg;
  }

  /// Add a locally generated message (e.g. call record) that should appear
  /// in history but is not stored in Tox.
  void addLocalMessage(String userId, ChatMessage msg) {
    final key = normalizeToxId(userId);
    // Persist local synthetic messages (like call records) through the same
    // history pipeline so they survive app restart.
    _appendHistory(key, msg);
  }

  /// All conversation ids (bare, normalized) that currently have persisted
  /// history. Public so the SDK platform's local message search
  /// (`searchLocalMessages`) can enumerate every conversation when no specific
  /// `conversationID` is given — the C++ `SearchLocalMessages` is an empty stub
  /// (history lives here, not in C++), so the search must run Dart-side.
  Set<String> getConversationIds() =>
      _messageHistoryPersistence.getConversationIds();

  List<ChatMessage> getHistory(String id) {
    // Normalize friend ID to 64 characters if it's a C2C conversation (not a group)
    // Group IDs don't need normalization, but friend IDs should be normalized
    // We can't easily distinguish here, so we normalize all IDs (groups are typically shorter)
    final normalizedId = id.length > 64 ? _normalizeFriendId(id) : id;

    // Get from persistence service (which maintains in-memory cache)
    var list = _messageHistoryPersistence.getHistory(normalizedId);
    if (list.isEmpty && id != normalizedId) {
      // Try original ID if normalized ID doesn't exist
      list = _messageHistoryPersistence.getHistory(id);
      if (list.isNotEmpty) {
        // Migrate to normalized ID for consistency (async, don't await)
        unawaited(_messageHistoryPersistence.saveHistory(normalizedId, list));
        unawaited(_messageHistoryPersistence.clearHistory(id));
      }
    }

    if (list.isEmpty) {
      // Try to load from disk if not in memory (async, but we return empty list for now)
      // The history will be loaded on next access after async load completes
      // Try both normalized and original ID
      unawaited(_loadHistory(normalizedId));
      if (id != normalizedId) {
        unawaited(_loadHistory(id));
      }
    }

    return list;
  }

  /// Find userID and groupID from msgID by searching all conversation histories
  /// Returns (userID, groupID) tuple, where one will be null
  (String?, String?) findUserIDAndGroupIDFromMsgID(String msgID) {
    // Search through all conversation histories
    for (final entry in _historyById.entries) {
      final conversationID = entry.key;
      final messages = entry.value;
      // Find message with matching msgID
      try {
        final foundMsg = messages.firstWhere((m) => m.msgID == msgID);
        // Extract userID/groupID from conversationID
        // For C2C: conversationID is the userID
        // For group: conversationID is the groupID
        // Check if it's a group by checking if the message has groupId
        if (foundMsg.groupId != null) {
          return (null, foundMsg.groupId);
        } else {
          // C2C conversation: conversationID is the userID
          return (conversationID, null);
        }
      } catch (_) {
        // Message not found in this conversation, continue searching
        continue;
      }
    }
    return (null, null);
  }

  /// Set auto-accept group invites setting
  /// This updates the FFI global variable that C++ reads before accepting group invites
  void setAutoAcceptGroupInvites(bool enabled) {
    _ffi.setAutoAcceptGroupInvitesNative(
        _ffi.getCurrentInstanceId(), enabled ? 1 : 0);
  }

  /// Get full tox conference ID from groupID
  /// Returns the 64-character hex string conference ID, or null on error
  String? getGroupChatId(String groupID) {
    try {
      final groupIDNative = groupID.toNativeUtf8();
      final buffer = pkgffi.malloc<ffi.Int8>(65); // 64 chars + null terminator
      try {
        final result = _ffi.getGroupChatIdNative(
            _ffi.getCurrentInstanceId(), groupIDNative, buffer, 65);
        if (result == 1) {
          final chatId = buffer.cast<pkgffi.Utf8>().toDartString();

          // Store to persistence for future use (async, don't await)
          if (chatId.isNotEmpty && _prefs != null) {
            unawaited(_prefs!.setGroupChatId(groupID, chatId));
          }

          return chatId;
        }
        return null;
      } finally {
        pkgffi.malloc.free(groupIDNative);
        pkgffi.malloc.free(buffer);
      }
    } catch (e) {
      return null;
    }
  }

  /// Get file transfer info (peerId, fileNumber) from msgID
  /// Returns (peerId, fileNumber) tuple, or (null, null) if not found
  (String?, int?) getFileTransferInfoFromMsgID(String msgID) {
    // Check if msgID is in the mapping
    if (_msgIDToFileTransfer.containsKey(msgID)) {
      final transfer = _msgIDToFileTransfer[msgID]!;
      return (transfer.$1, transfer.$2);
    }
    // If not found in mapping, try to find from history
    // This handles cases where the message was created but mapping wasn't set
    for (final entry in _historyById.entries) {
      final conversationID = entry.key;
      final messages = entry.value;
      try {
        final foundMsg = messages.firstWhere((m) => m.msgID == msgID);
        // Check if this is a file message that's still pending
        if (foundMsg.filePath != null &&
            foundMsg.filePath!.contains('/receiving_')) {
          // This is a pending file message - try to find the file transfer from progress tracking
          for (final progressEntry in _fileReceiveProgress.entries) {
            if (progressEntry.value.msgID == msgID) {
              return (progressEntry.key.$1, progressEntry.key.$2);
            }
          }
        }
      } catch (_) {
        continue;
      }
    }
    return (null, null);
  }

  /// Accept file transfer by msgID
  /// This is called when UIKit's download button is clicked
  Future<void> acceptFileTransferByMsgID(String msgID) async {
    final transferInfo = getFileTransferInfoFromMsgID(msgID);
    final peerId = transferInfo.$1;
    final fileNumber = transferInfo.$2;

    if (peerId == null || fileNumber == null) {
      throw Exception('File transfer not found for msgID: $msgID');
    }

    await acceptFileTransfer(peerId, fileNumber);
  }

  /// Clear C2C chat history for a user
  /// This is called by UIKit when user clicks "Clear Chat History" in profile page
  /// This deletes the persisted history file (JSON) but does NOT delete actual media files
  /// (images, videos, audio, documents) that may be referenced in the messages
  Future<void> clearC2CHistory(String userID) async {
    // Normalize friend ID to 64 characters (public key length)
    final normalizedUserID = _normalizeFriendId(userID);

    // Eagerly drop any matching cache entry from the persistence-owned map.
    // Persistence's `clearHistory` (called below) also clears in-memory state,
    // but doing it up-front means a concurrent reader sees the clear
    // immediately even while disk I/O is still in flight.
    _messageHistoryPersistence.removeCachedHistory(normalizedUserID);
    _messageHistoryPersistence.removeCachedHistory(userID);

    // Also drop any stored variant (e.g. 76-char address key).
    final keysToRemove = <String>[];
    for (final key in _messageHistoryPersistence.cache.keys) {
      final normalizedKey = key.length > 64 ? _normalizeFriendId(key) : key;
      if (normalizedKey == normalizedUserID ||
          key == userID ||
          normalizedKey == userID ||
          key == normalizedUserID) {
        keysToRemove.add(key);
      }
    }
    for (final key in keysToRemove) {
      _messageHistoryPersistence.removeCachedHistory(key);
    }

    // Clear persisted history file using persistence service
    // This deletes the JSON history file but preserves actual media files
    // This also clears the persistence service's in-memory cache
    try {
      await _messageHistoryPersistence.clearHistory(normalizedUserID);
    } catch (e, stackTrace) {
      // Log error but don't throw - clearing should continue even if file deletion fails
      _logger?.logError(
          'Failed to clear persisted history for user $normalizedUserID',
          e,
          stackTrace);
    }

    // Also try to clear with original ID in case it was stored differently
    if (userID != normalizedUserID) {
      try {
        await _messageHistoryPersistence.clearHistory(userID);
      } catch (e, stackTrace) {
        _logger?.logError(
            'Failed to clear persisted history for user (original ID) $userID',
            e,
            stackTrace);
      }
    }

    // Clear last message and unread count
    _lastByPeer.remove(normalizedUserID);
    _unreadByPeer.remove(normalizedUserID);
    if (userID != normalizedUserID) {
      _lastByPeer.remove(userID);
      _unreadByPeer.remove(userID);
    }
  }

  /// Clear group chat history
  /// This is called by UIKit when user clicks "Clear Chat History" in group profile page
  /// This deletes the persisted history file (JSON) but does NOT delete actual media files
  /// (images, videos, audio, documents) that may be referenced in the messages
  Future<void> clearGroupHistory(String groupID) async {
    print('[FfiChatService] clearGroupHistory: ENTRY - groupID=$groupID');
    // Eagerly drop the cached list. `clearHistory` below also clears the cache
    // and removes the on-disk file.
    final bool removed =
        _messageHistoryPersistence.getCachedList(groupID) != null;
    _messageHistoryPersistence.removeCachedHistory(groupID);
    print(
        '[FfiChatService] clearGroupHistory: Removed from persistence cache: $removed');

    // Clear persisted history file using persistence service
    // This deletes the JSON history file but preserves actual media files
    // This also clears the persistence service's in-memory cache
    try {
      print(
          '[FfiChatService] clearGroupHistory: Calling _messageHistoryPersistence.clearHistory');
      await _messageHistoryPersistence.clearHistory(groupID);
      print(
          '[FfiChatService] clearGroupHistory: _messageHistoryPersistence.clearHistory completed');
    } catch (e, stackTrace) {
      print(
          '[FfiChatService] clearGroupHistory: ERROR - clearHistory failed for groupID=$groupID: $e');
      // Log error but don't throw - clearing should continue even if file deletion fails
      _logger?.logError('Failed to clear persisted history for group $groupID',
          e, stackTrace);
    }

    // Clear last message and unread count
    bool lastRemoved = _lastByPeer.remove(groupID) != null;
    bool unreadRemoved = _unreadByPeer.remove(groupID) != null;
    print(
        '[FfiChatService] clearGroupHistory: Removed from _lastByPeer: $lastRemoved, _unreadByPeer: $unreadRemoved');
    print(
        '[FfiChatService] clearGroupHistory: EXIT - Completed for groupID=$groupID');
  }

  /// Delete friend
  /// This is called by UIKit when user clicks "Delete" in profile page
  Future<void> deleteFriend(String userID) async {
    try {
      // Normalize userID to 64 characters (Tox public key length)
      final normalizedUserID = _normalizeFriendId(userID);

      final pu = normalizedUserID.toNativeUtf8();
      final result = _ffi.deleteFriend(pu);
      pkgffi.malloc.free(pu);

      if (result != 1) {
        // Even if FFI returns failure, we should still clean up local state
        // This handles cases where the friend was already deleted or not found in Tox
      }

      // Remove from local friends persistence (always do this, even if FFI failed)
      // First, reload to ensure we have the latest state
      final localFriends = await _prefs?.getLocalFriends() ?? <String>{};
      final beforeCount = localFriends.length;
      // Normalize all IDs in the set for consistent comparison
      final normalizedLocalFriends =
          localFriends.map((uid) => normalizeToxId(uid)).toSet();
      normalizedLocalFriends.remove(normalizedUserID);
      // Also try removing the original userID if different
      if (normalizedUserID != userID) {
        final normalizedOriginalUserID = normalizeToxId(userID);
        normalizedLocalFriends.remove(normalizedOriginalUserID);
      }
      // Convert back to Set<String> for storage (keep normalized IDs)
      final updatedLocalFriends = normalizedLocalFriends.toSet();
      final afterCount = updatedLocalFriends.length;
      await _prefs?.setLocalFriends(updatedLocalFriends);
      // Wait a bit longer to ensure SharedPreferences write and reload have completed
      // Increased delay to ensure disk write is fully persisted
      await Future.delayed(const Duration(milliseconds: 500));
      // Verify the deletion was successful by reloading
      final verifyLocalFriends = await _prefs?.getLocalFriends() ?? <String>{};
      final verifyNormalizedLocalFriends =
          verifyLocalFriends.map((uid) => normalizeToxId(uid)).toSet();
      final normalizedForVerify = normalizeToxId(normalizedUserID);
      if (verifyNormalizedLocalFriends.contains(normalizedForVerify)) {
        // Retry removal with additional delay
        verifyNormalizedLocalFriends.remove(normalizedForVerify);
        await _prefs?.setLocalFriends(verifyNormalizedLocalFriends.toSet());
        await Future.delayed(const Duration(milliseconds: 200));
        // Verify again
        final verifyLocalFriends2 =
            await _prefs?.getLocalFriends() ?? <String>{};
        final verifyNormalizedLocalFriends2 =
            verifyLocalFriends2.map((uid) => normalizeToxId(uid)).toSet();
        if (verifyNormalizedLocalFriends2.contains(normalizedForVerify)) {
        } else {}
      } else {}

      // Clear chat history for this friend
      await clearC2CHistory(normalizedUserID);
      if (normalizedUserID != userID) {
        await clearC2CHistory(userID);
      }
    } catch (e, stackTrace) {
      rethrow;
    }
  }

  /// Delete messages by their IDs.
  ///
  /// Matches by the message's stored [ChatMessage.msgID] (the value written by
  /// `_appendHistory` of the form `'${timestamp}_${sequence}_${from}'`, or by
  /// `MessageIdGenerator` for outbound sends). Falls back to the legacy
  /// two-component reconstruction `'${timestamp}_${fromUserId}'` only for
  /// records persisted before msgID was attached, so old data is still
  /// deletable. Updates `MessageHistoryPersistence`'s in-memory cache for
  /// every modified conversation so reads do not repopulate stale data.
  ///
  /// Also refreshes the conversation-preview state (`_lastByPeer`,
  /// `_unreadByPeer`) for every conversation whose messages changed, because
  /// the conversation-list builder reads `lastMessages[peerId]` and the
  /// per-peer unread counter directly. Without this refresh, deleting the
  /// final message of a conversation leaves the sidebar showing the deleted
  /// message as the preview until a new message arrives or the app reloads
  /// (the same pattern already used by `_cleanIncompleteFileTransfersOnInit`).
  ///
  /// Returns the number of messages deleted.
  Future<int> deleteMessages(List<String> msgIDs) async {
    if (msgIDs.isEmpty) return 0;
    final msgIDSet = msgIDs.toSet();
    int deletedCount = 0;
    final modifiedConversations = <String>{};

    bool matches(ChatMessage msg) {
      final id = msg.msgID;
      if (id != null && id.isNotEmpty) {
        return msgIDSet.contains(id);
      }
      // Legacy fallback: pre-msgID records used (timestamp, fromUserId).
      final legacy =
          '${msg.timestamp.millisecondsSinceEpoch}_${msg.fromUserId}';
      return msgIDSet.contains(legacy);
    }

    // Iterate through all conversation histories to find and delete messages.
    for (final entry in _historyById.entries.toList()) {
      final conversationId = entry.key;
      final messages = entry.value;
      final originalLength = messages.length;
      messages.removeWhere((msg) {
        if (matches(msg)) {
          deletedCount++;
          return true;
        }
        return false;
      });
      if (messages.length < originalLength) {
        modifiedConversations.add(conversationId);

        final remaining = _historyById[conversationId];
        if (remaining == null || remaining.isEmpty) {
          // CR-05: the conversation is now empty. `_saveHistory` would no-op
          // (saveHistory returns early on an empty list), leaving the stale
          // on-disk JSON to resurrect the deleted message on the next launch.
          // Delete the history file (and backup) and drop preview state.
          await _messageHistoryPersistence.clearHistory(conversationId);
          _lastByPeer.remove(conversationId);
          _unreadByPeer.remove(conversationId);
        } else {
          // Persist the truncated list to disk. The in-memory cache mutation
          // above (`messages.removeWhere`) already lands in the
          // persistence-owned list — `_historyById` IS the persistence cache.
          await _saveHistory(conversationId);

          // Recompute conversation-preview state from what remains.
          ChatMessage newest = remaining.first;
          int unread = 0;
          for (final m in remaining) {
            if (m.timestamp.isAfter(newest.timestamp)) newest = m;
            if (!m.isSelf && !m.isRead) unread++;
          }
          _lastByPeer[conversationId] = newest;
          // Preserve the active-conversation zero-out (setActivePeer drives
          // _unreadByPeer to 0 for the active conversation).
          if (_activePeerId == conversationId) {
            _unreadByPeer[conversationId] = 0;
          } else if (unread > 0) {
            _unreadByPeer[conversationId] = unread;
          } else {
            _unreadByPeer.remove(conversationId);
          }
        }
      }
    }

    // `_messages` is a broadcast StreamController, not a List — there is no
    // historical buffer to clean. The previous `_messages is List` block was
    // a no-op left from an earlier shape. Intentionally drop it: the new
    // msgID-aware match above is also what would have been needed here.
    return deletedCount;
  }

  /// Normalizes a Tox friend ID to 64 characters (public key length).
  /// Tox friend IDs are 64 characters (public key, 32 bytes in hex).
  /// If the ID is 76 characters (full address), extracts the first 64 characters (public key).
  /// If longer, extracts only the first 64 characters.
  /// If shorter, returns as is (might be a partial ID or different format).
  String _normalizeFriendId(String id) => normalizeToxId(id);

  /// Avatar sync files should never appear in chat history.
  /// This is used as a compatibility fallback when old peers still send avatar as kind=0.
  static bool isAvatarSyncFilePath(String pathOrName) {
    final raw = pathOrName.trim();
    if (raw.isEmpty) return false;
    final fileName = p.basename(raw).toLowerCase();
    const imageExt = [
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.bmp',
      '.heic'
    ];
    final isImage = imageExt.any((ext) => fileName.endsWith(ext));
    if (!isImage) return false;

    final stem = p.basenameWithoutExtension(fileName);
    final startsWithAvatar =
        stem.startsWith('avatar_') || stem.startsWith('self_avatar');
    final friendAvatarPattern =
        stem.startsWith('friend_') && stem.contains('_avatar');
    final embeddedAvatarPattern =
        stem.contains('_avatar_') && stem.length >= 24;
    final strongAvatarPattern = startsWithAvatar && stem.length >= 8;
    return strongAvatarPattern || friendAvatarPattern || embeddedAvatarPattern;
  }

  String _detectKind(String path) {
    final p = path.toLowerCase();
    const img = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic'];
    // P2-1: previously missed common Windows/legacy mobile container
    // formats; UIKit was rendering these as generic file attachments.
    const vid = [
      '.mp4',
      '.mov',
      '.m4v',
      '.webm',
      '.mkv',
      '.avi',
      '.wmv',
      '.flv',
      '.mpeg',
      '.mpg',
      '.3gp',
      '.ts',
      '.m2ts',
    ];
    const aud = ['.mp3', '.wav', '.m4a', '.aac', '.ogg', '.flac'];
    for (final e in img) {
      if (p.endsWith(e)) return 'image';
    }
    for (final e in vid) {
      if (p.endsWith(e)) return 'video';
    }
    for (final e in aud) {
      if (p.endsWith(e)) return 'audio';
    }
    return 'file';
  }

  Future<void> sendTyping(String peerId, bool on) async {
    // Normalize to 64 chars (public key) - FFI set_typing expects exactly 64 hex chars
    final normalizedPeerId = _normalizeFriendId(peerId);
    final p = normalizedPeerId.toNativeUtf8();
    _ffi.setTyping(p, on ? 1 : 0);
    pkgffi.malloc.free(p);
  }

  Future<String?> createGroup(String name, {String groupType = 'group'}) async {
    final trimmed = name.trim();
    final pname = trimmed.toNativeUtf8();
    final ptype = groupType.toNativeUtf8();
    final buf = pkgffi.malloc.allocate<ffi.Int8>(256);
    final n = _ffi.createGroup(pname, ptype, buf, 256);
    pkgffi.malloc.free(pname);
    pkgffi.malloc.free(ptype);
    if (n > 0) {
      // Extract the id and free the native buffer BEFORE the awaited
      // prefs/history work below — a throw from those writes must not leak it.
      final gid = buf.cast<pkgffi.Utf8>().toDartString();
      pkgffi.malloc.free(buf);
      _knownGroups.add(gid);
      // Remove from quit groups if it was previously quit (in case of group ID reuse)
      _quitGroups.remove(gid);
      await _prefs?.removeQuitGroup(gid);
      // Clear history for this group ID to prevent loading old messages
      // This is important when group IDs are reused (e.g., IRC channels)
      await clearGroupHistory(gid);
      await _persistKnownGroups(); // This will call _syncKnownGroupsToNative()
      return gid;
    }
    pkgffi.malloc.free(buf);
    return null;
  }

  Future<void> joinGroup(String groupId, {String? requestMessage}) async {
    final p = groupId.toNativeUtf8();
    final wording = (requestMessage != null && requestMessage.trim().isNotEmpty)
        ? requestMessage.trim()
        : '';
    final pmsg = wording.toNativeUtf8();
    final int rc;
    try {
      // P0-B5: previously fire-and-forget. The FFI returns 1 on success,
      // 0 on failure (per the int convention). Surface a failure rather
      // than silently marking the group joined and persisting it to
      // _knownGroups — that left ghost entries on the user's group list.
      rc = _ffi.joinGroup(p, pmsg);
    } finally {
      pkgffi.malloc.free(p);
      pkgffi.malloc.free(pmsg);
    }
    if (rc != 1) {
      _logger?.log(
          '[FfiChatService] joinGroup: FFI returned rc=$rc for groupId=$groupId');
      throw StateError('joinGroup failed (rc=$rc) for $groupId');
    }
    _knownGroups.add(groupId);
    await _persistKnownGroups(); // This will call _syncKnownGroupsToNative()
    // Remove from quit groups if it was previously quit
    _quitGroups.remove(groupId);
    await _prefs?.removeQuitGroup(groupId);
  }

  Future<void> quitGroup(String groupId) async {
    print('[FfiChatService] quitGroup: ENTRY - groupId=$groupId');

    // Validate groupId
    if (groupId.isEmpty) {
      print('[FfiChatService] quitGroup: ERROR - groupId is empty');
      throw ArgumentError('groupId cannot be empty');
    }

    // Ensure NativeLibraryManager is initialized
    print('[FfiChatService] quitGroup: Registering NativeLibraryManager port');
    NativeLibraryManager.registerPort();

    // Generate unique user_data identifier for callback
    String userData = Tools.generateUserData('quitGroup');
    print(
        '[FfiChatService] quitGroup: Generated userData=$userData for callback');
    Completer<V2TimCallback> completer = Completer();
    NativeLibraryManager.addTimCallback2Map(userData, completer);

    // Prepare FFI pointers
    ffi.Pointer<ffi.Char> pGroupID = Tools.string2PointerChar(groupId);
    ffi.Pointer<ffi.Void> pUserData = Tools.string2PointerVoid(userData);
    print(
        '[FfiChatService] quitGroup: Prepared FFI pointers, calling DartQuitGroup');

    // Guard against double-free: the original implementation freed on the
    // success path and again in the catch. If any of the local-cleanup steps
    // (history clear, prefs write, offline queue) threw after the success
    // free, the catch would re-free already-released native memory.
    bool freed = false;
    void freeOnce() {
      if (freed) return;
      freed = true;
      Tools.freePointers([pGroupID, pUserData]);
    }

    try {
      // Call C++ layer DartQuitGroup (async) - this will call tox_group_leave
      int callResult =
          NativeLibraryManager.bindings.DartQuitGroup(pGroupID, pUserData);
      print(
          '[FfiChatService] quitGroup: DartQuitGroup call returned code=$callResult, waiting for callback');

      // Wait for callback result.
      // P0-B1: bound the wait with a timeout. Without it, if the C++ side
      // failed to deliver the SendPort message (e.g. callback bridge race
      // on dispose, instance routing error) the UI would freeze on the
      // unbounded `await completer.future`. 15s is generous for what is
      // ultimately a tox_group_leave / tox_conference_delete syscall.
      V2TimCallback result = await completer.future
          .timeout(const Duration(seconds: 15), onTimeout: () {
        print(
            '[FfiChatService] quitGroup: TIMEOUT waiting for C++ callback for groupId=$groupId');
        // Synthesize a failure result so the catch below cleans up native
        // pointers and surfaces the error to the caller. We deliberately
        // do not clean up local state here — the C++ side may still
        // deliver the callback later and a separate cleanupGroupState()
        // path exists for that case.
        return V2TimCallback(
            code: -1,
            desc: 'quitGroup timed out after 15s waiting for native callback');
      });
      print(
          '[FfiChatService] quitGroup: Received callback result: code=${result.code}, desc=${result.desc}');

      // FFI pointers are no longer referenced by the native side after the
      // callback completes — release them before doing local cleanup so any
      // exception below does not leak the allocations.
      freeOnce();

      // Check if the operation was successful
      if (result.code != 0) {
        print(
            '[FfiChatService] quitGroup: ERROR - C++ layer returned error code=${result.code}, desc=${result.desc}');
        throw Exception('quitGroup failed: ${result.desc}');
      }

      print(
          '[FfiChatService] quitGroup: C++ layer call succeeded (tox_group_leave completed), now cleaning up local state');

      // After successful quit from C++ layer, clean up local state
      // Remove from known groups
      print('[FfiChatService] quitGroup: Removing from _knownGroups');
      _knownGroups.remove(groupId);
      _syncKnownGroupsToNative(); // Sync immediately after removal
      await _persistKnownGroups();
      print(
          '[FfiChatService] quitGroup: Removed from _knownGroups and synced to native');

      // Add to quit groups list to prevent re-adding
      print('[FfiChatService] quitGroup: Adding to _quitGroups');
      _quitGroups.add(groupId);
      await _prefs?.addQuitGroup(groupId);
      print('[FfiChatService] quitGroup: Added to _quitGroups and persisted');

      // Clear history for this group (memory cache and persistence)
      print(
          '[FfiChatService] quitGroup: Clearing group history (memory and persistence)');
      await clearGroupHistory(groupId);
      print('[FfiChatService] quitGroup: Group history cleared');

      // Clear offline message queue for this group
      print('[FfiChatService] quitGroup: Clearing offline message queue');
      await _clearOfflineQueue(groupId);
      print('[FfiChatService] quitGroup: Offline message queue cleared');

      print(
          '[FfiChatService] quitGroup: COMPLETE - All cleanup operations finished for groupId=$groupId');
    } catch (e, stackTrace) {
      print('[FfiChatService] quitGroup: ERROR - Exception occurred: $e');
      print('[FfiChatService] quitGroup: Stack trace: $stackTrace');
      _logger?.logError('quitGroup failed for group $groupId', e, stackTrace);
      rethrow;
    } finally {
      // Idempotent release; safe even if freeOnce() already ran on the
      // success path.
      freeOnce();
    }
  }

  /// Register a self-join the Dart layer did NOT initiate (called from C++ via
  /// the groupJoinNotification FFI callback — e.g. auto-accepting a group
  /// invite). The Dart-initiated joinGroup path adds to _knownGroups itself; an
  /// invite auto-join happens entirely in C++ (tox_group_invite_accept +
  /// HandleGroupSelfJoin), so without this the group never surfaces in
  /// _knownGroups. Mirrors joinGroup's LOCAL bookkeeping without the C++ call;
  /// idempotent (no-op if already known).
  Future<void> registerJoinedGroupState(String groupId) async {
    if (_knownGroups.contains(groupId)) return;
    print(
        '[FfiChatService] registerJoinedGroupState: adding $groupId to _knownGroups');
    _knownGroups.add(groupId);
    _syncKnownGroupsToNative();
    await _persistKnownGroups();
    // A (re)join clears any prior quit so it is not filtered back out.
    _quitGroups.remove(groupId);
    await _prefs?.removeQuitGroup(groupId);
  }

  /// Cleanup group state after quit (called from C++ layer via FFI notification)
  /// This method performs the same cleanup as quitGroup but without calling C++ layer
  /// It's used when quitGroup is called directly from C++ layer (bypassing Dart layer)
  Future<void> cleanupGroupState(String groupId) async {
    print('[FfiChatService] cleanupGroupState: ENTRY - groupId=$groupId');

    try {
      // Remove from known groups
      print('[FfiChatService] cleanupGroupState: Removing from _knownGroups');
      _knownGroups.remove(groupId);
      _syncKnownGroupsToNative(); // Sync immediately after removal
      await _persistKnownGroups();
      print(
          '[FfiChatService] cleanupGroupState: Removed from _knownGroups and synced to native');

      // Add to quit groups list to prevent re-adding
      print('[FfiChatService] cleanupGroupState: Adding to _quitGroups');
      _quitGroups.add(groupId);
      await _prefs?.addQuitGroup(groupId);
      print(
          '[FfiChatService] cleanupGroupState: Added to _quitGroups and persisted');

      // Clear history for this group (memory cache and persistence)
      print(
          '[FfiChatService] cleanupGroupState: Clearing group history (memory and persistence)');
      await clearGroupHistory(groupId);
      print('[FfiChatService] cleanupGroupState: Group history cleared');

      // Clear offline message queue for this group
      print(
          '[FfiChatService] cleanupGroupState: Clearing offline message queue');
      await _clearOfflineQueue(groupId);
      print(
          '[FfiChatService] cleanupGroupState: Offline message queue cleared');

      print(
          '[FfiChatService] cleanupGroupState: COMPLETE - All cleanup operations finished for groupId=$groupId');
    } catch (e, stackTrace) {
      print(
          '[FfiChatService] cleanupGroupState: ERROR - Exception occurred: $e');
      print('[FfiChatService] cleanupGroupState: Stack trace: $stackTrace');
      _logger?.logError(
          'cleanupGroupState failed for group $groupId', e, stackTrace);
      // Don't rethrow - this is a notification callback, errors should be logged but not propagated
    }
  }

  Future<void> dismissGroup(String groupId) async {
    // Remove from known groups locally
    _knownGroups.remove(groupId);
    _syncKnownGroupsToNative(); // Sync immediately after removal
    await _persistKnownGroups();
    // Add to quit groups list to prevent re-adding
    _quitGroups.add(groupId);
    await _prefs?.addQuitGroup(groupId);
    // Clear history for this group to prevent old messages from appearing if group ID is reused
    await clearGroupHistory(groupId);
    // Note: In Tox, we can't actually dismiss a group, but we can remove it from local state
  }

  /// Connect to an IRC channel
  /// [server] IRC server address (e.g., "irc.libera.chat")
  /// [port] IRC server port (default 6667, 6697 for SSL)
  /// [channel] Channel name (e.g., "#libera")
  /// [password] Optional channel password
  /// [groupId] Corresponding Tox group ID
  /// [saslUsername] Optional SASL authentication username
  /// [saslPassword] Optional SASL authentication password
  /// [useSsl] Whether to use SSL/TLS (default false)
  /// [customNickname] Optional custom IRC nickname
  /// Returns true on success, false on failure
  Future<bool> connectIrcChannel(
    String server,
    int port,
    String channel,
    String? password,
    String groupId, {
    String? saslUsername,
    String? saslPassword,
    bool useSsl = false,
    String? customNickname,
  }) async {
    final pserver = server.toNativeUtf8();
    final pchannel = channel.toNativeUtf8();
    ffi.Pointer<pkgffi.Utf8>? ppassword;
    if (password != null && password.isNotEmpty) {
      ppassword = password.toNativeUtf8();
    }
    final pgroupId = groupId.toNativeUtf8();
    ffi.Pointer<pkgffi.Utf8>? psaslUsername;
    if (saslUsername != null && saslUsername.isNotEmpty) {
      psaslUsername = saslUsername.toNativeUtf8();
    }
    ffi.Pointer<pkgffi.Utf8>? psaslPassword;
    if (saslPassword != null && saslPassword.isNotEmpty) {
      psaslPassword = saslPassword.toNativeUtf8();
    }
    ffi.Pointer<pkgffi.Utf8>? pcustomNickname;
    if (customNickname != null && customNickname.isNotEmpty) {
      pcustomNickname = customNickname.toNativeUtf8();
    }

    try {
      final result = _ffi.ircConnectChannel(
        pserver,
        port,
        pchannel,
        ppassword ?? ffi.Pointer<pkgffi.Utf8>.fromAddress(0),
        pgroupId,
        psaslUsername ?? ffi.Pointer<pkgffi.Utf8>.fromAddress(0),
        psaslPassword ?? ffi.Pointer<pkgffi.Utf8>.fromAddress(0),
        useSsl ? 1 : 0,
        pcustomNickname ?? ffi.Pointer<pkgffi.Utf8>.fromAddress(0),
      );
      return result == 1;
    } finally {
      pkgffi.malloc.free(pserver);
      pkgffi.malloc.free(pchannel);
      if (ppassword != null) {
        pkgffi.malloc.free(ppassword);
      }
      pkgffi.malloc.free(pgroupId);
      if (psaslUsername != null) {
        pkgffi.malloc.free(psaslUsername);
      }
      if (psaslPassword != null) {
        pkgffi.malloc.free(psaslPassword);
      }
      if (pcustomNickname != null) {
        pkgffi.malloc.free(pcustomNickname);
      }
    }
  }

  /// Disconnect from an IRC channel
  /// [channel] Channel name
  /// Returns true on success, false on failure
  Future<bool> disconnectIrcChannel(String channel) async {
    final pchannel = channel.toNativeUtf8();
    try {
      final result = _ffi.ircDisconnectChannel(pchannel);
      return result == 1;
    } finally {
      pkgffi.malloc.free(pchannel);
    }
  }

  /// Check if an IRC channel is connected
  /// [channel] Channel name
  /// Returns true if connected, false otherwise
  Future<bool> isIrcChannelConnected(String channel) async {
    final pchannel = channel.toNativeUtf8();
    try {
      final result = _ffi.ircIsConnected(pchannel);
      return result == 1;
    } finally {
      pkgffi.malloc.free(pchannel);
    }
  }

  /// Load IRC client dynamic library
  /// [libraryPath] Path to the IRC client dynamic library
  /// Returns true on success, false on failure
  Future<bool> loadIrcLibrary(String libraryPath) async {
    final plibPath = libraryPath.toNativeUtf8();
    try {
      final result = _ffi.ircLoadLibrary(plibPath);
      if (result == 1) {
        // Register IRC callbacks after library is loaded
        _ffi.ircSetConnectionStatusCallback(
            _ircConnectionStatusCbPtr, ffi.Pointer.fromAddress(0));
        _ffi.ircSetUserListCallback(
            _ircUserListCbPtr, ffi.Pointer.fromAddress(0));
        _ffi.ircSetUserJoinPartCallback(
            _ircUserJoinPartCbPtr, ffi.Pointer.fromAddress(0));
      }
      return result == 1;
    } finally {
      pkgffi.malloc.free(plibPath);
    }
  }

  /// Unload IRC client dynamic library
  /// Returns true on success, false on failure
  Future<bool> unloadIrcLibrary() async {
    final result = _ffi.ircUnloadLibrary();
    return result == 1;
  }

  /// Check if IRC library is loaded
  /// Returns true if loaded, false otherwise
  Future<bool> isIrcLibraryLoaded() async {
    final result = _ffi.ircIsLibraryLoaded();
    return result == 1;
  }

  // Check if a message is a reaction message (should not send receipt)
  bool _isReactionMessage(String? text) {
    if (text == null || text.isEmpty) return false;
    try {
      final json = jsonDecode(text);
      return json is Map<String, dynamic> && json['type'] == 'reaction';
    } catch (e) {
      return false;
    }
  }

  // IRC callback handlers
  void _onIrcConnectionStatus(String channel, int status, String? message) {
    _ircConnectionStatusCtrl
        .add((channel: channel, status: status, message: message));
  }

  void _onIrcUserList(String channel, List<String> users) {
    _ircUserListCtrl.add((channel: channel, users: users));
  }

  void _onIrcUserJoinPart(String channel, String nickname, bool joined) {
    _ircUserJoinPartCtrl
        .add((channel: channel, nickname: nickname, joined: joined));
  }

  // Send receipt (received or read) via custom message
  // receiptType: 'received' or 'read'
  // Note: reaction messages should not trigger receipts
  Future<void> _sendReceipt(String peerId, String msgID, String receiptType,
      {String? groupID}) async {
    try {
      final json = {
        'type': 'receipt',
        'msgID': msgID,
        'receiptType': receiptType, // 'received' or 'read'
        'sender': _selfId,
        if (groupID != null) 'groupID': groupID,
      };
      final jsonString = jsonEncode(json);
      final jsonBytes = utf8.encode(jsonString);

      if (groupID != null) {
        // Send group receipt
        final pg = groupID.toNativeUtf8();
        final dataPtr = pkgffi.malloc.allocate<ffi.Uint8>(jsonBytes.length);
        dataPtr.asTypedList(jsonBytes.length).setAll(0, jsonBytes);
        final result =
            _ffi.sendGroupCustomNative(pg, dataPtr, jsonBytes.length);
        pkgffi.malloc.free(pg);
        pkgffi.malloc.free(dataPtr);
        if (result != 1) {
          throw Exception('Failed to send group receipt');
        }
      } else {
        // Send C2C receipt
        final pu = peerId.toNativeUtf8();
        final dataPtr = pkgffi.malloc.allocate<ffi.Uint8>(jsonBytes.length);
        dataPtr.asTypedList(jsonBytes.length).setAll(0, jsonBytes);
        final result = _ffi.sendC2CCustomNative(pu, dataPtr, jsonBytes.length);
        pkgffi.malloc.free(pu);
        pkgffi.malloc.free(dataPtr);
        if (result != 1) {
          throw Exception('Failed to send receipt');
        }
      }
    } catch (e) {
      // Don't rethrow - receipt failures shouldn't break message flow
    }
  }

  // Handle received receipt (async helper)
  Future<void> _handleReceipt(
      String msgID, String receiptType, String sender, String? groupID) async {
    // For group messages, track receivers
    if (groupID != null && receiptType == 'received') {
      _messageReceivers.putIfAbsent(msgID, () => <String>{}).add(sender);
    }

    // Update message status in history
    final id = groupID ?? sender;
    final history = _historyById[id];
    if (history != null) {
      for (int i = 0; i < history.length; i++) {
        final msg = history[i];
        if (msg.msgID == msgID && msg.isSelf) {
          // Update self-sent message receipt status
          ChatMessage updatedMsg;
          if (receiptType == 'received') {
            updatedMsg = msg.copyWith(isReceived: true);
          } else if (receiptType == 'read') {
            updatedMsg = msg.copyWith(isReceived: true, isRead: true);
          } else {
            return; // Unknown receipt type
          }
          history[i] = updatedMsg;
          await _saveHistory(id);
          // Emit updated message to stream for UI update
          _messages.add(updatedMsg);
          break;
        }
      }
    }
  }

  // Get list of users who received a group message
  List<String> getMessageReceivers(String msgID) {
    return _messageReceivers[msgID]?.toList() ?? [];
  }

  // Get count of users who received a group message
  int getMessageReceiverCount(String msgID) {
    return _messageReceivers[msgID]?.length ?? 0;
  }

  // Mark message as read and send read receipt
  Future<void> markMessageAsRead(String peerId, String msgID,
      {String? groupID}) async {
    // Update message status in history
    final id = groupID ?? peerId;
    final history = _historyById[id];
    if (history != null) {
      for (int i = 0; i < history.length; i++) {
        final msg = history[i];
        if (msg.msgID == msgID && !msg.isSelf) {
          // Update received message to read status
          final updatedMsg = msg.copyWith(isRead: true);
          history[i] = updatedMsg;
          await _saveHistory(id);
          // Send read receipt
          await _sendReceipt(peerId, msgID, 'read', groupID: groupID);
          break;
        }
      }
    }
  }

  // Send reaction via custom message
  Future<void> sendReaction(
      String peerId, String msgID, String reactionID, String action,
      {String? groupID}) async {
    try {
      final json = {
        'type': 'reaction',
        'msgID': msgID,
        'reactionID': reactionID,
        'action': action, // 'add' or 'remove'
        'sender': _selfId,
        if (groupID != null) 'groupID': groupID,
      };
      final jsonString = jsonEncode(json);
      final jsonBytes = utf8.encode(jsonString);

      if (groupID != null) {
        // Send group reaction
        final pg = groupID.toNativeUtf8();
        final dataPtr = pkgffi.malloc.allocate<ffi.Uint8>(jsonBytes.length);
        dataPtr.asTypedList(jsonBytes.length).setAll(0, jsonBytes);
        final result =
            _ffi.sendGroupCustomNative(pg, dataPtr, jsonBytes.length);
        pkgffi.malloc.free(pg);
        pkgffi.malloc.free(dataPtr);
        if (result != 1) {
          throw Exception('Failed to send group reaction');
        }
      } else {
        // Send C2C reaction
        final pu = peerId.toNativeUtf8();
        final dataPtr = pkgffi.malloc.allocate<ffi.Uint8>(jsonBytes.length);
        dataPtr.asTypedList(jsonBytes.length).setAll(0, jsonBytes);
        final result = _ffi.sendC2CCustomNative(pu, dataPtr, jsonBytes.length);
        pkgffi.malloc.free(pu);
        pkgffi.malloc.free(dataPtr);
        if (result != 1) {
          throw Exception('Failed to send reaction');
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  // Storage key used by the offline-message queue for group messages.
  // Prefixed so it can't collide with the 64-char hex peer IDs used for the
  // C2C queue, which share the same persistence backing store.
  String _groupOfflineQueueKey(String groupId) => 'group:$groupId';

  Future<void> sendGroupText(String groupId, String text) async {
    // P0-C1: parallel of the C2C offline-queue behavior. Group messages
    // used to be sent fire-and-forget even when we had no DHT connection
    // — Tox would silently drop them with no path for recovery, and the
    // user only learned about it when peers asked why their replies went
    // nowhere. Now: if we're not connected, queue the message and surface
    // it as pending; drain on the next conn:success.
    if (!_isConnected) {
      await _queueOfflineGroupText(groupId, text);
      return;
    }
    final pg = groupId.toNativeUtf8();
    final pt = text.toNativeUtf8();
    _ffi.sendGroupText(pg, pt);
    pkgffi.malloc.free(pg);
    pkgffi.malloc.free(pt);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sequence = _msgIDSequence++;
    final msgID = '${timestamp}_${sequence}_${_selfId}_$groupId';
    final out = ChatMessage(
      text: text,
      fromUserId: _selfId,
      isSelf: true,
      timestamp: DateTime.now(),
      groupId: groupId,
      msgID: msgID,
    );
    _lastByPeer[groupId] = out;
    _unreadByPeer[groupId] = 0;
    _appendHistory(groupId, out);
    _messages.add(out);
  }

  Future<void> _queueOfflineGroupText(String groupId, String text) async {
    // INVARIANT (drain depends on this): the queue item and the pending row
    // MUST share this one `now` — `_sendPendingGroupMessages` identifies this
    // item's row by EXACT-ms timestamp equality. Don't split into two calls.
    final now = DateTime.now();
    final storageKey = _groupOfflineQueueKey(groupId);
    // Compute msgID before enqueuing so the queue item carries the durable id.
    final timestamp = now.millisecondsSinceEpoch;
    final sequence = _msgIDSequence++;
    final msgID = '${timestamp}_${sequence}_${_selfId}_$groupId';
    _addToOfflineQueue(storageKey, (
      kind: 'text',
      text: text,
      filePath: null,
      fileName: null,
      timestamp: now,
      msgID: msgID,
    ));
    final msg = ChatMessage(
      text: text,
      fromUserId: _selfId,
      isSelf: true,
      timestamp: now,
      groupId: groupId,
      isPending: true,
      msgID: msgID,
    );
    _lastByPeer[groupId] = msg;
    _appendHistory(groupId, msg);
    _messages.add(msg);
    await _saveOfflineQueue();
  }

  /// Drains pending group messages for [groupId]. Called after a
  /// conn:success transition, when we believe we can reach the DHT and
  /// therefore the peers we're grouped with. There is no per-group-member
  /// presence in Tox's old-conference or new-group APIs (peers come and
  /// go independently), so the trigger is the overall connection state
  /// rather than per-peer online status as it is for C2C.
  Future<void> _sendPendingGroupMessages(String groupId) async {
    final storageKey = _groupOfflineQueueKey(groupId);
    final pending = List<OfflineMessageItem>.from(_getOfflineQueue(storageKey));
    if (pending.isEmpty) return;
    _logger?.log(
        '[FfiChatService] _sendPendingGroupMessages: draining ${pending.length} item(s) for groupId=$groupId');
    final history = _historyById[groupId];
    for (final item in pending) {
      // We only queue text items today; skip anything that snuck in as a
      // file (group file transfer is unsupported anyway — see sendGroupFile).
      if (item.kind != 'text' || item.text.isEmpty) {
        await _offlineQueuePersistence.removeItem(storageKey, item);
        continue;
      }
      if (!_isConnected) {
        _logger?.log(
            '[FfiChatService] _sendPendingGroupMessages: lost connection mid-drain for $groupId; ${pending.length - pending.indexOf(item)} item(s) kept in queue');
        break;
      }
      var dispatched = false;
      try {
        final pg = groupId.toNativeUtf8();
        final pt = item.text.toNativeUtf8();
        try {
          _ffi.sendGroupText(pg, pt);
        } finally {
          pkgffi.malloc.free(pg);
          pkgffi.malloc.free(pt);
        }
        // #25 Option B: durably clear the queue entry NOW (after send, before
        // the history reconcile) so a crash can't make the next drain re-send.
        // Same reorder as the C2C drain paths.
        await _offlineQueuePersistence.removeItem(storageKey, item);
        // #28 / #25 Property 5 (group): the send succeeded AND the queue entry
        // is durably gone. Any throw past here is a post-dispatch reconcile
        // failure, NOT a send failure — the catch must not mark it failed or
        // re-remove. (A removeItem throw above leaves dispatched=false, which is
        // treated as not-yet-dispatched, matching the C2C drain.)
        dispatched = true;
        // Flip the matching pending bubble to delivered. Identity via
        // _offlineRowMatchesItem (msgID-first, exact-ms fallback) — not a ±10s
        // window, which could cross two identical group texts queued close
        // together. (Same Bug-F-class fix as the C2C drain matchers.)
        if (history != null) {
          final itemMs = item.timestamp.millisecondsSinceEpoch;
          for (int i = history.length - 1; i >= 0; i--) {
            final msg = history[i];
            if (msg.isSelf &&
                msg.isPending &&
                msg.filePath == null &&
                msg.text == item.text &&
                _offlineRowMatchesItem(msg, item, itemMs)) {
              history[i] = msg.copyWith(isPending: false);
              _lastByPeer[groupId] = history[i];
              try {
                await _saveHistory(groupId);
              } catch (_) {}
              break;
            }
          }
        }
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e, stackTrace) {
        if (dispatched) {
          // #25 Property 5 (group): the message WAS sent and the queue entry
          // removed; only the post-dispatch history reconcile threw. Do NOT mark
          // it failed (it was delivered) and do NOT re-remove — the pending row
          // self-heals to delivered on the next reload.
          _logger?.logError(
              '[FfiChatService] _sendPendingGroupMessages: post-dispatch '
              'reconcile failed for an already-sent group text (delivered; row '
              'self-heals on reload)',
              e,
              stackTrace);
          continue;
        }
        // #28: a genuine pre-dispatch send failure. Mirror the C2C drain —
        // surface a failed bubble (flip the pending row non-pending) instead of
        // silently dropping the message, then clear the queue entry (one drain
        // attempt per online transition, matching C2C semantics). Previously this
        // catch only removed the item, leaving the bubble stuck pending forever
        // and the message lost with no UI signal.
        _logger?.logError(
            '[FfiChatService] _sendPendingGroupMessages: drain failed for group $groupId',
            e,
            stackTrace);
        _markPendingItemFailed(groupId, history, item, isFile: false);
        await _offlineQueuePersistence.removeItem(storageKey, item);
      }
    }
    await _saveOfflineQueue();
  }

  Future<void> _drainAllPendingGroupMessages() async {
    for (final gid in List<String>.from(_knownGroups)) {
      try {
        await _sendPendingGroupMessages(gid);
      } catch (e, st) {
        _logger?.logError(
            '[FfiChatService] _drainAllPendingGroupMessages: error for $gid',
            e,
            st);
      }
    }
  }

  Future<void> sendGroupFile(String groupId, String filePath) async {
    // Tox protocol only supports peer-to-peer file transfer, not group file transfer.
    // Throw a user-facing message so the UI can show it via onSDKFailed.
    throw Exception(
        'File transfer in group chats is not supported. Please send files in a private chat.');
  }

  /// H-B: tox_file_send caps the filename at 255 UTF-8 bytes. Multi-byte
  /// names (Chinese, emoji, …) hit the limit at ~85 chars and the C side
  /// silently rejects the transfer. Truncate to [maxBytes] UTF-8 bytes
  /// while preserving the file extension and snapping to a valid UTF-8
  /// boundary so the resulting name is still well-formed.
  String _truncateFileNameForTox(String name, {int maxBytes = 250}) {
    final bytes = utf8.encode(name);
    if (bytes.length <= maxBytes) return name;
    final ext = p.extension(name); // includes leading dot, e.g. ".jpg"
    final extBytes = utf8.encode(ext).length;
    final base = p.basenameWithoutExtension(name);
    final baseBudget = maxBytes - extBytes;
    if (baseBudget <= 0) {
      // Pathological case: extension alone exceeds the budget. Drop the
      // extension and truncate the base by bytes.
      int lo = 0, hi = base.length;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (utf8.encode(base.substring(0, mid)).length <= maxBytes) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      return base.substring(0, lo);
    }
    // Binary search the longest character prefix of [base] whose UTF-8
    // encoding fits in [baseBudget] bytes.
    int lo = 0, hi = base.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (utf8.encode(base.substring(0, mid)).length <= baseBudget) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return base.substring(0, lo) + ext;
  }

  /// H-B: when [originalPath]'s basename is too long for tox, materialise
  /// a symlink (or a fallback copy) under a temp dir whose name is the
  /// truncated form. Returns the path the FFI layer should send. The
  /// caller is responsible for cleaning up the temp entry — we currently
  /// rely on the OS temp-dir reaper since the transfer outlives the call.
  Future<String> _materializeSafeSendPath(String originalPath) async {
    final basename = p.basename(originalPath);
    final safeName = _truncateFileNameForTox(basename);
    if (safeName == basename) return originalPath;
    try {
      final dir = await Directory.systemTemp.createTemp('tim2tox_send_');
      final linkPath = p.join(dir.path, safeName);
      try {
        await Link(linkPath).create(originalPath);
        return linkPath;
      } catch (_) {
        // Symlink creation failed (Windows w/o privileges, FUSE mounts,
        // etc.). Fall back to a copy so the send still succeeds.
        await File(originalPath).copy(linkPath);
        return linkPath;
      }
    } catch (e, st) {
      _logger?.logError(
          '[FfiChatService] _materializeSafeSendPath: failed to materialise truncated-name path for $originalPath; falling back to original path',
          e,
          st);
      return originalPath;
    }
  }

  Future<void> sendFile(
    String peerId,
    String filePath, {
    bool addToChatHistory = true,
    bool throwIfOffline = false,
  }) async {
    // Normalize friend ID to 64 characters (public key length)
    final normalizedPeerId = _normalizeFriendId(peerId);
    // Check if file exists
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File does not exist');
    }
    final fileSize = await file.length();
    if (fileSize == 0) {
      throw Exception('File is empty');
    }
    // Check if friend is online
    final friends = await getFriendList();
    final friend = friends.firstWhere((f) => f.userId == normalizedPeerId,
        orElse: () => (
              userId: normalizedPeerId,
              nickName: '',
              status: '',
              online: false
            ));
    final isOnline = friend.online;

    if (!isOnline) {
      if (throwIfOffline) {
        // Drain path: friend went offline again before our send landed.
        // Leak the signal so _sendPendingMessages can leave the queue item
        // in place for the next online transition.
        throw const _OfflineDuringDrain();
      }
      // Friend is offline - queue the file send and surface a pending bubble.
      // Drain happens on the next online transition (see _sendPendingMessages).
      if (addToChatHistory) {
        await _queueOfflineFile(normalizedPeerId, filePath);
      }
      return;
    }

    // H-B: if the basename exceeds tox's 255-UTF-8-byte filename limit,
    // hand the FFI a symlink/copy with a safely-truncated name. The
    // history record below still uses the original [filePath] so the UI
    // and on-disk references stay intact.
    final effectiveSendPath = await _materializeSafeSendPath(filePath);

    // Friend is online - send immediately
    final pto = normalizedPeerId.toNativeUtf8();
    final pfp = effectiveSendPath.toNativeUtf8();
    final result = _ffi.sendFileNative(_ffi.getCurrentInstanceId(), pto, pfp);
    pkgffi.malloc.free(pto);
    pkgffi.malloc.free(pfp);
    if (result <= 0) {
      // -4 == FRIEND_NOT_CONNECTED: friend was reported online by the
      // pre-check but went offline before the FFI call landed. Fall through
      // to queueing instead of throwing so the UI keeps the message pending.
      if (result == -4) {
        if (throwIfOffline) {
          throw const _OfflineDuringDrain();
        }
        if (addToChatHistory) {
          await _queueOfflineFile(normalizedPeerId, filePath);
          return;
        }
      }
      final message = switch (result) {
        -1 => 'Tox is not ready. Please wait for connection.',
        -2 => 'Invalid peer ID format.',
        -3 => 'Peer is not in your friend list.',
        -4 => 'Peer is offline. Try again when they are online.',
        -5 => 'QR card file missing or empty.',
        -6 => 'Cannot read QR card file.',
        -7 => 'Tox refused the file transfer.',
        _ => 'Failed to send file (code $result).',
      };
      throw Exception(message);
    }
    if (!addToChatHistory) {
      return;
    }

    // add a local outgoing message immediately
    final kind = _detectKind(filePath);
    // P1-1: include the same monotonic sequence used for inbound msgIDs so
    // back-to-back outgoing file sends in the same millisecond don't collide
    // (which would let history dedupe drop the second message).
    final msgID =
        '${DateTime.now().millisecondsSinceEpoch}_${_msgIDSequence++}_$_selfId';
    final out = ChatMessage(
      text: '',
      fromUserId: _selfId,
      isSelf: true,
      timestamp: DateTime.now(),
      groupId: null,
      filePath: filePath,
      mediaKind: kind,
      isPending: false,
      msgID: msgID,
    );
    // Update last message for this peer
    _lastByPeer[normalizedPeerId] = out;
    // remember last sent path and msgID for progress correlation
    _lastSentPathByPeer[normalizedPeerId] = filePath;
    // Store msgID for this path to enable progress matching.
    // R-2: always overwrite — the freshest send wins. The old containsKey
    // guard meant a second send of the same file routed progress to the
    // first (now-completed) msgID.
    _pathToMsgID[filePath] = msgID;
    // P2-23: precise per-message reverse lookup. _lastSentPathByPeer is a
    // single-slot map keyed by peer, so back-to-back concurrent sends to
    // the same peer overwrite each other and the progress_send handler
    // can't tell which msgID a given chunk belongs to. Store
    // (msgID -> path) so the progress handler can recover the right
    // msgID from the path it just received a chunk for.
    _msgIDToSentPath[msgID] = filePath;
    // Add to history FIRST, then trigger stream update
    // This ensures getHistory() returns the new message when stream listener refreshes
    _appendHistory(normalizedPeerId, out);
    // Trigger stream update - listener will refresh from getHistory()
    _messages.add(out);
  }

  // File transfer control methods
  /// Accept file transfer. [instanceId] must be the receiver's instance (from file_request event);
  /// if omitted, uses current instance (wrong in multi-instance when event is for another instance).
  Future<void> acceptFileTransfer(String peerId, int fileNumber,
      {int? instanceId}) async {
    // Normalize friend ID to 64 characters (public key length)
    final normalizedPeerId = _normalizeFriendId(peerId);
    final pto = normalizedPeerId.toNativeUtf8();
    final effectiveInstanceId = instanceId ?? _ffi.getCurrentInstanceId();
    final result = _ffi.fileControlNative(
        effectiveInstanceId, pto, fileNumber, 0); // 0 = RESUME
    pkgffi.malloc.free(pto);
    if (result <= 0) {
      final message = switch (result) {
        -1 => 'Invalid arguments.',
        -2 => 'Friend not found.',
        -3 => 'File transfer not found.',
        -4 => 'File control failed.',
        _ => 'Failed to accept file transfer (code $result).',
      };
      throw Exception(message);
    }
  }

  Future<void> rejectFileTransfer(String peerId, int fileNumber) async {
    final normalizedPeerId = _normalizeFriendId(peerId);
    final pto = normalizedPeerId.toNativeUtf8();
    final result = _ffi.fileControlNative(
        _ffi.getCurrentInstanceId(), pto, fileNumber, 2); // 2 = CANCEL
    pkgffi.malloc.free(pto);
    if (result <= 0) {
      final message = switch (result) {
        -1 => 'Invalid arguments.',
        -2 => 'Friend not found.',
        -3 => 'File transfer not found.',
        -4 => 'File control failed.',
        _ => 'Failed to reject file transfer (code $result).',
      };
      throw Exception(message);
    }
    // Clean up mapping after rejection
    _cleanupFileNumberMapping(normalizedPeerId, peerId, fileNumber);
  }

  Future<void> pauseFileTransfer(String peerId, int fileNumber) async {
    // Normalize to 64 chars (public key) - FFI file_control expects exactly 64 hex chars
    final normalizedPeerId = _normalizeFriendId(peerId);
    final pto = normalizedPeerId.toNativeUtf8();
    final result = _ffi.fileControlNative(
        _ffi.getCurrentInstanceId(), pto, fileNumber, 1); // 1 = PAUSE
    pkgffi.malloc.free(pto);
    if (result <= 0) {
      final message = switch (result) {
        -1 => 'Invalid arguments.',
        -2 => 'Friend not found.',
        -3 => 'File transfer not found.',
        -4 => 'File control failed.',
        _ => 'Failed to pause file transfer (code $result).',
      };
      throw Exception(message);
    }
  }

  Future<void> resumeFileTransfer(String peerId, int fileNumber) async {
    // Normalize to 64 chars (public key) - FFI file_control expects exactly 64 hex chars
    final normalizedPeerId = _normalizeFriendId(peerId);
    final pto = normalizedPeerId.toNativeUtf8();
    final result = _ffi.fileControlNative(
        _ffi.getCurrentInstanceId(), pto, fileNumber, 0); // 0 = RESUME
    pkgffi.malloc.free(pto);
    if (result <= 0) {
      final message = switch (result) {
        -1 => 'Invalid arguments.',
        -2 => 'Friend not found.',
        -3 => 'File transfer not found.',
        -4 => 'File control failed.',
        _ => 'Failed to resume file transfer (code $result).',
      };
      throw Exception(message);
    }
  }

  Future<void> cancelFileTransfer(String peerId, int fileNumber) async {
    final normalizedPeerId = _normalizeFriendId(peerId);
    final pto = normalizedPeerId.toNativeUtf8();
    final result = _ffi.fileControlNative(
        _ffi.getCurrentInstanceId(), pto, fileNumber, 2); // 2 = CANCEL
    pkgffi.malloc.free(pto);
    if (result <= 0) {
      final message = switch (result) {
        -1 => 'Invalid arguments.',
        -2 => 'Friend not found.',
        -3 => 'File transfer not found.',
        -4 => 'File control failed.',
        _ => 'Failed to cancel file transfer (code $result).',
      };
      throw Exception(message);
    }
    // Clean up mapping after cancellation
    _cleanupFileNumberMapping(normalizedPeerId, peerId, fileNumber);
  }

  /// Helper method to safely clean up _fileNumberToMsgID mapping
  /// This ensures only the specific msgID's mapping is removed, preventing fileNumber reuse issues
  void _cleanupFileNumberMapping(
      String normalizedUid, String uid, int fileNumber) {
    // Find msgID from _fileReceiveProgress first
    String? msgID;
    if (_fileReceiveProgress.containsKey((normalizedUid, fileNumber))) {
      msgID = _fileReceiveProgress[(normalizedUid, fileNumber)]!.msgID;
    } else if (_fileReceiveProgress.containsKey((uid, fileNumber))) {
      msgID = _fileReceiveProgress[(uid, fileNumber)]!.msgID;
    }

    if (msgID != null) {
      // Only remove mapping for this specific msgID
      _fileNumberToMsgID.removeWhere((key, value) =>
          key.$2 == fileNumber &&
          (key.$1 == normalizedUid || key.$1 == uid) &&
          value == msgID);
      _logger?.log(
          '[FfiChatService] Cleaned up _fileNumberToMsgID mapping for fileNumber=$fileNumber, msgID=$msgID');
    } else {
      // If msgID not found, remove all entries with this fileNumber (fallback)
      _fileNumberToMsgID.remove((normalizedUid, fileNumber));
      _fileNumberToMsgID.remove((uid, fileNumber));
      _logger?.log(
          '[FfiChatService] Cleaned up _fileNumberToMsgID mapping for fileNumber=$fileNumber (msgID not found, removed all entries)');
    }
  }

  void _cleanupReceiveTrackingForCompletedFile(
      String uid, int? fileNumber, String? msgID) {
    if (fileNumber != null) {
      final normalizedUid = uid.length > 64 ? _normalizeFriendId(uid) : uid;
      _fileReceiveProgress.remove((normalizedUid, fileNumber));
      _fileReceiveProgress.remove((uid, fileNumber));
      _pendingFileTransfers.remove((normalizedUid, fileNumber));
      _pendingFileTransfers.remove((uid, fileNumber));
      _fileNumberToMsgID.remove((normalizedUid, fileNumber));
      _fileNumberToMsgID.remove((uid, fileNumber));
      _progressKeyCache.removeWhere((_, v) =>
          v.$2 == fileNumber && (v.$1 == normalizedUid || v.$1 == uid));
    }
    if (msgID != null && msgID.isNotEmpty) {
      _msgIDToFileTransfer.remove(msgID);
    }
  }

  Future<bool> addBootstrapNode(
      String host, int port, String publicKeyHex) async {
    final phost = host.toNativeUtf8();
    final pkey = publicKeyHex.toNativeUtf8();
    final result =
        _ffi.addBootstrapNode(_ffi.getCurrentInstanceId(), phost, port, pkey);
    pkgffi.malloc.free(phost);
    pkgffi.malloc.free(pkey);
    if (result != 0) {
      // Save as current bootstrap node
      await _prefs?.setCurrentBootstrapNode(host, port, publicKeyHex);
    }
    return result != 0;
  }

  /// Get UDP port this Tox instance is bound to
  /// Returns port number on success, 0 on failure
  int getUdpPort() {
    return _ffi.getUdpPort(_ffi.getCurrentInstanceId());
  }

  /// Get DHT ID (public key) of this Tox instance
  /// Returns DHT ID as hex string (64 characters), or null on error
  /// Create test instance with options (for testing)
  /// Returns instance handle on success, 0 on failure
  int createTestInstanceEx(String initPath,
      {bool localDiscoveryEnabled = true, bool ipv6Enabled = true}) {
    final p = initPath.toNativeUtf8();
    try {
      final handle = _ffi.createTestInstanceExNative(
          p, localDiscoveryEnabled ? 1 : 0, ipv6Enabled ? 1 : 0);
      return handle;
    } finally {
      pkgffi.malloc.free(p);
    }
  }

  /// Send DHT nodes request
  /// publicKey: public key of the node to query (64 hex chars)
  /// ip: IP address of the node to query
  /// port: UDP port of the node to query
  /// targetPublicKey: public key of the node we're looking for (64 hex chars)
  /// Returns true on success, false on failure
  bool dhtSendNodesRequest(
      String publicKey, String ip, int port, String targetPublicKey) {
    final pPublicKey = publicKey.toNativeUtf8();
    final pIp = ip.toNativeUtf8();
    final pTargetPublicKey = targetPublicKey.toNativeUtf8();
    try {
      final result = _ffi.dhtSendNodesRequestNative(
          pPublicKey, pIp, port, pTargetPublicKey);
      return result == 1;
    } finally {
      pkgffi.malloc.free(pPublicKey);
      pkgffi.malloc.free(pIp);
      pkgffi.malloc.free(pTargetPublicKey);
    }
  }

  // DHT nodes response callback storage
  void Function(String publicKey, String ip, int port)?
      _dhtNodesResponseCallback;

  /// Internal handler for DHT nodes response (called from static trampoline)
  void _onDhtNodesResponse(String publicKey, String ip, int port) {
    _dhtNodesResponseCallback?.call(publicKey, ip, port);
  }

  /// Set DHT nodes response callback
  /// callback: callback function (publicKey, ip, port) -> void
  /// Note: This callback may be called from Tox's background thread
  /// Supports multi-instance scenarios by routing based on instance ID
  void setDhtNodesResponseCallback(
      void Function(String publicKey, String ip, int port) callback) {
    _dhtNodesResponseCallback = callback;

    // Get current instance ID for routing
    // Note: This requires that setCurrentInstance has been called before setting the callback
    int? currentInstanceId;
    try {
      // Try to get current instance ID by checking if we can get a valid instance
      // We'll use a workaround: store the service in the map with instance ID
      // The instance ID will be determined when the callback is actually set
      currentInstanceId = _getCurrentInstanceId();
    } catch (e) {
      // If we can't get instance ID, fall back to global service (backward compatibility)
      _globalService = this;
    }

    // Register this service instance in the global map for routing
    if (currentInstanceId != null && currentInstanceId != 0) {
      _instanceId = currentInstanceId;
      synchronized(_instanceServicesLock, () {
        _instanceServices[currentInstanceId!] = this;
        _knownInstanceIds.add(currentInstanceId!);
      });

      // Create user_data pointer containing the instance ID. Heap-allocated
      // so it remains valid across thread hops when the listener posts the
      // call to the isolate.
      final instanceIdPtr = pkgffi.malloc<ffi.Int64>();
      instanceIdPtr.value = currentInstanceId;

      // Bind via NativeCallable.listener so the trampoline is invoked on this
      // isolate's event loop instead of Tox's background event_thread. The
      // shared listener routes by instance_id (userData) to the right service.
      _ffi.setDhtNodesResponseCallbackNative(currentInstanceId!,
          _dhtNodesResponseNativeFunction(), instanceIdPtr.cast());

      // Note: We don't free instanceIdPtr here because it needs to persist
      // for the callback lifetime. It will be freed when the callback is
      // unregistered or the service is disposed.
    } else {
      // Fallback to global service for default instance (backward compatibility)
      _globalService = this;
      _ffi.setDhtNodesResponseCallbackNative(
          0, _dhtNodesResponseNativeFunction(), ffi.nullptr);
    }
  }

  /// Get current instance ID (helper method)
  /// Returns the current instance ID, or null if using default instance
  int? _getCurrentInstanceId() {
    try {
      final instanceId = _ffi.getCurrentInstanceId();
      // Return null for default instance (0), otherwise return the instance ID
      return instanceId != 0 ? instanceId : null;
    } catch (e) {
      // If FFI call fails, return null (default instance)
      return null;
    }
  }

  String? getDhtId() {
    final buf = pkgffi.malloc.allocate<ffi.Int8>(65);
    try {
      final len = _ffi.getDhtIdNative(buf, 65);
      if (len > 0 && len <= 64) {
        return buf.cast<pkgffi.Utf8>().toDartString(length: len);
      }
      return null;
    } finally {
      pkgffi.malloc.free(buf);
    }
  }

  /// Test bootstrap node connectivity by attempting to connect to it
  /// Returns true if node appears to be reachable, false otherwise
  Future<bool> testBootstrapNode(String host, int port, String publicKeyHex,
      {Duration timeout = const Duration(seconds: 3)}) async {
    // First, try to resolve hostname (for domain names, not IPs)
    InternetAddress? address;
    try {
      final addresses = await InternetAddress.lookup(host).timeout(timeout);
      if (addresses.isEmpty) {
        return false;
      }
      address = addresses.first;
    } catch (e) {
      // For IP addresses, try to parse directly
      try {
        address = InternetAddress(host);
      } catch (e2) {
        // Invalid host format
        return false;
      }
    }

    // Try to establish a TCP connection to verify the node is reachable
    // This is a more reliable test than just adding the node to Tox
    if (address == null) {
      return false;
    }

    try {
      final socket = await Socket.connect(
        address,
        port,
        timeout: timeout,
      ).timeout(timeout);
      await socket.close();
      // Connection successful, node is reachable
      return true;
    } catch (e) {
      // Connection failed, node is not reachable
      return false;
    }
  }

  // Calculate SHA256 hash of avatar file
  Future<String?> _calculateAvatarHash(String? avatarPath) async {
    if (avatarPath == null || avatarPath.isEmpty) return null;
    try {
      final file = File(avatarPath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes);
      return hash.toString();
    } catch (e) {
      return null;
    }
  }

  // Send avatar to a friend if their cached hash is outdated.
  // [avatarPathOverride] bypasses the prefs lookup, avoiding stale scoped-key
  // reads when the UI sets the path via Prefs (unscoped) but the adapter has
  // an older scoped value.
  Future<void> _sendAvatarToFriendIfNeeded(String friendId,
      {String? avatarPathOverride}) async {
    if (!_avatarBroadcastAsChatFileEnabled) {
      return;
    }
    if (!_isConnected) {
      _logger?.log(
          '[FfiChatService] _sendAvatarToFriendIfNeeded: skipped – not connected');
      return;
    }

    final avatarPath = avatarPathOverride ?? await _prefs?.getAvatarPath();
    if (avatarPath == null || avatarPath.isEmpty) {
      _logger?.log(
          '[FfiChatService] _sendAvatarToFriendIfNeeded: skipped – no avatar path');
      return;
    }

    final currentHash = await _calculateAvatarHash(avatarPath);
    if (currentHash == null) {
      _logger?.log(
          '[FfiChatService] _sendAvatarToFriendIfNeeded: skipped – hash null for $avatarPath');
      return;
    }

    final friendHash = await _prefs?.getFriendAvatarHash(friendId);

    if (friendHash != currentHash) {
      try {
        _logger?.log(
            '[FfiChatService] _sendAvatarToFriendIfNeeded: sending avatar to $friendId (hash $currentHash, friendHash $friendHash)');
        await sendFile(friendId, avatarPath, addToChatHistory: false);
        await _prefs?.setFriendAvatarHash(friendId, currentHash);
        _logger?.log(
            '[FfiChatService] _sendAvatarToFriendIfNeeded: sent successfully to $friendId');
      } catch (e) {
        _logger?.logError(
            '[FfiChatService] _sendAvatarToFriendIfNeeded: failed to send to $friendId',
            e,
            StackTrace.current);
      }
    } else {
      _logger?.log(
          '[FfiChatService] _sendAvatarToFriendIfNeeded: skipped $friendId – hash unchanged');
    }
  }

  // Send avatar to all online friends when connection is established
  Future<void> _sendAvatarToAllFriendsOnConnect() async {
    if (!_avatarBroadcastAsChatFileEnabled) {
      return;
    }
    // Wait a bit for friend list to be populated
    await Future.delayed(const Duration(milliseconds: 500));
    // Get all friends and send avatar to those who are online
    final friends = await getFriendList();
    for (final friend in friends) {
      if (friend.online) {
        unawaited(_sendAvatarToFriendIfNeeded(friend.userId));
      }
    }
  }

  // Send avatar to all online friends when avatar changes.
  // [avatarPathOverride] is used when the caller already knows the correct path
  // (e.g. updateAvatar), avoiding a stale read from the prefs adapter.
  Future<void> sendAvatarToAllFriends({String? avatarPathOverride}) async {
    if (!_avatarBroadcastAsChatFileEnabled) {
      return;
    }
    if (!_isConnected) {
      _logger?.log(
          '[FfiChatService] sendAvatarToAllFriends: skipped – not connected');
      return;
    }

    final avatarPath = avatarPathOverride ?? await _prefs?.getAvatarPath();
    if (avatarPath == null || avatarPath.isEmpty) {
      _logger?.log(
          '[FfiChatService] sendAvatarToAllFriends: skipped – no avatar path');
      return;
    }

    final currentHash = await _calculateAvatarHash(avatarPath);
    if (currentHash == null) {
      _logger?.log(
          '[FfiChatService] sendAvatarToAllFriends: skipped – hash null for $avatarPath');
      return;
    }

    _currentAvatarHash = currentHash;
    await _prefs?.setSelfAvatarHash(currentHash);

    final friends = await getFriendList();
    int sentCount = 0;
    int skippedCount = 0;
    int offlineCount = 0;

    for (final friend in friends) {
      if (friend.online) {
        final friendHash = await _prefs?.getFriendAvatarHash(friend.userId);
        if (friendHash != currentHash) {
          try {
            await sendFile(friend.userId, avatarPath, addToChatHistory: false);
            await _prefs?.setFriendAvatarHash(friend.userId, currentHash);
            sentCount++;
          } catch (e) {
            _logger?.logError(
                '[FfiChatService] sendAvatarToAllFriends: failed to send to ${friend.userId}',
                e,
                StackTrace.current);
          }
        } else {
          skippedCount++;
        }
      } else {
        offlineCount++;
      }
    }
    _logger?.log(
        '[FfiChatService] sendAvatarToAllFriends: done – sent=$sentCount, skipped=$skippedCount, offline=$offlineCount, path=$avatarPath');
  }

  // Get Downloads directory path (cross-platform)
  // First checks user-configured directory, then falls back to default Downloads
  /// Get downloads directory
  /// For desktop platforms (Windows/Linux/macOS), prioritizes the directory configured in settings page
  /// For mobile platforms (Android/iOS), uses platform-specific default directories
  Future<String?> _getDownloadsDirectory() async {
    try {
      // First, check if user has configured a custom downloads directory in settings page
      // This is especially important for desktop platforms where users can configure their preferred directory
      final customDir = await _prefs?.getDownloadsDirectory();
      _logger?.log(
          '[FfiChatService] _getDownloadsDirectory: custom from prefs=${customDir ?? "null"}');
      if (customDir != null && customDir.isNotEmpty) {
        final dir = Directory(customDir);
        if (await dir.exists()) {
          _logger?.log(
              '[FfiChatService] _getDownloadsDirectory: using configured path (exists): $customDir');
          return customDir;
        } else {
          // Custom directory doesn't exist, try to create it
          try {
            await dir.create(recursive: true);
            _logger?.log(
                '[FfiChatService] _getDownloadsDirectory: using configured path (created): $customDir');
            return customDir;
          } catch (e) {
            // Failed to create, fall back to default
            _logger?.log(
                '[FfiChatService] _getDownloadsDirectory: failed to create custom dir, falling back: $e');
          }
        }
      }

      // Fall back to default Downloads directory
      // For desktop platforms: use system Downloads directory (~/Downloads or %USERPROFILE%\Downloads)
      // For mobile platforms: platform-specific directories
      if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
        // Use path_provider to get system Downloads directory for desktop platforms
        try {
          final downloadsDir = await getDownloadsDirectory();
          if (downloadsDir != null) {
            if (!await downloadsDir.exists()) {
              await downloadsDir.create(recursive: true);
            }
            _logger?.log(
                '[FfiChatService] _getDownloadsDirectory: using path_provider: ${downloadsDir.path}');
            return downloadsDir.path;
          }
        } catch (e) {
          // If path_provider fails, fall back to manual path construction
          _logger?.log(
              '[FfiChatService] _getDownloadsDirectory: path_provider failed: $e');
        }
        // Fallback: manual path construction for desktop platforms
        if (Platform.isMacOS || Platform.isLinux) {
          final home = Platform.environment['HOME'];
          if (home != null) {
            final downloadsDir = Directory(p.join(home, 'Downloads'));
            if (!await downloadsDir.exists()) {
              await downloadsDir.create(recursive: true);
            }
            _logger?.log(
                '[FfiChatService] _getDownloadsDirectory: using HOME fallback: ${downloadsDir.path}');
            return downloadsDir.path;
          }
        } else if (Platform.isWindows) {
          final userProfile = Platform.environment['USERPROFILE'];
          if (userProfile != null) {
            final downloadsDir = Directory(p.join(userProfile, 'Downloads'));
            if (!await downloadsDir.exists()) {
              await downloadsDir.create(recursive: true);
            }
            return downloadsDir.path;
          }
        }
      } else if (Platform.isAndroid) {
        // Android 10+ scoped storage: writes to /storage/emulated/0/Download
        // are denied without MANAGE_EXTERNAL_STORAGE. The previous 4-level
        // parent-traversal from getExternalStorageDirectory() reached that
        // shared path and silently failed under scoped storage. Use the
        // app-private documents directory + a Downloads subfolder instead;
        // files saved here are visible to the app and survive backups.
        final appDir = await getApplicationDocumentsDirectory();
        final downloadsDir = Directory(p.join(appDir.path, 'Downloads'));
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }
        return downloadsDir.path;
      } else if (Platform.isIOS) {
        // iOS: use app documents directory (can't access system Downloads)
        // Files saved here will be accessible via Files app if UIFileSharingEnabled is set in Info.plist
        final appDir = await getApplicationDocumentsDirectory();
        final downloadsDir = Directory(p.join(appDir.path, 'Downloads'));
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }
        return downloadsDir.path;
      }
    } catch (e) {}
    return null;
  }

  /// Get the avatars directory path. Uses per-account path if set, then the
  /// injected resolver (X6 — lets toxee route through `AppPaths`), then the
  /// `<appSupport>/avatars` default for tim2tox standalone tests.
  Future<String> _getAvatarsDir() async {
    if (_avatarsPath != null && _avatarsPath!.isNotEmpty) {
      final dir = Directory(_avatarsPath!);
      if (!await dir.exists()) await dir.create(recursive: true);
      return _avatarsPath!;
    }
    if (_pathResolver != null) {
      final resolved = _assertResolverPath(
        await _pathResolver!.resolveAvatarsDirectory(),
        'resolveAvatarsDirectory',
      );
      final dir = Directory(resolved);
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    }
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'avatars'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  // Move avatar file to avatars directory with a timestamped filename so that
  // each avatar version gets a unique path.  This forces Flutter's Image.file
  // (which keys on file path) to resolve the new image instead of reusing the
  // in-memory cache of the previous version.
  Future<String?> _moveAvatarToAvatarsDir(
      String sourcePath, String friendId) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return null;
      }
      final avatarsDirPath = await _getAvatarsDir();
      final ext = p.extension(sourcePath);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final destPath =
          p.join(avatarsDirPath, 'friend_${friendId}_avatar_$ts$ext');

      // Remove previous avatar files for this friend so stale versions don't
      // accumulate on disk.
      try {
        final dir = Directory(avatarsDirPath);
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File &&
                p
                    .basename(entity.path)
                    .startsWith('friend_${friendId}_avatar')) {
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}

      await sourceFile.copy(destPath);
      // Delete source file if it's in a temporary location
      if (sourcePath.contains('/file_recv/') || sourcePath.contains('/tmp/')) {
        try {
          await sourceFile.delete();
        } catch (e) {}
      }
      return destPath;
    } catch (e) {
      return null;
    }
  }

  // Move regular file to Downloads directory (except images which stay in avatars)
  Future<String?> _moveFileToDownloads(
      String sourcePath, String fileName) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        _logger?.log(
            '[FfiChatService] _moveFileToDownloads: source does not exist: $sourcePath');
        return null;
      }
      final downloadsDir = await _getDownloadsDirectory();
      if (downloadsDir == null) {
        _logger?.log(
            '[FfiChatService] _moveFileToDownloads: downloadsDir is null, returning source path');
        return sourcePath; // Return original path if Downloads not available
      }
      // Use original file name or extract from path
      final actualFileName = fileName ?? p.basename(sourcePath);
      final destPath = p.join(downloadsDir, actualFileName);
      // If file already exists, add a number suffix
      String finalPath = destPath;
      int counter = 1;
      while (await File(finalPath).exists()) {
        final nameWithoutExt = p.basenameWithoutExtension(actualFileName);
        final ext = p.extension(actualFileName);
        final dir = p.dirname(finalPath);
        finalPath = p.join(dir, '${nameWithoutExt}_$counter$ext');
        counter++;
      }
      _logger?.log(
          '[FfiChatService] _moveFileToDownloads: copying to: $finalPath');
      await sourceFile.copy(finalPath);
      // Delete source file if it's in a temporary location
      if (sourcePath.contains('/file_recv/') || sourcePath.contains('/tmp/')) {
        try {
          await sourceFile.delete();
        } catch (e) {
          _logger?.log(
              '[FfiChatService] _moveFileToDownloads: failed to delete source file: $e');
        }
      }
      final exists = await File(finalPath).exists();
      _logger?.log(
          '[FfiChatService] _moveFileToDownloads: copy done, destination exists: $exists');
      return finalPath;
    } catch (e, stackTrace) {
      // P1-4: previously returned [sourcePath] on failure, which let the
      // caller persist the temp `receiving_*` path into history as if the
      // file had landed in Downloads. The UI then surfaced a non-existent
      // file. Return null so the caller can mark the transfer failed
      // instead.
      _logger?.logError(
          '[FfiChatService] _moveFileToDownloads: copy failed', e, stackTrace);
      return null;
    }
  }

  // Public method to update avatar (called from profile page)
  Future<void> updateAvatar(String? avatarPath) async {
    if (avatarPath == null || avatarPath.isEmpty) {
      _currentAvatarHash = null;
      await _prefs?.setSelfAvatarHash(null);
      return;
    }

    final newHash = await _calculateAvatarHash(avatarPath);
    if (newHash == null) {
      _logger?.log(
          '[FfiChatService] updateAvatar: hash calculation returned null for $avatarPath');
      return;
    }

    if (_currentAvatarHash == newHash) {
      _logger?.log(
          '[FfiChatService] updateAvatar: hash unchanged ($newHash), skip');
      return;
    }

    _logger?.log(
        '[FfiChatService] updateAvatar: hash changed ${_currentAvatarHash ?? "null"} -> $newHash, path=$avatarPath');
    _currentAvatarHash = newHash;
    await _prefs?.setSelfAvatarHash(newHash);
    // Keep the adapter's scoped key in sync with the path the UI just set.
    // Without this, the adapter may return a stale value from its scoped key
    // when the UI wrote to the unscoped Prefs key.
    await _prefs?.setAvatarPath(avatarPath);
    if (_selfId.isNotEmpty) {
      _avatarUpdatedCtrl.add(_selfId);
    }

    if (!_avatarBroadcastAsChatFileEnabled) {
      return;
    }

    await sendAvatarToAllFriends(avatarPathOverride: avatarPath);
  }

  // Drain queued sends when a friend transitions offline -> online.
  //
  // One drain attempt per transition (no retry loops); successes flip the
  // matching pending bubble to delivered, failures flip it to non-pending so
  // the UI can show a failed state.
  //
  // Crash safety: we do NOT bulk-clear the queue before draining. Instead,
  // each item is removed from the in-memory cache and persisted to disk
  // individually — on success after dispatch, on failure after marking the
  // bubble failed. A `kill -9` / OOM mid-drain therefore leaves any
  // not-yet-attempted items on disk, satisfying the `clearOnLoad: false`
  // durability contract.
  Future<void> _sendPendingMessages(String peerId) async {
    final normalizedPeerId = _normalizeFriendId(peerId);

    // Snapshot the items to drain. The persistence cache still holds them;
    // they will be removed one-by-one as each is processed.
    final keyForNormalized = _getOfflineQueue(normalizedPeerId);
    final hasNormalizedQueue = keyForNormalized.isNotEmpty;
    final keyForRaw = (peerId != normalizedPeerId && !hasNormalizedQueue)
        ? _getOfflineQueue(peerId)
        : const <OfflineMessageItem>[];
    if (keyForNormalized.isEmpty && keyForRaw.isEmpty) {
      return;
    }
    // The peerId variant under which each item is currently stored matters
    // for the per-item removal: we must remove from the exact key the queue
    // was loaded under, otherwise the cache won't find it.
    final storageKey = hasNormalizedQueue ? normalizedPeerId : peerId;
    final messagesToSend = List<OfflineMessageItem>.from(
        hasNormalizedQueue ? keyForNormalized : keyForRaw);

    final history = _historyById[normalizedPeerId] ?? _historyById[peerId];

    for (final item in messagesToSend) {
      final isFile = item.kind == 'file' ||
          (item.filePath != null && item.filePath!.isNotEmpty);
      // #25 Option B: `dispatched` flips true the instant the FFI send has
      // succeeded and the queue entry has been durably removed (inside the
      // drain, via onDispatched), BEFORE the history reconcile. codex Property
      // 5: the reconcile can still throw AFTER dispatch — without this flag the
      // catch below would `_markPendingItemFailed` an already-DELIVERED message
      // (false "failed" UX) and double-remove. Guard on it so the failure path
      // only runs for a genuine pre-dispatch send failure.
      var dispatched = false;
      try {
        // The queue entry is removed INSIDE the drain, right after the FFI send
        // succeeds and before the history reconcile (via onDispatched) —
        // shrinking the dup-send-on-crash window.
        Future<void> remover() async {
          await _offlineQueuePersistence.removeItem(storageKey, item);
          dispatched = true;
        }

        if (isFile) {
          await _drainFileItem(normalizedPeerId, history, item,
              onDispatched: remover);
        } else if (item.text.isNotEmpty) {
          await _drainTextItem(normalizedPeerId, history, item,
              onDispatched: remover);
        } else {
          // Degenerate empty item (no text, no file): nothing to send — just
          // clear it so it doesn't linger in the queue forever.
          await remover();
        }
        await Future.delayed(const Duration(milliseconds: 100));
      } on _OfflineDuringDrain {
        // Friend disconnected again before/during this item's send. Leave
        // the queue item AND the pending bubble untouched so the next
        // online transition retries. Abort the rest of the loop since the
        // remaining items would all hit the same offline state.
        _logger?.log(
            '[FfiChatService] _sendPendingMessages: friend $normalizedPeerId went offline mid-drain; ${messagesToSend.length - messagesToSend.indexOf(item)} item(s) kept in queue');
        break;
      } catch (e, stackTrace) {
        if (dispatched) {
          // codex Property 5: the message WAS sent + the queue entry removed;
          // only the post-dispatch history reconcile threw. Do NOT mark it
          // failed (it was delivered) and do NOT re-remove. Log and move on —
          // the pending row self-heals to delivered on the next reload.
          _logger?.logError(
              '[FfiChatService] _sendPendingMessages: post-dispatch reconcile '
              'failed for an already-sent ${isFile ? "file" : "text"} item '
              '(message delivered; row will self-heal on reload)',
              e,
              stackTrace);
          continue;
        }
        _logger?.logError(
            '[FfiChatService] _sendPendingMessages: drain failed for ${isFile ? "file" : "text"} item',
            e,
            stackTrace);
        _markPendingItemFailed(normalizedPeerId, history, item, isFile: isFile);
        // One drain attempt per online transition: real failures (not
        // offline-during-drain) remove the item, matching the prior
        // bulk-clear semantics.
        await _offlineQueuePersistence.removeItem(storageKey, item);
      }
    }
  }

  // Replay a queued text item: locate the matching pending history record
  // (preserving its original timestamp + msgID) and flip it to delivered
  // after the FFI accepts the send.
  //
  // [onDispatched] (#25 Option B) is awaited immediately AFTER the FFI send
  // succeeds and BEFORE the history reconcile — the caller uses it to durably
  // remove this item from the offline queue. This shrinks the
  // duplicate-send-on-crash window to the irreducible `FFI send → one durable
  // persist` gap: a crash after send but before [onDispatched] re-sends on the
  // next drain (dup); a crash after [onDispatched] but before reconcile leaves
  // the queue clear (no resend) and the history row pending (self-heals to
  // delivered on reload). No message-loss mode.
  Future<void> _drainTextItem(String normalizedPeerId,
      List<ChatMessage>? history, OfflineMessageItem item,
      {Future<void> Function()? onDispatched}) async {
    // The drain trigger was an offline→online transition, but the friend
    // can flip back to offline before we reach this item. Pre-check the
    // cached online status (refreshed by the same getFriendList poll that
    // drives drain) and bail with the offline sentinel so the queue
    // item and pending bubble stay intact for the next transition.
    if (_friendOnlineStatus[normalizedPeerId] == 'offline') {
      throw const _OfflineDuringDrain();
    }

    ChatMessage? pendingMsg;
    int? pendingMsgIndex;
    if (history != null) {
      // codex (Bug F follow-up): match THIS item's pending row via
      // _offlineRowMatchesItem — msgID-first (durable; the queue item now
      // carries the pending row's msgID), with EXACT-ms timestamp as the
      // backward-compat fallback for legacy no-msgID queue files. NOT a ±10s
      // window: a window matcher that took the most-recent row could, with two
      // identical offline texts queued within 10s, reconcile the WRONG (newer)
      // pending row; and since reload clears `isPending` on history rows
      // (message_history_persistence.dart, "mark all historical messages as
      // not pending"), that mis-ownership becomes sticky across a crash.
      final itemMs = item.timestamp.millisecondsSinceEpoch;
      for (int i = history.length - 1; i >= 0; i--) {
        final msg = history[i];
        if (msg.isSelf &&
            msg.isPending &&
            msg.filePath == null &&
            msg.text == item.text &&
            _offlineRowMatchesItem(msg, item, itemMs)) {
          pendingMsg = msg;
          pendingMsgIndex = i;
          break;
        }
      }
    }

    final pto = normalizedPeerId.toNativeUtf8();
    final pmsg = item.text.toNativeUtf8();
    _ffi.sendText(pto, pmsg);
    pkgffi.malloc.free(pto);
    pkgffi.malloc.free(pmsg);

    // #25 Option B: durably clear the queue entry NOW (after send, before the
    // history reconcile) so a crash can't make the next drain re-send.
    if (onDispatched != null) await onDispatched();

    if (pendingMsg != null && pendingMsgIndex != null && history != null) {
      final updatedMsg = pendingMsg.copyWith(isPending: false);
      history[pendingMsgIndex] = updatedMsg;
      _lastByPeer[normalizedPeerId] = updatedMsg;
      try {
        await _saveHistory(normalizedPeerId);
      } catch (_) {}
      try {
        _messages.add(updatedMsg);
      } catch (_) {}
    } else {
      // Fallback: no matching *pending* row in the in-memory history (lost
      // across restart, trimmed, or composition→item timestamp drift > 10s).
      //
      // Bug F fix: appendHistory's content-dedup no longer covers self-sends,
      // so this fallback must guarantee its OWN idempotency or a re-drain could
      // append a duplicate of an already-delivered self row. Re-scan for THIS
      // item's own row (pending OR already-delivered) via _offlineRowMatchesItem
      // (msgID-first, exact-ms fallback) and reconcile it in place instead of
      // appending. NOT a window: a 10s window was too broad — it could match a
      // DIFFERENT identical-text message that merely happens to be nearby, and
      // wrongly suppress this send, re-creating Bug F in the fallback path.
      ChatMessage? existing;
      int? existingIndex;
      if (history != null) {
        final itemMs = item.timestamp.millisecondsSinceEpoch;
        for (int i = history.length - 1; i >= 0; i--) {
          final msg = history[i];
          if (msg.isSelf &&
              msg.filePath == null &&
              msg.text == item.text &&
              _offlineRowMatchesItem(msg, item, itemMs)) {
            existing = msg;
            existingIndex = i;
            break;
          }
        }
      }
      if (existing != null && existingIndex != null && history != null) {
        // Already present (e.g. a prior drain delivered it): ensure it reads as
        // delivered, but do NOT append a second row and do NOT re-emit on the
        // message stream — the row was streamed when first created.
        final updatedMsg =
            existing.isPending ? existing.copyWith(isPending: false) : existing;
        history[existingIndex] = updatedMsg;
        _lastByPeer[normalizedPeerId] = updatedMsg;
        try {
          await _saveHistory(normalizedPeerId);
        } catch (_) {}
      } else {
        // Genuinely absent: create a fresh delivered message but keep the
        // original composition timestamp.
        //
        // codex: REUSE the queue item's durable msgID (the id of the original
        // pending row) instead of minting a new one. Otherwise, if this branch
        // saves history and the process dies before the queue item is removed,
        // the surviving item carries the old id while history has a new id — the
        // next drain can't correlate them and may resend/duplicate. Only
        // synthesize a fresh id for legacy items that predate the queue-item
        // msgID field (item.msgID == null).
        final itemMsgID = item.msgID;
        final String msgID;
        if (itemMsgID != null && itemMsgID.isNotEmpty) {
          msgID = itemMsgID;
        } else {
          final sequence = _msgIDSequence++;
          msgID =
              '${item.timestamp.millisecondsSinceEpoch}_${sequence}_$_selfId';
        }
        final msg = ChatMessage(
          text: item.text,
          fromUserId: _selfId,
          isSelf: true,
          timestamp: item.timestamp,
          groupId: null,
          isPending: false,
          msgID: msgID,
        );
        _lastByPeer[normalizedPeerId] = msg;
        _appendHistory(normalizedPeerId, msg);
        _messages.add(msg);
        await _saveHistory(normalizedPeerId);
      }
    }
  }

  // Replay a queued file item via sendFile(addToChatHistory: false): the
  // pending bubble already exists from when it was queued, so we just
  // flip it to delivered after the FFI accepts the transfer.
  //
  // [onDispatched] (#25 Option B): same contract as _drainTextItem — awaited
  // after the FFI transfer is accepted and before the history reconcile, to
  // durably clear the queue entry and minimize the dup-send-on-crash window.
  Future<void> _drainFileItem(String normalizedPeerId,
      List<ChatMessage>? history, OfflineMessageItem item,
      {Future<void> Function()? onDispatched}) async {
    final filePath = item.filePath;
    if (filePath == null || filePath.isEmpty) return;
    if (!await File(filePath).exists()) {
      throw Exception('Queued file no longer exists: $filePath');
    }
    ChatMessage? pendingMsg;
    int? pendingMsgIndex;
    if (history != null) {
      // Identity via _offlineRowMatchesItem (msgID-first, exact-ms fallback) —
      // not a ±10s window. filePath is also matched, but two queued sends of
      // the SAME file would still need msgID/timestamp to disambiguate; a
      // window matcher could flip the wrong one.
      final itemMs = item.timestamp.millisecondsSinceEpoch;
      for (int i = history.length - 1; i >= 0; i--) {
        final msg = history[i];
        if (msg.isSelf &&
            msg.isPending &&
            msg.filePath == filePath &&
            _offlineRowMatchesItem(msg, item, itemMs)) {
          pendingMsg = msg;
          pendingMsgIndex = i;
          break;
        }
      }
    }
    await sendFile(normalizedPeerId, filePath,
        addToChatHistory: false, throwIfOffline: true);
    // #25 Option B: durably clear the queue entry after the transfer is
    // accepted, before the history reconcile (see _drainTextItem).
    if (onDispatched != null) await onDispatched();
    if (pendingMsg != null && pendingMsgIndex != null && history != null) {
      final updatedMsg = pendingMsg.copyWith(isPending: false);
      history[pendingMsgIndex] = updatedMsg;
      _lastByPeer[normalizedPeerId] = updatedMsg;
      try {
        await _saveHistory(normalizedPeerId);
      } catch (_) {}
      try {
        _messages.add(updatedMsg);
      } catch (_) {}
    }
  }

  // On drain failure, flip the matching pending history record to
  // non-pending so the UI can render it as failed. The queue entry is NOT
  // re-enqueued — one drain attempt per online transition by design.
  void _markPendingItemFailed(String normalizedPeerId,
      List<ChatMessage>? history, OfflineMessageItem item,
      {required bool isFile}) {
    if (history == null) return;
    // Identity via _offlineRowMatchesItem (msgID-first, exact-ms fallback) —
    // not a ±10s window, which could flip the WRONG pending row to failed when
    // two identical texts/files were queued close together.
    final itemMs = item.timestamp.millisecondsSinceEpoch;
    for (int i = history.length - 1; i >= 0; i--) {
      final msg = history[i];
      if (!msg.isSelf || !msg.isPending) continue;
      final matches = isFile
          ? (msg.filePath == item.filePath &&
              _offlineRowMatchesItem(msg, item, itemMs))
          : (msg.filePath == null &&
              msg.text == item.text &&
              _offlineRowMatchesItem(msg, item, itemMs));
      if (matches) {
        final updated = msg.copyWith(isPending: false);
        history[i] = updated;
        _lastByPeer[normalizedPeerId] = updated;
        try {
          _messages.add(updated);
        } catch (_) {}
        unawaited(_saveHistory(normalizedPeerId).catchError((_) {}));
        break;
      }
    }
  }

  // Save offline message queue to disk (delegate to persistence service)
  Future<void> _saveOfflineQueue() async {
    // Build queue map from persistence service cache
    final queue = _offlineQueuePersistence.cache;
    await _offlineQueuePersistence.saveQueue(queue);
  }

  // Load offline message queue from disk (delegate to persistence service).
  // Queue persists across restart; drain runs on the next online transition.
  Future<void> _loadOfflineQueue() async {
    await _offlineQueuePersistence.loadQueue(clearOnLoad: false);
  }

  /// Clear all account data (history, offline queue, files)
  /// This is used when user deletes their account
  Future<void> clearAllAccountData() async {
    // Clear in-memory data
    _lastByPeer.clear();
    _unreadByPeer.clear();

    // Clear all history files using persistence service
    await _messageHistoryPersistence.clearAllHistories();

    // Clear offline message queue using persistence service
    await _offlineQueuePersistence.clearQueueFile();
  }

  /// P1-3: Mark a single in-flight file transfer as failed.
  ///
  /// Called from the [_handleFileDone] error paths so a thrown exception
  /// inside the file-completion handler doesn't leave the message stuck in
  /// "receiving" state forever. We clear it from the tracking maps and flip
  /// the corresponding history record to non-pending so the UI can render an
  /// error state instead of a spinning progress bar.
  void _markFileTransferFailed(String uid, int? fileNumber, String? msgID) {
    try {
      final normalizedUid = uid.length > 64 ? _normalizeFriendId(uid) : uid;
      // Locate msgID by fileNumber if not supplied directly.
      String? resolvedMsgID = msgID;
      if (resolvedMsgID == null && fileNumber != null) {
        resolvedMsgID = _fileNumberToMsgID[(normalizedUid, fileNumber)] ??
            _fileNumberToMsgID[(uid, fileNumber)];
      }

      // Drop tracking entries so the next file_request with the same
      // fileNumber isn't matched to this dead transfer.
      if (fileNumber != null) {
        _fileReceiveProgress.remove((normalizedUid, fileNumber));
        _fileReceiveProgress.remove((uid, fileNumber));
        _pendingFileTransfers.remove((normalizedUid, fileNumber));
        _pendingFileTransfers.remove((uid, fileNumber));
        _fileNumberToMsgID.remove((normalizedUid, fileNumber));
        _fileNumberToMsgID.remove((uid, fileNumber));
        _lastProgressTs.remove((normalizedUid, fileNumber));
        _lastProgressTs.remove((uid, fileNumber));
        _pausedTransfers.remove((normalizedUid, fileNumber));
        _pausedTransfers.remove((uid, fileNumber));
      }
      if (resolvedMsgID != null) {
        _msgIDToFileTransfer.remove(resolvedMsgID);
      }

      // Flip the corresponding history record to non-pending with an empty
      // filePath so the UI knows it's no longer in-flight. We don't have a
      // dedicated MessageStatus.failed enum on ChatMessage today; the
      // combination "isPending=false + filePath==null" is the contract the
      // UI uses for "transfer didn't complete".
      if (resolvedMsgID != null) {
        final history = _historyById[normalizedUid] ?? _historyById[uid];
        if (history != null) {
          for (int i = 0; i < history.length; i++) {
            final m = history[i];
            if (m.msgID == resolvedMsgID && m.isPending) {
              final updated = m.copyWith(isPending: false, filePath: '');
              history[i] = updated;
              _messages.add(updated);
              // H-F: do not silently swallow save errors — at least leave
              // a trail so the failure isn't invisible. The unawaited()
              // is intentional; we don't want to block the caller on disk
              // I/O, but we still want a log if the write blew up.
              unawaited(_saveHistory(normalizedUid).catchError((e, st) {
                _logger?.logError(
                    '[FfiChatService] _markFileTransferFailed: history save failed for $normalizedUid',
                    e,
                    st);
              }));
              break;
            }
          }
        }
      }
    } catch (e, st) {
      _logger?.logError(
          '[FfiChatService] _markFileTransferFailed: error', e, st);
    }
  }

  /// P1-6: Handle a file_control event from native (peer-initiated cancel,
  /// pause, resume) or a Dart-side synthesized timeout.
  ///
  /// FFI emission of these events is still pending — wire up here is dead
  /// code today, but is in place so that as soon as the native layer adds
  /// the matching event strings, the Dart side already does the right thing.
  // TODO(P1-6): wire after FFI emits file_control events ('file_canceled',
  // 'file_paused', 'file_resumed').
  void _handleFileControl(
      {required String uid, required int fileNumber, required String control}) {
    final normalizedUid = uid.length > 64 ? _normalizeFriendId(uid) : uid;
    final key = (normalizedUid, fileNumber);
    final altKey = (uid, fileNumber);
    switch (control) {
      case 'cancel':
      case 'timeout':
        final progress =
            _fileReceiveProgress[key] ?? _fileReceiveProgress[altKey];
        final msgID = progress?.msgID ??
            _fileNumberToMsgID[key] ??
            _fileNumberToMsgID[altKey];
        // Best-effort: delete the half-received file on disk.
        final tempPath = progress?.tempPath;
        final actualPath = progress?.actualPath;
        for (final candidate in [tempPath, actualPath]) {
          if (candidate != null && candidate.isNotEmpty) {
            try {
              final f = File(candidate);
              // Don't await on the poll loop; fire and forget.
              unawaited(f.exists().then((exists) async {
                if (exists) {
                  try {
                    await f.delete();
                  } catch (_) {}
                }
              }).catchError((_) {}));
            } catch (_) {}
          }
        }
        _markFileTransferFailed(uid, fileNumber, msgID);
        _logger?.log(
            '[FfiChatService] _handleFileControl: cleaned up transfer uid=$uid fileNumber=$fileNumber control=$control');
        break;
      case 'pause':
        _pausedTransfers.add(key);
        _logger?.log(
            '[FfiChatService] _handleFileControl: paused uid=$uid fileNumber=$fileNumber');
        break;
      case 'resume':
        _pausedTransfers.remove(key);
        _pausedTransfers.remove(altKey);
        // Reset the idle clock so the timeout sweeper doesn't immediately
        // kill a freshly-resumed transfer.
        _lastProgressTs[key] = DateTime.now().millisecondsSinceEpoch;
        _logger?.log(
            '[FfiChatService] _handleFileControl: resumed uid=$uid fileNumber=$fileNumber');
        break;
      default:
        _logger?.log(
            '[FfiChatService] _handleFileControl: unknown control=$control uid=$uid fileNumber=$fileNumber');
    }
  }

  /// P1-7: Walk in-flight receives and treat ones with no progress update in
  /// [_fileTransferIdleTimeout] as dead. Called from the poll loop.
  /// P1-7 refined (H-D): 180s + at-least-one-chunk heuristic. We only
  /// declare a transfer dead if we've already seen *some* progress on it
  /// — a transfer that's been pending with zero bytes received is more
  /// likely a peer that hasn't started yet (still establishing the onion
  /// path, queued behind another transfer, etc.) than a wedged one.
  void _checkFileTransferTimeouts() {
    if (_fileReceiveProgress.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - _fileTransferIdleTimeout.inMilliseconds;
    final stale = <(String peerId, int fileNumber)>[];
    for (final entry in _fileReceiveProgress.entries) {
      final key = entry.key;
      if (_pausedTransfers.contains(key)) continue;
      final ts = _lastProgressTs[key];
      if (ts == null) {
        // Seed the clock on first sight so the very first timeout window
        // applies from when we noticed the transfer rather than epoch=0.
        _lastProgressTs[key] = now;
        continue;
      }
      if (ts < cutoff) {
        // H-D: only cull transfers that have actually started receiving
        // bytes. Zero-progress transfers are noisy at startup and on
        // flaky networks — log them but leave them alone.
        if (entry.value.received <= 0) {
          _logger?.log(
              '[FfiChatService] _checkFileTransferTimeouts: idle but zero-progress uid=${key.$1} fileNumber=${key.$2} — leaving alone (H-D heuristic)');
          continue;
        }
        stale.add(key);
      }
    }
    for (final key in stale) {
      _logger?.log(
          '[FfiChatService] _checkFileTransferTimeouts: stale transfer uid=${key.$1} fileNumber=${key.$2} — cleaning up');
      _handleFileControl(uid: key.$1, fileNumber: key.$2, control: 'timeout');
    }
  }

  /// Cancel all pending file transfers (called on exit or startup)
  /// This prevents chat window from showing "receiving" status for incomplete transfers
  Future<void> _cancelPendingFileTransfers() async {
    // P1-9: tell the remote peers we're bailing on every in-flight transfer
    // before we wipe local state. Without this, a peer keeps sending chunks
    // into a closed socket until tox itself times out (~minutes). Best-effort:
    // a failed native cancel must not block dispose.
    if (_pendingFileTransfers.isNotEmpty) {
      final entries = List<({(String, int) key, String msgID})>.from(
          _pendingFileTransfers.entries
              .map((e) => (key: e.key, msgID: e.value)));
      for (final e in entries) {
        final (peerUid, fileNumber) = e.key;
        try {
          final pto = peerUid.toNativeUtf8();
          // 2 = CANCEL (matches the constant used elsewhere in this file).
          _ffi.fileControlNative(
              _ffi.getCurrentInstanceId(), pto, fileNumber, 2);
          pkgffi.malloc.free(pto);
        } catch (_) {
          // Swallow — we're tearing down anyway, and the native layer may
          // already be partially uninitialised.
        }
      }
    }

    // Iterate through all conversation histories
    for (final entry in _historyById.entries) {
      final conversationId = entry.key;
      final messages = entry.value;
      bool hasUpdates = false;

      // Find and remove/update pending file messages
      for (int i = messages.length - 1; i >= 0; i--) {
        final msg = messages[i];
        // Check if this is a pending file message that is being received (not sent)
        // Only cancel incoming file transfers (isSelf=false) that are still pending
        // and have a temporary receiving path or are file/media messages
        if (!msg.isSelf &&
            msg.isPending &&
            msg.filePath != null &&
            (msg.filePath!.contains('/receiving_') || msg.mediaKind != null)) {
          // Remove the message from history to avoid showing "receiving" status
          messages.removeAt(i);
          hasUpdates = true;
        }
      }

      // Save updated history if there were changes
      if (hasUpdates) {
        await _saveHistory(conversationId);
        // Update last message if needed
        if (messages.isNotEmpty) {
          messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
          _lastByPeer[conversationId] = messages.first;
        } else {
          _lastByPeer.remove(conversationId);
        }
      }
    }

    // Clear all file transfer tracking maps
    _fileReceiveProgress.clear();
    _pendingFileTransfers.clear();
    _msgIDToFileTransfer.clear();
    _fileNumberToMsgID.clear();
    _lastProgressTs.clear();
    _pausedTransfers.clear();

    // P1-10: clear partially-received files off disk for this account so we
    // don't leave orphaned `receiving_*` blobs after logout. Scoped strictly
    // to [_fileRecvDir] — the per-account dir resolved during init — so we
    // don't touch another account's transfers.
    final recvDir = _fileRecvDir;
    if (recvDir != null && recvDir.isNotEmpty) {
      try {
        final dir = Directory(recvDir);
        if (await dir.exists()) {
          await for (final ent in dir.list(followLinks: false)) {
            if (ent is File && p.basename(ent.path).startsWith('receiving_')) {
              try {
                await ent.delete();
              } catch (_) {}
            }
          }
          // H-E: detect orphan *complete* files — files that the C layer
          // finished writing under a non-`receiving_` name but for which
          // we never recorded a history entry (Dart crashed mid-handoff,
          // _handleFileDone never ran, etc.). Synthesizing a history row
          // here requires sender/msgID/timestamp metadata we don't have
          // post-crash, so for now we only log + leave the file in place.
          // Auto-deleting user data here would be worse than the leak.
          // TODO(H-E): synthesize history entry from any available
          // _fileReceiveProgress remnants persisted on disk.
          try {
            await for (final ent in dir.list(followLinks: false)) {
              if (ent is! File) continue;
              final basename = p.basename(ent.path);
              if (basename.startsWith('receiving_')) continue;
              int size = -1;
              try {
                size = await ent.length();
              } catch (_) {}
              _logger?.log(
                  '[FfiChatService] orphan file in file_recv/: ${ent.path} (size=$size) — TODO(H-E) synthesize history entry');
            }
          } catch (e, st) {
            _logger?.logError(
                '[FfiChatService] _cancelPendingFileTransfers: H-E orphan scan failed for recvDir=$recvDir',
                e,
                st);
          }
        }
      } catch (e, st) {
        _logger?.logError(
            '[FfiChatService] _cancelPendingFileTransfers: failed to scan/clean recvDir=$recvDir',
            e,
            st);
      }
    }
  }

  Future<void> dispose() async {
    // Order matters here — the previous arrangement had a race where a poll
    // tick or in-flight callback could `appendHistory` between
    // `flushPendingSaves()` and `clearAllCached()`, resurrecting the
    // just-cleared cache and then losing the message when the debounce timer
    // fired against an empty service. M5 additionally moves the offline queue
    // save earlier so it runs while the queue cache and persistence are still
    // live — not after `_ffi.uninit()` and stream-close (where the queue
    // could be empty or unreachable). To close those windows:
    //
    //   1. Stop every source of new `appendHistory` calls (route, poller,
    //      profile timer, instance-map registration, in-flight file callbacks).
    //   2. Flush pending writes to disk: history flushPendingSaves AND
    //      offline-queue save, run adjacent so they share the "no new work"
    //      window.
    //   3. Switch the persistence layer into its "disposed" mode so any
    //      defensive late call falls through to a synchronous save instead of
    //      scheduling a timer that will never fire.
    //   4. Finally clear caches and tear down FFI / streams.

    // 1. Stop new work.
    if (_globalService == this) {
      _globalService = null;
    }
    _lastSentPathByPeer.clear();

    if (_instanceId != null && _instanceId! != 0) {
      synchronized(_instanceServicesLock, () {
        _instanceServices.remove(_instanceId!);
        _knownInstanceIds.remove(_instanceId!);
      });
    }

    _poller?.cancel();
    _poller = null;
    _pollingStarted = false;
    _profileSaveTimer?.cancel();
    _profileSaveTimer = null;

    // Cancel any in-flight file transfers — must happen after the poller has
    // been killed so cancellation callbacks don't race a fresh poll tick.
    await _cancelPendingFileTransfers();

    // 2. Flush pending debounced history writes. By this point no new
    // appendHistory should arrive, so the snapshot the flush takes is final.
    // M5: save the offline queue here too — it must run BEFORE `_ffi.uninit()`
    // and BEFORE stream controllers close, while the queue persistence is
    // still in a usable state.
    try {
      await _messageHistoryPersistence.flushPendingSaves();
    } catch (_) {
      // Best-effort: don't block dispose on a single conversation's save error.
    }
    try {
      await _saveOfflineQueue();
    } catch (_) {
      // Best-effort: don't block dispose if the queue save fails.
    }

    // 3. Switch persistence into disposed mode. After this, any late call
    // into _scheduleDebouncedSave (defensive — should not happen given step 1)
    // falls through to a synchronous saveHistory using the still-present
    // in-memory list, instead of scheduling a timer that gets cancelled in
    // step 4. `dispose()` itself awaits an internal `flushPendingSaves` —
    // idempotent against the explicit flush in step 2.
    await _messageHistoryPersistence.dispose();

    // 4. Clear caches and tear down.
    _messageHistoryPersistence.clearAllCached();
    _unreadByPeer.clear();
    _knownGroups.clear();
    _quitGroups.clear();
    _blockedUsers.clear();
    _lastByPeer.clear();
    _typingUntil.clear();
    _processingFileDone.clear();
    _observedApplicationWordings.clear();
    _activePeerId = null;

    // P1-18: previously-leaked maps. Empty them so a re-init of the service
    // (e.g. account switch) doesn't carry state over from the dead account.
    _pathToMsgID.clear();
    _friendOnlineStatus.clear();
    _messageReceivers.clear();
    _progressKeyCache.clear();
    _lastProgressEmitTime.clear();
    _lastProgressTs.clear();
    _pausedTransfers.clear();
    _msgIDToSentPath.clear();

    // P1-17: release the persistent NativeCallable allocated for login and
    // close the IRC stream controllers that were previously leaked across
    // disposes. `close()` on these controllers is safe even if no listener
    // was ever attached.
    try {
      _loginNativeCallable?.close();
    } catch (_) {}
    _loginNativeCallable = null;
    await _ircConnectionStatusCtrl.close();
    await _ircUserListCtrl.close();
    await _ircUserJoinPartCtrl.close();

    _ffi.uninit();
    await _messages.close();
    await _connectionStatus.close();
    await _progressCtrl.close();
    await _fileRequestCtrl.close();
    await _reactionCtrl.close();
    await _avatarUpdatedCtrl.close();
    await _nicknameUpdatedCtrl.close();
  }
}
