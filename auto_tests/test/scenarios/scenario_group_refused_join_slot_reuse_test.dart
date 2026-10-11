// Refused invite join, then slot reuse (follow-up to tim2tox#28).
//
// Accepting an invite begins a wire sync for the new group number. When the
// founder refuses the join (wrong password), HandleGroupJoinFail undoes the
// join and deletes the toxcore group, whose number toxcore then hands to the
// next group. That group (one we create gets no sync of its own) must still
// become wire-ready, or every send to it stays queued.
//
// Pinned here, end to end over the wire:
//   1. bob's accept of a password-protected group's invite is refused and
//      undone;
//   2. bob's next group reuses the refused group's number;
//   3. that group becomes wire-ready once alice joins, and a send from bob
//      reaches alice exactly once.
//
// Scope: in one process the invitee resolves the group to the creator's id
// (g_cross_instance_group_identity), so this covers the canonical-id refusal.
// The production case — an auto-accepted invite to a never-seen group, mapped
// under its invite alias until toxcore's self-join, whose readiness the
// refusal used to leave behind — needs two processes; it is pinned by
// test/GroupWireReadinessTest.cpp and DitMesh's real-peers run.
//
// The founder password is set through a test seam
// (tim2tox_ffi_debug_group_set_password): Tim2Tox has no product API for it.
//
// Mode-aware: runs wall-clock by default and under RUN_VIRTUAL=1.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_add_opt_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Refused Join Slot Reuse Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late String bobSelfKey;
    final aliceReceived = <String, List<String>>{};  // group id -> texts
    V2TimAdvancedMsgListener? aliceListener;

    int withGroupId(TestNode node, String groupId,
            int Function(ffi_lib.Tim2ToxFfi lib, ffi.Pointer<pkgffi.Utf8> gid) call) =>
        node.runWithInstance(() {
          final lib = ffi_lib.Tim2ToxFfi.open();
          final gid = groupId.toNativeUtf8();
          try {
            return call(lib, gid);
          } finally {
            pkgffi.malloc.free(gid);
          }
        });

    int groupNumber(TestNode node, String groupId) =>
        withGroupId(node, groupId, (lib, gid) => lib.debugGroupNumber(gid));

    int wireReady(TestNode node, String groupId) =>
        withGroupId(node, groupId, (lib, gid) => lib.groupWireReady(gid));

    Future<String> createGroup(TestNode node, String name) async {
      final created = await node.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'kTIMGroup_Private',
                groupName: name,
                addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
              ));
      expect(created.code, equals(0),
          reason: '${node.alias} createGroup failed: ${created.desc}');
      return created.data!;
    }

    // Alice may know bob's group under her own id; count across all of them.
    int aliceCount(String text) => aliceReceived.values
        .expand((texts) => texts)
        .where((t) => t == text)
        .length;

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
        timeout: const Duration(seconds: 15),
        description: 'both nodes logged in',
      );
      await configureLocalBootstrapVirtual(scenario);
      alice.enableAutoAccept();
      bob.enableAutoAccept();
      await establishFriendshipVirtual(scenario, alice, bob,
          timeout: const Duration(seconds: 60));
      bobSelfKey = bob.getToxId().substring(0, 64).toUpperCase();

      aliceListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          final text = message.textElem?.text;
          final gid = message.groupID;
          // Only a copy that came over the wire counts (the shared harness
          // service also surfaces bob's own rows to every listener).
          if (gid != null &&
              text != null &&
              message.sender?.toUpperCase() != bobSelfKey) {
            aliceReceived.putIfAbsent(gid, () => <String>[]).add(text);
          }
        },
      );
      alice.runWithInstance(() =>
          TIMMessageManager.instance.addAdvancedMsgListener(aliceListener!));
    });

    tearDownAll(() async {
      final listener = aliceListener;
      if (listener != null) {
        alice.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: listener));
      }
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test(
        'the group created in a refused join\'s slot becomes wire-ready and '
        'sends', () async {
      // 1. A password-protected group bob is invited to but cannot enter.
      final lockedId = await createGroup(alice, 'Locked Net');
      final setPassword = withGroupId(alice, lockedId,
          (lib, gid) {
        final pw = 'correct horse'.toNativeUtf8();
        try {
          return lib.debugGroupSetPassword(gid, pw);
        } finally {
          pkgffi.malloc.free(pw);
        }
      });
      expect(setPassword, equals(1),
          reason: 'the founder must be able to set the group password');

      final joinId = await inviteUserToGroupWithRetry(
          scenario, alice, bob, lockedId,
          context: 'locked group', maxAttempts: 5,
          timeout: const Duration(seconds: 15));
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      // Accept the invite; the founder will refuse it (no password given).
      final accept = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: joinId, message: ''));
      expect(accept.code, equals(0),
          reason: 'accepting the invite failed: ${accept.desc}');
      final refusedNumber = groupNumber(bob, joinId);
      expect(refusedNumber, greaterThanOrEqualTo(0),
          reason: 'the accepted invite must map to a toxcore group');
      expect(wireReady(bob, joinId), equals(0));

      // 2. The founder refuses (no password): native undoes the join.
      await waitUntilWithVirtualPump(
        scenario,
        () => groupNumber(bob, joinId) == -1,
        timeout: const Duration(seconds: 60),
        description: 'bob\'s refused join is undone',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );
      // The toxcore group is deleted from the event-thread queue, which the
      // tick drains.
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 2);

      final reusedId = await createGroup(bob, 'Reused Slot Net');
      expect(groupNumber(bob, reusedId), equals(refusedNumber),
          reason: 'toxcore must hand the refused group\'s freed number to '
              'the next group, or this test exercises nothing');
      expect(wireReady(bob, reusedId), equals(0),
          reason: 'alone in the new group, no send can reach anyone');

      // 3. Alice joins bob's group: its first confirmed peer makes it ready.
      final aliceJoinId = await inviteUserToGroupWithRetry(
          scenario, bob, alice, reusedId,
          context: 'reused-slot group', maxAttempts: 5,
          timeout: const Duration(seconds: 15));
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final join = await alice.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: aliceJoinId, message: ''));
      expect(join.code, equals(0), reason: 'alice join failed: ${join.desc}');
      final seen = await waitUntilFounderSeesMemberInGroupVirtual(
          scenario, bob, alice, reusedId,
          timeout: const Duration(seconds: 45));
      expect(seen, isNotNull, reason: 'bob must see alice in the group');
      await waitUntilWithVirtualPump(
        scenario,
        () => wireReady(bob, reusedId) == 1,
        timeout: const Duration(seconds: 60),
        description: 'bob\'s group in the reused slot turns wire-ready '
            '(stuck "awaiting sync" before the fix)',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      final probe = 'reused slot ${DateTime.now().microsecondsSinceEpoch}';
      final send = await bob.runWithInstanceAsync(() async {
        final created =
            TIMMessageManager.instance.createTextMessage(text: probe);
        return TIMMessageManager.instance.sendMessage(
          message: created.messageInfo!,
          receiver: null,
          groupID: reusedId,
          onlineUserOnly: false,
        );
      });
      expect(send.code, equals(0),
          reason: 'bob group sendMessage failed: ${send.desc}');
      await waitUntilWithVirtualPump(
        scenario,
        () => aliceCount(probe) >= 1,
        timeout: const Duration(seconds: 45),
        description: 'alice receives bob\'s send',
        advanceMs: 50,
        iterationsPerInstance: 2,
      );
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 2);
      expect(aliceCount(probe), equals(1),
          reason: 'the send must reach alice exactly once');
    }, timeout: const Timeout(Duration(seconds: 240)));
  });
}
