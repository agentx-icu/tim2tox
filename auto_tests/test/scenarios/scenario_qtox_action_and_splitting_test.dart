// Contract tests for qTox-compatible NORMAL/ACTION transport behavior.
//
// qTox sends `/me` bodies as TOX_MESSAGE_TYPE_ACTION and splits NORMAL text
// into frames of at most 1322 UTF-8 bytes. A split outbound message remains
// one logical send to the caller, while a qTox receiver sees each wire frame
// as a separate inbound message.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/log_level_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_value_callback.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/bindings/native_library_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/tools.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';

import '../test_fixtures.dart';
import '../test_helper.dart';

const int _qtoxFrameBytes = 1322;

List<String> _expectedQtoxFragments() => <String>[
      '${'a' * 1300}\n',
      '${'b' * 10} ',
      '🙂' * 330,
      '🙂' * 70,
    ];

String _qtoxSplitProbe() => _expectedQtoxFragments().join();

String _messageBody(V2TimMessage message) =>
    message.textElem?.text ?? message.customElem?.data ?? '';

typedef _SendActionDart = int Function(
  ffi.Pointer<pkgffi.Utf8> targetId,
  ffi.Pointer<pkgffi.Utf8> actionText,
);

/// Planned typed FFI seam:
/// `Tim2ToxFfi.sendC2CAction` -> `tim2tox_ffi_send_c2c_action`, and
/// `Tim2ToxFfi.sendGroupAction` -> `tim2tox_ffi_send_group_action`.
Future<int> _sendAction({
  required TestNode node,
  required String targetId,
  required String actionText,
  required bool toGroup,
}) =>
    node.runWithInstanceAsync(() async {
      final dynamic actionApi = Tim2ToxFfi.open();
      final target = targetId.toNativeUtf8();
      final body = actionText.toNativeUtf8();
      try {
        final _SendActionDart send = toGroup
            ? actionApi.sendGroupAction as _SendActionDart
            : actionApi.sendC2CAction as _SendActionDart;
        return send(target, body);
      } finally {
        pkgffi.malloc.free(target);
        pkgffi.malloc.free(body);
      }
    });

Future<V2TimValueCallback<String>> _createLegacyTextConference() async {
  final userData = Tools.generateUserData('createQtoxLegacyConference');
  final completer = Completer<V2TimValueCallback<String>>();
  void handleApiCallback(Map<dynamic, dynamic> jsonResult) {
    final result = V2TimValueCallback<Map<String, String>>.fromJson(
      Map<String, dynamic>.from(jsonResult),
    );
    completer.complete(
      V2TimValueCallback<String>(
        code: result.code,
        desc: result.desc,
        data: result.data?['create_group_result_groupid'],
      ),
    );
  }

  NativeLibraryManager.addTimApiValueCallback2Map(userData, handleApiCallback);
  final params = Tools.string2PointerChar(
    json.encode(<String, dynamic>{
      'create_group_param_group_name': 'qTox ACTION conference',
      'create_group_param_group_id': '',
      'create_group_param_group_type': 'conference',
      'create_group_param_is_support_topic': false,
      'create_group_param_group_member_array': <dynamic>[],
    }),
  );
  final callbackData = Tools.string2PointerVoid(userData);
  final immediate =
      NativeLibraryManager.bindings.DartCreateGroup(params, callbackData);
  if (immediate != 0) {
    NativeLibraryManager.removeTimCallbackFromMap(userData);
    Tools.freePointers([params, callbackData]);
    return V2TimValueCallback<String>(
      code: immediate,
      desc: 'DartCreateGroup rejected legacy conference parameters',
    );
  }

  try {
    return await completer.future;
  } finally {
    NativeLibraryManager.removeTimCallbackFromMap(userData);
    Tools.freePointers([params, callbackData]);
  }
}

void main() {
  group('qTox ACTION and 1322-byte NORMAL splitting', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(<String>['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);
      await Future.wait(<Future<void>>[alice.login(), bob.login()]);
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both qTox compatibility peers logged in',
      );
      await configureLocalBootstrapVirtual(scenario);
      await establishFriendshipVirtual(scenario, alice, bob);
      await pumpFriendConnectionVirtual(scenario, alice, bob);
      await Future.wait(<Future<void>>[
        waitForFriendConnectionVirtual(
          scenario,
          alice,
          bob.getToxId(),
          timeout: const Duration(seconds: 45),
        ),
        waitForFriendConnectionVirtual(
          scenario,
          bob,
          alice.getToxId(),
          timeout: const Duration(seconds: 45),
        ),
      ]);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test(
      '1:1 ACTION arrives as action-aware text, never V2TIM custom',
      () async {
        const actionBody = 'waves from qTox';
        final received = <V2TimMessage>[];
        final wrongInstanceReceived = <V2TimMessage>[];
        final bobListener = V2TimAdvancedMsgListener(
          onRecvNewMessage: (V2TimMessage message) {
            if (_messageBody(message) == actionBody) received.add(message);
          },
        );
        final aliceListener = V2TimAdvancedMsgListener(
          onRecvNewMessage: (V2TimMessage message) {
            if (_messageBody(message) == actionBody) {
              wrongInstanceReceived.add(message);
            }
          },
        );
        bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(bobListener),
        );
        alice.runWithInstance(
          () =>
              TIMMessageManager.instance.addAdvancedMsgListener(aliceListener),
        );

        try {
          final sendResult = await _sendAction(
            node: alice,
            targetId: bob.getToxId(),
            actionText: actionBody,
            toGroup: false,
          );
          expect(sendResult, 1);

          await waitUntilWithVirtualPump(
            scenario,
            () => received.isNotEmpty,
            timeout: const Duration(seconds: 30),
            description: 'Bob receives the qTox ACTION body',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );

          final action = received.single;
          expect(
            action.elemType,
            MessageElemType.V2TIM_ELEM_TYPE_TEXT,
            reason:
                'TOX_MESSAGE_TYPE_ACTION is user-visible text, not an opaque custom payload',
          );
          expect(action.textElem?.text, actionBody);
          expect(action.customElem, isNull);
          expect(wrongInstanceReceived, isEmpty);
        } finally {
          bob.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: bobListener,
            ),
          );
          alice.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: aliceListener,
            ),
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'generic V2TIM custom stays custom and is never presented as ACTION',
      () async {
        const customBody = 'generic V2TIM custom payload';
        final received = <V2TimMessage>[];
        final listener = V2TimAdvancedMsgListener(
          onRecvNewMessage: (V2TimMessage message) {
            if (message.customElem?.data == customBody) received.add(message);
          },
        );
        bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(listener),
        );

        try {
          final sendResult = await alice.runWithInstanceAsync(() async {
            final created = TIMMessageManager.instance.createCustomMessage(
              data: customBody,
            );
            return TIMMessageManager.instance.sendMessage(
              message: created.messageInfo,
              receiver: bob.getToxId(),
              groupID: null,
              onlineUserOnly: false,
            );
          });
          expect(sendResult.code, 0, reason: sendResult.desc);

          await waitUntilWithVirtualPump(
            scenario,
            () => received.isNotEmpty,
            timeout: const Duration(seconds: 30),
            description: 'Bob receives generic V2TIM custom data',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );

          final custom = received.single;
          expect(custom.elemType, MessageElemType.V2TIM_ELEM_TYPE_CUSTOM);
          expect(custom.customElem?.data, customBody);
          expect(
            custom.textElem,
            isNull,
            reason:
                'generic custom data must never acquire ACTION text semantics',
          );
        } finally {
          bob.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: listener,
            ),
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'NORMAL splits newline then space then UTF-8 boundary with one root receipt',
      () async {
        final expectedFragments = _expectedQtoxFragments();
        final payload = _qtoxSplitProbe();
        final received = <V2TimMessage>[];
        var rootReceiptCallbacks = 0;
        String? rootMessageId;

        final bobListener = V2TimAdvancedMsgListener(
          onRecvNewMessage: (V2TimMessage message) {
            if (expectedFragments.contains(_messageBody(message))) {
              received.add(message);
            }
          },
        );
        final aliceListener = V2TimAdvancedMsgListener(
          onRecvMessageReadReceipts: (List<dynamic> receipts) {
            if (receipts.any((receipt) => receipt.msgID == rootMessageId)) {
              rootReceiptCallbacks++;
            }
          },
        );
        bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(bobListener),
        );
        alice.runWithInstance(
          () =>
              TIMMessageManager.instance.addAdvancedMsgListener(aliceListener),
        );

        try {
          final sendResult = await alice.runWithInstanceAsync(() async {
            final created = TIMMessageManager.instance.createTextMessage(
              text: payload,
            );
            return TIMMessageManager.instance.sendMessage(
              message: created.messageInfo,
              receiver: bob.getToxId(),
              groupID: null,
              onlineUserOnly: false,
            );
          });

          expect(
            sendResult.code,
            0,
            reason:
                'the logical send must not be rejected merely because it exceeds one Tox frame: ${sendResult.desc}',
          );
          expect(sendResult.data?.id, isNotNull);
          expect(
            sendResult.data?.id,
            isNotEmpty,
            reason: 'all transport fragments share one caller-visible root ID',
          );
          rootMessageId = sendResult.data?.msgID;
          expect(rootMessageId, isNotNull);

          await waitUntilWithVirtualPump(
            scenario,
            () =>
                received.length >= expectedFragments.length &&
                rootReceiptCallbacks >= 1,
            timeout: const Duration(seconds: 45),
            description: 'all qTox frames and their aggregate root receipt',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          await pumpTestTick(
            scenario,
            advanceMs: 500,
            iterationsPerInstance: 2,
          );

          expect(
            received.map(_messageBody).toList(),
            expectedFragments,
            reason:
                'inbound qTox frames stay separate and preserve transport order',
          );
          expect(
            received.every(
              (message) =>
                  message.elemType == MessageElemType.V2TIM_ELEM_TYPE_TEXT,
            ),
            isTrue,
          );
          expect(
            received.every(
              (message) =>
                  utf8.encode(_messageBody(message)).length <= _qtoxFrameBytes,
            ),
            isTrue,
          );
          expect(received.map(_messageBody).join(), payload);
          expect(
            rootReceiptCallbacks,
            1,
            reason:
                'fragment delivery receipts aggregate before notifying the logical root',
          );
        } finally {
          bob.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: bobListener,
            ),
          );
          alice.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: aliceListener,
            ),
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'legacy text conference ACTION arrives as action-aware text',
      () async {
        const actionBody = 'applauds in a legacy conference';
        var inviteArrived = false;
        String? invitedGroupId;
        final received = <V2TimMessage>[];
        final wrongInstanceReceived = <V2TimMessage>[];
        final groupListener = V2TimGroupListener(
          onMemberInvited: (
            String groupID,
            V2TimGroupMemberInfo opUser,
            List<V2TimGroupMemberInfo> memberList,
          ) {
            inviteArrived = true;
            invitedGroupId = groupID;
          },
        );
        final messageListener = V2TimAdvancedMsgListener(
          onRecvNewMessage: (V2TimMessage message) {
            if (_messageBody(message) == actionBody) received.add(message);
          },
        );
        final aliceMessageListener = V2TimAdvancedMsgListener(
          onRecvNewMessage: (V2TimMessage message) {
            if (_messageBody(message) == actionBody) {
              wrongInstanceReceived.add(message);
            }
          },
        );
        bob.runWithInstance(
          () => TIMGroupManager.instance.addGroupListener(groupListener),
        );
        bob.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(
            messageListener,
          ),
        );
        alice.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(
            aliceMessageListener,
          ),
        );

        try {
          // The public SDK enum normalizes unknown `conference` to Public, so
          // use its raw binary-replacement call to exercise tox_conference_new.
          final created = await alice.runWithInstanceAsync(
            _createLegacyTextConference,
          );
          expect(created.code, 0, reason: created.desc);
          final conferenceId = created.data!;

          for (var attempt = 0; attempt < 3 && !inviteArrived; attempt++) {
            final invite = await alice.runWithInstanceAsync(
              () async => TIMGroupManager.instance.inviteUserToGroup(
                groupID: conferenceId,
                userList: <String>[bob.getPublicKey()],
              ),
            );
            expect(invite.code, 0, reason: invite.desc);
            try {
              await waitUntilWithVirtualPump(
                scenario,
                () => inviteArrived,
                timeout: const Duration(seconds: 20),
                description:
                    'Bob receives legacy conference invite attempt ${attempt + 1}',
                advanceMs: 100,
                iterationsPerInstance: 1,
              );
            } on TimeoutException {
              // Retry the native conference invite; the final assertion is strict.
            }
          }
          expect(inviteArrived, isTrue);
          expect(invitedGroupId, isNotNull);

          await pumpTestTick(
            scenario,
            advanceMs: 3000,
            iterationsPerInstance: 2,
          );

          final sendResult = await _sendAction(
            node: alice,
            targetId: conferenceId,
            actionText: actionBody,
            toGroup: true,
          );
          expect(sendResult, 1);

          await waitUntilWithVirtualPump(
            scenario,
            () => received.isNotEmpty,
            timeout: const Duration(seconds: 30),
            description: 'Bob receives legacy-conference ACTION',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          final action = received.single;
          expect(action.elemType, MessageElemType.V2TIM_ELEM_TYPE_TEXT);
          expect(action.textElem?.text, actionBody);
          expect(action.customElem, isNull);
          expect(wrongInstanceReceived, isEmpty);
        } finally {
          bob.runWithInstance(
            () => TIMGroupManager.instance.removeGroupListener(
              listener: groupListener,
            ),
          );
          bob.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: messageListener,
            ),
          );
          alice.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: aliceMessageListener,
            ),
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 150)),
    );

    test(
      'fragment transport failure is reported instead of partial success',
      () async {
        final bobToxId = bob.getToxId();
        final bobPublicKey = bob.getPublicKey();
        final ffiInstance = Tim2ToxFfi.open();
        final bobIdPointer = bobPublicKey.toNativeUtf8();
        final bobFriendNumber = alice.runWithInstance(
          () => ffiInstance.getFriendNumberByUserIdNative(bobIdPointer),
        );
        pkgffi.calloc.free(bobIdPointer);
        expect(bobFriendNumber, isNot(0xFFFFFFFF));
        expect(
          ffiInstance.getFriendConnectionStatusNative(
            alice.testInstanceHandle!,
            bobFriendNumber,
          ),
          isNot(0),
          reason: 'Alice must see Bob online before native teardown',
        );

        await bob.unInitSDK();
        await waitUntilWithVirtualPump(
          scenario,
          () =>
              ffiInstance.getFriendConnectionStatusNative(
                alice.testInstanceHandle!,
                bobFriendNumber,
              ) ==
              0,
          timeout: const Duration(seconds: 180),
          description: 'Alice observes Bob offline after native teardown',
          advanceMs: 100,
          iterationsPerInstance: 2,
        );

        final aliceAdapterReactivated = await alice.runWithInstanceAsync(
          () => alice.timManager!.initSDK(
            sdkAppID: 0,
            logLevel: LogLevelEnum.V2TIM_LOG_INFO,
            uiPlatform: 0,
            initPath: '',
            logPath: '',
          ),
        );
        expect(aliceAdapterReactivated, isTrue);

        var falseReceiptCallbacks = 0;
        final receiptListener = V2TimAdvancedMsgListener(
          onRecvMessageReadReceipts: (List<dynamic> receipts) {
            if (receipts.isNotEmpty) falseReceiptCallbacks++;
          },
        );
        alice.runWithInstance(
          () => TIMMessageManager.instance.addAdvancedMsgListener(
            receiptListener,
          ),
        );

        try {
          final sendResult = await alice.runWithInstanceAsync(() async {
            final created = TIMMessageManager.instance.createTextMessage(
              text: _qtoxSplitProbe(),
            );
            return TIMMessageManager.instance.sendMessage(
              message: created.messageInfo,
              receiver: bobToxId,
              groupID: null,
              onlineUserOnly: false,
            );
          });
          await pumpTestTick(
            scenario,
            advanceMs: 500,
            iterationsPerInstance: 2,
          );

          expect(
            sendResult.data,
            isNull,
            reason: 'a partially dispatched fragment sequence is not success',
          );
          expect(falseReceiptCallbacks, 0);
          expect(sendResult.desc.toLowerCase(), isNot(contains('too long')));
          expect(sendResult.desc.toLowerCase(), isNot(contains('exceed')));
          expect(
            sendResult.code,
            9508,
            reason:
                'a failed transport fragment must report peer disconnection, not a body-size rejection: ${sendResult.desc}',
          );
        } finally {
          alice.runWithInstance(
            () => TIMMessageManager.instance.removeAdvancedMsgListener(
              listener: receiptListener,
            ),
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
