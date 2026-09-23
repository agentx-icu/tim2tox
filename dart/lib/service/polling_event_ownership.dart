bool acceptsPollingEvent({
  required int serviceInstanceId,
  required int eventInstanceId,
  required bool isKnownEventInstance,
}) {
  if (eventInstanceId == serviceInstanceId) {
    return true;
  }
  if (serviceInstanceId != 0) {
    return false;
  }
  return isKnownEventInstance;
}

/// Native group notifications without user_data (groupQuitNotification,
/// groupJoinNotification, groupInviteNotification, groupJoinFailedNotification,
/// groupChatIdStored, groupTypeStored) reach ONE process-global handler, so
/// each carries the emitting native session: `instance_id` and
/// `session_epoch`. One is applied only when this service owns that instance
/// (same rule as [acceptsPollingEvent]) AND the epoch is still that
/// instance's live session — a notification the previous account's session
/// emitted (queued at the port, or replayed after an account switch that
/// reused the instance id) carries an epoch that is no longer live.
/// Unstamped or malformed payloads cannot be attributed and are rejected.
bool acceptsNativeSessionNotification({
  required Map<String, dynamic> data,
  required bool Function(int instanceId) ownsInstance,
  required int Function(int instanceId) liveSessionEpoch,
}) {
  final instanceId = data['instance_id'];
  final sessionEpoch = data['session_epoch'];
  if (instanceId is! int || sessionEpoch is! int || sessionEpoch <= 0) {
    return false;
  }
  if (!ownsInstance(instanceId)) {
    return false;
  }
  return liveSessionEpoch(instanceId) == sessionEpoch;
}
