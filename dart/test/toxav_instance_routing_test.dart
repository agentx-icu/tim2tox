import 'dart:ffi' as ffi;

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/service/toxav_service.dart';

void main() {
  test(
    'routes AV operations to the instance captured at construction',
    () async {
      final fakeFfi = _RecordingFfi(currentInstanceId: 41);
      final service = ToxAVService(fakeFfi);

      fakeFfi.currentInstanceId = 42;

      expect(await service.initialize(), isTrue);
      expect(await service.startCall(7), isTrue);
      expect(await service.answerCall(7), isTrue);
      expect(await service.endCall(7), isTrue);
      expect(await service.muteAudio(7, true), isTrue);
      expect(await service.muteVideo(7, true), isTrue);
      expect(
        await service.sendAudioFrame(
          7,
          List<int>.filled(960, 0),
          480,
          2,
          48000,
        ),
        isTrue,
      );
      expect(
        await service.sendVideoFrame(
          7,
          2,
          2,
          List<int>.filled(4, 0),
          List<int>.filled(1, 0),
          List<int>.filled(1, 0),
        ),
        isTrue,
      );
      expect(await service.setAudioBitRate(7, 48), isTrue);
      expect(await service.setVideoBitRate(7, 5000), isTrue);
      expect(service.getFriendConnectionStatus(7), 1);
      expect(await service.enableConferenceAudio('group-1'), isTrue);
      expect(
        await service.sendConferenceAudioFrame(
          'group-1',
          List<int>.filled(960, 0),
          480,
          2,
          48000,
        ),
        isTrue,
      );
      expect(await service.muteConferenceAudio('group-1', true), isTrue);
      expect(await service.disableConferenceAudio('group-1'), isTrue);
      service.shutdown();

      expect(
        fakeFfi.calls,
        everyElement(
          predicate<_RecordedCall>((call) => call.instanceId == 41),
        ),
      );
    },
  );

  test('keeps default-instance AV operations on instance zero', () async {
    final fakeFfi = _RecordingFfi(currentInstanceId: 0);
    final service = ToxAVService(fakeFfi);

    expect(await service.initialize(), isTrue);
    service.shutdown();

    expect(
      fakeFfi.calls,
      everyElement(
        predicate<_RecordedCall>((call) => call.instanceId == 0),
      ),
    );
  });
}

class _RecordedCall {
  const _RecordedCall(this.operation, this.instanceId);

  final String operation;
  final int instanceId;
}

class _RecordingFfi implements Tim2ToxFfi {
  _RecordingFfi({required this.currentInstanceId});

  int currentInstanceId;
  final calls = <_RecordedCall>[];

  void _record(String operation, int instanceId) {
    calls.add(_RecordedCall(operation, instanceId));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #avConferenceSendAudioFrame) {
      _record('sendConferenceAudioFrame',
          invocation.positionalArguments[0] as int);
      return 1;
    }
    if (invocation.memberName == #avConferenceEnable) {
      _record('enableConferenceAudio',
          invocation.positionalArguments[0] as int);
      return 1;
    }
    if (invocation.memberName == #avConferenceDisable) {
      _record('disableConferenceAudio',
          invocation.positionalArguments[0] as int);
      return 1;
    }
    if (invocation.memberName == #avConferenceMute) {
      _record('muteConferenceAudio',
          invocation.positionalArguments[0] as int);
      return 1;
    }
    if (!invocation.isGetter) {
      return super.noSuchMethod(invocation);
    }

    return switch (invocation.memberName) {
      #getCurrentInstanceId => () => currentInstanceId,
      #avInitialize => (int instanceId) {
          _record('initialize', instanceId);
          return 1;
        },
      #avShutdown => (int instanceId) => _record('shutdown', instanceId),
      #avStartCallNative => (int instanceId, int _, int __, int ___) {
          _record('startCall', instanceId);
          return 1;
        },
      #avAnswerCallNative => (int instanceId, int _, int __, int ___) {
          _record('answerCall', instanceId);
          return 1;
        },
      #avEndCallNative => (int instanceId, int _) {
          _record('endCall', instanceId);
          return 1;
        },
      #avMuteAudioNative => (int instanceId, int _, int __) {
          _record('muteAudio', instanceId);
          return 1;
        },
      #avMuteVideoNative => (int instanceId, int _, int __) {
          _record('muteVideo', instanceId);
          return 1;
        },
      #avSendAudioFrameNative =>
        (int instanceId, int _, ffi.Pointer<ffi.Int16> __, int ___, int ____, int _____) {
          _record('sendAudioFrame', instanceId);
          return 1;
        },
      #avSendVideoFrameNative =>
        (int instanceId, int _, int __, int ___, ffi.Pointer<ffi.Uint8> ____,
            ffi.Pointer<ffi.Uint8> _____, ffi.Pointer<ffi.Uint8> ______, int _______,
            int ________, int _________) {
          _record('sendVideoFrame', instanceId);
          return 1;
        },
      #avSetAudioBitRateNative => (int instanceId, int _, int __) {
          _record('setAudioBitRate', instanceId);
          return 1;
        },
      #avSetVideoBitRateNative => (int instanceId, int _, int __) {
          _record('setVideoBitRate', instanceId);
          return 1;
        },
      #getFriendConnectionStatusNative => (int instanceId, int _) {
          _record('getFriendConnectionStatus', instanceId);
          return 1;
        },
      #avSetCallCallbackNative ||
      #avSetCallStateCallbackNative ||
      #avSetAudioReceiveCallbackNative ||
      #avSetVideoReceiveCallbackNative ||
      #avSetAudioBitrateCallbackNative ||
      #avSetVideoBitrateCallbackNative ||
      #avConferenceSetAudioReceiveCallbackNative =>
        (int _, Object __, Object ___) {},
      _ => super.noSuchMethod(invocation),
    };
  }
}
