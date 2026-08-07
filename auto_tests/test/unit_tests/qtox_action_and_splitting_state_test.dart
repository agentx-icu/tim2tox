// Model/service contracts for qTox ACTION and fragmented NORMAL sends.
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_text_elem.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform_converters.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/binary_replacement_history_hook.dart';
import 'package:tim2tox_dart/utils/message_converter.dart';

import '../test_fixtures.dart';

const String _peerId =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const String _groupId = 'qtox_fragment_failure_group';

String _longQtoxText() => '${'a' * 1300}\n${'b' * 10} ${'🙂' * 400}';

void main() {
  setUpAll(setupNativeLibraryForTim2Tox);

  group('qTox logical message state', () {
    late Directory root;
    late FfiChatService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('qtox_state_red_');
      service = FfiChatService(
        historyDirectory: path.join(root.path, 'history'),
        queueFilePath: path.join(root.path, 'offline_queue.json'),
        fileRecvPath: path.join(root.path, 'file_recv'),
        avatarsPath: path.join(root.path, 'avatars'),
      );
    });

    tearDown(() async {
      await BinaryReplacementHistoryHook.uninstallStandalone();
      await service.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('ACTION content kind survives JSON and copyWith', () {
      final action = ChatMessage.fromJson(<String, dynamic>{
        'text': 'waves',
        'fromUserId': _peerId,
        'isSelf': false,
        'timestamp': DateTime.utc(2026, 7, 29).toIso8601String(),
        'groupId': null,
        'filePath': null,
        'fileName': null,
        'mediaKind': null,
        'contentKind': 'action',
        'isPending': false,
        'isReceived': true,
        'isRead': false,
        'msgID': 'qtox-action-root',
      });

      expect(action.contentKind, ChatMessageContentKind.action);
      expect(action.toJson()['contentKind'], 'action');
      expect(
        action.copyWith(isRead: true).contentKind,
        ChatMessageContentKind.action,
      );
      expect(
        ChatMessage.fromJson(<String, dynamic>{
          ...action.toJson(),
          'contentKind': 'future-value',
        }).contentKind,
        ChatMessageContentKind.normal,
      );
      final legacy = Map<String, dynamic>.from(action.toJson())
        ..remove('contentKind');
      expect(
        ChatMessage.fromJson(legacy).contentKind,
        ChatMessageContentKind.normal,
      );
    });

    test('ACTION source instance survives copy but is never serialized', () {
      final action = ChatMessage(
        text: 'waves',
        fromUserId: _peerId,
        isSelf: false,
        timestamp: DateTime.utc(2026, 7, 29),
        msgID: 'routed-action',
        contentKind: ChatMessageContentKind.action,
        sourceInstanceId: 42,
      );

      expect(action.copyWith(isRead: true).sourceInstanceId, 42);
      expect(action.toJson(), isNot(contains('sourceInstanceId')));
      expect(ChatMessage.fromJson(action.toJson()).sourceInstanceId, isNull);
    });

    test('ACTION converts to text with only the local content-kind marker', () {
      const body = 'waves';
      final action = ChatMessage(
        text: body,
        fromUserId: _peerId,
        isSelf: false,
        timestamp: DateTime.utc(2026, 7, 29),
        msgID: 'action-conversion',
        contentKind: ChatMessageContentKind.action,
      );
      final platform = Tim2ToxSdkPlatform(ffiService: service);
      addTearDown(platform.dispose);

      final converted = platform.chatMessageToV2TimMessage(action, 'self');

      expect(converted.elemType, MessageElemType.V2TIM_ELEM_TYPE_TEXT);
      expect(converted.textElem?.text, body);
      expect(converted.customElem, isNull);
      expect(converted.cloudCustomData, isNull);
      expect(
        converted.localCustomData,
        '{"tim2toxContentKind":"action"}',
      );
      expect(
        mergeChatMessageContentKindLocalCustomData(
          '{"draft":true}',
          ChatMessageContentKind.action,
        ),
        '{"draft":true,"tim2toxContentKind":"action"}',
      );

      final inbound = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_TEXT,
        textElem: V2TimTextElem(text: body),
        localCustomData: '{"draft":true,"tim2toxContentKind":"action"}',
      )
        ..sender = _peerId
        ..msgID = 'inbound-action';
      expect(
        MessageConverter.v2TimMessageToChatMessage(inbound, 'self').contentKind,
        ChatMessageContentKind.action,
      );
    });

    test('binary hook swallows exact ACTION control only for existing target',
        () async {
      final persistence = service.messageHistoryPersistence;
      final target = ChatMessage(
        text: 'target',
        fromUserId: 'SELF',
        isSelf: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1),
        msgID: 'known-action-target',
      );
      await persistence.appendHistory(_peerId, target);
      BinaryReplacementHistoryHook.initialize(persistence, 'SELF');
      final actionControl = V2TimMessage(
        elemType: MessageElemType.V2TIM_ELEM_TYPE_TEXT,
        textElem: V2TimTextElem(
          text: '{"type":"receipt","msgID":"known-action-target",'
              '"receiptType":"read","sender":"$_peerId"}',
        ),
        localCustomData: '{"tim2toxContentKind":"action"}',
      )
        ..sender = _peerId
        ..userID = _peerId
        ..msgID = 'action-control-wrapper';

      await BinaryReplacementHistoryHook.saveMessage(actionControl);

      expect(persistence.getHistory(_peerId), hasLength(1));
      expect(persistence.getHistory(_peerId).single.msgID, target.msgID);
    });

    test('case-insensitive /me send stores stripped pending ACTION', () async {
      final message = await service.sendTextWithResult(
        _peerId,
        '/Me waves offline',
        clientMessageID: 'offline-action',
      );

      expect(message.text, 'waves offline');
      expect(message.contentKind, ChatMessageContentKind.action);
      expect(message.isPending, isTrue);
      final queued =
          service.offlineMessageQueuePersistence.getMessages(_peerId);
      expect(queued, hasLength(1));
      expect(queued.single.text, 'waves offline');
      expect(queued.single.contentKind, ChatMessageContentKind.action);
    });

    test('/me without a space stays NORMAL and empty ACTION is rejected',
        () async {
      final normal = await service.sendTextWithResult(
        _peerId,
        '/me',
        clientMessageID: 'literal-me',
      );
      expect(normal.text, '/me');
      expect(normal.contentKind, ChatMessageContentKind.normal);

      await expectLater(
        service.sendTextWithResult(_peerId, '/mE '),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        service.sendTextWithResult(_peerId, '/me bad\u0000action'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'long C2C send stores one caller-visible root, never fragment rows',
      () async {
        final emitted = <ChatMessage>[];
        final subscription = service.messages.listen(emitted.add);
        addTearDown(subscription.cancel);

        final rootMessage = await service.sendTextWithResult(
          _peerId,
          _longQtoxText(),
          clientMessageID: 'qtox-c2c-root',
        );
        await Future<void>.delayed(Duration.zero);

        expect(rootMessage.msgID, 'qtox-c2c-root');
        expect(rootMessage.text, _longQtoxText());
        expect(rootMessage.isPending, isTrue);
        expect(service.getHistory(_peerId), hasLength(1));
        expect(service.getHistory(_peerId).single.msgID, 'qtox-c2c-root');
        expect(emitted, hasLength(1));
        expect(emitted.single.msgID, 'qtox-c2c-root');
      },
    );

    test(
      'native fragment failure leaves exactly one pending logical root',
      () async {
        final rootMessage = await service.sendGroupTextWithResult(
          _groupId,
          _longQtoxText(),
          clientMessageID: 'qtox-failed-root',
        );
        expect(rootMessage.isPending, isTrue);

        // No native group exists in this unit process. Once connected, retrying
        // exercises the real native fragmented sender's failure path.
        service.debugSetConnected(true);
        await service.retryPendingGroupMessages(_groupId);

        final history = service.getHistory(_groupId);
        expect(history, hasLength(1));
        expect(history.single.msgID, 'qtox-failed-root');
        expect(history.single.text, _longQtoxText());
        expect(
          history.single.isPending,
          isTrue,
          reason:
              'a failed fragment keeps the one logical root retryable; fragments are transport-only',
        );
      },
    );
  });
}
