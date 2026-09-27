// A history write that cannot land must SAY so, not only log it.
//
// WHY THIS EXISTS: every failure in MessageHistoryPersistence used to end at
// `_logger.logError`, and nothing downstream consumed HistoryFlushException
// either — so a device that cannot write history (full disk, revoked sandbox
// path, unwritable account directory) was indistinguishable from one with
// nothing to save. The app kept accepting messages and lost them at restart,
// and a test could only observe the damage after the fact by inspecting files.
// `writeFailures` is the seam: the store reports what it could not write, with
// enough shape for a host to decide whether the user needs telling.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

const _peer = 'peer';
const _ownerA =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _ownerB =
    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

ChatMessage _row(String id) => ChatMessage(
      text: id,
      fromUserId: 'self',
      isSelf: true,
      timestamp: DateTime.utc(2026, 1, 1, 12, 0, 0),
      msgID: id,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('history_write_failure_');
  });

  tearDown(() async {
    // Always restore the mode first: a read-only directory cannot be deleted.
    await Process.run('chmod', <String>['700', root.path]);
    final dirs = <String>[
      p.join(root.path, 'chat_history'),
      p.join(root.path, 'chat_history_$_ownerA'),
    ];
    for (final d in dirs) {
      if (Directory(d).existsSync()) {
        await Process.run('chmod', <String>['700', d]);
      }
    }
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// The directory the store resolves to for [ownerKey], established by one
  /// successful write (an empty unmarked base is claimed rather than
  /// side-stepped, so the path cannot be assumed).
  Future<Directory> boundDirectory(
      MessageHistoryPersistence store, String ownerKey) async {
    await store.appendHistory(_peer, _row('durable'));
    await store.flushPendingSaves();
    return Directory((await store.ownerBoundDefaultDirectory())!);
  }

  test('an unwritable directory is reported, with a retry still armed',
      () async {
    final store = MessageHistoryPersistence(appSupportRootOverride: root.path);
    await store.openSession(ownerKey: _ownerA);
    final dir = await boundDirectory(store, _ownerA);

    final seen = <HistoryWriteFailure>[];
    final sub = store.writeFailures.listen(seen.add);
    addTearDown(sub.cancel);

    await Process.run('chmod', <String>['500', dir.path]);
    // appendHistory's own future carries the error; the point of this test is
    // the SIGNAL, so the throw is swallowed here deliberately.
    try {
      await store.appendHistory(_peer, _row('cannot_land'));
    } catch (_) {}
    await store.flushPendingSaves().catchError((Object _) {});
    // The report is delivered asynchronously (a non-sync broadcast sink).
    await Future<void>.delayed(Duration.zero);

    expect(seen, isNotEmpty,
        reason: 'a write that cannot land must be reported, not only logged');
    final mainFile =
        seen.where((f) => f.stage == HistoryWriteStage.mainFile).toList();
    expect(mainFile, isNotEmpty);
    expect(mainFile.first.conversationId, _peer);
    expect(mainFile.first.willRetry, isTrue,
        reason: 'the first failure arms a retry, and a host must be able to '
            'tell that apart from "we have given up"');
    expect(mainFile.first.attempt, 1);

    await Process.run('chmod', <String>['700', dir.path]);
    await store.dispose();
  }, skip: Platform.isWindows ? 'chmod-based failure injection' : null);

  test('rows held for an outgoing identity are reported as held, not lost',
      () async {
    final store = MessageHistoryPersistence(appSupportRootOverride: root.path);
    await store.openSession(ownerKey: _ownerA);
    final dir = await boundDirectory(store, _ownerA);

    final seen = <HistoryWriteFailure>[];
    final sub = store.writeFailures.listen(seen.add);
    addTearDown(sub.cancel);

    await Process.run('chmod', <String>['500', dir.path]);
    // Owed to A's directory, which cannot be written.
    // ignore: unawaited_futures
    store.appendHistory(_peer, _row('owed_to_a')).catchError((Object _) {});
    // The owner change flushes what it owes, fails, and HOLDS the rows.
    await store.openSession(ownerKey: _ownerB);
    await Future<void>.delayed(Duration.zero);

    final held =
        seen.where((f) => f.stage == HistoryWriteStage.heldForOwner).toList();
    expect(held, isNotEmpty,
        reason: 'a hand-over that cannot write must say the rows are HELD — '
            'that is a different thing to tell the user than "lost"');
    expect(held.first.willRetry, isTrue,
        reason: 'reopening that identity re-writes them');

    await Process.run('chmod', <String>['700', dir.path]);
    await store.dispose();
  }, skip: Platform.isWindows ? 'chmod-based failure injection' : null);

  test('a store with no listener still works, and reports nothing', () async {
    // The seam is optional: nothing about a host that does not subscribe should
    // change, which is what keeps this safe to add to a shipped path.
    final store = MessageHistoryPersistence(appSupportRootOverride: root.path);
    await store.openSession(ownerKey: _ownerA);
    final dir = await boundDirectory(store, _ownerA);

    await Process.run('chmod', <String>['500', dir.path]);
    try {
      await store.appendHistory(_peer, _row('nobody_listening'));
    } catch (_) {}
    await Process.run('chmod', <String>['700', dir.path]);

    // ...and the row is still served from memory, as before.
    expect(store.getHistory(_peer).map((m) => m.msgID),
        containsAll(<String>['durable', 'nobody_listening']));
    await store.dispose();
  }, skip: Platform.isWindows ? 'chmod-based failure injection' : null);

  test('the sink survives a dispose + reopen cycle', () async {
    final store = MessageHistoryPersistence(appSupportRootOverride: root.path);
    await store.openSession(ownerKey: _ownerA);
    await store.appendHistory(_peer, _row('first_session'));
    await store.flushPendingSaves();
    await store.dispose();

    // A closed sink must not silence the next session: the getter re-makes it.
    await store.openSession(ownerKey: _ownerA);
    final seen = <HistoryWriteFailure>[];
    final sub = store.writeFailures.listen(seen.add);
    addTearDown(sub.cancel);
    final dir = Directory((await store.ownerBoundDefaultDirectory())!);

    await Process.run('chmod', <String>['500', dir.path]);
    try {
      await store.appendHistory(_peer, _row('second_session'));
    } catch (_) {}
    await Future<void>.delayed(Duration.zero);
    await Process.run('chmod', <String>['700', dir.path]);

    expect(seen, isNotEmpty,
        reason: 'a reopened store must be able to report again');
    await store.dispose();
  }, skip: Platform.isWindows ? 'chmod-based failure injection' : null);
}
