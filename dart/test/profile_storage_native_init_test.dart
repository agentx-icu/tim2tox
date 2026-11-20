// Run with TOX_FORCE_TCP_ONLY=1 TIM2TOX_TEST_LIBRARY=/absolute/native/library
// to exercise the Dart lifecycle against the real native implementation.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import 'package:tim2tox_dart/utils/offline_message_queue_persistence.dart';
import 'package:tim2tox_dart/utils/profile_storage_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['TIM2TOX_TEST_LIBRARY'];
  if (library != null) Tim2ToxFfi.setLibraryPathOverride(library);
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  FfiChatService? service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('profile-native-init-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => root.path);
  });
  tearDown(() async {
    await service?.dispose();
    service = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  FfiChatService open(
          {OfflineMessageQueuePersistence? queue,
          MessageHistoryPersistence? history}) =>
      FfiChatService(
        messageHistoryPersistence: history,
        historyDirectory: '${root.path}/history',
        offlineMessageQueuePersistence: queue,
        fileRecvPath: '${root.path}/files',
      );

  void expectNotLoggedInOrConnected() {
    final ffi = Tim2ToxFfi.open();
    expect(ffi.getSelfConnectionStatus(), 0);
    final user = calloc<Int8>(256);
    try {
      expect(ffi.getLoginUser(user, 256), 0);
    } finally {
      calloc.free(user);
    }
  }

  test('protected FfiChatService init reopens history offline before login',
      () async {
    final row = ChatMessage(
        text: 'offline history secret',
        fromUserId: 'self',
        isSelf: true,
        timestamp: DateTime.utc(2026),
        msgID: 'history-1');
    final firstHistory =
        MessageHistoryPersistence(historyDirectory: '${root.path}/history');
    service = open(history: firstHistory);
    expect(service!.setProfilePassphrase('password'), true);
    await service!.init(profileDirectory: '${root.path}/profile');
    expectNotLoggedInOrConnected();
    final identity = service!.getSelfToxId();
    expect(identity, hasLength(76));
    await firstHistory.saveHistory('peer', [row]);
    await service!.dispose();
    final reopenedHistory =
        MessageHistoryPersistence(historyDirectory: '${root.path}/history');
    service = open(history: reopenedHistory);
    expect(service!.setProfilePassphrase('password'), true);
    await service!.init(profileDirectory: '${root.path}/profile');
    expectNotLoggedInOrConnected();
    expect(service!.getSelfToxId(), identity);
    expect(reopenedHistory.getHistory('peer').single.text, row.text);
  },
      skip: library == null
          ? 'Set TIM2TOX_TEST_LIBRARY to a rebuilt native library'
          : false);

  test(
      'live rekey migrates the default queue and a protected restart restores it',
      () async {
    final queue = OfflineMessageQueuePersistence();
    service = open(queue: queue);
    await service!.init(profileDirectory: '${root.path}/profile');
    final pending = (
      kind: 'text',
      text: 'queued native secret',
      filePath: null,
      fileName: null,
      timestamp: DateTime.utc(2026),
      msgID: 'queued-1',
      cloudCustomData: '{"reply":1}',
      contentKind: ChatMessageContentKind.normal,
      control: null
    );
    await queue.addMessage('peer', pending);
    expect(service!.rekeyLiveProfilePassphrase('password'), true);
    await service!.waitForProfileStorageMigration();
    expect(queue.getMessages('peer'), [pending]);
    final account = service!.getSelfToxId()!.substring(0, 64).toUpperCase();
    final file = File(
        '${root.path}/tim2tox_accounts/$account/offline_message_queue.json');
    expect(ProfileStorageCodec.isProtectedSnapshot(await file.readAsString()),
        true);
    expect(await file.readAsString(), isNot(contains(pending.text)));
    await service!.dispose();
    final restored = OfflineMessageQueuePersistence();
    service = open(queue: restored);
    expect(service!.setProfilePassphrase('password'), true);
    await service!.init(profileDirectory: '${root.path}/profile');
    expectNotLoggedInOrConnected();
    expect(restored.getMessages('peer'), [pending]);
  },
      skip: library == null
          ? 'Set TIM2TOX_TEST_LIBRARY to a rebuilt native library'
          : false);

  test('reusing a service for another profile resets live queue ownership',
      () async {
    final queue = OfflineMessageQueuePersistence();
    service = open(queue: queue);
    await service!.init(profileDirectory: '${root.path}/account-a');
    final previous = (
      kind: 'text',
      text: 'account A secret',
      filePath: null,
      fileName: null,
      timestamp: DateTime.utc(2026),
      msgID: 'account-a-1',
      cloudCustomData: null,
      contentKind: ChatMessageContentKind.normal,
      control: null
    );
    await queue.addMessage('peer', previous);
    await service!.dispose();
    await service!.init(profileDirectory: '${root.path}/account-b');
    expect(service!.rekeyLiveProfilePassphrase('password'), true);
    await service!.waitForProfileStorageMigration();
    expect(queue.cache, isEmpty);
    expect(await queue.loadQueue(), isEmpty);
    final shared = OfflineMessageQueuePersistence(
        queueFilePath: '${root.path}/offline_message_queue.json');
    expect((await shared.loadQueue())['peer'], [previous]);
  },
      skip: library == null
          ? 'Set TIM2TOX_TEST_LIBRARY to a rebuilt native library'
          : false);
}
