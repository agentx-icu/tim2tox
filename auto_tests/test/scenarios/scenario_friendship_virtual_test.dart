/// Friendship Test — virtual-clock variant
import 'dart:async';
///
/// Mirrors scenario_friendship_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before initAllNodes() and uses
/// configureLocalBootstrapVirtual.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friendship Tests (Virtual)', () {
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
      // event_thread suppressed by enableEarly → DHT can't connect during
      // login(), so its 10s DHT-wait would burn full timeout. 500ms is enough
      // to set loggedIn=true and return; bootstrap happens explicitly below.
      await Future.wait([
        alice.login(timeout: const Duration(milliseconds: 500)),
        bob.login(timeout: const Duration(milliseconds: 500)),
      ]);
      await waitUntil(() => alice.loggedIn && bob.loggedIn);
      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {});

    test('Get friend list', () async {
      final result = await TIMFriendshipManager.instance.getFriendList();
      expect(result.code, equals(0));
      expect(result.data, isNotNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
