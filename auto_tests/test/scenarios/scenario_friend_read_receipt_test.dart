/// Standard toxcore friend delivery receipt test.
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_receipt.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Read Receipt Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      // Parallelize login
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'condition',
      );

      // Configure local bootstrap (virtual)
      await configureLocalBootstrapVirtual(scenario);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared scenario
    });

    test('standard delivery receipt callback arrives after friend message',
        () async {
      // Establish friendship (alice-bob) — virtual
      await establishFriendshipVirtual(scenario, alice, bob);

      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      await Future.wait([
        waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30)),
        waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30)),
      ]);

      var receiptCallbackCount = 0;
      final listener = V2TimAdvancedMsgListener(
        onRecvMessageReadReceipts: (List<V2TimMessageReceipt> receiptList) {
          receiptCallbackCount++;
          expect(receiptList, hasLength(1));
          alice.markCallbackReceived('onRecvMessageReadReceipts');
        },
      );
      alice.runWithInstance(() {
        TIMMessageManager.instance.addAdvancedMsgListener(listener);
      });

      // Alice sends a standard friend message. toxcore emits the C2C receipt
      // when Bob's core receives the packet; no human read action is involved.
      final messageResult = alice.runWithInstance(() =>
          TIMMessageManager.instance.createTextMessage(text: 'Hello Bob!'));
      final sendResult = await alice.runWithInstanceAsync(
          () async => TIMMessageManager.instance.sendMessage(
                message: messageResult.messageInfo!,
                receiver: bobToxId,
                groupID: null,
                onlineUserOnly: false,
              ));

      expect(sendResult.code, equals(0));
      expect(sendResult.data?.id, isNotNull);

      await waitUntilWithVirtualPump(
        scenario,
        () => alice.callbackReceived['onRecvMessageReadReceipts'] == true,
        timeout: const Duration(seconds: 30),
        description: 'standard toxcore friend delivery receipt callback',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );
      expect(receiptCallbackCount, equals(1));

      alice.runWithInstance(() {
        TIMMessageManager.instance
            .removeAdvancedMsgListener(listener: listener);
      });
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
