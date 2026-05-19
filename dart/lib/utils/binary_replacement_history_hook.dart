/// Binary replacement scheme history persistence hook
/// 
/// This hook provides message persistence for binary replacement scheme by:
/// 1. Wrapping V2TimAdvancedMsgListener to automatically save received messages
/// 2. Intercepting history message queries to load from persistence service
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'message_history_persistence.dart';
import 'message_converter.dart';

/// Binary replacement history hook
///
/// Provides hooks for binary replacement scheme to persist messages automatically
class BinaryReplacementHistoryHook {
  static MessageHistoryPersistence? _persistence;
  static String? _selfId;

  /// Monotonic counter bumped on every [initialize] call.
  ///
  /// `_persistence` and `_selfId` are static, so a logout-then-login as a
  /// different account replaces them globally. Any in-flight `saveMessage`
  /// that started under the previous session can finish *after* the
  /// re-init and would otherwise write under the new account's persistence
  /// + selfId — corrupting history (X8 in
  /// `local-storage-review-2026-05-18.md`).
  ///
  /// Each [saveMessage] captures the generation at entry; if the generation
  /// has changed by the time the dedup scan or the on-disk append would
  /// run, the call short-circuits. This bounds cross-session leakage to a
  /// single skipped message rather than a cross-account write.
  static int _generation = 0;

  /// Initialize the hook with persistence service and self ID
  static void initialize(MessageHistoryPersistence persistence, String selfId) {
    _persistence = persistence;
    _selfId = selfId;
    _generation++;
  }

  /// Visible-for-tests: the current generation counter. Used by the X8
  /// regression test to assert re-init bumps the counter.
  static int get generation => _generation;
  
  /// Wrap a V2TimAdvancedMsgListener to automatically save received messages
  /// 
  /// Returns a new listener that:
  /// 1. Calls the original listener's callbacks
  /// 2. Automatically saves received messages to persistence service
  static V2TimAdvancedMsgListener wrapListener(V2TimAdvancedMsgListener original) {
    return _WrappedAdvancedMsgListener(original);
  }
  
  /// Save a V2TimMessage to persistence (public for external use)
  /// 
  /// CRITICAL: For binary replacement scheme, FfiChatService already saves messages
  /// via _appendHistory when receiving/sending. This hook should only save messages
  /// that come through UIKit's listeners (onRecvNewMessage/onRecvMessageModified)
  /// and are NOT already saved by FfiChatService.
  /// 
  /// However, since we can't easily distinguish between messages from FfiChatService
  /// and messages from UIKit listeners, we check for duplicates before saving.
  static Future<void> saveMessage(V2TimMessage v2Msg) async {
    // Snapshot the session-scoped fields at entry. If `initialize` runs again
    // before we return (e.g. logout-then-login during await points below),
    // [_generation] will diverge from [capturedGeneration] and we abort
    // rather than write under the new account's persistence/selfId.
    final capturedGeneration = _generation;
    final capturedPersistence = _persistence;
    final capturedSelfId = _selfId;
    if (capturedPersistence == null || capturedSelfId == null) return;

    try {
      // CRITICAL: Skip messages with m-prefix IDs from native FFI callbacks.
      // These are duplicate messages created by HandleFriendMessage in C++ with temporary IDs.
      // The same message will arrive through the Dart stream path with a real ID.
      // Saving m-prefix messages causes duplicates in persistence/history.
      final msgID = v2Msg.msgID ?? v2Msg.id ?? '';
      if (msgID.startsWith('m') && RegExp(r'^m\d+-\d+$').hasMatch(msgID)) {
        return;
      }

      // Convert V2TimMessage to ChatMessage using the captured selfId so the
      // `isSelf` bit reflects the session that received the callback, not
      // whatever account is logged in by the time we reach this point.
      final chatMsg =
          MessageConverter.v2TimMessageToChatMessage(v2Msg, capturedSelfId);

      // Determine conversation ID
      final conversationId = v2Msg.groupID ?? v2Msg.userID ?? '';
      if (conversationId.isEmpty) return;

      // X8: if a new session was started while we were converting/checking,
      // abort — better to drop one event than to write the previous
      // session's message into the new account's persistence.
      if (_generation != capturedGeneration) return;

      // CRITICAL: Check if message already exists in persistence to avoid duplicates
      // For binary replacement scheme, FfiChatService already saves messages when receiving/sending
      // This hook should only save messages that are NOT already saved by FfiChatService
      final existingHistory = capturedPersistence.getHistory(conversationId);

      // Identity check, in priority order:
      //   1. msgID match  — exact, used whenever both messages carry an msgID.
      //   2. Content fallback when msgID is unreliable — match (fromUserId,
      //      text, timestamp within 2s). This is the path that catches
      //      "same logical message arrived via two callbacks with different
      //      IDs"; we *must* include fromUserId or two senders in a group
      //      chat typing identical short replies ("ok") within the window
      //      would collapse into one. We also shorten the window from 5s
      //      to 2s — the original 5s window was wide enough to swallow
      //      a real user sending two distinct messages quickly.
      const dedupWindow = Duration(seconds: 2);
      final chatMsgID = chatMsg.msgID;
      final messageExists = existingHistory.any((msg) {
        if (chatMsgID != null && msg.msgID == chatMsgID) return true;

        if (chatMsg.text.isEmpty) return false;
        if (msg.text != chatMsg.text) return false;
        if (msg.fromUserId != chatMsg.fromUserId) return false;
        if (msg.isSelf != chatMsg.isSelf) return false;
        final timeDiff = chatMsg.timestamp.difference(msg.timestamp).abs();
        return timeDiff <= dedupWindow;
      });
      
      if (messageExists) {
        // Message already exists, skip saving to avoid duplicate
        return;
      }
      
      // X8: final generation check before touching disk. The dedup scan
      // above is sync, but `appendHistory` schedules a debounced save and
      // may not complete until well after the next event loop turn. If the
      // session changed in the meantime, route this message to the dropped
      // bucket instead of the new account's history.
      if (_generation != capturedGeneration) return;

      // Save to persistence only if message doesn't exist. Await the on-disk
      // save inside the try block so disk-quota / permission failures land in
      // the catch path instead of becoming silent uncaught Future errors.
      await capturedPersistence.appendHistory(conversationId, chatMsg);
    } catch (e) {
      // Silently handle errors to avoid breaking the app
    }
  }
}

/// Wrapped V2TimAdvancedMsgListener that automatically saves messages
class _WrappedAdvancedMsgListener extends V2TimAdvancedMsgListener {
  final V2TimAdvancedMsgListener original;
  
  _WrappedAdvancedMsgListener(this.original) : super(
    onRecvNewMessage: (V2TimMessage message) {
      // Save message to persistence before calling original callback
      BinaryReplacementHistoryHook.saveMessage(message);
      // Call original callback
      original.onRecvNewMessage(message);
    },
    onRecvMessageModified: (V2TimMessage message) {
      // CRITICAL: Also save modified messages (e.g., sent messages that change from pending to sent)
      // This ensures sent messages are persisted even if they're notified via onRecvMessageModified
      BinaryReplacementHistoryHook.saveMessage(message);
      // Call original callback
      original.onRecvMessageModified(message);
    },
    onSendMessageProgress: original.onSendMessageProgress,
    onRecvC2CReadReceipt: original.onRecvC2CReadReceipt,
    onRecvMessageRevoked: original.onRecvMessageRevoked,
    onRecvMessageReadReceipts: original.onRecvMessageReadReceipts,
    onRecvMessageExtensionsChanged: original.onRecvMessageExtensionsChanged,
    onRecvMessageExtensionsDeleted: original.onRecvMessageExtensionsDeleted,
    onMessageDownloadProgressCallback: original.onMessageDownloadProgressCallback,
    onRecvMessageReactionsChanged: original.onRecvMessageReactionsChanged,
    onRecvMessageRevokedWithInfo: original.onRecvMessageRevokedWithInfo,
    onGroupMessagePinned: original.onGroupMessagePinned,
  );
}
