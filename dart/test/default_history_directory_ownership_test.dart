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
const _markerName = '.tim2tox_history_owner';

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
}
