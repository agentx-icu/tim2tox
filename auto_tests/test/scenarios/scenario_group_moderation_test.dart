// Group Moderation Test — virtual-clock variant
//
// Mirrors scenario_group_moderation_test.dart 1:1 but drives the harness via
// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// Used as the gold standard for the virtual-mode harness while we migrate
// the rest of Phase 4 / 10 / 12.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_role_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_add_opt_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_callback.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

/// Same flow as moderation_test._prepareGroupWithMember but using
/// pumpTestTick + waitUntilWithVirtualPump in place of wall-clock waits.
Future<({String groupId, String memberUserID})> _prepareGroupWithMemberVirtual(
  TestScenario scenario,
  TestNode founder,
  TestNode member, {
  required String label,
}) async {
  final createResult = await founder.runWithInstanceAsync(() async =>
      TIMGroupManager.instance.createGroup(
        groupType: 'kTIMGroup_Private',
        groupName: label,
        addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
      ));
  expect(createResult.code, equals(0),
      reason: 'createGroup($label) failed: ${createResult.desc}');
  final groupId = createResult.data!;

  final memberPublicKey = member.getPublicKey();
  // Retry invite + wait: inviteUserToGroup returns code=0 even when the
  // underlying tox_group_invite_friend packet was dropped (friend status=NONE),
  // and the first invite often races with friend P2P bring-up in virtual mode.
  var inviteArrived = false;
  for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
    member.clearCallbackReceived('onGroupInvited');
    final inviteResult = await founder.runWithInstanceAsync(() async =>
        TIMGroupManager.instance.inviteUserToGroup(
          groupID: groupId,
          userList: [memberPublicKey],
        ));
    expect(inviteResult.code, equals(0),
        reason: 'inviteUserToGroup($label) failed: ${inviteResult.desc}');
    try {
      await waitUntilWithVirtualPump(
        scenario,
        () => member.callbackReceived['onGroupInvited'] == true,
        timeout: const Duration(seconds: 15),
        description: '${member.alias} onGroupInvited for $label (attempt ${attempt + 1})',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );
      inviteArrived = true;
    } catch (_) {
      // Retry: friend P2P may not have been ONLINE for the first attempt.
    }
  }
  expect(inviteArrived, isTrue,
      reason: '${member.alias} never received onGroupInvited for $label after 3 retries');
  // Settle ~300ms virtual so pending invite -> chat_id mapping completes
  // before joinGroup is called.
  await pumpTestTick(scenario, advanceMs: 300, iterationsPerInstance: 1);

  final joinResult = await member.runWithInstanceAsync(() async =>
      TIMManager.instance.joinGroup(groupID: groupId, message: ''));
  expect(joinResult.code, equals(0),
      reason: 'joinGroup($label) failed: ${joinResult.desc}');

  final memberUserID = await waitUntilFounderSeesMemberInGroupVirtual(
    scenario,
    founder,
    member,
    groupId,
    timeout: const Duration(seconds: 30),
  );
  expect(memberUserID, isNotNull,
      reason: 'Founder did not see ${member.alias} in group $label');

  return (groupId: groupId, memberUserID: memberUserID!);
}

void main() {
  group('Group Moderation Tests', () {
    late TestScenario scenario;
    late TestNode founder;
    late TestNode member1;
    late TestNode member2;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['founder', 'member1', 'member2']);
      founder = scenario.getNode('founder')!;
      member1 = scenario.getNode('member1')!;
      member2 = scenario.getNode('member2')!;

      await scenario.initAllNodes();
      // Enable test mode BEFORE login so event_thread never starts.
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      // Logins still complete synchronously from Dart's POV (loggedIn flag
      // flips in the Dart bookkeeping when InitSDK returns); no virtual time
      // advance is required for them to "finish".
      await Future.wait([
        founder.login(),
        member1.login(),
        member2.login(),
      ]);
      await waitUntil(
          () => founder.loggedIn && member1.loggedIn && member2.loggedIn);

      // Full-mesh bootstrap with virtual-time DHT-connect wait.
      await configureLocalBootstrapVirtual(scenario);
      // Both friendships in parallel — virtual clock is global so both halves
      // step in lockstep through the same pumpTestTick.
      await Future.wait([
        establishFriendshipVirtual(scenario, founder, member1),
        establishFriendshipVirtual(scenario, founder, member2),
      ]);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Set group member role', () async {
      final ctx = await _prepareGroupWithMemberVirtual(
          scenario, founder, member1,
          label: 'role');
      // Retry setGroupMemberRole: Tox may list the peer slightly after
      // getGroupMemberList sees it.
      V2TimCallback? setRoleResult;
      for (var attempt = 0; attempt < 3; attempt++) {
        setRoleResult = await founder.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.setGroupMemberRole(
              groupID: ctx.groupId,
              userID: ctx.memberUserID,
              role: GroupMemberRoleTypeEnum.V2TIM_GROUP_MEMBER_ROLE_ADMIN,
            ));
        if (setRoleResult?.code == 0) break;
        await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 1);
      }
      expect(setRoleResult?.code, equals(0),
          reason: 'setGroupMemberRole failed: ${setRoleResult?.desc}');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Kick group member', () async {
      final ctx = await _prepareGroupWithMemberVirtual(
          scenario, founder, member1,
          label: 'kick');
      final kickResult = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.kickGroupMember(
            groupID: ctx.groupId,
            memberList: [ctx.memberUserID],
          ));
      expect(kickResult.code, equals(0),
          reason: 'kickGroupMember failed: ${kickResult.desc}');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Mute group member', () async {
      final ctx = await _prepareGroupWithMemberVirtual(
          scenario, founder, member1,
          label: 'mute');
      final muteResult = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.muteGroupMember(
            groupID: ctx.groupId,
            userID: ctx.memberUserID,
            seconds: 3600,
          ));
      expect(muteResult.code, equals(0),
          reason: 'muteGroupMember failed: ${muteResult.desc}');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Transfer group owner', () async {
      final ctx = await _prepareGroupWithMemberVirtual(
          scenario, founder, member1,
          label: 'transfer');
      final transferResult = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.transferGroupOwner(
            groupID: ctx.groupId,
            userID: ctx.memberUserID,
          ));
      expect(transferResult.code, equals(0),
          reason: 'transferGroupOwner failed: ${transferResult.desc}');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
