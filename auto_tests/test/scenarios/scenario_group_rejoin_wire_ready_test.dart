// Group rejoin wire-readiness test (tim2tox#28).
//
// JoinGroup on a group we already hold is a rejoin: toxcore's
// gc_rejoin_group() marks every peer connection for deletion and goes back
// to CS_CONNECTING, where tox_group_is_connected() still answers true and
// gc_send_message() reports success while reaching nobody
// (`sent > 0 || confirmed_peers == 0`). tim2tox_ffi_group_wire_ready used to
// be exactly tox_group_is_connected(), so the Dart send gate never queued and
// the text was lost.
//
// Pinned here, end to end over the wire:
//   1. right after the rejoin the group is NOT wire-ready;
//   2. a text composed in that window is queued (pending), not sent;
//   3. the moment native reports wire-ready again a send reaches the peer —
//      readiness means a confirmed peer, not just toxcore's self-join;
//   4. draining the queued text delivers it to the peer exactly once.
//
// Mode-aware: runs wall-clock by default and under RUN_VIRTUAL=1.

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_add_opt_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Group Rejoin Wire Ready Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late String groupId;
    late String bobSelfKey;
    final aliceReceived = <String>[];
    V2TimAdvancedMsgListener? aliceListener;

    /// Native tim2tox_ffi_group_wire_ready for [node]'s view of the group.
    int wireReady(TestNode node) => node.runWithInstance(() {
          final lib = ffi_lib.Tim2ToxFfi.open();
          final gid = groupId.toNativeUtf8();
          try {
            return lib.groupWireReady(gid);
          } finally {
            pkgffi.malloc.free(gid);
          }
        });

    int aliceCount(String text) => aliceReceived.where((t) => t == text).length;

    Future<void> bobSendsOverWire(String text) async {
      final result = await bob.runWithInstanceAsync(() async {
        final created =
            TIMMessageManager.instance.createTextMessage(text: text);
        return TIMMessageManager.instance.sendMessage(
          message: created.messageInfo!,
          receiver: null,
          groupID: groupId,
          onlineUserOnly: false,
        );
      });
      expect(result.code, equals(0),
          reason: 'bob group sendMessage failed: ${result.desc}');
    }

    Future<void> rejoinAndExpectNotReady() async {
      final rejoin = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(rejoin.code, equals(0), reason: 'rejoin failed: ${rejoin.desc}');
      // No pump in between: this is the CS_CONNECTING window.
      expect(wireReady(bob), equals(0),
          reason: 'a rejoining group must not report wire-ready while its '
              'peer connections are being torn down and resynced');
    }

    Future<void> waitWireReady(String description) => waitUntilWithVirtualPump(
          scenario,
          () => wireReady(bob) == 1,
          timeout: const Duration(seconds: 60),
          description: description,
          advanceMs: 50,
          iterationsPerInstance: 1,
        );

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

      final created = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'kTIMGroup_Private',
                groupName: 'Rejoin Wire Ready',
                addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
              ));
      expect(created.code, equals(0),
          reason: 'createGroup failed: ${created.desc}');
      groupId = created.data!;
      bobSelfKey = bob.getToxId().substring(0, 64).toUpperCase();

      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 5; attempt++) {
        bob.clearCallbackReceived('onGroupInvited');
        final invite = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.inviteUserToGroup(
                  groupID: groupId,
                  userList: [bob.getPublicKey()],
                ));
        expect(invite.code, equals(0),
            reason: 'inviteUserToGroup failed: ${invite.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          inviteArrived = true;
        } on Exception {
          // Friend P2P may still be warming up — retry the invite.
        }
      }
      expect(inviteArrived, isTrue,
          reason: 'bob never received onGroupInvited after 5 retries');
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      final join = await bob.runWithInstanceAsync(() async =>
          TIMManager.instance.joinGroup(groupID: groupId, message: ''));
      expect(join.code, equals(0), reason: 'joinGroup failed: ${join.desc}');
      final seen = await waitUntilFounderSeesMemberInGroupVirtual(
          scenario, alice, bob, groupId,
          timeout: const Duration(seconds: 45));
      expect(seen, isNotNull, reason: 'alice must see bob in the group');
      await waitWireReady('bob wire-ready after the first join');

      aliceListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          final text = message.textElem?.text;
          // The shared harness service also surfaces bob's own queued row
          // (sender = bob's long-term key) to every listener; only a copy
          // that came over the wire counts as received.
          if (message.groupID == groupId &&
              text != null &&
              message.sender?.toUpperCase() != bobSelfKey) {
            aliceReceived.add(text);
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

    test('wire-ready after a rejoin means a send reaches the peer', () async {
      await rejoinAndExpectNotReady();
      await waitWireReady('bob wire-ready again after the rejoin');

      // Ready is a confirmed peer, not toxcore's self-join: a send issued
      // the moment it flips must arrive.
      final probe = 'ready probe ${DateTime.now().microsecondsSinceEpoch}';
      await bobSendsOverWire(probe);
      await waitUntilWithVirtualPump(
        scenario,
        () => aliceCount(probe) >= 1,
        timeout: const Duration(seconds: 45),
        description: 'alice receives the first send after wire-ready',
        advanceMs: 50,
        iterationsPerInstance: 2,
      );
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 2);
      expect(aliceCount(probe), equals(1));
    }, timeout: const Timeout(Duration(seconds: 180)));

    test(
        'a text composed right after a rejoin is queued and reaches the '
        'peer exactly once', () async {
      final svc = (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
          .ffiService;
      svc.debugSetSelfId(bobSelfKey);
      // The shared harness service does not track per-node DHT state.
      svc.debugSetConnected(true);

      await rejoinAndExpectNotReady();
      final probe = 'queued probe ${DateTime.now().microsecondsSinceEpoch}';
      final row = await bob.runWithInstanceAsync(
          () => svc.sendGroupTextWithResult(groupId, probe));
      expect(row.isPending, isTrue,
          reason: 'a text sent while the group is still syncing must be '
              'queued, not handed to a send that reaches nobody');

      await waitWireReady('bob wire-ready again after the rejoin');
      // The native first-confirmed-peer notification also drains, but the
      // shared harness service runs that drain under whichever node is
      // current; drain under bob explicitly (single-flight, so overlapping
      // drains still send once).
      await bob
          .runWithInstanceAsync(() => svc.retryPendingGroupMessages(groupId));
      await waitUntilWithVirtualPump(
        scenario,
        () => aliceCount(probe) >= 1,
        timeout: const Duration(seconds: 45),
        description: 'alice receives the drained text',
        advanceMs: 50,
        iterationsPerInstance: 2,
      );
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 2);
      expect(aliceCount(probe), equals(1),
          reason: 'the queued text must be delivered exactly once');
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
