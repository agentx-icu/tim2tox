// Group receipts between members that know one group under DIFFERENT local
// ids (the author holds it as `tox_4`, the reader as `tox_3`).
//
// The cross-peer alias is `gmid:<local gid>|<author key>|<pseudo id>`, and each
// side stamps it with its own local gid. A receipt echoes the READER's alias,
// so the author used to find no row for it: every such receipt was dropped as
// an "unresolved control" and group rows never reached delivered or read. The
// author now reads the alias in its own group's terms (the group the receipt
// arrived on), keeping the author key and pseudo id as the identity.

import 'dart:convert';
import 'dart:io';

import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_text_elem.dart';
import 'package:test/test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/binary_replacement_history_hook.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

import '../test_fixtures.dart';

/// Our local id for the group.
const _authorGroup = 'tox_4';

/// The reader's local id for the same group.
const _readerGroup = 'tox_3';

/// Another group of ours.
const _otherGroup = 'tox_9';

const _authorKey =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _readerKey =
    'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const _pseudoId = 77;

String _alias(String groupId, {String author = _authorKey, int? pseudo}) =>
    toxGroupMessageAlias(
      groupId: groupId,
      senderPk: author,
      pseudoMsgId: pseudo ?? _pseudoId,
    );

String _receiptBody(String msgID, String receiptType, {String? groupID}) =>
    jsonEncode({
      'type': 'receipt',
      'msgID': msgID,
      'receiptType': receiptType,
      'sender': _readerKey,
      if (groupID != null) 'groupID': groupID,
    });

String _groupReceipt(String arrivedOn, String msgID, String receiptType) =>
    'gaction:$arrivedOn|$_readerKey:${_receiptBody(msgID, receiptType)}';

void main() {
  group('rebaseToxGroupMessageAlias', () {
    test('re-scopes the gid and keeps author key and pseudo id', () {
      expect(
        rebaseToxGroupMessageAlias(_alias(_readerGroup),
            groupId: _authorGroup),
        _alias(_authorGroup),
      );
      expect(
        rebaseToxGroupMessageAlias(_alias(_authorGroup),
            groupId: _authorGroup),
        _alias(_authorGroup),
        reason: 'ids that already agree are unchanged',
      );
    });

    test('accepts the uint32 bounds, a lowercase key and a gid with a pipe',
        () {
      for (final pseudo in [0, 0xFFFFFFFF]) {
        expect(
          rebaseToxGroupMessageAlias('gmid:$_readerGroup|$_authorKey|$pseudo',
              groupId: _authorGroup),
          _alias(_authorGroup, pseudo: pseudo),
        );
      }
      expect(
        rebaseToxGroupMessageAlias(
            'gmid:$_readerGroup|${_authorKey.toLowerCase()}|$_pseudoId',
            groupId: _authorGroup),
        _alias(_authorGroup),
      );
      expect(
        rebaseToxGroupMessageAlias('gmid:a|b|$_authorKey|$_pseudoId',
            groupId: _authorGroup),
        _alias(_authorGroup),
      );
    });

    test('rejects anything that is not a strict alias', () {
      final key63 = _authorKey.substring(1);
      for (final id in [
        'local-row-id',
        'bind:${'0' * 64}',
        'gmid:|$_authorKey|$_pseudoId',
        'gmid:$_readerGroup|$key63|$_pseudoId',
        'gmid:$_readerGroup|${_authorKey}A|$_pseudoId',
        'gmid:$_readerGroup|$_authorKey|4294967296',
        'gmid:$_readerGroup|$_authorKey|99999999999',
        'gmid:$_readerGroup|$_authorKey|-1',
        'gmid:$_readerGroup|$_authorKey|+1',
        'gmid:$_readerGroup|$_authorKey|01',
        'gmid:$_readerGroup|$_authorKey|',
        'gmid:$_readerGroup|$_authorKey|77x',
        'gmid:$_readerGroup|$_authorKey|77|5',
        'gmid:$_readerGroup|$_authorKey',
      ]) {
        expect(rebaseToxGroupMessageAlias(id, groupId: _authorGroup), isNull,
            reason: id);
      }
    });
  });

  group('receipt from a member with another local group id', () {
    late Directory tempDir;
    late MessageHistoryPersistence persistence;
    late FfiChatService service;

    setUpAll(setupTestEnvironment);
    tearDownAll(teardownTestEnvironment);

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('group_receipt_gid_');
      await Directory('${tempDir.path}/history').create(recursive: true);
      persistence = MessageHistoryPersistence(
        historyDirectory: '${tempDir.path}/history',
      );
      service = FfiChatService(
        preferencesService: MockPreferencesService(),
        loggerService: MockLoggerService(),
        bootstrapService: MockBootstrapService(),
        messageHistoryPersistence: persistence,
        queueFilePath: '${tempDir.path}/offline_queue.json',
      );
    });

    tearDown(() async {
      await BinaryReplacementHistoryHook.uninstallStandalone();
      await service.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Waits for [groupId]'s history file to satisfy [predicate]: receipt
    /// saves are unawaited, and ending a test before the write lands lets
    /// tearDown delete the directory under it.
    Future<void> waitForHistoryFile(
      String groupId,
      bool Function(String contents) predicate,
    ) async {
      final file = File('${tempDir.path}/history/$groupId.json');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (await file.exists() && predicate(await file.readAsString())) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('$groupId history never reached the expected state');
    }

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<void> authorRow(String groupId, String localId) =>
        persistence.appendHistory(
          groupId,
          ChatMessage(
            text: 'authored line',
            fromUserId: _authorKey,
            isSelf: true,
            timestamp: DateTime.now(),
            groupId: groupId,
            msgID: localId,
            altMsgIds: [_alias(groupId)],
          ),
        );

    ChatMessage rowOf(String groupId, String localId) =>
        service.getHistory(groupId).singleWhere((m) => m.msgID == localId);

    test('a READ flips, tallies and emits once under the local row id',
        () async {
      await authorRow(_authorGroup, 'local-row');
      final readCounts = <({String msgID, int readCount})>[];
      final rowEmits = <ChatMessage>[];
      final receiptSub = service.receiptEvents.listen(
          (e) => readCounts.add((msgID: e.msgID, readCount: e.readCount)));
      final rowSub = service.messages.listen((m) {
        if (m.msgID == 'local-row') rowEmits.add(m);
      });

      for (var i = 0; i < 3; i++) {
        expect(
          service.ingestActionEvent(
              _groupReceipt(_authorGroup, _alias(_readerGroup), 'read')),
          isTrue,
          reason: 'a receipt is consumed as a control, never rendered',
        );
      }
      await waitForHistoryFile(
          _authorGroup, (c) => c.contains('"isRead":true'));
      await settle();

      expect(service.getMessageReaders('local-row'), [_readerKey]);
      expect(service.getMessageReceivers('local-row'), [_readerKey]);
      expect(readCounts, [(msgID: 'local-row', readCount: 1)],
          reason: 'one reader, one event, keyed by the id UIKit holds');
      expect(rowEmits, hasLength(1), reason: 'replays change nothing');
      final row = rowOf(_authorGroup, 'local-row');
      expect(row.isReceived, isTrue);
      expect(row.isRead, isTrue);
      expect(service.getHistory(_authorGroup), hasLength(1),
          reason: 'no receipt may materialise as a row');

      await receiptSub.cancel();
      await rowSub.cancel();
    });

    test('a RECEIVED flips isReceived only and fires no read event', () async {
      await authorRow(_authorGroup, 'local-row');
      final readEvents = <Object>[];
      final rowEmits = <ChatMessage>[];
      final receiptSub = service.receiptEvents.listen(readEvents.add);
      final rowSub = service.messages.listen((m) {
        if (m.msgID == 'local-row') rowEmits.add(m);
      });

      expect(
        service.ingestActionEvent(
            _groupReceipt(_authorGroup, _alias(_readerGroup), 'received')),
        isTrue,
      );
      await waitForHistoryFile(
          _authorGroup, (c) => c.contains('"isReceived":true'));
      await settle();

      expect(service.getMessageReceivers('local-row'), [_readerKey]);
      expect(service.getMessageReaders('local-row'), isEmpty);
      expect(readEvents, isEmpty);
      expect(rowEmits, hasLength(1));
      final row = rowOf(_authorGroup, 'local-row');
      expect(row.isReceived, isTrue);
      expect(row.isRead, isFalse);

      await receiptSub.cancel();
      await rowSub.cancel();
    });

    test('a wrong author key or pseudo id stays an unresolved control',
        () async {
      await authorRow(_authorGroup, 'local-row');
      const otherAuthor =
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
      for (final ref in [
        _alias(_readerGroup, author: otherAuthor),
        _alias(_readerGroup, pseudo: _pseudoId + 1),
        'gmid:$_readerGroup|$_authorKey|$_pseudoId|1',
      ]) {
        expect(service.ingestActionEvent(_groupReceipt(_authorGroup, ref, 'read')),
            isTrue,
            reason: 'refused, but still swallowed: $ref');
      }
      await settle();

      final row = rowOf(_authorGroup, 'local-row');
      expect(row.isReceived, isFalse);
      expect(row.isRead, isFalse);
      expect(service.getMessageReaders('local-row'), isEmpty);
      expect(service.getHistory(_authorGroup), hasLength(1));
    });

    test('a receipt arriving on one group never touches another group',
        () async {
      // The same author key and pseudo id in two of our groups: only the
      // group the receipt arrived on may change.
      await authorRow(_authorGroup, 'row-g');
      await authorRow(_otherGroup, 'row-h');

      service.ingestActionEvent(
          _groupReceipt(_authorGroup, _alias(_readerGroup), 'read'));
      await waitForHistoryFile(
          _authorGroup, (c) => c.contains('"isRead":true'));
      await settle();

      expect(rowOf(_authorGroup, 'row-g').isRead, isTrue);
      final other = rowOf(_otherGroup, 'row-h');
      expect(other.isReceived, isFalse);
      expect(other.isRead, isFalse);
      expect(service.getMessageReaders('row-h'), isEmpty);
    });

    test('a target that exists only in another group is not resolved',
        () async {
      await authorRow(_otherGroup, 'row-h');

      expect(
        service.ingestActionEvent(
            _groupReceipt(_authorGroup, _alias(_otherGroup), 'read')),
        isTrue,
      );
      await settle();

      final other = rowOf(_otherGroup, 'row-h');
      expect(other.isRead, isFalse);
      expect(service.getMessageReaders('row-h'), isEmpty);
      expect(service.getHistory(_authorGroup), isEmpty);
    });

    test('a C2C ACTION naming a group gets neither rebasing nor relaxed binding',
        () async {
      await authorRow(_authorGroup, 'local-row');

      expect(
        service.ingestActionEvent('c2caction:$_readerKey:'
            '${_receiptBody(_alias(_readerGroup), 'read', groupID: _authorGroup)}'),
        isTrue,
      );
      await settle();

      final row = rowOf(_authorGroup, 'local-row');
      expect(row.isReceived, isFalse);
      expect(row.isRead, isFalse);
      expect(service.getMessageReaders('local-row'), isEmpty);
    });

    group('binary-replacement hook', () {
      V2TimMessage wrapper(String body, {String? groupID, String? userID}) =>
          V2TimMessage(
            elemType: MessageElemType.V2TIM_ELEM_TYPE_TEXT,
            textElem: V2TimTextElem(text: body),
            localCustomData: '{"tim2toxContentKind":"action"}',
          )
            ..sender = _readerKey
            ..groupID = groupID
            ..userID = userID
            ..msgID = 'receipt-wrapper';

      test('swallows a receipt whose alias carries another local group id',
          () async {
        await authorRow(_authorGroup, 'local-row');
        BinaryReplacementHistoryHook.initialize(persistence, _authorKey);

        await BinaryReplacementHistoryHook.saveMessage(wrapper(
          _receiptBody(_alias(_readerGroup), 'read'),
          groupID: _authorGroup,
        ));

        expect(persistence.getHistory(_authorGroup).map((m) => m.msgID),
            ['local-row'],
            reason: 'the wrapper must not be stored as a chat row');
      });

      test('does not rebase onto a group other than the one it consults', () {
        // Payload names tox_9 while the callback arrived on tox_4: the hook
        // consults tox_9's rows, so it must not rebase onto tox_4 as well.
        final protocol = {
          'type': 'receipt',
          'msgID': _alias(_readerGroup),
          'receiptType': 'read',
          'sender': _readerKey,
        };
        expect(
          BinaryReplacementHistoryHook.resolveControlMsgId(protocol,
              groupAliasScope: _authorGroup),
          _alias(_authorGroup),
        );
        expect(
          BinaryReplacementHistoryHook.resolveControlMsgId(protocol),
          _alias(_readerGroup),
          reason: 'no transport group, no rebasing',
        );
        expect(
          BinaryReplacementHistoryHook.resolveControlMsgId(
              {...protocol, 'type': 'reaction'},
              groupAliasScope: _authorGroup),
          _alias(_readerGroup),
          reason: 'only receipts are rebased',
        );
      });

      test('never rebases a C2C callback that names a group', () async {
        await authorRow(_authorGroup, 'local-row');
        BinaryReplacementHistoryHook.initialize(persistence, _authorKey);

        expect(
          BinaryReplacementHistoryHook.shouldConsumeInternalProtocolCustomData(
            data: _receiptBody(_alias(_readerGroup), 'read',
                groupID: _authorGroup),
            callbackSender: _readerKey,
            conversationId: _authorGroup,
            history: persistence.getHistory(_authorGroup),
          ),
          isFalse,
        );
        expect(
          BinaryReplacementHistoryHook.shouldConsumeInternalProtocolCustomData(
            data: _receiptBody(_alias(_readerGroup), 'read'),
            callbackSender: _readerKey,
            conversationId: _authorGroup,
            history: persistence.getHistory(_authorGroup),
            groupAliasScope: _authorGroup,
          ),
          isTrue,
        );
      });
    });
  });
}
