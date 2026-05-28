import 'dart:io';

import 'package:test/test.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import 'package:tim2tox_dart/models/chat_message.dart';

/// Pure-Dart unit tests (no native FFI) for the three persistence fixes:
/// - CR-05: deleting the last message must delete the on-disk history file.
/// - CR-06: updateFilePathSafely must not repoint history at a missing path.
/// - CR-07: markConversationViewed anchors the read barrier to the max
///   message timestamp instead of the local wall clock.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mhp_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  bool dirHasJson(Directory dir) => dir
      .listSync()
      .whereType<File>()
      .any((f) => f.path.endsWith('.json'));

  group('CR-05: empty conversation deletes the on-disk file', () {
    test('clearHistory removes the file and prevents resurrection', () async {
      const conversationId = 'cr05peer';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'hello',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          msgID: 'm1',
        ),
      );

      // appendHistory schedules a debounced save; flush it.
      await persistence.flushPendingSaves();
      expect(dirHasJson(tempDir), isTrue,
          reason: 'the history JSON should have been written to disk');

      await persistence.clearHistory(conversationId);
      expect(dirHasJson(tempDir), isFalse,
          reason: 'clearHistory must delete the JSON (and .bak) file');

      // A fresh instance pointed at the same dir must not resurrect anything.
      final fresh =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      final reloaded = await fresh.loadHistory(conversationId);
      expect(reloaded, isEmpty,
          reason: 'no on-disk file means no resurrection on restart');
    });
  });

  group('CR-06: updateFilePathSafely refuses a missing path', () {
    test('returns false and leaves the path unchanged when missing', () async {
      const conversationId = 'cr06peer';
      const msgID = 'cr06msg';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      final oldTemp = File('${tempDir.path}/old_temp.bin')
        ..writeAsBytesSync([1, 2, 3]);

      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: '',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
          msgID: msgID,
          filePath: oldTemp.path,
          mediaKind: 'file',
        ),
      );
      await persistence.flushPendingSaves();

      // Strict default: a non-existent new path is rejected.
      final missingPath = '${tempDir.path}/does_not_exist.bin';
      final rejected = await persistence.updateFilePathSafely(
        conversationId,
        msgID,
        missingPath,
        deleteOldTempFile: true,
      );
      expect(rejected, isFalse);

      var msg = persistence
          .getHistory(conversationId)
          .firstWhere((m) => m.msgID == msgID);
      expect(msg.filePath, oldTemp.path,
          reason: 'a rejected update must not mutate the stored path');

      // Existing path: accepted and the path is updated.
      final realFile = File('${tempDir.path}/real_file.bin')
        ..writeAsBytesSync([4, 5, 6, 7]);
      final accepted = await persistence.updateFilePathSafely(
        conversationId,
        msgID,
        realFile.path,
        deleteOldTempFile: false,
      );
      expect(accepted, isTrue);
      msg = persistence
          .getHistory(conversationId)
          .firstWhere((m) => m.msgID == msgID);
      expect(msg.filePath, realFile.path);

      // allowMissing: a missing path is accepted and the path updated.
      final futurePath = '${tempDir.path}/not_yet_here.bin';
      final allowed = await persistence.updateFilePathSafely(
        conversationId,
        msgID,
        futurePath,
        deleteOldTempFile: true,
        allowMissing: true,
      );
      expect(allowed, isTrue);
      msg = persistence
          .getHistory(conversationId)
          .firstWhere((m) => m.msgID == msgID);
      expect(msg.filePath, futurePath);
    });
  });

  group('CR-07: markConversationViewed uses a message-timestamp barrier', () {
    test('barrier anchors to max message timestamp, not wall clock', () async {
      const conversationId = 'cr07peer';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      final t1 = DateTime.fromMillisecondsSinceEpoch(10000);
      final t2 = DateTime.fromMillisecondsSinceEpoch(20000);
      final t3 = DateTime.fromMillisecondsSinceEpoch(30000);

      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'first',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: t1,
          msgID: 'c7a',
        ),
      );
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'second',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: t2,
          msgID: 'c7b',
        ),
      );

      expect(persistence.getUnreadCount(conversationId), 2);

      await persistence.markConversationViewed(conversationId);
      expect(persistence.getUnreadCount(conversationId), 0);
      expect(persistence.getLastViewTimestamp(conversationId),
          t2.millisecondsSinceEpoch);

      // A newer incoming message counts even though no wall-clock advanced.
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'third',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: t3,
          msgID: 'c7c',
        ),
      );
      expect(persistence.getUnreadCount(conversationId), 1);
    });

    test('empty conversation still advances the read barrier (regression)',
        () async {
      const conversationId = 'cr07empty';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      // Viewing a conversation with no loaded messages must still record that
      // it was viewed. Before the fix the empty-history early return left the
      // barrier at its 0 default.
      final before = DateTime.now().millisecondsSinceEpoch;
      await persistence.markConversationViewed(conversationId);
      final barrier = persistence.getLastViewTimestamp(conversationId);
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(barrier, greaterThanOrEqualTo(before));
      expect(barrier, lessThanOrEqualTo(after));
    });

    test('view barrier persists across reload for an unloaded conversation',
        () async {
      // Marking an on-disk-but-unloaded conversation viewed must load it and
      // persist the barrier, so a restart keeps the message read instead of
      // reverting to the stale on-disk barrier.
      const conversationId = 'cr07reload';
      final writer = MessageHistoryPersistence(historyDirectory: tempDir.path);
      await writer.appendHistory(
        conversationId,
        ChatMessage(
          text: 'hi',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(20000),
          msgID: 'r1',
        ),
      );
      await writer.flushPendingSaves();

      // Fresh instance: history is on disk but not in memory. Viewing it must
      // load the history, then persist the advanced barrier.
      final viewer = MessageHistoryPersistence(historyDirectory: tempDir.path);
      await viewer.markConversationViewed(conversationId);
      expect(viewer.getUnreadCount(conversationId), 0);

      // A second fresh instance simulates a restart; the persisted barrier must
      // reconcile the reloaded message as read.
      final restarted =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      await restarted.loadHistory(conversationId);
      expect(restarted.getUnreadCount(conversationId), 0,
          reason: 'the persisted barrier must survive the reload');
    });

    test('a clock-skewed / same-ms arrival after viewing is still unread',
        () async {
      // Strict `ts > lastView` dropped a genuinely new message whose timestamp
      // landed at or below the barrier (same millisecond, or remote clock
      // behind). isRead is now authoritative, so the new arrival counts.
      const conversationId = 'cr11skew';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'seen',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(20000),
          msgID: 's1',
        ),
      );
      await persistence.markConversationViewed(conversationId);
      expect(persistence.getUnreadCount(conversationId), 0);

      // A new inbound message stamped at the barrier (same-ms) must still count.
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'skewed new',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(20000),
          msgID: 's2',
        ),
      );
      expect(persistence.getUnreadCount(conversationId), 1,
          reason: 'a new arrival at/below the barrier must still be unread');
    });
  });
}
