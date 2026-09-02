/// Standard toxcore friend delivery receipt test.
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimAdvancedMsgListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message_receipt.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
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

    /// Offline READ-receipt queue: opening a chat flips the inbound rows
    /// isRead LOCALLY and removes them from every future on-view scan, so a
    /// wire READ receipt skipped because the peer was offline used to be lost
    /// FOREVER (recorded limit of the C2C receipt round-trip). The queue
    /// records those msgIDs and the peer's offline->online transition flushes
    /// them, so the sender's row still flips to peer-read.
    test('offline READ receipts queue and flush when the peer returns',
        () async {
      await establishFriendshipVirtual(scenario, alice, bob);
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      await Future.wait([
        waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: const Duration(seconds: 30)),
        waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: const Duration(seconds: 30)),
      ]);

      final platform =
          TencentCloudChatSdkPlatform.instance as Tim2ToxSdkPlatform;
      final svc = platform.ffiService;
      // Keep the exact case getToxId() returned: normalizeToxId truncates but
      // never re-cases, so a re-cased key would miss the history map.
      final alicePk = aliceToxId.substring(0, 64);
      final bobPk = bobToxId.substring(0, 64);
      // The SHARED harness service never runs svc.login() (TestNode.login is
      // the binary path), so _selfId is empty and _sendReceipt's init guard
      // would silently drop every wire receipt. Pin the reader's identity via
      // the sanctioned test seam; the wire sender field itself comes from
      // getSelfToxId() on the pinned instance, not from this value.
      svc.debugSetSelfId(bobPk);
      final probe =
          'offline read receipt probe ${DateTime.now().microsecondsSinceEpoch}';

      // Alice sends THROUGH the shared service so her own row (the receipt
      // target) lives in its history under Bob's key.
      await alice
          .runWithInstanceAsync(() => svc.sendTextWithResult(bobPk, probe));

      // Bob's poll ingest lands the inbound row under Alice's key, unread.
      await waitUntilWithVirtualPump(
        scenario,
        () => svc
            .getHistory(alicePk)
            .any((m) => !m.isSelf && m.text == probe && !m.isRead),
        timeout: const Duration(seconds: 30),
        description: 'Bob holds the probe message unread',
        advanceMs: 100,
        iterationsPerInstance: 2,
      );

      // Alice drops off FOR REAL: V2TIM Logout only clears the login alias
      // and leaves the tox instance connected, so the native teardown is the
      // only way Bob can observe an offline friend. Bob's service must then
      // OBSERVE the offline state via getFriendList (that is what maintains
      // _friendOnlineStatus and fires the came-online side effects in the
      // product). NOTE: unInitSDK also disposes the shared platform's stream
      // subscriptions — every assertion below reads the service directly,
      // which keeps polling for the surviving instances.
      await alice.unInitSDK();
      var aliceSeenOffline = false;
      for (var i = 0; i < 120 && !aliceSeenOffline; i++) {
        final friends =
            await bob.runWithInstanceAsync(() => svc.getFriendList());
        aliceSeenOffline = friends.any((f) =>
            f.userId.toUpperCase().startsWith(alicePk.toUpperCase()) &&
            !f.online);
        if (!aliceSeenOffline) {
          await pumpTestTick(scenario, advanceMs: 2000,
              iterationsPerInstance: 2);
          if (!shouldRunVirtual) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      }
      expect(aliceSeenOffline, isTrue,
          reason: 'Bob never observed Alice offline — the queue precondition '
              'cannot be constructed');

      // Bob opens the chat: rows flip isRead locally, the wire receipt is
      // QUEUED (peer offline), not dropped.
      final queuedBefore = svc.receiptDiag['receiptsReadQueuedOffline'] ?? 0;
      await bob.runWithInstanceAsync(() async => svc.setActivePeer(alicePk));
      expect(svc.receiptDiag['receiptsReadQueuedOffline'] ?? 0,
          greaterThan(queuedBefore),
          reason: 'chat-open while the peer is offline must queue the READ '
              'receipt instead of dropping it');
      await bob
          .runWithInstanceAsync(() async => svc.setActivePeer(null));

      // Alice returns: re-create her instance from the SAME data dir (the
      // tox save restores her identity and friend list), re-register the new
      // handle for polling (unInitSDK unregistered the old one), and log in.
      await alice.initSDK();
      FfiChatService.registerInstanceForPolling(alice.testInstanceHandle!);
      await alice.login();
      expect(alice.getToxId().substring(0, 64), alicePk,
          reason: 'the revived instance must restore the SAME identity, or '
              'the queued receipt targets a stranger');
      await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
          timeout: const Duration(seconds: 60));

      var flushed = false;
      final flushedBefore = svc.receiptDiag['receiptsReadFlushedOnline'] ?? 0;
      for (var i = 0; i < 60 && !flushed; i++) {
        await bob.runWithInstanceAsync(() => svc.getFriendList());
        await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 2);
        if (!shouldRunVirtual) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        flushed =
            (svc.receiptDiag['receiptsReadFlushedOnline'] ?? 0) > flushedBefore;
      }
      expect(flushed, isTrue,
          reason: 'the came-online transition never flushed the queued READ '
              'receipts');
      // receiptDiag is the debug workhorse here: receiptsHashOut proves the
      // wire send left, receiptsIn proves ingest, receiptsRowMatched proves
      // the hash-echo paired a row.
      // ignore: avoid_print
      print('[offline-receipt] post-flush receiptDiag=${svc.receiptDiag}');

      // The flushed hash-echo receipt must flip Alice's OWN row to read.
      await waitUntilWithVirtualPump(
        scenario,
        () => svc
            .getHistory(bobPk)
            .any((m) => m.isSelf && m.text == probe && m.isRead),
        timeout: const Duration(seconds: 45),
        description: "Alice's own row flips isRead from the flushed receipt",
        advanceMs: 200,
        iterationsPerInstance: 2,
      );
    }, timeout: const Timeout(Duration(seconds: 300)));
  });
}
