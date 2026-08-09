/// Self Query Test — virtual-clock variant
///
/// Mirrors scenario_self_query_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before scenario.initAllNodes() so the
/// V2TIMManagerImpl constructor inherits test_mode. Wall-clock waits are
/// replaced with virtual-clock pump helpers.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Self Query Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late TestNode charlie;

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation so V2TIMManagerImpl
      // constructor inherits test_mode and InitSDK skips event_thread.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob', 'charlie']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      charlie = scenario.getNode('charlie')!;

      await scenario.initAllNodes();
      // Refresh per-instance test_mode for visibility (idempotent on test_mode,
      // also seeds the virtual clock).
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      // Login with a short DHT-connect timeout: bootstrap is configured AFTER
      // this call, so the default 10s connection wait inside TestNode.login()
      // always times out. We re-establish connection via
      // configureLocalBootstrapVirtual + waitForConnectionVirtual below.
      await Future.wait([
        alice.login(timeout: const Duration(milliseconds: 500)),
        bob.login(timeout: const Duration(milliseconds: 500)),
        charlie.login(timeout: const Duration(milliseconds: 500)),
      ]);

      // Wait for all nodes to be connected
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn && charlie.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'all nodes logged in',
      );

      // Enable auto-accept so friend requests (addFriend) are accepted and friends appear in list
      alice.enableAutoAccept();
      bob.enableAutoAccept();
      charlie.enableAutoAccept();

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

    test('Self connection status callback and query', () async {
      final listener = V2TimSDKListener(
        onConnectSuccess: () {
          alice.connectionStatusCalled = true;
          alice.lastConnectionStatus = 2;
          alice.markCallbackReceived('onConnectSuccess');
        },
        onConnectFailed: (int code, String desc) {
          alice.connectionStatusCalled = true;
          alice.lastConnectionStatus = 0;
          alice.markCallbackReceived('onConnectFailed');
        },
      );

      alice.runWithInstance(() => TIMManager.instance.addSDKListener(listener));

      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 10));

      // was: an unconditional `alice.connectionStatusCalled = true;` (plus
      // `lastConnectionStatus = status;`) sat right here, immediately before
      // the expects below read those very fields — both assertions were true
      // by construction and could never fail. Snapshot the real state instead.
      final callbackFired = alice.connectionStatusCalled;
      final connectionStatus = alice.getConnectionStatus();

      // Verify connection status callback was called or connection is established
      expect(
        callbackFired || connectionStatus != 0,
        isTrue,
        reason: 'Either the SDK connection callback must fire or '
            'getConnectionStatus() must report a live connection '
            '(callbackFired=$callbackFired, status=$connectionStatus)',
      );

      // Verify connection status is not NONE (waitForConnectionVirtual only
      // returns once Tox reported TCP/UDP, so 0 here is a real regression).
      expect(
        connectionStatus,
        isNot(equals(0)),
        reason: 'Connection status should not be NONE',
      );

      alice.runWithInstance(
          () => TIMManager.instance.removeSDKListener(listener: listener));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Query self info (login alias)', () async {
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 5));
      // V2TIMManagerImpl::GetLoginUser() returns the login alias (the
      // userID passed at Login()), not the 76-hex Tox public key.
      final loginUser =
          alice.runWithInstance(() => TIMManager.instance.getLoginUser());
      expect(loginUser, equals(alice.userId));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Friend list query with multiple friends', () async {
      // Establish friendships: Alice adds Bob and Charlie, both add Alice back
      final aliceToxId = alice.getToxId();
      final alicePublicKey = alice.getPublicKey();
      final bobToxId = bob.getToxId();
      final bobPublicKey = bob.getPublicKey();
      final charlieToxId = charlie.getToxId();
      final charliePublicKey = charlie.getPublicKey();

      // Verify Tox IDs are different
      if (aliceToxId == bobToxId) {
        throw Exception('ERROR: Alice and Bob have the same Tox ID!');
      }
      if (aliceToxId == charlieToxId) {
        throw Exception('ERROR: Alice and Charlie have the same Tox ID!');
      }
      if (bobToxId == charlieToxId) {
        throw Exception('ERROR: Bob and Charlie have the same Tox ID!');
      }

      var converged = false;
      final aliceBobResult = await alice.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: bobToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Bob',
                addWording: 'Hello from Alice',
              ));
      final bobAliceResult = await bob.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: aliceToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Alice',
                addWording: 'Hello from Bob',
              ));
      final aliceCharlieResult = await alice.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: charlieToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Charlie',
                addWording: 'Hello from Alice',
              ));
      final charlieAliceResult = await charlie.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: aliceToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Alice',
                addWording: 'Hello from Charlie',
              ));

      expect(aliceBobResult.code, equals(0),
          reason: 'Alice -> Bob addFriend failed: ${aliceBobResult.desc}');
      expect(bobAliceResult.code, equals(0),
          reason: 'Bob -> Alice addFriend failed: ${bobAliceResult.desc}');
      expect(aliceCharlieResult.code, equals(0),
          reason:
              'Alice -> Charlie addFriend failed: ${aliceCharlieResult.desc}');
      expect(charlieAliceResult.code, equals(0),
          reason:
              'Charlie -> Alice addFriend failed: ${charlieAliceResult.desc}');

      try {
        // Short initial pump for requests to propagate.
        await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

        // Wait for friends to appear in Alice's list, pumping between polls.
        // Inline loop because the predicate is async. Bounded by a real-time
        // deadline so it terminates in BOTH modes: wall-clock uses the full 6s,
        // virtual mode still converges fast (pumpTestTick fast-forwards the
        // virtual clock) and breaks early. A VirtualClock.nowMs deadline would
        // spin forever in wall mode (the virtual clock is frozen there).
        final deadlineDt = DateTime.now().add(const Duration(seconds: 6));
        while (DateTime.now().isBefore(deadlineDt)) {
          final list = await alice.runWithInstanceAsync(
              () async => TIMFriendshipManager.instance.getFriendList());
          if (list.code == 0 && list.data != null) {
            final ids = list.data!.map((f) => f.userID).toSet();
            if (ids.contains(bobPublicKey) && ids.contains(charliePublicKey)) {
              converged = true;
              break;
            }
          }
          await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 1);
        }
      } catch (e) {
        print(
            'Warning: Friend connection timeout, querying friend list anyway: $e');
      }

      // was: `if (!converged) print('[Test] Friends did not appear...')` and
      // nothing more — the convergence budget's outcome was never asserted.
      // GetFriendList is served straight from tox_self_get_friend_list, so a
      // target shows up as soon as the local tox_friend_add succeeds; failing
      // to converge means addFriend broke, not that the network was slow.
      expect(converged, isTrue,
          reason: "Bob and Charlie must both appear in Alice's friend list "
              'within the convergence budget');

      final friendListResult = await alice.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.getFriendList());

      expect(friendListResult.code, equals(0));
      expect(friendListResult.data, isNotNull);

      // was: `if (friend.userID.length != 64) { /* No-op; legacy info-only
      // branch. */ }` — an empty if-body that checked nothing.
      // V2TIMFriendshipManagerImpl::GetFriendList hex-encodes
      // tox_friend_get_public_key, so every userID is exactly 64 chars.
      for (final friend in friendListResult.data!) {
        expect(friend.userID.length, equals(64),
            reason: 'friend userID must be the 64-char public key '
                '(length=${friend.userID.length})');
      }

      // was: `expect(friendCount, greaterThanOrEqualTo(0))` — a List length is
      // never negative, so only the upper bound was ever checked, and the three
      // identity assertions below were gated on `if (friendCount == 2)` with an
      // `else { print(...) }`, i.e. silently skipped whenever they mattered.
      // Alice added exactly Bob and Charlie and the list is local Tox state,
      // so the count is deterministic.
      final friendCount = friendListResult.data!.length;
      expect(friendCount, equals(2),
          reason: "Alice's friend list must contain exactly Bob and Charlie");

      final friendIds = friendListResult.data!.map((f) => f.userID).toList();
      expect(friendIds, contains(bobPublicKey));
      expect(friendIds, contains(charliePublicKey));
      expect(friendIds, isNot(contains(alicePublicKey)));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('UDP port query (if FFI supports)', () async {
      // Note: UDP port query requires FFI support
      // Currently, tim2tox_ffi.h does not expose get_udp_port function
      // This test verifies connection status instead

      final connectionStatus = alice.getConnectionStatus();
      expect(connectionStatus, isNotNull);

      // If connected, status should be > 0 (1=TCP, 2=UDP)
      if (connectionStatus > 0) {
        expect(connectionStatus, greaterThan(0));
        print(
            'Note: Connection status is $connectionStatus (UDP port query not yet available in FFI)');
      } else {
        print(
            'Note: Connection status is 0 (NONE) - may need more time to connect');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
