/// Save Friend Test — virtual-clock variant
///
/// Mirrors scenario_save_friend_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers. The single-node flow is mostly local (no
/// peer-to-peer message), so we wrap the node in a one-node TestScenario
/// purely so VirtualClock can seed test_mode on its instance.

import 'package:test/test.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Save Friend Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode node;
    final testDir = getTestDataDir();

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['test_node']);
      node = scenario.getNode('test_node')!;
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared node
    });

    test('Friend list persistence', () async {
      final dataDir = await testDir;
      await node.initSDK(initPath: dataDir);
      await VirtualClock.enableForScenario(scenario);
      await node.login();

      // Reduced delay — virtual instead of wall-clock.
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      await node.logout();
      await node.unInitSDK();

      await node.initSDK(initPath: dataDir);
      await VirtualClock.enableForScenario(scenario);
      await node.login();

      final friendListResult = await node.getFriendListResultWithInstance();
      expect(friendListResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
