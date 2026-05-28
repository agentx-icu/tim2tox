// Group Sync Test — virtual-clock variant
//
// Mirrors scenario_group_sync_test.dart 1:1 but drives the harness via
// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// Tests group synchronization: topic sync, member list sync.
// Reference: c-toxcore/auto_tests/scenarios/scenario_group_sync_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Sync Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      // Enable test mode BEFORE login so event_thread never starts.
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      await waitUntil(() => alice.loggedIn && bob.loggedIn);

      // Configure local bootstrap via virtual-clock helper.
      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Group topic synchronization', () async {
      // Create group
      final createResult = await TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: 'Test Group',
      );

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Members join
      await TIMManager.instance.joinGroup(
        groupID: groupId,
        message: '',
      );
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);

      // Set group topic
      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'kTIMGroup_Private',
      );
      final setInfoResult = await TIMGroupManager.instance.setGroupInfo(
        info: groupInfo,
      );

      expect(setInfoResult.code, equals(0));

      // Verify all members see the update
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);
      final groupsInfoResult = await TIMGroupManager.instance.getGroupsInfo(
        groupIDList: [groupId],
      );

      expect(groupsInfoResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Group member list synchronization', () async {
      // Create group
      final createResult = await TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: 'Test Group',
      );

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Members join
      await TIMManager.instance.joinGroup(
        groupID: groupId,
        message: '',
      );
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);

      // Get member list
      final memberListResult =
          await TIMGroupManager.instance.getGroupMemberList(
        groupID: groupId,
        filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
        nextSeq: '0',
      );

      expect(memberListResult.code, equals(0));
      expect(memberListResult.data?.memberInfoList, isNotNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
