import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
  });
  tearDown(() async {
    await root.delete(recursive: true);
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
