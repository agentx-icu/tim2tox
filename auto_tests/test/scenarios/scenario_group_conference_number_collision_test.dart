/// NGC group vs legacy conference number collision.
///
/// toxcore numbers NGC groups and legacy conferences in two independent spaces
/// that both start at 0, so on a fresh profile the first NGC group and the
/// first conference are both "#0". Tim2Tox used to keep them in one
/// number -> groupID map and one message handler, which cross-wired them:
/// conference messages were dropped as self-messages or filed under the NGC
/// group, member lists leaked across, and quitting one erased the other.
///
/// Here Bob owns NGC group #0 and joins Alice's conference, which is also #0
/// on Bob's side (and Alice owns NGC #0 + conference #0 too). Messages must be
/// attributed to the right group on both sides, and quitting the conference
/// must leave Bob's NGC group intact.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' as pkgffi;
import 'package:test/test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_full_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_full_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('NGC group / conference number collision', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([alice.login(), bob.login()]);
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'all nodes logged in',
      );

      await configureLocalBootstrapVirtual(scenario);
      alice.enableAutoAccept();
      bob.enableAutoAccept();

      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForConnectionVirtual(scenario, bob,
          timeout: const Duration(seconds: 15));
      await waitUntilWithVirtualPump(
        scenario,
        () => alice.getToxId().length == 76 && bob.getToxId().length == 76,
        timeout: const Duration(seconds: 10),
        description: 'Tox IDs available',
      );

      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      await alice.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: bobToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Bob',
                addWording: 'test',
              ));
      await bob.runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.addFriend(
                userID: aliceToxId,
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
                remark: 'Alice',
                addWording: 'test',
              ));
      await waitForFriendsInList(alice, [bob.getPublicKey()],
          timeout: const Duration(seconds: 120));
      await waitForFriendsInList(bob, [alice.getPublicKey()],
          timeout: const Duration(seconds: 120));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 90));
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test('messages, members and quit stay on the right kind', () async {
      // A known self name for Alice: it is her conference peer name, which
      // Bob must see as the sender nickname and in the conference members.
      const aliceNick = 'AliceConfNick';
      final aliceInfo = V2TimUserFullInfo()..nickName = aliceNick;
      final setName = await alice.runWithInstanceAsync(
          () async => TIMManager.instance.setSelfInfo(userFullInfo: aliceInfo));
      expect(setName.code, equals(0));

      // NGC #0 on both nodes.
      final bobNgc = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Bob NGC',
                groupID: '',
              ));
      expect(bobNgc.code, equals(0));
      final bobNgcId = bobNgc.data!;
      final aliceNgc = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'group',
                groupName: 'Alice NGC',
                groupID: '',
              ));
      expect(aliceNgc.code, equals(0));
      final aliceNgcId = aliceNgc.data!;

      // Conference #0 on Alice. The SDK's createGroup maps 'conference' to an
      // NGC "Meeting"; a real legacy conference only comes from the FFI
      // create path, which is what the app's "conference" option uses.
      final bindings = ffi_lib.Tim2ToxFfi.open();
      final name = 'Alice Conference'.toNativeUtf8();
      final type = 'conference'.toNativeUtf8();
      final output = pkgffi.malloc<ffi.Int8>(128);
      late String conferenceId;
      try {
        final len = alice.runWithInstance(
            () => bindings.createGroup(name, type, output, 128));
        expect(len, greaterThan(0));
        conferenceId = output.cast<pkgffi.Utf8>().toDartString(length: len);
      } finally {
        pkgffi.malloc.free(output);
        pkgffi.malloc.free(type);
        pkgffi.malloc.free(name);
      }
      expect(conferenceId, isNot(equals(aliceNgcId)));

      String? bobConferenceId;
      final bobGroupListener = V2TimGroupListener(
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser,
            List<V2TimGroupMemberInfo> memberList) {
          if (groupID != bobNgcId) bobConferenceId ??= groupID;
        },
      );
      bob.runWithInstance(
          () => TIMGroupManager.instance.addGroupListener(bobGroupListener));

      final bobReceived = <V2TimMessage>[];
      final aliceReceived = <V2TimMessage>[];
      bob.runWithInstance(() => TIMMessageManager.instance.addAdvancedMsgListener(
          V2TimAdvancedMsgListener(onRecvNewMessage: bobReceived.add)));
      alice.runWithInstance(() => TIMMessageManager.instance.addAdvancedMsgListener(
          V2TimAdvancedMsgListener(onRecvNewMessage: aliceReceived.add)));

      for (var attempt = 0; bobConferenceId == null && attempt < 3; attempt++) {
        final invite = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.inviteUserToGroup(
                  groupID: conferenceId,
                  userList: [bob.getPublicKey()],
                ));
        expect(invite.code, equals(0));
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bobConferenceId != null,
            timeout: const Duration(seconds: 30),
            description: 'Bob got the conference invite',
            advanceMs: 100,
            iterationsPerInstance: 1,
            wallSleep: const Duration(milliseconds: 30),
          );
        } on TimeoutException catch (e) {
          print('[Collision] invite attempt ${attempt + 1} timed out: $e');
        }
      }
      expect(bobConferenceId, isNotNull, reason: 'no conference invite');

      final join = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: bobConferenceId!, message: ''));
      expect(join.code, equals(0));
      await pumpTestTick(scenario, advanceMs: 3000, iterationsPerInstance: 1);

      Future<void> sendText(TestNode node, String groupId, String text) async {
        final r = await node.runWithInstanceAsync(() async {
          final created =
              TIMMessageManager.instance.createTextMessage(text: text);
          return TIMMessageManager.instance.sendMessage(
            message: created.messageInfo!,
            receiver: null,
            groupID: groupId,
          );
        });
        expect(r.code, equals(0), reason: 'send "$text" to $groupId failed');
      }

      // Conference traffic in both directions, retried until the conference
      // peers are connected (sends before that reach nobody).
      Future<V2TimMessage> exchange(TestNode from, String groupId, String text,
          List<V2TimMessage> inbox,
          {bool Function(V2TimMessage m)? accept}) async {
        bool matches(V2TimMessage m) =>
            (m.textElem?.text?.startsWith(text) ?? false) &&
            (accept == null || accept(m));
        V2TimMessage? found;
        for (var attempt = 0; found == null && attempt < 5; attempt++) {
          await sendText(from, groupId, '$text#$attempt');
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => inbox.any(matches),
              timeout: const Duration(seconds: 20),
              description: 'delivery of $text',
              advanceMs: 100,
              iterationsPerInstance: 1,
              wallSleep: const Duration(milliseconds: 30),
            );
          } on TimeoutException catch (e) {
            print('[Collision] $text attempt ${attempt + 1} timed out: $e');
          }
          for (final m in inbox) {
            if (matches(m)) found = m;
          }
        }
        expect(found, isNotNull, reason: '$text never arrived');
        return found!;
      }

      final atBob = await exchange(alice, conferenceId, 'conf-from-alice', bobReceived);
      expect(atBob.groupID, equals(bobConferenceId),
          reason: 'conference message filed under the wrong group on Bob');
      expect(atBob.groupID, isNot(equals(bobNgcId)));

      // The sender nickname of a conference message is Alice's conference
      // peer name (read with the conference API on the untagged number). Peer
      // names sync shortly after the join, so retry until it is populated.
      final namedAtBob = await exchange(
          alice, conferenceId, 'conf-named-from-alice', bobReceived,
          accept: (m) => (m.nickName ?? '').isNotEmpty);
      expect(namedAtBob.groupID, equals(bobConferenceId));
      expect(namedAtBob.nickName, equals(aliceNick),
          reason: 'conference sender nickname is not the conference peer name');

      final atAlice = await exchange(bob, bobConferenceId!, 'conf-from-bob', aliceReceived);
      expect(atAlice.groupID, equals(conferenceId),
          reason: 'conference message filed under the wrong group on Alice');
      expect(atAlice.groupID, isNot(equals(aliceNgcId)));

      // Bob's conference member list: enumerated with the conference API on
      // the untagged number, so Alice (with her conference name) and Bob
      // himself are there — never NGC #0's members.
      final confMembers = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: bobConferenceId!,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(confMembers.code, equals(0));
      final confList = (confMembers.data?.memberInfoList ?? const [])
          .whereType<V2TimGroupMemberFullInfo>()
          .toList();
      final aliceInConf = confList
          .where((m) =>
              (m.userID ?? '').toUpperCase() ==
              alice.getPublicKey().toUpperCase())
          .toList();
      expect(aliceInConf, hasLength(1),
          reason: 'Alice missing from (or duplicated in) the conference member list');
      expect(aliceInConf.single.nickName, equals(aliceNick),
          reason: 'conference member name not read from the conference peer');
      expect(
          confList
              .where((m) =>
                  (m.userID ?? '').toUpperCase() ==
                  bob.getPublicKey().toUpperCase())
              .length,
          equals(1),
          reason: 'self must appear exactly once in the conference member list');

      // Both sides report the same live conference id for the conference.
      final aliceConfIdentity =
          getGroupChatIdForInstance(alice.testInstanceHandle!, conferenceId);
      final bobConfIdentity =
          getGroupChatIdForInstance(bob.testInstanceHandle!, bobConferenceId!);
      expect(aliceConfIdentity, isNotNull);
      expect(aliceConfIdentity!.length, equals(64));
      expect(bobConfIdentity?.toLowerCase(),
          equals(aliceConfIdentity.toLowerCase()),
          reason: 'conference identity differs between the two members');

      // Bob's NGC group has no other member: conference peers must not leak in.
      final members = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: bobNgcId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(members.code, equals(0));
      final memberIds = (members.data?.memberInfoList ?? const [])
          .map((m) => m?.userID?.toUpperCase())
          .toList();
      expect(memberIds, isNot(contains(alice.getPublicKey().toUpperCase())),
          reason: 'NGC member list shows the conference peer');

      // Quitting the conference must not touch the NGC group #0.
      final quit = await bob.runWithInstanceAsync(
          () async => TIMManager.instance.quitGroup(groupID: bobConferenceId!));
      expect(quit.code, equals(0));
      await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 1);

      final joined = await bob.runWithInstanceAsync(
          () async => TIMGroupManager.instance.getJoinedGroupList());
      expect(joined.code, equals(0));
      final joinedIds = joined.data!.map((g) => g.groupID).toSet();
      expect(joinedIds, contains(bobNgcId));
      expect(joinedIds, isNot(contains(bobConferenceId)));

      final ngcInfo = await bob.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: bobNgcId,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
          ));
      expect(ngcInfo.code, equals(0),
          reason: 'NGC group lost its mapping when the conference was quit');
    }, timeout: const Timeout(Duration(minutes: 6)));
  });
}
