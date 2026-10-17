import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;

import '../ffi/tim2tox_ffi.dart';

/// One event from the native rendezvous layer (a `rendezvous_*` poll line).
///
/// Rendezvous groups are transport-only NGC public groups whose Chat ID is
/// derived from a 32-byte seed; see `source/RendezvousGroups.h` and
/// `doc/architecture/RENDEZVOUS_GROUPS.md`. The transport knows nothing about
/// what the payload means — the client (toxee's nearby feature) owns that.
sealed class RendezvousEvent {
  RendezvousEvent(this.chatIdHex);

  /// Lower-case hex Chat ID (64 chars) of the cell.
  final String chatIdHex;

  /// The native instance that produced the line (0 = the default instance).
  /// Production clients have one instance; the multi-instance auto_tests use
  /// it to tell receivers apart. Stamped by [RendezvousTransport.handleLine].
  int instanceId = 0;
}

/// We are in the cell: joined an existing group (`founded == false`) or
/// founded it because nobody answered within 30 s (`founded == true`).
final class RendezvousJoined extends RendezvousEvent {
  RendezvousJoined(super.chatIdHex, {required this.founded});
  final bool founded;
}

/// We left the cell. `reason` is one of `kicked`, `failed`, `stale`, `left`,
/// `full`. (`refound` is internal and never surfaces.)
final class RendezvousLeft extends RendezvousEvent {
  RendezvousLeft(super.chatIdHex, {required this.reason});
  final String reason;
}

/// A peer became confirmed (`joined == true`) or left.
final class RendezvousPeer extends RendezvousEvent {
  RendezvousPeer(super.chatIdHex,
      {required this.peerPkHex, required this.joined});
  final String peerPkHex;
  final bool joined;
}

/// Coalesced form emitted when peer events exceed the native budget: the
/// client should re-read the peer count and rebuild its table lazily.
final class RendezvousPeersChanged extends RendezvousEvent {
  RendezvousPeersChanged(super.chatIdHex, {required this.count});
  final int count;
}

/// The cell refused us because it is full (peer limit).
final class RendezvousFull extends RendezvousEvent {
  RendezvousFull(super.chatIdHex);
}

/// An opaque payload from `peerPkHex` (`private == true` when it came over a
/// private packet).
final class RendezvousPacket extends RendezvousEvent {
  RendezvousPacket(super.chatIdHex,
      {required this.peerPkHex,
      required this.isPrivate,
      required this.payload});
  final String peerPkHex;
  final bool isPrivate;
  final Uint8List payload;
}

/// Thin Dart face of the native rendezvous API plus the parsed event stream.
///
/// `FfiChatService` owns one instance and feeds it the `rendezvous_*` poll
/// lines before any message branch runs, so nothing here ever touches
/// history, conversations or the known-groups list.
class RendezvousTransport {
  RendezvousTransport(this._ffi);

  final Tim2ToxFfi _ffi;
  StreamController<RendezvousEvent> _events =
      StreamController<RendezvousEvent>.broadcast();

  /// One boundary for the whole frame (6-byte header + payload).
  static const int maxFrameBytes = 1200;
  static const int maxPayloadBytes = maxFrameBytes - 6;

  static const String _prefix = 'rendezvous_';

  /// The wire enum of `rendezvous_left` reasons.
  static const Set<String> leftReasons = {'kicked', 'failed', 'stale', 'left', 'full'};

  Stream<RendezvousEvent> get events => _events.stream;

  /// Cells each instance has been told it is in (joined and not yet left),
  /// so [dispose] can close them for the consumer: lines the native side
  /// emits while `UnInitSDK` leaves the cells are purged with the instance
  /// queue (`tim2tox_ffi_uninit`) and never reach Dart. Keyed by instance:
  /// the shared poller stamps lines of several instances through one
  /// transport, and two instances may sit in the same cell.
  final Map<int, Set<String>> _joined = <int, Set<String>>{};
  Set<String> joinedChatIdsOf(int instanceId) =>
      Set.unmodifiable(_joined[instanceId] ?? const <String>{});
  Set<String> get joinedChatIds =>
      Set.unmodifiable(_joined.values.expand((s) => s).toSet());

  /// True for a poll line this transport consumes.
  static bool isRendezvousLine(String line) => line.startsWith(_prefix);

  /// Parses one poll line; null when it is not a well-formed rendezvous line.
  static RendezvousEvent? parseLine(String line) {
    if (!line.startsWith(_prefix)) return null;
    final colon = line.indexOf(':');
    if (colon < 0) return null;
    final kind = line.substring(0, colon);
    final rest = line.substring(colon + 1);
    switch (kind) {
      case 'rendezvous_joined':
        final parts = rest.split(':');
        if (parts.length != 2 || !_isChatId(parts[0])) return null;
        if (parts[1] != '0' && parts[1] != '1') return null;
        return RendezvousJoined(parts[0], founded: parts[1] == '1');
      case 'rendezvous_left':
        final parts = rest.split(':');
        if (parts.length != 2 || !_isChatId(parts[0]) || !leftReasons.contains(parts[1])) {
          return null;
        }
        return RendezvousLeft(parts[0], reason: parts[1]);
      case 'rendezvous_peer':
        final parts = rest.split(':');
        if (parts.length != 3 || !_isChatId(parts[0]) || !_isKey(parts[1])) {
          return null;
        }
        if (parts[2] != 'join' && parts[2] != 'exit') return null;
        return RendezvousPeer(parts[0],
            peerPkHex: parts[1], joined: parts[2] == 'join');
      case 'rendezvous_peers_changed':
        final parts = rest.split(':');
        if (parts.length != 2 || !_isChatId(parts[0])) return null;
        final count = int.tryParse(parts[1]);
        if (count == null || count < 0) return null;
        return RendezvousPeersChanged(parts[0], count: count);
      case 'rendezvous_full':
        if (!_isChatId(rest)) return null;
        return RendezvousFull(rest);
      case 'rendezvous_packet':
        // <chat>:<pk>:<b|p>:<hex>; the hex may be empty for a zero-length payload.
        final parts = rest.split(':');
        if (parts.length != 4 || !_isChatId(parts[0]) || !_isKey(parts[1])) {
          return null;
        }
        if (parts[2] != 'b' && parts[2] != 'p') return null;
        final payload = _unhex(parts[3]);
        if (payload == null || payload.length > maxPayloadBytes) return null;
        return RendezvousPacket(parts[0],
            peerPkHex: parts[1], isPrivate: parts[2] == 'p', payload: payload);
      default:
        return null;
    }
  }

  /// Feeds one poll line. Returns true when it was a rendezvous line (parsed
  /// or malformed), so the caller skips every other branch.
  bool handleLine(String line, {int instanceId = 0}) {
    if (!isRendezvousLine(line)) return false;
    final event = parseLine(line);
    if (event != null && !_events.isClosed) {
      switch (event) {
        case RendezvousJoined():
          _joined.putIfAbsent(instanceId, () => <String>{}).add(event.chatIdHex);
        case RendezvousLeft():
          final cells = _joined[instanceId];
          if (cells != null) {
            cells.remove(event.chatIdHex);
            if (cells.isEmpty) _joined.remove(instanceId);
          }
        default:
          break;
      }
      _events.add(event..instanceId = instanceId);
    }
    return true;
  }

  /// Sets the name/seed convention used to recognise a cell restored from
  /// savedata. Call before init; the native defaults are toxee's literals.
  bool setConvention(
      {required String namePrefix, required String seedPrefix}) {
    final n = namePrefix.toNativeUtf8();
    final s = seedPrefix.toNativeUtf8();
    try {
      return _ffi.rendezvousSetConvention(n, s) == 1;
    } finally {
      pkgffi.malloc.free(n);
      pkgffi.malloc.free(s);
    }
  }

  /// Joins (or founds) the cell of [seed]. 1 accepted, 0 refused, 2 already.
  int join(Uint8List seed, {required String name, required String nick}) {
    if (seed.length != 32 || name.isEmpty || nick.isEmpty) return 0;
    final seedPtr = pkgffi.malloc.allocate<ffi.Uint8>(32);
    final namePtr = name.toNativeUtf8();
    final nickPtr = nick.toNativeUtf8();
    try {
      seedPtr.asTypedList(32).setAll(0, seed);
      return _ffi.rendezvousJoin(seedPtr, namePtr, nickPtr);
    } finally {
      pkgffi.malloc.free(seedPtr);
      pkgffi.malloc.free(namePtr);
      pkgffi.malloc.free(nickPtr);
    }
  }

  bool leave(String chatIdHex) {
    final p = chatIdHex.toNativeUtf8();
    try {
      return _ffi.rendezvousLeave(p) == 1;
    } finally {
      pkgffi.malloc.free(p);
    }
  }

  /// Number of cells asked to leave, -1 when not initialized.
  int leaveAll() => _ffi.rendezvousLeaveAll();

  /// 1 sent, 0 not sent, -1 too large, -2 unknown peer, -3 unknown cell.
  int send(String chatIdHex, Uint8List payload, {String? peerPkHex}) {
    // A header-only frame (empty payload) is valid on the wire.
    if (payload.length > maxPayloadBytes) return -1;
    final chat = chatIdHex.toNativeUtf8();
    final peer = (peerPkHex == null || peerPkHex.isEmpty)
        ? ffi.nullptr
        : peerPkHex.toNativeUtf8();
    final data = pkgffi.malloc.allocate<ffi.Uint8>(payload.isEmpty ? 1 : payload.length);
    try {
      if (payload.isNotEmpty) data.asTypedList(payload.length).setAll(0, payload);
      return _ffi.rendezvousSend(chat, peer, data, payload.length);
    } finally {
      pkgffi.malloc.free(chat);
      if (peer != ffi.nullptr) pkgffi.malloc.free(peer);
      pkgffi.malloc.free(data);
    }
  }

  /// Confirmed peers in the cell, -1 unknown.
  int peerCount(String chatIdHex) {
    final p = chatIdHex.toNativeUtf8();
    try {
      return _ffi.rendezvousPeerCount(p);
    } finally {
      pkgffi.malloc.free(p);
    }
  }

  int dropCount() => _ffi.rendezvousDropCount();

  /// DHT nodes near us that can store announces; 0 means group discovery
  /// cannot work yet, -1 not initialized.
  int dhtAnnounceCapableCount() => _ffi.dhtAnnounceCapableCount();

  /// Ends the session view. Every cell still joined is reported left first
  /// (`reason: left`, stamped with its instance): the native side leaves
  /// them during `UnInitSDK`, but its lines cannot be delivered any more
  /// (see [_joined]). The stream is then closed — without waiting for a
  /// paused subscriber to see the done event, so the service teardown that
  /// calls this is never held up — and a fresh stream is put in place for
  /// the next session of the same service (`_beginSession` re-init).
  Future<void> dispose() async {
    final old = _events;
    for (final entry in _joined.entries) {
      for (final chat in entry.value.toList()) {
        old.add(RendezvousLeft(chat, reason: 'left')..instanceId = entry.key);
      }
    }
    _joined.clear();
    _events = StreamController<RendezvousEvent>.broadcast();
    unawaited(old.close());
  }

  static bool _isChatId(String s) => s.length == 64 && _isLowerHex(s);
  static bool _isKey(String s) => s.length == 64 && _isLowerHex(s);

  static bool _isLowerHex(String s) {
    for (final unit in s.codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isLower = unit >= 0x61 && unit <= 0x66;
      if (!isDigit && !isLower) return false;
    }
    return true;
  }

  static Uint8List? _unhex(String s) {
    if (s.length.isOdd || !_isLowerHex(s)) return null;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
    }
    return out;
  }
}
