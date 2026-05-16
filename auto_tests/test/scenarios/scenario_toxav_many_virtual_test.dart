/// ToxAV Many Test — virtual-clock variant
///
/// Mirrors scenario_toxav_many_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers and pumpTestTickAv (ToxAV's iterate loop is not
/// driven by regular pumpTestTick).

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/service/toxav_service.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('ToxAV Many Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode alice;
    late List<TestNode> bobs;
    late ToxAVService aliceAV;
    late List<ToxAVService> bobAVs;

    const numBobs = 3;

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();

      final aliases = ['alice', ...List.generate(numBobs, (i) => 'bob_$i')];
      scenario = await createTestScenario(aliases);

      alice = scenario.getNode('alice')!;
      bobs = List.generate(numBobs, (i) => scenario.getNode('bob_$i')!);

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        ...bobs.map((bob) => bob.login()),
      ]);

      await waitUntil(
        () => alice.loggedIn && bobs.every((bob) => bob.loggedIn),
        timeout: const Duration(seconds: 10),
      );

      await configureLocalBootstrapVirtual(scenario);

      alice.enableAutoAccept();
      for (final bob in bobs) {
        bob.enableAutoAccept();
      }

      print('[Test] setUp - Waiting for connections to establish...');
      try {
        await waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 15));
        for (final bob in bobs) {
          await waitForConnectionVirtual(scenario, bob,
              timeout: const Duration(seconds: 15));
        }
      } catch (e) {
        print('[Test] setUp - Warning: Connection wait timeout, continuing: $e');
      }

      // Drive virtual clock so Tox IDs settle.
      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      final aliceToxId = alice.getToxId();
      print(
          '[Test] setUp - Alice Tox ID: $aliceToxId (length=${aliceToxId.length})');
      if (aliceToxId.isEmpty || aliceToxId.length != 76) {
        throw Exception(
            'Invalid Alice Tox ID: $aliceToxId (expected 76 hex chars)');
      }

      final bobToxIds = <String>[];
      for (int i = 0; i < numBobs; i++) {
        final bobToxId = bobs[i].getToxId();
        bobToxIds.add(bobToxId);
        print('[Test] setUp - Bob $i Tox ID: $bobToxId');
        if (bobToxId.isEmpty || bobToxId.length != 76) {
          throw Exception('Invalid Bob $i Tox ID: $bobToxId');
        }
      }

      // Add friends serially (FFI uses global current instance — parallel
      // friend additions can race and pick the wrong instance).
      print('[Test] setUp - Adding friends...');
      for (int i = 0; i < numBobs; i++) {
        await alice.runWithInstanceAsync(() async {
          await TIMFriendshipManager.instance.addFriend(
            userID: bobToxIds[i],
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
            remark: 'Bob $i',
            addWording: 'test',
          );
        });
        await bobs[i].runWithInstanceAsync(() async {
          await TIMFriendshipManager.instance.addFriend(
            userID: aliceToxId,
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
            remark: 'Alice',
            addWording: 'test',
          );
        });
      }

      // Pump so requests propagate / auto-accept.
      for (int i = 0; i < 50; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      final alicePub = alice.getPublicKey();
      final bobPubs = bobs.map((b) => b.getPublicKey()).toList();
      await waitForFriendsInList(alice, bobPubs,
          timeout: const Duration(seconds: 120));
      for (int i = 0; i < numBobs; i++) {
        await waitForFriendsInList(bobs[i], [alicePub],
            timeout: const Duration(seconds: 120));
      }
      // Extra pump for multi-node P2P propagation.
      for (int i = 0; i < 30; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
      print('[Test] setUp - Friend list ready');

      final ffi = ffi_lib.Tim2ToxFfi.open();
      final aliceInit = await alice.runWithInstanceAsync(() async {
        aliceAV = ToxAVService(ffi);
        return aliceAV.initialize();
      });
      expect(aliceInit, isTrue, reason: 'Alice ToxAV initialization failed');

      bobAVs = [];
      for (int i = 0; i < numBobs; i++) {
        final bobInit = await bobs[i].runWithInstanceAsync(() async {
          final bobAV = ToxAVService(ffi);
          final ok = await bobAV.initialize();
          bobAVs.add(bobAV);
          return ok;
        });
        expect(bobInit, isTrue, reason: 'Bob $i ToxAV initialization failed');
      }
    });

    tearDownAll(() async {
      aliceAV.shutdown();
      for (final bobAV in bobAVs) {
        bobAV.shutdown();
      }
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test('Multiple simultaneous AV calls', () async {
      final aliceToxId = alice.getToxId();
      final bobToxIds = bobs.map((bob) => bob.getToxId()).toList();

      final bobFriendNumbers = <int>[];
      final aliceFriendNumbers = <int>[];

      for (int i = 0; i < numBobs; i++) {
        final bobFriendNumber = alice.runWithInstance(
            () => aliceAV.getFriendNumberByUserId(bobToxIds[i]));
        final aliceFriendNumber = bobs[i].runWithInstance(
            () => bobAVs[i].getFriendNumberByUserId(aliceToxId));

        expect(bobFriendNumber, isNot(equals(0xFFFFFFFF)),
            reason: 'Bob $i friend number not found');
        expect(aliceFriendNumber, isNot(equals(0xFFFFFFFF)),
            reason: 'Alice friend number not found for Bob $i');

        bobFriendNumbers.add(bobFriendNumber);
        aliceFriendNumbers.add(aliceFriendNumber);
      }

      final bobReceivedCalls = List.generate(numBobs, (_) => false);
      final bobCallStates = List.generate(numBobs, (_) => 0);

      for (int i = 0; i < numBobs; i++) {
        bobAVs[i].setCallCallback((friendNumber, audioEnabled, videoEnabled) {
          if (friendNumber == aliceFriendNumbers[i]) {
            bobReceivedCalls[i] = true;
            bobs[i].markCallbackReceived('onCall');
          }
        });
        bobAVs[i].setCallStateCallback((friendNumber, state) {
          if (friendNumber == aliceFriendNumbers[i]) {
            bobCallStates[i] = state;
          }
        });
      }

      print('[Test] Waiting for friend connections...');
      await waitForFriendConnectionVirtual(scenario, alice, bobToxIds[0],
          timeout: const Duration(seconds: 90));
      for (int i = 0; i < numBobs; i++) {
        await waitForFriendConnectionVirtual(scenario, bobs[i], aliceToxId,
            timeout: const Duration(seconds: 90));
      }

      print('[Test] Iterating ToxAV to ensure connections...');
      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      // Alice calls all Bobs (with retry per call).
      for (int i = 0; i < numBobs; i++) {
        bool callReceivedI = false;
        for (var attempt = 0; !callReceivedI && attempt < 3; attempt++) {
          if (attempt > 0) {
            await alice.runWithInstanceAsync(
                () async => aliceAV.endCall(bobFriendNumbers[i]));
            for (int k = 0; k < 5; k++) {
              await pumpTestTickAv(scenario,
                  advanceMs: 50,
                  iterationsPerInstance: 1,
                  wallSleep: const Duration(milliseconds: 30));
            }
            bobReceivedCalls[i] = false;
          }
          final callResult = await alice.runWithInstanceAsync(() async =>
              aliceAV.startCall(
                bobFriendNumbers[i],
                audioBitRate: 48,
                videoBitRate: 3000,
              ));
          expect(callResult, isTrue, reason: 'Failed to call Bob $i');
          try {
            await waitUntilWithAvVirtualPump(
              scenario,
              () => bobReceivedCalls[i],
              timeout: const Duration(seconds: 25),
              description:
                  'Bob $i received call (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
              wallSleep: const Duration(milliseconds: 30),
            );
            callReceivedI = true;
          } catch (_) {}
        }
        expect(bobReceivedCalls[i], isTrue,
            reason: 'Bob $i never received call after retries');
      }

      // All Bobs answer
      for (int i = 0; i < numBobs; i++) {
        final answerResult = await bobs[i].runWithInstanceAsync(() async =>
            bobAVs[i].answerCall(
              aliceFriendNumbers[i],
              audioBitRate: 8,
              videoBitRate: 500,
            ));
        expect(answerResult, isTrue, reason: 'Bob $i failed to answer');
      }

      for (int i = 0; i < 20; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      // Alice hangs up all calls
      for (int i = 0; i < numBobs; i++) {
        final hangupResult = await alice.runWithInstanceAsync(
            () async => aliceAV.endCall(bobFriendNumbers[i]));
        expect(hangupResult, isTrue, reason: 'Failed to hang up Bob $i');
      }

      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 50,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
      print('[Test] Multiple simultaneous AV calls test completed');
    }, timeout: const Timeout(Duration(seconds: 240)));
  });
}
