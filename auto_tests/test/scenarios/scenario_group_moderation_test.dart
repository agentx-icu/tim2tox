// Group Moderation Test — virtual-clock variant
//
// Mirrors scenario_group_moderation_test.dart 1:1 but drives the harness via
// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// Used as the gold standard for the virtual-mode harness while we migrate
// the rest of Phase 4 / 10 / 12.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_role_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_role.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
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
      // Refresh the per-instance flag inherited from initAllNodes' early lease.
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
      await establishFriendshipVirtual(scenario, founder, member1);
      await establishFriendshipVirtual(scenario, founder, member2);
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

      // Nobody may change the founder's role — not even a moderator (member1
      // is one now). toxcore refuses with TOX_ERR_GROUP_SET_ROLE_PERMISSIONS,
      // which must reach the caller as ERR_SVR_GROUP_PERMISSION_DENY (10007):
      // it used to be the generic invalid-parameter code, so the UI could
      // only say "set failed" instead of "no permission".
      String? founderKey;
      for (var attempt = 0; attempt < 10 && founderKey == null; attempt++) {
        final list = await member1.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.getGroupMemberList(
              groupID: ctx.groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
              count: 100,
            ));
        for (final m in list.data?.memberInfoList ?? const []) {
          if (m.role == GroupMemberRoleType.V2TIM_GROUP_MEMBER_ROLE_OWNER) {
            founderKey = m.userID;
          }
        }
        if (founderKey == null) {
          await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 5);
        }
      }
      expect(founderKey, isNotNull,
          reason: 'member1 never saw the founder row in its member list');
      final demoteFounder = await member1.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.setGroupMemberRole(
            groupID: ctx.groupId,
            userID: founderKey!,
            role: GroupMemberRoleTypeEnum.V2TIM_GROUP_MEMBER_ROLE_MEMBER,
          ));
      expect(demoteFounder.code, equals(10007), // ERR_SVR_GROUP_PERMISSION_DENY
          reason: 'changing the founder\'s role must be refused as no '
              'permission, got ${demoteFounder.code} ${demoteFounder.desc}');
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

    test('Mute group member: timed expiry, early unmute, moderators refused',
        () async {
      final ctx = await _prepareGroupWithMemberVirtual(
          scenario, founder, member1,
          label: 'mute');

      // A mute is the NGC OBSERVER role: toxcore refuses the member's own
      // sends, so "can member1 post to the group" is the observable state.
      var probe = 0;
      Future<int> memberSendCode() => member1.runWithInstanceAsync(() async {
            final created = TIMMessageManager.instance
                .createTextMessage(text: 'mute probe ${probe++}');
            final result = await TIMMessageManager.instance.sendMessage(
              message: created.messageInfo!,
              receiver: null,
              groupID: ctx.groupId,
              onlineUserOnly: false,
            );
            return result.code;
          });
      Future<V2TimCallback> mute(int seconds) =>
          founder.runWithInstanceAsync(() async =>
              TIMGroupManager.instance.muteGroupMember(
                groupID: ctx.groupId,
                userID: ctx.memberUserID,
                seconds: seconds,
              ));
      // In wall mode pumpTestTick only moves the Dart-side counter; sleep for
      // real so the native steady_clock deadline actually passes.
      Future<void> tick(int ms) => pumpTestTick(scenario,
          advanceMs: ms,
          iterationsPerInstance: 5,
          wallSleep: VirtualClock.enabled
              ? const Duration(milliseconds: 5)
              : Duration(milliseconds: ms));
      Future<void> waitForSendable(bool sendable, String what,
          {int budgetMs = 10000}) async {
        final deadline = VirtualClock.nowMs + budgetMs;
        while (true) {
          final code = await memberSendCode();
          if ((code == 0) == sendable) return;
          if (VirtualClock.nowMs >= deadline) {
            fail('$what: member1 send code=$code after ${budgetMs}ms');
          }
          await tick(250);
        }
      }

      await waitForSendable(true, 'baseline (group synced)');

      // 1) Timed mute: muted now, still muted just before the deadline,
      //    lifted by the founder's client once it passes.
      const muteSeconds = 10;
      final mutedAt = VirtualClock.nowMs;
      final muteResult = await mute(muteSeconds);
      expect(muteResult.code, equals(0),
          reason: 'muteGroupMember failed: ${muteResult.desc}');
      await waitForSendable(false, 'mute takes effect', budgetMs: 5000);
      while (VirtualClock.nowMs - mutedAt < (muteSeconds - 2) * 1000) {
        await tick(500);
      }
      expect(await memberSendCode(), isNot(equals(0)),
          reason: 'member must stay muted until the deadline');
      while (VirtualClock.nowMs - mutedAt < (muteSeconds + 1) * 1000) {
        await tick(500);
      }
      await waitForSendable(true, 'timed mute expires');

      // 2) seconds == 0 lifts a (long) mute early.
      expect((await mute(3600)).code, equals(0));
      await waitForSendable(false, 'long mute takes effect', budgetMs: 5000);
      final unmuteResult = await mute(0);
      expect(unmuteResult.code, equals(0),
          reason: 'unmute (seconds: 0) failed: ${unmuteResult.desc}');
      await waitForSendable(true, 'early unmute', budgetMs: 5000);

      // 3) A moderator cannot be muted (OBSERVER would demote them and an
      //    unmute could never restore the role).
      V2TimCallback? promote;
      for (var attempt = 0; attempt < 3; attempt++) {
        promote = await founder.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.setGroupMemberRole(
              groupID: ctx.groupId,
              userID: ctx.memberUserID,
              role: GroupMemberRoleTypeEnum.V2TIM_GROUP_MEMBER_ROLE_ADMIN,
            ));
        if (promote?.code == 0) break;
        await tick(1000);
      }
      expect(promote?.code, equals(0),
          reason: 'setGroupMemberRole(ADMIN) failed: ${promote?.desc}');
      final muteModerator = await mute(60);
      expect(muteModerator.code, equals(7013),  // ERR_SDK_INTERFACE_NOT_SUPPORT
          reason: 'muting a moderator must be refused, got '
              '${muteModerator.code} ${muteModerator.desc}');
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('Transfer group owner', () async {
      final ctx = await _prepareGroupWithMemberVirtual(
          scenario, founder, member1,
          label: 'transfer');
      final transferResult = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.transferGroupOwner(
            groupID: ctx.groupId,
            userID: ctx.memberUserID,
          ));
      // NGC cannot hand over the founder role (tox_group_set_role rejects
      // FOUNDER as a target). The Dart adapter routes this through
      // DartSetGroupInfo, which ignores the owner field; native's own
      // TransferGroupOwner reports the toxcore refusal. Either way this must
      // NOT read as success — that is what let the UI show a transfer that
      // never happened.
      expect(transferResult.code, isNot(equals(0)),
          reason: 'transferGroupOwner must report that Tox cannot transfer ownership');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
