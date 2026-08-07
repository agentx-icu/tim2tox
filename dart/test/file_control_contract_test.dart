import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';

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
  test('maps local receive open failure', () {
    expect(
      Tim2ToxFfi.fileControlErrorMessage(-5),
      'Local receive file could not be opened.',
    );
  });

  test('maps oversized avatar rejection', () {
    expect(
      Tim2ToxFfi.fileControlErrorMessage(-6),
      'Avatar exceeds the 10 MiB receive limit.',
    );
  });

  test('prepares receive file before native resume and retains rollback', () {
    final source = _tim2ToxFile('../ffi/tim2tox_ffi.cpp').readAsStringSync();
    final start = source.indexOf('int tim2tox_ffi_file_control(');
    final end = source.indexOf('int tim2tox_ffi_set_file_recv_dir(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    int positionOf(String token, [int startAt = 0]) {
      final position = body.indexOf(token, startAt);
      expect(position, greaterThanOrEqualTo(0), reason: token);
      return position;
    }

    final lookup = positionOf('G.recv_files.find(instance_id)');
    final avatarCap =
        positionOf('it->second.kind == TOX_FILE_KIND_AVATAR &&', lookup);
    final open = positionOf('file_io::OpenUtf8(', avatarCap);
    final toxControl = positionOf('bool success = tox_file_control(', open);
    expect(lookup, lessThan(avatarCap));
    expect(avatarCap, lessThan(open));
    expect(open, lessThan(toxControl));
    expect(body,
        contains('case 0: tox_control = TOX_FILE_CONTROL_RESUME; break;'));
    expect(
        body, contains('case 1: tox_control = TOX_FILE_CONTROL_PAUSE; break;'));
    expect(body,
        contains('case 2: tox_control = TOX_FILE_CONTROL_CANCEL; break;'));
    expect(body, contains('return -5;'));
    expect(body, contains('it->second.size > kAvatarMaxBytes'));
    expect(body, contains('return -6;'));
    expect(
        positionOf('fclose(opened_file)', toxControl), greaterThan(toxControl));
    expect(
      positionOf('it->second.fp = nullptr', toxControl),
      greaterThan(toxControl),
    );
    expect(positionOf('file_io::RemoveUtf8(opened_path)', toxControl),
        greaterThan(toxControl));
    expect(positionOf('if (control == 2) { // CANCEL', toxControl),
        greaterThan(toxControl));
    expect(positionOf('instance_it->second.erase(it);', toxControl),
        greaterThan(toxControl));
    expect(body, isNot(contains('EraseSendContext(instance_id, key);')));
  });

  test('poll parser routes live file control prefixes into the handler', () {
    final source =
        _tim2ToxFile('lib/service/ffi_chat_service.dart').readAsStringSync();
    final branchStart = source.indexOf(
      "else if (s.startsWith('file_canceled:') ||",
    );
    final branchEnd = source.indexOf(
      "else if (s.startsWith('nickname_changed:'))",
      branchStart,
    );
    expect(branchStart, greaterThanOrEqualTo(0));
    expect(branchEnd, greaterThan(branchStart));

    final branch = source.substring(branchStart, branchEnd);
    expect(branch, contains("s.startsWith('file_canceled:')"));
    expect(branch, contains("s.startsWith('file_paused:')"));
    expect(branch, contains("s.startsWith('file_resumed:')"));
    expect(branch, contains('final uid = parts[0];'));
    expect(branch, contains('final fileNumber = int.tryParse(parts[1]);'));
    expect(
      branch,
      contains('_handleFileControl('),
    );
    expect(branch, contains('uid: uid, fileNumber: fileNumber'));
    expect(branch, contains('control: control'));
    expect(branch, isNot(contains('TODO(P1-6)')));
  });

  test('file control handler keeps state transitions idempotent and private',
      () {
    final source =
        _tim2ToxFile('lib/service/ffi_chat_service.dart').readAsStringSync();
    final handlerStart = source.indexOf('void _handleFileControl(');
    final handlerEnd =
        source.indexOf('/// P1-7: Walk in-flight receives', handlerStart);
    expect(handlerStart, greaterThanOrEqualTo(0));
    expect(handlerEnd, greaterThan(handlerStart));

    final handler = source.substring(handlerStart, handlerEnd);
    expect(
        handler, contains('_markFileTransferFailed(uid, fileNumber, msgID);'));
    expect(handler, contains('_pausedTransfers.add(key);'));
    expect(handler, contains('_pausedTransfers.remove(key);'));
    expect(handler, contains('_pausedTransfers.remove(altKey);'));
    expect(
      handler,
      contains(
        "[FfiChatService] _handleFileControl: status=cleaned up transfer control=",
      ),
    );
    expect(
      handler,
      contains(
        "[FfiChatService] _handleFileControl: status=paused control=",
      ),
    );
    expect(
      handler,
      contains(
        "[FfiChatService] _handleFileControl: status=resumed control=",
      ),
    );
    expect(
      handler,
      contains(
        "[FfiChatService] _handleFileControl: status=unknown control=",
      ),
    );
    expect(handler, isNot(contains('uid=')));
    expect(handler, isNot(contains('fileNumber=')));
  });

  test('file control wrappers free native peer strings and clean cancel state',
      () {
    final source =
        _tim2ToxFile('lib/service/ffi_chat_service.dart').readAsStringSync();

    int positionOf(String token, [int startAt = 0]) {
      final position = source.indexOf(token, startAt);
      expect(position, greaterThanOrEqualTo(0), reason: token);
      return position;
    }

    final acceptStart = positionOf('Future<void> acceptFileTransfer(');
    final rejectStart =
        positionOf('Future<void> rejectFileTransfer(', acceptStart);
    final pauseStart =
        positionOf('Future<void> pauseFileTransfer(', rejectStart);
    final resumeStart =
        positionOf('Future<void> resumeFileTransfer(', pauseStart);
    final cancelStart =
        positionOf('Future<void> cancelFileTransfer(', resumeStart);
    final helperStart = positionOf(
      '/// Helper method to safely clean up _fileNumberToMsgID mapping',
      cancelStart,
    );

    final acceptBody = source.substring(acceptStart, rejectStart);
    expect(
        acceptBody, contains('final pto = normalizedPeerId.toNativeUtf8();'));
    expect(acceptBody, contains('// 0 = RESUME'));
    expect(acceptBody, contains('pkgffi.malloc.free(pto);'));

    final rejectBody = source.substring(rejectStart, pauseStart);
    expect(
        rejectBody, contains('final pto = normalizedPeerId.toNativeUtf8();'));
    expect(rejectBody, contains('// 2 = CANCEL'));
    expect(rejectBody, contains('pkgffi.malloc.free(pto);'));

    final pauseBody = source.substring(pauseStart, resumeStart);
    expect(pauseBody, contains('final pto = normalizedPeerId.toNativeUtf8();'));
    expect(pauseBody, contains('// 1 = PAUSE'));
    expect(pauseBody, contains('pkgffi.malloc.free(pto);'));

    final resumeBody = source.substring(resumeStart, cancelStart);
    expect(
        resumeBody, contains('final pto = normalizedPeerId.toNativeUtf8();'));
    expect(resumeBody, contains('// 0 = RESUME'));
    expect(resumeBody, contains('pkgffi.malloc.free(pto);'));

    final cancelBody = source.substring(cancelStart, helperStart);
    expect(
        cancelBody, contains('final pto = normalizedPeerId.toNativeUtf8();'));
    expect(cancelBody, contains('// 2 = CANCEL'));
    expect(cancelBody, contains('pkgffi.malloc.free(pto);'));
    expect(
      cancelBody,
      contains(
          '_cleanupFileNumberMapping(normalizedPeerId, peerId, fileNumber);'),
    );
    expect(
        positionOf('if (result <= 0) {', cancelStart),
        lessThan(positionOf(
          '_cleanupFileNumberMapping(normalizedPeerId, peerId, fileNumber);',
          cancelStart,
        )));
    expect(cancelBody, contains('// Clean up mapping after cancellation'));
  });
}
