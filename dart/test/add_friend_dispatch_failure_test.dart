import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

/// `tim2tox_ffi_add_friend` throwing at dispatch (e.g. a lazy symbol lookup
/// failing in an older library).
class _ThrowingAddFriendFfi extends Tim2ToxFfi {
  _ThrowingAddFriendFfi() : super.forTesting();

  @override
  int Function(ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)
      get addFriend => (_, __) => throw ArgumentError('symbol not found');

  @override
  int Function() get getCurrentInstanceId => () => 0;

  @override
  void Function() get uninit => () {};
}

void main() {
  test('a throwing dispatch frees its buffers once and reports failure',
      () async {
    final dir = await Directory.systemTemp.createTemp('tim2tox_add_friend_');
    final service = FfiChatService(
      ffiForTesting: _ThrowingAddFriendFfi(),
      historyDirectory: p.join(dir.path, 'history'),
      queueFilePath: p.join(dir.path, 'queue.json'),
    );
    try {
      // The catch block used to free both native strings and then the
      // finally block freed them again: a double free (allocator abort).
      final result = await service.addFriend('A' * 76, requestMessage: 'CQ');
      expect(result.dispatched, isFalse);
      expect(result.isSuccess, isFalse);
      expect(result.resultInfo, contains('dispatch threw'));
    } finally {
      await service.dispose();
      await dir.delete(recursive: true);
    }
  });
}
