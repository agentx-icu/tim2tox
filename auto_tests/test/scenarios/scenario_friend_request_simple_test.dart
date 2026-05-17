/// Simple Friend Request Test
/// 
/// This is a simplified test to verify that addFriend can be called
/// and to debug why friend requests are not being received

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Simple Friend Request Test', () {
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
    
    test('Simple addFriend call test', () async {
      print('========================================');
      print('[SIMPLE_TEST] Test started');
      print('========================================');
      
      final aliceToxId = alice.getToxId();
      print('[SIMPLE_TEST] Alice Tox ID: ${aliceToxId.substring(0, 20)}...');
      final bobToxId = bob.getToxId();
      print('[SIMPLE_TEST] Bob Tox ID: ${bobToxId.substring(0, 20)}...');
      
      // CRITICAL: Set up listener for Bob BEFORE sending friend request
      // This ensures the listener is ready to receive the callback
      print('[SIMPLE_TEST] Setting up listener for Bob BEFORE sending friend request...');
      bool requestReceived = false;
      final completer = Completer<void>();
      
      // Set up listener for Bob
      final listener = V2TimFriendshipListener(
        onFriendApplicationListAdded: (List<V2TimFriendApplication> applicationList) {
          print('[SIMPLE_TEST] ✅ Bob received friend request! applicationList.length=${applicationList.length}');
          if (applicationList.isNotEmpty) {
            print('[SIMPLE_TEST] Application from: ${applicationList.first.userID}');
            print('[SIMPLE_TEST] Application message: ${applicationList.first.addWording}');
          }
          requestReceived = true;
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );
      
      bob.runWithInstance(() => TIMFriendshipManager.instance.addFriendListener(listener: listener));
      print('[SIMPLE_TEST] Listener added for Bob (instance_id=${bob.testInstanceHandle})');
      
      print('[SIMPLE_TEST] About to call addFriend...');
      print('[SIMPLE_TEST] bobToxId length: ${bobToxId.length}');
      print('[SIMPLE_TEST] bobToxId: $bobToxId');
      
      try {
        final addResult = await alice.runWithInstanceAsync(() async => TIMFriendshipManager.instance.addFriend(
          userID: bobToxId,
          addWording: 'Hello from simple test',
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
        ));
        
        print('[SIMPLE_TEST] addFriend returned!');
        print('[SIMPLE_TEST] addResult.code: ${addResult.code}');
        print('[SIMPLE_TEST] addResult.desc: ${addResult.desc}');
        
        expect(addResult.code, isNotNull, reason: 'addFriend should return a result code');
        
        if (addResult.code == 0) {
          print('[SIMPLE_TEST] ✅ addFriend succeeded!');
        } else {
          print('[SIMPLE_TEST] ⚠️ addFriend returned error code: ${addResult.code}, desc: ${addResult.desc}');
        }
        
        // Wait and check if Bob receives the friend request
        print('[SIMPLE_TEST] Waiting for Bob to receive friend request...');
        
        // Wait up to 60 seconds for friend request (callback or poll)
        const pollInterval = Duration(seconds: 2);
        const totalWait = Duration(seconds: 60);
        final deadline = DateTime.now().add(totalWait);
        try {
          while (DateTime.now().isBefore(deadline)) {
            if (completer.isCompleted || requestReceived) break;
            await completer.future.timeout(
              pollInterval,
              onTimeout: () {},
            );
          }
          if (!requestReceived) {
            // Poll Bob's application list as fallback
            print('[SIMPLE_TEST] Callback not received, polling Bob\'s friend application list...');
            while (DateTime.now().isBefore(deadline)) {
              final appListResult = await bob.runWithInstanceAsync(() async => TIMFriendshipManager.instance.getFriendApplicationList());
              if (appListResult.code == 0 &&
                  appListResult.data?.friendApplicationList != null &&
                  appListResult.data!.friendApplicationList!.isNotEmpty) {
                final alicePk = alice.getPublicKey();
                final fromAlice = appListResult.data!.friendApplicationList!.any((app) => app?.userID == alicePk);
                if (fromAlice) {
                  print('[SIMPLE_TEST] ✅ Found application from Alice in Bob\'s list (poll)');
                  requestReceived = true;
                  break;
                }
              }
              await Future.delayed(pollInterval);
            }
          }
          if (requestReceived) {
            print('[SIMPLE_TEST] ✅ Friend request was received by Bob!');
          } else {
            print('[SIMPLE_TEST] ❌ Friend request was NOT received by Bob after ${totalWait.inSeconds}s');
            final appListResult = await bob.runWithInstanceAsync(() async => TIMFriendshipManager.instance.getFriendApplicationList());
            if (appListResult.code == 0 && appListResult.data?.friendApplicationList != null && appListResult.data!.friendApplicationList!.isNotEmpty) {
              print('[SIMPLE_TEST] Bob\'s list has ${appListResult.data!.friendApplicationList!.length} application(s)');
            } else {
              print('[SIMPLE_TEST] Bob\'s application list is empty');
            }
          }
        } finally {
          bob.runWithInstance(() => TIMFriendshipManager.instance.removeFriendListener(listener: listener));
        }
      } catch (e, stackTrace) {
        print('[SIMPLE_TEST] ❌ Exception in addFriend: $e');
        print('[SIMPLE_TEST] Stack trace: $stackTrace');
        rethrow;
      }
      
      print('[SIMPLE_TEST] Test completed');
      print('========================================');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
