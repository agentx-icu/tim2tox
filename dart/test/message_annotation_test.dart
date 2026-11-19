import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

const _alice =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _bob = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

class _StubFfi extends Tim2ToxFfi {
  _StubFfi() : super.forTesting();

  final annotations = <({String text, String data, int group})>[];
  final plainGroupTexts = <String>[];
  bool hasAnnotatedExport = true;

  @override
  int Function() get getCurrentInstanceId => () => 0;

  @override
  void Function() get uninit => () {};

  @override
  int Function(Pointer<Int8>, int) get getSelfToxId => (buf, cap) => 0;

  @override
  int Function(Pointer<Int8>, int) get getFriendList => (buf, cap) {
        final row = '$_alice\tAlice\t0\n'.codeUnits;
        buf.asTypedList(row.length + 1).setAll(0, [...row, 0]);
        return row.length;
      };

  @override
  SendAnnotatedText? get sendAnnotatedText {
    if (!hasAnnotatedExport) return null;
    return (target, text, data, group, action, out, cap) {
      annotations.add(
          (text: text.toDartString(), data: data.toDartString(), group: group));
      out.value = 0;
      return 2;
    };
  }

  @override
  int Function(Pointer<Utf8>, Pointer<Utf8>) get sendGroupText =>
      (group, text) {
        plainGroupTexts.add(text.toDartString());
        return 1;
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late MessageHistoryPersistence history;
  late FfiChatService service;
  late _StubFfi ffi;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('annotation_test_');
    history = MessageHistoryPersistence(historyDirectory: temp.path);
    ffi = _StubFfi();
    service = FfiChatService(
      ffiForTesting: ffi,
      messageHistoryPersistence: history,
      queueFilePath: '${temp.path}/queue.json',
    );
  });

  tearDown(() async {
    await service.dispose();
    await temp.delete(recursive: true);
  });

  test('consecutive identical C2C texts are correlated by their native ID',
      () async {
    service.ingestC2cTextEvent('c2c:$_alice|msg_1_1_1:same');
    service.ingestC2cTextEvent('c2c:$_alice|msg_1_1_2:same');
    final updated = service.messageUpdates.first;
    expect(
        service.ingestMessageAnnotationEvent(
            'annotation:|$_alice|msg_1_1_2:{"quote":2}'),
        true);
    expect((await updated).msgID, 'msg_1_1_2');
    final rows = history.getHistory(_alice);
    expect(rows.map((row) => row.cloudCustomData), [null, '{"quote":2}']);
  });

  test('reordered NGC annotation only updates the authenticated author row',
      () async {
    const groupId = 'tox_group_7';
    expect(
        service.ingestMessageAnnotationEvent(
            'annotation:$groupId|$_alice|42:{"quote":2}'),
        true);
    service.ingestInboundGroupText(
        gid: groupId, from: _bob, text: 'same', pseudoMsgId: 42);
    final updated = service.messageUpdates.first;
    service.ingestInboundGroupText(
        gid: groupId, from: _alice, text: 'same', pseudoMsgId: 42);
    expect((await updated).fromUserId, _alice);
    final rows = history.getHistory(groupId);
    expect(rows.map((row) => row.cloudCustomData), [null, '{"quote":2}']);
    expect(
        service.ingestMessageAnnotationEvent(
            'annotation:$groupId|$_alice|42:"invalid"'),
        false);
  });

  test('offline group text retains its annotation through the queue drain',
      () async {
    const groupId = 'tox_group_7';
    service.debugSetSelfId(_bob);
    service.debugAddKnownGroupForTest(groupId);
    final row = await service.sendGroupTextWithResult(groupId, 'reply',
        cloudCustomData: '{"quote":1}');
    expect(row.isPending, true);
    expect(row.annotationDelivered, false);
    expect(ffi.annotations, isEmpty);
    service.debugSetConnected(true);
    await service.retryPendingGroupMessages(groupId);
    expect(ffi.annotations, [(text: 'reply', data: '{"quote":1}', group: 1)]);
    expect(history.getHistory(groupId).single.cloudCustomData, '{"quote":1}');
    expect(history.getHistory(groupId).single.annotationDelivered, true);
  });

  test('offline C2C text sends the queued annotation on reconnect', () async {
    service.debugSetSelfId(_bob);
    final pending = await service.sendTextWithResult(_alice, 'reply',
        cloudCustomData: '{"quote":1}');
    expect(pending.isPending, true);
    expect(ffi.annotations, isEmpty);
    final updated = service.messages
        .firstWhere((row) => row.msgID == pending.msgID && !row.isPending);
    service.debugSetFriendOnline(_alice, true);
    await service.getFriendList();
    await service.retryPendingC2cMessages(_alice);
    expect((await updated).annotationDelivered, true);
    expect(ffi.annotations, [(text: 'reply', data: '{"quote":1}', group: 0)]);
  });

  test('a native library without the annotated export still sends plain text',
      () async {
    const groupId = 'tox_group_7';
    ffi.hasAnnotatedExport = false;
    service.debugSetSelfId(_bob);
    service.debugSetConnected(true);
    final row = await service.sendGroupTextWithResult(groupId, 'reply',
        cloudCustomData: '{"quote":1}');
    expect(ffi.plainGroupTexts, ['reply']);
    expect(ffi.annotations, isEmpty);
    expect(row.annotationDelivered, false);
    expect(row.cloudCustomData, '{"quote":1}');
  });

  test('an oversized UTF-8 annotation fails before an offline text is queued',
      () async {
    const groupId = 'tox_group_7';
    final large = '{"quote":"${'中' * 400}"}';
    await expectLater(
      service.sendGroupTextWithResult(groupId, 'reply', cloudCustomData: large),
      throwsArgumentError,
    );
    expect(history.getHistory(groupId), isEmpty);
    expect(ffi.annotations, isEmpty);
  });
}
