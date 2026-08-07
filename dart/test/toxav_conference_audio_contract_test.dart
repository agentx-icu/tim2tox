import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/service/toxav_service.dart';

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
      'native receive handler forwards PCM with conference and peer metadata',
      () {
        final source = File(
          '../source/V2TIMManagerImpl.cpp',
        ).readAsStringSync();
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
        expect(body, contains('ForwardAVConferenceAudioToDart'));
      },
    );

    test(
      'native FFI exports legacy group-audio receive, send, and controls',
      () {
        final header = File('../ffi/tim2tox_ffi.h').readAsStringSync();

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
        final managerSource = File(
          '../source/ToxAVManager.cpp',
        ).readAsStringSync();
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

        final ffiSource = File('../ffi/tim2tox_ffi.cpp').readAsStringSync();
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
        expect(ffiInitialize, contains('catch (const std::exception& e)'));
        expect(ffiInitialize, contains('catch (...)'));
      },
    );

    test(
      'conference create join and re-enable retain the native PCM context',
      () {
        final managerSource = File(
          '../source/V2TIMManagerImpl.cpp',
        ).readAsStringSync();
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

        final avManagerSource = File(
          '../source/ToxAVManager.cpp',
        ).readAsStringSync();
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
      final source = File('lib/ffi/tim2tox_ffi.dart').readAsStringSync();

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
      final source = File('lib/service/toxav_service.dart').readAsStringSync();

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
  });
}
