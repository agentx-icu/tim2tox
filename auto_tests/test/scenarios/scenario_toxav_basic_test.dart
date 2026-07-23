/// ToxAV Basic Test — virtual-clock variant
///
/// Mirrors scenario_toxav_basic_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers. Uses [pumpTestTickAv] / [waitUntilWithAvVirtualPump]
/// so ToxAV's own iteration loop (av_iterate) is driven in addition to
/// tox_iterate — call-state transitions and audio/video frame callbacks
/// otherwise never fire under virtual mode.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/service/toxav_service.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('ToxAV Basic Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late ToxAVService aliceAV;
    late ToxAVService bobAV;
    int _toxavTestsCompleted = 0;

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

      // Enable auto-accept so friend additions succeed without a C++ default.
      alice.enableAutoAccept();
      bob.enableAutoAccept();

      print('[Test] setUp - Waiting for connections to establish...');
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 15));

      // Wait for Tox IDs to be available
      print('[Test] setUp - Waiting for Tox IDs to be available...');
      await waitUntilWithVirtualPump(
        scenario,
        () {
          final aliceToxId = alice.getToxId();
          final bobToxId = bob.getToxId();
          return aliceToxId.isNotEmpty &&
              aliceToxId.length == 76 &&
              bobToxId.isNotEmpty &&
              bobToxId.length == 76;
        },
        timeout: const Duration(seconds: 10),
        description: 'Tox IDs available',
      );

      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      print(
          '[Test] setUp - Alice Tox ID: $aliceToxId (length=${aliceToxId.length})');
      print('[Test] setUp - Bob Tox ID: $bobToxId (length=${bobToxId.length})');

      // Add friends using actual Tox IDs
      print('[Test] setUp - Adding friends using actual Tox IDs...');
      await alice.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: bobToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Bob',
                addWording: 'test',
              ));
      await bob.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: aliceToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Alice',
                addWording: 'test',
              ));

      // Friend list populate. Drive a burst of pump first so addFriend
      // auto-accept side-effects propagate, then poll the friend list via
      // the wall-clock helper (friend-list reads are local SDK lookups, the
      // helper just needs time which the surrounding pump bursts provide).
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

      // Create and initialize ToxAV for each node inside instance context.
      final ffi = ffi_lib.Tim2ToxFfi.open();
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
      aliceAV.shutdown();
      bobAV.shutdown();
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      if (_toxavTestsCompleted == 0) return;
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      if (bobToxId.isEmpty ||
          aliceToxId.isEmpty ||
          bobToxId.length != 76 ||
          aliceToxId.length != 76) {
        return;
      }
      final bobFriendNumber = alice
          .runWithInstance(() => aliceAV.getFriendNumberByUserId(bobToxId));
      final aliceFriendNumber =
          bob.runWithInstance(() => bobAV.getFriendNumberByUserId(aliceToxId));
      if (bobFriendNumber == 0xFFFFFFFF || aliceFriendNumber == 0xFFFFFFFF) {
        return;
      }
      await alice
          .runWithInstanceAsync(() async => aliceAV.endCall(bobFriendNumber));
      await bob
          .runWithInstanceAsync(() async => bobAV.endCall(aliceFriendNumber));
      // Drive virtual clock + AV iterate so hangup packets propagate.
      for (int i = 0; i < 30; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
    });

    test('Regular AV call - answer and hang up', () async {
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      print('[Test] Alice Tox ID: $aliceToxId');
      print('[Test] Bob Tox ID: $bobToxId');

      final bobFriendNumber = alice
          .runWithInstance(() => aliceAV.getFriendNumberByUserId(bobToxId));
      final aliceFriendNumber =
          bob.runWithInstance(() => bobAV.getFriendNumberByUserId(aliceToxId));

      print('[Test] Alice sees Bob as friend number: $bobFriendNumber');
      print('[Test] Bob sees Alice as friend number: $aliceFriendNumber');

      expect(bobFriendNumber, isNot(equals(0xFFFFFFFF)),
          reason: 'Bob friend number not found (Tox ID: $bobToxId)');
      expect(aliceFriendNumber, isNot(equals(0xFFFFFFFF)),
          reason: 'Alice friend number not found (Tox ID: $aliceToxId)');

      var bobReceivedCall = false;

      bobAV.setCallCallback((friendNumber, audioEnabled, videoEnabled) {
        if (friendNumber == aliceFriendNumber) {
          bobReceivedCall = true;
          bob.markCallbackReceived('onCall');
        }
      });

      aliceAV.setCallStateCallback((friendNumber, state) {});
      bobAV.setCallStateCallback((friendNumber, state) {});

      // Wait for friend P2P connection before starting the call.
      print('[Test] Waiting for friend connection before starting call...');
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 60));
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 60));

      print(
          '[Test] Iterating ToxAV to ensure friend connection is established...');
      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      // Alice calls Bob with retry — friend P2P signaling is flaky in 2-node.
      print('[Test] Alice calling Bob...');
      bool callReceived = false;
      for (var attempt = 0; !callReceived && attempt < 3; attempt++) {
        if (attempt > 0) {
          print('[Test] Retrying call (attempt ${attempt + 1})...');
          await alice.runWithInstanceAsync(
              () async => aliceAV.endCall(bobFriendNumber));
          for (int i = 0; i < 5; i++) {
            await pumpTestTickAv(scenario,
                advanceMs: 50,
                iterationsPerInstance: 1,
                wallSleep: const Duration(milliseconds: 30));
          }
          bobReceivedCall = false;
        }
        final callResult =
            await alice.runWithInstanceAsync(() async => aliceAV.startCall(
                  bobFriendNumber,
                  audioBitRate: 48,
                  videoBitRate: 4000,
                ));
        expect(callResult, isTrue, reason: 'Failed to start call');
        print('[Test] Alice call started: $callResult');

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
          // Try again
        }
      }
      expect(bobReceivedCall, isTrue,
          reason: 'Bob never received onCall after retries');

      // Bob answers
      print('[Test] Bob answering call...');
      final answerResult =
          await bob.runWithInstanceAsync(() async => bobAV.answerCall(
                aliceFriendNumber,
                audioBitRate: 48,
                videoBitRate: 4000,
              ));
      expect(answerResult, isTrue, reason: 'Failed to answer call');

      // Process call establishment
      for (int i = 0; i < 20; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      // Bob hangs up
      final hangupResult = await bob
          .runWithInstanceAsync(() async => bobAV.endCall(aliceFriendNumber));
      expect(hangupResult, isTrue, reason: 'Failed to end call');

      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
      _toxavTestsCompleted++;
      print('[Test] Regular AV call test completed');
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('Reject flow - Bob rejects call', () async {
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      print('[Test] Reject test - Alice Tox ID: $aliceToxId');
      print('[Test] Reject test - Bob Tox ID: $bobToxId');

      final bobFriendNumber = alice
          .runWithInstance(() => aliceAV.getFriendNumberByUserId(bobToxId));
      final aliceFriendNumber =
          bob.runWithInstance(() => bobAV.getFriendNumberByUserId(aliceToxId));

      expect(bobFriendNumber, isNot(equals(0xFFFFFFFF)),
          reason: 'Bob friend number not found');
      expect(aliceFriendNumber, isNot(equals(0xFFFFFFFF)),
          reason: 'Alice friend number not found');

      var bobReceivedCall = false;

      bobAV.setCallCallback((friendNumber, audioEnabled, videoEnabled) {
        if (friendNumber == aliceFriendNumber) {
          bobReceivedCall = true;
          bob.markCallbackReceived('onCall');
        }
      });

      aliceAV.setCallStateCallback((friendNumber, state) {});

      print('[Test] Reject test - Waiting for friend connection...');
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 60));
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 60));

      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      bool callReceived = false;
      for (var attempt = 0; !callReceived && attempt < 3; attempt++) {
        if (attempt > 0) {
          await alice.runWithInstanceAsync(
              () async => aliceAV.endCall(bobFriendNumber));
          for (int i = 0; i < 5; i++) {
            await pumpTestTickAv(scenario,
                advanceMs: 50,
                iterationsPerInstance: 1,
                wallSleep: const Duration(milliseconds: 30));
          }
          bobReceivedCall = false;
        }
        final callResult =
            await alice.runWithInstanceAsync(() async => aliceAV.startCall(
                  bobFriendNumber,
                  audioBitRate: 48,
                  videoBitRate: 0,
                ));
        expect(callResult, isTrue);
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
        } on TimeoutException catch (e) {
          // Expected between retry attempts (the post-loop expect enforces the
          // real assertion); a non-timeout error is a real bug and propagates.
          print('[Test] Attempt timed out; retrying: $e');
        }
      }
      expect(bobReceivedCall, isTrue,
          reason: 'Bob never received onCall after retries');

      print('[Test] Reject test - Bob rejecting call...');
      final rejectResult = await bob
          .runWithInstanceAsync(() async => bobAV.endCall(aliceFriendNumber));
      expect(rejectResult, isTrue, reason: 'Failed to reject call');

      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
      _toxavTestsCompleted++;
      print('[Test] Reject flow test completed');
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('Cancel flow - Alice cancels call', () async {
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      print('[Test] Cancel test - Alice Tox ID: $aliceToxId');
      print('[Test] Cancel test - Bob Tox ID: $bobToxId');

      final bobFriendNumber = alice
          .runWithInstance(() => aliceAV.getFriendNumberByUserId(bobToxId));
      final aliceFriendNumber =
          bob.runWithInstance(() => bobAV.getFriendNumberByUserId(aliceToxId));

      expect(bobFriendNumber, isNot(equals(0xFFFFFFFF)));
      expect(aliceFriendNumber, isNot(equals(0xFFFFFFFF)));

      var bobReceivedCall = false;

      bobAV.setCallCallback((friendNumber, audioEnabled, videoEnabled) {
        if (friendNumber == aliceFriendNumber) {
          bobReceivedCall = true;
          bob.markCallbackReceived('onCall');
        }
      });
      bobAV.setCallStateCallback((friendNumber, state) {});

      print('[Test] Cancel test - Waiting for friend connection...');
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 60));
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 60));

      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      bool callReceived = false;
      for (var attempt = 0; !callReceived && attempt < 3; attempt++) {
        if (attempt > 0) {
          await alice.runWithInstanceAsync(
              () async => aliceAV.endCall(bobFriendNumber));
          for (int i = 0; i < 5; i++) {
            await pumpTestTickAv(scenario,
                advanceMs: 50,
                iterationsPerInstance: 1,
                wallSleep: const Duration(milliseconds: 30));
          }
          bobReceivedCall = false;
        }
        final callResult =
            await alice.runWithInstanceAsync(() async => aliceAV.startCall(
                  bobFriendNumber,
                  audioBitRate: 48,
                  videoBitRate: 0,
                ));
        expect(callResult, isTrue);
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
        } on TimeoutException catch (e) {
          // Expected between retry attempts (the post-loop expect enforces the
          // real assertion); a non-timeout error is a real bug and propagates.
          print('[Test] Attempt timed out; retrying: $e');
        }
      }
      expect(bobReceivedCall, isTrue,
          reason: 'Bob never received onCall after retries');

      print('[Test] Cancel test - Alice canceling call...');
      final cancelResult = await alice
          .runWithInstanceAsync(() async => aliceAV.endCall(bobFriendNumber));
      expect(cancelResult, isTrue, reason: 'Failed to cancel call');

      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
      _toxavTestsCompleted++;
      print('[Test] Cancel flow test completed');
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
