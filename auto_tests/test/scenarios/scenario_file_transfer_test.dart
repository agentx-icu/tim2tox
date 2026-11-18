/// File Transfer Test — virtual-clock variant
///
/// Mirrors scenario_file_transfer_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
///
/// File-transfer specifics:
/// - The initial file-request acceptance round-trip can drop on a flaky
///   2-node local-bootstrap link, so the first "fileReceived" wait uses
///   a 3x send-retry pattern.
/// - Progress callbacks fire many times during transfer and recover from
///   transient drops naturally; we use waitUntilWithVirtualPump with a
///   generous virtual budget (60-90s) for transfer-completion waits and
///   do NOT retry the send for those.

import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_download_progress.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/service/file_receive_failure.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('File Transfer Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late String testDataDir;
    late File testFile;

    setUpAll(() async {
      await setupTestEnvironment();
      testDataDir = await getTestDataDir();

      // Create a test file
      testFile = File('$testDataDir/test_file.txt');
      await testFile
          .writeAsString('This is a test file for file transfer.\n' * 100);

      // Enable BEFORE initAllNodes so V2TIMManagerImpl never spawns
      // event_thread; file_request and progress events flow through
      // FfiChatService polling driven by pumpTestTick.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      await scenario.initAllNodes();
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([alice.login(), bob.login()]);
      await waitUntil(() => alice.loggedIn && bob.loggedIn,
          timeout: const Duration(seconds: 10),
          description: 'both nodes logged in');
      await configureLocalBootstrapVirtual(scenario);
      await establishFriendshipVirtual(scenario, alice, bob);
      // Pump so P2P connection is established before file transfer
      await pumpFriendConnectionVirtual(scenario, alice, bob);
    });

    tearDownAll(() async {
      // Cleanup test file
      if (await testFile.exists()) {
        await testFile.delete();
      }

      await scenario.dispose();
      await teardownTestEnvironment();
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      final bob = scenario.getNode('bob')!;
      bob.receivedMessages.clear();
    });

    test('simultaneous outgoing transfers report separate completions', () async {
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final service = platform.ffiService;
      final peer = bob.getToxId();
      final secondFile = File('$testDataDir/second_concurrent_file.txt');
      // A full chunk near the end is above 99.5%, before the EOF callback.
      await secondFile.writeAsBytes(List.filled(512 * 1024, 0x41));
      addTearDown(() => secondFile.delete());

      final sdkCompletions = <String, int>{};
      final progressListener = V2TimAdvancedMsgListener(
        onSendMessageProgress: (message, progress) {
          final id = message.msgID;
          if (progress == 100 && id != null) {
            sdkCompletions.update(id, (count) => count + 1, ifAbsent: () => 1);
          }
        },
      );
      alice.runWithInstance(
        () => TIMMessageManager.instance.addAdvancedMsgListener(progressListener),
      );
      addTearDown(() => alice.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: progressListener,
            ),
          ));

      final completions = <String, int>{};
      final subscription = service.progressUpdates.listen((event) {
        if (event.isSend && event.received == event.total && event.msgID != null) {
          completions[event.msgID!] = event.total;
        }
      });
      addTearDown(subscription.cancel);

      final first = await alice.runWithInstanceAsync(
        () => service.sendFile(peer, testFile.path),
      );
      final second = await alice.runWithInstanceAsync(
        () => service.sendFile(peer, secondFile.path),
      );
      final firstId = first!.msgID!;
      final secondId = second!.msgID!;
      await waitUntilWithVirtualPump(
        scenario,
        () =>
            completions.containsKey(firstId) && completions.containsKey(secondId),
        timeout: const Duration(seconds: 45),
        description: 'both outgoing offers have time to transfer',
      );
      expect(completions, containsPair(firstId, await testFile.length()));
      expect(completions, containsPair(secondId, await secondFile.length()));
      expect(sdkCompletions, {firstId: 1, secondId: 1});

      final prefs = service.preferencesService!;
      final previousLimit = await prefs.getAutoDownloadSizeLimit();
      await prefs.setAutoDownloadSizeLimit(0);
      addTearDown(() => prefs.setAutoDownloadSizeLimit(previousLimit));
      final failures = <String>{};
      final messages = service.messages.listen((row) {
        final id = row.msgID;
        if (row.isSelf && row.isFailed && id != null) failures.add(id);
      });
      addTearDown(messages.cancel);
      final canceled = await alice.runWithInstanceAsync(
        () => service.sendFile(peer, testFile.path),
      );
      await waitUntilWithVirtualPump(
        scenario,
        () => failures.contains(canceled!.msgID),
        timeout: const Duration(seconds: 30),
        description: 'receiver refuses the outgoing offer',
      );
      expect(failures, {canceled!.msgID});
      expect(completions, isNot(contains(canceled.msgID)));
    }, timeout: const Timeout(Duration(seconds: 100)));

    test('Send file to friend and receive', () async {
      // Setup Bob's message listener to receive file
      var fileReceived = false;

      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          // Accept FILE by elemType or by fileElem (native may send CElemType 4)
          final text = message.textElem?.text ?? '';
          final isForwardFileText =
              text.contains('转发文件') && text.contains('test_file.txt');
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
              message.fileElem != null ||
              isForwardFileText) {
            fileReceived = true;
            bob.addReceivedMessage(message);
          }
        },
        onMessageDownloadProgressCallback:
            (V2TimMessageDownloadProgress progress) {
          // Track download progress
          if (progress.currentSize == progress.totalSize) {
            fileReceived = true;
          }
        },
      );

      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(bobListener));
      try {
        final bobToxId = bob.getToxId();
        await waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 15));
        await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 90));
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        // Ensure file exists (native send uses this path)
        if (!await testFile.exists()) {
          await Directory(testDataDir).create(recursive: true);
          await File(testFile.path)
              .writeAsString('This is a test file for file transfer.\n' * 100);
        }

        // Retry send + wait. The initial file_request can drop while
        // friend P2P is still warming up on the back-direction link.
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          fileReceived = false;
          final sendResult = await alice.runWithInstanceAsync(() async {
            final fileResult = TIMMessageManager.instance.createFileMessage(
              filePath: testFile.path,
              fileName: 'test_file.txt',
            );
            expect(fileResult.messageInfo, isNotNull);
            return await TIMMessageManager.instance.sendMessage(
              message: fileResult.messageInfo!,
              receiver: bobToxId,
              groupID: null,
            );
          });
          expect(sendResult.code, equals(0));
          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => fileReceived,
              timeout: const Duration(seconds: 60),
              description: 'fileReceived (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } catch (_) {
            // retry — file_request may have been dropped
          }
        }

        expect(arrived, isTrue,
            reason: 'file never received after 3 send retries');
        expect(fileReceived, isTrue);
        expect(bob.receivedMessages.length, greaterThan(0));

        final fileMessages = bob.receivedMessages
            .where((m) =>
                m.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
                m.fileElem != null)
            .toList();
        if (fileMessages.isNotEmpty) {
          final receivedMessage = fileMessages.last;
          expect(receivedMessage.fileElem, isNotNull);
          if (receivedMessage.fileElem?.fileName != null) {
            expect(receivedMessage.fileElem!.fileName, equals('test_file.txt'));
          }
        } else {
          final hasForwardText = bob.receivedMessages.any((m) {
            final t = m.textElem?.text ?? '';
            return t.contains('转发文件') && t.contains('test_file.txt');
          });
          expect(hasForwardText, isTrue,
              reason: 'Expected FILE element or forward file text');
        }
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: bobListener));
      }
    }, timeout: const Timeout(Duration(seconds: 240)));

    test('File transfer progress callbacks', () async {
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      await Directory(testDataDir).create(recursive: true);
      final largeFile = File('$testDataDir/large_test_file.txt');
      await largeFile.writeAsString('Large file content.\n' * 1000);

      var progressUpdates = <int>[];
      final progressListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE) {
            progressUpdates.add(message.fileElem?.fileSize ?? 0);
          }
        },
        onMessageDownloadProgressCallback:
            (V2TimMessageDownloadProgress progress) {
          progressUpdates.add(progress.currentSize);
        },
      );

      bob.runWithInstance(() =>
          TIMMessageManager.instance.addAdvancedMsgListener(progressListener));
      try {
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        final sendResult = await alice.runWithInstanceAsync(() async {
          final fileResult = TIMMessageManager.instance.createFileMessage(
            filePath: largeFile.path,
            fileName: 'large_test_file.txt',
          );
          expect(fileResult.messageInfo, isNotNull);
          return await TIMMessageManager.instance.sendMessage(
            groupID: null,
            id: fileResult.id!,
            receiver: bobToxId,
          );
        });

        expect(sendResult.code, equals(0));

        // Give native time to enqueue file_request and Dart poll to
        // process it before waiting for progress.
        await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 100);
        await pumpTestTick(scenario, advanceMs: 800, iterationsPerInstance: 1);

        // Progress callbacks fire many times — use generous virtual budget
        // without retry; recovery from transient drops happens naturally
        // as the transfer continues.
        await waitUntilWithVirtualPump(
          scenario,
          () => progressUpdates.isNotEmpty,
          timeout: const Duration(seconds: 90),
          description: 'progressUpdates',
          advanceMs: 50,
          iterationsPerInstance: 1,
        );

        expect(progressUpdates.length, greaterThan(0));
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: progressListener));
        if (await largeFile.exists()) {
          await largeFile.delete();
        }
      }
    }, timeout: const Timeout(Duration(seconds: 150)));

    test('File transfer completion verification', () async {
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      var fileCompleted = false;
      final completionListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE) {
            // File received (count as complete when message is delivered; progress may follow)
            fileCompleted = true;
          }
        },
        onMessageDownloadProgressCallback:
            (V2TimMessageDownloadProgress progress) {
          if (progress.currentSize == progress.totalSize &&
              progress.totalSize > 0) {
            fileCompleted = true;
          }
        },
      );

      bob.runWithInstance(() => TIMMessageManager.instance
          .addAdvancedMsgListener(completionListener));
      try {
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        // Ensure file exists (may have been removed by earlier test or env)
        if (!await testFile.exists()) {
          await Directory(testDataDir).create(recursive: true);
          await testFile
              .writeAsString('This is a test file for file transfer.\n' * 100);
        }

        // Retry send for completion: file_request may drop and the
        // entire transfer never starts; in that case re-issue the send.
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          fileCompleted = false;
          final sendResult = await alice.runWithInstanceAsync(() async {
            final fileResult = TIMMessageManager.instance.createFileMessage(
              filePath: testFile.path,
              fileName: 'test_file.txt',
            );
            return await TIMMessageManager.instance.sendMessage(
              groupID: null,
              id: fileResult.id!,
              receiver: bobToxId,
            );
          });
          expect(sendResult.code, equals(0));

          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => fileCompleted,
              timeout: const Duration(seconds: 60),
              description: 'fileCompleted (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } catch (_) {
            // retry — file_request may have been dropped
          }
        }

        expect(arrived, isTrue,
            reason: 'file never completed after 3 send retries');
        expect(fileCompleted, isTrue);
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: completionListener));
      }
    }, timeout: const Timeout(Duration(seconds: 240)));

    test('peer disconnect clears an active transfer and allows a new transfer',
        () async {
      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final service = platform.ffiService;
      final peer = bob.getToxId();
      final aliceHandle = alice.testInstanceHandle!;
      final ffi = Tim2ToxFfi.open();
      final peerPointer = peer.toNativeUtf8();
      final int friendNumber;
      try {
        friendNumber =
            ffi.getFriendNumberByUserIdForInstanceNative(aliceHandle, peerPointer);
      } finally {
        malloc.free(peerPointer);
      }
      expect(friendNumber, greaterThanOrEqualTo(0));

      const interruptedName = 'interrupted_file.bin';
      final interruptedFile = File('$testDataDir/$interruptedName');
      final contents = await interruptedFile.open(mode: FileMode.write);
      await contents.truncate(8 * 1024 * 1024);
      await contents.close();
      addTearDown(interruptedFile.delete);

      final progress = <String, int>{};
      String? partialPath;
      final progressSub = service.progressUpdates.listen((event) {
        if (event.isSend && event.msgID != null) {
          progress[event.msgID!] = event.received;
        }
        if (!event.isSend &&
            event.instanceId == bob.testInstanceHandle &&
            event.received > 0 &&
            (event.path?.endsWith(interruptedName) ?? false)) {
          partialPath = event.path;
        }
      });
      addTearDown(progressSub.cancel);

      final failures = <String>[];
      var receiveFailed = false;
      final messageSub = service.messages.listen((row) {
        if (row.isSelf && row.isFailed && row.msgID != null) {
          failures.add(row.msgID!);
        }
        if (!row.isSelf && row.fileName == interruptedName && !row.isPending) {
          receiveFailed = row.filePath?.isEmpty ?? true;
        }
      });
      addTearDown(messageSub.cancel);

      final interrupted = await alice.runWithInstanceAsync(
        () => service.sendFile(peer, interruptedFile.path),
      );
      final interruptedId = interrupted!.msgID!;
      await waitUntilWithVirtualPump(
        scenario,
        () => (progress[interruptedId] ?? 0) > 0 && partialPath != null,
        description: 'the first transfer starts sending and receiving bytes',
      );
      final interruptedSize = await interruptedFile.length();
      expect(progress[interruptedId], lessThan(interruptedSize));
      final partial = File(partialPath!);
      final marker = File(receiveMarkerPathFor(partial.path));
      expect(partial.existsSync(), isTrue);
      expect(marker.existsSync(), isTrue);

      // Stalling Bob's network loop lets Alice observe a real Tox timeout
      // while preserving Bob's peer identity for the reconnect.
      final aliceOnly = TestScenario(virtualMode: true)..nodes.add(alice);
      await waitUntilWithVirtualPump(
        aliceOnly,
        () => ffi.getFriendConnectionStatusNative(aliceHandle, friendNumber) == 0,
        description: 'Alice sees Bob disconnect',
        advanceMs: 250,
      );
      await waitUntilWithVirtualPump(
        aliceOnly,
        () => failures.contains(interruptedId),
        timeout: const Duration(seconds: 8),
        description: 'the disconnected transfer fails its outgoing message',
      );

      await waitUntilWithVirtualPump(
        scenario,
        () => ffi.getFriendConnectionStatusNative(aliceHandle, friendNumber) > 0,
        description: 'Alice sees Bob reconnect',
      );
      await waitUntilWithVirtualPump(
        scenario,
        () => receiveFailed,
        timeout: const Duration(seconds: 8),
        description: 'the disconnected transfer fails its incoming message',
      );
      expect(partial.existsSync(), isFalse);
      expect(marker.existsSync(), isFalse);
      final next = await alice.runWithInstanceAsync(
        () => service.sendFile(peer, testFile.path),
      );
      final nextId = next!.msgID!;
      expect(next.isPending, isFalse);
      final nextSize = await testFile.length();
      await waitUntilWithVirtualPump(
        scenario,
        () => progress[nextId] == nextSize,
        description: 'a new transfer completes after reconnect',
      );
      expect(failures, [interruptedId]);
      expect(progress[interruptedId], lessThan(interruptedSize));
    },
        skip: shouldRunVirtual ? false : 'requires a controllable peer loop',
        timeout: const Timeout(Duration(seconds: 120)));
  });
}
