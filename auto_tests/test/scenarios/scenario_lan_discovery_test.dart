/// LAN Discovery Test — virtual-clock variant
///
/// Mirrors scenario_lan_discovery_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual
/// helpers).

// SKIP_IN_PARALLEL: LAN multicast requires sole occupancy of loopback 33445-33545 port range

import 'package:test/test.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('LAN Discovery Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      // Initialize nodes with local discovery enabled and IPv6 disabled.
      // initAllNodes() calls initSDK() without options, so call initSDK
      // explicitly per-node.
      await alice.initSDK(localDiscoveryEnabled: true, ipv6Enabled: false);
      await bob.initSDK(localDiscoveryEnabled: true, ipv6Enabled: false);
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        bob.login(),
      ]);
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );

      // Do NOT configure bootstrap; rely on LAN discovery.
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Alice and Bob discover network via LAN', () async {
      await Future.wait([
        waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 60)),
        waitForConnectionVirtual(scenario, bob,
            timeout: const Duration(seconds: 60)),
      ]);

      final aliceConnectionStatus = alice.getConnectionStatus();
      final bobConnectionStatus = bob.getConnectionStatus();

      expect(
        aliceConnectionStatus != 0 || bobConnectionStatus != 0,
        isTrue,
        reason: 'At least one node should be connected via LAN discovery',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
