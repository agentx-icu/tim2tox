/// Bootstrap Test
/// Reference: c-toxcore/auto_tests/scenarios/scenario_bootstrap_test.c
/// 
/// Tests bootstrap functionality:
/// - Bob bootstraps from Alice
/// - Bob waits for DHT connection (self-connected)
/// - Alice waits for Bob to finish

import 'package:test/test.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Bootstrap Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    
    setUpAll(() async {
      scenario = await acquireSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: false);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
    });

    tearDownAll(() async {
      releaseSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: false);
    });
    
    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });
    
    test('Bob bootstraps from Alice and connects to DHT', () async {
      print('[Test] Starting bootstrap test...');
      
      // Bob's script: Wait for DHT connection (self-connected)
      // This corresponds to WAIT_UNTIL(tox_node_is_self_connected(self)) in C test
      print('[Test] Bob: Waiting for DHT connection...');
      
      // Wait for Bob to be connected
      await bob.waitForConnection(timeout: const Duration(seconds: 30));
      
      // Verify Bob is connected
      final bobConnectionStatus = bob.getConnectionStatus();
      print('[Test] Bob: Connected to DHT! (connectionStatus=$bobConnectionStatus)');
      
      expect(bobConnectionStatus, isNot(equals(0)), 
        reason: 'Bob should be connected to DHT after bootstrap');
      
      // Alice's script: Wait for Bob to finish
      // This corresponds to WAIT_UNTIL(tox_node_is_finished(bob)) in C test
      // In Dart, we check if Bob is connected as a proxy for "finished"
      print('[Test] Alice: Waiting for Bob to finish...');
      
      await waitUntil(
        () {
          final bobConnected = bob.getConnectionStatus() != 0;
          return bobConnected;
        },
        timeout: const Duration(seconds: 30),
        description: 'Bob finished (connected to DHT)',
      );
      
      print('[Test] Scenario completed successfully!');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
