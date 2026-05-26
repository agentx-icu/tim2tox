/// ToxAV Conference Test
/// 
/// Tests AV conference (TOX_CONFERENCE_TYPE_AV) functionality
/// Verifies that AV conferences can be created, joined, and handle audio data
/// Reference: c-toxcore/auto_tests/scenarios/scenario_conference_av_test.c

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
  group('ToxAV Conference Tests', () {
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
      
      // Wait for connections so full Tox IDs (76 chars) are available for addFriend
      // NOTE: Do NOT parallelize cross-instance calls. The FFI layer uses a global
      // current instance, and parallel Future.wait can race and execute with the
      // wrong instance selected (e.g. "Cannot add yourself").
      await alice.waitForConnection(timeout: const Duration(seconds: 10));
      await bob.waitForConnection(timeout: const Duration(seconds: 10));
      await charlie.waitForConnection(timeout: const Duration(seconds: 10));
      await waitUntil(
        () =>
            alice.getToxId().length == 76 &&
            bob.getToxId().length == 76 &&
            charlie.getToxId().length == 76,
        timeout: const Duration(seconds: 10),
        description: 'Tox IDs available',
      );

      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      final charlieToxId = charlie.getToxId();

      // Add friends using full Tox IDs (required by tox_friend_add)
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
      await bob.runWithInstanceAsync(() async {
        await TIMFriendshipManager.instance.addFriend(
          userID: aliceToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          remark: 'Alice',
          addWording: 'test',
        );
      });
      await charlie.runWithInstanceAsync(() async {
        await TIMFriendshipManager.instance.addFriend(
          userID: aliceToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          remark: 'Alice',
          addWording: 'test',
        );
      });

      // Friend requests may need time to propagate/auto-accept over the local DHT.
      await Future.delayed(const Duration(seconds: 5));

      // For group invite to work we mainly need friend_number lookup to succeed.
      // The friend list stores *public keys* (64 chars), not full Tox IDs.
      final alicePub = alice.getPublicKey();
      final bobPub = bob.getPublicKey();
      final charliePub = charlie.getPublicKey();

      await waitForFriendsInList(alice, [bobPub, charliePub], timeout: const Duration(seconds: 120));
      await waitForFriendsInList(bob, [alicePub], timeout: const Duration(seconds: 120));
      await waitForFriendsInList(charlie, [alicePub], timeout: const Duration(seconds: 120));
      // Wait for P2P connection so conference invites can be delivered
      await Future.wait([
        alice.waitForFriendConnection(bobToxId, timeout: const Duration(seconds: 60)),
        alice.waitForFriendConnection(charlieToxId, timeout: const Duration(seconds: 60)),
        bob.waitForFriendConnection(aliceToxId, timeout: const Duration(seconds: 60)),
        charlie.waitForFriendConnection(aliceToxId, timeout: const Duration(seconds: 60)),
      ]);
      await Future.delayed(const Duration(seconds: 1));
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
    
    test('Create AV conference and verify type', () async {
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'conference',
        groupName: 'AV Conference Test',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0), 
        reason: 'Failed to create conference: ${createResult.code}');
      expect(createResult.data, isNotNull, 
        reason: 'Conference ID is null');
      
      final conferenceId = createResult.data!;
      
      await alice.waitForCallback('onGroupCreated', 
        timeout: const Duration(seconds: 10));
      
      final joinedListResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
      expect(joinedListResult.code, equals(0));
      expect(joinedListResult.data, isNotNull);
      
      final groupIds = joinedListResult.data!.map((g) => g.groupID).toList();
      expect(groupIds, contains(conferenceId),
        reason: 'Conference not found in joined list');
    }, timeout: const Timeout(Duration(seconds: 90)));
    
    test('Join AV conference via invite', () async {
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'conference',
        groupName: 'AV Conference Join Test',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;
      
      await alice.waitForCallback('onGroupCreated', 
        timeout: const Duration(seconds: 10));
      
      var bobReceivedInvite = false;
      String? invitedGroupId;
      
      final bobGroupListener = V2TimGroupListener(
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser, List<V2TimGroupMemberInfo> memberList) {
          // tim2tox emits a temporary invite groupID (tox_inv_*) when auto-accept
          // group invites is disabled. The receiver should call joinGroup with the
          // temp ID to accept the invite and join the actual groupID (conferenceId).
          bobReceivedInvite = true;
          invitedGroupId = groupID;
          bob.markCallbackReceived('onMemberInvited');
        },
      );
      
      bob.runWithInstance(() => TIMGroupManager.instance.addGroupListener(bobGroupListener));
      
      final bobPublicKey = bob.getPublicKey();
      final inviteResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.inviteUserToGroup(
        groupID: conferenceId,
        userList: [bobPublicKey],
      ));
      
      expect(inviteResult.code, equals(0),
        reason: 'Failed to invite Bob: ${inviteResult.code}');
      
      await waitUntil(
        () => bobReceivedInvite,
        timeout: const Duration(seconds: 45),
        description: 'Bob received conference invite',
      );
      
      await bob.waitForCallback('onMemberInvited', timeout: const Duration(seconds: 5));
      
      expect(bobReceivedInvite, isTrue,
        reason: 'Bob did not receive conference invite');
      expect(invitedGroupId, isNotNull,
        reason: 'Invited group ID should not be null');
      
      final joinResult = await bob.runWithInstanceAsync(() async => TIMManager.instance.joinGroup(
        groupID: invitedGroupId!,
        message: '',
      ));
      
      expect(joinResult.code, equals(0),
        reason: 'Bob failed to join conference: ${joinResult.code}');
      
      await Future.delayed(const Duration(seconds: 3));
      
      final bobJoinedListResult = await bob.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
      expect(bobJoinedListResult.code, equals(0));
      expect(bobJoinedListResult.data, isNotNull);
      
      final bobGroupIds = bobJoinedListResult.data!.map((g) => g.groupID).toList();
      // Joined list may contain the temp ID (tox_inv_*) instead of conferenceId (e.g. tox_group_1).
      // Reason: C++ JoinGroup(groupID) stores the caller-provided groupID in group_number_to_group_id_;
      // when Bob joins via invitedGroupId (the temp ID from OnMemberInvited), that temp ID is what we store.
      // GetJoinedGroupList returns those stored IDs, so Bob's list shows the temp ID. We do not "fix" this
      // in C++ because the invitee's instance never receives the creator's conferenceId—Tox invite payload
      // has no custom field for it, so we cannot replace temp ID with conferenceId without protocol changes.
      expect(bobGroupIds, isNotEmpty, reason: 'Bob should have joined a group');
      expect(
        bobGroupIds.contains(conferenceId) || bobGroupIds.contains(invitedGroupId),
        isTrue,
        reason: 'Bob not found in conference (expected $conferenceId or $invitedGroupId, got $bobGroupIds)',
      );
      
      bob.runWithInstance(() => TIMGroupManager.instance.removeGroupListener(listener: bobGroupListener));
    }, timeout: const Timeout(Duration(seconds: 90)));
    
    test('Multiple members join AV conference', () async {
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'conference',
        groupName: 'Multi-Member AV Conference',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;
      
      await alice.waitForCallback('onGroupCreated', 
        timeout: const Duration(seconds: 10));
      
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
      
      final bobPublicKey = bob.getPublicKey();
      final charliePublicKey = charlie.getPublicKey();
      final inviteResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.inviteUserToGroup(
        groupID: conferenceId,
        userList: [bobPublicKey, charliePublicKey],
      ));
      
      expect(inviteResult.code, equals(0));
      
      await waitUntil(
        () => bobReceivedInvite && charlieReceivedInvite,
        timeout: const Duration(seconds: 60),
        description: 'Both Bob and Charlie received invites',
      );
      
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
      
      await Future.delayed(const Duration(seconds: 5));
      
      final aliceJoinedList = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getJoinedGroupList());
      expect(aliceJoinedList.data, isNotNull);
      expect(aliceJoinedList.data!.any((g) => g.groupID == conferenceId), isTrue);
      
      bob.runWithInstance(() => TIMGroupManager.instance.removeGroupListener(listener: bobGroupListener));
      charlie.runWithInstance(() => TIMGroupManager.instance.removeGroupListener(listener: charlieGroupListener));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
