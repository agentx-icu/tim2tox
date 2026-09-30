// Ownership of the DEFAULT `<AppSupport>/chat_history` directory.
//
// WHY THIS EXISTS: history files are keyed by the PEER, so two accounts talking
// to the same peer write the same file name. Owner binding (the
// `.tim2tox_history_owner` marker) fixed that for directories it could reason
// about, but left one hole: a directory that already held history and carried
// NO marker — the shape every pre-binding install has — was handed to whichever
// account asked first, and then shared with every account after it. Ownership
// of such a directory cannot be decided here (rows carry peer ids, not ours),
// and first-to-ask is not proof; so it is now given to NOBODY unless the
// integrator declares a proven owner (toxee: LegacyAccountDataClaim). Every
// other identity gets `<base>_<publicKey>` and the legacy rows are left exactly
// where they are, still claimable by whoever can prove they own them.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/models/chat_message.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';

const _peer = 'peer';
const _ownerA =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _ownerB =
    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _markerName = '.tim2tox_history_owner';

/// Hex sha256 of [text], the way the store digests file contents.
String _digestOfString(String text) => sha256.convert(utf8.encode(text)).toString();

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
    root = await Directory.systemTemp.createTemp('default_history_owner_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Directory base() => Directory(p.join(root.path, 'chat_history'));
  File peerFile(Directory dir) => File(p.join(dir.path, '$_peer.json'));
  File marker(Directory dir) => File(p.join(dir.path, _markerName));

  /// A store on the shared app-support root with its session already open.
  ///
  /// `openSession` is awaited on purpose: an owner change hands the outgoing
  /// session's pending writes over to the directory that session was bound to
  /// before dropping its state, and that is asynchronous.
  Future<MessageHistoryPersistence> opened({
    String? ownerKey,
    String? provenOwner,
  }) async {
    final store = MessageHistoryPersistence(appSupportRootOverride: root.path);
    if (provenOwner != null) store.declareProvenDefaultOwner(provenOwner);
    await store.openSession(ownerKey: ownerKey);
    return store;
  }

  /// A pre-owner-binding install: history on disk, no owner marker.
  Future<void> seedLegacyDirectory() async {
    final store = MessageHistoryPersistence(appSupportRootOverride: root.path);
    await store.saveHistory(_peer, [_row('legacy_row')]);
    await store.dispose();
    expect(await peerFile(base()).exists(), isTrue);
    expect(await marker(base()).exists(), isFalse,
        reason: 'the seeded directory must look like a pre-binding one');
  }

  group('unmarked legacy default directory', () {
    test('an unproven account never reads or writes it', () async {
      await seedLegacyDirectory();
      final legacyBefore = await peerFile(base()).readAsString();

      final b = await opened(ownerKey: _ownerB);
      expect(await b.loadHistory(_peer), isEmpty,
          reason: 'an account that cannot prove ownership must start empty, '
              'not inherit whatever sits in the shared directory');
      await b.saveHistory(_peer, [_row('from_b')]);
      await b.dispose();

      expect(await peerFile(base()).readAsString(), legacyBefore,
          reason: 'the legacy rows must be left byte-identical for the '
              'account that can still prove it owns them');
      expect(await marker(base()).exists(), isFalse,
          reason: 'an unproven account must not claim the directory either');
      final isolated = Directory('${base().path}_$_ownerB');
      expect(await peerFile(isolated).readAsString(), contains('from_b'));
    });

    test('two unproven accounts never share a directory', () async {
      await seedLegacyDirectory();

      final a = await opened(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);
      await a.dispose();

      final b = await opened(ownerKey: _ownerB);
      expect(await b.loadHistory(_peer), isEmpty);
      await b.saveHistory(_peer, [_row('from_b')]);
      await b.dispose();

      final aDir = Directory('${base().path}_$_ownerA');
      final bDir = Directory('${base().path}_$_ownerB');
      expect(await peerFile(aDir).readAsString(), contains('from_a'));
      expect(await peerFile(aDir).readAsString(), isNot(contains('from_b')));
      expect(await peerFile(bDir).readAsString(), contains('from_b'));
      expect(await peerFile(bDir).readAsString(), isNot(contains('from_a')));
      expect(await peerFile(base()).readAsString(), contains('legacy_row'));
    });

    test('the proven owner adopts it in place and locks everyone else out',
        () async {
      await seedLegacyDirectory();

      final a = await opened(ownerKey: _ownerA, provenOwner: _ownerA);
      expect((await a.loadHistory(_peer)).map((m) => m.msgID), ['legacy_row'],
          reason: 'the proven owner keeps its history, in place');
      await a.saveHistory(_peer, [_row('legacy_row'), _row('from_a')]);
      await a.dispose();

      expect((await marker(base()).readAsString()).trim(), _ownerA,
          reason: 'adopting must mark the directory, so the NEXT account is '
              'refused by the marker rather than by the declaration');

      // A second account on the same device, even if it too claimed to be
      // proven, is now refused by the marker.
      final b = await opened(ownerKey: _ownerB, provenOwner: _ownerB);
      expect(await b.loadHistory(_peer), isEmpty);
      await b.saveHistory(_peer, [_row('from_b')]);
      await b.dispose();

      expect(await peerFile(base()).readAsString(), contains('from_a'));
      expect(await peerFile(base()).readAsString(), isNot(contains('from_b')));
    });

    test('a declaration for another identity does not open the directory',
        () async {
      await seedLegacyDirectory();

      final b = await opened(ownerKey: _ownerB, provenOwner: _ownerA);
      expect(await b.loadHistory(_peer), isEmpty);
      await b.saveHistory(_peer, [_row('from_b')]);
      await b.dispose();

      expect(await peerFile(base()).readAsString(), isNot(contains('from_b')));
      expect(
        await peerFile(Directory('${base().path}_$_ownerB')).readAsString(),
        contains('from_b'),
      );
    });
  });

  group('shapes that must NOT change', () {
    test('an owner-marked directory is still used by its owner', () async {
      final a = await opened(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);
      await a.dispose();
      expect((await marker(base()).readAsString()).trim(), _ownerA,
          reason: 'an EMPTY default directory is claimed, as before');

      final again = await opened(ownerKey: '${_ownerA}0102030405AB');
      expect((await again.loadHistory(_peer)).map((m) => m.msgID), ['from_a']);
      await again.dispose();
    });

    test('a session with no owner still uses an unmarked directory', () async {
      // Deliberate: with no owner there is nothing to isolate BY, and this is
      // the only shape a host that never supplies an owner produces —
      // isolating it would strand that host's whole history (and, in toxee,
      // the rows written before installAccountStorage, which its migration
      // adopts from exactly this directory).
      await seedLegacyDirectory();
      final anon = await opened();
      expect((await anon.loadHistory(_peer)).map((m) => m.msgID),
          ['legacy_row']);
      await anon.dispose();
    });

    test('a session with no owner is kept out of a CLAIMED directory',
        () async {
      final a = await opened(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);
      await a.dispose();

      final anon = await opened();
      expect(await anon.loadHistory(_peer), isEmpty);
      await anon.saveHistory(_peer, [_row('from_anon')]);
      await anon.dispose();

      expect(await peerFile(base()).readAsString(), isNot(contains('from_anon')));
      expect(
        await peerFile(Directory('${base().path}_unowned')).readAsString(),
        contains('from_anon'),
      );
    });
  });

  group('the ownerless -> owned hand-over (H1)', () {
    test('the new owner never inherits the ownerless session\'s rows',
        () async {
      // The transition every host makes: the store is opened before the Tox
      // profile is, so the first session has no identity and reads the
      // unmarked shared directory; the identity arrives afterwards.
      await seedLegacyDirectory();
      final store = await opened();
      expect((await store.loadHistory(_peer)).map((m) => m.msgID),
          ['legacy_row']);

      await store.openSession(ownerKey: _ownerB);

      expect(store.getHistory(_peer), isEmpty,
          reason: 'rows read from the unmarked shared directory belong to '
              'whoever owns it — B must not be served them');
      expect(await store.loadHistory(_peer), isEmpty,
          reason: 'B reloads from ITS directory, which is empty');

      await store.appendHistory(_peer, _row('from_b'));
      await store.dispose();

      final legacy = await peerFile(base()).readAsString();
      expect(legacy, contains('legacy_row'));
      expect(legacy, isNot(contains('from_b')),
          reason: 'an append after the hand-over must not copy the previous '
              'session\'s rows into the new owner\'s files, nor write into '
              'the shared directory');
      expect(
        await peerFile(Directory('${base().path}_$_ownerB')).readAsString(),
        contains('from_b'),
      );
    });

    test('the hand-over lands what the ownerless session still owed', () async {
      final store = await opened();
      // Debounced (200ms): owed to the directory THIS session is bound to.
      unawaited(store.appendHistory(_peer, _row('pre_login')));
      expect(await peerFile(base()).exists(), isFalse,
          reason: 'the save is still pending');

      await store.openSession(ownerKey: _ownerB);

      expect(await peerFile(base()).readAsString(), contains('pre_login'),
          reason: 'a pending write belongs to the directory it was made in; '
              'the hand-over must flush it there, not drop it and not carry '
              'it into B\'s directory');
      await store.dispose();
      expect(
        await peerFile(Directory('${base().path}_$_ownerB')).exists(),
        isFalse,
      );
    });

    test('rows an OWNERLESS session could not write are not handed to the next '
        'ownerless session', () async {
      final store = await opened();
      await store.saveHistory(_peer, [_row('already_durable')]);
      await store.flushPendingSaves();
      await Process.run('chmod', <String>['500', base().path]);
      addTearDown(() => Process.run('chmod', <String>['700', base().path]));
      unawaited(store
          .appendHistory(_peer, _row('owed_by_an_unknown_identity'))
          .catchError((Object _) {}));

      // A -> B -> (pre-login window again). `null` names no identity, so those
      // rows must not reappear for whoever logs in next (codex 2026-09-26).
      await store.openSession(ownerKey: _ownerB);
      await Process.run('chmod', <String>['700', base().path]);
      await store.openSession();

      expect(store.getHistory(_peer), isEmpty);
      await store.flushPendingSaves();
      final shared = peerFile(base());
      if (await shared.exists()) {
        expect(await shared.readAsString(),
            isNot(contains('owed_by_an_unknown_identity')));
      }
      await store.dispose();
    }, skip: Platform.isWindows ? 'chmod-based failure injection' : null);

    test('rows the hand-over could not write are held for that identity',
        () async {
      // A write that cannot land (full disk, unwritable directory) used to be
      // dropped outright by the hand-over: carrying it into the next identity
      // would put it in that account's files, so the message was simply lost
      // (codex 2026-09-26). It is now held for the identity it belongs to.
      final store = await opened(ownerKey: _ownerA);
      // One successful write first, so A's directory is resolved and claimed
      // (an empty unmarked base is claimed rather than side-stepped).
      await store.saveHistory(_peer, [_row('already_durable')]);
      await store.flushPendingSaves();
      final ownDir = Directory((await store.ownerBoundDefaultDirectory())!);
      await Process.run('chmod', <String>['500', ownDir.path]);
      addTearDown(() => Process.run('chmod', <String>['700', ownDir.path]));
      unawaited(store
          .appendHistory(_peer, _row('owed_to_a'))
          .catchError((Object _) {}));

      await store.openSession(ownerKey: _ownerB);

      expect(store.getHistory(_peer), isEmpty,
          reason: 'B must not be served the held rows');
      await store.appendHistory(_peer, _row('from_b'));
      await store.flushPendingSaves();
      expect(
        await peerFile(Directory('${base().path}_$_ownerB')).readAsString(),
        isNot(contains('owed_to_a')),
        reason: 'the held rows must not be written into B\'s files',
      );

      // Back to A, with its directory writable again: the held rows are
      // restored and land where they always belonged.
      await Process.run('chmod', <String>['700', ownDir.path]);
      await store.openSession(ownerKey: _ownerA);
      await store.flushPendingSaves();
      expect(await peerFile(ownDir).readAsString(), contains('owed_to_a'));
      await store.dispose();
    }, skip: Platform.isWindows ? 'chmod-based failure injection' : null);

    test('the deletion of the LAST row survives the hand-over', () async {
      // Nothing is left to hold for this conversation, so the tombstone is the
      // only thing that can carry the delete — and it has to be written, not
      // just remembered (codex 2026-09-26).
      final store = await opened(ownerKey: _ownerA);
      await store.appendHistory(_peer, _row('the_only_row'));
      await store.flushPendingSaves();
      final ownDir = Directory((await store.ownerBoundDefaultDirectory())!);

      await Process.run('chmod', <String>['500', ownDir.path]);
      addTearDown(() => Process.run('chmod', <String>['700', ownDir.path]));
      await expectLater(
          store.removeMessage(_peer, 'the_only_row'), throwsA(anything));
      unawaited(store.flushPendingSaves().catchError((Object _) {}));

      await store.openSession(ownerKey: _ownerB);
      await Process.run('chmod', <String>['700', ownDir.path]);
      await store.openSession(ownerKey: _ownerA);
      await store.flushPendingSaves();
      await store.dispose();

      // A fresh store, nothing cached: only the files can answer.
      final reopened = MessageHistoryPersistence(appSupportRootOverride: root.path);
      await reopened.openSession(ownerKey: _ownerA);
      expect(await reopened.loadHistory(_peer), isEmpty,
          reason: 'the deleted sole row must not come back next session');
      await reopened.dispose();
    }, skip: Platform.isWindows ? 'chmod-based failure injection' : null);

    test('a delete whose write failed is not undone when the owner returns',
        () async {
      // The row is on disk first, then deleted with the directory unwritable:
      // holding only the remaining rows would let the next load merge the
      // deleted one back in (codex 2026-09-26).
      final store = await opened(ownerKey: _ownerA);
      // appendHistory, so the rows are in the cache too: removeMessage works on
      // the cached list (saveHistory only writes a snapshot).
      await store.appendHistory(_peer, _row('keep'));
      await store.appendHistory(_peer, _row('gone'));
      await store.flushPendingSaves();
      final ownDir = Directory((await store.ownerBoundDefaultDirectory())!);
      expect(await peerFile(ownDir).readAsString(), contains('gone'));

      await Process.run('chmod', <String>['500', ownDir.path]);
      addTearDown(() => Process.run('chmod', <String>['700', ownDir.path]));
      // The tombstone is recorded before the write, so the delete stands in
      // memory even though the write cannot land and the call reports it.
      await expectLater(store.removeMessage(_peer, 'gone'), throwsA(anything));
      unawaited(store.flushPendingSaves().catchError((Object _) {}));

      await store.openSession(ownerKey: _ownerB);
      await Process.run('chmod', <String>['700', ownDir.path]);
      await store.openSession(ownerKey: _ownerA);

      expect((await store.loadHistory(_peer)).map((m) => m.msgID), ['keep'],
          reason: 'the tombstone must come back with the rows');
      await store.dispose();
    }, skip: Platform.isWindows ? 'chmod-based failure injection' : null);
  });

  group('an interrupted claim (H2)', () {
    test('the owner marker is written whole, leaving no temp file behind',
        () async {
      final a = await opened(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);
      await a.dispose();

      expect(await marker(base()).readAsString(), _ownerA);
      expect(await File('${marker(base()).path}.tmp').exists(), isFalse,
          reason: 'the marker is written through a temp file + rename, and '
              'the temp file must not survive the rename');
    });

    test('a marker naming nobody does not lock the proven owner out', () async {
      await seedLegacyDirectory();
      // Exactly what a crash during a non-atomic `writeAsString` left behind:
      // the file exists, and it names nobody.
      await marker(base()).writeAsString('');

      // It is still nobody's directory to an unproven account...
      final b = await opened(ownerKey: _ownerB);
      expect(await b.loadHistory(_peer), isEmpty);
      await b.dispose();
      expect(await peerFile(base()).readAsString(), contains('legacy_row'));

      // ...and the proven owner repairs the marker and keeps its history.
      final a = await opened(ownerKey: _ownerA, provenOwner: _ownerA);
      expect((await a.loadHistory(_peer)).map((m) => m.msgID), ['legacy_row'],
          reason: 'one interrupted write must not cost the owner its history');
      await a.dispose();
      expect((await marker(base()).readAsString()).trim(), _ownerA);
    });

    test('a truncated claim of an EMPTY directory is simply redone', () async {
      await base().create(recursive: true);
      await marker(base()).writeAsString('AAAA');

      final a = await opened(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);
      await a.dispose();

      expect(await marker(base()).readAsString(), _ownerA);
      expect(await peerFile(base()).readAsString(), contains('from_a'));
    });
  });

  group('a directory claimed under a live ownerless session (H3)', () {
    test('the session stops writing into it and does not delete it', () async {
      final anon = await opened();
      await anon.saveHistory(_peer, [_row('from_anon')]);
      expect(await peerFile(base()).readAsString(), contains('from_anon'));

      // Another instance of the app claims the base directory meanwhile. The
      // cached path used to be trusted forever, so this session kept writing
      // into — and clearAllHistories kept deleting — the new owner's files.
      await marker(base()).writeAsString(_ownerA, flush: true);

      await anon.saveHistory('peer2', [_row('later')]);
      expect(await File(p.join(base().path, 'peer2.json')).exists(), isFalse,
          reason: 'the claimed directory must be left alone from here on');
      expect(
        await File(p.join('${base().path}_unowned', 'peer2.json')).exists(),
        isTrue,
      );

      await anon.clearAllHistories();
      expect(await peerFile(base()).exists(), isTrue,
          reason: 'clearing this session must not delete the owner\'s history');
      expect(await Directory('${base().path}_unowned').exists(), isFalse);
      await anon.dispose();
    });
  });

  group('claim-or-migrate for an upgraded install (H4)', () {
    test('the status names the history the session was routed away from',
        () async {
      await seedLegacyDirectory();
      final a = await opened(ownerKey: _ownerA);
      expect(await a.loadHistory(_peer), isEmpty);

      final status = await a.defaultHistoryDirectoryStatus();
      expect(status, isNotNull);
      expect(status!.hasUnadoptedHistory, isTrue,
          reason: 'an empty view over history that is still on disk must be '
              'reportable, or it is indistinguishable from data loss');
      expect(status.basePath, base().path);
      expect(status.resolvedPath, '${base().path}_$_ownerA');
      expect(status.markedOwner, isNull);
      expect(status.baseHoldsHistory, isTrue);
      await a.dispose();
    });

    test('adopting merges what the isolated directory already holds', () async {
      await seedLegacyDirectory();
      final a = await opened(ownerKey: _ownerA);
      // The user kept chatting while the history looked empty.
      await a.saveHistory(_peer, [_row('sent_while_empty')]);

      expect(await a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);

      expect(
        (await a.loadHistory(_peer)).map((m) => m.msgID),
        containsAll(<String>['legacy_row', 'sent_while_empty']),
        reason: 'adopting must hide neither side',
      );
      await a.dispose();

      expect((await marker(base()).readAsString()).trim(), _ownerA,
          reason: 'the adoption is permanent: no second account may take it');
      expect(await Directory('${base().path}_$_ownerA').exists(), isFalse);
      expect(await Directory('${base().path}_$_ownerA.adopted').exists(), isTrue,
          reason: 'the source is renamed aside, never deleted');

      final status = await a.defaultHistoryDirectoryStatus();
      expect(status!.hasUnadoptedHistory, isFalse);
    });

    test('a file that cannot be merged aborts the adoption and hides nothing',
        () async {
      await seedLegacyDirectory();
      final a = await opened(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('sent_while_empty')]);
      await a.flushPendingSaves();
      // The isolated side's file is now unreadable as JSON. Before, the merge
      // logged it, the caller counted the file as merged, and the whole source
      // directory was renamed aside — the rows were then in neither the
      // adopted directory nor the one the app reads (codex 2026-09-26).
      final isolated = Directory('${base().path}_$_ownerA');
      await peerFile(isolated).writeAsString('{ truncated', flush: true);

      await expectLater(
        a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
        throwsA(isA<StateError>()),
      );

      expect(await isolated.exists(), isTrue,
          reason: 'a partial merge must leave the source in place');
      expect(await Directory('${isolated.path}.adopted').exists(), isFalse);
      expect(await marker(base()).exists(), isFalse,
          reason: 'the base must not be claimed while rows are still only in '
              'the source directory');
      expect(await peerFile(base()).readAsString(), contains('legacy_row'));
      await a.dispose();
    });

    test('a merge keeps the LATER read barrier of the two sides', () async {
      // Base: read long ago. Isolated: read just now. Merging must not move
      // the barrier backwards, or read messages come back as unread.
      await base().create(recursive: true);
      await peerFile(base()).writeAsString(
        '{"conversationId":"$_peer","version":2,"lastViewTimestamp":1000,'
        '"messages":[]}',
        flush: true,
      );
      final isolated = Directory('${base().path}_$_ownerA');
      await isolated.create(recursive: true);
      await peerFile(isolated).writeAsString(
        '{"conversationId":"$_peer","version":2,"lastViewTimestamp":9000,'
        '"messages":[${jsonEncode(_row('mine').toJson())}]}',
        flush: true,
      );

      final a = await opened(ownerKey: _ownerA);
      expect(await a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      await a.dispose();

      final decoded = jsonDecode(await peerFile(base()).readAsString())
          as Map<String, dynamic>;
      expect(decoded['lastViewTimestamp'], 9000);
    });

    test('a source changed after a partial adoption is merged again', () async {
      // Two conversations in the isolated directory, one of them unreadable, so
      // the adoption merges the first and then aborts. The session keeps using
      // the isolated directory and appends to the conversation that DID
      // transfer; the retry must not skip it on the strength of its name
      // (codex 2026-09-26).
      await seedLegacyDirectory();
      // The destination must already hold 'other' too, or the merge just copies
      // the source file wholesale and never has to decode it.
      await File(p.join(base().path, 'other.json')).writeAsString(
        jsonEncode(<String, Object?>{
          'conversationId': 'other',
          'version': 2,
          'lastViewTimestamp': 0,
          'messages': <Object?>[_row('legacy_of_other').toJson()],
        }),
        flush: true,
      );
      final a = await opened(ownerKey: _ownerA);
      await a.appendHistory(_peer, _row('first_of_peer'));
      await a.appendHistory('other', _row('only_of_other'));
      await a.flushPendingSaves();
      final isolated = Directory((await a.ownerBoundDefaultDirectory())!);
      final broken = File(p.join(isolated.path, 'other.json'));
      final rescue = await broken.readAsString();
      await broken.writeAsString('{ truncated', flush: true);

      await expectLater(a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          throwsA(isA<StateError>()));

      // The session is still on the isolated directory: append there.
      await a.appendHistory(_peer, _row('after_the_failure'));
      await a.flushPendingSaves();
      await broken.writeAsString(rescue, flush: true);

      expect(await a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      final rows = (await a.loadHistory(_peer)).map((m) => m.msgID);
      expect(rows, containsAll(<String>['first_of_peer', 'after_the_failure']),
          reason: 'the row written between the two attempts must not be lost');
      expect((await a.loadHistory('other')).map((m) => m.msgID),
          contains('only_of_other'));
      await a.dispose();
    });

    test('adoption refuses to run for an identity this store is not bound to',
        () async {
      await seedLegacyDirectory();
      final a = await opened(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);

      // Adoption merges THIS session's directory into the base and marks it
      // for the given owner: with two different identities that mixes A's rows
      // into B's account (codex 2026-09-26).
      await expectLater(
        a.adoptDefaultHistoryDirectory(ownerKey: _ownerB),
        throwsA(isA<StateError>()),
      );
      expect(await marker(base()).exists(), isFalse);
      await a.dispose();
    });

    test('adoption never overrides another identity\'s claim', () async {
      await seedLegacyDirectory();
      await marker(base()).writeAsString(_ownerB, flush: true);

      final a = await opened(ownerKey: _ownerA);
      expect(await a.adoptDefaultHistoryDirectory(ownerKey: _ownerA), isNull);
      await a.dispose();

      expect((await marker(base()).readAsString()).trim(), _ownerB);
    });

    test('an injected per-account directory reports no default at all',
        () async {
      final store = MessageHistoryPersistence(
          historyDirectory: p.join(root.path, 'account_a'));
      expect(await store.defaultHistoryDirectoryStatus(), isNull);
      expect(await store.ownerBoundDefaultDirectory(), isNull);
      await store.dispose();
    });

    test('only a PROVABLE directory is offered to the host for carry-over',
        () async {
      await seedLegacyDirectory();

      final anon = await opened();
      expect(await anon.ownerBoundDefaultDirectory(), isNull,
          reason: 'the unproven shared base must never be handed to a host to '
              'copy — that is the pre-binding dataset, and it may be another '
              'account\'s');
      await anon.dispose();

      final a = await opened(ownerKey: _ownerA);
      expect(await a.ownerBoundDefaultDirectory(), '${base().path}_$_ownerA',
          reason: 'rows written before installAccountStorage live here, and '
              'nothing else knows where "here" is');
      await a.dispose();
    });
  });

  group('the copy a partial adoption leaves behind', () {
    // A merge that fails on one file leaves the source directory in place, so
    // the session keeps using it and the retry has to reconcile two live
    // copies. Which rows the retry may drop turns on one question a file name
    // cannot answer: is the destination file nothing but the copy attempt one
    // made, or does it have rows of its own? Until the manifest recorded that,
    // every retry had to UNION, and a union puts back a row the user deleted in
    // between — the copy still holds it. The in-memory tombstones covered that
    // only while the process lived (codex 2026-09-28).

    /// The destination needs its OWN `other.json`, or the merge just copies the
    /// broken source file wholesale, never decodes it, and nothing fails --
    /// leaving no partial adoption to test.
    Future<void> seedBlockerInBase() async {
      await base().create(recursive: true);
      await File(p.join(base().path, 'other.json')).writeAsString(
        jsonEncode(<String, Object?>{
          'conversationId': 'other',
          'version': 2,
          'lastViewTimestamp': 0,
          'messages': <Object?>[_row('other_of_base').toJson()],
        }),
        flush: true,
      );
    }

    /// An isolated directory holding [_peer] plus a broken `other.json`, so the
    /// first adoption transfers the peer file and then aborts.
    Future<({MessageHistoryPersistence store, Directory isolated, File broken,
        String rescue})> partiallyAdopted(List<String> peerRows) async {
      await seedBlockerInBase();
      final a = await opened(ownerKey: _ownerA);
      for (final id in peerRows) {
        await a.appendHistory(_peer, _row(id));
      }
      await a.appendHistory('other', _row('other_row'));
      await a.flushPendingSaves();
      final isolated = Directory((await a.ownerBoundDefaultDirectory())!);
      final broken = File(p.join(isolated.path, 'other.json'));
      final rescue = await broken.readAsString();
      await broken.writeAsString('{ truncated', flush: true);
      await expectLater(a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          throwsA(isA<StateError>()));
      return (store: a, isolated: isolated, broken: broken, rescue: rescue);
    }

    File manifestOf(Directory isolated) =>
        File(p.join(isolated.path, '.tim2tox_merged'));

    /// What the manifest of [isolated] records for the peer conversation.
    Future<Map<String, dynamic>> readManifestEntry(Directory isolated) async {
      final decoded = jsonDecode(await manifestOf(isolated).readAsString())
          as Map<String, dynamic>;
      final files = decoded['files'] as Map<String, dynamic>;
      return files['$_peer.json'] as Map<String, dynamic>;
    }

    /// Rewrites that entry through [edit], the way a build that recorded no
    /// digests would have left it.
    Future<void> editManifest(Directory isolated,
        void Function(Map<String, dynamic> entry) edit) async {
      final file = manifestOf(isolated);
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final files = decoded['files'] as Map<String, dynamic>;
      edit(files['$_peer.json'] as Map<String, dynamic>);
      await file.writeAsString(jsonEncode(decoded), flush: true);
    }

    test('a row deleted between two attempts stays deleted across a restart',
        () async {
      final first = await partiallyAdopted(['doomed', 'keeper']);
      expect(await peerFile(base()).readAsString(), contains('doomed'),
          reason: 'the first attempt must really have transferred the file, or '
              'this test proves nothing');

      // The user deletes the row, then the app restarts before the retry: the
      // deletion now exists ONLY as a row missing from the source file.
      expect(await first.store.removeMessage(_peer, 'doomed'), isTrue);
      await first.store.flushPendingSaves();
      await first.store.dispose();

      // A brand-new store: its tombstones are in memory only, so it has none
      // -- which is exactly the state this test is about.
      final second = await opened(ownerKey: _ownerA);
      await first.broken.writeAsString(first.rescue, flush: true);

      expect(await second.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      final rows = (await second.loadHistory(_peer)).map((m) => m.msgID);
      expect(rows, contains('keeper'));
      expect(rows, isNot(contains('doomed')),
          reason: 'the retry put the deleted row back from the copy the first '
              'attempt left in the destination');
      expect(await peerFile(base()).readAsString(), isNot(contains('doomed')),
          reason: 'and it is on disk, not just filtered out of this read');
      await second.dispose();
    });

    test('deleting the LAST row empties our own copy too', () async {
      // The retry has nothing to carry, which used to be the cue to return
      // early and leave the destination alone — with the deleted row in it.
      final first = await partiallyAdopted(['only_row']);
      expect(await first.store.removeMessage(_peer, 'only_row'), isTrue);
      await first.store.flushPendingSaves();
      await first.store.dispose();

      final second = await opened(ownerKey: _ownerA);
      await first.broken.writeAsString(first.rescue, flush: true);
      expect(await second.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      expect(await second.loadHistory(_peer), isEmpty);
      expect(await peerFile(base()).readAsString(), isNot(contains('only_row')));
      await second.dispose();
    });

    test('a destination with rows of its own keeps them', () async {
      // The conservative half of the same decision, and the reason the
      // manifest has to record who wrote the destination rather than just
      // replacing it: here the base already held history, so its rows are NOT
      // ours to drop.
      await seedLegacyDirectory();
      final first = await partiallyAdopted(['mine']);
      // The source changes, so the retry merges it again rather than skipping
      // it on the strength of its name.
      await first.store.appendHistory(_peer, _row('after_the_failure'));
      await first.store.flushPendingSaves();
      await first.store.dispose();

      final second = await opened(ownerKey: _ownerA);
      await first.broken.writeAsString(first.rescue, flush: true);
      expect(await second.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      expect(
        (await second.loadHistory(_peer)).map((m) => m.msgID),
        containsAll(<String>['legacy_row', 'mine', 'after_the_failure']),
        reason: 'a destination this merge did not write must not lose rows to '
            'a retry',
      );
      await second.dispose();
    });

    test('our own copy is replaced, so the LATER read barrier still wins',
        () async {
      // Replacing rows must not replace the read barrier with an older one:
      // that marks read messages unread again.
      final first = await partiallyAdopted(['row']);
      await first.store.updateLastViewTimestamp(_peer, 9000);
      await first.store.flushPendingSaves();
      await first.store.dispose();

      final second = await opened(ownerKey: _ownerA);
      await first.broken.writeAsString(first.rescue, flush: true);
      expect(await second.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      final decoded = jsonDecode(await peerFile(base()).readAsString())
          as Map<String, dynamic>;
      expect(decoded['lastViewTimestamp'], 9000);
      await second.dispose();
    });

    test('an archive is not appended twice when the source grows', () async {
      // `.archive.jsonl` is append-only, so the merge concatenated it -- and a
      // retry concatenated everything the first pass had already contributed.
      await seedBlockerInBase();
      final a = await opened(ownerKey: _ownerA);
      await a.appendHistory('other', _row('other_row'));
      await a.flushPendingSaves();
      final isolated = Directory((await a.ownerBoundDefaultDirectory())!);
      final archive = File(p.join(isolated.path, '$_peer.archive.jsonl'));
      await archive.writeAsString(
        '${jsonEncode(_row('arch_1').toJson())}\n'
        '${jsonEncode(_row('arch_2').toJson())}\n',
        flush: true,
      );
      final broken = File(p.join(isolated.path, 'other.json'));
      final rescue = await broken.readAsString();
      await broken.writeAsString('{ truncated', flush: true);
      await expectLater(a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          throwsA(isA<StateError>()));

      // The session archives one more row into the directory it still uses.
      await archive.writeAsString(
        '${jsonEncode(_row('arch_3').toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      await broken.writeAsString(rescue, flush: true);
      expect(await a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      await a.dispose();

      final lines = (await File(p.join(base().path, '$_peer.archive.jsonl'))
              .readAsString())
          .trim()
          .split('\n');
      expect(lines, hasLength(3),
          reason: 'each archived row belongs in the destination exactly once, '
              'but got:\n${lines.join("\n")}');
      for (final id in ['arch_1', 'arch_2', 'arch_3']) {
        expect(lines.where((l) => l.contains(id)), hasLength(1), reason: id);
      }
    });

    test('an archive the destination already had keeps its own lines', () async {
      // Not ours, so it can only be appended to -- but only with what the
      // source has GROWN by, or the first pass's lines arrive twice.
      await seedBlockerInBase();
      final destArchive = File(p.join(base().path, '$_peer.archive.jsonl'));
      await destArchive.writeAsString(
        '${jsonEncode(_row('theirs').toJson())}\n',
        flush: true,
      );
      final a = await opened(ownerKey: _ownerA);
      await a.appendHistory('other', _row('other_row'));
      await a.flushPendingSaves();
      final isolated = Directory((await a.ownerBoundDefaultDirectory())!);
      final archive = File(p.join(isolated.path, '$_peer.archive.jsonl'));
      await archive.writeAsString(
        '${jsonEncode(_row('arch_1').toJson())}\n',
        flush: true,
      );
      final broken = File(p.join(isolated.path, 'other.json'));
      final rescue = await broken.readAsString();
      await broken.writeAsString('{ truncated', flush: true);
      await expectLater(a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          throwsA(isA<StateError>()));

      await archive.writeAsString(
        '${jsonEncode(_row('arch_2').toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      await broken.writeAsString(rescue, flush: true);
      expect(await a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      await a.dispose();

      final lines = (await destArchive.readAsString()).trim().split('\n');
      expect(lines, hasLength(3), reason: lines.join('\n'));
      for (final id in ['theirs', 'arch_1', 'arch_2']) {
        expect(lines.where((l) => l.contains(id)), hasLength(1), reason: id);
      }
    });

    test('a destination that vanished is transferred again', () async {
      // The source has NOT changed, so it was skipped on its own word -- and
      // the adoption then retired a directory whose rows were in neither place
      // (codex 2026-09-28).
      final first = await partiallyAdopted(['row']);
      expect(await peerFile(base()).exists(), isTrue);
      await peerFile(base()).delete();
      await first.broken.writeAsString(first.rescue, flush: true);

      expect(await first.store.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      expect(await peerFile(base()).exists(), isTrue,
          reason: 'the row is in the adopted directory or nowhere');
      expect(await peerFile(base()).readAsString(), contains('row'));
      await first.store.dispose();
    });

    test('a destination rewritten to the same length is not taken for ours',
        () async {
      // Our copy is recognised by a DIGEST, and this is the case size alone
      // cannot tell apart: another writer replaces it with equally long,
      // different content. Dropping that writer's rows would be exactly the
      // data loss the replace path is supposed to be safe from
      // (codex 2026-09-28).
      final first = await partiallyAdopted(['mine']);
      final dest = peerFile(base());
      final ourCopy = await dest.readAsString();
      // Built by swapping the row id for another of the SAME length inside our
      // own copy, which is the only way to be sure the two files differ in
      // nothing but content -- a hand-built row has a different shape and
      // cannot be padded to an arbitrary length (the id appears twice, so the
      // parity may never match).
      final theirs = ourCopy.replaceAll('mine', 'them');
      expect(theirs.length, ourCopy.length,
          reason: 'this test is only meaningful with two files of equal length');
      expect(theirs, isNot(ourCopy));
      await dest.writeAsString(theirs, flush: true);
      expect(await dest.length(), ourCopy.length,
          reason: 'the point of this test is a destination that size alone '
              'cannot distinguish from our own copy');

      await first.store.appendHistory(_peer, _row('after_the_failure'));
      await first.store.flushPendingSaves();
      await first.broken.writeAsString(first.rescue, flush: true);
      expect(await first.store.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      final merged = await peerFile(base()).readAsString();
      expect(merged, contains('them'),
          reason: 'the other writer\'s row was dropped as if it were our own '
              'earlier copy');
      expect(merged, contains('after_the_failure'));
      await first.store.dispose();
    });

    test('rows recovered from the destination backup survive a third attempt',
        () async {
      // The recovery path rebuilds an undecodable destination out of its own
      // .bak, and those rows were never ours to drop. If the manifest recorded
      // the file as "ours" anyway, the NEXT attempt would drop them
      // (codex 2026-09-28).
      //
      // For that to be reachable, OUR OWN copy has to be the undecodable one:
      // any other writer corrupting the destination changes its digest, so the
      // manifest would already have stopped calling it ours and the recovery
      // would never run on a destination it claims. So the source file starts
      // out invalid and is repaired between the attempts.
      await seedBlockerInBase();
      final a = await opened(ownerKey: _ownerA);
      await a.appendHistory('other', _row('other_row'));
      await a.flushPendingSaves();
      final isolated = Directory((await a.ownerBoundDefaultDirectory())!);
      final source = File(p.join(isolated.path, '$_peer.json'));
      await source.writeAsString('{ truncated', flush: true);
      final broken = File(p.join(isolated.path, 'other.json'));
      final rescue = await broken.readAsString();
      await broken.writeAsString('{ truncated', flush: true);

      await expectLater(a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          throwsA(isA<StateError>()));
      final dest = peerFile(base());
      expect(await dest.readAsString(), '{ truncated',
          reason: 'a destination that did not exist is copied verbatim, so our '
              'own copy is now the undecodable one');

      // The destination gains a backup holding a row that exists nowhere else.
      await File('${dest.path}.bak').writeAsString(
        jsonEncode(<String, Object?>{
          'conversationId': _peer,
          'version': 2,
          'lastViewTimestamp': 0,
          'messages': <Object?>[_row('from_backup').toJson()],
        }),
        flush: true,
      );
      // The source becomes valid, so it is merged again -- into a destination
      // the manifest still rightly calls ours, and which cannot be decoded.
      Future<void> writeSource(List<String> ids) => source.writeAsString(
            jsonEncode(<String, Object?>{
              'conversationId': _peer,
              'version': 2,
              'lastViewTimestamp': 0,
              'messages': ids.map((id) => _row(id).toJson()).toList(),
            }),
            flush: true,
          );
      await writeSource(['repaired']);
      await expectLater(a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          throwsA(isA<StateError>()));
      expect(await dest.readAsString(), contains('from_backup'),
          reason: 'the recovery itself must keep the backup row');

      // Third attempt, source changed again so it is merged rather than skipped.
      await writeSource(['repaired', 'third_attempt']);
      await broken.writeAsString(rescue, flush: true);
      expect(await a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      final merged = await dest.readAsString();
      expect(merged, contains('from_backup'),
          reason: 'a third pass dropped rows that only the backup had');
      expect(merged, contains('third_attempt'));
      await a.dispose();
    });

    test('an archive rewritten to the same length still transfers its new row',
        () async {
      // `removeArchivedMessages` rewrites an archive, so a source can change
      // without changing length. Appending "what it grew by" then transferred
      // NOTHING and the source was certified anyway (codex 2026-09-28).
      await seedBlockerInBase();
      final destArchive = File(p.join(base().path, '$_peer.archive.jsonl'));
      await destArchive.writeAsString(
        '${jsonEncode(_row('theirs').toJson())}\n',
        flush: true,
      );
      final a = await opened(ownerKey: _ownerA);
      await a.appendHistory('other', _row('other_row'));
      await a.flushPendingSaves();
      final isolated = Directory((await a.ownerBoundDefaultDirectory())!);
      final archive = File(p.join(isolated.path, '$_peer.archive.jsonl'));
      final firstLine = '${jsonEncode(_row('arch_1').toJson())}\n';
      await archive.writeAsString(firstLine, flush: true);
      final broken = File(p.join(isolated.path, 'other.json'));
      final rescue = await broken.readAsString();
      await broken.writeAsString('{ truncated', flush: true);
      await expectLater(a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          throwsA(isA<StateError>()));

      // A rewrite, not an append: same length, different row.
      final rewritten = '${jsonEncode(_row('arch_2').toJson())}\n';
      expect(rewritten.length, firstLine.length,
          reason: 'this test needs the rewrite to be byte-length identical');
      await archive.writeAsString(rewritten, flush: true);
      await broken.writeAsString(rescue, flush: true);
      expect(await a.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      await a.dispose();

      final lines = (await destArchive.readAsString()).trim().split('\n');
      expect(lines.where((l) => l.contains('arch_2')), hasLength(1),
          reason: 'the rewritten row never reached the destination:\n'
              '${lines.join("\n")}');
      expect(lines.where((l) => l.contains('theirs')), hasLength(1),
          reason: 'and the destination kept its own line');
    });

    test('a FOREIGN destination that lost the transferred rows is merged again',
        () async {
      // `created` is false here, so the retry can never drop the destination's
      // rows -- but it must still notice the destination no longer holds what
      // was put there. Accepting any existing file let an unchanged source be
      // skipped and then retired, with its rows in neither place
      // (codex 2026-09-28).
      await seedLegacyDirectory();
      final first = await partiallyAdopted(['mine']);
      final dest = peerFile(base());
      expect(await dest.readAsString(), contains('mine'));

      // Another writer puts the destination back to just its own row.
      await dest.writeAsString(
        jsonEncode(<String, Object?>{
          'conversationId': _peer,
          'version': 2,
          'lastViewTimestamp': 0,
          'messages': <Object?>[_row('legacy_row').toJson()],
        }),
        flush: true,
      );
      // The source is NOT touched, so only the destination check can save it.
      await first.broken.writeAsString(first.rescue, flush: true);
      expect(await first.store.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      final merged = await dest.readAsString();
      expect(merged, contains('mine'),
          reason: 'the transferred row was dropped by the other writer and the '
              'retry skipped the source on its own word');
      expect(merged, contains('legacy_row'));
      await first.store.dispose();
    });

    test('a source rewritten to the same length with its mtime restored is not '
        'taken for unchanged', () async {
      // The manifest records a DIGEST of the source, because size and a
      // millisecond mtime can both be made to match a file that has been
      // rewritten -- and the source directory was then retired with rows that
      // had never been transferred (codex 2026-09-28).
      //
      // Reproducing that aliasing takes two steps, and the first version of
      // this test got both wrong. `setLastModified` truncates to whole seconds,
      // so a stamp recorded with milliseconds can never be restored exactly:
      // the source is given a whole-second mtime first. And the stamp is only
      // RE-RECORDED by a pass that actually transfers the file, so its content
      // has to change too -- writing the same bytes back left the old
      // millisecond stamp in the manifest and the alias never held.
      final first = await partiallyAdopted(['row_a']);
      final source = File(p.join(first.isolated.path, '$_peer.json'));
      await source.writeAsString(
          (await source.readAsString()).replaceAll('row_a', 'row_x'),
          flush: true);
      final aligned = DateTime.fromMillisecondsSinceEpoch(
          ((await source.stat()).modified.millisecondsSinceEpoch ~/ 1000) *
              1000);
      await source.setLastModified(aligned);
      await expectLater(
          first.store.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          throwsA(isA<StateError>()));

      // A one-for-one character swap, so the length cannot differ, and the
      // recorded stamp put back exactly.
      final was = await source.readAsString();
      final rewritten = was.replaceAll('row_x', 'row_b');
      expect(rewritten.length, was.length);
      expect(rewritten, isNot(was));
      await source.writeAsString(rewritten, flush: true);
      await source.setLastModified(aligned);

      // The alias is against what the MANIFEST recorded, which is the only
      // comparison the skip path makes. stat() and not lastModified(): the code
      // reads stat().modified, and lastModified() truncates to whole seconds.
      final entry = await readManifestEntry(first.isolated);
      final stat = await source.stat();
      expect(entry['size'], stat.size,
          reason: 'this test is only meaningful while the recorded size matches');
      expect(entry['mtimeMs'], stat.modified.millisecondsSinceEpoch,
          reason: 'and while the recorded mtime matches');
      expect(entry['digest'], isNot(_digestOfString(rewritten)),
          reason: 'while the content does not');

      await first.broken.writeAsString(first.rescue, flush: true);
      expect(await first.store.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      expect(await peerFile(base()).readAsString(), contains('row_b'),
          reason: 'the rewritten source was certified as already transferred');
      await first.store.dispose();
    });

    test('a record with no destination digest is not trusted', () async {
      // `_digestOfFile` returns null on a read error, and a manifest from an
      // older build has no digests at all. Treating "says nothing" as "still
      // fine" reinstated the whole hole: an unchanged source was skipped and
      // then retired although the destination no longer held its rows
      // (codex 2026-09-28).
      final first = await partiallyAdopted(['mine']);
      final dest = peerFile(base());
      expect(await dest.readAsString(), contains('mine'));
      await editManifest(first.isolated, (entry) => entry.remove('destDigest'));

      // Another writer empties the destination; the source is NOT touched.
      await dest.writeAsString(
        jsonEncode(<String, Object?>{
          'conversationId': _peer,
          'version': 2,
          'lastViewTimestamp': 0,
          'messages': <Object?>[],
        }),
        flush: true,
      );
      await first.broken.writeAsString(first.rescue, flush: true);
      expect(await first.store.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      expect(await dest.readAsString(), contains('mine'),
          reason: 'a digest-less record let the retry skip a source whose rows '
              'were no longer in the destination');
      await first.store.dispose();
    });

    test('a record with no source digest is not trusted', () async {
      // Same rule on the source side. The manifest is edited to look like an
      // older build's -- no digest, and a size and mtime that MATCH the file
      // after the rewrite below, which is the aliasing the fallback allowed.
      final first = await partiallyAdopted(['row_a']);
      final source = File(p.join(first.isolated.path, '$_peer.json'));
      final was = await source.readAsString();
      final rewritten = was.replaceAll('row_a', 'row_b');
      expect(rewritten.length, was.length);
      await source.writeAsString(rewritten, flush: true);
      // `stat().modified` and not `lastModified()`: the latter truncates to
      // whole seconds on macOS, and feeding the manifest that value means the
      // aliasing this test needs never holds.
      final stat = await source.stat();
      await editManifest(first.isolated, (entry) {
        entry.remove('digest');
        entry['size'] = stat.size;
        entry['mtimeMs'] = stat.modified.millisecondsSinceEpoch;
      });

      await first.broken.writeAsString(first.rescue, flush: true);
      expect(await first.store.adoptDefaultHistoryDirectory(ownerKey: _ownerA),
          base().path);
      expect(await peerFile(base()).readAsString(), contains('row_b'),
          reason: 'a digest-less record let size and mtime certify a rewritten '
              'source as already transferred');
      await first.store.dispose();
    });
  });
}
