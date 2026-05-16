// Group vs Conference Comparison Test — virtual-clock variant
//
// Mirrors scenario_group_vs_conference_test.dart 1:1 but drives the harness
// via the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual
// helpers). Compares Group (new API) vs Conference (old API) types.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group vs Conference Comparison Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      // Enable test mode BEFORE login so event_thread never starts.
      await VirtualClock.enableForScenario(scenario);

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
      await Future.wait([
        waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 15)),
        waitForConnectionVirtual(scenario, bob,
            timeout: const Duration(seconds: 15)),
      ]);
      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 90));
      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 4));
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Create Group type (new API)', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group (New API)',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      expect(createResult.data, isNotNull);
      final groupId = createResult.data!;
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final groupsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(groupIDList: [groupId]));
      expect(groupsInfoResult.code, equals(0),
          reason: 'getGroupsInfo failed: ${groupsInfoResult.code}');
      expect(groupsInfoResult.data, isNotNull);
      expect(groupsInfoResult.data!.length, equals(1));
      expect(groupsInfoResult.data!.first.groupInfo?.groupName,
          equals('Test Group (New API)'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Create Conference type (old API)', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'Meeting',
                groupName: 'Test Conference (Old API)',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      expect(createResult.data, isNotNull);
      final conferenceId = createResult.data!;
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final groupsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(groupIDList: [conferenceId]));
      expect(groupsInfoResult.code, equals(0),
          reason: 'getGroupsInfo failed: ${groupsInfoResult.code}');
      expect(groupsInfoResult.data, isNotNull);
      expect(groupsInfoResult.data!.length, equals(1));
      expect(groupsInfoResult.data!.first.groupInfo?.groupName,
          equals('Test Conference (Old API)'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Group type: join and send message', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group Type Test',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      final expectedGroupIds = <String>{groupId};
      const groupMessage = 'Hello from Group type!';
      final alicePublicKey = alice.getPublicKey();
      var bobReceivedMessage = false;
      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          if (!expectedGroupIds.contains(message.groupID ?? '')) {
            return;
          }
          final messageUserID = message.userID ?? '';
          final senderPublicKey = messageUserID.length >= 64
              ? messageUserID.substring(0, 64)
              : messageUserID;
          final fromAlice = senderPublicKey == alicePublicKey;
          final isExpectedText = message.textElem?.text == groupMessage;
          if (fromAlice || isExpectedText) {
            bobReceivedMessage = true;
            bob.addReceivedMessage(message);
          }
        },
      );
      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(bobListener));
      try {
        await Future.wait([
          waitForConnectionVirtual(scenario, alice,
              timeout: const Duration(seconds: 10)),
          waitForConnectionVirtual(scenario, bob,
              timeout: const Duration(seconds: 10)),
        ]);
        await pumpTestTick(scenario,
            advanceMs: 500, iterationsPerInstance: 1);
        // Retry invite + wait: inviteUserToGroup returns code=0 even when the
        // underlying tox_group_invite_friend packet was dropped.
        var inviteArrived = false;
        final bobPublicKey = bob.getPublicKey();
        for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
          bob.clearCallbackReceived('onGroupInvited');
          final inviteResult = await alice.runWithInstanceAsync(() async =>
              TIMGroupManager.instance.inviteUserToGroup(
                  groupID: groupId, userList: [bobPublicKey]));
          expect(inviteResult.code, equals(0),
              reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => bob.callbackReceived['onGroupInvited'] == true,
              timeout: const Duration(seconds: 15),
              description:
                  'Bob onGroupInvited for group type test (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            inviteArrived = true;
          } catch (_) {
            // Retry: friend P2P may not have been ONLINE for the first attempt.
          }
        }
        expect(inviteArrived, isTrue,
            reason: 'Bob never received onGroupInvited after 3 retries');
        await pumpTestTick(scenario, advanceMs: 300, iterationsPerInstance: 1);
        final joinGroupId =
            bob.getLastCallbackGroupId('onGroupInvited') ?? groupId;
        expectedGroupIds.add(joinGroupId);
        final joinResult = await bob.runWithInstanceAsync(() async =>
            TIMManager.instance.joinGroup(groupID: joinGroupId, message: ''));
        expect(joinResult.code, equals(0),
            reason: 'joinGroup failed: ${joinResult.code}');
        await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
            duration: const Duration(seconds: 3));
        final bobInGroup = await waitUntilFounderSeesMemberInGroupVirtual(
            scenario, alice, bob, groupId,
            timeout: const Duration(seconds: 20));
        expect(bobInGroup, isNotNull,
            reason: 'Alice must see Bob in group before sending');
        final sendResult = await alice.runWithInstanceAsync(() async {
          final textResult =
              TIMMessageManager.instance.createTextMessage(text: groupMessage);
          return TIMMessageManager.instance.sendMessage(
              message: textResult.messageInfo!,
              receiver: null,
              groupID: groupId);
        });
        expect(sendResult.code, equals(0));
        await pumpTestTick(scenario,
            advanceMs: 50, iterationsPerInstance: 150);
        await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
        await waitUntilWithVirtualPump(
          scenario,
          () => bobReceivedMessage,
          timeout: const Duration(seconds: 25),
          description: 'Bob receives message',
          advanceMs: 50,
          iterationsPerInstance: 1,
        );
        expect(bobReceivedMessage, isTrue);
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: bobListener));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Conference type: join and send message', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'Meeting',
                groupName: 'Conference Type Test',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;
      final expectedGroupIds = <String>{conferenceId};
      const conferenceMessage = 'Hello from Conference type!';
      final alicePublicKey = alice.getPublicKey();
      var bobReceivedMessage = false;
      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          if (!expectedGroupIds.contains(message.groupID ?? '')) {
            return;
          }
          final messageUserID = message.userID ?? '';
          final senderPublicKey = messageUserID.length >= 64
              ? messageUserID.substring(0, 64)
              : messageUserID;
          final fromAlice = senderPublicKey == alicePublicKey;
          final isExpectedText = message.textElem?.text == conferenceMessage;
          if (fromAlice || isExpectedText) {
            bobReceivedMessage = true;
            bob.addReceivedMessage(message);
          }
        },
      );
      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(bobListener));
      try {
        await Future.wait([
          waitForConnectionVirtual(scenario, alice,
              timeout: const Duration(seconds: 10)),
          waitForConnectionVirtual(scenario, bob,
              timeout: const Duration(seconds: 10)),
        ]);
        await pumpTestTick(scenario,
            advanceMs: 500, iterationsPerInstance: 1);
        // Retry invite + wait: inviteUserToGroup returns code=0 even when the
        // underlying tox_group_invite_friend packet was dropped.
        var inviteArrived = false;
        final bobPublicKey = bob.getPublicKey();
        for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
          bob.clearCallbackReceived('onGroupInvited');
          final inviteResult = await alice.runWithInstanceAsync(() async =>
              TIMGroupManager.instance.inviteUserToGroup(
                  groupID: conferenceId, userList: [bobPublicKey]));
          expect(inviteResult.code, equals(0),
              reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => bob.callbackReceived['onGroupInvited'] == true,
              timeout: const Duration(seconds: 15),
              description:
                  'Bob onGroupInvited for conference type test (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            inviteArrived = true;
          } catch (_) {
            // Retry: friend P2P may not have been ONLINE for the first attempt.
          }
        }
        expect(inviteArrived, isTrue,
            reason: 'Bob never received onGroupInvited after 3 retries');
        await pumpTestTick(scenario, advanceMs: 300, iterationsPerInstance: 1);
        final joinConferenceId =
            bob.getLastCallbackGroupId('onGroupInvited') ?? conferenceId;
        expectedGroupIds.add(joinConferenceId);
        final joinResult = await bob.runWithInstanceAsync(() async =>
            TIMManager.instance
                .joinGroup(groupID: joinConferenceId, message: ''));
        expect(joinResult.code, equals(0),
            reason: 'joinGroup failed: ${joinResult.code}');
        await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
            duration: const Duration(seconds: 3));
        final bobInConference = await waitUntilFounderSeesMemberInGroupVirtual(
            scenario, alice, bob, conferenceId,
            timeout: const Duration(seconds: 20));
        expect(bobInConference, isNotNull,
            reason: 'Alice must see Bob in conference before sending');
        final sendResult = await alice.runWithInstanceAsync(() async {
          final textResult = TIMMessageManager.instance
              .createTextMessage(text: conferenceMessage);
          return TIMMessageManager.instance.sendMessage(
              message: textResult.messageInfo!,
              receiver: null,
              groupID: conferenceId);
        });
        expect(sendResult.code, equals(0));
        await pumpTestTick(scenario,
            advanceMs: 50, iterationsPerInstance: 150);
        await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
        await waitUntilWithVirtualPump(
          scenario,
          () => bobReceivedMessage,
          timeout: const Duration(seconds: 25),
          description: 'Bob receives conference message',
          advanceMs: 50,
          iterationsPerInstance: 1,
        );
        expect(bobReceivedMessage, isTrue);
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: bobListener));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Both types: member list synchronization', () async {
      // Local helper using virtual-clock invite-retry pattern.
      Future<String> inviteThenJoin(String creatorGroupId) async {
        var inviteArrived = false;
        final bobPublicKey = bob.getPublicKey();
        for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
          bob.clearCallbackReceived('onGroupInvited');
          final inviteResult = await alice.runWithInstanceAsync(() async =>
              TIMGroupManager.instance.inviteUserToGroup(
                  groupID: creatorGroupId, userList: [bobPublicKey]));
          expect(inviteResult.code, equals(0),
              reason:
                  'inviteUserToGroup($creatorGroupId) failed: ${inviteResult.desc}');
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => bob.callbackReceived['onGroupInvited'] == true,
              timeout: const Duration(seconds: 15),
              description:
                  'Bob onGroupInvited for $creatorGroupId (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            inviteArrived = true;
          } catch (_) {
            // Retry: friend P2P may not have been ONLINE for the first attempt.
          }
        }
        expect(inviteArrived, isTrue,
            reason:
                'Bob never received onGroupInvited for $creatorGroupId after 3 retries');
        await pumpTestTick(scenario,
            advanceMs: 300, iterationsPerInstance: 1);
        final joinId =
            bob.getLastCallbackGroupId('onGroupInvited') ?? creatorGroupId;
        final joinResult = await bob.runWithInstanceAsync(() async =>
            TIMManager.instance.joinGroup(groupID: joinId, message: ''));
        expect(joinResult.code, equals(0),
            reason: 'joinGroup($joinId) failed: ${joinResult.desc}');
        return joinId;
      }

      final groupResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group Member Test',
                groupID: '',
              ));
      expect(groupResult.code, equals(0));
      final groupId = groupResult.data!;
      final bobGroupId = await inviteThenJoin(groupId);
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final groupMemberResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: bobGroupId,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      expect(groupMemberResult.code, equals(0),
          reason: 'getGroupMemberList failed: ${groupMemberResult.code}');
      expect(groupMemberResult.data, isNotNull);
      expect(groupMemberResult.data!.memberInfoList, isNotNull);
      expect(groupMemberResult.data!.memberInfoList!.length, greaterThan(0));
      final conferenceResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'Meeting',
                groupName: 'Conference Member Test',
                groupID: '',
              ));
      expect(conferenceResult.code, equals(0));
      final conferenceId = conferenceResult.data!;
      final bobConferenceId = await inviteThenJoin(conferenceId);
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final conferenceMemberResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: bobConferenceId,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      expect(conferenceMemberResult.code, equals(0),
          reason: 'getGroupMemberList failed: ${conferenceMemberResult.code}');
      expect(conferenceMemberResult.data, isNotNull);
      expect(conferenceMemberResult.data!.memberInfoList, isNotNull);
      expect(
          conferenceMemberResult.data!.memberInfoList!.length, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Both types: get joined group list', () async {
      final groupResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group List Test',
                groupID: '',
              ));
      expect(groupResult.code, equals(0));
      final conferenceResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'Meeting',
                groupName: 'Conference List Test',
                groupID: '',
              ));
      expect(conferenceResult.code, equals(0));
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final joinedListResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(joinedListResult.code, equals(0),
          reason: 'getJoinedGroupList failed: ${joinedListResult.code}');
      expect(joinedListResult.data, isNotNull);
      final groupIds = joinedListResult.data!.map((g) => g.groupID).toList();
      expect(groupIds, contains(groupResult.data));
      expect(groupIds, contains(conferenceResult.data));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
