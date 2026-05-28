// Group State Test — virtual-clock variant
//
// Mirrors scenario_group_state_test.dart 1:1 but drives the harness via
// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// Tests group state changes and synchronization.
// Reference: c-toxcore/auto_tests/scenarios/scenario_group_state_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group State Tests', () {
    late TestScenario scenario;
    late TestNode founder;
    late TestNode member1;
    late TestNode member2;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['founder', 'member1', 'member2']);
      founder = scenario.getNode('founder')!;
      member1 = scenario.getNode('member1')!;
      member2 = scenario.getNode('member2')!;

      await scenario.initAllNodes();
      // Enable test mode BEFORE login so event_thread never starts.
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        founder.login(),
        member1.login(),
        member2.login(),
      ]);

      await waitUntil(
        () => founder.loggedIn && member1.loggedIn && member2.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'condition',
      );

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

    test('Modify group name', () async {
      // Create group
      final createResult = await TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: 'Original Name',
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

      // Modify group name
      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'kTIMGroup_Private',
        groupName: 'Updated Name',
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
      expect(groupsInfoResult.data, isNotNull);
      expect(groupsInfoResult.data!.length, equals(1));
      expect(groupsInfoResult.data!.first.groupInfo?.groupName,
          equals('Updated Name'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Modify group notification', () async {
      // Create group
      final createResult = await TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: 'Test Group',
        notification: 'Original notification',
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

      // Modify notification
      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'kTIMGroup_Private',
        notification: 'Updated notification',
      );
      final setInfoResult = await TIMGroupManager.instance.setGroupInfo(
        info: groupInfo,
      );

      expect(setInfoResult.code, equals(0));

      // Verify update
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);
      final groupsInfoResult = await TIMGroupManager.instance.getGroupsInfo(
        groupIDList: [groupId],
      );

      expect(groupsInfoResult.code, equals(0));
      expect(groupsInfoResult.data, isNotNull);
      expect(groupsInfoResult.data!.first.groupInfo?.notification,
          equals('Updated notification'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
