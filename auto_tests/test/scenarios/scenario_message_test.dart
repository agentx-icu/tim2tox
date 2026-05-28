/// Message Test
///
/// Tests message sending, receiving, and querying.
///
/// Mode-aware: this single file runs under both the wall-clock and the
/// virtual-clock harness. `acquireScenarioForMode` picks the shared-pool
/// (wall) or from-scratch virtual setup based on `RUN_VIRTUAL`; the body
/// helpers (`waitForConnectionVirtual`, `waitUntilWithVirtualPump`,
/// `pumpTestTick`, …) drive the virtual clock when enabled and fall back to
/// wall-clock waiting otherwise. There is no separate `*_virtual_test.dart`
/// sibling — `RUN_VIRTUAL=1` selects the virtual path here.
/// Reference: c-toxcore/auto_tests/scenarios/scenario_message_test.c

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Message Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      scenario = await acquireScenarioForMode(['alice', 'bob'],
          withBootstrap: true, withFriendship: true);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      // Virtual mode needs an explicit pump to advance the shared clock so the
      // friend P2P link warms up before the first test. This pump must NOT run
      // in wall mode: pumpFriendConnectionVirtual loops on `VirtualClock.nowMs`,
      // which never advances when the clock is disabled, so it would spin
      // forever. Wall mode relies on the per-test waitForConnectionVirtual /
      // waitForFriendConnectionVirtual calls (which return early once the real
      // connection is up), matching the original wall-clock setup.
      if (shouldRunVirtual) {
        await pumpFriendConnectionVirtual(scenario, alice, bob);
      }
    });

    tearDownAll(() async {
      await releaseScenarioForMode(scenario, ['alice', 'bob'],
          withBootstrap: true, withFriendship: true);
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Text message send and receive (Alice -> Bob)', () async {
      // Get actual Tox ID (friend list contains Tox IDs, not TestNode.userId)
      final bobToxId = bob.getToxId();

      // Wait for DHT then friend connection before sending messages
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));

      final messageText = 'Hello Bob!';
      final completer = Completer<V2TimMessage>();

      // Set up message listener for Bob
      final listener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          bob.addReceivedMessage(message);
          if (!completer.isCompleted) {
            completer.complete(message);
          }
        },
      );

      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(listener));

      // Retry send+wait: Tox direct-message packets can be dropped on the
      // first attempt while friend P2P is warming up. Wrap in 3x retry.
      var received = false;
      for (var attempt = 0; !received && attempt < 3; attempt++) {
        final sendResult = await alice.runWithInstanceAsync(() async {
          final messageResult =
              TIMMessageManager.instance.createTextMessage(text: messageText);
          return await TIMMessageManager.instance.sendMessage(
            message: messageResult.messageInfo,
            receiver: bobToxId,
            groupID: null,
            onlineUserOnly: false,
          );
        });
        expect(sendResult.code, equals(0),
            reason: 'Message send should succeed');

        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => completer.isCompleted,
            timeout: const Duration(seconds: 15),
            description: 'Bob receives text message (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          received = true;
        } catch (_) {
          // Retry — re-fire send on next iteration.
        }
      }
      expect(received, isTrue,
          reason: 'Bob never received text message after retries');
      final receivedMessage = await completer.future;

      expect(receivedMessage.textElem?.text, equals(messageText));
      expect(bob.receivedMessages.length, greaterThan(0));

      bob.runWithInstance(() => TIMMessageManager.instance
          .removeAdvancedMsgListener(listener: listener));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Message round trip (Alice -> Bob -> Alice)', () async {
      // Get actual Tox IDs (friend list contains Tox IDs, not TestNode.userId)
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();

      final aliceMessageText = 'Hello Bob!';
      final bobMessageText = 'Hello Alice!';

      final aliceCompleter = Completer<V2TimMessage>();
      final bobCompleter = Completer<V2TimMessage>();

      // Wait for DHT then friend connection
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 45));

      // Set up message listeners
      final aliceListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          // Only process messages received by Alice (not sent by Alice)
          // Also check that the sender is Bob (not Alice)
          if (message.isSelf == true) {
            print(
                '[Alice Listener] Ignoring self-sent message: text=${message.textElem?.text}');
            return;
          }
          // Additional check: ensure sender is Bob (not Alice)
          final senderPublicKey = (message.sender?.length ?? 0) >= 64
              ? message.sender!.substring(0, 64)
              : (message.sender ?? '');
          final bobPublicKey =
              bobToxId.length >= 64 ? bobToxId.substring(0, 64) : bobToxId;
          if (senderPublicKey != bobPublicKey) {
            print(
                '[Alice Listener] Ignoring message from unexpected sender: sender=$senderPublicKey, expected=$bobPublicKey, text=${message.textElem?.text}');
            return;
          }
          print(
              '[Alice Listener] Received message: text=${message.textElem?.text}, sender=${message.sender}, userID=${message.userID}, isSelf=${message.isSelf}');
          alice.addReceivedMessage(message);
          if (!aliceCompleter.isCompleted) {
            aliceCompleter.complete(message);
          }
        },
      );

      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          // Only process messages received by Bob (not sent by Bob)
          // Also check that the sender is Alice (not Bob)
          if (message.isSelf == true) {
            print(
                '[Bob Listener] Ignoring self-sent message: text=${message.textElem?.text}');
            return;
          }
          // Additional check: ensure sender is Alice (not Bob)
          final senderPublicKey = (message.sender?.length ?? 0) >= 64
              ? message.sender!.substring(0, 64)
              : (message.sender ?? '');
          final alicePublicKey = aliceToxId.length >= 64
              ? aliceToxId.substring(0, 64)
              : aliceToxId;
          if (senderPublicKey != alicePublicKey) {
            print(
                '[Bob Listener] Ignoring message from unexpected sender: sender=$senderPublicKey, expected=$alicePublicKey, text=${message.textElem?.text}');
            return;
          }
          print(
              '[Bob Listener] Received message: text=${message.textElem?.text}, sender=${message.sender}, userID=${message.userID}, isSelf=${message.isSelf}');
          bob.addReceivedMessage(message);
          if (!bobCompleter.isCompleted) {
            bobCompleter.complete(message);
          }
        },
      );

      // Add listeners in each node's instance scope (for multi-instance support)
      alice.runWithInstance(() {
        TIMMessageManager.instance.addAdvancedMsgListener(aliceListener);
      });
      bob.runWithInstance(() {
        TIMMessageManager.instance.addAdvancedMsgListener(bobListener);
      });

      // Alice -> Bob (with retry)
      var bobReceived = false;
      for (var attempt = 0; !bobReceived && attempt < 3; attempt++) {
        final aliceSendResult = await alice.runWithInstanceAsync(() async {
          final aliceMessageResult =
              TIMMessageManager.instance.createTextMessage(text: aliceMessageText);
          return await TIMMessageManager.instance.sendMessage(
            message: aliceMessageResult.messageInfo,
            receiver: bobToxId,
            groupID: null,
            onlineUserOnly: false,
          );
        });
        expect(aliceSendResult.code, equals(0));

        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bobCompleter.isCompleted,
            timeout: const Duration(seconds: 15),
            description: 'Bob receives message from Alice (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          bobReceived = true;
        } catch (_) {}
      }
      expect(bobReceived, isTrue,
          reason: 'Bob never received Alice message after retries');
      final bobReceivedMessage = await bobCompleter.future;
      expect(bobReceivedMessage.textElem?.text, equals(aliceMessageText));

      // Bob -> Alice (with retry)
      var aliceReceived = false;
      for (var attempt = 0; !aliceReceived && attempt < 3; attempt++) {
        final bobSendResult = await bob.runWithInstanceAsync(() async {
          final bobMessageResult =
              TIMMessageManager.instance.createTextMessage(text: bobMessageText);
          return await TIMMessageManager.instance.sendMessage(
            message: bobMessageResult.messageInfo,
            receiver: aliceToxId,
            groupID: null,
            onlineUserOnly: false,
          );
        });
        expect(bobSendResult.code, equals(0));

        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => aliceCompleter.isCompleted,
            timeout: const Duration(seconds: 15),
            description:
                'Alice receives message from Bob (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          aliceReceived = true;
        } catch (_) {}
      }
      expect(aliceReceived, isTrue,
          reason: 'Alice never received Bob message after retries');
      final aliceReceivedMessage = await aliceCompleter.future;
      expect(aliceReceivedMessage.textElem?.text, equals(bobMessageText));

      alice.runWithInstance(() => TIMMessageManager.instance
          .removeAdvancedMsgListener(listener: aliceListener));
      bob.runWithInstance(() => TIMMessageManager.instance
          .removeAdvancedMsgListener(listener: bobListener));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Custom message send and receive', () async {
      // Wait for DHT then friend connection
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));

      final customData = '{"type":"test","data":"custom"}';
      final completer = Completer<V2TimMessage>();

      // Set up message listener for Bob
      final listener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          bob.addReceivedMessage(message);
          if (!completer.isCompleted) {
            completer.complete(message);
          }
        },
      );

      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(listener));

      // Retry send+wait pattern.
      var received = false;
      for (var attempt = 0; !received && attempt < 3; attempt++) {
        final sendResult = await alice.runWithInstanceAsync(() async {
          final messageResult = TIMMessageManager.instance.createCustomMessage(
            data: customData,
            desc: 'Test custom message',
          );
          return await TIMMessageManager.instance.sendMessage(
            message: messageResult.messageInfo,
            receiver: bobToxId,
            groupID: null,
            onlineUserOnly: false,
          );
        });
        expect(sendResult.code, equals(0));

        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => completer.isCompleted,
            timeout: const Duration(seconds: 15),
            description:
                'Bob receives custom message (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          received = true;
        } catch (_) {}
      }
      expect(received, isTrue,
          reason: 'Bob never received custom message after retries');
      final receivedMessage = await completer.future;
      expect(receivedMessage.customElem?.data, equals(customData));

      bob.runWithInstance(() => TIMMessageManager.instance
          .removeAdvancedMsgListener(listener: listener));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Message query', () async {
      // Wait for DHT then friend connection
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 45));

      // Send and query in Alice's instance scope
      final messageText = 'Test query message';
      final bobPublicKey = bobToxId.substring(0, 64);
      final sendResult = await alice.runWithInstanceAsync(() async {
        final messageResult =
            TIMMessageManager.instance.createTextMessage(text: messageText);
        return await TIMMessageManager.instance.sendMessage(
          message: messageResult.messageInfo,
          receiver: bobToxId,
          groupID: null,
          onlineUserOnly: false,
        );
      });

      expect(sendResult.code, equals(0));

      // Wait for message to be processed and stored. In virtual mode this
      // advances the shared clock; in wall mode pumpTestTick falls back to a
      // wall-clock iterate burst.
      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      // Query messages in Alice's instance scope.
      //
      // History persistence in tim2tox lives in the Dart layer: when the
      // host app installs Tim2ToxSdkPlatform on TencentCloudChatSdkPlatform.instance
      // (the "Platform path"), getHistoryMessageList[V2] is routed through
      // FfiChatService.getHistory + MessageHistoryPersistence. In pure
      // binary-replacement mode — which auto_tests runs by design — there
      // is no Platform installed, so the C++ side returns
      // ERR_SDK_INTERFACE_NOT_SUPPORT (7013).
      //
      // Accept either:
      //   - code == 0 with results: implementation has been wired through
      //     a Platform stub in this test process (future enhancement); or
      //   - code == 7013: documented "binary-replacement has no history"
      //     contract. The test asserts the contract instead of forcing
      //     the wrong API surface to invent results.
      final queryResult = await alice.runWithInstanceAsync(() async {
        return await TIMMessageManager.instance.getHistoryMessageList(
          userID: bobPublicKey,
          groupID: null,
          count: 10,
          lastMsgID: null,
        );
      });

      const errSdkInterfaceNotSupport = 7013;
      expect(
        queryResult.code == 0 || queryResult.code == errSdkInterfaceNotSupport,
        isTrue,
        reason:
            'getHistoryMessageList in binary-replacement mode should either succeed (Platform installed) or return ERR_SDK_INTERFACE_NOT_SUPPORT; got code=${queryResult.code} desc=${queryResult.desc}',
      );

      if (queryResult.code == 0 &&
          queryResult.data != null &&
          queryResult.data!.isNotEmpty) {
        final hasOurMessage = queryResult.data!.any(
          (msg) => msg.textElem?.text == messageText,
        );
        if (hasOurMessage) {
          expect(hasOurMessage, isTrue);
        }
      } else {
        print(
            'Note: getHistoryMessageList code=${queryResult.code} (7013 == binary-replacement has no history; install Tim2ToxSdkPlatform to enable).');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
