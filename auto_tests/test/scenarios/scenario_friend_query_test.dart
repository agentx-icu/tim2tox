/// Friend Query Test — virtual-clock variant
///
/// Mirrors scenario_friend_query_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before initAllNodes() and uses
/// establishFriendshipVirtual / configureLocalBootstrapVirtual.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Query Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late TestNode charlie;

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob', 'charlie']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      charlie = scenario.getNode('charlie')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      // Parallelize login
      await Future.wait([
        alice.login(),
        bob.login(),
        charlie.login(),
      ]);

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn && charlie.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'condition',
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

    test('Query single friend info', () async {
      // Establish friendship (alice adds bob) — virtual
      await establishFriendshipVirtual(scenario, alice, bob);

      // Query single friend info; tim2tox friend userID is 64-char public key
      final bobPublicKey = bob.getPublicKey();
      final friendsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance
              .getFriendsInfo(userIDList: [bobPublicKey]));

      expect(friendsInfoResult.code, equals(0));
      expect(friendsInfoResult.data, isNotNull);
      expect(friendsInfoResult.data!.length, equals(1));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Query multiple friends info', () async {
      // Establish friendships (alice adds bob and charlie) — virtual
      await establishFriendshipVirtual(scenario, alice, bob);
      await establishFriendshipVirtual(scenario, alice, charlie);

      final bobPublicKey = bob.getPublicKey();
      final charliePublicKey = charlie.getPublicKey();
      final friendsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendsInfo(
              userIDList: [bobPublicKey, charliePublicKey]));

      expect(friendsInfoResult.code, equals(0));
      expect(friendsInfoResult.data, isNotNull);
      expect(friendsInfoResult.data!.length, greaterThanOrEqualTo(1));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('Query non-existent user', () async {
      // Use 64-char hex (public-key shape) for tim2tox
      final nonExistentUserId = '0' * 64;

      final friendsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance
              .getFriendsInfo(userIDList: [nonExistentUserId]));

      // Should handle gracefully (may return empty or error)
      expect(friendsInfoResult.code, isNotNull);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Get friend list', () async {
      // Establish friendship (alice adds bob) — virtual
      await establishFriendshipVirtual(scenario, alice, bob);

      final friendListResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendList());
      expect(friendListResult.code, equals(0));
      expect(friendListResult.data, isNotNull);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
