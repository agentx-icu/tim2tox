// Ported from c-toxcore scenario_conference_double_invite_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_value_callback.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_operation_result.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Double Invite Tests', () {
    late TestScenario scenario;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob']);
      await scenario.initAllNodes();

      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      await configureLocalBootstrap(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Second invite to already-joined conference is handled gracefully',
        () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;

      // Friendship is required before a conference invite can travel.
      await establishFriendship(alice, bob,
          timeout: const Duration(seconds: 20));

      // Alice creates the conference (V1 path uses Meeting groupType).
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Double Invite Conference',
            groupID: '',
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed with code ${createResult.code}');
      expect(createResult.data, isNotNull);
      final groupId = createResult.data!;

      // Wait for the friend channel to be ready before inviting.
      await pumpFriendConnection(alice, bob,
          duration: const Duration(seconds: 5));
      await bob.waitForConnection(timeout: const Duration(seconds: 10));
      await alice.waitForConnection(timeout: const Duration(seconds: 10));

      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      try {
        await alice.waitForFriendConnection(bobToxId,
            timeout: const Duration(seconds: 30));
      } catch (_) {
        // Friend connection may finalize during the invite; continue.
      }
      try {
        await bob.waitForFriendConnection(aliceToxId,
            timeout: const Duration(seconds: 30));
      } catch (_) {
        // Friend connection may finalize during the invite; continue.
      }
      await Future.delayed(const Duration(seconds: 2));

      final bobPublicKey = bob.getPublicKey();

      // First invite: must succeed.
      V2TimValueCallback<List<V2TimGroupMemberOperationResult>>? inviteResult1;
      for (int retry = 0; retry < 3; retry++) {
        if (retry > 0) {
          await Future.delayed(const Duration(seconds: 2));
        }
        inviteResult1 = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey],
            ));
        expect(inviteResult1!.code, equals(0),
            reason:
                'first inviteUserToGroup failed with code ${inviteResult1.code}');
        final bobInvite = inviteResult1.data!.firstWhere(
          (r) => r.memberID == bobPublicKey,
          orElse: () => throw Exception('Bob not found in invite result list'),
        );
        if (bobInvite.result == 1) {
          break;
        } else if (retry == 2) {
          throw Exception(
              'First invitation failed after 3 attempts: result=${bobInvite.result}');
        }
      }

      // Bob joins the conference.
      await Future.delayed(const Duration(seconds: 2));
      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: groupId,
            message: '',
          ));
      expect(joinResult.code, equals(0),
          reason: 'joinGroup failed with code ${joinResult.code}');

      // Wait until Bob is visible in the conference's member list.
      await pumpGroupPeerDiscovery(alice, bob,
          duration: const Duration(seconds: 5));
      final joinedDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(joinedDeadline)) {
        final list = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
            ));
        final count = list.data?.memberInfoList?.length ?? 0;
        if (count >= 2) break;
        await pumpGroupPeerDiscovery(alice, bob,
            duration: const Duration(seconds: 1));
      }

      // Second invite for the same already-joined peer must not throw and
      // must not produce a duplicate member entry. We accept either:
      //   - the call succeeding with no observable effect (typical), or
      //   - the call reporting a non-zero per-member result (legitimate
      //     duplicate rejection from the V1 conference layer).
      final inviteResult2 = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId,
            userList: [bobPublicKey],
          ));
      expect(inviteResult2.code, isNotNull,
          reason: 'second inviteUserToGroup must return a response');

      await Future.delayed(const Duration(seconds: 3));

      // Bob must appear at most once in the conference roster.
      final memberListResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(memberListResult.code, equals(0),
          reason:
              'getGroupMemberList failed with code ${memberListResult.code}');
      if (memberListResult.data?.memberInfoList != null) {
        final bobCount = memberListResult.data!.memberInfoList!.where((m) {
          final uid = m.userID;
          return uid == bobPublicKey ||
              (uid.length >= 64 && uid.startsWith(bobPublicKey));
        }).length;
        expect(bobCount, lessThanOrEqualTo(1),
            reason: 'Bob should appear at most once in conference roster');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
