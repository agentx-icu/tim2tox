// Group search by NAME, from a member that joined rather than created
// (plan item L3).
//
// toxee's global search delegates the "groups" section to
// V2TIMGroupManager.searchGroups, which is NOT on the Platform path: it runs
// through the binary-replacement symbol DartSearchGroups into the native
// V2TIMGroupManagerImpl::SearchGroups. That implementation matches a keyword
// against the name cached in `group_info_`, and a member that JOINED a group
// only has the placeholder EnsureGroupInfoExists seeds (`groupName = groupID`)
// until something else fills the cache — so the real name never matches and
// the group only surfaces through the conversation fallback section, which is
// exactly the product debt PR #80 recorded.
//
// The live NGC name is available the whole time (ToxManager::getGroupName), so
// this pins that searching a joined group by its REAL name finds it.
//
// Mode-aware: wall-clock by default, RUN_VIRTUAL=1 under the virtual clock.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_add_opt_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_search_param.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

const _groupName = 'Utah Data Center';

void main() {
  group('Group Search By Name Tests', () {
    late TestScenario scenario;
    late TestNode founder;
    late TestNode member;
    String? groupId;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['founder', 'member']);
      founder = scenario.getNode('founder')!;
      member = scenario.getNode('member')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([founder.login(), member.login()]);
      await waitUntil(
        () => founder.loggedIn && member.loggedIn,
        timeout: const Duration(seconds: 15),
        description: 'both nodes logged in',
      );
      await configureLocalBootstrapVirtual(scenario);

      founder.enableAutoAccept();
      member.enableAutoAccept();
      await establishFriendshipVirtual(scenario, founder, member,
          timeout: const Duration(seconds: 60));

      final createResult = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: _groupName,
            addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed: ${createResult.desc}');
      groupId = createResult.data;
      expect(groupId, isNotNull);

      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 5; attempt++) {
        member.clearCallbackReceived('onGroupInvited');
        final inviteResult = await founder.runWithInstanceAsync(() async =>
            TIMGroupManager.instance.inviteUserToGroup(
              groupID: groupId!,
              userList: [member.getPublicKey()],
            ));
        expect(inviteResult.code, equals(0),
            reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => member.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          inviteArrived = true;
        } on Exception {
          // Friend P2P may still be warming up — the loop retries.
        }
      }
      expect(inviteArrived, isTrue,
          reason: 'member never received onGroupInvited after 5 retries');
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final joinResult = await member.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
      expect(joinResult.code, equals(0),
          reason: 'member joinGroup failed: ${joinResult.code}');
      final inGroup = await waitUntilFounderSeesMemberInGroupVirtual(
        scenario,
        founder,
        member,
        groupId!,
        timeout: const Duration(seconds: 25),
      );
      expect(inGroup, isNotNull,
          reason: 'founder must see the member before searching');
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test('the creator finds its own group by name', () async {
      final res = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.searchGroups(
            searchParam: V2TimGroupSearchParam(keywordList: ['Utah']),
          ));
      expect(res.code, equals(0), reason: 'searchGroups failed: ${res.desc}');
      expect(res.data?.map((g) => g.groupID), contains(groupId),
          reason: 'the creator caches the name at CreateGroup, so this leg '
              'passing alone proves nothing about a joiner');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a member that JOINED finds the group by its real name', () async {
      // The member must ALSO have created a group of its own first. The
      // candidate set used to be "groups_ (creations) unless it is empty, else
      // the manager's mapping", so a node that had created anything searched
      // only its own creations and never saw a joined group — the empty-groups_
      // case was the only reason this ever worked. Creating here keeps that
      // regression pinned.
      final ownGroup = await member.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Member Own Room',
            addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
          ));
      expect(ownGroup.code, equals(0),
          reason: 'member createGroup failed: ${ownGroup.desc}');

      final res = await member.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.searchGroups(
            searchParam: V2TimGroupSearchParam(keywordList: ['Utah']),
          ));
      expect(res.code, equals(0), reason: 'searchGroups failed: ${res.desc}');
      // ignore: avoid_print
      print('[l3-search] member results: '
          '${res.data?.map((g) => "${g.groupID}=${g.groupName}").toList()}');
      expect(res.data?.map((g) => g.groupID), contains(groupId),
          reason: 'a joined group must be findable by the name every member '
              'can see on the live NGC group, not only by its id');
      final found =
          res.data!.firstWhere((g) => g.groupID == groupId);
      expect(found.groupName, _groupName,
          reason: 'the result must carry the real name, not the groupID '
              'placeholder EnsureGroupInfoExists seeds');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
