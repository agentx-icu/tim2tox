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

      final b = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..openSession(ownerKey: _ownerB);
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

      final a = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..openSession(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);
      await a.dispose();

      final b = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..openSession(ownerKey: _ownerB);
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

      final a = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..declareProvenDefaultOwner(_ownerA)
        ..openSession(ownerKey: _ownerA);
      expect((await a.loadHistory(_peer)).map((m) => m.msgID), ['legacy_row'],
          reason: 'the proven owner keeps its history, in place');
      await a.saveHistory(_peer, [_row('legacy_row'), _row('from_a')]);
      await a.dispose();

      expect((await marker(base()).readAsString()).trim(), _ownerA,
          reason: 'adopting must mark the directory, so the NEXT account is '
              'refused by the marker rather than by the declaration');

      // A second account on the same device, even if it too claimed to be
      // proven, is now refused by the marker.
      final b = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..declareProvenDefaultOwner(_ownerB)
        ..openSession(ownerKey: _ownerB);
      expect(await b.loadHistory(_peer), isEmpty);
      await b.saveHistory(_peer, [_row('from_b')]);
      await b.dispose();

      expect(await peerFile(base()).readAsString(), contains('from_a'));
      expect(await peerFile(base()).readAsString(), isNot(contains('from_b')));
    });

    test('a declaration for another identity does not open the directory',
        () async {
      await seedLegacyDirectory();

      final b = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..declareProvenDefaultOwner(_ownerA)
        ..openSession(ownerKey: _ownerB);
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
      final a = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..openSession(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);
      await a.dispose();
      expect((await marker(base()).readAsString()).trim(), _ownerA,
          reason: 'an EMPTY default directory is claimed, as before');

      final again = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..openSession(ownerKey: '${_ownerA}0102030405AB');
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
      final anon = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..openSession();
      expect((await anon.loadHistory(_peer)).map((m) => m.msgID),
          ['legacy_row']);
      await anon.dispose();
    });

    test('a session with no owner is kept out of a CLAIMED directory',
        () async {
      final a = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..openSession(ownerKey: _ownerA);
      await a.saveHistory(_peer, [_row('from_a')]);
      await a.dispose();

      final anon = MessageHistoryPersistence(appSupportRootOverride: root.path)
        ..openSession();
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
}
