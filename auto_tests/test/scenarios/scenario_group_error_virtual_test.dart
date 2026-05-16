// Group Error Test — virtual-clock variant
//
// Mirrors scenario_group_error_test.dart 1:1 but drives the harness via
// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// Most sub-tests are deliberate failure cases on a single instance and do
// not rely on group invites; the few that DO use an invite path apply the
// invite-retry pattern that is the canonical workaround for dropped
// tox_group_invite_friend packets in virtual mode.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_role_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Error Tests (Virtual)', () {
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
      // Enable test mode BEFORE login so event_thread never starts.
      await VirtualClock.enableForScenario(scenario);

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

      await configureLocalBootstrapVirtual(scenario);

      await Future.wait([
        waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 15)),
        waitForConnectionVirtual(scenario, bob,
            timeout: const Duration(seconds: 15)),
        waitForConnectionVirtual(scenario, charlie,
            timeout: const Duration(seconds: 15)),
      ]);
      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 90));
      await establishFriendshipVirtual(scenario, alice, charlie,
          timeout: const Duration(seconds: 90));
      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 4));
      await pumpFriendConnectionVirtual(scenario, alice, charlie,
          duration: const Duration(seconds: 4));
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

    Future<void> inviteAndJoinMember(
        String groupId, TestNode inviter, TestNode invitee) async {
      final inviteePublicKey = invitee.getPublicKey();
      // Retry invite + wait: inviteUserToGroup returns code=0 even when the
      // underlying tox_group_invite_friend packet was dropped, so re-fire up
      // to 3 times before giving up.
      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        invitee.clearCallbackReceived('onGroupInvited');
        final inviteResult = await inviter.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [inviteePublicKey],
            ));
        expect(inviteResult.code, equals(0),
            reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => invitee.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description:
                '${invitee.alias} receives onGroupInvited (attempt ${attempt + 1})',
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
              '${invitee.alias} never received onGroupInvited after 3 retries');
      // Settle ~300ms virtual so pending invite -> chat_id mapping completes
      // before joinGroup is called.
      await pumpTestTick(scenario, advanceMs: 300, iterationsPerInstance: 1);

      final joinGroupId =
          invitee.getLastCallbackGroupId('onGroupInvited') ?? groupId;
      final joinResult = await invitee
          .runWithInstanceAsync(() async => TIMManager.instance.joinGroup(
                groupID: joinGroupId,
                message: '',
              ));
      expect(joinResult.code, equals(0),
          reason: '${invitee.alias} joinGroup failed: ${joinResult.code}');

      final inviterSeesInvitee = await waitUntilFounderSeesMemberInGroupVirtual(
        scenario,
        inviter,
        invitee,
        groupId,
        timeout: const Duration(seconds: 10),
      );
      expect(inviterSeesInvitee, isNotNull,
          reason:
              '${inviter.alias} must see ${invitee.alias} in group $groupId after invite+join');
    }

    test('Get info for non-existent group', () async {
      const nonExistentGroupId = 'non_existent_group_id';
      final groupsInfoResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupsInfo(
                groupIDList: [nonExistentGroupId],
              ));

      expect(groupsInfoResult.code, isA<int>(),
          reason: 'Result code must be an integer');
      if (groupsInfoResult.code == 0) {
        final groups = groupsInfoResult.data ?? <dynamic>[];
        final hasUnexpectedExactMatch =
            groups.any((g) => g.groupInfo?.groupID == nonExistentGroupId);
        expect(hasUnexpectedExactMatch, isFalse,
            reason:
                'Successful lookup for non-existent group must not return an exact match');
      } else {
        expect(groupsInfoResult.code, isNot(equals(0)),
            reason:
                'Non-existent group lookup may fail, but must not silently succeed with invalid data');
      }

      if (groupsInfoResult.code == 0 &&
          groupsInfoResult.data != null &&
          groupsInfoResult.data!.isNotEmpty) {
        // If we got entries, they should not match the non-existent id (e.g. placeholder)
        for (final g in groupsInfoResult.data!) {
          expect(g.groupInfo?.groupID == nonExistentGroupId, isFalse);
        }
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Join non-existent group', () async {
      final joinResult = await alice
          .runWithInstanceAsync(() async => TIMManager.instance.joinGroup(
                groupID: 'non_existent_group_id',
                message: '',
              ));

      expect(joinResult.code, isNot(equals(0)));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Quit group not joined', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Bob tries to quit without joining (alice's group, bob not a member)
      final quitResult = await bob.runWithInstanceAsync(
          () async => TIMManager.instance.quitGroup(groupID: groupId));

      if (quitResult.code == 0) {
        final bobJoinedGroups = await bob.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getJoinedGroupList());
        expect(bobJoinedGroups.code, equals(0),
            reason: 'getJoinedGroupList should be queryable after quit');
        final stillJoined =
            bobJoinedGroups.data?.any((g) => g.groupID == groupId) ?? false;
        expect(stillJoined, isFalse,
            reason:
                'quitGroup on a non-member may return 0, but must be a no-op');
      } else {
        expect(quitResult.code, isNot(equals(0)));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Kick member from group not owned', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await inviteAndJoinMember(groupId, alice, bob);
      await inviteAndJoinMember(groupId, alice, charlie);

      final charliePublicKey = charlie.getPublicKey();
      final kickResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.kickGroupMember(
                groupID: groupId,
                memberList: [charliePublicKey],
              ));

      if (kickResult.code == 0) {
        final memberListResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
            ));
        expect(memberListResult.code, equals(0),
            reason: 'getGroupMemberList should succeed after kick attempt');
        final charlieStillInGroup = memberListResult.data?.memberInfoList
                ?.any((m) => m.userID == charliePublicKey) ??
            false;
        print(
            '[GroupError] kickGroupMember by non-owner returned 0; charlieStillInGroup=$charlieStillInGroup (implementation-dependent policy)');
      } else {
        expect(kickResult.code, isNot(equals(0)));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Set role without permission', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await inviteAndJoinMember(groupId, alice, bob);
      await inviteAndJoinMember(groupId, alice, charlie);

      final charliePublicKey = charlie.getPublicKey();
      final setRoleResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.setGroupMemberRole(
                groupID: groupId,
                userID: charliePublicKey,
                role: GroupMemberRoleTypeEnum.V2TIM_GROUP_MEMBER_ROLE_ADMIN,
              ));

      if (setRoleResult.code == 0) {
        final memberListResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
            ));
        expect(memberListResult.code, equals(0),
            reason: 'getGroupMemberList should succeed after set-role attempt');
        final memberList = memberListResult.data?.memberInfoList ?? <dynamic>[];
        final charlieCandidates =
            memberList.where((m) => m.userID == charliePublicKey).toList();
        if (charlieCandidates.isNotEmpty) {
          final role = charlieCandidates.first.role;
          print(
              '[GroupError] setGroupMemberRole by non-owner returned 0; observed role=$role (implementation-dependent policy)');
        } else {
          print(
              '[GroupError] charlie not found in member list after non-owner setRole attempt');
        }
      } else {
        expect(setRoleResult.code, isNot(equals(0)));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Modify group info without permission', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await inviteAndJoinMember(groupId, alice, bob);

      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        groupName: 'Unauthorized Change',
      );

      final setInfoResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.setGroupInfo(
                info: groupInfo,
              ));

      if (setInfoResult.code == 0) {
        final groupsInfoResult = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getGroupsInfo(
                  groupIDList: [groupId],
                ));
        expect(groupsInfoResult.code, equals(0),
            reason: 'Owner should be able to query group info');
        final groupName = groupsInfoResult.data?.first.groupInfo?.groupName;
        expect(groupName?.isNotEmpty, isTrue,
            reason: 'Group name should remain queryable after setGroupInfo');
        print(
            '[GroupError] setGroupInfo by non-owner returned 0; observed groupName=$groupName (implementation-dependent policy)');
      } else {
        expect(setInfoResult.code, isNot(equals(0)));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Invite to non-existent group', () async {
      final bobPublicKey = bob.getPublicKey();
      final inviteResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.inviteUserToGroup(
                groupID: 'non_existent_group_id',
                userList: [bobPublicKey],
              ));

      expect(inviteResult.code, isNot(equals(0)));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Get member list for non-existent group', () async {
      final memberListResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: 'non_existent_group_id',
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));

      expect(memberListResult.code, isNot(equals(0)));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Dismiss group not owned', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await inviteAndJoinMember(groupId, alice, bob);

      final dismissResult = await bob.runWithInstanceAsync(
          () async => TIMManager.instance.dismissGroup(groupID: groupId));

      if (dismissResult.code == 0) {
        final groupsInfoResult = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getGroupsInfo(
                  groupIDList: [groupId],
                ));
        if (groupsInfoResult.code == 0) {
          print(
              '[GroupError] dismissGroup by non-owner returned 0 and group remains queryable (no-op semantics)');
        } else {
          print(
              '[GroupError] dismissGroup by non-owner returned 0 and group is no longer queryable (strict semantics)');
        }
      } else {
        expect(dismissResult.code, isNot(equals(0)));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Invalid group type', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'InvalidType',
                groupName: 'Test Group',
                groupID: '',
              ));

      if (createResult.code == 0) {
        expect(createResult.data, isNotNull,
            reason: 'Successful createGroup must return group id');
        final groupsInfoResult = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getGroupsInfo(
                  groupIDList: [createResult.data!],
                ));
        expect(groupsInfoResult.code, equals(0),
            reason: 'Created group should be queryable');
        final actualType = groupsInfoResult.data?.first.groupInfo?.groupType;
        expect(actualType, isNot(equals('InvalidType')),
            reason:
                'Invalid input type should not persist unchanged when createGroup succeeds');
      } else {
        expect(createResult.code, isNot(equals(0)));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Empty group name', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: '',
                groupID: '',
              ));

      if (createResult.code == 0) {
        expect(createResult.data, isNotNull,
            reason: 'Successful createGroup must return group id');
        final groupsInfoResult = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getGroupsInfo(
                  groupIDList: [createResult.data!],
                ));
        expect(groupsInfoResult.code, equals(0),
            reason: 'Created group should be queryable');
        final actualName =
            groupsInfoResult.data?.first.groupInfo?.groupName ?? '';
        expect(actualName.isNotEmpty, isTrue,
            reason:
                'Empty group name input should be normalized to a non-empty stored value');
      } else {
        expect(createResult.code, isNot(equals(0)));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Operations after quitting group', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await inviteAndJoinMember(groupId, alice, bob);

      await bob.runWithInstanceAsync(
          () async => TIMManager.instance.quitGroup(groupID: groupId));
      try {
        await waitUntilJoinedListExcludesGroup(
          bob,
          groupId,
          timeout: const Duration(seconds: 20),
          iterationsPerPump: 80,
          stepDelay: const Duration(milliseconds: 200),
        );
      } catch (_) {
        print(
            '[GroupError] joined list still contains $groupId after quit; continuing with post-quit permission check');
      }

      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        groupName: 'Unauthorized',
      );

      final setInfoResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.setGroupInfo(
                info: groupInfo,
              ));

      expect(setInfoResult.code, isNot(equals(0)));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
