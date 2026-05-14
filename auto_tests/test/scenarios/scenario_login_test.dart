/// Login/Logout Test
/// 
/// Tests login, logout, and login state verification
/// Reference: c-toxcore auto_tests patterns

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Login/Logout Tests', () {
    late TestNode node;
    
    setUpAll(() async {
      await setupTestEnvironment();
      node = await createTestNode('test_node');
      await node.initSDK();
    });
    
    tearDownAll(() async {
      await node.dispose();
      await teardownTestEnvironment();
    });
    
    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Ensure node is logged out before each test (except first test which expects logged out state)
      // This ensures test isolation
      if (node.loggedIn) {
        await node.logout();
      }
    });
    
    test('Normal login flow', () async {
      await node.login();
      expect(node.loggedIn, isTrue);

      // V2TIMManagerImpl::GetLoginUser() returns `login_user_alias_`, the
      // userID passed at Login(). It is NOT the Tox public key — for that
      // use FfiChatService.selfId (which is what toxee itself uses). Older
      // comments in this test claimed the call returns "Tox ID (76 hex
      // characters)"; that was aspirational and never matched the C++
      // implementation.
      final loginUser = node.runWithInstance(() => TIMManager.instance.getLoginUser());
      expect(loginUser, equals(node.userId));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Login state verification', () async {
      expect(node.loggedIn, isFalse);

      await node.login();
      expect(node.loggedIn, isTrue);

      // See "Normal login flow" above for why this is the alias, not a Tox ID.
      final loginUser = node.runWithInstance(() => TIMManager.instance.getLoginUser());
      expect(loginUser, equals(node.userId));
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Logout flow', () async {
      await node.login();
      expect(node.loggedIn, isTrue);
      
      await node.logout();
      expect(node.loggedIn, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Repeated login handling', () async {
      await node.login();
      expect(node.loggedIn, isTrue);
      
      // Try to login again
      await node.login();
      expect(node.loggedIn, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
    
    test('Login after logout', () async {
      await node.login();
      await node.logout();
      expect(node.loggedIn, isFalse);
      
      await node.login();
      expect(node.loggedIn, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
