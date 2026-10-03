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
}
