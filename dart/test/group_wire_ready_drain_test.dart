// Group texts composed while the group cannot reach anyone (a rejoin or a
// restored group still syncing, or synced with no confirmed peer yet) are
// queued, and native posts groupJoinNotification twice on the way to
// deliverable: at toxcore's self-join, and again when the first peer is
// confirmed (tim2tox#28). The queue must survive the first, drain on the
// second, and send each item exactly once however the notifications overlap.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';

const _selfToxId =
    'ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB0000000012EF';
const _group = 'tox_7';

class _StubFfi extends Tim2ToxFfi {
  _StubFfi() : super.forTesting();

  final List<String> groupSent = [];

  /// What native tim2tox_ffi_group_wire_ready answers.
  int wireReady = 0;

  static int _write(String s, ffi.Pointer<ffi.Int8> buf, int cap) {
    final bytes = utf8.encode(s);
    if (bytes.length + 1 > cap) return -(bytes.length + 1);
    final out = buf.cast<ffi.Uint8>().asTypedList(bytes.length + 1);
    out.setAll(0, bytes);
    out[bytes.length] = 0;
    return bytes.length;
  }

  @override
  int Function() get getCurrentInstanceId => () => 0;

  @override
  void Function() get uninit => () {};

  @override
  int Function(ffi.Pointer<ffi.Int8>, int) get getSelfToxId =>
      (buf, cap) => _write(_selfToxId, buf, cap);

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>) get groupWireReady => (_) => wireReady;

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)
      get sendGroupText => (_, text) {
            groupSent.add(text.toDartString());
            return 1;
          };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String historyDir;
  late String queueFile;
  late _StubFfi ffiStub;
  late FfiChatService service;

  Future<FfiChatService> open() async {
    final queue = OfflineMessageQueuePersistence(queueFilePath: queueFile);
    await queue.loadQueue(clearOnLoad: false);
    final s = FfiChatService(
      ffiForTesting: ffiStub,
      messageHistoryPersistence:
          MessageHistoryPersistence(historyDirectory: historyDir),
      offlineMessageQueuePersistence: queue,
    );
    s.debugSetSelfId('FlutterUIKitClient');
    s.debugAddKnownGroupForTest(_group);
    s.debugSetConnected(true);
    return s;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('group_wire_ready_');
    historyDir = p.join(tempDir.path, 'history');
    queueFile = p.join(tempDir.path, 'offline_queue.json');
    await Directory(historyDir).create(recursive: true);
    ffiStub = _StubFfi();
    service = await open();
  });

  /// The notification starts its drain unawaited and the drain persists
  /// between items, so let every drain run out before counting sends.
  Future<void> drainsSettled() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  tearDown(() async {
    await service.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a text sent while the group is not wire-ready is queued, not sent',
      () async {
    final row = await service.sendGroupTextWithResult(_group, 'early');
    expect(row.isPending, isTrue);
    expect(ffiStub.groupSent, isEmpty);
  });

  test(
      'self-join without a confirmed peer keeps the queue; the first '
      'confirmed peer drains it exactly once', () async {
    final a = await service.sendGroupTextWithResult(_group, 'a');
    final b = await service.sendGroupTextWithResult(_group, 'b');

    // toxcore self-join: synced, but nobody confirmed yet.
    await service.registerJoinedGroupState(_group);
    await drainsSettled();
    expect(ffiStub.groupSent, isEmpty);

    // First confirmed peer; the notifications can overlap with another
    // drain trigger.
    ffiStub.wireReady = 1;
    await Future.wait([
      service.registerJoinedGroupState(_group),
      service.registerJoinedGroupState(_group),
      service.retryPendingGroupMessages(_group),
    ]);
    await drainsSettled();
    expect(ffiStub.groupSent, ['a', 'b']);

    // A later peer, or a reconnect, finds nothing left to send.
    await service.registerJoinedGroupState(_group);
    await drainsSettled();
    expect(ffiStub.groupSent, ['a', 'b']);
    final rows = service.getHistory(_group);
    expect(rows.singleWhere((m) => m.msgID == a.msgID).isPending, isFalse);
    expect(rows.singleWhere((m) => m.msgID == b.msgID).isPending, isFalse);
  });

  test(
      'a queue that outlives a restart drains once on the first confirmed '
      'peer of the restored group', () async {
    await service.sendGroupTextWithResult(_group, 'before restart');
    await service.dispose();

    service = await open();
    // Restored groups load as CS_CONNECTING: the provisional self-join from
    // the restore loop must not send.
    await service.registerJoinedGroupState(_group);
    await drainsSettled();
    expect(ffiStub.groupSent, isEmpty);

    ffiStub.wireReady = 1;
    await service.registerJoinedGroupState(_group);
    await service.registerJoinedGroupState(_group);
    await drainsSettled();
    expect(ffiStub.groupSent, ['before restart']);
  });
}
