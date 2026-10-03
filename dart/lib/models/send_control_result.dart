/// Outcome of a single-message send-control request
/// (`FfiChatService.cancelQueuedMessage` / `retryFailedMessage`).
enum SendControlResult {
  /// Done: the queued item was cancelled, or the failed row re-queued.
  success,

  /// A drain already handed the item to transport; it can no longer be
  /// cancelled (it may be delivered).
  alreadyClaimed,

  /// Nothing to act on: not our queued (cancel) / failed (retry) text row,
  /// a self-conversation row, or the state already changed.
  notApplicable,

  /// The durable write failed; the previous state is kept (still pending /
  /// still failed) and the request may be retried.
  persistFailed,
}
