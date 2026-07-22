/// ToxAV Conference Invite Test — virtual-clock variant
///
/// Mirrors scenario_toxav_conference_invite_test.dart 1:1 but drives the
/// harness via the virtual-clock helpers and pumpTestTickAv.

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
  group('ToxAV Conference Invite Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'all nodes logged in',
      );

      await configureLocalBootstrapVirtual(scenario);

      alice.enableAutoAccept();
      bob.enableAutoAccept();

      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 15));
      await waitUntilWithVirtualPump(
        scenario,
        () => alice.getToxId().length == 76 && bob.getToxId().length == 76,
        timeout: const Duration(seconds: 10),
        description: 'Tox IDs available',
      );

      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      await alice.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: bobToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Bob',
                addWording: 'test',
              ));
      await bob.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: aliceToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Alice',
                addWording: 'test',
              ));

      for (int i = 0; i < 50; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }

      final alicePub = alice.getPublicKey();
      final bobPub = bob.getPublicKey();
      await waitForFriendsInList(alice, [bobPub],
          timeout: const Duration(seconds: 120));
      await waitForFriendsInList(bob, [alicePub],
          timeout: const Duration(seconds: 120));

      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 90));
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {});

    test('Receive and accept AV conference invite', () async {
      alice.clearCallbackReceived('onGroupCreated');
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'conference',
                groupName: 'AV Conference Invite Test',
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

      var inviteReceived = false;
      String? receivedGroupId;
      String? inviterId;

      final bobGroupListener = V2TimGroupListener(
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser,
            List<V2TimGroupMemberInfo> memberList) {
          inviteReceived = true;
          receivedGroupId = groupID;
          inviterId = opUser.userID;
          bob.markCallbackReceived('onMemberInvited');
        },
      );

      bob.runWithInstance(
          () => TIMGroupManager.instance.addGroupListener(bobGroupListener));

      final bobPublicKey = bob.getPublicKey();
      final alicePublicKey = alice.getPublicKey();

      bool inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        inviteReceived = false;
        receivedGroupId = null;
        inviterId = null;
        bob.clearCallbackReceived('onMemberInvited');
        final inviteResult = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.inviteUserToGroup(
                  groupID: conferenceId,
                  userList: [bobPublicKey],
                ));
        expect(inviteResult.code, equals(0),
            reason: 'Failed to send invite: ${inviteResult.code}');
        try {
          await waitUntilWithAvVirtualPump(
            scenario,
            () => inviteReceived,
            timeout: const Duration(seconds: 30),
            description:
                'Bob received AV conference invite (attempt ${attempt + 1})',
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30),
          );
          inviteArrived = true;
        } on TimeoutException catch (e) {
          // Expected between retry attempts (the post-loop expect enforces the
          // real assertion); a non-timeout error is a real bug and propagates.
          print('[Test] Attempt timed out; retrying: $e');
        }
      }

      expect(inviteReceived, isTrue, reason: 'Bob did not receive invite');
      expect(receivedGroupId, isNotNull);
      expect(inviterId, equals(alicePublicKey), reason: 'Inviter ID mismatch');

      final joinResult = await bob
          .runWithInstanceAsync(() async => TIMManager.instance.joinGroup(
                groupID: receivedGroupId!,
                message: 'Joining AV conference',
              ));
      expect(joinResult.code, equals(0));

      await pumpTestTickAv(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      final bobJoinedList = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(bobJoinedList.code, equals(0));
      expect(bobJoinedList.data, isNotNull);

      final bobGroupIds = bobJoinedList.data!.map((g) => g.groupID).toList();
      expect(bobGroupIds, isNotEmpty);
      expect(
        bobGroupIds.contains(conferenceId) ||
            bobGroupIds.contains(receivedGroupId),
        isTrue,
      );

      bob.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: bobGroupListener));
    }, timeout: const Timeout(Duration(seconds: 150)));

    test('Multiple AV conference invites', () async {
      alice.clearCallbackReceived('onGroupCreated');
      final createResult1 = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'conference',
                groupName: 'AV Conference 1',
                groupID: '',
              ));
      final createResult2 = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'conference',
                groupName: 'AV Conference 2',
                groupID: '',
              ));
      expect(createResult1.code, equals(0));
      expect(createResult2.code, equals(0));

      final conferenceId1 = createResult1.data!;
      final conferenceId2 = createResult2.data!;

      await waitUntilWithAvVirtualPump(
        scenario,
        () => alice.callbackReceived['onGroupCreated'] == true,
        timeout: const Duration(seconds: 10),
        description: 'alice onGroupCreated',
      );

      final receivedInvites = <String>[];
      final bobGroupListener = V2TimGroupListener(
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser,
            List<V2TimGroupMemberInfo> memberList) {
          receivedInvites.add(groupID);
          bob.markCallbackReceived('onMemberInvited');
        },
      );

      bob.runWithInstance(
          () => TIMGroupManager.instance.addGroupListener(bobGroupListener));

      final bobPublicKey = bob.getPublicKey();

      bool gotBoth = false;
      for (var attempt = 0; !gotBoth && attempt < 3; attempt++) {
        receivedInvites.clear();
        bob.clearCallbackReceived('onMemberInvited');
        final inviteResult1 = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.inviteUserToGroup(
                  groupID: conferenceId1,
                  userList: [bobPublicKey],
                ));
        final inviteResult2 = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.inviteUserToGroup(
                  groupID: conferenceId2,
                  userList: [bobPublicKey],
                ));
        expect(inviteResult1.code, equals(0));
        expect(inviteResult2.code, equals(0));

        try {
          await waitUntilWithAvVirtualPump(
            scenario,
            () => receivedInvites.length >= 2,
            timeout: const Duration(seconds: 45),
            description: 'Bob received both invites (attempt ${attempt + 1})',
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30),
          );
          gotBoth = true;
        } on TimeoutException catch (e) {
          // Expected between retry attempts (the post-loop expect enforces the
          // real assertion); a non-timeout error is a real bug and propagates.
          print('[Test] Attempt timed out; retrying: $e');
        }
      }

      expect(receivedInvites.length, greaterThanOrEqualTo(2),
          reason: 'Bob should receive 2 invites');

      final joinResult1 = await bob
          .runWithInstanceAsync(() async => TIMManager.instance.joinGroup(
                groupID: receivedInvites[0],
                message: '',
              ));
      final joinResult2 = await bob
          .runWithInstanceAsync(() async => TIMManager.instance.joinGroup(
                groupID: receivedInvites[1],
                message: '',
              ));
      expect(joinResult1.code, equals(0));
      expect(joinResult2.code, equals(0));

      await pumpTestTickAv(scenario, advanceMs: 5000, iterationsPerInstance: 1);

      final bobJoinedList = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(bobJoinedList.data, isNotNull);

      final bobGroupIds = bobJoinedList.data!.map((g) => g.groupID).toList();
      expect(bobGroupIds.length, greaterThanOrEqualTo(2));
      expect(bobGroupIds, contains(receivedInvites[0]));
      expect(bobGroupIds, contains(receivedInvites[1]));

      bob.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: bobGroupListener));
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
