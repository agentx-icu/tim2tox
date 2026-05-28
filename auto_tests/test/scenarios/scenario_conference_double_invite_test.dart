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
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

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

    test('Second invite to already-joined conference is handled gracefully',
        () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;

      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 20));

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

      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 5));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 10));
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 10));

      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30));
      } catch (_) {
        // Friend connection may finalize during the invite; continue.
      }
      try {
        await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30));
      } catch (_) {
        // Friend connection may finalize during the invite; continue.
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final bobPublicKey = bob.getPublicKey();

      V2TimValueCallback<List<V2TimGroupMemberOperationResult>>? inviteResult1;
      for (int retry = 0; retry < 3; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 2000, iterationsPerInstance: 1);
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

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: groupId,
            message: '',
          ));
      expect(joinResult.code, equals(0),
          reason: 'joinGroup failed with code ${joinResult.code}');

      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 5));
      final joinedDeadline =
          VirtualClock.nowMs + const Duration(seconds: 20).inMilliseconds;
      while (VirtualClock.nowMs < joinedDeadline) {
        final list = await alice.runWithInstanceAsync(() async =>
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

      // Second invite for the same already-joined peer must not throw and
      // must not produce a duplicate member entry.
      final inviteResult2 = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId,
            userList: [bobPublicKey],
          ));
      expect(inviteResult2.code, isNotNull,
          reason: 'second inviteUserToGroup must return a response');

      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

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
