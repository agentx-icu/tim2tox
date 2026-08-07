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
