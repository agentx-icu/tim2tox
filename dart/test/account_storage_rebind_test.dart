// Late-binding of per-account storage onto an already-constructed store.
//
// WHY THIS EXISTS: a host whose account row carries no Tox ID cannot know the
// account's storage paths until `init()` + `login()` have opened the profile,
// so it has to construct the persistence layer on the SHARED
// `<AppSupport>/chat_history` + `offline_message_queue.json` defaults that
// every account on the device would otherwise share. `rebindHistoryDirectory`
// / `rebindQueueFile` are what let that host re-point the store once the
// identity is known, in the pre-boot window.
//
// These tests exercise the primitives directly (no FFI, no path_provider);
// the toxee-side wiring is covered by
// `test/legacy_account_storage_late_binding_test.dart` in the integrating app.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';

const _conversationId =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

ChatMessage _message(String text, {required String id}) => ChatMessage(
      text: text,
      fromUserId: 'self',
      isSelf: true,
      timestamp: DateTime.utc(2026, 1, 1, 12, 0, 0),
      msgID: id,
    );

OfflineMessageItem _queueItem(String text, {required String id}) => (
      kind: 'text',
      text: text,
      filePath: null,
      fileName: null,
      timestamp: DateTime.utc(2026, 1, 1, 12, 0, 0),
      msgID: id,
      cloudCustomData: null,
      contentKind: ChatMessageContentKind.normal,
    );

List<String> _historyFiles(Directory dir) {
  if (!dir.existsSync()) return const <String>[];
  return dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((name) => name.endsWith('.json'))
      .toList()
    ..sort();
}

String _historyText(Directory dir) {
  final files = dir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.json'),
      );
  return files.map((f) => f.readAsStringSync()).join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('account_storage_rebind_');
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Directory dirIn(String name) => Directory('${tempRoot.path}/$name');

  group('MessageHistoryPersistence.rebindHistoryDirectory', () {
    test('later writes land in the new directory, not the old one', () async {
      final shared = dirIn('shared_chat_history');
      final account = dirIn('account_data/AAAA/chat_history');
      final store = MessageHistoryPersistence(historyDirectory: shared.path);
      addTearDown(store.dispose);

      await store.saveHistory(_conversationId, [
        _message('written-before-rebind', id: 'm1'),
      ]);
      expect(_historyFiles(shared), isNotEmpty);

      await store.rebindHistoryDirectory(account.path);

      await store.saveHistory(_conversationId, [
        _message('written-after-rebind', id: 'm2'),
      ]);

      expect(_historyFiles(account), isNotEmpty);
      expect(_historyText(account), contains('written-after-rebind'));
      expect(
        _historyText(shared),
        isNot(contains('written-after-rebind')),
        reason: 'the shared default must not receive post-rebind writes',
      );
    });

    test('drops in-memory state read from the old location', () async {
      final shared = dirIn('shared_chat_history');
      final account = dirIn('account_data/AAAA/chat_history');
      final store = MessageHistoryPersistence(historyDirectory: shared.path);
      addTearDown(store.dispose);

      await store.appendHistory(
        _conversationId,
        _message('shared-row', id: 'm1'),
      );
      expect(store.getHistory(_conversationId), hasLength(1));

      await store.rebindHistoryDirectory(account.path);

      expect(
        store.getHistory(_conversationId),
        isEmpty,
        reason: 'rows loaded from the shared default must not survive the '
            'rebind — they would be re-persisted under the account',
      );
      expect(
        await store.loadHistory(_conversationId),
        isEmpty,
        reason: 'the new (empty) account directory is the only source now',
      );
    });

    test('two accounts rebound on the same device stay isolated', () async {
      final shared = dirIn('shared_chat_history');
      final accountA = dirIn('account_data/AAAA/chat_history');
      final accountB = dirIn('account_data/BBBB/chat_history');

      final storeA = MessageHistoryPersistence(historyDirectory: shared.path);
      addTearDown(storeA.dispose);
      await storeA.rebindHistoryDirectory(accountA.path);
      await storeA.saveHistory(_conversationId, [
        _message('alice-only', id: 'a1'),
      ]);
      await storeA.flushPendingSaves();

      final storeB = MessageHistoryPersistence(historyDirectory: shared.path);
      addTearDown(storeB.dispose);
      await storeB.rebindHistoryDirectory(accountB.path);
      await storeB.saveHistory(_conversationId, [
        _message('bob-only', id: 'b1'),
      ]);
      await storeB.flushPendingSaves();

      final rowsA = await storeA.loadHistory(_conversationId);
      final rowsB = await storeB.loadHistory(_conversationId);
      expect(rowsA.map((m) => m.text), ['alice-only']);
      expect(rowsB.map((m) => m.text), ['bob-only']);
      expect(_historyText(accountA), isNot(contains('bob-only')));
      expect(_historyText(accountB), isNot(contains('alice-only')));
    });

    test('rebinding to the directory already in use is a no-op', () async {
      final account = dirIn('account_data/AAAA/chat_history');
      final store = MessageHistoryPersistence(historyDirectory: account.path);
      addTearDown(store.dispose);

      await store.appendHistory(_conversationId, _message('kept', id: 'm1'));
      await store.rebindHistoryDirectory(account.path);

      expect(
        store.getHistory(_conversationId),
        hasLength(1),
        reason: 'an idempotent rebind must not discard live state',
      );
    });

    test('refuses an empty or relative directory', () async {
      final store = MessageHistoryPersistence(
        historyDirectory: dirIn('chat_history').path,
      );
      addTearDown(store.dispose);

      expect(
        () => store.rebindHistoryDirectory(''),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => store.rebindHistoryDirectory('relative/chat_history'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('OfflineMessageQueuePersistence.rebindQueueFile', () {
    test('later writes land in the new file, not the shared one', () async {
      final sharedQueue = File('${tempRoot.path}/offline_message_queue.json');
      final accountQueue = File(
        '${tempRoot.path}/account_data/AAAA/offline_message_queue.json',
      );
      final queue = OfflineMessageQueuePersistence(
        queueFilePath: sharedQueue.path,
      );

      await queue.addMessage('peer', _queueItem('before', id: 'q1'));
      expect(sharedQueue.existsSync(), isTrue);
      final sharedBefore = sharedQueue.readAsStringSync();

      await queue.rebindQueueFile(accountQueue.path);
      expect(
        queue.getMessages('peer'),
        isEmpty,
        reason: 'items loaded from the shared queue must not be re-persisted '
            'under the account',
      );

      await queue.addMessage('peer', _queueItem('after', id: 'q2'));
      expect(accountQueue.existsSync(), isTrue);
      expect(accountQueue.readAsStringSync(), contains('after'));
      expect(
        sharedQueue.readAsStringSync(),
        sharedBefore,
        reason: 'the shared queue file must be untouched after the rebind',
      );
      expect(
        accountQueue.readAsStringSync(),
        isNot(contains('"before"')),
        reason: 'the pre-rebind item belongs to the shared queue only',
      );
      expect(
        (jsonDecode(accountQueue.readAsStringSync())
            as Map<String, dynamic>)['peer'],
        hasLength(1),
      );
    });

    test('rebinding to the same path keeps the cache', () async {
      final accountQueue = File('${tempRoot.path}/q.json');
      final queue = OfflineMessageQueuePersistence(
        queueFilePath: accountQueue.path,
      );
      await queue.addMessage('peer', _queueItem('kept', id: 'q1'));
      await queue.rebindQueueFile(accountQueue.path);
      expect(queue.getMessages('peer'), hasLength(1));
    });

    test('refuses an empty path', () {
      final queue = OfflineMessageQueuePersistence(
        queueFilePath: '${tempRoot.path}/q.json',
      );
      expect(() => queue.rebindQueueFile(''), throwsA(isA<ArgumentError>()));
    });
  });
}
