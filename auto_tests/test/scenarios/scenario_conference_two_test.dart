// Ported from c-toxcore scenario_conference_two_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Two Tests (Single Node)', () {
    late TestScenario scenario;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['node']);
      await scenario.initAllNodes();

      final node = scenario.getNode('node')!;
      await node.login();

      await configureLocalBootstrap(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Node creates two parallel conferences with independent IDs',
        () async {
      final node = scenario.getNode('node')!;

      // Conference 1.
      final create1 = await node.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Conference One',
            groupID: '',
          ));
      expect(create1.code, equals(0),
          reason: 'createGroup conf1 failed with code ${create1.code}');
      expect(create1.data, isNotNull);
      final groupId1 = create1.data!;

      // Conference 2.
      final create2 = await node.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Conference Two',
            groupID: '',
          ));
      expect(create2.code, equals(0),
          reason: 'createGroup conf2 failed with code ${create2.code}');
      expect(create2.data, isNotNull);
      final groupId2 = create2.data!;

      // Different conferences must have different group IDs.
      expect(groupId1, isNot(equals(groupId2)),
          reason: 'Two conferences must have distinct group IDs');

      // Both conferences must be queryable independently and keep their
      // own names (no state bleed across the two).
      await Future.delayed(const Duration(seconds: 1));

      final info1 = await node.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(
            groupIDList: [groupId1],
          ));
      expect(info1.code, equals(0));
      expect(info1.data, isNotNull);
      expect(info1.data!.length, equals(1));
      expect(info1.data!.first.groupInfo?.groupName, equals('Conference One'),
          reason: 'Conference 1 must keep its own name');

      final info2 = await node.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(
            groupIDList: [groupId2],
          ));
      expect(info2.code, equals(0));
      expect(info2.data, isNotNull);
      expect(info2.data!.length, equals(1));
      expect(info2.data!.first.groupInfo?.groupName, equals('Conference Two'),
          reason: 'Conference 2 must keep its own name');

      // Both conferences must appear in the joined-list together.
      final joined = await node.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(joined.code, equals(0));
      expect(joined.data, isNotNull);
      final joinedIds = joined.data!.map((g) => g.groupID).toSet();
      expect(joinedIds.contains(groupId1), isTrue,
          reason: 'Joined list must contain conference 1');
      expect(joinedIds.contains(groupId2), isTrue,
          reason: 'Joined list must contain conference 2');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
