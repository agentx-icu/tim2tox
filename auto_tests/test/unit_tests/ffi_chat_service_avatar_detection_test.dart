import 'package:test/test.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

void main() {
  group('FfiChatService qTox avatar request parser', () {
    test('accepts only the explicit instance-scoped wire envelope', () {
      const sender =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const fileId =
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

      final parsed = FfiChatService.parseAvatarRequestEvent(
        'avatar_request:42:$sender:7:65536:$fileId',
      );

      expect(parsed, isNotNull);
      expect(parsed?.instanceId, 42);
      expect(parsed?.sender, sender);
      expect(parsed?.fileNumber, 7);
      expect(parsed?.size, 65536);
      expect(parsed?.fileId, fileId);
    });

    test('rejects malformed sender, size, and file id fields', () {
      const sender =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const fileId =
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

      expect(
        FfiChatService.parseAvatarRequestEvent(
          'avatar_request:42:short:7:12:$fileId',
        ),
        isNull,
      );
      expect(
        FfiChatService.parseAvatarRequestEvent(
          'avatar_request:42:$sender:7:-1:$fileId',
        ),
        isNull,
      );
      expect(
        FfiChatService.parseAvatarRequestEvent(
          'avatar_request:42:$sender:7:12:short',
        ),
        isNull,
      );
    });

    test('uses the inclusive qTox 65,536 byte receive limit', () {
      expect(FfiChatService.isAvatarAutoAcceptSizeAllowed(-1), isFalse);
      expect(FfiChatService.isAvatarAutoAcceptSizeAllowed(0), isTrue);
      expect(FfiChatService.isAvatarAutoAcceptSizeAllowed(65536), isTrue);
      expect(FfiChatService.isAvatarAutoAcceptSizeAllowed(65537), isFalse);
    });
  });
}
