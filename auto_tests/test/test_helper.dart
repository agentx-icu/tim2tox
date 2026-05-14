/// Test Helper Library
///
/// Provides TestNode class and utility functions for testing tim2tox Dart interfaces
/// Similar to c-toxcore's AutoTox structure

import 'dart:async';
import 'dart:io';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_conversation_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/log_level_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_response_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/group_member_filter_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_info.dart';
import 'dart:ffi' as ffi;
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/instance/tim2tox_instance.dart';
import 'package:ffi/ffi.dart' as pkgffi;
import 'package:path/path.dart' as path;
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';
import 'test_fixtures.dart';

/// Callback data structure
class CallbackData {
  final String callbackName;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  CallbackData({
    required this.callbackName,
    required this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Test node representing a user in the test scenario
/// Similar to c-toxcore's AutoTox structure
class TestNode {
  final String userId;
  final String userSig;
  final String alias;

  TIMManager? timManager;
  bool initialized = false;
  bool loggedIn = false;

  // Test instance handle (for multi-instance support)
  int? _testInstanceHandle;

  /// Get test instance handle (for multi-instance support)
  int? get testInstanceHandle => _testInstanceHandle;

  /// Runs [action] with this node's instance as current, then restores previous.
  /// Use instead of manual setCurrentInstance + TIMManager/TIMFriendshipManager/TIMGroupManager calls.
  R runWithInstance<R>(R Function() action) {
    return Tim2ToxInstance.fromHandle(testInstanceHandle)
        .runWithInstance(action);
  }

  /// Async version of [runWithInstance]. Use for login, initSDK, etc.
  Future<R> runWithInstanceAsync<R>(Future<R> Function() action) async {
    return Tim2ToxInstance.fromHandle(testInstanceHandle)
        .runWithInstanceAsync(action);
  }

  // Callback verification
  final Map<String, bool> callbackReceived = {};
  final List<CallbackData> callbackQueue = [];

  // Message queue
  final List<V2TimMessage> receivedMessages = [];

  // State
  Map<String, dynamic> state = {};

  // Stream subscriptions
  StreamSubscription? _connectionStatusSub;
  StreamSubscription? _messagesSub;

  // Completers for waiting
  final Map<String, Completer<void>> _callbackCompleters = {};

  // Connection status tracking
  bool connectionStatusCalled = false;
  int lastConnectionStatus = 0; // 0=NONE, 1=TCP, 2=UDP

  // Friend list cache
  List<String>? _friendListCache;
  DateTime? _friendListCacheTime;

  // Tox ID cache (to avoid repeated FFI calls)
  String? _toxIdCache;

  // Auto-accept listeners (similar to c-toxcore's auto-accept mechanism)
  // Reference: c-toxcore uses on_friend_request callback with tox_friend_add_norequest()
  V2TimFriendshipListener? _autoAcceptFriendListener;
  bool _autoAcceptEnabled = false;

  // Group listener for handling group callbacks (onGroupCreated, onMemberEnter, etc.)
  V2TimGroupListener? _groupListener;

  TestNode({
    required this.userId,
    required this.userSig,
    required this.alias,
  });

  /// Enable auto-accept for friend requests
  /// Similar to c-toxcore's auto-accept mechanism in test framework
  /// Reference: c-toxcore uses on_friend_request callback with tox_friend_add_norequest()
  void enableAutoAccept() {
    if (_autoAcceptEnabled) {
      return; // Already enabled
    }

    _autoAcceptEnabled = true;

    runWithInstance(() {
      // Auto-accept friend requests (similar to c-toxcore's on_friend_request callback)
      // In c-toxcore: tox_friend_add_norequest(tox, public_key, nullptr)
      // In tim2tox: acceptFriendApplication with V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD
      _autoAcceptFriendListener = V2TimFriendshipListener(
        onFriendApplicationListAdded:
            (List<V2TimFriendApplication> applicationList) async {
          print(
              '[AutoAccept] $alias: ✅ Received ${applicationList.length} friend request(s)');
          print(
              '[AutoAccept] $alias: applicationList type=${applicationList.runtimeType}');
          for (int i = 0; i < applicationList.length; i++) {
            final app = applicationList[i];
            print(
                '[AutoAccept] $alias: application[$i] type=${app.runtimeType}, userID=${app.userID}, userID.length=${app.userID.length}');
            if (app.userID.isNotEmpty) {
              print(
                  '[AutoAccept] $alias: Processing friend request from ${app.userID.substring(0, 20)}... (full ID: ${app.userID})');
              try {
                await runWithInstanceAsync(() async {
                  print(
                      '[AutoAccept] $alias: Calling acceptFriendApplication for ${app.userID.substring(0, 20)}...');
                  final acceptResult = await TIMFriendshipManager.instance
                      .acceptFriendApplication(
                    responseType: FriendResponseTypeEnum
                        .V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
                    userID: app.userID,
                  );
                  print(
                      '[AutoAccept] $alias: ✅ Auto-accepted friend request from ${app.userID.substring(0, 20)}, result code=${acceptResult.code}');
                });
              } catch (e, stackTrace) {
                print(
                    '[AutoAccept] $alias: ⚠️  Failed to auto-accept friend request from ${app.userID.substring(0, 20)}: $e');
                print('[AutoAccept] $alias: Stack trace: $stackTrace');
              }
            } else {
              print(
                  '[AutoAccept] $alias: ⚠️  Received null or empty friend application');
            }
          }
        },
      );
      TIMFriendshipManager.instance
          .addFriendListener(listener: _autoAcceptFriendListener!);

      // Also register group listener for handling group callbacks
      _groupListener = V2TimGroupListener(
        onGroupCreated: (String groupID) {
          print(
              '[TestNode] $alias: onGroupCreated callback triggered for groupID=$groupID');
          markCallbackReceived('onGroupCreated', data: {'groupID': groupID});
        },
        onMemberEnter: (String groupID, List<V2TimGroupMemberInfo> memberList) {
          print(
              '[TestNode] $alias: onMemberEnter callback triggered for groupID=$groupID, memberCount=${memberList.length}');
          markCallbackReceived('onMemberEnter',
              data: {'groupID': groupID, 'memberCount': memberList.length});
        },
        onMemberInvited: (String groupID, V2TimGroupMemberInfo opUser,
            List<V2TimGroupMemberInfo> memberList) {
          print(
              '[TestNode] $alias: onMemberInvited callback triggered for groupID=$groupID, memberCount=${memberList.length}');
          markCallbackReceived('onGroupInvited',
              data: {'groupID': groupID, 'memberCount': memberList.length});
        },
        onGroupInfoChanged: (String groupID, List changeInfos) {
          print(
              '[TestNode] $alias: onGroupInfoChanged callback triggered for groupID=$groupID');
          markCallbackReceived('onGroupInfoChanged',
              data: {'groupID': groupID});
        },
      );
      TIMGroupManager.instance.addGroupListener(_groupListener!);
    });

    print(
        '[AutoAccept] $alias: ✅ Auto-accept enabled for friend requests (similar to c-toxcore\'s tox_friend_add_norequest)');
    print(
        '[TestNode] $alias: ✅ Group listener registered for handling group callbacks');
  }

  /// Disable auto-accept
  void disableAutoAccept() {
    if (!_autoAcceptEnabled) {
      return;
    }

    _autoAcceptEnabled = false;

    runWithInstance(() {
      if (_autoAcceptFriendListener != null) {
        TIMFriendshipManager.instance
            .removeFriendListener(listener: _autoAcceptFriendListener!);
        _autoAcceptFriendListener = null;
      }
      if (_groupListener != null) {
        TIMGroupManager.instance.removeGroupListener(listener: _groupListener!);
        _groupListener = null;
      }
    });

    print('[AutoAccept] $alias: Auto-accept disabled');
  }

  /// Initialize SDK for this node
  Future<void> initSDK(
      {String? initPath,
      String? logPath,
      bool? localDiscoveryEnabled,
      bool? ipv6Enabled}) async {
    if (initialized) {
      return;
    }

    // Use test directory paths to avoid path_provider plugin issues
    final testDataDir = await getTestDataDir();
    final testInitPath = initPath ?? path.join(testDataDir, userId, 'init');
    final testLogPath = logPath ?? path.join(testDataDir, userId, 'logs');

    // Ensure directories exist
    await Directory(testInitPath).create(recursive: true);
    await Directory(testLogPath).create(recursive: true);

    // Create a new test instance using FFI (for multi-instance support)
    final ffiInstance = ffi_lib.Tim2ToxFfi.open();
    final initPathPtr = testInitPath.toNativeUtf8();
    try {
      int instanceHandle;
      // Use extended version if options are provided
      if (localDiscoveryEnabled != null || ipv6Enabled != null) {
        final localDiscovery = localDiscoveryEnabled ?? true;
        final ipv6 = ipv6Enabled ?? true;
        instanceHandle = ffiInstance.createTestInstanceExNative(
            initPathPtr, localDiscovery ? 1 : 0, ipv6 ? 1 : 0);
        print(
            '[Test] Created test instance $instanceHandle for node $alias with options: localDiscovery=$localDiscovery, ipv6=$ipv6');
      } else {
        instanceHandle = ffiInstance.createTestInstanceNative(initPathPtr);
        print(
            '[Test] Created test instance $instanceHandle for node $alias with default options (localDiscovery=true, ipv6=true)');
      }

      if (instanceHandle == 0) {
        throw Exception('Failed to create test instance for node $alias');
      }
      _testInstanceHandle = instanceHandle;

      print(
          '[Test] Created test instance $instanceHandle for node $alias with initPath=$testInitPath');
    } finally {
      pkgffi.malloc.free(initPathPtr);
    }

    // Still use TIMManager.instance for Dart API access
    // The underlying V2TIMManagerImpl instance is managed via FFI
    timManager = TIMManager.instance;

    // Initialize SDK (runWithInstanceAsync sets this instance as current for the call)
    final result = await runWithInstanceAsync(() async => timManager!.initSDK(
          sdkAppID: 0, // Placeholder for binary replacement mode
          logLevel: LogLevelEnum.V2TIM_LOG_INFO,
          uiPlatform: 0, // Flutter FFI platform
          initPath: testInitPath,
          logPath: testLogPath,
        ));

    if (!result) {
      throw Exception('Failed to initialize SDK for node $alias');
    }

    initialized = true;
  }

  /// Login this node
  Future<void> login({Duration? timeout}) async {
    print('[Test] Node $alias: ========== login() ENTRY ==========');
    print(
        '[Test] Node $alias: login() called, initialized=$initialized, loggedIn=$loggedIn, userId=$userId');

    if (!initialized) {
      print('[Test] Node $alias: ERROR - SDK not initialized');
      throw Exception('SDK not initialized for node $alias');
    }

    if (loggedIn) {
      print('[Test] Node $alias: Already logged in, skipping');
      return;
    }

    await runWithInstanceAsync(() async {
      if (testInstanceHandle != null) {
        print(
            '[Test] Node $alias: Using instance $testInstanceHandle for login');
      }
      print(
          '[Test] Node $alias: Calling timManager.login() with userId=$userId...');
      final loginStartTime = DateTime.now();
      final result = await timManager!.login(
        userID: userId,
        userSig: userSig,
      );
      final loginDuration = DateTime.now().difference(loginStartTime);
      print(
          '[Test] Node $alias: timManager.login() completed in ${loginDuration.inMilliseconds}ms');
      print(
          '[Test] Node $alias: timManager.login() returned: code=${result.code}, desc=${result.desc}');

      if (result.code != 0) {
        print(
            '[Test] Node $alias: ERROR - Login failed with code=${result.code}, desc=${result.desc}');
        throw Exception('Login failed for node $alias: ${result.desc}');
      }

      loggedIn = true;
      print(
          '[Test] Node $alias: Set loggedIn=true after successful login API call');
      clearToxIdCache();
      enableAutoAccept();

      // Wait for real Tox DHT connection (tox_self_get_connection_status), not just loginStatus
      final connectionTimeout = timeout ?? const Duration(seconds: 10);
      final deadline = DateTime.now().add(connectionTimeout);
      int checkCount = 0;
      int pollDelayMs = 50;
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      while (DateTime.now().isBefore(deadline)) {
        checkCount++;
        int connectionStatus = 0;
        try {
          connectionStatus = ffiInstance.getSelfConnectionStatus();
        } catch (e) {
          final loginStatus = timManager!.getLoginStatus();
          connectionStatus = loginStatus == 1 ? 2 : 0;
        }
        if (checkCount == 1) {
          print(
              '[Test] Node $alias: First check - connectionStatus=$connectionStatus (0=NONE,1=TCP,2=UDP), loggedIn=$loggedIn');
        }
        if (connectionStatus == 1 || connectionStatus == 2) {
          await Future.delayed(const Duration(milliseconds: 500));
          print(
              '[Test] Node $alias: ✅ Connection established after $checkCount checks, connectionStatus=$connectionStatus, loggedIn=$loggedIn');
          if (!loggedIn) {
            print(
                '[Test] Node $alias: ⚠️  WARNING - loggedIn is false but connectionStatus!=0, fixing...');
            loggedIn = true;
          }
          return;
        }
        if (checkCount % 10 == 0) {
          print(
              '[Test] Node $alias: Still waiting for connection (check $checkCount, connectionStatus=$connectionStatus, loggedIn=$loggedIn)');
        }
        await Future.delayed(Duration(milliseconds: pollDelayMs));
        if (pollDelayMs < 200) {
          pollDelayMs = (pollDelayMs * 1.5).round().clamp(50, 200);
        }
      }

      int finalConnectionStatus = 0;
      try {
        finalConnectionStatus = ffiInstance.getSelfConnectionStatus();
      } catch (e) {
        final loginStatus = timManager!.getLoginStatus();
        finalConnectionStatus = loginStatus == 1 ? 2 : 0;
      }
      print(
          '[Test] Node $alias: Connection timeout after $checkCount checks, finalConnectionStatus=$finalConnectionStatus, loggedIn=$loggedIn');
      if (finalConnectionStatus == 1 || finalConnectionStatus == 2) {
        print(
            '[Test] Node $alias: ✅ Connection timeout but connection was established (connectionStatus=$finalConnectionStatus)');
        if (!loggedIn) {
          print(
              '[Test] Node $alias: ⚠️  WARNING - loggedIn is false but connectionStatus!=0, fixing...');
          loggedIn = true;
        }
        return;
      }
      print(
          '[Test] Node $alias: ⚠️  Connection timeout, but loggedIn=$loggedIn (set after API call)');
    });
  }

  /// Logout this node
  Future<void> logout() async {
    if (!loggedIn) {
      return;
    }

    await timManager!.logout();
    loggedIn = false;

    // Clear Tox ID cache on logout
    clearToxIdCache();
  }

  /// Uninitialize SDK.
  ///
  /// Wrapped in try/finally so that if logout() throws (slow Tox shutdown,
  /// pending file transfers, etc.) the native test instance is still
  /// destroyed and the polling registry is still cleared. Without this, a
  /// single failing logout would leak a Tox instance for the rest of the
  /// process and the next scenario would poll a stale handle.
  Future<void> unInitSDK() async {
    if (!initialized) {
      return;
    }

    // Disable auto-accept before cleanup
    disableAutoAccept();

    try {
      await logout();
    } catch (e) {
      print(
          '[Test] Node $alias: logout() threw during unInitSDK, continuing with cleanup: $e');
    }

    // Cancel platform timer and subscriptions before native unInitSDK to avoid
    // Timer.periodic (friend status) firing after instance is destroyed (segfault).
    try {
      final p = TencentCloudChatSdkPlatform.instance;
      if (p is Tim2ToxSdkPlatform) {
        p.dispose();
      }
    } catch (_) {}

    try {
      // Uninit current instance (DartUnitSDK uninits whichever instance is current)
      if (_testInstanceHandle != null) {
        final ffiInstance = ffi_lib.Tim2ToxFfi.open();
        final handle = _testInstanceHandle!;
        try {
          // Uninit THIS node's instance
          ffiInstance.setCurrentInstance(handle);
          timManager!.unInitSDK();
          // Reset to default instance before destroying test instance
          ffiInstance.setCurrentInstance(0);
          final result = ffiInstance.destroyTestInstance(handle);
          if (result == 0) {
            print(
                'Warning: Failed to destroy test instance $handle for node $alias');
          } else {
            print('[Test] Destroyed test instance $handle for node $alias');
          }
        } finally {
          // Always unregister polling id and clear the handle so later
          // scenarios won't poll stale instance IDs even if destroyTestInstance
          // crashed.
          FfiChatService.unregisterInstanceForPolling(handle);
          _testInstanceHandle = null;
        }
      } else {
        timManager!.unInitSDK();
      }
    } finally {
      initialized = false;
      // Clear Tox ID cache when uninitialized
      clearToxIdCache();
    }
  }

  /// Wait for a specific callback to be received
  Future<void> waitForCallback(String callbackName, {Duration? timeout}) async {
    if (callbackReceived[callbackName] == true) {
      return;
    }

    final completer = Completer<void>();
    _callbackCompleters[callbackName] = completer;

    try {
      await completer.future.timeout(
        timeout ?? const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Timeout waiting for callback: $callbackName');
        },
      );
    } finally {
      _callbackCompleters.remove(callbackName);
    }
  }

  /// Wait for a condition to become true
  /// Wait for a condition to become true
  /// With local bootstrap, conditions should be met quickly (1-5 seconds)
  /// Optimization: Use 200ms poll interval for better performance (reduced from 100ms)
  Future<void> waitForCondition(
    bool Function() condition, {
    Duration? timeout,
    Duration pollInterval = const Duration(milliseconds: 200),
    String? description,
  }) async {
    final deadline = DateTime.now().add(timeout ?? const Duration(seconds: 10));

    while (DateTime.now().isBefore(deadline)) {
      if (condition()) {
        return;
      }
      await Future.delayed(pollInterval);
    }

    final desc = description ?? 'condition';
    throw TimeoutException(
        'Timeout waiting for $desc (timeout: ${timeout ?? const Duration(seconds: 30)})');
  }

  /// Wait for connection to be established
  /// This is important for tests that require network connectivity
  /// With local bootstrap, connection should establish quickly (1-5 seconds)
  /// Uses real Tox connection status (0=NONE, 1=TCP, 2=UDP) instead of login status
  Future<void> waitForConnection({Duration? timeout}) async {
    if (!loggedIn) {
      throw Exception('Cannot wait for connection: node is not logged in');
    }

    await runWithInstanceAsync(() async {
      final connectionTimeout = timeout ?? const Duration(seconds: 15);
      final deadline = DateTime.now().add(connectionTimeout);
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      int checkCount = 0;
      int pollDelayMs = 100;
      const maxPollDelayMs = 300;

      while (DateTime.now().isBefore(deadline)) {
        checkCount++;
        int connectionStatus = 0;
        try {
          connectionStatus = ffiInstance.getSelfConnectionStatus();
        } catch (e) {
          final loginStatus = timManager!.getLoginStatus();
          connectionStatus = loginStatus == 1 ? 2 : 0;
        }

        if (connectionStatus == 1 || connectionStatus == 2) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (checkCount > 1) {
            print(
                '[Test] Node $alias: Connected to DHT! (connectionStatus=$connectionStatus)');
          }
          return;
        }

        if (checkCount % 10 == 0) {
          print(
              '[Test] Node $alias: Still waiting for connection (check $checkCount, connectionStatus=$connectionStatus)');
        }

        await Future.delayed(Duration(milliseconds: pollDelayMs));
        pollDelayMs = (pollDelayMs * 1.2).round().clamp(100, maxPollDelayMs);
      }

      int finalConnectionStatus = 0;
      try {
        finalConnectionStatus = ffiInstance.getSelfConnectionStatus();
      } catch (e) {
        final loginStatus = timManager!.getLoginStatus();
        finalConnectionStatus = loginStatus == 1 ? 2 : 0;
      }

      if (finalConnectionStatus == 1 || finalConnectionStatus == 2) {
        print(
            '[Test] Node $alias: Connection timeout after $checkCount checks, but connection was established (status=$finalConnectionStatus)');
        return;
      }

      throw TimeoutException(
          'Timeout waiting for connection (timeout: $connectionTimeout, checkCount: $checkCount, finalConnectionStatus: $finalConnectionStatus)');
    });
  }

  /// Mark a callback as received
  void markCallbackReceived(String callbackName, {Map<String, dynamic>? data}) {
    callbackReceived[callbackName] = true;
    if (data != null) {
      callbackQueue.add(CallbackData(
        callbackName: callbackName,
        data: data,
      ));
    }

    // Complete any waiting completer
    final completer = _callbackCompleters[callbackName];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Clear a callback flag so the next waitForCallback(callbackName) will wait for a fresh occurrence.
  /// Use before invite+wait flows when the same callback can fire in multiple tests.
  void clearCallbackReceived(String callbackName) {
    callbackReceived[callbackName] = false;
  }

  /// Returns the groupID from the most recent callback with [callbackName] that had data containing 'groupID'.
  /// Used when joinGroup must use the invitee's groupID (e.g. tox_inv_0_xxx) rather than creator's groupID.
  String? getLastCallbackGroupId(String callbackName) {
    for (int i = callbackQueue.length - 1; i >= 0; i--) {
      final entry = callbackQueue[i];
      if (entry.callbackName == callbackName &&
          entry.data.containsKey('groupID')) {
        return entry.data['groupID'] as String?;
      }
    }
    return null;
  }

  /// Add a received message
  void addReceivedMessage(V2TimMessage message) {
    receivedMessages.add(message);
  }

  /// Wait for friend connection (friend is in friend list and online)
  /// With local bootstrap, friend connection should establish quickly (2-10 seconds)
  /// Note: friendUserId can be either full Tox ID (76 hex characters) or public key (64 hex characters)
  /// Friend list returns public keys (64 chars), so we extract public key for comparison
  /// After friend is in list, waits additional time for Tox to establish P2P connection
  /// Uses real Tox connection status; ensures self is connected to DHT before waiting for friend online.
  Future<void> waitForFriendConnection(String friendUserId,
      {Duration? timeout}) async {
    final connectionTimeout = timeout ?? const Duration(seconds: 45);
    final deadline = DateTime.now().add(connectionTimeout);
    final startedAt = DateTime.now();
    int checkCount = 0;

    // Extract public key (64 chars) from friendUserId if it's a full Tox ID (76 chars)
    final friendPublicKey = friendUserId.length >= 64
        ? friendUserId.substring(0, 64)
        : friendUserId;
    final targetAbbrev = friendPublicKey.length > 16
        ? '${friendPublicKey.substring(0, 16)}...'
        : friendPublicKey;

    print(
        '[waitForFriendConnection] ENTRY node=$alias target=$targetAbbrev timeout=${connectionTimeout.inSeconds}s');
    bool friendInList = false;
    int? lastRole;
    await runWithInstanceAsync(() async {
      // Ensure self is connected to DHT (real Tox connection_status) before waiting for friend online
      try {
        await waitForConnection(timeout: const Duration(seconds: 10));
      } catch (e) {
        print(
            '[waitForFriendConnection] Warning: self not yet connected to DHT: $e');
      }
      while (DateTime.now().isBefore(deadline)) {
        checkCount++;
        final elapsed = DateTime.now().difference(startedAt);
        final friendListResult =
            await TIMFriendshipManager.instance.getFriendList();

        if (friendListResult.code != 0) {
          if (friendListResult.code == 6013) {
            throw TimeoutException(
                'getFriendList returned 6013 (sdk not init). Teardown may have started; aborting waitForFriendConnection.');
          }
          if (checkCount <= 3 || checkCount % 10 == 0) {
            print(
                '[waitForFriendConnection] Check $checkCount (elapsed=${elapsed.inSeconds}s): getFriendList code=${friendListResult.code} desc=${friendListResult.desc}');
          }
        } else if (friendListResult.data != null) {
          final list = friendListResult.data!;
          bool matchesFriend(String uid) =>
              uid == friendPublicKey ||
              (uid.length >= 64 && uid.startsWith(friendPublicKey));
          final matchingFriends =
              list.where((f) => matchesFriend(f.userID)).toList();

          if (checkCount <= 2 || checkCount % 10 == 1) {
            print(
                '[waitForFriendConnection] Check $checkCount (elapsed=${elapsed.inSeconds}s): listLen=${list.length} '
                'friendIds=[${list.map((f) => f.userID.length > 12 ? f.userID.substring(0, 12) + '...' : f.userID).join(', ')}]');
          }

          if (matchingFriends.isNotEmpty) {
            final friendInfo = matchingFriends.first;
            friendInList = true;
            final role = friendInfo.userProfile?.role;
            lastRole = role;
            final userProfile = friendInfo.userProfile;

            if (checkCount <= 3 || checkCount % 5 == 0) {
              print(
                  '[waitForFriendConnection] Check $checkCount (elapsed=${elapsed.inSeconds}s): Friend IN LIST '
                  'role=$role (1=ONLINE, 2=OFFLINE) userProfile?.role=${userProfile?.role}');
            }

            final isOnline =
                friendInfo.userProfile?.role == 1; // V2TIM_USER_STATUS_ONLINE

            if (isOnline == true) {
              print(
                  '[waitForFriendConnection] ✅ Friend $targetAbbrev is online after $checkCount checks (elapsed=${elapsed.inSeconds}s)');
              await Future.delayed(const Duration(milliseconds: 500));
              return;
            } else {
              if (checkCount <= 8 || checkCount % 10 == 0) {
                print(
                    '[waitForFriendConnection] (elapsed=${elapsed.inSeconds}s) Friend in list but OFFLINE role=$role checkCount=$checkCount');
              }
            }
          } else {
            if (friendInList) {
              if (checkCount % 10 == 0) {
                print(
                    '[waitForFriendConnection] WARNING (elapsed=${elapsed.inSeconds}s): Friend was in list but now NOT FOUND');
              }
            } else {
              if (checkCount <= 5 || checkCount % 10 == 0) {
                print(
                    '[waitForFriendConnection] Check $checkCount (elapsed=${elapsed.inSeconds}s): Friend NOT in list '
                    'availableIds=[${list.map((f) => f.userID.length > 12 ? f.userID.substring(0, 12) + '...' : f.userID).join(', ')}]');
              }
            }
          }
        } else {
          if (checkCount <= 3 || checkCount % 10 == 0) {
            print(
                '[waitForFriendConnection] Check $checkCount (elapsed=${elapsed.inSeconds}s): getFriendList code=0 but data=null');
          }
        }

        if (checkCount % 20 == 0) {
          print(
              '[waitForFriendConnection] PROGRESS elapsed=${elapsed.inSeconds}s checkCount=$checkCount friendInList=$friendInList lastRole=$lastRole');
        }

        // Pump all instances so Tox can establish P2P (otherwise we only poll and connection never establishes)
        pumpAllInstancesOnce(iterations: 150);
        await Future.delayed(const Duration(milliseconds: 250));
      }

      final elapsedTotal = DateTime.now().difference(startedAt);
      final finalFriendListResult =
          await TIMFriendshipManager.instance.getFriendList();
      if (finalFriendListResult.code == 6013) {
        throw TimeoutException(
            'getFriendList returned 6013 (sdk not init) at end of waitForFriendConnection. Teardown may have started.');
      }
      bool matchesFriend(String uid) =>
          uid == friendPublicKey ||
          (uid.length >= 64 && uid.startsWith(friendPublicKey));
      final hasFriend = finalFriendListResult.code == 0 &&
          finalFriendListResult.data != null &&
          finalFriendListResult.data!.any((f) => matchesFriend(f.userID));

      print(
          '[waitForFriendConnection] TIMEOUT after ${elapsedTotal.inSeconds}s checkCount=$checkCount');
      print(
          '[waitForFriendConnection] FINAL getFriendList code=${finalFriendListResult.code} '
          'dataLen=${finalFriendListResult.data?.length ?? 0}');
      if (finalFriendListResult.data != null &&
          finalFriendListResult.data!.isNotEmpty) {
        for (int i = 0; i < finalFriendListResult.data!.length; i++) {
          final f = finalFriendListResult.data![i];
          final uid = f.userID;
          final role = f.userProfile?.role;
          final match = matchesFriend(uid);
          print(
              '[waitForFriendConnection]   friend[$i] userID=${uid.length > 20 ? uid.substring(0, 20) + '...' : uid} '
              'role=$role (1=ONLINE,2=OFFLINE) matchesTarget=$match');
        }
      } else {
        print('[waitForFriendConnection]   (no friends in list or data null)');
      }
      print(
          '[waitForFriendConnection] FINAL hasFriend=$hasFriend lastRole=$lastRole');

      throw TimeoutException(
          'Timeout waiting for friend connection: $friendPublicKey (timeout: $connectionTimeout). '
          'Final state: friend in list=$hasFriend lastRole=$lastRole elapsed=${elapsedTotal.inSeconds}s. '
          'This may indicate that nodes are not connected to each other (check bootstrap configuration).');
    });
  }

  /// Get the actual Tox ID for this node (76 hex characters: public key +
  /// nospam + checksum). In multi-instance scenarios, this returns the Tox
  /// ID for the current instance.
  ///
  /// Previously this called [TIMManager.instance.getLoginUser], but that
  /// returns the login alias (the userID passed to `Login()`), not the Tox
  /// address. Switched to the `tim2tox_ffi_get_self_tox_id` FFI export so
  /// callers like [establishFriendship] get the real address.
  String getToxId() {
    if (_toxIdCache != null && _toxIdCache!.isNotEmpty) {
      return _toxIdCache!;
    }
    final ffiInstance = ffi_lib.Tim2ToxFfi.open();
    final toxId = runWithInstance(() {
      final buf = pkgffi.malloc.allocate<ffi.Int8>(256);
      try {
        final n = ffiInstance.getSelfToxId(buf, 256);
        if (n <= 0) return '';
        return buf.cast<pkgffi.Utf8>().toDartString();
      } finally {
        pkgffi.malloc.free(buf);
      }
    });
    if (toxId.isNotEmpty) {
      _toxIdCache = toxId;
    }
    return toxId;
  }

  /// Clear Tox ID cache (call when node is reinitialized or logged out)
  void clearToxIdCache() {
    _toxIdCache = null;
  }

  /// Get public key (64 characters) from Tox ID (76 characters)
  /// In c-toxcore, friend request callbacks use public_key (32 bytes = 64 hex chars)
  /// while getLoginUser() returns full Tox address (38 bytes = 76 hex chars)
  /// This function extracts the first 64 characters (public key) from the full address
  String getPublicKey() {
    final fullToxId = getToxId();
    // Tox address format: [32-byte public key][4-byte nospam][2-byte checksum] = 38 bytes = 76 hex chars
    // Public key is the first 32 bytes = 64 hex chars
    if (fullToxId.length >= 64) {
      return fullToxId.substring(0, 64);
    }
    // If already 64 chars or less, return as-is (shouldn't happen, but handle gracefully)
    return fullToxId;
  }

  /// Get friend list (with caching)
  Future<List<String>> getFriendList({bool useCache = true}) async {
    final now = DateTime.now();
    if (useCache && _friendListCache != null && _friendListCacheTime != null) {
      final cacheAge = now.difference(_friendListCacheTime!);
      if (cacheAge.inSeconds < 2) {
        return _friendListCache!;
      }
    }

    final result = await runWithInstanceAsync(
        () async => TIMFriendshipManager.instance.getFriendList());
    if (result.code != 0) {}
    if (result.code == 0 && result.data != null && result.data!.isNotEmpty) {
      _friendListCache = result.data!.map((f) => f.userID).toList();
      _friendListCacheTime = now;
      // Log each friend's userID with its length for debugging
      for (var _ in result.data!) {}
      return _friendListCache!;
    }
    if (result.code == 0 && result.data != null && result.data!.isEmpty) {
    } else {}
    return [];
  }

  /// Get friend list result (full callback) in this node's instance. Use when test needs to assert on result.code.
  Future<dynamic> getFriendListResultWithInstance() async =>
      runWithInstanceAsync(
          () async => TIMFriendshipManager.instance.getFriendList());

  /// Get conversation list in this node's instance.
  Future<dynamic> getConversationListWithInstance(
          {required String nextSeq, required int count}) async =>
      runWithInstanceAsync(() async => TIMConversationManager.instance
          .getConversationList(nextSeq: nextSeq, count: count));

  /// Check if a user is in friend list
  Future<bool> isFriend(String userId) async {
    final friends = await getFriendList();
    return friends.contains(userId);
  }

  /// Wait for self connection status callback
  /// With local bootstrap, connection status should be available quickly (1-5 seconds)
  Future<void> waitForSelfConnectionStatus({Duration? timeout}) async {
    if (connectionStatusCalled) {
      return;
    }

    final deadline = DateTime.now().add(timeout ?? const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (connectionStatusCalled) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    throw TimeoutException(
        'Timeout waiting for self connection status callback');
  }

  /// Get connection status (0=NONE, 1=TCP, 2=UDP)
  /// Uses real Tox connection status from FFI
  int getConnectionStatus() {
    if (!loggedIn) {
      return 0;
    }
    return runWithInstance(() {
      try {
        final ffiInstance = ffi_lib.Tim2ToxFfi.open();
        final status = ffiInstance.getSelfConnectionStatus();
        return status;
      } catch (e) {
        print(
            '[Test] Warning: getSelfConnectionStatus() failed: $e, falling back to login status');
        final loginStatus = timManager?.getLoginStatus() ?? 0;
        return loginStatus == 1 ? 2 : 0; // Assume UDP if logged in
      }
    });
  }

  /// Cleanup resources
  Future<void> dispose() async {
    await _connectionStatusSub?.cancel();
    await _messagesSub?.cancel();
    await unInitSDK();
  }
}

/// Wait until a condition is true
/// Similar to c-toxcore's WAIT_UNTIL macro
/// Wait until condition is true
/// With local bootstrap, conditions should be met quickly (1-5 seconds)
/// Optimization: Use 200ms poll interval for better performance (reduced CPU usage)
Future<void> waitUntil(
  bool Function() condition, {
  Duration? timeout,
  Duration pollInterval = const Duration(milliseconds: 200),
  String? description,
}) async {
  final actualTimeout = timeout ?? const Duration(seconds: 10);
  final deadline = DateTime.now().add(actualTimeout);
  final desc = description ?? 'condition';
  int checkCount = 0;

  while (DateTime.now().isBefore(deadline)) {
    checkCount++;
    bool result;
    try {
      result = condition();
    } catch (e) {
      rethrow;
    }

    if (result) {
      return;
    }
    if (checkCount % 10 == 0) {}
    await Future.delayed(pollInterval);
  }

  // Final check to see what the condition evaluates to
  try {
    condition();
  } catch (e) {}
  throw TimeoutException('Timeout waiting for $desc (timeout: $actualTimeout)');
}

/// Async sibling of [waitUntil]: polls an `async` predicate until it returns
/// true or the timeout elapses. Use when the condition requires an awaited
/// call (e.g. `getFriendList`, `getFriendApplicationList`, network state).
/// A fixed `await Future.delayed(...)` would wait the worst-case duration
/// every time; this returns as soon as the condition holds.
Future<void> waitUntilAsync(
  Future<bool> Function() condition, {
  Duration? timeout,
  Duration pollInterval = const Duration(milliseconds: 200),
  String? description,
}) async {
  final actualTimeout = timeout ?? const Duration(seconds: 10);
  final deadline = DateTime.now().add(actualTimeout);
  final desc = description ?? 'async condition';
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future.delayed(pollInterval);
  }
  // Final attempt so failure messages reflect the latest probe rather than a
  // stale view from one poll interval ago.
  if (await condition()) return;
  throw TimeoutException('Timeout waiting for $desc (timeout: $actualTimeout)');
}

/// Wait for condition while pumping Tox on all instances (so file transfer / callbacks can progress).
/// [onEachLoop] If provided, called each loop after iterateAllInstances (e.g. trigger poll to consume file_request/progress).
Future<void> waitUntilWithPump(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
  String description = 'condition',
  int iterationsPerPump = 50,
  Duration stepDelay = const Duration(milliseconds: 400),
  void Function()? onEachLoop,
}) async {
  final deadline = DateTime.now().add(timeout);
  final ffiInstance = ffi_lib.Tim2ToxFfi.open();
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    ffiInstance.iterateAllInstances(iterationsPerPump);
    onEachLoop?.call();
    await Future.delayed(stepDelay);
  }
  throw TimeoutException(
      'Timeout waiting for $description (timeout: $timeout)');
}

/// Waits until [node]'s getJoinedGroupList no longer contains [groupId] (e.g. after quit).
/// Polls with pump so Dart/C++ state can sync. Use after quitGroup to avoid assert on sync delay.
Future<void> waitUntilJoinedListExcludesGroup(
  TestNode node,
  String groupId, {
  Duration timeout = const Duration(seconds: 15),
  int iterationsPerPump = 50,
  Duration stepDelay = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  final ffiInstance = ffi_lib.Tim2ToxFfi.open();
  while (DateTime.now().isBefore(deadline)) {
    final result = await node.runWithInstanceAsync(
        () async => TIMGroupManager.instance.getJoinedGroupList());
    if (result.code == 0 && result.data != null) {
      final contains = result.data!.any((g) => g.groupID == groupId);
      if (!contains) return;
    }
    ffiInstance.iterateAllInstances(iterationsPerPump);
    await Future.delayed(stepDelay);
  }
  throw TimeoutException(
      'Joined list still contained group $groupId after $timeout');
}

/// Run a single short pump on all instances (e.g. inside waitForFriendConnection so Tox can establish P2P).
void pumpAllInstancesOnce({int iterations = 50}) {
  final ffiInstance = ffi_lib.Tim2ToxFfi.open();
  ffiInstance.iterateAllInstances(iterations);
}

/// Pump Tox iterate on all test instances to accelerate friend P2P connection.
/// Call after establishFriendship so both Tox instances get enough iterations to establish
/// tox_friend_get_connection_status != NONE. Uses a single FFI iterate-all for fewer round-trips.
Future<void> pumpFriendConnection(
  TestNode nodeA,
  TestNode nodeB, {
  Duration duration = const Duration(seconds: 4),
  int iterationsPerPump = 50,
  Duration stepDelay = const Duration(milliseconds: 40),
}) async {
  final deadline = DateTime.now().add(duration);
  final ffiInstance = ffi_lib.Tim2ToxFfi.open();
  while (DateTime.now().isBefore(deadline)) {
    ffiInstance.iterateAllInstances(iterationsPerPump);
    await Future.delayed(stepDelay);
  }
}

/// Pump Tox iterate on all test instances to accelerate group peer discovery (PRIVATE groups use friend connection).
/// Call after one node joins a group so the other node's Tox can process peer list over friend link.
Future<void> pumpGroupPeerDiscovery(
  TestNode nodeA,
  TestNode nodeB, {
  Duration duration = const Duration(seconds: 5),
  int iterationsPerPump = 30,
  Duration stepDelay = const Duration(milliseconds: 50),
}) async {
  final deadline = DateTime.now().add(duration);
  final ffiInstance = ffi_lib.Tim2ToxFfi.open();
  while (DateTime.now().isBefore(deadline)) {
    ffiInstance.iterateAllInstances(iterationsPerPump);
    await Future.delayed(stepDelay);
  }
}

bool _matchesPublicKeyOrToxId(String candidate, String publicKey) {
  return candidate == publicKey ||
      (candidate.length >= 64 && candidate.startsWith(publicKey));
}

/// Waits until [founder] sees at least one non-self member in the target group member list.
/// Each loop: pumps both nodes so founder's Tox processes peer updates, then polls getGroupMemberList.
/// Use this instead of inlining pump + getGroupMemberList loops in moderation tests.
///
/// Returns the first non-founder userID seen by [founder], or null on timeout.
/// If [allowFallbackProceed] is true, legacy fallback behavior is used (not recommended for strict tests).
Future<String?> waitUntilFounderSeesMemberInGroup(
  TestNode founder,
  TestNode otherNode,
  String groupId, {
  Duration timeout = const Duration(seconds: 90),
  Duration pumpDurationPerLoop = const Duration(milliseconds: 600),
  int iterationsPerPump = 50,
  Duration stepDelay = const Duration(milliseconds: 50),
  Duration delayAfterPump = const Duration(milliseconds: 150),
  bool allowFallbackProceed = false,
}) async {
  final founderPublicKey = founder.getPublicKey();
  final otherPublicKey = otherNode.getPublicKey();
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await pumpGroupPeerDiscovery(
      founder,
      otherNode,
      duration: pumpDurationPerLoop,
      iterationsPerPump: iterationsPerPump,
      stepDelay: stepDelay,
    );
    await Future.delayed(delayAfterPump);
    final listResult = await founder.runWithInstanceAsync(
        () async => TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
              count: 100,
            ));
    if (listResult.code == 0 && listResult.data?.memberInfoList != null) {
      final nonFounder = listResult.data!.memberInfoList!
          .where((m) => !_matchesPublicKeyOrToxId(m.userID, founderPublicKey))
          .toList();
      if (nonFounder.isNotEmpty) {
        return nonFounder.first.userID;
      }
    }
  }

  // Diagnostics/fallback: founder-side visibility may lag in PUBLIC groups.
  // By default we DO NOT proceed to avoid false positives that later cause message-delivery timeouts.
  try {
    final otherListResult = await otherNode.runWithInstanceAsync(
        () async => TIMGroupManager.instance.getGroupMemberList(
              groupID: groupId,
              filter: GroupMemberFilterTypeEnum.V2TIM_GROUP_MEMBER_FILTER_ALL,
              nextSeq: '0',
              count: 100,
            ));
    final otherMembers = otherListResult.data?.memberInfoList;
    if (otherListResult.code == 0 && otherMembers != null) {
      final selfVisible = otherMembers
          .any((m) => _matchesPublicKeyOrToxId(m.userID, otherPublicKey));
      final founderVisibleFromOther = otherMembers
          .any((m) => _matchesPublicKeyOrToxId(m.userID, founderPublicKey));
      if (selfVisible) {
        if (allowFallbackProceed) {
          print(
              '[waitUntilFounderSeesMemberInGroup] founder visibility timeout for $groupId, but ${otherNode.alias} can see self in member list; proceeding due to allowFallbackProceed');
          return otherPublicKey;
        }
        print(
            '[waitUntilFounderSeesMemberInGroup] founder visibility timeout for $groupId: ${founder.alias} still cannot see any non-self member. '
            '${otherNode.alias} selfVisible=true founderVisibleFromOther=$founderVisibleFromOther');
      }
    }
  } catch (_) {
    // Ignore diagnostic errors and continue.
  }

  try {
    final joinedResult = await otherNode.runWithInstanceAsync(
        () async => TIMGroupManager.instance.getJoinedGroupList());
    final joined = joinedResult.code == 0 &&
        (joinedResult.data?.any((g) => g.groupID == groupId) ?? false);
    if (joined) {
      if (allowFallbackProceed) {
        print(
            '[waitUntilFounderSeesMemberInGroup] founder visibility timeout for $groupId, but ${otherNode.alias} joined list contains group; proceeding due to allowFallbackProceed');
        return otherPublicKey;
      }
      print(
          '[waitUntilFounderSeesMemberInGroup] founder visibility timeout for $groupId: ${otherNode.alias} joined list contains group, but ${founder.alias} still cannot see any non-self member');
    }
  } catch (_) {
    // Keep behavior backward-compatible: timeout returns null.
  }

  return null;
}

/// Returns the 64-char hex chat_id for the given [instanceId] and logical [groupId], or null.
/// Used to test "join public group by chat_id only" (single-account / no-invite path).
String? getGroupChatIdForInstance(int instanceId, String groupId) {
  final ffiInstance = ffi_lib.Tim2ToxFfi.open();
  final groupIDNative = groupId.toNativeUtf8();
  try {
    final buffer = pkgffi.malloc<ffi.Int8>(65);
    try {
      final result = ffiInstance.getGroupChatIdNative(
          instanceId, groupIDNative, buffer, 65);
      if (result == 1) {
        return buffer.cast<pkgffi.Utf8>().toDartString();
      }
      return null;
    } finally {
      pkgffi.malloc.free(buffer);
    }
  } finally {
    pkgffi.malloc.free(groupIDNative);
  }
}

/// Wait for an event from a stream
Future<T> waitForEvent<T>(
  Stream<T> stream, {
  Duration? timeout,
  bool Function(T)? predicate,
}) async {
  final completer = Completer<T>();
  late StreamSubscription sub;

  sub = stream.listen((event) {
    if (predicate == null || predicate(event)) {
      completer.complete(event);
      sub.cancel();
    }
  });

  try {
    return await completer.future.timeout(
      timeout ?? const Duration(seconds: 30),
      onTimeout: () {
        sub.cancel();
        throw TimeoutException('Timeout waiting for event');
      },
    );
  } catch (e) {
    sub.cancel();
    rethrow;
  }
}

/// Helper to wait for friend list to contain specific users
/// Wait for friends to appear in friend list
/// With local bootstrap, friends should appear quickly (2-10 seconds)
Future<void> waitForFriendsInList(
  TestNode node,
  List<String> userIds, {
  Duration? timeout,
}) async {
  final deadline = DateTime.now().add(timeout ?? const Duration(seconds: 15));
  int checkCount = 0;
  while (DateTime.now().isBefore(deadline)) {
    checkCount++;
    final friends = await node.getFriendList();
    if (userIds.every((id) => friends.contains(id))) {
      return;
    }
    await Future.delayed(const Duration(milliseconds: 500));
  }
  final finalFriends = await node.getFriendList();
  final missing = userIds.where((id) => !finalFriends.contains(id)).toList();
  throw TimeoutException(
      'Timeout waiting for friends ${userIds.join(", ")} in list after $checkCount checks. Missing: ${missing.join(", ")}');
}

/// Helper to establish bidirectional friendship
/// Note: Uses actual Tox IDs from getLoginUser(), not TestNode.userId
/// With local bootstrap, friendship should establish quickly (2-10 seconds)
Future<void> establishFriendship(TestNode alice, TestNode bob,
    {Duration? timeout}) async {
  // P2P wait is 90s each; allow time for friend-list loop + pump + both P2P waits
  final friendshipTimeout = timeout ?? const Duration(seconds: 200);
  final deadline = DateTime.now().add(friendshipTimeout);

  print(
      '[establishFriendship] Starting friendship establishment between ${alice.alias} and ${bob.alias}');

  // Check if nodes are logged in first
  if (!alice.loggedIn || !bob.loggedIn) {
    throw Exception(
        'Cannot establish friendship: nodes must be logged in first');
  }

  // Ensure both nodes auto-accept friend requests (so addFriend + pump leads to mutual friend list)
  alice.enableAutoAccept();
  bob.enableAutoAccept();

  // Wait for both nodes to have real Tox DHT connection (tox_self_get_connection_status != NONE)
  try {
    await alice.waitForConnection(timeout: const Duration(seconds: 10));
    await bob.waitForConnection(timeout: const Duration(seconds: 10));
    if (alice.getConnectionStatus() == 0 || bob.getConnectionStatus() == 0) {
      print(
          '[establishFriendship] Warning: One or both nodes still have connection_status=0 after wait');
    }
  } catch (e) {
    print(
        '[establishFriendship] Warning: Nodes may not be fully connected: $e');
    // Continue anyway, as connection may establish during friend request
  }

  // Get actual Tox IDs (not TestNode.userId which is just a test identifier)
  final aliceToxId = alice.getToxId();
  final bobToxId = bob.getToxId();
  print('[establishFriendship] ${alice.alias} Tox ID: $aliceToxId');
  print('[establishFriendship] ${bob.alias} Tox ID: $bobToxId');

  if (aliceToxId.isEmpty || aliceToxId.length != 76) {
    throw Exception(
        'Invalid Alice Tox ID: $aliceToxId (expected 76 hex characters)');
  }
  if (bobToxId.isEmpty || bobToxId.length != 76) {
    throw Exception(
        'Invalid Bob Tox ID: $bobToxId (expected 76 hex characters)');
  }

  // Extract public keys (64 chars) from full Tox IDs (76 chars) for friend list comparison
  // Friend list returns public keys, not full Tox addresses
  final alicePublicKey = aliceToxId.substring(0, 64);
  final bobPublicKey = bobToxId.substring(0, 64);
  print('[establishFriendship] ${alice.alias} Public Key: $alicePublicKey');
  print('[establishFriendship] ${bob.alias} Public Key: $bobPublicKey');

  // Alice adds Bob (using Bob's actual Tox ID)
  print(
      '[establishFriendship] ${alice.alias} adding ${bob.alias} as friend (Tox ID: $bobToxId)...');
  final aliceAddResult = await alice
      .runWithInstanceAsync(() async => TIMFriendshipManager.instance.addFriend(
            userID: bobToxId, // Use actual Tox ID, not bob.userId
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
            addWording:
                'Hello from Alice', // Use addWording instead of remark for Tox friend request message
          ));
  if (aliceAddResult.code != 0) {
    print(
        '[establishFriendship] Warning: ${alice.alias} addFriend returned code ${aliceAddResult.code}: ${aliceAddResult.desc}');
  } else {
    print(
        '[establishFriendship] ✅ ${alice.alias} successfully added ${bob.alias} as friend');
  }

  // Bob adds Alice (using Alice's actual Tox ID)
  print(
      '[establishFriendship] ${bob.alias} adding ${alice.alias} as friend (Tox ID: $aliceToxId)...');
  final bobAddResult = await bob
      .runWithInstanceAsync(() async => TIMFriendshipManager.instance.addFriend(
            userID: aliceToxId, // Use actual Tox ID, not alice.userId
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
            addWording:
                'Hello from Bob', // Use addWording instead of remark for Tox friend request message
          ));
  if (bobAddResult.code != 0) {
    print(
        '[establishFriendship] Warning: ${bob.alias} addFriend returned code ${bobAddResult.code}: ${bobAddResult.desc}');
  } else {
    print(
        '[establishFriendship] ✅ ${bob.alias} successfully added ${alice.alias} as friend');
  }

  // Give Tox CPU time to deliver friend requests and run auto-accept callbacks
  print(
      '[establishFriendship] Pumping Tox so friend requests can be delivered and auto-accepted...');
  await pumpFriendConnection(alice, bob,
      duration: const Duration(seconds: 6),
      stepDelay: const Duration(milliseconds: 25));
  await Future.delayed(const Duration(seconds: 2)); // Allow listener processing

  // Wait until both see each other as friends
  // tim2tox may return 64-char public key or 76-char Tox ID in friend list
  bool listContainsPublicKey(List<String> list, String publicKey) => list.any(
      (id) => id == publicKey || (id.length >= 64 && id.startsWith(publicKey)));
  int checkCount = 0;
  while (DateTime.now().isBefore(deadline)) {
    checkCount++;
    pumpAllInstancesOnce(
        iterations: 120); // So both instances process friend list updates
    final aliceFriends = await alice.getFriendList();
    final bobFriends = await bob.getFriendList();
    final aliceHasBob = listContainsPublicKey(aliceFriends, bobPublicKey);
    final bobHasAlice = listContainsPublicKey(bobFriends, alicePublicKey);

    if (aliceHasBob && bobHasAlice) {
      print(
          '[establishFriendship] ✅ Bidirectional friendship established after ${checkCount} checks');
      // Respect caller's total timeout: use remaining time for pump + waitForFriendConnection
      final remaining = deadline.difference(DateTime.now());
      if (remaining.inSeconds < 2) {
        print(
            '[establishFriendship] ⚠️ Little time left in timeout, skipping P2P wait');
        return;
      }
      // Pump Tox so P2P can establish (local bootstrap: short pump is enough)
      const pumpDuration = Duration(seconds: 3);
      final actualPump = remaining.inSeconds > 10
          ? pumpDuration
          : Duration(seconds: remaining.inSeconds > 5 ? 2 : 1);
      print(
          '[establishFriendship] Pumping Tox for P2P connection (${actualPump.inSeconds}s)...');
      await pumpFriendConnection(alice, bob, duration: actualPump);
      // Cap P2P wait by caller's remaining timeout; use at least 15s each so local bootstrap can establish
      final remainingForP2P = deadline.difference(DateTime.now());
      const minWaitSec = 15;
      final halfRemaining =
          remainingForP2P.inSeconds >= 2 ? (remainingForP2P.inSeconds ~/ 2) : 0;
      final waitEachSec = remainingForP2P.inSeconds >= 4
          ? (halfRemaining > 60
              ? 60
              : (halfRemaining < minWaitSec ? minWaitSec : halfRemaining))
          : remainingForP2P.inSeconds.clamp(1, 60);
      final waitEach = Duration(seconds: waitEachSec);
      // Run sequentially to avoid instance switching. P2P wait is best-effort so callers can retry in tests.
      print(
          '[establishFriendship] Waiting for Tox P2P connection (${waitEach.inSeconds}s each, remaining=${remainingForP2P.inSeconds}s)...');
      try {
        await alice.waitForFriendConnection(bobToxId, timeout: waitEach);
        await bob.waitForFriendConnection(aliceToxId, timeout: waitEach);
        print('[establishFriendship] ✅ Both sides see friend as ONLINE');
      } catch (e) {
        print(
            '[establishFriendship] ⚠️ P2P wait timed out (friend list is established; tests may retry): $e');
      }
      return;
    }

    if (checkCount % 5 == 0) {
      print(
          '[establishFriendship] Check $checkCount: alice has bob=$aliceHasBob, bob has alice=$bobHasAlice');
      print(
          '[establishFriendship] Check $checkCount: aliceFriends=${aliceFriends.join(", ")}, bobFriends=${bobFriends.join(", ")}');
    }

    await Future.delayed(const Duration(milliseconds: 400));
  }

  final finalAliceFriends = await alice.getFriendList();
  final finalBobFriends = await bob.getFriendList();
  final finalAliceHasBob =
      listContainsPublicKey(finalAliceFriends, bobPublicKey);
  final finalBobHasAlice =
      listContainsPublicKey(finalBobFriends, alicePublicKey);

  throw TimeoutException(
      'Timeout waiting for bidirectional friendship to be established (timeout: $friendshipTimeout). '
      'Final state: alice has bob=$finalAliceHasBob, bob has alice=$finalBobHasAlice. '
      'aliceFriends=${finalAliceFriends.join(", ")}, bobFriends=${finalBobFriends.join(", ")}. '
      'This may indicate that nodes are not connected to each other (check bootstrap configuration).');
}

/// Configure local bootstrap for test scenario
/// Similar to C test's tox_node_bootstrap mechanism
/// First node acts as bootstrap node, other nodes bootstrap from it using 127.0.0.1
///
/// Each node now has its own V2TIMManagerImpl instance, so we need to:
/// 1. Set the bootstrap node as current instance to get its port and DHT ID
/// 2. For each other node, set it as current instance and add bootstrap node
Future<void> configureLocalBootstrap(TestScenario scenario) async {
  final stopwatch = Stopwatch()..start();

  if (scenario.nodes.length < 2) {
    print(
        '[Bootstrap] SKIP: need at least 2 nodes, have ${scenario.nodes.length}');
    return;
  }

  print(
      '[Bootstrap] START (T+0ms) nodes=${scenario.nodes.map((n) => n.alias).join(', ')}');
  // First node acts as bootstrap node
  final bootstrapNode = scenario.nodes[0];

  // Wait for bootstrap node to be connected
  await Future.delayed(const Duration(milliseconds: 500));
  print(
      '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: after initial 500ms delay');

  // Get bootstrap node's UDP port and DHT ID (within bootstrap node's instance scope)
  final portAndDhtId = await bootstrapNode.runWithInstanceAsync(() async {
    final ffiInstance = ffi_lib.Tim2ToxFfi.open();
    int port = 0;
    for (int retry = 0; retry < 5; retry++) {
      port = ffiInstance.getUdpPort(ffiInstance.getCurrentInstanceId());
      if (retry % 2 == 0) {
        print(
            '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: getUdpPort() attempt ${retry + 1} for ${bootstrapNode.alias}: $port');
      }
      if (port > 0) {
        final loginStatus = TIMManager.instance.getLoginStatus();
        if (loginStatus == 1) {
          print(
              '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: Bootstrap node ${bootstrapNode.alias} ready port=$port loginStatus=$loginStatus');
          break;
        } else {
          print(
              '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: ${bootstrapNode.alias} port=$port loginStatus=$loginStatus (not yet 1)');
        }
      }
      if (retry < 4) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    if (port == 0) return (0, '');
    final dhtIdBuf = pkgffi.malloc.allocate<ffi.Int8>(65);
    try {
      final dhtIdLen = ffiInstance.getDhtIdNative(dhtIdBuf, 65);
      if (dhtIdLen == 0 || dhtIdLen > 64) {
        print(
            '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: getDhtIdNative returned len=$dhtIdLen');
        return (0, '');
      }
      final dhtId = dhtIdBuf.cast<pkgffi.Utf8>().toDartString(length: dhtIdLen);
      print(
          '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: Bootstrap node ${bootstrapNode.alias} port=$port dhtId=${dhtId.length}chars');
      return (port, dhtId);
    } finally {
      pkgffi.malloc.free(dhtIdBuf);
    }
  });

  final port = portAndDhtId.$1;
  final dhtId = portAndDhtId.$2;
  if (port == 0 || dhtId.isEmpty) {
    print(
        '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: ERROR cannot get port or dhtId (port=$port dhtIdLen=${dhtId.length})');
    return;
  }

  // Configure all other nodes to bootstrap from the first node
  for (int i = 1; i < scenario.nodes.length; i++) {
    final node = scenario.nodes[i];
    if (node.testInstanceHandle == null) {
      print(
          '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: WARNING ${node.alias} has no test instance handle');
      continue;
    }
    await node.runWithInstanceAsync(() async {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      final hostPtr = '127.0.0.1'.toNativeUtf8();
      final dhtIdPtr = dhtId.toNativeUtf8();
      try {
        print(
            '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: Adding bootstrap for ${node.alias} 127.0.0.1:$port');
        final success = ffiInstance.addBootstrapNode(
            ffiInstance.getCurrentInstanceId(), hostPtr, port, dhtIdPtr);
        if (success == 1) {
          print(
              '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: OK ${node.alias} bootstrap added');
        } else {
          print(
              '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: FAIL ${node.alias} addBootstrapNode returned $success');
        }
      } finally {
        pkgffi.malloc.free(hostPtr);
        pkgffi.malloc.free(dhtIdPtr);
      }
    });
  }

  print(
      '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: Waiting for all nodes to connect (timeout 10s each)...');
  await Future.wait(
    scenario.nodes.map((node) async {
      final nodeStopwatch = Stopwatch()..start();
      try {
        await node.waitForConnection(timeout: const Duration(seconds: 10));
        print(
            '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: Node ${node.alias} connected to Tox (took ${nodeStopwatch.elapsedMilliseconds}ms)');
      } catch (e) {
        print(
            '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: Node ${node.alias} connection TIMEOUT after ${nodeStopwatch.elapsedMilliseconds}ms: $e');
      }
    }),
  );

  print(
      '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: Waiting for all nodes real Tox connection (connection_status != 0, timeout 10s)...');
  try {
    await waitUntil(
      () {
        bool allConnected = true;
        for (final node in scenario.nodes) {
          final status = node.getConnectionStatus();
          if (status == 0) {
            allConnected = false;
            break;
          }
        }
        return allConnected;
      },
      timeout: const Duration(seconds: 10),
      pollInterval: const Duration(milliseconds: 200),
      description: 'all nodes connected to DHT (real connection_status)',
    );
    print(
        '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: All nodes connection_status != 0');
  } catch (e) {
    print(
        '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: waitUntil all connected failed: $e');
  }

  stopwatch.stop();
  print('[Bootstrap] DONE at T+${stopwatch.elapsedMilliseconds}ms total');
}
