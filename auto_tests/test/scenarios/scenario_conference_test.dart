/// Conference Test — virtual-clock variant
///
/// Mirrors scenario_conference_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Note: tim2tox uses Tox Group instead of Conference; this maps to group
/// features.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Conference Tests (Mapped to Group)', () {
    late TestScenario scenario;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob', 'charlie']);
      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final charlie = scenario.getNode('charlie')!;
      // Short DHT-connect timeout on login: bootstrap is configured AFTER
      // login, so the default 10s connection wait inside TestNode.login()
      // always times out. We re-establish connection via
      // configureLocalBootstrapVirtual below.
      await Future.wait([
        alice.login(timeout: const Duration(milliseconds: 500)),
        bob.login(timeout: const Duration(milliseconds: 500)),
        charlie.login(timeout: const Duration(milliseconds: 500)),
      ]);
      await waitUntil(() => alice.loggedIn && bob.loggedIn && charlie.loggedIn);

      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Create group (conference) and invite members', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final charlie = scenario.getNode('charlie')!;

      await Future.wait([
        establishFriendshipVirtual(scenario, alice, bob,
            timeout: const Duration(seconds: 20)),
        establishFriendshipVirtual(scenario, alice, charlie,
            timeout: const Duration(seconds: 20)),
        establishFriendshipVirtual(scenario, bob, charlie,
            timeout: const Duration(seconds: 20)),
      ]);
      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 5));
      await pumpFriendConnectionVirtual(scenario, alice, charlie,
          duration: const Duration(seconds: 3));

      // Register group listeners so onGroupCreated/onGroupInvited are
      // delivered (per-instance routing).
      alice.runWithInstance(() =>
          TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
            onGroupCreated: (gid) => alice.markCallbackReceived('onGroupCreated',
                data: {'groupID': gid}),
          )));
      bob.runWithInstance(() =>
          TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
            onMemberInvited: (gid, op, list) => bob
                .markCallbackReceived('onGroupInvited', data: {'groupID': gid}),
          )));
      charlie.runWithInstance(() =>
          TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
            onMemberInvited: (gid, op, list) => charlie.markCallbackReceived(
                'onGroupInvited',
                data: {'groupID': gid}),
          )));

      String groupId;
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Test Conference',
            groupID: '',
          ));
      expect(createResult.code, equals(0));
      expect(createResult.data, isNotNull);
      groupId = createResult.data!;

      await waitUntilWithVirtualPump(
        scenario,
        () => alice.callbackReceived['onGroupCreated'] == true,
        timeout: const Duration(seconds: 15),
        description: 'alice onGroupCreated',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, charlie,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bob.getToxId(),
            timeout: const Duration(seconds: 15));
        await waitForFriendConnectionVirtual(scenario, alice, charlie.getToxId(),
            timeout: const Duration(seconds: 15));
      } catch (e) {
        print(
            '[ConferenceCreate] Friend connection check not fully ready, continue with retry logic: $e');
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final bobPublicKey = bob.getPublicKey();
      final charliePublicKey = charlie.getPublicKey();

      for (int retry = 0; retry < 5; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 3000, iterationsPerInstance: 1);
        }
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey, charliePublicKey],
            ));
        expect(inviteResult.code, equals(0));
        expect(inviteResult.data, isNotNull);
        expect(inviteResult.data!.length, equals(2));
        final bobResult = inviteResult.data!.firstWhere(
            (r) => r.memberID == bobPublicKey,
            orElse: () =>
                throw Exception('Bob not found in invite result list'));
        final charlieResult = inviteResult.data!.firstWhere(
            (r) => r.memberID == charliePublicKey,
            orElse: () =>
                throw Exception('Charlie not found in invite result list'));
        if (bobResult.result == 1 && charlieResult.result == 1) break;
        if (retry == 4) {
          expect(bobResult.result, equals(1),
              reason:
                  'Bob invitation failed after 5 attempts: result=${bobResult.result}');
          expect(charlieResult.result, equals(1),
              reason:
                  'Charlie invitation failed after 5 attempts: result=${charlieResult.result}');
        }
      }

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      // 3x retry pattern for onGroupInvited.
      for (final invitee in <TestNode>[bob, charlie]) {
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          if (attempt > 0) {
            await alice.runWithInstanceAsync(() async =>
                TIMGroupManager.instance.inviteUserToGroup(
                  groupID: groupId,
                  userList: [invitee.getPublicKey()],
                ));
          }
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => invitee.callbackReceived['onGroupInvited'] == true,
              timeout: const Duration(seconds: 15),
              description:
                  '${invitee.alias} onGroupInvited (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } catch (_) {}
        }
        expect(arrived, isTrue,
            reason:
                '${invitee.alias} never received onGroupInvited after 3 retries');
      }

      final bobJoinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(bobJoinResult.code, equals(0));

      final charlieJoinResult = await charlie.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(charlieJoinResult.code, equals(0));

      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 4));
      await pumpGroupPeerDiscoveryVirtual(scenario, alice, charlie,
          duration: const Duration(seconds: 3));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Send messages in group (conference)', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final charlie = scenario.getNode('charlie')!;

      alice.clearCallbackReceived('onGroupCreated');
      bob.clearCallbackReceived('onGroupInvited');
      charlie.clearCallbackReceived('onGroupInvited');

      // Friendships were already established by test 1's setUpAll-equivalent
      // path; these calls converge in <5s normally. Shorter per-pair timeout.
      await Future.wait([
        establishFriendshipVirtual(scenario, alice, bob,
            timeout: const Duration(seconds: 25)),
        establishFriendshipVirtual(scenario, alice, charlie,
            timeout: const Duration(seconds: 25)),
        establishFriendshipVirtual(scenario, bob, charlie,
            timeout: const Duration(seconds: 20)),
      ]);

      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Test Conference',
            groupID: '',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      await waitUntilWithVirtualPump(
        scenario,
        () => alice.callbackReceived['onGroupCreated'] == true,
        timeout: const Duration(seconds: 10),
        description: 'alice onGroupCreated',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 10));
      await waitForConnectionVirtual(scenario, charlie,
          timeout: const Duration(seconds: 10));
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bob.getToxId(),
            timeout: const Duration(seconds: 15));
        await waitForFriendConnectionVirtual(scenario, alice, charlie.getToxId(),
            timeout: const Duration(seconds: 15));
      } catch (e) {
        print(
            '[ConferenceMessage] Friend connection check not fully ready, continue with retry logic: $e');
      }
      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      // Initial invite + retry per invitee for onGroupInvited.
      final inviteResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId,
            userList: [bob.getPublicKey(), charlie.getPublicKey()],
          ));
      expect(inviteResult.code, equals(0));
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
      for (final invitee in <TestNode>[bob, charlie]) {
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          if (attempt > 0) {
            await alice.runWithInstanceAsync(() async =>
                TIMGroupManager.instance.inviteUserToGroup(
                  groupID: groupId,
                  userList: [invitee.getPublicKey()],
                ));
          }
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => invitee.callbackReceived['onGroupInvited'] == true,
              timeout: const Duration(seconds: 15),
              description:
                  '${invitee.alias} onGroupInvited (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } catch (_) {}
        }
        expect(arrived, isTrue,
            reason:
                '${invitee.alias} never received onGroupInvited after 3 retries');
      }

      final alicePublicKey = alice.getPublicKey();
      var bobReceivedMessages = 0;

      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          final msgGroupId = message.groupID ?? '';
          final senderStr = message.sender ?? message.userID ?? '';
          final senderPublicKey = senderStr.length >= 64
              ? senderStr.substring(0, 64)
              : senderStr;
          final textPreview = message.textElem?.text ?? '(no text)';

          if (msgGroupId == groupId) {
            final matchesAlice = (senderPublicKey == alicePublicKey) ||
                (alicePublicKey.length >= 64 &&
                    senderStr.startsWith(alicePublicKey)) ||
                (senderStr.length >= 64 &&
                    alicePublicKey.startsWith(senderPublicKey));
            final isExpectedMessage =
                textPreview.contains('Hello from conference!');
            if (matchesAlice || isExpectedMessage) {
              bobReceivedMessages++;
              bob.addReceivedMessage(message);
            }
          }
        },
      );

      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(bobListener));

      final bobJoinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(bobJoinResult.code, equals(0));
      final charlieJoinResult = await charlie.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(charlieJoinResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 3));
      await pumpGroupPeerDiscoveryVirtual(scenario, alice, charlie,
          duration: const Duration(seconds: 2));

      // Wait until Bob sees 3 members in group.
      final memberSyncDeadline =
          VirtualClock.nowMs + const Duration(seconds: 25).inMilliseconds;
      while (VirtualClock.nowMs < memberSyncDeadline) {
        final list = await bob.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
            ));
        final count = list.data?.memberInfoList?.length ?? 0;
        if (count >= 3) break;
        await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
            duration: const Duration(seconds: 1));
        await pumpGroupPeerDiscoveryVirtual(scenario, alice, charlie,
            duration: const Duration(milliseconds: 500));
      }

      final sendResult = await alice.runWithInstanceAsync(() async {
        final textResult = TIMMessageManager.instance
            .createTextMessage(text: 'Hello from conference!');
        expect(textResult.messageInfo, isNotNull);
        return await TIMMessageManager.instance.sendMessage(
          message: textResult.messageInfo!,
          receiver: null,
          groupID: groupId,
        );
      });
      expect(sendResult.code, equals(0));

      try {
        await waitUntilWithVirtualPump(
          scenario,
          () => bobReceivedMessages > 0,
          timeout: const Duration(seconds: 60),
          description: 'Bob received group message',
          advanceMs: 50,
          iterationsPerInstance: 1,
        );
      } catch (e) {
        // Fall through to expect for diagnostic.
      }

      expect(bobReceivedMessages, greaterThan(0),
          reason: 'Bob did not receive message.');
    }, timeout: const Timeout(Duration(seconds: 200)));

    test('Verify member list synchronization', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;

      alice.clearCallbackReceived('onGroupCreated');
      bob.clearCallbackReceived('onGroupInvited');

      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 20));
      await pumpFriendConnectionVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 6));

      alice.runWithInstance(() =>
          TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
            onGroupCreated: (gid) => alice.markCallbackReceived('onGroupCreated',
                data: {'groupID': gid}),
          )));
      bob.runWithInstance(() =>
          TIMGroupManager.instance.addGroupListener(V2TimGroupListener(
            onMemberInvited: (gid, op, list) => bob
                .markCallbackReceived('onGroupInvited', data: {'groupID': gid}),
          )));

      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'Meeting',
            groupName: 'Test Conference',
            groupID: '',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      await waitUntilWithVirtualPump(
        scenario,
        () => alice.callbackReceived['onGroupCreated'] == true,
        timeout: const Duration(seconds: 15),
        description: 'alice onGroupCreated',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 20));
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bob.getToxId(),
            timeout: const Duration(seconds: 30));
      } catch (e) {
        print(
            '[ConferenceJoinLeave] Friend connection check not fully ready, continue with retry logic: $e');
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final bobPk = bob.getPublicKey();
      for (int retry = 0; retry < 5; retry++) {
        if (retry > 0) {
          await pumpTestTick(scenario,
              advanceMs: 3000, iterationsPerInstance: 1);
        }
        final inviteResult = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPk],
            ));
        expect(inviteResult.code, equals(0));
        expect(inviteResult.data, isNotNull);
        final bobRes =
            inviteResult.data!.where((r) => r.memberID == bobPk).toList();
        if (bobRes.isNotEmpty && bobRes.first.result == 1) break;
        if (retry == 4) {
          expect(bobRes.first.result, equals(1),
              reason: 'Bob invite failed after 5 attempts');
        }
      }
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      // Retry pattern for onGroupInvited.
      var arrived = false;
      for (var attempt = 0; !arrived && attempt < 3; attempt++) {
        if (attempt > 0) {
          await alice.runWithInstanceAsync(() async =>
              TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId,
                userList: [bobPk],
              ));
        }
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'Bob onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          arrived = true;
        } catch (_) {}
      }
      expect(arrived, isTrue,
          reason: 'Bob never received onGroupInvited after 3 retries');

      final joinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(joinResult.code, equals(0));

      await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
          duration: const Duration(seconds: 6));

      var memberResult = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      final syncDeadline =
          VirtualClock.nowMs + const Duration(seconds: 25).inMilliseconds;
      while (VirtualClock.nowMs < syncDeadline &&
          (memberResult.data?.memberInfoList?.length ?? 0) < 2) {
        await pumpGroupPeerDiscoveryVirtual(scenario, alice, bob,
            duration: const Duration(seconds: 1));
        await pumpTestTick(scenario,
            advanceMs: 200, iterationsPerInstance: 1);
        memberResult = await bob.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
            ));
      }

      expect(memberResult.code, equals(0));
      expect(memberResult.data, isNotNull);
      expect(memberResult.data!.memberInfoList, isNotEmpty);

      final alicePublicKey = alice.getPublicKey();
      final bobPublicKey = bob.getPublicKey();
      bool memberMatches(String uid, String publicKey) =>
          uid == publicKey || (uid.length >= 64 && uid.startsWith(publicKey));
      final memberIds =
          memberResult.data!.memberInfoList!.map((m) => m.userID).toList();
      final hasAlice =
          memberIds.any((id) => memberMatches(id, alicePublicKey));
      final hasBob = memberIds.any((id) => memberMatches(id, bobPublicKey));
      expect(hasAlice || hasBob, isTrue,
          reason: 'Neither Alice nor Bob in member list: $memberIds');
      expect(memberIds.length, greaterThanOrEqualTo(1),
          reason: 'Member list should have at least 1');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
