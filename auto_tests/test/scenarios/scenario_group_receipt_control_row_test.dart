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

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_add_opt_enum.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
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
  });
}
