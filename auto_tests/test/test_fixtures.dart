/// Test Fixtures
///
/// Provides test data factories, mock objects, and test environment setup

import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'package:tim2tox_dart/interfaces/extended_preferences_service.dart';
import 'package:tim2tox_dart/interfaces/logger_service.dart';
import 'package:tim2tox_dart/interfaces/bootstrap_service.dart';
import 'package:tencent_cloud_chat_sdk/native_im/bindings/native_library_manager.dart';
import 'test_helper.dart';

/// Call this in setUpAll() for tests that exercise the binary replacement path
/// (NativeLibraryManager → libtim2tox_ffi.dylib).
void setupNativeLibraryForTim2Tox() {
  setNativeLibraryName('tim2tox_ffi');
}

/// Mock preferences service for testing
class MockPreferencesService implements ExtendedPreferencesService {
  final Map<String, dynamic> _storage = {};

  @override
  Future<String?> getString(String key) async => _storage[key] as String?;

  @override
  Future<void> setString(String key, String value) async {
    _storage[key] = value;
  }

  @override
  Future<bool?> getBool(String key) async => _storage[key] as bool?;

  @override
  Future<void> setBool(String key, bool value) async {
    _storage[key] = value;
  }

  @override
  Future<int?> getInt(String key) async => _storage[key] as int?;

  @override
  Future<void> setInt(String key, int value) async {
    _storage[key] = value;
  }

  @override
  Future<List<String>?> getStringList(String key) async =>
      _storage[key] as List<String>?;

  @override
  Future<void> setStringList(String key, List<String> value) async {
    _storage[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _storage.remove(key);
  }

  @override
  Future<void> clear() async {
    _storage.clear();
  }

  @override
  Future<Set<String>> getStringSet(String key) async {
    final list = await getStringList(key);
    return list?.toSet() ?? <String>{};
  }

  @override
  Future<void> setStringSet(String key, Set<String> value) async {
    await setStringList(key, value.toList());
  }

  Future<Map<String, dynamic>?> getMap(String key) async =>
      _storage[key] as Map<String, dynamic>?;

  Future<void> setMap(String key, Map<String, dynamic> value) async {
    _storage[key] = value;
  }

  // ExtendedPreferencesService methods
  Future<Set<String>> getGroups() async => await getStringSet('groups');

  Future<void> setGroups(Set<String> groups) async =>
      await setStringSet('groups', groups);

  @override
  Future<Set<String>> getQuitGroups() async =>
      await getStringSet('quit_groups');

  @override
  Future<void> setQuitGroups(Set<String> groups) async =>
      await setStringSet('quit_groups', groups);

  @override
  Future<void> addQuitGroup(String groupId) async {
    final groups = await getQuitGroups();
    groups.add(groupId);
    await setQuitGroups(groups);
  }

  @override
  Future<void> removeQuitGroup(String groupId) async {
    final groups = await getQuitGroups();
    groups.remove(groupId);
    await setQuitGroups(groups);
  }

  @override
  Future<String?> getSelfAvatarHash() async =>
      await getString('self_avatar_hash');

  @override
  Future<void> setSelfAvatarHash(String? hash) async {
    if (hash != null) {
      await setString('self_avatar_hash', hash);
    } else {
      await remove('self_avatar_hash');
    }
  }

  @override
  Future<String?> getFriendNickname(String friendId) async =>
      await getString('friend_nickname_$friendId');

  @override
  Future<void> setFriendNickname(String friendId, String nickname) async =>
      await setString('friend_nickname_$friendId', nickname);

  @override
  Future<String?> getFriendStatusMessage(String friendId) async =>
      await getString('friend_status_$friendId');

  @override
  Future<void> setFriendStatusMessage(
          String friendId, String statusMessage) async =>
      await setString('friend_status_$friendId', statusMessage);

  @override
  Future<String?> getFriendAvatarPath(String friendId) async =>
      await getString('friend_avatar_path_$friendId');

  @override
  Future<void> setFriendAvatarPath(String friendId, String? path) async {
    if (path != null) {
      await setString('friend_avatar_path_$friendId', path);
    } else {
      await remove('friend_avatar_path_$friendId');
    }
  }

  @override
  Future<Set<String>> getLocalFriends() async =>
      await getStringSet('local_friends');

  @override
  Future<void> setLocalFriends(Set<String> ids) async =>
      await setStringSet('local_friends', ids);

  @override
  Future<String> getBootstrapNodeMode() async =>
      await getString('bootstrap_node_mode') ?? 'auto';

  @override
  Future<({String host, int port, String pubkey})?>
      getCurrentBootstrapNode() async {
    final data = await getMap('current_bootstrap_node');
    if (data == null) return null;
    return (
      host: data['host'] as String,
      port: data['port'] as int,
      pubkey: data['pubkey'] as String
    );
  }

  @override
  Future<void> setCurrentBootstrapNode(
      String host, int port, String pubkey) async {
    await setMap('current_bootstrap_node',
        {'host': host, 'port': port, 'pubkey': pubkey});
  }

  @override
  Future<int> getAutoDownloadSizeLimit() async =>
      await getInt('auto_download_size_limit') ?? 10;

  @override
  Future<void> setAutoDownloadSizeLimit(int sizeInMB) async =>
      await setInt('auto_download_size_limit', sizeInMB);

  @override
  Future<String?> getAvatarPath() async => await getString('avatar_path');

  @override
  Future<void> setAvatarPath(String? path) async {
    if (path != null) {
      await setString('avatar_path', path);
    } else {
      await remove('avatar_path');
    }
  }

  @override
  Future<String?> getFriendAvatarHash(String friendId) async =>
      await getString('friend_avatar_hash_$friendId');

  @override
  Future<void> setFriendAvatarHash(String friendId, String hash) async =>
      await setString('friend_avatar_hash_$friendId', hash);

  @override
  Future<String?> getDownloadsDirectory() async =>
      await getString('downloads_directory');

  @override
  Future<void> setDownloadsDirectory(String? path) async {
    if (path != null) {
      await setString('downloads_directory', path);
    } else {
      await remove('downloads_directory');
    }
  }

  @override
  Future<String?> getGroupName(String groupId) async =>
      await getString('group_name_$groupId');

  @override
  Future<void> setGroupName(String groupId, String name) async =>
      await setString('group_name_$groupId', name);

  @override
  Future<String?> getGroupAvatar(String groupId) async =>
      await getString('group_avatar_$groupId');

  @override
  Future<void> setGroupAvatar(String groupId, String? avatarPath) async {
    if (avatarPath != null) {
      await setString('group_avatar_$groupId', avatarPath);
    } else {
      await remove('group_avatar_$groupId');
    }
  }

  @override
  Future<String?> getGroupNotification(String groupId) async =>
      await getString('group_notification_$groupId');

  @override
  Future<void> setGroupNotification(
      String groupId, String? notification) async {
    if (notification != null) {
      await setString('group_notification_$groupId', notification);
    } else {
      await remove('group_notification_$groupId');
    }
  }

  @override
  Future<String?> getGroupIntroduction(String groupId) async =>
      await getString('group_introduction_$groupId');

  @override
  Future<void> setGroupIntroduction(
      String groupId, String? introduction) async {
    if (introduction != null) {
      await setString('group_introduction_$groupId', introduction);
    } else {
      await remove('group_introduction_$groupId');
    }
  }

  @override
  Future<String?> getGroupOwner(String groupId) async =>
      await getString('group_owner_$groupId');

  @override
  Future<void> setGroupOwner(String groupId, String ownerId) async =>
      await setString('group_owner_$groupId', ownerId);

  @override
  Future<String?> getGroupChatId(String groupId) async =>
      await getString('group_chat_id_$groupId');

  @override
  Future<void> setGroupChatId(String groupId, String chatId) async =>
      await setString('group_chat_id_$groupId', chatId);

  @override
  Future<Set<String>> getBlackList([String? userToxId]) async {
    final key = userToxId != null ? 'blacklist_$userToxId' : 'blacklist';
    return await getStringSet(key);
  }

  @override
  Future<void> setBlackList(Set<String> userIDs, [String? userToxId]) async {
    final key = userToxId != null ? 'blacklist_$userToxId' : 'blacklist';
    await setStringSet(key, userIDs);
  }

  @override
  Future<void> addToBlackList(List<String> userIDs, [String? userToxId]) async {
    final blacklist = await getBlackList(userToxId);
    blacklist.addAll(userIDs);
    await setBlackList(blacklist, userToxId);
  }

  @override
  Future<void> removeFromBlackList(List<String> userIDs,
      [String? userToxId]) async {
    final blacklist = await getBlackList(userToxId);
    blacklist.removeAll(userIDs);
    await setBlackList(blacklist, userToxId);
  }
}

/// Mock logger service for testing
class MockLoggerService implements LoggerService {
  final List<String> logs = [];

  @override
  void log(String message) {
    logs.add('[INFO] $message');
    print('[TestLogger] $message');
  }

  @override
  void logError(String message, Object error, StackTrace stack) {
    logs.add('[ERROR] $message: $error');
    print('[TestLogger] ERROR: $message: $error');
  }

  @override
  void logWarning(String message) {
    logs.add('[WARN] $message');
    print('[TestLogger] WARNING: $message');
  }

  @override
  void logDebug(String message) {
    logs.add('[DEBUG] $message');
  }

  void clear() {
    logs.clear();
  }
}

/// Mock bootstrap service for testing
class MockBootstrapService implements BootstrapService {
  String? _host;
  int? _port;
  String? _publicKey;

  @override
  Future<String?> getBootstrapHost() async => _host;

  @override
  Future<int?> getBootstrapPort() async => _port;

  @override
  Future<String?> getBootstrapPublicKey() async => _publicKey;

  @override
  Future<void> setBootstrapNode({
    required String host,
    required int port,
    required String publicKey,
  }) async {
    _host = host;
    _port = port;
    _publicKey = publicKey;
  }
}

/// Test scenario container
class TestScenario {
  final List<TestNode> nodes = [];
  final Map<String, TestNode> nodesByAlias = {};
  bool _running = false;

  /// Add a node to the scenario
  TestNode addNode({
    required String alias,
    required String userId,
    required String userSig,
  }) {
    final node = TestNode(
      userId: userId,
      userSig: userSig,
      alias: alias,
    );
    nodes.add(node);
    nodesByAlias[alias] = node;
    return node;
  }

  /// Get a node by alias
  TestNode? getNode(String alias) => nodesByAlias[alias];

  /// Get a node by index
  TestNode? getNodeByIndex(int index) {
    if (index >= 0 && index < nodes.length) {
      return nodes[index];
    }
    return null;
  }

  /// Initialize all nodes
  Future<void> initAllNodes({String? initPath, String? logPath}) async {
    for (final node in nodes) {
      await node.initSDK(initPath: initPath, logPath: logPath);
    }
    // Register all instance IDs for polling so FfiChatService consumes file_request and other
    // instance-scoped events (e.g. file_request:2:...) when using a single shared service.
    for (final node in nodes) {
      if (node.testInstanceHandle != null) {
        FfiChatService.registerInstanceForPolling(node.testInstanceHandle!);
      }
    }
    // Tests use TestNode.login() and may bypass platform.login(), so start polling here
    // to ensure file_request/progress/file_done events are drained in all scenarios.
    final platform = TencentCloudChatSdkPlatform.instance;
    if (platform is Tim2ToxSdkPlatform) {
      await platform.ffiService.startPolling();
    }
  }

  /// Login all nodes
  Future<void> loginAllNodes() async {
    for (int i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      try {
        await node.login();
      } catch (e) {
        rethrow;
      }
    }
  }

  /// Cleanup all nodes.
  /// Disposes nodes sequentially (not in parallel) to avoid 归类A: GetInstanceIdFromManager
  /// seeing a manager already removed from g_instance_to_id when another node's UnInitSDK
  /// or callbacks still run; and to avoid 6013 when one node is destroyed while the other
  /// is still in tearDown or in a waiting loop.
  Future<void> dispose() async {
    _running = false;
    for (final node in nodes) {
      await node.dispose();
    }
    // Ensure no stale instance IDs remain in global polling registry across scenarios.
    FfiChatService.clearPollingRegistryForTests();
    nodes.clear();
    nodesByAlias.clear();
  }

  bool get isRunning => _running;
  void setRunning(bool running) => _running = running;
}

/// Create a test node with default configuration
final _idRandom = math.Random();
String _uniqueSuffix() =>
    '${DateTime.now().microsecondsSinceEpoch}_${_idRandom.nextInt(1 << 32).toRadixString(16)}';

Future<TestNode> createTestNode(
  String alias, {
  String? userId,
  String? userSig,
}) async {
  // Generate default user ID and sig if not provided.
  // millisecondsSinceEpoch alone can collide when several nodes are created in
  // a tight loop (e.g. multi-instance scenarios); switch to microseconds plus
  // a random suffix so IDs are unique even within the same Dart microtask.
  final defaultUserId = userId ?? 'test_user_${alias}_${_uniqueSuffix()}';
  final defaultUserSig = userSig ?? 'test_sig_${alias}_${_uniqueSuffix()}';

  return TestNode(
    userId: defaultUserId,
    userSig: defaultUserSig,
    alias: alias,
  );
}

/// Create a test scenario with multiple nodes
Future<TestScenario> createTestScenario(List<String> aliases) async {
  final scenario = TestScenario();

  for (final alias in aliases) {
    final node = await createTestNode(alias);
    scenario.nodes.add(node);
    scenario.nodesByAlias[alias] = node;
  }

  return scenario;
}

/// Create FfiChatService for testing
Future<FfiChatService> createTestFfiChatService({
  ExtendedPreferencesService? preferencesService,
  LoggerService? loggerService,
  BootstrapService? bootstrapService,
}) async {
  final prefs = preferencesService ?? MockPreferencesService();
  final logger = loggerService ?? MockLoggerService();
  final bootstrap = bootstrapService ?? MockBootstrapService();

  return FfiChatService(
    preferencesService: prefs,
    loggerService: logger,
    bootstrapService: bootstrap,
  );
}

/// Get a temporary directory for test data.
/// [subdir] if provided (e.g. 'scenario_file_seek') returns a scenario-specific
/// path so one scenario's teardown does not delete another's files when tests
/// run interleaved.
///
/// When [subdir] is null the path is suffixed with the current process pid, so
/// two concurrent runs of the suite (CI matrix, local re-run while another
/// `flutter test` is still running) don't share `tim2tox_tests/default` and
/// trample each other's tox profiles / friend lists / known-groups state.
Future<String> getTestDataDir([String? subdir]) async {
  final base = path.join(Directory.systemTemp.path, 'tim2tox_tests');
  final testDir = subdir != null
      ? path.join(base, subdir)
      : path.join(base, 'default-$pid');
  final dir = Directory(testDir);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return testDir;
}

/// Cleanup test data directory. If [subdir] is provided, only that subdir under tim2tox_tests is removed.
/// With no args, only the default dir is removed so scenario-specific dirs are left intact.
Future<void> cleanupTestDataDir([String? subdir]) async {
  try {
    final testDir = await getTestDataDir(subdir);
    final dir = Directory(testDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  } catch (e) {
    // Ignore cleanup errors
    print('Warning: Failed to cleanup test data dir: $e');
  }
}

/// Setup test environment
Future<void> setupTestEnvironment() async {
  // Initialize Flutter binding for tests
  TestWidgetsFlutterBinding.ensureInitialized();

  // Configure NativeLibraryManager to load tim2tox_ffi instead of the default dart_native_imsdk.
  // This MUST happen before any NativeLibraryManager usage (which triggers lazy DynamicLibrary loading).
  setupNativeLibraryForTim2Tox();

  // Set DYLD_LIBRARY_PATH for macOS to find libtim2tox_ffi.dylib
  if (Platform.isMacOS) {
    // libPath for future use: path.join(path.dirname(path.dirname(path.dirname(Platform.resolvedExecutable))), 'tim2tox', 'build', 'ffi');
    // Note: DYLD_LIBRARY_PATH doesn't work in tests, so we'll need to copy the library
    // or use absolute path in the library loading code
    // For now, we'll rely on the library being in the system search path
  }

  // Mock path_provider platform channel to avoid plugin dependency.
  // PID-namespace the directories so PARALLEL_WORKERS>1 (or any other
  // setup that runs multiple `flutter test` processes concurrently)
  // doesn't share `tim2tox_tests/app_support` across processes — Tim2Tox
  // writes message-history dirs keyed by *instance_id* (1, 2, …) which
  // each process re-assigns from 1 upward, so without PID separation
  // two parallel processes' `chat_history_instance_1/` directories
  // would collide and corrupt each other's persisted state.
  final testDataDir =
      path.join(Directory.systemTemp.path, 'tim2tox_tests', 'pid-$pid');
  final appDocumentsDir = path.join(testDataDir, 'app_documents');
  final appSupportDir = path.join(testDataDir, 'app_support');
  final appCacheDir = path.join(testDataDir, 'app_cache');
  final tempDir = path.join(testDataDir, 'temp');

  // Create directories
  await Directory(appDocumentsDir).create(recursive: true);
  await Directory(appSupportDir).create(recursive: true);
  await Directory(appCacheDir).create(recursive: true);
  await Directory(tempDir).create(recursive: true);

  // Set up method channel handler for path_provider
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'getApplicationDocumentsDirectory':
          return appDocumentsDir;
        case 'getApplicationSupportDirectory':
          return appSupportDir;
        case 'getApplicationCacheDirectory':
          return appCacheDir;
        case 'getTemporaryDirectory':
          return tempDir;
        default:
          throw MissingPluginException(
              'No implementation found for method ${methodCall.method}');
      }
    },
  );

  // Ensure test data directory exists
  await getTestDataDir();

  // Use Tim2Tox per-instance routing so group state callbacks (leave/kick/role) are
  // dispatched by instance_id to the correct node's listener.
  final ffiService = await createTestFfiChatService();
  TencentCloudChatSdkPlatform.instance =
      Tim2ToxSdkPlatform(ffiService: ffiService);
}

/// Teardown test environment
Future<void> teardownTestEnvironment() async {
  // Cleanup test data
  await cleanupTestDataDir();
}
