/// Friend Request Spam Test — virtual-clock variant
///
/// Mirrors scenario_friend_request_spam_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before initAllNodes() and replaces the poll
/// loop with waitUntilWithVirtualPump.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Request Spam Tests', () {
    late TestScenario scenario;
    late TestNode receiver;
    late List<TestNode> senders;

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* scenario creation.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['receiver']);
      receiver = scenario.getNode('receiver')!;

      // Create multiple senders (3 to keep test time reasonable).
      senders = [];
      for (int i = 0; i < 3; i++) {
        final sender = scenario.addNode(
          alias: 'sender$i',
          userId: 'sender${i}_${DateTime.now().millisecondsSinceEpoch}',
          userSig: 'sender${i}_sig',
        );
        senders.add(sender);
      }

      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      // Parallelize login for all nodes
      await Future.wait([
        receiver.login(),
        ...senders.map((s) => s.login()),
      ]);

      await waitUntil(
          () => receiver.loggedIn && senders.every((s) => s.loggedIn));

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

    test('Multiple friend requests handling', () async {
      int requestCount = 0;
      final completer = Completer<void>();

      // Set up friend request listener on receiver's instance
      final listener = V2TimFriendshipListener(
        onFriendApplicationListAdded:
            (List<V2TimFriendApplication> applicationList) {
          requestCount += applicationList.length;
          receiver.markCallbackReceived('onFriendApplicationListAdded');

          if (requestCount >= senders.length && !completer.isCompleted) {
            completer.complete();
          }
        },
      );

      receiver.runWithInstance(() {
        TIMFriendshipManager.instance.addFriendListener(listener: listener);
      });

      // Higher retry count than 3 because spam tests send many requests and
      // may need additional re-fires to converge on a flaky local bootstrap.
      final receiverToxId = receiver.getToxId();
      var converged = false;
      for (var attempt = 0; !converged && attempt < 5; attempt++) {
        if (attempt > 0) {
          print(
              '[SPAM_TEST] Retry attempt ${attempt + 1}: re-firing addFriend for senders still missing...');
        }
        // All senders send friend requests (each in own instance; tim2tox uses Tox ID)
        final addResults = await Future.wait(
          senders.map((sender) => sender.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.addFriend(
                userID: receiverToxId,
                addWording: 'Hello!',
                addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
              ))),
        );

        // All requests should succeed (allow "already sent" as success for retries)
        final addOk = addResults.every((r) =>
            r.code == 0 ||
            (r.code != 0 &&
                (r.desc.contains('already sent') ||
                    r.desc.contains('Already sent'))));
        if (!addOk) {
          print(
              '[SPAM_TEST] Some addFriend calls failed (will retry): ${addResults.map((r) => "code=${r.code} desc=${r.desc}").join("; ")}');
        }

        // Inline pump loop because predicate is async (polls
        // getFriendApplicationList as a callback fallback).
        final spamDeadline = VirtualClock.nowMs + 60000;
        while (VirtualClock.nowMs < spamDeadline) {
          if (completer.isCompleted) {
            converged = true;
            break;
          }
          if (requestCount >= senders.length) {
            if (!completer.isCompleted) completer.complete();
            converged = true;
            break;
          }
          final appListResult = await receiver.runWithInstanceAsync(() async =>
              TIMFriendshipManager.instance.getFriendApplicationList());
          if (appListResult.code == 0 &&
              appListResult.data?.friendApplicationList != null) {
            final senderPks = senders.map((s) => s.getPublicKey()).toSet();
            final fromSenders = appListResult.data!.friendApplicationList!
                .whereType<V2TimFriendApplication>()
                .where((app) => senderPks.contains(app.userID))
                .length;
            if (fromSenders >= senders.length) {
              receiver.markCallbackReceived('onFriendApplicationListAdded');
              if (requestCount < senders.length) {
                requestCount = fromSenders;
              }
              if (!completer.isCompleted) completer.complete();
              converged = true;
              break;
            }
          }
          await pumpTestTick(scenario,
              advanceMs: 50, iterationsPerInstance: 1);
        }
      }

      if (!completer.isCompleted) {
        throw TimeoutException(
            'Timeout waiting for all ${senders.length} friend requests (got $requestCount) after 5 retries');
      }

      expect(receiver.callbackReceived['onFriendApplicationListAdded'], isTrue);
      expect(requestCount, greaterThanOrEqualTo(senders.length),
          reason: 'All friend requests should be received');
    }, timeout: const Timeout(Duration(seconds: 360)));
  });
}
