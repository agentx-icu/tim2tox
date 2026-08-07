// Typing Test
//
// Verifies that native typing events travel through the Tim2Tox FFI/poll path
// and update Bob's cached typing state for Alice on and off. Mode-aware: this
// single file runs under both wall-clock and virtual-clock harnesses via
// `acquireScenarioForMode` / `releaseScenarioForMode`.
// Reference: c-toxcore/auto_tests/scenarios/scenario_typing_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Typing Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      scenario = await acquireScenarioForMode(['alice', 'bob'],
          withBootstrap: true, withFriendship: true);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
    });

    tearDownAll(() async {
      await releaseScenarioForMode(scenario, ['alice', 'bob'],
          withBootstrap: true, withFriendship: true);
    });

    test('Typing status propagates from Alice to Bob', () async {
      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      final alicePublicKey = alice.getPublicKey();

      expect(aliceToxId, hasLength(76));
      expect(bobToxId, hasLength(76));

      bool bobSeesAliceTyping() {
        return bob.runWithInstance(() {
          final platform =
              TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
          return platform.ffiService.isTyping(alicePublicKey);
        });
      }

      Future<void> sendAliceTyping(bool on) async {
        await alice.runWithInstanceAsync(() async {
          final platform =
              TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
          await platform.ffiService.sendTyping(bobToxId, on);
        });
      }

      expect(bobSeesAliceTyping(), isFalse,
          reason: 'Bob should start with Alice typing off');

      await sendAliceTyping(true);
      await waitUntilWithVirtualPump(
        scenario,
        bobSeesAliceTyping,
        timeout: const Duration(seconds: 15),
        description: 'Bob observes Alice typing on',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );
      expect(bobSeesAliceTyping(), isTrue,
          reason: 'Bob should observe Alice typing on');

      final typingOffStartedAt = DateTime.now();
      await sendAliceTyping(false);
      await waitUntilWithVirtualPump(
        scenario,
        () => !bobSeesAliceTyping(),
        timeout: const Duration(seconds: 15),
        description: 'Bob observes Alice typing off',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );
      final typingOffElapsed = DateTime.now().difference(typingOffStartedAt);
      expect(typingOffElapsed, lessThan(const Duration(seconds: 3)),
          reason: 'Typing off should arrive before the cached 3s expiry');
      expect(bobSeesAliceTyping(), isFalse,
          reason: 'Bob should observe Alice typing off');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
