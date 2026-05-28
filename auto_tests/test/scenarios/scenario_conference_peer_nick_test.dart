/// Conference Peer Nick Test — virtual-clock variant
///
/// Mirrors scenario_conference_peer_nick_test.dart 1:1 but drives the
/// harness via the virtual-clock helpers (VirtualClock + pumpTestTick +
/// *Virtual helpers).

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_full_info.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Peer Nick Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

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
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Conference peer nickname changes', () async {
      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 20));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 10));
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 10));
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bob.getToxId(),
            timeout: const Duration(seconds: 30));
      } catch (e) {
        print(
            '[ConferencePeerNick] Friend connection check not fully ready, continue with retry logic: $e');
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      String? groupId;
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Peer Nick Test Conference',
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed: ${createResult.code}');
      expect(createResult.data, isNotNull);
      groupId = createResult.data;
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final bobPublicKey = bob.getPublicKey();
      for (int retry = 0; retry < 5; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 3000, iterationsPerInstance: 1);
        }
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId!,
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

      var arrived = false;
      for (var attempt = 0; !arrived && attempt < 3; attempt++) {
        if (attempt > 0) {
          await alice.runWithInstanceAsync(() async =>
              TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId!,
                userList: [bobPublicKey],
              ));
        }
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'Bob onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          arrived = true;
        } catch (_) {}
      }
      expect(arrived, isTrue,
          reason: 'Bob never received onGroupInvited after 3 retries');

      final aliceUserInfo = V2TimUserFullInfo();
      aliceUserInfo.nickName = 'Alice';
      final setAliceNameResult = await alice.runWithInstanceAsync(() async =>
          TIMManager.instance.setSelfInfo(
            userFullInfo: aliceUserInfo,
          ));
      expect(setAliceNameResult.code, equals(0),
          reason: 'setSelfInfo failed: ${setAliceNameResult.code}');

      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: groupId!,
            message: '',
          ));
      expect(joinResult.code, equals(0),
          reason: 'joinGroup failed: ${joinResult.code}');

      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 6));

      final bobSeenByAlice = await waitUntilFounderSeesMemberInGroupVirtual(
          scenario, alice, bob, groupId!,
          timeout: const Duration(seconds: 45));
      expect(bobSeenByAlice, isNotNull,
          reason:
              'Alice did not see Bob in group within timeout (setGroupMemberInfo would return 8500)');

      final bobUserInfo = V2TimUserFullInfo();
      bobUserInfo.nickName = 'Bob';
      final setBobNameResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.setSelfInfo(
            userFullInfo: bobUserInfo,
          ));
      expect(setBobNameResult.code, equals(0),
          reason: 'setSelfInfo failed: ${setBobNameResult.code}');

      await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 1);

      final memberListResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId!,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(memberListResult.code, equals(0),
          reason: 'getGroupMemberList failed: ${memberListResult.code}');
      expect(memberListResult.data?.memberInfoList?.length ?? 0,
          greaterThanOrEqualTo(2),
          reason: 'Alice must see at least 2 members');

      bool memberMatchesBob(String uid) =>
          uid == bobPublicKey || (uid.length >= 64 && uid.startsWith(bobPublicKey));
      final bobCandidates = memberListResult.data?.memberInfoList
              ?.where((m) => memberMatchesBob(m.userID))
              .toList() ??
          [];
      final bobUserIdForApi =
          bobCandidates.isNotEmpty ? bobCandidates.first.userID : bobSeenByAlice!;
      expect(bobUserIdForApi.isNotEmpty, isTrue,
          reason:
              'Must have a non-founder userID (Bob) for setGroupMemberInfo');

      final setBobNameCardResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.setGroupMemberInfo(
            groupID: groupId!,
            userID: bobUserIdForApi,
            nameCard: 'Bob Updated',
          ));
      expect(setBobNameCardResult.code, equals(0),
          reason: 'setGroupMemberInfo failed: ${setBobNameCardResult.code}');

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final memberInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMembersInfo(
            groupID: groupId!,
            memberList: [bobUserIdForApi],
          ));
      expect(memberInfoResult.code, equals(0),
          reason: 'getGroupMembersInfo failed: ${memberInfoResult.code}');
      expect(memberInfoResult.data, isNotNull);

      if (memberInfoResult.data != null && memberInfoResult.data!.isNotEmpty) {
        final bobInfo = memberInfoResult.data!.first;
        print('Bob nameCard: ${bobInfo.nameCard}');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
