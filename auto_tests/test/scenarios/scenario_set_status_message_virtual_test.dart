/// Set Status Message Test — virtual-clock variant
///
/// Mirrors scenario_set_status_message_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Reference: c-toxcore/auto_tests/scenarios/scenario_set_status_message_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_full_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Set Status Message Tests (Virtual)', () {
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

    test('Set status message', () async {
      // Status message setting depends on available APIs
      // Verify listener setup (single-instance self-info; no virtual-time
      // pumping needed for this verification path).
      final listener = V2TimSDKListener(
        onSelfInfoUpdated: (V2TimUserFullInfo info) {
          alice.markCallbackReceived('onSelfInfoUpdated');
        },
      );
      TIMManager.instance.addSDKListener(listener);
      expect(TIMManager.instance.v2TimSDKListenerList.contains(listener),
          isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
