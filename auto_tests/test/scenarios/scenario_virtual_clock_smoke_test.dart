// Virtual-clock harness smoke test.
//
// Verifies that the new test-mode FFI exports actually work end-to-end:
//   1. setTestMode disables per-instance event_thread (no auto iteration)
//   2. setVirtualTimeMs feeds a process-global clock into every test-mode
//      instance's mono_time
//   3. iterateInstance drives one tox_iterate manually
//   4. pumpTestTick + advance combine into a tick loop
//
// Does NOT touch any wall-clock helper (establishFriendship, pumpFriendConnection,
// configureLocalBootstrap, etc.) — those still drive real time. Migrating them
// to virtual time is the next step.

import 'package:test/test.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Virtual Clock Smoke Tests', () {
    late TestScenario scenario;

    setUpAll(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob']);
      await scenario.initAllNodes();
      // Enable test mode BEFORE login so event_thread never starts.
      await VirtualClock.enableForScenario(scenario);
      // Now safe to log in — InitSDK will see test_mode_ = true and skip the
      // event_thread spawn.
      await Future.wait([
        for (final node in scenario.nodes) node.login(),
      ]);
      await waitUntil(() => scenario.nodes.every((n) => n.loggedIn));
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test('test mode is enabled for all nodes', () {
      expect(VirtualClock.enabled, isTrue);
      expect(VirtualClock.nowMs, greaterThanOrEqualTo(1000));
      expect(scenario.nodes.length, equals(2));
      for (final node in scenario.nodes) {
        expect(node.testInstanceHandle, isNotNull);
        expect(node.loggedIn, isTrue);
      }
    });

    test('advance bumps virtual clock monotonically', () {
      final before = VirtualClock.nowMs;
      VirtualClock.advance(500);
      expect(VirtualClock.nowMs, equals(before + 500));
      VirtualClock.advance(2500);
      expect(VirtualClock.nowMs, equals(before + 3000));
    });

    test('pumpTestTick advances and iterates without throwing', () async {
      final before = VirtualClock.nowMs;
      // 200 ticks × 50ms = 10s virtual, each tick iterates both instances once.
      // Should complete in well under a real second.
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 1);
      }
      stopwatch.stop();
      expect(VirtualClock.nowMs, equals(before + 200 * 50));
      // Real wall time should be small because we're not sleeping.
      // Print for diagnostics; assert a generous bound.
      // ignore: avoid_print
      print('[smoke] 200 ticks took ${stopwatch.elapsedMilliseconds}ms real time');
      expect(stopwatch.elapsed.inSeconds, lessThan(10));
    });

    test('waitUntilWithVirtualPump returns when condition met early', () async {
      var ticks = 0;
      final before = VirtualClock.nowMs;
      await waitUntilWithVirtualPump(
        scenario,
        () {
          ticks++;
          return ticks >= 5;
        },
        timeout: const Duration(seconds: 5),
        description: 'tick counter reaches 5',
        advanceMs: 50,
      );
      // Should have advanced only ~5 ticks × 50ms (plus a couple slop).
      expect(VirtualClock.nowMs - before, lessThan(1000));
      expect(ticks, greaterThanOrEqualTo(5));
    });

    test('waitUntilWithVirtualPump times out on virtual budget', () async {
      final before = VirtualClock.nowMs;
      expect(
        () => waitUntilWithVirtualPump(
          scenario,
          () => false,
          timeout: const Duration(seconds: 2),
          description: 'never true',
          advanceMs: 50,
        ),
        throwsA(isA<Object>()),
      );
      // Even after timeout fires, the virtual clock should be roughly
      // advanced by the budget (within iterate slop).
      // (We can't check the exact value because the future is rejected and
      // the test framework will catch the throw; just sanity-check the clock
      // is still monotonic.)
      expect(VirtualClock.nowMs, greaterThanOrEqualTo(before));
    });
  });
}
