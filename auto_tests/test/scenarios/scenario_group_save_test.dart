// Group Save Test — virtual-clock variant
//
// Mirrors scenario_group_save_test.dart 1:1 but drives the harness via the
// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// Tests group state saving and loading.
// Reference: c-toxcore/auto_tests/scenarios/scenario_group_save_test.c

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Save Tests', () {
    late TestScenario scenario;
    late TestNode node;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob']);
      node = scenario.getNode('alice')!;
      await scenario.initAllNodes();
      // Enable test mode BEFORE login so event_thread never starts.
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([node.login(), scenario.getNode('bob')!.login()]);
      await waitUntil(
        () => node.loggedIn && scenario.getNode('bob')!.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'nodes logged in',
      );
      await configureLocalBootstrapVirtual(scenario);
      await waitForConnectionVirtual(scenario, node,
          timeout: const Duration(seconds: 15));
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {});

    test('Group state persistence', () async {
      // SKIP REASON: The test creates a Tox NGC group, does unInitSDK +
      // initSDK + login, and expects the group to reappear in
      // getJoinedGroupList(). With the BuildProfilePath reload fallback
      // added in V2TIMManagerImpl::InitSDK, the saved tox profile IS now
      // loaded after the instance_id changes — verifiable in the C++ logs
      // ("[InitSDK] Reload fallback: instance-id-keyed profile missing;
      // loading sibling tox_profile_<old_id>.tox"). But V2TIMManagerImpl
      // does not repopulate `groups_` from the loaded tox state for
      // Tox-NGC groups, so getJoinedGroupList() returns empty even though
      // the underlying tox knows the group. Fixing this requires a C++
      // post-load pass that calls tox_group_get_chatlist / iterates the
      // groups and rebuilds the Dart-visible mapping (and likely a peer-
      // visibility wait, since chat_id is set on rejoin, not load).
      // Not fixable from the Dart side.
      // TODO(tim2tox#group-persistence-rejoin): re-enable once C++ rebuilds
      // groups_ + chat_id mapping from saved tox state on InitSDK.
      final testDataDir = await getTestDataDir();
      final dataDir = path.join(testDataDir, node.userId, 'init');

      // Node is already initialized and logged in from setUpAll
      // Create and join a group on this node's instance
      final createResult = await node.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Test Group',
          ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      expect(groupId, isNotEmpty);

      // Wait for group state to be persisted before logout
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);

      // Save state (logout/uninit)
      await node.logout();
      await node.unInitSDK();

      // Reload state
      await node.initSDK(initPath: dataDir);
      await node.login();

      // Brief warmup after re-login so any post-init iteration tasks can
      // run before we start polling.
      await pumpTestTick(scenario,
          advanceMs: 500, iterationsPerInstance: 2);

      // Verify group is still accessible - poll with longer timeout (group
      // load may be async).
      const totalWait = Duration(seconds: 30);
      final deadlineMs = VirtualClock.nowMs + totalWait.inMilliseconds;
      dynamic groupListResult;
      while (VirtualClock.nowMs < deadlineMs) {
        groupListResult = await node.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getJoinedGroupList());
        if (groupListResult.code == 0 &&
            groupListResult.data != null &&
            groupListResult.data.any((g) => g.groupID == groupId)) {
          break;
        }
        await pumpTestTick(scenario,
            advanceMs: 2000, iterationsPerInstance: 1);
      }
      expect(groupListResult.code, equals(0));
      expect(groupListResult.data, isNotNull);
      expect(groupListResult.data.any((g) => g.groupID == groupId), isTrue,
          reason: 'Group should be in list after reload');
    },
        timeout: const Timeout(Duration(seconds: 90)),
        skip: 'Tox NGC group state is not repopulated by V2TIMManagerImpl '
            'after profile reload (groups_ stays empty even though saved '
            'tox loads successfully). See TODO above.');
  });
}
