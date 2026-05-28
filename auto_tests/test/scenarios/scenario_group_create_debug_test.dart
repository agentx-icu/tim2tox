// Group Create Debug Test — virtual-clock variant
//
// Mirrors scenario_group_create_debug_test.dart 1:1 but drives the harness via
// the virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// All sub-tests are single-instance createGroup probes; no invite-retry is
// required.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

/// Max time we allow createGroup to take; fail fast instead of hanging until test timeout.
const _createGroupStepTimeout = Duration(seconds: 20);

void main() {
  group('Group Create Debug Tests', () {
    late TestScenario scenario;
    late TestNode alice;

    setUpAll(() async {
      await setupTestEnvironment();
      // Need at least 2 nodes for configureLocalBootstrap (single node cannot form DHT)
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      // Enable test mode BEFORE login so event_thread never starts.
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([alice.login(), bob.login()]);

      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'alice and bob logged in',
      );

      await configureLocalBootstrapVirtual(scenario);

      try {
        await waitForConnectionVirtual(scenario, alice,
            timeout: const Duration(seconds: 15));
      } catch (e) {
        print('[GroupCreateDebug] setUpAll: waitForConnection failed: $e');
        rethrow;
      }
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Debug: Create group with minimal parameters', () async {
      print('\n=== Debug: Create Group Test ===');
      print('Step 1: Checking SDK initialization (alice instance)...');

      // Check if SDK is initialized for this test's instance (alice = instance 1)
      final loginStatus =
          alice.runWithInstance(() => TIMManager.instance.getLoginStatus());
      print('Login status: $loginStatus (1=logged in, 0=not logged in)');
      expect(loginStatus, equals(1), reason: 'User should be logged in');

      print(
          'Step 2: Attempting to create group (timeout: $_createGroupStepTimeout)...');
      print('Group type: group, group name: Test Group');

      final createResult = await alice.runWithInstanceAsync(() async {
        return await TIMGroupManager.instance.createGroup(
          groupType: 'group',
          groupName: 'Test Group',
          groupID: '',
        );
      }).timeout(
        _createGroupStepTimeout,
        onTimeout: () => throw TimeoutException(
          'CreateGroup did not complete within $_createGroupStepTimeout (blocking point: createGroup)',
        ),
      );

      print(
          'Step 3: CreateGroup result: code=${createResult.code}, desc=${createResult.desc}, data=${createResult.data}');

      if (createResult.code != 0) {
        print(
            '\n❌ CreateGroup FAILED with code ${createResult.code}: ${createResult.desc}');
        print(
            'Possible causes: Tox not init, network not connected (ANNOUNCE), name too long/empty, INIT/STATE error.');
      } else {
        print('\n✅ CreateGroup SUCCESS, group ID: ${createResult.data}');
      }

      expect(createResult.code, equals(0),
          reason:
              'createGroup failed: code=${createResult.code}, desc=${createResult.desc}');
      expect(createResult.data, isNotNull,
          reason: 'Group ID should not be null');
      expect(createResult.data, isNotEmpty,
          reason: 'Group ID should not be empty');
    }, timeout: const Timeout(Duration(seconds: 35)));

    test('Debug: Create group with different group types', () async {
      print('\n=== Debug: Create Group with Different Types ===');

      print(
          'Test 1: Creating group type "group" (timeout: $_createGroupStepTimeout)');
      final groupResult = await alice.runWithInstanceAsync(() async {
        return await TIMGroupManager.instance.createGroup(
          groupType: 'group',
          groupName: 'New API Group',
          groupID: '',
        );
      }).timeout(
        _createGroupStepTimeout,
        onTimeout: () => throw TimeoutException(
            'CreateGroup(group) did not complete within $_createGroupStepTimeout'),
      );
      print('Result: code=${groupResult.code}, desc=${groupResult.desc}');

      print(
          'Test 2: Creating group type "Meeting" (timeout: $_createGroupStepTimeout)');
      final meetingResult = await alice.runWithInstanceAsync(() async {
        return await TIMGroupManager.instance.createGroup(
          groupType: 'Meeting',
          groupName: 'Old API Conference',
          groupID: '',
        );
      }).timeout(
        _createGroupStepTimeout,
        onTimeout: () => throw TimeoutException(
            'CreateGroup(Meeting) did not complete within $_createGroupStepTimeout'),
      );
      print('Result: code=${meetingResult.code}, desc=${meetingResult.desc}');

      expect(groupResult.code, equals(0),
          reason:
              'createGroup(group) failed: code=${groupResult.code}, desc=${groupResult.desc}');
      expect(meetingResult.code, equals(0),
          reason:
              'createGroup(Meeting) failed: code=${meetingResult.code}, desc=${meetingResult.desc}');
    }, timeout: const Timeout(Duration(seconds: 50)));

    test('Debug: Create group with empty name', () async {
      print('\n=== Debug: Create Group with Empty Name ===');

      final createResult = await alice.runWithInstanceAsync(() async {
        return await TIMGroupManager.instance.createGroup(
          groupType: 'group',
          groupName: '',
          groupID: '',
        );
      }).timeout(
        _createGroupStepTimeout,
        onTimeout: () => throw TimeoutException(
            'CreateGroup(empty name) did not complete within $_createGroupStepTimeout'),
      );

      print('Result: code=${createResult.code}, desc=${createResult.desc}');
      if (createResult.code != 0) {
        print('Empty name failed or used default: ${createResult.desc}');
      } else {
        print('Empty name was accepted, using default name');
      }
    }, timeout: const Timeout(Duration(seconds: 35)));

    test('Debug: Check connection status before creating group', () async {
      print('\n=== Debug: Check Connection Before Create ===');

      final loginStatus =
          alice.runWithInstance(() => TIMManager.instance.getLoginStatus());
      print('Login status: $loginStatus (1=logged in, 0=not logged in)');

      print(
          'Attempting to create group (timeout: $_createGroupStepTimeout)...');
      final createResult = await alice.runWithInstanceAsync(() async {
        return await TIMGroupManager.instance.createGroup(
          groupType: 'group',
          groupName: 'Test After Wait',
          groupID: '',
        );
      }).timeout(
        _createGroupStepTimeout,
        onTimeout: () => throw TimeoutException(
            'CreateGroup did not complete within $_createGroupStepTimeout'),
      );

      print('Result: code=${createResult.code}, desc=${createResult.desc}');
      expect(createResult.code, equals(0),
          reason:
              'createGroup failed after wait: code=${createResult.code}, desc=${createResult.desc}');
    }, timeout: const Timeout(Duration(seconds: 35)));
  });
}
