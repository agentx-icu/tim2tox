/// Call Bridge Service
///
/// Bridges signaling events to ToxAV connections

import 'dart:async';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSignalingListener.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import '../interfaces/logger_service.dart';
import 'call_av_backend.dart';

export 'call_av_backend.dart';

/// Call state enumeration
enum CallState {
  idle,
  calling,
  ringing,
  inCall,
  ended,
}

/// Call information
class CallInfo {
  final String inviteID;
  final String inviter;
  final String? groupID;
  final List<String> inviteeList;
  final String data;
  CallState state;
  int? friendNumber; // Tox friend number

  CallInfo({
    required this.inviteID,
    required this.inviter,
    this.groupID,
    required this.inviteeList,
    required this.data,
    this.state = CallState.idle,
    this.friendNumber,
  });
}

/// Bridge service that connects signaling to ToxAV
class CallBridgeService {
  final TencentCloudChatSdkPlatform _sdkPlatform;
  final CallAvBackend _avService;
  final LoggerService? _logger;

  // Active calls: inviteID -> CallInfo
  final Map<String, CallInfo> _activeCalls = {};

  // Signaling listener
  V2TimSignalingListener? _signalingListener;

  // Callbacks
  Function(String inviteID, CallState state)? onCallStateChanged;

  CallBridgeService(this._sdkPlatform, this._avService,
      {LoggerService? logger})
      : _logger = logger {
    _setupSignalingListener();
  }

  /// Setup signaling listener
  void _setupSignalingListener() {
    _signalingListener = V2TimSignalingListener(
      onReceiveNewInvitation: (inviteID, inviter, groupID, inviteeList, data) {
        // New invitation received
        final callInfo = CallInfo(
          inviteID: inviteID,
          inviter: inviter,
          groupID: groupID,
          inviteeList: inviteeList,
          data: data,
          state: CallState.ringing,
        );

        // Get friend number from inviter user ID
        callInfo.friendNumber = _avService.getFriendNumberByUserId(inviter);
        if (callInfo.friendNumber == 0xFFFFFFFF) {
          // Friend not found, try to get from invitee list if 1-on-1
          if (inviteeList.isNotEmpty) {
            callInfo.friendNumber =
                _avService.getFriendNumberByUserId(inviteeList.first);
          }
        }

        _activeCalls[inviteID] = callInfo;
        onCallStateChanged?.call(inviteID, CallState.ringing);
      },
      onInvitationCancelled: (inviteID, inviter, data) {
        // Invitation cancelled
        final callInfo = _activeCalls[inviteID];
        if (callInfo != null) {
          callInfo.state = CallState.ended;
          if (callInfo.friendNumber != null) {
            _avService.endCall(callInfo.friendNumber!);
          }
          _activeCalls.remove(inviteID);
          onCallStateChanged?.call(inviteID, CallState.ended);
        }
      },
      onInviteeAccepted: (inviteID, invitee, data) async {
        // Invitee accepted - this callback is for the inviter (caller)
        // The inviter should already have started the call, so we just update state
        final callInfo = _activeCalls[inviteID];
        if (callInfo != null) {
          // If we're the inviter and haven't started the call yet, start it now
          if (callInfo.state == CallState.calling &&
              callInfo.friendNumber != null) {
            try {
              // Mid-tier opening targets in kbit/s; the integrator (e.g.
              // toxee's CallCodecProfile) can be wired to push different
              // targets in response to bitrate-change callbacks once the
              // call is up. See `tim2tox/source/ToxAVManager.h` for the
              // peer-suggested bitrate callbacks.
              const audioBitRate = 48;
              const videoBitRate = 2000;

              final success = await _avService.startCall(callInfo.friendNumber!,
                  audioBitRate: audioBitRate, videoBitRate: videoBitRate);
              if (success) {
                callInfo.state = CallState.inCall;
                onCallStateChanged?.call(inviteID, CallState.inCall);
              }
            } catch (e, st) {
              _logger?.logError('[CallBridge] Error starting call', e, st);
            }
          } else {
            // Call already started, just update state
            callInfo.state = CallState.inCall;
            onCallStateChanged?.call(inviteID, CallState.inCall);
          }
        }
      },
      onInviteeRejected: (inviteID, invitee, data) {
        // Invitee rejected
        final callInfo = _activeCalls[inviteID];
        if (callInfo != null) {
          callInfo.state = CallState.ended;
          _activeCalls.remove(inviteID);
          onCallStateChanged?.call(inviteID, CallState.ended);
        }
      },
      onInvitationTimeout: (inviteID, inviteeList) {
        // Invitation timeout
        final callInfo = _activeCalls[inviteID];
        if (callInfo != null) {
          callInfo.state = CallState.ended;
          if (callInfo.friendNumber != null) {
            _avService.endCall(callInfo.friendNumber!);
          }
          _activeCalls.remove(inviteID);
          onCallStateChanged?.call(inviteID, CallState.ended);
        }
      },
    );

    // Register listener with SDK platform
    _sdkPlatform.addSignalingListener(listener: _signalingListener!);
  }

  /// Register a just-created outgoing signaling call so later cancel/end events
  /// can resolve the friend number and current state.
  void registerOutgoingCall({
    required String inviteID,
    required String inviter,
    required String invitee,
    required String data,
    int? friendNumber,
    String? groupID,
  }) {
    _activeCalls[inviteID] = CallInfo(
      inviteID: inviteID,
      inviter: inviter,
      groupID: groupID,
      inviteeList: <String>[invitee],
      data: data,
      state: CallState.calling,
      friendNumber: friendNumber,
    );
  }

  /// Accept an invitation and start call.
  ///
  /// `audioBitRate` and `videoBitRate` are in kbit/s (the libtoxav unit).
  /// Defaults match the mid-tier target used elsewhere in this bridge
  /// (48 kbps audio / 2000 kbps video). The previous defaults — 64000 audio
  /// and 5000000 video — were latently wrong: they only worked because no
  /// known caller used the defaults, but if anyone ever did the encoder
  /// would have been asked for ~64 Mbit/s of audio and ~5 Gbit/s of video.
  Future<bool> acceptInvitation(String inviteID,
      {int audioBitRate = 48, int videoBitRate = 2000}) async {
    final callInfo = _activeCalls[inviteID];
    if (callInfo == null) return false;

    // Accept signaling invitation
    final result = await _sdkPlatform.accept(inviteID: inviteID);
    if (result.code != 0) return false;

    // Start ToxAV call
    if (callInfo.friendNumber != null) {
      final avResult = await _avService.answerCall(callInfo.friendNumber!,
          audioBitRate: audioBitRate, videoBitRate: videoBitRate);
      if (avResult) {
        callInfo.state = CallState.inCall;
        onCallStateChanged?.call(inviteID, CallState.inCall);
        return true;
      }
    }

    return false;
  }

  /// Reject an invitation
  Future<bool> rejectInvitation(String inviteID) async {
    final result = await _sdkPlatform.reject(inviteID: inviteID);
    if (result.code == 0) {
      _activeCalls.remove(inviteID);
      onCallStateChanged?.call(inviteID, CallState.ended);
      return true;
    }
    return false;
  }

  /// End a call
  Future<bool> endCall(String inviteID) async {
    final callInfo = _activeCalls[inviteID];
    if (callInfo == null) return false;

    if (callInfo.friendNumber != null) {
      await _avService.endCall(callInfo.friendNumber!);
    }

    // Cancel signaling if we're the inviter
    if (callInfo.state == CallState.calling) {
      await _sdkPlatform.cancel(inviteID: inviteID);
    }

    callInfo.state = CallState.ended;
    _activeCalls.remove(inviteID);
    onCallStateChanged?.call(inviteID, CallState.ended);
    return true;
  }

  /// Get active call info
  CallInfo? getCallInfo(String inviteID) {
    return _activeCalls[inviteID];
  }

  /// Get all active calls
  List<CallInfo> getActiveCalls() {
    return _activeCalls.values.toList();
  }

  /// Cleanup
  void dispose() {
    if (_signalingListener != null) {
      _sdkPlatform.removeSignalingListener(listener: _signalingListener);
    }
    _activeCalls.clear();
  }
}
