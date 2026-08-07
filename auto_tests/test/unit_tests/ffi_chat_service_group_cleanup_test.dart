import 'dart:io';

import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:test/test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';

import '../test_fixtures.dart';

void main() {
  late Directory tempDir;
  late OfflineMessageQueuePersistence queuePersistence;
  late MockPreferencesService preferences;
  late FfiChatService service;

  setUpAll(setupTestEnvironment);
  tearDownAll(teardownTestEnvironment);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('group_queue_cleanup_');
    queuePersistence = OfflineMessageQueuePersistence(
      queueFilePath: '${tempDir.path}/offline_message_queue.json',
    );
    preferences = MockPreferencesService();
    service = FfiChatService(
      preferencesService: preferences,
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
      contentKind: ChatMessageContentKind.normal,
    );
    await queuePersistence.addMessage('group:$groupId', item);
    await queuePersistence.addMessage(groupId, item);

    await service.cleanupGroupState(groupId);

    expect(queuePersistence.getMessages('group:$groupId'), isEmpty);
    expect(queuePersistence.getMessages(groupId), [item]);
  });

  test('dismissGroup native failure preserves local state and emits no success',
      () async {
    const groupId = 'group-native-failure';
    final message = ChatMessage(
      text: 'kept',
      fromUserId: 'sender',
      isSelf: false,
      timestamp: DateTime.utc(2026, 1, 1),
      groupId: groupId,
      msgID: 'message-kept',
    );
    final OfflineMessageItem queuedItem = (
      kind: 'text',
      text: 'pending',
      filePath: null,
      fileName: null,
      timestamp: DateTime.utc(2026, 1, 2),
      msgID: 'queued-message',
      cloudCustomData: null,
      contentKind: ChatMessageContentKind.normal,
    );
    await service.registerJoinedGroupState(groupId);
    service.messageHistoryPersistence.setCachedHistory(groupId, [message]);
    await queuePersistence.addMessage('group:$groupId', queuedItem);

    var dismissedNotifications = 0;
    final platform = Tim2ToxSdkPlatform(ffiService: service);
    await platform.setGroupListener(
      listener: V2TimGroupListener(
        onGroupDismissed: (_, __) => dismissedNotifications++,
      ),
    );
    try {
      final result = await platform.dismissGroup(groupID: groupId);

      expect(result.code, isNonZero);
      expect(dismissedNotifications, 0);
      expect(service.knownGroups, contains(groupId));
      expect(service.quitGroups, isNot(contains(groupId)));
      expect(await preferences.getGroups(), contains(groupId));
      expect(await preferences.getQuitGroups(), isNot(contains(groupId)));
      expect(service.messageHistoryPersistence.getHistory(groupId), [message]);
      expect(queuePersistence.getMessages('group:$groupId'), [queuedItem]);
    } finally {
      platform.dispose();
    }
  });

  test('dismissGroup rejects an empty group ID before changing local state',
      () async {
    await expectLater(
      service.dismissGroup('  '),
      throwsA(isA<ArgumentError>()),
    );

    expect(service.quitGroups, isEmpty);
    expect(await preferences.getQuitGroups(), isEmpty);
  });
}
