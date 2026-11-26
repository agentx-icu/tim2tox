import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';
import 'package:tim2tox_dart/utils/profile_storage_codec.dart';

// Native authentication and key lifecycle are exercised by ToxSessionPinTest.
// This injected transform isolates Dart storage framing and file transactions.
ProfileStorageCodec codec(int key) => ProfileStorageCodec((kind, seal, bytes) {
      final marker = key ^ kind;
      if (seal) {
        return Uint8List.fromList([marker, ...bytes.map((b) => b ^ marker)]);
      }
      if (bytes.isEmpty || bytes.first != marker) {
        throw const ProfileStorageException('wrong storage key');
      }
      return Uint8List.fromList(bytes.skip(1).map((b) => b ^ marker).toList());
    });

Future<void> damageSnapshot(File file) async {
  final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final corrupt = base64Decode(raw['_tim2toxEncrypted'] as String);
  corrupt[0] ^= 1;
  raw['_tim2toxEncrypted'] = base64Encode(corrupt);
  await file.writeAsString(jsonEncode(raw));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tim2tox-storage-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => root.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await root.delete(recursive: true);
  });

  const account =
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  OfflineMessageItem item(String id, {String? control}) => (
        kind: 'text',
        text: 'secret-$id',
        filePath: null,
        fileName: null,
        timestamp: DateTime.utc(2026),
        msgID: id,
        cloudCustomData: '{"reply":1}',
        contentKind: ChatMessageContentKind.action,
        control: control,
      );
  File ownedQueue() =>
      File('${root.path}/tim2tox_accounts/$account/offline_message_queue.json');

  test(
      'first password migrates live default sends durably and keeps the drain cache',
      () async {
    final queue = OfflineMessageQueuePersistence();
    final pending = item('live');
    // Both calls are intentionally submitted without awaiting: migration must
    // run after the durable enqueue through the same mutation fence.
    final enqueue = queue.addMessage('peer', pending);
    final migration =
        queue.installStorageCodec(codec(173), defaultAccountKey: account);
    await Future.wait([enqueue, migration]);
    expect(queue.getMessages('peer'), [pending]);
    final file = ownedQueue();
    for (final path in [file.path, '${file.path}.bak']) {
      expect(
          ProfileStorageCodec.isProtectedSnapshot(
              await File(path).readAsString()),
          true);
      expect(await File(path).readAsString(), isNot(contains(pending.text)));
    }
    final reopened = OfflineMessageQueuePersistence();
    await reopened.installStorageCodec(codec(173), defaultAccountKey: account);
    expect((await reopened.loadQueue())['peer'], [pending]);
    // Do not leave a plaintext copy or a backup that can resurrect this send.
    for (final suffix in ['', '.bak']) {
      expect(
          await File('${root.path}/offline_message_queue.json$suffix')
              .readAsString(),
          '{}');
    }
    await queue.removeItem('peer', pending);
    expect(await queue.loadQueue(), isEmpty);
  });

  test(
      'password migration adopts live sends but leaves unattributed legacy entries',
      () async {
    final legacy = item('legacy');
    final shared = File('${root.path}/offline_message_queue.json');
    await OfflineMessageQueuePersistence(queueFilePath: shared.path)
        .addMessage('peer', legacy);
    final queue = OfflineMessageQueuePersistence();
    await queue.loadQueue();
    final live = item('live');
    await queue.addMessage('peer', live);
    await queue.installStorageCodec(codec(173), defaultAccountKey: account);
    expect(queue.getMessages('peer'), [live]);
    expect((await queue.loadQueue())['peer'], [live]);
    expect(
        (await OfflineMessageQueuePersistence(queueFilePath: shared.path)
            .loadQueue())['peer'],
        [legacy]);
  });

  test('cold protected binding never adopts a shared legacy queue', () async {
    final shared = File('${root.path}/offline_message_queue.json');
    await OfflineMessageQueuePersistence(queueFilePath: shared.path)
        .addMessage('peer', item('legacy'));
    final before = await shared.readAsString();
    final queue = OfflineMessageQueuePersistence();
    await queue.loadQueue();
    await queue.installStorageCodec(codec(173), defaultAccountKey: account);
    expect(queue.cache, isEmpty);
    expect(await queue.loadQueue(), isEmpty);
    expect(await shared.readAsString(), before);
  });

  test('failed destination publication preserves live sends and can be retried',
      () async {
    final queue = OfflineMessageQueuePersistence();
    final pending = item('live');
    await queue.addMessage('peer', pending);
    final shared = File('${root.path}/offline_message_queue.json');
    final before = await shared.readAsString();
    final blocker = Directory('${ownedQueue().path}.tmp');
    await blocker.create(recursive: true);
    await expectLater(
        queue.installStorageCodec(codec(173), defaultAccountKey: account),
        throwsA(isA<FileSystemException>()));
    expect(queue.getMessages('peer'), [pending]);
    expect(await shared.readAsString(), before);
    await blocker.delete();
    await queue.installStorageCodec(codec(173), defaultAccountKey: account);
    expect((await queue.loadQueue())['peer'], [pending]);
  });

  test(
      'retry after source cleanup failure merges the destination without duplicates',
      () async {
    final queue = OfflineMessageQueuePersistence();
    final pending = item('live');
    await queue.addMessage('peer', pending);
    final sourceBlocker =
        Directory('${root.path}/offline_message_queue.json.tmp');
    await sourceBlocker.create();
    await expectLater(
        queue.installStorageCodec(codec(173), defaultAccountKey: account),
        throwsA(isA<FileSystemException>()));
    expect(queue.getMessages('peer'), [pending]);
    final destination =
        OfflineMessageQueuePersistence(queueFilePath: ownedQueue().path);
    await destination.installStorageCodec(codec(173));
    expect((await destination.loadQueue())['peer'], [pending]);
    await sourceBlocker.delete();
    await queue.installStorageCodec(codec(173), defaultAccountKey: account);
    expect((await queue.loadQueue())['peer'], [pending]);
  });

  test('source cleanup failure cannot resurrect a subsequently drained send',
      () async {
    final queue = OfflineMessageQueuePersistence();
    final pending = item('live');
    await queue.addMessage('peer', pending);
    final blocker = Directory('${root.path}/offline_message_queue.json.tmp');
    await blocker.create();
    await expectLater(
        queue.installStorageCodec(codec(173), defaultAccountKey: account),
        throwsA(isA<FileSystemException>()));
    await blocker.delete();
    await queue.removeItem('peer', pending);
    final restarted = OfflineMessageQueuePersistence();
    await restarted.installStorageCodec(codec(173), defaultAccountKey: account);
    expect(await restarted.loadQueue(), isEmpty);
    // A cleanup retry must not republish a stale copy into the active queue.
    await queue.installStorageCodec(codec(173), defaultAccountKey: account);
    expect(await queue.loadQueue(), isEmpty);
  });

  test(
      'migration retains target entries and current live controls but not removed sends',
      () async {
    final destination =
        OfflineMessageQueuePersistence(queueFilePath: ownedQueue().path);
    await destination.installStorageCodec(codec(173));
    final existing = item('existing');
    await destination.addMessage('peer', existing);
    final queue = OfflineMessageQueuePersistence();
    final original = item('live');
    final cancelled = item('live', control: OfflineSendControl.cancelled);
    await queue.addMessage('peer', original);
    expect(await queue.replaceItem('peer', original, cancelled), true);
    await queue.addMessage('peer', item('removed'));
    await queue.removeItem('peer', item('removed'));
    final migration =
        queue.installStorageCodec(codec(173), defaultAccountKey: account);
    final after = queue.addMessage('peer', item('after'));
    await Future.wait([migration, after]);
    expect((await queue.loadQueue())['peer'],
        [existing, cancelled, item('after')]);
    expect(queue.queuedMsgIDs(dispatchableOnly: true), {'existing', 'after'});
  });

  test(
      'a locked destination cannot replace the source cache or consume live sends',
      () async {
    final destination =
        OfflineMessageQueuePersistence(queueFilePath: ownedQueue().path);
    await destination.installStorageCodec(codec(18));
    await destination.addMessage('peer', item('other-key'));
    final protected = await ownedQueue().readAsString();
    final queue = OfflineMessageQueuePersistence();
    final pending = item('live');
    await queue.addMessage('peer', pending);
    await expectLater(
        queue.installStorageCodec(codec(173), defaultAccountKey: account),
        throwsA(isA<ProfileStorageException>()));
    expect(queue.getMessages('peer'), [pending]);
    expect(await ownedQueue().readAsString(), protected);
    expect((await queue.loadQueue())['peer'], [pending]);
  });

  final secret = ChatMessage(
    text: 'private-message',
    fromUserId: 'self',
    isSelf: true,
    timestamp: DateTime.utc(2026),
    msgID: 'private-id',
  );

  test('migrates and reloads the main history, archive and backup', () async {
    final plain = jsonEncode({
      'conversationId': 'peer',
      'version': 2,
      'messages': [secret.toJson()],
    });
    final primary = File('${root.path}/peer.json');
    final backup = File('${root.path}/peer.json.bak');
    final archive = File('${root.path}/peer.archive.jsonl');
    await primary.writeAsString(plain);
    await backup.writeAsString(plain);
    final archived = ChatMessage(
      text: 'private-archive',
      msgID: 'private-old-id',
      fromUserId: 'self',
      isSelf: true,
      timestamp: DateTime.utc(2025),
    );
    await archive.writeAsString('${jsonEncode(archived.toJson())}\n');

    final store = MessageHistoryPersistence(historyDirectory: root.path);
    await store.installStorageCodec(codec(173));
    for (final file in [primary, backup, archive]) {
      expect(await file.readAsString(), isNot(contains(secret.text)));
    }
    expect(await archive.readAsString(), isNot(contains(archived.text)));
    expect((await store.loadHistory('peer')).single.text, secret.text);
    expect(
        (await store.loadArchivedHistory('peer')).single.text, archived.text);
    await store.dispose();

    final unkeyed = MessageHistoryPersistence(historyDirectory: root.path);
    final sealed = await primary.readAsString();
    await expectLater(unkeyed.saveHistory('peer', [secret]), throwsException);
    expect(await primary.readAsString(), sealed);
    await unkeyed.dispose();
  });

  test('migrates both queue snapshots and recovers only with the right key',
      () async {
    final file = File('${root.path}/queue.json');
    final backup = File('${file.path}.bak');
    final clear = jsonEncode({
      'peer': [
        {'text': secret.text, 'timestamp': secret.timestamp.toIso8601String()}
      ]
    });
    await file.writeAsString(clear);
    await backup.writeAsString(clear);
    final queue = OfflineMessageQueuePersistence(queueFilePath: file.path);
    await queue.installStorageCodec(codec(173));
    expect((await queue.loadQueue())['peer']?.single.text, secret.text);
    expect(await file.readAsString(), isNot(contains(secret.text)));
    final protectedBackup = await backup.readAsString();
    expect(protectedBackup, isNot(contains(secret.text)));
    await file.delete();
    final reopened = OfflineMessageQueuePersistence(queueFilePath: file.path);
    await expectLater(reopened.installStorageCodec(codec(18)), throwsException);
    expect(await backup.readAsString(), protectedBackup);
    await reopened.installStorageCodec(codec(173));
    expect((await reopened.loadQueue())['peer']?.single.text, secret.text);
    expect(await file.readAsString(), protectedBackup);
  });

  test('a damaged encrypted queue recovers from an authenticated backup',
      () async {
    final file = File('${root.path}/queue.json');
    final backup = File('${file.path}.bak');
    final queue = OfflineMessageQueuePersistence(queueFilePath: file.path);
    final original = jsonEncode({
      'peer': [
        {'text': secret.text, 'timestamp': secret.timestamp.toIso8601String()}
      ]
    });
    await file.writeAsString(original);
    await backup.writeAsString(original);
    await queue.installStorageCodec(codec(173));
    await damageSnapshot(file);

    final reopened = OfflineMessageQueuePersistence(queueFilePath: file.path);
    await reopened.installStorageCodec(codec(173));
    expect((await reopened.loadQueue())['peer']?.single.text, secret.text);
    expect(await file.readAsString(), await backup.readAsString());
  });

  test('damaged encrypted history restores from its authenticated backup',
      () async {
    final file = File('${root.path}/peer.json');
    final backup = File('${file.path}.bak');
    final initial = jsonEncode({
      'conversationId': 'peer',
      'version': 2,
      'messages': [secret.toJson()],
    });
    await file.writeAsString(initial);
    await backup.writeAsString(initial);
    final seeded = MessageHistoryPersistence(historyDirectory: root.path);
    await seeded.installStorageCodec(codec(173));
    await seeded.dispose();
    await damageSnapshot(file);

    final reopened = MessageHistoryPersistence(historyDirectory: root.path);
    await reopened.installStorageCodec(codec(173));
    expect((await reopened.loadHistory('peer')).single.text, secret.text);
    await reopened.dispose();
  });
}
