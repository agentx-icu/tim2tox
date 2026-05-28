// Ported from c-toxcore scenario_toxav_peer_offline_test.c (virtual-clock variant).

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/service/toxav_service.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

// Bit flags from toxav.h (Toxav_Friend_Call_State).
const int _kCallStateError = 1; // TOXAV_FRIEND_CALL_STATE_ERROR
const int _kCallStateFinished = 2; // TOXAV_FRIEND_CALL_STATE_FINISHED
const int _kCallStateSendingA = 4; // TOXAV_FRIEND_CALL_STATE_SENDING_A

void main() {
  group('ToxAV Peer Offline Test', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late ToxAVService aliceAV;
    late ToxAVService bobAV;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();

      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
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

      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 15));

      await waitUntilWithVirtualPump(
        scenario,
        () {
          final a = alice.getToxId();
          final b = bob.getToxId();
          return a.length == 76 && b.length == 76;
        },
        timeout: const Duration(seconds: 10),
        description: 'Tox IDs available',
      );

      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();

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

      // Drive a burst so auto-accept side-effects propagate.
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

    test('Alice notices Bob offline after deleting friend during active call',
        () async {
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();

      final bobFriendNumber = alice
          .runWithInstance(() => aliceAV.getFriendNumberByUserId(bobToxId));
      final aliceFriendNumber = bob
          .runWithInstance(() => bobAV.getFriendNumberByUserId(aliceToxId));

      expect(bobFriendNumber, isNot(equals(0xFFFFFFFF)),
          reason: 'Bob friend number not found');
      expect(aliceFriendNumber, isNot(equals(0xFFFFFFFF)),
          reason: 'Alice friend number not found');

      var bobReceivedCall = false;
      int aliceLastState = 0;
      int bobLastState = 0;
      int aliceStateUpdates = 0;

      bobAV.setCallCallback((friendNumber, audioEnabled, videoEnabled) {
        if (friendNumber == aliceFriendNumber) {
          bobReceivedCall = true;
          bob.markCallbackReceived('onCall');
        }
      });
      aliceAV.setCallStateCallback((friendNumber, state) {
        if (friendNumber == bobFriendNumber) {
          aliceLastState = state;
          aliceStateUpdates++;
          alice.markCallbackReceived('onAliceCallState');
        }
      });
      bobAV.setCallStateCallback((friendNumber, state) {
        if (friendNumber == aliceFriendNumber) {
          bobLastState = state;
        }
      });

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

      // Alice calls Bob (audio only — matches the c-toxcore variant).
      // Friend P2P on 2-node loopback can be flaky; retry the call until
      // Bob's onCall fires.
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
        final callResult = await alice.runWithInstanceAsync(() async =>
            aliceAV.startCall(
              bobFriendNumber,
              audioBitRate: 48,
              videoBitRate: 0,
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
        } catch (_) {}
      }
      expect(bobReceivedCall, isTrue,
          reason: 'Bob never received onCall after retries');

      // Bob answers.
      final answerResult = await bob.runWithInstanceAsync(() async =>
          bobAV.answerCall(
            aliceFriendNumber,
            audioBitRate: 48,
            videoBitRate: 0,
          ));
      expect(answerResult, isTrue, reason: 'Failed to answer call');

      // Wait until Alice sees SENDING_A (call active).
      await waitUntilWithAvVirtualPump(
        scenario,
        () => (aliceLastState & _kCallStateSendingA) != 0,
        timeout: const Duration(seconds: 25),
        description: 'Alice sees call active (SENDING_A)',
        advanceMs: 50,
        iterationsPerInstance: 1,
        wallSleep: const Duration(milliseconds: 30),
      );

      // Take Bob "offline" w.r.t. Alice's ToxAV by removing him from her
      // friend list — mirrors c-toxcore tox_friend_delete. After delete,
      // tox_friend_get_connection_status() inside toxav_iterate returns NONE,
      // which routes to msi_call_timeout and ends the call with FINISHED.
      final bobPub = bob.getPublicKey();
      final deleteResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.deleteFromFriendList(
            userIDList: [bobPub],
            deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
          ));
      expect(deleteResult.code, equals(0),
          reason: 'Failed to delete Bob from Alice friend list');

      final stateUpdatesBefore = aliceStateUpdates;

      // Iterate ToxAV on Alice's side so the is_offline branch executes
      // without crashing (UAF regression check from the original) AND so
      // Alice's state callback fires the FINISHED transition.
      await waitUntilWithAvVirtualPump(
        scenario,
        () =>
            (aliceLastState & (_kCallStateFinished | _kCallStateError)) != 0,
        timeout: const Duration(seconds: 30),
        description: 'Alice call ends after Bob goes offline',
        advanceMs: 100,
        iterationsPerInstance: 1,
        wallSleep: const Duration(milliseconds: 30),
      );

      expect(aliceStateUpdates, greaterThan(stateUpdatesBefore),
          reason:
              'Alice should have received at least one extra call-state update '
              'after Bob went offline');
      expect((aliceLastState & (_kCallStateFinished | _kCallStateError)) != 0,
          isTrue,
          reason:
              'Alice call should be FINISHED or ERROR after peer offline, got '
              '$aliceLastState (bob last state was $bobLastState)');
    }, timeout: const Timeout(Duration(seconds: 240)));
  });
}
