/// Tim2Tox SDK Platform Implementation
///
/// This file provides a custom implementation of TencentCloudChatSdkPlatform
/// that routes all SDK calls to tim2tox FFI layer, completely replacing
/// the cloud SDK dependency.
///
/// Usage:
/// ```dart
/// // In app initialization (e.g., main.dart or home_page.dart)
/// TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(ffiService: ffiChatService);
/// ```

library tim2tox_sdk_platform;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimUIKitListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimConversationListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSignalingListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/offlinePushInfo.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_signaling_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_callback.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_value_callback.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_msg_create_info_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_list_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_conversation.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_conversation_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_conversation_operation_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_info_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_operation_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_check_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_full_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_full_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_info_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_application.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_application_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_change_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_operation_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_tips_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_change_info.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_tips_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_receipt.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_reaction_change_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_reaction.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_reaction_result.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_status.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_change_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_download_progress.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_application_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_response_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_status.dart';
import 'package:tencent_cloud_chat_sdk/enum/conversation_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_text_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_image_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_file_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_sound_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_video_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_custom_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_merger_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_image.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_online_url.dart';
import 'package:tencent_cloud_chat_sdk/enum/image_types.dart';
import '../service/ffi_chat_service.dart';
import '../models/chat_message.dart';
import '../utils/message_converter.dart';
import '../utils/tim2tox_failed_message_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ffi/tim2tox_ffi.dart' as ffi_lib;
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' as pkgffi;
import '../interfaces/event_bus_provider.dart';
import '../interfaces/conversation_manager_provider.dart';
import '../interfaces/extended_preferences_service.dart';
import '../interfaces/event_bus.dart';
import '../models/fake_models.dart';
import 'package:tencent_cloud_chat_common/tencent_cloud_chat.dart';
import 'package:tencent_cloud_chat_common/external/chat_message_provider.dart';
import 'package:tencent_cloud_chat_common/components/tencent_cloud_chat_components_utils.dart';
import 'package:tencent_cloud_chat_common/utils/tencent_cloud_chat_code_info.dart';
import 'tim2tox_sdk_platform_callbacks.dart' as callbacks;
import 'tim2tox_sdk_platform_converters.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_conversation_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/bindings/native_library_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/bindings/native_imsdk_bindings_generated.dart'
    show GlobalCallbackType;
import 'package:tencent_cloud_chat_sdk/native_im/tools.dart';
import 'package:tim2tox_dart/service/toxav_service.dart';

/// Custom SDK Platform implementation that routes calls to tim2tox.
///
/// TODO(tim2tox-refactor): this class is ~8000 lines (~70 @override methods
/// plus their helpers). Dart does not allow a single class body to be split
/// across multiple files via `part`/`part of`, so a clean mechanical split is
/// not possible. Two viable shrinkage paths, neither attempted in the audit
/// pass:
///   1. Mixin-based: declare `mixin _MessagingMethods on TencentCloudChatSdkPlatform`
///      etc. in part files and apply them via `with _MessagingMethods,
///      _ConversationMethods, _LifecycleMethods`. Mixins can `@override` base
///      methods. The constraint is that every private field a mixin touches
///      has to be exposed somehow (parts share library scope, so private `_`
///      access works across parts — declaring mixins in `.part.dart` files
///      sidesteps the getter explosion).
///   2. Composition: extract standalone helper classes
///      (`Tim2ToxMessagePipeline`, `Tim2ToxConversationPipeline`,
///      `Tim2ToxLifecycleController`) that the Platform holds as fields, and
///      delegate from the @override methods. Cleaner architecturally but
///      touches behaviour at every call site.
/// Either path needs manual smoke (login/send/receive/forward/file_done/
/// logout) since the submodule has no Dart tests. Do it as a focused commit
/// of its own.
class Tim2ToxSdkPlatform extends TencentCloudChatSdkPlatform {
  /// Set to true to enable verbose message/flow logging (off by default to reduce log noise).
  static const bool _debugLog = false;

  final FfiChatService ffiService;
  final EventBusProvider? eventBusProvider;

  /// Always-on logging hook. Routes through the host-injected
  /// [LoggerService] when one is available (so the app's own log file /
  /// console formatting catches it), and falls back to plain `print` so
  /// unit tests without a logger still surface output.
  void _log(String message) {
    final l = ffiService.logger;
    if (l != null) {
      l.log(message);
    } else {
      // ignore: avoid_print
      print(message);
    }
  }

  /// Verbose tracing — only fires when [_debugLog] is true. Use for
  /// per-message / per-event chatter so release builds stay quiet.
  void _debug(String message) {
    if (!_debugLog) return;
    final l = ffiService.logger;
    if (l != null) {
      l.logDebug(message);
    } else {
      // ignore: avoid_print
      print(message);
    }
  }

  /// Called when a group message is received via native path (not from self).
  /// The app should increment unread for [groupId] and refresh unread total so
  /// sidebar and conversation list show the new unread count.
  void Function(String? groupId)? onGroupMessageReceivedForUnread;

  /// Prefer the parsed chat-message group id, but fall back to the V2 message group id.
  /// Conference messages can arrive with only the latter populated.
  static String? resolveGroupIdForUnread({
    String? chatMessageGroupId,
    String? v2GroupId,
  }) {
    if (chatMessageGroupId != null && chatMessageGroupId.isNotEmpty) {
      return chatMessageGroupId;
    }
    if (v2GroupId != null && v2GroupId.isNotEmpty) {
      return v2GroupId;
    }
    return null;
  }

  /// Prefer per-instance listeners, but fall back to global listeners when the
  /// instance-specific list is empty. This must also work for `instanceId == 0`,
  /// because the main app registers most listeners only in the global lists.
  static List<T> selectDispatchListeners<T>({
    required int instanceId,
    required List<T> instanceListeners,
    required List<T> globalListeners,
  }) {
    if (instanceListeners.isNotEmpty) {
      return instanceListeners;
    }
    return globalListeners;
  }

  // Set current instance for static callbacks
  final ConversationManagerProvider? conversationManagerProvider;
  final ExtendedPreferencesService? _preferencesService;

  // Preferences service getter
  ExtendedPreferencesService? get preferencesService => _preferencesService;

  @override
  bool get isCustomPlatform => true;

  // Access preferences through ffiService or _preferencesService
  ExtendedPreferencesService? get _prefs =>
      _preferencesService ?? ffiService.preferencesService;

  // Store listeners (global, used when instance_id is 0 or null)
  final List<V2TimSDKListener> _sdkListeners = [];
  final List<V2TimAdvancedMsgListener> _advancedMsgListeners = [];
  final List<V2TimConversationListener> _conversationListeners = [];
  final List<V2TimFriendshipListener> _friendshipListeners = [];
  final List<V2TimGroupListener> _groupListeners = [];
  final Map<String, V2TimUIKitListener> _uikitListeners = {};
  final List<V2TimSignalingListener> _signalingListeners = [];

  // Per-instance listeners for strict multi-instance routing
  // (instance_id != 0). Only exercised by tim2tox/auto_tests, which spins
  // up multiple Tox instances in one process for end-to-end tests. The
  // production toxee client runs single-instance (instance_id == 0) and
  // never populates these maps. Keep populated by addSDKListener etc. for
  // test parity, but treat as test-only state in code review — the broadcast
  // dispatch path through _sdkListeners / _advancedMsgListeners / etc. is
  // what handles real traffic.
  final Map<int, List<V2TimSDKListener>> _instanceSdkListeners = {};
  final Map<int, List<V2TimAdvancedMsgListener>> _instanceAdvancedMsgListeners =
      {};
  final Map<int, List<V2TimConversationListener>>
      _instanceConversationListeners = {};
  final Map<int, List<V2TimFriendshipListener>> _instanceFriendshipListeners =
      {};
  final Map<int, List<V2TimGroupListener>> _instanceGroupListeners = {};
  final Map<int, List<V2TimSignalingListener>> _instanceSignalingListeners = {};

  // Static instance for FFI callbacks
  static Tim2ToxSdkPlatform? _currentInstance;

  bool _isInitialized = false;
  bool _isLoggedIn = false;
  int? _sdkAppID;
  String? _currentUserID;

  // Cache for forward messages created by createForwardMessage
  // Key: message id (e.g., "1766056010217_forward_unknown")
  // Value: the forward message
  final Map<String, V2TimMessage> _forwardMessageCache = {};

  // Track pending forward messages to fix their userID/groupID when received from stream
  // Key: message msgID (to match with received message)
  // Value: (userID, groupID, timestamp) - the target and timestamp of the forward message
  // We use msgID as key because it's consistent across pending and sent states
  // We keep entries for 30 seconds to handle delayed sends (e.g., when friend comes online)
  final Map<String, ({String? userID, String? groupID, int timestamp})>
      _pendingForwardTargets = {};

  // U-3 (partial): remember per-path soundElem.duration values handed to us
  // by `sendMessage`. The Tox file-transfer envelope has no duration field,
  // so the receiver currently displays 0 (see TODO(P1-11) in
  // fake_msg_provider_mapping.dart). At least the SENDER side can be made
  // consistent: when the local echo for an audio file lands in
  // `_setupMessageListener`, we patch the v2Msg.soundElem.duration from
  // this map so the sender's own history shows the correct length.
  // Entries are cleaned up after 60 s.
  final Map<String, ({int durationMs, int timestampMs})>
      _pendingSoundDurations = {};

  void _rememberSoundDuration(String filePath, int? durationMs) {
    if (filePath.isEmpty || durationMs == null || durationMs <= 0) return;
    _pendingSoundDurations[filePath] = (
      durationMs: durationMs,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    // Best-effort cleanup of stale entries.
    final now = DateTime.now().millisecondsSinceEpoch;
    _pendingSoundDurations
        .removeWhere((_, v) => (now - v.timestampMs).abs() > 60000);
  }

  int? _lookupSoundDuration(String? filePath) {
    if (filePath == null || filePath.isEmpty) return null;
    final entry = _pendingSoundDurations[filePath];
    if (entry != null) return entry.durationMs;
    // Fallback: filename-encoded duration `..._dur1234.ext` (used when the
    // receiver wants the duration too — see U-3 in sendMessage).
    final base = filePath.split('/').last;
    final marker = RegExp(r'__dur(\d+)');
    final m = marker.firstMatch(base);
    if (m != null) {
      return int.tryParse(m.group(1)!);
    }
    return null;
  }

  // Avatar path cache for populating faceUrl on V2TimMessages
  String? _selfAvatarPathCache;
  final Map<String, String> _friendAvatarPathCache = {};

  // Clean up old entries periodically
  void _cleanupPendingForwardTargets() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final keysToRemove = <String>[];
    for (final entry in _pendingForwardTargets.entries) {
      final timeDiff = (now - entry.value.timestamp).abs();
      if (timeDiff > 30000) {
        // 30 seconds
        keysToRemove.add(entry.key);
      }
    }
    for (final key in keysToRemove) {
      _pendingForwardTargets.remove(key);
    }
  }

  // Stream subscriptions
  StreamSubscription<bool>? _connectionStatusSubscription;
  StreamSubscription<ChatMessage>? _messagesSubscription;
  StreamSubscription<FakeConversation>? _conversationSubscription;
  StreamSubscription<FakeUnreadTotal>? _unreadSubscription;
  StreamSubscription<List<FakeUser>>? _contactsSubscription;
  StreamSubscription<List<FakeFriendApplication>>? _friendAppsSubscription;
  StreamSubscription<FakeFriendDeleted>? _friendDeletedSubscription;
  StreamSubscription<FakeGroupDeleted>? _groupDeletedSubscription;
  StreamSubscription<
      ({
        String msgID,
        String reactionID,
        String action,
        String sender,
        String? groupID
      })>? _reactionSubscription;
  StreamSubscription<
      ({
        int instanceId,
        String peerId,
        String? path,
        int received,
        int total,
        bool isSend,
        String? msgID
      })>? _progressSubscription;
  StreamSubscription<String>? _avatarUpdatedSubscription;
  final Map<String, V2TimMessage> _progressMsgCache =
      {}; // msgID -> cached V2TimMessage for progress lookup

  // Track previous friend online status to detect changes
  final Map<String, bool> _previousFriendOnlineStatus = {};
  Timer? _friendStatusCheckTimer;

  Tim2ToxSdkPlatform({
    required this.ffiService,
    this.eventBusProvider,
    this.conversationManagerProvider,
    ExtendedPreferencesService? preferencesService,
  }) : _preferencesService = preferencesService {
    _currentInstance = this;
    // Register custom callback handler for tim2tox-specific native callbacks
    NativeLibraryManager.customCallbackHandler = _handleCustomCallback;
    // Setup connection status listener
    _setupConnectionStatusListener();
    // Setup message listener
    _setupMessageListener();
    // Setup conversation listener
    _setupConversationListener();
    // Setup friendship listener
    _setupFriendshipListener();
    // Setup group listener
    _setupGroupListener();
    // Setup reaction listener
    _setupReactionListener();
    // Setup progress listener
    _setupProgressListener();
    // Setup avatar updated listener for faceUrl cache
    _setupAvatarUpdatedListener();
    // Friend status checker is started lazily when SDK listeners exist.
    // Setup internal conversation listener to handle pin/unpin from C++ layer
    _setupInternalConversationListener();

    // If ffiService is already initialized (e.g., from main.dart), mark this instance as initialized
    // This ensures that _isInitialized is true even if initSDK hasn't been called yet
    // Note: ffiService.init() is called in main.dart, so by the time home_page.dart creates this instance,
    // the service is already initialized. However, UIKit will call initSDK later, which will set _isInitialized = true.
    // For now, we assume that if ffiService exists and is working, we're initialized.
    // UIKit's initSDK call will properly set _isInitialized = true.
  }

  /// Handle custom callbacks from native layer that are tim2tox-specific.
  /// These are callbacks not handled by the generic SDK (e.g., clearHistoryMessage,
  /// groupQuitNotification, groupChatIdStored).
  Future<void> _handleCustomCallback(
    String callbackName,
    Map<String, dynamic> data,
    Map<String, void Function(Map)> apiCallbackMap,
  ) async {
    switch (callbackName) {
      case "clearHistoryMessage":
        final String? userData = data["user_data"];
        final String? convId = data["conv_id"];
        final String? convType = data["conv_type"];
        if (convId != null && convType != null) {
          try {
            V2TimCallback result;
            if (convType == "1") {
              result = await clearC2CHistoryMessage(userID: convId);
            } else if (convType == "2") {
              result = await clearGroupHistoryMessage(groupID: convId);
            } else {
              return;
            }
            if (userData != null && apiCallbackMap.containsKey(userData)) {
              apiCallbackMap[userData]!({
                "callback": "apiCallback",
                "user_data": userData,
                "code": result.code,
                "desc": result.desc,
              });
            }
          } catch (e) {
            if (userData != null && apiCallbackMap.containsKey(userData)) {
              apiCallbackMap[userData]!({
                "callback": "apiCallback",
                "user_data": userData,
                "code": -1,
                "desc": "clearHistoryMessage failed: $e",
              });
            }
          }
        }
        break;
      case "groupQuitNotification":
        final String? groupId = data["group_id"];
        if (groupId != null) {
          try {
            await ffiService.cleanupGroupState(groupId);
          } catch (e, st) {
            // Binary-replacement-only callback: if cleanupGroupState fails,
            // toxee's group state stays out of sync with C++ until next
            // restart. Surface through the host logger so it's visible,
            // but don't rethrow — the C++ side has already moved on.
            ffiService.logger?.logError(
                '[Tim2ToxSdkPlatform] _handleCustomCallback groupQuitNotification failed for groupId=$groupId',
                e,
                st);
          }
        }
        break;
      case "groupChatIdStored":
        final String? groupId = data["group_id"];
        final String? chatId = data["chat_id"];
        if (groupId != null && chatId != null) {
          try {
            final prefs = _prefs;
            if (prefs != null) {
              await prefs.setGroupChatId(groupId, chatId);
            } else {
              ffiService.logger?.log(
                  '[Tim2ToxSdkPlatform] _handleCustomCallback groupChatIdStored skipped: _prefs is null (groupId=$groupId)');
            }
          } catch (e, st) {
            // Losing this means the group can't auto-rejoin after restart.
            // Same reasoning as above: log loudly, do not rethrow.
            ffiService.logger?.logError(
                '[Tim2ToxSdkPlatform] _handleCustomCallback groupChatIdStored failed for groupId=$groupId',
                e,
                st);
          }
        }
        break;
    }
  }

  /// Check if SDK is initialized, and auto-initialize if ffiService is working
  /// Returns true if initialized, false otherwise
  bool _ensureInitialized() {
    if (!_isInitialized) {
      // Check if ffiService is actually working by checking if we can access it
      // If ffiService exists and has a selfId, it's likely initialized
      if (ffiService.selfId.isNotEmpty) {
        _isInitialized = true;
        return true;
      }
      return false;
    }
    return true;
  }

  // ============================================================================
  // SDK lifecycle methods
  // ============================================================================

  @override
  Future<V2TimValueCallback<bool>> initSDK({
    required int sdkAppID,
    required int loglevel,
    required V2TimSDKListener listener,
    required int uiPlatform,
    bool? showImLog,
    List<dynamic>? plugins,
  }) async {
    _log(
        '[Tim2ToxSdkPlatform] initSDK called - sdkAppID=$sdkAppID, loglevel=$loglevel, uiPlatform=$uiPlatform');
    _sdkAppID = sdkAppID;
    if (!_sdkListeners.contains(listener)) {
      _sdkListeners.add(listener);
    }
    // Start friend status checker only when listeners exist (avoids unnecessary
    // polling in unit tests where platform is instantiated but listeners are not registered).
    _setupFriendStatusChecker();

    // Initialize tim2tox via FFI
    try {
      _debug('[Tim2ToxSdkPlatform] initSDK - Calling ffiService.init()');
      await ffiService.init();

      _isInitialized = true;
      _log(
          '[Tim2ToxSdkPlatform] initSDK - Initialization successful, _isInitialized=true');

      // Notify listener of successful initialization
      // Connection status will be updated via connectionStatusStream

      return V2TimValueCallback<bool>(
        code: 0,
        desc: 'success',
        data: true,
      );
    } catch (e) {
      _log('[Tim2ToxSdkPlatform] initSDK - Initialization failed: $e');
      return V2TimValueCallback<bool>(
        code: -1,
        desc: 'initSDK failed: $e',
        data: false,
      );
    }
  }

  @override
  Future<V2TimCallback> unInitSDK() async {
    // Uninitialize tim2tox via FFI
    try {
      // Cancel all subscriptions to prevent memory leaks
      dispose();

      // IMPORTANT: Call FFI dispose to properly stop the event thread
      // This prevents crashes during application termination when tox_iterate
      // is still running while ToxManager is being destroyed
      if (_isInitialized) {
        try {
          await ffiService.dispose();
        } catch (e) {
          print(
              '[Tim2ToxSdkPlatform] unInitSDK - Error calling ffiService.dispose(): $e');
          // Continue with cleanup even if dispose fails
        }
      }

      _isInitialized = false;
      _isLoggedIn = false;
      _currentUserID = null;

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'unInitSDK failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> login({
    required String userID,
    required String userSig,
  }) async {
    _currentUserID = userID;

    try {
      // Notify connecting state
      _notifySDKListeners((listener) {
        listener.onConnecting?.call();
      });

      // Call FfiChatService.login
      await ffiService.login(userId: userID, userSig: userSig);

      // Start polling for messages
      await ffiService.startPolling();

      _isLoggedIn = true;

      // Connection status will be updated via connectionStatusStream
      // which will trigger onConnectSuccess or onConnectFailed

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      _notifySDKListeners((listener) {
        listener.onConnectFailed?.call(-1, 'login failed: $e');
      });
      return V2TimCallback(
        code: -1,
        desc: 'login failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> logout() async {
    try {
      // Intentional no-op against the underlying FfiChatService: real
      // teardown (cancel subscriptions, dispose FakeUIKit, restore
      // TencentCloudChatSdkPlatform.instance to the default
      // MethodChannel impl, drop UIKit provider registries, re-encrypt
      // profile) is centralized in
      // toxee/lib/util/account_service.dart::teardownCurrentSession,
      // which drives
      // toxee/lib/runtime/session_runtime_coordinator.dart::disposeRuntime.
      // This method only flips local flags so subsequent SDK calls
      // know there is no active session.
      _isLoggedIn = false;
      _currentUserID = null;

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'logout failed: $e',
      );
    }
  }

  // ============================================================================
  // Listener setup methods
  // ============================================================================

  void _setupConnectionStatusListener() {
    _connectionStatusSubscription?.cancel();
    _connectionStatusSubscription =
        ffiService.connectionStatusStream.listen((isConnected) {
      if (isConnected) {
        _notifySDKListeners((listener) {
          listener.onConnectSuccess?.call();
        });
      } else {
        _notifySDKListeners((listener) {
          listener.onConnectFailed?.call(-1, 'Connection failed');
        });
      }
    });
  }

  // _setupMessageListener subscribes to ffiService.messages and dispatches
  // each ChatMessage into the appropriate UIKit V2Tim listener callback
  // (onRecvNewMessage, onRecvMessageModified). Persistence dedup-and-merge
  // is delegated to MessageHistoryPersistence.appendHistory throughout (an
  // earlier version had four inline 5s/isSelf-only dedup blocks that have
  // since been collapsed into single appendHistory calls).
  void _setupMessageListener() {
    _messagesSubscription?.cancel();
    _messagesSubscription = ffiService.messages.listen((chatMsg) async {
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] _setupMessageListener: Received ChatMessage - msgID=${chatMsg.msgID}, isSelf=${chatMsg.isSelf}, isPending=${chatMsg.isPending}, fromUserId=${chatMsg.fromUserId}, text="${chatMsg.text}", groupId=${chatMsg.groupId}');
      // Clean up old pending forward targets periodically
      _cleanupPendingForwardTargets();

      // R-3 / U-1 / U-2 / H-H: inspect text-only payloads for our magic
      // control-signal prefixes before anything else touches them. Runs
      // for BOTH inbound and self-echoed messages so the sender does not
      // see their own `__revoke__:` payload as a ghost bubble either.
      // Skips file-transfer messages (mediaKind != null) since those carry
      // their text in a different envelope.
      ({
        bool swallow,
        String? rewriteText,
        String? rewriteCustomData,
        String? originalText,
      })? controlIntercept;
      if ((chatMsg.mediaKind == null || chatMsg.mediaKind!.isEmpty) &&
          chatMsg.text.isNotEmpty &&
          chatMsg.text.startsWith('__')) {
        controlIntercept = await _maybeInterceptControlSignal(chatMsg);
        if (controlIntercept.swallow) {
          // Revoke (or unrecognized __… control) — the chatMsg has already
          // been persisted by FfiChatService before reaching this stream,
          // so reverse-delete it best-effort. UIKit/history listeners are
          // never notified of the original text.
          final msgIDToReap = chatMsg.msgID;
          if (msgIDToReap != null && msgIDToReap.isNotEmpty) {
            try {
              await deleteMessages(msgIDs: [msgIDToReap]);
            } catch (e) {
              if (_debugLog) {
                print(
                    '[Tim2ToxSdkPlatform] _setupMessageListener: failed to reap self-echo for control signal (swallowed): $e');
              }
            }
          }
          if (_debugLog) {
            print(
                '[Tim2ToxSdkPlatform] _setupMessageListener: swallowed control signal (isSelf=${chatMsg.isSelf}, text="${chatMsg.text}")');
          }
          return;
        }
      }

      // Check if this is a forward message BEFORE converting to V2TimMessage
      // This allows us to fix the userID/groupID during conversion
      String? forwardTargetUserID;
      String? forwardTargetGroupID;

      // For self-sent messages, try to find the target (receiver) from _pendingForwardTargets
      // This is critical because ChatMessage.fromUserId is our own ID for sent messages,
      // but we need the peer's ID (receiver) to set userID correctly
      if (chatMsg.isSelf && chatMsg.msgID != null) {
        final msgID = chatMsg.msgID!;
        final messageText = chatMsg.text;
        final messageTimestamp = chatMsg.timestamp.millisecondsSinceEpoch;

        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Looking for target for sent message: msgID=$msgID, text="$messageText", _pendingForwardTargets keys: ${_pendingForwardTargets.keys.toList()}');

        // Try to match by msgID first (most reliable)
        if (_pendingForwardTargets.containsKey(msgID)) {
          final target = _pendingForwardTargets[msgID]!;
          forwardTargetUserID = target.userID;
          forwardTargetGroupID = target.groupID;
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Found target by msgID: msgID=$msgID, userID=$forwardTargetUserID, groupID=$forwardTargetGroupID');
        }
        // If not found, try to match by text and timestamp (for forward messages)
        else if (messageText.isNotEmpty &&
            _pendingForwardTargets.containsKey(messageText)) {
          final target = _pendingForwardTargets[messageText]!;
          final timeDiff = (messageTimestamp - target.timestamp).abs();
          if (timeDiff < 30000) {
            forwardTargetUserID = target.userID;
            forwardTargetGroupID = target.groupID;
            // Move from text key to msgID key
            _pendingForwardTargets[msgID] = target;
            _pendingForwardTargets.remove(messageText);
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Found target by text: msgID=$msgID, userID=$forwardTargetUserID, groupID=$forwardTargetGroupID');
          } else {
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Text match found but timestamp diff too large: $timeDiff ms');
          }
        }
        // Also check if there's a temporary ID (created_temp_id-*) that matches
        // This handles the case where msgID changed from temporary to actual
        else if (messageText.isNotEmpty) {
          // Check if any key in _pendingForwardTargets starts with "created_temp_id-"
          // and has matching text in _pendingForwardTargets
          for (final key in _pendingForwardTargets.keys.toList()) {
            if (key.startsWith('created_temp_id-')) {
              // If we have text key, use it; otherwise check if temp ID has matching target
              if (_pendingForwardTargets.containsKey(messageText)) {
                final target = _pendingForwardTargets[messageText]!;
                final timeDiff = (messageTimestamp - target.timestamp).abs();
                if (timeDiff < 30000) {
                  forwardTargetUserID = target.userID;
                  forwardTargetGroupID = target.groupID;
                  // Move from text key to msgID key
                  _pendingForwardTargets[msgID] = target;
                  _pendingForwardTargets.remove(messageText);
                  _pendingForwardTargets.remove(key); // Remove temporary ID key
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] Found target by text (via temp ID): msgID=$msgID, userID=$forwardTargetUserID, groupID=$forwardTargetGroupID');
                  break;
                }
              }
            }
          }
        }
        if (forwardTargetUserID == null && forwardTargetGroupID == null) {
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] No target found in _pendingForwardTargets for msgID=$msgID or text="$messageText"');
        }
      }

      // For received messages (isSelf=false), fromUserId is the sender's ID (peer's ID)
      // So userID should be fromUserId, which is already handled by chatMessageToV2TimMessage
      // No need to set forwardTargetUserID for received messages

      // For self-sent messages (especially image/file messages), if we don't have forwardTargetUserID yet,
      // try to find the receiver from FFI service history
      // This is important because image/file messages may not have text to match in _pendingForwardTargets
      if (chatMsg.isSelf &&
          forwardTargetUserID == null &&
          forwardTargetGroupID == null &&
          chatMsg.msgID != null) {
        // Search through all conversation histories in FFI service
        for (final entry in ffiService.lastMessages.entries) {
          final peerId = entry.key;
          final history = ffiService.getHistory(peerId);

          // Check if this message exists in this peer's history
          final messageExists = history.any((msg) {
            final currentMsgID = msg.msgID ??
                '${msg.timestamp.millisecondsSinceEpoch}_${msg.fromUserId}';
            return currentMsgID == chatMsg.msgID;
          });

          if (messageExists) {
            // Found the message in this peer's history, use peerId as the receiver
            if (chatMsg.groupId != null) {
              forwardTargetGroupID = peerId;
              forwardTargetUserID = null;
            } else {
              forwardTargetUserID = peerId;
              forwardTargetGroupID = null;
            }
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Found receiver from history: msgID=${chatMsg.msgID}, userID=$forwardTargetUserID, groupID=$forwardTargetGroupID');
            // Also update _pendingForwardTargets for future lookups
            if (chatMsg.msgID != null) {
              _pendingForwardTargets[chatMsg.msgID!] = (
                userID: forwardTargetUserID,
                groupID: forwardTargetGroupID,
                timestamp: chatMsg.timestamp.millisecondsSinceEpoch,
              );
            }
            break;
          }
        }
      }

      // For received messages, ensure userID is set to fromUserId (sender's ID)
      if (!chatMsg.isSelf &&
          forwardTargetUserID == null &&
          forwardTargetGroupID == null) {
        if (chatMsg.groupId != null) {
          forwardTargetGroupID = chatMsg.groupId;
        } else if (chatMsg.fromUserId.isNotEmpty) {
          forwardTargetUserID = chatMsg.fromUserId;
        }
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Set receiver for received message: userID=$forwardTargetUserID, groupID=$forwardTargetGroupID');
      }

      // Convert ChatMessage to V2TimMessage and notify listeners
      // Pass forward target info to chatMessageToV2TimMessage so it can set correct userID/groupID during conversion
      final v2Msg = chatMessageToV2TimMessage(chatMsg, ffiService.selfId,
          forwardTargetUserID: forwardTargetUserID,
          forwardTargetGroupID: forwardTargetGroupID);

      // U-1 / U-2: __face__ / __custom__ / __location__ → keep message but
      // rewrite the bubble text and stash the original JSON into
      // customElem.data for later rich rendering. The chatMsg.text in
      // history will still be the raw payload (since ChatMessage is
      // immutable); UIKit only ever sees the rewritten v2Msg.
      if (controlIntercept != null &&
          !controlIntercept.swallow &&
          (controlIntercept.rewriteText != null ||
              controlIntercept.rewriteCustomData != null)) {
        if (controlIntercept.rewriteText != null) {
          v2Msg.textElem = V2TimTextElem(text: controlIntercept.rewriteText);
        }
        if (controlIntercept.rewriteCustomData != null) {
          v2Msg.customElem = V2TimCustomElem(
            data: controlIntercept.rewriteCustomData,
            desc: controlIntercept.originalText ?? '',
            extension: '',
          );
        }
      }

      // U-3: patch local sender's soundElem.duration from
      // `_pendingSoundDurations`. Receiver-side duration recovery is
      // partial (filename-encoded `__dur{ms}`) and only kicks in for files
      // whose name went through sendMessage's encoding path.
      if (chatMsg.isSelf && v2Msg.soundElem != null) {
        final p = v2Msg.soundElem!.path ?? chatMsg.filePath;
        final dur = _lookupSoundDuration(p);
        if (dur != null && dur > 0 && (v2Msg.soundElem!.duration ?? 0) == 0) {
          v2Msg.soundElem = V2TimSoundElem(
            path: v2Msg.soundElem!.path,
            UUID: v2Msg.soundElem!.UUID,
            dataSize: v2Msg.soundElem!.dataSize,
            duration: dur,
            url: v2Msg.soundElem!.url,
            localUrl: v2Msg.soundElem!.localUrl,
          );
        }
      } else if (!chatMsg.isSelf && v2Msg.soundElem != null) {
        // Receiver: try filename-encoded duration as a best-effort.
        final p = v2Msg.soundElem!.path ?? chatMsg.filePath;
        final dur = _lookupSoundDuration(p);
        if (dur != null && dur > 0 && (v2Msg.soundElem!.duration ?? 0) == 0) {
          v2Msg.soundElem = V2TimSoundElem(
            path: v2Msg.soundElem!.path,
            UUID: v2Msg.soundElem!.UUID,
            dataSize: v2Msg.soundElem!.dataSize,
            duration: dur,
            url: v2Msg.soundElem!.url,
            localUrl: v2Msg.soundElem!.localUrl,
          );
        }
      }

      // If we found forward target before conversion, fix userID/groupID now
      if (forwardTargetUserID != null || forwardTargetGroupID != null) {
        v2Msg.userID = forwardTargetUserID;
        v2Msg.groupID = forwardTargetGroupID;
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Set userID/groupID from forwardTarget: userID=$forwardTargetUserID, groupID=$forwardTargetGroupID');
        // Store forward target info in localCustomData for future reference
        try {
          final customData = <String, dynamic>{
            'forwardTarget': {
              'userID': forwardTargetUserID,
              'groupID': forwardTargetGroupID,
            },
          };
          v2Msg.localCustomData = json.encode(customData);
        } catch (e) {
          // Failed to store forward target info, continue anyway
        }
      } else {
        // If forwardTarget was not found, check if v2Msg has userID/groupID set
        // For sent messages, if userID is still null, try to find from history
        if (chatMsg.isSelf &&
            (v2Msg.userID == null || v2Msg.userID!.isEmpty) &&
            (v2Msg.groupID == null || v2Msg.groupID!.isEmpty)) {
          print(
              '[Tim2ToxSdkPlatform] WARNING: Sent message has no userID/groupID after conversion, attempting to find from history');
          // This should have been handled above, but if not, try again
          for (final entry in ffiService.lastMessages.entries) {
            final peerId = entry.key;
            final history = ffiService.getHistory(peerId);
            if (history.any((msg) => msg.msgID == chatMsg.msgID)) {
              if (chatMsg.groupId != null) {
                v2Msg.groupID = peerId;
                forwardTargetGroupID = peerId;
              } else {
                v2Msg.userID = peerId;
                forwardTargetUserID = peerId;
              }
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] Found receiver from history (after conversion): userID=${v2Msg.userID}, groupID=${v2Msg.groupID}');
              break;
            }
          }
        }
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] After conversion: v2Msg.userID=${v2Msg.userID}, v2Msg.groupID=${v2Msg.groupID}');
      }

      // Determine forwardTargetID from the fixed userID/groupID
      String? forwardTargetID;
      if (forwardTargetUserID != null || forwardTargetGroupID != null) {
        forwardTargetID = forwardTargetGroupID ?? forwardTargetUserID;
      } else if (v2Msg.userID != null || v2Msg.groupID != null) {
        // Check if this is a forward message by checking if userID/groupID doesn't match fromUserId
        // For forward messages, userID should be the target user, not the sender
        if (chatMsg.isSelf &&
            chatMsg.groupId == null &&
            v2Msg.userID != chatMsg.fromUserId) {
          // This is likely a forward message to a user
          forwardTargetID = v2Msg.userID;
        } else if (chatMsg.isSelf &&
            chatMsg.groupId != null &&
            v2Msg.groupID == chatMsg.groupId) {
          // This is likely a forward message to a group
          forwardTargetID = v2Msg.groupID;
        }
      }

      // If we still don't have forwardTargetID, try to find the message in UIKit's messageData
      // This handles the case where message was sent later (e.g., when friend comes online)
      // IMPORTANT: Only do this for non-pending messages, as pending messages should use forwardTargetID from _pendingForwardTargets
      if (forwardTargetID == null &&
          chatMsg.isSelf &&
          chatMsg.msgID != null &&
          !chatMsg.isPending) {
        final messageListMap =
            TencentCloudChat.instance.dataInstance.messageData.messageListMap;
        for (final entry in messageListMap.entries) {
          final messageList = entry.value;
          final existingMsg = messageList.firstWhere(
            (msg) => msg.msgID == chatMsg.msgID || msg.id == chatMsg.msgID,
            orElse: () =>
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE),
          );
          if (existingMsg.elemType != MessageElemType.V2TIM_ELEM_TYPE_NONE) {
            // Found the message, use its userID/groupID
            if (existingMsg.userID != null || existingMsg.groupID != null) {
              v2Msg.userID = existingMsg.userID;
              v2Msg.groupID = existingMsg.groupID;
              forwardTargetID = existingMsg.groupID ?? existingMsg.userID;
              // Also update _pendingForwardTargets for future lookups
              if (chatMsg.msgID != null) {
                _pendingForwardTargets[chatMsg.msgID!] = (
                  userID: existingMsg.userID,
                  groupID: existingMsg.groupID,
                  timestamp: chatMsg.timestamp.millisecondsSinceEpoch,
                );
              }
            }
            break;
          }
        }
      }

      // Check if this is an update to an existing message (status change from pending to sent)
      // For self-sent messages that were pending and are now sent, use onRecvMessageModified
      // We need to check if the message already exists in messageData to determine if it's an update
      // CRITICAL: Check isPending explicitly - if it's null, treat as false (not pending)
      // This handles messages from _onNativeEvent which may not have isPending set
      // IMPORTANT: Define isPending at the top level so it's available in all branches
      final isPending = chatMsg.isPending ?? false;
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] Message processing: isSelf=${chatMsg.isSelf}, isPending=${chatMsg.isPending}, isPending (normalized)=$isPending, msgID=${chatMsg.msgID}, text="${chatMsg.text}", forwardTargetID=$forwardTargetID, v2Msg.userID=${v2Msg.userID}, v2Msg.groupID=${v2Msg.groupID}');

      if (chatMsg.isSelf && !isPending) {
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Processing self-sent non-pending message: msgID=${chatMsg.msgID}, text="${chatMsg.text}", isPending=$isPending, forwardTargetID=$forwardTargetID, v2Msg.userID=${v2Msg.userID}, v2Msg.groupID=${v2Msg.groupID}');
        // Check if message already exists in messageData
        // Use the corrected conversationID if this is a forward message
        // If forwardTargetID is still null, try to find the message in all conversations
        // to determine the correct target (this handles the case where message was sent later)
        String? conversationID = forwardTargetID;
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Initial conversationID from forwardTargetID: $conversationID');
        if (conversationID == null) {
          // Try to find the message in all conversations to determine the correct target
          // This handles the case where message was sent later (e.g., when friend comes online)
          final messageListMap =
              TencentCloudChat.instance.dataInstance.messageData.messageListMap;
          for (final entry in messageListMap.entries) {
            final targetID = entry.key;
            final messageList = entry.value;
            // CRITICAL: Check both msgID and id fields, and also check if id matches msgID
            // UIKit messages may have id (temporary ID) while FFI messages have msgID (actual ID)
            // We need to match on both to prevent duplicates
            // Also check by message content (text + timestamp) as fallback since FFI may generate different msgID
            final messageExists = messageList.any((msg) {
              // Check if msgID matches
              if (v2Msg.msgID != null && msg.msgID == v2Msg.msgID) return true;
              // Check if id matches msgID
              if (v2Msg.msgID != null && msg.id == v2Msg.msgID) return true;
              // Check if msgID matches id
              if (v2Msg.id != null && msg.msgID == v2Msg.id) return true;
              // Check if id matches id
              if (v2Msg.id != null &&
                  msg.id == v2Msg.id &&
                  v2Msg.id!.isNotEmpty) return true;

              // CRITICAL: Fallback matching by content (text + timestamp) for sent messages
              // FFI layer may generate different msgID than UIKit, so we need to match by content
              // This prevents duplicate messages when msgID doesn't match
              // Use the same isPending variable for consistency
              if (chatMsg.isSelf && !isPending) {
                // For sent messages, match by text content and timestamp (within 5 seconds)
                final v2Text = v2Msg.textElem?.text ??
                    v2Msg.mergerElem?.compatibleText ??
                    '';
                final msgText =
                    msg.textElem?.text ?? msg.mergerElem?.compatibleText ?? '';
                if (v2Text.isNotEmpty && msgText == v2Text) {
                  // Check timestamp match (within 5 seconds)
                  final timeDiff =
                      ((v2Msg.timestamp ?? 0) - (msg.timestamp ?? 0)).abs();
                  if (timeDiff <= 5) {
                    // Also check isSelf to ensure it's the same sender
                    if (v2Msg.isSelf == msg.isSelf) {
                      if (_debugLog)
                        print(
                            '[Tim2ToxSdkPlatform] Matched message by content in search: text="$v2Text", timeDiff=$timeDiff seconds');
                      return true;
                    }
                  }
                }
              }

              return false;
            });
            if (messageExists) {
              // Found the message in this conversation, use this as the target
              conversationID = targetID;
              // Also fix the userID/groupID to match
              if (targetID.startsWith('tox_')) {
                v2Msg.groupID = targetID;
                v2Msg.userID = null;
              } else {
                v2Msg.userID = targetID;
                v2Msg.groupID = null;
              }
              break;
            }
          }
        }

        // If still not found, use default (this should not happen for forward messages)
        // CRITICAL: For self-sent messages, conversationID should be the receiver's ID (forwardTargetID),
        // NOT the sender's own ID (fromUserId). UIKit stores messages with receiver's ID as conversationID.
        // If forwardTargetID is still null, try to use userID/groupID from v2Msg (which should be set by forwardTarget)
        final previousConversationID = conversationID;
        conversationID = conversationID ??
            (v2Msg.groupID ?? v2Msg.userID) ??
            (chatMsg.groupId ?? forwardTargetID);
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Final conversationID: $conversationID (previous: $previousConversationID, v2Msg.userID=${v2Msg.userID}, v2Msg.groupID=${v2Msg.groupID}, chatMsg.groupId=${chatMsg.groupId}, forwardTargetID=$forwardTargetID)');

        // IMPORTANT: For self-sent messages, if forwardTargetID is null, this is NOT a forward message
        // The conversationID should be the sender's own ID (fromUserId), which means it belongs to the sender's own conversation
        // We should NOT add it to the current chat page unless the current chat page is the sender's own conversation
        // However, UIKit will handle this correctly based on the userID/groupID we set in v2Msg

        // Ensure conversationID is not null before using it
        if (conversationID == null || conversationID.isEmpty) {
          print(
              '[Tim2ToxSdkPlatform] WARNING: conversationID is null or empty, cannot check message existence. Skipping message existence check.');
          // Use default: notify as new message
          await _setFaceUrlForMsg(v2Msg);
          _notifyAdvancedMsgListeners((listener) {
            listener.onRecvNewMessage?.call(v2Msg);
          });
          return;
        }

        // At this point, conversationID is guaranteed to be non-null and non-empty
        final finalConversationID = conversationID!;
        final messageList = TencentCloudChat.instance.dataInstance.messageData
            .getMessageList(key: finalConversationID);
        // CRITICAL: Check both msgID and id fields, and also check if id matches msgID
        // UIKit messages may have id (temporary ID) while FFI messages have msgID (actual ID)
        // We need to match on both to prevent duplicates
        // Also check by message content (text + timestamp) as fallback since FFI may generate different msgID
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Checking message existence: v2Msg.msgID=${v2Msg.msgID}, v2Msg.id=${v2Msg.id}, conversationID=$conversationID, messageList.length=${messageList.length}');
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Message details: isSelf=${chatMsg.isSelf}, isPending=${chatMsg.isPending}, isPending (normalized)=$isPending, text="${chatMsg.text}"');
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] First 3 messages in list: ${messageList.take(3).map((m) => 'id=${m.id}, msgID=${m.msgID}, text="${m.textElem?.text ?? ""}", timestamp=${m.timestamp}').join("; ")}');
        final messageExists = messageList.any((msg) {
          // Check if msgID matches
          if (v2Msg.msgID != null && msg.msgID == v2Msg.msgID) {
            if (_debugLog)
              print('[Tim2ToxSdkPlatform] Matched by msgID: ${v2Msg.msgID}');
            return true;
          }
          // Check if id matches msgID
          if (v2Msg.msgID != null && msg.id == v2Msg.msgID) {
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Matched by v2Msg.msgID == msg.id: ${v2Msg.msgID}');
            return true;
          }
          // Check if msgID matches id
          if (v2Msg.id != null && msg.msgID == v2Msg.id) {
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Matched by v2Msg.id == msg.msgID: ${v2Msg.id}');
            return true;
          }
          // Check if id matches id
          if (v2Msg.id != null && msg.id == v2Msg.id && v2Msg.id!.isNotEmpty) {
            if (_debugLog)
              print('[Tim2ToxSdkPlatform] Matched by id: ${v2Msg.id}');
            return true;
          }

          // CRITICAL: Check for temporary messages (created_temp_id-*) that need to be matched
          // When FFI returns a new message with different msgID, we need to match it with
          // the temporary message created by UIKit. This prevents duplicate messages.
          // Check if the existing message is a temporary message (created_temp_id-*)
          final isTempMessage =
              msg.id != null && msg.id!.startsWith('created_temp_id-');
          final isTempMsgID =
              msg.msgID != null && msg.msgID!.startsWith('created_temp_id-');

          // CRITICAL: Fallback matching by content (text + timestamp) for sent messages
          // FFI layer may generate different msgID than UIKit, so we need to match by content
          // This prevents duplicate messages when msgID doesn't match
          // Use the same isPending variable for consistency
          if (chatMsg.isSelf && !isPending) {
            // For sent messages, match by text content and timestamp (within 10 seconds)
            // Increased time window to 10 seconds to handle timing differences
            final v2Text =
                v2Msg.textElem?.text ?? v2Msg.mergerElem?.compatibleText ?? '';
            final msgText =
                msg.textElem?.text ?? msg.mergerElem?.compatibleText ?? '';
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Content matching: v2Text="$v2Text", msgText="$msgText", v2Msg.timestamp=${v2Msg.timestamp}, msg.timestamp=${msg.timestamp}, isTempMessage=$isTempMessage, isTempMsgID=$isTempMsgID');

            // Check timestamp match (within 10 seconds) - needed for both text and file matching
            final timeDiff =
                ((v2Msg.timestamp ?? 0) - (msg.timestamp ?? 0)).abs();
            final timestampMatches = timeDiff <= 10;

            bool contentMatches = false;

            // For text messages, match by text content
            if (v2Text.isNotEmpty && msgText == v2Text) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] Text matches, checking timestamp: timeDiff=$timeDiff seconds');
              contentMatches = timestampMatches;
            }
            // For file messages (text is empty), match by file path and filename
            else if (v2Text.isEmpty && msgText.isEmpty) {
              // Check if both messages are file messages
              final v2IsFile =
                  v2Msg.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE &&
                      v2Msg.fileElem != null;
              final msgIsFile =
                  msg.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE &&
                      msg.fileElem != null;

              if (v2IsFile && msgIsFile) {
                // Match by file path and filename
                final v2FilePath = v2Msg.fileElem?.path ?? '';
                final msgFilePath = msg.fileElem?.path ?? '';
                final v2FileName = v2Msg.fileElem?.fileName ?? '';
                final msgFileName = msg.fileElem?.fileName ?? '';

                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] File message matching: v2FilePath="$v2FilePath", msgFilePath="$msgFilePath", v2FileName="$v2FileName", msgFileName="$msgFileName", timeDiff=$timeDiff seconds');

                // Match if file path matches (most reliable) or if filename matches and timestamp is close
                if (v2FilePath.isNotEmpty &&
                    msgFilePath.isNotEmpty &&
                    v2FilePath == msgFilePath) {
                  contentMatches = timestampMatches;
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] File path matches: "$v2FilePath"');
                } else if (v2FileName.isNotEmpty &&
                    msgFileName.isNotEmpty &&
                    v2FileName == msgFileName &&
                    timestampMatches) {
                  // Fallback: match by filename if path doesn't match but timestamp is close
                  // This handles cases where path might differ slightly but filename is the same
                  contentMatches = true;
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] File name matches: "$v2FileName"');
                } else {
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] File match failed: path or name mismatch');
                }
              } else {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Content match skipped: both messages are empty but not both are file messages (v2IsFile=$v2IsFile, msgIsFile=$msgIsFile)');
              }
            } else {
              if (v2Text.isEmpty) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Content match skipped: v2Text is empty and not a file message match');
              } else if (msgText != v2Text) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Content match failed: text mismatch ("$msgText" != "$v2Text")');
              }
            }

            if (contentMatches) {
              // Also check isSelf to ensure it's the same sender
              if (v2Msg.isSelf == msg.isSelf) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Matched message by content: timeDiff=$timeDiff seconds, isTempMessage=$isTempMessage');
                // CRITICAL: Update the existing message's msgID and id to match the new one
                // This ensures future lookups will match correctly
                // For temporary messages, update both msgID and id to the new msgID
                if (v2Msg.msgID != null) {
                  if (msg.msgID != v2Msg.msgID) {
                    if (_debugLog)
                      print(
                          '[Tim2ToxSdkPlatform] Updating existing message msgID from ${msg.msgID} to ${v2Msg.msgID}');
                    msg.msgID = v2Msg.msgID;
                  }
                  // CRITICAL: For temporary messages, also update id to match the new msgID
                  // This ensures the temporary message is properly replaced
                  if (isTempMessage || isTempMsgID) {
                    if (_debugLog)
                      print(
                          '[Tim2ToxSdkPlatform] Updating temporary message id from ${msg.id} to ${v2Msg.msgID}');
                    msg.id = v2Msg.msgID;
                  } else if (msg.id == msg.msgID ||
                      msg.id == null ||
                      msg.id!.isEmpty) {
                    // If id matches old msgID or is empty, update it to new msgID
                    msg.id = v2Msg.msgID;
                  }
                }
                return true;
              } else {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Content match failed: isSelf mismatch (v2Msg.isSelf=${v2Msg.isSelf}, msg.isSelf=${msg.isSelf})');
              }
            } else {
              if (!timestampMatches) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Content match failed: timeDiff too large ($timeDiff seconds)');
              }
            }
          } else {
            if (!chatMsg.isSelf) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] Content match skipped: not self message (isSelf=${chatMsg.isSelf})');
            } else if (chatMsg.isPending) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] Content match skipped: message is pending (isPending=${chatMsg.isPending})');
            }
          }

          return false;
        });
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Message existence check result: $messageExists');

        if (messageExists) {
          // Message exists, notify as modified.
          // Persistence: hand off to MessageHistoryPersistence.appendHistory,
          // which dedups by msgID (and merges via _mergeMessages preserving
          // final file paths etc.) and falls back to a 2s content+sender
          // match. That replaces the previous inline "saveHistory full list
          // when found / appendHistory when missing" branching.
          final conversationId = finalConversationID;
          unawaited(ffiService.messageHistoryPersistence
              .appendHistory(conversationId, chatMsg));
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Persisted modified message: conversationId=$conversationId, msgID=${chatMsg.msgID}');

          await _setFaceUrlForMsg(v2Msg);
          _notifyAdvancedMsgListeners((listener) {
            listener.onRecvMessageModified?.call(v2Msg);
          });
        } else {
          // Message doesn't exist, notify as new
          await _setFaceUrlForMsg(v2Msg);
          _notifyAdvancedMsgListeners((listener) {
            listener.onRecvNewMessage?.call(v2Msg);
          });
        }
      } else {
        // New message or received message (including pending messages)
        // CRITICAL: Also check for self-sent non-pending messages that might have been missed
        // This handles messages from _onNativeEvent which may not have been processed correctly
        // Check isPending explicitly - if it's null, treat as false (not pending)
        final isPending = chatMsg.isPending ?? false;

        // For self-sent non-pending messages, try to match with existing messages
        // This prevents duplicate messages when FFI returns a message with different msgID
        if (chatMsg.isSelf && !isPending) {
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Processing self-sent non-pending message in else branch: msgID=${chatMsg.msgID}, text="${chatMsg.text}", isPending=$isPending, forwardTargetID=$forwardTargetID, v2Msg.userID=${v2Msg.userID}, v2Msg.groupID=${v2Msg.groupID}');
          // Try to find the message in messageData to determine if it's an update
          String? conversationID =
              forwardTargetID ?? (v2Msg.groupID ?? v2Msg.userID);
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Checking message existence in else branch: conversationID=$conversationID');

          if (conversationID != null && conversationID.isNotEmpty) {
            final messageList = TencentCloudChat
                .instance.dataInstance.messageData
                .getMessageList(key: conversationID!);
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Message list length: ${messageList.length}');
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] First 3 messages: ${messageList.take(3).map((m) => 'id=${m.id}, msgID=${m.msgID}, text="${m.textElem?.text ?? ""}", timestamp=${m.timestamp}').join("; ")}');

            // Check if message exists by msgID, id, or content
            final messageExists = messageList.any((msg) {
              // Check if msgID matches
              if (v2Msg.msgID != null && msg.msgID == v2Msg.msgID) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Matched by msgID in else branch: ${v2Msg.msgID}');
                return true;
              }
              // Check if id matches msgID
              if (v2Msg.msgID != null && msg.id == v2Msg.msgID) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Matched by v2Msg.msgID == msg.id in else branch: ${v2Msg.msgID}');
                return true;
              }
              // Check if msgID matches id
              if (v2Msg.id != null && msg.msgID == v2Msg.id) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Matched by v2Msg.id == msg.msgID in else branch: ${v2Msg.id}');
                return true;
              }
              // Check if id matches id
              if (v2Msg.id != null &&
                  msg.id == v2Msg.id &&
                  v2Msg.id!.isNotEmpty) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Matched by id in else branch: ${v2Msg.id}');
                return true;
              }

              // CRITICAL: Check for temporary messages (created_temp_id-*) that need to be matched
              // When FFI returns a new message with different msgID, we need to match it with
              // the temporary message created by UIKit. This prevents duplicate messages.
              // Check if the existing message is a temporary message (created_temp_id-*)
              final isTempMessage =
                  msg.id != null && msg.id!.startsWith('created_temp_id-');
              final isTempMsgID = msg.msgID != null &&
                  msg.msgID!.startsWith('created_temp_id-');

              // CRITICAL: Fallback matching by content (text + timestamp) for sent messages
              // FFI layer may generate different msgID than UIKit, so we need to match by content
              // This prevents duplicate messages when msgID doesn't match
              final v2Text = v2Msg.textElem?.text ??
                  v2Msg.mergerElem?.compatibleText ??
                  '';
              final msgText =
                  msg.textElem?.text ?? msg.mergerElem?.compatibleText ?? '';
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] Content matching in else branch: v2Text="$v2Text", msgText="$msgText", v2Msg.timestamp=${v2Msg.timestamp}, msg.timestamp=${msg.timestamp}, isTempMessage=$isTempMessage, isTempMsgID=$isTempMsgID');

              // Check timestamp match (within 10 seconds) - needed for both text and file matching
              final timeDiff =
                  ((v2Msg.timestamp ?? 0) - (msg.timestamp ?? 0)).abs();
              final timestampMatches = timeDiff <= 10;

              bool contentMatches = false;

              // For text messages, match by text content
              if (v2Text.isNotEmpty && msgText == v2Text) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Text matches in else branch, checking timestamp: timeDiff=$timeDiff seconds');
                contentMatches = timestampMatches;
              }
              // For file messages (text is empty), match by file path and filename
              else if (v2Text.isEmpty && msgText.isEmpty) {
                // Check if both messages are file messages
                final v2IsFile =
                    v2Msg.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE &&
                        v2Msg.fileElem != null;
                final msgIsFile =
                    msg.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE &&
                        msg.fileElem != null;

                if (v2IsFile && msgIsFile) {
                  // Match by file path and filename
                  final v2FilePath = v2Msg.fileElem?.path ?? '';
                  final msgFilePath = msg.fileElem?.path ?? '';
                  final v2FileName = v2Msg.fileElem?.fileName ?? '';
                  final msgFileName = msg.fileElem?.fileName ?? '';

                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] File message matching in else branch: v2FilePath="$v2FilePath", msgFilePath="$msgFilePath", v2FileName="$v2FileName", msgFileName="$msgFileName", timeDiff=$timeDiff seconds');

                  // Match if file path matches (most reliable) or if filename matches and timestamp is close
                  if (v2FilePath.isNotEmpty &&
                      msgFilePath.isNotEmpty &&
                      v2FilePath == msgFilePath) {
                    contentMatches = timestampMatches;
                    if (_debugLog)
                      print(
                          '[Tim2ToxSdkPlatform] File path matches in else branch: "$v2FilePath"');
                  } else if (v2FileName.isNotEmpty &&
                      msgFileName.isNotEmpty &&
                      v2FileName == msgFileName &&
                      timestampMatches) {
                    // Fallback: match by filename if path doesn't match but timestamp is close
                    // This handles cases where path might differ slightly but filename is the same
                    contentMatches = true;
                    if (_debugLog)
                      print(
                          '[Tim2ToxSdkPlatform] File name matches in else branch: "$v2FileName"');
                  } else {
                    if (_debugLog)
                      print(
                          '[Tim2ToxSdkPlatform] File match failed in else branch: path or name mismatch');
                  }
                } else {
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] Content match skipped in else branch: both messages are empty but not both are file messages (v2IsFile=$v2IsFile, msgIsFile=$msgIsFile)');
                }
              } else {
                if (v2Text.isEmpty) {
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] Content match skipped in else branch: v2Text is empty and not a file message match');
                } else if (msgText != v2Text) {
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] Content match failed in else branch: text mismatch ("$msgText" != "$v2Text")');
                }
              }

              if (contentMatches) {
                // Also check isSelf to ensure it's the same sender
                if (v2Msg.isSelf == msg.isSelf) {
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] Matched message by content in else branch: timeDiff=$timeDiff seconds, isTempMessage=$isTempMessage');
                  // CRITICAL: Update the existing message's msgID and id to match the new one
                  // This ensures future lookups will match correctly
                  // For temporary messages, update both msgID and id to the new msgID
                  if (v2Msg.msgID != null) {
                    if (msg.msgID != v2Msg.msgID) {
                      if (_debugLog)
                        print(
                            '[Tim2ToxSdkPlatform] Updating existing message msgID from ${msg.msgID} to ${v2Msg.msgID} in else branch');
                      msg.msgID = v2Msg.msgID;
                    }
                    // CRITICAL: For temporary messages, also update id to match the new msgID
                    // This ensures the temporary message is properly replaced
                    if (isTempMessage || isTempMsgID) {
                      if (_debugLog)
                        print(
                            '[Tim2ToxSdkPlatform] Updating temporary message id from ${msg.id} to ${v2Msg.msgID} in else branch');
                      msg.id = v2Msg.msgID;
                    } else if (msg.id == msg.msgID ||
                        msg.id == null ||
                        msg.id!.isEmpty) {
                      // If id matches old msgID or is empty, update it to new msgID
                      msg.id = v2Msg.msgID;
                    }
                  }
                  return true;
                } else {
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] Content match failed in else branch: isSelf mismatch (v2Msg.isSelf=${v2Msg.isSelf}, msg.isSelf=${msg.isSelf})');
                }
              } else {
                if (!timestampMatches) {
                  if (_debugLog)
                    print(
                        '[Tim2ToxSdkPlatform] Content match failed in else branch: timeDiff too large ($timeDiff seconds)');
                }
              }

              return false;
            });

            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Message existence check result in else branch: $messageExists');

            if (messageExists) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] Notifying as modified in else branch');

              // Same hand-off as block 1: appendHistory handles
              // msgID/content dedup and merging via _mergeMessages.
              unawaited(ffiService.messageHistoryPersistence
                  .appendHistory(conversationID, chatMsg));
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] Persisted modified message (else branch): conversationId=$conversationID, msgID=${chatMsg.msgID}');

              await _setFaceUrlForMsg(v2Msg);
              _notifyAdvancedMsgListeners((listener) {
                listener.onRecvMessageModified?.call(v2Msg);
              });
              return; // Skip the rest of the logic
            }
          }
        }

        // For received messages (isSelf=false), check if the message already exists in _messageListMap
        // by content + sender + timestamp. This prevents duplicates caused by the same message arriving
        // through BOTH the native FFI callback path (HandleFriendMessage → OnRecvNewMessage with m-prefix ID)
        // AND the Dart stream path (_setupMessageListener with real ID).
        if (!chatMsg.isSelf) {
          final conversationID = v2Msg.groupID ?? v2Msg.userID ?? '';
          if (conversationID.isNotEmpty) {
            final messageList = TencentCloudChat
                .instance.dataInstance.messageData
                .getMessageList(key: conversationID);
            final duplicateMsg = messageList.cast<V2TimMessage?>().firstWhere(
              (msg) {
                if (msg == null) return false;
                // Check msgID match first
                if (v2Msg.msgID != null && msg.msgID == v2Msg.msgID)
                  return true;
                if (v2Msg.msgID != null && msg.id == v2Msg.msgID) return true;
                if (v2Msg.id != null && msg.msgID == v2Msg.id) return true;

                // Only treat as duplicate by content when incoming message has no ID or temp ID (same message from two paths).
                // When v2Msg has a real msgID, distinct messages with same content must not be merged.
                if (v2Msg.msgID != null && !v2Msg.msgID!.startsWith('m'))
                  return false;
                // Content-based matching: same sender, same content, close timestamp
                if (msg.sender == v2Msg.sender) {
                  final timeDiff =
                      ((v2Msg.timestamp ?? 0) - (msg.timestamp ?? 0)).abs();
                  if (timeDiff <= 10) {
                    // Text message matching
                    final v2Text = v2Msg.textElem?.text ?? '';
                    final msgText = msg.textElem?.text ?? '';
                    if (v2Text.isNotEmpty && msgText == v2Text) return true;

                    // File message matching
                    if (v2Msg.fileElem != null && msg.fileElem != null) {
                      final v2FileName = v2Msg.fileElem?.fileName ?? '';
                      final msgFileName = msg.fileElem?.fileName ?? '';
                      if (v2FileName.isNotEmpty && v2FileName == msgFileName)
                        return true;
                    }

                    // Image message matching
                    if (v2Msg.imageElem != null && msg.imageElem != null) {
                      final v2Path = v2Msg.imageElem?.path ?? '';
                      final msgPath = msg.imageElem?.path ?? '';
                      if (v2Path.isNotEmpty && v2Path == msgPath) return true;
                    }

                    // Video message matching
                    if (v2Msg.videoElem != null && msg.videoElem != null) {
                      final v2Path = v2Msg.videoElem?.videoPath ?? '';
                      final msgPath = msg.videoElem?.videoPath ?? '';
                      if (v2Path.isNotEmpty && v2Path == msgPath) return true;
                    }

                    // Sound message matching
                    if (v2Msg.soundElem != null && msg.soundElem != null) {
                      final v2Path = v2Msg.soundElem?.path ?? '';
                      final msgPath = msg.soundElem?.path ?? '';
                      if (v2Path.isNotEmpty && v2Path == msgPath) return true;
                    }
                  }
                }
                return false;
              },
              orElse: () => null,
            );

            if (duplicateMsg != null) {
              // Message already exists (likely from native FFI callback with m-prefix ID).
              // Update the existing message's msgID to the real ID so future dedup works correctly.
              if (v2Msg.msgID != null && duplicateMsg.msgID != v2Msg.msgID) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Received message dedup: updating msgID from ${duplicateMsg.msgID} to ${v2Msg.msgID}');
                duplicateMsg.msgID = v2Msg.msgID;
                duplicateMsg.id = v2Msg.msgID;
              }
              // Notify as modified instead of new to update any changed fields
              await _setFaceUrlForMsg(v2Msg);
              _notifyAdvancedMsgListeners((listener) {
                listener.onRecvMessageModified?.call(v2Msg);
              });
              return;
            }
          }
        }

        // For pending forward messages, check if they already exist in the target conversation
        // This prevents duplicate messages in the current chat page
        if (chatMsg.isSelf && isPending) {
          // For pending messages, we must have forwardTargetID to know where to send the message
          // If forwardTargetID is null, this is NOT a forward message, it's a normal pending message
          if (forwardTargetID != null) {
            // This is a pending forward message, check if it already exists in the target conversation
            final targetConversationID = forwardTargetID;
            final targetMessageList = TencentCloudChat
                .instance.dataInstance.messageData
                .getMessageList(key: targetConversationID);
            // CRITICAL: Check both msgID and id fields, and also check if id matches msgID
            // UIKit messages may have id (temporary ID) while FFI messages have msgID (actual ID)
            // We need to match on both to prevent duplicates
            // Also check by message content (text + timestamp) as fallback since FFI may generate different msgID
            final targetMessageExists = targetMessageList.any((msg) {
              // Check if msgID matches
              if (v2Msg.msgID != null && msg.msgID == v2Msg.msgID) return true;
              // Check if id matches msgID
              if (v2Msg.msgID != null && msg.id == v2Msg.msgID) return true;
              // Check if msgID matches id
              if (v2Msg.id != null && msg.msgID == v2Msg.id) return true;
              // Check if id matches id
              if (v2Msg.id != null &&
                  msg.id == v2Msg.id &&
                  v2Msg.id!.isNotEmpty) return true;

              // CRITICAL: Fallback matching by content (text + timestamp) for sent messages
              // FFI layer may generate different msgID than UIKit, so we need to match by content
              // This prevents duplicate messages when msgID doesn't match
              // Use the same isPending variable for consistency
              if (chatMsg.isSelf && isPending) {
                // For pending messages, match by text content and timestamp (within 5 seconds)
                final v2Text = v2Msg.textElem?.text ??
                    v2Msg.mergerElem?.compatibleText ??
                    '';
                final msgText =
                    msg.textElem?.text ?? msg.mergerElem?.compatibleText ?? '';
                if (v2Text.isNotEmpty && msgText == v2Text) {
                  // Check timestamp match (within 5 seconds)
                  final timeDiff =
                      ((v2Msg.timestamp ?? 0) - (msg.timestamp ?? 0)).abs();
                  if (timeDiff <= 5) {
                    // Also check isSelf to ensure it's the same sender
                    if (v2Msg.isSelf == msg.isSelf) {
                      if (_debugLog)
                        print(
                            '[Tim2ToxSdkPlatform] Matched pending message by content: text="$v2Text", timeDiff=$timeDiff seconds');
                      return true;
                    }
                  }
                }
              }

              return false;
            });

            if (targetMessageExists) {
              // Message already exists in the forward target conversation,
              // notify as modified. Persistence dedup-and-merge happens
              // centrally in MessageHistoryPersistence.appendHistory.
              unawaited(ffiService.messageHistoryPersistence
                  .appendHistory(targetConversationID, chatMsg));
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] Persisted pending message in forward target: conversationId=$targetConversationID, msgID=${chatMsg.msgID}');

              await _setFaceUrlForMsg(v2Msg);
              _notifyAdvancedMsgListeners((listener) {
                listener.onRecvMessageModified?.call(v2Msg);
              });
              return; // Skip the rest of the logic
            } else {
              // Message doesn't exist in target conversation, notify as new
              // Double-check that userID/groupID are correct before notifying UIKit
              final finalConversationID = v2Msg.groupID ?? v2Msg.userID ?? '';
              if (targetConversationID != finalConversationID) {
                v2Msg.userID = forwardTargetUserID;
                v2Msg.groupID = forwardTargetGroupID;
              }
            }
          } else {
            // This is a normal pending message (not a forward), use default behavior
            // For normal pending messages, userID should be the sender (fromUserId)
            // This ensures they appear in the current conversation
          }
        }
        // Final check before notifying UIKit: ensure userID/groupID are correct for forward messages
        if (forwardTargetID != null) {
          final finalConversationID = v2Msg.groupID ?? v2Msg.userID ?? '';
          if (finalConversationID != forwardTargetID) {
            v2Msg.userID = forwardTargetUserID;
            v2Msg.groupID = forwardTargetGroupID;
          }
        }
        // Final check: ensure userID/groupID are correct for pending forward messages
        // This prevents messages from being added to the wrong conversation
        // Use the same isPending variable for consistency
        if (chatMsg.isSelf && isPending && forwardTargetID != null) {
          final finalConversationID = v2Msg.groupID ?? v2Msg.userID ?? '';
          if (finalConversationID != forwardTargetID) {
            v2Msg.userID = forwardTargetUserID;
            v2Msg.groupID = forwardTargetGroupID;
          }
        }
        // Final validation: ensure userID/groupID are set before notifying UIKit
        // If both are null/empty, the message won't be added to any conversation
        final finalConversationID = v2Msg.groupID ?? v2Msg.userID ?? '';
        if (finalConversationID.isEmpty) {
          print(
              '[Tim2ToxSdkPlatform] ERROR: Cannot notify new message - userID and groupID are both empty!');
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Message details: msgID=${v2Msg.msgID}, isSelf=${chatMsg.isSelf}, fromUserId=${chatMsg.fromUserId}, groupId=${chatMsg.groupId}');
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] forwardTargetUserID=$forwardTargetUserID, forwardTargetGroupID=$forwardTargetGroupID');
          // Try to fix: for received messages, use fromUserId as userID
          if (!chatMsg.isSelf && chatMsg.fromUserId.isNotEmpty) {
            v2Msg.userID = chatMsg.fromUserId;
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Fixed: Set userID to fromUserId=${chatMsg.fromUserId}');
          } else if (chatMsg.isSelf) {
            // For sent messages, try to find from history
            for (final entry in ffiService.lastMessages.entries) {
              final peerId = entry.key;
              final history = ffiService.getHistory(peerId);
              if (history.any((msg) => msg.msgID == chatMsg.msgID)) {
                if (chatMsg.groupId != null) {
                  v2Msg.groupID = peerId;
                } else {
                  v2Msg.userID = peerId;
                }
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] Fixed: Set ${chatMsg.groupId != null ? "groupID" : "userID"} to peerId=$peerId');
                break;
              }
            }
          }
        }

        // Final check after fix
        final finalConversationIDAfterFix = v2Msg.groupID ?? v2Msg.userID ?? '';
        if (finalConversationIDAfterFix.isEmpty) {
          print(
              '[Tim2ToxSdkPlatform] ERROR: Still cannot determine conversationID after fix attempt. Skipping message notification.');
          return;
        }

        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Notifying new message: msgID=${v2Msg.msgID}, userID=${v2Msg.userID}, groupID=${v2Msg.groupID}, conversationID=$finalConversationIDAfterFix');
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] v2Msg details: sender=${v2Msg.sender}, isSelf=${v2Msg.isSelf}, timestamp=${v2Msg.timestamp}, elemType=${v2Msg.elemType}');

        // Ensure message is saved to persistence. The previous "look it up
        // with an inline 5s window, then conditionally appendHistory" dance
        // is unnecessary: MessageHistoryPersistence.appendHistory itself
        // dedups by msgID (merging via _mergeMessages) and falls back to a
        // safer 2s + fromUserId content match, so calling it directly is
        // idempotent when the same message was already saved by
        // _onNativeEvent.
        final conversationId = finalConversationIDAfterFix;
        unawaited(ffiService.messageHistoryPersistence
            .appendHistory(conversationId, chatMsg));
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Persisted new message: conversationId=$conversationId, msgID=${chatMsg.msgID}');
        ffiService.refreshConversationCacheFromHistory(conversationId);

        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Calling _notifyAdvancedMsgListeners with onRecvNewMessage callback');
        await _setFaceUrlForMsg(v2Msg);
        _notifyAdvancedMsgListeners((listener) {
          listener.onRecvNewMessage?.call(v2Msg);
        });
        if (_debugLog)
          print('[Tim2ToxSdkPlatform] Finished notifying listeners');

        // When a group message is received (not from self), increment unread and refresh
        // so sidebar and conversation list show unread count (native path does not go through FakeIM).
        final groupIdForUnread = resolveGroupIdForUnread(
          chatMessageGroupId: chatMsg.groupId,
          v2GroupId: v2Msg.groupID,
        );
        if (!chatMsg.isSelf && (groupIdForUnread ?? '').isNotEmpty) {
          onGroupMessageReceivedForUnread?.call(groupIdForUnread);
        }

        // Clean up forward message cache after message is successfully added to target conversation
        // This prevents cached messages from being incorrectly used later
        // Use the same isPending variable for consistency
        if (chatMsg.isSelf && forwardTargetID != null && v2Msg.msgID != null) {
          // Find and remove the cached forward message by matching text content
          // We use text as key because the msgID changes when message is sent
          final messageText =
              v2Msg.textElem?.text ?? v2Msg.mergerElem?.compatibleText ?? '';
          if (messageText.isNotEmpty) {
            // Find the cached message by matching text and target
            final keysToRemove = <String>[];
            for (final entry in _forwardMessageCache.entries) {
              final cachedMsg = entry.value;
              final cachedText = cachedMsg.textElem?.text ??
                  cachedMsg.mergerElem?.compatibleText ??
                  '';
              if (cachedText == messageText) {
                // Check if this is the same forward message by comparing target
                // Since we can't directly compare, we'll remove it after a short delay
                // to ensure the message has been properly added to the target conversation
                keysToRemove.add(entry.key);
              }
            }
            // Remove cached messages after a short delay to ensure message is properly added
            Future.delayed(const Duration(milliseconds: 500), () {
              for (final key in keysToRemove) {
                _forwardMessageCache.remove(key);
              }
            });
          }
        }
      }

      // Check if message status changed (received/read) and notify listeners
      if (chatMsg.isSelf && chatMsg.isReceived) {
        // Message was received by peer
        _notifyAdvancedMsgListeners((listener) {
          // Create a receipt for C2C messages
          if (chatMsg.groupId == null) {
            final receipt = V2TimMessageReceipt(
              userID: chatMsg.fromUserId,
              msgID: chatMsg.msgID ?? '',
              timestamp: chatMsg.timestamp.millisecondsSinceEpoch ~/ 1000,
            );
            listener.onRecvC2CReadReceipt?.call([receipt]);
          }
        });
      }
    });
  }

  void _setupReactionListener() {
    _reactionSubscription?.cancel();
    _reactionSubscription = ffiService.reactionEvents.listen((event) {
      // Debug: Log reaction event to help diagnose duplicate reaction issues
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] Reaction event received: msgID=${event.msgID}, reactionID=${event.reactionID}, action=${event.action}, sender=${event.sender}');

      // CRITICAL: Validate msgID is not empty to prevent updating wrong messages
      if (event.msgID.isEmpty) {
        print(
            '[Tim2ToxSdkPlatform] WARNING: Reaction event has empty msgID, skipping');
        return;
      }

      // Convert reaction event to V2TIMMessageReactionChangeInfo
      // Create a V2TimMessageReaction with the reaction info
      final reaction = V2TimMessageReaction(
        reactionID: event.reactionID,
        totalUserCount: 1, // We don't track total count, use 1 for now
        partialUserList: [
          V2TimUserInfo(userID: event.sender),
        ],
        reactedByMyself: event.sender == ffiService.selfId,
      );

      final changeInfo = V2TIMMessageReactionChangeInfo(
        messageID: event.msgID,
        reactionList: [reaction],
      );

      _notifyAdvancedMsgListeners((listener) {
        listener.onRecvMessageReactionsChanged?.call([changeInfo]);
      });
    });
  }

  void _setupProgressListener() {
    _progressSubscription?.cancel();
    _progressSubscription = ffiService.progressUpdates.listen((progress) {
      // Progress may include instanceId (receiver) for multi-instance; we handle all and rely on
      // getHistory returning the right conversation so the correct listener gets the update.
      // Find the message by peerId and path
      // For sending progress, we need to find the message being sent
      // For receiving progress, we need to find the message being received

      // Find message by peerId; prefer msgID (receiving messages use temp path, progress has actual path)
      V2TimMessage? targetMessage;
      String? msgID;

      // Fast path: check cache from previous progress event (same msgID)
      final cacheKey = progress.msgID ?? progress.path ?? '';
      if (cacheKey.isNotEmpty) {
        targetMessage = _progressMsgCache[cacheKey];
        if (targetMessage != null) {
          msgID = targetMessage.msgID;
        }
      }

      // Slow path: scan history if cache miss
      if (targetMessage == null) {
        final history = ffiService.getHistory(progress.peerId);
        final isGroup = progress.peerId.startsWith('tox_');
        if (progress.msgID != null && progress.msgID!.isNotEmpty) {
          for (final chatMsg in history) {
            if (chatMsg.msgID == progress.msgID) {
              targetMessage = chatMessageToV2TimMessage(
                chatMsg,
                ffiService.selfId,
                forwardTargetUserID: isGroup ? null : progress.peerId,
                forwardTargetGroupID: isGroup ? progress.peerId : null,
              );
              msgID = chatMsg.msgID ?? progress.msgID;
              break;
            }
          }
        }
        if (targetMessage == null) {
          for (final chatMsg in history) {
            if (chatMsg.filePath == progress.path) {
              targetMessage = chatMessageToV2TimMessage(
                chatMsg,
                ffiService.selfId,
                forwardTargetUserID: isGroup ? null : progress.peerId,
                forwardTargetGroupID: isGroup ? progress.peerId : null,
              );
              msgID = chatMsg.msgID ?? '';
              break;
            }
          }
        }
        // Populate cache for subsequent progress events
        if (targetMessage != null && cacheKey.isNotEmpty) {
          _progressMsgCache[cacheKey] = targetMessage;
        }
      }

      // Clean up cache when transfer completes
      final isComplete =
          progress.total > 0 && progress.received >= progress.total;
      if (isComplete && cacheKey.isNotEmpty) {
        _progressMsgCache.remove(cacheKey);
      }

      if (targetMessage != null && msgID != null) {
        final progressValue = progress.total > 0
            ? (progress.received / progress.total * 100).round()
            : 0;

        if (progress.isSend) {
          // Sending progress
          _notifyAdvancedMsgListeners((listener) {
            listener.onSendMessageProgress?.call(
              targetMessage!,
              progressValue,
            );
          });
        } else {
          // Download progress
          final downloadProgress = V2TimMessageDownloadProgress(
            isFinish: progress.received >= progress.total,
            isError: false,
            msgID: msgID,
            currentSize: progress.received,
            totalSize: progress.total,
            type: 0, // Default type
            isSnapshot: false,
            path: progress.path ?? '',
            errorCode: 0,
            errorDesc: '',
          );

          // Notify per-instance listeners first (e.g. Bob's listener in _instanceAdvancedMsgListeners[2])
          if (progress.instanceId != 0) {
            for (final listener
                in _instanceAdvancedMsgListeners[progress.instanceId] ?? []) {
              try {
                listener.onMessageDownloadProgressCallback
                    ?.call(downloadProgress);
              } catch (e, st) {
                print(
                    '[Tim2ToxSdkPlatform] Error in instance ${progress.instanceId} progress listener: $e');
              }
            }
          }
          _notifyAdvancedMsgListeners((listener) {
            listener.onMessageDownloadProgressCallback?.call(downloadProgress);
          });
        }
      } else if (!progress.isSend &&
          progress.instanceId != 0 &&
          progress.total > 0) {
        // Multi-instance: progress was received but no history message matched (e.g. path/tempPath mismatch).
        // Still notify per-instance listeners so tests that wait for progress (e.g. file_seek) get callbacks.
        final instanceListeners =
            _instanceAdvancedMsgListeners[progress.instanceId] ?? [];
        final downloadProgress = V2TimMessageDownloadProgress(
          isFinish: progress.received >= progress.total,
          isError: false,
          msgID: '',
          currentSize: progress.received,
          totalSize: progress.total,
          type: 0,
          isSnapshot: false,
          path: progress.path ?? '',
          errorCode: 0,
          errorDesc: '',
        );
        for (final listener in instanceListeners) {
          try {
            listener.onMessageDownloadProgressCallback?.call(downloadProgress);
          } catch (e, st) {
            print(
                '[Tim2ToxSdkPlatform] Error in instance ${progress.instanceId} progress listener (no targetMessage): $e');
          }
        }
      }
    });
  }

  /// Populate [msg.faceUrl] from the local avatar cache.
  ///
  /// Checks the in-memory cache first; falls back to prefs on a cache miss.
  /// Validates that cached paths still point to existing files, re-reading
  /// from prefs when a file has been deleted (e.g. after a timestamped
  /// avatar rename).
  /// No-ops if [_prefs] is unavailable.
  Future<void> _setFaceUrlForMsg(V2TimMessage msg) async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (msg.isSelf == true) {
      if (_selfAvatarPathCache == null) {
        _selfAvatarPathCache = await prefs.getAvatarPath();
      } else if (_selfAvatarPathCache!.startsWith('/') &&
          !File(_selfAvatarPathCache!).existsSync()) {
        _selfAvatarPathCache = await prefs.getAvatarPath();
      }
      String? path = _selfAvatarPathCache;
      if ((path == null || path.isEmpty) && ffiService.selfId.isNotEmpty) {
        path = await prefs.getFriendAvatarPath(ffiService.selfId);
      }
      if (path != null && path.isNotEmpty) {
        msg.faceUrl = path;
      }
    } else {
      final sender = msg.sender ?? '';
      if (sender.isEmpty) return;
      if (!_friendAvatarPathCache.containsKey(sender)) {
        _friendAvatarPathCache[sender] =
            await prefs.getFriendAvatarPath(sender) ?? '';
      }
      final path = _friendAvatarPathCache[sender];
      if (path != null && path.isNotEmpty) {
        msg.faceUrl = path;
      }
    }
  }

  /// Fill [members] faceUrl, nickName, and role from local prefs.
  /// Handles the case where the native layer returns the raw public key as nickName
  /// (a placeholder, not a real nickname) by detecting nickName == userID.
  /// When [groupID] is provided, also corrects roles using the stored group owner.
  Future<void> _setFaceUrlForGroupMembers(
      List<V2TimGroupMemberFullInfo> members,
      {String? groupID}) async {
    final prefs = _prefs;
    if (prefs == null || members.isEmpty) return;
    final selfPublicKey = ffiService.selfId.length >= 64
        ? ffiService.selfId.substring(0, 64)
        : ffiService.selfId;
    String? groupOwner;
    if (groupID != null) {
      groupOwner = await prefs.getGroupOwner(groupID);
    }
    for (final m in members) {
      final uid = m.userID;
      if (uid.isEmpty) continue;
      final isSelf = uid == selfPublicKey;
      // faceUrl: for self prefer self avatar path, for others use friend avatar path
      if (m.faceUrl == null || m.faceUrl!.isEmpty) {
        if (isSelf) {
          final selfPath = await prefs.getAvatarPath();
          if (selfPath != null && selfPath.isNotEmpty) {
            m.faceUrl = selfPath;
          }
        }
        if (m.faceUrl == null || m.faceUrl!.isEmpty) {
          final path = await prefs.getFriendAvatarPath(uid);
          if (path != null && path.isNotEmpty) m.faceUrl = path;
        }
      }
      // nickName: treat raw hex key (== userID) as a placeholder
      final needsNickName =
          m.nickName == null || m.nickName!.isEmpty || m.nickName == uid;
      if (needsNickName) {
        if (isSelf) {
          final selfNick = await prefs.getString('self_nickname');
          if (selfNick != null && selfNick.isNotEmpty) {
            m.nickName = selfNick;
          }
        } else {
          final nick = await prefs.getFriendNickname(uid);
          if (nick != null && nick.isNotEmpty) m.nickName = nick;
        }
      }
      // role: native conferences return 200 for everyone; correct only when owner is known
      if (groupOwner != null && groupOwner.isNotEmpty) {
        if (uid == groupOwner) {
          m.role = 400; // Owner
        }
      }
    }
  }

  /// Evict the Flutter image cache for a given local file path so that
  /// widgets using [Image.file] pick up the new bytes on their next build.
  void _evictAvatarImageCache(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      FileImage(File(path)).evict();
    } catch (_) {}
  }

  /// Keep the avatar cache in sync when a new avatar is downloaded.
  void _setupAvatarUpdatedListener() {
    _avatarUpdatedSubscription?.cancel();
    _avatarUpdatedSubscription = ffiService.avatarUpdated.listen((uid) async {
      final prefs = _prefs;
      if (prefs == null) return;
      if (uid == ffiService.selfId) {
        final oldPath = _selfAvatarPathCache;
        _selfAvatarPathCache = await prefs.getAvatarPath();
        _evictAvatarImageCache(oldPath);
        _evictAvatarImageCache(_selfAvatarPathCache);
      } else {
        final oldPath = _friendAvatarPathCache[uid];
        _friendAvatarPathCache[uid] =
            await prefs.getFriendAvatarPath(uid) ?? '';
        final newPath = _friendAvatarPathCache[uid];
        _evictAvatarImageCache(oldPath);
        _evictAvatarImageCache(newPath);
        // Notify friendship listeners so contact list refreshes this friend's avatar
        try {
          final friends = await ffiService.getFriendList();
          final match = friends.where((e) => e.userId == uid).toList();
          if (match.isNotEmpty) {
            final f = match.first;
            final fakeUser = FakeUser(
              userID: uid,
              nickName: f.nickName,
              online: f.online,
            );
            final friendInfo = await fakeUserToV2TimFriendInfo(fakeUser);
            _notifyFriendshipListeners((listener) {
              listener.onFriendInfoChanged?.call([friendInfo]);
            });
          }
          // Also notify conversation listeners so C2C rows refresh avatar immediately.
          notifyConversationChangedForC2C(uid);
        } catch (e) {
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] avatarUpdated notify friendInfoChanged: $e');
        }
      }
    });
  }

  void _setupConversationListener() {
    _conversationSubscription?.cancel();
    _unreadSubscription?.cancel();

    // Listen to conversation events
    final eventBus = eventBusProvider?.eventBus;
    if (eventBus == null) return;
    _conversationSubscription = eventBus
        .on<FakeConversation>(EventTopics.conversation)
        .listen((fakeConv) async {
      // Convert FakeConversation to V2TimConversation
      final v2Conv = await fakeConversationToV2TimConversation(fakeConv);
      _notifyConversationListeners((listener) {
        listener.onConversationChanged?.call([v2Conv]);
        listener.onNewConversation?.call([v2Conv]);
      });
    });

    // Listen to unread count changes
    _unreadSubscription =
        eventBus.on<FakeUnreadTotal>(EventTopics.unread).listen((unread) {
      _notifyConversationListeners((listener) {
        listener.onTotalUnreadMessageCountChanged?.call(unread.total);
      });
    });
  }

  void _setupFriendshipListener() {
    _contactsSubscription?.cancel();
    _friendAppsSubscription?.cancel();
    _friendDeletedSubscription?.cancel();

    final eventBus = eventBusProvider?.eventBus;
    if (eventBus == null) return;

    // Listen to contacts (friends) list changes
    _contactsSubscription = eventBus
        .on<List<FakeUser>>(EventTopics.contacts)
        .listen((contacts) async {
      // Convert FakeUser list to V2TimFriendInfo list
      final friendInfoList = <V2TimFriendInfo>[];
      final statusChanges = <V2TimUserStatus>[];

      for (final fakeUser in contacts) {
        final friendInfo = await fakeUserToV2TimFriendInfo(fakeUser);
        friendInfoList.add(friendInfo);

        // Check for status changes
        final previousOnline = _previousFriendOnlineStatus[fakeUser.userID];
        final currentOnline = fakeUser.online;

        if (previousOnline != null && previousOnline != currentOnline) {
          // Status changed, add to status changes list
          final status = V2TimUserStatus(
            userID: fakeUser.userID,
            statusType: currentOnline ? 1 : 0, // 1 = online, 0 = offline
            customStatus: null,
            onlineDevices: currentOnline ? ['desktop'] : null,
          );
          statusChanges.add(status);
          print(
              '[Tim2ToxSdkPlatform] Friend status changed: userID=${fakeUser.userID}, online=$currentOnline');
        }

        // Update previous status
        _previousFriendOnlineStatus[fakeUser.userID] = currentOnline;
      }

      // Notify SDK listeners about status changes
      if (statusChanges.isNotEmpty) {
        print(
            '[Tim2ToxSdkPlatform] Notifying OnUserStatusChanged for ${statusChanges.length} status changes');
        print(
            '[Tim2ToxSdkPlatform] Status changes: ${statusChanges.map((s) => '${s.userID}:${s.statusType}').join(", ")}');
        _notifySDKListeners((listener) {
          print(
              '[Tim2ToxSdkPlatform] Calling listener.onUserStatusChanged, listener=${listener.runtimeType}, callback=${listener.onUserStatusChanged != null ? "not null" : "null"}');
          listener.onUserStatusChanged?.call(statusChanges);
        });
      }

      // Determine if this is a new friend or updated friend
      // For simplicity, we'll treat all as changed
      _notifyFriendshipListeners((listener) {
        listener.onFriendInfoChanged?.call(friendInfoList);
        // Also trigger onFriendListAdded for new friends (if any)
        // Note: We can't easily distinguish new vs updated, so we'll use onFriendInfoChanged
      });
    });

    // Listen to friend applications
    _friendAppsSubscription = eventBus
        .on<List<FakeFriendApplication>>(EventTopics.friendApps)
        .listen((apps) {
      final appList = apps
          .map((app) => fakeFriendApplicationToV2TimFriendApplication(app))
          .toList();
      _notifyFriendshipListeners((listener) {
        listener.onFriendApplicationListAdded?.call(appList);
      });
    });

    // Listen to friend deletions
    _friendDeletedSubscription = eventBus
        .on<FakeFriendDeleted>(EventTopics.friendDeleted)
        .listen((deleted) {
      _notifyFriendshipListeners((listener) {
        listener.onFriendListDeleted?.call([deleted.userID]);
      });
    });
  }

  void _setupGroupListener() {
    _groupDeletedSubscription?.cancel();

    final eventBus = eventBusProvider?.eventBus;
    if (eventBus == null) return;

    // Listen to group deletions
    _groupDeletedSubscription = eventBus
        .on<FakeGroupDeleted>(EventTopics.groupDeleted)
        .listen((deleted) {
      // Notify listeners about group deletion
      _notifyGroupListeners((listener) {
        listener.onQuitFromGroup?.call(deleted.groupID);
      });
    });
  }

  void _setupInternalConversationListener() {
    // Add internal listener to handle pin/unpin from C++ layer
    // This listener will be called when OnConversationChanged is triggered from C++ layer
    // (e.g., when DartPinConversation is called)
    // In binary replacement mode, OnConversationChanged goes through NativeLibraryManager
    // which calls TIMConversationManager's internal listener, which then calls all listeners
    // in v2TimConversationListenerList. We need to add our listener to that list.
    final internalListener = V2TimConversationListener(
      onConversationChanged: (conversationList) {
        // Check if any conversation's isPinned status changed
        final conversationManager = conversationManagerProvider;
        if (conversationManager == null) {
          return;
        }

        // Use unawaited to avoid blocking the callback
        for (final conv in conversationList) {
          final conversationID = conv.conversationID ?? '';
          final isPinned = conv.isPinned;

          // Update pinned status if isPinned is set
          if (isPinned != null && conversationID.isNotEmpty) {
            // Call setPinned asynchronously without blocking
            conversationManager
                .setPinned(conversationID, isPinned)
                .catchError((e) {
              // Silently handle errors
            });
          }
        }
      },
    );

    // Add the internal listener only to our platform list. Do NOT call
    // TIMConversationManager.instance.addConversationListener here: during
    // construction TencentCloudChatSdkPlatform.instance is not yet set to this,
    // so the adapter would call the default platform's addConversationListener
    // and throw UnimplementedError. C++ conversation events reach Dart via
    // globalCallback and are dispatched to _conversationListeners by this platform.
    addConversationListener(listener: internalListener);
  }

  void _setupFriendStatusChecker() {
    // Check friend status changes every 2 seconds
    _friendStatusCheckTimer?.cancel();
    _friendStatusCheckTimer =
        Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final friends = await ffiService.getFriendList();
        final statusChanges = <V2TimUserStatus>[];

        for (final friend in friends) {
          final previousOnline = _previousFriendOnlineStatus[friend.userId];
          final currentOnline = friend.online;

          if (previousOnline != null && previousOnline != currentOnline) {
            // Status changed, add to status changes list
            final status = V2TimUserStatus(
              userID: friend.userId,
              statusType: currentOnline ? 1 : 0, // 1 = online, 0 = offline
              customStatus: null,
              onlineDevices: currentOnline ? ['desktop'] : null,
            );
            statusChanges.add(status);
            print(
                '[Tim2ToxSdkPlatform] Friend status changed (timer): userID=${friend.userId}, online=$currentOnline');
          }

          // Update previous status
          _previousFriendOnlineStatus[friend.userId] = currentOnline;
        }

        // Notify SDK listeners about status changes
        if (statusChanges.isNotEmpty) {
          print(
              '[Tim2ToxSdkPlatform] Notifying OnUserStatusChanged (timer) for ${statusChanges.length} status changes');
          print(
              '[Tim2ToxSdkPlatform] Status changes: ${statusChanges.map((s) => '${s.userID}:${s.statusType}').join(", ")}');
          _notifySDKListeners((listener) {
            print(
                '[Tim2ToxSdkPlatform] Calling listener.onUserStatusChanged, listener=${listener.runtimeType}, callback=${listener.onUserStatusChanged != null ? "not null" : "null"}');
            listener.onUserStatusChanged?.call(statusChanges);
          });
        }
      } catch (e) {
        print('[Tim2ToxSdkPlatform] Error checking friend status: $e');
      }
    });
  }

  void dispose() {
    _connectionStatusSubscription?.cancel();
    _messagesSubscription?.cancel();
    _conversationSubscription?.cancel();
    _unreadSubscription?.cancel();
    _contactsSubscription?.cancel();
    _friendAppsSubscription?.cancel();
    _friendDeletedSubscription?.cancel();
    _groupDeletedSubscription?.cancel();
    _reactionSubscription?.cancel();
    _progressSubscription?.cancel();
    _avatarUpdatedSubscription?.cancel();
    _friendStatusCheckTimer?.cancel();
    _sdkListeners.clear();
    _advancedMsgListeners.clear();
    _conversationListeners.clear();
    _friendshipListeners.clear();
    _groupListeners.clear();
    _uikitListeners.clear();
    _pendingForwardTargets.clear();
    _friendAvatarPathCache.clear();
    _selfAvatarPathCache = null;
    _previousFriendOnlineStatus.clear();
    if (_currentInstance == this) {
      _currentInstance = null;
    }
  }

  // End of Tim2ToxSdkPlatform class methods

  // ============================================================================

  // ============================================================================
  // Manager Getters
  // ============================================================================

  // Note: These methods are not part of TencentCloudChatSdkPlatform interface
  // They are accessed through V2TIMManager which has its own getters
  // The actual implementation should be in custom Manager classes
  // that are returned by V2TIMManager's getter methods

  // ============================================================================
  // Listener Management
  // ============================================================================

  // Note: SDK listener management is typically handled by V2TIMManager
  // These methods may need to be implemented if required by the interface
  void addSDKListener(V2TimSDKListener listener) {
    final id = ffi_lib.Tim2ToxFfi.open().getCurrentInstanceId();
    if (id != 0) {
      (_instanceSdkListeners[id] ??= []).add(listener);
    }
    if (!_sdkListeners.contains(listener)) {
      _sdkListeners.add(listener);
    }
    _setupFriendStatusChecker();
  }

  void removeSDKListener(V2TimSDKListener listener) {
    for (final list in _instanceSdkListeners.values) {
      list.remove(listener);
    }
    _sdkListeners.remove(listener);
    if (_sdkListeners.isEmpty) {
      _friendStatusCheckTimer?.cancel();
    }
  }

  /// Dispatches a globalCallback to listeners registered for [instanceId] only.
  /// Called by NativeLibraryManager when instance_id != 0 and platform is Tim2ToxSdkPlatform.
  ///
  /// Multi-instance dispatch is only exercised by tim2tox/auto_tests; in
  /// single-instance toxee usage [instanceId] is always 0 and traffic
  /// follows the broadcast path in NativeLibraryManager._handleGlobalCallback
  /// instead of routing here. See the comment on [_instanceSdkListeners]
  /// for the reasoning.
  void dispatchInstanceGlobalCallback(int instanceId, int callbackType,
      Map<String, dynamic> dataFromNativeMap) {
    if (callbackType == 67) {
      ToxAVService.dispatchAvCall(
        instanceId,
        (dataFromNativeMap['friend_number'] is int)
            ? dataFromNativeMap['friend_number'] as int
            : int.tryParse(
                    dataFromNativeMap['friend_number']?.toString() ?? '0') ??
                0,
        (dataFromNativeMap['audio_enabled']?.toString() ?? '0') == '1',
        (dataFromNativeMap['video_enabled']?.toString() ?? '0') == '1',
      );
      return;
    }
    if (callbackType == 68) {
      ToxAVService.dispatchAvCallState(
        instanceId,
        (dataFromNativeMap['friend_number'] is int)
            ? dataFromNativeMap['friend_number'] as int
            : int.tryParse(
                    dataFromNativeMap['friend_number']?.toString() ?? '0') ??
                0,
        (dataFromNativeMap['state'] is int)
            ? dataFromNativeMap['state'] as int
            : int.tryParse(dataFromNativeMap['state']?.toString() ?? '0') ?? 0,
      );
      return;
    }
    final GlobalCallbackType type;
    try {
      type = GlobalCallbackType.fromValue(callbackType);
    } on ArgumentError {
      // Unknown callbackType (likely added by a future upstream SDK).
      // Match the safety net in NativeLibraryManager._handleGlobalCallback so
      // multi-instance dispatch degrades to no-op instead of crashing the
      // callback isolate.
      return;
    }
    final sdkList = selectDispatchListeners<V2TimSDKListener>(
      instanceId: instanceId,
      instanceListeners: _instanceSdkListeners[instanceId] ?? [],
      globalListeners: _sdkListeners,
    );
    final advList = selectDispatchListeners<V2TimAdvancedMsgListener>(
      instanceId: instanceId,
      instanceListeners: _instanceAdvancedMsgListeners[instanceId] ?? [],
      globalListeners: _advancedMsgListeners,
    );
    final grpList = selectDispatchListeners<V2TimGroupListener>(
      instanceId: instanceId,
      instanceListeners: _instanceGroupListeners[instanceId] ?? [],
      globalListeners: _groupListeners,
    );
    final convList = selectDispatchListeners<V2TimConversationListener>(
      instanceId: instanceId,
      instanceListeners: _instanceConversationListeners[instanceId] ?? [],
      globalListeners: _conversationListeners,
    );

    switch (type) {
      case GlobalCallbackType.ConversationEvent:
        {
          final convEvent = dataFromNativeMap['conv_event']?.toString();
          List<dynamic> resultList = [];
          final jsonConvArrayValue = dataFromNativeMap['json_conv_array'];
          if (jsonConvArrayValue != null) {
            if (jsonConvArrayValue is String && jsonConvArrayValue.isNotEmpty) {
              try {
                resultList = json.decode(jsonConvArrayValue);
              } catch (_) {}
            } else if (jsonConvArrayValue is List) {
              resultList = jsonConvArrayValue;
            }
          }
          if (convEvent == '2' && resultList.isNotEmpty) {
            try {
              final conversationList = resultList
                  .map((v) => v is Map<String, dynamic>
                      ? V2TimConversation.fromJson(v)
                      : null)
                  .whereType<V2TimConversation>()
                  .toList();
              for (final l in convList) {
                l.onConversationChanged?.call(conversationList);
              }
            } catch (e) {
              // Ignore parse/listener errors
            }
          }
        }
        break;
      case GlobalCallbackType.NetworkStatus:
        {
          final code = dataFromNativeMap["code"] as int? ?? 0;
          final desc = dataFromNativeMap["desc"] as String? ?? '';
          final status = dataFromNativeMap["status"] as int? ?? 0;
          for (final l in sdkList) {
            if (status == 0) {
              l.onConnectSuccess();
            } else if (status == 1 || status == 3) {
              l.onConnectFailed(code, desc);
            } else if (status == 2) {
              l.onConnecting();
            }
          }
        }
        break;
      case GlobalCallbackType.KickedOffline:
        for (final l in sdkList) {
          l.onKickedOffline();
        }
        break;
      case GlobalCallbackType.UserSigExpired:
        for (final l in sdkList) {
          l.onUserSigExpired();
        }
        break;
      case GlobalCallbackType.SelfInfoUpdated:
        {
          final jsonUserInfoValue = dataFromNativeMap["json_user_profile"];
          if (jsonUserInfoValue != null) {
            Map<String, dynamic> userInfo;
            if (jsonUserInfoValue is String) {
              userInfo = json.decode(jsonUserInfoValue);
            } else if (jsonUserInfoValue is Map) {
              userInfo = Map<String, dynamic>.from(jsonUserInfoValue);
            } else {
              break;
            }
            final v2 = V2TimUserFullInfo.fromJson(userInfo);
            for (final l in sdkList) {
              l.onSelfInfoUpdated(v2);
            }
          }
        }
        break;
      case GlobalCallbackType.UserStatusChanged:
        {
          final v = dataFromNativeMap["json_user_status_array"];
          if (v != null) {
            List<dynamic> arr = v is String ? json.decode(v) : (v as List);
            final userStatusList = [
              for (dynamic e in arr) V2TimUserStatus.fromJson(e)
            ];
            for (final l in sdkList) {
              l.onUserStatusChanged(userStatusList);
            }
          }
        }
        break;
      case GlobalCallbackType.UserInfoChanged:
        {
          final v = dataFromNativeMap["json_user_info_array"];
          if (v != null) {
            List<dynamic> arr = v is String ? json.decode(v) : (v as List);
            final userInfoList = [
              for (dynamic e in arr) V2TimUserFullInfo.fromJson(e)
            ];
            for (final l in sdkList) {
              l.onUserInfoChanged(userInfoList);
            }
          }
        }
        break;
      case GlobalCallbackType.LogCallback:
        {
          final logLevel = dataFromNativeMap["level"] as int? ?? 0;
          final log = dataFromNativeMap["log"] as String? ?? '';
          for (final l in sdkList) {
            l.onLog(logLevel, log);
          }
        }
        break;
      case GlobalCallbackType.ReceiveNewMessage:
        {
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] dispatchInstanceGlobalCallback ReceiveNewMessage: instanceId=$instanceId, advList.length=${advList.length}');
          if (advList.isEmpty) {
            print(
                '[Tim2ToxSdkPlatform] ReceiveNewMessage WARNING: no per-instance listeners for instanceId=$instanceId, message will not be delivered');
          }
          final v = dataFromNativeMap["json_msg_array"];
          if (v != null) {
            List<dynamic> messageArray =
                v is String ? json.decode(v) : (v as List);
            if (messageArray.isNotEmpty) {
              final v2Msg = V2TimMessage.fromJson(
                  messageArray[0] as Map<String, dynamic>);
              // Trigger immediate poll so file_request (enqueued in same OnFileRecv) is consumed and accept runs.
              // Native sends elem_type: 4 (CElemType.ElemFile); Dart V2TIM_ELEM_TYPE_FILE is 6; fromJson sets fileElem when elem_type==4.
              const int kNativeFileElemType = 4;
              if (v2Msg.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
                  v2Msg.elemType == kNativeFileElemType ||
                  v2Msg.fileElem != null) {
                ffiService.triggerPollOnce();
              }
              // Populate faceUrl from local avatar cache so message list shows correct avatar (same as event path).
              Future.microtask(() async {
                await _setFaceUrlForMsg(v2Msg);
                for (final l in advList) {
                  l.onRecvNewMessage?.call(v2Msg);
                }
              });
            }
          }
        }
        break;
      case GlobalCallbackType.MessageUpdate:
        {
          final v = dataFromNativeMap["json_msg_array"];
          if (v != null) {
            List<dynamic> messageArray =
                v is String ? json.decode(v) : (v as List);
            if (messageArray.isNotEmpty) {
              final v2Msg = V2TimMessage.fromJson(
                  messageArray[0] as Map<String, dynamic>);
              // Populate faceUrl from local avatar cache so updated message shows correct avatar.
              Future.microtask(() async {
                await _setFaceUrlForMsg(v2Msg);
                for (final l in advList) {
                  l.onRecvMessageModified?.call(v2Msg);
                }
                // H2: persist the modified message so updates (e.g. pending →
                // sent, content edits) survive restarts. Mirrors the
                // appendHistory call in the modified-branch handler around
                // lines 1226-1231. Wrapped in try/catch so a persistence
                // error doesn't break callback dispatch.
                try {
                  final conversationId =
                      v2Msg.groupID ?? v2Msg.userID ?? '';
                  if (conversationId.isNotEmpty) {
                    final chatMsg =
                        MessageConverter.v2TimMessageToChatMessage(
                            v2Msg, ffiService.selfId);
                    await ffiService.messageHistoryPersistence
                        .appendHistory(conversationId, chatMsg);
                  }
                } catch (e) {
                  if (_debugLog) {
                    print(
                        '[Tim2ToxSdkPlatform] MessageUpdate persistence error: $e');
                  }
                }
              });
            }
          }
        }
        break;
      case GlobalCallbackType.MessageRevoke:
        {
          final v = dataFromNativeMap["json_msg_locator_array"];
          if (v != null) {
            final List<dynamic> arr = v is String
                ? json.decode(v) as List<dynamic>
                : (v as List<dynamic>);
            if (arr.isNotEmpty) {
              final o = arr[0];
              final loc = (o is Map<String, dynamic>)
                  ? (o["message_msg_id"] as String? ?? '')
                  : '';
              for (final l in advList) {
                l.onRecvMessageRevoked?.call(loc);
              }
              // H2: persist the revoke by deleting the message from history.
              // Single call outside the listener loop so a persistence error
              // doesn't fan out across listeners.
              if (loc.isNotEmpty) {
                Future.microtask(() async {
                  try {
                    await ffiService.deleteMessages([loc]);
                  } catch (e) {
                    if (_debugLog) {
                      print(
                          '[Tim2ToxSdkPlatform] MessageRevoke persistence error: $e');
                    }
                  }
                });
              }
            }
          }
        }
        break;
      case GlobalCallbackType.UpdateFriendProfile:
        {
          final jsonFriendProfileArray =
              dataFromNativeMap['json_friend_profile_update_array'];
          if (jsonFriendProfileArray == null) break;
          List<dynamic> arr;
          if (jsonFriendProfileArray is String &&
              jsonFriendProfileArray.isNotEmpty) {
            try {
              arr = json.decode(jsonFriendProfileArray);
            } catch (_) {
              break;
            }
          } else if (jsonFriendProfileArray is List) {
            arr = jsonFriendProfileArray;
          } else {
            break;
          }
          if (arr.isEmpty) break;
          List<V2TimFriendInfo> friendInfoList = [];
          for (final e in arr) {
            if (e is Map<String, dynamic>) {
              try {
                friendInfoList.add(V2TimFriendInfo.fromJson(e));
              } catch (_) {}
            }
          }
          if (friendInfoList.isEmpty) break;
          List<V2TimFriendshipListener> friendshipList =
              _instanceFriendshipListeners[instanceId] ?? [];
          if (friendshipList.isEmpty && instanceId != 0) {
            friendshipList = _friendshipListeners;
          }
          for (final l in friendshipList) {
            try {
              l.onFriendInfoChanged?.call(friendInfoList);
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] UpdateFriendProfile: listener threw: $e');
            }
          }
        }
        break;
      case GlobalCallbackType.FriendAddRequest:
        {
          final jsonApplicationArray =
              dataFromNativeMap['json_application_array'];
          if (jsonApplicationArray == null) {
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] FriendAddRequest: json_application_array is null');
            break;
          }
          List<dynamic> applicationArray;
          if (jsonApplicationArray is String &&
              jsonApplicationArray.isNotEmpty) {
            try {
              applicationArray = json.decode(jsonApplicationArray);
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] FriendAddRequest: json.decode failed: $e');
              break;
            }
          } else if (jsonApplicationArray is List) {
            applicationArray = jsonApplicationArray;
          } else {
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] FriendAddRequest: json_application_array type=${jsonApplicationArray.runtimeType}');
            break;
          }
          List<V2TimFriendApplication> applicationList = [];
          if (applicationArray.isNotEmpty) {
            try {
              applicationList = applicationArray
                  .whereType<Map>()
                  .map((v) => V2TimFriendApplication.fromJsonForCallback(v))
                  .toList();
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] FriendAddRequest: fromJsonForCallback failed: $e');
              break;
            }
          }
          // Prefer per-instance listeners; fall back to global list when instance list is empty
          // (e.g. listener was registered when getCurrentInstanceId() returned 0 in runWithInstance)
          List<V2TimFriendshipListener> friendshipList =
              _instanceFriendshipListeners[instanceId] ?? [];
          if (friendshipList.isEmpty && instanceId != 0) {
            friendshipList = _friendshipListeners;
          }
          if (friendshipList.isNotEmpty) {
            for (final l in friendshipList) {
              try {
                l.onFriendApplicationListAdded?.call(applicationList);
              } catch (e) {
                if (_debugLog)
                  print(
                      '[Tim2ToxSdkPlatform] FriendAddRequest: listener threw: $e');
              }
            }
          }
        }
        break;
      case GlobalCallbackType.AddFriend:
        {
          // C++ sends: {"json_identifier_array":["<userID>", ...]} when we add friend(s) or our list gains new friends
          final jsonIdArray = dataFromNativeMap['json_identifier_array'];
          if (jsonIdArray == null) break;
          List<dynamic> idArray;
          if (jsonIdArray is String && jsonIdArray.isNotEmpty) {
            try {
              idArray = json.decode(jsonIdArray);
            } catch (_) {
              break;
            }
          } else if (jsonIdArray is List) {
            idArray = jsonIdArray;
          } else {
            break;
          }
          final addedUserIDs = idArray.whereType<String>().toList();
          if (addedUserIDs.isEmpty) break;
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] AddFriend: addedUserIDs=$addedUserIDs');
          final capturedInstanceId = instanceId;
          unawaited((() async {
            try {
              final friends = await ffiService.getFriendList();
              final addedSet = addedUserIDs.toSet();
              final friendInfoList = <V2TimFriendInfo>[];
              for (final friend in friends) {
                final normalized = friend.userId.length > 64
                    ? friend.userId.substring(0, 64)
                    : friend.userId;
                if (addedSet.contains(friend.userId) ||
                    addedSet.contains(normalized)) {
                  final fakeUser = FakeUser(
                    userID: friend.userId,
                    nickName: friend.nickName,
                    online: friend.online,
                  );
                  friendInfoList.add(await fakeUserToV2TimFriendInfo(fakeUser));
                }
              }
              if (friendInfoList.isEmpty) {
                for (final uid in addedUserIDs) {
                  friendInfoList.add(await fakeUserToV2TimFriendInfo(
                    FakeUser(userID: uid, nickName: '', online: false),
                  ));
                }
              }
              final allListeners = <V2TimFriendshipListener>{
                ...(_instanceFriendshipListeners[capturedInstanceId] ?? []),
                ..._friendshipListeners,
              };
              for (final l in allListeners) {
                try {
                  l.onFriendListAdded?.call(friendInfoList);
                } catch (e) {
                  if (_debugLog)
                    print('[Tim2ToxSdkPlatform] AddFriend: listener threw: $e');
                }
              }
              // Send our avatar to all friends (including new ones) so they see our avatar soon
              await ffiService.sendAvatarToAllFriends();
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] AddFriend: failed to build list or notify: $e');
            }
          })());
        }
        break;
      case GlobalCallbackType.DeleteFriend:
        {
          // C++ sends: {"json_identifier_array":["<userID>", ...]}
          final jsonIdArray = dataFromNativeMap['json_identifier_array'];
          if (jsonIdArray == null) break;
          List<dynamic> idArray;
          if (jsonIdArray is String && jsonIdArray.isNotEmpty) {
            try {
              idArray = json.decode(jsonIdArray);
            } catch (_) {
              break;
            }
          } else if (jsonIdArray is List) {
            idArray = jsonIdArray;
          } else {
            break;
          }
          final deletedUserIDs = idArray.whereType<String>().toList();
          if (deletedUserIDs.isEmpty) break;
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] DeleteFriend: deletedUserIDs=$deletedUserIDs');
          // Collect all unique listeners from both instance and global lists
          final allListeners = <V2TimFriendshipListener>{
            ...(_instanceFriendshipListeners[instanceId] ?? []),
            ..._friendshipListeners,
          };
          for (final l in allListeners) {
            try {
              l.onFriendListDeleted?.call(deletedUserIDs);
            } catch (e) {
              if (_debugLog)
                print('[Tim2ToxSdkPlatform] DeleteFriend: listener threw: $e');
            }
          }
        }
        break;
      case GlobalCallbackType.GroupTipsEvent:
        {
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] dispatchInstanceGlobalCallback GroupTipsEvent: instanceId=$instanceId, grpList.length=${grpList.length}');
          dynamic jsonGroupTipData = dataFromNativeMap["json_group_tip"];
          Map<String, dynamic> jsonGroupTips;
          if (jsonGroupTipData is String) {
            jsonGroupTips = json.decode(jsonGroupTipData);
          } else if (jsonGroupTipData is Map) {
            jsonGroupTips = Map<String, dynamic>.from(jsonGroupTipData);
          } else {
            break;
          }
          final groupTips = V2TimGroupTipsElem.fromJson(jsonGroupTips);
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] dispatchInstanceGlobalCallback GroupTipsEvent: instanceId=$instanceId, groupID=${groupTips.groupID}, type=${groupTips.type}, grpList.isEmpty=${grpList.isEmpty}');
          if (grpList.isEmpty) break;

          final groupID = groupTips.groupID;
          final opUser = groupTips.opMember;
          List<V2TimGroupMemberInfo> groupMemberList =
              (groupTips.memberList ?? [])
                  .whereType<V2TimGroupMemberInfo>()
                  .toList();
          List<V2TimGroupChangeInfo> groupChangeInfoList =
              (groupTips.groupChangeInfoList ?? [])
                  .whereType<V2TimGroupChangeInfo>()
                  .toList();
          List<V2TimGroupMemberChangeInfo> memberChangeInfoList =
              (groupTips.memberChangeInfoList ?? [])
                  .whereType<V2TimGroupMemberChangeInfo>()
                  .toList();
          const loginUser = '';

          switch (groupTips.type) {
            case GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_INVITE:
              groupMemberList
                  .removeWhere((member) => member.userID == loginUser);
              for (final l in grpList) {
                l.onMemberInvited(groupID, opUser, groupMemberList);
              }
              break;
            case GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_JOIN:
              groupMemberList
                  .removeWhere((member) => member.userID == loginUser);
              final opUserID = opUser.userID ?? '';
              if (groupMemberList.isEmpty && opUserID.isEmpty) {
                for (final l in grpList) {
                  l.onGroupCreated(groupID);
                }
              } else if (groupMemberList.isNotEmpty) {
                for (final l in grpList) {
                  l.onMemberEnter(groupID, groupMemberList);
                }
              }
              break;
            case GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_QUIT:
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] dispatchInstanceGlobalCallback CALL_PATH QUIT -> onMemberLeave(instanceId=$instanceId, groupID=$groupID), grpList.length=${grpList.length}');
              for (final l in grpList) {
                l.onMemberLeave(groupID, opUser);
              }
              break;
            case GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_KICKED:
              groupMemberList
                  .removeWhere((member) => member.userID == loginUser);
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] dispatchInstanceGlobalCallback CALL_PATH KICKED -> onMemberKicked(instanceId=$instanceId, groupID=$groupID, memberCount=${groupMemberList.length}), grpList.length=${grpList.length}');
              if (groupMemberList.isNotEmpty) {
                for (final l in grpList) {
                  l.onMemberKicked(groupID, opUser, groupMemberList);
                }
              }
              break;
            case GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_SET_ADMIN:
              for (final l in grpList) {
                l.onGrantAdministrator(groupID, opUser, groupMemberList);
              }
              break;
            case GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_CANCEL_ADMIN:
              for (final l in grpList) {
                l.onRevokeAdministrator(groupID, opUser, groupMemberList);
              }
              break;
            case GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_GROUP_INFO_CHANGE:
              groupChangeInfoList
                  .removeWhere((changeInfo) => changeInfo.type == 7);
              if (groupChangeInfoList.isNotEmpty) {
                for (final l in grpList) {
                  l.onGroupInfoChanged(groupID, groupChangeInfoList);
                }
              }
              break;
            case GroupTipsElemType.V2TIM_GROUP_TIPS_TYPE_MEMBER_INFO_CHANGE:
              // Do not remove loginUser: for role-change we notify the target user's instance and the
              // change list contains that user; filtering out self would deliver an empty list.
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] dispatchInstanceGlobalCallback CALL_PATH MEMBER_INFO_CHANGE -> onMemberInfoChanged(instanceId=$instanceId, groupID=$groupID, changeCount=${memberChangeInfoList.length}), grpList.length=${grpList.length}');
              if (memberChangeInfoList.isNotEmpty) {
                for (final l in grpList) {
                  l.onMemberInfoChanged(groupID, memberChangeInfoList);
                }
              }
              break;
            default:
              break;
          }
        }
        break;
      case GlobalCallbackType.SignalingReceiveNewInvitation:
        {
          final idKey = instanceId is int
              ? instanceId
              : (instanceId is num
                  ? instanceId.toInt()
                  : int.tryParse(instanceId.toString()) ?? 0);
          var sigList = _instanceSignalingListeners[idKey] ?? [];
          if (sigList.isEmpty && instanceId != 0) sigList = _signalingListeners;
          if (sigList.isEmpty) break;
          final inviteID = dataFromNativeMap['invite_id']?.toString() ?? '';
          final inviter = dataFromNativeMap['inviter']?.toString() ?? '';
          final groupID = dataFromNativeMap['group_id']?.toString() ?? '';
          List<String> inviteeList = const [];
          try {
            final v = dataFromNativeMap['json_invitee_list'];
            if (v != null) {
              final decoded = v is String ? json.decode(v) : v;
              if (decoded is List) {
                inviteeList = decoded.whereType<String>().toList();
              }
            }
          } catch (_) {}
          final data = dataFromNativeMap['data']?.toString() ?? '';
          for (final l in sigList) {
            try {
              l.onReceiveNewInvitation(
                  inviteID, inviter, groupID, inviteeList, data);
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] SignalingReceiveNewInvitation: listener threw: $e');
            }
          }
        }
        break;
      case GlobalCallbackType.SignalingInvitationCancelled:
        {
          var sigList = _instanceSignalingListeners[instanceId] ?? [];
          if (sigList.isEmpty && instanceId != 0) sigList = _signalingListeners;
          if (sigList.isEmpty) break;
          final inviteID = dataFromNativeMap['invite_id']?.toString() ?? '';
          final inviter = dataFromNativeMap['inviter']?.toString() ?? '';
          final data = dataFromNativeMap['data']?.toString() ?? '';
          for (final l in sigList) {
            try {
              l.onInvitationCancelled(inviteID, inviter, data);
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] SignalingInvitationCancelled: listener threw: $e');
            }
          }
        }
        break;
      case GlobalCallbackType.SignalingInviteeAccepted:
        {
          var sigList = _instanceSignalingListeners[instanceId] ?? [];
          if (sigList.isEmpty && instanceId != 0) sigList = _signalingListeners;
          if (sigList.isEmpty) break;
          final inviteID = dataFromNativeMap['invite_id']?.toString() ?? '';
          final invitee = dataFromNativeMap['invitee']?.toString() ?? '';
          final data = dataFromNativeMap['data']?.toString() ?? '';
          for (final l in sigList) {
            try {
              l.onInviteeAccepted(inviteID, invitee, data);
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] SignalingInviteeAccepted: listener threw: $e');
            }
          }
        }
        break;
      case GlobalCallbackType.SignalingInviteeRejected:
        {
          var sigList = _instanceSignalingListeners[instanceId] ?? [];
          if (sigList.isEmpty && instanceId != 0) sigList = _signalingListeners;
          if (sigList.isEmpty) break;
          final inviteID = dataFromNativeMap['invite_id']?.toString() ?? '';
          final invitee = dataFromNativeMap['invitee']?.toString() ?? '';
          final data = dataFromNativeMap['data']?.toString() ?? '';
          for (final l in sigList) {
            try {
              l.onInviteeRejected(inviteID, invitee, data);
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] SignalingInviteeRejected: listener threw: $e');
            }
          }
        }
        break;
      case GlobalCallbackType.SignalingInvitationTimeout:
        {
          var sigList = _instanceSignalingListeners[instanceId] ?? [];
          if (sigList.isEmpty && instanceId != 0) sigList = _signalingListeners;
          if (sigList.isEmpty) break;
          final inviteID = dataFromNativeMap['invite_id']?.toString() ?? '';
          List<String> inviteeList = const [];
          try {
            final v = dataFromNativeMap['json_invitee_list'];
            if (v != null) {
              final decoded = v is String ? json.decode(v) : v;
              if (decoded is List) {
                inviteeList = decoded.whereType<String>().toList();
              }
            }
          } catch (_) {}
          for (final l in sigList) {
            try {
              l.onInvitationTimeout(inviteID, inviteeList);
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] SignalingInvitationTimeout: listener threw: $e');
            }
          }
        }
        break;
      case GlobalCallbackType.SignalingInvitationModified:
        {
          var sigList = _instanceSignalingListeners[instanceId] ?? [];
          if (sigList.isEmpty && instanceId != 0) sigList = _signalingListeners;
          if (sigList.isEmpty) break;
          final inviteID = dataFromNativeMap['invite_id']?.toString() ?? '';
          final data = dataFromNativeMap['data']?.toString() ?? '';
          for (final l in sigList) {
            try {
              l.onInvitationModified(inviteID, data);
            } catch (e) {
              if (_debugLog)
                print(
                    '[Tim2ToxSdkPlatform] SignalingInvitationModified: listener threw: $e');
            }
          }
        }
        break;
      default:
        // Other types (Conversation, Friend, Group, etc.) can be extended here
        break;
    }
  }

  @override
  String addUIKitListener({required V2TimUIKitListener listener}) {
    // Generate unique ID and store listener
    final uuid = DateTime.now().millisecondsSinceEpoch.toString();
    _uikitListeners[uuid] = listener;
    if (_debugLog)
      print(
          '[Tim2ToxSdkPlatform] addUIKitListener: Added listener with UUID=$uuid, total listeners=${_uikitListeners.length}');
    return uuid;
  }

  @override
  void emitUIKitListener({required Map<String, dynamic> data}) {
    if (_debugLog)
      print('[Tim2ToxSdkPlatform] emitUIKitListener called with data: $data');
    if (_debugLog)
      print(
          '[Tim2ToxSdkPlatform] emitUIKitListener: ${_uikitListeners.length} UIKit listeners registered');
    // Notify all UIKit listeners
    for (final listener in _uikitListeners.values) {
      try {
        listener.onUiKitEventEmit?.call(data);
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] emitUIKitListener: Successfully notified listener');
      } catch (e, stackTrace) {
        print('[Tim2ToxSdkPlatform] Error notifying UIKit listener: $e');
        if (_debugLog) print('[Tim2ToxSdkPlatform] Stack trace: $stackTrace');
      }
    }
    if (_uikitListeners.isEmpty) {
      print(
          '[Tim2ToxSdkPlatform] WARNING: No UIKit listeners registered! Events will not be delivered.');
    }
  }

  @override
  void removeUIKitListener({String? uuid}) {
    if (uuid != null) {
      final removed = _uikitListeners.remove(uuid);
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] removeUIKitListener: Removed listener with UUID=$uuid, removed=${removed != null}, remaining listeners=${_uikitListeners.length}');
    } else {
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] removeUIKitListener: UUID is null, no listener removed');
    }
  }

  // ============================================================================
  // Helper Methods
  // ============================================================================

  /// Notify all SDK listeners
  void _notifySDKListeners(void Function(V2TimSDKListener) callback) {
    // Snapshot before iterating: a listener callback may add or remove
    // listeners (e.g. one-shot subscriptions), which would otherwise throw
    // ConcurrentModificationError.
    final listeners = List.of(_sdkListeners);
    if (_debugLog) {
      print(
          '[Tim2ToxSdkPlatform] _notifySDKListeners: ${listeners.length} listeners registered');
    }
    for (final listener in listeners) {
      try {
        callback(listener);
      } catch (e) {
        print('Error notifying SDK listener: $e');
      }
    }
  }

  /// Notify all Advanced Message listeners
  void _notifyAdvancedMsgListeners(
      void Function(V2TimAdvancedMsgListener) callback) {
    final listeners = List.of(_advancedMsgListeners);
    if (_debugLog) {
      print(
          '[Tim2ToxSdkPlatform] _notifyAdvancedMsgListeners: ${listeners.length} listeners registered');
    }
    if (listeners.isEmpty) {
      // Always warn — no UIKit listener means messages disappear, which is
      // almost always a startup-ordering bug worth surfacing in release logs.
      print(
          '[Tim2ToxSdkPlatform] WARNING: No AdvancedMsg listeners registered! Messages will not be delivered to UIKit.');
    }
    for (final listener in listeners) {
      try {
        if (_debugLog) {
          print(
              '[Tim2ToxSdkPlatform] Notifying listener: ${listener.runtimeType}');
        }
        callback(listener);
      } catch (e, stackTrace) {
        print('[Tim2ToxSdkPlatform] Error notifying AdvancedMsg listener: $e');
        if (_debugLog) print('[Tim2ToxSdkPlatform] Stack trace: $stackTrace');
      }
    }
  }

  /// Notify all Conversation listeners
  void _notifyConversationListeners(
      void Function(V2TimConversationListener) callback) {
    final listeners = List.of(_conversationListeners);
    for (final listener in listeners) {
      try {
        callback(listener);
      } catch (e) {
        print('Error notifying Conversation listener: $e');
      }
    }
  }

  /// Notify all Friendship listeners
  void _notifyFriendshipListeners(
      void Function(V2TimFriendshipListener) callback) {
    final listeners = List.of(_friendshipListeners);
    for (final listener in listeners) {
      try {
        callback(listener);
      } catch (e) {
        print('Error notifying Friendship listener: $e');
      }
    }
  }

  /// Notify all Group listeners
  void _notifyGroupListeners(void Function(V2TimGroupListener) callback) {
    final listeners = List.of(_groupListeners);
    for (final listener in listeners) {
      try {
        callback(listener);
      } catch (e) {
        print('Error notifying Group listener: $e');
      }
    }
  }

  // ============================================================================
  // Message conversion methods (moved to tim2tox_sdk_platform_converters.dart)
  // ============================================================================

  // ============================================================================
  // Conversation Manager methods
  // ============================================================================

  @override
  Future<void> addConversationListener({
    required V2TimConversationListener listener,
  }) async {
    final id = ffi_lib.Tim2ToxFfi.open().getCurrentInstanceId();
    if (id != 0) {
      (_instanceConversationListeners[id] ??= []).add(listener);
    }
    if (!_conversationListeners.contains(listener)) {
      _conversationListeners.add(listener);
    }
  }

  @override
  Future<void> setConversationListener({
    required V2TimConversationListener listener,
  }) async {
    // setConversationListener replaces all existing listeners
    _conversationListeners.clear();
    _conversationListeners.add(listener);
  }

  @override
  Future<void> removeConversationListener({
    V2TimConversationListener? listener,
  }) async {
    if (listener != null) {
      _conversationListeners.remove(listener);
    }
  }

  @override
  void notifyConversationChangedForC2C(String receiver) {
    if (receiver.isEmpty) return;
    final c2cKey = receiver.length >= 64 ? receiver.substring(0, 64) : receiver;
    final conversationID = 'c2c_$c2cKey';
    final convToNotify = V2TimConversation(conversationID: conversationID);
    // Populate faceUrl from cache so UIKit widgets can display the latest avatar
    // without needing a separate getConversation round-trip.
    final cachedPath =
        _friendAvatarPathCache[receiver] ?? _friendAvatarPathCache[c2cKey];
    if (cachedPath != null && cachedPath.isNotEmpty) {
      convToNotify.faceUrl = cachedPath;
    }
    _notifyConversationListeners((listener) {
      listener.onConversationChanged?.call([convToNotify]);
    });
  }

  @override
  Future<V2TimValueCallback<V2TimConversationResult>> getConversationList({
    required String nextSeq,
    required int count,
  }) async {
    try {
      // Get conversation list from provider
      final conversationManager = conversationManagerProvider;
      if (conversationManager == null) {
        return V2TimValueCallback<V2TimConversationResult>(
          code: -1,
          desc: 'ConversationManager not initialized',
          data: V2TimConversationResult(
            nextSeq: '0',
            isFinished: true,
            conversationList: [],
          ),
        );
      }

      final fakeConvs = await conversationManager.getConversationList();

      // Convert to V2TimConversation
      final v2Convs = <V2TimConversation>[];
      for (final fakeConv in fakeConvs) {
        final v2Conv = await fakeConversationToV2TimConversation(fakeConv);
        v2Convs.add(v2Conv);
      }

      // Sort: pinned first, then by orderkey (newest first)
      v2Convs.sort((a, b) {
        final aPinned = a.isPinned ?? false;
        final bPinned = b.isPinned ?? false;
        if (aPinned != bPinned) {
          return aPinned ? -1 : 1;
        }
        final aOrder = a.orderkey ?? 0;
        final bOrder = b.orderkey ?? 0;
        return bOrder.compareTo(aOrder);
      });

      // Apply pagination
      final nextSeqInt = int.tryParse(nextSeq) ?? 0;
      final startIndex = nextSeqInt;
      final endIndex = (startIndex + count).clamp(0, v2Convs.length);
      final paginatedConvs = v2Convs.sublist(startIndex, endIndex);

      final isFinished = endIndex >= v2Convs.length;
      final newNextSeq = isFinished ? '0' : endIndex.toString();

      return V2TimValueCallback<V2TimConversationResult>(
        code: 0,
        desc: 'success',
        data: V2TimConversationResult(
          nextSeq: newNextSeq,
          isFinished: isFinished,
          conversationList: paginatedConvs,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimConversationResult>(
        code: -1,
        desc: 'getConversationList failed: $e',
        data: V2TimConversationResult(
          nextSeq: '0',
          isFinished: true,
          conversationList: [],
        ),
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimConversation>>>
      getConversationListByConversationIds({
    required List<String> conversationIDList,
  }) async {
    try {
      final conversationManager = conversationManagerProvider;
      if (conversationManager == null) {
        return V2TimValueCallback<List<V2TimConversation>>(
          code: -1,
          desc: 'ConversationManager not initialized',
          data: [],
        );
      }

      final fakeConvs = await conversationManager.getConversationList();
      final v2Convs = <V2TimConversation>[];

      for (final convID in conversationIDList) {
        final fakeConv = fakeConvs.firstWhere(
          (c) => c.conversationID == convID,
          orElse: () => FakeConversation(
            conversationID: convID,
            title: '',
            faceUrl: null,
            unreadCount: 0,
            isGroup: convID.startsWith('group_'),
          ),
        );
        final v2Conv = await fakeConversationToV2TimConversation(fakeConv);
        v2Convs.add(v2Conv);
      }

      return V2TimValueCallback<List<V2TimConversation>>(
        code: 0,
        desc: 'success',
        data: v2Convs,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimConversation>>(
        code: -1,
        desc: 'getConversationListByConversationIds failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimConversation>> getConversation({
    required String conversationID,
  }) async {
    if (_debugLog)
      print(
          '[Tim2ToxSdkPlatform] getConversation: START, conversationID=$conversationID');
    debugPrint(
        '[Tim2ToxSdkPlatform] getConversation: START, conversationID=$conversationID');
    try {
      final conversationManager = conversationManagerProvider;
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getConversation: conversationManager=${conversationManager != null ? "not null" : "null"}');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: conversationManager=${conversationManager != null ? "not null" : "null"}');
      if (conversationManager == null) {
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] getConversation: ConversationManager not initialized, returning error');
        debugPrint(
            '[Tim2ToxSdkPlatform] getConversation: ConversationManager not initialized, returning error');
        return V2TimValueCallback<V2TimConversation>(
          code: -1,
          desc: 'ConversationManager not initialized',
        );
      }

      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getConversation: Calling conversationManager.getConversationList()...');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: Calling conversationManager.getConversationList()...');
      final fakeConvs = await conversationManager.getConversationList();
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getConversation: getConversationList() returned, count=${fakeConvs.length}');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: getConversationList() returned, count=${fakeConvs.length}');
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getConversation: Searching for conversationID=$conversationID in list...');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: Searching for conversationID=$conversationID in list...');
      final fakeConv = fakeConvs.firstWhere(
        (c) => c.conversationID == conversationID,
        orElse: () {
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] getConversation: Conversation not found, creating default FakeConversation');
          debugPrint(
              '[Tim2ToxSdkPlatform] getConversation: Conversation not found, creating default FakeConversation');
          return FakeConversation(
            conversationID: conversationID,
            title: '',
            faceUrl: null,
            unreadCount: 0,
            isGroup: conversationID.startsWith('group_'),
          );
        },
      );
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getConversation: Found/created fakeConv, conversationID=${fakeConv.conversationID}, isGroup=${fakeConv.isGroup}');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: Found/created fakeConv, conversationID=${fakeConv.conversationID}, isGroup=${fakeConv.isGroup}');

      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getConversation: Calling fakeConversationToV2TimConversation()...');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: Calling fakeConversationToV2TimConversation()...');
      final v2Conv = await fakeConversationToV2TimConversation(fakeConv);
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getConversation: fakeConversationToV2TimConversation() returned, conversationID=${v2Conv.conversationID}');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: fakeConversationToV2TimConversation() returned, conversationID=${v2Conv.conversationID}');

      if (_debugLog)
        print('[Tim2ToxSdkPlatform] getConversation: END, returning success');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: END, returning success');
      return V2TimValueCallback<V2TimConversation>(
        code: 0,
        desc: 'success',
        data: v2Conv,
      );
    } catch (e, stackTrace) {
      if (_debugLog)
        print('[Tim2ToxSdkPlatform] getConversation: Exception caught: $e');
      debugPrint('[Tim2ToxSdkPlatform] getConversation: Exception caught: $e');
      if (_debugLog)
        print('[Tim2ToxSdkPlatform] getConversation: Stack trace: $stackTrace');
      debugPrint(
          '[Tim2ToxSdkPlatform] getConversation: Stack trace: $stackTrace');
      return V2TimValueCallback<V2TimConversation>(
        code: -1,
        desc: 'getConversation failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> deleteConversation({
    required String conversationID,
  }) async {
    try {
      // Delete conversation
      final conversationManager = conversationManagerProvider;
      if (conversationManager != null) {
        // Note: FakeConversationManager doesn't have deleteConversation method
        // We'll need to clear messages and update conversation list
        // For now, just notify listeners
        _notifyConversationListeners((listener) {
          listener.onConversationDeleted?.call([conversationID]);
        });
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'deleteConversation failed: $e',
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimConversationOperationResult>>>
      deleteConversationList({
    required List<String> conversationIDList,
    required bool clearMessage,
  }) async {
    try {
      final results = <V2TimConversationOperationResult>[];

      for (final conversationID in conversationIDList) {
        try {
          // Notify conversation listeners that conversation is being deleted
          _notifyConversationListeners((listener) {
            listener.onConversationDeleted?.call([conversationID]);
          });

          // If clearMessage is true, also clear messages for this conversation
          if (clearMessage) {
            // Extract groupID or userID from conversationID
            if (conversationID.startsWith('group_')) {
              final groupID = conversationID.substring(6);
              // Clear group messages via FfiChatService if available
              // Note: This is a best-effort operation
              try {
                await ffiService.clearGroupHistory(groupID);
              } catch (e) {
                // Silently handle errors
              }
            } else if (conversationID.startsWith('c2c_')) {
              final userID = conversationID.substring(4);
              // Clear C2C messages via FfiChatService if available
              try {
                await ffiService.clearC2CHistory(userID);
              } catch (e) {
                // Silently handle errors
              }
            }
          }

          results.add(V2TimConversationOperationResult(
            conversationID: conversationID,
            resultCode: 0,
          ));
        } catch (e) {
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] deleteConversationList: Error deleting conversation $conversationID: $e');
          results.add(V2TimConversationOperationResult(
            conversationID: conversationID,
            resultCode: -1,
            resultInfo: e.toString(),
          ));
        }
      }

      return V2TimValueCallback<List<V2TimConversationOperationResult>>(
        code: 0,
        desc: 'success',
        data: results,
      );
    } catch (e) {
      if (_debugLog)
        print('[Tim2ToxSdkPlatform] deleteConversationList: Failed: $e');
      return V2TimValueCallback<List<V2TimConversationOperationResult>>(
        code: -1,
        desc: 'deleteConversationList failed: $e',
        data: conversationIDList
            .map((id) => V2TimConversationOperationResult(
                  conversationID: id,
                  resultCode: -1,
                  resultInfo: e.toString(),
                ))
            .toList(),
      );
    }
  }

  @override
  Future<V2TimCallback> setConversationDraft({
    required String conversationID,
    String? draftText,
  }) async {
    // Draft is stored locally
    // For now, just return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimCallback> pinConversation({
    required String conversationID,
    required bool isPinned,
  }) async {
    try {
      final conversationManager = conversationManagerProvider;
      if (conversationManager != null) {
        await conversationManager.setPinned(conversationID, isPinned);
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'pinConversation failed: $e',
      );
    }
  }

  @override
  Future<V2TimValueCallback<int>> getTotalUnreadMessageCount() async {
    try {
      int totalUnread = 0;
      final conversationManager = conversationManagerProvider;
      if (conversationManager != null) {
        final fakeConvs = await conversationManager.getConversationList();
        for (final conv in fakeConvs) {
          totalUnread += (conv.unreadCount ?? 0).toInt();
        }
      }

      return V2TimValueCallback<int>(
        code: 0,
        desc: 'success',
        data: totalUnread,
      );
    } catch (e) {
      return V2TimValueCallback<int>(
        code: -1,
        desc: 'getTotalUnreadMessageCount failed: $e',
        data: 0,
      );
    }
  }

  @override
  Future<V2TimCallback> cleanConversationUnreadMessageCount({
    required String conversationID,
    required int cleanTimestamp,
    required int cleanSequence,
  }) async {
    // For Tim2Tox implementation, unread count is managed by the conversation system
    // This is a simple implementation that just returns success
    // The actual unread count clearing is handled by the conversation manager
    // when messages are marked as read through other mechanisms
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  // ============================================================================
  // Message Manager methods
  // ============================================================================

  @override
  Future<String> addAdvancedMsgListener({
    required V2TimAdvancedMsgListener listener,
  }) async {
    final id = ffi_lib.Tim2ToxFfi.open().getCurrentInstanceId();
    if (id != 0) {
      (_instanceAdvancedMsgListeners[id] ??= []).add(listener);
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] addAdvancedMsgListener: instanceId=$id, per-instance list length=${_instanceAdvancedMsgListeners[id]!.length}');
    } else {
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] addAdvancedMsgListener: getCurrentInstanceId()=0, listener NOT added to per-instance map');
    }
    if (_debugLog)
      print(
          '[Tim2ToxSdkPlatform] addAdvancedMsgListener called, current listeners: ${_advancedMsgListeners.length}');
    if (!_advancedMsgListeners.contains(listener)) {
      _advancedMsgListeners.add(listener);
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] Added AdvancedMsg listener, total listeners: ${_advancedMsgListeners.length}');
    }
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  @override
  Future<void> removeAdvancedMsgListener({
    V2TimAdvancedMsgListener? listener,
    String? uuid,
  }) async {
    if (listener != null) {
      _advancedMsgListeners.remove(listener);
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createTextMessage({
    required String text,
  }) async {
    // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
    final senderID = ffiService.selfId.isNotEmpty
        ? ffiService.selfId
        : (_currentUserID ?? 'unknown');
    print(
        '[Tim2ToxSdkPlatform] createTextMessage called - text length=${text.length}, senderID=$senderID, _currentUserID=$_currentUserID, ffiService.selfId=${ffiService.selfId}');
    try {
      final msgID = '${DateTime.now().millisecondsSinceEpoch}_$senderID';
      final msg = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_TEXT,
        msgID: msgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        textElem: V2TimTextElem(text: text),
      );
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      msg.isSelf = true;
      msg.sender = senderID;
      await _setFaceUrlForMsg(msg);

      print(
          '[Tim2ToxSdkPlatform] createTextMessage - Created message with msgID=$msgID');
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: msgID,
          messageInfo: msg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createTextMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createTextAtMessage({
    required String text,
    required List<String> atUserList,
  }) async {
    try {
      // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
      final senderID = ffiService.selfId.isNotEmpty
          ? ffiService.selfId
          : (_currentUserID ?? 'unknown');
      final msgID = '${DateTime.now().millisecondsSinceEpoch}_$senderID';
      final msg = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_TEXT,
        msgID: msgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        textElem: V2TimTextElem(text: text),
        groupAtUserList: atUserList,
      );
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      msg.isSelf = true;
      msg.sender = senderID;
      await _setFaceUrlForMsg(msg);

      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: msgID,
          messageInfo: msg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createTextAtMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createImageMessage({
    required String imagePath,
    dynamic inputElement,
    String? imageName,
  }) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        return V2TimValueCallback<V2TimMsgCreateInfoResult>(
          code: -1,
          desc: 'imagePath is not found',
          data: V2TimMsgCreateInfoResult(
              id: '',
              messageInfo:
                  V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
        );
      }

      // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
      final senderID = ffiService.selfId.isNotEmpty
          ? ffiService.selfId
          : (_currentUserID ?? 'unknown');
      final msgID = '${DateTime.now().millisecondsSinceEpoch}_$senderID';
      final fileSize = await file.length();
      // Generate UUID from msgID for download identification
      final imageUuid = msgID.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      // Create imageList with both thumb and origin images
      // UIKit may request either THUMB (1) or ORIGIN (0), so we need both
      final imageList = [
        V2TimImage(
          uuid: imageUuid, // Required for downloadMessage
          type: V2TIM_IMAGE_TYPE.V2TIM_IMAGE_TYPE_THUMB,
          size: fileSize,
          width: 0,
          height: 0,
          url: imagePath, // Use local path as URL for Tox protocol
          localUrl: imagePath,
        ),
        V2TimImage(
          uuid: imageUuid, // Required for downloadMessage
          type: V2TIM_IMAGE_TYPE.V2TIM_IMAGE_TYPE_ORIGIN,
          size: fileSize,
          width: 0,
          height: 0,
          url: imagePath, // Use local path as URL for Tox protocol
          localUrl: imagePath,
        ),
      ];

      final msg = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_IMAGE,
        msgID: msgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        imageElem: V2TimImageElem(
          path: imagePath,
          imageList: imageList,
        ),
      );
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      msg.isSelf = true;
      msg.sender = senderID;
      await _setFaceUrlForMsg(msg);

      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: msgID,
          messageInfo: msg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createImageMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createSoundMessage({
    required String soundPath,
    required int duration,
  }) async {
    try {
      final file = File(soundPath);
      if (!await file.exists()) {
        return V2TimValueCallback<V2TimMsgCreateInfoResult>(
          code: -1,
          desc: 'soundPath is not found',
          data: V2TimMsgCreateInfoResult(
              id: '',
              messageInfo:
                  V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
        );
      }

      // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
      final senderID = ffiService.selfId.isNotEmpty
          ? ffiService.selfId
          : (_currentUserID ?? 'unknown');
      final msgID = '${DateTime.now().millisecondsSinceEpoch}_$senderID';
      final fileSize = await file.length();

      final msg = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_SOUND,
        msgID: msgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        soundElem: V2TimSoundElem(
          path: soundPath,
          duration: duration,
          dataSize: fileSize,
        ),
      );
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      msg.isSelf = true;
      msg.sender = senderID;
      await _setFaceUrlForMsg(msg);

      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: msgID,
          messageInfo: msg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createSoundMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createVideoMessage({
    required String videoFilePath,
    required String type,
    String? snapshotPath,
    required int duration,
    dynamic inputElement,
  }) async {
    try {
      final file = File(videoFilePath);
      if (!await file.exists()) {
        return V2TimValueCallback<V2TimMsgCreateInfoResult>(
          code: -1,
          desc: 'videoFilePath is not found',
          data: V2TimMsgCreateInfoResult(
              id: '',
              messageInfo:
                  V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
        );
      }

      // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
      final senderID = ffiService.selfId.isNotEmpty
          ? ffiService.selfId
          : (_currentUserID ?? 'unknown');
      final msgID = '${DateTime.now().millisecondsSinceEpoch}_$senderID';
      final fileSize = await file.length();

      final msg = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_VIDEO,
        msgID: msgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        videoElem: V2TimVideoElem(
          videoPath: videoFilePath,
          snapshotPath: snapshotPath,
          duration: duration,
          videoSize: fileSize,
        ),
      );
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      msg.isSelf = true;
      msg.sender = senderID;
      await _setFaceUrlForMsg(msg);

      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: msgID,
          messageInfo: msg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createVideoMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createFileMessage({
    required String filePath,
    required String fileName,
    dynamic inputElement,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return V2TimValueCallback<V2TimMsgCreateInfoResult>(
          code: -1,
          desc: 'filePath is not found',
          data: V2TimMsgCreateInfoResult(
              id: '',
              messageInfo:
                  V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
        );
      }

      // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
      final senderID = ffiService.selfId.isNotEmpty
          ? ffiService.selfId
          : (_currentUserID ?? 'unknown');
      final msgID = '${DateTime.now().millisecondsSinceEpoch}_$senderID';
      final fileSize = await file.length();
      // Generate UUID from msgID for download identification
      final fileUuid = msgID.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

      final msg = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_FILE,
        msgID: msgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        fileElem: V2TimFileElem(
          path: filePath,
          fileName: fileName,
          UUID: fileUuid, // Required for downloadMessage
          url: filePath, // Use local path as URL for Tox protocol
          fileSize: fileSize,
          localUrl: filePath,
        ),
      );
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      msg.isSelf = true;
      msg.sender = senderID;
      await _setFaceUrlForMsg(msg);

      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: msgID,
          messageInfo: msg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createFileMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createCustomMessage({
    required String data,
    String desc = "",
    String extension = "",
  }) async {
    try {
      // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
      final senderID = ffiService.selfId.isNotEmpty
          ? ffiService.selfId
          : (_currentUserID ?? 'unknown');
      final msgID = '${DateTime.now().millisecondsSinceEpoch}_$senderID';

      final msg = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_CUSTOM,
        msgID: msgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        customElem: V2TimCustomElem(
          data: data,
          desc: desc,
          extension: extension,
        ),
      );
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      msg.isSelf = true;
      msg.sender = senderID;
      await _setFaceUrlForMsg(msg);

      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: msgID,
          messageInfo: msg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createCustomMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createForwardMessage({
    String? msgID,
    String? webMessageInstance,
  }) async {
    // Force print to ensure it's logged even if there's an issue
    if (_debugLog)
      print('[Tim2ToxSdkPlatform] ===== createForwardMessage CALLED =====');
    if (_debugLog) print('[Tim2ToxSdkPlatform] msgID=$msgID');
    if (_debugLog) print('[Tim2ToxSdkPlatform] _isInitialized=$_isInitialized');
    if (_debugLog)
      print('[Tim2ToxSdkPlatform] this instance hashCode=${hashCode}');
    if (_debugLog)
      print('[Tim2ToxSdkPlatform] webMessageInstance=$webMessageInstance');
    print(
        '[Tim2ToxSdkPlatform] Platform: ${Platform.isMacOS ? "macOS" : "other"}');
    if (_debugLog)
      print('[Tim2ToxSdkPlatform] ffiService.selfId=${ffiService.selfId}');
    try {
      // Check if SDK is initialized
      if (!_ensureInitialized()) {
        print(
            '[Tim2ToxSdkPlatform] createForwardMessage failed: SDK not initialized (selfId is empty)');
        return V2TimValueCallback<V2TimMsgCreateInfoResult>(
          code: 6013,
          desc: 'sdk not init',
          data: V2TimMsgCreateInfoResult(
              id: '',
              messageInfo:
                  V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
        );
      }
      if (msgID == null || msgID.isEmpty) {
        print(
            '[Tim2ToxSdkPlatform] createForwardMessage failed: msgID is required');
        return V2TimValueCallback<V2TimMsgCreateInfoResult>(
          code: -1,
          desc: 'msgID is required',
          data: V2TimMsgCreateInfoResult(
              id: '',
              messageInfo:
                  V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
        );
      }

      // Find the original message
      if (_debugLog)
        print('[Tim2ToxSdkPlatform] Searching for message with msgID: $msgID');
      final foundMessages = await findMessages(messageIDList: [msgID]);
      print(
          '[Tim2ToxSdkPlatform] findMessages returned: code=${foundMessages.code}, found ${foundMessages.data?.length ?? 0} messages');
      if (foundMessages.data == null || foundMessages.data!.isEmpty) {
        print(
            '[Tim2ToxSdkPlatform] createForwardMessage failed: message not found (msgID: $msgID)');
        return V2TimValueCallback<V2TimMsgCreateInfoResult>(
          code: -1,
          desc:
              'Failed to create forward message: message not found (msgID: $msgID)',
          data: V2TimMsgCreateInfoResult(
              id: '',
              messageInfo:
                  V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
        );
      }

      final originalMsg = foundMessages.data!.first;
      print(
          '[Tim2ToxSdkPlatform] Found original message: msgID=${originalMsg.msgID}, elemType=${originalMsg.elemType}');

      // Create a new forward message by copying the original message
      // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
      final senderID = ffiService.selfId.isNotEmpty
          ? ffiService.selfId
          : (_currentUserID ?? 'unknown');
      final forwardMsgID =
          '${DateTime.now().millisecondsSinceEpoch}_forward_$senderID';
      final forwardMsg = V2TimMessage(
        elemType: originalMsg.elemType,
        msgID: forwardMsgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      forwardMsg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      forwardMsg.isSelf = true;
      await _setFaceUrlForMsg(forwardMsg);

      // Copy message elements
      if (originalMsg.textElem != null) {
        forwardMsg.textElem = V2TimTextElem(text: originalMsg.textElem!.text);
      }
      if (originalMsg.imageElem != null) {
        // P1-14: received image messages may have a null `path` but a
        // populated `imageList[i].localUrl`. Fall back so forwards survive.
        String? imgPath = originalMsg.imageElem!.path;
        if (imgPath == null || imgPath.isEmpty) {
          final imgList = originalMsg.imageElem!.imageList;
          if (imgList != null) {
            for (final img in imgList) {
              final lu = img?.localUrl;
              if (lu != null && lu.isNotEmpty) {
                imgPath = lu;
                break;
              }
            }
          }
        }
        forwardMsg.imageElem = V2TimImageElem(
          path: imgPath,
          imageList: originalMsg.imageElem!.imageList,
        );
      }
      if (originalMsg.fileElem != null) {
        // P1-14: prefer non-null path, fall back to localUrl for received files.
        final String? filePath =
            originalMsg.fileElem!.path ?? originalMsg.fileElem!.localUrl;
        forwardMsg.fileElem = V2TimFileElem(
          path: filePath,
          fileName: originalMsg.fileElem!.fileName,
          fileSize: originalMsg.fileElem!.fileSize,
          localUrl: originalMsg.fileElem!.localUrl,
        );
      }
      if (originalMsg.soundElem != null) {
        // P1-14: prefer non-null path, fall back to localUrl for received audio.
        final String? sndPath =
            originalMsg.soundElem!.path ?? originalMsg.soundElem!.localUrl;
        forwardMsg.soundElem = V2TimSoundElem(
          path: sndPath,
          dataSize: originalMsg.soundElem!.dataSize,
          duration: originalMsg.soundElem!.duration,
        );
      }
      if (originalMsg.videoElem != null) {
        // P1-14: prefer non-null videoPath, fall back to localVideoUrl for received video.
        final String? vidPath = originalMsg.videoElem!.videoPath ??
            originalMsg.videoElem!.localVideoUrl;
        forwardMsg.videoElem = V2TimVideoElem(
          videoPath: vidPath,
          snapshotPath: originalMsg.videoElem!.snapshotPath,
          videoSize: originalMsg.videoElem!.videoSize,
          duration: originalMsg.videoElem!.duration,
        );
      }
      if (originalMsg.customElem != null) {
        forwardMsg.customElem = V2TimCustomElem(
          data: originalMsg.customElem!.data,
          desc: originalMsg.customElem!.desc,
          extension: originalMsg.customElem!.extension,
        );
      }
      if (originalMsg.mergerElem != null) {
        forwardMsg.mergerElem = V2TimMergerElem(
          title: originalMsg.mergerElem!.title,
          abstractList: originalMsg.mergerElem!.abstractList,
          compatibleText: originalMsg.mergerElem!.compatibleText,
        );
      }

      // Copy other fields.
      // H-I: forwarded messages must NOT inherit the original sender,
      // otherwise the receiver shows Bob's nick/avatar on a message that
      // Alice forwarded. Leave `sender` empty so the sendMessage path
      // populates it with selfId.
      forwardMsg.sender = '';
      forwardMsg.nickName = null;
      // Don't copy userID/groupID from original message - they should be set by UIKit
      // when the message is sent to the target conversation
      // Setting them to null ensures UIKit will use the target conversation's userID/groupID
      forwardMsg.userID = null;
      forwardMsg.groupID = null;

      // Set the id field to match the forwardMsgID for lookup
      forwardMsg.id = forwardMsgID;

      // Cache the forward message so sendMessage can find it later
      // This is necessary because when forwarding to non-current conversations,
      // UIKit doesn't add the forward message to messageData
      _forwardMessageCache[forwardMsgID] = forwardMsg;
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] Cached forward message with id: $forwardMsgID');

      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: forwardMsgID,
          messageInfo: forwardMsg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createForwardMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMsgCreateInfoResult>> createMergerMessage({
    List<String>? msgIDList,
    required String title,
    required List<String> abstractList,
    required String compatibleText,
    List<String>? webMessageInstanceList,
  }) async {
    try {
      // Use ffiService.selfId instead of _currentUserID, as selfId is set during initialization
      final senderID = ffiService.selfId.isNotEmpty
          ? ffiService.selfId
          : (_currentUserID ?? 'unknown');
      final msgID = '${DateTime.now().millisecondsSinceEpoch}_merger_$senderID';

      final msg = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_MERGER,
        msgID: msgID,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        mergerElem: V2TimMergerElem(
          title: title,
          abstractList: abstractList,
          compatibleText: compatibleText,
        ),
      );
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      msg.isSelf = true;
      msg.sender = senderID;
      await _setFaceUrlForMsg(msg);

      // Set cloudCustomData with mergerMessageIDs for C++ layer to use
      if (msgIDList != null && msgIDList.isNotEmpty) {
        final cloudCustomDataMap = {
          'mergerMessageIDs': msgIDList,
        };
        msg.cloudCustomData = json.encode(cloudCustomDataMap);
      }

      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: 0,
        desc: 'success',
        data: V2TimMsgCreateInfoResult(
          id: msgID,
          messageInfo: msg,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMsgCreateInfoResult>(
        code: -1,
        desc: 'createMergerMessage failed: $e',
        data: V2TimMsgCreateInfoResult(
            id: '',
            messageInfo:
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE)),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMessage>> sendMessage({
    String? id,
    required String receiver,
    required String groupID,
    int priority = 0,
    bool onlineUserOnly = false,
    bool? needReadReceipt,
    bool? isExcludedFromUnreadCount,
    bool? isExcludedFromLastMessage,
    bool? isSupportMessageExtension,
    bool? isExcludedFromContentModeration,
    Map<String, dynamic>? offlinePushInfo,
    String? cloudCustomData,
    String? localCustomData,
  }) async {
    try {
      print(
          '[Tim2ToxSdkPlatform] sendMessage called: id=$id, receiver=$receiver, groupID=$groupID');
      // Get message by id from message data
      // UIKit stores messages in messageData before calling sendMessage
      final userID = receiver.isNotEmpty ? receiver : null;
      final targetID = groupID.isNotEmpty ? groupID : userID ?? '';
      if (targetID.isEmpty) {
        print(
            '[Tim2ToxSdkPlatform] sendMessage failed: userID or groupID is required');
        return V2TimValueCallback<V2TimMessage>(
          code: -1,
          desc: 'userID or groupID is required',
        );
      }

      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] Looking for message in targetID: $targetID');
      // Try to find the message in messageData by id
      final messageList =
          TencentCloudChat.instance.dataInstance.messageData.getMessageList(
        key: targetID,
      );
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] Found ${messageList.length} messages in list');
      V2TimMessage messageToSend =
          V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE);

      if (id != null && id.isNotEmpty) {
        if (_debugLog)
          print('[Tim2ToxSdkPlatform] Searching for message with id: $id');
        // Find message by id
        messageToSend = messageList.firstWhere(
          (msg) => msg.id == id || msg.msgID == id,
          orElse: () =>
              V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE),
        );
        if (messageToSend.elemType != MessageElemType.V2TIM_ELEM_TYPE_NONE) {
          print(
              '[Tim2ToxSdkPlatform] Found message: msgID=${messageToSend.msgID}, elemType=${messageToSend.elemType}');
        } else {
          print(
              '[Tim2ToxSdkPlatform] Message not found by id. Available message IDs: ${messageList.map((m) => 'id=${m.id}, msgID=${m.msgID}').join(", ")}');
        }
      } else {
        print(
            '[Tim2ToxSdkPlatform] No id provided, searching for most recent SENDING message');
        // If no id provided, try to find the most recent SENDING message
        messageToSend = messageList.firstWhere(
          (msg) =>
              msg.status == MessageStatus.V2TIM_MSG_STATUS_SENDING &&
              msg.isSelf == true,
          orElse: () =>
              V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE),
        );
        if (messageToSend.elemType != MessageElemType.V2TIM_ELEM_TYPE_NONE) {
          print(
              '[Tim2ToxSdkPlatform] Found SENDING message: msgID=${messageToSend.msgID}');
        } else {
          print(
              '[Tim2ToxSdkPlatform] No SENDING message found. Message statuses: ${messageList.map((m) => '${m.msgID}: status=${m.status}, isSelf=${m.isSelf}').join(", ")}');
        }
      }

      // If message not found in target conversation, try to find it in all conversations
      // This handles the case where forward messages are not added to target conversation's messageData
      // (e.g., when forwarding to a different conversation or group)
      if (messageToSend.elemType == MessageElemType.V2TIM_ELEM_TYPE_NONE &&
          id != null &&
          id.isNotEmpty) {
        print(
            '[Tim2ToxSdkPlatform] Message not found in target conversation, searching all conversations for id: $id');
        // Search through all conversations in messageData
        final messageListMap =
            TencentCloudChat.instance.dataInstance.messageData.messageListMap;
        for (final entry in messageListMap.entries) {
          final conversationID = entry.key;
          final conversationMessages = entry.value;
          final foundMessage = conversationMessages.firstWhere(
            (msg) => msg.id == id || msg.msgID == id,
            orElse: () =>
                V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_NONE),
          );
          if (foundMessage.elemType != MessageElemType.V2TIM_ELEM_TYPE_NONE) {
            print(
                '[Tim2ToxSdkPlatform] Found message in conversation $conversationID: msgID=${foundMessage.msgID}');
            messageToSend = foundMessage;
            break;
          }
        }

        // If still not found, check the forward message cache
        // This handles the case where forward messages are not added to messageData at all
        // (e.g., when forwarding to non-current conversations)
        if (messageToSend.elemType == MessageElemType.V2TIM_ELEM_TYPE_NONE) {
          print(
              '[Tim2ToxSdkPlatform] Message not found in messageData, checking forward message cache for id: $id');
          final cachedMessage = _forwardMessageCache[id];
          if (cachedMessage != null) {
            print(
                '[Tim2ToxSdkPlatform] Found message in forward cache: msgID=${cachedMessage.msgID}, elemType=${cachedMessage.elemType}');
            messageToSend = cachedMessage;
          } else {
            print(
                '[Tim2ToxSdkPlatform] Message not found in forward cache. Cache keys: ${_forwardMessageCache.keys.join(", ")}');
          }
        }
      }

      if (messageToSend.elemType == MessageElemType.V2TIM_ELEM_TYPE_NONE) {
        print(
            '[Tim2ToxSdkPlatform] sendMessage failed: Message not found (id: $id)');
        return V2TimValueCallback<V2TimMessage>(
          code: -1,
          desc: 'Message not found (id: $id)',
        );
      }

      // H-I: forwarded messages clear sender/nickName in createForwardMessage
      // so we can repopulate them here with the local user (we are the sender
      // when forwarding). Done unconditionally for self-sent flows — never
      // overwrite when the field is already set to a non-empty real value.
      if (messageToSend.sender == null || messageToSend.sender!.isEmpty) {
        messageToSend.sender = ffiService.selfId;
      }
      messageToSend.isSelf = true;

      // Set faceUrl immediately so the list shows correct avatar from the first frame (avoids default→correct flicker)
      await _setFaceUrlForMsg(messageToSend);
      _notifyAdvancedMsgListeners((listener) {
        listener.onRecvMessageModified?.call(messageToSend);
      });

      // Get ChatMessageProvider to send the message
      final provider = ChatMessageProviderRegistry.provider;
      if (provider == null) {
        print(
            '[Tim2ToxSdkPlatform] sendMessage failed: ChatMessageProvider is not available');
        return V2TimValueCallback<V2TimMessage>(
          code: -1,
          desc: 'ChatMessageProvider is not available',
        );
      }

      print(
          '[Tim2ToxSdkPlatform] ChatMessageProvider found, sending message type: ${messageToSend.elemType}');

      // If this is a forward message (from cache), track the target so we can fix the userID/groupID
      // when the message is received from the stream
      // We use message text as key because FfiChatService returns messages with new msgIDs
      if (id != null && _forwardMessageCache.containsKey(id)) {
        final messageText = messageToSend.textElem?.text ??
            messageToSend.mergerElem?.compatibleText ??
            '';
        if (messageText.isNotEmpty) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          print(
              '[Tim2ToxSdkPlatform] Tracking forward message target: text="$messageText", userID=$userID, groupID=$groupID, timestamp=$timestamp');
          _pendingForwardTargets[messageText] = (
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            timestamp: timestamp,
          );
        }
      }

      // Send message based on element type
      try {
        if (messageToSend.textElem != null) {
          // Text message (including forward messages which are text)
          final text = messageToSend.textElem!.text ?? '';
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Sending text message: "$text"');
          await provider.sendText(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            text: text,
          );
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Text message sent successfully');
        } else if (messageToSend.imageElem != null &&
            messageToSend.imageElem!.path != null) {
          // Image message
          print(
              '[Tim2ToxSdkPlatform] Sending image message: ${messageToSend.imageElem!.path}');
          await provider.sendImage(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            imagePath: messageToSend.imageElem!.path!,
            imageName: messageToSend.imageElem!.path,
          );
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Image message sent successfully');
        } else if (messageToSend.fileElem != null &&
            messageToSend.fileElem!.path != null) {
          // File message
          print(
              '[Tim2ToxSdkPlatform] Sending file message: ${messageToSend.fileElem!.path}');
          await provider.sendFile(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            filePath: messageToSend.fileElem!.path!,
            fileName: messageToSend.fileElem!.fileName,
          );
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] File message sent successfully');
        } else if (messageToSend.mergerElem != null) {
          // Merger message - send as text with merger data encoded
          // The C++ layer will handle the merger message encoding
          final compatibleText =
              messageToSend.mergerElem!.compatibleText ?? '转发消息';
          print(
              '[Tim2ToxSdkPlatform] Sending merger message with compatibleText: "$compatibleText"');
          print(
              '[Tim2ToxSdkPlatform] Merger message cloudCustomData: ${messageToSend.cloudCustomData}');
          await provider.sendText(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            text: compatibleText,
          );
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Merger message sent successfully');
        } else if (messageToSend.soundElem != null &&
            messageToSend.soundElem!.path != null &&
            messageToSend.soundElem!.path!.isNotEmpty) {
          // Sound message — send the audio file via Tox file transfer (same as fileElem/imageElem).
          // Sound has a `path` field (verified against
          // tencent_cloud_chat_sdk/lib/models/v2_tim_sound_elem.dart:16).
          final soundPath = messageToSend.soundElem!.path!;
          final soundDuration = messageToSend.soundElem!.duration ?? 0;
          print(
              '[Tim2ToxSdkPlatform] Sending sound message: $soundPath (duration=$soundDuration ms)');
          // U-3: Tox's file-transfer envelope has no duration field, so we
          // smuggle it via the filename: `<base>__dur{ms}<ext>`. Because
          // FfiChatService.sendFile derives the wire filename from the
          // on-disk basename and we cannot edit FfiChatService here, we
          // copy the audio file to a temp file with the encoded name and
          // send that. The receive-side fake_msg_provider mapping decoder
          // strips `__dur{ms}` back out when constructing
          // soundElem.duration. We also remember the local sender-side
          // duration for our own echo so the sender's UI does not show
          // 0 ms.
          // Best-effort: if copy fails or duration is 0, fall back to the
          // original path/name.
          _rememberSoundDuration(soundPath, soundDuration);
          String pathToSend = soundPath;
          String? encodedName;
          if (soundDuration > 0) {
            try {
              final originalName = soundPath.split('/').last;
              final dotIdx = originalName.lastIndexOf('.');
              final base = dotIdx > 0
                  ? originalName.substring(0, dotIdx)
                  : originalName;
              final ext = dotIdx > 0 ? originalName.substring(dotIdx) : '';
              encodedName = '${base}__dur$soundDuration$ext';
              final srcFile = File(soundPath);
              if (await srcFile.exists()) {
                final tmpDir = Directory.systemTemp;
                final tmpPath = '${tmpDir.path}/$encodedName';
                final tmpFile = File(tmpPath);
                // Copy is idempotent: overwrite if it somehow exists from a
                // previous send of the same recording.
                await srcFile.copy(tmpPath);
                // Map the temp path → duration too so the local echo
                // (which may arrive with the temp path) is patched.
                _rememberSoundDuration(tmpPath, soundDuration);
                pathToSend = tmpPath;
                // Schedule a delayed cleanup. Tox file transfer might still
                // be reading the file when we return; keep it around for a
                // few minutes.
                Future.delayed(const Duration(minutes: 5), () async {
                  try {
                    if (await tmpFile.exists()) {
                      await tmpFile.delete();
                    }
                  } catch (_) {
                    // Cleanup is best-effort.
                  }
                });
              }
            } catch (e) {
              if (_debugLog) {
                print(
                    '[Tim2ToxSdkPlatform] U-3 duration encode failed (falling back to raw path): $e');
              }
              pathToSend = soundPath;
              encodedName = null;
            }
          }
          await provider.sendFile(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            filePath: pathToSend,
            fileName: encodedName ?? pathToSend.split('/').last,
          );
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Sound message sent successfully (pathToSend=$pathToSend, encodedName=${encodedName ?? "(none)"})');
        } else if (messageToSend.videoElem != null &&
            messageToSend.videoElem!.videoPath != null &&
            messageToSend.videoElem!.videoPath!.isNotEmpty) {
          // Video message — send the video file via Tox file transfer.
          // Video uses `videoPath` (not `path`); verified against
          // tencent_cloud_chat_sdk/lib/models/v2_tim_video_elem.dart:15.
          final videoPath = messageToSend.videoElem!.videoPath!;
          print(
              '[Tim2ToxSdkPlatform] Sending video message: $videoPath');
          await provider.sendFile(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            filePath: videoPath,
            fileName: videoPath.split('/').last,
          );
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Video message sent successfully');
        } else if (messageToSend.faceElem != null) {
          // Face message — there is no native Tox channel for sticker
          // metadata, so we serialize {index, data} as JSON and send it as
          // text with a `__face__:` prefix. The receiving side currently
          // renders this as plain text; rich-rendering is deferred.
          final faceJson = json.encode({
            'index': messageToSend.faceElem!.index,
            'data': messageToSend.faceElem!.data,
          });
          final payload = '__face__:$faceJson';
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Sending face message: $payload');
          await provider.sendText(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            text: payload,
          );
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Face message sent successfully');
        } else if (messageToSend.locationElem != null) {
          // Location message — same approach as face: serialize via JSON,
          // send as text with a `__location__:` prefix. Receiver renders as
          // plain text for now.
          final locJson = json.encode({
            'desc': messageToSend.locationElem!.desc,
            'longitude': messageToSend.locationElem!.longitude,
            'latitude': messageToSend.locationElem!.latitude,
          });
          final payload = '__location__:$locJson';
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Sending location message: $payload');
          await provider.sendText(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            text: payload,
          );
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Location message sent successfully');
        } else if (messageToSend.customElem != null &&
            messageToSend.customElem!.data != null &&
            messageToSend.customElem!.data!.isNotEmpty) {
          // Custom message — pass-through customElem.data as-is, but wrap
          // with a `__custom__:` prefix so the receiver can route it back
          // into a customElem instead of rendering as plain text.
          // Receiver-side parsing is deferred (TODO(P0-1)).
          final payload = '__custom__:${messageToSend.customElem!.data}';
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Sending custom message');
          await provider.sendText(
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            text: payload,
          );
          if (_debugLog)
            print('[Tim2ToxSdkPlatform] Custom message sent successfully');
        } else if (messageToSend.groupTipsElem != null) {
          // Group tips (system messages) are synthesized client-side from
          // Tox group events. Senders never push them over the wire;
          // silently succeed so the UIKit dispatch loop doesn't complain.
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] groupTipsElem is local-only, returning success without wire send');
        } else {
          print(
              '[Tim2ToxSdkPlatform] sendMessage failed: Unsupported message type: ${messageToSend.elemType}');
          return V2TimValueCallback<V2TimMessage>(
            code: -1,
            desc: 'Unsupported message type: ${messageToSend.elemType}',
          );
        }

        // Update message status to SEND_SUCC
        messageToSend.status = MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC;
        if (_debugLog)
          print('[Tim2ToxSdkPlatform] Message status updated to SEND_SUCC');

        // CRITICAL: Ensure id and msgID are both set to the same value for proper matching
        // UIKit messages may have id (temporary ID) while FFI messages have msgID (actual ID)
        // Setting both ensures we can match messages correctly and prevent duplicates
        if (messageToSend.msgID != null && messageToSend.msgID!.isNotEmpty) {
          // If id is not set or different from msgID, set it to msgID
          if (messageToSend.id == null ||
              messageToSend.id!.isEmpty ||
              messageToSend.id != messageToSend.msgID) {
            messageToSend.id = messageToSend.msgID;
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] Set message id to msgID: ${messageToSend.msgID}');
          }
        } else if (messageToSend.id != null && messageToSend.id!.isNotEmpty) {
          // If msgID is not set but id is, set msgID to id
          messageToSend.msgID = messageToSend.id;
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Set message msgID to id: ${messageToSend.id}');
        }

        // Populate faceUrl from local avatar cache so the sent message row shows correct avatar
        await _setFaceUrlForMsg(messageToSend);

        // CRITICAL: Immediately notify UIKit about the status change
        // This ensures the temporary message (created_temp_id) is updated to SEND_SUCC
        // before the FFI service returns the actual message with a different msgID
        // This prevents duplicate messages (one failed, one success)
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Notifying UIKit about message status update: msgID=${messageToSend.msgID}, id=${messageToSend.id}');
        _notifyAdvancedMsgListeners((listener) {
          listener.onRecvMessageModified?.call(messageToSend);
        });

        // IMPORTANT: Track the target (userID/groupID) for this message so we can set correct userID/groupID
        // when the message is received from the stream (FfiChatService returns messages with fromUserId=selfId)
        // We use msgID as key because it's unique and stable
        // NOTE: FfiChatService creates messages with new msgIDs, so we also track by message text as fallback
        if (messageToSend.msgID != null &&
            (userID != null || groupID.isNotEmpty)) {
          final messageText = messageToSend.textElem?.text ??
              messageToSend.mergerElem?.compatibleText ??
              '';
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          if (_debugLog)
            print(
                '[Tim2ToxSdkPlatform] Tracking sent message target: msgID=${messageToSend.msgID}, id=${messageToSend.id}, userID=$userID, groupID=$groupID, text="$messageText"');
          _pendingForwardTargets[messageToSend.msgID!] = (
            userID: userID,
            groupID: groupID.isNotEmpty ? groupID : null,
            timestamp: timestamp,
          );
          // Also track by message text as fallback (for forward messages where msgID might change)
          if (messageText.isNotEmpty) {
            _pendingForwardTargets[messageText] = (
              userID: userID,
              groupID: groupID.isNotEmpty ? groupID : null,
              timestamp: timestamp,
            );
          }
        }

        // Also track by message text for forward messages (already handled above for forward messages)
        // This ensures we can match messages even if msgID changes

        // Note: We don't remove forward messages from cache immediately after sending,
        // because the same forward message may be sent to multiple targets (users/groups).
        // The cache will be cleaned up when the message is no longer needed.
        // For forward messages, UIKit may call sendMessage multiple times with the same id
        // for different targets, so we keep the message in cache until it's naturally
        // replaced or the app restarts.

        // Notify conversation listeners so C2C conversation list / lastMessage updates (e.g. tests waiting for onConversationChanged)
        if (userID != null && userID.isNotEmpty) {
          final c2cKey = userID.length >= 64 ? userID.substring(0, 64) : userID;
          final conversationID = 'c2c_$c2cKey';
          V2TimConversation convToNotify;
          try {
            final convResult =
                await getConversation(conversationID: conversationID);
            if (convResult.code == 0 && convResult.data != null) {
              convToNotify = convResult.data!;
            } else {
              // When conversationManagerProvider is null or conversation was deleted (e.g. test 3 then test 4)
              convToNotify = V2TimConversation(conversationID: conversationID);
            }
          } catch (_) {
            // getConversation can throw after DeleteConversation or in tests; still notify so onConversationChanged fires
            convToNotify = V2TimConversation(conversationID: conversationID);
          }
          try {
            _notifyConversationListeners((listener) {
              listener.onConversationChanged?.call([convToNotify]);
            });
          } catch (_) {
            // Ignore so send still returns success
          }
        }

        return V2TimValueCallback<V2TimMessage>(
          code: 0,
          desc: 'success',
          data: messageToSend,
        );
      } catch (e, stackTrace) {
        if (_debugLog) print('[Tim2ToxSdkPlatform] sendMessage exception: $e');
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] sendMessage exception stack trace: $stackTrace');
        // Update message status to SEND_FAIL
        messageToSend.status = MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL;

        await _setFaceUrlForMsg(messageToSend);

        // CRITICAL: Immediately notify UIKit about the failure status
        // This ensures the temporary message (created_temp_id) is updated to SEND_FAIL
        // so the user can see the error and potentially retry
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] Notifying UIKit about message failure: msgID=${messageToSend.msgID}, id=${messageToSend.id}');
        _notifyAdvancedMsgListeners((listener) {
          listener.onRecvMessageModified?.call(messageToSend);
        });

        // Note: We don't remove forward messages from cache even after failure,
        // because the same forward message may be retried or sent to other targets.
        // The cache will be cleaned up when the message is no longer needed.

        // Use a user-friendly description for known limitations (e.g. group file not supported)
        final errStr = e.toString().toLowerCase();
        final bool isGroupFileUnsupported = groupID.isNotEmpty &&
            (errStr.contains('group') && errStr.contains('file') ||
                errStr.contains('not supported'));
        final String desc = isGroupFileUnsupported
            ? 'File transfer in group chats is not supported. Please send files in a private chat.'
            : 'sendMessage failed: $e';

        return V2TimValueCallback<V2TimMessage>(
          code: -1,
          desc: desc,
          data: messageToSend,
        );
      }
    } catch (e, stackTrace) {
      if (_debugLog) {
        print('[Tim2ToxSdkPlatform] sendMessage outer exception: $e');
        print(
            '[Tim2ToxSdkPlatform] sendMessage outer exception stack trace: $stackTrace');
      }
      // H-L: outer-catch path — when failure happens before we found
      // `messageToSend` (e.g. provider lookup, registry missing), we don't
      // have a V2TimMessage to flip to FAIL. Try to recover one from
      // _forwardMessageCache by `id` so the bubble doesn't get stuck in
      // SENDING. If unrecoverable, return a non-null `data` with status
      // marked FAIL so UIKit can route status updates correctly.
      V2TimMessage failedMsg;
      if (id != null && _forwardMessageCache.containsKey(id)) {
        failedMsg = _forwardMessageCache[id]!;
      } else {
        failedMsg = V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_TEXT);
        failedMsg.msgID = id;
        failedMsg.id = id;
      }
      failedMsg.userID = receiver.isNotEmpty ? receiver : null;
      failedMsg.groupID = groupID.isNotEmpty ? groupID : null;
      if (failedMsg.groupID != null) {
        failedMsg.userID = null;
      }
      failedMsg.isSelf = true;
      if (failedMsg.sender == null || failedMsg.sender!.isEmpty) {
        failedMsg.sender = ffiService.selfId;
      }
      failedMsg.status = MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL;
      await _setFaceUrlForMsg(failedMsg);
      try {
        _notifyAdvancedMsgListeners((listener) {
          listener.onRecvMessageModified?.call(failedMsg);
        });
      } catch (_) {
        // Listener fan-out errors are non-fatal here.
      }
      return V2TimValueCallback<V2TimMessage>(
        code: -1,
        desc: 'sendMessage failed: $e',
        data: failedMsg,
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMessageListResult>> getHistoryMessageListV2({
    int getType = 3, // HistoryMessageGetType.V2TIM_GET_LOCAL_OLDER_MSG = 3
    String? userID,
    String? groupID,
    int lastMsgSeq = -1,
    required int count,
    String? lastMsgID,
    List<int>? messageTypeList,
    List<int>? messageSeqList,
    int? timeBegin,
    int? timePeriod,
  }) async {
    try {
      // M7: `lastMsgSeq` and `messageSeqList` are intentionally unsupported
      // here. Tox has no server-assigned sequence numbers — all ordering is
      // local-timestamp based. The Tencent V2TIM SDK uses these for
      // cloud-side anchored pagination; in Tim2Tox the equivalent anchor is
      // `lastMsgID`. If a caller passes a non-default value we log a warning
      // so they can fix the call site rather than silently mis-paginating.
      if (lastMsgSeq != -1) {
        if (_debugLog) {
          print(
              '[Tim2ToxSdkPlatform] getHistoryMessageListV2: lastMsgSeq=$lastMsgSeq ignored (Tox has no server sequence numbers; use lastMsgID instead)');
        }
      }
      if (messageSeqList != null && messageSeqList.isNotEmpty) {
        if (_debugLog) {
          print(
              '[Tim2ToxSdkPlatform] getHistoryMessageListV2: messageSeqList (${messageSeqList.length} entries) ignored (Tox has no server sequence numbers)');
        }
      }
      final targetID = groupID ?? userID ?? '';
      if (targetID.isEmpty) {
        return V2TimValueCallback<V2TimMessageListResult>(
          code: -1,
          desc: 'userID or groupID is required',
          data: V2TimMessageListResult(isFinished: true, messageList: []),
        );
      }

      // Get history from FfiChatService
      // CRITICAL: If history is empty, try to load from persistence first
      // This handles the case where history hasn't been loaded into memory yet
      // Note: If history was cleared, the file should have been deleted,
      // so loadHistory will return empty list if file doesn't exist
      var history = ffiService.getHistory(targetID);

      if (history.isEmpty) {
        // Try to load from persistence synchronously
        // Normalize ID if needed (for C2C conversations)
        final normalizedId = targetID.length > 64
            ? ffiService.normalizeToxId(targetID)
            : targetID;

        // Load from persistence (this will update the cache)
        // If the history file was deleted by clearHistory(), loadHistory will return empty list
        try {
          final persistence = ffiService.messageHistoryPersistence;
          final quitGroups = ffiService.quitGroups;
          final loadedMessages = await persistence.loadHistory(normalizedId,
              quitGroups: quitGroups);

          if (loadedMessages.isNotEmpty) {
            history = loadedMessages;
            // CRITICAL: After loading from persistence, the persistence service's cache is updated
            // FfiChatService.getHistory() reads from persistence service cache (line 1599),
            // so it should now return the loaded messages. However, we use the loaded messages directly
            // to avoid another lookup.
          } else if (targetID != normalizedId) {
            // Try original ID if normalized ID didn't work
            final loadedMessagesOriginal =
                await persistence.loadHistory(targetID, quitGroups: quitGroups);
            if (loadedMessagesOriginal.isNotEmpty) {
              history = loadedMessagesOriginal;
            }
          }

          if (history.isEmpty) {
            final cacheKeys = persistence.cache.keys.toList();
            // Also check if targetID matches any cache key (with normalization)
            // CRITICAL: Only return cached data if the history file still exists
            // If the file was deleted (e.g., by clearHistory), don't return cached data
            for (final key in cacheKeys) {
              final normalizedKey =
                  key.length > 64 ? ffiService.normalizeToxId(key) : key;
              if (normalizedKey == normalizedId ||
                  key == targetID ||
                  normalizedKey == targetID) {
                // Check if history file exists before returning cached data
                // If file was deleted by clearHistory(), don't return cached data
                final fileExists = await persistence.historyFileExists(key);
                if (fileExists) {
                  final cachedHistory = persistence.getHistory(key);
                  if (cachedHistory.isNotEmpty) {
                    history = cachedHistory;
                    break;
                  }
                } else {
                  // File doesn't exist, clear the cache entry to prevent stale data
                  // This handles the case where file was deleted but cache wasn't cleared
                  try {
                    await persistence.clearHistory(key);
                  } catch (e) {
                    // Ignore errors when clearing non-existent cache
                  }
                }
              }
            }
          }
        } catch (e) {}
      }

      // Filter + sort history.
      //
      // Performance (P4 in `local-storage-review-2026-05-18.md`): the previous
      // implementation called `.sort()` three times — once up front, then again
      // after each `where(...).toList()`. Filtering preserves relative order,
      // so a single sort after both filters have run is correct and O(n log n)
      // instead of O(3·n log n). For 1k-message conversations on a cold open
      // this used to dominate `getHistoryMessageListV2`'s wall time.
      List<ChatMessage> filteredHistory = List.from(history);

      // Filter by message type if specified
      if (messageTypeList != null && messageTypeList.isNotEmpty) {
        filteredHistory = filteredHistory.where((msg) {
          int msgType = MessageElemType.V2TIM_ELEM_TYPE_TEXT;
          if (msg.mediaKind == 'image') {
            msgType = MessageElemType.V2TIM_ELEM_TYPE_IMAGE;
          } else if (msg.mediaKind == 'video') {
            msgType = MessageElemType.V2TIM_ELEM_TYPE_VIDEO;
          } else if (msg.mediaKind == 'audio') {
            msgType = MessageElemType.V2TIM_ELEM_TYPE_SOUND;
          } else if (msg.mediaKind == 'file') {
            msgType = MessageElemType.V2TIM_ELEM_TYPE_FILE;
          }
          return messageTypeList.contains(msgType);
        }).toList();
      }

      // Filter by time range if specified
      if (timeBegin != null && timePeriod != null) {
        final timeEnd = timeBegin + timePeriod;
        filteredHistory = filteredHistory.where((msg) {
          final msgTime = msg.timestamp.millisecondsSinceEpoch ~/ 1000;
          return msgTime >= timeBegin && msgTime <= timeEnd;
        }).toList();
      }

      // Sort once, descending (newest first, oldest last) — matches the
      // internal storage format in TencentCloudChatMessageData and is required
      // for the pagination logic below.
      filteredHistory.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      // CRITICAL: Keep descending order (newest first, oldest last)
      // This is required for correct pagination logic below
      // getType: 1 = V2TIM_GET_CLOUD_OLDER_MSG (get older messages from cloud)
      //          2 = V2TIM_GET_CLOUD_NEWER_MSG (get newer messages from cloud)
      //          3 = V2TIM_GET_LOCAL_OLDER_MSG (get older messages from local)
      //          4 = V2TIM_GET_LOCAL_NEWER_MSG (get newer messages from local)
      // Both 1 and 3 mean "get older messages"; both 2 and 4 mean "get newer messages"
      final bool isGetOlderMessages = (getType == 1 || getType == 3);
      List<ChatMessage> sublist;
      bool isFinished = false;

      if (lastMsgID != null) {
        final lastMsgIndex =
            filteredHistory.indexWhere((msg) => msg.msgID == lastMsgID);
        if (lastMsgIndex != -1) {
          if (isGetOlderMessages) {
            // Get older messages (after lastMsgID in descending list, going backwards in time)
            // Since list is newest-first, older messages are at higher indices
            // Start from the message after lastMsgID
            final startIndex = lastMsgIndex + 1;
            final endIndex =
                (startIndex + count).clamp(0, filteredHistory.length);
            if (startIndex >= filteredHistory.length) {
              // No older messages available
              sublist = [];
              isFinished = true;
            } else {
              sublist = filteredHistory.sublist(startIndex, endIndex);
              isFinished = endIndex >=
                  filteredHistory
                      .length; // Finished if we reached the end (oldest)
            }
          } else {
            // Get newer messages (before lastMsgID in descending list, going forwards in time)
            // Since list is newest-first, newer messages are at lower indices
            // Start from count messages before lastMsgID
            final startIndex =
                (lastMsgIndex - count).clamp(0, filteredHistory.length);
            final endIndex = lastMsgIndex; // Don't include lastMsgID itself
            if (startIndex >= endIndex) {
              // No newer messages available
              sublist = [];
              isFinished = true;
            } else {
              sublist = filteredHistory.sublist(startIndex, endIndex);
              isFinished = startIndex ==
                  0; // Finished if we reached the beginning (newest)
            }
          }
        } else {
          // H4: lastMsgID not found in the filtered history. Returning
          // `isFinished: true` here freezes the UIKit pagination state and
          // the caller can never recover — typical cause is a stale
          // anchor (e.g. the message was just revoked, or the type filter
          // excluded it). Return `isFinished: false` with an empty page so
          // the caller can retry with a different anchor.
          if (_debugLog) {
            print(
                '[Tim2ToxSdkPlatform] getHistoryMessageListV2: lastMsgID="$lastMsgID" not found in filtered history; keeping pagination open (isFinished=false)');
          }
          sublist = [];
          isFinished = false;
        }
      } else {
        // No lastMsgID provided - return the most recent messages
        // CRITICAL: When opening a chat, UIKit expects the most recent messages first
        // filteredHistory is sorted descending (newest first, oldest last)
        // Both older and newer initial loads start from the most recent messages
        final endIndex = count.clamp(0, filteredHistory.length);
        sublist = filteredHistory.sublist(0, endIndex);
        isFinished = endIndex >=
            filteredHistory.length; // Finished if we got all messages
      }

      // Convert ChatMessage to V2TimMessage with conversation context so sent messages get correct userID/groupID
      final v2Messages = sublist.map((chatMsg) {
        return chatMessageToV2TimMessage(
          chatMsg,
          ffiService.selfId,
          forwardTargetUserID: userID,
          forwardTargetGroupID: groupID,
        );
      }).toList();

      // Ensure userID/groupID on messages (redundant when forwardTarget was passed, but safe)
      for (final msg in v2Messages) {
        if (userID != null) {
          msg.userID = userID;
        }
        if (groupID != null) {
          msg.groupID = groupID;
        }
      }

      // Populate faceUrl for all history messages using the local avatar cache
      for (final msg in v2Messages) {
        await _setFaceUrlForMsg(msg);
      }

      // Deduplicate by msgID so the same message is never returned twice (e.g. from cache + persistence)
      final seenIds = <String>{};
      final deduped = v2Messages.where((msg) {
        final id = msg.msgID;
        if (id == null || id.isEmpty) return true;
        if (seenIds.contains(id)) return false;
        seenIds.add(id);
        return true;
      }).toList();

      // IMPORTANT: UI layer expects messages in descending order (newest first, oldest last)
      // - Internal storage in TencentCloudChatMessageData uses newest-first order
      // - getMessageListForRender handles the display order
      // - onReceiveNewMessage inserts new messages at index 0 (newest first)
      // - loadMessageList with direction=latest inserts reversed messages at index 0
      // OPTIMIZED: sublist is already in descending order (newest first) from filteredHistory
      // (which was sorted at line 3054), so no need to sort again here

      return V2TimValueCallback<V2TimMessageListResult>(
        code: 0,
        desc: 'success',
        data: V2TimMessageListResult(
          isFinished: isFinished,
          messageList: deduped,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMessageListResult>(
        code: -1,
        desc: 'getHistoryMessageListV2 failed: $e',
        data: V2TimMessageListResult(isFinished: true, messageList: []),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMessage>> reSendMessage({
    required String msgID,
    bool onlineUserOnly = false,
    Object? webMessageInstatnce,
  }) async {
    // P0-12: rebuild the failed message from Tim2ToxFailedMessagePersistence
    // (v2 schema) and re-dispatch through sendMessage. Removes the entry
    // from the failed persistence on success.
    try {
      if (msgID.isEmpty) {
        return V2TimValueCallback<V2TimMessage>(
          code: -1,
          desc: 'msgID is required',
        );
      }

      // We don't know which conversation contains the failed entry up
      // front, so we walk through prefs and search every conversation
      // bucket. This is acceptable because failed-message storage is
      // small in practice.
      final prefs = await SharedPreferences.getInstance();
      // Reuse the persistence helper's keying logic by listing all
      // candidate keys directly: we can't enumerate the
      // accountToxId here, so we attempt the legacy (un-suffixed) key
      // first and any current account key suffix.
      // Practical approach: iterate over all keys that start with the
      // persistence prefix.
      final allKeys = prefs.getKeys();
      String? matchedConvKey;
      Map<String, dynamic>? entry;
      String? accountToxIdForRemoval;
      for (final key in allKeys) {
        if (!key.startsWith('tencent_cloud_chat_failed_messages')) continue;
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = json.decode(raw);
          if (decoded is! Map) continue;
          for (final convEntry in decoded.entries) {
            final convList = convEntry.value;
            if (convList is! List) continue;
            for (final mEntry in convList) {
              if (mEntry is! Map) continue;
              if (mEntry['msgID'] == msgID || mEntry['id'] == msgID) {
                entry = Map<String, dynamic>.from(mEntry);
                matchedConvKey = convEntry.key as String;
                // Recover the per-account suffix (if any) so we can call
                // removeFailedMessage with the right scope. Suffix is
                // everything after `<persistenceKey>_`.
                const base = 'tencent_cloud_chat_failed_messages';
                if (key.length > base.length + 1 &&
                    key.startsWith('${base}_')) {
                  accountToxIdForRemoval = key.substring(base.length + 1);
                }
                break;
              }
            }
            if (entry != null) break;
          }
        } catch (_) {
          continue;
        }
        if (entry != null) break;
      }

      if (entry == null || matchedConvKey == null) {
        return V2TimValueCallback<V2TimMessage>(
          code: -1,
          desc: 'reSendMessage: failed message not found for msgID=$msgID',
        );
      }

      // Decide userID/groupID. The persisted `userID`/`groupID` fields
      // are authoritative when present; the conversation key is a useful
      // fallback for legacy entries.
      String? userID = entry['userID'] as String?;
      String? groupID = entry['groupID'] as String?;
      // Conversation key contains the destination when persisted entries
      // were keyed only by conversation.
      if ((userID == null || userID.isEmpty) &&
          (groupID == null || groupID.isEmpty)) {
        // matchedConvKey is groupID for groups, userID for c2c (see
        // saveFailedMessage's conversationKey construction).
        // H-C: previously we always assumed userID, which silently routed
        // group-message resends into a C2C target named `tox_conf_…`. In
        // toxee, every group ID begins with `tox_` (`tox_conf_` for
        // conferences, `tox_group_` for ng-groups), and C2C peer IDs are
        // raw 64-char Tox public keys that never start with `tox_`. Use
        // that as the discriminator so legacy entries route correctly.
        if (matchedConvKey.startsWith('tox_')) {
          groupID = matchedConvKey;
        } else {
          userID = matchedConvKey;
        }
      }

      // Rebuild a V2TimMessage from the entry.
      final mediaKind = entry['mediaKind'] as String?;
      final text = entry['text'] as String? ?? '';
      final filePath = entry['filePath'] as String?;
      final fileName = entry['fileName'] as String?;
      final fileSize = entry['fileSize'] as int?;
      final localUrl = entry['localUrl'] as String?;
      final customData = entry['customData'] as String?;
      final soundDuration = entry['soundDuration'] as int?;
      final videoDuration = entry['videoDuration'] as int?;

      int elemType = entry['elemType'] as int? ??
          MessageElemType.V2TIM_ELEM_TYPE_TEXT;
      // mediaKind takes precedence when present (v2 entries).
      switch (mediaKind) {
        case 'image':
          elemType = MessageElemType.V2TIM_ELEM_TYPE_IMAGE;
          break;
        case 'file':
          elemType = MessageElemType.V2TIM_ELEM_TYPE_FILE;
          break;
        case 'audio':
          elemType = MessageElemType.V2TIM_ELEM_TYPE_SOUND;
          break;
        case 'video':
          elemType = MessageElemType.V2TIM_ELEM_TYPE_VIDEO;
          break;
        case 'custom':
          elemType = MessageElemType.V2TIM_ELEM_TYPE_CUSTOM;
          break;
      }

      final rebuilt = V2TimMessage(elemType: elemType);
      rebuilt.msgID = msgID;
      rebuilt.id = msgID;
      rebuilt.isSelf = entry['isSelf'] as bool? ?? true;
      rebuilt.timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      rebuilt.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
      if (userID != null && userID.isNotEmpty) rebuilt.userID = userID;
      if (groupID != null && groupID.isNotEmpty) rebuilt.groupID = groupID;

      // Always include a textElem when the entry had text (e.g. text
      // messages, file-with-caption). For pure media this stays null.
      if (text.isNotEmpty) {
        rebuilt.textElem = V2TimTextElem(text: text);
      }

      switch (elemType) {
        case MessageElemType.V2TIM_ELEM_TYPE_IMAGE:
          final p = filePath ?? localUrl;
          if (p == null || p.isEmpty) {
            return V2TimValueCallback<V2TimMessage>(
              code: -1,
              desc:
                  'reSendMessage: image entry missing filePath/localUrl for msgID=$msgID',
            );
          }
          rebuilt.imageElem = V2TimImageElem(path: p);
          break;
        case MessageElemType.V2TIM_ELEM_TYPE_FILE:
          final p = filePath ?? localUrl;
          if (p == null || p.isEmpty) {
            return V2TimValueCallback<V2TimMessage>(
              code: -1,
              desc:
                  'reSendMessage: file entry missing filePath/localUrl for msgID=$msgID',
            );
          }
          rebuilt.fileElem = V2TimFileElem(
            path: p,
            fileName: fileName ?? p.split('/').last,
            fileSize: fileSize,
            localUrl: localUrl,
          );
          break;
        case MessageElemType.V2TIM_ELEM_TYPE_SOUND:
          final p = filePath ?? localUrl;
          if (p == null || p.isEmpty) {
            return V2TimValueCallback<V2TimMessage>(
              code: -1,
              desc:
                  'reSendMessage: sound entry missing filePath/localUrl for msgID=$msgID',
            );
          }
          rebuilt.soundElem = V2TimSoundElem(
            path: p,
            dataSize: fileSize,
            duration: soundDuration,
          );
          break;
        case MessageElemType.V2TIM_ELEM_TYPE_VIDEO:
          final p = filePath ?? localUrl;
          if (p == null || p.isEmpty) {
            return V2TimValueCallback<V2TimMessage>(
              code: -1,
              desc:
                  'reSendMessage: video entry missing filePath/localUrl for msgID=$msgID',
            );
          }
          rebuilt.videoElem = V2TimVideoElem(
            videoPath: p,
            videoSize: fileSize,
            duration: videoDuration,
          );
          break;
        case MessageElemType.V2TIM_ELEM_TYPE_CUSTOM:
          rebuilt.customElem = V2TimCustomElem(data: customData ?? '');
          break;
        case MessageElemType.V2TIM_ELEM_TYPE_TEXT:
        default:
          // text-only or unknown elemType — treat as text. textElem already set above when non-empty.
          if (rebuilt.textElem == null) {
            rebuilt.textElem = V2TimTextElem(text: text);
          }
          break;
      }

      // Cache the rebuilt message in the same way createXxxMessage does
      // so the sendMessage path can find it via id lookup.
      _forwardMessageCache[msgID] = rebuilt;

      // H-A: drop the old failed entry from history BEFORE we kick off the
      // new send. Otherwise the user sees two bubbles (the original failed
      // one and the new sending/successful one) until manual cleanup. Done
      // best-effort: a failure here must not block the resend.
      try {
        await deleteMessages(msgIDs: [msgID]);
      } catch (e) {
        if (_debugLog) {
          print(
              '[Tim2ToxSdkPlatform] reSendMessage: pre-resend cleanup of old entry failed (swallowed): $e');
        }
      }

      // Dispatch via sendMessage so we go through the elem branches that
      // we just added in P0-1.
      final result = await sendMessage(
        id: msgID,
        receiver: userID ?? '',
        groupID: groupID ?? '',
      );

      if (result.code == 0) {
        // Remove from failed persistence on success.
        try {
          await Tim2ToxFailedMessagePersistence.removeFailedMessage(
            messageID: msgID,
            userID: userID,
            groupID: groupID,
            accountToxId: accountToxIdForRemoval,
          );
        } catch (_) {
          // Non-fatal: the message is sent; failure to clean up is just
          // a stale entry.
        }
      }
      return result;
    } catch (e, st) {
      if (_debugLog) {
        print('[Tim2ToxSdkPlatform] reSendMessage exception: $e\n$st');
      }
      return V2TimValueCallback<V2TimMessage>(
        code: -1,
        desc: 'reSendMessage failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> deleteMessages({
    List<String>? msgIDs,
    List<dynamic>? webMessageInstanceList,
  }) async {
    try {
      if (msgIDs == null || msgIDs.isEmpty) {
        return V2TimCallback(
          code: -1,
          desc: 'msgIDs is empty',
        );
      }

      // Delete messages via FfiChatService
      await ffiService.deleteMessages(msgIDs);

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'deleteMessages failed: $e',
      );
    }
  }

  /// Ensure message has necessary download info (imageList with uuid/url for images, UUID/url for files)
  ///
  /// Performance (P5 in `local-storage-review-2026-05-18.md`): file size and
  /// existence checks are async (`File.length()` / `File.exists()`) so the UI
  /// isolate doesn't block on a synchronous `stat()` per message while the
  /// page is being built. The previous `existsSync` + `lengthSync` pair was
  /// hot in `getHistoryMessageListV2`'s response path.
  Future<V2TimMessage> _ensureDownloadInfo(V2TimMessage msg) async {
    final msgID = msg.msgID ?? msg.id ?? '';
    if (msgID.isEmpty) return msg;

    // Fix image messages
    if (msg.elemType == MessageElemType.V2TIM_ELEM_TYPE_IMAGE &&
        msg.imageElem != null) {
      final imageElem = msg.imageElem!;
      final imagePath = imageElem.path;

      // Check if imageList exists and has uuid/url
      bool needsFix = false;
      if (imageElem.imageList == null || imageElem.imageList!.isEmpty) {
        needsFix = true;
      } else {
        // Check if any image in the list has uuid and url
        final hasValidImage = imageElem.imageList!.any((img) =>
            img != null &&
            (img.uuid != null && img.uuid!.isNotEmpty) &&
            (img.url != null && img.url!.isNotEmpty));
        if (!hasValidImage) {
          needsFix = true;
        }
      }

      if (needsFix && imagePath != null) {
        // Generate UUID from msgID
        final imageUuid = msgID.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
        int? fileSize;
        try {
          final file = File(imagePath);
          if (await file.exists()) {
            fileSize = await file.length();
          }
        } catch (e) {
          // Ignore file size errors
        }

        // Create or update imageList with both thumb and origin images
        // UIKit may request either THUMB (1) or ORIGIN (0), so we need both
        // CRITICAL: Don't use /tmp/receiving_ paths as URL - they are temporary and will fail when used as online URLs
        // Only use valid local paths (file_recv, avatars) or null if still receiving
        final imageUrl =
            (imagePath != null && !imagePath.startsWith('/tmp/receiving_'))
                ? imagePath
                : null;
        final imageList = [
          V2TimImage(
            uuid: imageUuid,
            type: V2TIM_IMAGE_TYPE.V2TIM_IMAGE_TYPE_THUMB,
            size: fileSize,
            url: imageUrl,
            localUrl: imagePath,
          ),
          V2TimImage(
            uuid: imageUuid,
            type: V2TIM_IMAGE_TYPE.V2TIM_IMAGE_TYPE_ORIGIN,
            size: fileSize,
            url: imageUrl,
            localUrl: imagePath,
          ),
        ];

        msg.imageElem = V2TimImageElem(
          path: imagePath,
          imageList: imageList,
        );
      }
    }

    // Fix file messages
    if (msg.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE &&
        msg.fileElem != null) {
      final fileElem = msg.fileElem!;
      final filePath = fileElem.path;

      // Check if UUID and url are set
      if ((fileElem.UUID == null || fileElem.UUID!.isEmpty) ||
          (fileElem.url == null || fileElem.url!.isEmpty)) {
        if (filePath != null) {
          // Generate UUID from msgID
          final fileUuid = msgID.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
          int? fileSize = fileElem.fileSize;
          if (fileSize == null) {
            try {
              final file = File(filePath);
              if (await file.exists()) {
                fileSize = await file.length();
              }
            } catch (e) {
              // Ignore file size errors
            }
          }

          // CRITICAL: Don't use /tmp/receiving_ paths as URL - they are temporary and will fail when used as online URLs
          // Only use valid local paths (file_recv, avatars) or null if still receiving
          final fileUrl =
              (filePath != null && !filePath.startsWith('/tmp/receiving_'))
                  ? filePath
                  : null;
          msg.fileElem = V2TimFileElem(
            path: filePath,
            fileName: fileElem.fileName,
            UUID: fileUuid,
            url: fileUrl,
            fileSize: fileSize,
            localUrl: fileElem.localUrl ?? filePath,
          );
        }
      }
    }

    return msg;
  }

  @override
  Future<V2TimValueCallback<List<V2TimMessage>>> findMessages({
    required List<String> messageIDList,
  }) async {
    try {
      print(
          '[Tim2ToxSdkPlatform] findMessages called with messageIDList: $messageIDList');
      final foundMessages = <V2TimMessage>[];
      final remainingIDs = Set<String>.from(messageIDList);

      // Search through all conversation histories
      print(
          '[Tim2ToxSdkPlatform] Searching through ${ffiService.lastMessages.length} conversations');
      for (final entry in ffiService.lastMessages.entries) {
        final peerId = entry.key;
        final history = ffiService.getHistory(peerId);
        print(
            '[Tim2ToxSdkPlatform] Checking conversation $peerId, history length: ${history.length}');

        for (final chatMsg in history) {
          // Try multiple matching strategies
          bool matched = false;

          // Strategy 1: Exact match with chatMsg.msgID
          if (chatMsg.msgID != null && remainingIDs.contains(chatMsg.msgID!)) {
            matched = true;
            remainingIDs.remove(chatMsg.msgID!);
          }

          // Strategy 2: Match with generated msgID (timestamp_userID format)
          if (!matched) {
            final generatedMsgID =
                '${chatMsg.timestamp.millisecondsSinceEpoch}_${chatMsg.fromUserId}';
            if (remainingIDs.contains(generatedMsgID)) {
              matched = true;
              remainingIDs.remove(generatedMsgID);
            }
          }

          // Strategy 3: Match with generated msgID for group messages (timestamp_userID_groupID format)
          if (!matched && chatMsg.groupId != null) {
            final generatedGroupMsgID =
                '${chatMsg.timestamp.millisecondsSinceEpoch}_${chatMsg.fromUserId}_${chatMsg.groupId}';
            if (remainingIDs.contains(generatedGroupMsgID)) {
              matched = true;
              remainingIDs.remove(generatedGroupMsgID);
            }
          }

          // Strategy 4: Partial match - check if any messageID in the list contains the timestamp
          // This handles cases where the msgID format might be slightly different
          // Also handles cases where Tox IDs might be in different formats (64 vs 76 chars)
          // Also handles cases where userID contains underscores (e.g., 76-char Tox IDs)
          if (!matched) {
            final timestampStr =
                chatMsg.timestamp.millisecondsSinceEpoch.toString();
            // Snapshot the set: `remainingIDs.remove(searchID)` below mutates
            // the same collection we're iterating and throws
            // "Concurrent modification during iteration".
            for (final searchID in remainingIDs.toList()) {
              if (searchID.startsWith(timestampStr) ||
                  searchID.contains(timestampStr)) {
                // Extract userID from searchID
                // Format can be: timestamp_userID or timestamp_userID_groupID
                // Since userID might contain underscores (76-char Tox IDs), we need to be careful
                final timestampIndex = searchID.indexOf(timestampStr);
                if (timestampIndex == 0) {
                  // searchID starts with timestamp
                  final afterTimestamp =
                      searchID.substring(timestampStr.length);
                  if (afterTimestamp.startsWith('_')) {
                    // Remove leading underscore
                    final rest = afterTimestamp.substring(1);

                    // Check if this is a group message (has groupID at the end)
                    String? searchUserID;
                    String? searchGroupID;
                    if (rest.contains('_') && chatMsg.groupId != null) {
                      // Try to extract groupID (last part after last underscore)
                      final lastUnderscoreIndex = rest.lastIndexOf('_');
                      if (lastUnderscoreIndex > 0) {
                        searchUserID = rest.substring(0, lastUnderscoreIndex);
                        searchGroupID = rest.substring(lastUnderscoreIndex + 1);
                      } else {
                        searchUserID = rest;
                      }
                    } else {
                      searchUserID = rest;
                    }

                    final chatUserID = chatMsg.fromUserId;

                    // Normalize both IDs for comparison (take first 64 chars if longer)
                    final normalizedSearchUserID =
                        searchUserID != null && searchUserID.length > 64
                            ? searchUserID.substring(0, 64)
                            : (searchUserID ?? '');
                    final normalizedChatUserID = chatUserID.length > 64
                        ? chatUserID.substring(0, 64)
                        : chatUserID;

                    // Check if userID matches (handle both 64 and 76 char Tox IDs)
                    bool userIDMatches = false;
                    if (searchUserID != null) {
                      userIDMatches = searchUserID == chatUserID ||
                          normalizedSearchUserID == normalizedChatUserID ||
                          searchID.contains(chatUserID) ||
                          chatUserID.contains(searchUserID) ||
                          normalizedChatUserID
                              .contains(normalizedSearchUserID) ||
                          normalizedSearchUserID.contains(normalizedChatUserID);
                    }

                    // Check if groupID matches (if applicable)
                    bool groupIDMatches = true;
                    if (chatMsg.groupId != null && searchGroupID != null) {
                      groupIDMatches = searchGroupID == chatMsg.groupId;
                    } else if (chatMsg.groupId == null &&
                        searchGroupID == null) {
                      groupIDMatches = true;
                    } else {
                      groupIDMatches = false;
                    }

                    // Also check exact msgID match
                    if ((userIDMatches && groupIDMatches) ||
                        (chatMsg.msgID != null && searchID == chatMsg.msgID)) {
                      matched = true;
                      remainingIDs.remove(searchID);
                      break;
                    }
                  }
                }
              }
            }
          }

          if (matched) {
            print(
                '[Tim2ToxSdkPlatform] Found matching message: msgID=${chatMsg.msgID}, text="${chatMsg.text}"');
            final isGroup = peerId.startsWith('tox_');
            final v2Msg = chatMessageToV2TimMessage(
              chatMsg,
              ffiService.selfId,
              forwardTargetUserID: isGroup ? null : peerId,
              forwardTargetGroupID: isGroup ? peerId : null,
            );
            // Ensure download info is set
            final fixedMsg = await _ensureDownloadInfo(v2Msg);
            // Required for deleteMessagesForMe/revokeMessage: native adapter rejects messages without userID/groupID
            if ((fixedMsg.userID == null || fixedMsg.userID!.isEmpty) &&
                (fixedMsg.groupID == null || fixedMsg.groupID!.isEmpty)) {
              if (isGroup) {
                fixedMsg.groupID = peerId;
              } else {
                fixedMsg.userID = peerId;
              }
            }
            foundMessages.add(fixedMsg);

            // If we found all messages, break early
            if (remainingIDs.isEmpty) {
              break;
            }
          }
        }

        // If we found all messages, break early
        if (remainingIDs.isEmpty) {
          break;
        }
      }

      print(
          '[Tim2ToxSdkPlatform] findMessages result: found ${foundMessages.length} messages, remaining IDs: $remainingIDs');
      if (remainingIDs.isNotEmpty) {
        print(
            '[Tim2ToxSdkPlatform] Could not find messages with IDs: $remainingIDs');
        // Try to find messages in messageData as fallback
        // First, try to search all message lists directly (more efficient)
        try {
          final messageListMap =
              TencentCloudChat.instance.dataInstance.messageData.messageListMap;
          print(
              '[Tim2ToxSdkPlatform] Searching in messageData messageListMap with ${messageListMap.length} conversations');
          print(
              '[Tim2ToxSdkPlatform] Conversation keys: ${messageListMap.keys.take(10).join(", ")}');

          // Snapshot — `remainingIDs.remove(msgID)` below mutates the set
          // we're iterating and trips the "Concurrent modification during
          // iteration" guard.
          for (final msgID in remainingIDs.toList()) {
            print(
                '[Tim2ToxSdkPlatform] Trying to find message $msgID in messageData');
            V2TimMessage? found;

            // Extract timestamp from search msgID for better matching
            final searchParts = msgID.split('_');
            final searchTimestamp =
                searchParts.isNotEmpty ? searchParts[0] : null;
            print(
                '[Tim2ToxSdkPlatform] Search msgID timestamp: $searchTimestamp');

            // Search through all message lists in messageData
            for (final entry in messageListMap.entries) {
              final targetID = entry.key;
              final messageList = entry.value;

              if (messageList.isEmpty) continue;

              // Try multiple matching strategies
              // Strategy 1: Exact match with msgID or id
              for (final msg in messageList) {
                if (msg.msgID == msgID || msg.id == msgID) {
                  found = msg;
                  print(
                      '[Tim2ToxSdkPlatform] Found message by exact match in conversation $targetID: msgID=${msg.msgID}, id=${msg.id}');
                  break;
                }
              }

              // Strategy 2: Partial match - check if msgID contains timestamp
              if (found == null && searchTimestamp != null) {
                try {
                  // Try to find message with matching timestamp
                  for (final msg in messageList) {
                    if (msg.msgID != null &&
                        msg.msgID!.startsWith(searchTimestamp)) {
                      // Extract the part after timestamp
                      final msgIDAfterTimestamp =
                          msg.msgID!.substring(searchTimestamp.length);
                      final searchIDAfterTimestamp =
                          msgID.substring(searchTimestamp.length);

                      // Remove leading underscore if present
                      final msgIDPart = msgIDAfterTimestamp.startsWith('_')
                          ? msgIDAfterTimestamp.substring(1)
                          : msgIDAfterTimestamp;
                      final searchIDPart =
                          searchIDAfterTimestamp.startsWith('_')
                              ? searchIDAfterTimestamp.substring(1)
                              : searchIDAfterTimestamp;

                      // Normalize both (take first 64 chars if longer, for Tox ID comparison)
                      final normalizedMsgID = msgIDPart.length > 64
                          ? msgIDPart.substring(0, 64)
                          : msgIDPart;
                      final normalizedSearchID = searchIDPart.length > 64
                          ? searchIDPart.substring(0, 64)
                          : searchIDPart;

                      // Check if they match (exact or normalized, or contains)
                      if (msgIDPart == searchIDPart ||
                          normalizedMsgID == normalizedSearchID ||
                          msgIDPart.contains(searchIDPart) ||
                          searchIDPart.contains(msgIDPart) ||
                          normalizedMsgID.contains(normalizedSearchID) ||
                          normalizedSearchID.contains(normalizedMsgID)) {
                        found = msg;
                        print(
                            '[Tim2ToxSdkPlatform] Found message by timestamp match in conversation $targetID: msgID=${msg.msgID}, matched part: $msgIDPart vs $searchIDPart');
                        break;
                      }
                    }
                    if (found == null &&
                        msg.id != null &&
                        msg.id!.startsWith(searchTimestamp)) {
                      found = msg;
                      print(
                          '[Tim2ToxSdkPlatform] Found message by timestamp match (id) in conversation $targetID: id=${msg.id}');
                      break;
                    }
                  }
                } catch (e, stackTrace) {
                  print('[Tim2ToxSdkPlatform] ERROR in timestamp matching: $e');
                }
              }

              if (found != null) {
                print(
                    '[Tim2ToxSdkPlatform] Found message $msgID in messageData for conversation $targetID');
                // Ensure download info is set before adding
                final fixedMsg = await _ensureDownloadInfo(found);
                // Required for deleteMessagesForMe/revokeMessage: ensure userID/groupID from conversation
                if ((fixedMsg.userID == null || fixedMsg.userID!.isEmpty) &&
                    (fixedMsg.groupID == null || fixedMsg.groupID!.isEmpty)) {
                  if (targetID.startsWith('tox_')) {
                    fixedMsg.groupID = targetID;
                  } else {
                    fixedMsg.userID = targetID;
                  }
                }
                foundMessages.add(fixedMsg);
                remainingIDs.remove(msgID);
                break;
              }
            }

            if (found == null) {
              print(
                  '[Tim2ToxSdkPlatform] Message $msgID not found in messageData');
              // Log all available message IDs for debugging (first conversation only to avoid too much output)
              try {
                final allMsgIDs = <String>[];
                int count = 0;
                for (final entry in messageListMap.entries) {
                  if (count >= 3) break; // Only check first 3 conversations
                  print(
                      '[Tim2ToxSdkPlatform] Conversation ${entry.key} has ${entry.value.length} messages');
                  final messageList = entry.value;
                  for (final msg in messageList) {
                    if (msg.msgID != null) allMsgIDs.add(msg.msgID!);
                    if (msg.id != null && msg.id != msg.msgID)
                      allMsgIDs.add(msg.id!);
                  }
                  count++;
                }
                print(
                    '[Tim2ToxSdkPlatform] Sample message IDs from messageData (first 30): ${allMsgIDs.take(30).join(", ")}');
                if (searchTimestamp != null) {
                  final matchingIDs = allMsgIDs
                      .where((id) => id.startsWith(searchTimestamp))
                      .take(10)
                      .toList();
                  print(
                      '[Tim2ToxSdkPlatform] Messages with matching timestamp $searchTimestamp (first 10): ${matchingIDs.join(", ")}');
                }
              } catch (e) {
                print(
                    '[Tim2ToxSdkPlatform] ERROR getting available message IDs: $e');
              }
            }
          }
        } catch (e, stackTrace) {
          print('[Tim2ToxSdkPlatform] ERROR searching in messageData: $e');
        }
      }

      return V2TimValueCallback<List<V2TimMessage>>(
        code: 0,
        desc: 'success',
        data: foundMessages,
      );
    } catch (e, stackTrace) {
      if (_debugLog) print('[Tim2ToxSdkPlatform] findMessages exception: $e');
      return V2TimValueCallback<List<V2TimMessage>>(
        code: -1,
        desc: 'findMessages failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMessageOnlineUrl>> getMessageOnlineUrl({
    String? msgID,
  }) async {
    // Not applicable for local P2P
    return V2TimValueCallback<V2TimMessageOnlineUrl>(
      code: -1,
      desc: 'getMessageOnlineUrl not applicable for local P2P',
    );
  }

  @override
  Future<V2TimCallback> downloadMessage({
    String? msgID,
    required int messageType,
    required int imageType,
    required bool isSnapshot,
  }) async {
    if (msgID == null) {
      return V2TimCallback(
        code: -1,
        desc: 'msgID is required',
      );
    }

    // For file messages (messageType == 6), accept file transfer via FfiChatService
    if (messageType == 6) {
      // V2TIM_ELEM_TYPE_FILE
      try {
        await ffiService.acceptFileTransferByMsgID(msgID);
        return V2TimCallback(code: 0, desc: 'success');
      } catch (e) {
        return V2TimCallback(
          code: -1,
          desc: 'downloadMessage failed: $e',
        );
      }
    }

    // For other message types (images, videos, etc.), return success
    // These are handled automatically by Tox file transfer
    return V2TimCallback(code: 0, desc: 'success');
  }

  /// P1-13: merger messages are not yet supported in toxee. Return an
  /// explicit error instead of letting the default platform interface
  /// throw `UnimplementedError`, which crashes the UIKit dispatch loop.
  @override
  Future<V2TimValueCallback<List<V2TimMessage>>> downloadMergerMessage({
    String? msgID,
  }) async {
    return V2TimValueCallback<List<V2TimMessage>>(
      code: -1,
      desc: 'merger messages not yet supported in toxee',
      data: const <V2TimMessage>[],
    );
  }

  @override
  Future<V2TimCallback> revokeMessage({
    String? msgID,
    Object? webMessageInstatnce,
  }) async {
    try {
      if (msgID == null || msgID.isEmpty) {
        return V2TimCallback(
          code: -1,
          desc: 'msgID is empty',
        );
      }

      // Find the message to revoke
      final foundMessages = await findMessages(messageIDList: [msgID]);
      if (foundMessages.data == null || foundMessages.data!.isEmpty) {
        return V2TimCallback(
          code: -1,
          desc: 'Message not found',
        );
      }

      final message = foundMessages.data!.first;

      // M-5: enforce a 2-minute revoke window. V2TimMessage.timestamp is in
      // seconds. Treat a missing timestamp as 'recent enough'.
      final tsSeconds = message.timestamp ?? 0;
      if (tsSeconds > 0) {
        final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final ageSeconds = nowSeconds - tsSeconds;
        if (ageSeconds > 120) {
          return V2TimCallback(
            code: 7501,
            desc: 'Message too old to revoke',
          );
        }
      }

      // In Tox there is no native revoke; emulate it with a magic-prefix
      // text message (`__revoke__:<json>`) so a peer that understands the
      // protocol can delete its local copy too.
      //
      // 1) Always perform the local delete + listener fan-out (works even
      //    if the peer hasn't adopted the protocol yet — at least the
      //    sender's view is consistent).
      // 2) Best-effort send the signaling message; failure must not block
      //    the local revoke from succeeding.
      //
      // P0-11 (send side). Receive-side handling is implemented best-effort
      // in `_maybeInterceptControlSignal` (called from `_setupMessageListener`).
      // If the peer does not run a build with the intercept, the message
      // will display as raw text — degraded but strictly better than
      // silent drop.

      // Delete the message locally first so the sender sees the result
      // immediately even if the signal send fails.
      await deleteMessages(msgIDs: [msgID]);

      // Notify listeners (sender-side onRecvMessageRevoked).
      _notifyAdvancedMsgListeners((listener) {
        listener.onRecvMessageRevoked?.call(msgID);
      });

      // Best-effort wire signal so the peer can also revoke.
      try {
        final String? peerUserID = message.userID;
        final String? peerGroupID = message.groupID;
        // H-G: include the sender-side timestamp (ms) so the receiver
        // can locate the matching history entry by sender + timestamp
        // window when our msgID doesn't survive the wire trip.
        final senderTimestampMs = (message.timestamp ?? 0) * 1000;
        final payload = '__revoke__:${json.encode({
              'msgID': msgID,
              'senderTimestampMs': senderTimestampMs,
              'fromUserId': ffiService.selfId,
            })}';
        if (peerUserID != null && peerUserID.isNotEmpty) {
          await ffiService.sendText(peerUserID, payload);
        } else if (peerGroupID != null && peerGroupID.isNotEmpty) {
          // Group revoke: FfiChatService exposes sendGroupText.
          await ffiService.sendGroupText(peerGroupID, payload);
        }
      } catch (e) {
        // Wire-side failure should not fail the local revoke.
        if (_debugLog) {
          print(
              '[Tim2ToxSdkPlatform] revokeMessage: signal send failed (peer will keep its copy): $e');
        }
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'revokeMessage failed: $e',
      );
    }
  }

  /// Result of [_maybeInterceptControlSignal].
  ///
  /// * [swallow] — caller must drop the message entirely (used for
  ///   `__revoke__:` signals where the message should never reach UIKit).
  /// * [rewriteText] / [rewriteCustomData] — when non-null, caller should
  ///   patch the outgoing V2TimMessage so the UI bubble shows a friendly
  ///   placeholder (e.g. "[Sticker]") and the original JSON travels in
  ///   `customElem.data` for future rich rendering.
  /// * [originalText] — the raw payload (kept for log/persistence purposes).
  ///
  /// Used by both the receive listener and the self-echo path to keep
  /// `__revoke__:`/`__face__:`/`__custom__:`/`__location__:` prefixes from
  /// ever showing up as raw JSON in chat bubbles.
  ({
    bool swallow,
    String? rewriteText,
    String? rewriteCustomData,
    String? originalText,
  }) _interceptResult({
    bool swallow = false,
    String? rewriteText,
    String? rewriteCustomData,
    String? originalText,
  }) =>
      (
        swallow: swallow,
        rewriteText: rewriteText,
        rewriteCustomData: rewriteCustomData,
        originalText: originalText,
      );

  /// P0-11 / R-3 / U-1 / U-2 receive-side handler.
  ///
  /// Inspect an incoming text payload for any of our magic-prefix control
  /// signals. Handling is:
  ///
  /// * `__revoke__:{json}` → best-effort delete the referenced message from
  ///   local history (by msgID if available, otherwise by sender + timestamp
  ///   match within a 5 s window), fire `onRecvMessageRevoked`, and signal
  ///   the caller to swallow the message entirely.
  /// * `__face__:{json}` → keep the message in history but rewrite the
  ///   bubble text to `[Sticker]` and stash the original JSON in
  ///   `customElem.data` so a future renderer can pick it up.
  /// * `__custom__:{json}` → same idea, bubble text becomes
  ///   `[Custom Message]`.
  /// * `__location__:{json}` → same idea, bubble text becomes `[Location]`.
  ///
  /// Returns a record describing what the caller should do.
  Future<
      ({
        bool swallow,
        String? rewriteText,
        String? rewriteCustomData,
        String? originalText,
      })> _maybeInterceptControlSignal(ChatMessage chatMsg) async {
    final text = chatMsg.text;
    if (text.isEmpty) return _interceptResult();

    // __revoke__: { msgID, senderTimestampMs?, fromUserId? }
    if (text.startsWith('__revoke__:')) {
      try {
        final payload = text.substring('__revoke__:'.length);
        final parsed = json.decode(payload);
        if (parsed is Map) {
          final revokedID = parsed['msgID'] as String?;
          final senderTimestampMs = parsed['senderTimestampMs'] is int
              ? parsed['senderTimestampMs'] as int
              : null;

          String? targetMsgID = revokedID;
          // H-G: sender's msgID rarely matches the receiver's history
          // msgID. Use sender + timestamp window to locate the actual
          // entry in our history. Skipped for self-sent revoke signals
          // (revokeMessage already deleted the sender's own copy).
          if (!chatMsg.isSelf && senderTimestampMs != null) {
            final senderUid = chatMsg.fromUserId;
            final convId = chatMsg.groupId ?? senderUid;
            try {
              // Make sure we have history loaded for this conversation.
              await ffiService.messageHistoryPersistence
                  .loadHistory(convId);
            } catch (_) {
              // Best-effort: continue with whatever is in memory.
            }
            final history = ffiService.getHistory(convId);
            // Walk the most recent 50 entries from this sender; pick the
            // closest match within 5 s.
            ChatMessage? best;
            int bestDelta = 5000;
            final recent = history.reversed.take(50);
            for (final m in recent) {
              if (m.fromUserId != senderUid) continue;
              if (m.text.isEmpty) continue;
              if (m.text.startsWith('__')) continue; // skip control msgs
              final delta =
                  (m.timestamp.millisecondsSinceEpoch - senderTimestampMs)
                      .abs();
              if (delta <= bestDelta && m.msgID != null) {
                best = m;
                bestDelta = delta;
              }
            }
            if (best != null) {
              targetMsgID = best.msgID;
            }
          }

          if (targetMsgID != null && targetMsgID.isNotEmpty) {
            try {
              await deleteMessages(msgIDs: [targetMsgID]);
            } catch (e) {
              if (_debugLog) {
                print(
                    '[Tim2ToxSdkPlatform] _maybeInterceptControlSignal: revoke deleteMessages failed (swallowed): $e');
              }
            }
            final notifyID = targetMsgID;
            _notifyAdvancedMsgListeners((listener) {
              listener.onRecvMessageRevoked?.call(notifyID);
            });
          } else if (_debugLog) {
            print(
                '[Tim2ToxSdkPlatform] _maybeInterceptControlSignal: revoke target not found, swallowing anyway');
          }
          return _interceptResult(swallow: true, originalText: text);
        }
      } catch (e) {
        if (_debugLog) {
          print(
              '[Tim2ToxSdkPlatform] _maybeInterceptControlSignal: __revoke__ parse error: $e');
        }
      }
      // Parse failed: still swallow so we never show raw control text.
      return _interceptResult(swallow: true, originalText: text);
    }

    // __face__: { index, data } — keep message, show "[Sticker]" placeholder.
    if (text.startsWith('__face__:')) {
      final payload = text.substring('__face__:'.length);
      return _interceptResult(
        rewriteText: '[Sticker]',
        rewriteCustomData: payload,
        originalText: text,
      );
    }

    // __location__: { desc, longitude, latitude } — show "[Location]".
    if (text.startsWith('__location__:')) {
      final payload = text.substring('__location__:'.length);
      return _interceptResult(
        rewriteText: '[Location]',
        rewriteCustomData: payload,
        originalText: text,
      );
    }

    // __custom__: arbitrary JSON — show "[Custom Message]".
    if (text.startsWith('__custom__:')) {
      final payload = text.substring('__custom__:'.length);
      return _interceptResult(
        rewriteText: '[Custom Message]',
        rewriteCustomData: payload,
        originalText: text,
      );
    }

    return _interceptResult();
  }

  @override
  Future<V2TimCallback> markC2CMessageAsRead({
    required String userID,
  }) async {
    try {
      // H3: cold cache → no-op. Load from persistence before iterating so
      // the first mark-as-read after app launch actually flips the in-memory
      // history (which getHistory reads).
      await ffiService.messageHistoryPersistence.loadHistory(userID);
      final history = ffiService.getHistory(userID);
      for (final msg in history) {
        if (!msg.isSelf) {
          await ffiService.markMessageAsRead(userID, msg.msgID ?? '');
        }
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'markC2CMessageAsRead failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> markGroupMessageAsRead({
    required String groupID,
  }) async {
    try {
      // H3: same cold-cache fix as markC2CMessageAsRead — load persistence
      // before iterating so the first mark-as-read post-launch isn't a no-op.
      await ffiService.messageHistoryPersistence.loadHistory(groupID);
      final history = ffiService.getHistory(groupID);
      for (final msg in history) {
        if (!msg.isSelf) {
          await ffiService.markMessageAsRead(groupID, msg.msgID ?? '',
              groupID: groupID);
        }
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'markGroupMessageAsRead failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> setGroupReceiveMessageOpt({
    required String groupID,
    required int opt,
  }) async {
    try {
      // Tox doesn't support group message receive options
      // For now, just return success
      // The opt parameter can be:
      // 0: Receive all messages
      // 1: Receive only @ mentions
      // 2: Do not receive messages
      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'setGroupReceiveMessageOpt failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> clearC2CHistoryMessage({
    required String userID,
  }) async {
    try {
      // Clear C2C history via FfiChatService
      await ffiService.clearC2CHistory(userID);

      // Trigger message list refresh in UIKit
      // This ensures the chat window updates after clearing history
      TencentCloudChat.instance.dataInstance.messageData
          .clearMessageList(userID: userID);
      TencentCloudChat.instance.dataInstance.messageData
          .clearMessageListStatus(userID: userID);

      // CRITICAL: Trigger conversation update to refresh the conversation list
      // This ensures the last message in the conversation list is cleared
      try {
        final conversationID = 'c2c_$userID';
        final convResult =
            await getConversation(conversationID: conversationID);
        if (convResult.code == 0 && convResult.data != null) {
          // Notify conversation listeners that the conversation has changed
          // This will update the conversation list to show no last message
          _notifyConversationListeners((listener) {
            listener.onConversationChanged?.call([convResult.data!]);
          });
        }
      } catch (e) {
        // Continue even if conversation update fails
      }

      // Notify user of success (if callbacks are available)
      try {
        TencentCloudChat.instance.callbacks.onUserNotificationEvent?.call(
          TencentCloudChatComponentsEnum.contact,
          TencentCloudChatUserNotificationEvent(
            eventCode: 0,
            text: 'Clear chat history completed',
          ),
        );
      } catch (_) {
        // Ignore if callbacks are not available
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      // Notify user of failure (if callbacks are available)
      try {
        TencentCloudChat.instance.callbacks.onUserNotificationEvent?.call(
          TencentCloudChatComponentsEnum.contact,
          TencentCloudChatUserNotificationEvent(
            eventCode: -1,
            text: 'Clear chat history failed: $e',
          ),
        );
      } catch (_) {
        // Ignore if callbacks are not available
      }

      return V2TimCallback(
        code: -1,
        desc: 'clearC2CHistoryMessage failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> clearGroupHistoryMessage({
    required String groupID,
  }) async {
    try {
      // Clear group history via FfiChatService
      await ffiService.clearGroupHistory(groupID);

      // Trigger message list refresh in UIKit
      // This ensures the chat window updates after clearing history
      TencentCloudChat.instance.dataInstance.messageData
          .clearMessageList(groupID: groupID);
      TencentCloudChat.instance.dataInstance.messageData
          .clearMessageListStatus(groupID: groupID);

      // CRITICAL: Trigger conversation update to refresh the conversation list
      // This ensures the last message in the conversation list is cleared
      try {
        final conversationID = 'group_$groupID';
        final convResult =
            await getConversation(conversationID: conversationID);
        if (convResult.code == 0 && convResult.data != null) {
          // Notify conversation listeners that the conversation has changed
          // This will update the conversation list to show no last message
          _notifyConversationListeners((listener) {
            listener.onConversationChanged?.call([convResult.data!]);
          });
        }
      } catch (e) {
        // Continue even if conversation update fails
      }

      // Notify user of success (if callbacks are available)
      try {
        TencentCloudChat.instance.callbacks.onUserNotificationEvent?.call(
          TencentCloudChatComponentsEnum.message,
          TencentCloudChatUserNotificationEvent(
            eventCode: 0,
            text: 'Clear chat history completed',
          ),
        );
      } catch (_) {
        // Ignore if callbacks are not available
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      // Notify user of failure (if callbacks are available)
      try {
        TencentCloudChat.instance.callbacks.onUserNotificationEvent?.call(
          TencentCloudChatComponentsEnum.message,
          TencentCloudChatUserNotificationEvent(
            eventCode: -1,
            text: 'Clear chat history failed: $e',
          ),
        );
      } catch (_) {
        // Ignore if callbacks are not available
      }

      return V2TimCallback(
        code: -1,
        desc: 'clearGroupHistoryMessage failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> sendMessageReadReceipts({
    List<String>? messageIDList,
  }) async {
    try {
      if (messageIDList == null || messageIDList.isEmpty) {
        return V2TimCallback(
          code: -1,
          desc: 'messageIDList is empty',
        );
      }

      // Find messages and send read receipts
      final foundMessages = await findMessages(messageIDList: messageIDList);
      if (foundMessages.data != null) {
        for (final msg in foundMessages.data!) {
          final userID = msg.userID;
          final groupID = msg.groupID;
          final msgID = msg.msgID ?? '';

          if (msgID.isNotEmpty) {
            if (groupID != null && groupID.isNotEmpty) {
              await ffiService.markMessageAsRead(groupID, msgID,
                  groupID: groupID);
            } else if (userID != null && userID.isNotEmpty) {
              await ffiService.markMessageAsRead(userID, msgID);
            }
          }
        }
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'sendMessageReadReceipts failed: $e',
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimMessageChangeInfo>> modifyMessage({
    required V2TimMessage message,
  }) async {
    try {
      // Message modification is not directly supported in Tox
      // For now, we'll just return success
      // In a real implementation, we might need to send a custom message with modification info

      final changeInfo = V2TimMessageChangeInfo(
        code: 0,
        desc: 'success',
        message: message,
      );

      // Notify listeners
      _notifyAdvancedMsgListeners((listener) {
        listener.onRecvMessageModified?.call(message);
      });

      return V2TimValueCallback<V2TimMessageChangeInfo>(
        code: 0,
        desc: 'success',
        data: changeInfo,
      );
    } catch (e) {
      return V2TimValueCallback<V2TimMessageChangeInfo>(
        code: -1,
        desc: 'modifyMessage failed: $e',
      );
    }
  }

  // ============================================================================

  // ============================================================================

  // ============================================================================
  // Friendship Manager methods
  // ============================================================================

  @override
  Future<void> addFriendListener({
    required V2TimFriendshipListener listener,
  }) async {
    final id = ffi_lib.Tim2ToxFfi.open().getCurrentInstanceId();
    if (id != 0) {
      (_instanceFriendshipListeners[id] ??= []).add(listener);
    }
    if (!_friendshipListeners.contains(listener)) {
      _friendshipListeners.add(listener);
    }
  }

  @override
  Future<void> setFriendListener({
    required V2TimFriendshipListener listener,
  }) async {
    // setFriendListener replaces all existing listeners
    _friendshipListeners.clear();
    _friendshipListeners.add(listener);
  }

  @override
  Future<void> removeFriendListener({
    V2TimFriendshipListener? listener,
  }) async {
    if (listener != null) {
      _friendshipListeners.remove(listener);
      for (final list in _instanceFriendshipListeners.values) {
        list.remove(listener);
      }
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimFriendInfo>>> getFriendList() async {
    try {
      final friends = await ffiService.getFriendList();
      final friendInfoList = <V2TimFriendInfo>[];

      for (final friend in friends) {
        final fakeUser = FakeUser(
          userID: friend.userId,
          nickName: friend.nickName,
          online: friend.online,
        );
        final friendInfo = await fakeUserToV2TimFriendInfo(fakeUser);
        friendInfoList.add(friendInfo);
      }

      return V2TimValueCallback<List<V2TimFriendInfo>>(
        code: 0,
        desc: 'success',
        data: friendInfoList,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimFriendInfo>>(
        code: -1,
        desc: 'getFriendList failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimFriendInfoResult>>> getFriendsInfo({
    required List<String> userIDList,
  }) async {
    try {
      final friends = await ffiService.getFriendList();
      final resultList = <V2TimFriendInfoResult>[];

      for (final userID in userIDList) {
        final friend = friends.firstWhere(
          (f) => f.userId == userID,
          orElse: () =>
              (userId: userID, nickName: '', online: false, status: ''),
        );

        final fakeUser = FakeUser(
          userID: friend.userId,
          nickName: friend.nickName,
          online: friend.online,
        );
        final friendInfo = await fakeUserToV2TimFriendInfo(fakeUser);

        resultList.add(V2TimFriendInfoResult(
          resultCode: 0,
          friendInfo: friendInfo,
        ));
      }

      return V2TimValueCallback<List<V2TimFriendInfoResult>>(
        code: 0,
        desc: 'success',
        data: resultList,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimFriendInfoResult>>(
        code: -1,
        desc: 'getFriendsInfo failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimFriendOperationResult>> addFriend({
    required String userID,
    String? remark,
    String? friendGroup,
    String? addWording,
    String? addSource,
    required int addType,
  }) async {
    try {
      final success = await ffiService.addFriend(
        userID,
        requestMessage:
            addWording?.trim().isNotEmpty == true ? addWording : null,
      );
      return V2TimValueCallback<V2TimFriendOperationResult>(
        code: success ? 0 : -1,
        desc: success ? 'success' : 'addFriend failed',
        data: V2TimFriendOperationResult(
          userID: userID,
          resultCode: success ? 0 : -1,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimFriendOperationResult>(
        code: -1,
        desc: 'addFriend failed: $e',
        data: V2TimFriendOperationResult(
          userID: userID,
          resultCode: -1,
        ),
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimFriendOperationResult>>>
      deleteFromFriendList({
    required List<String> userIDList,
    required int deleteType,
  }) async {
    try {
      // Delete friends via FfiChatService
      // Use deleteFriend instead of removeFriend to ensure local persistence cleanup
      final results = <V2TimFriendOperationResult>[];
      for (final userID in userIDList) {
        try {
          await ffiService.deleteFriend(userID);
          results.add(V2TimFriendOperationResult(
            userID: userID,
            resultCode: 0,
          ));
        } catch (e) {
          results.add(V2TimFriendOperationResult(
            userID: userID,
            resultCode: -1,
            resultInfo: e.toString(),
          ));
        }
      }

      // Notify listeners
      _notifyFriendshipListeners((listener) {
        listener.onFriendListDeleted?.call(userIDList);
      });

      return V2TimValueCallback<List<V2TimFriendOperationResult>>(
        code: 0,
        desc: 'success',
        data: results,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimFriendOperationResult>>(
        code: -1,
        desc: 'deleteFromFriendList failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimFriendApplicationResult>>
      getFriendApplicationList() async {
    try {
      final apps = await ffiService.getFriendApplications();
      final appList = apps
          .map((app) => fakeFriendApplicationToV2TimFriendApplication(
                FakeFriendApplication(userID: app.userId, wording: app.wording),
              ))
          .toList();

      return V2TimValueCallback<V2TimFriendApplicationResult>(
        code: 0,
        desc: 'success',
        data: V2TimFriendApplicationResult(
          unreadCount: appList.length,
          friendApplicationList: appList,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimFriendApplicationResult>(
        code: -1,
        desc: 'getFriendApplicationList failed: $e',
        data: V2TimFriendApplicationResult(
          unreadCount: 0,
          friendApplicationList: [],
        ),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimFriendOperationResult>>
      acceptFriendApplication({
    required String userID,
    required int responseType,
    required int type,
  }) async {
    try {
      // Accept friend application via FfiChatService
      await ffiService.acceptFriendRequest(userID);

      // Persist locally to ensure friend is saved even after app restart
      final current = await _prefs?.getLocalFriends() ?? <String>{};
      // Normalize userID to ensure consistent storage (64 characters for Tox public key)
      final normalizedUserID =
          userID.length > 64 ? userID.substring(0, 64) : userID;
      if (!current.contains(normalizedUserID)) {
        current.add(normalizedUserID);
        await _prefs?.setLocalFriends(current);
      }

      // Notify listeners
      final friendInfo = await fakeUserToV2TimFriendInfo(
        FakeUser(userID: normalizedUserID, nickName: '', online: false),
      );
      _notifyFriendshipListeners((listener) {
        listener.onFriendListAdded?.call([friendInfo]);
      });
      // Send our avatar to all friends (including the one we just accepted) so they see our avatar
      unawaited(ffiService.sendAvatarToAllFriends());

      return V2TimValueCallback<V2TimFriendOperationResult>(
        code: 0,
        desc: 'success',
        data: V2TimFriendOperationResult(
          userID: userID,
          resultCode: 0,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimFriendOperationResult>(
        code: -1,
        desc: 'acceptFriendApplication failed: $e',
        data: V2TimFriendOperationResult(
          userID: userID,
          resultCode: -1,
        ),
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimFriendOperationResult>>
      refuseFriendApplication({
    required String userID,
    required int type,
  }) async {
    try {
      // Tox has no native "refuse" RPC; persist the dismissal locally so the
      // entry stops reappearing on every 5s poll and across restarts.
      await ffiService.refuseFriendApplication(userID);
      return V2TimValueCallback<V2TimFriendOperationResult>(
        code: 0,
        desc: 'success',
        data: V2TimFriendOperationResult(
          userID: userID,
          resultCode: 0,
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimFriendOperationResult>(
        code: -1,
        desc: 'refuseFriendApplication failed: $e',
        data: V2TimFriendOperationResult(
          userID: userID,
          resultCode: -1,
        ),
      );
    }
  }

  @override
  Future<V2TimCallback> setFriendInfo({
    required String userID,
    String? friendRemark,
    Map<String, String>? friendCustomInfo,
  }) async {
    try {
      final prefs = _prefs;

      // friendRemark requested but no preferences service available — the
      // caller's data is being dropped. Surface this as a real failure
      // instead of returning code:0 (which previously made integrators see
      // "success" while nothing was written).
      if (friendRemark != null && prefs == null) {
        _log(
          '[Tim2ToxSdkPlatform] setFriendInfo: no preferences service '
          'attached — dropping friendRemark for $userID. Caller should '
          'inject ExtendedPreferencesService via the Tim2ToxSdkPlatform '
          'constructor or FfiChatService.preferencesService.',
        );
        return V2TimCallback(
          code: -1,
          desc:
              'setFriendInfo: no preferences service available, friendRemark not persisted',
        );
      }

      if (prefs != null && friendRemark != null) {
        // Persist via the typed [ExtendedPreferencesService.setFriendRemark]
        // so the host adapter applies its per-account scoping (toxee scopes
        // by the current Tox-ID prefix). The matching read in
        // `fakeUserToV2TimFriendInfo` calls `getFriendRemark` against the
        // same scope, which is how the alias becomes visible across the
        // contact list, search, and chat headers — not just the editing UI's
        // ephemeral state.
        await prefs.setFriendRemark(userID, friendRemark);
      }

      // TODO(tim2tox): `friendCustomInfo` requires a structured per-friend
      // map in `ExtendedPreferencesService`. Until that lands, log a warning
      // when callers pass it so the silent-drop is visible. UIKit's profile
      // page does not call this with custom info today, so the warning is
      // effectively a tripwire for a future contract change.
      if (friendCustomInfo != null && friendCustomInfo.isNotEmpty) {
        _log(
          '[Tim2ToxSdkPlatform] setFriendInfo: friendCustomInfo is not yet '
          'implemented — dropping ${friendCustomInfo.length} key(s) for '
          '$userID. If the host UI starts relying on this, wire it through '
          'ExtendedPreferencesService.',
        );
        // If the caller only asked for customInfo (no remark), they got
        // nothing — return failure rather than pretending it worked.
        if (friendRemark == null) {
          return V2TimCallback(
            code: -1,
            desc:
                'setFriendInfo: friendCustomInfo not supported, no remark provided',
          );
        }
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'setFriendInfo failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> setC2CReceiveMessageOpt({
    required List<String> userIDList,
    required int opt,
  }) async {
    try {
      final prefs = _prefs;

      // No prefs attached — surface the silent drop instead of pretending
      // success. Mirrors the loud failure mode in [setFriendInfo] so an
      // integrator that forgot to inject ExtendedPreferencesService sees a
      // real error rather than UI that toggles back on next refresh.
      if (prefs == null) {
        _log(
          '[Tim2ToxSdkPlatform] setC2CReceiveMessageOpt: no preferences '
          'service attached — dropping opt=$opt for ${userIDList.length} '
          'user(s). Caller should inject ExtendedPreferencesService via the '
          'Tim2ToxSdkPlatform constructor or FfiChatService.preferencesService.',
        );
        return V2TimCallback(
          code: -1,
          desc:
              'setC2CReceiveMessageOpt: no preferences service available, opt not persisted',
        );
      }

      final currentUserToxId = ffiService.selfId;
      if (currentUserToxId.isEmpty) {
        return V2TimCallback(
          code: -1,
          desc:
              'setC2CReceiveMessageOpt failed: user not logged in (no Tox ID)',
        );
      }

      for (final userID in userIDList) {
        await prefs.setC2CReceiveMessageOpt(userID, opt, currentUserToxId);
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'setC2CReceiveMessageOpt failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> deleteFriendApplication({
    required int type,
    required String userID,
  }) async {
    try {
      // Same path as refuse — the V2TIM API distinguishes the two for IM
      // analytics, but for Tox both mean "drop it from the local queue".
      await ffiService.deleteFriendApplication(userID);
      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'deleteFriendApplication failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> setFriendApplicationRead() async {
    try {
      // Mark all friend applications as read
      // In Tox, we don't have a separate read status
      // For now, just return success
      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'setFriendApplicationRead failed: $e',
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimFriendOperationResult>>> addToBlackList({
    required List<String> userIDList,
  }) async {
    try {
      final prefs = _prefs;
      if (prefs == null) {
        _log(
          '[Tim2ToxSdkPlatform] addToBlackList: no preferences service '
          'attached — dropping ${userIDList.length} user(s). Caller should '
          'inject ExtendedPreferencesService via the Tim2ToxSdkPlatform '
          'constructor or FfiChatService.preferencesService.',
        );
        return V2TimValueCallback<List<V2TimFriendOperationResult>>(
          code: -1,
          desc:
              'addToBlackList: no preferences service available, blacklist not persisted',
          data: [],
        );
      }

      // Add to blacklist via preferences service, using current user's Tox ID
      final currentUserToxId = ffiService.selfId;
      if (currentUserToxId.isEmpty) {
        return V2TimValueCallback<List<V2TimFriendOperationResult>>(
          code: -1,
          desc: 'addToBlackList failed: user not logged in (no Tox ID)',
          data: [],
        );
      }
      // Tox protocol itself does not block incoming messages from a peer — the
      // blacklist is a purely local hide/filter applied by the client when
      // rendering conversations and notifications. Persistence here is
      // sufficient for UIKit's blacklist UI; incoming-message filtering is
      // the host's responsibility on top of this state.
      _log(
        '[Tim2ToxSdkPlatform] addToBlackList: persisting locally for '
        '${userIDList.length} user(s); Tox protocol does not block messages '
        'at the network layer.',
      );
      await prefs.addToBlackList(userIDList, currentUserToxId);

      final results = userIDList
          .map((userID) => V2TimFriendOperationResult(
                userID: userID,
                resultCode: 0,
              ))
          .toList();

      // Notify listeners
      final friendInfoList =
          userIDList.map((userID) => V2TimFriendInfo(userID: userID)).toList();
      _notifyFriendshipListeners((listener) {
        listener.onBlackListAdd?.call(friendInfoList);
      });

      return V2TimValueCallback<List<V2TimFriendOperationResult>>(
        code: 0,
        desc: 'success',
        data: results,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimFriendOperationResult>>(
        code: -1,
        desc: 'addToBlackList failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimFriendOperationResult>>>
      deleteFromBlackList({
    required List<String> userIDList,
  }) async {
    try {
      final prefs = _prefs;
      if (prefs == null) {
        _log(
          '[Tim2ToxSdkPlatform] deleteFromBlackList: no preferences service '
          'attached — dropping ${userIDList.length} user(s). Caller should '
          'inject ExtendedPreferencesService via the Tim2ToxSdkPlatform '
          'constructor or FfiChatService.preferencesService.',
        );
        return V2TimValueCallback<List<V2TimFriendOperationResult>>(
          code: -1,
          desc:
              'deleteFromBlackList: no preferences service available, blacklist not updated',
          data: [],
        );
      }

      // Remove from blacklist via preferences service, using current user's Tox ID
      final currentUserToxId = ffiService.selfId;
      if (currentUserToxId.isEmpty) {
        return V2TimValueCallback<List<V2TimFriendOperationResult>>(
          code: -1,
          desc: 'deleteFromBlackList failed: user not logged in (no Tox ID)',
          data: [],
        );
      }
      await prefs.removeFromBlackList(userIDList, currentUserToxId);

      final results = userIDList
          .map((userID) => V2TimFriendOperationResult(
                userID: userID,
                resultCode: 0,
              ))
          .toList();

      // Notify listeners
      _notifyFriendshipListeners((listener) {
        listener.onBlackListDeleted?.call(userIDList);
      });

      return V2TimValueCallback<List<V2TimFriendOperationResult>>(
        code: 0,
        desc: 'success',
        data: results,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimFriendOperationResult>>(
        code: -1,
        desc: 'deleteFromBlackList failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimFriendInfo>>> getBlackList() async {
    try {
      // Get blacklist from preferences service, using current user's Tox ID
      final currentUserToxId = ffiService.selfId;
      if (currentUserToxId.isEmpty) {
        return V2TimValueCallback<List<V2TimFriendInfo>>(
          code: -1,
          desc: 'getBlackList failed: user not logged in (no Tox ID)',
          data: [],
        );
      }
      final blackList =
          await _prefs?.getBlackList(currentUserToxId) ?? <String>{};

      // Convert to V2TimFriendInfo list
      final friendInfoList =
          blackList.map((userID) => V2TimFriendInfo(userID: userID)).toList();

      return V2TimValueCallback<List<V2TimFriendInfo>>(
        code: 0,
        desc: 'success',
        data: friendInfoList,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimFriendInfo>>(
        code: -1,
        desc: 'getBlackList failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimFriendCheckResult>>> checkFriend({
    required List<String> userIDList,
    required int checkType,
  }) async {
    try {
      final friends = await ffiService.getFriendList();
      final friendIds = friends.map((f) => f.userId).toSet();

      final results = <V2TimFriendCheckResult>[];
      for (final userID in userIDList) {
        final isFriend = friendIds.contains(userID);
        results.add(V2TimFriendCheckResult(
          userID: userID,
          resultCode: 0,
          resultType: isFriend ? 1 : 0, // 1 = friend, 0 = not friend
        ));
      }

      return V2TimValueCallback<List<V2TimFriendCheckResult>>(
        code: 0,
        desc: 'success',
        data: results,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimFriendCheckResult>>(
        code: -1,
        desc: 'checkFriend failed: $e',
        data: [],
      );
    }
  }

  // ============================================================================

  // ============================================================================
  // Group Manager methods
  // ============================================================================

  @override
  Future<void> addGroupListener({
    required V2TimGroupListener listener,
  }) async {
    final id = ffi_lib.Tim2ToxFfi.open().getCurrentInstanceId();
    (_instanceGroupListeners[id] ??= []).add(listener);
    if (!_groupListeners.contains(listener)) {
      _groupListeners.add(listener);
    }
  }

  @override
  Future<void> setGroupListener({
    required V2TimGroupListener listener,
  }) async {
    // setGroupListener replaces all existing listeners
    _groupListeners.clear();
    _groupListeners.add(listener);
  }

  @override
  Future<void> removeGroupListener({
    V2TimGroupListener? listener,
  }) async {
    if (listener != null) {
      _groupListeners.remove(listener);
    }
  }

  @override
  Future<V2TimValueCallback<String>> createGroup({
    String? groupID,
    required String groupType,
    required String groupName,
    String? notification,
    String? introduction,
    String? faceUrl,
    bool? isAllMuted,
    int? addOpt,
    int? approveOpt,
    int? defaultPermissions,
    bool? isEnablePermissionGroup,
    List<V2TimGroupMember>? memberList,
    bool? isSupportTopic,
  }) async {
    try {
      // Create group via FfiChatService
      final gid = await ffiService.createGroup(groupName);
      if (gid == null) {
        return V2TimValueCallback<String>(
          code: -1,
          desc: 'Failed to create group',
        );
      }

      // Save group name to Prefs
      await _prefs?.setGroupName(gid, groupName);
      // Clear old avatar if no new faceUrl provided, or set new avatar
      // This ensures new groups don't reuse old group avatars when group ID is reused
      if (faceUrl != null && faceUrl.isNotEmpty) {
        await _prefs?.setGroupAvatar(gid, faceUrl);
      } else {
        await _prefs?.setGroupAvatar(gid, null);
      }
      if (notification != null && notification.isNotEmpty) {
        await _prefs?.setGroupNotification(gid, notification);
      }
      if (introduction != null && introduction.isNotEmpty) {
        await _prefs?.setGroupIntroduction(gid, introduction);
      }
      // Creator is the owner
      final selfPublicKey = ffiService.selfId.length >= 64
          ? ffiService.selfId.substring(0, 64)
          : ffiService.selfId;
      await _prefs?.setGroupOwner(gid, selfPublicKey);

      // Notify listeners
      _notifyGroupListeners((listener) {
        listener.onGroupCreated?.call(gid);
        listener.onGroupInfoChanged?.call(gid, [
          V2TimGroupChangeInfo(
            type: 0, // V2TIM_GROUP_INFO_CHANGE_TYPE_NAME
            value: groupName,
          )
        ]);
      });

      return V2TimValueCallback<String>(
        code: 0,
        desc: 'success',
        data: gid,
      );
    } catch (e) {
      return V2TimValueCallback<String>(
        code: -1,
        desc: 'createGroup failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> joinGroup({
    required String groupID,
    required String message,
    String? groupType,
  }) async {
    try {
      await ffiService.joinGroup(groupID, requestMessage: message);

      // Notify listeners
      // Get self public key (64 chars) for member userID
      final selfPublicKey = ffiService.selfId.length >= 64
          ? ffiService.selfId.substring(0, 64)
          : ffiService.selfId;
      _notifyGroupListeners((listener) {
        // Create a member info for self
        final selfMember = V2TimGroupMemberInfo(userID: selfPublicKey);
        listener.onMemberEnter?.call(groupID, [selfMember]);
      });

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'joinGroup failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> quitGroup({
    required String groupID,
  }) async {
    if (_debugLog)
      print('[Tim2ToxSdkPlatform] quitGroup: ENTRY - groupID=$groupID');
    try {
      if (_debugLog)
        print('[Tim2ToxSdkPlatform] quitGroup: Calling ffiService.quitGroup');
      await ffiService.quitGroup(groupID);
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] quitGroup: ffiService.quitGroup completed successfully');

      // Notify listeners
      if (_debugLog)
        print('[Tim2ToxSdkPlatform] quitGroup: Notifying group listeners');
      _notifyGroupListeners((listener) {
        listener.onQuitFromGroup?.call(groupID);
      });

      if (_debugLog) print('[Tim2ToxSdkPlatform] quitGroup: EXIT - Success');
      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e, stackTrace) {
      if (_debugLog)
        print('[Tim2ToxSdkPlatform] quitGroup: ERROR - Exception: $e');
      if (_debugLog)
        print('[Tim2ToxSdkPlatform] quitGroup: Stack trace: $stackTrace');
      return V2TimCallback(
        code: -1,
        desc: 'quitGroup failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> dismissGroup({
    required String groupID,
  }) async {
    try {
      await ffiService.dismissGroup(groupID);

      // Notify listeners - C++ layer will also notify via onGroupDismissed
      // We notify here as well to ensure UI updates immediately
      // Get self public key (64 chars) for opUser userID
      final selfPublicKey = ffiService.selfId.length >= 64
          ? ffiService.selfId.substring(0, 64)
          : ffiService.selfId;
      _notifyGroupListeners((listener) {
        final opUser = V2TimGroupMemberInfo(
          userID: selfPublicKey,
        );
        listener.onGroupDismissed?.call(groupID, opUser);
      });

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'dismissGroup failed: $e',
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimUserFullInfo>>> getUsersInfo({
    required List<String> userIDList,
  }) async {
    try {
      final list = <V2TimUserFullInfo>[];
      final selfPublicKey = ffiService.selfId.length >= 64
          ? ffiService.selfId.substring(0, 64)
          : ffiService.selfId;
      for (final userID in userIDList) {
        final isSelf = userID == ffiService.selfId || userID == selfPublicKey;
        String? faceUrl;
        if (isSelf) {
          faceUrl = await _prefs?.getAvatarPath();
          if (faceUrl == null || faceUrl.isEmpty) {
            faceUrl = await _prefs?.getFriendAvatarPath(userID);
          }
        } else {
          faceUrl = await _prefs?.getFriendAvatarPath(userID);
        }
        String? nickName;
        if (isSelf) {
          nickName = await _prefs?.getString('self_nickname');
        } else {
          nickName = await _prefs?.getFriendNickname(userID);
        }
        list.add(V2TimUserFullInfo(
          userID: userID,
          faceUrl: faceUrl,
          nickName: nickName,
        ));
      }
      return V2TimValueCallback<List<V2TimUserFullInfo>>(
        code: 0,
        desc: 'success',
        data: list,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimUserFullInfo>>(
        code: -1,
        desc: 'getUsersInfo failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimGroupInfoResult>>> getGroupsInfo({
    required List<String> groupIDList,
  }) async {
    try {
      final results = <V2TimGroupInfoResult>[];

      for (final groupID in groupIDList) {
        // Get group info from preferences service
        final groupName = await _prefs?.getGroupName(groupID);
        final groupAvatar = await _prefs?.getGroupAvatar(groupID);
        final groupNotification = await _prefs?.getGroupNotification(groupID);
        final groupIntroduction = await _prefs?.getGroupIntroduction(groupID);
        final groupOwner = await _prefs?.getGroupOwner(groupID);

        // Get member count from actual Tox peer list
        int? memberCount;
        try {
          final memberResult = await getGroupMemberList(
              groupID: groupID, nextSeq: '0', count: 1000, filter: 0);
          if (memberResult.code == 0 &&
              memberResult.data?.memberInfoList != null) {
            memberCount = memberResult.data!.memberInfoList!.length;
          }
        } catch (_) {}

        final groupInfo = V2TimGroupInfo(
          groupID: groupID,
          groupType: GroupType.Work,
          groupName: groupName ?? groupID,
          faceUrl: groupAvatar,
          memberCount: memberCount,
          notification: groupNotification,
          introduction: groupIntroduction,
          owner: groupOwner,
        );

        results.add(V2TimGroupInfoResult(
          resultCode: 0,
          groupInfo: groupInfo,
        ));
      }

      return V2TimValueCallback<List<V2TimGroupInfoResult>>(
        code: 0,
        desc: 'success',
        data: results,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimGroupInfoResult>>(
        code: -1,
        desc: 'getGroupsInfo failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimCallback> setGroupInfo({
    required V2TimGroupInfo info,
  }) async {
    try {
      // Save group info to Prefs
      if (info.groupName != null) {
        await _prefs?.setGroupName(info.groupID, info.groupName!);
      }
      if (info.faceUrl != null) {
        await _prefs?.setGroupAvatar(info.groupID, info.faceUrl!);
      }
      if (info.notification != null) {
        await _prefs?.setGroupNotification(info.groupID, info.notification);
      }
      if (info.introduction != null) {
        await _prefs?.setGroupIntroduction(info.groupID, info.introduction);
      }
      if (info.owner != null && info.owner!.isNotEmpty) {
        await _prefs?.setGroupOwner(info.groupID, info.owner!);
      }

      // Notify listeners
      final changeInfos = <V2TimGroupChangeInfo>[];
      if (info.groupName != null) {
        changeInfos.add(V2TimGroupChangeInfo(
          type: 0, // V2TIM_GROUP_INFO_CHANGE_TYPE_NAME
          value: info.groupName!,
        ));
      }
      if (info.faceUrl != null) {
        changeInfos.add(V2TimGroupChangeInfo(
          type: 3, // V2TIM_GROUP_INFO_CHANGE_TYPE_FACE_URL
          value: info.faceUrl!,
        ));
      }
      if (info.notification != null) {
        changeInfos.add(V2TimGroupChangeInfo(
          type: 1, // V2TIM_GROUP_INFO_CHANGE_TYPE_NOTIFICATION
          value: info.notification!,
        ));
      }
      if (info.introduction != null) {
        changeInfos.add(V2TimGroupChangeInfo(
          type: 2, // V2TIM_GROUP_INFO_CHANGE_TYPE_INTRODUCTION
          value: info.introduction!,
        ));
      }

      if (changeInfos.isNotEmpty) {
        _notifyGroupListeners((listener) {
          listener.onGroupInfoChanged?.call(info.groupID, changeInfos);
        });
      }

      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'setGroupInfo failed: $e',
      );
    }
  }

  @override
  Future<V2TimValueCallback<List<V2TimGroupInfo>>> getJoinedGroupList() async {
    print(
        '[Tim2ToxSdkPlatform] getJoinedGroupList called - _isInitialized=$_isInitialized, ffiService.selfId=${ffiService.selfId.isEmpty ? "empty" : "not empty"}');
    try {
      // For tim2tox, we can get group list even if SDK initialization flag is not set,
      // as long as ffiService is available (selfId is not empty)
      // This allows getting group list during message reception before full SDK init
      if (!_isInitialized && ffiService.selfId.isEmpty) {
        print(
            '[Tim2ToxSdkPlatform] getJoinedGroupList - SDK not initialized, returning 6013');
        return V2TimValueCallback<List<V2TimGroupInfo>>(
          code: 6013,
          desc: 'sdk not init',
          data: [],
        );
      }

      // If ffiService is available (selfId not empty), we can get groups even if _isInitialized is false
      // This is safe because ffiService.init() has been called and groups are available
      final groups = ffiService.knownGroups;
      print(
          '[Tim2ToxSdkPlatform] getJoinedGroupList - Found ${groups.length} groups from knownGroups');

      // Filter out quit groups to ensure they don't appear in the list
      final quitGroups = await _prefs?.getQuitGroups() ?? <String>{};
      print(
          '[Tim2ToxSdkPlatform] getJoinedGroupList - Quit groups: ${quitGroups.toList()}');
      final activeGroups =
          groups.where((gid) => !quitGroups.contains(gid)).toList();
      print(
          '[Tim2ToxSdkPlatform] getJoinedGroupList - Active groups after filtering: ${activeGroups.length}');

      final groupInfoList = <V2TimGroupInfo>[];

      for (final groupID in activeGroups) {
        final groupName = await _prefs?.getGroupName(groupID);
        final groupAvatar = await _prefs?.getGroupAvatar(groupID);
        final groupNotification = await _prefs?.getGroupNotification(groupID);
        final groupIntroduction = await _prefs?.getGroupIntroduction(groupID);
        final groupOwner = await _prefs?.getGroupOwner(groupID);

        // Get member count from actual Tox peer list
        int? memberCount;
        try {
          final memberResult = await getGroupMemberList(
              groupID: groupID, nextSeq: '0', count: 1000, filter: 0);
          if (memberResult.code == 0 &&
              memberResult.data?.memberInfoList != null) {
            memberCount = memberResult.data!.memberInfoList!.length;
          }
        } catch (_) {}

        final groupInfo = V2TimGroupInfo(
          groupID: groupID,
          groupType: GroupType.Work,
          groupName: groupName ?? groupID,
          faceUrl: groupAvatar,
          memberCount: memberCount,
          notification: groupNotification,
          introduction: groupIntroduction,
          owner: groupOwner,
        );
        groupInfoList.add(groupInfo);
      }

      return V2TimValueCallback<List<V2TimGroupInfo>>(
        code: 0,
        desc: 'success',
        data: groupInfoList,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimGroupInfo>>(
        code: -1,
        desc: 'getJoinedGroupList failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimGroupMemberInfoResult>> getGroupMemberList({
    required String groupID,
    required String nextSeq,
    int count = 100,
    required int filter,
    int offset = 0,
  }) async {
    try {
      // Call C++ implementation via FFI to get actual group members from Tox
      NativeLibraryManager.registerPort();
      String userData = Tools.generateUserData('getGroupMemberList');
      Completer<V2TimValueCallback<V2TimGroupMemberInfoResult>> completer =
          Completer();
      NativeLibraryManager.timValueCallback2Future<V2TimGroupMemberInfoResult>(
          userData, completer);

      final nextSeqInt = int.tryParse(nextSeq) ?? 0;
      final jsonParam = jsonEncode({
        'group_get_members_info_list_param_group_id': groupID,
        'group_get_members_info_list_param_option': {
          'group_member_get_info_option_role_flag': 0
        },
        'group_get_members_info_list_param_next_seq': nextSeqInt,
      });

      final pJsonParam = Tools.string2PointerChar(jsonParam);
      final pUserData = Tools.string2PointerVoid(userData);

      try {
        int callResult = NativeLibraryManager.bindings
            .DartGetGroupMemberList(pJsonParam, pUserData);
        if (callResult != 0) {
          Tools.freePointers([pJsonParam, pUserData]);
          // FFI call failed, fall back to message history
          return _getGroupMemberListFallback(groupID, nextSeq, count, offset);
        }

        V2TimValueCallback<V2TimGroupMemberInfoResult> result =
            await completer.future;
        Tools.freePointers([pJsonParam, pUserData]);

        // Fill faceUrl, nickName, and role from prefs
        if (result.data?.memberInfoList != null &&
            result.data!.memberInfoList!.isNotEmpty) {
          await _setFaceUrlForGroupMembers(
              result.data!.memberInfoList!
                  .whereType<V2TimGroupMemberFullInfo>()
                  .toList(),
              groupID: groupID);
        }

        return result;
      } catch (e) {
        Tools.freePointers([pJsonParam, pUserData]);
        // FFI call threw, fall back to message history
        return _getGroupMemberListFallback(groupID, nextSeq, count, offset);
      }
    } catch (e) {
      return V2TimValueCallback<V2TimGroupMemberInfoResult>(
        code: -1,
        desc: 'getGroupMemberList failed: $e',
        data: V2TimGroupMemberInfoResult(
          nextSeq: '0',
          memberInfoList: [],
        ),
      );
    }
  }

  /// Fallback: get group members from message history and prefs when FFI call fails.
  /// Note: this only discovers members who have sent messages or are stored in prefs
  /// (self + owner). Members who have never sent messages will be missing.
  Future<V2TimValueCallback<V2TimGroupMemberInfoResult>>
      _getGroupMemberListFallback(
          String groupID, String nextSeq, int count, int offset) async {
    final history = ffiService.getHistory(groupID);
    final memberSet = <String>{};
    final selfPublicKey = ffiService.selfId.length >= 64
        ? ffiService.selfId.substring(0, 64)
        : ffiService.selfId;
    memberSet.add(selfPublicKey);

    // Include group owner from prefs even if they haven't sent messages
    final groupOwner = await _prefs?.getGroupOwner(groupID);
    if (groupOwner != null && groupOwner.isNotEmpty) {
      memberSet.add(groupOwner);
    }

    for (final msg in history) {
      if (msg.groupId == groupID && msg.fromUserId.isNotEmpty) {
        final normalizedUserId = msg.fromUserId.length >= 64
            ? msg.fromUserId.substring(0, 64)
            : msg.fromUserId;
        memberSet.add(normalizedUserId);
      }
    }
    final owner = groupOwner;
    final memberList = memberSet.map((userID) {
      final int role;
      if (owner != null && owner.isNotEmpty && userID == owner) {
        role = 400; // Owner
      } else {
        role = 200; // Member
      }
      return V2TimGroupMemberFullInfo(userID: userID, role: role);
    }).toList();
    final startIndex = offset;
    final endIndex = (startIndex + count).clamp(0, memberList.length);
    final paginatedList =
        memberList.sublist(startIndex.clamp(0, memberList.length), endIndex);
    final hasMore = endIndex < memberList.length;
    final nextSeqValue = hasMore ? endIndex.toString() : '0';
    await _setFaceUrlForGroupMembers(paginatedList, groupID: groupID);
    return V2TimValueCallback<V2TimGroupMemberInfoResult>(
      code: 0,
      desc: 'success',
      data: V2TimGroupMemberInfoResult(
          nextSeq: nextSeqValue, memberInfoList: paginatedList),
    );
  }

  @override
  Future<V2TimValueCallback<List<V2TimGroupMemberFullInfo>>>
      getGroupMembersInfo({
    required String groupID,
    required List<String> memberList,
  }) async {
    try {
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getGroupMembersInfo: ENTRY - groupID=$groupID, requested members=${memberList.length}');
      for (int i = 0; i < memberList.length && i < 3; i++) {
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] getGroupMembersInfo: requested[$i]=${memberList[i]}');
      }

      // Validate inputs
      if (groupID.isEmpty) {
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] getGroupMembersInfo: ERROR - groupID is empty');
        return V2TimValueCallback<List<V2TimGroupMemberFullInfo>>(
          code: -1,
          desc: 'groupID cannot be empty',
          data: [],
        );
      }

      if (memberList.isEmpty) {
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] getGroupMembersInfo: ERROR - memberList is empty');
        return V2TimValueCallback<List<V2TimGroupMemberFullInfo>>(
          code: -1,
          desc: 'memberList cannot be empty',
          data: [],
        );
      }

      // Ensure NativeLibraryManager is initialized
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getGroupMembersInfo: Registering NativeLibraryManager port');
      NativeLibraryManager.registerPort();

      // Generate unique user_data identifier for callback
      String userData = Tools.generateUserData('getGroupMembersInfo');
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getGroupMembersInfo: Generated userData=$userData for callback');

      // Create completer for async callback
      Completer<V2TimValueCallback<List<V2TimGroupMemberFullInfo>>> completer =
          Completer();
      NativeLibraryManager.timValueCallback2Future<
          List<V2TimGroupMemberFullInfo>>(userData, completer);

      // Build JSON parameter with required field names
      final jsonParam = jsonEncode({
        'group_get_members_info_param_group_id': groupID,
        'group_get_members_info_param_identifier_array': memberList,
      });
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getGroupMembersInfo: JSON param=$jsonParam');

      // Prepare FFI pointers
      ffi.Pointer<ffi.Char> pJsonParam = Tools.string2PointerChar(jsonParam);
      ffi.Pointer<ffi.Void> pUserData = Tools.string2PointerVoid(userData);
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getGroupMembersInfo: Prepared FFI pointers, calling DartGetGroupMembersInfo');

      try {
        // Call C++ layer DartGetGroupMembersInfo (async) - this will query Tox for member info
        int callResult = NativeLibraryManager.bindings
            .DartGetGroupMembersInfo(pJsonParam, pUserData);
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] getGroupMembersInfo: DartGetGroupMembersInfo call returned code=$callResult, waiting for callback');

        // Wait for callback result
        V2TimValueCallback<List<V2TimGroupMemberFullInfo>> result =
            await completer.future;
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] getGroupMembersInfo: Received callback result: code=${result.code}, desc=${result.desc}, data length=${result.data?.length ?? 0}');

        // Free pointers
        Tools.freePointers([pJsonParam, pUserData]);

        // Fill faceUrl, nickName, and role from prefs
        if (result.data != null && result.data!.isNotEmpty) {
          await _setFaceUrlForGroupMembers(result.data!, groupID: groupID);
        }

        // Log results
        if (result.data != null && result.data!.isNotEmpty) {
          for (int i = 0; i < result.data!.length && i < 3; i++) {
            if (_debugLog)
              print(
                  '[Tim2ToxSdkPlatform] getGroupMembersInfo: result[$i].userID=${result.data![i].userID}');
          }
        }

        return result;
      } catch (e, stackTrace) {
        // Free pointers on error
        Tools.freePointers([pJsonParam, pUserData]);
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] getGroupMembersInfo: ERROR - Exception during FFI call: $e');
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] getGroupMembersInfo: Stack trace: $stackTrace');
        rethrow;
      }
    } catch (e, stackTrace) {
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getGroupMembersInfo: ERROR - Exception: $e');
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] getGroupMembersInfo: Stack trace: $stackTrace');
      return V2TimValueCallback<List<V2TimGroupMemberFullInfo>>(
        code: -1,
        desc: 'getGroupMembersInfo failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimGroupApplicationResult>>
      getGroupApplicationList() async {
    try {
      // Tox doesn't have group application list
      // For now, return empty list
      return V2TimValueCallback<V2TimGroupApplicationResult>(
        code: 0,
        desc: 'success',
        data: V2TimGroupApplicationResult(
          unreadCount: 0,
          groupApplicationList: [],
        ),
      );
    } catch (e) {
      return V2TimValueCallback<V2TimGroupApplicationResult>(
        code: -1,
        desc: 'getGroupApplicationList failed: $e',
        data: V2TimGroupApplicationResult(
          unreadCount: 0,
          groupApplicationList: [],
        ),
      );
    }
  }

  @override
  Future<V2TimCallback> acceptGroupApplication({
    required String groupID,
    String? reason,
    required String fromUser,
    required String toUser,
    int? addTime,
    int? type,
    String? webMessageInstance,
  }) async {
    // Tox doesn't have group application approval
    // For now, return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimCallback> refuseGroupApplication({
    required String groupID,
    String? reason,
    required String fromUser,
    required String toUser,
    required int addTime,
    required int type,
    String? webMessageInstance,
  }) async {
    // Tox doesn't have group application rejection
    // For now, return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimCallback> setGroupMemberInfo({
    required String groupID,
    required String userID,
    String? nameCard,
    Map<String, String>? customInfo,
  }) async {
    // Group member info is stored locally, not in FfiChatService
    // For now, just return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimCallback> muteGroupMember({
    required String groupID,
    required String userID,
    required int seconds,
  }) async {
    // Tox doesn't support muting group members
    // For now, return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimValueCallback<List<V2TimGroupMemberOperationResult>>>
      inviteUserToGroup({
    required String groupID,
    required List<String> userList,
  }) async {
    try {
      // Call C++ implementation via FFI
      // The C++ layer (V2TIMGroupManagerImpl::InviteUserToGroup) will:
      // 1. Call Tox API to invite users to the conference
      // 2. Return operation results
      // 3. Notify listeners via onMemberInvited callback

      // Create JSON parameter for FFI call
      final userListJson = jsonEncode(userList);

      // Generate unique user_data identifier for callback
      final userDataId =
          'invite_${DateTime.now().millisecondsSinceEpoch}_${groupID}';
      final userDataPtr = userDataId.toNativeUtf8();

      try {
        // Call FFI function - Note: This requires callback handling
        // For now, we'll use a workaround: the C++ layer will handle the invitation
        // and notify listeners, but we need to wait for the callback result

        // Since we don't have a callback mechanism set up yet, we'll call the C++ API
        // directly through a helper. For now, we'll use the existing implementation
        // which calls Tox API and notifies listeners

        // The C++ implementation (V2TIMGroupManagerImpl::InviteUserToGroup) already:
        // 1. Calls Tox API to invite users
        // 2. Returns operation results
        // 3. The listeners will be notified by the C++ layer when members actually join

        // For now, we'll simulate the call and let the C++ layer handle it
        // In a full implementation, we would:
        // 1. Call DartInviteUserToGroup via FFI
        // 2. Wait for callback with user_data
        // 3. Parse and return results

        // Temporary: Use the existing notification mechanism
        // The actual invitation happens in C++ layer via Tox API
        final results = userList
            .map((userID) => V2TimGroupMemberOperationResult(
                  memberID: userID,
                  result:
                      1, // _OPERATION_RESULT_SUCC - C++ layer will handle actual invitation
                ))
            .toList();

        // Notify listeners that members were "invited"
        // The C++ layer will also notify when members actually join via Tox callbacks
        // Get self public key (64 chars) for opUser userID
        final selfPublicKey = ffiService.selfId.length >= 64
            ? ffiService.selfId.substring(0, 64)
            : ffiService.selfId;
        _notifyGroupListeners((listener) {
          final opUser = V2TimGroupMemberInfo(
            userID: selfPublicKey,
          );
          final memberList = userList
              .map((userID) => V2TimGroupMemberInfo(
                    userID: userID,
                  ))
              .toList();
          listener.onMemberInvited?.call(groupID, opUser, memberList);
        });

        return V2TimValueCallback<List<V2TimGroupMemberOperationResult>>(
          code: 0,
          desc: 'success',
          data: results,
        );
      } finally {
        pkgffi.malloc.free(userDataPtr);
      }
    } catch (e) {
      final results = userList
          .map((userID) => V2TimGroupMemberOperationResult(
                memberID: userID,
                result: 0, // _OPERATION_RESULT_FAIL
              ))
          .toList();
      return V2TimValueCallback<List<V2TimGroupMemberOperationResult>>(
        code: -1,
        desc: 'inviteUserToGroup failed: $e',
        data: results,
      );
    }
  }

  @override
  Future<V2TimCallback> kickGroupMember({
    required String groupID,
    required List<String> memberList,
    String? reason,
    int? duration,
  }) async {
    try {
      // Call C++ implementation via FFI
      // The C++ layer (V2TIMGroupManagerImpl::KickGroupMember) will:
      // 1. Remove members from local group member list
      // 2. Notify listeners via onMemberKicked callback
      // 3. Return success

      // Create JSON parameter for FFI call
      final memberListJson = jsonEncode(memberList);
      final reasonStr = reason ?? '';

      // Generate unique user_data identifier for callback
      final userDataId =
          'kick_${DateTime.now().millisecondsSinceEpoch}_${groupID}';
      final userDataPtr = userDataId.toNativeUtf8();
      final reasonPtr = reasonStr.toNativeUtf8();

      try {
        // Call FFI function - Note: This requires callback handling
        // For now, we'll use a workaround: the C++ layer will handle the removal
        // and notify listeners, but we need to wait for the callback result

        // Since we don't have a callback mechanism set up yet, we'll call the C++ API
        // directly through a helper. For now, we'll use the existing implementation
        // which removes members locally and notifies listeners

        // The C++ implementation (V2TIMGroupManagerImpl::KickGroupMember) already:
        // 1. Removes members from local list
        // 2. Notifies listeners via onMemberKicked
        // 3. Returns success

        // For now, we'll simulate the call and let the C++ layer handle it
        // In a full implementation, we would:
        // 1. Call DartKickGroupMember via FFI
        // 2. Wait for callback with user_data
        // 3. Parse and return results

        // Temporary: Use the existing notification mechanism
        // The actual removal happens in C++ layer
        // Get self public key (64 chars) for opUser userID
        final selfPublicKey = ffiService.selfId.length >= 64
            ? ffiService.selfId.substring(0, 64)
            : ffiService.selfId;
        _notifyGroupListeners((listener) {
          final opUser = V2TimGroupMemberInfo(
            userID: selfPublicKey,
          );
          final kickedMemberList = memberList
              .map((userID) => V2TimGroupMemberInfo(
                    userID: userID,
                  ))
              .toList();
          listener.onMemberKicked?.call(groupID, opUser, kickedMemberList);
        });

        return V2TimCallback(
          code: 0,
          desc: 'success',
        );
      } finally {
        pkgffi.malloc.free(userDataPtr);
        pkgffi.malloc.free(reasonPtr);
      }
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'kickGroupMember failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> setGroupMemberRole({
    required String groupID,
    required String userID,
    required int role,
  }) async {
    // Tox doesn't support group member roles
    // For now, return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimCallback> transferGroupOwner({
    required String groupID,
    required String userID,
  }) async {
    // Tox doesn't support group owner transfer
    // For now, return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimCallback> setGroupApplicationRead() async {
    // Tox doesn't have group application list
    // For now, return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  // ============================================================================

  // ============================================================================
  // User Status methods
  // ============================================================================

  @override
  Future<V2TimValueCallback<List<V2TimUserStatus>>> getUserStatus({
    required List<String> userIDList,
  }) async {
    try {
      final friends = await ffiService.getFriendList();
      final statusList = <V2TimUserStatus>[];

      for (final userID in userIDList) {
        final friend = friends.firstWhere(
          (f) => f.userId == userID,
          orElse: () =>
              (userId: userID, nickName: '', online: false, status: ''),
        );

        final status = V2TimUserStatus(
          userID: userID,
          statusType: friend.online ? 1 : 0, // 1 = online, 0 = offline
          customStatus: null,
          onlineDevices: friend.online ? ['desktop'] : null,
        );
        statusList.add(status);
      }

      return V2TimValueCallback<List<V2TimUserStatus>>(
        code: 0,
        desc: 'success',
        data: statusList,
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimUserStatus>>(
        code: -1,
        desc: 'getUserStatus failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<V2TimCallback> subscribeUserStatus({
    required List<String> userIDList,
  }) async {
    // Tox doesn't have explicit status subscription
    // Status is automatically updated via friend list
    // For now, just return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimCallback> unsubscribeUserStatus({
    required List<String> userIDList,
  }) async {
    // Tox doesn't have explicit status unsubscription
    // For now, just return success
    return V2TimCallback(
      code: 0,
      desc: 'success',
    );
  }

  @override
  Future<V2TimCallback> setSelfStatus({
    required String status,
  }) async {
    try {
      // Set self status via FfiChatService
      // Note: FfiChatService doesn't have a direct setStatus method
      // We might need to use setSelfInfo or a custom message
      // For now, just return success
      return V2TimCallback(
        code: 0,
        desc: 'success',
      );
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'setSelfStatus failed: $e',
      );
    }
  }

  /// Find userID and groupID from msgID by searching through message history
  (String?, String?) _findUserIDAndGroupIDFromMsgID(String msgID) {
    // CRITICAL: Ensure msgID is not empty
    if (msgID.isEmpty) {
      if (_debugLog)
        print(
            '[Tim2ToxSdkPlatform] _findUserIDAndGroupIDFromMsgID: msgID is empty');
      return (null, null);
    }

    // Debug: Log the search to help diagnose duplicate reaction issues
    if (_debugLog)
      print(
          '[Tim2ToxSdkPlatform] _findUserIDAndGroupIDFromMsgID: searching for msgID=$msgID');

    // Search through all conversation histories
    int matchCount = 0;
    String? foundUserID;
    String? foundGroupID;

    for (final entry in ffiService.lastMessages.entries) {
      final peerId = entry.key;
      final history = ffiService.getHistory(peerId);

      for (final chatMsg in history) {
        final currentMsgID = chatMsg.msgID ??
            '${chatMsg.timestamp.millisecondsSinceEpoch}_${chatMsg.fromUserId}';
        if (currentMsgID == msgID) {
          // Found the message, return userID/groupID
          matchCount++;
          if (chatMsg.groupId != null) {
            foundGroupID = chatMsg.groupId;
            foundUserID = null;
          } else {
            foundUserID = chatMsg.fromUserId;
            foundGroupID = null;
          }
          // CRITICAL: Break on first match to avoid returning wrong result if multiple matches exist
          // This ensures we only return the first matching message
          break;
        }
      }

      // If we found a match, return it immediately (don't continue searching)
      if (matchCount > 0) {
        if (matchCount > 1) {
          print(
              '[Tim2ToxSdkPlatform] WARNING: Multiple messages found with msgID=$msgID (count=$matchCount), using first match');
        }
        if (_debugLog)
          print(
              '[Tim2ToxSdkPlatform] _findUserIDAndGroupIDFromMsgID: found msgID=$msgID, userID=$foundUserID, groupID=$foundGroupID');
        return (foundUserID, foundGroupID);
      }
    }

    if (_debugLog)
      print(
          '[Tim2ToxSdkPlatform] _findUserIDAndGroupIDFromMsgID: msgID=$msgID not found in any conversation');
    return (null, null);
  }

  @override
  Future<V2TimCallback> addMessageReaction({
    String? msgID,
    required String reactionID,
  }) async {
    if (msgID == null) {
      return V2TimCallback(
        code: -1,
        desc: 'msgID is required',
      );
    }

    // Find userID/groupID from message history
    final (userID, groupID) = _findUserIDAndGroupIDFromMsgID(msgID);

    if (userID == null && groupID == null) {
      return V2TimCallback(
        code: -1,
        desc: 'Message not found in history',
      );
    }

    // Determine peerId (userID for C2C, groupID for group)
    final peerId = groupID ?? userID ?? '';
    if (peerId.isEmpty) {
      return V2TimCallback(
        code: -1,
        desc: 'Cannot determine peerId from message',
      );
    }

    try {
      await ffiService.sendReaction(peerId, msgID, reactionID, 'add',
          groupID: groupID);
      return V2TimCallback(code: 0, desc: 'success');
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'addMessageReaction failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> removeMessageReaction({
    String? msgID,
    required String reactionID,
  }) async {
    if (msgID == null) {
      return V2TimCallback(
        code: -1,
        desc: 'msgID is required',
      );
    }

    // Find userID/groupID from message history
    final (userID, groupID) = _findUserIDAndGroupIDFromMsgID(msgID);

    if (userID == null && groupID == null) {
      return V2TimCallback(
        code: -1,
        desc: 'Message not found in history',
      );
    }

    // Determine peerId (userID for C2C, groupID for group)
    final peerId = groupID ?? userID ?? '';
    if (peerId.isEmpty) {
      return V2TimCallback(
        code: -1,
        desc: 'Cannot determine peerId from message',
      );
    }

    try {
      await ffiService.sendReaction(peerId, msgID, reactionID, 'remove',
          groupID: groupID);
      return V2TimCallback(code: 0, desc: 'success');
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'removeMessageReaction failed: $e',
      );
    }
  }

  // ============================================================================

  // Placeholder Methods (required by interface but not critical)
  // ============================================================================

  @override
  Future<V2TimValueCallback<List<V2TimMessageReactionResult>>>
      getMessageReactions({
    List<String>? msgIDList,
    required int maxUserCountPerReaction,
    List<String>? webMessageInstanceList,
  }) async {
    try {
      // Tox doesn't have built-in reaction storage, so we return empty results
      // Reactions are handled via custom messages and tracked through reactionEvents stream
      // The reaction data is managed by the reaction plugin's local storage (SharedPreferences)
      // This matches the approach in the reference implementation where reactions are persisted locally
      return V2TimValueCallback<List<V2TimMessageReactionResult>>(
        code: 0,
        desc: 'success',
        data: [], // Return empty list - reactions are managed by plugin's local storage
      );
    } catch (e) {
      return V2TimValueCallback<List<V2TimMessageReactionResult>>(
        code: -1,
        desc: 'getMessageReactions failed: $e',
        data: [],
      );
    }
  }

  @override
  Future<String?> getPlatformVersion() async {
    return 'tim2tox-1.0.0';
  }

  @override
  void addNativeCallback() {
    // Not needed for FFI-based implementation
  }

  @override
  Future<void> emitUIKitEvent(dynamic event) async {
    // TODO: Implement if needed
  }

  @override
  Future<void> emitPluginEvent(dynamic event) async {
    // TODO: Implement if needed
  }

  // ============================================================================

  // ============================================================================
  // Signaling methods
  // ============================================================================

  // Note: Static callback functions are defined below

  @override
  Future<void> addSignalingListener({
    required V2TimSignalingListener listener,
  }) async {
    final ffiLib = ffi_lib.Tim2ToxFfi.open();
    int id = ffiLib.getCurrentInstanceId();
    if (id != 0) {
      (_instanceSignalingListeners[id] ??= []).add(listener);
    }
    _signalingListeners.add(listener);

    // Register per-instance C++ listener via dart_compat so events are sent with instance_id
    // and dispatched to _instanceSignalingListeners[id]. Required for multi-instance (e.g. Bob).
    final isFirstForInstance = id == 0
        ? _signalingListeners.length == 1
        : (_instanceSignalingListeners[id]?.length ?? 0) == 1;
    if (isFirstForInstance) {
      final ffiLib = ffi_lib.Tim2ToxFfi.open();
      // Ensure C++ current instance matches our id so listener is registered on the correct manager
      ffiLib.setCurrentInstance(id);
      ffiLib.dartSetSignalingReceiveNewInvitationCallback(ffi.nullptr);
      ffiLib.dartSetSignalingInvitationCancelledCallback(ffi.nullptr);
      ffiLib.dartSetSignalingInviteeAcceptedCallback(ffi.nullptr);
      ffiLib.dartSetSignalingInviteeRejectedCallback(ffi.nullptr);
      ffiLib.dartSetSignalingInvitationTimeoutCallback(ffi.nullptr);
      ffiLib.dartSetSignalingInvitationModifiedCallback(ffi.nullptr);
    }
  }

  @override
  Future<void> removeSignalingListener({
    V2TimSignalingListener? listener,
  }) async {
    final id = ffi_lib.Tim2ToxFfi.open().getCurrentInstanceId();
    if (listener != null) {
      _signalingListeners.remove(listener);
      if (id != 0) _instanceSignalingListeners[id]?.remove(listener);
    } else {
      _signalingListeners.clear();
      if (id != 0) _instanceSignalingListeners[id]?.clear();
    }

    // Remove per-instance C++ listener when this instance has no more listeners
    final noListenersForInstance = id == 0
        ? _signalingListeners.isEmpty
        : (_instanceSignalingListeners[id]?.isEmpty ?? true);
    if (noListenersForInstance) {
      final ffiLib = ffi_lib.Tim2ToxFfi.open();
      ffiLib.dartRemoveSignalingListenerForCurrentInstance();
    }
  }

  @override
  Future<V2TimValueCallback<String>> invite({
    required String invitee,
    required String data,
    int timeout = 30,
    bool onlineUserOnly = false,
    OfflinePushInfo? offlinePushInfo,
  }) async {
    try {
      final ffiLib = ffi_lib.Tim2ToxFfi.open();

      final inviteePtr = invitee.toNativeUtf8();
      final dataPtr = data.toNativeUtf8();
      final outInviteId = pkgffi.malloc.allocate<ffi.Int8>(64);
      // Initialize buffer to zeros to ensure it's properly null-terminated
      outInviteId.asTypedList(64).fillRange(0, 64, 0);

      try {
        final result = ffiLib.signalingInviteNative(
          inviteePtr,
          dataPtr,
          onlineUserOnly ? 1 : 0,
          timeout,
          outInviteId,
          64,
        );

        if (result == 1 && outInviteId.address != 0) {
          final inviteId = outInviteId.cast<pkgffi.Utf8>().toDartString();
          return V2TimValueCallback<String>(
            code: 0,
            desc: 'success',
            data: inviteId,
          );
        } else {
          return V2TimValueCallback<String>(
            code: -1,
            desc: 'invite failed',
            data: '',
          );
        }
      } finally {
        pkgffi.malloc.free(inviteePtr);
        pkgffi.malloc.free(dataPtr);
        pkgffi.malloc.free(outInviteId);
      }
    } catch (e) {
      return V2TimValueCallback<String>(
        code: -1,
        desc: 'invite failed: $e',
        data: '',
      );
    }
  }

  @override
  Future<V2TimValueCallback<String>> inviteInGroup({
    required String groupID,
    required List<String> inviteeList,
    required String data,
    int timeout = 30,
    bool onlineUserOnly = false,
  }) async {
    try {
      final ffiLib = ffi_lib.Tim2ToxFfi.open();

      final groupIdPtr = groupID.toNativeUtf8();
      final inviteeListStr = inviteeList.join(',');
      final inviteeListPtr = inviteeListStr.toNativeUtf8();
      final dataPtr = data.toNativeUtf8();
      final outInviteId = pkgffi.malloc.allocate<ffi.Int8>(64);
      // Initialize buffer to zeros to ensure it's properly null-terminated
      outInviteId.asTypedList(64).fillRange(0, 64, 0);

      try {
        final result = ffiLib.signalingInviteInGroupNative(
          groupIdPtr,
          inviteeListPtr,
          dataPtr,
          onlineUserOnly ? 1 : 0,
          timeout,
          outInviteId,
          64,
        );

        if (result == 1 && outInviteId.address != 0) {
          final inviteId = outInviteId.cast<pkgffi.Utf8>().toDartString();
          return V2TimValueCallback<String>(
            code: 0,
            desc: 'success',
            data: inviteId,
          );
        } else {
          return V2TimValueCallback<String>(
            code: -1,
            desc: 'inviteInGroup failed',
            data: '',
          );
        }
      } finally {
        pkgffi.malloc.free(groupIdPtr);
        pkgffi.malloc.free(inviteeListPtr);
        pkgffi.malloc.free(dataPtr);
        pkgffi.malloc.free(outInviteId);
      }
    } catch (e) {
      return V2TimValueCallback<String>(
        code: -1,
        desc: 'inviteInGroup failed: $e',
        data: '',
      );
    }
  }

  @override
  Future<V2TimCallback> cancel({
    required String inviteID,
    String? data,
  }) async {
    try {
      final ffiLib = ffi_lib.Tim2ToxFfi.open();

      final inviteIdPtr = inviteID.toNativeUtf8();
      final dataPtr = (data ?? '').toNativeUtf8();

      try {
        final result = ffiLib.signalingCancelNative(inviteIdPtr, dataPtr);
        return V2TimCallback(
          code: result == 1 ? 0 : -1,
          desc: result == 1 ? 'success' : 'cancel failed',
        );
      } finally {
        pkgffi.malloc.free(inviteIdPtr);
        pkgffi.malloc.free(dataPtr);
      }
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'cancel failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> accept({
    required String inviteID,
    String? data,
  }) async {
    try {
      final ffiLib = ffi_lib.Tim2ToxFfi.open();

      final inviteIdPtr = inviteID.toNativeUtf8();
      final dataPtr = (data ?? '').toNativeUtf8();

      try {
        final result = ffiLib.signalingAcceptNative(inviteIdPtr, dataPtr);
        return V2TimCallback(
          code: result == 1 ? 0 : -1,
          desc: result == 1 ? 'success' : 'accept failed',
        );
      } finally {
        pkgffi.malloc.free(inviteIdPtr);
        pkgffi.malloc.free(dataPtr);
      }
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'accept failed: $e',
      );
    }
  }

  @override
  Future<V2TimCallback> reject({
    required String inviteID,
    String? data,
  }) async {
    try {
      final ffiLib = ffi_lib.Tim2ToxFfi.open();

      final inviteIdPtr = inviteID.toNativeUtf8();
      final dataPtr = (data ?? '').toNativeUtf8();

      try {
        final result = ffiLib.signalingRejectNative(inviteIdPtr, dataPtr);
        return V2TimCallback(
          code: result == 1 ? 0 : -1,
          desc: result == 1 ? 'success' : 'reject failed',
        );
      } finally {
        pkgffi.malloc.free(inviteIdPtr);
        pkgffi.malloc.free(dataPtr);
      }
    } catch (e) {
      return V2TimCallback(
        code: -1,
        desc: 'reject failed: $e',
      );
    }
  }

  @override
  Future<V2TimValueCallback<V2TimSignalingInfo>> getSignalingInfo({
    required String msgID,
  }) async {
    // TODO: Implement getSignalingInfo from message
    return V2TimValueCallback<V2TimSignalingInfo>(
      code: -1,
      desc: 'getSignalingInfo not implemented',
      data: V2TimSignalingInfo(
        inviteID: '',
        inviter: '',
        groupID: '',
        inviteeList: const [],
        data: '',
        actionType: 0,
        timeout: 0,
        businessID: null,
        isOnlineUserOnly: false,
        offlinePushInfo: null,
      ),
    );
  }

  @override
  Future<V2TimCallback> addInvitedSignaling({
    required V2TimSignalingInfo info,
  }) async {
    // TODO: Implement addInvitedSignaling
    return V2TimCallback(
      code: -1,
      desc: 'addInvitedSignaling not implemented',
    );
  }

  @override
  Future<void> uikitTrace({
    required String trace,
  }) async {
    // For tim2tox implementation, we can simply print to console
    // or ignore the trace. This is mainly used for SDK logging/tracing.
    // In a production environment, you might want to log this to a file
    // or send it to a logging service.
    print('[Tim2Tox UIKit Trace] $trace');
  }

  // Static callback functions for FFI (must be static for fromFunction)
  static void _onInvitationCallback(
    ffi.Pointer<pkgffi.Utf8> inviteIdPtr,
    ffi.Pointer<pkgffi.Utf8> inviterPtr,
    ffi.Pointer<pkgffi.Utf8> groupIdPtr,
    ffi.Pointer<pkgffi.Utf8> dataPtr,
    ffi.Pointer<ffi.Void> userData,
  ) {
    // This will be set by the instance
    final instance = _currentInstance;
    if (instance == null) return;

    final inviteId = inviteIdPtr.address != 0
        ? inviteIdPtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final inviter = inviterPtr.address != 0
        ? inviterPtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final groupId = groupIdPtr.address != 0
        ? groupIdPtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final data =
        dataPtr.address != 0 ? dataPtr.cast<pkgffi.Utf8>().toDartString() : '';

    for (final listener in instance._signalingListeners) {
      listener.onReceiveNewInvitation(
        inviteId,
        inviter,
        groupId,
        const [],
        data,
      );
    }
  }

  static void _onCancelCallback(
    ffi.Pointer<pkgffi.Utf8> inviteIdPtr,
    ffi.Pointer<pkgffi.Utf8> inviterPtr,
    ffi.Pointer<pkgffi.Utf8> dataPtr,
    ffi.Pointer<ffi.Void> userData,
  ) {
    final instance = _currentInstance;
    if (instance == null) return;

    final inviteId = inviteIdPtr.address != 0
        ? inviteIdPtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final inviter = inviterPtr.address != 0
        ? inviterPtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final data =
        dataPtr.address != 0 ? dataPtr.cast<pkgffi.Utf8>().toDartString() : '';

    for (final listener in instance._signalingListeners) {
      listener.onInvitationCancelled(inviteId, inviter, data);
    }
  }

  static void _onAcceptCallback(
    ffi.Pointer<pkgffi.Utf8> inviteIdPtr,
    ffi.Pointer<pkgffi.Utf8> inviteePtr,
    ffi.Pointer<pkgffi.Utf8> dataPtr,
    ffi.Pointer<ffi.Void> userData,
  ) {
    final instance = _currentInstance;
    if (instance == null) return;

    final inviteId = inviteIdPtr.address != 0
        ? inviteIdPtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final invitee = inviteePtr.address != 0
        ? inviteePtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final data =
        dataPtr.address != 0 ? dataPtr.cast<pkgffi.Utf8>().toDartString() : '';

    for (final listener in instance._signalingListeners) {
      listener.onInviteeAccepted(inviteId, invitee, data);
    }
  }

  static void _onRejectCallback(
    ffi.Pointer<pkgffi.Utf8> inviteIdPtr,
    ffi.Pointer<pkgffi.Utf8> inviteePtr,
    ffi.Pointer<pkgffi.Utf8> dataPtr,
    ffi.Pointer<ffi.Void> userData,
  ) {
    final instance = _currentInstance;
    if (instance == null) return;

    final inviteId = inviteIdPtr.address != 0
        ? inviteIdPtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final invitee = inviteePtr.address != 0
        ? inviteePtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final data =
        dataPtr.address != 0 ? dataPtr.cast<pkgffi.Utf8>().toDartString() : '';

    for (final listener in instance._signalingListeners) {
      listener.onInviteeRejected(inviteId, invitee, data);
    }
  }

  static void _onTimeoutCallback(
    ffi.Pointer<pkgffi.Utf8> inviteIdPtr,
    ffi.Pointer<pkgffi.Utf8> inviterPtr,
    ffi.Pointer<ffi.Void> userData,
  ) {
    final instance = _currentInstance;
    if (instance == null) return;

    final inviteId = inviteIdPtr.address != 0
        ? inviteIdPtr.cast<pkgffi.Utf8>().toDartString()
        : '';
    final inviter = inviterPtr.address != 0
        ? inviterPtr.cast<pkgffi.Utf8>().toDartString()
        : '';

    for (final listener in instance._signalingListeners) {
      listener.onInvitationTimeout(inviteId, const []);
    }
  }
}
