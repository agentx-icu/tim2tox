import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_status.dart';
import 'package:tim2tox_dart/utils/tim2tox_failed_message_persistence.dart';

const _baseKey = 'tencent_cloud_chat_failed_messages';
const _accountA =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _accountB =
    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

Map<String, dynamic> _failedTextMessage({
  required String id,
  required String msgID,
  required String text,
  required int timestamp,
}) =>
    <String, dynamic>{
      'id': id,
      'msgID': msgID,
      'timestamp': timestamp,
      'elemType': MessageElemType.V2TIM_ELEM_TYPE_TEXT,
      'text': text,
      'userID': null,
      'groupID': null,
      'isSelf': true,
      'status': MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL,
      'savedAt': timestamp,
      'schemaVersion': 2,
    };

Future<Map<String, dynamic>> _storedMap(String key) async {
  final prefs = await SharedPreferences.getInstance();
  return jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Tim2ToxFailedMessagePersistence', () {
    test('save scopes rows to the full Tox account and exact conversation',
        () async {
      final message = _failedTextMessage(
        id: 'local-1',
        msgID: 'wire-1',
        text: 'failed c2c',
        timestamp: 100,
      );

      await Tim2ToxFailedMessagePersistence.saveFailedMessageData(
        messageData: message,
        userID: 'peer-a',
        accountToxId: _accountA,
      );

      final scoped = await Tim2ToxFailedMessagePersistence.loadFailedMessages(
        userID: 'peer-a',
        accountToxId: _accountA,
      );
      final otherAccount =
          await Tim2ToxFailedMessagePersistence.loadFailedMessages(
        userID: 'peer-a',
        accountToxId: _accountB,
      );
      final prefs = await SharedPreferences.getInstance();

      expect(scoped, hasLength(1));
      expect(scoped.single['id'], 'local-1');
      expect(scoped.single['msgID'], 'wire-1');
      expect(scoped.single['text'], 'failed c2c');
      expect(scoped.single['status'], MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL);
      expect(otherAccount, isEmpty);
      expect(prefs.getString('${_baseKey}_$_accountA'), isNotNull);
      expect(
          prefs.getString('${_baseKey}_${_accountA.substring(0, 16)}'), isNull);
    });

    test('saving the same row by id or msgID rewrites instead of duplicating',
        () async {
      final original = _failedTextMessage(
        id: 'local-1',
        msgID: 'wire-1',
        text: 'first failure',
        timestamp: 100,
      );
      final replacement = _failedTextMessage(
        id: 'different-local',
        msgID: 'wire-1',
        text: 'second failure',
        timestamp: 101,
      );

      await Tim2ToxFailedMessagePersistence.saveFailedMessageData(
        messageData: original,
        groupID: 'tox_group_room',
        accountToxId: _accountA,
      );
      await Tim2ToxFailedMessagePersistence.saveFailedMessageData(
        messageData: replacement,
        groupID: 'tox_group_room',
        accountToxId: _accountA,
      );

      final scoped = await Tim2ToxFailedMessagePersistence.loadFailedMessages(
        groupID: 'tox_group_room',
        accountToxId: _accountA,
      );

      expect(scoped, hasLength(1));
      expect(scoped.single['id'], 'different-local');
      expect(scoped.single['msgID'], 'wire-1');
      expect(scoped.single['text'], 'second failure');
    });

    test('load migrates a 16-char legacy account key to the full account key',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${_baseKey}_${_accountA.substring(0, 16)}': jsonEncode({
          'peer-a': [
            {
              'id': 'legacy-local',
              'msgID': 'legacy-wire',
              'timestamp': 99,
              'elemType': MessageElemType.V2TIM_ELEM_TYPE_TEXT,
              'text': 'legacy failed',
              'isSelf': true,
              'status': MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL,
            }
          ]
        }),
      });

      final loaded = await Tim2ToxFailedMessagePersistence.loadFailedMessages(
        userID: 'peer-a',
        accountToxId: _accountA,
      );
      final prefs = await SharedPreferences.getInstance();

      expect(loaded, hasLength(1));
      expect(loaded.single['msgID'], 'legacy-wire');
      expect(prefs.getString('${_baseKey}_$_accountA'), isNotNull);
      expect(
          prefs.getString('${_baseKey}_${_accountA.substring(0, 16)}'), isNull);
    });

    test('migration merges mixed stores and deduplicates by id or msgID',
        () async {
      final legacyKey = '${_baseKey}_${_accountA.substring(0, 16)}';
      const fullKey = '${_baseKey}_$_accountA';
      SharedPreferences.setMockInitialValues(<String, Object>{
        fullKey: jsonEncode({
          'peer-a': [
            _failedTextMessage(
              id: 'same-id',
              msgID: 'full-wire-by-id',
              text: 'full wins by id',
              timestamp: 100,
            ),
            _failedTextMessage(
              id: 'full-local-by-msg',
              msgID: 'same-wire',
              text: 'full wins by msgID',
              timestamp: 101,
            ),
            _failedTextMessage(
              id: 'full-only',
              msgID: 'full-only-wire',
              text: 'full only',
              timestamp: 102,
            ),
          ],
          'full-room': [
            _failedTextMessage(
              id: 'full-room-local',
              msgID: 'full-room-wire',
              text: 'full room',
              timestamp: 103,
            ),
          ],
        }),
        legacyKey: jsonEncode({
          'peer-a': [
            _failedTextMessage(
              id: 'same-id',
              msgID: 'legacy-wire-by-id',
              text: 'legacy duplicate by id',
              timestamp: 90,
            ),
            _failedTextMessage(
              id: 'legacy-local-by-msg',
              msgID: 'same-wire',
              text: 'legacy duplicate by msgID',
              timestamp: 91,
            ),
            _failedTextMessage(
              id: 'legacy-only',
              msgID: 'legacy-only-wire',
              text: 'legacy only',
              timestamp: 92,
            ),
          ],
          'legacy-room': [
            _failedTextMessage(
              id: 'legacy-room-local',
              msgID: 'legacy-room-wire',
              text: 'legacy room',
              timestamp: 93,
            ),
          ],
        }),
      });

      final peerRows = await Tim2ToxFailedMessagePersistence.loadFailedMessages(
        userID: 'peer-a',
        accountToxId: _accountA,
      );
      final fullRoomRows =
          await Tim2ToxFailedMessagePersistence.loadFailedMessages(
        userID: 'full-room',
        accountToxId: _accountA,
      );
      final legacyRoomRows =
          await Tim2ToxFailedMessagePersistence.loadFailedMessages(
        userID: 'legacy-room',
        accountToxId: _accountA,
      );
      final prefs = await SharedPreferences.getInstance();

      expect(peerRows, hasLength(4));
      expect(
        peerRows.map((row) => row['text']),
        containsAll(<String>[
          'full wins by id',
          'full wins by msgID',
          'full only',
          'legacy only',
        ]),
      );
      expect(
        peerRows.map((row) => row['text']),
        isNot(contains('legacy duplicate by id')),
      );
      expect(
        peerRows.map((row) => row['text']),
        isNot(contains('legacy duplicate by msgID')),
      );
      expect(fullRoomRows.single['msgID'], 'full-room-wire');
      expect(legacyRoomRows.single['msgID'], 'legacy-room-wire');
      expect(prefs.getString(fullKey), isNotNull);
      expect(prefs.getString(legacyKey), isNull);
    });

    test('scoped lookup falls back to the legacy unscoped base key', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _baseKey: jsonEncode({
          'peer-a': [
            _failedTextMessage(
              id: 'base-local',
              msgID: 'base-wire',
              text: 'unscoped legacy failure',
              timestamp: 100,
            ),
          ],
        }),
      });

      final found = await Tim2ToxFailedMessagePersistence.findFailedMessageByID(
        messageID: 'base-wire',
        accountToxId: _accountA,
      );

      expect(found, isNotNull);
      expect(found!.conversationKey, 'peer-a');
      expect(found.messageData['text'], 'unscoped legacy failure');
      expect(found.accountToxId, isNull);
    });

    test('removeFailedMessagesByIDs only scans the current account failed keys',
        () async {
      final removeByMsgID = _failedTextMessage(
        id: 'local-remove-msg',
        msgID: 'wire-remove-msg',
        text: 'remove by msg',
        timestamp: 100,
      );
      final removeByID = _failedTextMessage(
        id: 'local-remove-id',
        msgID: 'wire-remove-id',
        text: 'remove by id',
        timestamp: 101,
      );
      final keepCurrent = _failedTextMessage(
        id: 'local-keep',
        msgID: 'wire-keep',
        text: 'keep current account',
        timestamp: 102,
      );
      final keepOther = _failedTextMessage(
        id: 'other-local-remove-msg',
        msgID: 'wire-remove-msg',
        text: 'keep other account',
        timestamp: 103,
      );

      await Tim2ToxFailedMessagePersistence.saveFailedMessageData(
        messageData: removeByMsgID,
        userID: 'peer-a',
        accountToxId: _accountA,
      );
      await Tim2ToxFailedMessagePersistence.saveFailedMessageData(
        messageData: removeByID,
        groupID: 'tox_group_room',
        accountToxId: _accountA,
      );
      await Tim2ToxFailedMessagePersistence.saveFailedMessageData(
        messageData: keepCurrent,
        userID: 'peer-a',
        accountToxId: _accountA,
      );
      await Tim2ToxFailedMessagePersistence.saveFailedMessageData(
        messageData: keepOther,
        userID: 'peer-a',
        accountToxId: _accountB,
      );

      await Tim2ToxFailedMessagePersistence.removeFailedMessagesByIDs(
        messageIDs: const {'wire-remove-msg', 'local-remove-id'},
        accountToxId: _accountA,
      );

      final currentStore = await _storedMap('${_baseKey}_$_accountA');
      final otherStore = await _storedMap('${_baseKey}_$_accountB');

      expect(currentStore['peer-a'], hasLength(1));
      expect((currentStore['peer-a'] as List).single['msgID'], 'wire-keep');
      expect(currentStore.containsKey('tox_group_room'), isFalse);
      expect((otherStore['peer-a'] as List).single['msgID'], 'wire-remove-msg');
    });
  });
}
