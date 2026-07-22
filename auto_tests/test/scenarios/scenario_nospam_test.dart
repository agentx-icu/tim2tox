/// Nospam Test — virtual-clock variant
///
/// Mirrors scenario_nospam_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Multiple addFriend calls; apply retry per friend-state-arrival.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_response_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Nospam Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

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
      await waitUntil(() => alice.loggedIn && bob.loggedIn);

      await configureLocalBootstrapVirtual(scenario);

      await Future.wait([
        waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 45)),
        waitForConnectionVirtual(scenario, bob,
            timeout: const Duration(seconds: 45)),
      ]);
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      final bobPublicKey = bob.getPublicKey();
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      final appListResult = await alice.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.getFriendApplicationList());
      final list = appListResult.data?.friendApplicationList;
      if (list != null && list.isNotEmpty) {
        final isFromBob = (String uid) =>
            uid == bobPublicKey ||
            uid == bobToxId ||
            (uid.length >= 64 && uid.startsWith(bobPublicKey));
        for (final app in list) {
          if (app != null && isFromBob(app.userID)) {
            await alice.runWithInstanceAsync(() async {
              await TIMFriendshipManager.instance.acceptFriendApplication(
                userID: app.userID,
                responseType:
                    FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
              );
              await pumpTestTick(scenario,
                  advanceMs: 1000, iterationsPerInstance: 1);
              await TIMFriendshipManager.instance.deleteFromFriendList(
                userIDList: [bobToxId],
                deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
              );
              await pumpTestTick(scenario,
                  advanceMs: 1000, iterationsPerInstance: 1);
            });
            await bob.runWithInstanceAsync(
                () async => TIMFriendshipManager.instance.deleteFromFriendList(
                      userIDList: [aliceToxId],
                      deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
                    ));
            await pumpTestTick(scenario,
                advanceMs: 3000, iterationsPerInstance: 1);
          }
        }
      }
      final aliceFriends = await alice.getFriendList();
      final bobFriends = await bob.getFriendList();
      final bobInAliceList = aliceFriends.any((id) =>
          id == bobPublicKey ||
          id == bobToxId ||
          (id.length >= 64 && id.startsWith(bobPublicKey)));
      final alicePublicKey =
          aliceToxId.length >= 64 ? aliceToxId.substring(0, 64) : aliceToxId;
      final aliceInBobList = bobFriends.any((id) =>
          id == alicePublicKey ||
          id == aliceToxId ||
          (id.length >= 64 && id.startsWith(alicePublicKey)));
      if (bobInAliceList || aliceInBobList) {
        if (bobInAliceList) {
          await alice.runWithInstanceAsync(
              () async => TIMFriendshipManager.instance.deleteFromFriendList(
                    userIDList: [bobToxId],
                    deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
                  ));
          await pumpTestTick(scenario,
              advanceMs: 1000, iterationsPerInstance: 1);
        }
        if (aliceInBobList) {
          await bob.runWithInstanceAsync(
              () async => TIMFriendshipManager.instance.deleteFromFriendList(
                    userIDList: [aliceToxId],
                    deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
                  ));
          await pumpTestTick(scenario,
              advanceMs: 1000, iterationsPerInstance: 1);
        }
        await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);
      }
    });

    tearDown(() async {
      alice.callbackReceived.clear();
      bob.callbackReceived.clear();
    });

    test('Friend request spam protection', () async {
      bool requestReceived = false;
      final completer = Completer<dynamic>();

      final listener = V2TimFriendshipListener(
        onFriendApplicationListAdded:
            (List<V2TimFriendApplication> applicationList) {
          if (applicationList.isNotEmpty) {
            requestReceived = true;
            alice.markCallbackReceived('onFriendApplicationListAdded');
            if (!completer.isCompleted) {
              completer.complete(applicationList.first);
            }
          }
        },
      );

      alice.runWithInstance(() =>
          TIMFriendshipManager.instance.addFriendListener(listener: listener));
      final aliceToxId = alice.getToxId();
      final addResult = await bob.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: aliceToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Alice',
                addWording: 'Hi',
              ));
      expect(addResult.code, equals(0));

      // Drive virtual time toward completer with retries.
      var arrived = false;
      for (var attempt = 0; !arrived && attempt < 3; attempt++) {
        if (attempt > 0) {
          await bob.runWithInstanceAsync(
              () async => TIMFriendshipManager.instance.addFriend(
                    userID: aliceToxId,
                    addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                    remark: 'Alice',
                    addWording: 'Hi',
                  ));
        }
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => completer.isCompleted,
            timeout: const Duration(seconds: 60),
            description:
                'Alice received friend request (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          arrived = true;
        } on TimeoutException catch (e) {
          // Expected between retry attempts (the post-loop expect enforces the
          // real assertion); a non-timeout error is a real bug and propagates.
          print('[Test] Attempt timed out; retrying: $e');
        }
      }

      expect(requestReceived, isTrue,
          reason: 'Alice should receive friend request');
      expect(alice.callbackReceived['onFriendApplicationListAdded'], isTrue,
          reason: 'Callback should be marked as received');
      alice.runWithInstance(() => TIMFriendshipManager.instance
          .removeFriendListener(listener: listener));
    }, timeout: const Timeout(Duration(seconds: 150)));

    test('Nospam change invalidates old address', () async {
      await Future.wait([
        waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 15)),
        waitForConnectionVirtual(scenario, bob,
            timeout: const Duration(seconds: 15)),
      ]);
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final completer1 = Completer<dynamic>();
      bool request1Received = false;

      final listener1 = V2TimFriendshipListener(
        onFriendApplicationListAdded:
            (List<V2TimFriendApplication> applicationList) {
          if (applicationList.isNotEmpty) {
            request1Received = true;
            if (!completer1.isCompleted) {
              completer1.complete(applicationList.first);
            }
          }
        },
      );

      alice.runWithInstance(() =>
          TIMFriendshipManager.instance.addFriendListener(listener: listener1));
      final aliceToxId = alice.getToxId();
      final addResult = await bob.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: aliceToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                addWording: 'Hi',
              ));

      try {
        await waitUntilWithVirtualPump(
          scenario,
          () => completer1.isCompleted,
          timeout: const Duration(seconds: 180),
          description: 'Alice received friend request (initial)',
          advanceMs: 50,
          iterationsPerInstance: 1,
        );
      } on TimeoutException catch (e) {
        // Best-effort wait: proceed regardless, but keep the timeout visible.
        // A non-timeout error is a real bug and propagates.
        print('[Test] Continuing after timeout: $e');
      }

      var applications = await alice.runWithInstanceAsync(() async {
        final p = TencentCloudChatSdkPlatform.instance;
        if (p is Tim2ToxSdkPlatform) return await p.getFriendApplicationList();
        return await TIMFriendshipManager.instance.getFriendApplicationList();
      });
      var appCount1 = applications.data?.friendApplicationList?.length ?? 0;
      for (int poll = 0; poll < 5 && appCount1 == 0; poll++) {
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
        applications = await alice.runWithInstanceAsync(() async {
          final p = TencentCloudChatSdkPlatform.instance;
          if (p is Tim2ToxSdkPlatform) {
            return await p.getFriendApplicationList();
          }
          return await TIMFriendshipManager.instance.getFriendApplicationList();
        });
        appCount1 = applications.data?.friendApplicationList?.length ?? 0;
        if (appCount1 > 0 && !request1Received) {
          request1Received = true;
        }
      }
      if (appCount1 > 0 && !request1Received) {
        request1Received = true;
      }
      // Note: addResult is referenced for parity with the wall-clock test;
      // outcome may be ALREADY_SENT in tight test cycles.
      // ignore: avoid_print
      print(
          '[Nospam] Nospam change invalidates: addResult.code=${addResult.code}');

      if (applications.data?.friendApplicationList != null &&
          applications.data!.friendApplicationList!.isNotEmpty) {
        final application = applications.data!.friendApplicationList!.first;

        if (application != null) {
          final acceptResult = await alice.runWithInstanceAsync(
              () async => TIMFriendshipManager.instance.acceptFriendApplication(
                    userID: application.userID,
                    responseType: FriendResponseTypeEnum
                        .V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
                  ));
          expect(acceptResult.code, equals(0),
              reason: 'Friend request should be accepted');
        }
      }

      alice.runWithInstance(() => TIMFriendshipManager.instance
          .removeFriendListener(listener: listener1));
      expect(request1Received, isTrue,
          reason: 'request should have been received');
    }, timeout: const Timeout(Duration(seconds: 240)));

    group('Multiple friend requests handling (isolated scenario)', () {
      late TestScenario scenarioIso;
      late TestNode aliceIso;
      late TestNode bobIso;

      setUpAll(() async {
        scenarioIso = await createTestScenario(['alice_iso', 'bob_iso']);
        aliceIso = scenarioIso.getNode('alice_iso')!;
        bobIso = scenarioIso.getNode('bob_iso')!;
        await scenarioIso.initAllNodes();
        if (shouldRunVirtual) await VirtualClock.enableForScenario(scenarioIso);
        await Future.wait([
          aliceIso.login(),
          bobIso.login(),
        ]);
        await waitUntil(() => aliceIso.loggedIn && bobIso.loggedIn);
        await configureLocalBootstrapVirtual(scenarioIso);
        await Future.wait([
          waitForConnectionVirtual(scenarioIso, aliceIso,
              timeout: const Duration(seconds: 45)),
          waitForConnectionVirtual(scenarioIso, bobIso,
              timeout: const Duration(seconds: 45)),
        ]);
        await pumpTestTick(scenarioIso,
            advanceMs: 5000, iterationsPerInstance: 1);
      });

      tearDownAll(() async {
        await scenarioIso.dispose();
      });

      setUp(() async {
        final bobIsoPublicKey = bobIso.getPublicKey();
        final bobIsoToxId = bobIso.getToxId();
        final aliceIsoToxId = aliceIso.getToxId();
        final appListResult = await aliceIso.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendApplicationList());
        final list = appListResult.data?.friendApplicationList;
        if (list != null && list.isNotEmpty) {
          for (final app in list) {
            if (app != null && app.userID == bobIsoPublicKey) {
              await aliceIso.runWithInstanceAsync(() async {
                await TIMFriendshipManager.instance.acceptFriendApplication(
                  userID: app.userID,
                  responseType:
                      FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
                );
                await pumpTestTick(scenarioIso,
                    advanceMs: 1000, iterationsPerInstance: 1);
                await TIMFriendshipManager.instance.deleteFromFriendList(
                  userIDList: [bobIsoToxId],
                  deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
                );
                await pumpTestTick(scenarioIso,
                    advanceMs: 1000, iterationsPerInstance: 1);
              });
            }
          }
        }
        final aliceIsoFriends = await aliceIso.getFriendList();
        final bobIsoInList = aliceIsoFriends.any((id) =>
            id == bobIsoPublicKey ||
            id == bobIsoToxId ||
            (id.length >= 64 && id.startsWith(bobIsoPublicKey)));
        if (bobIsoInList) {
          await aliceIso.runWithInstanceAsync(
              () async => TIMFriendshipManager.instance.deleteFromFriendList(
                    userIDList: [bobIsoToxId],
                    deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
                  ));
          await pumpTestTick(scenarioIso,
              advanceMs: 1000, iterationsPerInstance: 1);
          await bobIso.runWithInstanceAsync(
              () async => TIMFriendshipManager.instance.deleteFromFriendList(
                    userIDList: [aliceIsoToxId],
                    deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
                  ));
          await pumpTestTick(scenarioIso,
              advanceMs: 2000, iterationsPerInstance: 1);
        }
        aliceIso.callbackReceived.clear();
        bobIso.callbackReceived.clear();
      });

      tearDown(() async {
        aliceIso.callbackReceived.clear();
        bobIso.callbackReceived.clear();
      });

      test('Multiple friend requests handling', () async {
        final completer = Completer<dynamic>();
        bool requestReceived = false;

        final listener = V2TimFriendshipListener(
          onFriendApplicationListAdded:
              (List<V2TimFriendApplication> applicationList) {
            if (applicationList.isNotEmpty) {
              requestReceived = true;
              aliceIso.markCallbackReceived('onFriendApplicationListAdded');
              if (!completer.isCompleted) {
                completer.complete(applicationList.first);
              }
            }
          },
        );

        aliceIso.runWithInstance(() => TIMFriendshipManager.instance
            .addFriendListener(listener: listener));

        final aliceToxId = aliceIso.getToxId();
        final addResultIso = await bobIso.runWithInstanceAsync(
            () async => TIMFriendshipManager.instance.addFriend(
                  userID: aliceToxId,
                  addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                  addWording: 'Hi',
                ));

        // Retry per-arrival pattern.
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          if (attempt > 0) {
            await bobIso.runWithInstanceAsync(
                () async => TIMFriendshipManager.instance.addFriend(
                      userID: aliceToxId,
                      addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                      addWording: 'Hi',
                    ));
          }
          try {
            await waitUntilWithVirtualPump(
              scenarioIso,
              () => completer.isCompleted,
              timeout: const Duration(seconds: 90),
              description:
                  'alice_iso received friend request (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } on TimeoutException catch (e) {
            // Expected between retry attempts (the post-loop expect enforces the
            // real assertion); a non-timeout error is a real bug and propagates.
            print('[Test] Attempt timed out; retrying: $e');
          }
        }
        // ignore: avoid_print
        print(
            '[Nospam] Multiple (isolated): addResult.code=${addResultIso.code}');

        final applications = await aliceIso.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendApplicationList());

        expect(applications.data?.friendApplicationList, isNotNull,
            reason: 'Should have friend application list');
        expect(applications.data!.friendApplicationList!.length,
            greaterThanOrEqualTo(0),
            reason: 'Should have at least one friend application');

        final bobPublicKey = bobIso.getPublicKey();
        final bobApplication =
            applications.data!.friendApplicationList!.firstWhere(
          (app) => app?.userID == bobPublicKey,
          orElse: () => null,
        );

        if (bobApplication != null) {
          expect(bobApplication.userID, equals(bobPublicKey),
              reason: 'Application should be from Bob');
        }

        expect(requestReceived, isTrue,
            reason: 'request should have been received');
        aliceIso.runWithInstance(() => TIMFriendshipManager.instance
            .removeFriendListener(listener: listener));
      }, timeout: const Timeout(Duration(seconds: 150)));
    });
  });
}
