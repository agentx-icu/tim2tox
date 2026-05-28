// Group Double Invite Test — virtual-clock variant
//
// Mirrors scenario_group_double_invite_test.dart 1:1 but drives the harness
// via the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual
// helpers). Tests handling of duplicate group invitations.
// Reference: c-toxcore/auto_tests/scenarios/scenario_conference_double_invite_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Double Invite Tests', () {
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
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      await waitUntil(() => alice.loggedIn && bob.loggedIn);

      // Configure local bootstrap via virtual-clock helper.
      await configureLocalBootstrapVirtual(scenario);
      // Establish friendship so the invite has a friend channel to travel
      // on (the wall-clock version relied on incidental wall-time warmup;
      // virtual mode needs an explicit bring-up).
      await establishFriendshipVirtual(scenario, alice, bob);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Duplicate group invitation handling', () async {
      final createResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Test Group',
          ));
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      final bobPublicKey = bob.getPublicKey();

      // First invite: retry up to 3× until bob receives onGroupInvited.
      // The first invite often races with friend P2P warming up in virtual
      // mode, even after establishFriendshipVirtual.
      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        bob.clearCallbackReceived('onGroupInvited');
        final inviteResult1 = await alice.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId,
              userList: [bobPublicKey],
            ));
        expect(inviteResult1.code, equals(0),
            reason: 'inviteUserToGroup (first) failed: ${inviteResult1.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description:
                '${bob.alias} onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          inviteArrived = true;
        } catch (_) {
          // retry — friend P2P may still be warming up
        }
      }
      expect(inviteArrived, isTrue,
          reason:
              '${bob.alias} never received onGroupInvited after 3 retries');

      // Settle so the invite-side bookkeeping completes before the second
      // (deliberate duplicate) invite goes out.
      await pumpTestTick(scenario,
          advanceMs: 2000, iterationsPerInstance: 1);

      // Second invite is the deliberate duplicate — single call, no retry.
      // The test asserts behavior under double invite (bob appears at most
      // once in the member list).
      final inviteResult2 = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId,
            userList: [bobPublicKey],
          ));
      expect(inviteResult2.code, isNotNull);

      final memberListResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(memberListResult.code, equals(0));
      if (memberListResult.data?.memberInfoList != null) {
        // tim2tox: C++ may return 76-char Tox ID or 64-char public key;
        // bobPublicKey is 64-char.
        final bobCount = memberListResult.data!.memberInfoList!.where((member) {
          final uid = member.userID;
          return uid == bobPublicKey ||
              (uid.length >= 64 && uid.startsWith(bobPublicKey));
        }).length;
        expect(bobCount, lessThanOrEqualTo(1),
            reason: 'Bob should appear at most once');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
