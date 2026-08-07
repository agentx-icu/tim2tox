import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

void main() {
  test('decodes instance-safe group custom binary events', () {
    final event = FfiChatService.parseGroupCustomBinaryEvent(
      'gcustombin:tox_group_0|${'a' * 64}:7b2274797065223a226f6b227d',
    );

    expect(event?.groupId, 'tox_group_0');
    expect(event?.sender, 'a' * 64);
    expect(event?.payload, '{"type":"ok"}');
  });

  test('rejects malformed group custom binary events', () {
    expect(
      FfiChatService.parseGroupCustomBinaryEvent(
        'gcustombin:tox_group_0|not-a-key:00',
      ),
      isNull,
    );
  });
}
