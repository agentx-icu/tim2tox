import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimConversationListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_conversation.dart';
import 'package:tim2tox_dart/interfaces/conversation_manager_provider.dart';
import 'package:tim2tox_dart/interfaces/draft_preferences_service.dart';
import 'package:tim2tox_dart/interfaces/extended_preferences_service.dart';
import 'package:tim2tox_dart/models/fake_models.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

const _conversationID = 'c2c_friend';
const _sharedAccountPrefix = 'ABCDEF0123456789';
final _accountA = '$_sharedAccountPrefix${List.filled(60, 'A').join()}';
final _accountB = '$_sharedAccountPrefix${List.filled(60, 'B').join()}';

class _MemoryDraftPreferences implements DraftPreferencesService {
  final Map<String, ConversationDraft> values = {};
  final Completer<void> firstSaveStarted = Completer<void>();
  Completer<void>? firstSaveGate;
  bool failSaves = false;
  int saveCalls = 0;
  int loadCalls = 0;

  String _key(String accountToxId, String conversationID) =>
      '$accountToxId::$conversationID';

  @override
  Future<ConversationDraft?> loadConversationDraft({
    required String accountToxId,
    required String conversationID,
  }) async {
    loadCalls++;
    return values[_key(accountToxId, conversationID)];
  }

  @override
  Future<void> removeConversationDraft({
    required String accountToxId,
    required String conversationID,
  }) async {
    values.remove(_key(accountToxId, conversationID));
  }

  @override
  Future<void> saveConversationDraft({
    required String accountToxId,
    required ConversationDraft draft,
  }) async {
    saveCalls++;
    if (saveCalls == 1) {
      if (!firstSaveStarted.isCompleted) firstSaveStarted.complete();
      await firstSaveGate?.future;
    }
    if (failSaves) throw StateError('simulated draft write failure');
    values[_key(accountToxId, draft.conversationID)] = draft;
  }
}

class _CombinedPreferences extends _MemoryDraftPreferences
    implements ExtendedPreferencesService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestFfiChatService extends FfiChatService {
  _TestFfiChatService({
    required String accountToxId,
    required DraftPreferencesService? drafts,
    required String storageDirectory,
    ExtendedPreferencesService? preferences,
  })  : _accountToxId = accountToxId,
        super(
          preferencesService: preferences,
          draftPreferencesService: drafts,
          historyDirectory: '$storageDirectory/history',
          queueFilePath: '$storageDirectory/offline_queue.json',
        );

  final String _accountToxId;

  @override
  String? getSelfToxId() => _accountToxId;
}

class _ConversationProvider implements ConversationManagerProvider {
  @override
  Future<void> deleteConversation(String conversationID) async {}

  @override
  Future<List<FakeConversation>> getConversationList() async => [
        FakeConversation(
          conversationID: _conversationID,
          title: 'Friend',
          faceUrl: null,
          unreadCount: 0,
        ),
      ];

  @override
  Future<int> getTotalUnreadCount() async => 0;

  @override
  Future<void> setPinned(String conversationID, bool isPinned) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('tim2tox_draft_test_');
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  _TestFfiChatService createService(
    String accountToxId,
    DraftPreferencesService? drafts, {
    String? suffix,
    ExtendedPreferencesService? preferences,
  }) {
    final storageDirectory =
        suffix == null ? tempDirectory.path : '${tempDirectory.path}/$suffix';
    return _TestFfiChatService(
      accountToxId: accountToxId,
      drafts: drafts,
      storageDirectory: storageDirectory,
      preferences: preferences,
    );
  }

  test('serializes saves and queues a load behind pending writes', () async {
    final drafts = _MemoryDraftPreferences();
    drafts.firstSaveGate = Completer<void>();
    final service = createService(_accountA, drafts);
    addTearDown(service.dispose);
    final changes = <ConversationDraft>[];
    final subscription = service.conversationDraftChanges.listen(changes.add);
    addTearDown(subscription.cancel);

    final first = service.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'first',
    );
    await drafts.firstSaveStarted.future;
    final second = service.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'second',
    );
    final queuedLoad = service.loadConversationDraft(_conversationID);
    await Future<void>.delayed(Duration.zero);

    expect(drafts.saveCalls, 1);
    expect(drafts.loadCalls, 0);

    drafts.firstSaveGate!.complete();
    await Future.wait([first, second]);
    expect((await queuedLoad)?.text, 'second');
    await Future<void>.delayed(Duration.zero);
    expect(changes.map((draft) => draft.text), ['first', 'second']);
  });

  test('isolates accounts sharing the same 16-character prefix', () async {
    final drafts = _MemoryDraftPreferences();
    final serviceA = createService(_accountA, drafts, suffix: 'a');
    final serviceB = createService(_accountB, drafts, suffix: 'b');
    addTearDown(serviceA.dispose);
    addTearDown(serviceB.dispose);

    await serviceA.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'account A',
    );
    await serviceB.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'account B',
    );

    expect(
      (await serviceA.loadConversationDraft(_conversationID))?.text,
      'account A',
    );
    expect(
      (await serviceB.loadConversationDraft(_conversationID))?.text,
      'account B',
    );
  });

  test('rejects a shortened account ID before persistence', () async {
    final drafts = _MemoryDraftPreferences();
    final service = createService(List.filled(64, 'A').join(), drafts);
    addTearDown(service.dispose);

    await expectLater(
      service.setConversationDraft(
        conversationID: _conversationID,
        draftText: 'not persisted',
      ),
      throwsStateError,
    );
    expect(drafts.saveCalls, 0);
  });

  test('uses preferences draft capability when no explicit service is passed',
      () async {
    final preferences = _CombinedPreferences();
    final service = createService(
      _accountA,
      null,
      preferences: preferences,
    );
    addTearDown(service.dispose);

    expect(service.supportsConversationDrafts, isTrue);
    await service.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'fallback',
    );
    expect(
      (await service.loadConversationDraft(_conversationID))?.text,
      'fallback',
    );
  });

  test('platform fails closed and emits no change when persistence fails',
      () async {
    final drafts = _MemoryDraftPreferences()..failSaves = true;
    final service = createService(_accountA, drafts);
    final platform = Tim2ToxSdkPlatform(ffiService: service);
    addTearDown(() async {
      platform.dispose();
      await service.dispose();
    });
    final changes = <ConversationDraft>[];
    final subscription = service.conversationDraftChanges.listen(changes.add);
    addTearDown(subscription.cancel);

    final result = await platform.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'write fails',
    );
    await Future<void>.delayed(Duration.zero);

    expect(result.code, isNot(0));
    expect(changes, isEmpty);
    expect(
      await service.loadConversationDraft(_conversationID),
      isNull,
    );
  });

  test('platform emits a sparse conversation update after durable success',
      () async {
    final drafts = _MemoryDraftPreferences();
    final service = createService(_accountA, drafts);
    final platform = Tim2ToxSdkPlatform(ffiService: service);
    addTearDown(() async {
      platform.dispose();
      await service.dispose();
    });
    final changed = Completer<V2TimConversation>();
    await platform.setConversationListener(
      listener: V2TimConversationListener(
        onConversationChanged: (conversations) {
          if (!changed.isCompleted) changed.complete(conversations.single);
        },
      ),
    );

    final result = await platform.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'durable text',
    );
    final conversation = await changed.future;

    expect(result.code, 0);
    expect(conversation.conversationID, _conversationID);
    expect(conversation.draftText, 'durable text');
    expect(conversation.draftTimestamp, isPositive);
    expect(conversation.lastMessage, isNull);
    expect(conversation.showName, isNull);
  });

  test('reload projects persisted draft into conversation reads', () async {
    final drafts = _MemoryDraftPreferences();
    final firstService = createService(_accountA, drafts, suffix: 'first');
    addTearDown(firstService.dispose);
    final saved = await firstService.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'restored after restart',
    );

    final reloadedService =
        createService(_accountA, drafts, suffix: 'reloaded');
    final platform = Tim2ToxSdkPlatform(
      ffiService: reloadedService,
      conversationManagerProvider: _ConversationProvider(),
    );
    addTearDown(() async {
      platform.dispose();
      await reloadedService.dispose();
    });

    final result =
        await platform.getConversation(conversationID: _conversationID);

    expect(result.code, 0);
    expect(result.data?.draftText, 'restored after restart');
    expect(result.data?.draftTimestamp, saved.timestamp);
  });

  test('platform fails closed when no draft service is configured', () async {
    final service = createService(_accountA, null);
    final platform = Tim2ToxSdkPlatform(ffiService: service);
    addTearDown(() async {
      platform.dispose();
      await service.dispose();
    });

    final result = await platform.setConversationDraft(
      conversationID: _conversationID,
      draftText: 'cannot persist',
    );

    expect(result.code, isNot(0));
  });
}
