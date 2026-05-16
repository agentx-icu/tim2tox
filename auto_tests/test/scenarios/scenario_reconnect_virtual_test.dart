/// Reconnect Test — virtual-clock variant
///
/// Mirrors scenario_reconnect_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Reconnect Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        bob.login(),
      ]);
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );

      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Connection status monitoring', () async {
      bool connectionLost = false;
      bool connectionRestored = false;

      final listener = V2TimSDKListener(
        onConnectFailed: (int code, String error) {
          connectionLost = true;
          alice.markCallbackReceived('connectionLost');
        },
        onConnectSuccess: () {
          if (connectionLost) {
            connectionRestored = true;
            alice.markCallbackReceived('connectionRestored');
          }
        },
      );

      alice.runWithInstance(
          () => TIMManager.instance.addSDKListener(listener));
      expect(
        alice.runWithInstance(() =>
            TIMManager.instance.v2TimSDKListenerList.contains(listener)),
        isTrue,
        reason: 'SDK listener should be registered on Alice instance',
      );

      // In local test env we cannot deterministically force disconnect.
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
      if (connectionLost) {
        expect(connectionRestored, isTrue,
            reason:
                'When onConnectFailed occurs, a later onConnectSuccess is expected');
      } else {
        expect(connectionRestored, isFalse,
            reason:
                'onConnectSuccess should not be treated as restore when no prior failure happened');
      }

      alice.runWithInstance(
          () => TIMManager.instance.removeSDKListener(listener: listener));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Reconnection after logout and login', () async {
      // Logout
      await alice.logout();
      expect(alice.loggedIn, isFalse);

      // Login again
      await alice.login();
      expect(alice.loggedIn, isTrue);

      // Wait for connection to be restored after re-login. The virtual clock
      // continues across login/logout, so use the virtual variant.
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));

      final loginUser =
          alice.runWithInstance(() => TIMManager.instance.getLoginUser());
      expect(loginUser, equals(alice.userId));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
