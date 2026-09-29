// Checklist M5: receiving large files when storage is low.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/service/file_receive_failure.dart';

void main() {
  group('file_recv_failed event', () {
    test('parses instance, sender, file number and reason', () {
      final e = parseFileRecvFailedEvent('file_recv_failed:3:ABCD:65536:no_space');
      expect(e, isNotNull);
      expect(e!.instanceId, 3);
      expect(e.uid, 'ABCD');
      expect(e.fileNumber, 65536);
      expect(e.reason, FileReceiveFailureReason.noSpace);
      expect(
        parseFileRecvFailedEvent('file_recv_failed:3:ABCD:1:io')!.reason,
        FileReceiveFailureReason.io,
      );
    });

    test('rejects malformed lines', () {
      for (final line in [
        'file_recv_failed:',
        'file_recv_failed:x:ABCD:1:io',
        'file_recv_failed:1::1:io',
        'file_recv_failed:1:ABCD:y:io',
        'file_recv_failed:1:ABCD:1',
        'file_canceled:ABCD:1',
      ]) {
        expect(parseFileRecvFailedEvent(line), isNull, reason: line);
      }
    });
  });

  test('marker path matches the native sidecar naming', () {
    expect(
      receiveMarkerPathFor('/r/file_recv/abc_1_2_photo.jpg'),
      '/r/file_recv/.abc_1_2_photo.jpg.t2t-receiving',
    );
  });

  test('FileControlException keeps the code and the old message text', () {
    const e = FileControlException(-7, 'Not enough storage to receive this file.');
    expect(e.isInsufficientStorage, isTrue);
    expect(e.toString(), 'Exception: Not enough storage to receive this file.');
    expect(const FileControlException(-5, 'x').isInsufficientStorage, isFalse);
  });

  test('isNoSpaceError recognises a full disk only', () {
    final noSpace = FileSystemException(
      'write failed',
      '/x',
      OSError('No space left on device', Platform.isWindows ? 112 : 28),
    );
    expect(isNoSpaceError(noSpace), isTrue);
    expect(
      isNoSpaceError(const FileSystemException('x', '/x', OSError('denied', 13))),
      isFalse,
    );
    expect(isNoSpaceError(StateError('x')), isFalse);
  });

  group('finalizeReceivedFile', () {
    late Directory root;
    late Directory recv;
    late Directory dest;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('t2t_finalize_');
      recv = await Directory('${root.path}/file_recv').create();
      dest = await Directory('${root.path}/Downloads').create();
    });
    tearDown(() => root.delete(recursive: true));

    Future<String> received(String name, String content) async {
      final f = File('${recv.path}/$name');
      await f.writeAsString(content);
      return f.path;
    }

    test('moves the file (same volume) and frees the source', () async {
      final src = await received('abc_1_2_report.pdf', 'data');
      final out = await finalizeReceivedFile(
        source: src,
        destDir: dest.path,
        fileName: 'report.pdf',
        uniqueTag: 't1',
        moveSource: true,
      );
      expect(out, '${dest.path}/report.pdf');
      expect(await File(out).readAsString(), 'data');
      expect(await File(src).exists(), isFalse);
    });

    test('never overwrites: same names get _1, _2', () async {
      await File('${dest.path}/a.txt').writeAsString('old');
      final s1 = await received('x_1_1_a.txt', 'one');
      final s2 = await received('x_1_2_a.txt', 'two');
      final results = await Future.wait([
        finalizeReceivedFile(
            source: s1, destDir: dest.path, fileName: 'a.txt', uniqueTag: '1', moveSource: true),
        finalizeReceivedFile(
            source: s2, destDir: dest.path, fileName: 'a.txt', uniqueTag: '2', moveSource: true),
      ]);
      expect(results.toSet(), {'${dest.path}/a_1.txt', '${dest.path}/a_2.txt'});
      expect(await File('${dest.path}/a.txt').readAsString(), 'old');
      final contents = {
        for (final r in results) await File(r).readAsString(),
      };
      expect(contents, {'one', 'two'});
    });

    test('copy mode keeps the source and leaves no stage behind', () async {
      final src = await received('keep.bin', 'payload');
      final out = await finalizeReceivedFile(
        source: src,
        destDir: dest.path,
        fileName: 'keep.bin',
        uniqueTag: 'k',
        moveSource: false,
      );
      expect(await File(out).readAsString(), 'payload');
      expect(await File(src).exists(), isTrue);
      expect(dest.listSync().map((e) => e.path), ['${dest.path}/keep.bin']);
    });

    test('a failed copy (disk full) cleans up and keeps the source', () async {
      final src = await received('big.iso', 'bytes');
      Future<void> failingCopy(String from, String to) async {
        await File(to).writeAsString('partial');
        throw FileSystemException(
          'write failed',
          to,
          OSError('No space left on device', Platform.isWindows ? 112 : 28),
        );
      }

      await expectLater(
        finalizeReceivedFile(
          source: src,
          destDir: dest.path,
          fileName: 'big.iso',
          uniqueTag: 'f',
          moveSource: false,
          copy: failingCopy,
        ),
        throwsA(predicate(isNoSpaceError)),
      );
      expect(dest.listSync(), isEmpty, reason: 'no stage, no reservation');
      expect(await File(src).readAsString(), 'bytes');
    });
  });
}
