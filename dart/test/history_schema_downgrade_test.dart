import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MessageHistoryPersistence store;
  late File file;
  final row = ChatMessage(
      text: 'preserve',
      fromUserId: 'self',
      isSelf: true,
      timestamp: DateTime.utc(2026),
      msgID: 'm1');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('history-schema-');
    store = MessageHistoryPersistence(historyDirectory: root.path);
    file = File('${root.path}/peer.json');
  });
  tearDown(() async {
    await store.dispose();
    await root.delete(recursive: true);
  });
  String futureData() => jsonEncode({
        'version': 999,
        'conversationId': 'peer',
        'futureMetadata': {'keep': true},
        'messages': [row.toJson()]
      });
  test('future primary rejects load and preserves original for re-upgrade',
      () async {
    final bytes = futureData();
    await file.writeAsString(bytes);
    await expectLater(store.loadHistory('peer'),
        throwsA(isA<HistorySchemaNewerThanAppException>()));
    expect(await file.readAsString(), bytes);
    expect(root.listSync().whereType<File>().length, 1);
    await file.writeAsString(bytes.replaceFirst('999', '2'));
    expect((await store.loadHistory('peer')).single.msgID, 'm1');
  });
  test('save without prior load cannot replace newer history', () async {
    final bytes = futureData();
    await file.writeAsString(bytes);
    await expectLater(store.saveHistory('peer', [row]),
        throwsA(isA<HistorySchemaNewerThanAppException>()));
    expect(await file.readAsString(), bytes);
  });
  test('future backup rejects recovery and writes without moving it', () async {
    final backup = File('${file.path}.bak');
    final bytes = futureData();
    await backup.writeAsString(bytes);
    await expectLater(store.loadHistory('peer'),
        throwsA(isA<HistorySchemaNewerThanAppException>()));
    await expectLater(store.saveHistory('peer', [row]),
        throwsA(isA<HistorySchemaNewerThanAppException>()));
    expect(await backup.readAsString(), bytes);
    expect(await file.exists(), isFalse);
  });
  test('future backup beside current primary blocks load and replacement',
      () async {
    final current = jsonEncode({
      'version': 2,
      'conversationId': 'peer',
      'messages': [row.toJson()]
    });
    final future = futureData();
    final backup = File('${file.path}.bak');
    await file.writeAsString(current);
    await backup.writeAsString(future);
    await expectLater(store.loadHistory('peer'),
        throwsA(isA<HistorySchemaNewerThanAppException>()));
    await expectLater(store.saveHistory('peer', [row]),
        throwsA(isA<HistorySchemaNewerThanAppException>()));
    expect(await file.readAsString(), current);
    expect(await backup.readAsString(), future);
  });
  test('bulk load propagates upgrade requirement instead of empty history',
      () async {
    await file.writeAsString(futureData());
    await expectLater(store.loadAllHistories(),
        throwsA(isA<HistorySchemaNewerThanAppException>()));
  });
}
