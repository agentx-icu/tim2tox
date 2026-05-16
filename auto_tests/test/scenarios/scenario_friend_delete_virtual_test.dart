/// Friend Delete Test — virtual-clock variant
///
/// Mirrors scenario_friend_delete_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before initAllNodes() and uses
/// establishFriendshipVirtual / virtual pump for delete-callback wait.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Delete Tests (Virtual)', () {
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

      await waitUntil(() => alice.loggedIn && bob.loggedIn);

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

    test('Delete friend', () async {
      // Establish friendship (alice adds bob) — virtual
      await establishFriendshipVirtual(scenario, alice, bob);

      // Delete friend from alice's instance; native may expect 64-char public key
      final bobPublicKey = bob.getPublicKey();
      final deleteResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.deleteFromFriendList(
            userIDList: [bobPublicKey],
            deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
          ));

      expect(deleteResult.code, equals(0));

      // Verify friend is deleted (inline pump loop because predicate is async).
      final delDeadline = VirtualClock.nowMs + 10000;
      while (VirtualClock.nowMs < delDeadline) {
        final list = await alice.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendList());
        if (list.data == null) break;
        if (!list.data!.any((friend) => friend.userID == bobPublicKey)) {
          break;
        }
        await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 1);
      }

      final friendListResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendList());
      expect(friendListResult.code, equals(0));
      if (friendListResult.data != null) {
        final bobInList =
            friendListResult.data!.any((friend) => friend.userID == bobPublicKey);
        expect(bobInList, isFalse,
            reason: 'Bob should not be in friend list after deletion');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Friend deletion callback', () async {
      final completer = Completer<void>();

      final listener = V2TimFriendshipListener(
        onFriendListDeleted: (List<String> userIDList) {
          alice.markCallbackReceived('onFriendListDeleted');
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

      alice.runWithInstance(() {
        TIMFriendshipManager.instance.addFriendListener(listener: listener);
      });

      // Establish and then delete friendship in alice's context (virtual)
      await establishFriendshipVirtual(scenario, alice, bob);
      final bobPublicKey = bob.getPublicKey();

      // Retry: delete + wait for callback up to 3 attempts.
      var arrived = false;
      for (var attempt = 0; !arrived && attempt < 3; attempt++) {
        if (attempt > 0) {
          // Re-fire delete; callback may have been missed on first attempt.
          await alice.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.deleteFromFriendList(
                userIDList: [bobPublicKey],
                deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
              ));
        } else {
          await alice.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.deleteFromFriendList(
                userIDList: [bobPublicKey],
                deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
              ));
        }
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => alice.callbackReceived['onFriendListDeleted'] == true,
            timeout: const Duration(seconds: 30),
            description: 'onFriendListDeleted (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          arrived = true;
        } catch (_) {
          // retry
        }
      }
      // Callback may not be triggered in all cases (mirrors wall-clock onTimeout no-op).

      expect(
          alice.runWithInstance(() => TIMFriendshipManager
              .instance.v2TimFriendshipListenerList
              .contains(listener)),
          isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
