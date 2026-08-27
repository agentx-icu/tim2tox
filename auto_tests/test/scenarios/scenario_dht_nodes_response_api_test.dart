/// DHT Nodes Response API Test — virtual-clock variant
///
/// Mirrors scenario_dht_nodes_response_api_test.dart 1:1 but drives the
/// harness via the virtual-clock helpers (VirtualClock + pumpTestTick +
/// *Virtual helpers).
///
/// NOTE: Migration is mechanical; the original test is gated behind
/// RUN_NATIVE_CRASH_TESTS=1 because of a known native crash in DHT crawling
/// (run_tests_ordered.sh). That crash is unrelated to virtual mode.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:test/test.dart';
import 'package:ffi/ffi.dart' as pkgffi;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('DHT Nodes Response API Tests', () {
    const numNodes = 5;
    late TestScenario scenario;
    late List<TestNode> nodes;
    late List<String> publicKeys;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();

      final aliases = List.generate(numNodes, (i) => 'peer-$i');
      scenario = await createTestScenario(aliases);

      nodes = aliases.map((alias) => scenario.getNode(alias)!).toList();

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait(nodes.map((node) => node.login()));

      await waitUntil(
        () => nodes.every((node) => node.loggedIn),
        timeout: const Duration(seconds: 10),
        description: 'all nodes logged in',
      );

      publicKeys = [];
      for (final node in nodes) {
        final dhtId = node.getToxId();
        if (dhtId.length == 76) {
          publicKeys.add(dhtId.substring(0, 64));
        } else if (dhtId.length == 64) {
          publicKeys.add(dhtId);
        } else {
          throw Exception(
              'Invalid DHT ID length for node ${node.alias}: ${dhtId.length}');
        }
      }

      await configureLinearBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('DHT nodes crawling: All nodes discover each other via DHT', () async {
      try {
        final connectionFutures = nodes.asMap().entries.map((entry) {
          final node = entry.value;
          return waitForConnectionVirtual(scenario, node,
                  timeout: const Duration(seconds: 30))
              .catchError((Object error) {
            // ignore: avoid_print
            print('[Test] Connection wait failed for ${node.alias}: $error');
          });
        }).toList();

        await Future.wait(connectionFutures, eagerError: false);
      } catch (e) {
        // ignore: avoid_print
        print('[Test] Error waiting for connections: $e');
      }

      final discoveredNodes = List.generate(numNodes, (_) => <String>{});
      final chatServices = <FfiChatService>[];

      for (int i = 0; i < nodes.length; i++) {
        final node = nodes[i];
        final nodeIndex = i;
        final chatService = await node.runWithInstanceAsync(() async {
          final svc = FfiChatService();
          svc.setDhtNodesResponseCallback((publicKey, ip, port) {
            discoveredNodes[nodeIndex].add(publicKey);
          });
          return svc;
        });
        chatServices.add(chatService);
      }

      final dhtKeys = <String>[];
      final udpPorts = <int>[];
      for (final node in nodes) {
        final pair = await node.runWithInstanceAsync(() async {
          final ffiInstance = ffi_lib.Tim2ToxFfi.open();
          final port =
              ffiInstance.getUdpPort(ffiInstance.getCurrentInstanceId());
          final buf = pkgffi.malloc.allocate<ffi.Int8>(65);
          try {
            final len = ffiInstance.getDhtIdNative(buf, 65);
            final key = (len > 0 && len <= 64)
                ? buf.cast<pkgffi.Utf8>().toDartString(length: len)
                : '';
            return (port, key);
          } finally {
            pkgffi.malloc.free(buf);
          }
        });
        udpPorts.add(pair.$1);
        dhtKeys.add(pair.$2);
      }
      print(
          '[dht-api] dhtKeys=${dhtKeys.map(_short).toList()} ports=$udpPorts');
      // The node key a getnodes request is ENCRYPTED to must be the peer's DHT
      // public key (`tox_self_get_dht_id`), NOT the first 64 chars of its Tox
      // ID (its long-term key). Addressing a node by its Tox ID makes the
      // request undecryptable, the node silently drops it, and the test then
      // "proves" nothing while looking like it exercised the API.
      for (var i = 0; i < numNodes; i++) {
        expect(dhtKeys[i], isNot(equalsIgnoringCase(publicKeys[i])),
            reason: 'DHT id and Tox ID prefix must not be conflated');
      }

      var totalRequests = 0;
      for (int i = 1; i < nodes.length; i++) {
        final bsPort = udpPorts[i - 1];
        final bsPublicKey = dhtKeys[i - 1];

        final chatService = chatServices[i];
        await nodes[i].runWithInstanceAsync(() async {
          for (final targetPublicKey in publicKeys) {
            final ok = chatService.dhtSendNodesRequest(
                bsPublicKey, '127.0.0.1', bsPort, targetPublicKey);
            expect(ok, isTrue,
                reason: 'node$i could not send a getnodes request to '
                    '127.0.0.1:$bsPort');
            totalRequests++;
          }
        });
      }

      // Allow DHT to respond.
      for (var round = 0; round < 10; round++) {
        await pumpTestTick(scenario,
            advanceMs: 5000, iterationsPerInstance: 20);
        if (!shouldRunVirtual) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }

      for (var i = 0; i < discoveredNodes.length; i++) {
        print('[dht-api] node$i dht=${_short(dhtKeys[i])} '
            'queried=${i == 0 ? "-" : _short(dhtKeys[i - 1])} '
            'discovered=${discoveredNodes[i].length} '
            '${discoveredNodes[i].map(_short).toList()}');
      }
      final discoveryCounts = discoveredNodes.map((set) => set.length).toList();
      final totalDiscoveries = discoveryCounts.reduce((a, b) => a + b);

      // NOT `>= 0`. The previous assertion was tautological and passed with
      // ZERO deliveries for years, which is exactly how the FFI callback could
      // be silently dead. This one goes red the moment the callback stops
      // being delivered to Dart.
      expect(totalDiscoveries, greaterThan(0),
          reason: 'tox_callback_dht_nodes_response delivered NOTHING to Dart '
              'after $totalRequests getnodes requests between $numNodes live '
              'peers — the FFI callback chain (tox_callback_dht_nodes_response '
              '-> on_dht_nodes_response_internal -> NativeCallable trampoline '
              '-> FfiChatService) is broken.');

      // CONTRACT PIN. toxcore reports the nodes CONTAINED IN the response (the
      // responder's neighbours), never the responder itself — see
      // DHT.c:handle_nodes_response, which loops over `plain_nodes[i]`. A node
      // never lists itself among its own close nodes, so the key we queried can
      // never come back. Any consumer that waits for a callback keyed by the
      // QUERIED node's public key therefore waits forever. toxee's
      // BootstrapNodeProbe did exactly that and reported every node — live or
      // dead — as unreachable.
      for (var i = 1; i < numNodes; i++) {
        if (discoveredNodes[i].isEmpty) continue;
        expect(discoveredNodes[i].map((k) => k.toUpperCase()),
            isNot(contains(dhtKeys[i - 1].toUpperCase())),
            reason: 'node$i queried ${_short(dhtKeys[i - 1])} and the callback '
                'reported that same key back. If this ever passes, the event '
                'semantics changed and responder-keyed matching became viable; '
                'revisit BootstrapNodeProbe.');
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    /// Pins the exact contract toxee's `BootstrapNodeProbe` now relies on.
    ///
    /// A bootstrap-node reachability probe cannot key on the responder (see the
    /// contract pin above), so it instead runs on a **deliberately isolated**
    /// Tox instance — fresh profile, `local_discovery_enabled = 0`, no
    /// bootstrap nodes — where the ONLY node it ever queries is the candidate.
    /// toxcore only accepts a nodes response whose sender public key, address
    /// and ping id match a request we actually sent
    /// (`DHT.c:sent_nodes_request_to_node`), so on such an instance "any
    /// `dht_nodes_response` at all" is sound evidence that the candidate
    /// answered.
    ///
    /// This test drives BOTH directions on ONE instance, because a probe that
    /// always says "unreachable" and a probe that always says "reachable" are
    /// equally useless and each would satisfy a one-sided assertion.
    test(
        'send refusal carries its reason: unresolvable host is BAD_IP, '
        'not a local constraint', () async {
      // toxee's BootstrapNodeProbe turns "no request ever left" into a
      // verdict, and it can only do that honestly if the FFI says WHY. Before
      // tim2tox_ffi_dht_send_nodes_request returned the negated
      // Tox_Err_Dht_Send_Nodes_Request, an unresolvable host on a UDP-capable
      // desktop was rendered as "this device is running TCP-only".
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      final target = await _dhtEndpointOf(nodes[0]);
      expect(target.$1, greaterThan(0), reason: 'peer-0 needs a UDP port');
      expect(target.$2.length, 64, reason: 'peer-0 needs a DHT public key');

      final dir = Directory.systemTemp.createTempSync('t2t_send_reason_');
      final prev = ffiInstance.getCurrentInstanceId();
      final pathPtr = dir.path.toNativeUtf8();
      final int handle;
      try {
        handle = ffiInstance.createTestInstanceExNative(pathPtr, 0, 1);
      } finally {
        pkgffi.malloc.free(pathPtr);
      }
      try {
        expect(handle, isNot(0),
            reason: 'the probe instance must be creatable at runtime');
        ffiInstance.setCurrentInstance(handle);
        final svc = FfiChatService();
        final udp = ffiInstance.getUdpPort(handle);
        expect(udp, greaterThan(0),
            reason: 'this case needs a UDP-capable instance so UDP_DISABLED '
                'cannot be the reason');
        // RFC 2606 reserves .invalid: it never resolves, on any resolver.
        final unresolvable = svc.dhtSendNodesRequestChecked(
            target.$2, 'no-such-host.invalid', target.$1, target.$2);
        final badPort = svc.dhtSendNodesRequestChecked(
            target.$2, '127.0.0.1', 0, target.$2);
        final accepted = svc.dhtSendNodesRequestChecked(
            target.$2, '127.0.0.1', target.$1, target.$2);
        final legacyBool = svc.dhtSendNodesRequest(
            target.$2, '127.0.0.1', target.$1, target.$2);
        expect(unresolvable, DhtSendNodesRequestError.badIp,
            reason: 'an unresolvable host must come back as BAD_IP — the '
                'descriptor is wrong, this device is not (got '
                'unresolvable=$unresolvable badPort=$badPort '
                'accepted=$accepted legacyBool=$legacyBool)');
        expect(badPort, DhtSendNodesRequestError.badPort);
        expect(accepted, isNull,
            reason: 'a well-formed request to a live local endpoint must be '
                'accepted by toxcore');
        expect(legacyBool, isTrue,
            reason: 'the boolean wrapper keeps its == 1 contract');
      } finally {
        if (handle != 0) {
          ffiInstance.setCurrentInstance(0);
          ffiInstance.destroyTestInstance(handle);
          ffiInstance.setCurrentInstance(prev);
        }
        try {
          dir.deleteSync(recursive: true);
        } catch (e) {
          // Non-fatal for the verdict (the instance is already destroyed), but
          // a leaked save dir is worth seeing in the output.
          stderr.writeln('[dht-send-reason] temp dir cleanup failed: $e');
        }
      }
    });

    test('isolated probe instance: dead endpoint is silent, live node answers',
        () async {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      final target = await _dhtEndpointOf(nodes[0]);
      expect(target.$1, greaterThan(0), reason: 'peer-0 needs a UDP port');
      expect(target.$2.length, 64, reason: 'peer-0 needs a DHT public key');

      final dir = Directory.systemTemp.createTempSync('t2t_node_probe_');
      final prev = ffiInstance.getCurrentInstanceId();
      final pathPtr = dir.path.toNativeUtf8();
      final int handle;
      try {
        // local_discovery_enabled = 0: a LAN peer answering a discovery
        // broadcast would otherwise make a dead candidate look alive.
        handle = ffiInstance.createTestInstanceExNative(pathPtr, 0, 1);
      } finally {
        pkgffi.malloc.free(pathPtr);
      }
      expect(handle, isNot(0),
          reason: 'the probe instance must be creatable at runtime');

      final hits = <String>[];
      FfiChatService? svc;
      try {
        ffiInstance.setCurrentInstance(handle);
        svc = FfiChatService();
        svc.setDhtNodesResponseCallback((pk, ip, port) => hits.add(pk));
        final udp = ffiInstance.getUdpPort(handle);
        ffiInstance.setCurrentInstance(prev);
        expect(udp, greaterThan(0),
            reason: 'a UDP-less probe instance cannot run a DHT probe at all');
        print('[dht-probe] probe instance handle=$handle udp=$udp '
            'target=${_short(target.$2)}:${target.$1}');

        // NEGATIVE half: same public key, a port nothing listens on.
        await _probeRounds(
            ffiInstance, handle, prev, svc, scenario, target.$2, 1, 8);
        print('[dht-probe] dead endpoint 127.0.0.1:1 -> ${hits.length} hits');
        expect(hits, isEmpty,
            reason: 'an isolated probe instance saw a DHT nodes response with '
                'no live node to have produced one — the isolation this '
                'verdict depends on is leaking (local discovery? saved '
                'bootstrap nodes?), so "reachable" would be a false positive.');

        // POSITIVE half: the SAME probe instance, pointed at real, live DHT
        // endpoints. Each peer is tried in turn and the first that answers
        // ends the sweep, so the assertion below is "a live Tox DHT node is
        // distinguishable from a dead endpoint", not "peer-N specifically
        // answers within N seconds" (which would be a timing race).
        final answered = <String>[];
        for (var pi = 0; pi < numNodes && answered.isEmpty; pi++) {
          final t = await _dhtEndpointOf(nodes[pi]);
          if (t.$1 == 0 || t.$2.length != 64) continue;
          final before = hits.length;
          await _probeRounds(
              ffiInstance, handle, prev, svc, scenario, t.$2, t.$1, 8,
              stopWhen: () => hits.length > before);
          final got = hits.length - before;
          print(
              '[dht-probe] live peer$pi ${_short(t.$2)}:${t.$1} -> $got hits');
          if (got > 0) answered.add('peer$pi');
        }
        expect(answered, isNotEmpty,
            reason: 'NO live Tox DHT node produced a nodes response on the '
                'isolated probe instance, while the dead endpoint produced '
                'none either — the probe cannot tell a reachable bootstrap '
                'node from an unreachable one, so every node would be '
                'reported unreachable (toxee issue: BootstrapNodeProbe).');
      } finally {
        if (svc != null) {
          ffiInstance.setCurrentInstance(handle);
          svc.clearDhtNodesResponseCallback();
          ffiInstance.setCurrentInstance(prev);
        }
        ffiInstance.setCurrentInstance(0);
        ffiInstance.destroyTestInstance(handle);
        ffiInstance.setCurrentInstance(prev);
        try {
          dir.deleteSync(recursive: true);
        } catch (e) {
          // Non-fatal: the probe instance is already destroyed, so a leftover
          // temp dir cannot affect the verdict. Report it rather than swallow
          // it — a repeated failure here means the instance did not release
          // its save file, which IS worth noticing.
          print('[dht-probe] temp dir cleanup failed (${dir.path}): $e');
        }
      }
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}

String _short(String key) => key.length >= 8 ? key.substring(0, 8) : '?';

/// `(udpPort, dhtPublicKey)` of [node], read inside its own instance context.
///
/// The DHT public key (`tox_self_get_dht_id`) is NOT the first 64 chars of the
/// Tox ID: a getnodes request is encrypted to the DHT key, so addressing a node
/// by its Tox ID produces a packet the node silently drops.
Future<(int, String)> _dhtEndpointOf(TestNode node) async {
  return node.runWithInstanceAsync(() async {
    final f = ffi_lib.Tim2ToxFfi.open();
    final port = f.getUdpPort(f.getCurrentInstanceId());
    final buf = pkgffi.malloc.allocate<ffi.Int8>(65);
    try {
      final len = f.getDhtIdNative(buf, 65);
      return (
        port,
        (len > 0 && len <= 64)
            ? buf.cast<pkgffi.Utf8>().toDartString(length: len)
            : ''
      );
    } finally {
      pkgffi.malloc.free(buf);
    }
  });
}

/// Repeatedly send a getnodes request from the isolated probe instance
/// [handle] to [host]:[port], iterating that instance so it is driven in both
/// wall-clock and virtual-clock mode, for up to [seconds].
///
/// The instance is made current only around the synchronous FFI call and
/// restored immediately — `g_current_instance_id` is a process-global, so it
/// must never stay switched across an await.
Future<void> _probeRounds(
  ffi_lib.Tim2ToxFfi ffiInstance,
  int handle,
  int prev,
  FfiChatService svc,
  TestScenario scenario,
  String publicKey,
  int port,
  int seconds, {
  bool Function()? stopWhen,
}) async {
  for (var round = 0; round < seconds; round++) {
    if (stopWhen != null && stopWhen()) return;
    ffiInstance.setCurrentInstance(handle);
    svc.dhtSendNodesRequest(publicKey, '127.0.0.1', port, publicKey);
    ffiInstance.setCurrentInstance(prev);
    for (var i = 0; i < 20; i++) {
      ffiInstance.iterateInstance(handle);
    }
    await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 20);
    if (!shouldRunVirtual) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
}

/// Virtual-clock variant of configureLinearBootstrap: Peer-i bootstraps from
/// Peer-(i-1). Peer-0 doesn't bootstrap from anyone.
Future<void> configureLinearBootstrapVirtual(TestScenario scenario) async {
  if (scenario.nodes.length < 2) return;

  final rootNode = scenario.nodes[0];
  try {
    await waitForConnectionVirtual(scenario, rootNode,
        timeout: const Duration(seconds: 5));
  } on TimeoutException catch (e) {
    // Best-effort wait: proceed regardless, but keep the timeout visible.
    // A non-timeout error is a real bug and propagates.
    print('[Test] Continuing after timeout: $e');
  }

  final rootPortDhtId = await rootNode.runWithInstanceAsync(() async {
    final ffiInstance = ffi_lib.Tim2ToxFfi.open();
    int port = 0;
    for (int retry = 0; retry < 10; retry++) {
      port = ffiInstance.getUdpPort(ffiInstance.getCurrentInstanceId());
      if (port > 0) break;
      await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
    }
    if (port == 0) return (0, '');
    final dhtIdBuf = pkgffi.malloc.allocate<ffi.Int8>(65);
    try {
      final len = ffiInstance.getDhtIdNative(dhtIdBuf, 65);
      if (len == 0 || len > 64) return (0, '');
      return (port, dhtIdBuf.cast<pkgffi.Utf8>().toDartString(length: len));
    } finally {
      pkgffi.malloc.free(dhtIdBuf);
    }
  });

  if (rootPortDhtId.$1 == 0) return;

  for (int i = 1; i < scenario.nodes.length; i++) {
    final node = scenario.nodes[i];
    final bootstrapSource = scenario.nodes[i - 1];

    try {
      await waitForConnectionVirtual(scenario, bootstrapSource,
          timeout: const Duration(seconds: 5));
    } on TimeoutException catch (e) {
      // Best-effort wait: proceed regardless, but keep the timeout visible.
      // A non-timeout error is a real bug and propagates.
      print('[Test] Continuing after timeout: $e');
    }

    final bsPortDhtId = await bootstrapSource.runWithInstanceAsync(() async {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      int bsPort = 0;
      for (int retry = 0; retry < 10; retry++) {
        bsPort = ffiInstance.getUdpPort(ffiInstance.getCurrentInstanceId());
        if (bsPort > 0) break;
        await pumpTestTick(scenario, advanceMs: 500, iterationsPerInstance: 1);
      }
      if (bsPort == 0) return (0, '');
      final buf = pkgffi.malloc.allocate<ffi.Int8>(65);
      try {
        final len = ffiInstance.getDhtIdNative(buf, 65);
        if (len > 0 && len <= 64) {
          return (bsPort, buf.cast<pkgffi.Utf8>().toDartString(length: len));
        }
        return (bsPort, '');
      } finally {
        pkgffi.malloc.free(buf);
      }
    });

    if (bsPortDhtId.$1 == 0 || bsPortDhtId.$2.isEmpty) continue;

    final hostPtr = '127.0.0.1'.toNativeUtf8();
    final dhtIdPtr = bsPortDhtId.$2.toNativeUtf8();
    try {
      await node.runWithInstanceAsync(() async {
        final ffiInstance = ffi_lib.Tim2ToxFfi.open();
        return ffiInstance.addBootstrapNode(ffiInstance.getCurrentInstanceId(),
            hostPtr, bsPortDhtId.$1, dhtIdPtr);
      });
    } finally {
      pkgffi.malloc.free(hostPtr);
      pkgffi.malloc.free(dhtIdPtr);
    }
  }

  for (final node in scenario.nodes) {
    try {
      await waitForConnectionVirtual(scenario, node,
          timeout: const Duration(seconds: 10));
    } on TimeoutException catch (e) {
      // Best-effort wait: proceed regardless, but keep the timeout visible.
      // A non-timeout error is a real bug and propagates.
      print('[Test] Continuing after timeout: $e');
    }
  }
}
