/// Friend Connection Test
import 'dart:async';
/// 
/// Tests friend connection status monitoring
/// Reference: c-toxcore/auto_tests/scenarios/scenario_friend_connection_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_info.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend Connection Tests', () {
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
    
    test('Friend connection status', () async {
      // Establish bidirectional friendship
      await establishFriendship(alice, bob);
      
      // Get actual Tox IDs and public keys
      // Note: Friend list contains public keys (64 chars), not full Tox IDs (76 chars)
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      final bobPublicKey = bob.getPublicKey();
      final alicePublicKey = alice.getPublicKey();
      
      // Wait for friend connection to be established - parallelize
      await Future.wait([
        alice.waitForFriendConnection(bobToxId, timeout: const Duration(seconds: 30)),
        bob.waitForFriendConnection(aliceToxId, timeout: const Duration(seconds: 30)),
      ]);
      
      // Get friend list and verify connection (per-instance; use node context)
      final aliceFriendListResult = await alice.runWithInstanceAsync(() async => TIMFriendshipManager.instance.getFriendList());
      expect(aliceFriendListResult.code, equals(0));
      expect(aliceFriendListResult.data, isNotNull);
      expect(aliceFriendListResult.data!.any((f) => f.userID == bobPublicKey), isTrue,
          reason: 'Bob should be in Alice\'s friend list');
      
      final bobFriendListResult = await bob.runWithInstanceAsync(() async => TIMFriendshipManager.instance.getFriendList());
      expect(bobFriendListResult.code, equals(0));
      expect(bobFriendListResult.data, isNotNull);
      expect(bobFriendListResult.data!.any((f) => f.userID == alicePublicKey), isTrue,
          reason: 'Alice should be in Bob\'s friend list');
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Friend connection status change monitoring', () async {
      // Establish friendship first
      await establishFriendship(alice, bob);
      
      final completer = Completer<void>();
      
      // Set up friendship listener to monitor friend status changes (per-instance; use alice context)
      // Note: Friend info callbacks use public key (64 chars), not TestNode.userId
      final bobPublicKey = bob.getPublicKey();
      final friendshipListener = V2TimFriendshipListener(
        onFriendInfoChanged: (List<V2TimFriendInfo> infoList) {
          if (infoList.any((info) => info.userID == bobPublicKey)) {
            alice.markCallbackReceived('onFriendInfoChanged');
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        },
      );
      
      alice.runWithInstance(() {
        TIMFriendshipManager.instance.addFriendListener(listener: friendshipListener);
      });
      
      // Wait for friend connection status to change (waitForFriendConnection uses Tox ID)
      final bobToxId = bob.getToxId();
      await alice.waitForFriendConnection(bobToxId, timeout: const Duration(seconds: 30));
      
      // Verify friend is connected; friend list stores 64-char public key in userID, not 76-char Tox ID
      final isFriend = await alice.isFriend(bobPublicKey);
      expect(isFriend, isTrue, reason: 'Bob should be in Alice\'s friend list');
      
      // Cleanup (per-instance; use alice context)
      alice.runWithInstance(() {
        TIMFriendshipManager.instance.removeFriendListener(listener: friendshipListener);
      });
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
