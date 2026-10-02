import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

/// The byte-array passphrase API: the host's bytes reach native intact and
/// are NOT zeroed by the call (the host owns their lifetime), an empty or
/// null value stages "no passphrase", and the String convenience path feeds
/// the same native entry point.
class _PassphraseRecordingFfi extends Tim2ToxFfi {
  _PassphraseRecordingFfi() : super.forTesting();

  final List<Uint8List> staged = <Uint8List>[];
  final List<int> stagedAddresses = <int>[];
  final List<Uint8List> rekeyed = <Uint8List>[];

  @override
  int Function(ffi.Pointer<ffi.Uint8>, int) get setProfilePassphrase =>
      (buf, len) {
        stagedAddresses.add(buf.address);
        staged.add(Uint8List.fromList(
            len == 0 ? const <int>[] : buf.asTypedList(len)));
        return 1;
      };

  @override
  int Function(ffi.Pointer<ffi.Uint8>, int, int)
      get rekeyLiveProfilePassphrase => (buf, len, _) {
            rekeyed.add(Uint8List.fromList(
                len == 0 ? const <int>[] : buf.asTypedList(len)));
            return 1;
          };

  @override
  void Function() get uninit => () {};
}

void main() {
  late Directory tempDirectory;
  late _PassphraseRecordingFfi fakeFfi;
  late FfiChatService service;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('tim2tox_passphrase_bytes_');
    fakeFfi = _PassphraseRecordingFfi();
    service = FfiChatService(
      ffiForTesting: fakeFfi,
      historyDirectory: p.join(tempDirectory.path, 'history'),
      queueFilePath: p.join(tempDirectory.path, 'queue.json'),
      fileRecvPath: p.join(tempDirectory.path, 'file_recv'),
      avatarsPath: p.join(tempDirectory.path, 'avatars'),
    );
  });

  tearDown(() async {
    await tempDirectory.delete(recursive: true);
  });

  test('bytes reach native verbatim and the host buffer is left intact', () {
    final host = Uint8List.fromList(<int>[0x70, 0xC3, 0xA4, 0x00, 0x73, 0x73]);
    final before = Uint8List.fromList(host);

    expect(service.setProfilePassphraseBytes(host), isTrue);

    expect(fakeFfi.staged, hasLength(1));
    expect(fakeFfi.staged.single, before);
    // Not zeroed, not replaced: the caller decides when its copy dies.
    expect(host, before);
    // The native side saw a COPY, never the Dart buffer's address.
    expect(fakeFfi.stagedAddresses.single, isNot(0));
  });

  test('null and empty both stage "no passphrase"', () {
    expect(service.setProfilePassphraseBytes(null), isTrue);
    expect(service.setProfilePassphraseBytes(Uint8List(0)), isTrue);
    expect(fakeFfi.staged, hasLength(2));
    expect(fakeFfi.staged[0], isEmpty);
    expect(fakeFfi.staged[1], isEmpty);
    expect(fakeFfi.stagedAddresses, everyElement(0));
  });

  test('the String convenience path is the bytes path', () {
    expect(service.setProfilePassphrase('pä\u0000ss'), isTrue);
    expect(fakeFfi.staged.single,
        Uint8List.fromList(<int>[0x70, 0xC3, 0xA4, 0x00, 0x73, 0x73]));
    expect(service.setProfilePassphrase(''), isTrue);
    expect(fakeFfi.staged.last, isEmpty);
  });

  test('re-key uses the same byte contract', () {
    final host = Uint8List.fromList(<int>[1, 2, 3]);
    expect(service.rekeyLiveProfilePassphraseBytes(host), isTrue);
    expect(fakeFfi.rekeyed.single, Uint8List.fromList(<int>[1, 2, 3]));
    expect(host, Uint8List.fromList(<int>[1, 2, 3]));
    expect(service.rekeyLiveProfilePassphrase(null), isTrue);
    expect(fakeFfi.rekeyed.last, isEmpty);
  });
}
