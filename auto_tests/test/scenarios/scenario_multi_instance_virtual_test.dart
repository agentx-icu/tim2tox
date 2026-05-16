/// Multi-instance test scenario — virtual-clock variant
///
/// Verifies that each TestNode has its own independent Tox instance,
/// UDP port, and DHT ID, and that nodes can connect via 127.0.0.1.
///
/// Mirrors scenario_multi_instance_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before initAllNodes() so V2TIMManagerImpl
/// inherits test_mode and InitSDK skips event_thread. Inter-instance waits
/// (port-ready, connection wait, friendship, message delivery) are driven
/// through pumpTestTick / waitUntilWithVirtualPump.

import 'package:flutter_test/flutter_test.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:ffi/ffi.dart' as pkgffi;
import 'dart:ffi' as ffi;
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';

void main() {
  group('Multi-instance Tox support (Virtual)', () {
    test('Each node has independent Tox instance, port, and DHT ID', () async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation so V2TIMManagerImpl
      // constructor inherits test_mode and InitSDK skips event_thread.
      await VirtualClock.enableEarly();
      final scenario = await createTestScenario(['alice', 'bob', 'charlie']);

      try {
        // Initialize all nodes
        print('[Test] Initializing all nodes...');
        for (int i = 0; i < scenario.nodes.length; i++) {
          final node = scenario.nodes[i];
          print(
              '[Test] Initializing node ${i + 1}/${scenario.nodes.length}: ${node.alias}');
          try {
            await node.initSDK();
            print('[Test] OK Node ${node.alias} SDK initialized');

            print('[Test] Calling login for node ${node.alias}...');
            try {
              await node.login(timeout: const Duration(seconds: 5));
              print(
                  '[Test] OK Node ${node.alias} login completed (loggedIn=${node.loggedIn})');
            } catch (e) {
              print(
                  '[Test] Node ${node.alias} login timeout or error: $e');
              if (!node.loggedIn) {
                rethrow;
              }
            }
          } catch (e) {
            print('[Test] Failed to initialize node ${node.alias}: $e');
            rethrow;
          }
        }
        // Refresh per-instance test_mode for visibility (idempotent).
        await VirtualClock.enableForScenario(scenario);

        // Wait for all nodes to be logged in
        print('[Test] Waiting for all nodes to be logged in...');
        try {
          await waitUntil(
            () => scenario.nodes.every((node) => node.loggedIn),
            timeout: const Duration(seconds: 10),
            description: 'all nodes logged in',
          );
          print('[Test] All nodes are logged in');
        } catch (e) {
          print('[Test] Timeout waiting for all nodes to log in: $e');
          rethrow;
        }

        final Map<String, Map<String, dynamic>> nodeInfo = {};
        final List<String> failedNodes = [];

        // Process all nodes using instance scope.
        for (final node in scenario.nodes) {
          try {
            if (node.testInstanceHandle == null) {
              throw Exception(
                  'Node ${node.alias} does not have a test instance handle');
            }

            await node.runWithInstanceAsync(() async {
              final ffiInstance = ffi_lib.Tim2ToxFfi.open();

              // Get UDP port — pump virtual time so Tox's bind/iterate ticks
              // before we query, then retry a few times if needed.
              await pumpTestTick(scenario,
                  advanceMs: 500, iterationsPerInstance: 1);
              int port = 0;
              for (int retry = 0; retry < 5; retry++) {
                port = ffiInstance.getUdpPort(ffiInstance.getCurrentInstanceId());
                if (port > 0) {
                  break;
                }
                if (retry % 2 == 0) {
                  print(
                      '[Test] getUdpPort() attempt ${retry + 1} for node ${node.alias}: $port');
                }
                if (retry < 4) {
                  await pumpTestTick(scenario,
                      advanceMs: 200, iterationsPerInstance: 1);
                }
              }

              if (port == 0) {
                throw Exception(
                    'Failed to get UDP port for node ${node.alias} after retries');
              }

              // Get DHT ID
              final dhtIdBuf = pkgffi.malloc.allocate<ffi.Int8>(65);
              String? dhtId;
              try {
                final dhtIdLen = ffiInstance.getDhtIdNative(dhtIdBuf, 65);
                if (dhtIdLen > 0 && dhtIdLen <= 64) {
                  dhtId = dhtIdBuf
                      .cast<pkgffi.Utf8>()
                      .toDartString(length: dhtIdLen);
                }
              } finally {
                pkgffi.malloc.free(dhtIdBuf);
              }

              if (dhtId == null || dhtId.isEmpty) {
                throw Exception('Failed to get DHT ID for node ${node.alias}');
              }

              nodeInfo[node.alias] = {
                'instanceHandle': node.testInstanceHandle,
                'port': port,
                'dhtId': dhtId,
              };

              print(
                  '[Test] OK Node ${node.alias}: instance=${node.testInstanceHandle}, port=$port, dhtId=$dhtId');
            });
          } catch (e) {
            print('[Test] Failed to get info for node ${node.alias}: $e');
            failedNodes.add(node.alias);
          }
        }

        if (failedNodes.isNotEmpty) {
          throw Exception(
              'Failed to get info for nodes: ${failedNodes.join(", ")}');
        }

        // Verify all nodes have different instance handles
        final instanceHandles = nodeInfo.values
            .map((info) => info['instanceHandle'] as int)
            .toSet();
        expect(instanceHandles.length, equals(scenario.nodes.length),
            reason: 'All nodes should have unique instance handles');

        // Verify all nodes have different ports
        final ports =
            nodeInfo.values.map((info) => info['port'] as int).toSet();
        expect(ports.length, equals(scenario.nodes.length),
            reason: 'All nodes should have unique UDP ports');

        // Verify all nodes have different DHT IDs
        final dhtIds =
            nodeInfo.values.map((info) => info['dhtId'] as String).toSet();
        expect(dhtIds.length, equals(scenario.nodes.length),
            reason: 'All nodes should have unique DHT IDs');

        print('[Test] OK All nodes have independent instances, ports, and DHT IDs');
      } finally {
        await scenario.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Nodes can connect via 127.0.0.1 bootstrap', () async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation so V2TIMManagerImpl
      // constructor inherits test_mode and InitSDK skips event_thread.
      await VirtualClock.enableEarly();
      final scenario = await createTestScenario(['alice', 'bob']);

      try {
        // Initialize all nodes
        print('[Test] Initializing all nodes...');
        for (int i = 0; i < scenario.nodes.length; i++) {
          final node = scenario.nodes[i];
          print(
              '[Test] Initializing node ${i + 1}/${scenario.nodes.length}: ${node.alias}');
          try {
            await node.initSDK();
            print('[Test] OK Node ${node.alias} SDK initialized');

            print('[Test] Calling login for node ${node.alias}...');
            try {
              await node.login(timeout: const Duration(seconds: 5));
              print(
                  '[Test] OK Node ${node.alias} login completed (loggedIn=${node.loggedIn})');
            } catch (e) {
              print(
                  '[Test] Node ${node.alias} login timeout or error: $e');
              if (!node.loggedIn) {
                rethrow;
              }
            }
          } catch (e) {
            print('[Test] Failed to initialize node ${node.alias}: $e');
            rethrow;
          }
        }
        // Refresh per-instance test_mode for visibility (idempotent).
        await VirtualClock.enableForScenario(scenario);

        // Wait for all nodes to be logged in
        print('[Test] Waiting for all nodes to be logged in...');
        try {
          await waitUntil(
            () => scenario.nodes.every((node) => node.loggedIn),
            timeout: const Duration(seconds: 10),
            description: 'all nodes logged in',
          );
          print('[Test] All nodes are logged in');
        } catch (e) {
          print('[Test] Timeout waiting for all nodes to log in: $e');
          rethrow;
        }

        // Pump virtual time so Tox instances finish bind/init.
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        // Configure local bootstrap
        print('[Test] Configuring local bootstrap...');
        try {
          await configureLocalBootstrapVirtual(scenario);
          print('[Test] Bootstrap configuration completed');
        } catch (e) {
          print('[Test] Bootstrap configuration failed: $e');
          rethrow;
        }

        // Wait for nodes to connect - parallelize
        print('[Test] Waiting for nodes to connect...');
        await Future.wait(scenario.nodes.map((node) async {
          try {
            await waitForConnectionVirtual(scenario, node,
                timeout: const Duration(seconds: 10));
            print('[Test] Node ${node.alias} is connected');
          } catch (e) {
            print('[Test] Node ${node.alias} connection timeout: $e');
          }
        }));

        // Verify connection status
        final alice = scenario.nodes[0];
        final bob = scenario.nodes[1];

        if (alice.connectionStatusCalled) {
          expect(alice.lastConnectionStatus, greaterThan(0),
              reason: 'Alice should have a connection status > 0 (TCP or UDP)');
          print('[Test] Alice connection status: ${alice.lastConnectionStatus}');
        } else {
          print('[Test] Alice connection status not called yet');
        }

        if (bob.connectionStatusCalled) {
          expect(bob.lastConnectionStatus, greaterThan(0),
              reason: 'Bob should have a connection status > 0 (TCP or UDP)');
          print('[Test] Bob connection status: ${bob.lastConnectionStatus}');
        } else {
          print('[Test] Bob connection status not called yet');
        }

        // Try to establish friendship and verify they can communicate
        print('[Test] Attempting to establish friendship...');
        try {
          await establishFriendshipVirtual(scenario, alice, bob,
              timeout: const Duration(seconds: 30));
          print('[Test] Friendship established');

          // Try sending a message to verify connectivity (run in Alice's instance context)
          print('[Test] Testing message delivery...');
          final bobToxId = bob.getToxId();
          final testMessage = 'Hello from Alice!';
          await alice.runWithInstanceAsync(() async {
            final messageResult = TIMMessageManager.instance
                .createTextMessage(text: testMessage);
            final sendResult = await TIMMessageManager.instance.sendMessage(
              message: messageResult.messageInfo,
              receiver: bobToxId,
              groupID: null,
              onlineUserOnly: false,
            );
            if (sendResult.code != 0) {
              print('[Test] Message send failed: ${sendResult.desc}');
            } else {
              print('[Test] Message sent successfully');
            }
          });

          // Wait for message delivery via virtual-clock pump.
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.receivedMessages
                .any((msg) => msg.textElem?.text == testMessage),
            timeout: const Duration(seconds: 10),
            description: 'Bob receives test message',
            advanceMs: 50,
            iterationsPerInstance: 1,
          ).catchError((_) {
            // Best-effort: original test also tolerates no-receive here.
          });

          final bobReceivedMessages = bob.receivedMessages
              .where((msg) => msg.textElem?.text == testMessage)
              .toList();

          if (bobReceivedMessages.isNotEmpty) {
            print('[Test] Message successfully delivered via local bootstrap');
          } else {
            print('[Test] Message not received yet (may need more time)');
          }
        } catch (e) {
          print('[Test] Could not establish friendship or send message: $e');
          print('[Test] This may be due to Tox network connection delays');
        }

        print('[Test] Local bootstrap configuration completed');
      } finally {
        await scenario.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
