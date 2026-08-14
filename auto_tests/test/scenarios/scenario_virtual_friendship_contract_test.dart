import 'dart:async';

import 'package:test/test.dart';

import '../test_fixtures.dart';
import '../test_helper.dart';

Future<TestScenario> _createScenario({required bool withBootstrap}) async {
  await setupTestEnvironment();
  final scenario = await createTestScenario(['alice', 'bob']);

  await scenario.initAllNodes(
    localDiscoveryEnabled: false,
    ipv6Enabled: false,
  );
  for (final node in scenario.nodes) {
    await node.login(timeout: const Duration(milliseconds: 500));
  }
  if (withBootstrap) {
    await configureLocalBootstrapVirtual(scenario);
  }
  return scenario;
}

Future<int?> _friendRole(TestNode observer, TestNode friend) async {
  final result = await observer.getFriendListResultWithInstance();
  final friendPublicKey = friend.getPublicKey();
  final matches = result.data
      ?.where((entry) =>
          entry.userID == friendPublicKey ||
          entry.userID.startsWith(friendPublicKey))
      .toList();
  return matches == null || matches.isEmpty
      ? null
      : matches.first.userProfile?.role;
}

TestScenario _lifecycleScenario(
  String alias, {
  bool virtualMode = true,
  Future<void> Function(
    TestNode node, {
    String? initPath,
    String? logPath,
    bool? localDiscoveryEnabled,
    bool? ipv6Enabled,
  })? nodeInitializer,
  Future<void> Function(TestNode node)? nodeDisposer,
}) {
  final scenario = TestScenario(
    virtualMode: virtualMode,
    nodeInitializer: nodeInitializer,
    nodeDisposer: nodeDisposer,
  );
  scenario.addNode(alias: alias, userId: 'test-$alias', userSig: 'sig-$alias');
  return scenario;
}

void main() {
  group('Virtual friendship contract', () {
    test('throws at the deadline when peers cannot come online', () async {
      final scenario = await _createScenario(withBootstrap: false);
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;
      const deadline = Duration(seconds: 4);
      final startedAt = VirtualClock.nowMs;

      try {
        await expectLater(
          establishFriendshipVirtual(
            scenario,
            alice,
            bob,
            timeout: deadline,
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(VirtualClock.nowMs - startedAt, deadline.inMilliseconds);
      } finally {
        await scenario.dispose();
        await teardownTestEnvironment();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('returns only after both peers report role 1', () async {
      expect(VirtualClock.enabled, isFalse,
          reason: 'the previous bundled test must restore wall-clock mode');
      expect(VirtualClock.nowMs, 0,
          reason: 'the previous bundled test must clear virtual time');
      final scenario = await _createScenario(withBootstrap: true);
      final alice = scenario.getNode('alice')!;
      final bob = scenario.getNode('bob')!;

      try {
        await establishFriendshipVirtual(
          scenario,
          alice,
          bob,
          timeout: const Duration(seconds: 60),
        );
        expect(await _friendRole(alice, bob), 1);
        expect(await _friendRole(bob, alice), 1);
      } finally {
        await scenario.dispose();
        await teardownTestEnvironment();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('boundary success requires a successful matching online sample', () {
      expect(
        isSuccessfulFriendConnectionBoundary(
          resultCode: 0,
          hasMatchingFriend: true,
          role: 1,
        ),
        isTrue,
      );
      expect(
        isSuccessfulFriendConnectionBoundary(
          resultCode: 1,
          hasMatchingFriend: true,
          role: 1,
        ),
        isFalse,
      );
      expect(
        isSuccessfulFriendConnectionBoundary(
          resultCode: 0,
          hasMatchingFriend: false,
          role: 1,
        ),
        isFalse,
      );
      expect(
        isSuccessfulFriendConnectionBoundary(
          resultCode: 0,
          hasMatchingFriend: true,
          role: 2,
        ),
        isFalse,
      );
    });

    test('two scenario leases keep virtual mode until final disposal',
        () async {
      final first = _lifecycleScenario('first', nodeInitializer: (
        node, {
        initPath,
        logPath,
        localDiscoveryEnabled,
        ipv6Enabled,
      }) async {});
      final second = _lifecycleScenario('second', nodeInitializer: (
        node, {
        initPath,
        logPath,
        localDiscoveryEnabled,
        ipv6Enabled,
      }) async {});
      addTearDown(() async {
        await first.dispose();
        await second.dispose();
      });

      await first.initAllNodes();
      expect(VirtualClock.earlyLeaseCount, 1);
      VirtualClock.advance(250);
      final beforeSecondLease = VirtualClock.nowMs;
      await second.initAllNodes();
      expect(VirtualClock.earlyLeaseCount, 2);
      expect(VirtualClock.nowMs, beforeSecondLease,
          reason: 'a later lease must not rewind the shared clock');

      await first.dispose();
      await first.dispose();
      expect(VirtualClock.earlyLeaseCount, 1,
          reason: 'duplicate scenario disposal must not release twice');
      expect(VirtualClock.enabled, isTrue);

      await second.dispose();
      expect(VirtualClock.earlyLeaseCount, 0);
      expect(VirtualClock.enabled, isFalse);
      expect(VirtualClock.nowMs, 0);
    });

    test('scenario lease starts before initialization and resets automatically',
        () async {
      var initializerCalls = 0;
      final scenario = _lifecycleScenario('automatic', nodeInitializer: (
        node, {
        initPath,
        logPath,
        localDiscoveryEnabled,
        ipv6Enabled,
      }) async {
        initializerCalls++;
        expect(VirtualClock.earlyLeaseCount, 1);
        expect(VirtualClock.enabled, isTrue);
        expect(VirtualClock.nowMs, 1000);
      });
      addTearDown(scenario.dispose);

      await scenario.initAllNodes();
      expect(initializerCalls, 1);
      expect(VirtualClock.earlyLeaseCount, 1);

      await scenario.dispose();
      await scenario.dispose();
      expect(VirtualClock.earlyLeaseCount, 0,
          reason: 'duplicate scenario disposal must not release twice');
      expect(VirtualClock.enabled, isFalse);
      expect(VirtualClock.nowMs, 0);
    });

    test('wall-mode scenario initialization does not acquire a lease',
        () async {
      var initialized = false;
      bool? forwardedLocalDiscovery;
      bool? forwardedIpv6;
      final scenario = _lifecycleScenario(
        'wall',
        virtualMode: false,
        nodeInitializer: (
          node, {
          initPath,
          logPath,
          localDiscoveryEnabled,
          ipv6Enabled,
        }) async {
          initialized = true;
          forwardedLocalDiscovery = localDiscoveryEnabled;
          forwardedIpv6 = ipv6Enabled;
        },
      );
      addTearDown(scenario.dispose);

      await scenario.initAllNodes(
        localDiscoveryEnabled: false,
        ipv6Enabled: false,
      );
      expect(initialized, isTrue);
      expect(forwardedLocalDiscovery, isFalse);
      expect(forwardedIpv6, isFalse);
      expect(VirtualClock.earlyLeaseCount, 0);
      expect(VirtualClock.enabled, isFalse);
      await scenario.dispose();
    });

    test('partial initialization disposes every node before lease rollback',
        () async {
      final initialized = <String>[];
      final disposed = <String>[];
      final scenario = TestScenario(
        virtualMode: true,
        nodeInitializer: (
          node, {
          initPath,
          logPath,
          localDiscoveryEnabled,
          ipv6Enabled,
        }) async {
          initialized.add(node.alias);
          if (node.alias == 'bob') {
            throw StateError('injected initialization failure');
          }
        },
        nodeDisposer: (node) async {
          disposed.add(node.alias);
        },
      );
      for (final alias in ['alice', 'bob', 'charlie']) {
        scenario.addNode(alias: alias, userId: 'test-$alias', userSig: 'sig');
      }
      addTearDown(scenario.dispose);

      await expectLater(scenario.initAllNodes(), throwsStateError);
      expect(initialized, ['alice', 'bob']);
      expect(disposed, ['alice', 'bob', 'charlie']);
      expect(scenario.nodes, isEmpty);
      expect(VirtualClock.earlyLeaseCount, 0);
      expect(VirtualClock.enabled, isFalse);
      expect(VirtualClock.nowMs, 0);
    });

    test('failed scenario cleanup retains its lease until cleanup succeeds',
        () async {
      var failCleanup = true;
      final scenario = _lifecycleScenario(
        'cleanup',
        nodeInitializer: (
          node, {
          initPath,
          logPath,
          localDiscoveryEnabled,
          ipv6Enabled,
        }) async {},
        nodeDisposer: (node) async {
          if (failCleanup) {
            throw StateError('injected cleanup failure');
          }
        },
      );
      addTearDown(() async {
        failCleanup = false;
        await scenario.dispose();
      });
      await scenario.initAllNodes();

      await expectLater(scenario.dispose(), throwsStateError);
      expect(VirtualClock.earlyLeaseCount, 1);
      expect(VirtualClock.enabled, isTrue);

      failCleanup = false;
      await scenario.dispose();
      expect(VirtualClock.earlyLeaseCount, 0);
      expect(VirtualClock.enabled, isFalse);
    });
  });
}
