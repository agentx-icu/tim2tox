/// Conference Invite Merge Test — virtual-clock variant
///
/// Mirrors scenario_conference_invite_merge_test.dart 1:1 but drives the
/// harness via the virtual-clock helpers (VirtualClock + pumpTestTick +
/// *Virtual helpers).

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Invite Merge Tests (Virtual)', () {
    late TestScenario scenario;

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(
          ['node0', 'node1', 'coordinator', 'node3', 'node4']);
      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      await Future.wait(scenario.nodes.map((node) => node.login()));

      await configureLocalBootstrapVirtual(scenario);

      await waitUntil(
        () => scenario.nodes.every((node) => node.loggedIn),
        timeout: const Duration(seconds: 15),
        description: 'all nodes logged in',
      );
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Conference invite and merge with 5 nodes', () async {
      final coordinator = scenario.getNode('coordinator')!;
      final node0 = scenario.getNode('node0')!;
      final node1 = scenario.getNode('node1')!;
      final node3 = scenario.getNode('node3')!;
      final node4 = scenario.getNode('node4')!;

      String? groupId;
      final createResult = await coordinator.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Merge Test Conference',
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed: ${createResult.code}');
      expect(createResult.data, isNotNull);
      groupId = createResult.data;

      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }

      await establishFriendshipVirtual(scenario, coordinator, node1,
          timeout: const Duration(seconds: 25));
      await establishFriendshipVirtual(scenario, node1, node0,
          timeout: const Duration(seconds: 25));
      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      final node1PublicKey = node1.getPublicKey();
      final inviteNode1Result = await coordinator.runWithInstanceAsync(
          () async => TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId!,
                userList: [node1PublicKey],
              ));
      expect(inviteNode1Result.code, equals(0),
          reason: 'inviteNode1 failed: ${inviteNode1Result.code}');
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }
      final join1 = await node1.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
      expect(join1.code, equals(0),
          reason: 'node1 joinGroup failed: ${join1.code}');

      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }

      final node0PublicKey = node0.getPublicKey();
      final inviteNode0Result = await node1.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId!,
            userList: [node0PublicKey],
          ));
      expect(inviteNode0Result.code, equals(0),
          reason: 'inviteNode0 failed: ${inviteNode0Result.code}');
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }
      final join0 = await node0.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
      expect(join0.code, equals(0),
          reason: 'node0 joinGroup failed: ${join0.code}');

      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      final memberListResult1 = await coordinator.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: groupId!,
                filter:
                    GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      expect(memberListResult1.code, equals(0),
          reason: 'getGroupMemberList failed: ${memberListResult1.code}');
      expect(memberListResult1.data, isNotNull);
      expect(memberListResult1.data!.memberInfoList?.length ?? 0,
          greaterThanOrEqualTo(2));

      await establishFriendshipVirtual(scenario, coordinator, node3,
          timeout: const Duration(seconds: 25));
      await establishFriendshipVirtual(scenario, node3, node4,
          timeout: const Duration(seconds: 25));
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }

      final node3PublicKey = node3.getPublicKey();
      final inviteNode3Result = await coordinator.runWithInstanceAsync(
          () async => TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId!,
                userList: [node3PublicKey],
              ));
      expect(inviteNode3Result.code, equals(0),
          reason: 'inviteNode3 failed: ${inviteNode3Result.code}');
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }
      final join3 = await node3.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
      expect(join3.code, equals(0),
          reason: 'node3 joinGroup failed: ${join3.code}');

      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }

      final node4PublicKey = node4.getPublicKey();
      final inviteNode4Result = await node3.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId!,
            userList: [node4PublicKey],
          ));
      expect(inviteNode4Result.code, equals(0),
          reason: 'inviteNode4 failed: ${inviteNode4Result.code}');
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }
      final join4 = await node4.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
      expect(join4.code, equals(0),
          reason: 'node4 joinGroup failed: ${join4.code}');

      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      final memberListResult2 = await coordinator.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getGroupMemberList(
                groupID: groupId!,
                filter:
                    GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
                nextSeq: '0',
              ));
      expect(memberListResult2.code, equals(0),
          reason: 'getGroupMemberList failed: ${memberListResult2.code}');
      expect(memberListResult2.data, isNotNull);

      final memberCount = memberListResult2.data!.memberInfoList?.length ?? 0;
      expect(memberCount, greaterThanOrEqualTo(1));

      print('Conference merge test completed. Member count: $memberCount');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
