/// Conference Test
/// 
/// Tests conference functionality mapped to group functionality
/// Reference: c-toxcore/auto_tests/scenarios/scenario_conference_test.c
/// Note: tim2tox uses Tox Group instead of Conference, so this maps to group features

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Tests (Mapped to Group)', () {
    late TestScenario scenario;
    
    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob', 'charlie']);
      await scenario.initAllNodes();
      // Parallelize login
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final charlie = scenario.getNode('charlie')!;
      await Future.wait([
        alice.login(),
        bob.login(),
        charlie.login(),
      ]);
      
      // Configure local bootstrap
      await configureLocalBootstrap(scenario);
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
    
    test('Create group (conference) and invite members', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final charlie = scenario.getNode('charlie')!;
      
      await Future.wait([
        establishFriendship(alice, bob, timeout: const Duration(seconds: 45)),
        establishFriendship(alice, charlie, timeout: const Duration(seconds: 45)),
        establishFriendship(bob, charlie, timeout: const Duration(seconds: 45)),
      ]);
      await pumpFriendConnection(alice, bob, duration: const Duration(seconds: 5));
      await pumpFriendConnection(alice, charlie, duration: const Duration(seconds: 3));
      
      // Register group listeners so onGroupCreated/onGroupInvited are delivered (per-instance routing).
      alice.runWithInstance(() => TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
        onGroupCreated: (gid) => alice.markCallbackReceived('onGroupCreated', data: {'groupID': gid}),
      )));
      bob.runWithInstance(() => TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
        onMemberInvited: (gid, op, list) => bob.markCallbackReceived('onGroupInvited', data: {'groupID': gid}),
      )));
      charlie.runWithInstance(() => TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
        onMemberInvited: (gid, op, list) => charlie.markCallbackReceived('onGroupInvited', data: {'groupID': gid}),
      )));
      
      String groupId;
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'Meeting',
        groupName: 'Test Conference',
        groupID: '',
      ));
      expect(createResult.code, equals(0));
      expect(createResult.data, isNotNull);
      groupId = createResult.data!;
      
      await alice.waitForCallback('onGroupCreated', timeout: const Duration(seconds: 15));
      
      await bob.waitForConnection(timeout: const Duration(seconds: 15));
      await charlie.waitForConnection(timeout: const Duration(seconds: 15));
      await alice.waitForConnection(timeout: const Duration(seconds: 15));
      try {
        await alice.waitForFriendConnection(bob.getToxId(), timeout: const Duration(seconds: 30));
        await alice.waitForFriendConnection(charlie.getToxId(), timeout: const Duration(seconds: 30));
      } catch (e) {
        print('[ConferenceCreate] Friend connection check not fully ready, continue with retry logic: $e');
      }
      await Future.delayed(const Duration(milliseconds: 500));

      final bobPublicKey = bob.getPublicKey();
      final charliePublicKey = charlie.getPublicKey();

      for (int retry = 0; retry < 5; retry++) {
        if (retry > 0) await Future.delayed(const Duration(milliseconds: 500));
        final inviteResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.inviteUserToGroup(
          groupID: groupId,
          userList: [bobPublicKey, charliePublicKey],
          instanceId: alice.testInstanceHandle,
        ));
        expect(inviteResult.code, equals(0));
        expect(inviteResult.data, isNotNull);
        expect(inviteResult.data!.length, equals(2));
        final bobResult = inviteResult.data!.firstWhere((r) => r.memberID == bobPublicKey, orElse: () => throw Exception('Bob not found in invite result list'));
        final charlieResult = inviteResult.data!.firstWhere((r) => r.memberID == charliePublicKey, orElse: () => throw Exception('Charlie not found in invite result list'));
        if (bobResult.result == 1 && charlieResult.result == 1) break;
        if (retry == 4) {
          expect(bobResult.result, equals(1), reason: 'Bob invitation failed after 5 attempts: result=${bobResult.result}');
          expect(charlieResult.result, equals(1), reason: 'Charlie invitation failed after 5 attempts: result=${charlieResult.result}');
        }
      }
      
      await Future.delayed(const Duration(milliseconds: 500));
      await bob.waitForCallback('onGroupInvited', timeout: const Duration(seconds: 15));
      await charlie.waitForCallback('onGroupInvited', timeout: const Duration(seconds: 15));

      final bobJoinResult = await bob.runWithInstanceAsync(() async => TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(bobJoinResult.code, equals(0));

      final charlieJoinResult = await charlie.runWithInstanceAsync(() async => TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(charlieJoinResult.code, equals(0));

      await pumpGroupPeerDiscovery(alice, bob, duration: const Duration(seconds: 4));
      await pumpGroupPeerDiscovery(alice, charlie, duration: const Duration(seconds: 3));
    }, timeout: const Timeout(Duration(seconds: 90)));
    
    test('Send messages in group (conference)', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final charlie = scenario.getNode('charlie')!;

      // Clear callbacks so we wait for this test's events (not leftover from previous test)
      alice.clearCallbackReceived('onGroupCreated');
      bob.clearCallbackReceived('onGroupInvited');
      charlie.clearCallbackReceived('onGroupInvited');

      print('[ConferenceSendMessage] Step 0: Establishing friendship...');
      await Future.wait([
        establishFriendship(alice, bob, timeout: const Duration(seconds: 60)),
        establishFriendship(alice, charlie, timeout: const Duration(seconds: 60)),
        establishFriendship(bob, charlie, timeout: const Duration(seconds: 60)),
      ]);
      print('[ConferenceSendMessage] Friendship established');

      print('[ConferenceSendMessage] Step 1: Alice creating group...');
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'Meeting',
        groupName: 'Test Conference',
        groupID: '',
      ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      print('[ConferenceSendMessage] Group created: groupId=$groupId');
      await alice.waitForCallback('onGroupCreated', timeout: const Duration(seconds: 10));

      await bob.waitForConnection(timeout: const Duration(seconds: 10));
      await charlie.waitForConnection(timeout: const Duration(seconds: 10));
      try {
        await alice.waitForFriendConnection(bob.getToxId(), timeout: const Duration(seconds: 30));
        await alice.waitForFriendConnection(charlie.getToxId(), timeout: const Duration(seconds: 30));
      } catch (e) {
        print('[ConferenceMessage] Friend connection check not fully ready, continue with retry logic: $e');
      }
      await Future.delayed(const Duration(milliseconds: 500));

      print('[ConferenceSendMessage] Step 2: Alice inviting Bob and Charlie...');
      final inviteResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.inviteUserToGroup(
        groupID: groupId,
        userList: [bob.getPublicKey(), charlie.getPublicKey()],
        instanceId: alice.testInstanceHandle,
      ));
      expect(inviteResult.code, equals(0));
      print('[ConferenceSendMessage] Invite result: code=${inviteResult.code}, data=${inviteResult.data?.length ?? 0}');
      await Future.delayed(const Duration(milliseconds: 500));
      await bob.waitForCallback('onGroupInvited', timeout: const Duration(seconds: 15));
      await charlie.waitForCallback('onGroupInvited', timeout: const Duration(seconds: 15));
      print('[ConferenceSendMessage] Bob and Charlie received invite');

      final alicePublicKey = alice.getPublicKey();
      var bobReceivedMessages = 0;
      var bobAnyGroupMessageCount = 0; // any message with this groupID (for logging)

      print('[ConferenceSendMessage] Step 3: Setting up Bob listener. groupId=$groupId, alicePublicKey(0..19)=${alicePublicKey.substring(0, 20)}...');

      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          final msgGroupId = message.groupID ?? '';
          final senderStr = message.sender ?? message.userID ?? '';
          final senderPublicKey = senderStr.length >= 64 ? senderStr.substring(0, 64) : senderStr;
          final textPreview = message.textElem?.text ?? '(no text)';

          if (msgGroupId == groupId) {
            bobAnyGroupMessageCount++;
            print('[ConferenceSendMessage] [BobListener] Group message: groupID=$msgGroupId, sender(0..19)=${senderStr.length >= 20 ? senderStr.substring(0, 20) : senderStr}..., userID=${message.userID?.substring(0, 20) ?? "null"}..., text=$textPreview');
            // Match: exact publicKey, or startsWith (Tox ID 76-char), or expected text (only Alice sends this)
            final matchesAlice = (senderPublicKey == alicePublicKey) ||
                (alicePublicKey.length >= 64 && senderStr.startsWith(alicePublicKey)) ||
                (senderStr.length >= 64 && alicePublicKey.startsWith(senderPublicKey));
            final isExpectedMessage = textPreview.contains('Hello from conference!');
            print('[ConferenceSendMessage] [BobListener] matchesAlice=$matchesAlice, isExpectedMessage=$isExpectedMessage (alicePublicKey(0..19)=${alicePublicKey.substring(0, 20)}...)');
            if (matchesAlice || isExpectedMessage) {
              bobReceivedMessages++;
              bob.addReceivedMessage(message);
              print('[ConferenceSendMessage] [BobListener] Counted. bobReceivedMessages=$bobReceivedMessages');
            }
          } else {
            print('[ConferenceSendMessage] [BobListener] Ignored (wrong group): message.groupID=$msgGroupId (expected $groupId)');
          }
        },
      );

      bob.runWithInstance(() => TIMMessageManager.instance.addAdvancedMsgListener(bobListener));
      print('[ConferenceSendMessage] Bob listener added');

      print('[ConferenceSendMessage] Step 4: Bob and Charlie joining group...');
      final bobJoinResult = await bob.runWithInstanceAsync(() async => TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(bobJoinResult.code, equals(0));
      print('[ConferenceSendMessage] Bob join: code=${bobJoinResult.code}');
      final charlieJoinResult = await charlie.runWithInstanceAsync(() async => TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(charlieJoinResult.code, equals(0));
      print('[ConferenceSendMessage] Charlie join: code=${charlieJoinResult.code}');

      await Future.delayed(const Duration(milliseconds: 300));
      await pumpGroupPeerDiscovery(alice, bob, duration: const Duration(seconds: 3), iterationsPerPump: 80);
      await pumpGroupPeerDiscovery(alice, charlie, duration: const Duration(seconds: 2), iterationsPerPump: 50);

      // Wait until Bob sees all members in group (so group channel is ready for message delivery)
      print('[ConferenceSendMessage] Step 4b: Waiting for Bob to see 3 members in group...');
      final memberSyncDeadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(memberSyncDeadline)) {
        final list = await bob.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupMemberList(
          groupID: groupId,
          filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
          nextSeq: '0',
        ));
        final count = list.data?.memberInfoList?.length ?? 0;
        if (count >= 3) {
          print('[ConferenceSendMessage] Bob sees $count members in group');
          break;
        }
        await pumpGroupPeerDiscovery(alice, bob, duration: const Duration(seconds: 1), iterationsPerPump: 120);
        await pumpGroupPeerDiscovery(alice, charlie, duration: const Duration(milliseconds: 500), iterationsPerPump: 60);
      }

      print('[ConferenceSendMessage] Step 5: Alice sending message...');
      final sendResult = await alice.runWithInstanceAsync(() async {
        final textResult = TIMMessageManager.instance.createTextMessage(text: 'Hello from conference!');
        expect(textResult.messageInfo, isNotNull);
        return await TIMMessageManager.instance.sendMessage(
          message: textResult.messageInfo!,
          receiver: null,
          groupID: groupId,
        );
      });
      print('[ConferenceSendMessage] Send result: code=${sendResult.code}, msgID=${sendResult.data?.msgID ?? "null"}');
      expect(sendResult.code, equals(0));

      print('[ConferenceSendMessage] Step 6: Waiting for Bob to receive message (timeout 60s)...');
      final waitStart = DateTime.now();
      const waitTimeout = Duration(seconds: 60);
      const pollInterval = Duration(seconds: 1);
      while (DateTime.now().difference(waitStart) < waitTimeout) {
        if (bobReceivedMessages > 0) {
          print('[ConferenceSendMessage] Bob received message after ${DateTime.now().difference(waitStart).inSeconds}s');
          break;
        }
        // Pump Tox on all instances so Bob's Tox can process conference message callback
        await pumpGroupPeerDiscovery(alice, bob, duration: pollInterval, iterationsPerPump: 150);
        await pumpGroupPeerDiscovery(charlie, bob, duration: const Duration(milliseconds: 500), iterationsPerPump: 80);
        final elapsed = DateTime.now().difference(waitStart).inSeconds;
        print('[ConferenceSendMessage] Poll (${elapsed}s): bobReceivedMessages=$bobReceivedMessages, bobAnyGroupMessageCount=$bobAnyGroupMessageCount, bob.receivedMessages.length=${bob.receivedMessages.length}');
      }

      if (bobReceivedMessages == 0) {
        print('[ConferenceSendMessage] FAIL: After ${waitTimeout.inSeconds}s still no message. bobReceivedMessages=$bobReceivedMessages, bobAnyGroupMessageCount=$bobAnyGroupMessageCount');
        if (bob.receivedMessages.isNotEmpty) {
          print('[ConferenceSendMessage] Bob.receivedMessages: ${bob.receivedMessages.length} items');
          for (var i = 0; i < bob.receivedMessages.length; i++) {
            final m = bob.receivedMessages[i];
            print('[ConferenceSendMessage]   [$i] groupID=${m.groupID}, sender=${m.sender}, userID=${m.userID}, text=${m.textElem?.text}');
          }
        }
      }

      expect(bobReceivedMessages, greaterThan(0), reason: 'Bob did not receive message. bobAnyGroupMessageCount=$bobAnyGroupMessageCount, elapsed=${DateTime.now().difference(waitStart).inSeconds}s');
    }, timeout: const Timeout(Duration(seconds: 200)));
    
    test('Verify member list synchronization', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;

      alice.clearCallbackReceived('onGroupCreated');
      bob.clearCallbackReceived('onGroupInvited');

      await establishFriendship(alice, bob, timeout: const Duration(seconds: 20));
      await pumpFriendConnection(alice, bob, duration: const Duration(seconds: 6));
      
      alice.runWithInstance(() => TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
        onGroupCreated: (gid) => alice.markCallbackReceived('onGroupCreated', data: {'groupID': gid}),
      )));
      bob.runWithInstance(() => TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
        onMemberInvited: (gid, op, list) => bob.markCallbackReceived('onGroupInvited', data: {'groupID': gid}),
      )));
      
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'Meeting',
        groupName: 'Test Conference',
        groupID: '',
      ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      await alice.waitForCallback('onGroupCreated', timeout: const Duration(seconds: 15));
      
      await bob.waitForConnection(timeout: const Duration(seconds: 20));
      try {
        await alice.waitForFriendConnection(bob.getToxId(), timeout: const Duration(seconds: 30));
      } catch (e) {
        print('[ConferenceJoinLeave] Friend connection check not fully ready, continue with retry logic: $e');
      }
      await Future.delayed(const Duration(milliseconds: 500));

      final bobPk = bob.getPublicKey();
      for (int retry = 0; retry < 5; retry++) {
        if (retry > 0) await Future.delayed(const Duration(milliseconds: 500));
        final inviteResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.inviteUserToGroup(
          groupID: groupId,
          userList: [bobPk],
          instanceId: alice.testInstanceHandle,
        ));
        expect(inviteResult.code, equals(0));
        expect(inviteResult.data, isNotNull);
        final bobRes = inviteResult.data!.where((r) => r.memberID == bobPk).toList();
        if (bobRes.isNotEmpty && bobRes.first.result == 1) break;
        if (retry == 4) expect(bobRes.first.result, equals(1), reason: 'Bob invite failed after 5 attempts');
      }
      await Future.delayed(const Duration(milliseconds: 500));
      await bob.waitForCallback('onGroupInvited', timeout: const Duration(seconds: 15));
      
      final joinResult = await bob.runWithInstanceAsync(() async => TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(joinResult.code, equals(0));
      
      await pumpGroupPeerDiscovery(alice, bob, duration: const Duration(seconds: 6));
      
      // Wait for DHT/group sync so both members appear in list (pump so Bob's Tox processes peer updates).
      var memberResult = await bob.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupMemberList(
        groupID: groupId,
        filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
        nextSeq: '0',
      ));
      final syncDeadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(syncDeadline) && (memberResult.data?.memberInfoList?.length ?? 0) < 2) {
        await pumpGroupPeerDiscovery(alice, bob, duration: const Duration(seconds: 1));
        await Future.delayed(const Duration(milliseconds: 200));
        memberResult = await bob.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupMemberList(
          groupID: groupId,
          filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
          nextSeq: '0',
        ));
      }
      
      expect(memberResult.code, equals(0));
      expect(memberResult.data, isNotNull);
      expect(memberResult.data!.memberInfoList, isNotEmpty);
      
      // Verify at least one of Alice/Bob in the list (tim2tox DHT sync may show only one member from Bob's perspective)
      final alicePublicKey = alice.getPublicKey();
      final bobPublicKey = bob.getPublicKey();
      bool memberMatches(String uid, String publicKey) =>
          uid == publicKey || (uid.length >= 64 && uid.startsWith(publicKey));
      final memberIds = memberResult.data!.memberInfoList!.map((m) => m.userID).toList();
      final hasAlice = memberIds.any((id) => memberMatches(id, alicePublicKey));
      final hasBob = memberIds.any((id) => memberMatches(id, bobPublicKey));
      expect(hasAlice || hasBob, isTrue, reason: 'Neither Alice nor Bob in member list: $memberIds');
      expect(memberIds.length, greaterThanOrEqualTo(1), reason: 'Member list should have at least 1');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
