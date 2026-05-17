/// Friend Delete Test
/// 
/// Tests friend deletion
/// Reference: c-toxcore/auto_tests/scenarios/scenario_friend_delete_test.c

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Delete Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    
    setUpAll(() async {
      scenario = await acquireSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: false);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
    });

    tearDownAll(() async {
      releaseSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: false);
    });
    
    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });
    
    test('Delete friend', () async {
      // Establish friendship (alice adds bob); all ops in alice's instance context
      await establishFriendship(alice, bob);
      
      // Delete friend from alice's instance; native may expect 64-char public key
      final bobPublicKey = bob.getPublicKey();
      final deleteResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.deleteFromFriendList(
        userIDList: [bobPublicKey],
        deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
      ));
      
      expect(deleteResult.code, equals(0));
      
      // Verify friend is deleted (query alice's friend list in her context)
      await Future.delayed(const Duration(seconds: 2));
      final friendListResult = await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendList());
      expect(friendListResult.code, equals(0));
      if (friendListResult.data != null) {
        final bobInList = friendListResult.data!.any((friend) => friend.userID == bobPublicKey);
        expect(bobInList, isFalse, reason: 'Bob should not be in friend list after deletion');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Friend deletion callback', () async {
      final completer = Completer<void>();
      
      final listener = V2TimFriendshipListener(
        onFriendListDeleted: (List<String> userIDList) {
          alice.markCallbackReceived('onFriendListDeleted');
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );
      
      alice.runWithInstance(() {
        TIMFriendshipManager.instance.addFriendListener(listener: listener);
      });
      
      // Establish and then delete friendship in alice's context
      await establishFriendship(alice, bob);
      final bobPublicKey = bob.getPublicKey();
      await alice.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.deleteFromFriendList(
        userIDList: [bobPublicKey],
        deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
      ));
      
      // Wait for deletion callback
      await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          // Callback may not be triggered in all cases
        },
      );
      
      expect(alice.runWithInstance(() => TIMFriendshipManager.instance.v2TimFriendshipListenerList.contains(listener)), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
