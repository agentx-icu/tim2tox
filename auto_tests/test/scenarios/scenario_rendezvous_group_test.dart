// Rendezvous groups (people nearby) — two nodes in one process.
//
// Alice asks for the cell of a seed; nobody answers, so after 30 s she founds
// it (tox_group_new_with_seed). Bob asks for the same seed and joins her group
// through the DHT announce. Bob's broadcast reaches Alice, Alice's private
// packet reaches Bob only, neither node lists the cell as a V2TIM group, a
// flood from Bob is cut by Alice's native budget, and Bob's leave is seen by
// Alice. The savedata-restore rule (a cell left behind by a crash is left on
// init) is pinned by the gtests (RendezvousGroupsTest.RestoreRule*,
// RendezvousIsolationSourceRegressionTest); it needs a crashed profile and is
// not reproduced here.
//
// Runs wall-clock by default and under the virtual clock with RUN_VIRTUAL=1.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:test/test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/service/rendezvous_transport.dart';

import '../test_fixtures.dart';
import '../test_helper.dart';

const String _label = 'wx4g0';
const String _name = 'toxee-nearby/v1/$_label';

Uint8List _seed() => Uint8List.fromList(
    sha256.convert(utf8.encode('toxee/nearby/v1|$_label')).bytes);

void main() {
  group('Rendezvous group (people nearby cells)', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late RendezvousTransport
        raw; // calls, routed per instance with runWithInstance
    late Stream<RendezvousEvent> events; // from the shared polling service
    final received = <RendezvousEvent>[];
    StreamSubscription<RendezvousEvent>? sub;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);
      await Future.wait([
        alice.login(timeout: const Duration(milliseconds: 500)),
        bob.login(timeout: const Duration(milliseconds: 500)),
      ]);
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );
      await configureLocalBootstrapVirtual(scenario);
      await Future.wait([
        waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 15)),
        waitForConnectionVirtual(scenario, bob,
            timeout: const Duration(seconds: 15)),
      ]);
      raw = RendezvousTransport(ffi_lib.Tim2ToxFfi.open());
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      events = platform.ffiService.rendezvous.events;
      sub = events.listen(received.add);
    });

    tearDownAll(() async {
      await sub?.cancel();
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    Future<void> pumpUntil(bool Function() condition,
        {required String what,
        Duration timeout = const Duration(seconds: 120),
        int advanceMs = 1000}) async {
      // A pump advances native time only in virtual mode. In wall-clock mode
      // its short socket yield does not pay for the 30-second join-to-found
      // timer, so a fixed tick count would expire before founding is possible.
      await waitUntilWithVirtualPump(scenario, condition,
          timeout: timeout,
          description: what,
          advanceMs: advanceMs,
          iterationsPerInstance: 20);
    }

    Iterable<T> of<T extends RendezvousEvent>(TestNode node) => received
        .whereType<T>()
        .where((e) => e.instanceId == node.testInstanceHandle);

    test('join-or-found, payloads, isolation, budget, leave', () async {
      final seed = _seed();

      // Alice: nobody is in the cell, so the join turns into a found after
      // kJoinToFoundMs (30 s) without any peer.
      final aliceRc = alice
          .runWithInstance(() => raw.join(seed, name: _name, nick: 'a1b2c3d4'));
      expect(aliceRc, 1, reason: 'alice join accepted');
      expect(
          alice.runWithInstance(
              () => raw.join(seed, name: _name, nick: 'a1b2c3d4')),
          2,
          reason: 'second request for the same cell reports already present');
      await pumpUntil(() => of<RendezvousJoined>(alice).isNotEmpty,
          what: 'alice joined (founded) the cell',
          timeout: const Duration(seconds: 60));
      final aliceJoined = of<RendezvousJoined>(alice).first;
      expect(aliceJoined.founded, isTrue);
      final chatId = aliceJoined.chatIdHex;
      expect(chatId.length, 64);

      // Bob: same seed -> same chat id -> joins Alice's group via the DHT.
      expect(
          bob.runWithInstance(
              () => raw.join(seed, name: _name, nick: 'e5f6a7b8')),
          1);
      await pumpUntil(
          () =>
              of<RendezvousJoined>(bob).any((e) => e.chatIdHex == chatId) &&
              of<RendezvousPeer>(alice).any((e) => e.joined) &&
              of<RendezvousPeer>(bob).any((e) => e.joined),
          what: 'bob joined and both saw a peer',
          timeout: const Duration(seconds: 90));
      expect(of<RendezvousJoined>(bob).first.founded, isFalse,
          reason: 'bob must have joined, not founded a second group');
      final alicePk = of<RendezvousPeer>(bob).first.peerPkHex;
      final bobPk = of<RendezvousPeer>(alice).first.peerPkHex;
      expect(alice.runWithInstance(() => raw.peerCount(chatId)), 1);
      expect(bob.runWithInstance(() => raw.peerCount(chatId)), 1);

      // Neither node lists the cell as a V2TIM group.
      for (final node in [alice, bob]) {
        final list = await node.runWithInstanceAsync(
            () async => TIMGroupManager.instance.getJoinedGroupList());
        expect(list.code, 0);
        expect(list.data ?? const [], isEmpty,
            reason: '${node.alias} must not list the rendezvous cell');
      }

      // Bob broadcasts; Alice receives it as a broadcast packet.
      final hello = Uint8List.fromList(utf8.encode('{"t":"presence","v":1}'));
      expect(bob.runWithInstance(() => raw.send(chatId, hello)), 1);
      await pumpUntil(() => of<RendezvousPacket>(alice).isNotEmpty,
          what: 'alice received bob broadcast',
          timeout: const Duration(seconds: 30));
      final pkt = of<RendezvousPacket>(alice).first;
      expect(pkt.isPrivate, isFalse);
      expect(pkt.peerPkHex, bobPk);
      expect(utf8.decode(pkt.payload), '{"t":"presence","v":1}');

      // Alice sends a private packet to Bob only.
      final intent = Uint8List.fromList(utf8.encode('{"t":"intent","v":1}'));
      expect(
          alice.runWithInstance(
              () => raw.send(chatId, intent, peerPkHex: bobPk)),
          1);
      await pumpUntil(() => of<RendezvousPacket>(bob).isNotEmpty,
          what: 'bob received alice private packet',
          timeout: const Duration(seconds: 30));
      final priv = of<RendezvousPacket>(bob).first;
      expect(priv.isPrivate, isTrue);
      expect(priv.peerPkHex, alicePk);
      expect(utf8.decode(priv.payload), '{"t":"intent","v":1}');
      expect(of<RendezvousPacket>(alice).where((e) => e.isPrivate), isEmpty,
          reason: 'a private packet never echoes to its sender');

      // Error codes of send.
      expect(
          alice.runWithInstance(
              () => raw.send(chatId, intent, peerPkHex: 'f' * 64)),
          -2);
      expect(alice.runWithInstance(() => raw.send('0' * 64, intent)), -3);
      expect(
          alice.runWithInstance(() => raw.send(
              chatId, Uint8List(RendezvousTransport.maxPayloadBytes + 1))),
          -1);

      // A flood from Bob is cut by Alice's native per-peer budget (6 / 10 s).
      final before = of<RendezvousPacket>(alice).length;
      for (var i = 0; i < 12; i++) {
        bob.runWithInstance(() => raw.send(chatId, Uint8List.fromList([i])));
      }
      await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 40);
      await pumpTestTick(scenario, advanceMs: 200, iterationsPerInstance: 40);
      final delivered = of<RendezvousPacket>(alice).length - before;
      expect(delivered, lessThanOrEqualTo(6),
          reason: 'budget admits at most 6 packets per 10 s per peer');
      expect(alice.runWithInstance(() => raw.dropCount()), greaterThan(0));

      // DHT health signal is available.
      expect(alice.runWithInstance(() => raw.dhtAnnounceCapableCount()),
          greaterThanOrEqualTo(0));

      // Bob leaves: Alice sees the exit, Bob is told it left.
      expect(bob.runWithInstance(() => raw.leave(chatId)), isTrue);
      await pumpUntil(
          () =>
              of<RendezvousLeft>(bob).any((e) => e.reason == 'left') &&
              of<RendezvousPeer>(alice).any((e) => !e.joined),
          what: 'bob left and alice saw the exit',
          timeout: const Duration(seconds: 60));
      expect(bob.runWithInstance(() => raw.peerCount(chatId)), -1);
      expect(bob.runWithInstance(() => raw.leave(chatId)), isFalse);

      // Leave-all on Alice leaves her founded cell too.
      expect(alice.runWithInstance(() => raw.leaveAll()), 1);
      await pumpUntil(
          () => of<RendezvousLeft>(alice).any((e) => e.reason == 'left'),
          what: 'alice left her cell',
          timeout: const Duration(seconds: 30));
      expect(alice.runWithInstance(() => raw.peerCount(chatId)), -1);
    }, timeout: const Timeout(Duration(seconds: 170)));
  });
}
