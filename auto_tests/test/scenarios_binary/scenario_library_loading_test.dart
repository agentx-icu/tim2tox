// Library Loading Tests (Binary Replacement Path)
//
// Tests that setNativeLibraryName() correctly configures the native library
// loaded by NativeLibraryManager, and verifies the library is functional.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/bindings/native_library_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import '../test_fixtures.dart';

void main() {
  group('Library Loading Tests', () {
    setUpAll(() async {
      await setupTestEnvironment();
      // Call setNativeLibraryName BEFORE any NativeLibraryManager usage
      // (which triggers lazy DynamicLibrary loading)
      setupNativeLibraryForTim2Tox();
    });

    tearDownAll(() async {
      await teardownTestEnvironment();
    });

    test('macOS runtime maps libtim2tox_ffi.dylib from this checkout', () async {
      if (!Platform.isMacOS) {
        return;
      }

      final expectedLibraryPath = resolveTim2ToxLibraryPath();
      final lsofResult = await Process.run('lsof', [
        '-n',
        '-P',
        '-p',
        pid.toString(),
      ]);

      expect(
        lsofResult.exitCode,
        equals(0),
        reason: 'lsof must succeed on macOS',
      );

      final mappedLibraryPaths = (lsofResult.stdout as String)
          .split('\n')
          .where((line) => line.contains('libtim2tox_ffi.dylib'))
          .map((line) {
            final match = RegExp(
              r'(/.*libtim2tox_ffi\.dylib)(?: \(deleted\))?$',
            ).firstMatch(line);
            return match?.group(1) ?? line.trim().split(RegExp(r'\s+')).last;
          })
          .toList();

      expect(
        mappedLibraryPaths,
        isNotEmpty,
        reason: 'Tim2Tox FFI library must be mapped on macOS',
      );
      expect(
        mappedLibraryPaths.every(
          (mappedPath) => mappedPath == expectedLibraryPath,
        ),
        isTrue,
        reason: 'Every Tim2Tox FFI mapping must use the current checkout',
      );
    });

    test('setNativeLibraryName configures tim2tox_ffi library', () {
      // If we get here, the library was loaded successfully.
      // NativeLibraryManager.bindings would have thrown if the library
      // could not be opened (lazy _dylib initialization).
      // Verify by checking that the bindings object is accessible.
      expect(NativeLibraryManager.bindings, isNotNull);
    });

    test('injectCallback returns 0 before registerPort', () {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      final result = ffiInstance.injectCallback('{"callback":"noop"}');
      expect(result, equals(0));
    });

    test('NativeLibraryManager.registerPort succeeds with tim2tox_ffi', () {
      // registerPort() calls DartInitDartApiDL and DartRegisterSendPort
      // on the loaded native library. If the wrong library was loaded,
      // these symbols would be missing and it would throw.
      NativeLibraryManager.registerPort();
      // If we get here without exception, the port was registered successfully.
    });

    test('Injected callback reaches Dart through NativeLibraryManager port', () async {
      final completer = Completer<void>();

      NativeLibraryManager.setSdkListener(V2TimSDKListener(
        onConnectSuccess: () {
          if (!completer.isCompleted) completer.complete();
        },
        onConnectFailed: (code, desc) {},
        onConnecting: () {},
        onKickedOffline: () {},
        onUserSigExpired: () {},
        onSelfInfoUpdated: (info) {},
        onUserStatusChanged: (statusList) {},
      ));

      // Use injectCallback to send a message through the registered port
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      final json = jsonEncode({
        "callback": "globalCallback",
        "callbackType": 0, // NetworkStatus
        "instance_id": 0,
        "code": 0,
        "desc": "",
        "status": 0, // connected
      });
      final result = ffiInstance.injectCallback(json);
      expect(result, equals(1), reason: 'Dart port should be registered');

      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Callback did not arrive through the registered port'),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

  });
}
