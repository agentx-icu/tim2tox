import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/interfaces/logger_service.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

class _FriendApplicationsFfi extends Tim2ToxFfi {
  _FriendApplicationsFfi({required this.payload}) : super.forTesting();

  static const int instanceId = 73;

  final String payload;
  final List<int> requestedInstanceIds = <int>[];
  final List<int> requestedCapacities = <int>[];

  int get requiredCapacity => utf8.encode(payload).length + 1;

  @override
  int Function() get getCurrentInstanceId => () => instanceId;

  @override
  int Function(int, ffi.Pointer<ffi.Int8>, int)
      get getFriendApplicationsForInstance => (int requestedInstanceId,
              ffi.Pointer<ffi.Int8> buffer, int capacity) {
            requestedInstanceIds.add(requestedInstanceId);
            requestedCapacities.add(capacity);

            final bytes = utf8.encode(payload);
            final required = bytes.length + 1;
            if (capacity < required) return -required;

            final output = buffer.cast<ffi.Uint8>().asTypedList(required);
            output.setAll(0, bytes);
            output[bytes.length] = 0;
            return bytes.length;
          };

  @override
  void Function() get uninit => () {};
}

class _RecordingLogger implements LoggerService {
  final List<String> messages = <String>[];

  @override
  void log(String message) => messages.add(message);

  @override
  void logDebug(String message) => messages.add(message);

  @override
  void logError(String message, Object error, StackTrace stack) =>
      messages.add(message);

  @override
  void logWarning(String message) => messages.add(message);
}

void main() {
  test('retries the exact-instance friend application read without truncation',
      () async {
    final firstWording = 'first-${'a' * 18000}';
    final secondWording = 'second-${'b' * 18000}';
    final firstUserId = '1' * 64;
    final secondUserId = '2' * 64;
    final payload = '$firstUserId\t$firstWording\n'
        '$secondUserId\t$secondWording\n';
    final fakeFfi = _FriendApplicationsFfi(payload: payload);
    final logger = _RecordingLogger();
    final tempDirectory = await Directory.systemTemp.createTemp(
      'tim2tox_friend_application_buffer_',
    );
    final service = FfiChatService(
      ffiForTesting: fakeFfi,
      loggerService: logger,
      historyDirectory: p.join(tempDirectory.path, 'history'),
      queueFilePath: p.join(tempDirectory.path, 'offline_queue.json'),
    );

    try {
      final applications = await service.getFriendApplications();

      expect(fakeFfi.requiredCapacity, greaterThan(32 * 1024));
      expect(
        fakeFfi.requestedCapacities,
        <int>[32 * 1024, fakeFfi.requiredCapacity],
      );
      expect(
        fakeFfi.requestedInstanceIds,
        <int>[
          _FriendApplicationsFfi.instanceId,
          _FriendApplicationsFfi.instanceId
        ],
      );
      expect(
        applications,
        <({String userId, String wording})>[
          (userId: firstUserId, wording: firstWording),
          (userId: secondUserId, wording: secondWording),
        ],
      );
      expect(
        logger.messages,
        contains(
          '[FfiChatService] getFriendApplications '
          'rawCount=2 dismissedCount=0 filteredCount=2',
        ),
      );
      final diagnostics = logger.messages.join('\n');
      expect(diagnostics, isNot(contains(firstUserId)));
      expect(diagnostics, isNot(contains(secondUserId)));
      expect(diagnostics, isNot(contains(firstWording)));
      expect(diagnostics, isNot(contains(secondWording)));
    } finally {
      await service.dispose();
      await tempDirectory.delete(recursive: true);
    }
  });
}
