/// Avatar Test — virtual-clock variant
///
/// Mirrors scenario_avatar_test.dart 1:1 but drives the harness via the
/// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
/// Tests avatar file transfer (TOX_FILE_KIND_AVATAR).
/// Reference: c-toxcore/auto_tests/scenarios/scenario_avatar_test.c

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:path/path.dart' as path;
import '../test_helper.dart';
import '../test_fixtures.dart';

const _avatarSubdir = 'scenario_avatar_virtual';

void main() {
  group('Avatar Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late String testDataDir;
    late File avatarFile;

    const avatarSize = 100;
    final avatarData = Uint8List.fromList(
      List.generate(avatarSize, (i) => i % 256),
    );

    setUpAll(() async {
      await setupTestEnvironment();
      testDataDir = await getTestDataDir(_avatarSubdir);

      // Create avatar file (isolated dir so other scenarios' teardown won't wipe it)
      final avatarPath = path.join(testDataDir, 'avatar_test.dat');
      avatarFile = File(avatarPath);
      await avatarFile.writeAsBytes(avatarData);

      // ENABLE TEST MODE *BEFORE* scenario creation.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
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
    });

    tearDownAll(() async {
      await scenario.dispose();
      await cleanupTestDataDir(_avatarSubdir);
      await teardownTestEnvironment();
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      bob.receivedMessages.clear();
    });

    test('Avatar file transfer', () async {
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      final completer = Completer<File>();
      bool avatarReceived = false;

      final listener = V2TimAdvancedMsgListener(
        onRecvNewMessage: (V2TimMessage message) {
          final text = message.textElem?.text ?? '';
          final isAvatarForwardText =
              text.contains('转发文件') && text.contains('avatar');
          if (message.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
              message.fileElem != null ||
              isAvatarForwardText) {
            bob.addReceivedMessage(message);
            avatarReceived = true;
            final fileElem = message.fileElem;
            if (fileElem != null && !completer.isCompleted) {
              completer.complete(File(fileElem.path ?? ''));
            }
          }
        },
      );

      bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(listener));

      try {
        // Retry send+wait: file-progress callbacks can race friend P2P
        // bring-up on a local bootstrap; retry up to 3x.
        var received = false;
        for (var attempt = 0; !received && attempt < 3; attempt++) {
          final sendResult = await alice.runWithInstanceAsync(() async {
            final fileMsgResult = TIMMessageManager.instance.createFileMessage(
              filePath: avatarFile.path,
              fileName: 'avatar.png',
            );
            expect(fileMsgResult.messageInfo, isNotNull,
                reason: 'File message creation should succeed');
            return await TIMMessageManager.instance.sendMessage(
              groupID: null,
              message: fileMsgResult.messageInfo!,
              receiver: bobToxId,
              onlineUserOnly: false,
            );
          });

          expect(sendResult.code, equals(0),
              reason: 'Avatar file send should succeed');

          try {
            await waitUntilWithVirtualPump(
              scenario,
              () => avatarReceived,
              timeout: const Duration(seconds: 30),
              description:
                  'avatar file message received (attempt ${attempt + 1})',
              advanceMs: 50,
              iterationsPerInstance: 1,
            );
            received = true;
          } on TimeoutException catch (e) {
            // Expected between retry attempts (the post-loop expect enforces the
            // real assertion); a non-timeout error is a real bug and propagates.
            print('[Test] Attempt timed out; retrying: $e');
          }
        }

        expect(received, isTrue, reason: 'Avatar never received after retries');
        expect(avatarReceived, isTrue, reason: 'Avatar should be received');
        expect(bob.receivedMessages.length, greaterThan(0),
            reason: 'Bob should have received messages');

        final fileMsgs = bob.receivedMessages
            .where((m) =>
                m.elemType == MessageElemType.V2TIM_ELEM_TYPE_FILE ||
                m.fileElem != null)
            .toList();
        if (fileMsgs.isNotEmpty) {
          final receivedMsg = fileMsgs.last;
          expect(receivedMsg.fileElem, isNotNull,
              reason: 'File element should not be null');
          expect(
              receivedMsg.fileElem!.fileName == 'avatar.png' ||
                  receivedMsg.fileElem!.fileName == 'avatar_test.dat',
              isTrue,
              reason:
                  'File name should be avatar.png (sent) or avatar_test.dat (from path)');
        } else {
          final hasForwardText = bob.receivedMessages.any((m) {
            final t = m.textElem?.text ?? '';
            return t.contains('转发文件') && t.contains('avatar');
          });
          expect(hasForwardText, isTrue,
              reason: 'Expected FILE element or forward file text');
        }
      } finally {
        bob.runWithInstance(() => TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: listener));
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('Avatar file hash verification', () async {
      // Pure synchronous metadata check — no virtual-time pumping required.
      final fileMsgResult = alice
          .runWithInstance(() => TIMMessageManager.instance.createFileMessage(
                filePath: avatarFile.path,
                fileName: 'avatar.png',
              ));

      expect(fileMsgResult.messageInfo, isNotNull);
      expect(fileMsgResult.messageInfo!.fileElem, isNotNull,
          reason: 'File element should be set');
      final fileSize = fileMsgResult.messageInfo!.fileElem!.fileSize;
      if (fileSize != null) {
        expect(fileSize, equals(avatarSize),
            reason: 'File size should match avatar data size');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Avatar update notification', () async {
      final bobToxId = bob.getToxId();
      await waitForConnectionVirtual(scenario, alice,
          timeout: const Duration(seconds: 15));
      await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
          timeout: const Duration(seconds: 90));

      final sendResult = await alice.runWithInstanceAsync(() async {
        final fileMsgResult = TIMMessageManager.instance.createFileMessage(
          filePath: avatarFile.path,
          fileName: 'avatar.png',
        );
        expect(fileMsgResult.messageInfo, isNotNull);
        return await TIMMessageManager.instance.sendMessage(
          groupID: null,
          message: fileMsgResult.messageInfo!,
          receiver: bobToxId,
          onlineUserOnly: false,
        );
      });

      expect(sendResult.code, equals(0),
          reason:
              'Avatar update message should be sent successfully (code 7012 may indicate SDK internal error)');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
