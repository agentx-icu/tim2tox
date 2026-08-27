// Guards the needReadReceipt field's serialization contract: the flag must
// survive a toJson/fromJson round trip (cold-reload path through
// MessageHistoryPersistence), and a message WITHOUT the flag must serialize
// byte-identically to the pre-field format so existing on-disk history rows
// are untouched (same gating convention as cloudCustomData).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';

void main() {
  ChatMessage build({bool needReadReceipt = false}) => ChatMessage(
        text: 'hello',
        fromUserId: 'SELF',
        isSelf: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        groupId: 'g1',
        msgID: 'm_1',
        needReadReceipt: needReadReceipt,
      );

  test('flag survives a json round trip', () {
    final restored = ChatMessage.fromJson(
      jsonDecode(jsonEncode(build(needReadReceipt: true).toJson()))
          as Map<String, dynamic>,
    );
    expect(restored.needReadReceipt, isTrue);
  });

  test('absent flag round-trips false (legacy rows)', () {
    final json = build().toJson();
    expect(json.containsKey('needReadReceipt'), isFalse,
        reason: 'gated key: plain rows must serialize byte-identically');
    final restored = ChatMessage.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(restored.needReadReceipt, isFalse);
  });

  test('copyWith preserves and overrides the flag', () {
    final on = build(needReadReceipt: true);
    expect(on.copyWith(isRead: true).needReadReceipt, isTrue);
    expect(on.copyWith(needReadReceipt: false).needReadReceipt, isFalse);
  });
}
