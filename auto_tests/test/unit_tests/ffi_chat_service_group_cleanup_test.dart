import 'dart:io';

import 'package:test/test.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';

import '../test_fixtures.dart';

void main() {
  late Directory tempDir;
  late OfflineMessageQueuePersistence queuePersistence;
  late FfiChatService service;

  setUpAll(setupTestEnvironment);
  tearDownAll(teardownTestEnvironment);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('group_queue_cleanup_');
    queuePersistence = OfflineMessageQueuePersistence(
      queueFilePath: '${tempDir.path}/offline_message_queue.json',
    );
    service = FfiChatService(
      preferencesService: MockPreferencesService(),
      loggerService: MockLoggerService(),
      bootstrapService: MockBootstrapService(),
      offlineMessageQueuePersistence: queuePersistence,
      historyDirectory: '${tempDir.path}/history',
    );
  });

  tearDown(() async {
    await service.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('cleanupGroupState clears only the group-scoped queue key', () async {
    const groupId = 'group-42';
    final OfflineMessageItem item = (
      kind: 'text',
      text: 'pending',
      filePath: null,
      fileName: null,
      timestamp: DateTime.utc(2026, 1, 1),
      msgID: 'message-1',
      cloudCustomData: null,
    );
    await queuePersistence.addMessage('group:$groupId', item);
    await queuePersistence.addMessage(groupId, item);

    await service.cleanupGroupState(groupId);

    expect(queuePersistence.getMessages('group:$groupId'), isEmpty);
    expect(queuePersistence.getMessages(groupId), [item]);
  });
}
