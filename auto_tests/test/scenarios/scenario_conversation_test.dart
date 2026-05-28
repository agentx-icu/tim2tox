/// Conversation Test — virtual-clock variant
///
/// Mirrors scenario_conversation_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Sub-tests that wait on cross-instance onConversationChanged callbacks
/// apply a 3x send-retry pattern: tim2tox C2C messages travel over Tox
/// custom packets that can drop on flaky 2-node local bootstrap links, and
/// the retry is independent of clock mode.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_conversation_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conversation Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      // Enable BEFORE initAllNodes so V2TIMManagerImpl never spawns
      // event_thread; conversation tests rely on virtual-time message
      // delivery through pumpTestTick.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      // Parallelize login
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      // Wait for both nodes to be connected
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );

      // Configure local bootstrap (virtual-time DHT-connect wait)
      await configureLocalBootstrapVirtual(scenario);
      // Establish friendship so C2C messages can be sent (receiver must be Tox ID)
      await establishFriendshipVirtual(scenario, alice, bob);
      // Pump both instances so Tox P2P connection establishes
      await pumpFriendConnectionVirtual(scenario, alice, bob);
    });

    tearDownAll(() async {
      // Allow pending native callbacks (e.g. OnRecvNewMessage) to drain before teardown
      await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 1);
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Get conversation list', () async {
      // Use Tox ID for C2C (tim2tox requires 76-char hex Tox ID as receiver)
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));

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
      expect(sendResult.code, equals(0), reason: 'Send message should succeed');

      // Allow OnRecvNewMessage callback to be processed before getConversationList
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final convListResult = await alice.runWithInstanceAsync(() async =>
          await TIMConversationManager.instance.getConversationList(
            nextSeq: '0',
            count: 10,
          ));

      expect(convListResult.code, equals(0));
      expect(convListResult.data, isNotNull);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Get conversation', () async {
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));

      await alice.runWithInstanceAsync(() async {
        final messageResult =
            TIMMessageManager.instance.createTextMessage(text: 'Hello');
        final r = await TIMMessageManager.instance.sendMessage(
          groupID: null,
          message: messageResult.messageInfo,
          receiver: bobToxId,
          onlineUserOnly: false,
        );
        expect(r.code, equals(0));
      });

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      // Native stores C2C conversationID as c2c_<64-char public key>, not full 76-char Tox ID
      final bobPublicKey = bob.getPublicKey();
      final conversationID = 'c2c_$bobPublicKey';
      final convResult = await alice.runWithInstanceAsync(() async =>
          await TIMConversationManager.instance.getConversation(
            conversationID: conversationID,
          ));

      expect(convResult.code, equals(0));
      if (convResult.data != null) {
        expect(convResult.data?.conversationID, equals(conversationID));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Delete conversation', () async {
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));

      await alice.runWithInstanceAsync(() async {
        final messageResult =
            TIMMessageManager.instance.createTextMessage(text: 'Hello');
        final r = await TIMMessageManager.instance.sendMessage(
          groupID: null,
          message: messageResult.messageInfo,
          receiver: bobToxId,
          onlineUserOnly: false,
        );
        expect(r.code, equals(0));
      });

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final conversationID = 'c2c_${bob.getPublicKey()}';
      final deleteResult = await alice.runWithInstanceAsync(() async =>
          await TIMConversationManager.instance.deleteConversation(
            conversationID: conversationID,
          ));

      expect(deleteResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 90)));

    // The 'Conversation callback - onConversationChanged' subtest lives in
    // `scenario_conversation_callback_test.dart` because the
    // conversation-changed fan-out composes badly with this file's shared
    // scenario across 4 sub-tests (stream re-entrancy in the Flutter test
    // runner's _GuaranteeSink). One isolated scenario per file → no
    // accumulated dispatch state → no re-entry.
  });
}
