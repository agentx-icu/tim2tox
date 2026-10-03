// Single-message send control: cancelling a queued text before any drain
// hands it to transport, and retrying a confirmed-failed one under its own
// msgID. Drains work from a queue snapshot and suspend between items, so
// these tests pin the arbitration: cancel wins while the item is only
// queued, the drain never sends a cancelled item (also across a restart),
// and a claimed item reports alreadyClaimed.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/models/send_control_result.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';

const _selfKey =
    'ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB';
const _selfToxId = '${_selfKey}0000000012EF';
const _peer =
    'CDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCD';
const _group = 'tox_7';

/// One offline friend; records every text that reaches the native send and
/// can be told to throw (a generic failure marks the queued row failed).
class _StubFfi extends Tim2ToxFfi {
  _StubFfi() : super.forTesting();

  final List<String> sent = [];
  final List<String> groupSent = [];
  bool throwOnSend = false;

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
  int Function(ffi.Pointer<ffi.Int8>, int) get getFriendList =>
      (buf, cap) => _write('$_peer\tpeer\t0\n', buf, cap);

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)
      get sendText => (_, text) {
            if (throwOnSend) throw StateError('native send exploded');
            sent.add(text.toDartString());
            return 1;
          };

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
  late MessageHistoryPersistence history;
  late OfflineMessageQueuePersistence queue;
  late FfiChatService service;

  Future<FfiChatService> open() async {
    history = MessageHistoryPersistence(historyDirectory: historyDir);
    queue = OfflineMessageQueuePersistence(queueFilePath: queueFile);
    await queue.loadQueue(clearOnLoad: false);
    final s = FfiChatService(
      ffiForTesting: ffiStub,
      messageHistoryPersistence: history,
      offlineMessageQueuePersistence: queue,
    );
    s.debugSetSelfId('FlutterUIKitClient');
    return s;
  }

  /// Makes the peer reachable for the drain without the native came-online
  /// side effects (which would start a drain of their own).
  Future<void> peerOnline() async {
    service.debugSetFriendOnline(_peer, true);
    await service.getFriendList();
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('send_control_');
    historyDir = p.join(tempDir.path, 'history');
    queueFile = p.join(tempDir.path, 'offline_queue.json');
    await Directory(historyDir).create(recursive: true);
    ffiStub = _StubFfi();
    service = await open();
  });

  tearDown(() async {
    await service.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ChatMessage rowOf(String msgID, {String peer = _peer}) =>
      service.getHistory(peer).singleWhere((m) => m.msgID == msgID);

  test('a queued text is cancelled: kept as a cancelled row, never sent',
      () async {
    final row = await service.sendTextWithResult(_peer, 'one');
    expect(row.isPending, isTrue);

    final result = await service.cancelQueuedMessage(_peer, row.msgID!);
    expect(result, SendControlResult.success);
    expect(rowOf(row.msgID!).isCancelled, isTrue);
    expect(rowOf(row.msgID!).isPending, isFalse);
    expect(queue.getMessages(_peer), isEmpty);

    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, isEmpty);
    expect(await service.cancelQueuedMessage(_peer, row.msgID!),
        SendControlResult.notApplicable,
        reason: 'a second cancel finds nothing queued');
  });

  test('cancel wins over a drain that already took its snapshot', () async {
    final first = await service.sendTextWithResult(_peer, 'first');
    final second = await service.sendTextWithResult(_peer, 'second');
    await peerOnline();

    // The drain sends `first` synchronously, then suspends.
    final drain = service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, ['first']);
    expect(await service.cancelQueuedMessage(_peer, first.msgID!),
        SendControlResult.alreadyClaimed,
        reason: 'handed to transport: no cancelling it');
    expect(await service.cancelQueuedMessage(_peer, second.msgID!),
        SendControlResult.success);
    await drain;

    expect(ffiStub.sent, ['first'], reason: 'the snapshot item was skipped');
    expect(rowOf(first.msgID!).isCancelled, isFalse);
    expect(rowOf(second.msgID!).isCancelled, isTrue);
    expect(queue.getMessages(_peer), isEmpty);
  });

  test('a cancelled row is never re-queued after a restart', () async {
    final row = await service.sendTextWithResult(_peer, 'gone');
    await service.cancelQueuedMessage(_peer, row.msgID!);
    await history.flushPendingSaves();
    await service.dispose();

    service = await open();
    await service.loadHistory(_peer);
    expect(rowOf(row.msgID!).isCancelled, isTrue);
    expect(queue.getMessages(_peer), isEmpty);
    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, isEmpty);
  });

  test('a durable cancelled row drops a queue item that outlived it',
      () async {
    // A crash between the history write and the queue removal.
    final row = await service.sendTextWithResult(_peer, 'stale');
    final item = queue.getMessages(_peer).single;
    await service.cancelQueuedMessage(_peer, row.msgID!);
    await queue.addMessage(_peer, item);
    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, isEmpty);
    expect(queue.getMessages(_peer), isEmpty);
  });

  test('retry re-queues a failed row under its own msgID, once', () async {
    final row = await service.sendTextWithResult(_peer, 'again');
    await peerOnline();
    ffiStub.throwOnSend = true;
    await service.retryPendingC2cMessages(_peer);
    expect(rowOf(row.msgID!).isFailed, isTrue);
    expect(queue.getMessages(_peer), isEmpty);

    ffiStub.throwOnSend = false;
    final results = await Future.wait([
      service.retryFailedMessage(_peer, row.msgID!),
      service.retryFailedMessage(_peer, row.msgID!),
    ]);
    expect(results, [SendControlResult.success, SendControlResult.notApplicable]);
    // The retry drains on its own while the peer is online.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(ffiStub.sent, ['again']);
    final rows = service.getHistory(_peer).where((m) => m.text == 'again');
    expect(rows, hasLength(1), reason: 'no second bubble');
    expect(rows.single.isFailed, isFalse);
    expect(rows.single.isPending, isFalse);
    expect(await service.retryFailedMessage(_peer, row.msgID!),
        SendControlResult.notApplicable);
  });

  test('only failed own text rows can be retried', () async {
    final row = await service.sendTextWithResult(_peer, 'queued');
    expect(await service.retryFailedMessage(_peer, row.msgID!),
        SendControlResult.notApplicable);
    expect(await service.retryFailedMessage(_peer, 'nope'),
        SendControlResult.notApplicable);
  });

  test('self rows have no send control', () async {
    final row = await service.sendTextWithResult(_selfKey, 'note');
    expect(await service.cancelQueuedMessage(_selfKey, row.msgID!),
        SendControlResult.notApplicable);
    expect(await service.retryFailedMessage(_selfKey, row.msgID!),
        SendControlResult.notApplicable);
  });

  test('a queued group text is cancelled and the group drain skips it',
      () async {
    service.debugAddKnownGroupForTest(_group);
    final keep = await service.sendGroupTextWithResult(_group, 'keep');
    final drop = await service.sendGroupTextWithResult(_group, 'drop');
    expect(keep.isPending, isTrue);
    expect(await service.cancelQueuedMessage(_group, drop.msgID!,
            isGroup: true),
        SendControlResult.success);

    service.debugSetConnected(true);
    service.debugGroupWireReadyOverride = (_) => true;
    await service.retryPendingGroupMessages(_group);
    expect(ffiStub.groupSent, ['keep']);
    final rows = service.getHistory(_group);
    expect(rows.singleWhere((m) => m.msgID == drop.msgID).isCancelled, isTrue);
    expect(rows.singleWhere((m) => m.msgID == keep.msgID).isPending, isFalse);
  });

  test('isCancelled round-trips and stays off older rows', () {
    final row = ChatMessage(
      text: 'x',
      fromUserId: 'me',
      isSelf: true,
      timestamp: DateTime.utc(2026, 10, 3),
      msgID: 'm',
      isCancelled: true,
    );
    expect(ChatMessage.fromJson(row.toJson()).isCancelled, isTrue);
    expect(row.copyWith(isCancelled: false).toJson().containsKey('isCancelled'),
        isFalse);
  });
}
