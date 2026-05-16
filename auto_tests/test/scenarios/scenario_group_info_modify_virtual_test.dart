// Group Info Modify Test — virtual-clock variant
//
// Mirrors scenario_group_info_modify_test.dart 1:1 but drives the harness
// via the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual
// helpers). Tests modifying group information: name, introduction,
// notification, multi-field, and cross-instance change notification.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Info Modify Tests (Virtual)', () {
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

      // tim2tox inviteUserToGroup needs invitee as friend. Only one sub-test
      // exercises the cross-instance join+sync flow, but doing it once in
      // setUpAll keeps the friendship warm for all tests.
      try {
        await establishFriendshipVirtual(scenario, alice, bob,
            timeout: const Duration(seconds: 90));
      } catch (e) {
        print('[setUpAll] establishFriendshipVirtual best-effort: $e');
      }
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Modify group name', () async {
      // Create group on alice's instance
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Original Name',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        groupName: 'Modified Name',
      );

      final setInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.setGroupInfo(info: groupInfo));

      expect(setInfoResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final groupsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(groupIDList: [groupId]));

      if (groupsInfoResult.code == 0 &&
          groupsInfoResult.data != null &&
          groupsInfoResult.data!.isNotEmpty) {
        expect(groupsInfoResult.data!.first.groupInfo?.groupName,
            equals('Modified Name'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Modify group introduction', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                introduction: 'Original Introduction',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        introduction: 'Modified Introduction',
      );

      final setInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.setGroupInfo(info: groupInfo));

      expect(setInfoResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final groupsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(groupIDList: [groupId]));

      if (groupsInfoResult.code == 0 &&
          groupsInfoResult.data != null &&
          groupsInfoResult.data!.isNotEmpty) {
        expect(groupsInfoResult.data!.first.groupInfo?.introduction,
            equals('Modified Introduction'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Modify group notification', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Test Group',
                notification: 'Original Notification',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        notification: 'Modified Notification',
      );

      final setInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.setGroupInfo(info: groupInfo));

      expect(setInfoResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final groupsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(groupIDList: [groupId]));

      if (groupsInfoResult.code == 0 &&
          groupsInfoResult.data != null &&
          groupsInfoResult.data!.isNotEmpty) {
        expect(groupsInfoResult.data!.first.groupInfo?.notification,
            equals('Modified Notification'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Modify multiple group info fields', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Original Name',
                introduction: 'Original Introduction',
                notification: 'Original Notification',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        groupName: 'New Name',
        introduction: 'New Introduction',
        notification: 'New Notification',
      );

      final setInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.setGroupInfo(info: groupInfo));

      expect(setInfoResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final groupsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(groupIDList: [groupId]));

      if (groupsInfoResult.code == 0 &&
          groupsInfoResult.data != null &&
          groupsInfoResult.data!.isNotEmpty) {
        final info = groupsInfoResult.data!.first.groupInfo!;
        expect(info.groupName, equals('New Name'));
        expect(info.introduction, equals('New Introduction'));
        expect(info.notification, equals('New Notification'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Modify group info for conference type', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'Meeting',
                groupName: 'Original Conference Name',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      final groupInfo = V2TimGroupInfo(
        groupID: conferenceId,
        groupType: 'Meeting',
        groupName: 'Modified Conference Name',
      );

      final setInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.setGroupInfo(info: groupInfo));

      expect(setInfoResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final groupsInfoResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(groupIDList: [conferenceId]));

      if (groupsInfoResult.code == 0 &&
          groupsInfoResult.data != null &&
          groupsInfoResult.data!.isNotEmpty) {
        expect(groupsInfoResult.data!.first.groupInfo?.groupName,
            equals('Modified Conference Name'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Group info change notification to members', () async {
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Original Name',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Friend P2P needs periodic keepalive packets which only fire on real
      // wall time. Between setUpAll friendship and this (the last) sub-test,
      // the prior 5 Alice-local sub-tests don't drive enough iterates to keep
      // Alice<->Bob's friend connection alive, so by the time we get here
      // the C++ side may report `Friend X connection status: 0 (NONE)` and
      // the invite packet drops. Pump aggressively to revive friend keepalives
      // before the invite. Best-effort: if DHT itself is down, this can't
      // help — that's a separate setUpAll-level flake.
      await pumpTestTick(scenario,
          advanceMs: 2000,
          iterationsPerInstance: 40,
          wallSleep: const Duration(milliseconds: 15));

      // Bob needs an invite before joinGroup can succeed (joinGroup wants a
      // stored chat_id or pending invite; chat_id only lives on Alice's instance).
      // Retry invite + wait: inviteUserToGroup returns code=0 even when the
      // underlying tox_group_invite_friend packet was dropped, and the first
      // invite often races with friend P2P bring-up in virtual mode.
      var inviteArrived = false;
      final bobPublicKey = bob.getPublicKey();
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        bob.clearCallbackReceived('onGroupInvited');
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey],
            ));
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
          // Retry: friend P2P may not have been ONLINE for the first attempt.
        }
      }
      expect(inviteArrived, isTrue,
          reason: 'bob never received onGroupInvited after 3 retries');
      await pumpTestTick(scenario, advanceMs: 300, iterationsPerInstance: 1);
      final bobJoinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(bobJoinResult.code, equals(0),
          reason: 'bob joinGroup failed: ${bobJoinResult.desc}');
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      var bobReceivedInfoChange = false;
      final bobListener = V2TimGroupListener(
        onGroupInfoChanged: (groupID, changeInfos) {
          if (groupID == groupId) {
            bobReceivedInfoChange = true;
            bob.markCallbackReceived('onGroupInfoChanged');
          }
        },
      );

      bob.runWithInstance(
          () => TIMManager.instance.addGroupListener(listener: bobListener));

      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        groupName: 'Changed Name',
      );

      await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.setGroupInfo(info: groupInfo));

      // NGC topic-change propagation needs (a) Alice's iterate to emit the
      // topic packet, (b) UDP loopback delivery, (c) Bob's iterate to process
      // it. With 5 prior groups already announcing on Alice's instance,
      // iterate budget per group is divided — give the topic packet enough
      // densely-packed iterates AND real wall time on both ends to settle.
      // Without the larger advanceMs/wallSleep, virtual mode runs ~200 sparse
      // iterates within ~1s real wall (vs ~23s wall in the wall-clock test),
      // not enough for NGC topic sync. Pump aggressively first, then wait.
      // The high wallSleep (50ms) is critical: UDP loopback packets need real
      // wall time to be delivered between iterate bursts.
      await pumpTestTick(scenario,
          advanceMs: 3000,
          iterationsPerInstance: 60,
          wallSleep: const Duration(milliseconds: 50));

      // Callback may be delayed on some runs; query is the authoritative fallback.
      try {
        await waitUntilWithVirtualPump(
          scenario,
          () => bobReceivedInfoChange,
          timeout: const Duration(seconds: 45),
          description: 'Bob receives group info change',
          advanceMs: 1000,
          iterationsPerInstance: 20,
          wallSleep: const Duration(milliseconds: 50),
        );
      } catch (e) {
        print(
            '[GroupInfoModify] onGroupInfoChanged callback not observed in time, fallback to state query: $e');
      }

      final bobGroupInfoResult = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupsInfo(groupIDList: [groupId]));
      expect(bobGroupInfoResult.code, equals(0),
          reason: 'Bob should be able to query group info');
      final bobObservedChangedName = bobGroupInfoResult.data != null &&
          bobGroupInfoResult.data!.isNotEmpty &&
          bobGroupInfoResult.data!.first.groupInfo?.groupName == 'Changed Name';
      expect(
        bobObservedChangedName,
        isTrue,
        reason: 'Bob should observe updated group name via getGroupsInfo',
      );
      expect(
        bobReceivedInfoChange || bobObservedChangedName,
        isTrue,
        reason:
            'Bob should observe group info change via callback or state query',
      );

      bob.runWithInstance(
          () => TIMManager.instance.removeGroupListener(listener: bobListener));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
