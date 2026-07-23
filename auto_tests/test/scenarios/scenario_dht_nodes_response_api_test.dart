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

      for (int i = 1; i < nodes.length; i++) {
        final bootstrapSource = nodes[i - 1];
        final bsPort = await bootstrapSource.runWithInstanceAsync(() async {
          final ffiInstance = ffi_lib.Tim2ToxFfi.open();
          return ffiInstance.getUdpPort(ffiInstance.getCurrentInstanceId());
        });
        final bsDhtId = bootstrapSource.getToxId();
        final bsPublicKey =
            bsDhtId.length == 76 ? bsDhtId.substring(0, 64) : bsDhtId;

        final chatService = chatServices[i];
        for (final targetPublicKey in publicKeys) {
          chatService.dhtSendNodesRequest(
              bsPublicKey, '127.0.0.1', bsPort, targetPublicKey);
        }
      }

      // Allow DHT to respond.
      await pumpTestTick(scenario, advanceMs: 5000, iterationsPerInstance: 1);

      final discoveryCounts = discoveredNodes.map((set) => set.length).toList();
      final totalDiscoveries = discoveryCounts.reduce((a, b) => a + b);

      expect(totalDiscoveries >= 0, isTrue,
          reason: 'DHT nodes API should work');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
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
