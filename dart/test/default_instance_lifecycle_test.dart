import 'dart:ffi' as dartffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';

/// Default-instance quarantine → detach → re-init lifecycle, against the
/// REAL native library (built dylib next to this package). Skips cleanly
/// when the library has not been built locally.
typedef NativeVoidPtrFn = dartffi.Void Function(dartffi.Pointer<dartffi.Void>);

void main() {
  final candidates = [
    File('../build/ffi/libtim2tox_ffi.dylib').absolute,
    File('../build/libtim2tox_ffi.dylib').absolute,
  ];
  final lib = candidates.firstWhere(
    (f) => f.existsSync(),
    orElse: () => candidates.first,
  );
  final available = lib.existsSync();

  test('source contract: dispose authorizes, init requests behind the guard',
      () {
    final source = File('lib/service/ffi_chat_service.dart').readAsStringSync();
    expect(source, contains('quarantineDefaultInstance(_sessionEpoch)'));
    final guardIdx = source.indexOf('isInstanceInitialized(0) == 1');
    final detachIdx = source.indexOf('_ffi.detachDefaultInstance()');
    expect(guardIdx, greaterThanOrEqualTo(0));
    expect(detachIdx, greaterThan(guardIdx));
    // Refusal path claims a fresh epoch so a predecessor's late quarantine
    // can never condemn the adopted session.
    expect(source, contains('claimDefaultEpoch()'));
  });

  test(
    'native: healthy refusal, epoch-bound quarantine, detach, re-init',
    () {
      Tim2ToxFfi.setLibraryPathOverride(lib.path);
      final ffi = Tim2ToxFfi.open();
      expect(ffi.isInstanceInitialized(0), 0);
      // Detach on a non-inited instance is a tolerant no-op.
      expect(ffi.detachDefaultInstance(), 1);

      expect(ffi.init(), 1);
      final epoch1 = ffi.defaultEpoch();
      expect(ffi.isInstanceInitialized(0), 1);

      // Register a DISTINCT per-instance compat listener alongside the
      // init-added global one: the manager's listener store is a SET, so a
      // failed unwire of the SAME global pointer would be invisible; a
      // second distinct pointer makes stale wiring observable (codex).
      final raw = ffi.rawLibraryForTest;
      final setKicked = raw.lookupFunction<NativeVoidPtrFn,
          void Function(dartffi.Pointer<dartffi.Void>)>(
        'DartSetKickedOfflineCallback',
      );
      setKicked(Tim2ToxFfi.nullPtr);
      expect(ffi.debugSdkListenerCount(), 2);

      // HEALTHY protection: no quarantine recorded => detach refuses.
      expect(ffi.detachDefaultInstance(), 0);
      expect(ffi.isInstanceInitialized(0), 1);

      // Stale-epoch quarantine is ignored.
      expect(ffi.quarantineDefaultInstance(epoch1 - 1), 0);
      expect(ffi.detachDefaultInstance(), 0);

      // Correct-epoch quarantine authorizes exactly one detach.
      expect(ffi.quarantineDefaultInstance(epoch1), 1);
      expect(ffi.detachDefaultInstance(), 1);
      expect(ffi.isInstanceInitialized(0), 0);

      // Detach itself bumped the epoch (independently of any init).
      final afterDetach = ffi.defaultEpoch();
      expect(afterDetach, greaterThan(epoch1));

      // Re-init mints a NEW session epoch on top of the detach bump, the
      // old flag is dead, and callbacks are registered EXACTLY ONCE (the
      // detach really unwired the previous session's listeners).
      expect(ffi.init(), 1);
      final epoch2 = ffi.defaultEpoch();
      expect(epoch2, greaterThan(afterDetach));
      expect(ffi.detachDefaultInstance(), 0);
      // EXACTLY ONCE: the previous session's distinct listener is gone and
      // the fresh init re-added only the global — 1, not 2 (stale) or 3.
      expect(ffi.debugSdkListenerCount(), 1);

      // CLAIM/adopt: a claimed epoch invalidates the predecessor's late
      // quarantine (the exact A/B/C race the epoch binding closes).
      final claimed = ffi.claimDefaultEpoch();
      expect(claimed, greaterThan(epoch2));
      expect(ffi.quarantineDefaultInstance(epoch2), 0);
      expect(ffi.detachDefaultInstance(), 0);

      // Leave the process clean for any later tests.
      expect(ffi.quarantineDefaultInstance(claimed), 1);
      expect(ffi.detachDefaultInstance(), 1);
      expect(ffi.isInstanceInitialized(0), 0);
    },
    skip: available ? false : 'libtim2tox_ffi.dylib not built locally',
  );
}
