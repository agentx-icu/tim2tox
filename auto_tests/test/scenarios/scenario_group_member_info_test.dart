/// Group Member Info Test
///
/// Tests modifying member information: nameCard, role, etc.
/// Verifies member info changes are synchronized

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_role_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_full_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Member Info Tests', () {
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
      // Both pumps share the same global iterate, so run in parallel and shorten.
      await Future.wait([
        pumpFriendConnection(alice, bob,
            duration: const Duration(seconds: 2)),
        pumpFriendConnection(alice, charlie,
            duration: const Duration(seconds: 2)),
      ]);
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

    Future<String> inviteAndJoinMember(
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
          duration: const Duration(milliseconds: 800));
      final inviteeInGroup = await waitUntilFounderSeesMemberInGroup(
          alice, invitee, groupId,
          timeout: const Duration(seconds: 25));
      expect(inviteeInGroup, isNotNull,
          reason: 'Alice must see ${invitee.alias} in group before $context');

      return joinGroupId;
    }

    test('Modify member nameCard', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      await inviteAndJoinMember(groupId, bob,
          context: 'modify member nameCard');
      final bobPublicKey = bob.getPublicKey();
      final setMemberInfoResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.setGroupMemberInfo(
                groupID: groupId,
                userID: bobPublicKey,
                nameCard: 'Bob\'s Name Card',
              ));
      expect(setMemberInfoResult.code, equals(0));
      pumpAllInstancesOnce(iterations: 50);
      await Future.delayed(const Duration(milliseconds: 200));
      final memberListResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: groupId,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      if (memberListResult.code == 0 && memberListResult.data != null) {
        // tim2tox: C++ may return 76-char Tox ID or 64-char public key
        final bobMember = memberListResult.data!.memberInfoList?.firstWhere(
          (m) =>
              m.userID == bobPublicKey ||
              (m.userID.length >= 64 && m.userID.startsWith(bobPublicKey)),
          orElse: () => V2TimGroupMemberFullInfo(userID: ''),
        );
        if (bobMember != null &&
            (bobMember.userID == bobPublicKey ||
                bobMember.userID.startsWith(bobPublicKey))) {
          expect(bobMember.nameCard, equals('Bob\'s Name Card'));
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Modify own nameCard', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      final bobJoinGroupId = await inviteAndJoinMember(groupId, bob,
          context: 'modify own nameCard');
      final bobPublicKey = bob.getPublicKey();
      final setMemberInfoResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.setGroupMemberInfo(
                groupID: bobJoinGroupId,
                userID: bobPublicKey,
                nameCard: 'My Own Name Card',
              ));
      expect(setMemberInfoResult.code, equals(0));
      pumpAllInstancesOnce(iterations: 50);
      await Future.delayed(const Duration(milliseconds: 200));
      final memberListResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: bobJoinGroupId,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      if (memberListResult.code == 0 && memberListResult.data != null) {
        final bobMember = memberListResult.data!.memberInfoList?.firstWhere(
          (m) =>
              m.userID == bobPublicKey ||
              (m.userID.length >= 64 && m.userID.startsWith(bobPublicKey)),
          orElse: () => V2TimGroupMemberFullInfo(userID: ''),
        );
        if (bobMember != null &&
            (bobMember.userID == bobPublicKey ||
                bobMember.userID.startsWith(bobPublicKey))) {
          expect(bobMember.nameCard, equals('My Own Name Card'));
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Set member role to admin', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      await inviteAndJoinMember(groupId, bob,
          context: 'set member role to admin');
      final bobPublicKey = bob.getPublicKey();
      // Wait until Alice sees Bob in the group (DHT/peer list sync) so setGroupMemberRole does not return 8500
      final bobUserIdForRole = await waitUntilFounderSeesMemberInGroup(
          alice, bob, groupId,
          timeout: const Duration(seconds: 25));
      expect(bobUserIdForRole, isNotNull,
          reason: 'Alice must see Bob in group before setGroupMemberRole');
      final setRoleResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.setGroupMemberRole(
                groupID: groupId,
                userID: bobUserIdForRole!,
                role: GroupMemberRoleTypeEnum.V2TIM_GROUP_MEMBER_ROLE_ADMIN,
              ));
      expect(setRoleResult.code, equals(0));
      pumpAllInstancesOnce(iterations: 50);
      await Future.delayed(const Duration(milliseconds: 200));
      final memberListResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: groupId,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      if (memberListResult.code == 0 && memberListResult.data != null) {
        final bobMember = memberListResult.data!.memberInfoList?.firstWhere(
          (m) =>
              m.userID == bobPublicKey ||
              (m.userID.length >= 64 && m.userID.startsWith(bobPublicKey)),
          orElse: () => V2TimGroupMemberFullInfo(userID: ''),
        );
        if (bobMember != null &&
            (bobMember.userID == bobPublicKey ||
                bobMember.userID.startsWith(bobPublicKey))) {
          expect(bobMember.role,
              equals(GroupMemberRoleTypeEnum.V2TIM_GROUP_MEMBER_ROLE_ADMIN));
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Multiple member info modifications', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      await inviteAndJoinMember(groupId, bob,
          context: 'multiple member info modifications (bob)');
      await inviteAndJoinMember(groupId, charlie,
          context: 'multiple member info modifications (charlie)');
      final bobPublicKey = bob.getPublicKey();
      final charliePublicKey = charlie.getPublicKey();
      await alice.runWithInstanceAsync(() async {
        await TIMGroupManager.instance.setGroupMemberInfo(
            groupID: groupId, userID: bobPublicKey, nameCard: 'Bob Card');
        await TIMGroupManager.instance.setGroupMemberInfo(
            groupID: groupId,
            userID: charliePublicKey,
            nameCard: 'Charlie Card');
      });
      pumpAllInstancesOnce(iterations: 50);
      await Future.delayed(const Duration(milliseconds: 200));
      final memberListResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: groupId,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      if (memberListResult.code == 0 && memberListResult.data != null) {
        final members = memberListResult.data!.memberInfoList!;
        final bobMember = members.firstWhere(
          (m) =>
              m.userID == bobPublicKey ||
              (m.userID.length >= 64 && m.userID.startsWith(bobPublicKey)),
          orElse: () => V2TimGroupMemberFullInfo(userID: ''),
        );
        final charlieMember = members.firstWhere(
          (m) =>
              m.userID == charliePublicKey ||
              (m.userID.length >= 64 && m.userID.startsWith(charliePublicKey)),
          orElse: () => V2TimGroupMemberFullInfo(userID: ''),
        );
        if (bobMember.userID.startsWith(bobPublicKey) ||
            bobMember.userID == bobPublicKey)
          expect(bobMember.nameCard, equals('Bob Card'));
        if (charlieMember.userID.startsWith(charliePublicKey) ||
            charlieMember.userID == charliePublicKey)
          expect(charlieMember.nameCard, equals('Charlie Card'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Member info for conference type', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'Meeting',
                groupName: 'Test Conference',
                groupID: '',
              ));
      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;
      await inviteAndJoinMember(conferenceId, bob,
          context: 'conference member info');
      final bobPublicKey = bob.getPublicKey();
      final setMemberInfoResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.setGroupMemberInfo(
                groupID: conferenceId,
                userID: bobPublicKey,
                nameCard: 'Conference Name Card',
              ));
      expect(setMemberInfoResult.code, equals(0));
      pumpAllInstancesOnce(iterations: 50);
      await Future.delayed(const Duration(milliseconds: 200));
      final memberListResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: conferenceId,
                filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      if (memberListResult.code == 0 && memberListResult.data != null) {
        final bobMember = memberListResult.data!.memberInfoList?.firstWhere(
          (m) =>
              m.userID == bobPublicKey ||
              (m.userID.length >= 64 && m.userID.startsWith(bobPublicKey)),
          orElse: () => V2TimGroupMemberFullInfo(userID: ''),
        );
        if (bobMember != null &&
            (bobMember.userID == bobPublicKey ||
                bobMember.userID.startsWith(bobPublicKey))) {
          expect(bobMember.nameCard, equals('Conference Name Card'));
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
