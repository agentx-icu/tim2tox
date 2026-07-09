/// ToxAV Media Frames Test — audio/video frame send + receive coverage.
///
/// Closes the Phase 5 gap where call/answer/reject/cancel signaling was
/// covered but the media frame path (sendAudioFrame / sendVideoFrame and the
/// audio/video receive callbacks) had zero automated coverage.
///
/// Scenario: alice calls bob (audio+video bitrates > 0), bob answers, both
/// sides see the call active, then alice sends 20ms 48kHz mono PCM frames
/// (960 samples, sine pattern) and small 64x64 I420 frames. The test asserts
/// bob's ToxAVService audio/video receive callbacks fire with plausible data.
///
/// Mode-aware (single file, no *_virtual_test.dart sibling): runs wall-clock
/// by default and virtual-clock under RUN_VIRTUAL=1 via [shouldRunVirtual],
/// mirroring scenario_toxav_basic_test.dart.
///
/// Codec note: ToxAV is lossy (Opus / VP8). We do NOT assert byte equality of
/// received PCM/YUV — only shape/rate plausibility (sample count > 0,
/// channels >= 1, sampling rate == 48000; width/height > 0, non-empty
/// planes). Frames are also routinely dropped early in a call while RTP/BWC
/// spin up, so sends run in a retry loop until the first receive callback.
///
/// Iteration discipline: the audio/video receive callbacks are direct
/// Pointer.fromFunction trampolines invoked synchronously from inside
/// `toxav_iterate` — they can only ever fire during a Dart-initiated
/// `tim2tox_ffi_av_iterate` call. Under RUN_VIRTUAL=1 [pumpTestTickAv]
/// already drives av-iterate per instance; in wall-clock mode the native
/// event thread only drives `tox_iterate` (never `toxav_iterate`), so this
/// test additionally calls `avIterate` per node from the test isolate — see
/// [_pumpAv].

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/service/toxav_service.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

// Bit flags from toxav.h (Toxav_Friend_Call_State).
const int _kCallStateSendingA = 4; // TOXAV_FRIEND_CALL_STATE_SENDING_A

/// Drives one harness tick in a mode-agnostic way, guaranteeing ToxAV's
/// iterate loop runs on BOTH instances in BOTH clock modes.
///
/// - Virtual mode: [pumpTestTickAv] advances the shared clock and calls
///   iterate + av-iterate per instance already.
/// - Wall mode: [pumpTestTickAv] falls back to tox-only pumping (the event
///   threads drive tox_iterate; nothing drives toxav_iterate), so we call
///   `avIterate` per node explicitly from the Dart thread — which is also
///   the only thread the direct-pointer receive trampolines may run on.
Future<void> _pumpAv(
  TestScenario scenario, {
  int advanceMs = 50,
  int iterationsPerInstance = 1,
  Duration wallSleep = const Duration(milliseconds: 20),
}) async {
  await pumpTestTickAv(
    scenario,
    advanceMs: advanceMs,
    iterationsPerInstance: iterationsPerInstance,
    wallSleep: wallSleep,
  );
  if (!VirtualClock.enabled) {
    final ffi = ffi_lib.Tim2ToxFfi.open();
    for (final node in scenario.nodes) {
      final handle = node.testInstanceHandle;
      if (handle == null) continue;
      try {
        ffi.avIterate(handle);
      } catch (_) {
        // Instance has no ToxAV attached; ignore.
      }
    }
  }
}

void main() {
  group('ToxAV Media Frames Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late ToxAVService aliceAV;
    late ToxAVService bobAV;

    setUpAll(() async {
      await setupTestEnvironment();
      // Enable test mode BEFORE initAllNodes so event_thread never starts.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      // Seed the virtual clock + idempotent per-instance test_mode refresh.
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
      );

      await configureLocalBootstrapVirtual(scenario);

      alice.enableAutoAccept();
      bob.enableAutoAccept();

      print('[Test] setUp - Waiting for connections to establish...');
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 15));

      await waitUntilWithVirtualPump(
        scenario,
        () {
          final aliceToxId = alice.getToxId();
          final bobToxId = bob.getToxId();
          return aliceToxId.length == 76 && bobToxId.length == 76;
        },
        timeout: const Duration(seconds: 10),
        description: 'Tox IDs available',
      );

      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      print('[Test] setUp - Alice Tox ID: $aliceToxId');
      print('[Test] setUp - Bob Tox ID: $bobToxId');

      await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.addFriend(
            userID: bobToxId,
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
            remark: 'Bob',
            addWording: 'test',
          ));
      await bob.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.addFriend(
            userID: aliceToxId,
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
            remark: 'Alice',
            addWording: 'test',
          ));

      // Drive a burst so addFriend auto-accept side-effects propagate.
      for (int i = 0; i < 30; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
      final alicePub = alice.getPublicKey();
      final bobPub = bob.getPublicKey();
      await waitForFriendsInList(alice, [bobPub],
          timeout: const Duration(seconds: 60));
      await waitForFriendsInList(bob, [alicePub],
          timeout: const Duration(seconds: 60));

      print('[Test] setUp - Friend list ready');

      final ffi = ffi_lib.Tim2ToxFfi.open();

      // Availability probe: the loaded library MUST be a real ToxAV build.
      // A stub build (BUILD_TOXAV off) would make every AV call a silent
      // no-op — fail loudly instead of green-washing the media path.
      if (!ffi.avIsAvailable) {
        throw StateError(
            'tim2tox_ffi_av_is_available() != 1 — libtim2tox_ffi is a stub '
            'ToxAV build (BUILD_TOXAV off). Rebuild with ./build_ffi.sh; the '
            'media-frame scenario cannot run against a stub.');
      }

      final aliceInit = await alice.runWithInstanceAsync(() async {
        aliceAV = ToxAVService(ffi);
        return aliceAV.initialize();
      });
      final bobInit = await bob.runWithInstanceAsync(() async {
        bobAV = ToxAVService(ffi);
        return bobAV.initialize();
      });

      expect(aliceInit, isTrue, reason: 'Alice ToxAV initialization failed');
      expect(bobInit, isTrue, reason: 'Bob ToxAV initialization failed');
    });

    tearDownAll(() async {
      // shutdown() resolves the instance via getCurrentInstanceId(), so it
      // must run inside each node's instance context — a bare call would
      // shut down whichever instance happens to be current.
      alice.runWithInstance(() => aliceAV.shutdown());
      bob.runWithInstance(() => bobAV.shutdown());
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test('FFI availability probe - tim2tox_ffi_av_is_available == 1', () {
      final ffi = ffi_lib.Tim2ToxFfi.open();
      expect(ffi.avIsAvailable, isTrue,
          reason:
              'tim2tox_ffi_av_is_available() must return 1 — a stub build '
              '(BUILD_TOXAV off) must never let media-path tests pass '
              'silently.');
      expect(aliceAV.isAvailable, isTrue,
          reason: 'ToxAVService.isAvailable must reflect the real build');
    });

    test('Media frames - alice sends audio+video, bob receives plausible data',
        () async {
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();

      final bobFriendNumber = alice
          .runWithInstance(() => aliceAV.getFriendNumberByUserId(bobToxId));
      final aliceFriendNumber = bob
          .runWithInstance(() => bobAV.getFriendNumberByUserId(aliceToxId));

      expect(bobFriendNumber, isNot(equals(0xFFFFFFFF)),
          reason: 'Bob friend number not found (Tox ID: $bobToxId)');
      expect(aliceFriendNumber, isNot(equals(0xFFFFFFFF)),
          reason: 'Alice friend number not found (Tox ID: $aliceToxId)');

      var bobReceivedCall = false;
      int aliceCallState = 0;
      int bobCallState = 0;

      // -- Audio receive captures (bob side) --
      int audioFrames = 0;
      int lastAudioSampleCount = 0;
      int lastAudioChannels = 0;
      int lastAudioRate = 0;
      int lastAudioPcmLen = 0;
      bool sawNonZeroPcm = false;

      // -- Video receive captures (bob side) --
      int videoFrames = 0;
      int lastVideoWidth = 0;
      int lastVideoHeight = 0;
      int lastYLen = 0;
      int lastULen = 0;
      int lastVLen = 0;
      bool sawNonZeroY = false;

      bobAV.setCallCallback((friendNumber, audioEnabled, videoEnabled) {
        if (friendNumber == aliceFriendNumber) {
          bobReceivedCall = true;
          bob.markCallbackReceived('onCall');
        }
      });
      aliceAV.setCallStateCallback((friendNumber, state) {
        if (friendNumber == bobFriendNumber) aliceCallState = state;
      });
      bobAV.setCallStateCallback((friendNumber, state) {
        if (friendNumber == aliceFriendNumber) bobCallState = state;
      });
      bobAV.setAudioReceiveCallback(
          (friendNumber, pcm, sampleCount, channels, samplingRate) {
        if (friendNumber != aliceFriendNumber) return;
        audioFrames++;
        lastAudioSampleCount = sampleCount;
        lastAudioChannels = channels;
        lastAudioRate = samplingRate;
        lastAudioPcmLen = pcm.length;
        if (!sawNonZeroPcm && pcm.any((s) => s != 0)) sawNonZeroPcm = true;
      });
      bobAV.setVideoReceiveCallback((friendNumber, width, height, y, u, v) {
        if (friendNumber != aliceFriendNumber) return;
        videoFrames++;
        lastVideoWidth = width;
        lastVideoHeight = height;
        lastYLen = y.length;
        lastULen = u.length;
        lastVLen = v.length;
        if (!sawNonZeroY && y.any((b) => b != 0)) sawNonZeroY = true;
      });

      // Wait for friend P2P connection before starting the call.
      print('[Test] Waiting for friend connection before starting call...');
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 60));
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 60));

      for (int i = 0; i < 10; i++) {
        await _pumpAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      // Alice calls Bob with audio+video enabled (bitrates > 0), with retry —
      // friend P2P signaling is flaky in 2-node local-bootstrap setups.
      print('[Test] Alice calling Bob (audio=48 video=4000)...');
      bool callReceived = false;
      for (var attempt = 0; !callReceived && attempt < 3; attempt++) {
        if (attempt > 0) {
          print('[Test] Retrying call (attempt ${attempt + 1})...');
          await alice
              .runWithInstanceAsync(() async => aliceAV.endCall(bobFriendNumber));
          for (int i = 0; i < 5; i++) {
            await _pumpAv(scenario,
                advanceMs: 50,
                iterationsPerInstance: 1,
                wallSleep: const Duration(milliseconds: 30));
          }
          bobReceivedCall = false;
        }
        final callResult = await alice.runWithInstanceAsync(() async =>
            aliceAV.startCall(
              bobFriendNumber,
              audioBitRate: 48,
              videoBitRate: 4000,
            ));
        expect(callResult, isTrue, reason: 'Failed to start call');

        try {
          await waitUntilWithAvVirtualPump(
            scenario,
            () => bobReceivedCall,
            timeout: const Duration(seconds: 25),
            description: 'Bob received call (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30),
          );
          callReceived = true;
        } catch (_) {
          // Try again.
        }
      }
      expect(bobReceivedCall, isTrue,
          reason: 'Bob never received onCall after retries');

      // Bob answers with audio+video enabled.
      print('[Test] Bob answering call (audio=48 video=4000)...');
      final answerResult = await bob.runWithInstanceAsync(() async =>
          bobAV.answerCall(
            aliceFriendNumber,
            audioBitRate: 48,
            videoBitRate: 4000,
          ));
      expect(answerResult, isTrue, reason: 'Failed to answer call');

      // Both sides see the call active:
      //  - alice (caller) sees SENDING_A once bob's MSI answer arrives —
      //    this is the observable "call active" transition and the same
      //    condition scenario_toxav_peer_offline_test.dart waits on;
      //  - bob (callee) saw the call active the moment answerCall returned
      //    true (asserted above). MSI gives the callee NO call-state
      //    callback on answer — it learned the caller's capabilities from
      //    the invite; bob's state callback only fires on later changes —
      //    so a hard wait on bobCallState here would hang.
      print('[Test] Waiting for call to become active...');
      await waitUntilWithAvVirtualPump(
        scenario,
        () => (aliceCallState & _kCallStateSendingA) != 0,
        timeout: const Duration(seconds: 30),
        description: 'Alice sees call active (SENDING_A)',
        advanceMs: 50,
        iterationsPerInstance: 1,
        wallSleep: const Duration(milliseconds: 30),
      );
      print('[Test] Call active: aliceState=$aliceCallState '
          'bobState=$bobCallState (bob answered OK)');

      // ================= AUDIO =================
      // 20ms @ 48kHz mono => 960 samples per frame. Use a 440Hz sine so the
      // Opus encoder gets a recognizable, codec-friendly signal (byte
      // equality is intentionally NOT asserted — lossy codec).
      final pcm = List<int>.generate(
          960, (i) => (8000 * math.sin(2 * math.pi * 440 * i / 48000)).round());

      print('[Test] Sending audio frames until Bob\'s receive callback fires...');
      var audioSendAccepted = 0;
      var audioSendAttempts = 0;
      const maxAudioAttempts = 1200;
      while (audioFrames == 0 && audioSendAttempts < maxAudioAttempts) {
        audioSendAttempts++;
        final ok = await alice.runWithInstanceAsync(() async =>
            aliceAV.sendAudioFrame(bobFriendNumber, pcm, 960, 1, 48000));
        if (ok) audioSendAccepted++;
        await _pumpAv(scenario,
            advanceMs: 20,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 20));
      }
      print('[Test] Audio: attempts=$audioSendAttempts '
          'accepted=$audioSendAccepted received=$audioFrames '
          'sampleCount=$lastAudioSampleCount channels=$lastAudioChannels '
          'rate=$lastAudioRate pcmLen=$lastAudioPcmLen nonZero=$sawNonZeroPcm');

      expect(audioFrames, greaterThan(0),
          reason: 'Bob never received an audio frame '
              '($audioSendAttempts sends, $audioSendAccepted accepted by '
              'toxav_audio_send_frame)');
      expect(lastAudioSampleCount, greaterThan(0),
          reason: 'Received audio frame must have sample count > 0');
      expect(lastAudioChannels, greaterThanOrEqualTo(1),
          reason: 'Received audio frame must have channels >= 1');
      expect(lastAudioRate, equals(48000),
          reason: 'Received audio frame must have sampling rate == 48000');
      expect(lastAudioPcmLen, equals(lastAudioSampleCount * lastAudioChannels),
          reason: 'PCM copy length must match sampleCount * channels');

      // ================= VIDEO =================
      // Small I420 frame: 64x64 => Y = 64*64 bytes, U = V = 32*32 bytes.
      // Distinctive fill: Y row gradient, U/V constant chroma.
      const w = 64, h = 64;
      final yPlane =
          List<int>.generate(w * h, (i) => 16 + ((i ~/ w) * 3) % 220);
      final uPlane = List<int>.filled((w ~/ 2) * (h ~/ 2), 64);
      final vPlane = List<int>.filled((w ~/ 2) * (h ~/ 2), 192);

      print('[Test] Sending video frames until Bob\'s receive callback fires...');
      var videoSendAccepted = 0;
      var videoSendAttempts = 0;
      const maxVideoAttempts = 1200;
      while (videoFrames == 0 && videoSendAttempts < maxVideoAttempts) {
        videoSendAttempts++;
        final ok = await alice.runWithInstanceAsync(() async =>
            aliceAV.sendVideoFrame(bobFriendNumber, w, h, yPlane, uPlane, vPlane));
        if (ok) videoSendAccepted++;
        await _pumpAv(scenario,
            advanceMs: 20,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 20));
      }
      print('[Test] Video: attempts=$videoSendAttempts '
          'accepted=$videoSendAccepted received=$videoFrames '
          'w=$lastVideoWidth h=$lastVideoHeight yLen=$lastYLen uLen=$lastULen '
          'vLen=$lastVLen nonZeroY=$sawNonZeroY');

      expect(videoFrames, greaterThan(0),
          reason: 'Bob never received a video frame '
              '($videoSendAttempts sends, $videoSendAccepted accepted by '
              'toxav_video_send_frame)');
      expect(lastVideoWidth, greaterThan(0),
          reason: 'Received video frame must have width > 0');
      expect(lastVideoHeight, greaterThan(0),
          reason: 'Received video frame must have height > 0');
      expect(lastYLen, greaterThan(0),
          reason: 'Received video frame must have a non-empty Y plane');
      expect(lastULen, greaterThan(0),
          reason: 'Received video frame must have a non-empty U plane');
      expect(lastVLen, greaterThan(0),
          reason: 'Received video frame must have a non-empty V plane');

      // Hang up + drain so tearDown never races an active call.
      print('[Test] Hanging up...');
      final hangupResult = await bob
          .runWithInstanceAsync(() async => bobAV.endCall(aliceFriendNumber));
      expect(hangupResult, isTrue, reason: 'Failed to end call');
      for (int i = 0; i < 10; i++) {
        await _pumpAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
      print('[Test] Media frames test completed '
          '(audio=$audioFrames video=$videoFrames frames received)');
    }, timeout: const Timeout(Duration(seconds: 240)));
  });
}
