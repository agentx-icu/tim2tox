Future<void> runFileAcceptFailureCleanup({
  required bool hasPendingRow,
  required void Function() markPendingFailed,
  required Future<void> Function() cancelNative,
  required void Function(Object error, StackTrace stackTrace) onCancelFailure,
}) async {
  if (hasPendingRow) markPendingFailed();
  try {
    await cancelNative();
  } catch (error, stackTrace) {
    onCancelFailure(error, stackTrace);
  }
}
