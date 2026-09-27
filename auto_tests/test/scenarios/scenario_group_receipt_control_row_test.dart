// Group receipt control-row pollution test (plan item I1).
//
// Group receipts ride the group ACTION control line carrying the legacy
// receipt schema. A peer consumes such a control ONLY when the referenced
// msgID already exists in its history or altMsgIds
// (BinaryReplacementHistoryHook.shouldConsumeInternalProtocolCustomData, via
// FfiChatService._tryConsumeLegacyActionControl). When that gate FAILS the
// body falls through to ingestInboundGroupText(contentKind: action,
// forceEmit: true) — i.e. the raw receipt JSON is appended to history and
// emitted as a visible ACTION row.
//
// That gate cannot currently be satisfied on a group: the inbound ingest mints
// a RECEIVER-LOCAL msgID ('<ts>_<seq>_<from>_<gid>') and the auto received
// receipt echoes exactly that id, which no other member has ever seen. This
// test pins the observable consequence: after ordinary group traffic, NO
// peer's group history may contain a control-JSON row.
//
// Mode-aware: runs wall-clock by default and under RUN_VIRTUAL=1.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_add_opt_enum.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

/// True when [text] is one of the internal control payloads that ride the
/// group ACTION line (receipt / reaction). Those must never surface as rows.
bool _isControlJson(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('{')) return false;
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return false;
  }
  if (decoded is! Map) return false;
  final type = decoded['type'];
  return type == 'receipt' || type == 'reaction';
}

String _describe(ChatMessage m) =>
    'kind=${m.contentKind.name} self=${m.isSelf} from=${m.fromUserId} '
    'text=${m.text.substring(0, m.text.length.clamp(0, 120))}';

void main() {
  group('Group Receipt Control Row Tests', () {
    late TestScenario scenario;
    late TestNode founder;
    late TestNode member1;
    late TestNode member2;
    String? groupId;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['founder', 'member1', 'member2']);
      founder = scenario.getNode('founder')!;
      member1 = scenario.getNode('member1')!;
      member2 = scenario.getNode('member2')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([
        founder.login(),
        member1.login(),
        member2.login(),
      ]);
      await waitUntil(
        () => founder.loggedIn && member1.loggedIn && member2.loggedIn,
        timeout: const Duration(seconds: 15),
        description: 'all nodes logged in',
      );

      await configureLocalBootstrapVirtual(scenario);

      founder.enableAutoAccept();
      member1.enableAutoAccept();
      member2.enableAutoAccept();

      // Group invites ride the friend link, so both members must be friends
      // of the founder before the invite is sent.
      // No explicit friend-CONNECTION wait here: on a 3-node wall-clock mesh
      // the second friendship reliably lags 30s+ behind the first, and the
      // invite retry loop below is the sanctioned way to absorb that (same
      // shape as scenario_group_moderation_test).
      await establishFriendshipVirtual(scenario, founder, member1,
          timeout: const Duration(seconds: 60));
      await establishFriendshipVirtual(scenario, founder, member2,
          timeout: const Duration(seconds: 60));

      final createResult = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.createGroup(
            groupType: 'kTIMGroup_Private',
            groupName: 'Receipt Control Row',
            addOpt: GroupAddOptTypeEnum.V2TIM_GROUP_ADD_ANY,
          ));
      expect(createResult.code, equals(0),
          reason: 'createGroup failed: ${createResult.desc}');
      groupId = createResult.data;
      expect(groupId, isNotNull);

      for (final member in [member1, member2]) {
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
            reason: 'a member never received onGroupInvited after 5 retries');
        await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
        final joinResult = await member.runWithInstanceAsync(() async =>
            TIMManager.instance.joinGroup(groupID: groupId!, message: ''));
        expect(joinResult.code, equals(0),
            reason: 'joinGroup failed: ${joinResult.code}');
        final inGroup = await waitUntilFounderSeesMemberInGroupVirtual(
          scenario,
          founder,
          member,
          groupId!,
          timeout: const Duration(seconds: 25),
        );
        expect(inGroup, isNotNull,
            reason: 'founder must see the member before sending group text');
      }
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    /// The founder's view of the group: member key -> proven friend (upper
    /// case), for every member except the founder itself.
    Future<Map<String, String?>> founderMemberFriends() async {
      final svc =
          (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
              .ffiService;
      final founderPk = founder.getPublicKey().toUpperCase();
      final list = await founder.runWithInstanceAsync(() async =>
          TIMGroupManager.instance.getGroupMemberList(
            groupID: groupId!,
            filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
            nextSeq: '0',
            count: 100,
          ));
      final out = <String, String?>{};
      for (final m in list.data?.memberInfoList ?? const []) {
        final key = m.userID;
        if (key.length < 64 || key.toUpperCase().startsWith(founderPk)) {
          continue;
        }
        out[key] = founder
            .runWithInstance(() => svc.friendForGroupMemberKey(key))
            ?.toUpperCase();
      }
      return out;
    }

    // MM-6 end to end: the founder is friends with both members, so each
    // member's per-group key must resolve to that friend (hint over the friend
    // channel -> challenge -> NGC private proof). Pins that the bounded,
    // index-based matcher still finds every legitimate member.
    test('MM-6: the founder resolves each member key to its friend', () async {
      final expected = {
        member1.getPublicKey().toUpperCase(),
        member2.getPublicKey().toUpperCase(),
      };
      var resolved = <String, String?>{};
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline)) {
        resolved = await founderMemberFriends();
        if (resolved.values.whereType<String>().toSet().containsAll(expected)) {
          break;
        }
        await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 2);
        if (!shouldRunVirtual) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      // ignore: avoid_print
      print('[mm6] founder member->friend: $resolved');
      expect(resolved.values.whereType<String>().toSet(), equals(expected),
          reason: 'every member key must be proven to exactly its friend');
    }, timeout: const Timeout(Duration(seconds: 150)));

    // MM-6 confidentiality (the leak fixed on 2026-09-23).
    //
    // A friend's challenge names "the challenger's per-group key", and that
    // value is whatever the friend put in the packet. Per-group keys are
    // visible to every member, so a friend can name ANY member -- and we still
    // have to answer, because the honest flow cannot tell the two apart in
    // time (the challenge is fired from the peer-join path, before the asker's
    // own hint has arrived, and a challenger never retries; see the MM-6 block
    // comment in V2TIMManagerImpl.cpp). What must hold instead is that the
    // answer is readable ONLY by the friend that asked.
    //
    // Here member1 -- a friend of the founder -- names member2's per-group key.
    // The founder answers, to member2. member2 must get an opaque box of
    // exactly the v2 size, must NOT find member1's long-term key (nor its own,
    // nor the founder's) anywhere in it, and must not resolve anything from it.
    test('MM-6: a proof for one friend is unreadable by the member it names',
        () async {
      final lib = ffi_lib.Tim2ToxFfi.open();

      // The crafted challenge is a test-only FFI hook, compiled in only with
      // -DTIM2TOX_ENABLE_TEST_HOOKS=ON (build_ffi.sh does that; app/CI builds
      // do not). Without it this case cannot be constructed at all.
      final sendCraftedChallenge = lib.mm6SendCraftedChallengeNative;
      if (sendCraftedChallenge == null) {
        const message =
            'libtim2tox_ffi lacks tim2tox_ffi_mm6_send_crafted_challenge: '
            'rebuild with -DTIM2TOX_ENABLE_TEST_HOOKS=ON (build_ffi.sh, or '
            'toxee tool/ci/build_tim2tox.sh --enable-test-hooks)';
        // A suite that is SUPPOSED to have the hook (every CI job running this
        // file sets TIM2TOX_EXPECT_TEST_HOOKS=1) must FAIL on its absence: the
        // library was built wrong, and skipping would report green for a
        // confidentiality check that never ran.
        if (Platform.environment['TIM2TOX_EXPECT_TEST_HOOKS'] == '1') {
          fail('TIM2TOX_EXPECT_TEST_HOOKS=1 but $message');
        }
        markTestSkipped(message);
        return;
      }

      Map<String, Object?> mm6Diag(TestNode node) => node.runWithInstance(() {
            final buf = pkgffi.calloc<ffi.Int8>(4096);
            try {
              final n = lib.getMm6DiagNative(0, buf, 4096);
              if (n <= 0) return <String, Object?>{};
              final decoded = jsonDecode(
                  buf.cast<pkgffi.Utf8>().toDartString(length: n));
              return decoded is Map<String, Object?>
                  ? decoded
                  : <String, Object?>{};
            } finally {
              pkgffi.calloc.free(buf);
            }
          });
      int diagInt(Map<String, Object?> d, String key) =>
          (d[key] as num?)?.toInt() ?? 0;

      final member1Pk = member1.getPublicKey().toUpperCase();
      final member2Pk = member2.getPublicKey().toUpperCase();
      final founderPk = founder.getPublicKey().toUpperCase();
      final proven = await founderMemberFriends();
      final member2Key = proven.entries
          .where((e) => e.value == member2Pk)
          .map((e) => e.key)
          .firstOrNull;
      expect(member2Key, isNotNull,
          reason: 'needs the member key the MM-6 test proved');

      final founderBefore = mm6Diag(founder);
      final victimBefore = mm6Diag(member2);

      // The one packet shape the honest API cannot produce: member1 challenges
      // the founder while claiming member2's per-group key as its own.
      final sent = member1.runWithInstance(() {
        final gid = groupId!.toNativeUtf8();
        final friendKey = founderPk.toNativeUtf8();
        final claimed = member2Key!.toNativeUtf8();
        try {
          return sendCraftedChallenge(0, gid, friendKey, claimed);
        } finally {
          pkgffi.malloc.free(gid);
          pkgffi.malloc.free(friendKey);
          pkgffi.malloc.free(claimed);
        }
      });
      expect(sent, equals(1), reason: 'the crafted challenge must go out');

      var founderAfter = founderBefore;
      var victimAfter = victimBefore;
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        founderAfter = mm6Diag(founder);
        victimAfter = mm6Diag(member2);
        if (diagInt(victimAfter, 'proofsIn') >
            diagInt(victimBefore, 'proofsIn')) {
          break;
        }
        await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 2);
        if (!shouldRunVirtual) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      // ignore: avoid_print
      print('[mm6] founder diag: $founderAfter');
      // ignore: avoid_print
      print('[mm6] named-member diag: $victimAfter');

      expect(diagInt(founderAfter, 'proofsSent'),
          greaterThanOrEqualTo(diagInt(founderBefore, 'proofsSent') + 1),
          reason: 'the founder still answers whatever key the friend names');
      expect(diagInt(victimAfter, 'proofsIn'),
          greaterThanOrEqualTo(diagInt(victimBefore, 'proofsIn') + 1),
          reason: 'the named member is the one that receives the answer');
      // The strict one: being named must teach the member nothing.
      expect(diagInt(victimAfter, 'proofsAccepted'),
          equals(diagInt(victimBefore, 'proofsAccepted')),
          reason: 'nothing may be proven to the member that was merely named');
      expect(diagInt(victimAfter, 'proofsRejected'),
          greaterThanOrEqualTo(diagInt(victimBefore, 'proofsRejected') + 1),
          reason: 'it must be rejected, not silently half-processed');

      // The payload itself: a v2 box (24-byte nonce + 160-byte plaintext +
      // 16-byte MAC = 200 bytes), with no identity readable in it. Before the
      // fix this was "nonce || member1's long-term public key" in the clear.
      final payload =
          (victimAfter['lastProofPayloadHex'] as String? ?? '').toUpperCase();
      expect(payload.length, equals(200 * 2),
          reason: 'MM-6 proof v2 is a fixed-size sealed box');
      for (final secret in <String>[member1Pk, member2Pk, founderPk]) {
        expect(payload.contains(secret), isFalse,
            reason: 'no long-term key may be readable in the proof payload');
      }
      expect(payload.contains(member2Key!.toUpperCase()), isFalse,
          reason: 'not even the per-group key it was addressed to');

      // ... and the named member learns no mapping from it.
      final svc = (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
          .ffiService;
      for (final key in proven.keys) {
        final resolvedTo =
            member2.runWithInstance(() => svc.friendForGroupMemberKey(key))
                ?.toUpperCase();
        expect(resolvedTo, isNot(equals(member1Pk)),
            reason: 'the crafted challenge must not teach member2 about '
                'member1 (key $key)');
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    // A member can replay one valid kind-2 receipt as often as it likes. The
    // receiving native side must forward it ONCE (per group, authenticated
    // sender, msgID and receipt type); a different type or msgID is not a
    // replay. Counted at Dart's control ingest, before any authorization gate.
    test('a replayed private group receipt reaches Dart once', () async {
      final svc =
          (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
              .ffiService;
      final member1Pk = member1.getPublicKey().toUpperCase();
      final member1Key = (await founderMemberFriends())
          .entries
          .where((e) => e.value == member1Pk)
          .map((e) => e.key)
          .firstOrNull;
      expect(member1Key, isNotNull,
          reason: 'needs the member key the MM-6 test proved');

      final lib = ffi_lib.Tim2ToxFfi.open();
      int sendReceipt(String msgId, String type) =>
          founder.runWithInstance(() {
            final gid = groupId!.toNativeUtf8();
            final author = member1Key!.toNativeUtf8();
            final id = msgId.toNativeUtf8();
            final kind = type.toNativeUtf8();
            try {
              return lib.sendGroupReceiptNative(0, gid, author, id, kind);
            } finally {
              pkgffi.malloc.free(gid);
              pkgffi.malloc.free(author);
              pkgffi.malloc.free(id);
              pkgffi.malloc.free(kind);
            }
          });
      int received() => svc.receiptDiag['groupReceiptsIn'] ?? 0;
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 2);
          if (!shouldRunVirtual) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }

      await settle(); // drain whatever earlier traffic is still in flight
      final before = received();
      final msgId = 'replay-probe-${DateTime.now().microsecondsSinceEpoch}';
      for (var i = 0; i < 4; i++) {
        expect(sendReceipt(msgId, 'read'), equals(1),
            reason: 'copy ${i + 1} must leave the sender');
      }
      await waitUntilWithVirtualPump(
        scenario,
        () => received() > before,
        timeout: const Duration(seconds: 30),
        description: 'the first copy reaches Dart',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );
      await settle();
      expect(received() - before, equals(1),
          reason: 'three replays of the same receipt must be dropped natively');

      expect(sendReceipt(msgId, 'received'), equals(1));
      expect(sendReceipt('$msgId-b', 'read'), equals(1));
      await waitUntilWithVirtualPump(
        scenario,
        () => received() >= before + 3,
        timeout: const Duration(seconds: 30),
        description: 'distinct receipts are all forwarded',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );
      await settle();
      // ignore: avoid_print
      print('[replay] groupReceiptsIn delta=${received() - before}');
      expect(received() - before, equals(3),
          reason: 'another type or msgID is a new receipt, not a replay');
    }, timeout: const Timeout(Duration(seconds: 150)));

    test('group traffic never leaves a control-JSON row in history', () async {
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final svc = platform.ffiService;
      // The SHARED harness service never runs svc.login(), so _selfId is empty
      // and _sendReceipt's init guard would drop every receipt before it ever
      // reached the wire — the test would then pass vacuously. Pin a non-empty
      // identity; the wire sender itself comes from the per-instance
      // getSelfToxId(), not from this value.
      svc.debugSetSelfId(founder.getToxId().substring(0, 64));

      final probe =
          'control row probe ${DateTime.now().microsecondsSinceEpoch}';
      final sendResult = await founder.runWithInstanceAsync(() async {
        final created =
            TIMMessageManager.instance.createTextMessage(text: probe);
        return TIMMessageManager.instance.sendMessage(
          message: created.messageInfo!,
          receiver: null,
          groupID: groupId!,
          onlineUserOnly: false,
        );
      });
      expect(sendResult.code, equals(0),
          reason: 'group sendMessage failed: ${sendResult.code}');

      // The receivers' poll ingest must land the row first — that ingest is
      // what fires the automatic 'received' receipt we are probing for.
      await waitUntilWithVirtualPump(
        scenario,
        () => svc.getHistory(groupId!).any((m) => m.text == probe),
        timeout: const Duration(seconds: 45),
        description: 'group text reaches the shared history',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );

      // Give every auto receipt time to fly and be ingested by all three
      // instances before inspecting what history holds.
      for (var i = 0; i < 20; i++) {
        await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 2);
        if (!shouldRunVirtual) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }

      final polluted =
          svc.getHistory(groupId!).where((m) => _isControlJson(m.text)).toList();
      // ignore: avoid_print
      print('[i1] group history rows=${svc.getHistory(groupId!).length} '
          'controlRows=${polluted.length} receiptDiag=${svc.receiptDiag}');
      expect(
        polluted,
        isEmpty,
        reason: 'group receipt controls must be CONSUMED, never rendered as '
            'rows. Offending rows: ${polluted.map(_describe).join(' | ')}',
      );
    }, timeout: const Timeout(Duration(seconds: 300)));

    // The live test above CANNOT observe the cross-process case: every node in
    // this harness shares ONE FfiChatService, so a receipt echoing a
    // receiver-minted msgID finds that id in the shared _historyById[gid] and
    // the consume gate passes. In the product each peer is its own process
    // with its own history, so the referenced id is absent and the gate fails.
    // This test reproduces that condition directly at the ingest seam.
    test('a receipt referencing an unknown msgID must not render a row',
        () async {
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final svc = platform.ffiService;

      // A well-formed group receipt from a peer, referencing an id that this
      // node has never seen — exactly what every real cross-process group
      // receipt looks like today.
      final peerPk = member1.getToxId().substring(0, 64);
      final foreignMsgId = '1725300000000_7_${peerPk}_$groupId';
      final body = jsonEncode({
        'type': 'receipt',
        'msgID': foreignMsgId,
        'receiptType': 'received',
        'sender': peerPk,
      });

      final before = svc.getHistory(groupId!).length;
      svc.ingestActionEvent('gaction:$groupId|$peerPk:$body');
      final rows = svc.getHistory(groupId!);
      final polluted = rows.where((m) => _isControlJson(m.text)).toList();
      // ignore: avoid_print
      print('[i1-inject] rows ${before} -> ${rows.length} '
          'controlRows=${polluted.length}');
      expect(
        polluted,
        isEmpty,
        reason: 'a group receipt whose referenced msgID is unknown to this '
            'peer must be dropped, not rendered as an ACTION row. Offending '
            'rows: ${polluted.map(_describe).join(' | ')}',
      );
      expect(rows.length, equals(before),
          reason: 'an unconsumed group control must not append history');
    }, timeout: const Timeout(Duration(seconds: 60)));

    // The parity leg: a group message carries ONE cross-peer identity —
    // toxcore's Tox_Group_Message_Id, minted by the sender and packed into the
    // broadcast. Both sides stamp it into altMsgIds as
    // `gmid:<gid>|<senderPk>|<id>`, receipts echo it, and the tally is re-keyed
    // to the AUTHOR's local row id, which is the id UIKit asks about.
    test('a group read receipt resolves to the author row and tallies readers',
        () async {
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final svc = platform.ffiService;
      final founderPk = founder.getToxId().substring(0, 64);
      svc.debugSetSelfId(founderPk);

      final probe = 'parity probe ${DateTime.now().microsecondsSinceEpoch}';
      final authored = await founder.runWithInstanceAsync(
          () => svc.sendGroupTextWithResult(groupId!, probe));

      // Send side: the author's own row must carry the alias, which means the
      // pseudo id made it out of tox_group_send_message, through the FFI
      // export, and into Dart.
      final authorAlias = authored.altMsgIds
          .where((id) => id.startsWith('gmid:'))
          .toList();
      expect(authorAlias, hasLength(1),
          reason: 'the author row must carry exactly one cross-peer alias; '
              'got ${authored.altMsgIds}');

      // Receive side: the peer's ingest must derive the SAME alias from the
      // polled event line, or no receipt could ever correlate.
      await waitUntilWithVirtualPump(
        scenario,
        () => svc.getHistory(groupId!).any(
            (m) => !m.isSelf && m.text == probe && m.altMsgIds.isNotEmpty),
        timeout: const Duration(seconds: 45),
        description: 'peer row carries the cross-peer alias',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );
      final peerRow = svc
          .getHistory(groupId!)
          .firstWhere((m) => !m.isSelf && m.text == probe);
      expect(peerRow.altMsgIds, equals(authorAlias),
          reason: 'sender and receiver must derive the same alias from the '
              'same tox pseudo id');

      // A real READ receipt over the wire, echoing the alias.
      await member1.runWithInstanceAsync(() => svc.markMessageAsRead(
            groupId!,
            peerRow.msgID!,
            groupID: groupId,
          ));
      await waitUntilWithVirtualPump(
        scenario,
        () => svc.getMessageReaders(authored.msgID!).isNotEmpty,
        timeout: const Duration(seconds: 45),
        description: 'the read receipt tallies against the AUTHOR row id',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );

      // A second reader: the shared-harness ingest dedups the second peer's
      // copy of the same group text, so the second reader's receipt is
      // injected at the ingest seam instead of being produced by the wire.
      final member2Pk = member2.getToxId().substring(0, 64);
      svc.ingestActionEvent(
        'gaction:$groupId|$member2Pk:${jsonEncode({
              'type': 'receipt',
              'msgID': authorAlias.single,
              'receiptType': 'read',
              'sender': member2Pk,
            })}',
      );
      final readers = svc.getMessageReaders(authored.msgID!);
      // ignore: avoid_print
      print('[i1-parity] alias=${authorAlias.single} readers=$readers');
      expect(readers, hasLength(2),
          reason: 'both readers must tally against the author row id');
    }, timeout: const Timeout(Duration(seconds: 300)));

    /// The native `groupReceipts` block of one node's MM-6 diag JSON, as
    /// `{in, refused, replayed, forwarded, perSenderLimit}`. Empty when the
    /// library predates the block.
    Map<String, int> nativeGroupReceiptDiag(TestNode node) {
      final lib = ffi_lib.Tim2ToxFfi.open();
      return node.runWithInstance(() {
        final buf = pkgffi.calloc<ffi.Int8>(8192);
        try {
          final n = lib.getMm6DiagNative(0, buf, 8192);
          if (n <= 0) return <String, int>{};
          final decoded =
              jsonDecode(buf.cast<pkgffi.Utf8>().toDartString(length: n));
          if (decoded is! Map) return <String, int>{};
          final block = decoded['groupReceipts'];
          if (block is! Map) return <String, int>{};
          return <String, int>{
            for (final entry in block.entries)
              if (entry.key is String && entry.value is num)
                entry.key as String: (entry.value as num).toInt(),
          };
        } finally {
          pkgffi.calloc.free(buf);
        }
      });
    }

    // THE PRODUCT TRIGGER. Everything under this used to work on the wire and
    // still never flipped a group read tick, because the only thing that called
    // markMessageAsRead for a group was UIKit's reader trigger — and that fires
    // only for rows whose `needReadReceipt` is true, a flag set on OUTGOING rows
    // that never travels on the wire. An inbound group row is therefore always
    // false, so no member ever reported reading anything.
    //
    // Viewing the conversation is the trigger that does exist: a member that
    // merely OPENS the group (setActivePeer, what a chat tap drives) must wire
    // one READ receipt per unread inbound row, with NO explicit mark-read call
    // anywhere in this test.
    test('opening a group wires READ receipts without an explicit mark-read',
        () async {
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final svc = platform.ffiService;
      final founderPk = founder.getToxId().substring(0, 64);
      svc.debugSetSelfId(founderPk);
      // The on-view walk dispatches on "is this conversation id a known
      // group?"; make that authoritative rather than a side effect of whichever
      // earlier test last ingested into this shared service.
      svc.debugAddKnownGroupForTest(groupId!);

      final probe = 'on-view probe ${DateTime.now().microsecondsSinceEpoch}';
      final authored = await founder.runWithInstanceAsync(
          () => svc.sendGroupTextWithResult(groupId!, probe));
      final authorAlias = authored.altMsgIds
          .firstWhere((id) => id.startsWith('gmid:'), orElse: () => '');
      expect(authorAlias, isNotEmpty,
          reason: 'the author row must carry the cross-peer alias');

      await waitUntilWithVirtualPump(
        scenario,
        () => svc.getHistory(groupId!).any((m) =>
            !m.isSelf && m.text == probe && m.altMsgIds.contains(authorAlias)),
        timeout: const Duration(seconds: 45),
        description: 'the peer row carries the cross-peer alias',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );
      expect(svc.getMessageReaders(authored.msgID!), isEmpty,
          reason: 'nobody has read this row yet — the tick must start empty');

      final diagBefore = Map<String, int>.from(svc.receiptDiag);
      final nativeBefore = nativeGroupReceiptDiag(founder);

      // The whole trigger: member1 opens the conversation. No
      // markMessageAsRead, no needReadReceipt, no new wire field.
      member1.runWithInstance(() => svc.setActivePeer(groupId!));

      await waitUntilWithVirtualPump(
        scenario,
        () => svc.getMessageReaders(authored.msgID!).isNotEmpty,
        timeout: const Duration(seconds: 45),
        description: 'opening the group lands a reader on the author row',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );
      final nativeAfter = nativeGroupReceiptDiag(founder);
      // ignore: avoid_print
      print('[on-view] readers=${svc.getMessageReaders(authored.msgID!)} '
          'diag=${svc.receiptDiag} nativeGroupReceipts=$nativeAfter');

      int delta(String key) =>
          (svc.receiptDiag[key] ?? 0) - (diagBefore[key] ?? 0);
      // (b) the new counters, as deltas across the open.
      expect(delta('groupReceiptsReadOut'), greaterThanOrEqualTo(1),
          reason: 'the open must put at least one READ receipt on the wire');
      expect(delta('groupReceiptsOut'),
          greaterThanOrEqualTo(delta('groupReceiptsReadOut')),
          reason: 'every accepted send counts in the Out total too');
      expect(delta('groupReceiptsIn'), greaterThanOrEqualTo(1),
          reason: 'the author must have received it');
      expect(delta('groupReceiptsRowMatched'), greaterThanOrEqualTo(1),
          reason: 'and it must have resolved to one of the author OWN rows');
      // Nothing was offline here, so neither the no-peer refusal nor the
      // pending queue may have been touched.
      expect(delta('groupReceiptsDroppedNoPeer'), equals(0));
      expect(delta('groupReceiptsQueuedOffline'), equals(0));
      // ... and the same event seen from the native side of the author.
      if (nativeAfter.isNotEmpty) {
        expect((nativeAfter['in'] ?? 0) - (nativeBefore['in'] ?? 0),
            greaterThanOrEqualTo(1),
            reason: 'the receipt reached the per-sender meter');
        expect(
            (nativeAfter['forwarded'] ?? 0) - (nativeBefore['forwarded'] ?? 0),
            greaterThanOrEqualTo(1),
            reason: 'and was forwarded, not refused');
        expect((nativeAfter['refused'] ?? 0) - (nativeBefore['refused'] ?? 0),
            equals(0),
            reason: 'an honest single open is nowhere near the budget');
      }

      // Re-opening must not re-send receipts for rows an open already
      // receipted (the claim set), so a chat the user flips in and out of does
      // not fan out packets per visit.
      final outAfterFirstOpen = svc.receiptDiag['groupReceiptsReadOut'] ?? 0;
      member1.runWithInstance(() => svc.setActivePeer(groupId!));
      await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 2);
      expect(svc.receiptDiag['groupReceiptsReadOut'], equals(outAfterFirstOpen),
          reason: 're-opening the same group must send nothing again');
      svc.setActivePeer(null);
    }, timeout: const Timeout(Duration(seconds: 300)));

    // The offline/absent-author half. SendGroupReceipt fails closed when the
    // row's author is not a live NGC peer, and nothing retried: the on-view walk
    // flags the row read in the same breath, so that reader was lost to the
    // author forever. A row from a key NOBODY in this group holds reproduces
    // exactly that condition (the native side cannot resolve a peer for it),
    // which is what an author that went offline looks like from here.
    test('a READ receipt for an absent author is parked and retried on return',
        () async {
      final svc =
          (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
              .ffiService;
      svc.debugSetSelfId(founder.getToxId().substring(0, 64));
      svc.debugAddKnownGroupForTest(groupId!);

      final ghost = 'AB' * 32; // 64 hex, and no member's per-group key
      final stamp = DateTime.now().microsecondsSinceEpoch;
      founder.runWithInstance(() => svc.ingestInboundGroupText(
            gid: groupId!,
            from: ghost,
            text: 'absent author line $stamp',
            pseudoMsgId: 990001,
          ));

      final before = Map<String, int>.from(svc.receiptDiag);
      int delta(String key) =>
          (svc.receiptDiag[key] ?? 0) - (before[key] ?? 0);

      founder.runWithInstance(() => svc.setActivePeer(groupId!));
      await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 2);
      // ignore: avoid_print
      print('[parked] dropped=${delta('groupReceiptsDroppedNoPeer')} '
          'queued=${delta('groupReceiptsQueuedOffline')}');
      expect(delta('groupReceiptsDroppedNoPeer'), greaterThanOrEqualTo(1),
          reason: 'the native send must report the author as no live peer');
      expect(delta('groupReceiptsQueuedOffline'), greaterThanOrEqualTo(1),
          reason: 'and the READ receipt must be parked, not dropped');
      expect(delta('groupReceiptsReadOut'), equals(0),
          reason: 'nothing can have reached the wire for an absent author');

      // The author "returns": a second line from it proves to Dart that it is a
      // resolvable group peer again, which is the flush point.
      final flushedBefore = svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0;
      founder.runWithInstance(() => svc.ingestInboundGroupText(
            gid: groupId!,
            from: ghost,
            text: 'absent author line $stamp b',
            pseudoMsgId: 990002,
          ));
      await waitUntilWithVirtualPump(
        scenario,
        () =>
            (svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0) >
            flushedBefore,
        timeout: const Duration(seconds: 20),
        description: 'the parked receipt is flushed when the author returns',
        advanceMs: 100,
        iterationsPerInstance: 1,
      );
      // ignore: avoid_print
      print('[parked] flushed='
          '${svc.receiptDiag['groupReceiptsFlushedOnline']} '
          'requeued=${delta('groupReceiptsQueuedOffline')}');
      // Still absent (this key never was a peer), so the retry parks it again
      // rather than losing it — the queue is self-healing, not one-shot.
      expect(delta('groupReceiptsQueuedOffline'), greaterThanOrEqualTo(2),
          reason: 'a retry that still finds no peer must re-park the receipt');
      svc.setActivePeer(null);
    }, timeout: const Timeout(Duration(seconds: 120)));

    /// The parked-group-READ-receipt blob of the account [node] is logged in
    /// as, decoded back into `[gid, author, msgID]` triples. Read straight out
    /// of the injected preferences service, i.e. the DURABLE half — the same
    /// bytes a restart would recover.
    Future<List<List<String>>> parkedQueueOf(TestNode node) async {
      final svc = (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
          .ffiService;
      final scope = node.runWithInstance(() => svc.prefsAccountScopeToxId);
      if (scope == null) return const <List<String>>[];
      final stored = await svc.preferencesService
              ?.getStringList('pending_group_read_receipts_$scope') ??
          const <String>[];
      return stored
          .map((e) => (jsonDecode(e) as List).cast<String>())
          .toList();
    }

    /// Open and close the group once as [node], so every row an earlier leg
    /// left unread is flipped read and claimed. Without this, the next leg's
    /// counter deltas would also contain those rows' receipts.
    Future<void> drainOnViewWalk(TestNode node) async {
      final svc = (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
          .ffiService;
      node.runWithInstance(() => svc.setActivePeer(groupId!));
      for (var i = 0; i < 4; i++) {
        await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 2);
      }
      svc.setActivePeer(null);
    }

    // FIX 1 — the RETRYABLE failure. `SendGroupReceipt` returns 0 both for "this
    // group is not in our map" and for a toxcore send that failed (a group whose
    // transport is down), and Dart used to park only the -3 "author is not a
    // live NGC peer" refusal. Everything else was dropped while the on-view walk
    // flagged the row read in the same breath — so a mobile user who opens a
    // group during a connection drop lost those ticks for good, with a retry
    // that would have worked seconds later.
    //
    // HOW THIS IS DRIVEN HONESTLY: 0 is ALL Dart can see — one code for several
    // causes is the defect — and this harness has no seam to sever a live
    // group's transport mid-run. So the 0 is produced by the other input the
    // native side rejects with the SAME code: an author key that is not 64 hex.
    // The direct probe first pins that the code really is 0 and not -3, which is
    // what makes this leg exercise the new rule instead of the old one. What is
    // NOT faked: the native send, the park, the flush trigger and the retry are
    // all the production ones.
    test('a READ receipt lost to a send FAILURE, not an absent author, is '
        'parked and retried', () async {
      final svc =
          (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
              .ffiService;
      svc.debugSetSelfId(founder.getToxId().substring(0, 64));
      svc.debugAddKnownGroupForTest(groupId!);
      await drainOnViewWalk(founder);

      final lib = ffi_lib.Tim2ToxFfi.open();
      // 62 hex: real group, real msgID, real receipt type — and still
      // unaddressable, so the native side reports the GENERIC failure.
      final failingAuthor = 'CD' * 31;
      final probe = founder.runWithInstance(() {
        final gid = groupId!.toNativeUtf8();
        final author = failingAuthor.toNativeUtf8();
        final id = 'send-failure-probe'.toNativeUtf8();
        final kind = 'read'.toNativeUtf8();
        try {
          return lib.sendGroupReceiptNative(0, gid, author, id, kind);
        } finally {
          pkgffi.malloc.free(gid);
          pkgffi.malloc.free(author);
          pkgffi.malloc.free(id);
          pkgffi.malloc.free(kind);
        }
      });
      expect(probe, equals(0),
          reason: 'this leg needs the GENERIC failure code: -3 is the case the '
              'previous leg already covers');

      final stamp = DateTime.now().microsecondsSinceEpoch;
      founder.runWithInstance(() => svc.ingestInboundGroupText(
            gid: groupId!,
            from: failingAuthor,
            text: 'send failure line $stamp',
            pseudoMsgId: 991001,
          ));

      final before = Map<String, int>.from(svc.receiptDiag);
      int delta(String key) =>
          (svc.receiptDiag[key] ?? 0) - (before[key] ?? 0);

      founder.runWithInstance(() => svc.setActivePeer(groupId!));
      await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 2);
      // ignore: avoid_print
      print('[park-on-failure] queued=${delta('groupReceiptsQueuedOffline')} '
          'droppedNoPeer=${delta('groupReceiptsDroppedNoPeer')} '
          'readOut=${delta('groupReceiptsReadOut')}');
      expect(delta('groupReceiptsQueuedOffline'), greaterThanOrEqualTo(1),
          reason: 'a 0 is not a definite success: the receipt must be parked, '
              'not dropped with the row already flagged read');
      expect(delta('groupReceiptsDroppedNoPeer'), equals(0),
          reason: 'this park was NOT the -3 refusal — the no-peer counter must '
              'keep meaning exactly what its name says');
      expect(delta('groupReceiptsReadOut'), equals(0),
          reason: 'nothing reached the wire');

      // The durable half must hold it too, or a restart would still lose it.
      final parked = await parkedQueueOf(founder);
      expect(parked.where((t) => t[1] == failingAuthor), isNotEmpty,
          reason: 'the park must survive a restart: $parked');

      // The retry point: a second line from that author. It is still
      // unaddressable, so the retry fails again and must RE-park rather than
      // drop — the queue is self-healing, not one-shot.
      final flushedBefore = svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0;
      founder.runWithInstance(() => svc.ingestInboundGroupText(
            gid: groupId!,
            from: failingAuthor,
            text: 'send failure line $stamp b',
            pseudoMsgId: 991002,
          ));
      await waitUntilWithVirtualPump(
        scenario,
        () =>
            (svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0) >
            flushedBefore,
        timeout: const Duration(seconds: 20),
        description: 'the parked receipt is retried when the author speaks',
        advanceMs: 100,
        iterationsPerInstance: 1,
      );
      // ignore: avoid_print
      print('[park-on-failure] retried, requeued='
          '${delta('groupReceiptsQueuedOffline')}');
      expect(delta('groupReceiptsQueuedOffline'), greaterThanOrEqualTo(2),
          reason: 'a retry that fails again must re-park the receipt');
      expect(delta('groupReceiptsDroppedNoPeer'), equals(0),
          reason: 'still not a -3 anywhere in this leg');
      // And the RE-park must be durable too (codex): the flush clears the blob
      // before it sends, so a re-park that only landed in memory would make the
      // first retry the last one a restart could ever make.
      for (var i = 0; i < 4; i++) {
        await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 1);
      }
      final parkedAfterRetry = (await parkedQueueOf(founder))
          .where((t) => t[1] == failingAuthor)
          .map((t) => t[2])
          .toSet();
      // ignore: avoid_print
      print('[park-on-failure] durable after retry=${parkedAfterRetry.length}');
      expect(parkedAfterRetry, isNotEmpty,
          reason: 'the re-park has to reach the durable half as well');
      svc.setActivePeer(null);
    }, timeout: const Timeout(Duration(seconds: 150)));

    // FIX 3 — one group open parks under ONE prefs write. Each park used to
    // rewrite the whole blob, so a walk near the 64-pair x 200-entry bound
    // serialized and pushed a large blob across the mobile prefs bridge up to 50
    // times for a single chat tap. The counter asserted here is incremented at
    // the real `setStringList` call site, so this measures writes, not intent.
    test('parking a 50-row walk writes the queue once, completely', () async {
      final svc =
          (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
              .ffiService;
      svc.debugSetSelfId(founder.getToxId().substring(0, 64));
      svc.debugAddKnownGroupForTest(groupId!);
      await drainOnViewWalk(founder);

      // 50 unread inbound rows from one unaddressable author: the walk's bound
      // is 50, so this is the worst case one open can produce.
      final burstAuthor = 'CE' * 31; // 62 hex -> the generic failure again
      final stamp = DateTime.now().microsecondsSinceEpoch;
      const rows = 50;
      for (var i = 0; i < rows; i++) {
        founder.runWithInstance(() => svc.ingestInboundGroupText(
              gid: groupId!,
              from: burstAuthor,
              text: 'burst line $stamp #$i',
              pseudoMsgId: 992000 + i,
            ));
      }

      final writesBefore = svc.debugGroupReadReceiptQueueWrites;
      final queuedBefore = svc.receiptDiag['groupReceiptsQueuedOffline'] ?? 0;
      founder.runWithInstance(() => svc.setActivePeer(groupId!));
      await waitUntilWithVirtualPump(
        scenario,
        () => svc.debugGroupReadReceiptQueueWrites > writesBefore,
        timeout: const Duration(seconds: 20),
        description: 'the walk persists its parks',
        advanceMs: 100,
        iterationsPerInstance: 1,
      );
      // Let anything that was going to write a second time do it.
      for (var i = 0; i < 6; i++) {
        await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 1);
      }

      final writes = svc.debugGroupReadReceiptQueueWrites - writesBefore;
      final queued =
          (svc.receiptDiag['groupReceiptsQueuedOffline'] ?? 0) - queuedBefore;
      final parked = (await parkedQueueOf(founder))
          .where((t) => t[1] == burstAuthor)
          .map((t) => t[2])
          .toSet();
      // ignore: avoid_print
      print('[coalesce] rows=$rows parked=${parked.length} queued=$queued '
          'prefsWrites=$writes');
      expect(queued, equals(rows),
          reason: 'every row of the walk must park (this is the burst)');
      expect(writes, equals(1),
          reason: 'the whole burst must cost ONE whole-blob prefs write, not '
              'one per park');
      expect(parked, hasLength(rows),
          reason: 'coalescing must not lose a single parked id: the durable '
              'half has to hold the complete walk');
      svc.setActivePeer(null);
    }, timeout: const Timeout(Duration(seconds: 150)));

    // FIX 2 — the queue is per ACCOUNT, not per (group, author). This harness
    // routes every node through ONE FfiChatService, which is exactly the
    // condition the bug needed: with a queue keyed only by (group, author), a
    // line from the author observed on ANOTHER account flushed the first
    // account's parked receipts from the wrong native instance, and the author
    // credited the read to a reader that never read anything.
    test('one account must not flush another account parked receipts',
        () async {
      final svc =
          (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
              .ffiService;
      svc.debugSetSelfId(founder.getToxId().substring(0, 64));
      svc.debugAddKnownGroupForTest(groupId!);
      await drainOnViewWalk(founder);

      final founderScope =
          founder.runWithInstance(() => svc.prefsAccountScopeToxId);
      final member1Scope =
          member1.runWithInstance(() => svc.prefsAccountScopeToxId);
      expect(founderScope, isNotNull);
      expect(member1Scope, isNotNull);
      expect(founderScope, isNot(equals(member1Scope)),
          reason: 'the two instances must resolve to two account scopes, or '
              'this leg cannot tell the accounts apart at all');

      // FOUNDER parks a receipt: a row from a key nobody in the group holds.
      final ghost = 'BC' * 32;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      founder.runWithInstance(() => svc.ingestInboundGroupText(
            gid: groupId!,
            from: ghost,
            text: 'scoped park line $stamp',
            pseudoMsgId: 993001,
          ));
      final queuedBefore = svc.receiptDiag['groupReceiptsQueuedOffline'] ?? 0;
      founder.runWithInstance(() => svc.setActivePeer(groupId!));
      await waitUntilWithVirtualPump(
        scenario,
        () =>
            (svc.receiptDiag['groupReceiptsQueuedOffline'] ?? 0) > queuedBefore,
        timeout: const Duration(seconds: 20),
        description: 'the founder parks a receipt for the absent author',
        advanceMs: 100,
        iterationsPerInstance: 1,
      );
      svc.setActivePeer(null);
      // The park reaches memory synchronously but its prefs write is queued
      // behind the queue's single-writer gate, so wait for the DURABLE half
      // rather than assuming one pump is enough.
      var founderParked = <String>{};
      for (var i = 0; i < 20 && founderParked.isEmpty; i++) {
        await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 1);
        founderParked = (await parkedQueueOf(founder))
            .where((t) => t[1] == ghost)
            .map((t) => t[2])
            .toSet();
      }
      expect(founderParked, isNotEmpty,
          reason: 'the founder must have something parked to be stolen; '
              'durable queue = ${await parkedQueueOf(founder)}');
      expect(await parkedQueueOf(member1), isEmpty,
          reason: 'member1 has parked nothing of its own');

      // MEMBER1 now observes that same author speaking in that same group —
      // the flush trigger. It must move NOTHING: the parked receipt belongs to
      // the founder, and sending it from member1 instance would report the
      // wrong reader to the author.
      final flushedBefore = svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0;
      member1.runWithInstance(() => svc.ingestInboundGroupText(
            gid: groupId!,
            from: ghost,
            text: 'scoped park line $stamp seen by member1',
            pseudoMsgId: 993002,
          ));
      for (var i = 0; i < 8; i++) {
        await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 1);
      }
      // ignore: avoid_print
      print('[scoped] flushedDelta='
          '${(svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0) - flushedBefore} '
          'founderParked=${founderParked.length}');
      expect(svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0,
          equals(flushedBefore),
          reason: 'the other account observing the author must not flush this '
              'account queue');
      expect(
          (await parkedQueueOf(founder))
              .where((t) => t[1] == ghost)
              .map((t) => t[2])
              .toSet(),
          equals(founderParked),
          reason: 'and the founder durable queue must be untouched');

      // AND THE SAME THING WITH AN EMPTY MEMORY HALF (codex): the assertion
      // above would also hold if the per-account HYDRATION memo were broken,
      // because it flushed from memory. Forget the memory half and the memo —
      // what a restart leaves — so the next observation has to decide from the
      // DURABLE half, per account. member1 must hydrate its own (empty) key and
      // still flush nothing.
      svc.debugForgetGroupReadReceiptQueueForTest();
      member1.runWithInstance(() => svc.ingestInboundGroupText(
            gid: groupId!,
            from: ghost,
            text: 'scoped park line $stamp seen by member1 after a restart',
            pseudoMsgId: 993003,
          ));
      for (var i = 0; i < 8; i++) {
        await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 1);
      }
      expect(svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0,
          equals(flushedBefore),
          reason: 'recovering the queue from disk must recover the OBSERVING '
              'account queue, and member1 parked nothing');
      expect(
          (await parkedQueueOf(founder))
              .where((t) => t[1] == ghost)
              .map((t) => t[2])
              .toSet(),
          equals(founderParked),
          reason: 'the founder durable queue must still be intact after the '
              'other account hydrated');

      // The control: the OWNING account observing the same author does flush —
      // now from the durable half alone, so the leg proves scoping and recovery
      // rather than a dead queue.
      founder.runWithInstance(() => svc.ingestInboundGroupText(
            gid: groupId!,
            from: ghost,
            text: 'scoped park line $stamp seen by the founder',
            pseudoMsgId: 993004,
          ));
      await waitUntilWithVirtualPump(
        scenario,
        () =>
            (svc.receiptDiag['groupReceiptsFlushedOnline'] ?? 0) >
            flushedBefore,
        timeout: const Duration(seconds: 20),
        description: 'the owning account does flush its own parks',
        advanceMs: 100,
        iterationsPerInstance: 1,
      );
      svc.setActivePeer(null);
    }, timeout: const Timeout(Duration(seconds: 150)));

    // Per-sender metering of INBOUND group receipts. The replay filter only
    // stops the same receipt twice; distinct msgIDs from one member were
    // unbounded, and each one costs a Dart event plus two history scans, so the
    // native side meters them per authenticated sender.
    //
    // WHAT THIS LEG DOES **NOT** ASSERT, AND WHY. It used to read
    // `perSenderLimit` from the diag and send `limit * 2` to watch the excess be
    // refused. That stopped being honest when the budget moved into its own
    // table and the cap was re-derived to 4096 (one `markGroupMessageAsRead`
    // call can emit up to the loaded window, and UIKit calls it on every chat
    // open): out-sending it now means 8192 native sends, which take longer than
    // the 60s rate window they have to fit inside — the window rolls over
    // mid-flood, the counter resets, and `refused >= 1` passes or fails by luck.
    // There is no seam to lower the cap or to fill the sender table honestly
    // (that would need a native test hook, which is not in this library), and
    // faking the refusal would assert nothing about the meter. So this leg
    // asserts the two things it CAN observe deterministically: an honest burst
    // is metered and forwarded in full and refuses nothing, and the cap is wide
    // enough that a single chat open can never refuse its own receipts — the
    // invariant the re-derivation was for. The refusal path itself is covered by
    // the native side's own reasoning, not by this file; making it testable
    // needs a hook that sets the cap.
    test('the per-sender receipt meter counts an honest burst and refuses none',
        () async {
      final svc =
          (TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform)
              .ffiService;
      final member1Pk = member1.getPublicKey().toUpperCase();
      final member1Key = (await founderMemberFriends())
          .entries
          .where((e) => e.value == member1Pk)
          .map((e) => e.key)
          .firstOrNull;
      expect(member1Key, isNotNull,
          reason: 'needs the member key the MM-6 test proved');

      final lib = ffi_lib.Tim2ToxFfi.open();
      final baseline = nativeGroupReceiptDiag(member1);
      final limit = baseline['perSenderLimit'] ?? 0;
      // FAIL, never skip (codex): the `groupReceipts` diag block is part of the
      // ORDINARY library — `Mm6DiagJson` is not behind a test hook — so a
      // library that cannot report the budget is a library built from the wrong
      // tree, and skipping here would report green for the metering assertions
      // below while they never ran. No env gate for the same reason: there is no
      // legitimate configuration in which this block is absent.
      expect(limit, greaterThan(0),
          reason: 'libtim2tox_ffi reports no groupReceipts.perSenderLimit — it '
              'predates the group-receipt meter. Rebuild it (build_ffi.sh); do '
              'not run this suite against a stale library.');

      int sendReceipt(String msgId) => founder.runWithInstance(() {
            final gid = groupId!.toNativeUtf8();
            final author = member1Key!.toNativeUtf8();
            final id = msgId.toNativeUtf8();
            final kind = 'read'.toNativeUtf8();
            try {
              return lib.sendGroupReceiptNative(0, gid, author, id, kind);
            } finally {
              pkgffi.malloc.free(gid);
              pkgffi.malloc.free(author);
              pkgffi.malloc.free(id);
              pkgffi.malloc.free(kind);
            }
          });

      // THE CAP ITSELF: a single chat open must never be able to refuse its own
      // receipts. `Tim2ToxSdkPlatform.markGroupMessageAsRead` can emit one per
      // inbound row of the loaded window (1000 messages in memory) on a first
      // open, and FfiChatService's on-view walk up to 50 — so a cap under the
      // window size would make the product refuse honest readers.
      expect(limit, greaterThanOrEqualTo(1000),
          reason: 'the per-sender cap must cover the largest burst one chat '
              'open can honestly emit; got $limit');

      // Distinct msgIDs, so the replay filter is not what accounts for them,
      // and a burst small enough to complete far inside the 60s rate window.
      final stamp = DateTime.now().microsecondsSinceEpoch;
      const burst = 24;
      var sent = 0;
      for (var i = 0; i < burst; i++) {
        if (sendReceipt('budget-probe-$stamp-$i') == 1) sent++;
      }
      expect(sent, equals(burst),
          reason: 'every probe must leave the sender: sent $sent of $burst');

      var after = baseline;
      await waitUntilWithVirtualPump(
        scenario,
        () {
          after = nativeGroupReceiptDiag(member1);
          return (after['in'] ?? 0) - (baseline['in'] ?? 0) >= sent;
        },
        timeout: const Duration(seconds: 60),
        description: 'every receipt reaches the meter',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );
      final forwarded =
          (after['forwarded'] ?? 0) - (baseline['forwarded'] ?? 0);
      final refused = (after['refused'] ?? 0) - (baseline['refused'] ?? 0);
      final metered = (after['in'] ?? 0) - (baseline['in'] ?? 0);
      // ignore: avoid_print
      print('[budget] sent=$sent limit=$limit metered=$metered '
          'forwarded=$forwarded refused=$refused');

      expect(metered, greaterThanOrEqualTo(sent),
          reason: 'the meter must see every receipt that arrives — that is what '
              'makes a cap enforceable at all');
      expect(refused, equals(0),
          reason: 'an honest burst this far inside the window must not be '
              'refused');
      expect(forwarded, greaterThanOrEqualTo(sent),
          reason: 'and all of it must be forwarded to Dart');
    }, timeout: const Timeout(Duration(seconds: 300)));

    // The PLATFORM reader trigger, and the load it used to put on the meter
    // above (codex): UIKit calls `markGroupMessageAsRead` on every group chat
    // open, and it walked the whole loaded window sending a READ receipt for
    // every inbound row — no claim, no `isRead` skip — so each visit re-paid for
    // the entire window (up to `_maxMessagesInMemory` private packets per tap,
    // per member). It must pay once per ROW, not once per OPEN.
    test('markGroupMessageAsRead pays for each row once, not once per open',
        () async {
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final svc = platform.ffiService;
      svc.debugSetSelfId(founder.getToxId().substring(0, 64));
      svc.debugAddKnownGroupForTest(groupId!);

      // A REAL member key, so the receipts actually reach the wire: a leg where
      // every send fails could not tell "claimed" from "never sent".
      final member1Pk = member1.getPublicKey().toUpperCase();
      final member1Key = (await founderMemberFriends())
          .entries
          .where((e) => e.value == member1Pk)
          .map((e) => e.key)
          .firstOrNull;
      expect(member1Key, isNotNull,
          reason: 'needs the member key the MM-6 test proved');

      final stamp = DateTime.now().microsecondsSinceEpoch;
      for (var i = 0; i < 2; i++) {
        founder.runWithInstance(() => svc.ingestInboundGroupText(
              gid: groupId!,
              from: member1Key!,
              text: 'platform mark-read line $stamp #$i',
              pseudoMsgId: 994000 + i,
            ));
      }
      await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 2);

      // Everything one row can cost: on the wire, or parked for a retry.
      int spent() => (svc.receiptDiag['groupReceiptsReadOut'] ?? 0) +
          (svc.receiptDiag['groupReceiptsQueuedOffline'] ?? 0);
      final before = spent();
      final first = await founder.runWithInstanceAsync(
          () async => platform.markGroupMessageAsRead(groupID: groupId!));
      expect(first.code, equals(0),
          reason: 'the API contract must not change: ${first.desc}');
      await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 2);
      final afterFirst = spent();
      final second = await founder.runWithInstanceAsync(
          () async => platform.markGroupMessageAsRead(groupID: groupId!));
      expect(second.code, equals(0), reason: second.desc ?? '');
      await pumpTestTick(scenario, advanceMs: 250, iterationsPerInstance: 2);
      final afterSecond = spent();
      // ignore: avoid_print
      print('[platform-mark-read] first=${afterFirst - before} '
          'second=${afterSecond - afterFirst}');
      expect(afterFirst - before, greaterThanOrEqualTo(2),
          reason: 'the two fresh rows must be reported the first time, or this '
              'leg proves nothing about the second');
      expect(afterSecond, equals(afterFirst),
          reason: 'a second open must cost nothing: every row of the window '
              'was already reported once');
    }, timeout: const Timeout(Duration(seconds: 150)));

    // THE RESTART LEG. A C2C read tick survives a relaunch because the receipt
    // flips `isRead` on the row and the row is persisted. The GROUP tick used to
    // vanish: `Tim2ToxSdkPlatform.getMessageReadReceipts` derived readCount
    // purely from `getMessageReaders`, a live tally keyed by READER IDENTITY
    // that starts empty on every launch. So a user who saw "read" on their own
    // group message, restarted, and reopened the conversation saw it unread
    // again.
    //
    // The fact that somebody read it IS persisted, on the author's own row and
    // through the same flags C2C uses. The reader identities are NOT, and must
    // not be: a member's per-group key rotates, so a stored reader set would
    // de-anonymize who read what across restarts. So only the boolean comes
    // back, and "at least one member read it" is exactly what the group tick
    // renders.
    //
    // LAST in this group on purpose: it closes and reopens the SHARED history
    // store, which is the only honest way to prove the flag came off disk.
    test('the group read tick survives a history-store restart', () async {
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final svc = platform.ffiService;
      svc.debugSetSelfId(founder.getToxId().substring(0, 64));
      svc.debugAddKnownGroupForTest(groupId!);

      final probe = 'restart tick probe ${DateTime.now().microsecondsSinceEpoch}';
      final authored = await founder.runWithInstanceAsync(
          () => svc.sendGroupTextWithResult(groupId!, probe));
      final localId = authored.msgID!;
      final alias = authored.altMsgIds
          .firstWhere((id) => id.startsWith('gmid:'), orElse: () => '');
      expect(alias, isNotEmpty,
          reason: 'the author row must carry the cross-peer alias — it is the '
              'only id a receipt can reference, and the id the reload has to '
              'be able to find');

      // A member reads it. Injected at the ingest seam (same shape the native
      // group ACTION line delivers, same technique as the second reader in the
      // parity leg above) so this leg does not depend on a second peer's copy
      // of the row surviving the shared-harness dedup.
      final member2Pk = member2.getToxId().substring(0, 64);
      // In the FOUNDER's instance context (codex): applying a receipt runs the
      // pending-receipt flush and its account-scope lookup synchronously off
      // the CURRENT native instance, so ingesting outside it would touch
      // another node's queue.
      expect(
        founder.runWithInstance(
          () => svc.ingestActionEvent(
            'gaction:$groupId|$member2Pk:${jsonEncode({
                  'type': 'receipt',
                  'msgID': alias,
                  'receiptType': 'read',
                  'sender': member2Pk,
                })}',
          ),
        ),
        isTrue,
        reason: 'a receipt is consumed as a control, never rendered',
      );
      await waitUntilWithVirtualPump(
        scenario,
        () => svc.getMessageReaders(localId).isNotEmpty,
        timeout: const Duration(seconds: 30),
        description: 'the READ receipt lands on the author row',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );
      expect(
        svc.getHistory(groupId!).firstWhere((m) => m.msgID == localId).isRead,
        isTrue,
        reason: 'the receipt must flip the row flag, exactly as C2C does — '
            'that flag IS the persisted half of the tally',
      );

      // The restart: close the store (which flushes what it owes) and reopen a
      // session on the same identity, so everything read back came off disk.
      final MessageHistoryPersistence store = svc.messageHistoryPersistence;
      final owner = (await store.defaultHistoryDirectoryStatus())?.sessionOwner;
      await store.flushPendingSaves();
      await store.dispose();
      expect(store.getHistory(groupId!), isEmpty,
          reason: 'a closed store keeps nothing in memory; anything found '
              'after this came from the file');
      await store.openSession(ownerKey: owner);
      final reloaded = await store.loadHistory(groupId!);
      final restoredRow =
          reloaded.where((m) => m.msgID == localId).toList().single;
      expect(restoredRow.isSelf, isTrue);
      expect(restoredRow.isRead, isTrue,
          reason: "the tick's underlying flag must survive the restart");
      expect(restoredRow.altMsgIds, contains(alias),
          reason: 'and the row must still be findable by the alias a later '
              'receipt would carry');

      // A real relaunch also loses the live tally: that is the state the tick
      // used to be rendered from, and the whole reason it disappeared.
      svc.debugClearReceiptTalliesForTest();
      expect(svc.getMessageReaders(localId), isEmpty);
      expect(svc.isGroupRowReadByAnyMember(localId, groupID: groupId), isTrue,
          reason: 'the persisted fact answers where the tally cannot');

      final receipts = await founder.runWithInstanceAsync(
          () => platform.getMessageReadReceipts(messageIDList: [localId]));
      expect(receipts.code, equals(0), reason: receipts.desc ?? '');
      final receipt = (receipts.data ?? const [])
          .where((r) => r.msgID == localId)
          .toList()
          .single;
      // ignore: avoid_print
      print('[restart-tick] readCount=${receipt.readCount} '
          'unread=${receipt.unreadCount}');
      expect(receipt.readCount ?? 0, greaterThanOrEqualTo(1),
          reason: 'the fork renders the group tick from readCount > 0, so a '
              'restored row must report at least one reader');
      expect(receipt.unreadCount, isNull,
          reason: 'only the boolean was restored: there is no exact count, so '
              'unread must stay unknown rather than be derived from a floor');

      // And the count must NOT become falsely precise again once live receipts
      // resume (codex): a tally rebuilt after a restart is still missing
      // whoever read the row before it, so "members - 1 - readers" remains a
      // guess no matter how many fresh receipts arrive.
      final member1Pk = member1.getToxId().substring(0, 64);
      expect(
        founder.runWithInstance(
          () => svc.ingestActionEvent(
            'gaction:$groupId|$member1Pk:${jsonEncode({
                  'type': 'receipt',
                  'msgID': alias,
                  'receiptType': 'read',
                  'sender': member1Pk,
                })}',
          ),
        ),
        isTrue,
      );
      await waitUntilWithVirtualPump(
        scenario,
        () => svc.getMessageReaders(localId).isNotEmpty,
        timeout: const Duration(seconds: 30),
        description: 'the post-restart receipt rebuilds a partial tally',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );
      final relive = await founder.runWithInstanceAsync(
          () => platform.getMessageReadReceipts(messageIDList: [localId]));
      expect(relive.code, equals(0), reason: relive.desc ?? '');
      final receiptAgain = (relive.data ?? const [])
          .where((r) => r.msgID == localId)
          .toList()
          .single;
      // ignore: avoid_print
      print('[restart-tick] relive readCount=${receiptAgain.readCount} '
          'unread=${receiptAgain.unreadCount}');
      expect(receiptAgain.readCount ?? 0, greaterThanOrEqualTo(1));
      expect(receiptAgain.unreadCount, isNull,
          reason: 'the identities lost at restart stay lost: the rebuilt tally '
              'must not be presented as an exact count');
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
