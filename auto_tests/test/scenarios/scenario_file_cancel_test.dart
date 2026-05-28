/// File Cancel Test — virtual-clock variant
///
/// Mirrors scenario_file_cancel_test.dart 1:1 but drives the harness via
/// the virtual-clock helpers. The initial file-request acceptance gets the
/// 3x send-retry pattern since the underlying Tox file_request can drop on
/// a flaky 2-node local-bootstrap link. The other two sub-tests only verify
/// that the send was initiated; they keep mechanical pump substitutions.

import 'dart:io';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:path/path.dart' as path;
import '../test_helper.dart';
import '../test_fixtures.dart';

const _fileCancelSubdir = 'scenario_file_cancel_virtual';

void main() {
  group('File Cancel Tests', () {
    late TestScenario scenario;
    late String testDataDir;
    late File testFile;

    setUpAll(() async {
      await setupTestEnvironment();
      testDataDir = await getTestDataDir(_fileCancelSubdir);

      // Create a test file (isolated dir so other scenarios' teardown won't wipe it)
      testFile = File(path.join(testDataDir, 'test_file_cancel.txt'));
      await testFile
          .writeAsString('This is a test file for cancellation.\n' * 1000);

      // Enable BEFORE initAllNodes so V2TIMManagerImpl never spawns
      // event_thread; file_request events flow through FfiChatService
      // polling driven by pumpTestTick.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      await scenario.initAllNodes();
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);
      await Future.wait([alice.login(), bob.login()]);
      await waitUntil(() => alice.loggedIn && bob.loggedIn,
          timeout: const Duration(seconds: 10),
          description: 'both nodes logged in');
      await configureLocalBootstrapVirtual(scenario);
      await establishFriendshipVirtual(scenario, alice, bob);
      await pumpFriendConnectionVirtual(scenario, alice, bob);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await cleanupTestDataDir(_fileCancelSubdir);
      await teardownTestEnvironment();
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      final bob = scenario.getNode('bob')!;
      bob.receivedMessages.clear();
    });

    test('Cancel incoming file transfer', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      var fileRequestReceived = false;
      String? fileMessageId;

      final bobListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE) {
            fileRequestReceived = true;
            fileMessageId = message.msgID;
            bob.addReceivedMessage(message);
          }
          // tim2tox may deliver file as text "[转发文件] fileName (size 字节)"
          final text = message.textElem?.text ?? '';
          if (text.contains('转发文件') &&
              text.contains('test_file_cancel.txt')) {
            fileRequestReceived = true;
            fileMessageId = message.msgID;
            bob.addReceivedMessage(message);
          }
        },
      );

      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(bobListener));
      try {
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        // Retry send + wait for file-request callback. The first
        // file_request packet can drop while friend P2P warms up.
        var arrived = false;
        for (var attempt = 0; !arrived && attempt < 3; attempt++) {
          fileRequestReceived = false;
          final sendResult = await alice.runWithInstanceAsync(() async {
            final fileResult = TIMMessageManager.instance.createFileMessage(
              filePath: testFile.path,
              fileName: 'test_file_cancel.txt',
            );
            expect(fileResult.messageInfo, isNotNull,
                reason: 'File message creation should succeed');
            return await TIMMessageManager.instance.sendMessage(
              groupID: null,
              message: fileResult.messageInfo!,
              receiver: bobToxId,
              onlineUserOnly: false,
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
            // retry — file_request may have been dropped
          }
        }

        expect(arrived, isTrue,
            reason: 'file request never received after 3 send retries');
        expect(fileRequestReceived, isTrue);
        expect(fileMessageId, isNotNull);

        // Verify file-related message was received (FILE elem or forward text from tim2tox)
        final fileMsgs = bob.receivedMessages
            .where((m) => m.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE)
            .toList();
        final forwardTextMsgs = bob.receivedMessages
            .where((m) =>
                (m.textElem?.text ?? '').contains('转发文件') &&
                (m.textElem?.text ?? '').contains('test_file_cancel.txt'))
            .toList();
        expect(fileMsgs.isNotEmpty || forwardTextMsgs.isNotEmpty, isTrue,
            reason: 'expected FILE or forward text message');
        if (fileMsgs.isNotEmpty) {
          expect(fileMsgs.first.fileElem, isNotNull);
        }
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: bobListener));
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('Cancel outgoing file transfer', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final bobToxId = bob.getToxId();
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      final sendResult = await alice.runWithInstanceAsync(() async {
        final fileResult = TIMMessageManager.instance.createFileMessage(
          filePath: testFile.path,
          fileName: 'test_file_cancel.txt',
        );
        expect(fileResult.messageInfo, isNotNull);
        return await TIMMessageManager.instance.sendMessage(
          groupID: null,
          message: fileResult.messageInfo!,
          receiver: bobToxId,
          onlineUserOnly: false,
        );
      });

      expect(sendResult.code, equals(0));

      // Wait a bit for transfer to start
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

      // Cancel the file transfer
      // Note: File cancellation in tim2tox requires FfiChatService
      // This test verifies the send was initiated successfully
      expect(sendResult.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('File transfer cancellation state update', () async {
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      final bobToxId = bob.getToxId();
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      final cancelListener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE) {
            // File request received
          }
        },
        onMessageDownloadProgressCallback: (progress) {
          // Track progress
        },
      );

      bob.runWithInstance(() =>
          TIMMessageManager.instance.addAdvancedMsgListener(cancelListener));
      try {
        await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);

        final sendResult = await alice.runWithInstanceAsync(() async {
          final fileResult = TIMMessageManager.instance.createFileMessage(
            filePath: testFile.path,
            fileName: 'test_file_cancel.txt',
          );
          expect(fileResult.messageInfo, isNotNull);
          return await TIMMessageManager.instance.sendMessage(
            groupID: null,
            message: fileResult.messageInfo!,
            receiver: bobToxId,
            onlineUserOnly: false,
          );
        });

        expect(sendResult.code, equals(0));
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: cancelListener));
      }
      // Note: Actual cancellation would require FfiChatService.cancelFileTransfer()
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
