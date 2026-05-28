/// Conversation callback test (mode-aware: wall-clock, or virtual under RUN_VIRTUAL=1)
///
/// Isolated scenario for the `onConversationChanged` callback after a
/// binary-path `TIMMessageManager.sendMessage`. Split out of
/// `scenario_conversation_test.dart` because the conversation-changed
/// fan-out (Tim2ToxSdkPlatform + binary singleton list + per-instance dispatch)
/// composes badly with the shared-scenario harness's stream re-entry guard
/// when multiple sub-tests in one file each issue sends and accumulate state
/// — the test isolate dies with `Bad state: Cannot add event while adding stream`
/// on the 4th sub-test even though the callback itself fires correctly.
///
/// Each sub-test in this file owns its own scenario (`setUpAll` per `group`),
/// so the dispatch state never crosses test boundaries and the Flutter test
/// runner's `_GuaranteeSink` never sees re-entrant adds.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_conversation_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimConversationListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_conversation.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conversation Callback Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
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

      await configureLocalBootstrapVirtual(scenario);
      await establishFriendshipVirtual(scenario, alice, bob);
      await pumpFriendConnectionVirtual(scenario, alice, bob);
    });

    tearDownAll(() async {
      await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 1);
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test('Conversation callback - onConversationChanged', () async {
      alice.clearCallbackReceived('onConversationChanged');
      final bobToxId = bob.getToxId();
      await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 80);
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      final listener = V2TimConversationListener(
        onConversationChanged: (List<V2TimConversation> conversationList) {
          alice.markCallbackReceived('onConversationChanged');
        },
      );

      await alice.runWithInstanceAsync(() async {
        TIMConversationManager.instance
            .addConversationListener(listener: listener);
        await TencentCloudChatSdkPlatform.instance
            .addConversationListener(listener: listener);
      });

      try {
        var callbackArrived = false;
        for (var attempt = 0; !callbackArrived && attempt < 3; attempt++) {
          alice.clearCallbackReceived('onConversationChanged');
          final sendResult = await alice.runWithInstanceAsync(() async {
            final messageResult =
                TIMMessageManager.instance.createTextMessage(text: 'Hello');
            return await TIMMessageManager.instance.sendMessage(
              groupID: null,
              message: messageResult.messageInfo,
              receiver: bobToxId,
              onlineUserOnly: false,
            );
          });
          expect(sendResult.code, equals(0));

          await pumpTestTick(scenario,
              advanceMs: 50, iterationsPerInstance: 100);
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => alice.callbackReceived['onConversationChanged'] == true,
              timeout: const Duration(seconds: 60),
              description: 'onConversationChanged callback (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            callbackArrived = true;
          } catch (_) {
            // retry — packet may have been dropped
          }
        }
        expect(alice.callbackReceived['onConversationChanged'], isTrue,
            reason:
                'onConversationChanged must fire after send (after 3 retries)');
      } finally {
        alice.runWithInstance(() => TIMConversationManager.instance
            .removeConversationListener(listener: listener));
        await TencentCloudChatSdkPlatform.instance
            .removeConversationListener(listener: listener);
      }
    }, timeout: const Timeout(Duration(seconds: 240)));
  });
}
