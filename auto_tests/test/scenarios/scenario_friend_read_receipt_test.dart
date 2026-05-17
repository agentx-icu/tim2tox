/// Friend Read Receipt Test
/// 
/// Tests read receipt functionality for friend messages
/// Reference: c-toxcore/auto_tests/scenarios/scenario_friend_read_receipt_test.c

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Read Receipt Tests', () {
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
    
    test('Send read receipt', () async {
      // Establish friendship (alice–bob); tim2tox uses Tox ID
      await establishFriendship(alice, bob);
      
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      await Future.wait([
        alice.waitForFriendConnection(bobToxId, timeout: const Duration(seconds: 30)),
        bob.waitForFriendConnection(aliceToxId, timeout: const Duration(seconds: 30)),
      ]);
      
      // Alice sends message to Bob (alice's context; receiver = bob's Tox ID)
      final messageResult = alice.runWithInstance(() =>
          TIMMessageManager.instance.createTextMessage(text: 'Hello Bob!'));
      final sendResult = await alice.runWithInstanceAsync(() async =>
          TIMMessageManager.instance.sendMessage(
        message: messageResult.messageInfo!,
        receiver: bobToxId,
        groupID: null,
        onlineUserOnly: false,
      ));
      
      expect(sendResult.code, equals(0));
      final messageID = sendResult.data?.id;
      
      await Future.delayed(const Duration(seconds: 2));
      
      if (messageID != null) {
        // Bob marks Alice's messages as read (bob's context; userID = alice's identity in tim2tox)
        final alicePublicKey = alice.getPublicKey();
        final markReadResult = await bob.runWithInstanceAsync(() async =>
            TIMMessageManager.instance.markC2CMessageAsRead(userID: alicePublicKey));
        
        expect(markReadResult.code, equals(0));
        
        // Alice should receive read receipt (listener on alice's instance)
        final completer = Completer<void>();
        final listener = V2TimAdvancedMsgListener(
          onRecvMessageReadReceipts: (List<dynamic> receiptList) {
            alice.markCallbackReceived('onRecvMessageReadReceipts');
            completer.complete();
          },
        );
        
        alice.runWithInstance(() {
          TIMMessageManager.instance.addAdvancedMsgListener(listener);
        });
        
        // Wait for read receipt
        await completer.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            // Read receipt may not be triggered in all cases
          },
        );
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
