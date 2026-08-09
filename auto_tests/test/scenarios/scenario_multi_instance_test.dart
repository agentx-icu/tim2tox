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

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:ffi/ffi.dart' as pkgffi;
import 'dart:ffi' as ffi;
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';

void main() {
  group('Multi-instance Tox support', () {
    test('Each node has independent Tox instance, port, and DHT ID', () async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation so V2TIMManagerImpl
      // constructor inherits test_mode and InitSDK skips event_thread.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
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
        if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

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
      if (shouldRunVirtual) await VirtualClock.enableEarly();
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
        if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

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

        // was: both expects were guarded by `if (node.connectionStatusCalled)`
        // — a flag that ONLY scenario_self_query_test.dart ever sets (it is
        // never set by the harness), so the guard is always false here and this
        // test executed zero assertions about the connection it is named after.
        // Assert the real Tox connection status instead, after a bounded wait
        // (the Future.wait above deliberately swallows its per-node timeout).
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () =>
                alice.getConnectionStatus() > 0 &&
                bob.getConnectionStatus() > 0,
            timeout: const Duration(seconds: 30),
            description: 'alice and bob report a non-NONE connection status',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
        } on TimeoutException catch (e) {
          // Reported by the expects below; non-timeout errors bubble up.
          print('[Test] Connection status wait timed out: $e');
        }
        print('[Test] Alice connection status: ${alice.getConnectionStatus()}, '
            'Bob connection status: ${bob.getConnectionStatus()}');
        expect(alice.getConnectionStatus(), greaterThan(0),
            reason:
                'Alice should be connected (1=TCP, 2=UDP) via local bootstrap');
        expect(bob.getConnectionStatus(), greaterThan(0),
            reason:
                'Bob should be connected (1=TCP, 2=UDP) via local bootstrap');

        // Establish friendship and verify the two instances really can
        // exchange a message over the 127.0.0.1 bootstrap.
        //
        // was: the whole block below sat inside `try { ... } catch (e) {
        // print('Could not establish friendship or send message') }`, the
        // delivery wait ended in a no-op catchError handler, and the outcome
        // was only printed — so nothing here was ever asserted (a no-op in
        // BOTH modes, and guaranteed no-op under RUN_VIRTUAL=1 where the 10s
        // virtual budget is ~1.2s of real loopback time). Worse, the old
        // `bobReceivedMessages.isNotEmpty` check was dead code:
        // `bob.receivedMessages` is only populated by `addReceivedMessage`,
        // which nothing called because TestNode installs no message listener.
        print('[Test] Attempting to establish friendship...');
        await establishFriendshipVirtual(scenario, alice, bob,
            timeout: const Duration(seconds: 60));
        print('[Test] Friendship established');

        print('[Test] Testing message delivery...');
        final bobToxId = bob.getToxId();
        const testMessage = 'Hello from Alice!';
        final bobListener = V2TimAdvancedMsgListener(
          onRecvNewMessage: (V2TimMessage message) {
            bob.addReceivedMessage(message);
          },
        );
        bob.runWithInstance(() =>
            TIMMessageManager.instance.addAdvancedMsgListener(bobListener));
        try {
          var delivered = false;
          Object? lastError;
          for (var attempt = 0; !delivered && attempt < 3; attempt++) {
            final sendResult = await alice.runWithInstanceAsync(() async {
              final messageResult = TIMMessageManager.instance
                  .createTextMessage(text: testMessage);
              return await TIMMessageManager.instance.sendMessage(
                message: messageResult.messageInfo,
                receiver: bobToxId,
                groupID: null,
                onlineUserOnly: false,
              );
            });
            expect(sendResult.code, equals(0),
                reason: 'sendMessage failed: ${sendResult.desc}');

            try {
              await waitUntilWithVirtualPump(
                scenario,
                () => bob.receivedMessages
                    .any((msg) => msg.textElem?.text == testMessage),
                timeout: const Duration(seconds: 20),
                description:
                    'Bob receives test message (attempt ${attempt + 1})',
                advanceMs: 50,
                iterationsPerInstance: 1,
              );
              delivered = true;
            } on TimeoutException catch (e) {
              // Retry; the post-loop expect below is the real assertion.
              lastError = e;
            }
          }
          expect(delivered, isTrue,
              reason: 'Bob never received the C2C message over the local '
                  'bootstrap after 3 send attempts; last error: $lastError');
          print('[Test] Message successfully delivered via local bootstrap');
        } finally {
          bob.runWithInstance(() => TIMMessageManager.instance
              .removeAdvancedMsgListener(listener: bobListener));
        }

        print('[Test] Local bootstrap configuration completed');
      } finally {
        await scenario.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
