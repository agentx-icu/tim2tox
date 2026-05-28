/// Simple Friend Request Test — virtual-clock variant
///
/// Mirrors scenario_friend_request_simple_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before scenario.initAllNodes() and replaces
/// wall-clock waits with virtual-clock pump helpers.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Simple Friend Request Test', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation so V2TIMManagerImpl
      // constructor inherits test_mode and InitSDK skips event_thread.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      // Refresh per-instance test_mode for visibility (idempotent).
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

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

    test('Simple addFriend call test', () async {
      print('========================================');
      print('[SIMPLE_TEST] Test started');
      print('========================================');

      final aliceToxId = alice.getToxId();
      print('[SIMPLE_TEST] Alice Tox ID: ${aliceToxId.substring(0, 20)}...');
      final bobToxId = bob.getToxId();
      print('[SIMPLE_TEST] Bob Tox ID: ${bobToxId.substring(0, 20)}...');

      // Set up listener for Bob BEFORE sending friend request.
      print('[SIMPLE_TEST] Setting up listener for Bob BEFORE sending friend request...');
      bool requestReceived = false;
      final completer = Completer<void>();

      final listener = V2TimFriendshipListener(
        onFriendApplicationListAdded:
            (List<V2TimFriendApplication> applicationList) {
          print(
              '[SIMPLE_TEST] OK Bob received friend request! applicationList.length=${applicationList.length}');
          if (applicationList.isNotEmpty) {
            print('[SIMPLE_TEST] Application from: ${applicationList.first.userID}');
            print(
                '[SIMPLE_TEST] Application message: ${applicationList.first.addWording}');
          }
          requestReceived = true;
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

      bob.runWithInstance(
          () => TIMFriendshipManager.instance.addFriendListener(listener: listener));
      print(
          '[SIMPLE_TEST] Listener added for Bob (instance_id=${bob.testInstanceHandle})');

      print('[SIMPLE_TEST] About to call addFriend...');
      print('[SIMPLE_TEST] bobToxId length: ${bobToxId.length}');

      try {
        // Friend-request retry pattern: re-fire addFriend up to 3 times,
        // pumping virtual time between attempts to wait for the callback.
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          if (attempt > 0) {
            print('[SIMPLE_TEST] Retry attempt ${attempt + 1}, re-firing addFriend...');
          }
          final addResult =
              await alice.runWithInstanceAsync(() async => TIMFriendshipManager
                  .instance
                  .addFriend(
            userID: bobToxId,
            addWording: 'Hello from simple test',
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
          ));

          print('[SIMPLE_TEST] addFriend returned: code=${addResult.code}, desc=${addResult.desc}');
          expect(addResult.code, isNotNull,
              reason: 'addFriend should return a result code');

          // Inline pump loop because predicate is async (poll Bob's
          // application list as a fallback to the callback).
          final attemptDeadline = VirtualClock.nowMs + 30000;
          while (VirtualClock.nowMs < attemptDeadline) {
            if (requestReceived) {
              arrived = true;
              break;
            }
            final appListResult = await bob.runWithInstanceAsync(() async =>
                TIMFriendshipManager.instance.getFriendApplicationList());
            if (appListResult.code == 0 &&
                appListResult.data?.friendApplicationList != null &&
                appListResult.data!.friendApplicationList!.isNotEmpty) {
              final alicePk = alice.getPublicKey();
              final fromAlice = appListResult.data!.friendApplicationList!
                  .any((app) => app?.userID == alicePk);
              if (fromAlice) {
                requestReceived = true;
                if (!completer.isCompleted) completer.complete();
                arrived = true;
                break;
              }
            }
            await pumpTestTick(scenario,
                advanceMs: 50, iterationsPerInstance: 1);
          }
        }

        if (requestReceived) {
          print('[SIMPLE_TEST] OK Friend request was received by Bob!');
        } else {
          print('[SIMPLE_TEST] Friend request was NOT received by Bob after 3 retries');
        }

        bob.runWithInstance(() => TIMFriendshipManager.instance
            .removeFriendListener(listener: listener));
      } catch (e, stackTrace) {
        print('[SIMPLE_TEST] Exception in addFriend: $e');
        print('[SIMPLE_TEST] Stack trace: $stackTrace');
        rethrow;
      }

      print('[SIMPLE_TEST] Test completed');
      print('========================================');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
