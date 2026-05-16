/// Send Message Test — virtual-clock variant
///
/// Mirrors scenario_send_message_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Reference: c-toxcore/auto_tests/scenarios/scenario_send_message_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Send Message Tests (Virtual)', () {
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

      // Wait for both nodes to be connected
      await waitUntil(() => alice.loggedIn && bob.loggedIn,
          timeout: const Duration(seconds: 10));

      // Configure local bootstrap (virtual-clock variant)
      await configureLocalBootstrapVirtual(scenario);

      // Establish bidirectional friendship (required for message delivery in Tox)
      await establishFriendshipVirtual(scenario, alice, bob);
      // Pump so P2P connection is established before tests send messages
      await pumpFriendConnectionVirtual(scenario, alice, bob);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Send text message', () async {
      // Get actual Tox ID (friend list contains Tox IDs, not TestNode.userId)
      final bobToxId = bob.getToxId();

      // Wait for DHT then friend connection before sending
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));

      final sendResult = await alice.runWithInstanceAsync(() async {
        final messageResult =
            TIMMessageManager.instance.createTextMessage(text: 'Hello');
        return await TIMMessageManager.instance.sendMessage(
          message: messageResult.messageInfo,
          receiver: bobToxId,
          groupID: null,
          onlineUserOnly: false,
        );
      });
      expect(sendResult.code, equals(0), reason: 'Message send should succeed');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Send custom message', () async {
      // Get actual Tox ID (friend list contains Tox IDs, not TestNode.userId)
      final bobToxId = bob.getToxId();

      // Wait for DHT then friend connection before sending
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));

      final sendResult = await alice.runWithInstanceAsync(() async {
        final messageResult = TIMMessageManager.instance
            .createCustomMessage(data: '{"type":"test"}');
        return await TIMMessageManager.instance.sendMessage(
          message: messageResult.messageInfo,
          receiver: bobToxId,
          groupID: null,
          onlineUserOnly: false,
        );
      });
      expect(sendResult.code, equals(0),
          reason: 'Custom message send should succeed');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
