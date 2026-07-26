/// Native Callback Dispatch Tests (Binary Replacement Path)
///
/// Tests the NativeLibraryManager static listener dispatch path:
///   C++ callback → ReceivePort → _handleNativeMessage → _handleGlobalCallback → static listeners
///
/// This covers the binary replacement path that toxee uses,
/// where instance_id is 0 or null (single-instance, no Tim2ToxSdkPlatform routing).

import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/bindings/native_library_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimConversationListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_conversation.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Native Callback Dispatch Tests (Binary Replacement Path)', () {
    late TestNode node;
    late ffi_lib.Tim2ToxFfi ffiInstance;

    setUpAll(() async {
      await setupTestEnvironment();
      setupNativeLibraryForTim2Tox();
      node = await createTestNode('callback_test_node');
      await node.initSDK();
      ffiInstance = ffi_lib.Tim2ToxFfi.open();
    });

    tearDownAll(() async {
      await node.dispose();
      await teardownTestEnvironment();
    });

    test('NetworkStatus callback - onConnectSuccess', () async {
      final completer = Completer<void>();

      NativeLibraryManager.setSdkListener(V2TimSDKListener(
        onConnectSuccess: () {
          if (!completer.isCompleted) completer.complete();
        },
        onConnectFailed: (code, desc) {},
        onConnecting: () {},
        onKickedOffline: () {},
        onUserSigExpired: () {},
        onSelfInfoUpdated: (info) {},
        onUserStatusChanged: (statusList) {},
      ));

      // Inject a NetworkStatus callback with status=0 (connected)
      final json = jsonEncode({
        "callback": "globalCallback",
        "callbackType": 0, // NetworkStatus
        "instance_id": 0,
        "code": 0,
        "desc": "",
        "status": 0, // 0 = connected
      });
      final result = ffiInstance.injectCallback(json);
      expect(result, equals(1), reason: 'injectCallback should return 1 on success');

      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('onConnectSuccess was not called within timeout'),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('NetworkStatus callback - onConnecting', () async {
      final completer = Completer<void>();

      NativeLibraryManager.setSdkListener(V2TimSDKListener(
        onConnectSuccess: () {},
        onConnectFailed: (code, desc) {},
        onConnecting: () {
          if (!completer.isCompleted) completer.complete();
        },
        onKickedOffline: () {},
        onUserSigExpired: () {},
        onSelfInfoUpdated: (info) {},
        onUserStatusChanged: (statusList) {},
      ));

      final json = jsonEncode({
        "callback": "globalCallback",
        "callbackType": 0, // NetworkStatus
        "instance_id": 0,
        "code": 0,
        "desc": "",
        "status": 2, // 2 = connecting
      });
      ffiInstance.injectCallback(json);

      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('onConnecting was not called within timeout'),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('ReceiveNewMessage callback dispatches to advancedMessageListener', () async {
      final completer = Completer<V2TimMessage>();

      NativeLibraryManager.setAdvancedMessageListener(V2TimAdvancedMsgListener(
        onRecvNewMessage: (msg) {
          if (!completer.isCompleted) completer.complete(msg);
        },
      ));

      // Inject a ReceiveNewMessage callback with a text message
      final msgJson = jsonEncode({
        "callback": "globalCallback",
        "callbackType": 7, // ReceiveNewMessage
        "instance_id": 0,
        "json_msg_array": jsonEncode([
          {
            "message_msg_id": "test_msg_001",
            "message_sender": "user_alice",
            "message_conv_id": "user_bob",
            "message_conv_type": 1,
            "message_elem_array": [
              {
                "elem_type": 0, // Text
                "text_elem_content": "Hello from inject test!",
              }
            ],
          }
        ]),
      });
      ffiInstance.injectCallback(msgJson);

      final receivedMsg = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('onRecvNewMessage was not called within timeout'),
      );
      expect(receivedMsg.textElem?.text, equals('Hello from inject test!'));
      expect(receivedMsg.sender, equals('user_alice'));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('ConversationEvent callback dispatches to conversationListener', () async {
      final completer = Completer<List<V2TimConversation?>>();

      NativeLibraryManager.setConversationListener(V2TimConversationListener(
        onConversationChanged: (convList) {
          if (!completer.isCompleted) completer.complete(convList);
        },
      ));

      final convJson = jsonEncode({
        "callback": "globalCallback",
        "callbackType": 32, // ConversationEvent
        "instance_id": 0,
        "conv_event": 2, // conversationEventUpdate
        "json_conv_array": jsonEncode([
          {
            "conv_id": "user_alice",
            "conv_type": 1,
            "conv_show_name": "Alice",
            "conv_unread_num": 3,
            "conv_recv_opt": 0,
            "conv_active_time": 0,
          }
        ]),
      });
      ffiInstance.injectCallback(convJson);

      final conversations = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('onConversationChanged was not called within timeout'),
      );
      expect(conversations, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('FriendAddRequest callback dispatches to friendshipListener', () async {
      final completer = Completer<List<V2TimFriendApplication>>();

      NativeLibraryManager.setFriendshipListener(V2TimFriendshipListener(
        onFriendApplicationListAdded: (appList) {
          if (!completer.isCompleted) completer.complete(appList);
        },
      ));

      final friendJson = jsonEncode({
        "callback": "globalCallback",
        "callbackType": 43, // FriendAddRequest
        "instance_id": 0,
        "json_application_array": jsonEncode([
          {
            "friend_add_pendency_identifier": "user_charlie",
            "friend_add_pendency_nick_name": "Charlie",
            "friend_add_pendency_add_wording": "Hi, add me!",
            "friend_add_pendency_type": 1,
          }
        ]),
      });
      ffiInstance.injectCallback(friendJson);

      final applications = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('onFriendApplicationListAdded was not called within timeout'),
      );
      expect(applications, isNotEmpty);
      expect(applications.first.userID, equals('user_charlie'));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('malformed payloads do not stop later callback dispatch', () async {
      final validCallback = Completer<void>();
      NativeLibraryManager.setSdkListener(V2TimSDKListener(
        onConnectSuccess: () {
          if (!validCallback.isCompleted) validCallback.complete();
        },
        onConnectFailed: (code, desc) {},
        onConnecting: () {},
        onKickedOffline: () {},
        onUserSigExpired: () {},
        onSelfInfoUpdated: (info) {},
        onUserStatusChanged: (statusList) {},
      ));

      expect(ffiInstance.injectCallback('{"callback":"globalCallback",'), 1);
      expect(
        ffiInstance.injectCallback(jsonEncode({
          'callback': 'globalCallback',
          'callbackType': 7,
          'instance_id': 0,
          'json_msg_array': '',
        })),
        1,
      );
      expect(
        ffiInstance.injectCallback(jsonEncode({
          'callback': 'globalCallback',
          'callbackType': 0,
          'instance_id': 0,
          'code': 0,
          'desc': '',
          'status': 0,
        })),
        1,
      );

      await validCallback.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'valid callback was not dispatched after malformed payloads',
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
