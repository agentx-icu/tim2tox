import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

const _peer = 'private-test-peer';

ChatMessage _file(String id) => ChatMessage(
      text: '',
      fromUserId: 'test-sender',
      isSelf: true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1),
      msgID: id,
      fileName: 'route.txt',
      fileSize: 38,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late MessageHistoryPersistence writer;
  late MessageHistoryPersistence reader;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tim2tox-outgoing-file-test-');
    writer = MessageHistoryPersistence(historyDirectory: temp.path);
    reader = MessageHistoryPersistence(historyDirectory: temp.path);
  });

  tearDown(() async {
    await reader.dispose();
    await writer.dispose();
    await temp.delete(recursive: true);
  });

  test('completed transfer survives a duplicate append and cold load',
      () async {
    final offered = _file('transfer-1');
    final completed = offered.copyWith(isOutgoingFileComplete: true);
    await writer.appendHistory(_peer, completed);
    await writer.appendHistory(_peer, offered);
    final reopened = await reader.loadHistory(_peer);
    expect(reopened.single.msgID, offered.msgID);
    expect(reopened.single.isOutgoingFileComplete, isTrue);
  });

  test('cold load preserves a completed duplicate in the on-disk history',
      () async {
    final offered = _file('transfer-1');
    final completed = offered.copyWith(isOutgoingFileComplete: true);
    await writer.saveHistory(_peer, [offered, completed]);
    expect((await reader.loadHistory(_peer)).single.isOutgoingFileComplete,
        isTrue);
  });

  test('with the same filename, only the exact transfer is marked complete',
      () async {
    ChatMessage completed(String id) =>
        _file(id).copyWith(isOutgoingFileComplete: true);
    await writer.saveHistory(_peer, [
      completed('success'),
      _file('unknown'),
      completed('failed'),
      _file('failed').copyWith(isFailed: true),
      completed('cancelled'),
      _file('cancelled').copyWith(isCancelled: true),
    ]);
    final rows = {
      for (final row in await reader.loadHistory(_peer)) row.msgID: row,
    };
    expect(rows.keys,
        unorderedEquals(['success', 'unknown', 'failed', 'cancelled']));
    expect(rows['success']!.isOutgoingFileComplete, isTrue);
    expect(rows['unknown']!.isOutgoingFileComplete, isFalse);
    expect(rows['failed']!.isFailed, isTrue);
    expect(rows['failed']!.isOutgoingFileComplete, isFalse);
    expect(rows['cancelled']!.isCancelled, isTrue);
    expect(rows['cancelled']!.isOutgoingFileComplete, isFalse);
  });
}
