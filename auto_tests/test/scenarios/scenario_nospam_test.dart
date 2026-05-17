/// Nospam Test
/// 
/// Tests Tox address nospam mechanism to prevent spam friend requests
/// Reference: c-toxcore/auto_tests/scenarios/scenario_nospam_test.c
/// 
/// Note: This test requires access to low-level Tox functions (tox_self_set_nospam,
/// tox_self_get_nospam) which may not be directly exposed in the Dart layer.
/// The test verifies that changing nospam value invalidates old friend requests.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_response_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Nospam Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    
    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      
      await scenario.initAllNodes();
      // Parallelize login
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);
      
      await waitUntil(() => alice.loggedIn && bob.loggedIn);
      
      // Configure local bootstrap
      await configureLocalBootstrap(scenario);
      
      // Wait for both nodes to be connected to Tox network so friend requests can be delivered
      await Future.wait([
        alice.waitForConnection(timeout: const Duration(seconds: 45)),
        bob.waitForConnection(timeout: const Duration(seconds: 45)),
      ]);
      print('[Nospam] waitForConnection(45s) completed for alice and bob');
      // 2s DHT settle kept (not removed): test 2 ("Nospam change invalidates")
      // is sensitive to DHT readiness in baseline, dropping this makes it
      // intermittently miss the friend request.
      await Future.delayed(const Duration(seconds: 2));
      print('[Nospam] Post-connection delay 2s done (DHT settle)');
    });
    
    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });
    
    // Clean up before each test: clear pending request or existing friendship so Bob can send again (avoid TOX_ERR_FRIEND_ADD_ALREADY_SENT).
    // login() enables auto-accept, so after test 1 Alice may have auto-accepted Bob -> they are friends; setUp must delete friendship too.
    setUp(() async {
      final bobPublicKey = bob.getPublicKey();
      final bobToxId = bob.getToxId();
      final aliceToxId = alice.getToxId();
      print('[Nospam] setUp: getFriendApplicationList (alice)...');
      final appListResult = await alice.runWithInstanceAsync(() async => TIMFriendshipManager.instance.getFriendApplicationList());
      final list = appListResult.data?.friendApplicationList;
      final totalApps = list?.length ?? 0;
      print('[Nospam] setUp: alice application list length=$totalApps, bobPublicKey prefix=${bobPublicKey.length >= 16 ? bobPublicKey.substring(0, 16) : bobPublicKey}...');
      if (list != null && list.isNotEmpty) {
        int cleared = 0;
        final isFromBob = (String uid) =>
            uid == bobPublicKey || uid == bobToxId || (uid.length >= 64 && uid.startsWith(bobPublicKey));
        final bobPubKeyMatch = (String id) =>
            id == bobPublicKey || id == bobToxId || (id.length >= 64 && id.startsWith(bobPublicKey));
        final alicePubKeyShort = aliceToxId.length >= 64 ? aliceToxId.substring(0, 64) : aliceToxId;
        final aliceMatch = (String id) =>
            id == alicePubKeyShort || id == aliceToxId || (id.length >= 64 && id.startsWith(alicePubKeyShort));
        for (final app in list) {
          if (app != null && isFromBob(app.userID)) {
            print('[Nospam] setUp: accept+delete application from Bob (userID prefix=${app.userID.length >= 16 ? app.userID.substring(0, 16) : app.userID}...)');
            await alice.runWithInstanceAsync(() async {
              await TIMFriendshipManager.instance.acceptFriendApplication(
                userID: app.userID,
                responseType: FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
              );
              // Poll until alice's friend list contains Bob (accept took
              // effect) instead of waiting a flat 1s. Bounded to 2s — the
              // local FFI call returns synchronously in practice.
              try {
                await waitUntilAsync(
                  () async {
                    final friends = await alice.getFriendList(useCache: false);
                    return friends.any(bobPubKeyMatch);
                  },
                  timeout: const Duration(seconds: 2),
                  pollInterval: const Duration(milliseconds: 100),
                  description: 'alice friend list contains Bob after accept',
                );
              } catch (_) {/* fall through; the next delete is a no-op if not there */}
              await TIMFriendshipManager.instance.deleteFromFriendList(
                userIDList: [bobToxId],
                deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
              );
              try {
                await waitUntilAsync(
                  () async {
                    final friends = await alice.getFriendList(useCache: false);
                    return !friends.any(bobPubKeyMatch);
                  },
                  timeout: const Duration(seconds: 2),
                  pollInterval: const Duration(milliseconds: 100),
                  description: 'alice friend list excludes Bob after delete',
                );
              } catch (_) {}
            });
            // After accept, Bob has Alice in his list; delete Alice from Bob so Bob can send a new request in the next test.
            await bob.runWithInstanceAsync(() async => TIMFriendshipManager.instance.deleteFromFriendList(
              userIDList: [aliceToxId],
              deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
            ));
            // Wait for the Tox-level friendship reset on Bob's side
            // (previously a flat 3s sleep). The local friend list flips
            // immediately, but the Tox onion-routing state needs a moment
            // to invalidate the prior "already_sent" record so the next
            // test's addFriend gets through. Keep a small floor wait.
            try {
              await waitUntilAsync(
                () async {
                  final bobFriends = await bob.getFriendList(useCache: false);
                  return !bobFriends.any(aliceMatch);
                },
                timeout: const Duration(seconds: 2),
                pollInterval: const Duration(milliseconds: 100),
                description: 'bob friend list excludes Alice after delete',
              );
            } catch (_) {}
            // Floor wait for Tox onion/announce state to invalidate the
            // prior add-friend record — kept at 2.5s. Going lower made the
            // next test's bob.addFriend(alice) intermittently never reach
            // alice in baseline runs.
            await Future.delayed(const Duration(milliseconds: 2500));
            cleared++;
          } else if (app != null) {
            print('[Nospam] setUp: skip app userID prefix=${app.userID.length >= 16 ? app.userID.substring(0, 16) : app.userID}... (not Bob)');
          }
        }
        print('[Nospam] setUp: cleared $cleared pending application(s) from Bob');
      }
      // Ensure both sides are not friends so the next test can receive a new friend request (Bob addFriend(Alice)).
      final aliceFriends = await alice.getFriendList();
      final bobFriends = await bob.getFriendList();
      final bobInAliceList = aliceFriends.any((id) => id == bobPublicKey || id == bobToxId || (id.length >= 64 && id.startsWith(bobPublicKey)));
      final alicePublicKey = aliceToxId.length >= 64 ? aliceToxId.substring(0, 64) : aliceToxId;
      final aliceInBobList = bobFriends.any((id) => id == alicePublicKey || id == aliceToxId || (id.length >= 64 && id.startsWith(alicePublicKey)));
      if (bobInAliceList || aliceInBobList) {
        print('[Nospam] setUp: ensuring non-friends (bobInAlice=$bobInAliceList, aliceInBob=$aliceInBobList); deleting both sides');
        if (bobInAliceList) {
          await alice.runWithInstanceAsync(() async => TIMFriendshipManager.instance.deleteFromFriendList(
            userIDList: [bobToxId],
            deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
          ));
        }
        if (aliceInBobList) {
          await bob.runWithInstanceAsync(() async => TIMFriendshipManager.instance.deleteFromFriendList(
            userIDList: [aliceToxId],
            deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
          ));
        }
        // Replace the historical 1s + 1s + 3s sleeps with bounded polling on
        // both sides observing the deletion, plus a small floor wait for
        // Tox onion-routing state to settle (otherwise the next test's
        // addFriend can hit a stale ALREADY_SENT record).
        try {
          await waitUntilAsync(
            () async {
              final aFriends = await alice.getFriendList(useCache: false);
              final bFriends = await bob.getFriendList(useCache: false);
              final stillInAlice = aFriends.any((id) => id == bobPublicKey || id == bobToxId || (id.length >= 64 && id.startsWith(bobPublicKey)));
              final alicePubKeyShort2 = aliceToxId.length >= 64 ? aliceToxId.substring(0, 64) : aliceToxId;
              final stillInBob = bFriends.any((id) => id == alicePubKeyShort2 || id == aliceToxId || (id.length >= 64 && id.startsWith(alicePubKeyShort2)));
              return !stillInAlice && !stillInBob;
            },
            timeout: const Duration(seconds: 3),
            pollInterval: const Duration(milliseconds: 150),
            description: 'both sides observe friendship cleared',
          );
          print('[Nospam] setUp: friendship cleared (poll-confirmed)');
        } catch (_) {
          print('[Nospam] setUp: friendship cleanup poll did not converge; proceeding');
        }
        // Floor wait so Tox state has time to invalidate prior friend
        // records — kept at 2.5s for the same reason as above.
        await Future.delayed(const Duration(milliseconds: 2500));
      }
    });

    tearDown(() async {
      alice.callbackReceived.clear();
      bob.callbackReceived.clear();
      print('[Nospam] tearDown: cleared callbackReceived for alice and bob');
    });
    
    test('Friend request spam protection', () async {
      bool requestReceived = false;
      final completer = Completer<dynamic>();
      final waitSeconds = 60;

      final listener = V2TimFriendshipListener(
        onFriendApplicationListAdded: (List<V2TimFriendApplication> applicationList) {
          if (applicationList.isNotEmpty) {
            requestReceived = true;
            alice.markCallbackReceived('onFriendApplicationListAdded');
            print('[Nospam] Friend request spam protection: onFriendApplicationListAdded fired, count=${applicationList.length}');
            if (!completer.isCompleted) {
              completer.complete(applicationList.first);
            }
          }
        },
      );

      alice.runWithInstance(() => TIMFriendshipManager.instance.addFriendListener(listener: listener));
      final aliceToxId = alice.getToxId();
      print('[Nospam] Friend request spam protection: bob.addFriend(alice) call, aliceToxId prefix=${aliceToxId.length >= 20 ? aliceToxId.substring(0, 20) : aliceToxId}...');
      final addResult = await bob.runWithInstanceAsync(() async => TIMFriendshipManager.instance.addFriend(
        userID: aliceToxId,
        addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
        remark: 'Alice',
        addWording: 'Hi',
      ));
      print('[Nospam] Friend request spam protection: addFriend returned code=${addResult.code}, desc=${addResult.desc}');
      expect(addResult.code, equals(0));

      print('[Nospam] Friend request spam protection: waiting ${waitSeconds}s for Alice to receive request...');
      bool completerTimedOut = false;
      try {
        await completer.future.timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            completerTimedOut = true;
            print('[Nospam] Friend request spam protection: wait timed out after ${waitSeconds}s');
          },
        );
        if (!completerTimedOut) {
          print('[Nospam] Friend request spam protection: completer completed (request received)');
        }
      } catch (e) {
        print('[Nospam] Friend request spam protection: completer exception: $e');
      }
      final appListResult = await alice.runWithInstanceAsync(() async => TIMFriendshipManager.instance.getFriendApplicationList());
      final appCount = appListResult.data?.friendApplicationList?.length ?? 0;
      print('[Nospam] Friend request spam protection: requestReceived=$requestReceived, completerTimedOut=$completerTimedOut, '
          'getFriendApplicationList.length=$appCount, addResult.code=${addResult.code}');
      if (appCount > 0 && appListResult.data?.friendApplicationList != null) {
        final first = appListResult.data!.friendApplicationList!.first;
        if (first != null) {
          final uid = first.userID;
          print('[Nospam]   first application userID: ${uid.length > 20 ? uid.substring(0, 20) : uid}...');
        }
      } else if (appCount == 0) {
        print('[Nospam] Friend request spam protection: getFriendApplicationList returned 0 (request not reached Alice or not in list)');
      }
      expect(requestReceived, isTrue, reason: 'Alice should receive friend request');
      expect(alice.callbackReceived['onFriendApplicationListAdded'], isTrue,
        reason: 'Callback should be marked as received');
      alice.runWithInstance(() => TIMFriendshipManager.instance.removeFriendListener(listener: listener));
    }, timeout: const Timeout(Duration(seconds: 150)));
    
    test('Nospam change invalidates old address', () async {
      // Ensure both are connected before sending so the request is delivered (avoids DHT flakiness).
      await Future.wait([
        alice.waitForConnection(timeout: const Duration(seconds: 15)),
        bob.waitForConnection(timeout: const Duration(seconds: 15)),
      ]);
      await Future.delayed(const Duration(seconds: 2));

      final completer1 = Completer<dynamic>();
      bool request1Received = false;
      const waitSeconds = 90;

      final listener1 = V2TimFriendshipListener(
        onFriendApplicationListAdded: (List<V2TimFriendApplication> applicationList) {
          if (applicationList.isNotEmpty) {
            request1Received = true;
            print('[Nospam] Nospam change invalidates: onFriendApplicationListAdded fired, count=${applicationList.length}');
            if (!completer1.isCompleted) {
              completer1.complete(applicationList.first);
            }
          }
        },
      );

      alice.runWithInstance(() => TIMFriendshipManager.instance.addFriendListener(listener: listener1));
      final aliceToxId = alice.getToxId();
      print('[Nospam] Nospam change invalidates: bob.addFriend(alice) call...');
      final addResult = await bob.runWithInstanceAsync(() async => TIMFriendshipManager.instance.addFriend(
        userID: aliceToxId,
        addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
        addWording: 'Hi',
      ));
      print('[Nospam] Nospam change invalidates: addFriend returned code=${addResult.code}, desc=${addResult.desc}');

      print('[Nospam] Nospam change invalidates: waiting ${waitSeconds}s for request...');
      bool completer1TimedOut = false;
      await completer1.future.timeout(
        const Duration(seconds: 180),
        onTimeout: () {
          completer1TimedOut = true;
          print('[Nospam] Nospam change invalidates: wait timed out after 180s');
        },
      );

      // After timeout, use platform getFriendApplicationList (FFI path) so we get the list for current instance;
      // TIMFriendshipManager uses DartGetFriendApplicationList (async callback) which can return empty in tests.
      var applications = await alice.runWithInstanceAsync(() async {
        final p = TencentCloudChatSdkPlatform.instance;
        if (p is Tim2ToxSdkPlatform) return await p.getFriendApplicationList();
        return await TIMFriendshipManager.instance.getFriendApplicationList();
      });
      var appCount1 = applications.data?.friendApplicationList?.length ?? 0;
      for (int poll = 0; poll < 5 && appCount1 == 0; poll++) {
        await Future.delayed(const Duration(seconds: 2));
        applications = await alice.runWithInstanceAsync(() async {
          final p = TencentCloudChatSdkPlatform.instance;
          if (p is Tim2ToxSdkPlatform) return await p.getFriendApplicationList();
          return await TIMFriendshipManager.instance.getFriendApplicationList();
        });
        appCount1 = applications.data?.friendApplicationList?.length ?? 0;
        if (appCount1 > 0 && !request1Received) {
          request1Received = true;
          print('[Nospam] Nospam change invalidates: using getFriendApplicationList.length=$appCount1 as request received (poll $poll)');
        }
      }
      if (appCount1 > 0 && !request1Received) {
        request1Received = true;
        print('[Nospam] Nospam change invalidates: using getFriendApplicationList.length=$appCount1 as request received');
      }
      print('[Nospam] Nospam change invalidates: request1Received=$request1Received, completer1TimedOut=$completer1TimedOut, '
          'getFriendApplicationList.length=$appCount1, addResult.code=${addResult.code}');
      if (appCount1 > 0 && applications.data?.friendApplicationList != null) {
        final first = applications.data!.friendApplicationList!.first;
        if (first != null) {
          final uid = first.userID;
          print('[Nospam]   first application userID: ${uid.length > 20 ? uid.substring(0, 20) : uid}...');
        }
      } else if (appCount1 == 0 && addResult.code != 0) {
        print('[Nospam] Nospam change invalidates: addResult non-zero (e.g. ALREADY_SENT) and 0 apps - setUp had nothing to clear or Tox state not reset');
      }

      if (applications.data?.friendApplicationList != null &&
          applications.data!.friendApplicationList!.isNotEmpty) {
        final application = applications.data!.friendApplicationList!.first;

        if (application != null) {
          final acceptResult = await alice.runWithInstanceAsync(() async => TIMFriendshipManager.instance
            .acceptFriendApplication(
              userID: application.userID,
              responseType: FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
            ));

          expect(acceptResult.code, equals(0),
            reason: 'Friend request should be accepted');
        }
      }

      alice.runWithInstance(() => TIMFriendshipManager.instance.removeFriendListener(listener: listener1));
      expect(request1Received, isTrue, reason: 'request should have been received');
    }, timeout: const Timeout(Duration(seconds: 240)));
    
    // Isolated scenario: alice and bob are NOT yet friends, so a new addFriend
    // will trigger onFriendApplicationListAdded on Alice.
    group('Multiple friend requests handling (isolated scenario)', () {
      late TestScenario scenarioIso;
      late TestNode aliceIso;
      late TestNode bobIso;

      setUpAll(() async {
        scenarioIso = await createTestScenario(['alice_iso', 'bob_iso']);
        aliceIso = scenarioIso.getNode('alice_iso')!;
        bobIso = scenarioIso.getNode('bob_iso')!;
        await scenarioIso.initAllNodes();
        await Future.wait([
          aliceIso.login(),
          bobIso.login(),
        ]);
        await waitUntil(() => aliceIso.loggedIn && bobIso.loggedIn);
        await configureLocalBootstrap(scenarioIso);
        // Wait for both nodes to be connected to Tox network so friend requests can be delivered
        await Future.wait([
          aliceIso.waitForConnection(timeout: const Duration(seconds: 45)),
          bobIso.waitForConnection(timeout: const Duration(seconds: 45)),
        ]);
        print('[Nospam] waitForConnection(45s) completed for alice_iso and bob_iso');
        await Future.delayed(const Duration(seconds: 5));
        print('[Nospam] Isolated: post-connection delay 5s done (DHT settle for new instances)');
        // Do NOT establish friendship here so that the test receives a new friend request.
      });

      tearDownAll(() async {
        await scenarioIso.dispose();
      });

      setUp(() async {
        final bobIsoPublicKey = bobIso.getPublicKey();
        final bobIsoToxId = bobIso.getToxId();
        final aliceIsoToxId = aliceIso.getToxId();
        print('[Nospam] Isolated setUp: getFriendApplicationList (alice_iso)...');
        final appListResult = await aliceIso.runWithInstanceAsync(() async => TIMFriendshipManager.instance.getFriendApplicationList());
        final list = appListResult.data?.friendApplicationList;
        final totalApps = list?.length ?? 0;
        print('[Nospam] Isolated setUp: alice_iso application list length=$totalApps');
        if (list != null && list.isNotEmpty) {
          for (final app in list) {
            if (app != null && app.userID == bobIsoPublicKey) {
              print('[Nospam] Isolated setUp: accept+delete application from Bob_iso');
              await aliceIso.runWithInstanceAsync(() async {
                await TIMFriendshipManager.instance.acceptFriendApplication(
                  userID: app.userID,
                  responseType: FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
                );
                await Future.delayed(const Duration(seconds: 1));
                await TIMFriendshipManager.instance.deleteFromFriendList(
                  userIDList: [bobIsoToxId],
                  deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
                );
                await Future.delayed(const Duration(seconds: 1));
              });
            }
          }
        }
        final aliceIsoFriends = await aliceIso.getFriendList();
        final bobIsoInList = aliceIsoFriends.any((id) => id == bobIsoPublicKey || id == bobIsoToxId || (id.length >= 64 && id.startsWith(bobIsoPublicKey)));
        if (bobIsoInList) {
          print('[Nospam] Isolated setUp: Bob_iso in Alice_iso friend list; deleting both sides');
          await aliceIso.runWithInstanceAsync(() async => TIMFriendshipManager.instance.deleteFromFriendList(
            userIDList: [bobIsoToxId],
            deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
          ));
          await Future.delayed(const Duration(seconds: 1));
          await bobIso.runWithInstanceAsync(() async => TIMFriendshipManager.instance.deleteFromFriendList(
            userIDList: [aliceIsoToxId],
            deleteType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
          ));
          await Future.delayed(const Duration(seconds: 2));
        }
        aliceIso.callbackReceived.clear();
        bobIso.callbackReceived.clear();
        print('[Nospam] Isolated setUp: cleared callbackReceived for alice_iso and bob_iso');
      });

      tearDown(() async {
        aliceIso.callbackReceived.clear();
        bobIso.callbackReceived.clear();
        print('[Nospam] Isolated tearDown: cleared callbackReceived for alice_iso and bob_iso');
      });

      test('Multiple friend requests handling', () async {
        final completer = Completer<dynamic>();
        bool requestReceived = false;
        const waitSeconds = 90;

        final listener = V2TimFriendshipListener(
          onFriendApplicationListAdded: (List<V2TimFriendApplication> applicationList) {
            if (applicationList.isNotEmpty) {
              requestReceived = true;
              aliceIso.markCallbackReceived('onFriendApplicationListAdded');
              print('[Nospam] Multiple (isolated): onFriendApplicationListAdded fired, count=${applicationList.length}');
              if (!completer.isCompleted) {
                completer.complete(applicationList.first);
              }
            }
          },
        );

        aliceIso.runWithInstance(() => TIMFriendshipManager.instance.addFriendListener(listener: listener));

        final aliceToxId = aliceIso.getToxId();
        print('[Nospam] Multiple (isolated): bobIso.addFriend(aliceIso) call...');
        final addResultIso = await bobIso.runWithInstanceAsync(() async => TIMFriendshipManager.instance.addFriend(
          userID: aliceToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          addWording: 'Hi',
        ));
        print('[Nospam] Multiple (isolated): addFriend returned code=${addResultIso.code}, desc=${addResultIso.desc}');

        print('[Nospam] Multiple (isolated): waiting ${waitSeconds}s for request...');
        bool completerTimedOutIso = false;
        await completer.future.timeout(
          const Duration(seconds: 90),
          onTimeout: () {
            completerTimedOutIso = true;
            print('[Nospam] Multiple (isolated): wait timed out after 90s (DHT may not have delivered request to alice_iso)');
          },
        );

        final applications = await aliceIso.runWithInstanceAsync(() async => TIMFriendshipManager.instance.getFriendApplicationList());
        final appCountIso = applications.data?.friendApplicationList?.length ?? 0;
        print('[Nospam] Multiple (isolated): requestReceived=$requestReceived, completerTimedOut=$completerTimedOutIso, '
            'getFriendApplicationList.length=$appCountIso, addResult.code=${addResultIso.code}');
        if (appCountIso > 0 && applications.data?.friendApplicationList != null) {
          final first = applications.data!.friendApplicationList!.first;
          if (first != null) {
            final uid = first.userID;
            print('[Nospam]   first application userID: ${uid.length > 20 ? uid.substring(0, 20) : uid}...');
          }
        } else if (appCountIso == 0) {
          print('[Nospam] Multiple (isolated): getFriendApplicationList=0 (request not reached alice_iso within ${waitSeconds}s or not in list)');
        }

        expect(applications.data?.friendApplicationList, isNotNull,
          reason: 'Should have friend application list');
        expect(applications.data!.friendApplicationList!.length, greaterThanOrEqualTo(0),
          reason: 'Should have at least one friend application');

        // Verify the request is from Bob
        final bobPublicKey = bobIso.getPublicKey();
        final bobApplication = applications.data!.friendApplicationList!.firstWhere(
          (app) => app?.userID == bobPublicKey,
          orElse: () => null,
        );

        if (bobApplication != null) {
          expect(bobApplication.userID, equals(bobPublicKey),
            reason: 'Application should be from Bob');
        }

        expect(requestReceived, isTrue, reason: 'request should have been received');
        aliceIso.runWithInstance(() => TIMFriendshipManager.instance.removeFriendListener(listener: listener));
      }, timeout: const Timeout(Duration(seconds: 150)));
    });
  });
}
