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

  group('Cross-path dedup: same inbound message via both hybrid paths', () {
    // Regression for the toxee hybrid double-delivery. An inbound message
    // arrives through BOTH the binary-replacement V2TimAdvancedMsgListener
    // (native `msg_<n>_<nanos>_<seq>` id) and the FfiChatService poll path
    // (`<millis>_<n>_<toxId>` id), each assigning a DIFFERENT msgID. msgID
    // dedup can't see them as the same message; the content fallback must.
    // Before the fix appendHistory's content dedup sat behind
    // `else if (msgID == null)` and never ran when both copies carried ids,
    // so the echo persisted twice (observed live against the echo peer).
    test('two different msgIDs, same content within 2s → stored once',
        () async {
      const conversationId = 'xpathpeer';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      // Copy A — native V2TIM-style id (binary-replacement path).
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'echo-roundtrip',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000000),
          msgID: 'msg_0_1000000000000_2',
        ),
      );
      // Copy B — poll-path id, same message, 573ms later (within window).
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'echo-roundtrip',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000573),
          msgID: '1000573_0_$conversationId',
        ),
      );

      expect(persistence.getHistory(conversationId).length, 1,
          reason:
              'same inbound message via two paths (different ids) must dedup');
    });

    test('distinct text with different ids is kept (no false collapse)',
        () async {
      const conversationId = 'xpathdistinct';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'first distinct',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(2000000),
          msgID: 'd1',
        ),
      );
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'second distinct',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(2000100),
          msgID: 'd2',
        ),
      );

      expect(persistence.getHistory(conversationId).length, 2,
          reason: 'different text must never be collapsed by content dedup');
    });

    test('identical text outside the 2s window is kept (window respected)',
        () async {
      const conversationId = 'xpathwindow';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'ok',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(3000000),
          msgID: 'w1',
        ),
      );
      // 3s later — a genuine repeat the peer typed, NOT a dual-path echo.
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'ok',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(3003000),
          msgID: 'w2',
        ),
      );

      expect(persistence.getHistory(conversationId).length, 2,
          reason:
              'identical text >2s apart is a real repeat, not a duplicate');
    });

    test('dropped msgID stays resolvable via alias for removeMessage', () async {
      // codex P1: dedup collapses two ids into one row, keeping the LATER id.
      // The dropped (first) id must remain resolvable, or every consumer that
      // still holds it (revoke/modify via the binary-replacement path, a delete
      // keyed on the native id) silently no-ops.
      const conversationId = 'xpathaliasrm';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      const nativeId = 'msg_0_5000000000000_2'; // arrives first → its id is dropped
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'aliased',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(5000000),
          msgID: nativeId,
        ),
      );
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'aliased',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(5000400),
          msgID: '5000400_0_$conversationId',
        ),
      );
      expect(persistence.getHistory(conversationId).length, 1);

      // Remove by the DROPPED native id — alias must route it to the kept row.
      final removed = await persistence.removeMessage(conversationId, nativeId);
      expect(removed, isTrue,
          reason: 'the dropped cross-path id must resolve through the alias');
      expect(persistence.getHistory(conversationId), isEmpty);
    });

    test('dropped msgID stays resolvable via alias for updateMessage', () async {
      const conversationId = 'xpathaliasupd';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      const nativeId = 'msg_0_5100000000000_2';
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'editme',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(5100000),
          msgID: nativeId,
        ),
      );
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'editme',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(5100400),
          msgID: '5100400_0_$conversationId',
        ),
      );

      final ok = await persistence.updateMessage(
        conversationId,
        nativeId, // the dropped id
        ChatMessage(
          text: 'editme',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(5100400),
          msgID: nativeId,
          isRead: true,
        ),
      );
      expect(ok, isTrue,
          reason: 'updateMessage by the dropped id must resolve via alias');

      // codex re-review: the merge can flip the primary id. Prove BOTH ids
      // still resolve AFTER that update — a second op keyed on EITHER id works.
      expect(persistence.getHistory(conversationId).length, 1);
      final byPoll = await persistence.removeMessage(
          conversationId, '5100400_0_$conversationId');
      expect(byPoll, isTrue,
          reason: 'the other id must still resolve after an alias-resolved op');
      expect(persistence.getHistory(conversationId), isEmpty);
    });

    test('absorbed alias survives flush + reload (durable, not in-memory only)',
        () async {
      // The whole point of storing aliases ON the row (altMsgIds) rather than
      // in an in-memory map: a dropped cross-path id must still resolve AFTER an
      // app restart. Write a deduped row, flush to disk, reload in a fresh
      // instance, and delete by the dropped native id.
      const conversationId = 'xpathreload';
      const nativeId = 'msg_0_5200000000000_2';
      final writer =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      await writer.appendHistory(
        conversationId,
        ChatMessage(
          text: 'durable',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(5200000),
          msgID: nativeId,
        ),
      );
      await writer.appendHistory(
        conversationId,
        ChatMessage(
          text: 'durable',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(5200400),
          msgID: '5200400_0_$conversationId',
        ),
      );
      await writer.flushPendingSaves();

      // Fresh instance == app restart: rebuilds state from disk only.
      final restarted =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      final reloaded = await restarted.loadHistory(conversationId);
      expect(reloaded.length, 1,
          reason: 'the deduped row persists as a single message');
      final removed =
          await restarted.removeMessage(conversationId, nativeId);
      expect(removed, isTrue,
          reason:
              'the dropped id must resolve after reload (alias is on the row)');
    });

    test('Bug F regression: identical self text within 2s is KEPT '
        '(not collapsed)', () async {
      // Bug F: the content-dedup fallback used to run for ALL messages, so a
      // single sender repeating the EXACT same text inside the 2s window lost
      // the second copy — including legitimate self-sends (double-tap send, or
      // "ok" then "ok"). The fix scopes content-dedup to INCOMING messages
      // only: self-sends never double-deliver (no Tox loopback) and now carry
      // unique sequenced msgIDs, so two identical self-sends with distinct ids
      // must both persist as distinct rows.
      const conversationId = 'xpathselfkeep';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'ok',
          fromUserId: conversationId,
          isSelf: true,
          timestamp: DateTime.fromMillisecondsSinceEpoch(30000),
          msgID: 'self_a',
        ),
      );
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'ok',
          fromUserId: conversationId,
          isSelf: true,
          timestamp: DateTime.fromMillisecondsSinceEpoch(30500), // 0.5s later
          msgID: 'self_b',
        ),
      );

      await persistence.flushPendingSaves();
      final reloaded = await persistence.loadHistory(conversationId);
      expect(reloaded.length, 2,
          reason:
              'Bug F fixed: two identical self-sends with distinct msgIDs are '
              'not content-deduped and must both persist');
    });

    test('inbound duplicate (different ids, same content <2s) still collapses '
        'to one', () async {
      // The complement of Bug F: the content-dedup fallback is deliberately
      // preserved for INCOMING messages. An inbound message genuinely
      // double-delivers across the two hybrid paths with DIFFERENT msgIDs and
      // must still be collapsed by content within the 2s window.
      const conversationId = 'xpathinbounddup';
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);

      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'ok',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(40000),
          msgID: 'in_a',
        ),
      );
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'ok',
          fromUserId: conversationId,
          isSelf: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(40500), // 0.5s later
          msgID: 'in_b',
        ),
      );

      await persistence.flushPendingSaves();
      final reloaded = await persistence.loadHistory(conversationId);
      expect(reloaded.length, 1,
          reason:
              'inbound cross-path duplicate (different ids, same content <2s) '
              'must still collapse to one row');
    });
  });

  // S18 reply: the cloudCustomData quote must survive the on-disk JSON
  // round-trip (the sender-side persistence fix). The L3 runner gate reads the
  // in-memory getHistory, so it can't catch a toJson regression — these tests
  // close that gap (reviewer MEDIUM).
  group('S18 cloudCustomData (reply quote) persistence', () {
    test('toJson gates the key for plain messages; round-trips when set', () {
      final plain = ChatMessage(
        text: 'hi',
        fromUserId: 'A',
        isSelf: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        msgID: 'm1',
      );
      expect(plain.toJson().containsKey('cloudCustomData'), isFalse,
          reason: 'plain messages must serialize byte-identically (gated key)');
      expect(ChatMessage.fromJson(plain.toJson()).cloudCustomData, isNull);

      const cloud =
          '{"messageReply":{"messageID":"m1","messageAbstract":"hi"}}';
      final reply = ChatMessage(
        text: 're',
        fromUserId: 'A',
        isSelf: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
        msgID: 'm2',
        cloudCustomData: cloud,
      );
      expect(reply.toJson()['cloudCustomData'], cloud);
      expect(ChatMessage.fromJson(reply.toJson()).cloudCustomData, cloud);
    });

    test('legacy on-disk JSON without the key loads as null (backward compat)',
        () {
      final legacy = <String, dynamic>{
        'text': 'old',
        'fromUserId': 'A',
        'isSelf': true,
        'timestamp': DateTime.fromMillisecondsSinceEpoch(1000).toIso8601String(),
        'msgID': 'm0',
        'version': 1,
      };
      expect(ChatMessage.fromJson(legacy).cloudCustomData, isNull);
    });

    test('a reply survives flush + reload (fresh instance) with the quote intact',
        () async {
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      const conversationId = 'c2c_PEER';
      const cloud =
          '{"messageReply":{"messageID":"base1","messageAbstract":"base"}}';
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'my reply',
          fromUserId: 'SELF',
          isSelf: true,
          timestamp: DateTime.fromMillisecondsSinceEpoch(3000),
          msgID: 'reply1',
          cloudCustomData: cloud,
        ),
      );
      await persistence.flushPendingSaves();
      // Fresh instance → true on-disk read, not the in-memory cache.
      final fresh =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      final reloaded = await fresh.loadHistory(conversationId);
      expect(reloaded.length, 1);
      expect(reloaded.first.cloudCustomData, cloud,
          reason:
              'cloudCustomData (reply quote) must survive the on-disk '
              'toJson/fromJson round-trip — the S18 sender-side persistence fix');
    });
  });

  group('S17/S18: cloudCustomData survives a cross-path merge', () {
    // toxee double-writes an outbound send through both hybrid paths; the two
    // copies meet in _mergeMessages and only ONE carries the sender-side
    // cloudCustomData (FfiChatService.sendText sets it; the binary-replacement
    // copy does not). The merge must keep the quote — dropping it here is what
    // broke L3-reply-text LIVE even though sendText set cloudCustomData (the
    // on-disk round-trip test above passed but never exercised the merge).
    test('merge keeps the quote when only the EXISTING copy has it', () async {
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      const conversationId = 'c2c_MERGE_A';
      const cloud =
          '{"messageReply":{"messageID":"base1","messageAbstract":"base"}}';
      // Copy A — the FfiChatService.sendText copy, carries the quote.
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'my reply',
          fromUserId: 'SELF',
          isSelf: true,
          timestamp: DateTime.fromMillisecondsSinceEpoch(3000),
          msgID: 'reply1',
          cloudCustomData: cloud,
        ),
      );
      // Copy B — same msgID (binary-replacement copy), no quote → merges.
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'my reply',
          fromUserId: 'SELF',
          isSelf: true,
          timestamp: DateTime.fromMillisecondsSinceEpoch(3100),
          msgID: 'reply1',
        ),
      );
      final hist = persistence.getHistory(conversationId);
      expect(hist.length, 1, reason: 'same msgID must merge to one row');
      expect(hist.single.cloudCustomData, cloud,
          reason: 'merge must preserve the sender-side reply quote');
    });

    test('merge keeps the quote when only the UPDATED copy has it', () async {
      final persistence =
          MessageHistoryPersistence(historyDirectory: tempDir.path);
      const conversationId = 'c2c_MERGE_B';
      const cloud = '{"messageReply":{"messageID":"base2"}}';
      // Copy A — no quote first.
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'my reply',
          fromUserId: 'SELF',
          isSelf: true,
          timestamp: DateTime.fromMillisecondsSinceEpoch(4000),
          msgID: 'reply2',
        ),
      );
      // Copy B — same msgID, carries the quote → merges, quote must win.
      await persistence.appendHistory(
        conversationId,
        ChatMessage(
          text: 'my reply',
          fromUserId: 'SELF',
          isSelf: true,
          timestamp: DateTime.fromMillisecondsSinceEpoch(4100),
          msgID: 'reply2',
          cloudCustomData: cloud,
        ),
      );
      final hist = persistence.getHistory(conversationId);
      expect(hist.length, 1, reason: 'same msgID must merge to one row');
      expect(hist.single.cloudCustomData, cloud,
          reason: 'merge must preserve the quote from the updated copy');
    });
  });
}
