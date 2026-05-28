/// Binary-replacement history hook teardown / deferred-selfId tests.
///
/// Exercises [BinaryReplacementHistoryHook] on the binary-replacement path
/// (Phase 13). Constructing a [V2TimMessage] reaches into the native SDK
/// (`TIMManager.getServerTime`), so this test loads `libtim2tox_ffi` via
/// [setupNativeLibraryForTim2Tox] in setUpAll — that's why it lives under
/// `scenarios_binary/` rather than the pure-Dart `unit_tests/`.
import 'dart:io';

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_text_elem.dart';
import 'package:tim2tox_dart/utils/binary_replacement_history_hook.dart';
import 'package:tim2tox_dart/utils/message_history_persistence.dart';
import '../test_fixtures.dart';

/// Build an incoming text V2TimMessage. `isSelf` is left null so
/// MessageConverter resolves it from `sender == selfId` — which is what the
/// CR-04 buffering flow exercises (a message that must NOT be persisted with a
/// guessed isSelf before the real selfId is known).
V2TimMessage _incomingText({
  required String fromUserId,
  required String text,
  required String msgID,
}) {
  final msg = V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_TEXT);
  msg.textElem = V2TimTextElem(text: text);
  msg.sender = fromUserId;
  msg.userID = fromUserId;
  msg.msgID = msgID;
  msg.timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return msg;
}

void main() {
  group('BinaryReplacementHistoryHook', () {
    late Directory tempDir;
    late MessageHistoryPersistence persistence;

    setUpAll(() {
      // Route NativeLibraryManager at libtim2tox_ffi so V2TimMessage's
      // constructor (TIMManager.getServerTime) can load the native lib.
      setupNativeLibraryForTim2Tox();
    });

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('brhh_test_');
      persistence = MessageHistoryPersistence(historyDirectory: tempDir.path);
    });

    tearDown(() async {
      // Static state — reset between tests so one case can't leak into the
      // next (e.g. a lingering listener / persistence / buffer).
      await BinaryReplacementHistoryHook.uninstallStandalone();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Best-effort cleanup.
      }
    });

    test('CR-01: uninstallStandalone bumps generation and no-ops later saves',
        () async {
      final before = BinaryReplacementHistoryHook.generation;
      BinaryReplacementHistoryHook.installStandalone(persistence, 'selfA');

      await BinaryReplacementHistoryHook.uninstallStandalone();

      // installStandalone bumps once, uninstallStandalone bumps once more.
      expect(BinaryReplacementHistoryHook.generation, greaterThan(before));

      // After uninstall, _persistence is null so saveMessage is a no-op.
      await BinaryReplacementHistoryHook.saveMessage(_incomingText(
        fromUserId: 'bob',
        text: 'hello after uninstall',
        msgID: 'real-1',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(persistence.getHistory('bob'), isEmpty);
    });

    test('CR-04: empty selfId buffers, then updateSelfId replays exactly once',
        () async {
      BinaryReplacementHistoryHook.installStandalone(persistence, '');

      await BinaryReplacementHistoryHook.saveMessage(_incomingText(
        fromUserId: 'bob',
        text: 'hi alice',
        msgID: 'real-42',
      ));
      // Buffered, not yet persisted.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(persistence.getHistory('bob'), isEmpty);

      BinaryReplacementHistoryHook.updateSelfId('selfA');
      // Let the debounced appendHistory land.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final history = persistence.getHistory('bob');
      expect(history, hasLength(1));
      expect(history.first.text, 'hi alice');
      // Incoming message: sender (bob) != selfId (selfA) -> isSelf false.
      expect(history.first.isSelf, isFalse);
      expect(history.first.fromUserId, 'bob');
    });
  });
}
