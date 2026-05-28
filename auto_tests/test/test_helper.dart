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
          // V2TIM onMemberInvited fires on EVERY current group member when a
          // new member is invited (so existing members can refresh their UI).
          // Auto_tests use this as a stand-in for "I was invited" (there is
          // no separate onSelfInvited callback) but if we mark it
          // unconditionally, later invites to other members overwrite the
          // local node's stored invite groupID — joinGroup then receives a
          // groupID for which we have no pending invite and returns 6017
          // "Pending invite not found".
          //
          // Filter: only treat this as "I was invited" when the invited
          // memberList contains this node's public key. The C++
          // HandleGroupInvite pushes self into memberList right before
          // firing onMemberInvited (V2TIMManagerImpl.cpp ~580), so on the
          // invitee's side memberList[0].userID == self's 64-char public key.
          // On peer (existing-member) sides, memberList[0].userID is the
          // newly-invited peer's public key, NOT ours, so we skip.
          //
          // Read self's pubkey from the existing cache rather than calling
          // getPublicKey() here — getPublicKey()->getToxId()->runWithInstance
          // would re-enter the instance switching machinery from inside a
          // dispatch callback. That has caused getToxId() to transiently
          // return an empty string when establishFriendshipVirtual is racing
          // with this listener firing during setUpAll (symptom:
          // "Invalid Alice Tox ID:  (expected 76 hex characters)"). If the
          // cache isn't populated yet (listener fires before any test code
          // has called getToxId() once), fall back to legacy "mark
          // unconditionally" behaviour — better to flake the way we used to
          // than to silently drop a self-invite.
          String selfPk = '';
          final cachedToxId = _toxIdCache;
          if (cachedToxId != null && cachedToxId.length >= 64) {
            selfPk = cachedToxId.substring(0, 64).toUpperCase();
          }
          bool isForSelf = selfPk.isEmpty;
          if (!isForSelf && memberList.isNotEmpty) {
            for (final m in memberList) {
              final uid = (m.userID ?? '').toUpperCase();
              final uidPrefix = uid.length >= 64 ? uid.substring(0, 64) : uid;
              if (uidPrefix == selfPk) {
                isForSelf = true;
                break;
              }
            }
          }
          if (!isForSelf) {
            final memberPks = memberList
                .map((m) =>
                    (m.userID ?? '').length >= 16 ? (m.userID ?? '').substring(0, 16) : (m.userID ?? ''))
                .toList();
            final selfPkPrefix = selfPk.length >= 16 ? selfPk.substring(0, 16) : selfPk;
            print(
                '[TestNode] $alias: onMemberInvited skipped (peer-invite, not self); selfPk=$selfPkPrefix memberPks=$memberPks');
            return;
          }
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
      // localDiscovery default is mode-dependent:
      //   • Solo (PARALLEL_WORKERS=1 or unset): default ON. LAN multicast
      //     accelerates loopback DHT peer-find by ~5–10 s, so a 2-node
      //     friendship test costs ~11 s instead of ~20 s.
      //   • Parallel (PARALLEL_WORKERS≥2): default OFF. With LAN on, every
      //     process's Tox instances broadcast on the loopback interface;
      //     c-toxcore's LAN-discovery sweeps the entire 33445–33545 port
      //     range and crosses test-process boundaries. The second worker's
      //     nodes end up routing through the first worker's DHT entries —
      //     friend P2P never resolves, so message / group / ToxAV tests
      //     time out with `friend in list=true but role=2 (OFFLINE)`.
      //     Trading ~50 % per-test wall-clock for zero cross-process flakes
      //     is the right call here.
      // Tests that need LAN discovery for their own purpose
      // (`scenario_lan_discovery_test`) still pass `localDiscoveryEnabled:
      // true` explicitly and override this default.
      final parallelWorkers =
          int.tryParse(Platform.environment['PARALLEL_WORKERS'] ?? '1') ?? 1;
      final defaultLocalDiscovery = parallelWorkers <= 1;
      final localDiscovery = localDiscoveryEnabled ?? defaultLocalDiscovery;
      final ipv6 = ipv6Enabled ?? true;
      instanceHandle = ffiInstance.createTestInstanceExNative(
          initPathPtr, localDiscovery ? 1 : 0, ipv6 ? 1 : 0);
      print(
          '[Test] Created test instance $instanceHandle for node $alias with options: localDiscovery=$localDiscovery, ipv6=$ipv6 (PARALLEL_WORKERS=$parallelWorkers)');

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
      // Warm the Tox ID cache eagerly so the _groupListener.onMemberInvited
      // filter (which compares memberList[*].userID against self's pubkey)
      // can read it synchronously without re-entering runWithInstance from
      // inside a dispatch callback. Without this, the first onMemberInvited
      // can fire before _toxIdCache is populated and the filter falls back
      // to "mark unconditionally" — which re-introduces the late-invite
      // overwrite bug that broke scenario_group_state_changes_virtual_test.
      try {
        getToxId();
      } catch (_) {
        // best-effort; non-fatal if FFI not yet ready
      }
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
          // Short stabilization wait: getSelfConnectionStatus has confirmed
          // TCP/UDP, but Tox's first announce/handshake hasn't always
          // completed yet, and removing this entirely broke multi-node
          // tests that race the bootstrap setup. Kept at 200ms (was 500ms)
          // so we still save ~0.3s/node × 80+ tests across the suite.
          await Future.delayed(const Duration(milliseconds: 200));
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
      int pollDelayMs = 50;
      const maxPollDelayMs = 150;

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
          // Previously slept 500ms here as a "stabilization" pause before
          // returning. There's no callback or state-machine that needs that
          // gap — the next test step (addFriend / iterate) is the very thing
          // that consumes the just-online state. Drop the sleep: 500ms × 2
          // nodes × ~30 setUpAlls ≈ 30s off the total suite. If you ever
          // see a flake that re-introduces a need for this, prefer polling
          // the specific predicate rather than restoring a fixed sleep.
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
        // Tighter ramp: poll every 50-150ms instead of 100-300ms so a node
        // that comes online inside the first second is detected immediately
        // (was paying up to one extra 300ms tick).
        pollDelayMs = (pollDelayMs * 1.2).round().clamp(50, 150);
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
              // No "stabilization" sleep — the next test step can react to
              // role==1 immediately. Saves ~500ms per friendship setup.
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

        // Pump all instances so Tox can establish P2P (otherwise we only poll and connection never establishes).
        // 100ms step (was 250ms): when role flips to ONLINE the next poll lands within ~100ms instead of 250ms.
        // Over ~30 setUpAlls × N polls per friendship this is ~5s suite-wide.
        pumpAllInstancesOnce(iterations: 150);
        await Future.delayed(const Duration(milliseconds: 100));
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

  // Wait for both nodes to have real Tox DHT connection in parallel.
  // Sequential wait paid each node's worst case in series (up to 20s);
  // Future.wait collapses to the slower side and saves typical 1-2s.
  try {
    await Future.wait([
      alice.waitForConnection(timeout: const Duration(seconds: 10)),
      bob.waitForConnection(timeout: const Duration(seconds: 10)),
    ]);
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

  // The previous version paid a flat 6s pumpFriendConnection + 2s
  // Future.delayed BEFORE checking the friend list. The Future.delayed was
  // pure dead time, but the 6s pump was actually doing work: pumpFriendConnection
  // uses 25ms step delay (~240 iterations/sec), while the polling loop
  // below pumps at 400ms step (~2.5 iter/sec). Removing the pre-pump
  // starved Tox of iterate time and broke friend-request propagation.
  //
  // Compromise: an aggressive *bounded* pre-pump that exits as soon as both
  // friend lists converge. Worst case is still cheaper than the original
  // (the original always paid 8s; this pays at most 3s and usually much
  // less). The downstream polling loop is unchanged for the slow case.
  bool listContainsPublicKey(List<String> list, String publicKey) => list.any(
      (id) => id == publicKey || (id.length >= 64 && id.startsWith(publicKey)));
  print(
      '[establishFriendship] Pumping until friend lists converge or 3s elapses...');
  {
    final prePumpDeadline = DateTime.now().add(const Duration(seconds: 3));
    final ffi = ffi_lib.Tim2ToxFfi.open();
    bool converged = false;
    while (DateTime.now().isBefore(prePumpDeadline)) {
      ffi.iterateAllInstances(40);
      await Future.delayed(const Duration(milliseconds: 25));
      final aliceFriends = await alice.getFriendList();
      final bobFriends = await bob.getFriendList();
      if (listContainsPublicKey(aliceFriends, bobPublicKey) &&
          listContainsPublicKey(bobFriends, alicePublicKey)) {
        converged = true;
        break;
      }
    }
    if (converged) {
      print(
          '[establishFriendship] Friend lists converged during pre-pump (saved up to 8s of the old fixed wait)');
    }
  }

  // Slower fallback polling loop (in case the 3s pre-pump didn't converge).
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
      // Short P2P warm-up pump. Previous 800ms baseline was a leftover from
      // before pumpFriendConnection got tighter iteration density. Local
      // bootstrap converges in 100-300ms; 400ms is plenty as a guard and
      // the actual waitForFriendConnection below polls and pumps further.
      const pumpDuration = Duration(milliseconds: 400);
      final actualPump = remaining.inSeconds > 4
          ? pumpDuration
          : Duration(milliseconds: remaining.inMilliseconds.clamp(200, 400));
      print(
          '[establishFriendship] Pumping Tox for P2P connection (${actualPump.inMilliseconds}ms)...');
      await pumpFriendConnection(alice, bob, duration: actualPump);
      // Cap P2P wait. In local-bootstrap environments, friend connections
      // either come ONLINE within ~2-5s sequentially or never within the
      // test budget; waiting longer than 30s is pure overhead.
      // Floor 12s: previously 15s; empirically the success path on local
      // bootstrap is sub-5s under sequential load, but under PARALLEL_WORKERS>1
      // CPU contention can push it past 8s, so 12s is the safe boundary that
      // saves time on the happy path without introducing flakes under N=3.
      // waitForFriendConnection pumps every iteration and exits the instant
      // role flips to ONLINE, so a tight floor only costs cycles in the
      // truly-stuck unhappy path.
      final remainingForP2P = deadline.difference(DateTime.now());
      const minWaitSec = 12;
      const maxWaitSec = 30;
      final halfRemaining =
          remainingForP2P.inSeconds >= 2 ? (remainingForP2P.inSeconds ~/ 2) : 0;
      final waitEachSec = remainingForP2P.inSeconds >= 4
          ? (halfRemaining > maxWaitSec
              ? maxWaitSec
              : (halfRemaining < minWaitSec ? minWaitSec : halfRemaining))
          : remainingForP2P.inSeconds.clamp(1, maxWaitSec);
      final waitEach = Duration(seconds: waitEachSec);
      // Run in parallel: each waitForFriendConnection is bottlenecked on
      // tox_iterate progress, not on which Dart Future is awaited first.
      // Previous version ran sequentially and paid the worst case twice;
      // Future.wait collapses that to the slower side once.
      print(
          '[establishFriendship] Waiting for Tox P2P connection in parallel (${waitEach.inSeconds}s each)...');
      try {
        await Future.wait([
          alice.waitForFriendConnection(bobToxId, timeout: waitEach),
          bob.waitForFriendConnection(aliceToxId, timeout: waitEach),
        ], eagerError: false);
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

    // 200ms step (was 400ms): once we're in this fallback the pre-pump
    // already gave Tox 3s of dense iteration; the friend-list update is
    // typically only one iter+poll cycle behind. A tighter step exits the
    // loop sooner without meaningfully costing CPU (each iter already
    // does pumpAllInstancesOnce + 2× async getFriendList).
    await Future.delayed(const Duration(milliseconds: 200));
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

/// Process-level cache of fully-bootstrapped [TestScenario] instances, keyed
/// by the (aliases × options) signature. Used when multiple test files are
/// loaded into the same `flutter test` invocation and they share a node
/// composition that's expensive to recreate (Tox cold start + DHT bootstrap
/// + friendship handshake is 7–20 s per scenario).
///
/// The pool is opt-in: tests call [acquireSharedScenario] in `setUpAll` and
/// [releaseSharedScenario] in `tearDownAll`. The fallback semantics match
/// the original `createTestScenario → initAllNodes → login → bootstrap → …`
/// chain, so a test file that runs in isolation pays the same cost it always
/// did — the savings only materialize when multiple test files share an
/// isolate and ask for the same signature.
///
/// State hygiene: on cache-hit, only **transient** per-test state is reset
/// (callback flags, callback queue, received-message list). Tox-level state
/// (friend list, DHT routing, saved nodes) is preserved by design — that's
/// the whole point. Tests that mutate persistent state (creating groups,
/// deleting friends, changing nospam) MUST clean up after themselves or
/// explicitly opt out of sharing via [acquireSharedScenario] with a unique
/// `signatureSalt`.
///
/// Disposal: scenarios stay alive until the Dart process exits — the OS
/// reclaims the underlying Tox sockets/threads. For deterministic teardown
/// inside long-running test bundles, call [SharedScenarioPool.disposeAll].
class SharedScenarioPool {
  SharedScenarioPool._();

  static final Map<String, TestScenario> _cache = {};
  static bool _envSetup = false;

  static String _signatureFor(
    List<String> aliases, {
    required bool withFriendship,
    required bool withBootstrap,
    String? signatureSalt,
  }) {
    final salt = signatureSalt == null ? '' : '|salt=$signatureSalt';
    return '${aliases.join(",")}|f=$withFriendship|b=$withBootstrap$salt';
  }

  static void _resetTransientState(TestScenario scenario) {
    for (final n in scenario.nodes) {
      n.callbackReceived.clear();
      n.callbackQueue.clear();
      n.receivedMessages.clear();
    }
  }

  /// Returns a fully-prepared [TestScenario] for [aliases], reusing a cached
  /// one when its signature matches.
  ///
  /// When [withBootstrap] is true the pool runs [configureLocalBootstrap]
  /// for fresh scenarios. When [withFriendship] is true it establishes a
  /// **mesh** friendship over all node pairs in parallel (so 3 nodes = 3
  /// concurrent `establishFriendship` calls). Each call uses a 60 s timeout
  /// — enough headroom for cold-start P2P handshake under parallel CPU load.
  ///
  /// Pass a [signatureSalt] when you want a fresh scenario for a particular
  /// test (e.g. testing scenario.dispose behavior itself, or any test that
  /// mutates Tox state in ways the pool can't safely reset).
  static Future<TestScenario> acquire(
    List<String> aliases, {
    bool withFriendship = false,
    bool withBootstrap = true,
    String? signatureSalt,
  }) async {
    final key = _signatureFor(aliases,
        withFriendship: withFriendship,
        withBootstrap: withBootstrap,
        signatureSalt: signatureSalt);
    final cached = _cache[key];
    if (cached != null) {
      print('[SharedScenarioPool] HIT $key — reusing cached scenario');
      _resetTransientState(cached);
      return cached;
    }
    print(
        '[SharedScenarioPool] MISS $key — bootstrapping fresh scenario (cold start)');
    if (!_envSetup) {
      await setupTestEnvironment();
      _envSetup = true;
    }
    final scenario = await createTestScenario(aliases);
    await scenario.initAllNodes();
    await Future.wait(scenario.nodes.map((n) => n.login()));
    await waitUntil(
      () => scenario.nodes.every((n) => n.loggedIn),
      timeout: const Duration(seconds: 10),
      description: 'all ${aliases.length} nodes logged in (shared-pool)',
    );
    if (withBootstrap) {
      await configureLocalBootstrap(scenario);
    }
    for (final n in scenario.nodes) {
      n.enableAutoAccept();
    }
    if (withFriendship && scenario.nodes.length >= 2) {
      // Mesh in parallel: every pair (i, j) where i < j.
      final pairs = <Future<void>>[];
      for (int i = 0; i < scenario.nodes.length; i++) {
        for (int j = i + 1; j < scenario.nodes.length; j++) {
          pairs.add(establishFriendship(scenario.nodes[i], scenario.nodes[j],
              timeout: const Duration(seconds: 60)));
        }
      }
      await Future.wait(pairs);
    }
    _cache[key] = scenario;
    return scenario;
  }

  /// No-op by design — the scenario stays cached for the next [acquire].
  /// Provided for API symmetry; tests that want hard teardown call
  /// [disposeAll] from a top-level `tearDownAll` hook.
  static void release(List<String> aliases,
      {bool withFriendship = false,
      bool withBootstrap = true,
      String? signatureSalt}) {
    // intentional no-op
  }

  /// Tear down every cached scenario. Call from a process-level
  /// `tearDownAll` when running a bundled test file that knows it's the
  /// last user of the pool.
  static Future<void> disposeAll() async {
    final snapshot = List<TestScenario>.from(_cache.values);
    _cache.clear();
    for (final s in snapshot) {
      try {
        await s.dispose();
      } catch (_) {
        // ignore: deliberate — best-effort cleanup at end of process
      }
    }
  }

  /// Diagnostic: number of cached scenarios. Useful in bundle sanity tests.
  static int get cachedCount => _cache.length;
}

/// Convenience wrapper around [SharedScenarioPool.acquire]. Call from
/// `setUpAll`. The returned scenario is ready to use — bootstrap is done,
/// friendships are established (if [withFriendship]), auto-accept is on.
Future<TestScenario> acquireSharedScenario(
  List<String> aliases, {
  bool withFriendship = false,
  bool withBootstrap = true,
  String? signatureSalt,
}) =>
    SharedScenarioPool.acquire(aliases,
        withFriendship: withFriendship,
        withBootstrap: withBootstrap,
        signatureSalt: signatureSalt);

/// Convenience wrapper around [SharedScenarioPool.release]. Call from
/// `tearDownAll`. No-op by contract.
void releaseSharedScenario(List<String> aliases,
        {bool withFriendship = false,
        bool withBootstrap = true,
        String? signatureSalt}) =>
    SharedScenarioPool.release(aliases,
        withFriendship: withFriendship,
        withBootstrap: withBootstrap,
        signatureSalt: signatureSalt);

/// True when the suite was launched with `RUN_VIRTUAL=1` (virtual-clock mode).
///
/// A single scenario file can branch on this to drive either the wall-clock or
/// the virtual-clock setup without needing a separate `*_virtual_test.dart`
/// sibling. The runner sets `RUN_VIRTUAL` in the environment; `flutter test`
/// propagates it to the test isolate, so `Platform.environment` reads it here.
bool get shouldRunVirtual => Platform.environment['RUN_VIRTUAL'] == '1';

/// Mode-aware scenario acquisition — the single `setUpAll` entry point for a
/// unified scenario file that must run under both the wall-clock and the
/// virtual-clock harness.
///
/// - **Wall-clock** (`RUN_VIRTUAL` unset): delegates to [acquireSharedScenario]
///   so a bundle of files reuses one bootstrapped+friended fixture (the pool
///   saves the 7–20 s Tox cold start per file).
/// - **Virtual-clock** (`RUN_VIRTUAL=1`): builds a fresh scenario from scratch.
///   The shared pool is intentionally *not* used here because it never calls
///   [VirtualClock.enableEarly] before instance creation, which signaling-
///   sensitive flows require (the constructor must read `test_mode` so
///   `InitSDK` never spawns an `event_thread`). The from-scratch path mirrors
///   the canonical virtual `setUpAll` template in `VIRTUAL_CLOCK.md` §4.
///
/// Either way the returned scenario is logged in, bootstrapped (when
/// [withBootstrap]), auto-accept enabled, and meshed with friendships (when
/// [withFriendship]). Pair with [releaseScenarioForMode] in `tearDownAll`.
Future<TestScenario> acquireScenarioForMode(
  List<String> aliases, {
  bool withFriendship = false,
  bool withBootstrap = true,
  String? signatureSalt,
}) async {
  if (!shouldRunVirtual) {
    return acquireSharedScenario(aliases,
        withFriendship: withFriendship,
        withBootstrap: withBootstrap,
        signatureSalt: signatureSalt);
  }

  // Virtual-clock from-scratch setup.
  await setupTestEnvironment();
  // Must run BEFORE any test instance is created (process-global default).
  await VirtualClock.enableEarly();
  final scenario = await createTestScenario(aliases);
  await scenario.initAllNodes();
  // Idempotent w.r.t. enableEarly; seeds the clock + syncs the per-instance flag.
  await VirtualClock.enableForScenario(scenario);
  await Future.wait(scenario.nodes.map((n) => n.login()));
  await waitUntil(
    () => scenario.nodes.every((n) => n.loggedIn),
    timeout: const Duration(seconds: 10),
    description: 'all ${aliases.length} nodes logged in (virtual)',
  );
  if (withBootstrap) {
    await configureLocalBootstrapVirtual(scenario);
  }
  for (final n in scenario.nodes) {
    n.enableAutoAccept();
  }
  if (withFriendship && scenario.nodes.length >= 2) {
    final pairs = <Future<void>>[];
    for (int i = 0; i < scenario.nodes.length; i++) {
      for (int j = i + 1; j < scenario.nodes.length; j++) {
        pairs.add(establishFriendshipVirtual(
            scenario, scenario.nodes[i], scenario.nodes[j],
            timeout: const Duration(seconds: 60)));
      }
    }
    await Future.wait(pairs);
  }
  return scenario;
}

/// Mode-aware teardown counterpart to [acquireScenarioForMode]. Call from
/// `tearDownAll`.
///
/// - **Wall-clock**: no-op [releaseSharedScenario] (keeps the pool warm for the
///   next file in a bundle; the OS reclaims sockets at process exit).
/// - **Virtual-clock**: hard teardown — disposes the fresh scenario and the
///   global test environment, matching what the old `*_virtual_test.dart`
///   siblings did.
Future<void> releaseScenarioForMode(
  TestScenario scenario,
  List<String> aliases, {
  bool withFriendship = false,
  bool withBootstrap = true,
  String? signatureSalt,
}) async {
  if (!shouldRunVirtual) {
    releaseSharedScenario(aliases,
        withFriendship: withFriendship,
        withBootstrap: withBootstrap,
        signatureSalt: signatureSalt);
    return;
  }
  await scenario.dispose();
  await teardownTestEnvironment();
}

/// Invite [invitee] into [groupId] from [inviter], waiting for the invitee's
/// `onGroupInvited` callback and re-issuing the invite up to [maxAttempts]
/// times. Returns the group id the invitee should join (taken from the
/// callback payload, falling back to [groupId]).
///
/// Why this exists: `inviteUserToGroup` returns `code=0` even when the
/// underlying `tox_group_invite_friend` packet is dropped, and the first invite
/// frequently races with friend P2P bring-up. Re-issuing the invite is the
/// established workaround (see `VIRTUAL_CLOCK.md` §5) — it was hand-rolled in
/// dozens of scenario files before being centralized here.
///
/// Mode-agnostic: waits via [waitUntilWithVirtualPump], which drives the shared
/// virtual clock when enabled and falls back to wall-clock waiting otherwise,
/// so one call site works under both harnesses. Throws [StateError] if an
/// invite returns a non-zero code, or [TimeoutException] if the invitee never
/// receives `onGroupInvited` after [maxAttempts].
Future<String> inviteUserToGroupWithRetry(
  TestScenario scenario,
  TestNode inviter,
  TestNode invitee,
  String groupId, {
  String context = '',
  int maxAttempts = 3,
  Duration timeout = const Duration(seconds: 12),
  int advanceMs = 50,
  int iterationsPerInstance = 1,
}) async {
  final label = context.isEmpty ? groupId : context;
  final inviteePubKey = invitee.getPublicKey();
  var arrived = false;
  for (var attempt = 0; !arrived && attempt < maxAttempts; attempt++) {
    invitee.clearCallbackReceived('onGroupInvited');
    final inviteResult = await inviter.runWithInstanceAsync(() async =>
        TIMGroupManager.instance.inviteUserToGroup(
          groupID: groupId,
          userList: [inviteePubKey],
        ));
    if (inviteResult.code != 0) {
      throw StateError(
          'inviteUserToGroup failed for ${invitee.alias} ($label): '
          'code=${inviteResult.code} ${inviteResult.desc}');
    }
    try {
      await waitUntilWithVirtualPump(
        scenario,
        () => invitee.callbackReceived['onGroupInvited'] == true,
        timeout: timeout,
        description:
            '${invitee.alias} receives onGroupInvited ($label, attempt ${attempt + 1})',
        advanceMs: advanceMs,
        iterationsPerInstance: iterationsPerInstance,
      );
      arrived = true;
    } catch (_) {
      // Re-issue the invite on the next attempt.
    }
  }
  if (!arrived) {
    throw TimeoutException(
        '${invitee.alias} never received onGroupInvited for $label '
        'after $maxAttempts attempts');
  }
  return invitee.getLastCallbackGroupId('onGroupInvited') ?? groupId;
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

  // Brief sleep to let UDP listeners bind. Verified experimentally:
  // dropping this caused 3-node friend_query setups to race ahead before
  // ports were stable, and getUdpPort's retry loop wasn't enough to
  // recover before per-node 10s DHT-connect timeouts piled up.
  await Future.delayed(const Duration(milliseconds: 500));
  print(
      '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: after initial 500ms delay');

  Future<(int, String)> readPortAndDhtId(TestNode node) async {
    return node.runWithInstanceAsync(() async {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      int port = 0;
      for (int retry = 0; retry < 5; retry++) {
        port = ffiInstance.getUdpPort(ffiInstance.getCurrentInstanceId());
        if (port > 0) {
          final loginStatus = TIMManager.instance.getLoginStatus();
          if (loginStatus == 1) break;
        }
        if (retry < 4) await Future.delayed(const Duration(milliseconds: 200));
      }
      if (port == 0) return (0, '');
      final dhtIdBuf = pkgffi.malloc.allocate<ffi.Int8>(65);
      try {
        final dhtIdLen = ffiInstance.getDhtIdNative(dhtIdBuf, 65);
        if (dhtIdLen == 0 || dhtIdLen > 64) return (0, '');
        final dhtId = dhtIdBuf.cast<pkgffi.Utf8>().toDartString(length: dhtIdLen);
        return (port, dhtId);
      } finally {
        pkgffi.malloc.free(dhtIdBuf);
      }
    });
  }

  // Read every node's (port, dhtId). Run sequentially to avoid clobbering
  // current-instance state during runWithInstanceAsync.
  final nodeEndpoints = <(int, String)>[];
  for (final node in scenario.nodes) {
    final pair = await readPortAndDhtId(node);
    nodeEndpoints.add(pair);
    print(
        '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: endpoint ${node.alias} port=${pair.$1} dhtIdLen=${pair.$2.length}');
  }

  bool atLeastOneEndpoint = false;
  for (final ep in nodeEndpoints) {
    if (ep.$1 != 0 && ep.$2.isNotEmpty) {
      atLeastOneEndpoint = true;
      break;
    }
  }
  if (!atLeastOneEndpoint) {
    print(
        '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: ERROR no usable endpoint on any node');
    return;
  }

  // Full mesh: every node bootstraps to every OTHER node. Previously only
  // nodes[1..] bootstrapped to nodes[0], which left nodes[0] without any
  // DHT peer to learn from on a 3-node local-only setup, killing PUBLIC
  // group peer-discovery (peer_join callback never fires on founder).
  for (int i = 0; i < scenario.nodes.length; i++) {
    final node = scenario.nodes[i];
    if (node.testInstanceHandle == null) {
      print(
          '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: WARNING ${node.alias} has no test instance handle');
      continue;
    }
    await node.runWithInstanceAsync(() async {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      for (int j = 0; j < scenario.nodes.length; j++) {
        if (i == j) continue;
        final port = nodeEndpoints[j].$1;
        final dhtId = nodeEndpoints[j].$2;
        if (port == 0 || dhtId.isEmpty) continue;
        final hostPtr = '127.0.0.1'.toNativeUtf8();
        final dhtIdPtr = dhtId.toNativeUtf8();
        try {
          final success = ffiInstance.addBootstrapNode(
              ffiInstance.getCurrentInstanceId(), hostPtr, port, dhtIdPtr);
          print(
              '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: ${node.alias} -> ${scenario.nodes[j].alias} 127.0.0.1:$port success=$success');
        } finally {
          pkgffi.malloc.free(hostPtr);
          pkgffi.malloc.free(dhtIdPtr);
        }
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
      '[Bootstrap] T+${stopwatch.elapsedMilliseconds}ms: Waiting for all nodes real Tox connection (connection_status != 0, timeout 5s)...');
  try {
    // Shorter cap: in successful runs all nodes hit non-zero connection_status
    // within ~1s. In flaky runs some nodes never come online at all, so any
    // wait longer than a few seconds is wasted before establishFriendship
    // takes over anyway.
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
      timeout: const Duration(seconds: 5),
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

// =============================================================================
// Virtual-clock test harness.
//
// When enabled, the C++ side suspends each instance's event_thread and
// consults a process-global virtual clock instead of wall time. The harness
// drives Tox iteration manually via [pumpTestTick] / [waitUntilWithVirtualPump]
// against that shared clock — letting tests advance "time" deterministically
// without flaky sleeps.
//
// Lifecycle (after createTestScenario + initAllNodes, before loginAllNodes):
//
//   await VirtualClock.enableForScenario(scenario);
//   ... loginAllNodes / establishFriendship etc, using pumpTestTick or
//       waitUntilWithVirtualPump instead of the wall-clock variants.
//
// When [VirtualClock.enabled] is false the helpers below transparently fall
// back to the legacy wall-clock pump so existing tests can opt in piecemeal.
// =============================================================================

/// Process-global shared virtual clock for test-mode tim2tox instances.
///
/// Stateful and intentionally static — there is exactly one C++ virtual clock
/// per process, and every in-test-mode instance reads from it. Reset between
/// scenarios is unnecessary because each scenario re-arms the clock from a
/// known starting value when [enableForScenario] is called.
class VirtualClock {
  VirtualClock._();

  static int _ms = 0;
  static bool _enabled = false;

  /// Enable test mode BEFORE any test instance is created. Sets the
  /// process-global default test_mode flag so the V2TIMManagerImpl
  /// constructor reads it, and InitSDK skips spawning event_thread entirely.
  ///
  /// Required for tests that depend on event_thread's task_queue being
  /// suppressed — signaling flows in particular. Call this BEFORE
  /// `scenario.initAllNodes()`. For group-only tests, [enableForScenario]
  /// (which sets test_mode after InitSDK) is still sufficient because group
  /// flows go through tox_iterate which both event_thread and pumpTestTick
  /// drive.
  static Future<void> enableEarly() async {
    final ffi = ffi_lib.Tim2ToxFfi.open();
    ffi.setDefaultTestMode(true);
    _ms = 1000;
    ffi.setVirtualTimeMs(_ms);
    _enabled = true;
  }

  /// Enable test mode for every node in [scenario] and seed the virtual clock.
  ///
  /// Call after `scenario.initAllNodes()` but before any `login()`. For
  /// signaling-style tests that need event_thread fully suppressed before
  /// InitSDK runs, use [enableEarly] before initAllNodes instead.
  ///
  /// Seeds the clock at 1000ms (rather than 0) because some toxcore timers
  /// treat 0 as "uninitialised" and re-arm on the first iteration.
  static Future<void> enableForScenario(TestScenario scenario) async {
    final ffi = ffi_lib.Tim2ToxFfi.open();
    for (final node in scenario.nodes) {
      final handle = node.testInstanceHandle;
      if (handle == null) continue;
      ffi.setTestMode(handle, true);
    }
    _ms = 1000;
    ffi.setVirtualTimeMs(_ms);
    _enabled = true;
  }

  /// Advance the shared virtual clock by [ms] milliseconds. Does NOT iterate;
  /// callers must follow up with iteration (use [pumpTestTick] for the
  /// combined advance-then-iterate pattern).
  static void advance(int ms) {
    _ms += ms;
    final ffi = ffi_lib.Tim2ToxFfi.open();
    ffi.setVirtualTimeMs(_ms);
  }

  /// Current virtual clock value (milliseconds).
  static int get nowMs => _ms;

  /// Whether test mode is currently enabled for this process.
  static bool get enabled => _enabled;
}

/// Drive one tick of the virtual-clock harness: advance the shared clock by
/// [advanceMs], then run [iterationsPerInstance] iterations on every node in
/// [scenario] that has a test instance handle.
///
/// Falls back to [pumpAllInstancesOnce] when [VirtualClock.enabled] is false
/// so callers can sprinkle this into existing helpers without breaking the
/// wall-clock path.
Future<void> pumpTestTick(
  TestScenario scenario, {
  int advanceMs = 50,
  int iterationsPerInstance = 1,
  Duration wallSleep = const Duration(milliseconds: 5),
}) async {
  if (!VirtualClock.enabled) {
    // Wall-clock fallback. Advance the (Dart-side) virtual clock counter so
    // inline `while (VirtualClock.nowMs < deadline)` poll loops in unified test
    // bodies still terminate in wall mode (C++ ignores the mirrored virtual
    // time when test_mode is off — it reads real mono_time — so this only moves
    // the Dart-side counter). Honor the caller's iteration count and real
    // `wallSleep` so unified bodies that replaced `Future.delayed` /
    // `pumpAllInstancesOnce` with `pumpTestTick` keep an equivalent settle
    // window (the event_thread is also running in wall mode).
    VirtualClock.advance(advanceMs);
    pumpAllInstancesOnce(
        iterations: iterationsPerInstance > 50 ? iterationsPerInstance : 50);
    if (wallSleep > Duration.zero) {
      await Future.delayed(wallSleep);
    }
    return;
  }
  VirtualClock.advance(advanceMs);
  // Scale iterations with advanceMs so e.g. `pumpTestTick(advanceMs: 3000)`
  // mimics what the suppressed event_thread would have done — a continuous
  // ~50ms iterate cadence. Without this, a 3-second virtual advance with
  // `iterationsPerInstance: 1` only fires a single tox_iterate, leaving
  // Tox NGC peer discovery, friend P2P handshake, and group announce/connect
  // under-driven; tests that rely on member-list convergence (e.g. group
  // message sender matching) intermittently fail because the receiver sees
  // only the founder's self peer when it queries getGroupMemberList. `max`
  // with the explicit caller value preserves call sites that pass a higher
  // count.
  final iterationsForAdvance = (advanceMs / 50).floor();
  final effectiveIterations =
      iterationsPerInstance > iterationsForAdvance
          ? iterationsPerInstance
          : (iterationsForAdvance > 0 ? iterationsForAdvance : 1);
  final ffi = ffi_lib.Tim2ToxFfi.open();
  // Interleave iterations with small wall yields so loopback UDP packets
  // between sibling instances actually get delivered between iterates.
  // Without this every iterate burst sends packets that all sit in the
  // OS socket buffer until the final wallSleep — which then only gives
  // one chance to drain. For large effectiveIterations (e.g. 60), batch
  // into ~10 chunks so each chunk gets a 5ms loopback window.
  final batchCount = effectiveIterations >= 10 ? 10 : 1;
  final perBatch = (effectiveIterations / batchCount).ceil();
  for (var b = 0; b < batchCount; b++) {
    for (final node in scenario.nodes) {
      final handle = node.testInstanceHandle;
      if (handle == null) continue;
      for (var i = 0; i < perBatch; i++) {
        ffi.iterateInstance(handle);
      }
    }
    if (batchCount > 1 && b < batchCount - 1) {
      // Mid-pump wall yield so loopback packets settle between batches.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }
  // Real wall sleep so UDP/TCP packets sent by this iterate burst have a
  // chance to be delivered to peer sockets before the next iterate. Virtual
  // clock only fast-forwards Tox-internal timers; loopback socket round-trips
  // still need real time. ~5ms is enough on macOS loopback for friend P2P
  // handshake to make progress.
  if (wallSleep.inMicroseconds > 0) {
    await Future<void>.delayed(wallSleep);
  } else {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Same contract as [waitUntilWithPump], but drives the virtual clock when
/// test mode is enabled. [timeout] is interpreted as virtual milliseconds in
/// that case, real milliseconds otherwise.
///
/// When [VirtualClock.enabled] is false this delegates directly to
/// [waitUntilWithPump] so existing call sites keep their wall-clock semantics.
Future<void> waitUntilWithVirtualPump(
  TestScenario scenario,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
  String description = 'condition',
  int advanceMs = 50,
  int iterationsPerInstance = 1,
  Duration wallSleep = const Duration(milliseconds: 5),
}) async {
  if (!VirtualClock.enabled) {
    return waitUntilWithPump(
      condition,
      timeout: timeout,
      description: description,
    );
  }
  final budgetMs = timeout.inMilliseconds;
  final deadline = VirtualClock.nowMs + budgetMs;
  while (VirtualClock.nowMs < deadline) {
    if (condition()) return;
    await pumpTestTick(
      scenario,
      advanceMs: advanceMs,
      iterationsPerInstance: iterationsPerInstance,
      wallSleep: wallSleep,
    );
  }
  // Grace period: a native callback (e.g. OnRecvNewMessage) processed during
  // the final pumpTestTick posts to the Dart ReceivePort, which schedules
  // `Future.microtask(() async { await _setFaceUrlForMsg(...); ... listener })`.
  // The await inside that microtask body means the listener may not have
  // fired yet by the time the deadline-bound loop exits. Yield to the event
  // loop a few times so any pending native callback → microtask → listener
  // chains can drain before we declare timeout.
  //
  // We do NOT advance the virtual clock here — these are "drain" ticks, not
  // logical progress. iterateInstance is also skipped to avoid spurious side
  // effects after deadline. Each Future.delayed turn drains all pending
  // microtasks and ReceivePort events queued earlier.
  for (var i = 0; i < 10; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (condition()) return;
  throw TimeoutException(
      'Timeout waiting for $description (virtual: $budgetMs ms)');
}

/// AV-aware sibling of [pumpTestTick]. Drives one tick of the virtual harness
/// AND calls `tim2tox_ffi_av_iterate` on each instance so ToxAV's separate
/// iteration loop (call-state transitions, audio/video frame delivery) makes
/// progress too. Use this for tests that depend on ToxAV state updates —
/// regular [pumpTestTick] does not advance ToxAV's internal timers.
///
/// Falls back to [pumpAllInstancesOnce] when [VirtualClock.enabled] is false
/// so non-virtual call sites keep working.
Future<void> pumpTestTickAv(
  TestScenario scenario, {
  int advanceMs = 50,
  int iterationsPerInstance = 1,
  Duration wallSleep = const Duration(milliseconds: 5),
}) async {
  if (!VirtualClock.enabled) {
    // Wall-clock fallback (mirrors pumpTestTick): advance the Dart-side clock
    // counter so inline nowMs poll loops terminate, honor the caller's
    // iteration count + wall settle. The event_thread drives both tox_iterate
    // and ToxAV iterate in wall mode, so no explicit av-iterate is needed here.
    VirtualClock.advance(advanceMs);
    pumpAllInstancesOnce(
        iterations: iterationsPerInstance > 50 ? iterationsPerInstance : 50);
    if (wallSleep > Duration.zero) {
      await Future.delayed(wallSleep);
    }
    return;
  }
  VirtualClock.advance(advanceMs);
  final ffi = ffi_lib.Tim2ToxFfi.open();
  for (final node in scenario.nodes) {
    final handle = node.testInstanceHandle;
    if (handle == null) continue;
    for (var i = 0; i < iterationsPerInstance; i++) {
      ffi.iterateInstance(handle);
      // Also drive ToxAV iterate so call-state and frame callbacks fire.
      // ToxAV may not be initialized on every node — swallow native errors.
      try {
        ffi.avIterate(handle);
      } catch (_) {
        // Instance has no ToxAV attached; ignore.
      }
    }
  }
  if (wallSleep.inMicroseconds > 0) {
    await Future<void>.delayed(wallSleep);
  } else {
    await Future<void>.delayed(Duration.zero);
  }
}

/// AV-aware sibling of [waitUntilWithVirtualPump]. Polls [condition] while
/// driving [pumpTestTickAv] each iteration so ToxAV's iterate loop has a
/// chance to fire call-state and frame callbacks.
///
/// When [VirtualClock.enabled] is false this delegates to [waitUntilWithPump]
/// (wall-clock mode) so callers keep their existing semantics.
Future<void> waitUntilWithAvVirtualPump(
  TestScenario scenario,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
  String description = 'condition',
  int advanceMs = 50,
  int iterationsPerInstance = 1,
  Duration wallSleep = const Duration(milliseconds: 5),
}) async {
  if (!VirtualClock.enabled) {
    return waitUntilWithPump(
      condition,
      timeout: timeout,
      description: description,
    );
  }
  final budgetMs = timeout.inMilliseconds;
  final deadline = VirtualClock.nowMs + budgetMs;
  while (VirtualClock.nowMs < deadline) {
    if (condition()) return;
    await pumpTestTickAv(
      scenario,
      advanceMs: advanceMs,
      iterationsPerInstance: iterationsPerInstance,
      wallSleep: wallSleep,
    );
  }
  if (condition()) return;
  throw TimeoutException(
      'Timeout waiting for $description (virtual AV: $budgetMs ms)');
}

// =============================================================================
// Virtual-clock variants of the wall-clock helpers above.
//
// Every helper below mirrors the behaviour of its wall-clock twin but drives
// time forward through [pumpTestTick] (which advances the shared virtual
// clock and iterates each instance) instead of `Future.delayed`. The first
// parameter is always the [TestScenario] so the helper knows which nodes to
// iterate when ticking the clock.
//
// These functions are purely additive — the originals stay in place so callers
// can opt in piecemeal.
// =============================================================================

/// Top-level virtual-clock variant of [TestNode.waitForConnection].
///
/// Polls the node's connection_status while advancing the shared virtual
/// clock between samples. All timeouts are interpreted as virtual ms.
Future<void> waitForConnectionVirtual(
  TestScenario scenario,
  TestNode node, {
  Duration? timeout,
}) async {
  // Wall-clock fallback: the poll loop below is bounded by VirtualClock.nowMs,
  // which is frozen when the clock is disabled — on a slow/failed connection it
  // early-returns on success but otherwise spins forever (it never reaches the
  // virtual deadline). Delegate to the real-time TestNode waiter, which is what
  // the wall-clock tests used directly and which times out properly.
  if (!VirtualClock.enabled) {
    await node.waitForConnection(timeout: timeout);
    return;
  }
  if (!node.loggedIn) {
    throw Exception('Cannot wait for connection: node is not logged in');
  }

  // Scale the caller-supplied virtual timeout when running under
  // PARALLEL_WORKERS>=2: in that mode `TestNode.initSDK` defaults LAN
  // discovery OFF to prevent cross-process Tox-DHT cross-pollination,
  // which makes loopback multi-node bootstrap rely entirely on the
  // explicit `tox_bootstrap()` chain and the slower onion-announce path.
  // The wall-clock cost roughly doubles. Without scaling, multi-node
  // setUpAll budgets that pass `Duration(seconds: 25)` (e.g.
  // scenario_group_large_virtual_test) saturate before Tox finishes.
  // Single-worker / solo runs leave the timeout untouched.
  final parallelWorkers =
      int.tryParse(Platform.environment['PARALLEL_WORKERS'] ?? '1') ?? 1;
  final baseTimeout = timeout ?? const Duration(seconds: 15);
  final connectionTimeout = parallelWorkers >= 2
      ? Duration(milliseconds: baseTimeout.inMilliseconds * 3)
      : baseTimeout;

  await node.runWithInstanceAsync(() async {
    final ffiInstance = ffi_lib.Tim2ToxFfi.open();
    final deadline = VirtualClock.nowMs + connectionTimeout.inMilliseconds;
    int checkCount = 0;

    while (VirtualClock.nowMs < deadline) {
      checkCount++;
      int connectionStatus = 0;
      try {
        connectionStatus = ffiInstance.getSelfConnectionStatus();
      } catch (e) {
        final loginStatus = node.timManager!.getLoginStatus();
        connectionStatus = loginStatus == 1 ? 2 : 0;
      }

      if (connectionStatus == 1 || connectionStatus == 2) {
        // Give the network a beat to settle (virtual time, still progresses
        // Tox internal timers).
        await pumpTestTick(scenario,
            advanceMs: 500, iterationsPerInstance: 1);
        if (checkCount > 1) {
          print(
              '[Test] Node ${node.alias}: Connected to DHT! (connectionStatus=$connectionStatus)');
        }
        return;
      }

      if (checkCount % 10 == 0) {
        print(
            '[Test] Node ${node.alias}: Still waiting for connection (check $checkCount, connectionStatus=$connectionStatus)');
      }

      // Dense iteration with real wall pause for UDP round-trips.
      await pumpTestTick(scenario,
          advanceMs: 100,
          iterationsPerInstance: 3,
          wallSleep: const Duration(milliseconds: 10));
    }

    int finalConnectionStatus = 0;
    try {
      finalConnectionStatus = ffiInstance.getSelfConnectionStatus();
    } catch (e) {
      final loginStatus = node.timManager!.getLoginStatus();
      finalConnectionStatus = loginStatus == 1 ? 2 : 0;
    }

    if (finalConnectionStatus == 1 || finalConnectionStatus == 2) {
      print(
          '[Test] Node ${node.alias}: Connection timeout after $checkCount checks, but connection was established (status=$finalConnectionStatus)');
      return;
    }

    throw TimeoutException(
        'Timeout waiting for connection (virtual timeout: $connectionTimeout, checkCount: $checkCount, finalConnectionStatus: $finalConnectionStatus)');
  });
}

/// Virtual-clock variant of [pumpFriendConnection].
///
/// Iterates every node in [scenario] (not just nodeA/nodeB) so the shared
/// virtual clock advances uniformly — friend P2P only needs nodeA/nodeB but
/// ticking the whole scenario keeps every Tox instance's timers consistent.
/// nodeA / nodeB are accepted for signature parity with the wall-clock helper.
Future<void> pumpFriendConnectionVirtual(
  TestScenario scenario,
  TestNode nodeA,
  TestNode nodeB, {
  Duration duration = const Duration(seconds: 4),
  int iterationsPerPump = 50,
  int advanceMs = 50,
}) async {
  // Wall-clock fallback: the loop below advances on VirtualClock.nowMs, which
  // never moves when the clock is disabled — it would spin forever. Delegate
  // to the real-time pump so this helper is safe to call from a mode-aware
  // (unified) test file regardless of RUN_VIRTUAL.
  if (!VirtualClock.enabled) {
    await pumpFriendConnection(nodeA, nodeB,
        duration: duration, iterationsPerPump: iterationsPerPump);
    return;
  }
  final deadline = VirtualClock.nowMs + duration.inMilliseconds;
  while (VirtualClock.nowMs < deadline) {
    await pumpTestTick(
      scenario,
      advanceMs: advanceMs,
      iterationsPerInstance: iterationsPerPump,
    );
  }
}

/// Virtual-clock variant of [pumpGroupPeerDiscovery]. Same shape as
/// [pumpFriendConnectionVirtual].
Future<void> pumpGroupPeerDiscoveryVirtual(
  TestScenario scenario,
  TestNode nodeA,
  TestNode nodeB, {
  Duration duration = const Duration(seconds: 5),
  int iterationsPerPump = 30,
  int advanceMs = 50,
}) async {
  // Wall-clock fallback (see pumpFriendConnectionVirtual) — loops on
  // VirtualClock.nowMs, which is frozen when the clock is disabled.
  if (!VirtualClock.enabled) {
    await pumpGroupPeerDiscovery(nodeA, nodeB,
        duration: duration, iterationsPerPump: iterationsPerPump);
    return;
  }
  final deadline = VirtualClock.nowMs + duration.inMilliseconds;
  while (VirtualClock.nowMs < deadline) {
    await pumpTestTick(
      scenario,
      advanceMs: advanceMs,
      iterationsPerInstance: iterationsPerPump,
    );
  }
}

/// Virtual-clock variant of [waitUntilFounderSeesMemberInGroup].
///
/// Same return contract as the original (returns the first non-founder
/// userID seen by [founder], or null on timeout). Drives iteration through
/// [pumpTestTick] so the virtual clock advances between polls.
Future<String?> waitUntilFounderSeesMemberInGroupVirtual(
  TestScenario scenario,
  TestNode founder,
  TestNode otherNode,
  String groupId, {
  Duration timeout = const Duration(seconds: 90),
  Duration pumpDurationPerLoop = const Duration(milliseconds: 600),
  int iterationsPerPump = 50,
  int advanceMs = 50,
  Duration delayAfterPump = const Duration(milliseconds: 150),
  bool allowFallbackProceed = false,
}) async {
  // Wall-clock fallback: loops on VirtualClock.nowMs (frozen when disabled).
  // Delegate to the real-time waiter so unified files are safe in wall mode.
  if (!VirtualClock.enabled) {
    return waitUntilFounderSeesMemberInGroup(founder, otherNode, groupId,
        timeout: timeout,
        pumpDurationPerLoop: pumpDurationPerLoop,
        iterationsPerPump: iterationsPerPump,
        delayAfterPump: delayAfterPump,
        allowFallbackProceed: allowFallbackProceed);
  }
  final founderPublicKey = founder.getPublicKey();
  final otherPublicKey = otherNode.getPublicKey();
  final deadline = VirtualClock.nowMs + timeout.inMilliseconds;
  while (VirtualClock.nowMs < deadline) {
    await pumpGroupPeerDiscoveryVirtual(
      scenario,
      founder,
      otherNode,
      duration: pumpDurationPerLoop,
      iterationsPerPump: iterationsPerPump,
      advanceMs: advanceMs,
    );
    await pumpTestTick(scenario,
        advanceMs: delayAfterPump.inMilliseconds,
        iterationsPerInstance: 1);
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

  // Diagnostics/fallback (mirrors wall-clock variant).
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
              '[waitUntilFounderSeesMemberInGroupVirtual] founder visibility timeout for $groupId, but ${otherNode.alias} can see self in member list; proceeding due to allowFallbackProceed');
          return otherPublicKey;
        }
        print(
            '[waitUntilFounderSeesMemberInGroupVirtual] founder visibility timeout for $groupId: ${founder.alias} still cannot see any non-self member. '
            '${otherNode.alias} selfVisible=true founderVisibleFromOther=$founderVisibleFromOther');
      }
    }
  } catch (_) {
    // Ignore diagnostic errors.
  }

  try {
    final joinedResult = await otherNode.runWithInstanceAsync(
        () async => TIMGroupManager.instance.getJoinedGroupList());
    final joined = joinedResult.code == 0 &&
        (joinedResult.data?.any((g) => g.groupID == groupId) ?? false);
    if (joined) {
      if (allowFallbackProceed) {
        print(
            '[waitUntilFounderSeesMemberInGroupVirtual] founder visibility timeout for $groupId, but ${otherNode.alias} joined list contains group; proceeding due to allowFallbackProceed');
        return otherPublicKey;
      }
      print(
          '[waitUntilFounderSeesMemberInGroupVirtual] founder visibility timeout for $groupId: ${otherNode.alias} joined list contains group, but ${founder.alias} still cannot see any non-self member');
    }
  } catch (_) {
    // Timeout returns null; keep contract.
  }

  return null;
}

/// Top-level virtual-clock variant of [TestNode.waitForFriendConnection].
///
/// Polls getFriendList while advancing the shared virtual clock between
/// samples. Times are virtual ms.
Future<void> waitForFriendConnectionVirtual(
  TestScenario scenario,
  TestNode node,
  String friendUserId, {
  Duration? timeout,
}) async {
  // Wall-clock fallback (see waitForConnectionVirtual): the VirtualClock.nowMs
  // poll loop never advances when the clock is disabled, so a failed friend
  // connection would spin forever instead of timing out. Delegate to the
  // real-time TestNode waiter.
  if (!VirtualClock.enabled) {
    await node.waitForFriendConnection(friendUserId, timeout: timeout);
    return;
  }
  final connectionTimeout = timeout ?? const Duration(seconds: 45);
  final deadline = VirtualClock.nowMs + connectionTimeout.inMilliseconds;
  final startedAtMs = VirtualClock.nowMs;
  int checkCount = 0;

  final friendPublicKey = friendUserId.length >= 64
      ? friendUserId.substring(0, 64)
      : friendUserId;
  final targetAbbrev = friendPublicKey.length > 16
      ? '${friendPublicKey.substring(0, 16)}...'
      : friendPublicKey;

  print(
      '[waitForFriendConnectionVirtual] ENTRY node=${node.alias} target=$targetAbbrev timeout=${connectionTimeout.inSeconds}s');
  bool friendInList = false;
  int? lastRole;

  await node.runWithInstanceAsync(() async {
    // Ensure self is connected to DHT first.
    try {
      await waitForConnectionVirtual(scenario, node,
          timeout: const Duration(seconds: 10));
    } catch (e) {
      print(
          '[waitForFriendConnectionVirtual] Warning: self not yet connected to DHT: $e');
    }

    while (VirtualClock.nowMs < deadline) {
      checkCount++;
      final elapsedMs = VirtualClock.nowMs - startedAtMs;
      final friendListResult =
          await TIMFriendshipManager.instance.getFriendList();

      if (friendListResult.code != 0) {
        if (friendListResult.code == 6013) {
          throw TimeoutException(
              'getFriendList returned 6013 (sdk not init). Teardown may have started; aborting waitForFriendConnectionVirtual.');
        }
        if (checkCount <= 3 || checkCount % 10 == 0) {
          print(
              '[waitForFriendConnectionVirtual] Check $checkCount (elapsed=${elapsedMs ~/ 1000}s): getFriendList code=${friendListResult.code} desc=${friendListResult.desc}');
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
              '[waitForFriendConnectionVirtual] Check $checkCount (elapsed=${elapsedMs ~/ 1000}s): listLen=${list.length} '
              'friendIds=[${list.map((f) => f.userID.length > 12 ? '${f.userID.substring(0, 12)}...' : f.userID).join(', ')}]');
        }

        if (matchingFriends.isNotEmpty) {
          final friendInfo = matchingFriends.first;
          friendInList = true;
          final role = friendInfo.userProfile?.role;
          lastRole = role;
          final userProfile = friendInfo.userProfile;

          if (checkCount <= 3 || checkCount % 5 == 0) {
            print(
                '[waitForFriendConnectionVirtual] Check $checkCount (elapsed=${elapsedMs ~/ 1000}s): Friend IN LIST '
                'role=$role (1=ONLINE, 2=OFFLINE) userProfile?.role=${userProfile?.role}');
          }

          final isOnline = friendInfo.userProfile?.role == 1;

          if (isOnline == true) {
            print(
                '[waitForFriendConnectionVirtual] Friend $targetAbbrev is online after $checkCount checks (elapsed=${elapsedMs ~/ 1000}s)');
            return;
          } else {
            if (checkCount <= 8 || checkCount % 10 == 0) {
              print(
                  '[waitForFriendConnectionVirtual] (elapsed=${elapsedMs ~/ 1000}s) Friend in list but OFFLINE role=$role checkCount=$checkCount');
            }
          }
        } else {
          if (friendInList) {
            if (checkCount % 10 == 0) {
              print(
                  '[waitForFriendConnectionVirtual] WARNING (elapsed=${elapsedMs ~/ 1000}s): Friend was in list but now NOT FOUND');
            }
          } else {
            if (checkCount <= 5 || checkCount % 10 == 0) {
              print(
                  '[waitForFriendConnectionVirtual] Check $checkCount (elapsed=${elapsedMs ~/ 1000}s): Friend NOT in list '
                  'availableIds=[${list.map((f) => f.userID.length > 12 ? '${f.userID.substring(0, 12)}...' : f.userID).join(', ')}]');
            }
          }
        }
      } else {
        if (checkCount <= 3 || checkCount % 10 == 0) {
          print(
              '[waitForFriendConnectionVirtual] Check $checkCount (elapsed=${elapsedMs ~/ 1000}s): getFriendList code=0 but data=null');
        }
      }

      if (checkCount % 20 == 0) {
        print(
            '[waitForFriendConnectionVirtual] PROGRESS elapsed=${elapsedMs ~/ 1000}s checkCount=$checkCount friendInList=$friendInList lastRole=$lastRole');
      }

      // Iterate so Tox can establish P2P + advance the virtual clock.
      // Real wall sleep is critical: friend P2P handshake needs UDP/TCP
      // round-trips between iterates, which loopback OS scheduling needs
      // a few ms to deliver.
      await pumpTestTick(scenario,
          advanceMs: 250,
          iterationsPerInstance: 5,
          wallSleep: const Duration(milliseconds: 10));
    }

    final elapsedTotalMs = VirtualClock.nowMs - startedAtMs;
    final finalFriendListResult =
        await TIMFriendshipManager.instance.getFriendList();
    if (finalFriendListResult.code == 6013) {
      throw TimeoutException(
          'getFriendList returned 6013 (sdk not init) at end of waitForFriendConnectionVirtual. Teardown may have started.');
    }
    bool matchesFriend(String uid) =>
        uid == friendPublicKey ||
        (uid.length >= 64 && uid.startsWith(friendPublicKey));
    final hasFriend = finalFriendListResult.code == 0 &&
        finalFriendListResult.data != null &&
        finalFriendListResult.data!.any((f) => matchesFriend(f.userID));

    print(
        '[waitForFriendConnectionVirtual] TIMEOUT after ${elapsedTotalMs ~/ 1000}s checkCount=$checkCount');
    print(
        '[waitForFriendConnectionVirtual] FINAL getFriendList code=${finalFriendListResult.code} '
        'dataLen=${finalFriendListResult.data?.length ?? 0}');
    if (finalFriendListResult.data != null &&
        finalFriendListResult.data!.isNotEmpty) {
      for (int i = 0; i < finalFriendListResult.data!.length; i++) {
        final f = finalFriendListResult.data![i];
        final uid = f.userID;
        final role = f.userProfile?.role;
        final match = matchesFriend(uid);
        print(
            '[waitForFriendConnectionVirtual]   friend[$i] userID=${uid.length > 20 ? '${uid.substring(0, 20)}...' : uid} '
            'role=$role (1=ONLINE,2=OFFLINE) matchesTarget=$match');
      }
    } else {
      print(
          '[waitForFriendConnectionVirtual]   (no friends in list or data null)');
    }
    print(
        '[waitForFriendConnectionVirtual] FINAL hasFriend=$hasFriend lastRole=$lastRole');

    throw TimeoutException(
        'Timeout waiting for friend connection: $friendPublicKey (virtual timeout: $connectionTimeout). '
        'Final state: friend in list=$hasFriend lastRole=$lastRole elapsed=${elapsedTotalMs ~/ 1000}s. '
        'This may indicate that nodes are not connected to each other (check bootstrap configuration).');
  });
}

/// Virtual-clock variant of [establishFriendship].
///
/// Same multi-stage behaviour: friend-list converge pre-pump → fallback
/// polling → P2P wait — but every wall-clock delay is driven through the
/// virtual clock so total elapsed time is virtual ms.
Future<void> establishFriendshipVirtual(
  TestScenario scenario,
  TestNode alice,
  TestNode bob, {
  Duration? timeout,
}) async {
  // Wall-clock fallback: this helper has fixed-duration pre-pump loops keyed on
  // VirtualClock.nowMs, which is frozen when the clock is disabled — they would
  // spin forever. Delegate to the real-time establishFriendship so a mode-aware
  // (unified) test file can call this regardless of RUN_VIRTUAL.
  if (!VirtualClock.enabled) {
    await establishFriendship(alice, bob, timeout: timeout);
    return;
  }
  final friendshipTimeout = timeout ?? const Duration(seconds: 200);
  final deadline = VirtualClock.nowMs + friendshipTimeout.inMilliseconds;

  print(
      '[establishFriendshipVirtual] Starting friendship establishment between ${alice.alias} and ${bob.alias}');

  if (!alice.loggedIn || !bob.loggedIn) {
    throw Exception(
        'Cannot establish friendship: nodes must be logged in first');
  }

  alice.enableAutoAccept();
  bob.enableAutoAccept();

  try {
    await waitForConnectionVirtual(scenario, alice,
        timeout: const Duration(seconds: 10));
    await waitForConnectionVirtual(scenario, bob,
        timeout: const Duration(seconds: 10));
    if (alice.getConnectionStatus() == 0 || bob.getConnectionStatus() == 0) {
      print(
          '[establishFriendshipVirtual] Warning: One or both nodes still have connection_status=0 after wait');
    }
  } catch (e) {
    print(
        '[establishFriendshipVirtual] Warning: Nodes may not be fully connected: $e');
  }

  final aliceToxId = alice.getToxId();
  final bobToxId = bob.getToxId();
  print('[establishFriendshipVirtual] ${alice.alias} Tox ID: $aliceToxId');
  print('[establishFriendshipVirtual] ${bob.alias} Tox ID: $bobToxId');

  if (aliceToxId.isEmpty || aliceToxId.length != 76) {
    throw Exception(
        'Invalid Alice Tox ID: $aliceToxId (expected 76 hex characters)');
  }
  if (bobToxId.isEmpty || bobToxId.length != 76) {
    throw Exception(
        'Invalid Bob Tox ID: $bobToxId (expected 76 hex characters)');
  }

  final alicePublicKey = aliceToxId.substring(0, 64);
  final bobPublicKey = bobToxId.substring(0, 64);
  print(
      '[establishFriendshipVirtual] ${alice.alias} Public Key: $alicePublicKey');
  print('[establishFriendshipVirtual] ${bob.alias} Public Key: $bobPublicKey');

  print(
      '[establishFriendshipVirtual] ${alice.alias} adding ${bob.alias} as friend (Tox ID: $bobToxId)...');
  final aliceAddResult = await alice.runWithInstanceAsync(
      () async => TIMFriendshipManager.instance.addFriend(
            userID: bobToxId,
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
            addWording: 'Hello from Alice',
          ));
  if (aliceAddResult.code != 0) {
    print(
        '[establishFriendshipVirtual] Warning: ${alice.alias} addFriend returned code ${aliceAddResult.code}: ${aliceAddResult.desc}');
  } else {
    print(
        '[establishFriendshipVirtual] ${alice.alias} successfully added ${bob.alias} as friend');
  }

  print(
      '[establishFriendshipVirtual] ${bob.alias} adding ${alice.alias} as friend (Tox ID: $aliceToxId)...');
  final bobAddResult = await bob.runWithInstanceAsync(
      () async => TIMFriendshipManager.instance.addFriend(
            userID: aliceToxId,
            addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
            addWording: 'Hello from Bob',
          ));
  if (bobAddResult.code != 0) {
    print(
        '[establishFriendshipVirtual] Warning: ${bob.alias} addFriend returned code ${bobAddResult.code}: ${bobAddResult.desc}');
  } else {
    print(
        '[establishFriendshipVirtual] ${bob.alias} successfully added ${alice.alias} as friend');
  }

  bool listContainsPublicKey(List<String> list, String publicKey) => list.any(
      (id) => id == publicKey || (id.length >= 64 && id.startsWith(publicKey)));

  print(
      '[establishFriendshipVirtual] Pumping until friend lists converge or 3s elapses...');
  {
    final prePumpDeadline = VirtualClock.nowMs + 3000;
    bool converged = false;
    while (VirtualClock.nowMs < prePumpDeadline) {
      await pumpTestTick(scenario,
          advanceMs: 25, iterationsPerInstance: 40);
      final aliceFriends = await alice.getFriendList();
      final bobFriends = await bob.getFriendList();
      if (listContainsPublicKey(aliceFriends, bobPublicKey) &&
          listContainsPublicKey(bobFriends, alicePublicKey)) {
        converged = true;
        break;
      }
    }
    if (converged) {
      print(
          '[establishFriendshipVirtual] Friend lists converged during pre-pump');
    }
  }

  int checkCount = 0;
  while (VirtualClock.nowMs < deadline) {
    checkCount++;
    await pumpTestTick(scenario,
        advanceMs: 50, iterationsPerInstance: 120);
    final aliceFriends = await alice.getFriendList();
    final bobFriends = await bob.getFriendList();
    final aliceHasBob = listContainsPublicKey(aliceFriends, bobPublicKey);
    final bobHasAlice = listContainsPublicKey(bobFriends, alicePublicKey);

    if (aliceHasBob && bobHasAlice) {
      print(
          '[establishFriendshipVirtual] Bidirectional friendship established after $checkCount checks');
      final remainingMs = deadline - VirtualClock.nowMs;
      if (remainingMs < 2000) {
        print(
            '[establishFriendshipVirtual] Little time left in timeout, skipping P2P wait');
        return;
      }
      const pumpDurationMs = 800;
      final actualPumpMs = remainingMs > 4000
          ? pumpDurationMs
          : remainingMs.clamp(200, 800);
      print(
          '[establishFriendshipVirtual] Pumping Tox for P2P connection (${actualPumpMs}ms)...');
      await pumpFriendConnectionVirtual(
        scenario,
        alice,
        bob,
        duration: Duration(milliseconds: actualPumpMs),
      );

      final remainingForP2PMs = deadline - VirtualClock.nowMs;
      const minWaitSec = 15;
      const maxWaitSec = 30;
      final remainingForP2PSec = remainingForP2PMs ~/ 1000;
      final halfRemaining =
          remainingForP2PSec >= 2 ? (remainingForP2PSec ~/ 2) : 0;
      final waitEachSec = remainingForP2PSec >= 4
          ? (halfRemaining > maxWaitSec
              ? maxWaitSec
              : (halfRemaining < minWaitSec ? minWaitSec : halfRemaining))
          : remainingForP2PSec.clamp(1, maxWaitSec);
      final waitEach = Duration(seconds: waitEachSec);
      print(
          '[establishFriendshipVirtual] Waiting for Tox P2P connection sequentially (${waitEach.inSeconds}s each)...');
      // Sequential, not Future.wait: same reasoning as configureLocalBootstrapVirtual.
      // Concurrent waiters share VirtualClock and stomp on the process-global
      // current-instance pointer set by runWithInstanceAsync. Going sequentially
      // gives each side a clean virtual budget and instance context; the other
      // side still makes Tox-level progress through the shared pump.
      try {
        await waitForFriendConnectionVirtual(scenario, alice, bobToxId,
            timeout: waitEach);
        await waitForFriendConnectionVirtual(scenario, bob, aliceToxId,
            timeout: waitEach);
        print(
            '[establishFriendshipVirtual] Both sides see friend as ONLINE');
      } catch (e) {
        print(
            '[establishFriendshipVirtual] P2P wait timed out (friend list is established; tests may retry): $e');
      }
      return;
    }

    if (checkCount % 5 == 0) {
      print(
          '[establishFriendshipVirtual] Check $checkCount: alice has bob=$aliceHasBob, bob has alice=$bobHasAlice');
      print(
          '[establishFriendshipVirtual] Check $checkCount: aliceFriends=${aliceFriends.join(", ")}, bobFriends=${bobFriends.join(", ")}');
    }

    await pumpTestTick(scenario,
        advanceMs: 400, iterationsPerInstance: 1);
  }

  final finalAliceFriends = await alice.getFriendList();
  final finalBobFriends = await bob.getFriendList();
  final finalAliceHasBob =
      listContainsPublicKey(finalAliceFriends, bobPublicKey);
  final finalBobHasAlice =
      listContainsPublicKey(finalBobFriends, alicePublicKey);

  throw TimeoutException(
      'Timeout waiting for bidirectional friendship to be established (virtual timeout: $friendshipTimeout). '
      'Final state: alice has bob=$finalAliceHasBob, bob has alice=$finalBobHasAlice. '
      'aliceFriends=${finalAliceFriends.join(", ")}, bobFriends=${finalBobFriends.join(", ")}. '
      'This may indicate that nodes are not connected to each other (check bootstrap configuration).');
}

/// Virtual-clock variant of [configureLocalBootstrap].
///
/// The initial 500ms UDP-bind sleep stays as real wall time because that's
/// a real OS operation, not a Tox-protocol timer. Everything after that
/// drives time forward through the virtual clock.
Future<void> configureLocalBootstrapVirtual(TestScenario scenario) async {
  final stopwatch = Stopwatch()..start();

  if (scenario.nodes.length < 2) {
    print(
        '[BootstrapVirtual] SKIP: need at least 2 nodes, have ${scenario.nodes.length}');
    return;
  }

  print(
      '[BootstrapVirtual] START (T+0ms) nodes=${scenario.nodes.map((n) => n.alias).join(', ')}');

  // Real wall-time sleep: UDP listener bind is a kernel operation, not a
  // Tox-protocol timer. Virtualising it would race port readiness.
  await Future.delayed(const Duration(milliseconds: 500));
  print(
      '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: after initial 500ms wall-time delay (UDP bind)');

  Future<(int, String)> readPortAndDhtId(TestNode node) async {
    return node.runWithInstanceAsync(() async {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      int port = 0;
      for (int retry = 0; retry < 5; retry++) {
        port = ffiInstance.getUdpPort(ffiInstance.getCurrentInstanceId());
        if (port > 0) {
          final loginStatus = TIMManager.instance.getLoginStatus();
          if (loginStatus == 1) break;
        }
        if (retry < 4) {
          // Advance virtual time + iterate so any pending login tasks make
          // progress between port-readiness retries.
          await pumpTestTick(scenario,
              advanceMs: 200, iterationsPerInstance: 1);
        }
      }
      if (port == 0) return (0, '');
      final dhtIdBuf = pkgffi.malloc.allocate<ffi.Int8>(65);
      try {
        final dhtIdLen = ffiInstance.getDhtIdNative(dhtIdBuf, 65);
        if (dhtIdLen == 0 || dhtIdLen > 64) return (0, '');
        final dhtId =
            dhtIdBuf.cast<pkgffi.Utf8>().toDartString(length: dhtIdLen);
        return (port, dhtId);
      } finally {
        pkgffi.malloc.free(dhtIdBuf);
      }
    });
  }

  final nodeEndpoints = <(int, String)>[];
  for (final node in scenario.nodes) {
    final pair = await readPortAndDhtId(node);
    nodeEndpoints.add(pair);
    print(
        '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: endpoint ${node.alias} port=${pair.$1} dhtIdLen=${pair.$2.length}');
  }

  bool atLeastOneEndpoint = false;
  for (final ep in nodeEndpoints) {
    if (ep.$1 != 0 && ep.$2.isNotEmpty) {
      atLeastOneEndpoint = true;
      break;
    }
  }
  if (!atLeastOneEndpoint) {
    print(
        '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: ERROR no usable endpoint on any node');
    return;
  }

  for (int i = 0; i < scenario.nodes.length; i++) {
    final node = scenario.nodes[i];
    if (node.testInstanceHandle == null) {
      print(
          '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: WARNING ${node.alias} has no test instance handle');
      continue;
    }
    await node.runWithInstanceAsync(() async {
      final ffiInstance = ffi_lib.Tim2ToxFfi.open();
      for (int j = 0; j < scenario.nodes.length; j++) {
        if (i == j) continue;
        final port = nodeEndpoints[j].$1;
        final dhtId = nodeEndpoints[j].$2;
        if (port == 0 || dhtId.isEmpty) continue;
        final hostPtr = '127.0.0.1'.toNativeUtf8();
        final dhtIdPtr = dhtId.toNativeUtf8();
        try {
          final success = ffiInstance.addBootstrapNode(
              ffiInstance.getCurrentInstanceId(), hostPtr, port, dhtIdPtr);
          print(
              '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: ${node.alias} -> ${scenario.nodes[j].alias} 127.0.0.1:$port success=$success');
        } finally {
          pkgffi.malloc.free(hostPtr);
          pkgffi.malloc.free(dhtIdPtr);
        }
      }
    });
  }

  print(
      '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: Warmup pump (DHT handshake needs real UDP round-trips)');
  // Tox onion routing requires ~3 successful announce-response cycles before
  // tox_self_get_connection_status flips to non-zero. Each cycle needs real
  // UDP round-trips (loopback is sub-ms but the protocol needs ~3-5 cycles).
  // Drive ~3s of real wall time with dense iteration so all nodes see their
  // announces succeed before we start polling connection status. Empirically
  // 1.5s was enough to bring up 2 of 3 nodes; bumping to 3s catches the slow
  // one too.
  for (var i = 0; i < 300; i++) {
    await pumpTestTick(scenario,
        advanceMs: 50,
        iterationsPerInstance: 3,
        wallSleep: const Duration(milliseconds: 10));
  }
  print(
      '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: Warmup done; waiting for all nodes to connect (virtual timeout 10s each)...');
  // Sequential, not Future.wait: VirtualClock is process-global, and
  // pumpTestTick iterates every node in scenario.nodes on every tick. With N
  // concurrent waiters each calling pumpTestTick(advanceMs: 100), the shared
  // clock advances ~N×100ms per wall cycle and burns each waiter's deadline
  // in ~budget/N wall time before UDP bootstrap can converge. Going
  // sequentially gives each node its own full virtual budget, while the
  // others still make Tox-level progress because pumpTestTick already
  // iterates all of them.
  for (final node in scenario.nodes) {
    final nodeStopwatch = Stopwatch()..start();
    try {
      await waitForConnectionVirtual(scenario, node,
          timeout: const Duration(seconds: 10));
      print(
          '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: Node ${node.alias} connected to Tox (took ${nodeStopwatch.elapsedMilliseconds}ms wall)');
    } catch (e) {
      print(
          '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: Node ${node.alias} connection TIMEOUT after ${nodeStopwatch.elapsedMilliseconds}ms wall: $e');
    }
  }

  print(
      '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: Waiting for all nodes real Tox connection (virtual timeout 5s)...');
  try {
    await waitUntilWithVirtualPump(
      scenario,
      () => scenario.nodes.every((n) => n.getConnectionStatus() != 0),
      timeout: const Duration(seconds: 5),
      description: 'all nodes connected to DHT',
      advanceMs: 100,
      iterationsPerInstance: 1,
    );
    print(
        '[BootstrapVirtual] T+${stopwatch.elapsedMilliseconds}ms: All nodes connection_status != 0');
  } catch (e) {
    print(
        '[BootstrapVirtual] waitUntil all connected failed: $e');
  }

  stopwatch.stop();
  print('[BootstrapVirtual] DONE at T+${stopwatch.elapsedMilliseconds}ms total wall');
}
