/// Conference Query Test — virtual-clock variant
///
/// Mirrors scenario_conference_query_test.dart 1:1 but drives the harness
/// via the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual
/// helpers).

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Query Tests (Virtual)', () {
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

    test('Conference query operations', () async {
      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 20));

      String groupId;
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Query Test Conference',
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed: ${createResult.code}');
      expect(createResult.data, isNotNull);
      groupId = createResult.data!;

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

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

      for (int retry = 0; retry < 3; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 2000, iterationsPerInstance: 1);
        }
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey],
            ));
        expect(inviteResult.code, equals(0));
        expect(inviteResult.data, isNotNull);
        expect(inviteResult.data!.isNotEmpty, isTrue);
        final bobInviteResult = inviteResult.data!.firstWhere(
            (r) => r.memberID == bobPublicKey,
            orElse: () =>
                throw Exception('Bob not found in invite result list'));
        if (bobInviteResult.result == 1) break;
        if (retry == 2) {
          expect(bobInviteResult.result, equals(1),
              reason:
                  'Bob invitation failed after 3 attempts: result=${bobInviteResult.result}');
        }
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(joinResult.code, equals(0),
          reason: 'joinGroup failed: ${joinResult.code}');

      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      // Wait for DHT synchronization so both peers see each other.
      bool bothPeersVisible = false;
      final syncDeadline =
          VirtualClock.nowMs + const Duration(seconds: 15).inMilliseconds;
      while (VirtualClock.nowMs < syncDeadline && !bothPeersVisible) {
        final syncCheck = await bob.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
            ));
        if (syncCheck.code == 0 && syncCheck.data != null) {
          final cnt = syncCheck.data!.memberInfoList?.length ?? 0;
          if (cnt >= 2) {
            bothPeersVisible = true;
            break;
          }
        }
        final aliceCheck = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
            ));
        if (aliceCheck.code == 0 && aliceCheck.data != null) {
          final cnt = aliceCheck.data!.memberInfoList?.length ?? 0;
          if (cnt >= 2) {
            bothPeersVisible = true;
            break;
          }
        }
        await pumpTestTick(scenario,
            advanceMs: 200, iterationsPerInstance: 1);
      }

      final memberListResult = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(memberListResult.code, equals(0),
          reason: 'getGroupMemberList failed: ${memberListResult.code}');
      expect(memberListResult.data, isNotNull);
      expect(memberListResult.data!.memberInfoList?.length ?? 0,
          greaterThanOrEqualTo(1));

      final alicePublicKey = alice.getPublicKey();
      bool memberMatches(String uid, String publicKey) {
        final u = uid.toLowerCase();
        final p = publicKey.toLowerCase();
        return u == p ||
            (u.length >= 64 && u.startsWith(p)) ||
            (p.length >= 64 && p.startsWith(u));
      }

      final memberListForRef = memberListResult.data!.memberInfoList!;
      var aliceUserIDFromList = memberListForRef
          .where((m) => memberMatches(m.userID, alicePublicKey))
          .map((m) => m.userID)
          .firstOrNull;
      var bobUserIDFromList = memberListForRef
          .where((m) => memberMatches(m.userID, bobPublicKey))
          .map((m) => m.userID)
          .firstOrNull;
      if (memberListForRef.length >= 2) {
        if (aliceUserIDFromList == null) {
          final notBob = memberListForRef
              .where((m) => !memberMatches(m.userID, bobPublicKey))
              .map((m) => m.userID)
              .firstOrNull;
          if (notBob != null) aliceUserIDFromList = notBob;
        }
        if (bobUserIDFromList == null) {
          final notAlice = memberListForRef
              .where((m) => !memberMatches(m.userID, alicePublicKey))
              .map((m) => m.userID)
              .firstOrNull;
          if (notAlice != null) bobUserIDFromList = notAlice;
        }
      }
      expect(memberListForRef.length, greaterThanOrEqualTo(2),
          reason: 'getGroupMemberList should have at least 2 members');
      expect(aliceUserIDFromList, isNotNull,
          reason: 'could not identify Alice in member list');
      expect(bobUserIDFromList, isNotNull,
          reason: 'could not identify Bob in member list');

      final aliceMemberInfoResult = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMembersInfo(
            groupID: groupId,
            memberList: [alicePublicKey],
          ));
      expect(aliceMemberInfoResult.code, equals(0),
          reason:
              'getGroupMembersInfo failed: ${aliceMemberInfoResult.code}');
      expect(aliceMemberInfoResult.data, isNotNull);
      expect(aliceMemberInfoResult.data!.isNotEmpty, isTrue);

      final bobMemberInfoResult = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMembersInfo(
            groupID: groupId,
            memberList: [bobPublicKey],
          ));
      expect(bobMemberInfoResult.code, equals(0),
          reason: 'getGroupMembersInfo failed: ${bobMemberInfoResult.code}');
      expect(bobMemberInfoResult.data, isNotNull);
      expect(bobMemberInfoResult.data!.isNotEmpty, isTrue);

      final groupInfoResult = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(
            groupIDList: [groupId],
          ));
      expect(groupInfoResult.code, equals(0),
          reason: 'getGroupsInfo failed: ${groupInfoResult.code}');
      expect(groupInfoResult.data, isNotNull);
      expect(groupInfoResult.data!.isNotEmpty, isTrue);

      final groupInfoResultItem = groupInfoResult.data!.first;
      expect(groupInfoResultItem.groupInfo, isNotNull);
      final groupInfo = groupInfoResultItem.groupInfo!;
      expect(groupInfo.groupID, equals(groupId));
      expect(groupInfo.groupType, equals('Meeting'));

      final aliceInfo = aliceMemberInfoResult.data!.firstWhere(
        (m) =>
            memberMatches(m.userID, alicePublicKey) ||
            (aliceUserIDFromList != null &&
                m.userID.toLowerCase() == aliceUserIDFromList.toLowerCase()),
        orElse: () => throw Exception(
            'getGroupMembersInfo did not return a member matching alicePublicKey'),
      );
      final bobInfo = bobMemberInfoResult.data!.firstWhere(
        (m) =>
            memberMatches(m.userID, bobPublicKey) ||
            (bobUserIDFromList != null &&
                m.userID.toLowerCase() == bobUserIDFromList.toLowerCase()),
        orElse: () => throw Exception(
            'getGroupMembersInfo did not return a member matching bobPublicKey'),
      );

      expect(
          memberMatches(aliceInfo.userID, alicePublicKey) ||
              (aliceUserIDFromList != null &&
                  aliceInfo.userID.toLowerCase() ==
                      aliceUserIDFromList.toLowerCase()),
          isTrue,
          reason: 'aliceInfo.userID=${aliceInfo.userID}');
      expect(
          memberMatches(bobInfo.userID, bobPublicKey) ||
              (bobUserIDFromList != null &&
                  bobInfo.userID.toLowerCase() ==
                      bobUserIDFromList.toLowerCase()),
          isTrue,
          reason: 'bobInfo.userID=${bobInfo.userID}');

      print('Conference query test completed successfully');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
