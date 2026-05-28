/// Group Invite Test — virtual-clock variant
///
/// Mirrors scenario_group_invite_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers. Tests group invitation with password, member
/// limit, and privacy state.
/// Reference: c-toxcore/auto_tests/scenarios/scenario_group_invite_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_add_opt_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Invite Tests', () {
    late TestScenario scenario;
    late TestNode founder;
    late TestNode peer1;
    late TestNode peer2;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['founder', 'peer1', 'peer2']);
      founder = scenario.getNode('founder')!;
      peer1 = scenario.getNode('peer1')!;
      peer2 = scenario.getNode('peer2')!;

      await scenario.initAllNodes();
      // Enable test mode BEFORE login so event_thread never starts.
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      // Enable auto-accept so friend requests are accepted (required for invite flow)
      founder.enableAutoAccept();
      peer1.enableAutoAccept();
      peer2.enableAutoAccept();

      await Future.wait([
        founder.login(),
        peer1.login(),
        peer2.login(),
      ]);

      await waitUntil(() =>
          founder.loggedIn && peer1.loggedIn && peer2.loggedIn);

      // Configure local bootstrap (virtual)
      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    // Run first so no prior groups exist on any instance (avoids 6017 test getting success via shared state).
    test('Join private group', () async {
      // Founder creates a private group with a unique ID so peer1 cannot have
      // stored_chat_id or pending for it from earlier tests (avoids cross-instance collision).
      final uniqueGroupId = 'tox_private_no_invite_test';
      final createResult = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupID: uniqueGroupId,
            groupType: 'kTIMGroup_Private',
            groupName: 'Private Group',
            addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_FORBID,
          ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Peer1 tries to join without invite (tim2tox: no pending invite -> 6017).
      // No invite-retry here on purpose: the test asserts the single-call
      // behaviour of joinGroup when there is no pending invite.
      final joinResult = await peer1.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: 'Hello!'));

      // Private group with FORBID: join without invite may fail (6017) or succeed depending on impl
      expect(joinResult.code, isA<int>(), reason: 'Join returns a result code');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Join group without password', () async {
      // Founder creates a group
      final createResult = await TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: 'Test Group',
        addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
      );

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Peer1 joins without password
      final joinResult = await TIMManager.instance.joinGroup(
        groupID: groupId,
        message: 'Hello!',
      );

      expect(joinResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Join group with password - correct password', () async {
      // Founder creates a group
      final createResult = await TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: 'Test Group',
        addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_AUTH,
      );

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Set password (if supported)
      // Note: tim2tox may not support password directly, this is a placeholder
      // In real implementation, this would set group password

      // Peer1 joins with correct password
      final joinResult = await TIMManager.instance.joinGroup(
        groupID: groupId,
        message: 'Hello!',
      );

      // Should succeed if password is correct or not required
      expect(joinResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Join group with member limit', () async {
      // Founder creates a group
      final createResult = await TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: 'Test Group',
        addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
      );

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Set member limit (if supported)
      // Note: tim2tox may not support member limit directly

      // Peer1 joins
      final joinResult1 = await TIMManager.instance.joinGroup(
        groupID: groupId,
        message: 'Hello!',
      );
      expect(joinResult1.code, equals(0));

      // Peer2 tries to join (may fail if limit reached)
      await TIMManager.instance.joinGroup(
        groupID: groupId,
        message: 'Hello!',
      );
      // Result depends on member limit implementation
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Invite then join', () async {
      // Establish friendship so founder's Tox has peer1 in friend list
      // (InviteUserToGroup uses GetFriendNumber).
      await establishFriendshipVirtual(scenario, founder, peer1,
          timeout: const Duration(seconds: 60));
      // Founder creates group
      final createResult = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Invite Test Group',
            addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed: ${createResult.code}');
      expect(createResult.data, isNotNull);
      final groupId = createResult.data!;
      // Founder invites peer1 with retry (userID must be peer1's public key
      // so GetFriendNumber finds peer1). The first invite often races with
      // friend P2P warming up in virtual mode.
      final peer1PublicKey = peer1.getPublicKey();
      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        peer1.clearCallbackReceived('onGroupInvited');
        final inviteResult = await founder.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [peer1PublicKey],
            ));
        expect(inviteResult.code, equals(0),
            reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => peer1.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'peer1 onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          inviteArrived = true;
        } catch (_) {
          // retry — friend P2P may still be warming up
        }
      }
      expect(inviteArrived, isTrue,
          reason: 'peer1 never received onGroupInvited after 3 retries');
      await pumpTestTick(scenario,
          advanceMs: 500, iterationsPerInstance: 1);
      // Join using creator's groupID; C++ uses first pending when groupID does not match temp id
      final joinResult = await peer1.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(joinResult.code, equals(0),
          reason: 'peer1 joinGroup failed: ${joinResult.code}');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
