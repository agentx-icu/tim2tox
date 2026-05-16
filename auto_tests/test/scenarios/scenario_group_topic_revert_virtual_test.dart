// Group Topic Revert Test — virtual-clock variant
//
// Mirrors scenario_group_topic_revert_test.dart 1:1 but drives the harness via
// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// Reference: c-toxcore/auto_tests/scenarios/scenario_group_topic_revert_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Topic Revert Tests (Virtual)', () {
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
      await VirtualClock.enableForScenario(scenario);

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

    test('Rapid topic changes', () async {
      // Create group
      final createResult = await TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: 'Test Group',
      );

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Rapid topic changes
      final groupInfo1 = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'kTIMGroup_Private',
        introduction: 'Topic 1',
      );
      final groupInfo2 = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'kTIMGroup_Private',
        introduction: 'Topic 2',
      );
      final groupInfo3 = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'kTIMGroup_Private',
        introduction: 'Topic 3',
      );
      await TIMGroupManager.instance.setGroupInfo(info: groupInfo1);
      await TIMGroupManager.instance.setGroupInfo(info: groupInfo2);
      await TIMGroupManager.instance.setGroupInfo(info: groupInfo3);

      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);
      final groupsInfoResult =
          await TIMGroupManager.instance.getGroupsInfo(groupIDList: [groupId]);
      expect(groupsInfoResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
