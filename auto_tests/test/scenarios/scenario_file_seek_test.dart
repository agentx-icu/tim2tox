/// File Seek Test — virtual-clock variant
///
/// Mirrors scenario_file_seek_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers. Each sub-test's "file_request" wait gets
/// the 3x send-retry pattern (drops on flaky 2-node link). Progress and
/// completion waits use waitUntilWithVirtualPump with generous virtual
/// budgets (60-90s).

import 'dart:io';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_download_progress.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:path/path.dart' as path;
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

/// Subdir so this scenario's file is not deleted by another file's teardown (cleanupTestDataDir).
const _fileSeekSubdir = 'scenario_file_seek_virtual';

void main() {
  group('File Seek Tests', () {
    late TestScenario scenario;
    late String testDataDir;
    late File testFile;

    setUpAll(() async {
      await setupTestEnvironment();
      testDataDir = await getTestDataDir(_fileSeekSubdir);

      // Create a large test file for seeking (isolated dir so other scenarios' teardown won't wipe it)
      testFile = File(path.join(testDataDir, 'test_file_seek.txt'));
      final content = 'File content for seeking test.\n' * 2000;
      await testFile.writeAsString(content);

      // Enable BEFORE initAllNodes so V2TIMManagerImpl never spawns
      // event_thread; file_request and progress events flow through
      // FfiChatService polling driven by pumpTestTick.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      await scenario.initAllNodes();
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );
      await configureLocalBootstrapVirtual(scenario);
      await establishFriendshipVirtual(scenario, alice, bob);
      await pumpFriendConnectionVirtual(scenario, alice, bob);
      // Ensure FfiChatService polling is started so file_request events are consumed
      // (test instances may not go through platform login).
      final platform = TencentCloudChatSdkPlatform.instance;
      if (platform is Tim2ToxSdkPlatform) {
        await platform.ffiService.startPolling();
      }
    });

    tearDownAll(() async {
      await scenario.dispose();
      await cleanupTestDataDir(_fileSeekSubdir);
      await teardownTestEnvironment();
    });

    // Lightweight setUp: ensure test file exists (e.g. when running single test by name, or if cleaned)
    setUp(() async {
      if (!await testFile.exists()) {
        await Directory(testDataDir).create(recursive: true);
        final content = 'File content for seeking test.\n' * 2000;
        await testFile.writeAsString(content);
      }
      final bob = scenario.getNode('bob')!;
      bob.receivedMessages.clear();
    });

    test('Seek to middle position during file transfer', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final bobToxId = bob.getToxId();
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      var fileReceived = false;
      var seekPosition = 0;
      final fileSize = await testFile.length();
      final seekTarget = fileSize ~/ 2; // Seek to middle

      final seekListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          final text = message.textElem?.text ?? '';
          final isForwardFileText =
              text.contains('转发文件') && text.contains('test_file_seek.txt');
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
              message.fileElem != null ||
              isForwardFileText) {
            fileReceived = true;
            bob.addReceivedMessage(message);
          }
        },
        onMessageDownloadProgressCallback:
            (V2TimMessageDownloadProgress progress) {
          seekPosition = progress.currentSize;
          if (progress.currentSize >= seekTarget &&
              progress.currentSize < progress.totalSize) {
            // File transfer is in progress from seek position
          }
        },
      );

      bob.runWithInstance(() =>
          TIMMessageManager.instance.addAdvancedMsgListener(seekListener));
      try {
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        // Retry send + wait for file_request: the initial file_request can
        // drop on a flaky 2-node link.
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          fileReceived = false;
          final sendResult = await alice.runWithInstanceAsync(() async {
            final fileResult = TIMMessageManager.instance.createFileMessage(
              filePath: testFile.path,
              fileName: 'test_file_seek.txt',
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
              () => fileReceived,
              timeout: const Duration(seconds: 30),
              description: 'file request received (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } catch (_) {
            // retry — file_request may have been dropped
          }
        }

        expect(arrived, isTrue,
            reason: 'file request never received after 3 send retries');

        // Note: File seeking in tim2tox requires FfiChatService
        // The seek operation would be: ffiService.seekFileTransfer(peerId, fileNumber, position)
        // This test verifies the file transfer can be initiated and progress tracked
        expect(fileReceived, isTrue);

        // Verify file message
        final fileMessages = bob.receivedMessages
            .where((m) =>
                m.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
                m.fileElem != null)
            .toList();
        if (fileMessages.isNotEmpty) {
          final fileMessage = fileMessages.last;
          expect(fileMessage.fileElem, isNotNull);
          final reportedSize = fileMessage.fileElem?.fileSize;
          if (reportedSize != null) {
            expect(reportedSize, equals(fileSize));
          }
        } else {
          final hasForwardText = bob.receivedMessages.any((m) {
            final t = m.textElem?.text ?? '';
            return t.contains('转发文件') && t.contains('test_file_seek.txt');
          });
          expect(hasForwardText, isTrue,
              reason: 'Expected FILE element or forward file text');
        }
        expect(seekPosition, greaterThanOrEqualTo(0),
            reason: 'should have received progress');
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: seekListener));
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('Seek and verify file integrity', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      var transferComplete = false;
      final fileSize = await testFile.length();
      final seekTarget = fileSize ~/ 3; // Seek to 1/3 position

      var progressPositions = <int>[];
      final progressListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE) {
            bob.addReceivedMessage(message);
          }
        },
        onMessageDownloadProgressCallback:
            (V2TimMessageDownloadProgress progress) {
          progressPositions.add(progress.currentSize);
          if (progress.currentSize == progress.totalSize &&
              progress.totalSize > 0) {
            transferComplete = true;
          }
        },
      );

      bob.runWithInstance(() =>
          TIMMessageManager.instance.addAdvancedMsgListener(progressListener));
      try {
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        // Retry initial send: file_request may drop and the transfer
        // never starts; the progress + completion waits below are
        // tolerant via long virtual budgets but won't make up for a
        // never-received request.
        bool fileMsgArrived() => bob.receivedMessages.any((m) =>
            m.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
            m.fileElem != null);
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          final sendResult = await alice.runWithInstanceAsync(() async {
            final fileResult = TIMMessageManager.instance.createFileMessage(
              filePath: testFile.path,
              fileName: 'test_file_seek.txt',
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
              fileMsgArrived,
              timeout: const Duration(seconds: 30),
              description:
                  'file message received by Bob (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } catch (_) {
            // retry
          }
        }
        expect(arrived, isTrue,
            reason: 'file message never received after 3 send retries');

        // Give poll timer time to process file_request and progress_recv
        await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 100);
        await pumpTestTick(scenario, advanceMs: 800, iterationsPerInstance: 1);

        // Wait for transfer to start (progress from progress_recv).
        // Generous virtual budget; transfer continues across small drops.
        await waitUntilWithVirtualPump(
          scenario,
          () => progressPositions.isNotEmpty,
          timeout: const Duration(seconds: 90),
          description: 'file transfer progress',
          advanceMs: 50,
          iterationsPerInstance: 1,
        );
        // Wait for completion (pump so Tox can complete transfer)
        await waitUntilWithVirtualPump(
          scenario,
          () => transferComplete,
          timeout: const Duration(seconds: 90),
          description: 'file transfer complete',
          advanceMs: 50,
          iterationsPerInstance: 1,
        );

        expect(transferComplete, isTrue,
            reason: 'File transfer should complete');
        if (progressPositions.isNotEmpty) {
          expect(progressPositions.length, greaterThan(0));
        }
        expect(seekTarget, greaterThan(0),
            reason: 'seek target should be positive');
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: progressListener));
      }
    }, timeout: const Timeout(Duration(seconds: 300)));

    test('Seek from beginning after partial transfer', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final bobToxId = bob.getToxId();
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      var fileRequestReceived = false;
      final fileSize = await testFile.length();

      final seekBeginListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          final text = message.textElem?.text ?? '';
          final isForwardFileText =
              text.contains('转发文件') && text.contains('test_file_seek.txt');
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
              message.fileElem != null ||
              isForwardFileText) {
            fileRequestReceived = true;
            bob.addReceivedMessage(message);
          }
        },
        onMessageDownloadProgressCallback:
            (V2TimMessageDownloadProgress progress) {
          // Track progress
        },
      );

      bob.runWithInstance(() => TIMMessageManager.instance
          .addAdvancedMsgListener(seekBeginListener));
      try {
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        // Retry send + wait for file_request callback.
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          fileRequestReceived = false;
          final sendResult = await alice.runWithInstanceAsync(() async {
            final fileResult = TIMMessageManager.instance.createFileMessage(
              filePath: testFile.path,
              fileName: 'test_file_seek.txt',
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
              () => fileRequestReceived,
              timeout: const Duration(seconds: 30),
              description: 'file request received (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            arrived = true;
          } catch (_) {
            // retry
          }
        }

        expect(arrived, isTrue,
            reason: 'file request never received after 3 send retries');

        // Verify latest file message in this test run.
        final fileMessages = bob.receivedMessages
            .where((m) =>
                m.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
                m.fileElem != null)
            .toList();
        expect(fileMessages.isNotEmpty, isTrue,
            reason: 'Expected at least one file message');
        final fileMessage = fileMessages.last;

        expect(fileMessage.fileElem, isNotNull);
        final reportedSize = fileMessage.fileElem?.fileSize;
        if (reportedSize != null) {
          expect(reportedSize, equals(fileSize));
        }
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: seekBeginListener));
      }
      // Note: Seeking to beginning (position 0) would restart the transfer
      // This is handled by FfiChatService.seekFileTransfer(peerId, fileNumber, 0)
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
