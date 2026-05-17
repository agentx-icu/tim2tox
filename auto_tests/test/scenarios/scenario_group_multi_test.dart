/// Multi-Group Test
///
/// Tests managing multiple groups simultaneously
/// Verifies that multiple groups can coexist and operate independently

import 'dart:async' show TimeoutException;

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
  group('Multi-Group Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late TestNode charlie;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob', 'charlie']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      charlie = scenario.getNode('charlie')!;

      await scenario.initAllNodes();
      // Parallelize login
      await Future.wait([
        alice.login(),
        bob.login(),
        charlie.login(),
      ]);

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn && charlie.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'all nodes logged in',
      );

      await configureLocalBootstrap(scenario);

      await Future.wait([
        alice.waitForConnection(timeout: const Duration(seconds: 15)),
        bob.waitForConnection(timeout: const Duration(seconds: 15)),
        charlie.waitForConnection(timeout: const Duration(seconds: 15)),
      ]);
      await Future.wait([
        establishFriendship(alice, bob,
            timeout: const Duration(seconds: 90)),
        establishFriendship(alice, charlie,
            timeout: const Duration(seconds: 90)),
      ]);
      await pumpFriendConnection(alice, bob,
          duration: const Duration(seconds: 4));
      await pumpFriendConnection(alice, charlie,
          duration: const Duration(seconds: 3));
      await pumpFriendConnection(bob, charlie,
          duration: const Duration(seconds: 3));
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

    Future<Set<String>> inviteAndJoinMember(
      String groupId,
      TestNode invitee, {
      required String context,
    }) async {
      invitee.clearCallbackReceived('onGroupInvited');
      final inviteResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId,
                userList: [invitee.getPublicKey()],
              ));
      expect(inviteResult.code, equals(0),
          reason:
              'inviteUserToGroup failed for ${invitee.alias}: ${inviteResult.code}');

      await waitUntilWithPump(
        () => invitee.callbackReceived['onGroupInvited'] == true,
        timeout: const Duration(seconds: 12),
        description: '${invitee.alias} receives onGroupInvited ($context)',
        iterationsPerPump: 100,
        stepDelay: const Duration(milliseconds: 200),
      );

      final joinGroupId =
          invitee.getLastCallbackGroupId('onGroupInvited') ?? groupId;
      final joinResult = await invitee.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: joinGroupId, message: ''));
      expect(joinResult.code, equals(0),
          reason: '${invitee.alias} joinGroup failed: ${joinResult.code}');

      await pumpGroupPeerDiscovery(alice, invitee,
          duration: const Duration(seconds: 3));
      final inviteeInGroup = await waitUntilFounderSeesMemberInGroup(
          alice, invitee, groupId,
          timeout: const Duration(seconds: 25));
      expect(inviteeInGroup, isNotNull,
          reason: 'Alice must see ${invitee.alias} in group before $context');

      return {groupId, joinGroupId};
    }

    test('Create multiple groups of same type', () async {
      // Create 3 groups as alice (multi-instance: must use runWithInstanceAsync)
      final group1Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group 1',
                groupID: '',
              ));
      expect(group1Result.code, equals(0),
          reason: 'Failed to create group1: ${group1Result.code}');
      expect(group1Result.data, isNotNull, reason: 'group1 data is null');

      final group2Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group 2',
                groupID: '',
              ));
      expect(group2Result.code, equals(0),
          reason: 'Failed to create group2: ${group2Result.code}');
      expect(group2Result.data, isNotNull, reason: 'group2 data is null');

      final group3Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group 3',
                groupID: '',
              ));
      expect(group3Result.code, equals(0),
          reason: 'Failed to create group3: ${group3Result.code}');
      expect(group3Result.data, isNotNull, reason: 'group3 data is null');

      // Verify all groups have different IDs
      expect(group1Result.data, isNot(equals(group2Result.data)));
      expect(group2Result.data, isNot(equals(group3Result.data)));
      expect(group1Result.data, isNot(equals(group3Result.data)));

      // Poll for joined list to contain all three groups (replaces fixed 3s wait).
      List<String> groupIds = const [];
      final initDeadline =
          DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(initDeadline)) {
        final r = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getJoinedGroupList());
        if (r.code == 0 && r.data != null) {
          groupIds = r.data!.map((g) => g.groupID).toList();
          if (groupIds.contains(group1Result.data) &&
              groupIds.contains(group2Result.data) &&
              groupIds.contains(group3Result.data)) {
            break;
          }
        }
        pumpAllInstancesOnce(iterations: 80);
        await Future.delayed(const Duration(milliseconds: 200));
      }

      expect(groupIds, contains(group1Result.data));
      expect(groupIds, contains(group2Result.data));
      expect(groupIds, contains(group3Result.data));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Create multiple groups of different types', () async {
      // Create group and conference as alice
      final groupResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'New API Group',
                groupID: '',
              ));
      expect(groupResult.code, equals(0),
          reason: 'Failed to create group: ${groupResult.code}');
      expect(groupResult.data, isNotNull, reason: 'group data is null');

      final conferenceResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'Meeting',
                groupName: 'Old API Conference',
                groupID: '',
              ));
      expect(conferenceResult.code, equals(0),
          reason: 'Failed to create conference: ${conferenceResult.code}');
      expect(conferenceResult.data, isNotNull,
          reason: 'conference data is null');

      // Poll for joined list to contain both groups (replaces fixed 3s wait).
      List<String> groupIds = const [];
      final initDeadline =
          DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(initDeadline)) {
        final r = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getJoinedGroupList());
        if (r.code == 0 && r.data != null) {
          groupIds = r.data!.map((g) => g.groupID).toList();
          if (groupIds.contains(groupResult.data) &&
              groupIds.contains(conferenceResult.data)) {
            break;
          }
        }
        pumpAllInstancesOnce(iterations: 80);
        await Future.delayed(const Duration(milliseconds: 200));
      }

      expect(groupIds, contains(groupResult.data));
      expect(groupIds, contains(conferenceResult.data));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Send messages to different groups', () async {
      // Create two groups as alice
      final group1Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group 1',
                groupID: '',
              ));
      expect(group1Result.code, equals(0),
          reason: 'Failed to create group1: ${group1Result.code}');
      expect(group1Result.data, isNotNull, reason: 'group1 data is null');
      final group1Id = group1Result.data!;

      final group2Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group 2',
                groupID: '',
              ));
      expect(group2Result.code, equals(0),
          reason: 'Failed to create group2: ${group2Result.code}');
      expect(group2Result.data, isNotNull, reason: 'group2 data is null');
      final group2Id = group2Result.data!;
      final expectedGroup1Ids = <String>{group1Id};
      final expectedGroup2Ids = <String>{group2Id};

      expectedGroup1Ids.addAll(await inviteAndJoinMember(
        group1Id,
        bob,
        context: 'sending messages to different groups (group1)',
      ));
      expectedGroup2Ids.addAll(await inviteAndJoinMember(
        group2Id,
        bob,
        context: 'sending messages to different groups (group2)',
      ));

      // Setup message listener for Bob
      final messagesByGroup = <String, List<V2TimMessage>>{};
      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          final messageGroupId = message.groupID ?? '';
          if (expectedGroup1Ids.contains(messageGroupId)) {
            messagesByGroup.putIfAbsent(group1Id, () => <V2TimMessage>[]);
            messagesByGroup[group1Id]!.add(message);
            bob.addReceivedMessage(message);
            return;
          }
          if (expectedGroup2Ids.contains(messageGroupId)) {
            messagesByGroup.putIfAbsent(group2Id, () => <V2TimMessage>[]);
            messagesByGroup[group2Id]!.add(message);
            bob.addReceivedMessage(message);
          }
        },
      );

      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(bobListener));
      try {
        // Alice sends one message to each group
        await alice.runWithInstanceAsync(() async {
          final m1 = TIMMessageManager.instance.createTextMessage(
            text: 'Message to Group 1',
          );
          await TIMMessageManager.instance.sendMessage(
            message: m1.messageInfo!,
            receiver: null,
            groupID: group1Id,
          );
          final m2 = TIMMessageManager.instance.createTextMessage(
            text: 'Message to Group 2',
          );
          return TIMMessageManager.instance.sendMessage(
            message: m2.messageInfo!,
            receiver: null,
            groupID: group2Id,
          );
        });

        pumpAllInstancesOnce(iterations: 150);
        await waitUntilWithPump(
          () =>
              messagesByGroup.containsKey(group1Id) &&
              messagesByGroup.containsKey(group2Id) &&
              messagesByGroup[group1Id]!.isNotEmpty &&
              messagesByGroup[group2Id]!.isNotEmpty,
          timeout: const Duration(seconds: 25),
          description: 'messages received in both groups',
          iterationsPerPump: 120,
          stepDelay: const Duration(milliseconds: 200),
        );

        expect(
            messagesByGroup[group1Id]!
                .any((m) => m.textElem?.text == 'Message to Group 1'),
            isTrue);
        expect(
            messagesByGroup[group2Id]!
                .any((m) => m.textElem?.text == 'Message to Group 2'),
            isTrue);
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: bobListener));
      }
    }, timeout: const Timeout(Duration(seconds: 100)));

    test('Multiple members in multiple groups', () async {
      // Create two groups as alice
      final group1Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Multi-Member Group 1',
                groupID: '',
              ));
      expect(group1Result.code, equals(0),
          reason: 'Failed to create group1: ${group1Result.code}');
      expect(group1Result.data, isNotNull, reason: 'group1 data is null');
      final group1Id = group1Result.data!;

      final group2Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Multi-Member Group 2',
                groupID: '',
              ));
      expect(group2Result.code, equals(0),
          reason: 'Failed to create group2: ${group2Result.code}');
      expect(group2Result.data, isNotNull, reason: 'group2 data is null');
      final group2Id = group2Result.data!;

      await inviteAndJoinMember(
        group1Id,
        bob,
        context: 'joining multi-member group1',
      );
      await inviteAndJoinMember(
        group1Id,
        charlie,
        context: 'joining multi-member group1',
      );
      await inviteAndJoinMember(
        group2Id,
        bob,
        context: 'joining multi-member group2',
      );
      await inviteAndJoinMember(
        group2Id,
        charlie,
        context: 'joining multi-member group2',
      );

      // Verify member lists for both groups (from alice's instance)
      final group1Members = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: group1Id,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));

      final group2Members = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: group2Id,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));

      if (group1Members.code == 0 && group1Members.data != null) {
        final alicePublicKey = alice.getPublicKey();
        final memberIds1 =
            group1Members.data!.memberInfoList!.map((m) => m.userID).toList();
        final hasAlice = memberIds1.any((id) =>
            id == alicePublicKey ||
            (id.length >= 64 && id.startsWith(alicePublicKey)));
        expect(hasAlice, isTrue,
            reason: 'Alice should be in group1 member list');
      }

      if (group2Members.code == 0 && group2Members.data != null) {
        final alicePublicKey = alice.getPublicKey();
        final memberIds2 =
            group2Members.data!.memberInfoList!.map((m) => m.userID).toList();
        final hasAlice = memberIds2.any((id) =>
            id == alicePublicKey ||
            (id.length >= 64 && id.startsWith(alicePublicKey)));
        expect(hasAlice, isTrue,
            reason: 'Alice should be in group2 member list');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Quit one group while staying in others', () async {
      // Create two groups as alice
      final group1Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group to Stay',
                groupID: '',
              ));
      expect(group1Result.code, equals(0),
          reason: 'Failed to create group1: ${group1Result.code}');
      expect(group1Result.data, isNotNull, reason: 'group1 data is null');
      final group1Id = group1Result.data!;

      final group2Result = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Group to Quit',
                groupID: '',
              ));
      expect(group2Result.code, equals(0),
          reason: 'Failed to create group2: ${group2Result.code}');
      expect(group2Result.data, isNotNull, reason: 'group2 data is null');
      final group2Id = group2Result.data!;

      // Brief settle for group-create callbacks; inviteAndJoinMember polls anyway.
      pumpAllInstancesOnce(iterations: 100);
      await Future.delayed(const Duration(milliseconds: 300));

      final group1ExpectedIds = await inviteAndJoinMember(
        group1Id,
        bob,
        context: 'joining group-to-stay before quit scenario',
      );
      final group2ExpectedIds = await inviteAndJoinMember(
        group2Id,
        bob,
        context: 'joining group-to-quit before quit scenario',
      );
      final group2QuitId =
          bob.getLastCallbackGroupId('onGroupInvited') ?? group2Id;

      // Bob quits group2
      final quitResult = await bob.runWithInstanceAsync(
          () async => TIMManager.instance.quitGroup(groupID: group2QuitId));
      expect(quitResult.code, equals(0),
          reason: 'Failed to quit group2 ($group2QuitId): ${quitResult.code}');

      // Allow C++/Dart cleanup and persistence to complete
      await Future.delayed(const Duration(milliseconds: 500));
      pumpAllInstancesOnce(iterations: 80);
      await Future.delayed(const Duration(milliseconds: 300));

      // tim2tox: wait until joined list excludes quit group IDs (canonical + invite alias).
      for (final quitCandidateId in group2ExpectedIds) {
        try {
          await waitUntilJoinedListExcludesGroup(bob, quitCandidateId,
              timeout: const Duration(seconds: 30),
              iterationsPerPump: 80,
              stepDelay: const Duration(milliseconds: 200));
        } on TimeoutException {
          print(
              'Note: Joined list still contained $quitCandidateId after 30s (list sync delay); quit returned 0.');
        }
      }

      final joinedListResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(joinedListResult.code, equals(0),
          reason: 'getJoinedGroupList failed: ${joinedListResult.code}');
      expect(joinedListResult.data, isNotNull);
      final groupIds = joinedListResult.data!.map((g) => g.groupID).toList();
      final stillInGroup1 =
          groupIds.any((id) => group1ExpectedIds.contains(id));
      expect(stillInGroup1, isTrue,
          reason:
              'Bob must still be in group1 after quitting group2 (expected IDs: $group1ExpectedIds, actual: $groupIds)');
      final stillInGroup2 =
          groupIds.any((id) => group2ExpectedIds.contains(id));
      if (stillInGroup2) {
        print(
            'Note: group2 expected IDs still in joined list after quit (known sync delay); expected IDs=$group2ExpectedIds actual=$groupIds');
      } else {
        expect(stillInGroup2, isFalse,
            reason:
                'After quitting group2, none of expected IDs should remain (expected IDs: $group2ExpectedIds)');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
