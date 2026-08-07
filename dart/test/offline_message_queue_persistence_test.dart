import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';

OfflineMessageItem textItem(
  String text, {
  required String id,
  String? cloudCustomData,
  ChatMessageContentKind contentKind = ChatMessageContentKind.normal,
}) {
  return (
    kind: 'text',
    text: text,
    filePath: null,
    fileName: null,
    timestamp: DateTime.utc(2026, 1, 1, 12, 0, int.parse(id.substring(1))),
    msgID: id,
    cloudCustomData: cloudCustomData,
    contentKind: contentKind,
  );
}

Map<String, Object?> itemJson(
  String text, {
  required String id,
  String? kind = 'text',
  String? filePath,
  String? cloudCustomData,
  String? contentKind,
}) {
  return {
    if (kind != null) 'kind': kind,
    'text': text,
    'filePath': filePath,
    'fileName': null,
    'timestamp': _timestampForId(id).toIso8601String(),
    'msgID': id,
    if (cloudCustomData != null) 'cloudCustomData': cloudCustomData,
    if (contentKind != null) 'contentKind': contentKind,
  };
}

DateTime _timestampForId(String id) {
  final digits = RegExp(r'\d+').firstMatch(id)?.group(0) ?? '1';
  return DateTime.utc(2026, 1, 1, 12, 0, int.parse(digits));
}

Future<void> writeRawQueue(File queueFile, Map<String, Object?> queue) async {
  await queueFile.create(recursive: true);
  await queueFile.writeAsString(jsonEncode(queue));
}

List<dynamic> readStoredItems(File queueFile, String peerId) {
  final json = jsonDecode(queueFile.readAsStringSync()) as Map<String, dynamic>;
  return json[peerId] as List<dynamic>;
}

class _DeleteFailingFile implements File {
  _DeleteFailingFile(this.delegate);

  final File delegate;
  bool deleteAttempted = false;

  @override
  String get path => delegate.path;

  @override
  Directory get parent => delegate.parent;

  @override
  Future<bool> exists() => delegate.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) {
    deleteAttempted = true;
    throw FileSystemException('simulated delete failure', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected File call: $invocation');
}

Future<_DeleteFailingFile> _failClearAtBackupDeletion({
  required OfflineMessageQueuePersistence persistence,
  required File queueFile,
}) async {
  final backupFile = File('${queueFile.path}.bak');
  final failingBackupFile = _DeleteFailingFile(backupFile);
  final knownFiles = <String, File>{
    queueFile.path: queueFile,
    backupFile.path: failingBackupFile,
    '${queueFile.path}.tmp': File('${queueFile.path}.tmp'),
    '${queueFile.path}.bak.tmp': File('${queueFile.path}.bak.tmp'),
  };

  await IOOverrides.runZoned(
    () async {
      await expectLater(
        persistence.clearQueueFile(),
        throwsA(isA<FileSystemException>()),
      );
    },
    createFile: (path) =>
        knownFiles[path] ??
        (throw StateError('Unexpected queue artifact path: $path')),
  );
  return failingBackupFile;
}

void main() {
  late Directory tempDir;
  late File queueFile;
  late OfflineMessageQueuePersistence persistence;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_queue_test_');
    queueFile = File('${tempDir.path}/offline_message_queue.json');
    persistence = OfflineMessageQueuePersistence(queueFilePath: queueFile.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('durable mutations', () {
    test('addMessage snapshots the live map without clearing the cache',
        () async {
      final item = textItem('hello', id: 'm1');

      await persistence.addMessage('self', item);

      expect(persistence.getMessages('self'), [item]);
      expect(readStoredItems(queueFile, 'self'), hasLength(1));
    });

    test('two concurrent adds serialize without lost or duplicated items',
        () async {
      final first = textItem('one', id: 'm1');
      final second = textItem('two', id: 'm2');

      await Future.wait([
        persistence.addMessage('peer', first),
        persistence.addMessage('peer', second),
      ]);

      final reloaded = OfflineMessageQueuePersistence(
        queueFilePath: queueFile.path,
      );
      final queue = await reloaded.loadQueue();

      expect(queue['peer']?.map((item) => item.text), ['one', 'two']);
      expect(queue['peer']?.map((item) => item.msgID), ['m1', 'm2']);
    });

    test('add remove add race is ordered by the mutation queue', () async {
      final first = textItem('first', id: 'm1');
      final second = textItem('second', id: 'm2');

      final addFirst = persistence.addMessage('peer', first);
      final removeFirst = persistence.removeItem('peer', first);
      final addSecond = persistence.addMessage('peer', second);

      await Future.wait([addFirst, removeFirst, addSecond]);

      final queue = await OfflineMessageQueuePersistence(
        queueFilePath: queueFile.path,
      ).loadQueue();
      expect(queue['peer']?.map((item) => item.text), ['second']);
    });

    test('restart keeps duplicate-looking items distinct by msgID', () async {
      final first = textItem('same', id: 'm1');
      final second = textItem('same', id: 'm2');

      await persistence.addMessage('peer', first);
      await persistence.addMessage('peer', second);

      final restarted = OfflineMessageQueuePersistence(
        queueFilePath: queueFile.path,
      );
      final queue = await restarted.loadQueue();

      expect(queue['peer'], [first, second]);
    });

    test('ACTION content kind survives restart while unknown values are normal',
        () async {
      final action = textItem(
        'waves',
        id: 'm1',
        contentKind: ChatMessageContentKind.action,
      );
      await persistence.addMessage('peer', action);

      final restarted = OfflineMessageQueuePersistence(
        queueFilePath: queueFile.path,
      );
      final queue = await restarted.loadQueue();
      expect(queue['peer']?.single.contentKind, ChatMessageContentKind.action);
      expect(
          readStoredItems(queueFile, 'peer').single,
          containsPair(
            'contentKind',
            'action',
          ));

      await writeRawQueue(queueFile, {
        'peer': <Object?>[
          itemJson('future', id: 'm2', contentKind: 'future-value'),
        ],
      });
      final unknown = await OfflineMessageQueuePersistence(
        queueFilePath: queueFile.path,
      ).loadQueue();
      expect(
          unknown['peer']?.single.contentKind, ChatMessageContentKind.normal);
    });

    test('successful drain removal persists exactly the removed item',
        () async {
      final first = textItem('first', id: 'm1');
      final second = textItem('second', id: 'm2');
      await persistence.addMessage('peer', first);
      await persistence.addMessage('peer', second);

      await persistence.removeItem('peer', first);

      final restarted = OfflineMessageQueuePersistence(
        queueFilePath: queueFile.path,
      );
      final queue = await restarted.loadQueue();
      expect(queue['peer'], [second]);
    });

    test('clearQueueFile removes primary backup temp and cache', () async {
      await persistence.addMessage('peer', textItem('hello', id: 'm1'));
      await File('${queueFile.path}.bak').writeAsString('backup');
      await File('${queueFile.path}.tmp').writeAsString('temp');
      await File('${queueFile.path}.bak.tmp').writeAsString('backup temp');

      await persistence.clearQueueFile();

      expect(await queueFile.exists(), isFalse);
      expect(await File('${queueFile.path}.bak').exists(), isFalse);
      expect(await File('${queueFile.path}.tmp').exists(), isFalse);
      expect(await File('${queueFile.path}.bak.tmp').exists(), isFalse);
      expect(persistence.getPeerIds(), isEmpty);
    });

    test('backup copy stages at the single .bak.tmp path', () async {
      final knownFiles = <String, File>{
        queueFile.path: queueFile,
        '${queueFile.path}.bak': File('${queueFile.path}.bak'),
        '${queueFile.path}.tmp': File('${queueFile.path}.tmp'),
        '${queueFile.path}.bak.tmp': File('${queueFile.path}.bak.tmp'),
        '${queueFile.path}.bak.bak.tmp': File('${queueFile.path}.bak.bak.tmp'),
      };
      final createdPaths = <String>[];

      await IOOverrides.runZoned(
        () => persistence.addMessage('peer', textItem('hello', id: 'm1')),
        createFile: (path) {
          createdPaths.add(path);
          return knownFiles[path] ??
              (throw StateError('Unexpected queue artifact path: $path'));
        },
      );

      expect(createdPaths, contains('${queueFile.path}.bak.tmp'));
      expect(createdPaths, isNot(contains('${queueFile.path}.bak.bak.tmp')));
    });

    test('clearQueueFile commits empty state before backup cleanup failure',
        () async {
      await persistence.addMessage('peer', textItem('old queued', id: 'm1'));

      final failingBackupFile = await _failClearAtBackupDeletion(
        persistence: persistence,
        queueFile: queueFile,
      );

      expect(failingBackupFile.deleteAttempted, isTrue);
      expect(await queueFile.exists(), isFalse);
      expect(await failingBackupFile.delegate.exists(), isTrue);
      expect(
        jsonDecode(await failingBackupFile.delegate.readAsString()),
        isEmpty,
      );
      expect(
        persistence.getPeerIds(),
        isEmpty,
        reason: 'the durable empty snapshot is the cache commit point',
      );
    });

    test('restart after primary deletion loads empty tombstoned backup',
        () async {
      await persistence.addMessage('peer', textItem('old queued', id: 'm1'));
      await _failClearAtBackupDeletion(
        persistence: persistence,
        queueFile: queueFile,
      );

      final restarted = OfflineMessageQueuePersistence(
        queueFilePath: queueFile.path,
      );
      final queue = await restarted.loadQueue();

      expect(queue, isEmpty);
      expect(restarted.getPeerIds(), isEmpty);
      expect(jsonDecode(await queueFile.readAsString()), isEmpty);
    });
  });

  group('load and recovery', () {
    test('recovers corrupt primary from valid backup', () async {
      await queueFile.writeAsString('{not json');
      final backupJson = jsonEncode({
        'peer': [
          itemJson(
            'from-backup',
            id: 'm1',
            cloudCustomData: '{"messageReply":{"messageID":"quoted"}}',
          ),
        ],
      });
      await File('${queueFile.path}.bak').writeAsString(backupJson);

      final queue = await persistence.loadQueue();

      expect(queue['peer']?.single.text, 'from-backup');
      expect(queue['peer']?.single.cloudCustomData, contains('quoted'));
      expect(await queueFile.readAsString(), backupJson);
    });

    test('unrecoverable corrupt primary throws and keeps bad evidence',
        () async {
      const corrupt = '{only bad primary';
      await queueFile.writeAsString(corrupt);

      await expectLater(persistence.loadQueue(), throwsA(anything));

      expect(await queueFile.exists(), isTrue);
      expect(await queueFile.readAsString(), corrupt);
    });

    test('valid primary wins over stale tmp and tmp is cleaned', () async {
      await writeRawQueue(queueFile, {
        'peer': [itemJson('primary', id: 'm1')],
      });
      final tempFile = File('${queueFile.path}.tmp');
      await tempFile.writeAsString('{torn temp');

      final queue = await persistence.loadQueue();

      expect(queue['peer']?.single.text, 'primary');
      expect(await tempFile.exists(), isFalse);
    });

    test('valid primary cleans stale backup temp from interrupted copy',
        () async {
      await writeRawQueue(queueFile, {
        'peer': [itemJson('primary', id: 'm1')],
      });
      final backupTempFile = File('${queueFile.path}.bak.tmp');
      await backupTempFile.writeAsString('{torn backup temp');

      final queue = await persistence.loadQueue();

      expect(queue['peer']?.single.text, 'primary');
      expect(await backupTempFile.exists(), isFalse);
    });

    test('legacy items infer kind while msgID and cloudCustomData round trip',
        () async {
      await writeRawQueue(queueFile, {
        'peer': [
          itemJson(
            'legacy file',
            id: 'file-id',
            kind: null,
            filePath: '/tmp/a.png',
          ),
          itemJson('legacy text', id: 'text-id', kind: null),
          itemJson(
            'quoted',
            id: 'quote-id',
            cloudCustomData: '{"messageReply":{"messageID":"q1"}}',
          ),
        ],
      });

      final queue = await persistence.loadQueue();
      await persistence.saveQueue(queue);

      final items = await OfflineMessageQueuePersistence(
        queueFilePath: queueFile.path,
      ).loadQueue();
      expect(items['peer']?[0].kind, 'file');
      expect(items['peer']?[1].kind, 'text');
      expect(items['peer']?[2].msgID, 'quote-id');
      expect(items['peer']?[2].cloudCustomData, contains('q1'));
    });
  });
}
