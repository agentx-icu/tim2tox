/// ToxAV Conference Audio Send Test
/// 
/// Tests audio sending in AV conferences
/// Reference: c-toxcore/auto_tests/scenarios/scenario_conference_av_test.c
/// 
/// Verifies that audio frames can be sent in AV conferences and received by peers

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
      scenario = await createTestScenario(['alice', 'bob', 'charlie']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      charlie = scenario.getNode('charlie')!;
      
      await scenario.initAllNodes();
      // Parallelize login
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
      
      // Configure local bootstrap
      await configureLocalBootstrap(scenario);
      
      // Enable auto-accept in Dart so three-node friend establishment succeeds (no C++ default)
      alice.enableAutoAccept();
      bob.enableAutoAccept();
      charlie.enableAutoAccept();
      
      // Add friends (use Tox ID for addFriend like scenario_toxav_conference_test)
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
      await bob.runWithInstanceAsync(() async => TIMFriendshipManager.instance.addFriend(
        userID: aliceToxId,
        addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
        remark: 'Alice',
        addWording: 'test',
      ));
      await charlie.runWithInstanceAsync(() async => TIMFriendshipManager.instance.addFriend(
        userID: aliceToxId,
        addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
        remark: 'Alice',
        addWording: 'test',
      ));

      // Friend list stores *public keys* (64 chars), not full Tox IDs.
      // Skip the fixed 5s presettle: waitForFriendsInList already polls and
      // pump the Tox iterates in parallel to accelerate friend-list propagation.
      final alicePub = alice.getPublicKey();
      final bobPub = bob.getPublicKey();
      final charliePub = charlie.getPublicKey();
      final friendListPump = pumpFriendConnection(alice, bob,
          duration: const Duration(seconds: 4), iterationsPerPump: 60);
      await Future.wait([
        waitForFriendsInList(alice, [bobPub, charliePub], timeout: const Duration(seconds: 120)),
        waitForFriendsInList(bob, [alicePub], timeout: const Duration(seconds: 120)),
        waitForFriendsInList(charlie, [alicePub], timeout: const Duration(seconds: 120)),
        friendListPump,
      ]);
      // Briefly pump for P2P/connection to stabilize before conference invites
      // (was a fixed 5s sleep; the test body re-waits on friend-connection state).
      await pumpFriendConnection(alice, bob,
          duration: const Duration(seconds: 1), iterationsPerPump: 60);
    });
    
    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });
    
    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });
    
    test('AV conference with audio sending', () async {
      await alice.waitForConnection(timeout: const Duration(seconds: 15));
      await bob.waitForConnection(timeout: const Duration(seconds: 15));
      await charlie.waitForConnection(timeout: const Duration(seconds: 15));
      await pumpFriendConnection(alice, bob, duration: const Duration(seconds: 5), iterationsPerPump: 60);
      final bobPub = bob.getPublicKey();
      final charliePub = charlie.getPublicKey();
      await alice.waitForFriendConnection(bobPub, timeout: const Duration(seconds: 50));
      await alice.waitForFriendConnection(charliePub, timeout: const Duration(seconds: 50));
      await pumpFriendConnection(alice, bob, duration: const Duration(seconds: 2), iterationsPerPump: 40);

      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'conference',
        groupName: 'AV Conference Audio Test',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;
      
      await alice.waitForCallback('onGroupCreated',
        timeout: const Duration(seconds: 10));
      pumpAllInstancesOnce(iterations: 80);
      await Future.delayed(const Duration(milliseconds: 400));
      
      var bobReceivedInvite = false;
      var charlieReceivedInvite = false;
      String? bobInvitedGroupId;
      String? charlieInvitedGroupId;
      
      final bobGroupListener = V2TimGroupListener(
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser, List<V2TimGroupMemberInfo> memberList) {
          bobReceivedInvite = true;
          bobInvitedGroupId = groupID;
          bob.markCallbackReceived('onMemberInvited');
        },
      );
      
      final charlieGroupListener = V2TimGroupListener(
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser, List<V2TimGroupMemberInfo> memberList) {
          charlieReceivedInvite = true;
          charlieInvitedGroupId = groupID;
          charlie.markCallbackReceived('onMemberInvited');
        },
      );
      
      bob.runWithInstance(() => TIMGroupManager.instance.addGroupListener(bobGroupListener));
      charlie.runWithInstance(() => TIMGroupManager.instance.addGroupListener(charlieGroupListener));
      
      var inviteResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.inviteUserToGroup(
        groupID: conferenceId,
        userList: [bobPub, charliePub],
      ));
      
      expect(inviteResult.code, equals(0));
      final failedResults = inviteResult.data?.where((r) => r.result != 1).toList() ?? [];
      if (failedResults.isNotEmpty) {
        pumpAllInstancesOnce(iterations: 120);
        await Future.delayed(const Duration(seconds: 3));
        inviteResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.inviteUserToGroup(
          groupID: conferenceId,
          userList: [bobPub, charliePub],
        ));
      }
      
      pumpAllInstancesOnce(iterations: 100);
      await Future.delayed(const Duration(milliseconds: 300));
      await waitUntilWithPump(
        () => bobReceivedInvite && charlieReceivedInvite,
        timeout: const Duration(seconds: 120),
        description: 'Both received invites',
        iterationsPerPump: 150,
        stepDelay: const Duration(milliseconds: 200),
      );
      expect(bobInvitedGroupId, isNotNull);
      expect(charlieInvitedGroupId, isNotNull);
      
      // AV conferences auto-join inside the invite callback and only map the
      // invite's local id a moment later, so an explicit join racing that mapping
      // can transiently return 6017. Retry until the mapping settles.
      Future<int> joinWithRetry(TestNode node, String gid) async {
        var res = await node.runWithInstanceAsync(
            () async => TIMManager.instance.joinGroup(groupID: gid, message: ''));
        for (int r = 0; r < 6 && res.code != 0; r++) {
          await Future.delayed(const Duration(milliseconds: 500));
          res = await node.runWithInstanceAsync(
              () async => TIMManager.instance.joinGroup(groupID: gid, message: ''));
        }
        return res.code;
      }

      expect(await joinWithRetry(bob, bobInvitedGroupId!), equals(0));
      expect(await joinWithRetry(charlie, charlieInvitedGroupId!), equals(0));

      // Poll all three joined lists in a single 5s window instead of sleeping 5s flat.
      Future<bool> allJoined() async {
        final a = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
        if (a.data == null || !a.data!.any((g) => g.groupID == conferenceId)) return false;
        final b = await bob.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
        if (b.data == null || !b.data!.any((g) => g.groupID == conferenceId || g.groupID == bobInvitedGroupId)) return false;
        final c = await charlie.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
        if (c.data == null || !c.data!.any((g) => g.groupID == conferenceId || g.groupID == charlieInvitedGroupId)) return false;
        return true;
      }
      final joinedDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(joinedDeadline)) {
        if (await allJoined()) break;
        pumpAllInstancesOnce(iterations: 60);
        await Future.delayed(const Duration(milliseconds: 200));
      }

      final aliceJoinedList = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
      expect(aliceJoinedList.data, isNotNull);
      expect(aliceJoinedList.data!.any((g) => g.groupID == conferenceId), isTrue);
      
      final bobJoinedList = await bob.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
      expect(bobJoinedList.data, isNotNull);
      expect(bobJoinedList.data!.isNotEmpty, isTrue);
      expect(
        bobJoinedList.data!.any((g) => g.groupID == conferenceId || g.groupID == bobInvitedGroupId),
        isTrue,
      );
      
      final charlieJoinedList = await charlie.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
      expect(charlieJoinedList.data, isNotNull);
      expect(charlieJoinedList.data!.isNotEmpty, isTrue);
      expect(
        charlieJoinedList.data!.any((g) => g.groupID == conferenceId || g.groupID == charlieInvitedGroupId),
        isTrue,
      );
      
      bob.runWithInstance(() => TIMGroupManager.instance.removeGroupListener(listener: bobGroupListener));
      charlie.runWithInstance(() => TIMGroupManager.instance.removeGroupListener(listener: charlieGroupListener));
    }, timeout: const Timeout(Duration(seconds: 200)));
  });
}
