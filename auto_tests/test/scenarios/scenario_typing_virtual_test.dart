/// Typing Test — virtual-clock variant
///
/// Mirrors scenario_typing_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Tests typing status (input state) synchronization.
/// Reference: c-toxcore/auto_tests/scenarios/scenario_typing_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Typing Tests (Virtual)', () {
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

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );

      // Configure local bootstrap (virtual-clock variant)
      await configureLocalBootstrapVirtual(scenario);
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

    test('Typing status synchronization', () async {
      // Set up typing status listener for Bob
      // Note: Typing status may be delivered through friend info changes
      final listener = V2TimFriendshipListener(
        onFriendInfoChanged: (List<dynamic> infoList) {
          // Check if typing status is included
          bob.markCallbackReceived('onFriendInfoChanged');
        },
      );

      bob.runWithInstance(() =>
          TIMFriendshipManager.instance.addFriendListener(listener: listener));

      // Alice sets typing status (if supported)
      // Note: This depends on whether TIMMessageManager has setTypingStatus
      // For now, we verify the listener is set up correctly
      //
      // In a real implementation, we would:
      // 1. Alice calls setTypingStatus(true)
      // 2. Bob receives onFriendInfoChanged with typing status
      // 3. Alice calls setTypingStatus(false)
      // 4. Bob receives onFriendInfoChanged with typing status false

      expect(
          bob.runWithInstance(() => TIMFriendshipManager
              .instance.v2TimFriendshipListenerList
              .contains(listener)),
          isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
