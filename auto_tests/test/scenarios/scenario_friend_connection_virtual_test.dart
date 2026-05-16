/// Friend Connection Test — virtual-clock variant
import 'dart:async';
///
/// Mirrors scenario_friend_connection_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before initAllNodes() and replaces wall-clock
/// waits with virtual-clock pump helpers. establishFriendship and
/// waitForFriendConnection are routed through the *Virtual variants.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Connection Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation.
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      // Parallelize login
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );

      // Configure local bootstrap (virtual)
      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Friend connection status', () async {
      // Establish bidirectional friendship (virtual)
      await establishFriendshipVirtual(scenario, alice, bob);

      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      final bobPublicKey = bob.getPublicKey();
      final alicePublicKey = alice.getPublicKey();

      // Wait for friend connection to be established (virtual, parallel)
      await Future.wait([
        waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30)),
        waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30)),
      ]);

      // Get friend list and verify connection (per-instance; use node context)
      final aliceFriendListResult = await alice.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.getFriendList());
      expect(aliceFriendListResult.code, equals(0));
      expect(aliceFriendListResult.data, isNotNull);
      expect(aliceFriendListResult.data!.any((f) => f.userID == bobPublicKey),
          isTrue,
          reason: 'Bob should be in Alice\'s friend list');

      final bobFriendListResult = await bob.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendList());
      expect(bobFriendListResult.code, equals(0));
      expect(bobFriendListResult.data, isNotNull);
      expect(bobFriendListResult.data!.any((f) => f.userID == alicePublicKey),
          isTrue,
          reason: 'Alice should be in Bob\'s friend list');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Friend connection status change monitoring', () async {
      // Establish friendship first (virtual)
      await establishFriendshipVirtual(scenario, alice, bob);

      final completer = Completer<void>();

      // Set up friendship listener to monitor friend status changes.
      final bobPublicKey = bob.getPublicKey();
      final friendshipListener = V2TimFriendshipListener(
        onFriendInfoChanged: (List<V2TimFriendInfo> infoList) {
          if (infoList.any((info) => info.userID == bobPublicKey)) {
            alice.markCallbackReceived('onFriendInfoChanged');
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        },
      );

      alice.runWithInstance(() {
        TIMFriendshipManager.instance
            .addFriendListener(listener: friendshipListener);
      });

      // Wait for friend connection status to change (virtual). Apply retry
      // pattern: re-pump up to 3x in case the callback was missed on the
      // first connection event.
      final bobToxId = bob.getToxId();
      var arrived = false;
      for (var attempt = 0; !arrived && attempt < 3; attempt++) {
        try {
          await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
              timeout: const Duration(seconds: 30));
          arrived = true;
        } catch (_) {
          // retry the wait
          await pumpTestTick(scenario,
              advanceMs: 1000, iterationsPerInstance: 1);
        }
      }
      expect(arrived, isTrue,
          reason: 'Alice never observed friend connection to Bob after 3 retries');

      // Verify friend is connected; friend list stores 64-char public key in userID
      final isFriend = await alice.isFriend(bobPublicKey);
      expect(isFriend, isTrue, reason: 'Bob should be in Alice\'s friend list');

      // Cleanup
      alice.runWithInstance(() {
        TIMFriendshipManager.instance
            .removeFriendListener(listener: friendshipListener);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
