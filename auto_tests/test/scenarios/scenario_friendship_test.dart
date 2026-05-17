/// Friendship Test
import 'dart:async';
/// 
/// Tests friend management: add, delete, query, and friend request handling
/// Reference: c-toxcore/auto_tests/scenarios/scenario_friend_request_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friendship Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      // Uses the SharedScenarioPool: when another test file in the same
      // `flutter test` invocation already prepared an [alice, bob] scenario
      // with the same options (bootstrap only, no friendship), we reuse it
      // and skip the 10-22 s cold start. Standalone invocations still pay
      // the cold start once.
      scenario = await acquireSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: false);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
    });

    tearDownAll(() async {
      // No-op release: the pool keeps the scenario alive for the next
      // test file in the bundle. Final teardown happens at process exit.
      releaseSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: false);
    });

    setUp(() async {});

    test('Get friend list', () async {
      final result = await TIMFriendshipManager.instance.getFriendList();
      expect(result.code, equals(0));
      expect(result.data, isNotNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
