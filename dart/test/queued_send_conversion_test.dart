// How a queued send's state crosses the V2TIM boundary.
//
// A cancelled send is LOCAL_REVOKED plus a namespaced localCustomData marker,
// and only that pair converts back to isCancelled. On our own message the
// reverse conversion takes delivery and read from the PEER (isPeerRead):
// SEND_SUCC only says it left, and treating it as delivery would let any
// converted copy outrank a genuine failure when history merges the copies.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_status.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_text_elem.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/utils/message_converter.dart';

const _self = 'SELF';

V2TimMessage _own({required int status, String? localCustomData, bool? peerRead}) =>
    // fromJson: the plain constructor asks the native SDK for the server time.
    V2TimMessage.fromJson({
      'message_sender': _self,
      'message_server_time': 1760000000,
    })
      ..elemType = MessageElemType.V2TIM_ELEM_TYPE_TEXT
      ..msgID = 'm1'
      ..textElem = V2TimTextElem(text: 'hello')
      ..isSelf = true
      ..status = status
      ..isPeerRead = peerRead
      ..localCustomData = localCustomData;

void main() {
  test('only LOCAL_REVOKED with the marker is a cancelled send', () {
    final marker = mergeIntoLocalCustomData(
        null, {queuedCancelledLocalCustomDataKey: true});
    expect(
        MessageConverter.v2TimMessageToChatMessage(
                _own(
                    status: MessageStatus.V2TIM_MSG_STATUS_LOCAL_REVOKED,
                    localCustomData: marker),
                _self)
            .isCancelled,
        isTrue);
    expect(
        MessageConverter.v2TimMessageToChatMessage(
                _own(status: MessageStatus.V2TIM_MSG_STATUS_LOCAL_REVOKED),
                _self)
            .isCancelled,
        isFalse);
    expect(
        MessageConverter.v2TimMessageToChatMessage(
                _own(
                    status: MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC,
                    localCustomData: marker),
                _self)
            .isCancelled,
        isFalse);
  });

  test('an own SEND_SUCC copy carries no delivery without a peer receipt', () {
    final sent = MessageConverter.v2TimMessageToChatMessage(
        _own(status: MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC), _self);
    expect(sent.isReceived, isFalse);
    expect(sent.isRead, isFalse);
    final read = MessageConverter.v2TimMessageToChatMessage(
        _own(status: MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC, peerRead: true),
        _self);
    expect(read.isReceived, isTrue);
    expect(read.isRead, isTrue);
  });

  test('the marker merges into existing localCustomData, never replacing it',
      () {
    final existing = jsonEncode({toxGroupMsgIdLocalCustomDataKey: 7});
    final merged = mergeIntoLocalCustomData(
        existing, {queuedCancelledLocalCustomDataKey: true})!;
    expect(toxGroupMsgIdFromLocalCustomData(merged), 7);
    expect(queuedCancelledFromLocalCustomData(merged), isTrue);
    expect(mergeIntoLocalCustomData('plain', {'k': 1}), 'plain');
  });

  test('every forward branch maps a cancelled row before pending / failed',
      () {
    final converters = File('lib/sdk/tim2tox_sdk_platform_converters.dart')
        .readAsStringSync();
    expect(
      RegExp(r'if \(chatMsg\.isSelf && chatMsg\.isCancelled\) \{\s*\n'
              r'\s*// .*\n'
              r'\s*msg\.status = MessageStatus\.V2TIM_MSG_STATUS_LOCAL_REVOKED;\s*\n'
              r'\s*msg\.localCustomData = mergeIntoLocalCustomData\(')
          .allMatches(converters)
          .length,
      3,
    );
    final platform =
        File('lib/sdk/tim2tox_sdk_platform.dart').readAsStringSync();
    expect(platform,
        contains('mergeIntoLocalCustomData(existing, customData);'),
        reason: 'the forward-target stamp keeps the marker');
  });
}
