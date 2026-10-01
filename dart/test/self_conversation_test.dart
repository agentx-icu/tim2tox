// The SELF conversation ("note to self"): a C2C conversation keyed by our own
// public key whose rows are local only.
//
// toxcore cannot befriend its own key, so before FfiChatService knew about
// self a send to it looked like a send to an OFFLINE friend: it was parked in
// the offline queue forever and every other C2C path (typing, receipts,
// control, file control, queued group invites) would hand the own key to
// native code. These tests pin the contract: every outbound path addressed to
// self is a no-op on the wire (the stub COUNTS every native send binding),
// the rows persist like any delivered send, and every alias of the key (case,
// 76-hex address, `c2c_` prefix) reaches the same history.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/interfaces/extended_preferences_service.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';

const _selfKey =
    'ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB';
const _selfToxId = '${_selfKey}0000000012EF';

/// Answers the identity and the friend list (empty: self is never a friend);
/// counts every native SEND binding a self-addressed path could reach.
class _CountingFfi extends Tim2ToxFfi {
  _CountingFfi() : super.forTesting();

  final Map<String, int> calls = {};

  int _count(String name) {
    calls[name] = (calls[name] ?? 0) + 1;
    return 1;
  }

  int get totalSends => calls.values.fold(0, (a, b) => a + b);

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
      (buf, cap) => _write('', buf, cap);

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)
      get sendText => (_, __) => _count('sendText');

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>,
      ffi.Pointer<ffi.Int8>, int) get sendTextEx =>
      (_, __, ___, ____) => _count('sendTextEx');

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>,
      ffi.Pointer<ffi.Int8>, int) get sendC2CActionEx =>
      (_, __, ___, ____) => _count('sendC2CActionEx');

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<ffi.Uint8>, int, int)
      get sendC2CControlNative =>
          (_, __, ___, ____) => _count('sendC2CControlNative');

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>, int) get setTyping =>
      (_, __) => _count('setTyping');

  @override
  int Function(int, ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)
      get sendFileNative => (_, __, ___) => _count('sendFileNative');

  @override
  int Function(int, ffi.Pointer<pkgffi.Utf8>, int, int)
      get fileControlNative => (_, __, ___, ____) => _count('fileControl');
}

/// A session whose identity cannot be read (no native binding behind it).
class _ThrowingIdentityFfi extends _CountingFfi {
  @override
  int Function(ffi.Pointer<ffi.Int8>, int) get getSelfToxId =>
      (_, __) => throw StateError('no native session');
}

/// Just enough preferences for the queued-group-invite store.
class _MemoryPrefs implements ExtendedPreferencesService {
  final Map<String, Set<String>> sets = {};

  @override
  Future<Set<String>> getStringSet(String key) async => {...?sets[key]};

  @override
  Future<void> setStringSet(String key, Set<String> value) async =>
      sets[key] = {...value};

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<dynamic>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String historyDir;
  late _CountingFfi ffiStub;
  late MessageHistoryPersistence history;
  late OfflineMessageQueuePersistence queue;
  late FfiChatService service;

  FfiChatService open({ExtendedPreferencesService? prefs}) => FfiChatService(
        ffiForTesting: ffiStub,
        preferencesService: prefs,
        messageHistoryPersistence: history,
        offlineMessageQueuePersistence: queue,
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('self_conversation_');
    historyDir = p.join(tempDir.path, 'history');
    await Directory(historyDir).create(recursive: true);
    ffiStub = _CountingFfi();
    history = MessageHistoryPersistence(historyDirectory: historyDir);
    queue = OfflineMessageQueuePersistence(
        queueFilePath: p.join(tempDir.path, 'offline_queue.json'));
    service = open();
    service.debugSetSelfId('FlutterUIKitClient'); // the login alias
  });

  tearDown(() async {
    await service.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('self is recognised by key, never by the login alias', () {
    expect(service.selfPublicKey, _selfKey);
    expect(service.isSelfPeer(_selfKey), isTrue);
    expect(service.isSelfPeer(_selfKey.toLowerCase()), isTrue);
    expect(service.isSelfPeer(_selfToxId), isTrue);
    expect(service.isSelfPeer('c2c_$_selfKey'), isTrue);
    expect(service.isSelfPeer('FlutterUIKitClient'), isFalse);
    expect(service.isSelfPeer('CD' * 32), isFalse);
    expect(service.isSelfPeer(''), isFalse);
  });

  test('a text to self is a delivered local row and never reaches native',
      () async {
    final emitted = <ChatMessage>[];
    final sub = service.messages.listen(emitted.add);
    final row = await service.sendTextWithResult(_selfKey, 'note one');
    await service.sendTextWithResult(_selfKey, 'me practising',
        clientMessageID: 'client-42');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(row.isSelf, isTrue);
    expect(row.isPending, isFalse, reason: 'self rows are never queued');
    expect(row.text, 'note one');
    expect(service.getHistory(_selfKey).map((m) => m.text),
        ['note one', 'me practising']);
    expect(service.getHistory(_selfKey).last.msgID, 'client-42');
    expect(emitted.map((m) => m.text), ['note one', 'me practising']);
    expect(service.c2cPeerOfSelfRow(row.msgID!), _selfKey,
        reason: 'integrators route their own rows by this lookup');
    expect(queue.getMessages(_selfKey), isEmpty);
    expect(ffiStub.calls, isEmpty);
  });

  test('armed reply metadata lands on the self row and is consumed', () async {
    service.armNextSendCloudCustomData('{"messageReply":{"messageID":"m1"}}');
    service.armNextSendNeedReadReceipt(true);
    final quoted = await service.sendTextWithResult(_selfKey, 'quote');
    expect(quoted.cloudCustomData, contains('messageReply'));
    expect(quoted.needReadReceipt, isFalse,
        reason: 'nobody can read-receipt a note to self');
    final plain = await service.sendTextWithResult(_selfKey, 'plain');
    expect(plain.cloudCustomData, isNull, reason: 'armed data is one-shot');
  });

  test('an unreadable identity disables self matching but not history',
      () async {
    await service.dispose();
    ffiStub = _ThrowingIdentityFfi();
    service = open();
    expect(service.selfPublicKey, isNull);
    expect(service.isSelfPeer(_selfKey), isFalse);
    expect(service.getHistory(_selfKey), isEmpty);
  });

  test('every alias of the self key reads and clears the same history',
      () async {
    await service.sendTextWithResult(_selfKey.toLowerCase(), 'lower');
    await service.sendTextWithResult(_selfToxId, 'address');
    for (final alias in [
      _selfKey,
      _selfKey.toLowerCase(),
      _selfToxId,
      'c2c_$_selfKey',
    ]) {
      expect(service.getHistory(alias).map((m) => m.text),
          ['lower', 'address'],
          reason: alias);
    }
    expect(service.getConversationIds(), {_selfKey});
    await service.loadHistory(_selfKey.toLowerCase());
    expect(await service.hasArchivedHistory('c2c_$_selfKey'),
        await service.hasArchivedHistory(_selfKey));
    expect(await service.getArchivedHistory(_selfToxId), isEmpty);
    await service.markConversationRead('c2c_${_selfKey.toLowerCase()}');
    for (final alias in [_selfKey, _selfKey.toLowerCase(), _selfToxId]) {
      expect(service.getUnreadOf(alias), 0, reason: alias);
    }

    await service.clearC2CHistory('c2c_${_selfKey.toLowerCase()}');
    expect(service.getHistory(_selfKey), isEmpty);
    expect(ffiStub.calls, isEmpty);
  });

  test('self rows survive a store restart', () async {
    await service.sendTextWithResult(_selfKey, 'keep me');
    await history.flushPendingSaves();

    final reopened = MessageHistoryPersistence(historyDirectory: historyDir);
    final rows = await reopened.loadHistory(_selfKey);
    expect(rows.map((m) => m.text), ['keep me']);
    expect(rows.single.isSelf, isTrue);
    expect(rows.single.isPending, isFalse);
    await reopened.dispose();
  });

  test('a file to self is a local row; the drain flavour adds none', () async {
    final file = File(p.join(tempDir.path, 'photo.png'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    final row = await service.sendFile(_selfKey, file.path);
    expect(row, isNotNull);
    expect(row!.filePath, file.path);
    expect(row.fileSize, 4);
    expect(row.isPending, isFalse);
    expect(
        await service.sendFile(_selfKey, file.path, addToChatHistory: false),
        isNull);
    expect(service.getHistory(_selfKey), hasLength(1));
    expect(queue.getMessages(_selfKey), isEmpty);
    expect(ffiStub.calls, isEmpty);
  });

  test('typing, control, reactions and receipts stay local',
      () async {
    final row = await service.sendTextWithResult(_selfKey, 'x');
    await service.sendTyping(_selfKey, true);
    await service.sendControlSignal(_selfKey, '__revoke__:{}');
    await service.sendReaction(_selfKey, row.msgID!, 'like', 'add');
    // An inbound-looking row is the only thing an on-view receipt walk acts on.
    await history.appendHistory(
        _selfKey,
        ChatMessage(
          text: 'odd',
          fromUserId: _selfKey,
          isSelf: false,
          timestamp: DateTime.now(),
          groupId: null,
          msgID: 'inbound-1',
        ));
    await service.markConversationRead(_selfKey);
    expect(ffiStub.calls, isEmpty);
  });

  test('a group invite to self is never queued', () async {
    await service.dispose();
    final prefs = _MemoryPrefs();
    service = open(prefs: prefs);
    await service.queueGroupInviteForOfflineFriend('tox_1', _selfToxId);
    expect(await service.debugQueuedOfflineGroupInvites(), isEmpty);
    await service.queueGroupInviteForOfflineFriend('tox_1', 'CD' * 32);
    expect(await service.debugQueuedOfflineGroupInvites(),
        {'tox_1\t${'CD' * 32}'});
  });

  OfflineMessageItem queued(String msgID, DateTime at,
          {String text = '', String? filePath}) =>
      (
        kind: filePath == null ? 'text' : 'file',
        text: text,
        filePath: filePath,
        fileName: filePath == null ? null : p.basename(filePath),
        timestamp: at,
        msgID: msgID,
        cloudCustomData: null,
        contentKind: ChatMessageContentKind.normal,
      );

  test('a text an older build queued for self is reconciled locally',
      () async {
    final queuedAt = DateTime.now().subtract(const Duration(minutes: 5));
    await history.appendHistory(
        _selfKey,
        ChatMessage(
          text: 'stuck',
          fromUserId: 'FlutterUIKitClient',
          isSelf: true,
          timestamp: queuedAt,
          groupId: null,
          isPending: true,
          msgID: 'legacy-1',
        ));
    await queue.addMessage(_selfKey, queued('legacy-1', queuedAt, text: 'stuck'));

    await service.retryPendingC2cMessages(_selfKey);

    expect(queue.getMessages(_selfKey), isEmpty);
    final rows = service.getHistory(_selfKey);
    expect(rows, hasLength(1), reason: 'reconciled in place, not duplicated');
    expect(rows.single.msgID, 'legacy-1');
    expect(rows.single.isPending, isFalse);
    expect(ffiStub.calls, isEmpty);
  });

  test('queue-only legacy items (text and file) become rows, durably',
      () async {
    final file = File(p.join(tempDir.path, 'old.jpg'))
      ..writeAsBytesSync([9, 9, 9]);
    final at = DateTime.now().subtract(const Duration(minutes: 3));
    await queue.addMessage(_selfKey, queued('q-text', at, text: 'orphan'));
    await queue.addMessage(_selfKey,
        queued('q-file', at.add(const Duration(seconds: 1)), filePath: file.path));

    await service.retryPendingC2cMessages(_selfKey);

    expect(queue.getMessages(_selfKey), isEmpty);
    final byId = {for (final m in service.getHistory(_selfKey)) m.msgID: m};
    expect(byId['q-text']!.text, 'orphan');
    expect(byId['q-text']!.timestamp, at);
    expect(byId['q-file']!.filePath, file.path);
    expect(byId['q-file']!.fileName, 'old.jpg');
    expect(byId['q-file']!.fileSize, 3);
    expect(byId.values.every((m) => m.isSelf && !m.isPending), isTrue);

    // Saved before the queue was cleared: a fresh store sees both rows.
    final reopened = MessageHistoryPersistence(historyDirectory: historyDir);
    expect((await reopened.loadHistory(_selfKey)).map((m) => m.msgID),
        containsAll(<String>['q-text', 'q-file']));
    await reopened.dispose();
    expect(ffiStub.calls, isEmpty);
  });

  test('a new self send reconciles legacy items without losing the preview',
      () async {
    await queue.addMessage(_selfKey,
        queued('legacy-2', DateTime.now().subtract(const Duration(hours: 1)),
            text: 'old'));
    await service.sendTextWithResult(_selfKey, 'new');
    for (var i = 0; i < 50 && queue.getMessages(_selfKey).isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(queue.getMessages(_selfKey), isEmpty);
    expect(service.getHistory(_selfKey).map((m) => m.msgID),
        contains('legacy-2'));
    expect(service.lastMessages[_selfKey]?.text, 'new',
        reason: 'an older reconciled row must not replace the newest preview');
    expect(ffiStub.calls, isEmpty);
  });

  test('legacy queued group invites to self are dropped, never dispatched',
      () async {
    await service.dispose();
    final prefs = _MemoryPrefs();
    prefs.sets['queued_offline_group_invites_v1'] = {
      'tox_1\t$_selfKey',
      'tox_2\t${'CD' * 32}',
    };
    service = open(prefs: prefs);
    var dispatched = 0;
    await service.debugFlushPendingGroupInvitesForTest(_selfKey, (_) async {
      dispatched++;
      return true;
    });
    expect(dispatched, 0);
    expect(await service.debugQueuedOfflineGroupInvites(),
        {'tox_2\t${'CD' * 32}'});
  });

  test('msgID-less legacy notes sharing a millisecond are both kept',
      () async {
    final at = DateTime.now().subtract(const Duration(minutes: 2));
    await history.appendHistory(
        _selfKey,
        ChatMessage(
          text: 'first',
          fromUserId: 'FlutterUIKitClient',
          isSelf: true,
          timestamp: at,
          groupId: null,
          isPending: true,
          msgID: 'row-first',
        ));
    OfflineMessageItem legacy(String text) => (
          kind: 'text',
          text: text,
          filePath: null,
          fileName: null,
          timestamp: at,
          msgID: null,
          cloudCustomData: null,
          contentKind: ChatMessageContentKind.normal,
        );
    await queue.addMessage(_selfKey, legacy('first'));
    await queue.addMessage(_selfKey, legacy('second'));

    await service.retryPendingC2cMessages(_selfKey);

    expect(queue.getMessages(_selfKey), isEmpty);
    final texts = service.getHistory(_selfKey).map((m) => m.text).toList();
    expect(texts..sort(), ['first', 'second'],
        reason: 'the timestamp-only match must not swallow the second note');
    expect(service.getHistory(_selfKey).every((m) => !m.isPending), isTrue);
  });

  test('a self send sweeps invite-only legacy state', () async {
    await service.dispose();
    final prefs = _MemoryPrefs();
    prefs.sets['queued_offline_group_invites_v1'] = {
      'tox_1\t$_selfKey',
      'tox_2\t${'CD' * 32}',
    };
    service = open(prefs: prefs);
    await service.sendTextWithResult(_selfKey, 'hello me');
    for (var i = 0;
        i < 50 && (await service.debugQueuedOfflineGroupInvites()).length > 1;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await service.debugQueuedOfflineGroupInvites(),
        {'tox_2\t${'CD' * 32}'});
  });

  test('a re-initialised session sweeps again', () async {
    await service.dispose();
    final prefs = _MemoryPrefs();
    service = open(prefs: prefs);
    Future<Set<String>> settle() async {
      for (var i = 0;
          i < 50 && (await service.debugQueuedOfflineGroupInvites()).isNotEmpty;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return service.debugQueuedOfflineGroupInvites();
    }

    await service.sendTextWithResult(_selfKey, 'first session');
    await settle(); // swept: nothing queued

    // Next session on the same service object finds stale invite state.
    service.debugBeginSessionForTest();
    prefs.sets['queued_offline_group_invites_v1'] = {'tox_9\t$_selfKey'};
    await service.sendTextWithResult(_selfKey, 'second session');
    expect(await settle(), isEmpty);
  });

  test('a real friend still goes to the wire (guards are self-only)',
      () async {
    // Offline friend: queued (the stub reports no friends), not dropped.
    final row = await service.sendTextWithResult('CD' * 32, 'hello');
    expect(row.isPending, isTrue);
    expect(queue.getMessages('CD' * 32), hasLength(1));
    await service.sendTyping('CD' * 32, true);
    expect(ffiStub.calls['setTyping'], 1);
  });
}
