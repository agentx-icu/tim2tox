/// SDK Initialization Test — virtual-clock variant
///
/// Mirrors scenario_sdk_init_test.dart 1:1 but enables VirtualClock.enableEarly()
/// before any TestNode is created so the V2TIMManagerImpl constructor inherits
/// test_mode and InitSDK never spawns event_thread.
///
/// This is a single-node test: there is no bootstrap, no friendship, and no
/// inter-instance pumping. The assertions verify init/uninit/version/server-time
/// surface — none of those require virtual time to advance.

import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/log_level_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('SDK Initialization Tests (Virtual)', () {
    late TestNode node;

    setUpAll(() async {
      await setupTestEnvironment();
      // ENABLE TEST MODE *BEFORE* node creation so V2TIMManagerImpl
      // constructor inherits test_mode and InitSDK skips event_thread.
      await VirtualClock.enableEarly();
      node = await createTestNode('test_node');
    });

    tearDownAll(() async {
      await node.dispose();
      await teardownTestEnvironment();
    });

    setUp(() async {
      // Most tests don't need cleanup since they use shared node
    });

    test('SDK initialization succeeds', () async {
      await node.initSDK();
      expect(node.initialized, isTrue);
      expect(TIMManager.instance.isInitSDK(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('SDK initialization with custom paths', () async {
      final testDir = await getTestDataDir();
      await node.initSDK(
        initPath: testDir,
        logPath: testDir,
      );
      expect(node.initialized, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('SDK uninitialization', () async {
      await node.initSDK();
      expect(node.initialized, isTrue);

      await node.unInitSDK();
      expect(node.initialized, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('SDK version retrieval', () async {
      await node.initSDK();

      final version = TIMManager.instance.getSDKVersion();
      expect(version, isNotNull);
      expect(version, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Server time retrieval', () async {
      await node.initSDK();

      final serverTime = TIMManager.instance.getServerTime();
      expect(serverTime, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Repeated initialization handling', () async {
      await node.initSDK();
      expect(node.initialized, isTrue);

      // Try to initialize again
      await node.initSDK();
      expect(node.initialized, isTrue);
      expect(TIMManager.instance.isInitSDK(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('SDK configuration', () async {
      await node.initSDK();

      // Test setConfig
      TIMManager.instance.setConfig(
        logLevel: LogLevelEnum.V2TIM_LOG_DEBUG,
        showImLog: true,
      );

      // Configuration should be applied without error
      expect(TIMManager.instance.isInitSDK(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
