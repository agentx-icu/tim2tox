import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _sendAvatarSignature = 'int tim2tox_ffi_send_avatar(';
const _deleteAvatarSignature = 'int tim2tox_ffi_delete_avatar(';

File _tim2ToxFile(String packageRelativePath) {
  final candidates = <String>[
    packageRelativePath,
    'third_party/tim2tox/dart/$packageRelativePath',
  ];
  if (packageRelativePath.startsWith('../')) {
    candidates.add(
      'third_party/tim2tox/${packageRelativePath.substring(3)}',
    );
  }
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) return file;
  }
  throw StateError('Tim2Tox test source was not found.');
}

void main() {
  late String nativeSource;
  late String bindingSource;
  late String serviceSource;

  setUpAll(() {
    nativeSource = _tim2ToxFile('../ffi/tim2tox_ffi.cpp').readAsStringSync();
    bindingSource = _tim2ToxFile('lib/ffi/tim2tox_ffi.dart').readAsStringSync();
    serviceSource =
        _tim2ToxFile('lib/service/ffi_chat_service.dart').readAsStringSync();
  });

  test('declares the explicit qTox avatar C FFI seam', () {
    final compile = _compileAvatarCallSite();
    expect(
      compile.exitCode,
      0,
      reason: 'Avatar traffic needs an explicit high-level C FFI API; the '
          'generic file API cannot express qTox avatar metadata.\n'
          '${compile.stderr}',
    );
  });

  test('binds the exact qTox avatar ABI and exposes owned-buffer wrappers', () {
    expect(
      bindingSource,
      matches(
        RegExp(
          r'typedef _send_avatar_c = ffi\.Int32 Function\(\s*ffi\.Int64,\s*ffi\.Pointer<pkgffi\.Utf8>,\s*ffi\.Pointer<ffi\.Uint8>,\s*ffi\.Size,?\s*\);',
        ),
      ),
    );
    expect(
      bindingSource,
      matches(
        RegExp(
          r'typedef _delete_avatar_c = ffi\.Int32 Function\(\s*ffi\.Int64,\s*ffi\.Pointer<pkgffi\.Utf8>,?\s*\);',
        ),
      ),
    );
    expect(bindingSource, contains('sendAvatarNative = _lib.lookupFunction<'));
    expect(bindingSource, contains("'tim2tox_ffi_send_avatar'"));
    expect(
      bindingSource,
      matches(RegExp(r'deleteAvatarNative\s*=\s*_lib\.lookupFunction<')),
    );
    expect(bindingSource, contains("'tim2tox_ffi_delete_avatar'"));

    final sendWrapper = _functionBody(
      bindingSource,
      'int sendAvatar(',
    );
    expect(sendWrapper, contains('pkgffi.malloc<ffi.Uint8>'));
    expect(sendWrapper, contains('.asTypedList('));
    expect(sendWrapper, contains('sendAvatarNative('));
    expect(sendWrapper, contains('pkgffi.malloc.free('));

    final deleteWrapper = _functionBody(
      bindingSource,
      'int deleteAvatar(',
    );
    expect(deleteWrapper, contains('deleteAvatarNative('));
    expect(deleteWrapper, contains('pkgffi.malloc.free('));
  });

  test('reports the avatar receive limit in MiB', () {
    final body = _functionBody(
      bindingSource,
      'static String? fileControlErrorMessage(',
    );

    expect(body, contains('10 MiB'));
    expect(body, isNot(contains('64 KiB')));
  });

  test('accepts 10 MiB and rejects only larger avatars', () {
    final body = _functionBody(nativeSource, _sendAvatarSignature);

    expect(
      nativeSource,
      contains('kAvatarMaxBytes = 10ULL * 1024ULL * 1024ULL'),
    );
    expect(
      body,
      contains('if (avatar_size > kAvatarMaxBytes)'),
      reason: 'The qTox-compatible maximum is inclusive at 10 MiB.',
    );
    expect(
      body,
      contains('return -8;'),
      reason:
          'Oversize rejection must be distinguishable before tox_file_send.',
    );
    expect(
      RegExp(r'return -8;').allMatches(body),
      hasLength(1),
      reason: '-8 is reserved exclusively for the oversize guard.',
    );
    expect(
      body,
      matches(
        RegExp(
          r'if \(avatar_data == nullptr \|\| avatar_size == 0\)[\s\S]*?return -1;',
        ),
      ),
      reason: 'Null data and zero-size sends remain invalid; deletion is '
          'a separate API.',
    );
  });

  test('set and update use raw SHA-256 file_id and lowercase hex filename', () {
    final body = _functionBody(nativeSource, _sendAvatarSignature);

    expect(
      body,
      contains('std::array<uint8_t, TOX_HASH_LENGTH> file_id{}'),
    );
    expect(
      body,
      matches(
        RegExp(
          r'tox_hash\(file_id\.data\(\),\s*context->memory\.data\(\),\s*context->memory\.size\(\)\)',
        ),
      ),
      reason: 'The identifier must be SHA-256 of the exact avatar bytes.',
    );
    expect(
      body,
      contains('LowerHex(file_id.data(), file_id.size())'),
      reason: 'The qTox wire filename is the lowercase 64-hex digest.',
    );
    expect(
      nativeSource,
      contains('static constexpr char kHexDigits[] = "0123456789abcdef"'),
      reason: 'The 32-byte digest must expand to lowercase hexadecimal.',
    );
    expect(
      body,
      matches(
        RegExp(
          r'tox_file_send\([\s\S]*?TOX_FILE_KIND_AVATAR[\s\S]*?file_id\.data\(\)[\s\S]*?wire_name\.data\(\)[\s\S]*?wire_name\.size\(\)',
        ),
      ),
      reason: 'toxcore receives the raw 32-byte file_id and a separate '
          'lowercase hex filename.',
    );
  });

  test('same-hash offers remain observable to the receiver', () {
    final body = _functionBody(nativeSource, _sendAvatarSignature);

    expect(
      body,
      isNot(contains('friendHash')),
      reason:
          'The sender must not suppress an offer using app-local hash state; '
          'the receiver compares the raw file_id and cancels a duplicate.',
    );
    expect(body, contains('TOX_FILE_KIND_AVATAR'));
    expect(body, contains('file_id.data()'));
  });

  test('zero-size removal uses the separate delete AVATAR offer', () {
    final sendBody = _functionBody(nativeSource, _sendAvatarSignature);
    final deleteBody = _functionBody(nativeSource, _deleteAvatarSignature);

    expect(
      sendBody,
      matches(
        RegExp(
          r'if \(avatar_data == nullptr \|\| avatar_size == 0\)[\s\S]*?return -1;',
        ),
      ),
    );
    expect(deleteBody, contains('TOX_FILE_KIND_AVATAR'));
    expect(
      deleteBody,
      matches(
        RegExp(
          r'tox_file_send\([\s\S]*?TOX_FILE_KIND_AVATAR,\s*0,\s*nullptr,\s*nullptr,\s*0,',
        ),
      ),
      reason: 'Deletion is a zero-size AVATAR offer with null file_id/name.',
    );
  });

  test('avatar service flow does not delegate to generic sendFile', () {
    final sendIfNeeded = _functionBody(
      serviceSource,
      'Future<void> _sendAvatarToFriendIfNeeded(',
      bodyMarker: ') async {',
    );
    final sendAll = _functionBody(
      serviceSource,
      'Future<void> sendAvatarToAllFriends(',
      bodyMarker: ') async {',
    );
    final nativeSend = _functionBody(
      serviceSource,
      'void _sendAvatarBytes(',
      bodyMarker: ') {',
    );
    final genericSend = _functionBody(
      nativeSource,
      'int tim2tox_ffi_send_file(',
    );
    final genericUsesNullFileId = RegExp(
      r'tox_file_send\([\s\S]*file_size,\s*nullptr,',
    ).hasMatch(genericSend);

    expect(
      sendIfNeeded.contains('sendFile(') && genericUsesNullFileId,
      isFalse,
      reason: 'Current avatar sync delegates to generic sendFile, whose '
          'tox_file_send call supplies a null file_id.',
    );
    expect(
      sendAll.contains('sendFile(') && genericUsesNullFileId,
      isFalse,
      reason: 'Avatar broadcasts must not inherit the generic null file_id.',
    );
    expect(
      sendIfNeeded.contains('_sendAvatarBytes('),
      isTrue,
      reason: 'Avatar sync must call the explicit Dart FFI binding.',
    );
    expect(
      sendAll.contains('_sendAvatarBytes('),
      isTrue,
      reason: 'Avatar updates must call the explicit Dart FFI binding.',
    );
    expect(nativeSend, contains('_ffi.sendAvatar('));
    expect(serviceSource, contains('_ffi.deleteAvatar('));
  });

  test('avatar receive routing is explicit and precedes generic files', () {
    final avatarRequest = serviceSource.indexOf(
      "else if (s.startsWith('avatar_request:'))",
    );
    final fileRequest = serviceSource.indexOf(
      "else if (s.startsWith('file_request:'))",
    );

    expect(avatarRequest, greaterThanOrEqualTo(0));
    expect(fileRequest, greaterThan(avatarRequest));
    expect(
      serviceSource,
      isNot(contains('isAvatarSyncFilePath')),
      reason: 'Only TOX_FILE_KIND_AVATAR may select avatar behavior.',
    );
  });

  test('generic images always remain TOX_FILE_KIND_DATA', () {
    final body = _functionBody(nativeSource, 'int tim2tox_ffi_send_file(');

    expect(
      body.contains('TOX_FILE_KIND_AVATAR'),
      isFalse,
      reason: 'Image paths and filenames must not promote generic chat files '
          'to avatar traffic.',
    );
    expect(body.contains('TOX_FILE_KIND_DATA'), isTrue);
    expect(
      body,
      matches(
        RegExp(
          r'tox_file_send\([\s\S]*?TOX_FILE_KIND_DATA[\s\S]*?file_size,\s*nullptr,',
        ),
      ),
      reason: 'Generic DATA transfers always use a null file_id.',
    );
  });
}

ProcessResult _compileAvatarCallSite() {
  final tempRoot = Directory.systemTemp.createTempSync(
    'tim2tox_qtox_avatar_abi_${pid}_',
  );
  try {
    final source = File('${tempRoot.path}/avatar_abi.c');
    final headerPath = _tim2ToxFile('../ffi/tim2tox_ffi.h').absolute.path;
    source.writeAsStringSync('''
#include "$headerPath"

typedef int (*send_avatar_fn)(
    int64_t, const char *, const uint8_t *, size_t);
typedef int (*delete_avatar_fn)(int64_t, const char *);

static send_avatar_fn send_avatar = &tim2tox_ffi_send_avatar;
static delete_avatar_fn delete_avatar = &tim2tox_ffi_delete_avatar;

int main(void) {
    return send_avatar == 0 || delete_avatar == 0;
}
''');
    return Process.runSync(Platform.environment['CC'] ?? 'cc', [
      '-std=c11',
      '-Werror',
      '-fsyntax-only',
      source.path,
    ]);
  } finally {
    tempRoot.deleteSync(recursive: true);
  }
}

String _functionBody(
  String source,
  String signature, {
  String bodyMarker = '{',
}) {
  final signatureStart = source.indexOf(signature);
  expect(
    signatureStart,
    greaterThanOrEqualTo(0),
    reason: 'Missing production seam: $signature',
  );
  if (signatureStart < 0) {
    return '';
  }

  final markerStart = source.indexOf(bodyMarker, signatureStart);
  final bodyStart = bodyMarker == '{'
      ? markerStart
      : markerStart + bodyMarker.lastIndexOf('{');
  expect(bodyStart, greaterThan(signatureStart), reason: signature);
  if (bodyStart <= signatureStart) {
    return '';
  }

  var depth = 0;
  for (var index = bodyStart; index < source.length; index++) {
    switch (source.codeUnitAt(index)) {
      case 123:
        depth++;
      case 125:
        depth--;
        if (depth == 0) {
          return source.substring(bodyStart, index + 1);
        }
    }
  }
  fail('Unterminated function body: $signature');
}
