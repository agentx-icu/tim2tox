import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/binary_replacement_history_hook.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

import '../test_fixtures.dart';

const _peer =
    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

String _event(Object payload, {required int route}) {
  final json = payload is String ? payload : jsonEncode(payload);
  final encoded = <int>[route, ...utf8.encode(json)]
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'c2cbin:$_peer:$encoded';
}

String _actionEvent(String body) => 'c2caction:$_peer:$body';

String _groupActionEvent(String groupId, String body) =>
    'gaction:$groupId|$_peer:$body';

Future<void> _deleteTempDirectory(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

void main() {
  late Directory tempDir;
  late MessageHistoryPersistence persistence;
  late FfiChatService service;

  setUpAll(setupTestEnvironment);
  tearDownAll(teardownTestEnvironment);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('c2c_binary_event_');
    persistence = MessageHistoryPersistence(
      historyDirectory: '${tempDir.path}/history',
    );
    service = FfiChatService(
      preferencesService: MockPreferencesService(),
      loggerService: MockLoggerService(),
      bootstrapService: MockBootstrapService(),
      messageHistoryPersistence: persistence,
      queueFilePath: '${tempDir.path}/offline_queue.json',
    );
  });

  tearDown(() async {
    await BinaryReplacementHistoryHook.uninstallStandalone();
    await service.dispose();
    if (await tempDir.exists()) {
      await _deleteTempDirectory(tempDir);
    }
  });

  test('route 3 generic reaches Platform-only live and history pipelines',
      () async {
    final payload = <String, Object?>{
      'type': 'third-party',
      'text': 'visible custom',
    };
    final liveMessage = service.messages.first;

    expect(
      service.ingestC2cBinaryEvent(
        _event(payload, route: 3),
        sourceInstanceId: 42,
      ),
      isTrue,
    );

    final message = await liveMessage;
    expect(message.fromUserId, _peer);
    expect(message.mediaKind, 'custom');
    expect(message.text, jsonEncode(payload));
    expect(message.sourceInstanceId, 42);
    expect(service.getHistory(_peer), hasLength(1));
    expect(service.getHistory(_peer).single.msgID, message.msgID);
  });

  test('route 3 reaction-shaped JSON stays generic and cannot execute control',
      () async {
    final payload = <String, Object?>{
      'type': 'reaction',
      'msgID': 'target',
      'reactionID': 'wave',
      'action': 'add',
      'sender': _peer,
    };
    final liveMessage = service.messages.first;
    final reactions = <Object>[];
    final reactionSubscription = service.reactionEvents.listen(reactions.add);

    expect(
      service.ingestC2cBinaryEvent(_event(payload, route: 3)),
      isTrue,
    );

    final message = await liveMessage;
    expect(message.mediaKind, 'custom');
    expect(message.text, jsonEncode(payload));
    expect(service.getHistory(_peer), hasLength(1));
    expect(reactions, isEmpty);
    await reactionSubscription.cancel();
  });

  test('route 2 exact reaction emits only control event and creates no row',
      () async {
    final liveMessages = <ChatMessage>[];
    final subscription = service.messages.listen(liveMessages.add);
    final reactionEvent = service.reactionEvents.first;

    expect(
      service.ingestC2cBinaryEvent(
        _event(<String, Object?>{
          'type': 'reaction',
          'msgID': 'm-reaction',
          'reactionID': 'wave',
          'action': 'add',
          'sender': _peer,
        }, route: 2),
      ),
      isTrue,
    );

    final reaction = await reactionEvent;
    expect(reaction.msgID, 'm-reaction');
    expect(reaction.reactionID, 'wave');
    expect(reaction.action, 'add');
    expect(reaction.sender, _peer);
    expect(reaction.groupID, isNull);
    expect(service.getHistory(_peer), isEmpty);
    expect(service.lastMessages, isEmpty);
    expect(liveMessages, isEmpty);
    await subscription.cancel();
  });

  test('route 1 exact receipt updates target without creating control row',
      () async {
    final original = ChatMessage(
      text: 'original message',
      fromUserId: 'self',
      isSelf: true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1),
      msgID: 'm-receipt',
    );
    await persistence.appendHistory(_peer, original);
    final liveUpdate = service.messages.first;

    expect(
      service.ingestC2cBinaryEvent(
        _event(<String, Object?>{
          'type': 'receipt',
          'msgID': 'm-receipt',
          'receiptType': 'received',
          'sender': _peer,
        }, route: 1),
      ),
      isTrue,
    );

    final updated = await liveUpdate;
    expect(updated.msgID, original.msgID);
    expect(updated.text, original.text);
    expect(updated.isReceived, isTrue);
    expect(service.getHistory(_peer), hasLength(1));
    expect(service.getHistory(_peer).single.text, original.text);
    expect(service.getHistory(_peer).single.isReceived, isTrue);
  });

  test('route 0 accepts an exact legacy receipt control', () async {
    final original = ChatMessage(
      text: 'legacy target',
      fromUserId: 'self',
      isSelf: true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1),
      msgID: 'legacy-receipt',
    );
    await persistence.appendHistory(_peer, original);
    final liveUpdate = service.messages.first;

    expect(
      service.ingestC2cBinaryEvent(
        _event(<String, Object?>{
          'type': 'receipt',
          'msgID': 'legacy-receipt',
          'receiptType': 'read',
          'sender': _peer,
        }, route: 0),
      ),
      isTrue,
    );

    final updated = await liveUpdate;
    expect(updated.isReceived, isTrue);
    expect(updated.isRead, isTrue);
    expect(service.getHistory(_peer), hasLength(1));
  });

  test('route 0 accepts an exact legacy reaction control', () async {
    final reactionEvent = service.reactionEvents.first.timeout(
      const Duration(milliseconds: 100),
    );

    expect(
      service.ingestC2cBinaryEvent(
        _event(<String, Object?>{
          'type': 'reaction',
          'msgID': 'legacy-reaction',
          'reactionID': 'wave',
          'action': 'remove',
          'sender': _peer,
        }, route: 0),
      ),
      isTrue,
    );

    final reaction = await reactionEvent;
    expect(reaction.msgID, 'legacy-reaction');
    expect(reaction.reactionID, 'wave');
    expect(reaction.action, 'remove');
    expect(reaction.sender, _peer);
    expect(service.getHistory(_peer), isEmpty);
  });

  test('route 0 ordinary ACTION succeeds as an advanced-owned no-op', () async {
    final liveMessages = <ChatMessage>[];
    final subscription = service.messages.listen(liveMessages.add);

    expect(
      service.ingestC2cBinaryEvent(
        _event(<String, Object?>{
          'type': 'third-party',
          'text': 'advanced owns this payload',
        }, route: 0),
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(service.getHistory(_peer), isEmpty);
    expect(service.lastMessages, isEmpty);
    expect(liveMessages, isEmpty);
    await subscription.cancel();
  });

  test('ordinary C2C ACTION force-emits with its polling instance', () async {
    final liveMessages = <ChatMessage>[];
    final subscription = service.messages.listen(liveMessages.add);
    final advancedListener = V2TimAdvancedMsgListener();
    TIMMessageManager.instance.addAdvancedMsgListener(advancedListener);

    try {
      expect(
        service.ingestActionEvent(
          _actionEvent('waves'),
          sourceInstanceId: 42,
        ),
        isTrue,
      );
      expect(
        service.ingestActionEvent(
          _actionEvent('waves'),
          sourceInstanceId: 42,
        ),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);

      expect(service.getHistory(_peer), hasLength(1));
      expect(
        service.getHistory(_peer).single.contentKind,
        ChatMessageContentKind.action,
      );
      expect(liveMessages, hasLength(1));
      expect(liveMessages.single.sourceInstanceId, 42);
    } finally {
      TIMMessageManager.instance.removeAdvancedMsgListener(
        listener: advancedListener,
      );
      await subscription.cancel();
    }
  });

  test('ordinary group ACTION materializes once with action content kind',
      () async {
    const groupId = 'qtox-action-group';
    final liveMessages = <ChatMessage>[];
    final subscription = service.messages.listen(liveMessages.add);

    expect(
      service.ingestActionEvent(_groupActionEvent(groupId, 'applauds')),
      isTrue,
    );
    expect(
      service.ingestActionEvent(_groupActionEvent(groupId, 'applauds')),
      isFalse,
    );
    await Future<void>.delayed(Duration.zero);

    expect(service.getHistory(groupId), hasLength(1));
    expect(
      service.getHistory(groupId).single.contentKind,
      ChatMessageContentKind.action,
    );
    expect(liveMessages, hasLength(1));
    await subscription.cancel();
  });

  test('exact legacy ACTION control is consumed only when target exists',
      () async {
    final original = ChatMessage(
      text: 'target',
      fromUserId: 'self',
      isSelf: true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1),
      msgID: 'legacy-action-target',
    );
    await persistence.appendHistory(_peer, original);
    final liveUpdate = service.messages.first;
    final receipt = jsonEncode(<String, Object?>{
      'type': 'receipt',
      'msgID': original.msgID,
      'receiptType': 'read',
      'sender': _peer,
    });

    expect(service.ingestActionEvent(_actionEvent(receipt)), isTrue);
    final updated = await liveUpdate;
    expect(updated.isRead, isTrue);
    expect(service.getHistory(_peer), hasLength(1));
  });

  test('group ACTION control uses event group and emits no visible message',
      () async {
    const groupId = 'legacy-action-group';
    final original = ChatMessage(
      text: 'group target',
      fromUserId: 'self',
      isSelf: true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1),
      groupId: groupId,
      msgID: 'legacy-group-target',
    );
    await persistence.appendHistory(groupId, original);
    final liveMessages = <ChatMessage>[];
    final messageSubscription = service.messages.listen(liveMessages.add);
    final reactionEvent = service.reactionEvents.first;
    final reaction = jsonEncode(<String, Object?>{
      'type': 'reaction',
      'msgID': original.msgID,
      'reactionID': 'wave',
      'action': 'add',
      'sender': _peer,
    });

    expect(
      service.ingestActionEvent(_groupActionEvent(groupId, reaction)),
      isTrue,
    );
    final emittedReaction = await reactionEvent;
    await Future<void>.delayed(Duration.zero);

    expect(emittedReaction.groupID, groupId);
    expect(service.getHistory(groupId), hasLength(1));
    expect(liveMessages, isEmpty);
    await messageSubscription.cancel();
  });

  test('exact-looking ACTION control with absent target stays visible',
      () async {
    final reaction = jsonEncode(<String, Object?>{
      'type': 'reaction',
      'msgID': 'missing-target',
      'reactionID': 'wave',
      'action': 'add',
      'sender': _peer,
    });
    final reactions = <Object>[];
    final subscription = service.reactionEvents.listen(reactions.add);

    expect(service.ingestActionEvent(_actionEvent(reaction)), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(reactions, isEmpty);
    expect(service.getHistory(_peer), hasLength(1));
    expect(service.getHistory(_peer).single.text, reaction);
    expect(
      service.getHistory(_peer).single.contentKind,
      ChatMessageContentKind.action,
    );
    await subscription.cancel();
  });

  test('route 3 is ignored when binary replacement owns inbound history',
      () async {
    BinaryReplacementHistoryHook.initialize(persistence, 'self');
    expect(BinaryReplacementHistoryHook.ownsInboundMessageHistory, isTrue);
    final liveMessages = <ChatMessage>[];
    final subscription = service.messages.listen(liveMessages.add);

    expect(
      service.ingestC2cBinaryEvent(
        _event(<String, Object?>{
          'type': 'third-party',
          'text': 'advanced already delivered this',
        }, route: 3),
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(service.getHistory(_peer), isEmpty);
    expect(service.lastMessages, isEmpty);
    expect(liveMessages, isEmpty);
    await subscription.cancel();
  });

  group('typed controls fail closed', () {
    final cases = <String, ({int route, Object payload})>{
      'route mismatch': (
        route: 1,
        payload: <String, Object?>{
          'type': 'reaction',
          'msgID': 'm',
          'reactionID': 'wave',
          'action': 'add',
          'sender': _peer,
        },
      ),
      'sender mismatch': (
        route: 2,
        payload: <String, Object?>{
          'type': 'reaction',
          'msgID': 'm',
          'reactionID': 'wave',
          'action': 'add',
          'sender': 'not-the-envelope-sender',
        },
      ),
      'extra keys': (
        route: 1,
        payload: <String, Object?>{
          'type': 'receipt',
          'msgID': 'm',
          'receiptType': 'read',
          'sender': _peer,
          'text': 'must not become content',
        },
      ),
      'empty required field': (
        route: 2,
        payload: <String, Object?>{
          'type': 'reaction',
          'msgID': 'm',
          'reactionID': '',
          'action': 'add',
          'sender': _peer,
        },
      ),
      'unknown control value': (
        route: 1,
        payload: <String, Object?>{
          'type': 'receipt',
          'msgID': 'm',
          'receiptType': 'displayed',
          'sender': _peer,
        },
      ),
      'malformed JSON': (route: 2, payload: '{not-json'),
    };

    for (final entry in cases.entries) {
      test('${entry.key} creates no row or control event', () async {
        final liveMessages = <ChatMessage>[];
        final reactions = <Object>[];
        final messageSubscription = service.messages.listen(liveMessages.add);
        final reactionSubscription =
            service.reactionEvents.listen(reactions.add);

        expect(
          service.ingestC2cBinaryEvent(
            _event(entry.value.payload, route: entry.value.route),
          ),
          isFalse,
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.getHistory(_peer), isEmpty);
        expect(service.lastMessages, isEmpty);
        expect(liveMessages, isEmpty);
        expect(reactions, isEmpty);
        await messageSubscription.cancel();
        await reactionSubscription.cancel();
      });
    }
  });
}
