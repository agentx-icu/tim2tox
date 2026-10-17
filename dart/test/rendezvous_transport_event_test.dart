import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/service/rendezvous_transport.dart';

/// The transport never calls into native in these tests.
final class _NoFfi implements Tim2ToxFfi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final chat = 'a' * 64;
  final pk = 'b' * 64;

  test('parses every rendezvous line kind', () {
    final joined =
        RendezvousTransport.parseLine('rendezvous_joined:$chat:1') as RendezvousJoined;
    expect(joined.chatIdHex, chat);
    expect(joined.founded, isTrue);
    expect(
        (RendezvousTransport.parseLine('rendezvous_joined:$chat:0') as RendezvousJoined)
            .founded,
        isFalse);

    final left =
        RendezvousTransport.parseLine('rendezvous_left:$chat:kicked') as RendezvousLeft;
    expect(left.reason, 'kicked');

    final peer = RendezvousTransport.parseLine('rendezvous_peer:$chat:$pk:join')
        as RendezvousPeer;
    expect(peer.peerPkHex, pk);
    expect(peer.joined, isTrue);
    expect(
        (RendezvousTransport.parseLine('rendezvous_peer:$chat:$pk:exit') as RendezvousPeer)
            .joined,
        isFalse);

    final changed = RendezvousTransport.parseLine('rendezvous_peers_changed:$chat:12')
        as RendezvousPeersChanged;
    expect(changed.count, 12);

    expect(RendezvousTransport.parseLine('rendezvous_full:$chat'), isA<RendezvousFull>());

    final packet = RendezvousTransport.parseLine('rendezvous_packet:$chat:$pk:p:0102ff')
        as RendezvousPacket;
    expect(packet.isPrivate, isTrue);
    expect(packet.payload, Uint8List.fromList([1, 2, 255]));
    final broadcast = RendezvousTransport.parseLine('rendezvous_packet:$chat:$pk:b:')
        as RendezvousPacket;
    expect(broadcast.isPrivate, isFalse);
    expect(broadcast.payload, isEmpty);
  });

  test('rejects malformed lines instead of guessing', () {
    final bad = <String>[
      'rendezvous_joined:short:1',
      'rendezvous_joined',
      'rendezvous_left:',
      'rendezvous_peer:XX:join',
      'rendezvous_peers_changed:abc:-1',
      'rendezvous_full:',
      'rendezvous_packet:',
      'rendezvous_unknown:x',
      'rendezvous_joined:$chat:2',
      'rendezvous_left:$chat:evicted',
      'gcustombin:tox_group_0|x:00',
    ];
    for (final line in bad) {
      expect(RendezvousTransport.parseLine(line), isNull, reason: line);
    }
    // Upper-case hex is not canonical on this wire.
    expect(RendezvousTransport.parseLine('rendezvous_peer:${'A' * 64}:$pk:join'),
        isNull);
    // Odd-length or non-hex payload.
    expect(RendezvousTransport.parseLine('rendezvous_packet:$chat:$pk:b:abc'), isNull);
    expect(RendezvousTransport.parseLine('rendezvous_packet:$chat:$pk:b:zz'), isNull);
    // Payload above the frame budget.
    final tooBig = 'ab' * (RendezvousTransport.maxPayloadBytes + 1);
    expect(RendezvousTransport.parseLine('rendezvous_packet:$chat:$pk:b:$tooBig'),
        isNull);
  });

  test('isRendezvousLine claims only its own prefix', () {
    expect(RendezvousTransport.isRendezvousLine('rendezvous_joined:$chat:1'), isTrue);
    expect(RendezvousTransport.isRendezvousLine('rendezvous_nonsense'), isTrue);
    expect(RendezvousTransport.isRendezvousLine('gtext:x|y:hello'), isFalse);
    expect(RendezvousTransport.isRendezvousLine('c2c:x:rendezvous_joined'), isFalse);
  });

  test('dispose reports every still-joined cell as left, per instance, and reopens', () async {
    final transport = RendezvousTransport(_NoFfi());
    final seen = <RendezvousEvent>[];
    final sub = transport.events.listen(seen.add);
    final other = 'b' * 64;
    // Two instances share the poller; both sit in `chat`, one also in `other`.
    expect(transport.handleLine('rendezvous_joined:$chat:1', instanceId: 3), isTrue);
    expect(transport.handleLine('rendezvous_joined:$chat:0', instanceId: 4), isTrue);
    expect(transport.handleLine('rendezvous_joined:$other:0', instanceId: 4), isTrue);
    expect(transport.handleLine('rendezvous_left:$other:stale', instanceId: 4), isTrue);
    // Instance 4 leaving `chat` does not touch instance 3's membership.
    expect(transport.handleLine('rendezvous_left:$chat:left', instanceId: 4), isTrue);
    expect(transport.joinedChatIdsOf(3), {chat});
    expect(transport.joinedChatIdsOf(4), isEmpty);
    expect(transport.joinedChatIds, {chat});
    // A paused subscriber must not hold the teardown up.
    final paused = transport.events.listen((_) {})..pause();
    await transport.dispose().timeout(const Duration(seconds: 1));
    // The (async) broadcast controller delivers in microtasks: let them run
    // before cancelling the subscription.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    final lefts = seen.whereType<RendezvousLeft>().toList();
    expect(lefts.map((e) => (e.chatIdHex, e.instanceId)), [(other, 4), (chat, 4), (chat, 3)]);
    expect(lefts.last.reason, 'left');
    expect(transport.joinedChatIds, isEmpty);
    await paused.cancel();
    // The next session of the same service gets a live stream again.
    final again = <RendezvousEvent>[];
    final sub2 = transport.events.listen(again.add);
    expect(transport.handleLine('rendezvous_joined:$chat:1', instanceId: 5), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(again.single, isA<RendezvousJoined>());
    expect(transport.joinedChatIdsOf(5), {chat});
    await transport.dispose();
    await sub2.cancel();
  });
}
