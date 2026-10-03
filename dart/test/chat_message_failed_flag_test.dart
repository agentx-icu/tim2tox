import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';

void main() {
  final DateTime at = DateTime.utc(2026, 10, 3);

  ChatMessage row({bool failed = false}) => ChatMessage(
        text: 'CQ',
        fromUserId: 'me',
        isSelf: true,
        timestamp: at,
        msgID: 'm1',
        isFailed: failed,
      );

  test('isFailed round-trips through JSON', () {
    final restored = ChatMessage.fromJson(row(failed: true).toJson());
    expect(restored.isFailed, isTrue);
    expect(restored.isPending, isFalse);
  });

  test('rows that never failed serialize exactly as before', () {
    expect(row().toJson().containsKey('isFailed'), isFalse);
    final legacy = row().toJson()..remove('isFailed');
    expect(ChatMessage.fromJson(legacy).isFailed, isFalse);
  });

  test('copyWith keeps or sets the flag', () {
    final failed = row().copyWith(isPending: false, isFailed: true);
    expect(failed.isFailed, isTrue);
    expect(failed.copyWith(isRead: true).isFailed, isTrue);
  });

  // The conversions below need a live platform / native session; their
  // contracts are pinned on the source like the other wire tests here.
  final String converters =
      File('lib/sdk/tim2tox_sdk_platform_converters.dart').readAsStringSync();
  final String service =
      File('lib/service/ffi_chat_service.dart').readAsStringSync();
  final String persistence =
      File('lib/utils/message_history_persistence.dart').readAsStringSync();

  test('every ChatMessage -> V2TIM status mapping reports failures', () {
    final failBranches = RegExp(
      r'else if \(chatMsg\.isSelf && chatMsg\.isFailed\) \{\s*'
      r'//[^\n]*\n\s*msg\.status = MessageStatus\.V2TIM_MSG_STATUS_SEND_FAIL;',
    ).allMatches(converters).length;
    final statusBranches =
        RegExp(r'if \(chatMsg\.isPending\) \{').allMatches(converters).length;
    expect(failBranches, statusBranches);
    expect(failBranches, greaterThan(0));
  });

  test('a SEND_FAIL own V2TIM message converts back to isFailed', () {
    final String reverse =
        File('lib/utils/message_converter.dart').readAsStringSync();
    expect(
      reverse,
      contains('isFailed: isSelf &&\n'
          '          v2Msg.status == MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL,'),
    );
  });

  test('a queued row restored after a restart can still be marked failed', () {
    final mark = service.substring(
      service.indexOf('void _markPendingItemFailed('),
      service.indexOf('Future<void> _loadOfflineQueue()'),
    );
    expect(mark, contains('if (!msg.isSelf || msg.isFailed) continue;'));
    expect(mark, contains('msg.msgID != item.msgID'));
    expect(mark, contains('copyWith(isPending: false, isFailed: true)'));
  });

  test('both history merge paths keep a failure', () {
    expect(persistence,
        contains('isFailed: updated.isFailed || existing.isFailed'));
    final prefer = persistence.substring(
      persistence.indexOf('static ChatMessage _preferLoadedCopy('),
    );
    expect(prefer, contains('final isFailed = existing.isFailed || msg.isFailed;'));
    expect(prefer, contains('isFailed: isFailed,'));
  });

  test('a sent item whose queue removal fails is never marked failed', () {
    // C2C: `sent` flips before the durable removal; the catch honours it.
    expect(service, contains('sent = true;\n          await _offlineQueuePersistence.removeItem(storageKey, item);'));
    // Group: set right after the native send.
    expect(service, contains('_sendGroupTextByKindChecked(groupId, item.text, item.contentKind);\n        sent = true;'));
    expect(
      RegExp(r'if \(sent\) \{').allMatches(service).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('a row with delivery evidence is never marked failed', () {
    final mark = service.substring(
      service.indexOf('void _markPendingItemFailed('),
      service.indexOf('Future<void> _loadOfflineQueue()'),
    );
    expect(mark, contains('msg.isReceived ||'));
    expect(mark, contains('msg.isRead'));
  });

  test('a later successful replay clears an earlier failure', () {
    expect(service, contains('existing.copyWith(isPending: false, isFailed: false)'));
    expect(service, contains('(msg.isPending || msg.isFailed) &&\n            msg.filePath == filePath'));
    expect(service, contains('history[i] = msg.copyWith(isPending: false, isFailed: false);'));
  });

  test('a duplicate carrying a failure keeps it on the absorbed row', () {
    expect(persistence, contains('isFailed: current.isFailed || duplicate.isFailed'));
  });

  test('queued failures are recorded for SDK resend', () {
    final platform =
        File('lib/sdk/tim2tox_sdk_platform.dart').readAsStringSync();
    expect(platform, contains('if (chatMsg.isSelf && chatMsg.isFailed) {'));
    expect(platform, contains('_persistFinalizedFailedMessage('));
  });
}
