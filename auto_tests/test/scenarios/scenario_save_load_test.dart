/// Save Load Test — virtual-clock variant
///
/// Mirrors scenario_save_load_test.dart 1:1 but enables
/// VirtualClock.enableEarly() before any TestNode is created so the
/// V2TIMManagerImpl constructor inherits test_mode and InitSDK skips
/// event_thread.
///
/// Single-node test: init/login/uninit bookkeeping flips synchronously from
/// Dart's POV; no virtual time advance needed.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Save Load Tests', () {
    late TestNode node;
    final testDir = getTestDataDir();

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* node creation so V2TIMManagerImpl
      // constructor inherits test_mode and InitSDK skips event_thread.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      node = await createTestNode('test_node');
    });

    tearDownAll(() async {
      await node.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared node
    });

    test('Save and load state', () async {
      final dataDir = await testDir;

      // Initialize SDK with save path
      await node.initSDK(initPath: dataDir);
      await node.login();

      // Logout
      await node.logout();

      // Uninitialize
      await node.unInitSDK();

      // Reinitialize and login
      await node.initSDK(initPath: dataDir);
      await node.login();

      // Verify state is restored.
      final loginUser =
          node.runWithInstance(() => TIMManager.instance.getLoginUser());
      expect(loginUser, equals(node.userId));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Friend list persistence', () async {
      final dataDir = await testDir;

      await node.initSDK(initPath: dataDir);
      await node.login();

      // Get friend list (per-instance; use node context)
      final friendListResult = await node.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendList());
      expect(friendListResult.code, equals(0));

      // Save state (logout/uninit)
      await node.logout();
      await node.unInitSDK();

      // Reload state
      await node.initSDK(initPath: dataDir);
      await node.login();

      // Verify friend list is still accessible (per-instance; use node context)
      final friendListResult2 = await node.runWithInstanceAsync(() async =>
          TIMFriendshipManager.instance.getFriendList());
      expect(friendListResult2.code, equals(0));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
