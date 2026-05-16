/// Conference Offline Test — virtual-clock variant
///
/// Mirrors scenario_conference_offline_test.dart 1:1 but drives the harness
/// via the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual
/// helpers).

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Offline Tests (Group Offline Members) (Virtual)', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        bob.login(),
      ]);
      await waitUntil(() => alice.loggedIn && bob.loggedIn);

      await configureLocalBootstrapVirtual(scenario);

      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 25));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 10));
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 10));
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bob.getToxId(),
            timeout: const Duration(seconds: 30));
        await waitForFriendConnectionVirtual(scenario, bob, alice.getToxId(),
            timeout: const Duration(seconds: 30));
      } catch (e) {
        print(
            '[ConferenceOffline] Friend connection check not fully ready, continue with retry logic: $e');
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Group offline member handling after reload', () async {
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Offline Test Conference',
            groupID: '',
          ));
      expect(createResult.code, equals(0));
      expect(createResult.data, isNotNull);
      final groupId = createResult.data!;

      var bobInvited = false;
      var bobJoined = false;
      final bobGroupListener = V2TimGroupListener(
        onMemberEnter: (groupID, memberList) {
          if (groupID == groupId) bobJoined = true;
        },
        onMemberInvited: (groupID, opUser, memberList) {
          bobInvited = true;
        },
      );

      bob.runWithInstance(
          () => TIMGroupManager.instance.addGroupListener(bobGroupListener));

      final bobPublicKey = bob.getPublicKey();
      for (int retry = 0; retry < 5; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 3000, iterationsPerInstance: 1);
        }
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey],
            ));
        expect(inviteResult.code, equals(0));
        final bobRes =
            inviteResult.data?.where((r) => r.memberID == bobPublicKey).toList();
        if (bobRes != null && bobRes.isNotEmpty && bobRes.first.result == 1) {
          break;
        }
        if (retry == 4) {
          expect(bobRes?.first.result ?? 0, equals(1),
              reason: 'Bob invite failed after 5 attempts');
        }
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 6));

      // Retry pattern for onMemberInvited.
      var arrived = false;
      for (var attempt = 0; !arrived && attempt < 3; attempt++) {
        if (attempt > 0) {
          await alice.runWithInstanceAsync(() async =>
              TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId,
                userList: [bobPublicKey],
              ));
        }
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bobInvited,
            timeout: const Duration(seconds: 30),
            description:
                'Bob received group invite (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          arrived = true;
        } catch (_) {}
      }
      expect(arrived, isTrue,
          reason: 'Bob never received group invite after 3 retries');

      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(joinResult.code, equals(0));

      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 6));

      await waitUntilWithVirtualPump(
        scenario,
        () => bobJoined,
        timeout: const Duration(seconds: 45),
        description: 'Bob joined group (onMemberEnter)',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      final aliceMembersResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(aliceMembersResult.code, equals(0));
      expect(aliceMembersResult.data?.memberInfoList, isNotNull);
      expect(aliceMembersResult.data!.memberInfoList!.length,
          greaterThanOrEqualTo(2));

      // Simulate reload: Alice logs out and logs back in.
      await alice.logout();
      await alice.login();

      await waitUntil(() => alice.loggedIn,
          timeout: const Duration(seconds: 30));

      final afterReloadMembersResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: groupId,
                filter:
                    GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      expect(afterReloadMembersResult.code, equals(0));
      expect(afterReloadMembersResult.data?.memberInfoList, isNotNull);

      final memberCount =
          afterReloadMembersResult.data!.memberInfoList!.length;
      expect(memberCount, greaterThanOrEqualTo(1));

      bob.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: bobGroupListener));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Group member list includes offline members', () async {
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Offline Member Test',
            groupID: '',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      final bobPublicKey = bob.getPublicKey();
      for (int retry = 0; retry < 5; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 3000, iterationsPerInstance: 1);
        }
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey],
            ));
        expect(inviteResult.code, equals(0));
        final bobRes =
            inviteResult.data?.where((r) => r.memberID == bobPublicKey).toList();
        if (bobRes != null && bobRes.isNotEmpty && bobRes.first.result == 1) {
          break;
        }
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(joinResult.code, equals(0));

      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 6));
      final bobSeenByAlice = await waitUntilFounderSeesMemberInGroupVirtual(
          scenario, alice, bob, groupId,
          timeout: const Duration(seconds: 45));
      expect(bobSeenByAlice, isNotNull,
          reason:
              'Alice must see Bob in group before asserting member list');

      final membersResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(membersResult.code, equals(0));
      expect(membersResult.data?.memberInfoList, isNotNull);

      final memberList = membersResult.data!.memberInfoList!;
      expect(memberList.length, greaterThanOrEqualTo(2));

      final alicePublicKey = alice.getPublicKey();
      final bobPublicKeyForCompare = bob.getPublicKey();

      bool memberMatches(String uid, String publicKey) =>
          uid == publicKey || (uid.length >= 64 && uid.startsWith(publicKey));
      final aliceMember = memberList.firstWhere(
        (m) => memberMatches(m.userID, alicePublicKey),
        orElse: () => throw Exception('Alice not found in member list'),
      );
      final bobMember = memberList.firstWhere(
        (m) =>
            memberMatches(m.userID, bobPublicKeyForCompare) ||
            (bobSeenByAlice != null && m.userID == bobSeenByAlice),
        orElse: () => throw Exception('Bob not found in member list'),
      );
      expect(memberMatches(aliceMember.userID, alicePublicKey), isTrue);
      expect(
          memberMatches(bobMember.userID, bobPublicKeyForCompare) ||
              bobMember.userID == bobSeenByAlice,
          isTrue);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
