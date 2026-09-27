// The group read tick across a restart.
//
// A C2C read tick survives a restart because the receipt flips `isRead` on the
// row and the row is persisted. The GROUP tick used to disappear: the platform
// derived `V2TimMessageReceipt.readCount` purely from
// FfiChatService.getMessageReaders, a live tally keyed by reader identity that
// starts empty on every launch. So a user who saw "read" on their own group
// message, restarted, and reopened the conversation saw it unread again.
//
// The FACT that somebody read it is persisted on the author's own row exactly
// like C2C (`isRead` / `isReceived`, flipped and saved by
// FfiChatService._handleReceipt). These tests pin the two halves that make the
// tick come back: the flag survives a store restart, and the platform reports a
// restored row as read — as "at least one member", which is all the group tick
// renders — without inventing a reader count and without ever persisting who
// the readers were (per-group member keys rotate; a stored reader set would
// de-anonymize readers across restarts).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

// `tox_` prefixed: that is how the whole stack tells a group conversation from
// a C2C one (findMessages / chatMessageToV2TimMessage both key off it).
const _groupId = 'tox_group_9';
const _authorKey =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _readRowId = 'local-read-row';
const _unreadRowId = 'local-unread-row';

/// A binding fake: nothing in these tests reaches the native library, but the
/// service constructor asks for the instance id and dispose calls uninit.
class _StubFfi extends Tim2ToxFfi {
  _StubFfi() : super.forTesting();

  @override
  int Function() get getCurrentInstanceId => () => 0;

  @override
  void Function() get uninit => () {};
}

ChatMessage _authorRow(String msgID, {required bool read}) => ChatMessage(
      text: 'authored $msgID',
      fromUserId: _authorKey,
      isSelf: true,
      timestamp: DateTime.now(),
      groupId: _groupId,
      msgID: msgID,
      altMsgIds: [
        FfiChatService.groupMessageAlias(
          groupId: _groupId,
          senderPk: _authorKey,
          pseudoMsgId: msgID == _readRowId ? 11 : 12,
        ),
      ],
      needReadReceipt: true,
      isReceived: read,
      isRead: read,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String historyDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('group_read_tick_');
    historyDir = p.join(tempDir.path, 'history');
    await Directory(historyDir).create(recursive: true);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Writes the author's rows through one store session, then closes it — so
  /// everything the next session sees really came off disk.
  Future<void> writeAndCloseFirstSession() async {
    final first = MessageHistoryPersistence(historyDirectory: historyDir);
    await first.appendHistory(_groupId, _authorRow(_readRowId, read: true));
    await first.appendHistory(_groupId, _authorRow(_unreadRowId, read: false));
    await first.flushPendingSaves();
    await first.dispose();
  }

  test('the read fact on an author group row survives a store restart',
      () async {
    await writeAndCloseFirstSession();

    final reopened = MessageHistoryPersistence(historyDirectory: historyDir);
    final rows = await reopened.loadHistory(_groupId);
    final restored = rows.firstWhere((m) => m.msgID == _readRowId);
    expect(restored.isSelf, isTrue);
    expect(restored.isRead, isTrue,
        reason: 'the read FACT is what makes the tick come back; the reader '
            'identities are deliberately not stored');
    expect(restored.isReceived, isTrue);
    expect(rows.firstWhere((m) => m.msgID == _unreadRowId).isRead, isFalse,
        reason: 'an unread row must not be dragged along');

    // The persisted row carries no reader identity anywhere in the file.
    final onDisk =
        await File(p.join(historyDir, '$_groupId.json')).readAsString();
    expect(onDisk, contains('"isRead":true'));
    expect(onDisk, isNot(contains('reader')));
    await reopened.dispose();
  });

  test('a restored row reports read without a live tally', () async {
    await writeAndCloseFirstSession();

    final store = MessageHistoryPersistence(historyDirectory: historyDir);
    final service = FfiChatService(
      ffiForTesting: _StubFfi(),
      messageHistoryPersistence: store,
      queueFilePath: p.join(tempDir.path, 'offline_queue.json'),
    );
    try {
      // What a cold start does: the rows come back from disk, the tallies do
      // not exist at all.
      await service.loadHistory(_groupId);
      expect(service.getHistory(_groupId), hasLength(2));
      expect(service.getMessageReaders(_readRowId), isEmpty,
          reason: 'the live tally is rebuilt from traffic only');

      expect(service.isGroupRowReadByAnyMember(_readRowId, groupID: _groupId),
          isTrue);
      expect(service.isGroupRowReadByAnyMember(_unreadRowId, groupID: _groupId),
          isFalse);
      // Alias-aware: the receipt wire id resolves to the same row.
      final alias = service
          .getHistory(_groupId)
          .firstWhere((m) => m.msgID == _readRowId)
          .altMsgIds
          .single;
      expect(service.isGroupRowReadByAnyMember(alias, groupID: _groupId), isTrue,
          reason: 'the cross-peer `gmid:` alias is the id a receipt carries');
      expect(service.isGroupRowReadByAnyMember(_readRowId), isTrue,
          reason: 'resolvable without being told the group');
      expect(service.isGroupRowReadByAnyMember('no-such-id', groupID: _groupId),
          isFalse);

      // What the platform reports: the restored row claims the floor of 1 and
      // declares the count INEXACT, so no unread number can be derived from it.
      final restoredTally =
          service.groupRowReadTally(_readRowId, groupID: _groupId);
      expect(restoredTally.readCount, 1,
          reason: '"at least one member read it" is the honest lower bound — '
              'not a fabricated reader count');
      expect(restoredTally.exactCount, isFalse,
          reason: 'the readers behind the persisted fact were never stored');
      final unreadTally =
          service.groupRowReadTally(_unreadRowId, groupID: _groupId);
      expect(unreadTally.readCount, 0);
      expect(unreadTally.exactCount, isTrue,
          reason: 'nobody read it: zero IS exact');

      // The PLATFORM read-back (getMessageReadReceipts reporting readCount 1
      // for a restored row) is asserted in
      // auto_tests/test/scenarios/scenario_group_receipt_control_row_test.dart
      // instead: `lib/sdk/tim2tox_sdk_platform.dart` only compiles against the
      // PATCHED tencent_cloud_chat_sdk the integrator vendors, so importing it
      // from this standalone package fails to build (same reason
      // tim2tox_sdk_platform_group_taxonomy_test.dart asserts on source text).
    } finally {
      await service.dispose();
    }
  });
}
