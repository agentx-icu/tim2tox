/// Group Test — virtual-clock variant
///
/// Mirrors scenario_group_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Reference: c-toxcore/auto_tests/scenarios/scenario_group_general_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Tests (Virtual)', () {
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

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );

      await configureLocalBootstrapVirtual(scenario);
      // Pre-establish the alice/bob friendship once for the whole group —
      // most sub-tests assume it's already in place.
      await establishFriendshipVirtual(scenario, alice, bob);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Create group', () async {
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Test Group',
            notification: 'Test notification',
            introduction: 'Test introduction',
          ));
      expect(createResult.code, equals(0));
      expect(createResult.data, isNotNull);
      expect(createResult.data, isNotEmpty);
      alice.state['group_id'] = createResult.data!;
    }, timeout: const Timeout(Duration(seconds: 60)));

    /// Join public group by passing 64-char chat_id as groupID (no invite; single-account / link join path).
    test('Join public group by 64-char chat_id only', () async {
      await Future.wait([
        waitForFriendConnectionVirtual(scenario, alice, bob.getToxId(),
            timeout: const Duration(seconds: 30)),
        waitForFriendConnectionVirtual(scenario, bob, alice.getToxId(),
            timeout: const Duration(seconds: 30)),
      ]);
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'group',
            groupName: 'Public Group For ChatId Join',
            groupID: '',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      expect(alice.testInstanceHandle, isNotNull);
      final chatId = getGroupChatIdForInstance(alice.testInstanceHandle!, groupId);
      expect(chatId, isNotNull,
          reason: 'chat_id must be available after createGroup');
      expect(chatId!.length, equals(64),
          reason: 'chat_id must be 64 hex chars');
      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 2));
      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: chatId,
            message: '',
          ));
      expect(joinResult.code, equals(0),
          reason: 'joinGroup by chat_id failed: ${joinResult.code}');
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);
      final bobListResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(bobListResult.code, equals(0));
      expect(
        bobListResult.data
                ?.any((g) => g.groupID == chatId || g.groupID == groupId) ??
            false,
        isTrue,
        reason: 'Bob should see the joined group in getJoinedGroupList',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Join group', () async {
      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      await Future.wait([
        waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30)),
        waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30)),
      ]);
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Test Group',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      final bobPublicKey = bob.getPublicKey();

      // Retry invite + wait: inviteUserToGroup may return code=0 even when
      // the friend P2P is still warming up in virtual mode.
      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        bob.clearCallbackReceived('onGroupInvited');
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId, userList: [bobPublicKey]));
        expect(inviteResult.code, equals(0),
            reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'bob onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          inviteArrived = true;
        } catch (_) {
          // retry — friend P2P may still be warming up
        }
      }
      expect(inviteArrived, isTrue,
          reason: 'bob never received onGroupInvited after 3 retries');
      await pumpTestTick(scenario,
          advanceMs: 500, iterationsPerInstance: 1);
      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: groupId,
            message: 'Hello, I want to join!',
          ));
      expect(joinResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Get joined group list', () async {
      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      await Future.wait([
        waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30)),
        waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30)),
      ]);
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Test Group',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      final bobPublicKey = bob.getPublicKey();

      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        bob.clearCallbackReceived('onGroupInvited');
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId, userList: [bobPublicKey]));
        expect(inviteResult.code, equals(0),
            reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'bob onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          inviteArrived = true;
        } catch (_) {
          // retry — friend P2P may still be warming up
        }
      }
      expect(inviteArrived, isTrue,
          reason: 'bob never received onGroupInvited after 3 retries');
      await pumpTestTick(scenario,
          advanceMs: 500, iterationsPerInstance: 1);
      await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      await pumpTestTick(scenario,
          advanceMs: 3000, iterationsPerInstance: 1);
      final groupListResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(groupListResult.code, equals(0),
          reason: 'getJoinedGroupList failed: ${groupListResult.code}');
      expect(groupListResult.data, isNotNull);
      expect(groupListResult.data!.length, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Get groups info', () async {
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Test Group',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);
      await pumpTestTick(scenario,
          advanceMs: 3000, iterationsPerInstance: 1);
      final groupsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(
            groupIDList: [groupId],
          ));
      expect(groupsInfoResult.code, equals(0),
          reason: 'getGroupsInfo failed: ${groupsInfoResult.code}');
      expect(groupsInfoResult.data, isNotNull);
      expect(groupsInfoResult.data!.length, equals(1));
      expect(groupsInfoResult.data!.first.groupInfo?.groupID, equals(groupId));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Quit group', () async {
      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      await Future.wait([
        waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30)),
        waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30)),
      ]);
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Test Group',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      final bobPublicKey = bob.getPublicKey();

      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        bob.clearCallbackReceived('onGroupInvited');
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId, userList: [bobPublicKey]));
        expect(inviteResult.code, equals(0),
            reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'bob onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          inviteArrived = true;
        } catch (_) {
          // retry — friend P2P may still be warming up
        }
      }
      expect(inviteArrived, isTrue,
          reason: 'bob never received onGroupInvited after 3 retries');
      await pumpTestTick(scenario,
          advanceMs: 500, iterationsPerInstance: 1);
      await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      await pumpTestTick(scenario,
          advanceMs: 3000, iterationsPerInstance: 1);
      final quitResult = await bob.runWithInstanceAsync(
          () async => TIMManager.instance.quitGroup(groupID: groupId));
      expect(quitResult.code, equals(0),
          reason: 'quitGroup failed: ${quitResult.code}');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Dismiss group', () async {
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Test Group',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);
      final dismissResult = await alice.runWithInstanceAsync(
          () async => TIMManager.instance.dismissGroup(groupID: groupId));
      expect(dismissResult.code, equals(0),
          reason: 'dismissGroup failed: ${dismissResult.code}');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
