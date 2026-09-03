// Cross-peer group message alias (`gmid:<gid>|<perGroupKey>|<pseudoId>`).
//
// A group message has exactly one identity every peer agrees on: toxcore's
// Tox_Group_Message_Id, minted by the sender and packed into the broadcast.
// Every peer's own msgID is local, so that alias is the only thing a receipt
// from another member can reference. These tests pin the Dart half:
// header parsing (both the new three-segment and the legacy two-segment form),
// alias stamping, the persistence round trip, and the receipt correlation.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/utils/binary_replacement_history_hook.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

import '../test_fixtures.dart';

const _groupId = 'tox_group_7';
const _authorKey =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _readerKey =
    'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';

void main() {
  late Directory tempDir;
  late MessageHistoryPersistence persistence;
  late FfiChatService service;

  setUpAll(setupTestEnvironment);
  tearDownAll(teardownTestEnvironment);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('group_alias_');
    // The service saves history eagerly on a receipt match; without the
    // directory the save throws before the assertions run.
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

  group('group event header', () {
    test('parses the pseudo id segment', () {
      final parsed = FfiChatService.parseGroupHeader('$_groupId|$_authorKey|m42');
      expect(parsed, isNotNull);
      expect(parsed!.groupId, _groupId);
      expect(parsed.sender, _authorKey);
      expect(parsed.pseudoMsgId, 42);
    });

    test('still parses the legacy two-segment form', () {
      // Routes without a Tox_Group_Message_Id, and any older native library,
      // emit this form forever — it must never become a parse failure.
      final parsed = FfiChatService.parseGroupHeader('$_groupId|$_authorKey');
      expect(parsed, isNotNull);
      expect(parsed!.sender, _authorKey);
      expect(parsed.pseudoMsgId, isNull);
    });

    test('treats a garbled or unknown segment as absent, not as failure', () {
      for (final header in [
        '$_groupId|$_authorKey|mNOTANUMBER',
        '$_groupId|$_authorKey|x99',
      ]) {
        final parsed = FfiChatService.parseGroupHeader(header);
        expect(parsed, isNotNull, reason: 'header: $header');
        expect(parsed!.sender, _authorKey);
        expect(parsed.pseudoMsgId, isNull);
      }
    });

    test('rejects a malformed header', () {
      expect(FfiChatService.parseGroupHeader('nopipe'), isNull);
      expect(FfiChatService.parseGroupHeader('|$_authorKey'), isNull);
      expect(FfiChatService.parseGroupHeader('$_groupId|'), isNull);
    });
  });

  test('an inbound group row carries the alias and survives a reload',
      () async {
    expect(
      service.ingestInboundGroupText(
        gid: _groupId,
        from: _authorKey,
        text: 'hello group',
        pseudoMsgId: 4242,
      ),
      isTrue,
    );

    final alias = FfiChatService.groupMessageAlias(
      groupId: _groupId,
      senderPk: _authorKey,
      pseudoMsgId: 4242,
    );
    final row = service.getHistory(_groupId).single;
    expect(row.altMsgIds, contains(alias));

    // The alias is only useful if it outlives the process: a receipt can
    // arrive long after a restart. The ingest save is debounced, so force it
    // to disk before reading the file back through a fresh store.
    await persistence.saveHistory(_groupId, service.getHistory(_groupId));
    final reloaded = MessageHistoryPersistence(
      historyDirectory: '${tempDir.path}/history',
    );
    final reloadedRows = await reloaded.loadHistory(_groupId);
    final reloadedRow = reloadedRows.single;
    expect(reloadedRow.altMsgIds, contains(alias),
        reason: 'the cross-peer alias must round-trip through persistence');
    expect(reloadedRow.msgID, row.msgID);
  });

  test('the duplicate path merges the alias onto an already-saved row',
      () async {
    // This is the PRODUCT's normal path: in hybrid mode the native advanced
    // listener persists the row first (with no alias — MessageConverter has
    // none to give), and the polled copy that carries the pseudo id arrives
    // second and lands in the duplicate branch. If that branch did not merge,
    // the row would stay alias-less forever and every later receipt would be
    // dropped as unresolved — working in tests, dead in the app.
    expect(
      service.ingestInboundGroupText(
        gid: _groupId,
        from: _authorKey,
        text: 'delivered twice',
      ),
      isTrue,
    );
    expect(service.getHistory(_groupId).single.altMsgIds, isEmpty);

    service.ingestInboundGroupText(
      gid: _groupId,
      from: _authorKey,
      text: 'delivered twice',
      pseudoMsgId: 9001,
    );

    final alias = FfiChatService.groupMessageAlias(
      groupId: _groupId,
      senderPk: _authorKey,
      pseudoMsgId: 9001,
    );
    final rows = service.getHistory(_groupId);
    expect(rows, hasLength(1), reason: 'the duplicate must not add a row');
    expect(rows.single.altMsgIds, contains(alias));

    // Idempotent: a third delivery of the same message must not duplicate the
    // alias (and must not re-receipt).
    service.ingestInboundGroupText(
      gid: _groupId,
      from: _authorKey,
      text: 'delivered twice',
      pseudoMsgId: 9001,
    );
    expect(service.getHistory(_groupId).single.altMsgIds, [alias]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('a row without a pseudo id keeps the legacy shape', () {
    expect(
      service.ingestInboundGroupText(
        gid: _groupId,
        from: _authorKey,
        text: 'legacy route',
      ),
      isTrue,
    );
    expect(service.getHistory(_groupId).single.altMsgIds, isEmpty);
  });

  test('a receipt echoing the alias tallies against the LOCAL row id',
      () async {
    // Stand in for a locally authored row: what the author holds is its own
    // msgID plus the shared alias.
    final alias = FfiChatService.groupMessageAlias(
      groupId: _groupId,
      senderPk: _authorKey,
      pseudoMsgId: 77,
    );
    final authored = ChatMessage(
      text: 'authored line',
      fromUserId: _authorKey,
      isSelf: true,
      timestamp: DateTime.now(),
      groupId: _groupId,
      msgID: 'local-author-id',
      altMsgIds: [alias],
    );
    await persistence.appendHistory(_groupId, authored);

    service.ingestActionEvent(
      'gaction:$_groupId|$_readerKey:${jsonEncode({
            'type': 'receipt',
            'msgID': alias,
            'receiptType': 'read',
            'sender': _readerKey,
          })}',
    );
    // _handleReceipt is async (it persists before emitting), so poll instead
    // of assuming one microtask is enough — otherwise the test tears the
    // service down underneath the in-flight handler.
    for (var i = 0;
        i < 100 && service.getMessageReaders('local-author-id').isEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(service.getMessageReaders('local-author-id'), [_readerKey],
        reason: 'the tally must be keyed by the id UIKit holds, not the wire '
            'id the receipt carried');
    expect(service.getMessageReaders(alias), isEmpty,
        reason: 'nothing may be left keyed by the wire alias');
    expect(service.getHistory(_groupId).where((m) => !m.isSelf), isEmpty,
        reason: 'the receipt must not materialise as a row');

    // The tally is observable before _handleReceipt's persist finishes; let it
    // land, or tearDown deletes the history directory underneath the in-flight
    // save and the failure is reported against this test.
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
}
