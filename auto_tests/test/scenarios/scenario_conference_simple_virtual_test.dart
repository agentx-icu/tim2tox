/// Conference Simple Test — virtual-clock variant
///
/// Mirrors scenario_conference_simple_test.dart 1:1 but drives the harness
/// via the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual
/// helpers).

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_value_callback.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_operation_result.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Simple Tests (Two Nodes) (Virtual)', () {
    late TestScenario scenario;

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);
      await waitUntil(() => alice.loggedIn && bob.loggedIn);

      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Simple conference: create, join, send message', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;

      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 20));

      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Simple Conference',
            groupID: '',
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed with code ${createResult.code}');
      expect(createResult.data, isNotNull);
      final groupId = createResult.data!;

      final alicePublicKey = alice.getPublicKey();

      var bobReceivedMessage = false;
      var bobReceivedMessageCount = 0;

      List<String>? groupMemberPublicKeys;

      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          if (message.groupID == groupId) {
            final messageSender = message.sender ?? message.userID ?? '';
            final senderPublicKey = messageSender.length >= 64
                ? messageSender.substring(0, 64)
                : messageSender;

            bool senderInGroup = false;
            if (groupMemberPublicKeys != null) {
              senderInGroup = groupMemberPublicKeys.contains(senderPublicKey);
            } else {
              senderInGroup = true; // Optimistically accept
            }

            final matchesAlice = (senderPublicKey == alicePublicKey);

            if (senderInGroup || matchesAlice) {
              bobReceivedMessage = true;
              bobReceivedMessageCount++;
              bob.addReceivedMessage(message);
            }
          }
        },
      );

      bob.runWithInstance(() {
        TIMMessageManager.instance.addAdvancedMsgListener(bobListener);
      });

      final bobToxId = bob.getToxId();
      final bobPublicKey = bob.getPublicKey();
      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 5));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 10));
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 10));

      final aliceToxId = alice.getToxId();
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30));
      } catch (e) {
        print('[ConferenceSimpleTest] Warning: Alice did not see Bob online: $e');
      }
      try {
        await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30));
      } catch (e) {
        print('[ConferenceSimpleTest] Warning: Bob did not see Alice online: $e');
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      V2TimValueCallback<List<V2TimGroupMemberOperationResult>>? inviteResult;
      for (int retry = 0; retry < 3; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 2000, iterationsPerInstance: 1);
        }
        inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey],
            ));
        final ir = inviteResult!;
        expect(ir.code, equals(0),
            reason: 'inviteUserToGroup failed with code ${ir.code}');
        expect(ir.data, isNotNull);
        expect(ir.data!.isNotEmpty, isTrue);
        final bobInviteResult = ir.data!.firstWhere(
          (r) => r.memberID == bobPublicKey,
          orElse: () => throw Exception('Bob not found in invite result list'),
        );
        if (bobInviteResult.result == 1) {
          break;
        } else if (retry == 2) {
          throw Exception(
              'Bob invitation failed after 3 attempts: result=${bobInviteResult.result}');
        }
      }

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: groupId,
            message: '',
          ));
      expect(joinResult.code, equals(0),
          reason: 'joinGroup failed with code ${joinResult.code}');

      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      final bobMemberResult = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      if (bobMemberResult.data?.memberInfoList != null) {
        final memberIds = bobMemberResult.data!.memberInfoList!
            .map((m) => m.userID)
            .toList();
        groupMemberPublicKeys = memberIds;
      }

      // Wait until Bob sees at least 2 members.
      final memberSyncDeadline =
          VirtualClock.nowMs + const Duration(seconds: 20).inMilliseconds;
      while (VirtualClock.nowMs < memberSyncDeadline) {
        final list = await bob.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
            ));
        final count = list.data?.memberInfoList?.length ?? 0;
        if (count >= 2) break;
        await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
            duration: const Duration(seconds: 1));
      }

      final sendResult = await alice.runWithInstanceAsync(() async {
        final textResult = TIMMessageManager.instance.createTextMessage(
          text: 'Hello from simple conference!',
        );
        expect(textResult.messageInfo, isNotNull);
        final message = textResult.messageInfo!;
        return await TIMMessageManager.instance.sendMessage(
          message: message,
          receiver: null,
          groupID: groupId,
        );
      });
      expect(sendResult.code, equals(0),
          reason: 'sendMessage failed with code ${sendResult.code}');

      try {
        // Conference message round-trip needs real wall time for the UDP
        // packet to actually deliver — bump wallSleep so virtual ms budget
        // maps to ~equivalent real wall time as in wall mode (~45s).
        await waitUntilWithVirtualPump(
          scenario,
          () => bobReceivedMessage,
          timeout: const Duration(seconds: 90),
          description: 'Bob received group message',
          advanceMs: 50,
          iterationsPerInstance: 1,
          wallSleep: const Duration(milliseconds: 30),
        );
      } catch (e) {
        print(
            '[ConferenceSimpleTest] ERROR: timeout waiting for message. bobReceivedMessageCount=$bobReceivedMessageCount');
        rethrow;
      }

      expect(bobReceivedMessage, isTrue);
      expect(bob.receivedMessages.length, greaterThan(0));

      final receivedMessage = bob.receivedMessages.first;
      expect(receivedMessage.textElem?.text,
          equals('Hello from simple conference!'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Basic conference functionality verification', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;

      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 20));

      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Basic Conference',
            groupID: '',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      final bobPublicKey = bob.getPublicKey();
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 5));
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 5));

      final bobToxId = bob.getToxId();
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30));
      } catch (e) {
        print('Warning: Alice did not see Bob as online yet: $e');
      }
      final aliceToxId = alice.getToxId();
      try {
        await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30));
      } catch (e) {
        print('Warning: Bob did not see Alice as online yet: $e');
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      V2TimValueCallback<List<V2TimGroupMemberOperationResult>>? inviteResult;
      for (int retry = 0; retry < 3; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 2000, iterationsPerInstance: 1);
        }
        inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey],
            ));
        final ir = inviteResult!;
        expect(ir.code, equals(0));
        expect(ir.data, isNotNull);
        expect(ir.data!.isNotEmpty, isTrue);
        final bobInviteResult = ir.data!.firstWhere(
          (r) => r.memberID == bobPublicKey,
          orElse: () => throw Exception('Bob not found in invite result list'),
        );
        if (bobInviteResult.result == 1) {
          break;
        } else if (retry == 2) {
          expect(bobInviteResult.result, equals(1),
              reason:
                  'Bob invitation failed after 3 attempts: result=${bobInviteResult.result}');
        }
      }

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: groupId,
            message: '',
          ));
      expect(joinResult.code, equals(0));

      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 4));
      final listDeadline =
          VirtualClock.nowMs + const Duration(seconds: 20).inMilliseconds;
      while (VirtualClock.nowMs < listDeadline) {
        await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
            duration: const Duration(seconds: 1));
        final aliceList = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getJoinedGroupList());
        final bobList = await bob.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getJoinedGroupList());
        if ((aliceList.data?.length ?? 0) >= 1 &&
            (bobList.data?.length ?? 0) >= 1) {
          break;
        }
        await pumpTestTick(scenario,
            advanceMs: 300, iterationsPerInstance: 1);
      }

      final groupInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(
            groupIDList: [groupId],
          ));
      expect(groupInfoResult.code, equals(0));
      expect(groupInfoResult.data, isNotNull);
      expect(groupInfoResult.data!.length, equals(1));
      expect(groupInfoResult.data!.first.groupInfo?.groupName,
          equals('Basic Conference'));

      final aliceGroupsResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      final bobGroupsResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());

      expect(aliceGroupsResult.code, equals(0));
      expect(bobGroupsResult.code, equals(0));
      expect(aliceGroupsResult.data, isNotNull);
      expect(bobGroupsResult.data, isNotNull);
      expect(aliceGroupsResult.data!.length, greaterThanOrEqualTo(1),
          reason: 'Alice joined list empty');
      expect(bobGroupsResult.data!.length, greaterThanOrEqualTo(1),
          reason: 'Bob joined list empty');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
