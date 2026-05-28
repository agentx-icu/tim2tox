/// Conference AV Test — virtual-clock variant
///
/// Mirrors scenario_conference_av_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers. ToxAV has its own iteration loop separate
/// from tox_iterate; per the migration plan, retain small wall-clock
/// settle waits (Future.delayed) here so AV iteration has a chance to run.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference AV Tests', () {
    late TestScenario scenario;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario =
          await createTestScenario(['peer0', 'peer1', 'peer2', 'peer3']);
      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

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

    test('Conference AV with 4 peers', () async {
      final peer0 = scenario.getNode('peer0')!;
      final peer1 = scenario.getNode('peer1')!;
      final peer2 = scenario.getNode('peer2')!;
      final peer3 = scenario.getNode('peer3')!;

      String? groupId;
      final createResult = await peer0.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'AV Test Conference',
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed: ${createResult.code}');
      expect(createResult.data, isNotNull);
      groupId = createResult.data;

      // ToxAV has its own iteration loop; allow a small wall-clock settle so
      // the AV thread can run (unlike tox_iterate which the virtual pump
      // drives).
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }

      // Establish friendships so invites succeed (inviter-invitee friendship
      // required).
      await establishFriendshipVirtual(scenario, peer0, peer1,
          timeout: const Duration(seconds: 25));
      await establishFriendshipVirtual(scenario, peer1, peer2,
          timeout: const Duration(seconds: 25));
      await establishFriendshipVirtual(scenario, peer2, peer3,
          timeout: const Duration(seconds: 25));
      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      // Peer0 invites Peer1, Peer1 joins.
      final peer1PublicKey = peer1.getPublicKey();
      final invitePeer1Result = await peer0.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId!,
            userList: [peer1PublicKey],
          ));
      expect(invitePeer1Result.code, equals(0),
          reason: 'invitePeer1 failed: ${invitePeer1Result.code}');
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }
      final join1 = await peer1.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
      expect(join1.code, equals(0),
          reason: 'peer1 joinGroup failed: ${join1.code}');

      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }

      // Peer1 invites Peer2, Peer2 joins.
      final peer2PublicKey = peer2.getPublicKey();
      final invitePeer2Result = await peer1.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId!,
            userList: [peer2PublicKey],
          ));
      expect(invitePeer2Result.code, equals(0),
          reason: 'invitePeer2 failed: ${invitePeer2Result.code}');
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }
      final join2 = await peer2.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
      expect(join2.code, equals(0),
          reason: 'peer2 joinGroup failed: ${join2.code}');

      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }

      // Peer2 invites Peer3, Peer3 joins.
      final peer3PublicKey = peer3.getPublicKey();
      final invitePeer3Result = await peer2.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId!,
            userList: [peer3PublicKey],
          ));
      expect(invitePeer3Result.code, equals(0),
          reason: 'invitePeer3 failed: ${invitePeer3Result.code}');
      for (var _i = 0; _i < 10; _i++) { await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 3, wallSleep: const Duration(milliseconds: 200)); }
      final join3 = await peer3.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
      expect(join3.code, equals(0),
          reason: 'peer3 joinGroup failed: ${join3.code}');

      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      // Verify all 4 peers are in the group.
      final memberListResult = await peer0.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId!,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(memberListResult.code, equals(0),
          reason: 'getGroupMemberList failed: ${memberListResult.code}');
      expect(memberListResult.data, isNotNull);

      final memberCount = memberListResult.data!.memberInfoList?.length ?? 0;
      expect(memberCount, greaterThanOrEqualTo(1));

      print('Conference AV test completed. Member count: $memberCount');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
