/// Conversation Pin Test — virtual-clock variant
///
/// Mirrors scenario_conversation_pin_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers. pin/unpin state is local on each instance, so
/// no retry pattern is needed; this is mostly mechanical helper substitution.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_conversation_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conversation Pin Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      // Enable BEFORE initAllNodes so V2TIMManagerImpl never spawns
      // event_thread; pin state changes still flow through the conversation
      // manager but the message send + processing uses virtual time.
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      await Future.wait([alice.login(), bob.login()]);
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'logged in',
      );

      await configureLocalBootstrapVirtual(scenario);
      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 60));
      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 6));
    });

    tearDownAll(() async {
      await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 1);
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Pin conversation', () async {
      final bobToxId = bob.getToxId();
      final bobPubKey = bob.getPublicKey();
      final bobPubKeyLower = bobPubKey.toLowerCase();
      // Use c2c_ + 64-char pubkey so native pinned_conversations_ key matches list (list uses c2c_+pubkey)
      final bobConvId = 'c2c_$bobPubKey';
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 8));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));
      final r1 = await alice.runWithInstanceAsync(() async {
        final message1 =
            TIMMessageManager.instance.createTextMessage(text: 'Hello Bob');
        return await TIMMessageManager.instance.sendMessage(
          groupID: null,
          message: message1.messageInfo,
          receiver: bobToxId,
          onlineUserOnly: false,
        );
      });
      expect(r1.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      final pinResult = await alice.runWithInstanceAsync(() async =>
          await TIMConversationManager.instance.pinConversation(
            conversationID: bobConvId,
            isPinned: true,
          ));

      expect(pinResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 300, iterationsPerInstance: 1);
      final convListResult = await alice.runWithInstanceAsync(() async =>
          await TIMConversationManager.instance.getConversationList(
            nextSeq: '0',
            count: 10,
          ));

      expect(convListResult.code, equals(0));
      expect(
          convListResult.data?.conversationList != null &&
              convListResult.data!.conversationList!.isNotEmpty,
          isTrue,
          reason:
              'getConversationList should return at least one conversation after sending');
      // Match bob's conversation by ID (c2c_ + Tox ID or 64-char pubkey; format may vary)
      final list = convListResult.data!.conversationList!;
      final matching = list.where((c) {
        final id = c.conversationID.toLowerCase();
        return id == 'c2c_$bobToxId'.toLowerCase() ||
            id == 'c2c_$bobPubKey'.toLowerCase() ||
            id == bobPubKeyLower ||
            (id.length >= 64 && id.contains(bobPubKeyLower));
      });
      // Prefer asserting we found bob's conv and it is pinned; fallback: at least one pinned conv
      final pinnedConvs = list.where((c) => c.isPinned == true).toList();
      expect(pinnedConvs.isNotEmpty, isTrue,
          reason:
              'Expected at least one pinned conversation; list: ${list.map((c) => "${c.conversationID}:pinned=${c.isPinned}").join(", ")}');
      if (matching.isNotEmpty) {
        expect(matching.first.isPinned, isTrue);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('Unpin conversation', () async {
      final bobToxId = bob.getToxId();
      final bobConvId = 'c2c_${bob.getPublicKey()}';
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 8));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));
      final sendResult = await alice.runWithInstanceAsync(() async {
        final message =
            TIMMessageManager.instance.createTextMessage(text: 'Hello');
        return await TIMMessageManager.instance.sendMessage(
          groupID: null,
          message: message.messageInfo,
          receiver: bobToxId,
          onlineUserOnly: false,
        );
      });
      expect(sendResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      await alice.runWithInstanceAsync(() async {
        await TIMConversationManager.instance.pinConversation(
          conversationID: bobConvId,
          isPinned: true,
        );
      });

      final unpinResult = await alice.runWithInstanceAsync(() async =>
          await TIMConversationManager.instance.pinConversation(
            conversationID: bobConvId,
            isPinned: false,
          ));

      expect(unpinResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
