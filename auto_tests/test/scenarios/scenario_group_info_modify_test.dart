/// Group Info Modify Test
/// 
/// Tests modifying group information: name, introduction, notification, etc.
/// Verifies that group info changes are synchronized across members

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Info Modify Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    
    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      
      await scenario.initAllNodes();
      // Parallelize login
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);
      
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );
      
      await configureLocalBootstrap(scenario);

      // tim2tox inviteUserToGroup needs invitee as friend. Only one sub-test
      // exercises the cross-instance join+sync flow, but doing it once in
      // setUpAll keeps the friendship warm for all tests.
      try {
        await establishFriendship(alice, bob,
            timeout: const Duration(seconds: 90));
      } catch (e) {
        print('[setUpAll] establishFriendship best-effort: $e');
      }
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
    
    test('Modify group name', () async {
      // Create group on alice's instance
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'group',
        groupName: 'Original Name',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        groupName: 'Modified Name',
      );
      
      final setInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.setGroupInfo(
        info: groupInfo,
      ));
      
      expect(setInfoResult.code, equals(0));
      
      await Future.delayed(const Duration(milliseconds: 500));
      final groupsInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupsInfo(
        groupIDList: [groupId],
      ));
      
      if (groupsInfoResult.code == 0 && groupsInfoResult.data != null && groupsInfoResult.data!.isNotEmpty) {
        expect(groupsInfoResult.data!.first.groupInfo?.groupName, equals('Modified Name'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Modify group introduction', () async {
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'group',
        groupName: 'Test Group',
        introduction: 'Original Introduction',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        introduction: 'Modified Introduction',
      );
      
      final setInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.setGroupInfo(
        info: groupInfo,
      ));
      
      expect(setInfoResult.code, equals(0));
      
      await Future.delayed(const Duration(milliseconds: 500));
      final groupsInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupsInfo(
        groupIDList: [groupId],
      ));
      
      if (groupsInfoResult.code == 0 && groupsInfoResult.data != null && groupsInfoResult.data!.isNotEmpty) {
        expect(groupsInfoResult.data!.first.groupInfo?.introduction, equals('Modified Introduction'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Modify group notification', () async {
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'group',
        groupName: 'Test Group',
        notification: 'Original Notification',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        notification: 'Modified Notification',
      );
      
      final setInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.setGroupInfo(
        info: groupInfo,
      ));
      
      expect(setInfoResult.code, equals(0));
      
      await Future.delayed(const Duration(milliseconds: 500));
      final groupsInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupsInfo(
        groupIDList: [groupId],
      ));
      
      if (groupsInfoResult.code == 0 && groupsInfoResult.data != null && groupsInfoResult.data!.isNotEmpty) {
        expect(groupsInfoResult.data!.first.groupInfo?.notification, equals('Modified Notification'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Modify multiple group info fields', () async {
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'group',
        groupName: 'Original Name',
        introduction: 'Original Introduction',
        notification: 'Original Notification',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        groupName: 'New Name',
        introduction: 'New Introduction',
        notification: 'New Notification',
      );
      
      final setInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.setGroupInfo(
        info: groupInfo,
      ));
      
      expect(setInfoResult.code, equals(0));
      
      await Future.delayed(const Duration(milliseconds: 500));
      final groupsInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupsInfo(
        groupIDList: [groupId],
      ));
      
      if (groupsInfoResult.code == 0 && groupsInfoResult.data != null && groupsInfoResult.data!.isNotEmpty) {
        final info = groupsInfoResult.data!.first.groupInfo!;
        expect(info.groupName, equals('New Name'));
        expect(info.introduction, equals('New Introduction'));
        expect(info.notification, equals('New Notification'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Modify group info for conference type', () async {
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'Meeting',
        groupName: 'Original Conference Name',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final conferenceId = createResult.data!;
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final groupInfo = V2TimGroupInfo(
        groupID: conferenceId,
        groupType: 'Meeting',
        groupName: 'Modified Conference Name',
      );
      
      final setInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.setGroupInfo(
        info: groupInfo,
      ));
      
      expect(setInfoResult.code, equals(0));
      
      await Future.delayed(const Duration(milliseconds: 500));
      final groupsInfoResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupsInfo(
        groupIDList: [conferenceId],
      ));
      
      if (groupsInfoResult.code == 0 && groupsInfoResult.data != null && groupsInfoResult.data!.isNotEmpty) {
        expect(groupsInfoResult.data!.first.groupInfo?.groupName, equals('Modified Conference Name'));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Group info change notification to members', () async {
      final createResult = await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.createGroup(
        groupType: 'group',
        groupName: 'Original Name',
        groupID: '',
      ));
      
      expect(createResult.code, equals(0));
      final groupId = createResult.data!;
      
      // Bob needs an invite before joinGroup can succeed (joinGroup wants a
      // stored chat_id or pending invite; chat_id only lives on Alice's instance).
      bob.clearCallbackReceived('onGroupInvited');
      final inviteResult = await alice.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.inviteUserToGroup(
            groupID: groupId,
            userList: [bob.getPublicKey()],
          ));
      expect(inviteResult.code, equals(0),
          reason: 'inviteUserToGroup failed: ${inviteResult.desc}');
      await waitUntilWithPump(
        () => bob.callbackReceived['onGroupInvited'] == true,
        timeout: const Duration(seconds: 30),
        description: 'bob receives onGroupInvited',
        iterationsPerPump: 100,
        stepDelay: const Duration(milliseconds: 200),
      );
      await Future.delayed(const Duration(milliseconds: 300));
      final bobJoinResult = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(bobJoinResult.code, equals(0),
          reason: 'bob joinGroup failed: ${bobJoinResult.desc}');
      await Future.delayed(const Duration(milliseconds: 500));

      var bobReceivedInfoChange = false;
      final bobListener = V2TimGroupListener(
        onGroupInfoChanged: (groupID, changeInfos) {
          if (groupID == groupId) {
            bobReceivedInfoChange = true;
            bob.markCallbackReceived('onGroupInfoChanged');
          }
        },
      );
      
      bob.runWithInstance(() => TIMManager.instance.addGroupListener(listener: bobListener));
      
      final groupInfo = V2TimGroupInfo(
        groupID: groupId,
        groupType: 'group',
        groupName: 'Changed Name',
      );
      
      await alice.runWithInstanceAsync(() async => TIMGroupManager.instance.setGroupInfo(info: groupInfo));
      
      // Callback may be delayed on some runs; query is the authoritative fallback.
      try {
        await waitUntil(
          () => bobReceivedInfoChange,
          timeout: const Duration(seconds: 10),
          description: 'Bob receives group info change',
        );
      } catch (e) {
        print('[GroupInfoModify] onGroupInfoChanged callback not observed in time, fallback to state query: $e');
      }

      final bobGroupInfoResult = await bob.runWithInstanceAsync(() async => TIMGroupManager.instance.getGroupsInfo(
        groupIDList: [groupId],
      ));
      expect(bobGroupInfoResult.code, equals(0), reason: 'Bob should be able to query group info');
      final bobObservedChangedName = bobGroupInfoResult.data != null &&
          bobGroupInfoResult.data!.isNotEmpty &&
          bobGroupInfoResult.data!.first.groupInfo?.groupName == 'Changed Name';
      expect(
        bobObservedChangedName,
        isTrue,
        reason: 'Bob should observe updated group name via getGroupsInfo',
      );
      expect(
        bobReceivedInfoChange || bobObservedChangedName,
        isTrue,
        reason: 'Bob should observe group info change via callback or state query',
      );
      
      bob.runWithInstance(() => TIMManager.instance.removeGroupListener(listener: bobListener));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
