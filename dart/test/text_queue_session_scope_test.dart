// A queued poll record belongs to the SESSION that produced it.
//
// THE DEFECT (2026-09-22 review): the native text queue behind
// `tim2tox_ffi_poll_text` keyed records by instance id only, and no teardown
// path cleared it. The default instance (id 0) is a process singleton that
// every account switch reuses, so a record account A queued and nobody polled
// — the app was suspended, the poll loop had already stopped, the event
// arrived during logout — was handed to account B's poll loop after B logged
// in, and B wrote A's message into ITS history.
//
// Records now carry the session epoch (V2TIMManagerImpl::GetSessionEpoch) and
// are purged at teardown, so nothing can cross a session boundary. Runs
// against the real dylib; skips when it has not been built locally.

import 'dart:ffi' as dartffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';

typedef _SaveNicknameC = dartffi.Int32 Function(
    dartffi.Pointer<pkgffi.Utf8>, dartffi.Pointer<pkgffi.Utf8>);
typedef _SaveNicknameDart = int Function(
    dartffi.Pointer<pkgffi.Utf8>, dartffi.Pointer<pkgffi.Utf8>);

const _peer =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _markerFromA = 'queued-by-session-a';

void main() {
  final candidates = [
    File('../build/ffi/libtim2tox_ffi.dylib').absolute,
    File('../build/libtim2tox_ffi.dylib').absolute,
    File('../build/ffi/libtim2tox_ffi.so').absolute,
  ];
  final lib = candidates.firstWhere(
    (f) => f.existsSync(),
    orElse: () => candidates.first,
  );

  test(
    'native: an unpolled record does not survive into the next session',
    () {
      Tim2ToxFfi.setLibraryPathOverride(lib.path);
      final ffi = Tim2ToxFfi.open();
      expect(ffi.isInstanceInitialized(0), 0);

      // ---- Session A -----------------------------------------------------
      expect(ffi.init(), 1);
      // Queue a record through a producer that needs no peer: it lands in the
      // same bounded text queue every message uses.
      final saveNickname = ffi.rawLibraryForTest
          .lookupFunction<_SaveNicknameC, _SaveNicknameDart>(
              'tim2tox_ffi_save_friend_nickname');
      final peer = _peer.toNativeUtf8();
      final nickname = _markerFromA.toNativeUtf8();
      expect(saveNickname(peer, nickname), 1);
      pkgffi.calloc.free(peer);
      pkgffi.calloc.free(nickname);

      // Nobody polls it: the session ends with the record still queued.
      final epoch = ffi.defaultEpoch();
      expect(ffi.quarantineDefaultInstance(epoch), 1);
      expect(ffi.detachDefaultInstance(), 1);
      expect(ffi.isInstanceInitialized(0), 0);

      // ---- Session B, same instance id -----------------------------------
      expect(ffi.init(), 1);
      final buffer = pkgffi.calloc<dartffi.Int8>(4096);
      final seen = <String>[];
      try {
        for (var i = 0; i < 64; i++) {
          final n = ffi.pollText(0, buffer, 4096);
          if (n <= 0) break;
          seen.add(buffer.cast<pkgffi.Utf8>().toDartString());
        }
      } finally {
        pkgffi.calloc.free(buffer);
      }
      expect(
        seen.where((line) => line.contains(_markerFromA)),
        isEmpty,
        reason: 'the next account must never receive the previous one\'s '
            'queued records',
      );

      // Leave the process clean for any later tests.
      final epochB = ffi.defaultEpoch();
      expect(ffi.quarantineDefaultInstance(epochB), 1);
      expect(ffi.detachDefaultInstance(), 1);
    },
    skip: lib.existsSync() ? false : 'libtim2tox_ffi not built locally',
  );
}
