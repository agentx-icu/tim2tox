import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:tim2tox_dart/service/toxav_service.dart';

Directory _tim2ToxRootDirectory() {
  for (final start in _rootSearchStarts()) {
    var directory = start;
    while (true) {
      if (_hasTim2ToxMarkers(directory)) return directory;
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
  }
  throw StateError('Tim2Tox root was not found from test search roots.');
}

Iterable<Directory> _rootSearchStarts() sync* {
  yield Directory.current.absolute;
  yield Directory(
    path.join(Directory.current.absolute.path, 'third_party', 'tim2tox'),
  );
  if (Platform.script.scheme == 'file') {
    yield File(Platform.script.toFilePath()).parent.absolute;
  }
}

bool _hasTim2ToxMarkers(Directory directory) {
  return File(path.join(directory.path, 'README_BUILD.md')).existsSync() &&
      File(path.join(directory.path, 'CMakeLists.txt')).existsSync() &&
      Directory(path.join(directory.path, 'source')).existsSync() &&
      File(path.join(directory.path, 'dart', 'pubspec.yaml')).existsSync();
}

String _dartPackageRoot() => path.join(_tim2ToxRootDirectory().path, 'dart');

String _tim2ToxRoot() => _tim2ToxRootDirectory().path;

String _readTim2ToxSource(String relativePath) =>
    File(path.join(_tim2ToxRoot(), relativePath)).readAsStringSync();

String _readDartSource(String relativePath) =>
    File(path.join(_dartPackageRoot(), relativePath)).readAsStringSync();

void main() {
  group('legacy qTox AV conference audio contract', () {
    test(
      'retains a Dart-owned PCM copy after the native callback returns',
      () async {
        const sampleCount = 48;
        const channels = 2;
        final expected = List<int>.generate(
          sampleCount * channels,
          (index) => ((index * 977 + 12345) & 0xffff) - 0x8000,
        );
        final nativePcm = pkgffi.malloc<ffi.Int16>(expected.length);
        late Int16List retained;

        for (var index = 0; index < expected.length; index++) {
          nativePcm[index] = expected[index];
        }

        void simulateNativeCallback() {
          retained = ToxAVService.copyAudioForCallback(
            nativePcm,
            sampleCount,
            channels,
          );
        }

        simulateNativeCallback();
        for (var index = 0; index < expected.length; index++) {
          nativePcm[index] = 0;
        }
        pkgffi.malloc.free(nativePcm);

        await Future<void>.delayed(Duration.zero);

        expect(retained, isA<Int16List>());
        expect(retained, orderedEquals(expected));
      },
    );

    test(
      'native receive handler enqueues PCM with conference and peer metadata',
      () {
        final source = _readTim2ToxSource('source/V2TIMManagerImpl.cpp');
        final start = source.indexOf('static void HandleAVConferenceAudio(');
        final end = source.indexOf('#endif // BUILD_TOXAV', start);

        expect(start, greaterThanOrEqualTo(0));
        expect(end, greaterThan(start));

        final body = source.substring(start, end);
        expect(
          body,
          isNot(contains('TODO: Forward audio data to Dart layer if needed')),
          reason: 'HandleAVConferenceAudio must dispatch instead of log-only',
        );
        expect(body, contains('conference_number'));
        expect(body, contains('peer_number'));
        expect(body, contains('groupID'));
        expect(body, contains('pcm'));
        expect(body, contains('samples'));
        expect(body, contains('channels'));
        expect(body, contains('sample_rate'));
        expect(body, contains('EnqueueAVConferenceAudioFrame'));
        expect(body, isNot(contains('ForwardAVConferenceAudioToDart(')));
      },
    );

    test(
      'native FFI exports legacy group-audio receive, send, and controls',
      () {
        final header = _readTim2ToxSource('ffi/tim2tox_ffi.h');

        for (final symbol in <String>[
          'tim2tox_ffi_av_conference_set_audio_receive_callback',
          'tim2tox_ffi_av_conference_send_audio_frame',
          'tim2tox_ffi_av_conference_enable',
          'tim2tox_ffi_av_conference_disable',
          'tim2tox_ffi_av_conference_mute',
        ]) {
          expect(
            header,
            contains(symbol),
            reason: 'missing native ABI: $symbol',
          );
        }
      },
    );

    test(
      'native AV initialization is idempotent before FFI callback binding',
      () {
        final managerSource = _readTim2ToxSource('source/ToxAVManager.cpp');
        final initializeStart = managerSource.indexOf(
          'void ToxAVManager::initialize(',
        );
        final initializeEnd = managerSource.indexOf(
          'void ToxAVManager::shutdown(',
          initializeStart,
        );
        expect(initializeStart, greaterThanOrEqualTo(0));
        expect(initializeEnd, greaterThan(initializeStart));

        final initializeBody = managerSource.substring(
          initializeStart,
          initializeEnd,
        );
        final sameOwnerGuard = initializeBody.indexOf(
          'manager_impl_ == manager_impl',
        );
        final differentOwnerFailure = initializeBody.indexOf(
          'ToxAV instance belongs to a different V2TIMManagerImpl',
        );
        expect(sameOwnerGuard, greaterThanOrEqualTo(0));
        expect(differentOwnerFailure, greaterThan(sameOwnerGuard));
        final sameOwnerPath = initializeBody.substring(
          sameOwnerGuard,
          differentOwnerFailure,
        );
        expect(
          sameOwnerPath,
          contains('return;'),
        );
        expect(sameOwnerPath, isNot(contains('toxav_.reset')));
        expect(sameOwnerPath, isNot(contains('manager_impl_ = manager_impl;')));
        expect(sameOwnerPath, isNot(contains('conference_audio_callback_')));
        expect(
          initializeBody,
          isNot(
            contains(
                'throw std::runtime_error("ToxAV instance already initialized")'),
          ),
        );

        final ffiSource = _readTim2ToxSource('ffi/tim2tox_ffi.cpp');
        final ffiInitializeStart = ffiSource.indexOf(
          'int tim2tox_ffi_av_initialize(',
        );
        final ffiInitializeEnd = ffiSource.indexOf(
          'void tim2tox_ffi_av_shutdown(',
          ffiInitializeStart,
        );
        expect(ffiInitializeStart, greaterThanOrEqualTo(0));
        expect(ffiInitializeEnd, greaterThan(ffiInitializeStart));

        final ffiInitialize = ffiSource.substring(
          ffiInitializeStart,
          ffiInitializeEnd,
        );
        final nativeInitialize = ffiInitialize.indexOf(
          'av_mgr->initialize(manager_impl);',
        );
        final callbackBinding = ffiInitialize.indexOf(
          'av_mgr->setCallCallback(',
        );
        final initializedRegistration = ffiInitialize.indexOf(
          'g_av_initialized_instances.insert(instance_id);',
        );
        expect(nativeInitialize, greaterThanOrEqualTo(0));
        expect(callbackBinding, greaterThan(nativeInitialize));
        expect(initializedRegistration, greaterThan(callbackBinding));
        expect(ffiInitialize, contains('catch (const std::exception&)'));
        expect(ffiInitialize, contains('catch (...)'));
      },
    );

    test(
      'conference create join and re-enable retain the native PCM context',
      () {
        final managerSource = _readTim2ToxSource('source/V2TIMManagerImpl.cpp');
        expect(
          managerSource,
          contains(
            'toxav_add_av_groupchat(\n'
            '            av_tox, HandleAVConferenceAudio, this)',
          ),
        );
        expect(
          managerSource,
          contains(
            'audio_callback,\n'
            '                    this  // userdata',
          ),
        );

        final enableStart = managerSource.indexOf(
          'bool V2TIMManagerImpl::EnableAVConferenceAudio(',
        );
        final enableEnd = managerSource.indexOf(
          'bool V2TIMManagerImpl::DisableAVConferenceAudio(',
          enableStart,
        );
        expect(enableStart, greaterThanOrEqualTo(0));
        expect(enableEnd, greaterThan(enableStart));
        final enableBody = managerSource.substring(enableStart, enableEnd);
        final contextRegistration = enableBody.indexOf(
          'setConferenceAudioCallbackContext(',
        );
        final nativeEnable = enableBody.indexOf('enableConferenceAudio(');
        expect(contextRegistration, greaterThanOrEqualTo(0));
        expect(nativeEnable, greaterThan(contextRegistration));
        expect(enableBody, contains('HandleAVConferenceAudio, this'));

        final avManagerSource = _readTim2ToxSource('source/ToxAVManager.cpp');
        final nativeEnableStart = avManagerSource.indexOf(
          'bool ToxAVManager::enableConferenceAudio(',
        );
        final nativeEnableEnd = avManagerSource.indexOf(
          'bool ToxAVManager::disableConferenceAudio(',
          nativeEnableStart,
        );
        expect(nativeEnableStart, greaterThanOrEqualTo(0));
        expect(nativeEnableEnd, greaterThan(nativeEnableStart));
        final nativeEnableBody = avManagerSource.substring(
          nativeEnableStart,
          nativeEnableEnd,
        );
        expect(nativeEnableBody, contains('conference_audio_callback_'));
        expect(nativeEnableBody, contains('manager_impl_'));
        expect(nativeEnableBody, isNot(contains('nullptr')));
      },
    );

    test('Dart FFI uses size_t sample_count for conference audio ABI', () {
      final source = _readDartSource('lib/ffi/tim2tox_ffi.dart');

      final callbackStart = source.indexOf(
        'typedef _av_conference_audio_receive_callback_native',
      );
      final callbackEnd = source.indexOf(
        'typedef _av_conference_set_audio_receive_callback_c',
        callbackStart,
      );
      expect(callbackStart, greaterThanOrEqualTo(0));
      expect(callbackEnd, greaterThan(callbackStart));
      final callbackTypedef = source.substring(callbackStart, callbackEnd);
      expect(callbackTypedef, contains('ffi.Pointer<pkgffi.Utf8>'));
      expect(callbackTypedef, contains('ffi.Uint32, // conference_number'));
      expect(callbackTypedef, contains('ffi.Uint32, // peer_number'));
      expect(callbackTypedef, contains('ffi.Size, // sample_count'));

      final sendStart = source.indexOf(
        'typedef _av_conference_send_audio_frame_c',
      );
      final sendEnd = source.indexOf(
        'typedef _av_conference_enable_c',
        sendStart,
      );
      expect(sendStart, greaterThanOrEqualTo(0));
      expect(sendEnd, greaterThan(sendStart));
      final sendTypedef = source.substring(sendStart, sendEnd);
      expect(sendTypedef, contains('ffi.Pointer<pkgffi.Utf8>'));
      expect(sendTypedef, contains('ffi.Pointer<ffi.Int16>'));
      expect(sendTypedef, contains('ffi.Size, // sample_count'));
    });

    test('validates qTox-compatible interleaved audio frame shapes', () {
      expect(
        ToxAVService.isValidConferenceAudioFrame(
          groupId: 'group-1',
          pcmLength: 960,
          sampleCount: 960,
          channels: 1,
          samplingRate: 48000,
        ),
        isTrue,
      );
      expect(
        ToxAVService.isValidConferenceAudioFrame(
          groupId: 'group-1',
          pcmLength: 1920,
          sampleCount: 960,
          channels: 2,
          samplingRate: 48000,
        ),
        isTrue,
      );
      expect(
        ToxAVService.isValidConferenceAudioFrame(
          groupId: '',
          pcmLength: 960,
          sampleCount: 960,
          channels: 1,
          samplingRate: 48000,
        ),
        isFalse,
      );
      expect(
        ToxAVService.isValidConferenceAudioFrame(
          groupId: 'group-1',
          pcmLength: 959,
          sampleCount: 960,
          channels: 1,
          samplingRate: 48000,
        ),
        isFalse,
      );
      expect(
        ToxAVService.isValidConferenceAudioFrame(
          groupId: 'group-1',
          pcmLength: 2880,
          sampleCount: 960,
          channels: 3,
          samplingRate: 48000,
        ),
        isFalse,
      );
      expect(
        ToxAVService.isValidConferenceAudioFrame(
          groupId: 'group-1',
          pcmLength: 960,
          sampleCount: 960,
          channels: 1,
          samplingRate: 44100,
        ),
        isFalse,
      );
    });

    test('Dart service owns legacy conference audio lifecycle', () {
      final source = _readDartSource('lib/service/toxav_service.dart');

      for (final api in <String>[
        'ConferenceAudioReceiveCallback',
        'setConferenceAudioReceiveCallback',
        'sendConferenceAudioFrame',
        'enableConferenceAudio',
        'disableConferenceAudio',
        'isConferenceAudioEnabled',
        'muteConferenceAudio',
        '_onConferenceAudioReceiveNativeTrampoline',
        '_enabledConferenceAudioGroups',
        '_mutedConferenceAudioGroups',
      ]) {
        expect(source, contains(api), reason: 'missing Dart AV API: $api');
      }

      final trampolineStart = source.indexOf(
        'static void _onConferenceAudioReceiveNativeTrampoline',
      );
      final trampolineEnd = source.indexOf(
        '/// Set conference audio receive callback',
        trampolineStart,
      );
      expect(trampolineStart, greaterThanOrEqualTo(0));
      expect(trampolineEnd, greaterThan(trampolineStart));

      final trampoline = source.substring(trampolineStart, trampolineEnd);
      expect(trampoline, contains('copyAudioForCallback'));
      expect(trampoline, contains('conferenceNumber'));
      expect(trampoline, contains('peerNumber'));
      expect(trampoline, contains('groupId'));
      expect(trampoline, contains('_lookupService(instanceId)'));
      expect(trampoline, contains('!target._initialized'));
      expect(trampoline, contains('_enabledConferenceAudioGroups.contains'));
      expect(trampoline, contains('_mutedConferenceAudioGroups.contains'));
      expect(trampoline, isNot(contains('logDebug')));

      final sendStart = source.indexOf('Future<bool> sendConferenceAudioFrame');
      final sendEnd = source.indexOf('/// Enable conference audio', sendStart);
      expect(sendStart, greaterThanOrEqualTo(0));
      expect(sendEnd, greaterThan(sendStart));
      final sendMethod = source.substring(sendStart, sendEnd);
      expect(sendMethod, contains('isValidConferenceAudioFrame'));
      expect(sendMethod, contains('pkgffi.malloc<ffi.Int16>'));
      expect(sendMethod, contains('pkgffi.malloc.free(pcmPtr)'));

      final disableStart =
          source.indexOf('Future<bool> disableConferenceAudio');
      final disableEnd =
          source.indexOf('/// Mute conference audio', disableStart);
      expect(disableStart, greaterThanOrEqualTo(0));
      expect(disableEnd, greaterThan(disableStart));
      final disableMethod = source.substring(disableStart, disableEnd);
      expect(disableMethod, contains('return true'));
      expect(disableMethod, contains('_enabledConferenceAudioGroups.remove'));
      expect(disableMethod, contains('_mutedConferenceAudioGroups.remove'));
    });

    test(
      'conference audio is queued until avIterate drains manager-owned frames',
      () {
        final managerSource = _readTim2ToxSource('source/V2TIMManagerImpl.cpp');
        final ffiSource = _readTim2ToxSource('ffi/tim2tox_ffi.cpp');
        final serviceSource = _readDartSource('lib/service/toxav_service.dart');

        final handleStart = managerSource.indexOf(
          'static void HandleAVConferenceAudio(',
        );
        final handleEnd = managerSource.indexOf(
          '#endif // BUILD_TOXAV',
          handleStart,
        );
        expect(handleStart, greaterThanOrEqualTo(0));
        expect(handleEnd, greaterThan(handleStart));

        final handleBody = managerSource.substring(handleStart, handleEnd);
        expect(
          handleBody,
          contains('manager_impl->EnqueueAVConferenceAudioFrame('),
        );
        expect(handleBody, isNot(contains('ForwardAVConferenceAudioToDart(')));

        final trampolineStart = serviceSource.indexOf(
          'static void _onConferenceAudioReceiveNativeTrampoline',
        );
        final trampolineEnd = serviceSource.indexOf(
          '/// Set conference audio receive callback',
          trampolineStart,
        );
        expect(trampolineStart, greaterThanOrEqualTo(0));
        expect(trampolineEnd, greaterThan(trampolineStart));
        final trampolineBody = serviceSource.substring(
          trampolineStart,
          trampolineEnd,
        );
        expect(trampolineBody, contains('copyAudioForCallback'));
        expect(trampolineBody, contains('target._onConferenceAudioReceive!('));

        final iterateStart = ffiSource.indexOf('void tim2tox_ffi_av_iterate(');
        final iterateEnd = ffiSource.indexOf(
          'int tim2tox_ffi_av_start_call(',
          iterateStart,
        );
        expect(iterateStart, greaterThanOrEqualTo(0));
        expect(iterateEnd, greaterThan(iterateStart));

        final iterateBody = ffiSource.substring(iterateStart, iterateEnd);
        expect(
          iterateBody,
          contains('manager_impl->DrainPendingAVConferenceAudioFrames();'),
          reason: 'avIterate is the only Dart-dispatch drain point',
        );
        expect(
          ffiSource,
          isNot(contains('g_pending_av_conference_audio_frames')),
          reason: 'conference PCM queue ownership belongs to V2TIMManagerImpl',
        );
        expect(
          ffiSource,
          isNot(contains('DrainAVConferenceAudioFrames(')),
          reason: 'FFI must not own a process-global conference PCM drain',
        );
        expect(
          ffiSource,
          contains('tim2tox_ffi_av_conference_clear_pending_audio('),
          reason:
              'callback replacement needs an additive pending-frame clear ABI',
        );
        expect(
          ffiSource,
          contains('manager->ClearPendingAVConferenceAudioFrames();'),
        );
        expect(
            ffiSource, isNot(contains('kMaxPendingAVConferenceAudioFrames')));

        final callbackSetterStart = serviceSource.indexOf(
          'void setConferenceAudioReceiveCallback(',
        );
        final callbackSetterEnd = serviceSource.indexOf(
          "@pragma('vm:entry-point')",
          callbackSetterStart,
        );
        expect(callbackSetterStart, greaterThanOrEqualTo(0));
        expect(callbackSetterEnd, greaterThan(callbackSetterStart));
        final callbackSetter = serviceSource.substring(
          callbackSetterStart,
          callbackSetterEnd,
        );
        final nativeClear = callbackSetter.indexOf(
          'avConferenceClearPendingAudioNative(_boundInstanceId)',
        );
        final replacement = callbackSetter.indexOf(
          '_onConferenceAudioReceive = callback',
        );
        expect(nativeClear, greaterThanOrEqualTo(0));
        expect(replacement, greaterThan(nativeClear));
      },
    );
  });
}
