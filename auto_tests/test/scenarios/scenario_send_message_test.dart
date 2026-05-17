/// Send Message Test
/// Reference: c-toxcore/auto_tests/scenarios/scenario_send_message_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Send Message Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    
    setUpAll(() async {
      scenario = await acquireSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: true);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
    });

    tearDownAll(() async {
      releaseSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: true);
    });
    
    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });
    
    test('Send text message', () async {
      // Get actual Tox ID (friend list contains Tox IDs, not TestNode.userId)
      final bobToxId = bob.getToxId();
      
      // Wait for DHT then friend connection before sending
      await alice.waitForConnection(timeout: const Duration(seconds: 15));
      await alice.waitForFriendConnection(bobToxId, timeout: const Duration(seconds: 45));
      
      final sendResult = await alice.runWithInstanceAsync(() async {
        final messageResult = TIMMessageManager.instance.createTextMessage(text: 'Hello');
        return await TIMMessageManager.instance.sendMessage(
          message: messageResult.messageInfo,
          receiver: bobToxId,
          groupID: null,
          onlineUserOnly: false,
        );
      });
      expect(sendResult.code, equals(0), reason: 'Message send should succeed');
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Send custom message', () async {
      // Get actual Tox ID (friend list contains Tox IDs, not TestNode.userId)
      final bobToxId = bob.getToxId();
      
      // Wait for DHT then friend connection before sending
      await alice.waitForConnection(timeout: const Duration(seconds: 15));
      await alice.waitForFriendConnection(bobToxId, timeout: const Duration(seconds: 45));
      
      final sendResult = await alice.runWithInstanceAsync(() async {
        final messageResult = TIMMessageManager.instance.createCustomMessage(data: '{"type":"test"}');
        return await TIMMessageManager.instance.sendMessage(
          message: messageResult.messageInfo,
          receiver: bobToxId,
          groupID: null,
          onlineUserOnly: false,
        );
      });
      expect(sendResult.code, equals(0), reason: 'Custom message send should succeed');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
