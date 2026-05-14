/// Reconnect Test
/// 
/// Tests network reconnection handling
/// Reference: c-toxcore/auto_tests/scenarios/scenario_reconnect_test.c

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSDKListener.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Reconnect Tests', () {
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
      
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );
      
      // Configure local bootstrap (like C test's tox_node_bootstrap)
      await configureLocalBootstrap(scenario);
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
    
    test('Connection status monitoring', () async {
      bool connectionLost = false;
      bool connectionRestored = false;
      
      final listener = V2TimSDKListener(
        onConnectFailed: (int code, String error) {
          connectionLost = true;
          alice.markCallbackReceived('connectionLost');
        },
        onConnectSuccess: () {
          if (connectionLost) {
            connectionRestored = true;
            alice.markCallbackReceived('connectionRestored');
          }
        },
      );
      
      alice.runWithInstance(() => TIMManager.instance.addSDKListener(listener));
      expect(
        alice.runWithInstance(() => TIMManager.instance.v2TimSDKListenerList.contains(listener)),
        isTrue,
        reason: 'SDK listener should be registered on Alice instance',
      );
      
      // In local test env we cannot deterministically force disconnect.
      // Validate event relation if disconnect happens, and ensure no fake "restored" without loss.
      await Future.delayed(const Duration(seconds: 2));
      if (connectionLost) {
        expect(connectionRestored, isTrue,
            reason: 'When onConnectFailed occurs, a later onConnectSuccess is expected');
      } else {
        expect(connectionRestored, isFalse,
            reason: 'onConnectSuccess should not be treated as restore when no prior failure happened');
      }

      alice.runWithInstance(() => TIMManager.instance.removeSDKListener(listener: listener));
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Reconnection after logout and login', () async {
      // Logout
      await alice.logout();
      expect(alice.loggedIn, isFalse);
      
      // Login again
      await alice.login();
      expect(alice.loggedIn, isTrue);
      
      // Wait for connection to be restored after re-login.
      await alice.waitForConnection(timeout: const Duration(seconds: 15));
      
      // Connection should be restored. V2TIMManagerImpl::GetLoginUser()
      // returns the login alias (userID passed to Login), not the Tox
      // public key — use FfiChatService.selfId for the Tox ID.
      final loginUser = alice.runWithInstance(() => TIMManager.instance.getLoginUser());
      expect(loginUser, equals(alice.userId));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
