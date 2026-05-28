/// Login/Logout Test — virtual-clock variant
///
/// Mirrors scenario_login_test.dart 1:1 but enables VirtualClock.enableEarly()
/// before any TestNode is created so the V2TIMManagerImpl constructor inherits
/// test_mode and InitSDK never spawns event_thread.
///
/// Single-node test: login/logout bookkeeping flags flip synchronously from
/// Dart's POV; no virtual time advance needed.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Login/Logout Tests', () {
    late TestNode node;

    // Single-node test: no peer to connect to, so the default 10s DHT-connect
    // wait inside TestNode.login() always times out. Shorten the per-login
    // timeout aggressively — login state flags are set before the connect
    // poll begins, and that's all this test verifies.
    const fastLoginTimeout = Duration(milliseconds: 500);

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* node creation so V2TIMManagerImpl
      // constructor inherits test_mode and InitSDK skips event_thread.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      node = await createTestNode('test_node');
      await node.initSDK();
    });

    tearDownAll(() async {
      await node.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Ensure node is logged out before each test (except first test which expects logged out state)
      // This ensures test isolation
      if (node.loggedIn) {
        await node.logout();
      }
    });

    test('Normal login flow', () async {
      await node.login(timeout: fastLoginTimeout);
      expect(node.loggedIn, isTrue);

      // V2TIMManagerImpl::GetLoginUser() returns `login_user_alias_`, the
      // userID passed at Login(). It is NOT the Tox public key — for that
      // use FfiChatService.selfId (which is what toxee itself uses).
      final loginUser = node.runWithInstance(() => TIMManager.instance.getLoginUser());
      expect(loginUser, equals(node.userId));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Login state verification', () async {
      expect(node.loggedIn, isFalse);

      await node.login(timeout: fastLoginTimeout);
      expect(node.loggedIn, isTrue);

      // See "Normal login flow" above for why this is the alias, not a Tox ID.
      final loginUser = node.runWithInstance(() => TIMManager.instance.getLoginUser());
      expect(loginUser, equals(node.userId));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Logout flow', () async {
      await node.login(timeout: fastLoginTimeout);
      expect(node.loggedIn, isTrue);

      await node.logout();
      expect(node.loggedIn, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Repeated login handling', () async {
      await node.login(timeout: fastLoginTimeout);
      expect(node.loggedIn, isTrue);

      // Try to login again
      await node.login(timeout: fastLoginTimeout);
      expect(node.loggedIn, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Login after logout', () async {
      await node.login(timeout: fastLoginTimeout);
      await node.logout();
      expect(node.loggedIn, isFalse);

      await node.login(timeout: fastLoginTimeout);
      expect(node.loggedIn, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
