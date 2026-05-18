/// TUICallKit Adapter
///
/// Adapts TUICallKit service calls to ToxAV implementation
/// This allows chat-uikit-flutter to use ToxAV without modification
///
/// Usage:
///   await TUICallKitAdapter.initialize(sdkPlatform, avService, callBridge);
///   This will intercept TUICallKit calls and route them to ToxAV

import 'dart:async';
import 'dart:convert';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import '../interfaces/logger_service.dart';
import 'call_bridge_service.dart';

/// TUICallKit service name (must match tuicore_define.dart / TUICallingService)
const String TUICALLKIT_SERVICE_NAME = "TUICallingService";

/// Method names
const String METHOD_NAME_CALL = "call";

/// Parameter names (must match tuicore_define.dart)
const String PARAM_NAME_TYPE = "type";
const String PARAM_NAME_USERIDS = "userIDs";
const String PARAM_NAME_GROUPID = "groupId";

/// Call types
const String TYPE_AUDIO = "audio";
const String TYPE_VIDEO = "video";

/// Callback for outgoing call initiated events.
/// [inviteID]: signaling invite ID, [userID]: remote user, [type]: "audio" or "video".
typedef OutgoingCallCallback = void Function(
    String inviteID, String userID, String type);
typedef OutgoingCallPreflight = Future<bool> Function(
    String userID, String type);

/// TUICallKit Adapter Service
///
/// Registers itself as a TUICallKit service in TUICore
/// and routes calls to ToxAV via CallBridgeService
class TUICallKitAdapter {
  static TUICallKitAdapter? _instance;
  final TencentCloudChatSdkPlatform _sdkPlatform;
  final CallAvBackend _avService;
  final CallBridgeService _callBridge;
  final LoggerService? _logger;

  // Track active calls by user ID
  final Map<String, String> _userToInviteId = {}; // userID -> inviteID

  /// Fires when an outgoing call is successfully initiated so the UI can show the ringing overlay.
  OutgoingCallCallback? onOutgoingCallInitiated;
  OutgoingCallPreflight? onBeforeOutgoingCall;

  /// When set, we only call endCall() before startCall() if this returns false (i.e. there is an active call).
  /// Avoids blocking the UI when native endCall() is invoked with no call in progress (e.g. second call after hangup).
  bool Function()? isCallIdle;

  TUICallKitAdapter._(this._sdkPlatform, this._avService, this._callBridge,
      {LoggerService? logger})
      : _logger = logger;

  /// Initialize the adapter
  static Future<TUICallKitAdapter> initialize(
    TencentCloudChatSdkPlatform sdkPlatform,
    CallAvBackend avService,
    CallBridgeService callBridge, {
    LoggerService? logger,
  }) async {
    if (_instance != null) return _instance!;

    _instance = TUICallKitAdapter._(sdkPlatform, avService, callBridge,
        logger: logger);
    _globalAdapter = _instance;
    await _instance!._registerService();
    return _instance!;
  }

  /// Internal setup (TUICore registration happens via registerToxAVWithTUICore).
  Future<void> _registerService() async {
    _logger?.log('[TUICallKitAdapter] Service initialized');
  }

  /// Intercept and handle TUICallKit calls
  /// This should be called from TencentCloudChatTUICore.audioCall/videoCall
  Future<bool> handleCall({
    required String type,
    required List<String> userids,
    String? groupid,
  }) async {
    try {
      await _handleCall({
        PARAM_NAME_TYPE: type,
        PARAM_NAME_USERIDS: userids,
        PARAM_NAME_GROUPID: groupid ?? "",
      });
      return true;
    } catch (e, st) {
      _logger?.logError('[TUICallKitAdapter] Error handling call', e, st);
      return false;
    }
  }

  /// Handle call method. Throws on failure so handleCall() can return false.
  Future<void> _handleCall(Map<String, Object> params) async {
    final type = params[PARAM_NAME_TYPE] as String?;
    final userids = params[PARAM_NAME_USERIDS] as List<String>?;
    final groupID = params[PARAM_NAME_GROUPID] as String?;

    if (userids == null || userids.isEmpty) {
      throw Exception('No userids provided');
    }

    // For now, only support 1-on-1 calls
    if (userids.length > 1) {
      throw Exception('Group calls not yet supported');
    }

    final userID = userids.first;
    final isVideo = type == TYPE_VIDEO;

    if (onBeforeOutgoingCall != null) {
      final allowed = await onBeforeOutgoingCall!(
        userID,
        type ?? TYPE_AUDIO,
      );
      if (!allowed) {
        throw Exception('Outgoing call preflight denied');
      }
    }

    // Create call data JSON
    final callData = jsonEncode({
      'type': type,
      'audio': true,
      'video': isVideo,
    });

    // Invite user via signaling
    final result = await _sdkPlatform.invite(
      invitee: userID,
      data: callData,
      onlineUserOnly: false,
      timeout: 30,
    );

    if (result.code != 0 || result.data == null) {
      throw Exception('Signaling invite failed: code=${result.code}');
    }

    final inviteID = result.data!;
    _userToInviteId[userID] = inviteID;

    // Resolve friend number BEFORE registering so the bridge gets the
    // correct value on first write. Previously this method called
    // `registerOutgoingCall` twice — once with `friendNumber: null` and
    // again with the resolved number — and any state-machine lookup that
    // landed in the gap (notably `onOutgoingCallInitiated` listeners that
    // queried `getCallInfo(inviteID).friendNumber`) saw `null`.
    final resolvedFriendNumber = _avService.getFriendNumberByUserId(userID);
    final hasFriend = resolvedFriendNumber != 0xFFFFFFFF;

    _callBridge.registerOutgoingCall(
      inviteID: inviteID,
      inviter: 'self',
      invitee: userID,
      data: callData,
      friendNumber: hasFriend ? resolvedFriendNumber : null,
      groupID: groupID,
    );

    // Notify listeners about the outgoing call so UI can show ringing overlay
    _logger?.logDebug(
        '[TUICallKitAdapter] _handleCall firing onOutgoingCallInitiated: '
        'inviteID=$inviteID userID=$userID type=$type '
        'cb=${onOutgoingCallInitiated != null ? "SET" : "NULL"}');
    onOutgoingCallInitiated?.call(inviteID, userID, type ?? TYPE_AUDIO);

    if (!hasFriend) {
      _logger?.logWarning(
          '[TUICallKitAdapter] Friend not found for userID=$userID; signaling-only call');
      return;
    }

    // Mid-tier opening targets in kbit/s. Adaptive bitrate callbacks (see
    // ToxAVService.setAudioBitrateChangedCallback / setVideoBitrateChangedCallback)
    // can re-tune these per-call once the link is established.
    const audioBitRate = 48;
    final videoBitRate = isVideo ? 2000 : 0;

    // Initialize ToxAV if needed
    if (!_avService.isInitialized) {
      await _avService.initialize();
    }

    // End any existing call to this friend before starting a new one
    // (prevents FRIEND_ALREADY_IN_CALL when user double-taps). Skip when app is idle to avoid
    // blocking the UI: native endCall() with no call in progress can block or take long (error 3).
    final skipEndCall = isCallIdle != null && isCallIdle!();
    if (!skipEndCall) {
      try {
        await _avService.endCall(resolvedFriendNumber);
      } catch (_) {
        // Ignore — no active call to end
      }
    }

    // Start the call
    final callResult = await _avService.startCall(resolvedFriendNumber,
        audioBitRate: audioBitRate, videoBitRate: videoBitRate);
    _logger?.log(
        '[TUICallKitAdapter] _handleCall startCall result=$callResult friendNumber=$resolvedFriendNumber');
  }

  /// Dispose
  ///
  /// Releases per-instance state and clears the static singleton holders so
  /// the next [initialize] returns a fresh adapter. Required for clean
  /// account-switch and logout/re-login flows: previously the static
  /// `_instance` / `_globalAdapter` references were never cleared, and a
  /// second `initialize()` call returned a stale adapter still holding
  /// references to the disposed `ToxAVService` and `CallBridgeService`.
  void dispose() {
    _userToInviteId.clear();
    if (identical(_instance, this)) {
      _instance = null;
    }
    if (identical(_globalAdapter, this)) {
      _globalAdapter = null;
    }
  }
}

/// Global adapter instance
TUICallKitAdapter? _globalAdapter;

/// Initialize TUICallKit adapter
/// This should be called during app initialization
Future<TUICallKitAdapter> initializeTUICallKitAdapter(
  TencentCloudChatSdkPlatform sdkPlatform,
  CallAvBackend avService,
  CallBridgeService callBridge, {
  LoggerService? logger,
}) async {
  return await TUICallKitAdapter.initialize(sdkPlatform, avService, callBridge,
      logger: logger);
}

/// Get global adapter instance
TUICallKitAdapter? getTUICallKitAdapter() {
  return _globalAdapter;
}
