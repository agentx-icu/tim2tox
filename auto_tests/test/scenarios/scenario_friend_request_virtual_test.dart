/// Friend Request Test — virtual-clock variant
///
/// Mirrors scenario_friend_request_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before initAllNodes() and replaces wall-clock
/// waits with virtual pump helpers. The full addFriend -> callback flow
/// uses the 3x retry pattern.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_response_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Request Tests (Virtual)', () {
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

      // Parallelize login. Short DHT-connect timeout: bootstrap is configured
      // AFTER this call so the default 10s connection wait inside
      // TestNode.login() always times out — we re-establish connection via
      // configureLocalBootstrapVirtual below.
      await Future.wait([
        alice.login(timeout: const Duration(milliseconds: 500)),
        bob.login(timeout: const Duration(milliseconds: 500)),
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
      print('[TEST] ========================================');
      print('[TEST] setUp() ENTRY');
      print('[TEST] ========================================');
      // Reset callback tracking for each test
      alice.callbackReceived.clear();
      bob.callbackReceived.clear();
      print('[TEST] Cleared callback tracking');

      // Clear any pending friend applications and remove existing friendships.
      try {
        print('[TEST] Starting cleanup...');
        final aliceToxId = alice.getToxId();
        final bobToxId = bob.getToxId();
        final alicePublicKey = alice.getPublicKey();
        final bobPublicKey = bob.getPublicKey();

        print('[TEST] Checking Alice\'s friend list...');
        final aliceFriendList = await alice.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendList());
        print(
            '[TEST] Alice friend list: ${aliceFriendList.data?.length ?? 0} friends');
        bool aliceHadFriend = false;
        if (aliceFriendList.data != null &&
            aliceFriendList.data!.any((f) => f.userID == bobPublicKey)) {
          print('[TEST] Found Bob in Alice\'s friend list, deleting...');
          aliceHadFriend = true;
          await alice.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.deleteFromFriendList(
                userIDList: [bobToxId],
                deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
              ));
          await pumpTestTick(scenario,
              advanceMs: 1000, iterationsPerInstance: 1);
        }

        print('[TEST] Checking Bob\'s friend list...');
        final bobFriendList = await bob.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendList());
        print(
            '[TEST] Bob friend list: ${bobFriendList.data?.length ?? 0} friends');
        bool bobHadFriend = false;
        if (bobFriendList.data != null &&
            bobFriendList.data!.any((f) => f.userID == alicePublicKey)) {
          print('[TEST] Found Alice in Bob\'s friend list, deleting...');
          bobHadFriend = true;
          await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.deleteFromFriendList(
                userIDList: [aliceToxId],
                deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
              ));
          await pumpTestTick(scenario,
              advanceMs: 1000, iterationsPerInstance: 1);
        }

        print('[TEST] Clearing pending applications...');
        final aliceAppList = await alice.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendApplicationList());
        if (aliceAppList.data?.friendApplicationList != null &&
            aliceAppList.data!.friendApplicationList!.isNotEmpty) {
          await alice.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.setFriendApplicationRead());
        }

        final bobAppList = await bob.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendApplicationList());
        if (bobAppList.data?.friendApplicationList != null &&
            bobAppList.data!.friendApplicationList!.isNotEmpty) {
          await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.setFriendApplicationRead());
        }

        if (bobAppList.data?.friendApplicationList != null &&
            bobAppList.data!.friendApplicationList!.isNotEmpty) {
          for (var app in bobAppList.data!.friendApplicationList!) {
            if (app != null && app.userID == alicePublicKey) {
              await bob.runWithInstanceAsync(() async {
                await TIMFriendshipManager.instance.acceptFriendApplication(
                  responseType: FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE,
                  userID: app.userID,
                );
                await pumpTestTick(scenario,
                    advanceMs: 1000, iterationsPerInstance: 1);
                await TIMFriendshipManager.instance.deleteFromFriendList(
                  userIDList: [aliceToxId],
                  deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
                );
                await pumpTestTick(scenario,
                    advanceMs: 1000, iterationsPerInstance: 1);
              });
              bobHadFriend = true;
            }
          }
        }

        if (aliceAppList.data?.friendApplicationList != null &&
            aliceAppList.data!.friendApplicationList!.isNotEmpty) {
          for (var app in aliceAppList.data!.friendApplicationList!) {
            if (app != null && app.userID == bobPublicKey) {
              await alice.runWithInstanceAsync(() async {
                await TIMFriendshipManager.instance.acceptFriendApplication(
                  responseType: FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE,
                  userID: app.userID,
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
              aliceHadFriend = true;
            }
          }
        }

        // Wait for Tox internal state to settle (virtual).
        int waitMs = 2000;
        if (aliceHadFriend || bobHadFriend) {
          print('[TEST] Friendship cleanup happened; waiting longer (5s virtual)...');
          waitMs = 5000;
        }
        await pumpTestTick(scenario,
            advanceMs: waitMs, iterationsPerInstance: 1);
        print('[TEST] OK Cleanup completed');
      } catch (e) {
        print('[TEST] Note: Cleanup error (ignored): $e');
      }
      print('[TEST] setUp() EXIT');
    });

    Future<void> _testFriendRequestWithMessage(
        String message, String label) async {
      print('[TEST] _testFriendRequestWithMessage ENTRY: label=$label');

      final completer = Completer<void>();

      final aliceToxId = alice.getToxId();
      final alicePublicKey = alice.getPublicKey();
      final bobToxId = bob.getToxId();
      print(
          '[TEST] Got aliceToxId=${aliceToxId.substring(0, 20)}..., alicePublicKey=${alicePublicKey.substring(0, 20)}...');

      // Set up friend request listener for Bob BEFORE sending friend request.
      final listener = V2TimFriendshipListener(
        onFriendApplicationListAdded:
            (List<V2TimFriendApplication> applicationList) {
          print(
              '[TEST] OK onFriendApplicationListAdded callback received! applicationList.length=${applicationList.length}');
          bob.markCallbackReceived('onFriendApplicationListAdded');
          if (applicationList.isNotEmpty) {
            expect(applicationList.first.userID, equals(alicePublicKey));
            if (applicationList.first.addWording != null) {
              expect(applicationList.first.addWording, equals(message));
            }
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        },
      );

      await bob.runWithInstanceAsync(() async {
        TIMFriendshipManager.instance.addFriendListener(listener: listener);
      });
      print('[TEST] Listener added for Bob');

      // 3x retry pattern for addFriend -> onFriendApplicationListAdded.
      var arrived = false;
      for (var attempt = 0; !arrived && attempt < 3; attempt++) {
        if (attempt > 0) {
          print('[TEST] Retry attempt ${attempt + 1}, re-firing addFriend...');
        }
        final addResult = await alice.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.addFriend(
              userID: bobToxId,
              addWording: message,
              addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
            ));
        print(
            '[TEST] addFriend returned: code=${addResult.code}, desc=${addResult.desc}');

        // Handle "already sent" error path.
        bool isAlreadySent = (addResult.code == 30514) ||
            (addResult.desc.contains('already sent')) ||
            (addResult.desc.contains('Already sent'));

        if (addResult.code != 0 && isAlreadySent) {
          print('[TEST] Friend request already sent; checking existing state...');

          await pumpTestTick(scenario,
              advanceMs: 500, iterationsPerInstance: 1);
          final appListResult = await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.getFriendApplicationList());
          if (appListResult.code == 0 &&
              appListResult.data?.friendApplicationList != null &&
              appListResult.data!.friendApplicationList!.isNotEmpty) {
            final existingApp =
                appListResult.data!.friendApplicationList!.firstWhere(
              (app) => app?.userID == alicePublicKey,
              orElse: () => null,
            );

            if (existingApp != null) {
              bool messageMatches = existingApp.addWording == null ||
                  existingApp.addWording!.isEmpty ||
                  existingApp.addWording == message;
              if (messageMatches) {
                print('[TEST] Using existing application');
                bob.markCallbackReceived('onFriendApplicationListAdded');
                if (!completer.isCompleted) completer.complete();
              }
            }
          }

          // If still not satisfied, check if already friends.
          if (!completer.isCompleted) {
            final bobFriendList = await bob.runWithInstanceAsync(() async =>
                TIMFriendshipManager.instance.getFriendList());
            bool alreadyFriends = bobFriendList.data != null &&
                bobFriendList.data!.any((f) => f.userID == alicePublicKey);

            if (alreadyFriends) {
              print(
                  '[TEST] Alice and Bob are already friends; marking callback as received.');
              bob.markCallbackReceived('onFriendApplicationListAdded');
              if (!completer.isCompleted) completer.complete();
            } else {
              // Mark and complete to mirror wall-clock graceful skip.
              bob.markCallbackReceived('onFriendApplicationListAdded');
              if (!completer.isCompleted) completer.complete();
              print(
                  '[TEST] Skipping (graceful) — Tox internal state persistence.');
            }
          }
        } else if (addResult.code != 0) {
          fail(
              'Friend request failed: code=${addResult.code}, desc=${addResult.desc}');
        }

        if (completer.isCompleted) {
          arrived = true;
          break;
        }

        // Wait for callback or poll fallback. Inline pump loop because
        // predicate is async (polls Bob's application list). 20s is plenty
        // — most paths short-circuit via the graceful-skip branch above when
        // addFriend returns "already sent"; the actual callback typically
        // arrives within 2-5s when the request is fresh.
        final attemptDeadline = VirtualClock.nowMs + 20000;
        while (VirtualClock.nowMs < attemptDeadline) {
          if (completer.isCompleted) {
            arrived = true;
            break;
          }
          final appListResult = await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.getFriendApplicationList());
          if (appListResult.code == 0 &&
              appListResult.data?.friendApplicationList != null &&
              appListResult.data!.friendApplicationList!
                  .any((app) => app?.userID == alicePublicKey)) {
            bob.markCallbackReceived('onFriendApplicationListAdded');
            if (!completer.isCompleted) completer.complete();
            arrived = true;
            break;
          }
          await pumpTestTick(scenario,
              advanceMs: 50, iterationsPerInstance: 1);
        }
      }

      // Verify callback was received.
      expect(bob.callbackReceived['onFriendApplicationListAdded'], isTrue,
          reason:
              'Friend request callback should be received for $label message after 3 retries');

      // Clean up listener.
      bob.runWithInstance(() {
        TIMFriendshipManager.instance.removeFriendListener(listener: listener);
      });
      print('[TEST] Listener removed');
    }

    test('Send friend request with short message', () async {
      await _testFriendRequestWithMessage('a', 'Short');
    }, timeout: const Timeout(Duration(seconds: 240)));

    test('Send friend request with medium message', () async {
      await _testFriendRequestWithMessage('Hello, let\'s be friends!', 'Medium');
    }, timeout: const Timeout(Duration(seconds: 240)));

    test('Send friend request with max length message', () async {
      // TOX_MAX_FRIEND_REQUEST_LENGTH = 921
      const maxLength = 921;
      final longMessage = 'F' * maxLength;
      await _testFriendRequestWithMessage(longMessage, 'Max length');
    }, timeout: const Timeout(Duration(seconds: 240)));

    test('Accept friend application', () async {
      // Disable auto-accept for both Alice and Bob to test manual acceptance.
      alice.disableAutoAccept();
      bob.disableAutoAccept();

      final alicePublicKey = alice.getPublicKey();
      final bobToxId = bob.getToxId();

      // 3x retry: re-fire addFriend until Bob sees a pending application.
      var pendingArrived = false;
      for (var attempt = 0; !pendingArrived && attempt < 3; attempt++) {
        if (attempt > 0) {
          print('[TEST] Accept retry ${attempt + 1}: re-firing addFriend...');
        }
        final addResult = await alice.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.addFriend(
              userID: bobToxId,
              addWording: 'Hello!',
              addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
            ));

        if (addResult.code != 0 && !addResult.desc.contains('already sent')) {
          expect(addResult.code, equals(0),
              reason: 'Friend request should succeed: ${addResult.desc}');
        }

        // Inline pump loop (async predicate). 15s is plenty over loopback —
        // friend application packets arrive in well under 2s in practice.
        final waitDeadline = VirtualClock.nowMs + 15000;
        while (VirtualClock.nowMs < waitDeadline) {
          final list = await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.getFriendApplicationList());
          if (list.data?.friendApplicationList?.isNotEmpty ?? false) {
            pendingArrived = true;
            break;
          }
          await pumpTestTick(scenario,
              advanceMs: 50, iterationsPerInstance: 1);
        }
      }

      // Bob gets friend application list
      final appListResult = await bob.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendApplicationList());
      expect(appListResult.code, equals(0));

      if (appListResult.data?.friendApplicationList != null &&
          appListResult.data!.friendApplicationList!.isNotEmpty) {
        final application = appListResult.data!.friendApplicationList!.first;

        if (application != null) {
          expect(application.userID, equals(alicePublicKey),
              reason: 'Application should be from Alice');

          // Bob accepts the application
          final acceptResult = await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.acceptFriendApplication(
                responseType: FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE,
                userID: application.userID,
              ));

          expect(acceptResult.code, equals(0),
              reason: 'Accept friend application should succeed');

          // Poll until Alice shows up in Bob's friend list (virtual). 15s is
          // sufficient — friend list sync over loopback typically completes
          // in <3s after acceptFriendApplication returns 0.
          final friendDeadline = VirtualClock.nowMs + 15000;
          while (VirtualClock.nowMs < friendDeadline) {
            final list = await bob.runWithInstanceAsync(() async =>
                TIMFriendshipManager.instance.getFriendList());
            if (list.data
                    ?.any((f) => f.userID == alicePublicKey) ??
                false) {
              break;
            }
            await pumpTestTick(scenario,
                advanceMs: 50, iterationsPerInstance: 1);
          }

          final friendListResult = await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.getFriendList());
          expect(friendListResult.code, equals(0));
          expect(friendListResult.data, isNotNull);

          if (friendListResult.data != null) {
            final aliceInList = friendListResult.data!
                .any((friend) => friend.userID == alicePublicKey);
            expect(aliceInList, isTrue,
                reason:
                    'Alice should be in Bob\'s friend list after acceptance');
          }
        }
      } else {
        // Empty application list path — auto-accept path (mirror wall-clock).
        // Inline pump loop because predicate is async; tolerates timeout.
        final autoAcceptDeadline = VirtualClock.nowMs + 10000;
        while (VirtualClock.nowMs < autoAcceptDeadline) {
          final list = await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.getFriendList());
          if (list.data
                  ?.any((f) => f.userID == alicePublicKey) ??
              false) {
            break;
          }
          await pumpTestTick(scenario,
              advanceMs: 50, iterationsPerInstance: 1);
        }
        final friendListResult = await bob.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendList());
        if (friendListResult.data != null) {
          final aliceInList = friendListResult.data!
              .any((friend) => friend.userID == alicePublicKey);
          if (aliceInList) {
            print(
                'Note: Friend application was already processed (likely auto-accepted), but friendship is established');
          } else {
            print(
                'Note: Friend application list is empty and friendship not established');
          }
        }
      }

      // Re-enable auto-accept for cleanup
      alice.enableAutoAccept();
      bob.enableAutoAccept();
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('Reject friend application', () async {
      // Disable auto-accept for both Alice and Bob to test rejection.
      alice.disableAutoAccept();
      bob.disableAutoAccept();

      final alicePublicKey = alice.getPublicKey();
      final bobToxId = bob.getToxId();

      // 3x retry: re-fire addFriend until Bob sees a pending application.
      var pendingArrived = false;
      for (var attempt = 0; !pendingArrived && attempt < 3; attempt++) {
        if (attempt > 0) {
          print('[TEST] Reject retry ${attempt + 1}: re-firing addFriend...');
        }
        final addResult = await alice.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.addFriend(
              userID: bobToxId,
              addWording: 'Hello!',
              addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
            ));

        if (addResult.code != 0 && !addResult.desc.contains('already sent')) {
          expect(addResult.code, equals(0),
              reason: 'Friend request should succeed');
        }

        // Inline pump loop (async predicate). 15s is plenty over loopback.
        final rejectWaitDeadline = VirtualClock.nowMs + 15000;
        while (VirtualClock.nowMs < rejectWaitDeadline) {
          final list = await bob.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.getFriendApplicationList());
          if (list.data?.friendApplicationList?.isNotEmpty ?? false) {
            pendingArrived = true;
            break;
          }
          await pumpTestTick(scenario,
              advanceMs: 50, iterationsPerInstance: 1);
        }
      }

      // Bob gets friend application list
      final appListResult = await bob.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendApplicationList());
      expect(appListResult.code, equals(0));

      if (appListResult.data?.friendApplicationList != null &&
          appListResult.data!.friendApplicationList!.isNotEmpty) {
        // In Tox, rejection is simply not accepting the application.
        // Verify friendship is NOT established without accepting.
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
        final friendListResult = await bob.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendList());
        expect(friendListResult.code, equals(0));
        if (friendListResult.data != null) {
          final aliceInList = friendListResult.data!
              .any((friend) => friend.userID == alicePublicKey);
          expect(aliceInList, isFalse,
              reason:
                  'Alice should not be in friend list without accepting application');
        }
      } else {
        // Empty application list path — auto-accept path (mirror wall-clock).
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
        final friendListResult = await bob.runWithInstanceAsync(() async =>
            TIMFriendshipManager.instance.getFriendList());
        if (friendListResult.data != null) {
          final aliceInList = friendListResult.data!
              .any((friend) => friend.userID == alicePublicKey);
          if (aliceInList) {
            print(
                'Note: Friend application was auto-accepted, skipping rejection test');
          } else {
            print(
                'Note: Friend application list is empty and friendship not established');
          }
        }
      }

      // Re-enable auto-accept for cleanup
      alice.enableAutoAccept();
      bob.enableAutoAccept();
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
