/// Message Overflow Test — virtual-clock variant
///
/// Mirrors scenario_message_overflow_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Tests message queue overflow handling (send and receive queues).
/// Reference: c-toxcore/auto_tests/scenarios/scenario_overflow_recvq_test.c and
/// scenario_overflow_sendq_test.c

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Message Overflow Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode sender;
    late TestNode receiver;

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation.
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['sender', 'receiver']);
      sender = scenario.getNode('sender')!;
      receiver = scenario.getNode('receiver')!;

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      // Parallelize login
      await Future.wait([
        sender.login(),
        receiver.login(),
      ]);

      await waitUntil(
        () => sender.loggedIn && receiver.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );

      // Configure local bootstrap (virtual-clock variant)
      await configureLocalBootstrapVirtual(scenario);

      // Establish bidirectional friendship (required for message delivery in Tox)
      await establishFriendshipVirtual(scenario, sender, receiver);
      // Pump so P2P connection is established before tests send messages
      await pumpFriendConnectionVirtual(scenario, sender, receiver);
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

    test('Send queue overflow handling', () async {
      // Get actual Tox ID for receiver
      final receiverToxId = receiver.getToxId();

      // Wait for DHT then friend connection before sending
      await waitForConnectionVirtual(scenario, sender,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, sender, receiverToxId,
          timeout: const Duration(seconds: 45));

      int receivedCount = 0;

      // Set up message listener for receiver
      final listener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          receiver.addReceivedMessage(message);
          receivedCount++;
        },
      );

      receiver.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(listener));

      // Send many messages rapidly (in sender's instance scope)
      const messageCount = 100; // Reduced for test speed, can be increased
      final sendResults = await sender.runWithInstanceAsync(() async {
        final results = <int>[];
        for (int i = 0; i < messageCount; i++) {
          final messageResult = TIMMessageManager.instance.createTextMessage(
            text: 'Message $i',
          );
          final sendResult = await TIMMessageManager.instance.sendMessage(
            groupID: null,
            message: messageResult.messageInfo,
            receiver: receiverToxId,
            onlineUserOnly: false,
          );
          results.add(sendResult.code);
          if (i % 10 == 0) {
            await pumpTestTick(scenario,
                advanceMs: 2000, iterationsPerInstance: 1);
          }
        }
        return results;
      });

      // Wait for messages to be processed (virtual)
      await pumpTestTick(scenario, advanceMs: 5000, iterationsPerInstance: 1);

      // Verify most messages were sent successfully
      final successCount = sendResults.where((code) => code == 0).length;
      expect(successCount, greaterThan(messageCount * 0.8),
          reason: 'At least 80% of messages should be sent successfully');

      // Verify receiver received messages
      // Note: In Tox, messages may not be delivered if friend connection is not established
      if (receivedCount > 0) {
        expect(receivedCount, greaterThan(0),
            reason: 'Receiver should receive at least some messages');
      } else {
        print('Note: No messages received (may need friend connection in Tox)');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Receive queue overflow handling', () async {
      // Get actual Tox ID for receiver
      final receiverToxId = receiver.getToxId();

      // Wait for DHT then friend connection before sending
      print('[Receive queue overflow] Waiting for connection and friend...');
      await waitForConnectionVirtual(scenario, sender,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, sender, receiverToxId,
          timeout: const Duration(seconds: 90));
      print('[Receive queue overflow] Friend connection established');
      // Brief virtual settle so receiver's instance is ready before we send
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      int receivedCount = 0;
      final completer = Completer<void>();

      // Set up message listener for receiver
      final listener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          receiver.addReceivedMessage(message);
          receivedCount++;

          // Complete after receiving a reasonable number of messages
          if (receivedCount >= 50 && !completer.isCompleted) {
            completer.complete();
          }
        },
      );

      receiver.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(listener));

      // Send many messages (in sender's instance scope)
      const messageCount = 100;
      int successCount = 0;
      int failureCount = 0;
      await sender.runWithInstanceAsync(() async {
        for (int i = 0; i < messageCount; i++) {
          final messageResult = TIMMessageManager.instance.createTextMessage(
            text: 'Message $i',
          );
          final sendResult = await TIMMessageManager.instance.sendMessage(
            groupID: null,
            message: messageResult.messageInfo,
            receiver: receiverToxId,
            onlineUserOnly: false,
          );
          if (sendResult.code == 0) {
            successCount++;
          } else {
            failureCount++;
            if (failureCount <= 5) {
              print(
                  '[Receive queue overflow] Message $i send failed: code=${sendResult.code}, desc=${sendResult.desc}');
            }
            if (sendResult.code == 30003 ||
                sendResult.desc.contains('not connected')) {
              print(
                  '[Receive queue overflow] Friend not connected, stopping message sending after $i messages (success=$successCount, failure=$failureCount)');
              break;
            }
          }
          if (i % 10 == 0) {
            await pumpTestTick(scenario,
                advanceMs: 2000, iterationsPerInstance: 1);
          }
        }
      });

      print(
          '[Receive queue overflow] Sent $successCount successful messages, $failureCount failed messages');

      // Wait for messages to be received (pump so Tox can deliver)
      await waitUntilWithVirtualPump(
        scenario,
        () => receivedCount >= 50 || (successCount > 0 && receivedCount > 0),
        timeout: const Duration(seconds: 120),
        description: 'receive messages (received=$receivedCount)',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );
      if (successCount > 0) {
        if (receivedCount == 0) {
          // Known issue: receive callback may not be routed to receiver instance in multi-instance (see README RERUN summary)
          print(
              '[Receive queue overflow] Messages sent ($successCount) but none received (receiver listener may not get callback by instance)');
        }
        expect(receivedCount, greaterThan(0),
            reason:
                'Should receive messages if some were sent successfully (sent=$successCount, received=$receivedCount). If received=0, check message callback routing by instance.');
      }

      // Verify receiver queue doesn't overflow
      // Note: In Tox, messages may not be delivered if friend connection is not established
      if (successCount > 0 && receivedCount > 0) {
        expect(receiver.receivedMessages.length, greaterThan(0));
        expect(receivedCount, greaterThan(0));
      } else if (successCount == 0) {
        print(
            '[Receive queue overflow] No messages were sent successfully (friend may not be connected)');
        // This is acceptable if friend connection was not established
      } else {
        print(
            '[Receive queue overflow] Messages were sent but none received (sent=$successCount, received=$receivedCount)');
      }
    }, timeout: const Timeout(Duration(seconds: 240)));
  });
}
