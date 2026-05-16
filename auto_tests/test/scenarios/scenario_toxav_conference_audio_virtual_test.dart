/// ToxAV Conference Audio Test — virtual-clock variant
///
/// Mirrors scenario_toxav_conference_audio_test.dart 1:1 but drives the
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
  group('ToxAV Conference Audio Tests (Virtual)', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

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
        () =>
            alice.getToxId().length == 76 && bob.getToxId().length == 76,
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

    test('AV conference setup for audio handling', () async {
      alice.clearCallbackReceived('onGroupCreated');
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
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

      var bobReceivedInvite = false;
      String? bobInvitedGroupId;

      final bobGroupListener = V2TimGroupListener(
        onMemberInvited:
            (String groupID, V2TimGroupMemberInfo opUser, List<V2TimGroupMemberInfo> memberList) {
          bobReceivedInvite = true;
          bobInvitedGroupId = groupID;
          bob.markCallbackReceived('onMemberInvited');
        },
      );

      bob.runWithInstance(
          () => TIMGroupManager.instance.addGroupListener(bobGroupListener));

      final bobPublicKey = bob.getPublicKey();

      bool inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        bobReceivedInvite = false;
        bobInvitedGroupId = null;
        bob.clearCallbackReceived('onMemberInvited');
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: conferenceId,
              userList: [bobPublicKey],
            ));
        expect(inviteResult.code, equals(0));
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
      expect(bobInvitedGroupId, isNotNull);

      final joinResult = await bob.runWithInstanceAsync(
          () async => TIMManager.instance.joinGroup(
                groupID: bobInvitedGroupId!,
                message: '',
              ));
      expect(joinResult.code, equals(0));

      await pumpTestTickAv(scenario,
          advanceMs: 5000, iterationsPerInstance: 1);

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
        bobJoinedList.data!.any((g) =>
            g.groupID == conferenceId || g.groupID == bobInvitedGroupId),
        isTrue,
      );

      bob.runWithInstance(() => TIMGroupManager.instance
          .removeGroupListener(listener: bobGroupListener));
    }, timeout: const Timeout(Duration(seconds: 150)));

    test('AV conference type verification', () async {
      alice.clearCallbackReceived('onGroupCreated');
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'conference',
            groupName: 'Conference Type Verification',
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

      final joinedListResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(joinedListResult.code, equals(0));
      expect(joinedListResult.data, isNotNull);

      final conference = joinedListResult.data!.firstWhere(
        (g) => g.groupID == conferenceId,
        orElse: () => throw Exception('Conference not found'),
      );
      expect(conference.groupID, equals(conferenceId));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
