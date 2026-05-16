/// Many Nodes Test — virtual-clock variant
///
/// Mirrors scenario_many_nodes_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Many Nodes Tests (Virtual)', () {
    late TestScenario scenario;
    late List<TestNode> nodes;

    setUpAll(() async {
      await setupTestEnvironment();
      await VirtualClock.enableEarly();
      final aliases = List.generate(5, (i) => 'node$i');
      scenario = await createTestScenario(aliases);
      nodes = aliases.map((alias) => scenario.getNode(alias)!).toList();

      await scenario.initAllNodes();
      await VirtualClock.enableForScenario(scenario);

      await Future.wait(nodes.map((node) => node.login()));

      await waitUntil(() => nodes.every((node) => node.loggedIn));

      for (final node in nodes) {
        node.enableAutoAccept();
      }

      await configureLocalBootstrapVirtual(scenario);

      await Future.wait(
        nodes.map((node) => waitForConnectionVirtual(scenario, node,
            timeout: const Duration(seconds: 45))),
      );
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Multiple nodes communication', () async {
      await Future.wait([
        for (int i = 1; i < nodes.length; i++)
          establishFriendshipVirtual(scenario, nodes[0], nodes[i],
              timeout: const Duration(seconds: 90)),
      ]);
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final createResult = await nodes[0].runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Many Nodes Group',
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed: ${createResult.code}');
      final groupId = createResult.data!;

      for (int i = 1; i < nodes.length; i++) {
        final peer = nodes[i];
        final peerPublicKey = peer.getPublicKey();
        peer.clearCallbackReceived('onGroupInvited');

        // 3x retry pattern for onGroupInvited.
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          if (attempt > 0) {
            // Re-fire the invite.
          }
          final inviteResult = await nodes[0].runWithInstanceAsync(() async =>
              TIMGroupManager.instance.inviteUserToGroup(
                groupID: groupId,
                userList: [peerPublicKey],
              ));
          expect(inviteResult.code, equals(0),
              reason:
                  'inviteUserToGroup(node$i) failed: ${inviteResult.code}');
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => peer.callbackReceived['onGroupInvited'] == true,
              timeout: const Duration(seconds: 20),
              description: 'node$i onGroupInvited (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } catch (_) {}
        }
        expect(arrived, isTrue,
            reason: 'node$i never received onGroupInvited after 3 retries');

        await pumpTestTick(scenario,
            advanceMs: 500, iterationsPerInstance: 1);
        final joinGroupId =
            peer.getLastCallbackGroupId('onGroupInvited') ?? groupId;
        final joinResult = await peer.runWithInstanceAsync(() async =>
            TIMManager.instance.joinGroup(
              groupID: joinGroupId,
              message: 'Hello from node$i',
            ));
        expect(joinResult.code, equals(0),
            reason: 'node$i joinGroup failed: ${joinResult.code}');
      }

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      final sendResult = await nodes[0].runWithInstanceAsync(() async {
        final messageResult =
            TIMMessageManager.instance.createTextMessage(text: 'Hello from node0');
        return TIMMessageManager.instance.sendMessage(
          groupID: null,
          message: messageResult.messageInfo!,
          receiver: nodes[1].getToxId(),
          onlineUserOnly: false,
        );
      });
      expect(sendResult.code, equals(0));

      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);

      final memberListResult = await nodes[0].runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(memberListResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 420)));
  });
}
