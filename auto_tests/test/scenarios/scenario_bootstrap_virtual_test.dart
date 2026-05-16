/// Bootstrap Test — virtual-clock variant
///
/// Mirrors scenario_bootstrap_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).

import 'package:test/test.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Bootstrap Tests (Virtual)', () {
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

      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Bob bootstraps from Alice and connects to DHT', () async {
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 30));

      final bobConnectionStatus = bob.getConnectionStatus();
      expect(bobConnectionStatus, isNot(equals(0)),
          reason: 'Bob should be connected to DHT after bootstrap');

      await waitUntilWithVirtualPump(
        scenario,
        () => bob.getConnectionStatus() != 0,
        timeout: const Duration(seconds: 30),
        description: 'Bob finished (connected to DHT)',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
