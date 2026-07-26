import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';

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
    final source = File('../ffi/tim2tox_ffi.cpp').readAsStringSync();
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
    final avatarCap = positionOf(
        'it->second.kind == TOX_FILE_KIND_AVATAR &&', lookup);
    final open = positionOf('file_io::OpenUtf8(', avatarCap);
    final toxControl = positionOf('bool success = tox_file_control(', open);
    expect(lookup, lessThan(avatarCap));
    expect(avatarCap, lessThan(open));
    expect(open, lessThan(toxControl));
    expect(body, contains('return -5;'));
    expect(body, contains('it->second.size > kAvatarAutoAcceptMaxBytes'));
    expect(body, contains('return -6;'));
    expect(
        positionOf('fclose(opened_file)', toxControl), greaterThan(toxControl));
    expect(
      positionOf('it->second.fp = nullptr', toxControl),
      greaterThan(toxControl),
    );
    expect(positionOf('file_io::RemoveUtf8(opened_path)', toxControl),
        greaterThan(toxControl));
  });
}
