import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/service/file_receive_cleanup.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

void main() {
  test('failed regular accept marks pending before exact-instance cancel',
      () async {
    final actions = <String>[];
    const eventInstanceId = 42;

    await runFileAcceptFailureCleanup(
      hasPendingRow: true,
      markPendingFailed: () => actions.add('mark-failed'),
      cancelNative: () async => actions.add('cancel:$eventInstanceId'),
      onCancelFailure: (_, __) => actions.add('cancel-error'),
    );

    expect(actions, ['mark-failed', 'cancel:42']);
  });

  test('failed avatar accept cancels without pending state and absorbs errors',
      () async {
    final actions = <String>[];

    await runFileAcceptFailureCleanup(
      hasPendingRow: false,
      markPendingFailed: () => actions.add('mark-failed'),
      cancelNative: () async {
        actions.add('cancel:7');
        throw StateError('cancel failed');
      },
      onCancelFailure: (_, __) => actions.add('cancel-error'),
    );

    expect(actions, ['cancel:7', 'cancel-error']);
  });

  test('avatar auto-accept permits the 10 MiB boundary only', () {
    const cap = 10 * 1024 * 1024;

    expect(FfiChatService.isAvatarAutoAcceptSizeAllowed(-1), isFalse);
    expect(FfiChatService.isAvatarAutoAcceptSizeAllowed(0), isTrue);
    expect(FfiChatService.isAvatarAutoAcceptSizeAllowed(cap), isTrue);
    expect(FfiChatService.isAvatarAutoAcceptSizeAllowed(cap + 1), isFalse);
  });

  test(
      'file request branch cancels blocked and failed accepts by event instance',
      () {
    final source = File('lib/service/ffi_chat_service.dart').readAsStringSync();
    final processing =
        source.indexOf('[FfiChatService] Processing file_request event');
    final start = source.lastIndexOf(
        "else if (s.startsWith('file_request:'))", processing);
    final end = source.indexOf("else if (s.startsWith('file_done:'))", start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final branch = source.substring(start, end);

    final blocked = branch.indexOf('if (senderBlocked)');
    final avatarSizeGuard = branch.indexOf(
        'if (isAvatarTransfer &&\n                      !FfiChatService.isAvatarAutoAcceptSizeAllowed(fileSize))');
    final tracking = branch.indexOf('_fileReceiveProgress[');
    expect(blocked, greaterThanOrEqualTo(0));
    expect(avatarSizeGuard, greaterThan(blocked));
    expect(tracking, greaterThan(avatarSizeGuard));
    final blockedSection = branch.substring(blocked, avatarSizeGuard);
    expect(blockedSection, contains('_cancelFileTransferBestEffort('));
    expect(blockedSection, contains('instanceId: fileRequestInstanceId'));
    expect(blockedSection, contains('continue;'));
    expect(blockedSection, isNot(contains('acceptFileTransfer(')));
    expect(blockedSection, isNot(contains('_appendHistory(')));
    expect(blockedSection, isNot(contains('_fileRequestCtrl.add(')));

    final oversizedAvatarSection =
        branch.substring(avatarSizeGuard, tracking);
    expect(oversizedAvatarSection,
        contains('_cancelFileTransferBestEffort('));
    expect(oversizedAvatarSection,
        contains('instanceId: fileRequestInstanceId'));
    expect(oversizedAvatarSection, contains("reason: 'avatar size limit'"));
    expect(oversizedAvatarSection, contains('continue;'));
    expect(oversizedAvatarSection, isNot(contains('acceptFileTransfer(')));
    expect(oversizedAvatarSection, isNot(contains('_appendHistory(')));
    expect(oversizedAvatarSection, isNot(contains('_fileRequestCtrl.add(')));

    expect(branch, contains('_handleFileAcceptFailure('));
    expect(branch, contains('hasPendingRow: false'));
    expect(branch, contains('hasPendingRow: true'));
    expect(branch, contains('instanceId: fileRequestInstanceId'));
  });

  test('manual and msgID receive paths retain and clean exact instance', () {
    final source = File('lib/service/ffi_chat_service.dart').readAsStringSync();

    expect(source, contains('int? instanceId'));
    expect(source, contains('instanceId: fileRequestInstanceId'));
    expect(
        source,
        contains(
            '_fileTransferInstanceByMsgID[msgID] = fileRequestInstanceId'));
    expect(
        source, contains('(String?, int?, int?) getFileTransferInfoFromMsgID'));
    expect(source, contains('_fileTransferInstanceByMsgID[msgID]'));
    expect(source, contains(r'instanceId: transferInfo.$3'));
    expect(
      source,
      contains('_fileTransferInstanceByMsgID[e.msgID] ??'),
    );
    expect(source, contains('void _removeFileTransferByMsgID(String msgID)'));
    expect(source, contains('_removeFileTransferByMsgID(existingMsgID)'));
    expect(source, contains('_removeFileTransferByMsgID(resolvedMsgID)'));
    expect(source, contains('_removeFileTransferByMsgID(msgID)'));
    expect(source, contains('_fileTransferInstanceByMsgID.clear()'));

    final appProvider =
        File('../../../lib/sdk_fake/fake_msg_provider.dart').readAsStringSync();
    expect(appProvider, contains('instanceId: req.instanceId'));
  });

  test('file_done parser keeps legacy uid and colon-bearing path intact', () {
    final parsed = FfiChatService.parseFileDoneEvent(
      'file_done:legacy-peer:0:/tmp/archive:part.bin',
    );

    expect(parsed, isNotNull);
    expect(parsed?.instanceId, 0);
    expect(parsed?.uid, 'legacy-peer');
    expect(parsed?.fileKind, 0);
    expect(parsed?.path, '/tmp/archive:part.bin');
  });

  test('file_done parser recognizes a numeric instance prefix', () {
    final parsed = FfiChatService.parseFileDoneEvent(
      'file_done:42:peer:0:/tmp/archive:part.bin',
    );

    expect(parsed, isNotNull);
    expect(parsed?.instanceId, 42);
    expect(parsed?.uid, 'peer');
    expect(parsed?.fileKind, 0);
    expect(parsed?.path, '/tmp/archive:part.bin');
  });

  test('progress parser keeps legacy uid and colon-bearing path intact', () {
    final parsed = FfiChatService.parseProgressRecvEvent(
      'progress_recv:legacy-peer:1:2:/tmp/archive:part.bin',
    );

    expect(parsed, isNotNull);
    expect(parsed?.instanceId, 0);
    expect(parsed?.uid, 'legacy-peer');
    expect(parsed?.received, 1);
    expect(parsed?.total, 2);
    expect(parsed?.path, '/tmp/archive:part.bin');
  });

  test('progress parser recognizes a numeric instance prefix', () {
    final parsed = FfiChatService.parseProgressRecvEvent(
      'progress_recv:42:peer:1:2:/tmp/archive:part.bin',
    );

    expect(parsed, isNotNull);
    expect(parsed?.instanceId, 42);
    expect(parsed?.uid, 'peer');
    expect(parsed?.received, 1);
    expect(parsed?.total, 2);
    expect(parsed?.path, '/tmp/archive:part.bin');
  });

  test('file completion paths propagate the parsed exact instance', () {
    final source = File('lib/service/ffi_chat_service.dart').readAsStringSync();
    final progressStart =
        source.indexOf("else if (s.startsWith('progress_recv:'))");
    final fileDoneStart =
        source.indexOf("else if (s.startsWith('file_done:'))");
    final fileDoneEnd = source.indexOf(
        "else if (s.startsWith('file_canceled:')", fileDoneStart);
    expect(progressStart, greaterThanOrEqualTo(0));
    expect(fileDoneStart, greaterThan(progressStart));
    expect(fileDoneEnd, greaterThan(fileDoneStart));

    final progressBranch = source.substring(progressStart, fileDoneStart);
    final progressCalls = RegExp(r'unawaited\(_handleFileDone\(')
        .allMatches(progressBranch)
        .toList();
    expect(progressCalls.length, 2);
    for (final call in progressCalls) {
      final callEnd = progressBranch.indexOf('.catchError', call.start);
      expect(callEnd, greaterThan(call.start));
      expect(
        progressBranch.substring(call.start, callEnd),
        contains('instanceId: instanceId'),
      );
    }

    final fileDoneBranch = source.substring(fileDoneStart, fileDoneEnd);
    expect(
      RegExp(r'unawaited\(_handleFileDone\(').allMatches(fileDoneBranch).length,
      1,
    );
    expect(fileDoneBranch, contains('instanceId: fileDoneEvent.instanceId'));

    final handlerStart = source.indexOf('Future<void> _handleFileDone(');
    final handlerEnd =
        source.indexOf('Future<String?> _moveFileToDownloads(', handlerStart);
    final handler = source.substring(handlerStart, handlerEnd);
    expect(handler, contains('{int instanceId = 0}'));
    expect(handler, contains('instanceId: instanceId'));
  });

  test('matched download progress dispatches per-instance listener once', () {
    final source = File('lib/sdk/tim2tox_sdk_platform.dart').readAsStringSync();
    final listenerStart = source.indexOf('void _setupProgressListener()');
    final downloadStart = source.indexOf('// Download progress', listenerStart);
    final noTargetStart =
        source.indexOf('} else if (!progress.isSend &&', downloadStart);
    expect(listenerStart, greaterThanOrEqualTo(0));
    expect(downloadStart, greaterThan(listenerStart));
    expect(noTargetStart, greaterThan(downloadStart));
    final matchedDownloadBranch =
        source.substring(downloadStart, noTargetStart);

    expect(
      RegExp(r'_notifyAdvancedMsgListeners\(')
          .allMatches(matchedDownloadBranch)
          .length,
      1,
    );
    expect(
      matchedDownloadBranch,
      isNot(contains('_instanceAdvancedMsgListeners')),
    );

    final listenerEnd = source.indexOf('\n  /// Populate ', noTargetStart);
    final noTargetBranch = source.substring(noTargetStart, listenerEnd);
    expect(noTargetBranch, contains('_instanceAdvancedMsgListeners'));
  });

  test('message and file diagnostics do not log payloads or absolute paths',
      () {
    final dartSource =
        File('lib/service/ffi_chat_service.dart').readAsStringSync();
    final nativeSource = File('../ffi/tim2tox_ffi.cpp').readAsStringSync();
    final managerSource =
        File('../source/V2TIMManagerImpl.cpp').readAsStringSync();
    final platformSource =
        File('lib/sdk/tim2tox_sdk_platform.dart').readAsStringSync();
    final compatSource =
        File('../ffi/dart_compat_message.cpp').readAsStringSync();
    final groupCompatSource =
        File('../ffi/dart_compat_group.cpp').readAsStringSync();
    final friendshipCompatSource =
        File('../ffi/dart_compat_friendship.cpp').readAsStringSync();

    const dartLeaks = <String>[
      r'Polled file_done event (length=$n): $s',
      r'Polled file_request event (length=$n): $s',
      r'Polled message event (length=$n): $s',
      r'Polled conn event (length=$n): $s',
      r'Polled other event (length=$n): $s',
      r'Processing file_request event: $s',
      r'Raw file_done event string: $s',
      r'file_done event path: $path',
      r'path=$actualPath',
      r'path=$path',
      r'path length=${path.length}, path=$path',
      r'path=$avatarPath',
      r'for $originalPath; falling back',
      r'recvDir=$recvDir',
      r'Auto-accepting image file: $fileName',
      r'Auto-accepting small file: $fileName',
      r'acceptFileTransfer(uid=$uid',
      r'Large file requires manual download: $fileName',
    ];
    for (final leak in dartLeaks) {
      expect(dartSource, isNot(contains(leak)), reason: leak);
    }

    const nativeLeaks = <String>[
      'Sending file_done event: {}',
      'incomplete file {}, expected exact size',
      'Received file does not exist or is empty: {}',
      'failed to open local receive file {}',
      'successfully opened file {}',
      'failed to create parent directory {}',
      'set_file_recv_dir: set to {}',
      'send_file: file missing or empty {}',
      'send_file: fopen failed for {}',
    ];
    for (final leak in nativeLeaks) {
      expect(nativeSource, isNot(contains(leak)), reason: leak);
    }

    const managerLeaks = <String>[
      'Text message content: %s',
      'sender_pubkey=%.64s',
      'Received C2C msg type {} from {}',
      'sender=%s, friend_number=',
    ];
    for (final leak in managerLeaks) {
      expect(managerSource, isNot(contains(leak)), reason: leak);
    }
    for (final leak in <String>[
      'Full JSON content: {}',
    ]) {
      expect(compatSource, isNot(contains(leak)), reason: leak);
    }
    expect(groupCompatSource, isNot(contains('Full JSON received: {}')));
    expect(friendshipCompatSource,
        isNot(contains("DartHandleFriendAddRequest: json_str='{}'")));
    for (final leak in <String>[
      'Sending image message: \${messageToSend.imageElem!.path}',
      'Sending file message: \${messageToSend.fileElem!.path}',
      'Sending video message: \$videoPath',
      'Sending sound message: \$soundPath',
      'Sending text message: "\$text"',
      'Sending face message: \$payload',
      'Sending location message: \$payload',
      'Sound message sent successfully (pathToSend=',
      'getConversation: START, conversationID=',
      'createTextMessage called - text length=\${text.length}, senderID=',
      'Created message with msgID=',
      'sendMessage called: id=',
      'Found message: msgID=',
      'Available message IDs:',
      'Cache keys:',
      'Tracking sent message target: msgID=',
    ]) {
      expect(platformSource, isNot(contains(leak)), reason: leak);
    }
  });
}
