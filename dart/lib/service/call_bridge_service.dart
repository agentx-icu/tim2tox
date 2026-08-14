// Call Bridge Service
//
// Bridges signaling events to ToxAV connections

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

  /// True once the ToxAV media leg has actually been started for this call
  /// (`startCall` for outgoing, `answerCall` for incoming). The `calling`
  /// state is set by [CallBridgeService.registerOutgoingCall] BEFORE the
  /// adapter starts the AV leg, so teardown paths must check this flag — not
  /// the `state` — before calling `endCall`, or they'd end a never-started
  /// call (native endCall with no call in progress can block or error).
  bool avLegStarted;

  CallInfo({
    required this.inviteID,
    required this.inviter,
    this.groupID,
    required this.inviteeList,
    required this.data,
    this.state = CallState.idle,
    this.friendNumber,
    this.avLegStarted = false,
  });
}

enum _TeardownOperation { reject, cancel, avEnd }

class _TeardownKey {
  const _TeardownKey(this.operation, this.target);

  final _TeardownOperation operation;
  final Object target;

  @override
  bool operator ==(Object other) {
    return other is _TeardownKey &&
        other.operation == operation &&
        other.target == target;
  }

  @override
  int get hashCode => Object.hash(operation, target);
}

class _PendingTeardown {
  _PendingTeardown(this.action);

  final Future<bool> Function() action;
  final Completer<bool> terminal = Completer<bool>();
  int attempts = 0;
  Timer? timer;
}

typedef _AvTeardownToken = ({String inviteID, int friendNumber});

/// Bridge service that connects signaling to ToxAV
class CallBridgeService {
  static const List<Duration> _teardownRetryDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
  ];
  static const int _maxTeardownAttempts = 6;

  final TencentCloudChatSdkPlatform _sdkPlatform;
  final CallAvBackend _avService;
  final LoggerService? _logger;

  // Active calls: inviteID -> CallInfo
  final Map<String, CallInfo> _activeCalls = {};

  final Map<_TeardownKey, _PendingTeardown> _pendingTeardowns = {};

  // Signaling listener
  V2TimSignalingListener? _signalingListener;

  // Callbacks
  //
  // `endReason` is populated whenever [state] is [CallState.ended] and the
  // termination origin is known. Values used by this bridge:
  //   - 'reject'  — invitee rejected the invitation (onInviteeRejected)
  //   - 'timeout' — invitation rang out without an answer (onInvitationTimeout)
  //   - 'cancel'  — caller cancelled before the call was up, or the local
  //     side aborted an outgoing/ringing call without ever entering inCall
  //   - 'hangup'  — either party hung up an established (inCall) session
  //
  // Consumers are expected to surface these in call-history rows so users can
  // tell "missed (timeout)" from "declined (reject)" from "cancelled (cancel)".
  void Function(String inviteID, CallState state, {String? endReason})?
      onCallStateChanged;

  CallBridgeService(this._sdkPlatform, this._avService, {LoggerService? logger})
      : _logger = logger {
    _setupSignalingListener();
  }

  /// Setup signaling listener
  void _setupSignalingListener() {
    _signalingListener = V2TimSignalingListener(
      onReceiveNewInvitation: (inviteID, inviter, groupID, inviteeList, data) {
        _logger?.log(
            '[CallBridge] onReceiveNewInvitation groupPresent=${groupID.isNotEmpty} inviteeCount=${inviteeList.length} dataLength=${data.length}');
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
        _logger?.log(
            '[CallBridge] invitation mapped friendResolved=${callInfo.friendNumber != null && callInfo.friendNumber != 0xFFFFFFFF} state=${callInfo.state}');
        onCallStateChanged?.call(inviteID, CallState.ringing);
      },
      onInvitationCancelled: (inviteID, inviter, data) {
        _logger?.log(
            '[CallBridge] onInvitationCancelled dataLength=${data.length}');
        final callInfo = _activeCalls[inviteID];
        if (callInfo != null) {
          final wasInCall = callInfo.state == CallState.inCall;
          callInfo.state = CallState.ended;
          // Only ends the ToxAV leg if it was actually started (avLegStarted).
          _endAvLegIfStarted(callInfo);
          _activeCalls.remove(inviteID);
          onCallStateChanged?.call(inviteID, CallState.ended,
              endReason: wasInCall ? 'hangup' : 'cancel');
        }
      },
      onInviteeAccepted: (inviteID, invitee, data) {
        _logger
            ?.log('[CallBridge] onInviteeAccepted dataLength=${data.length}');
        // Invitee accepted - this callback is for the inviter (caller)
        // The inviter already started the ToxAV leg after the signaling invite
        // succeeded (see TUICallKitAdapter._handleCall). Do not call
        // startCall() again here: a second toxav_call for the same friend can
        // fail with FRIEND_ALREADY_IN_CALL or disturb the active media leg.
        final callInfo = _activeCalls[inviteID];
        // Idempotency guard: the signaling transport can redeliver an accept
        // for a call that is already established. Re-firing `inCall` would
        // re-run enterCall / _startMediaCapture on a live call, so only
        // transition (and notify) on the first accept.
        if (callInfo != null && callInfo.state != CallState.inCall) {
          callInfo.state = CallState.inCall;
          onCallStateChanged?.call(inviteID, CallState.inCall);
        }
      },
      onInviteeRejected: (inviteID, invitee, data) {
        _logger
            ?.log('[CallBridge] onInviteeRejected dataLength=${data.length}');
        // Invitee rejected the invitation.
        final callInfo = _activeCalls[inviteID];
        if (callInfo != null) {
          callInfo.state = CallState.ended;
          _endAvLegIfStarted(callInfo);
          _activeCalls.remove(inviteID);
          onCallStateChanged?.call(inviteID, CallState.ended,
              endReason: 'reject');
        }
      },
      onInvitationTimeout: (inviteID, inviteeList) {
        _logger?.log(
            '[CallBridge] onInvitationTimeout inviteeCount=${inviteeList.length}');
        // Invitation rang out without an answer.
        final callInfo = _activeCalls[inviteID];
        if (callInfo != null) {
          callInfo.state = CallState.ended;
          _endAvLegIfStarted(callInfo);
          _activeCalls.remove(inviteID);
          onCallStateChanged?.call(inviteID, CallState.ended,
              endReason: 'timeout');
        }
      },
    );

    // Register listener with SDK platform
    _sdkPlatform.addSignalingListener(listener: _signalingListener!);
  }

  void _endAvLegIfStarted(CallInfo callInfo) {
    final friendNumber = callInfo.friendNumber;
    // Only tear down the ToxAV leg if it was actually started. `calling` is
    // recorded by registerOutgoingCall BEFORE the adapter calls startCall(), so
    // a reject/cancel/timeout in that gap must NOT call endCall() on a
    // never-started call (native endCall with no call in progress can block or
    // error — see TUICallKitAdapter._handleCall).
    if (friendNumber == null || !callInfo.avLegStarted) {
      return;
    }
    unawaited(_startAvLegTeardown(callInfo.inviteID, friendNumber));
  }

  Future<bool> _startAvLegTeardown(
    String inviteID,
    int friendNumber, {
    bool waitForTerminal = false,
  }) {
    return _startBoundedTeardown(
      _TeardownKey(
        _TeardownOperation.avEnd,
        (inviteID: inviteID, friendNumber: friendNumber),
      ),
      () => _tryEndAvLeg((
        inviteID: inviteID,
        friendNumber: friendNumber,
      )),
      waitForTerminal: waitForTerminal,
    );
  }

  Future<bool> _tryRejectInvite(String inviteID) async {
    try {
      final result = await _sdkPlatform.reject(inviteID: inviteID);
      return result.code == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryCancelInvite(String inviteID) async {
    try {
      final result = await _sdkPlatform.cancel(inviteID: inviteID);
      return result.code == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryEndAvLeg(_AvTeardownToken token) async {
    final activeCall = _activeCalls.values.where(
      (callInfo) =>
          callInfo.inviteID != token.inviteID &&
          callInfo.friendNumber == token.friendNumber &&
          callInfo.avLegStarted,
    );
    if (activeCall.isNotEmpty) {
      return true;
    }
    try {
      return await _avService.endCall(token.friendNumber);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _startBoundedTeardown(
      _TeardownKey key, Future<bool> Function() action,
      {bool waitForTerminal = false}) async {
    final replaced = _pendingTeardowns.remove(key);
    replaced?.timer?.cancel();
    if (replaced != null && !replaced.terminal.isCompleted) {
      replaced.terminal.complete(false);
    }
    final pending = _PendingTeardown(action);
    _pendingTeardowns[key] = pending;

    final success = await _runTeardownAttempt(key, pending);
    if (waitForTerminal) return pending.terminal.future;
    return success;
  }

  Future<bool> _runTeardownAttempt(
    _TeardownKey key,
    _PendingTeardown pending,
  ) async {
    if (_pendingTeardowns[key] != pending) {
      if (!pending.terminal.isCompleted) pending.terminal.complete(false);
      return false;
    }

    pending.attempts += 1;
    final success = await pending.action();
    if (_pendingTeardowns[key] != pending) {
      if (!pending.terminal.isCompleted) pending.terminal.complete(false);
      return success;
    }
    if (success || pending.attempts >= _maxTeardownAttempts) {
      _pendingTeardowns.remove(key);
      if (!pending.terminal.isCompleted) pending.terminal.complete(success);
      return success;
    }

    final delay = _teardownRetryDelays[pending.attempts - 1];
    pending.timer = Timer(delay, () {
      unawaited(_runTeardownAttempt(key, pending));
    });
    return false;
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
    _logger?.log(
        '[CallBridge] registerOutgoingCall groupPresent=${groupID != null && groupID.isNotEmpty} hasFriendNumber=${friendNumber != null} dataLength=${data.length}');
    _activeCalls[inviteID] = CallInfo(
      inviteID: inviteID,
      inviter: inviter,
      groupID: groupID,
      inviteeList: <String>[invitee],
      data: data,
      state: CallState.calling,
      friendNumber: friendNumber,
      // avLegStarted stays false until the adapter calls [markAvLegStarted]
      // after _avService.startCall() succeeds.
    );
  }

  /// Claim ownership of a just-started outgoing ToxAV media leg.
  ///
  /// Returns false when the invite was already removed while `startCall` was
  /// awaiting. In that stale-success case the bridge owns cleanup and starts a
  /// bounded AV teardown using the resolved friend number supplied by the
  /// adapter.
  bool markAvLegStarted(
    String inviteID, {
    int? friendNumber,
    bool teardownIfMissing = true,
  }) {
    _logger?.log(
        '[CallBridge] markAvLegStarted hasFriendNumber=${friendNumber != null}');
    final callInfo = _activeCalls[inviteID];
    if (callInfo == null) {
      if (friendNumber != null && teardownIfMissing) {
        unawaited(_startAvLegTeardown(inviteID, friendNumber));
      }
      return false;
    }
    if (friendNumber != null) {
      callInfo.friendNumber = friendNumber;
    }
    callInfo.avLegStarted = true;
    return true;
  }

  Future<bool> endAvLegAndWaitForTeardown(
    String inviteID,
    int friendNumber,
  ) {
    return _startAvLegTeardown(
      inviteID,
      friendNumber,
      waitForTerminal: true,
    );
  }

  Future<void> waitForAvTeardownsForFriend(int friendNumber) async {
    while (true) {
      final pending = _pendingTeardowns.entries
          .where((entry) {
            if (entry.key.operation != _TeardownOperation.avEnd) {
              return false;
            }
            final target = entry.key.target;
            return target is _AvTeardownToken &&
                target.friendNumber == friendNumber;
          })
          .map((entry) => entry.value.terminal.future)
          .toList();
      if (pending.isEmpty) return;
      await Future.wait(pending);
    }
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

    final friendNumber = callInfo.friendNumber;
    if (friendNumber == null || friendNumber == 0xFFFFFFFF) {
      await _failAccept(inviteID, postAccept: false);
      return false;
    }

    // Accept signaling invitation. If the SDK rejects the accept (transport
    // failure, expired invite, etc.), signaling never reached the peer's
    // accepted state, so hidden cleanup must stay on the pre-accept reject path.
    final result = await _sdkPlatform.accept(inviteID: inviteID);
    if (!identical(_activeCalls[inviteID], callInfo)) {
      return false;
    }
    if (result.code != 0) {
      await _failAccept(inviteID, postAccept: false);
      return false;
    }

    await waitForAvTeardownsForFriend(friendNumber);
    if (!identical(_activeCalls[inviteID], callInfo)) {
      return false;
    }

    // Start ToxAV call
    final avResult = await _avService.answerCall(friendNumber,
        audioBitRate: audioBitRate, videoBitRate: videoBitRate);
    if (!identical(_activeCalls[inviteID], callInfo)) {
      if (avResult) {
        await _startAvLegTeardown(inviteID, friendNumber);
      }
      return false;
    }
    if (avResult) {
      callInfo.avLegStarted = true;
      callInfo.state = CallState.inCall;
      onCallStateChanged?.call(inviteID, CallState.inCall);
      return true;
    }
    await _failAccept(inviteID, postAccept: true);
    return false;
  }

  /// Tear down a failed accept while hiding visible call state immediately.
  /// When `accept()` itself failed, signaling never reached the peer's accepted
  /// state, so bounded cleanup uses `reject` and reports `cancel`. Once
  /// `accept()` succeeded, native signaling has consumed the received route;
  /// if the AV answer then fails, only the ToxAV leg can be retried and the
  /// visible outcome is an established-call `hangup`.
  Future<void> _failAccept(String inviteID, {required bool postAccept}) async {
    // Capture friendNumber before remove(); endCall() needs it and the entry
    // is still in the map when acceptInvitation calls into _failAccept.
    final int? friendNumber =
        postAccept ? _activeCalls[inviteID]?.friendNumber : null;

    _activeCalls.remove(inviteID);
    onCallStateChanged?.call(inviteID, CallState.ended,
        endReason: postAccept ? 'hangup' : 'cancel');

    if (postAccept && friendNumber != null) {
      await _startBoundedTeardown(
        _TeardownKey(
          _TeardownOperation.avEnd,
          (inviteID: inviteID, friendNumber: friendNumber),
        ),
        () => _tryEndAvLeg((
          inviteID: inviteID,
          friendNumber: friendNumber,
        )),
      );
    }
    if (postAccept) {
      return;
    }
    await _startBoundedTeardown(
      _TeardownKey(_TeardownOperation.reject, inviteID),
      () => _tryRejectInvite(inviteID),
    );
  }

  /// Reject an invitation
  Future<bool> rejectInvitation(String inviteID) async {
    if (_activeCalls.containsKey(inviteID)) {
      _activeCalls.remove(inviteID);
      onCallStateChanged?.call(inviteID, CallState.ended, endReason: 'reject');
      return _startBoundedTeardown(
        _TeardownKey(_TeardownOperation.reject, inviteID),
        () => _tryRejectInvite(inviteID),
      );
    }

    final result = await _sdkPlatform.reject(inviteID: inviteID);
    if (result.code == 0) {
      onCallStateChanged?.call(inviteID, CallState.ended, endReason: 'reject');
      return true;
    }
    return false;
  }

  /// End a call. The emitted `endReason` reflects which side of the lifecycle
  /// we were in: `'cancel'` for an outgoing call that never connected, and
  /// `'hangup'` for an established (or just-accepted) session.
  Future<bool> endCall(String inviteID) {
    return _endCall(inviteID, awaitAvTeardown: false);
  }

  /// End a call and wait for the hidden AV teardown to finish or exhaust its
  /// bounded retries. Used by serialized stale-start cleanup before another
  /// native start may claim the same friend.
  Future<bool> endCallAndWaitForTeardown(String inviteID) {
    return _endCall(inviteID, awaitAvTeardown: true);
  }

  Future<bool> _endCall(
    String inviteID, {
    required bool awaitAvTeardown,
  }) async {
    final callInfo = _activeCalls[inviteID];
    if (callInfo == null) return false;

    final friendNumber = callInfo.friendNumber;
    final avLegStarted = callInfo.avLegStarted;
    final isOutgoingPreAnswer = callInfo.state == CallState.calling;

    callInfo.state = CallState.ended;
    _activeCalls.remove(inviteID);
    onCallStateChanged?.call(inviteID, CallState.ended,
        endReason: isOutgoingPreAnswer ? 'cancel' : 'hangup');

    // Only end the ToxAV leg if it was actually started — an outgoing call torn
    // down during the registerOutgoingCall→startCall gap has friendNumber set
    // but no media leg yet, and endCall on a never-started call can block/error.
    if (friendNumber != null && avLegStarted) {
      final teardown = _startBoundedTeardown(
        _TeardownKey(
          _TeardownOperation.avEnd,
          (inviteID: inviteID, friendNumber: friendNumber),
        ),
        () => _tryEndAvLeg((
          inviteID: inviteID,
          friendNumber: friendNumber,
        )),
        waitForTerminal: awaitAvTeardown,
      );
      if (awaitAvTeardown) {
        await teardown;
      } else {
        unawaited(teardown);
      }
    }

    if (isOutgoingPreAnswer) {
      unawaited(_startBoundedTeardown(
        _TeardownKey(_TeardownOperation.cancel, inviteID),
        () => _tryCancelInvite(inviteID),
      ));
    }
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
    for (final pending in _pendingTeardowns.values) {
      pending.timer?.cancel();
      if (!pending.terminal.isCompleted) pending.terminal.complete(false);
    }
    _pendingTeardowns.clear();
    if (_signalingListener != null) {
      _sdkPlatform.removeSignalingListener(listener: _signalingListener);
    }
    _activeCalls.clear();
  }
}
