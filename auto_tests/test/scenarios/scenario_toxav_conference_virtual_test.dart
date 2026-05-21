/// ToxAV Conference Test — virtual-clock variant
///
/// Mirrors scenario_toxav_conference_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers and pumpTestTickAv (ToxAV iterate not driven by
/// regular pumpTestTick).

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('ToxAV Conference Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late TestNode charlie;

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob', 'charlie']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      charlie = scenario.getNode('charlie')!;

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        bob.login(),
        charlie.login(),
      ]);

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn && charlie.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'all nodes logged in',
      );

      await configureLocalBootstrapVirtual(scenario);

      alice.enableAutoAccept();
      bob.enableAutoAccept();
      charlie.enableAutoAccept();

      // Wait for DHT connection so full Tox IDs are available.
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, charlie,
          timeout: const Duration(seconds: 15));
      await waitUntilWithVirtualPump(
        scenario,
        () =>
            alice.getToxId().length == 76 &&
            bob.getToxId().length == 76 &&
            charlie.getToxId().length == 76,
        timeout: const Duration(seconds: 10),
        description: 'Tox IDs available',
      );

      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      final charlieToxId = charlie.getToxId();

      await alice.runWithInstanceAsync(() async {
        await TIMFriendshipManager.instance.addFriend(
          userID: bobToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          remark: 'Bob',
          addWording: 'test',
        );
        await TIMFriendshipManager.instance.addFriend(
          userID: charlieToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          remark: 'Charlie',
          addWording: 'test',
        );
      });
      await bob.runWithInstanceAsync(() async {
        await TIMFriendshipManager.instance.addFriend(
          userID: aliceToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          remark: 'Alice',
          addWording: 'test',
        );
      });
      await charlie.runWithInstanceAsync(() async {
        await TIMFriendshipManager.instance.addFriend(
          userID: aliceToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          remark: 'Alice',
          addWording: 'test',
        );
      });

      // Pump for friend-request propagation / auto-accept.
      for (int i = 0; i < 50; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      final alicePub = alice.getPublicKey();
      final bobPub = bob.getPublicKey();
      final charliePub = charlie.getPublicKey();

      await waitForFriendsInList(alice, [bobPub, charliePub],
          timeout: const Duration(seconds: 120));
      await waitForFriendsInList(bob, [alicePub],
          timeout: const Duration(seconds: 120));
      await waitForFriendsInList(charlie, [alicePub],
          timeout: const Duration(seconds: 120));

      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));
      await waitForFriendConnectionVirtual(scenario, alice, charlieToxId,
          timeout: const Duration(seconds: 90));
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 90));
      await waitForFriendConnectionVirtual(scenario, charlie, aliceToxId,
          timeout: const Duration(seconds: 90));

      await pumpTestTickAv(scenario,
          advanceMs: 1000, iterationsPerInstance: 1);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {});

    test('Create AV conference and verify type', () async {
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'conference',
            groupName: 'AV Conference Test',
            groupID: '',
          ));

      expect(createResult.code, equals(0),
          reason: 'Failed to create conference: ${createResult.code}');
      expect(createResult.data, isNotNull);

      final conferenceId = createResult.data!;

      // Pump while waiting for onGroupCreated callback (virtual mode).
      await waitUntilWithAvVirtualPump(
        scenario,
        () => alice.callbackReceived['onGroupCreated'] == true,
        timeout: const Duration(seconds: 10),
        description: 'alice onGroupCreated',
      );

      final joinedListResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getJoinedGroupList());
      expect(joinedListResult.code, equals(0));
      expect(joinedListResult.data, isNotNull);

      final groupIds = joinedListResult.data!.map((g) => g.groupID).toList();
      expect(groupIds, contains(conferenceId),
          reason: 'Conference not found in joined list');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('Join AV conference via invite', () async {
      alice.clearCallbackReceived('onGroupCreated');
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'conference',
            groupName: 'AV Conference Join Test',
            groupID: '',
          ));

      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;

      await waitUntilWithAvVirtualPump(
        scenario,
        () => alice.callbackReceived['onGroupCreated'] == true,
        timeout: const Duration(seconds: 10),
        description: 'alice onGroupCreated',
      );

      var bobReceivedInvite = false;
      String? invitedGroupId;

      final bobGroupListener = V2TimGroupListener(
        onMemberInvited:
            (String groupID, V2TimGroupMemberInfo opUser, List<V2TimGroupMemberInfo> memberList) {
          bobReceivedInvite = true;
          invitedGroupId = groupID;
          bob.markCallbackReceived('onMemberInvited');
        },
      );

      bob.runWithInstance(
          () => TIMGroupManager.instance.addGroupListener(bobGroupListener));

      final bobPublicKey = bob.getPublicKey();
      // Invite retry — friend P2P custom-packet flake.
      bool inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        bobReceivedInvite = false;
        invitedGroupId = null;
        bob.clearCallbackReceived('onMemberInvited');
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: conferenceId,
              userList: [bobPublicKey],
            ));
        expect(inviteResult.code, equals(0),
            reason: 'Failed to invite Bob: ${inviteResult.code}');

        try {
          await waitUntilWithAvVirtualPump(
            scenario,
            () => bobReceivedInvite,
            timeout: const Duration(seconds: 30),
            description: 'Bob received invite (attempt ${attempt + 1})',
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30),
          );
          inviteArrived = true;
        } catch (_) {}
      }
      expect(bobReceivedInvite, isTrue,
          reason: 'Bob did not receive conference invite');
      expect(invitedGroupId, isNotNull);

      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: invitedGroupId!,
            message: '',
          ));

      expect(joinResult.code, equals(0),
          reason: 'Bob failed to join conference: ${joinResult.code}');

      // Settle.
      await pumpTestTickAv(scenario,
          advanceMs: 3000, iterationsPerInstance: 1);

      final bobJoinedListResult = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(bobJoinedListResult.code, equals(0));
      expect(bobJoinedListResult.data, isNotNull);

      final bobGroupIds =
          bobJoinedListResult.data!.map((g) => g.groupID).toList();
      expect(bobGroupIds, isNotEmpty,
          reason: 'Bob should have joined a group');
      expect(
        bobGroupIds.contains(conferenceId) ||
            bobGroupIds.contains(invitedGroupId),
        isTrue,
        reason:
            'Bob not in conference (expected $conferenceId or $invitedGroupId, got $bobGroupIds)',
      );

      bob.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: bobGroupListener));
    }, timeout: const Timeout(Duration(seconds: 150)));

    test('Multiple members join AV conference', () async {
      alice.clearCallbackReceived('onGroupCreated');
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'conference',
            groupName: 'Multi-Member AV Conference',
            groupID: '',
          ));

      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;

      await waitUntilWithAvVirtualPump(
        scenario,
        () => alice.callbackReceived['onGroupCreated'] == true,
        timeout: const Duration(seconds: 10),
        description: 'alice onGroupCreated',
      );

      var bobReceivedInvite = false;
      var charlieReceivedInvite = false;
      String? bobInvitedGroupId;
      String? charlieInvitedGroupId;

      final bobPublicKey = bob.getPublicKey();
      final charliePublicKey = charlie.getPublicKey();

      final bobGroupListener = V2TimGroupListener(
        onMemberInvited:
            (String groupID, V2TimGroupMemberInfo opUser, List<V2TimGroupMemberInfo> memberList) {
          // V2TIM onMemberInvited fires on every group member for any new invite;
          // only capture the entry where Bob himself is among the invited members.
          final memberIDs = memberList.map((m) => (m.userID ?? '').toUpperCase()).toSet();
          if (!memberIDs.contains(bobPublicKey.toUpperCase())) return;
          bobReceivedInvite = true;
          bobInvitedGroupId = groupID;
          bob.markCallbackReceived('onMemberInvited');
        },
      );
      final charlieGroupListener = V2TimGroupListener(
        onMemberInvited:
            (String groupID, V2TimGroupMemberInfo opUser, List<V2TimGroupMemberInfo> memberList) {
          final memberIDs = memberList.map((m) => (m.userID ?? '').toUpperCase()).toSet();
          if (!memberIDs.contains(charliePublicKey.toUpperCase())) return;
          charlieReceivedInvite = true;
          charlieInvitedGroupId = groupID;
          charlie.markCallbackReceived('onMemberInvited');
        },
      );

      bob.runWithInstance(
          () => TIMGroupManager.instance.addGroupListener(bobGroupListener));
      charlie.runWithInstance(() =>
          TIMGroupManager.instance.addGroupListener(charlieGroupListener));

      bool bothArrived = false;
      for (var attempt = 0; !bothArrived && attempt < 3; attempt++) {
        bobReceivedInvite = false;
        charlieReceivedInvite = false;
        bob.clearCallbackReceived('onMemberInvited');
        charlie.clearCallbackReceived('onMemberInvited');
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: conferenceId,
              userList: [bobPublicKey, charliePublicKey],
            ));
        expect(inviteResult.code, equals(0));
        try {
          await waitUntilWithAvVirtualPump(
            scenario,
            () => bobReceivedInvite && charlieReceivedInvite,
            timeout: const Duration(seconds: 60),
            description:
                'Both Bob and Charlie received invites (attempt ${attempt + 1})',
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30),
          );
          bothArrived = true;
        } catch (_) {}
      }
      expect(bothArrived, isTrue,
          reason: 'Bob and Charlie did not both receive invites');

      final bobJoinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: bobInvitedGroupId!,
            message: '',
          ));
      expect(bobJoinResult.code, equals(0));

      final charlieJoinResult = await charlie.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(
            groupID: charlieInvitedGroupId!,
            message: '',
          ));
      expect(charlieJoinResult.code, equals(0));

      await pumpTestTickAv(scenario,
          advanceMs: 5000, iterationsPerInstance: 1);

      final aliceJoinedList = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(aliceJoinedList.data, isNotNull);
      expect(
          aliceJoinedList.data!.any((g) => g.groupID == conferenceId), isTrue);

      bob.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: bobGroupListener));
      charlie.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: charlieGroupListener));
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
