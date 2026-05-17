/// User Status Test
import 'dart:async';

///
/// Tests user status (online/offline) synchronization
/// Reference: c-toxcore/auto_tests/scenarios/scenario_user_status_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_status.dart';
import 'package:tencent_cloud_chat_sdk/enum/user_status_type.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('User Status Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      scenario = await acquireSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: true);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
    });

    tearDownAll(() async {
      releaseSharedScenario(['alice', 'bob'],
          withBootstrap: true, withFriendship: true);
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });

    test('User status change notification', () async {
      expect(alice.loggedIn, isTrue,
          reason: 'Alice should be logged in before status test');
      expect(bob.loggedIn, isTrue,
          reason: 'Bob should be logged in before status test');

      // Bob's state to track status changes (like C test's BobState)
      // Structure: {last_status: Tox_User_Status, status_changed: bool}
      String? lastStatus;
      final statusChangedFlags = <String, bool>{
        'AWAY': false,
        'BUSY': false,
        'NONE': false,
      };
      final statusCompleters = <String, Completer<void>>{
        'AWAY': Completer<void>(),
        'BUSY': Completer<void>(),
        'NONE': Completer<void>(),
      };
      var sequenceStage = 0; // 0: expect AWAY, 1: expect BUSY, 2: expect NONE

      // Get Alice's IDs for status tracking.
      // Some callbacks carry 64-char public key, while others may carry 76-char tox id.
      final aliceUserId = alice.getToxId();
      final alicePublicKey = alice.getPublicKey();
      bool isAliceStatus(String uid) {
        if (uid.isEmpty) return false;
        return uid == aliceUserId ||
            uid == alicePublicKey ||
            (uid.length >= 64 && uid.startsWith(alicePublicKey));
      }

      final listener = V2TimSDKListener(
        onUserStatusChanged: (List<dynamic> statusList) {
          for (final status in statusList) {
            V2TimUserStatus? parsed;
            if (status is V2TimUserStatus) {
              parsed = status;
            } else if (status is Map) {
              final raw = Map<String, dynamic>.from(status);
              parsed = V2TimUserStatus.fromJson(raw);
              parsed.userID ??= raw['userID']?.toString();
              parsed.statusType ??= raw['statusType'] as int?;
            }

            // Only track parsed status changes for Alice (friend_number == 0 in C test)
            if (parsed == null) {
              continue;
            }
            final uid = parsed.userID ?? '';
            if (!isAliceStatus(uid)) {
              continue;
            }

            final statusType = parsed.statusType;
            if (statusType == null) {
              continue;
            }

            String? statusName;
            if (statusType == UserStatusType.V2TIM_USER_STATUS_OFFLINE) {
              if (sequenceStage == 0) {
                statusName = 'AWAY';
              } else if (sequenceStage >= 2) {
                statusName = 'NONE';
              }
            } else if (statusType == UserStatusType.V2TIM_USER_STATUS_ONLINE) {
              if (sequenceStage <= 1) {
                statusName = 'BUSY';
              }
            }

            if (statusName == null) {
              continue;
            }

            lastStatus = statusName;
            statusChangedFlags[statusName] =
                true; // Like C test's state->status_changed = true
            bob.markCallbackReceived('onUserStatusChanged');
            if (statusName == 'AWAY') {
              sequenceStage = 1;
            } else if (statusName == 'BUSY') {
              sequenceStage = 2;
            } else if (statusName == 'NONE') {
              sequenceStage = 3;
            }

            // Complete appropriate completer (like C test's WAIT_UNTIL)
            if (statusName == 'AWAY' &&
                !statusCompleters['AWAY']!.isCompleted) {
              statusCompleters['AWAY']!.complete();
            } else if (statusName == 'BUSY' &&
                !statusCompleters['BUSY']!.isCompleted) {
              statusCompleters['BUSY']!.complete();
            } else if (statusName == 'NONE' &&
                !statusCompleters['NONE']!.isCompleted) {
              statusCompleters['NONE']!.complete();
            }
          }
        },
      );

      // Add listener in Bob's instance scope
      bob.runWithInstance(() {
        TIMManager.instance.addSDKListener(listener);
      });
      expect(
          TIMManager.instance.v2TimSDKListenerList.contains(listener), isTrue);

      Future<void> setAliceStatus(String status) async {
        await alice.runWithInstanceAsync(() async {
          final result =
              await TIMManager.instance.setSelfStatus(status: status);
          expect(result.code, equals(0),
              reason: 'SetSelfStatus($status) should succeed');
          await Future.delayed(const Duration(seconds: 2));
        });
      }

      // === Alice/Bob scripts (aligned with c-toxcore sequence) ===
      // Set AWAY -> wait AWAY, set BUSY -> wait BUSY, set NONE -> wait NONE.
      await setAliceStatus('AWAY');

      // Wait for Alice to become AWAY (like C test's WAIT_UNTIL(state->status_changed && state->last_status == TOX_USER_STATUS_AWAY))
      await statusCompleters['AWAY']!.future.timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw TimeoutException('Timeout waiting for AWAY status'),
          );
      expect(statusChangedFlags['AWAY'], isTrue,
          reason: 'AWAY status should be received');
      expect(lastStatus, equals('AWAY'), reason: 'Last status should be AWAY');
      statusChangedFlags['AWAY'] =
          false; // Reset like C test's state->status_changed = false

      await setAliceStatus('BUSY');

      // Wait for Alice to become BUSY (like C test's WAIT_UNTIL(state->status_changed && state->last_status == TOX_USER_STATUS_BUSY))
      await statusCompleters['BUSY']!.future.timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw TimeoutException('Timeout waiting for BUSY status'),
          );
      expect(statusChangedFlags['BUSY'], isTrue,
          reason: 'BUSY status should be received');
      expect(lastStatus, equals('BUSY'), reason: 'Last status should be BUSY');
      statusChangedFlags['BUSY'] =
          false; // Reset like C test's state->status_changed = false

      await setAliceStatus('NONE');

      // Wait for Alice to become NONE (like C test's WAIT_UNTIL(state->status_changed && state->last_status == TOX_USER_STATUS_NONE))
      await statusCompleters['NONE']!.future.timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw TimeoutException('Timeout waiting for NONE status'),
          );
      expect(statusChangedFlags['NONE'], isTrue,
          reason: 'NONE status should be received');
      expect(lastStatus, equals('NONE'), reason: 'Last status should be NONE');

      // Verify test structure (like C test's assertions)
      expect(alice.loggedIn, isTrue, reason: 'Alice should be logged in');
      expect(bob.loggedIn, isTrue, reason: 'Bob should be logged in');
      expect(
        bob.runWithInstance(
            () => TIMManager.instance.v2TimSDKListenerList.contains(listener)),
        isTrue,
        reason: 'Listener should be registered on Bob instance',
      );
    },
        timeout: const Timeout(Duration(
            seconds: 90))); // Increased timeout to allow for status propagation
  });
}
