// Single-message send control: cancelling a queued text before any drain
// hands it to transport, and retrying a confirmed-failed one under its own
// msgID. Drains work from a queue snapshot and suspend between items, so
// these tests pin the arbitration: cancel wins while the item is only
// queued, the drain never sends a cancelled item (also across a restart),
// and a claimed item reports alreadyClaimed.
//
// Durability: every send-control decision is committed on the queue item
// first (a cancelled / failed tombstone, a retry marker) and the history row
// follows. The crash tests reopen a second service on the same files while
// the first one's history store keeps failing, so nothing it holds in memory
// can reach disk afterwards.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:crypto/crypto.dart';
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

/// A queue whose single-item writes can be made to fail.
class _FlakyQueue extends OfflineMessageQueuePersistence {
  _FlakyQueue({required super.queueFilePath});

  bool failRemove = false;
  bool failReplace = false;
  bool failAdd = false;

  @override
  Future<void> removeItem(String peerId, OfflineMessageItem item) {
    if (failRemove) return Future.error(const FileSystemException('disk'));
    return super.removeItem(peerId, item);
  }

  @override
  Future<bool> replaceItem(
      String peerId, OfflineMessageItem old, OfflineMessageItem updated) {
    if (failReplace) return Future.error(const FileSystemException('disk'));
    return super.replaceItem(peerId, old, updated);
  }

  @override
  Future<void> addMessage(String peerId, OfflineMessageItem item) {
    if (failAdd) return Future.error(const FileSystemException('disk'));
    return super.addMessage(peerId, item);
  }
}

/// A history store whose writes can be made to fail (every write goes
/// through [saveHistory], debounced and retried ones included).
class _FlakyHistory extends MessageHistoryPersistence {
  _FlakyHistory({required super.historyDirectory});

  bool failSave = false;

  @override
  Future<void> saveHistory(String conversationId, List<ChatMessage> messages) {
    if (failSave) return Future.error(const FileSystemException('disk'));
    return super.saveHistory(conversationId, messages);
  }
}

String _bind(String text) =>
    'bind:${sha256.convert(utf8.encode(text)).toString()}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String historyDir;
  late String queueFile;
  late _StubFfi ffiStub;
  late _FlakyHistory history;
  late _FlakyQueue queue;
  late FfiChatService service;
  final crashed = <FfiChatService>[];

  Future<FfiChatService> open() async {
    history = _FlakyHistory(historyDirectory: historyDir);
    queue = _FlakyQueue(queueFilePath: queueFile);
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
    for (final s in crashed) {
      try {
        await s.dispose();
      } catch (_) {}
    }
    crashed.clear();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ChatMessage rowOf(String msgID, {String peer = _peer}) =>
      service.getHistory(peer).singleWhere((m) => m.msgID == msgID);

  /// The process dies: the current service is abandoned with its history
  /// store failing every write from now on (so it cannot repair disk later),
  /// and a fresh one opens the same files. History is reloaded from disk.
  Future<void> crashAndReopen() async {
    history.failSave = true;
    crashed.add(service);
    service = await open();
    await service.loadHistory(_peer);
  }

  /// A queued text whose drain failed: its row says failed, nothing queued.
  Future<ChatMessage> failedRow(String text) async {
    final row = await service.sendTextWithResult(_peer, text);
    await peerOnline();
    ffiStub.throwOnSend = true;
    await service.retryPendingC2cMessages(_peer);
    ffiStub.throwOnSend = false;
    expect(rowOf(row.msgID!).isFailed, isTrue);
    expect(queue.getMessages(_peer), isEmpty);
    return rowOf(row.msgID!);
  }

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

  test('a cancel whose queue write fails changes nothing', () async {
    final row = await service.sendTextWithResult(_peer, 'still going');
    queue.failReplace = true;
    expect(await service.cancelQueuedMessage(_peer, row.msgID!),
        SendControlResult.persistFailed);
    expect(rowOf(row.msgID!).isCancelled, isFalse);
    expect(rowOf(row.msgID!).isPending, isTrue);
    expect(queue.getMessages(_peer).single.control, isNull);

    queue.failReplace = false;
    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, ['still going'], reason: 'not cancelled: it sends');
  });

  test('a cancel stands once its tombstone is written, though its clean-up '
      'fails', () async {
    final row = await service.sendTextWithResult(_peer, 'stopped');
    queue.failRemove = true;
    expect(await service.cancelQueuedMessage(_peer, row.msgID!),
        SendControlResult.success);
    expect(rowOf(row.msgID!).isCancelled, isTrue);
    expect(queue.getMessages(_peer).single.control,
        OfflineSendControl.cancelled);

    queue.failRemove = false;
    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, isEmpty);
    expect(queue.getMessages(_peer), isEmpty, reason: 'the drain cleans up');
  });

  test('a cancel whose row write never landed holds across a crash', () async {
    final row = await service.sendTextWithResult(_peer, 'never');
    await history.flushPendingSaves();
    history.failSave = true;
    expect(await service.cancelQueuedMessage(_peer, row.msgID!),
        SendControlResult.success);
    expect(queue.getMessages(_peer).single.control,
        OfflineSendControl.cancelled);

    await crashAndReopen();
    expect(rowOf(row.msgID!).isCancelled, isFalse,
        reason: 'disk still had the queued row');
    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, isEmpty);
    expect(rowOf(row.msgID!).isCancelled, isTrue,
        reason: 'the tombstone re-applies the cancel');
    expect(queue.getMessages(_peer), isEmpty);
  });

  test('a cancel while a cancel or retry holds the message is refused',
      () async {
    final row = await service.sendTextWithResult(_peer, 'twice');
    final results = await Future.wait([
      service.cancelQueuedMessage(_peer, row.msgID!),
      service.cancelQueuedMessage(_peer, row.msgID!),
    ]);
    expect(results,
        [SendControlResult.success, SendControlResult.notApplicable]);
  });

  test('a retry whose queue write fails changes nothing', () async {
    final row = await failedRow('nope');
    queue.failAdd = true;
    expect(await service.retryFailedMessage(_peer, row.msgID!),
        SendControlResult.persistFailed);
    expect(rowOf(row.msgID!).isFailed, isTrue);
    expect(rowOf(row.msgID!).isPending, isFalse);
    expect(queue.getMessages(_peer), isEmpty);
  });

  test('a retried send clears its failure durably before it goes out',
      () async {
    final row = await failedRow('again');
    await history.flushPendingSaves();
    history.failSave = true;
    expect(await service.retryFailedMessage(_peer, row.msgID!),
        SendControlResult.success);
    expect(queue.getMessages(_peer).single.control, OfflineSendControl.retry);
    // The kicked drain and an immediate second one both find the row write
    // failing: neither may send while disk still says failed.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, isEmpty);
    expect(queue.getMessages(_peer).single.control, OfflineSendControl.retry);

    history.failSave = false;
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, ['again']);
    expect(rowOf(row.msgID!).isFailed, isFalse);
    expect(rowOf(row.msgID!).isPending, isFalse);
    expect(queue.getMessages(_peer), isEmpty);
  });

  test('a second retry after a crash adds no second queue item', () async {
    final row = await failedRow('once more');
    await history.flushPendingSaves();
    history.failSave = true;
    expect(await service.retryFailedMessage(_peer, row.msgID!),
        SendControlResult.success);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await crashAndReopen();
    expect(rowOf(row.msgID!).isPending, isTrue,
        reason: 'disk says failed, but the retry is queued');
    expect(await service.retryFailedMessage(_peer, row.msgID!),
        SendControlResult.notApplicable);
    expect(queue.getMessages(_peer), hasLength(1));

    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, ['once more']);
    expect(rowOf(row.msgID!).isFailed, isFalse);
  });

  test('a queued retry loads its history and clears the failure before it '
      'sends after a crash', () async {
    final row = await failedRow('reloaded');
    await history.flushPendingSaves();
    history.failSave = true;
    expect(await service.retryFailedMessage(_peer, row.msgID!),
        SendControlResult.success);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ffiStub.sent, isEmpty);

    crashed.add(service);
    service = await open(); // the conversation is not loaded yet
    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, ['reloaded']);
    expect(rowOf(row.msgID!).isFailed, isFalse);
    await history.flushPendingSaves();

    await crashAndReopen();
    expect(rowOf(row.msgID!).isFailed, isFalse, reason: 'cleared on disk');
    expect(await service.retryFailedMessage(_peer, row.msgID!),
        SendControlResult.notApplicable);
  });

  test('a failed send whose row write fails keeps a failed tombstone that is '
      'never sent', () async {
    final row = await service.sendTextWithResult(_peer, 'broken');
    await history.flushPendingSaves();
    await peerOnline();
    ffiStub.throwOnSend = true;
    history.failSave = true;
    await service.retryPendingC2cMessages(_peer);
    expect(queue.getMessages(_peer).single.control, OfflineSendControl.failed);

    ffiStub.throwOnSend = false;
    await crashAndReopen();
    expect(rowOf(row.msgID!).isFailed, isFalse, reason: 'the write was lost');
    await peerOnline();
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, isEmpty, reason: 'a tombstone is never dispatched');
    expect(rowOf(row.msgID!).isFailed, isTrue);
    expect(queue.getMessages(_peer), isEmpty);
  });

  test('a failed send without a loaded row stays queued', () async {
    await service.sendTextWithResult(_peer, 'kept');
    await history.flushPendingSaves();
    history.failSave = true;
    crashed.add(service);
    service = await open(); // history not loaded
    await peerOnline();
    ffiStub.throwOnSend = true;
    await service.retryPendingC2cMessages(_peer);
    expect(queue.getMessages(_peer).single.control, isNull);
  });

  test('rows still queued show pending after a startup load', () async {
    final row = await service.sendTextWithResult(_peer, 'boot');
    await history.flushPendingSaves();
    history.failSave = true;
    crashed.add(service);
    service = await open();
    await service.installAccountStorage(
        historyDirectory: historyDir, queueFilePath: queueFile);
    expect(rowOf(row.msgID!).isPending, isTrue);
  });

  test('a committed failure stays failed when its published row is echoed '
      'back into history', () async {
    // The SDK listener converts every published row and the history hook
    // appends it again: a genuine failure must survive its own echo.
    final row = await service.sendTextWithResult(_peer, 'echo');
    await peerOnline();
    final echo = service.messages.listen((m) {
      if (m.isFailed) unawaited(history.appendHistory(_peer, m));
    });
    ffiStub.throwOnSend = true;
    await service.retryPendingC2cMessages(_peer);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await echo.cancel();
    expect(rowOf(row.msgID!).isFailed, isTrue);
  });

  test('a content receipt never lands on a row that did not go out',
      () async {
    final queued = await service.sendTextWithResult(_peer, 'hi');
    await service.debugHandleReceiptForTest(_bind('hi'), 'received', _peer);
    expect(rowOf(queued.msgID!).isReceived, isFalse, reason: 'still queued');

    await service.cancelQueuedMessage(_peer, queued.msgID!);
    await peerOnline();
    final sent = await service.sendTextWithResult(_peer, 'hi');
    expect(ffiStub.sent, ['hi']);
    await service.debugHandleReceiptForTest(_bind('hi'), 'received', _peer);
    expect(rowOf(queued.msgID!).isReceived, isFalse, reason: 'cancelled');
    expect(rowOf(sent.msgID!).isReceived, isTrue);
  });

  test('a content receipt for a queued row waits for its send across a '
      'restart', () async {
    final row = await service.sendTextWithResult(_peer, 'later');
    await history.flushPendingSaves();
    await crashAndReopen();
    expect(rowOf(row.msgID!).isPending, isTrue,
        reason: 'still queued: pending again, not sent');
    await service.debugHandleReceiptForTest(_bind('later'), 'received', _peer);
    expect(rowOf(row.msgID!).isReceived, isFalse);
  });

  test('an exact receipt proves delivery and clears a failure', () async {
    final row = await failedRow('arrived');
    await service.debugHandleReceiptForTest(row.msgID!, 'received', _peer);
    expect(rowOf(row.msgID!).isReceived, isTrue);
    expect(rowOf(row.msgID!).isFailed, isFalse);
  });

  test('a sent item whose queue cleanup failed is neither cancelled nor '
      'sent twice', () async {
    final row = await service.sendTextWithResult(_peer, 'once');
    await peerOnline();
    queue.failRemove = true;
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, ['once']);
    expect(queue.getMessages(_peer), hasLength(1), reason: 'cleanup failed');
    await service.loadHistory(_peer);
    expect(rowOf(row.msgID!).isPending, isFalse,
        reason: 'it went out: a lingering queue item does not make it pending');

    expect(await service.cancelQueuedMessage(_peer, row.msgID!),
        SendControlResult.alreadyClaimed);
    queue.failRemove = false;
    await service.retryPendingC2cMessages(_peer);
    expect(ffiStub.sent, ['once'], reason: 'no duplicate send');
    expect(queue.getMessages(_peer), isEmpty, reason: 'the leftover is dropped');
    expect(rowOf(row.msgID!).isCancelled, isFalse);
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
