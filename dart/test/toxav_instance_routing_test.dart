import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/service/toxav_service.dart';

Directory _tim2ToxRoot() {
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

String _dartPackageRoot() => path.join(_tim2ToxRoot().path, 'dart');

String _readDartSource(String relativePath) =>
    File(path.join(_dartPackageRoot(), relativePath)).readAsStringSync();

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

  test('binds friend lookup to the captured instance', () {
    final fakeFfi = _RecordingFfi(currentInstanceId: 41);
    final service = ToxAVService(fakeFfi);
    final ffiSource = _readDartSource('lib/ffi/tim2tox_ffi.dart');

    fakeFfi.currentInstanceId = 42;

    expect(service.getFriendNumberByUserId('friend-user-id'), equals(7));

    final lookupCalls = fakeFfi.calls.where(
      (call) => call.operation == 'getFriendNumberByUserId',
    );
    expect(
      lookupCalls,
      hasLength(1),
      reason: 'friend lookup must use the instance captured at construction',
    );
    expect(lookupCalls.single.instanceId, equals(41));

    expect(
      ffiSource,
      contains('tim2tox_ffi_get_friend_number_by_user_id_for_instance'),
      reason: 'friend lookup needs an instance-scoped native binding',
    );
    expect(
      ffiSource,
      contains("tim2tox_ffi_get_friend_number_by_user_id');"),
      reason: 'the additive instance-scoped binding must retain legacy ABI',
    );
  });

  test(
    'falls back to the legacy friend lookup only for the default instance',
    () {
      final fakeFfi = _RecordingFfi(currentInstanceId: 0)
        ..missingFriendLookupForInstanceNative = true;
      final service = ToxAVService(fakeFfi);

      expect(service.getFriendNumberByUserId('friend-user-id'), equals(7));

      final legacyCalls = fakeFfi.calls.where(
        (call) => call.operation == 'getFriendNumberByUserIdLegacy',
      );
      expect(legacyCalls, hasLength(1));
      expect(legacyCalls.single.instanceId, equals(0));
    },
  );

  test(
    'does not fall back to ambient friend lookup for nonzero instances',
    () {
      final fakeFfi = _RecordingFfi(currentInstanceId: 41)
        ..missingFriendLookupForInstanceNative = true;
      final service = ToxAVService(fakeFfi);

      expect(
        service.getFriendNumberByUserId('friend-user-id'),
        equals(0xFFFFFFFF),
      );

      final legacyCalls = fakeFfi.calls.where(
        (call) => call.operation == 'getFriendNumberByUserIdLegacy',
      );
      expect(legacyCalls, isEmpty);
    },
  );

  test('ignores a missing conference clear-pending binding', () {
    final fakeFfi = _RecordingFfi(currentInstanceId: 41)
      ..missingConferenceClearPendingAudioNative = true;
    final service = ToxAVService(fakeFfi);

    expect(
      () => service.setConferenceAudioReceiveCallback(
        (
          String _,
          int __,
          int ___,
          List<int> ____,
          int _____,
          int ______,
          int _______,
        ) {},
      ),
      returnsNormally,
    );
  });

  test('clears the route on shutdown before init', () {
    final fakeFfi = _RecordingFfi(currentInstanceId: 41);
    final service = ToxAVService(fakeFfi);
    final calls = <int>[];

    service.setCallCallback((friendNumber, _, __) {
      calls.add(friendNumber);
    });

    service.shutdown();
    ToxAVService.dispatchAvCall(41, 7, true, false);

    expect(
      calls,
      isEmpty,
      reason: 'shutdown before init should clear the static route',
    );
  });

  test('re-registers the route after init shutdown init', () async {
    final fakeFfi = _RecordingFfi(currentInstanceId: 41);
    final service = ToxAVService(fakeFfi);
    final calls = <int>[];

    service.setCallCallback((friendNumber, _, __) {
      calls.add(friendNumber);
    });

    expect(await service.initialize(), isTrue);
    service.shutdown();
    expect(await service.initialize(), isTrue);

    ToxAVService.dispatchAvCall(41, 9, true, false);

    expect(
      calls,
      orderedEquals([9]),
      reason: 'reinitialize should restore instance routing',
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
  bool missingConferenceClearPendingAudioNative = false;
  bool missingFriendLookupForInstanceNative = false;
  bool missingLegacyFriendLookupNative = false;
  final calls = <_RecordedCall>[];

  void _record(String operation, int instanceId) {
    calls.add(_RecordedCall(operation, instanceId));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #avConferenceClearPendingAudioNative &&
        missingConferenceClearPendingAudioNative) {
      throw ArgumentError('missing avConferenceClearPendingAudioNative');
    }
    if (invocation.memberName == #getFriendNumberByUserIdForInstanceNative &&
        missingFriendLookupForInstanceNative) {
      throw ArgumentError('missing getFriendNumberByUserIdForInstanceNative');
    }
    if (invocation.memberName == #getFriendNumberByUserIdNative &&
        missingLegacyFriendLookupNative) {
      throw ArgumentError('missing getFriendNumberByUserIdNative');
    }
    if (invocation.memberName == #avConferenceSendAudioFrame) {
      _record(
          'sendConferenceAudioFrame', invocation.positionalArguments[0] as int);
      return 1;
    }
    if (invocation.memberName == #avConferenceEnable) {
      _record(
          'enableConferenceAudio', invocation.positionalArguments[0] as int);
      return 1;
    }
    if (invocation.memberName == #avConferenceDisable) {
      _record(
          'disableConferenceAudio', invocation.positionalArguments[0] as int);
      return 1;
    }
    if (invocation.memberName == #avConferenceMute) {
      _record('muteConferenceAudio', invocation.positionalArguments[0] as int);
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
      #avSendAudioFrameNative => (int instanceId, int _,
            ffi.Pointer<ffi.Int16> __, int ___, int ____, int _____) {
          _record('sendAudioFrame', instanceId);
          return 1;
        },
      #avSendVideoFrameNative => (int instanceId,
            int _,
            int __,
            int ___,
            ffi.Pointer<ffi.Uint8> ____,
            ffi.Pointer<ffi.Uint8> _____,
            ffi.Pointer<ffi.Uint8> ______,
            int _______,
            int ________,
            int _________) {
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
      #getFriendNumberByUserIdNative => (ffi.Pointer<pkgffi.Utf8> _) {
          _record('getFriendNumberByUserIdLegacy', currentInstanceId);
          return 7;
        },
      #getFriendNumberByUserIdForInstanceNative =>
        (int instanceId, ffi.Pointer<pkgffi.Utf8> _) {
          _record('getFriendNumberByUserId', instanceId);
          return 7;
        },
      #avSetCallCallbackNative ||
      #avSetCallStateCallbackNative ||
      #avSetAudioReceiveCallbackNative ||
      #avSetVideoReceiveCallbackNative ||
      #avSetAudioBitrateCallbackNative ||
      #avSetVideoBitrateCallbackNative ||
      #avConferenceSetAudioReceiveCallbackNative =>
        (int _, Object __, Object ___) {},
      #avConferenceClearPendingAudioNative => (int instanceId) =>
          _record('clearPendingConferenceAudio', instanceId),
      _ => super.noSuchMethod(invocation),
    };
  }
}
