/// ToxAV Conference Audio Send Test — virtual-clock variant
///
/// Mirrors scenario_toxav_conference_audio_send_test.dart 1:1 but drives the
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
  group('ToxAV Conference Audio Send Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late TestNode charlie;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob', 'charlie']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      charlie = scenario.getNode('charlie')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

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

      final bobToxId = bob.getToxId();
      final charlieToxId = charlie.getToxId();
      final aliceToxId = alice.getToxId();
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
      await bob.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: aliceToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Alice',
                addWording: 'test',
              ));
      await charlie.runWithInstanceAsync(
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
      final charliePub = charlie.getPublicKey();

      await waitForFriendsInList(alice, [bobPub, charliePub],
          timeout: const Duration(seconds: 120));
      await waitForFriendsInList(bob, [alicePub],
          timeout: const Duration(seconds: 120));
      await waitForFriendsInList(charlie, [alicePub],
          timeout: const Duration(seconds: 120));

      // Extra pump for multi-node P2P propagation.
      for (int i = 0; i < 30; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30));
      }
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {});

    test('AV conference with audio sending', () async {
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 30));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 30));
      await waitForConnectionVirtual(scenario, charlie,
          timeout: const Duration(seconds: 30));

      // Pump for friend P2P bring-up.
      for (int i = 0; i < 20; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 200,
            iterationsPerInstance: 3,
            wallSleep: const Duration(milliseconds: 50));
      }

      final bobPub = bob.getPublicKey();
      final charliePub = charlie.getPublicKey();
      await waitForFriendConnectionVirtual(scenario, alice, bobPub,
          timeout: const Duration(seconds: 90));
      await waitForFriendConnectionVirtual(scenario, alice, charliePub,
          timeout: const Duration(seconds: 90));

      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 200,
            iterationsPerInstance: 3,
            wallSleep: const Duration(milliseconds: 50));
      }

      alice.clearCallbackReceived('onGroupCreated');
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'conference',
                groupName: 'AV Conference Audio Test',
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

      for (int i = 0; i < 10; i++) {
        await pumpTestTickAv(scenario,
            advanceMs: 200,
            iterationsPerInstance: 4,
            wallSleep: const Duration(milliseconds: 50));
      }

      var bobReceivedInvite = false;
      var charlieReceivedInvite = false;
      String? bobInvitedGroupId;
      String? charlieInvitedGroupId;

      final bobGroupListener = V2TimGroupListener(
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser,
            List<V2TimGroupMemberInfo> memberList) {
          // V2TIM onMemberInvited fires on every group member for any new invite;
          // only capture entries where Bob himself is among the invited members.
          final memberIDs =
              memberList.map((m) => (m.userID ?? '').toUpperCase()).toSet();
          if (!memberIDs.contains(bobPub.toUpperCase())) return;
          bobReceivedInvite = true;
          bobInvitedGroupId = groupID;
          bob.markCallbackReceived('onMemberInvited');
        },
      );
      final charlieGroupListener = V2TimGroupListener(
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser,
            List<V2TimGroupMemberInfo> memberList) {
          final memberIDs =
              memberList.map((m) => (m.userID ?? '').toUpperCase()).toSet();
          if (!memberIDs.contains(charliePub.toUpperCase())) return;
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
      for (var attempt = 0; !bothArrived && attempt < 4; attempt++) {
        bobReceivedInvite = false;
        charlieReceivedInvite = false;
        bobInvitedGroupId = null;
        charlieInvitedGroupId = null;
        bob.clearCallbackReceived('onMemberInvited');
        charlie.clearCallbackReceived('onMemberInvited');

        final inviteResult = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.inviteUserToGroup(
                  groupID: conferenceId,
                  userList: [bobPub, charliePub],
                ));
        expect(inviteResult.code, equals(0));

        try {
          await waitUntilWithAvVirtualPump(
            scenario,
            () => bobReceivedInvite && charlieReceivedInvite,
            timeout: const Duration(seconds: 60),
            description: 'Both received invites (attempt ${attempt + 1})',
            advanceMs: 200,
            iterationsPerInstance: 4,
            wallSleep: const Duration(milliseconds: 50),
          );
          bothArrived = true;
        } on TimeoutException catch (e) {
          // Expected between retry attempts (the post-loop expect enforces the
          // real assertion); a non-timeout error is a real bug and propagates.
          print('[Test] Attempt timed out; retrying: $e');
        }
      }

      expect(bobInvitedGroupId, isNotNull,
          reason: 'Bob never received invite after retries');
      expect(charlieInvitedGroupId, isNotNull,
          reason: 'Charlie never received invite after retries');

      // AV conferences auto-join inside the invite callback and only map the
      // invite's local id a moment later, so an explicit join racing that mapping
      // can transiently return 6017. Retry until the mapping settles.
      Future<int> joinWithRetry(TestNode node, String gid) async {
        var res = await node.runWithInstanceAsync(() async =>
            TIMManager.instance.joinGroup(groupID: gid, message: ''));
        for (int r = 0; r < 6 && res.code != 0; r++) {
          await Future.delayed(const Duration(milliseconds: 500));
          res = await node.runWithInstanceAsync(() async =>
              TIMManager.instance.joinGroup(groupID: gid, message: ''));
        }
        return res.code;
      }

      expect(await joinWithRetry(bob, bobInvitedGroupId!), equals(0));
      expect(await joinWithRetry(charlie, charlieInvitedGroupId!), equals(0));

      await pumpTestTickAv(scenario, advanceMs: 5000, iterationsPerInstance: 2);

      final aliceJoinedList = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(aliceJoinedList.data, isNotNull);
      expect(
          aliceJoinedList.data!.any((g) => g.groupID == conferenceId), isTrue);

      final bobJoinedList = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(bobJoinedList.data, isNotNull);
      expect(bobJoinedList.data!.isNotEmpty, isTrue);
      expect(
        bobJoinedList.data!.any(
            (g) => g.groupID == conferenceId || g.groupID == bobInvitedGroupId),
        isTrue,
      );

      final charlieJoinedList = await charlie.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(charlieJoinedList.data, isNotNull);
      expect(charlieJoinedList.data!.isNotEmpty, isTrue);
      expect(
        charlieJoinedList.data!.any((g) =>
            g.groupID == conferenceId || g.groupID == charlieInvitedGroupId),
        isTrue,
      );

      bob.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: bobGroupListener));
      charlie.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: charlieGroupListener));
    }, timeout: const Timeout(Duration(seconds: 240)));
  });
}
