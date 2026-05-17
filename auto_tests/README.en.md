# Tim2Tox Auto Tests
> Language: [Chinese](README.md) | [English](README.en.md)

Automated test suite covering UIKit / V2TIM-style APIs against both the Platform and the Binary Replacement paths. The most recent regression baseline lives in [VALIDATION_RESULTS.md](VALIDATION_RESULTS.md).

**Index**: [Overview](#overview) · [Layout](#layout) · [Test framework](#test-framework) · [Virtual clock](#virtual-clock-mode) · [Running tests](#running-tests) · [Troubleshooting](#troubleshooting) · [Best practices](#best-practices)

## Overview

This suite borrows the scenario-style approach from `c-toxcore/auto_tests` and uses Dart / Flutter's `test` / `flutter_test` framework. Each scenario simulates a real usage path with one or more `TestNode` peers.

### Design principles

- **Scenario-style tests**: each `.dart` file maps to a functional path.
- **Multi-node tests**: build with multiple `TestNode` instances to simulate multi-peer flows.
- **Auto-accept**: mirrors `c-toxcore`'s `tox_friend_add_norequest()` — auto-accepts friend requests, group invites, and file transfers.
- **Local bootstrap**: optional in-test bootstrap to accelerate peer discovery.

## Layout

```
tim2tox/auto_tests/
├── pubspec.yaml                    # Package config and dependencies
├── run_tests.sh                    # Basic runner (supports name filter)
├── run_tests_verbose.sh            # Verbose output
├── run_tests_ordered.sh            # **Recommended**: run Phase 1-14 in order, 180 s per-test timeout
├── run_all_tests.sh                # Compatibility entry; delegates to run_tests_ordered.sh
├── run_group_tests.sh              # Alias for group-related phases
├── run_tests_with_lib.sh           # Variant that explicitly sets DYLD_LIBRARY_PATH
├── check_test_assertions.sh        # Static check that prevents trivially-true asserts or empty catches
├── test/
│   ├── test_helper.dart            # Test helpers (TestNode, waitUntil, TestScenario)
│   ├── test_fixtures.dart          # Test data / mocks
│   ├── scenarios/                  # Business scenarios (139 total: 70 wall-clock + 69 *_virtual_test siblings)
│   │   ├── scenario_sdk_init_test.dart
│   │   ├── scenario_sdk_init_virtual_test.dart
│   │   ├── scenario_login_test.dart
│   │   ├── scenario_login_virtual_test.dart
│   │   ├── scenario_virtual_clock_smoke_test.dart   # Smoke test for the virtual-clock plumbing
│   │   └── ... (other files follow the same naming convention)
│   ├── scenarios_binary/           # Binary-replacement path scenarios (Phase 13, 3 files)
│   │   ├── scenario_native_callback_dispatch_test.dart  # NativeLibraryManager static listener dispatch
│   │   ├── scenario_custom_callback_handler_test.dart   # customCallbackHandler registration + dispatch
│   │   └── scenario_library_loading_test.dart           # setNativeLibraryName loading verification
│   └── unit_tests/                 # Pure unit tests (Phase 14 currently only runs test_listeners.dart)
│       ├── test_listeners.dart                          # Listener interface tests
│       ├── ffi_chat_service_avatar_detection_test.dart  # Avatar change detection
│       └── ffi_chat_service_avatar_sync_test.dart       # Avatar sync
├── VALIDATION_RESULTS.md           # Latest full regression pass/fail snapshot
├── VIRTUAL_CLOCK.md                # Virtual-clock design, usage, and performance
├── DEBUG_NATIVE_CRASH.md           # lldb walkthrough for native stacks
└── README.md                       # This file
```

## Test framework

### `TestNode`

`TestNode` represents one user peer in a scenario.

#### Lifecycle

- **`initSDK()`** — Initialize SDK, create an isolated test instance
- **`login()`** — Log in; auto-accept is enabled implicitly
- **`logout()`** — Log out
- **`unInitSDK()`** — Tear down the SDK and free resources

#### Instance context (must read for multi-instance)

In scenarios with multiple nodes (alice, bob, ...), **every** call into a `TIM*Manager` must be made while the matching node's instance is active. Otherwise the call lands on the wrong instance (or the default) and you'll see `ToxManager not initialized` or similar.

- **`runWithInstance(action)`** — Run `action` synchronously with this node as the current instance
- **`runWithInstanceAsync(action)`** — Run `action` asynchronously with this node as the current instance

**Rule**: any call to `TIMConversationManager.instance.*`, `TIMMessageManager.instance.*`, `TIMFriendshipManager.instance.*`, `TIMGroupManager.instance.*` (etc.) must be wrapped in the corresponding node's `runWithInstanceAsync` / `runWithInstance`. The receiver / listener registration should be wrapped in the receiver's instance. For example: Alice sending — `alice.runWithInstanceAsync(() => TIMMessageManager.instance.sendMessage(...))`; Bob registering a listener — `bob.runWithInstance(() => TIMMessageManager.instance.addAdvancedMsgListener(...))`. **Use `bob.getToxId()` (the 76-char Tox ID), not `bob.userId`, as the C2C receiver.**

- **`getFriendListResultWithInstance()`** — Fetch the friend-list result (with code) under this node's instance for assertions
- **`getConversationListWithInstance(nextSeq, count)`** — Fetch the conversation list under this node's instance

#### Waiting and synchronization

- **`waitForConnection()`** — Wait for the node to come online
- **`waitForFriendConnection(userId)`** — Wait for a specific friend connection
- **`waitForCallback(callbackName)`** — Wait for a specific callback
- **`waitForCondition(condition)`** — Wait for a generic predicate

#### Queries

- **`getToxId()`** — Tox ID (76 hex chars)
- **`getPublicKey()`** — Public key (64 hex chars)
- **`getFriendList()`** — Cached friend list
- **`isFriend(userId)`** — Friend check

#### Auto-accept

After login, `TestNode` auto-accepts friend requests, group invites, and file transfer requests — similar to `c-toxcore`'s `tox_friend_add_norequest()`.

### `TestScenario`

`TestScenario` orchestrates multiple nodes:

```dart
final scenario = await createTestScenario(['alice', 'bob']);
final alice = scenario.getNode('alice')!;
final bob = scenario.getNode('bob')!;

await scenario.initAllNodes();
await scenario.loginAllNodes();
await configureLocalBootstrap(scenario);
```

### Helpers

#### `waitUntil(condition, {timeout, description})`

Equivalent of `c-toxcore`'s `WAIT_UNTIL` macro:

```dart
await waitUntil(
  () => alice.loggedIn && bob.loggedIn,
  timeout: const Duration(seconds: 10),
  description: 'both nodes logged in',
);
```

#### `establishFriendship(alice, bob)`

Establishes a bidirectional friendship:

```dart
await establishFriendship(alice, bob);
// alice and bob are now mutual friends
```

#### `configureLocalBootstrap(scenario)`

Uses the first node as a local bootstrap source for the others; speeds up tests significantly.

## Virtual clock mode

Virtual clock is an optional acceleration mechanism: each test instance's `event_thread` is suspended on the C++ side, and Tox's internal `mono_time` reads from a **process-wide shared virtual clock**. Tests drive time manually with `pumpTestTick(scenario, ...)`. A "virtual advance 60 s" finishes within milliseconds of wall time, bypassing Tox protocol timers (60 s ping, 122 s BAD_NODE, 10 s onion path, ...).

### Why it exists

Tox protocol constants run in seconds (DHT heartbeat, friend reconnect, group announce). On wall-clock, multi-instance `setUpAll` phases get pinned by those timers for tens of seconds to minutes. Virtual clock decouples protocol time from wall time: protocol time can be compressed arbitrarily; UDP loopback still uses real wall time (`pumpTestTick` inserts small `wallSleep` to let loopback packets land).

### Core model

- **Shared virtual `mono_time`**: maintained on the Dart side by `VirtualClock`; mirrored into C++ via `tim2tox_ffi_set_virtual_time_ms()`.
- **Manual iteration**: each `pumpTestTick(scenario, ...)` advances the virtual clock and calls `tim2tox_ffi_iterate_instance()` on every instance.
- **Synchronous `task_queue` drain**: under test mode `tim2tox_ffi_iterate_instance` also drains the task queue, so signaling dispatch via `PostToEventThread` still runs.
- **Inline `RunOnEventThread`**: test mode runs it inline, avoiding the deadlock from waiting on `event_thread`.

### Usage

```bash
# Run every phase with the virtual clock (swaps each test for its *_virtual_test.dart
# sibling when one exists; falls back to the wall-clock original otherwise).
RUN_VIRTUAL=1 ./run_tests_ordered.sh

# Single phase / range / list work the same way
RUN_VIRTUAL=1 ./run_tests_ordered.sh 4
RUN_VIRTUAL=1 ./run_tests_ordered.sh 10-12
```

`RUN_VIRTUAL=0` (default) keeps the existing wall-clock behavior.

### Parallel execution (PARALLEL_WORKERS)

```bash
# Run 2 tests concurrently (each worker spawns its own flutter_tester)
PARALLEL_WORKERS=2 ./run_tests_ordered.sh

# 3 workers, restricted to specific phases
PARALLEL_WORKERS=3 ./run_tests_ordered.sh 4 10
```

`PARALLEL_WORKERS=N` flattens all selected tests into a single queue and dispatches them across N concurrent `flutter test` processes. Default is 1 (sequential). Rule of thumb on a developer Mac: 2–3 workers stay reliable, 4+ tends to trip Tox DHT timeouts and friend P2P handshake failures under CPU pressure. Each test file already has its own `setUpAll` so no cross-phase ordering is assumed; results are still printed grouped by phase after the parallel batch completes.

### Phase coverage

Phase 1–12 have `*_virtual_test.dart` siblings (~69 files plus `scenario_virtual_clock_smoke_test.dart`), covering basics / friendship / message / group / ToxAV / profile / conversation / file / conference / group-ext / network / other. Phase 13 (Binary Replacement) and Phase 14 (unit_tests) do not depend on Tox protocol timers and **do not need** virtual variants.

### About flakes

Virtual-mode stability matches wall-clock — it does **not** fix Tox-protocol-level flakes (DHT jitter, friend P2P handshake timing, group announce convergence). If a test is flaky in wall-clock mode, virtual mode won't make it stable; you have to find the root cause in the test logic or the protocol layer.

### Full guide

See [VIRTUAL_CLOCK.md](VIRTUAL_CLOCK.md) (core API, `*Virtual` replacement table, canonical `setUpAll` template, group-invite retry pattern, performance numbers, C++ internals).

## Running tests

### All tests

```bash
# Basic (all tests)
./run_tests.sh

# Run in order to reduce concurrency contention (recommended)
./run_tests_ordered.sh

# Skip the assertion lint guard (it normally runs ./check_test_assertions.sh first)
ASSERTION_GUARD=0 ./run_tests_ordered.sh

# Phase 11 includes scenario_dht_nodes_response_api_test by default (previously gated
# behind a flag because of a native trampoline crash). To skip it locally:
RUN_NATIVE_CRASH_TESTS=0 ./run_tests_ordered.sh 11

# Run only PHASE5_TOXAV + PHASE6_PROFILE, no early-exit on failure, summarize results
./run_tests_ordered.sh 5,6
# or: ./run_tests_ordered.sh PHASE5_TOXAV,PHASE6_PROFILE

# Phases 7–9 (conversation / file / conference)
./run_tests_ordered.sh 7-9
# or: ./run_tests_ordered.sh 7,8,9   or   ./run_tests_ordered.sh 7 9

# Compatibility entry — equivalent to run_tests_ordered.sh
./run_all_tests.sh

# Run the assertion lint by itself
./check_test_assertions.sh

# Verbose output
./run_tests_verbose.sh
```

### Running specific phases

```bash
# Phases 10/11/12 (group ext / network / other)
./run_tests_ordered.sh 10 11 12

# Phase 13 (Binary Replacement)
./run_tests_ordered.sh 13
./run_tests_ordered.sh BINARY

# Phase 14 (unit_tests)
./run_tests_ordered.sh 14
./run_tests_ordered.sh UNIT
```

### A single test

```bash
flutter test test/scenarios/scenario_login_test.dart
flutter test --name "login"                # by test name
```

### Environment variables

- `RUN_VIRTUAL=1` — swap each test for its `*_virtual_test.dart` sibling when present (see [Virtual clock mode](#virtual-clock-mode)).
- `PARALLEL_WORKERS=N` — flatten selected tests into one queue and run N concurrently (see above).
- `ASSERTION_GUARD=0` — skip the `check_test_assertions.sh` pre-flight.
- `RUN_NATIVE_CRASH_TESTS=0` — exclude `scenario_dht_nodes_response_api_test` from Phase 11.
- `RETRY_COUNT=N` — re-run each failed test up to N times before declaring failure. Tests that pass on retry are still counted as passing but are listed separately in a "Flaky" section of the summary. Used by Tier 2 CI (`RETRY_COUNT=1`).
- `SKIP_PHASES=N1,N2,...` — drop these phases from the run even if they were otherwise selected (or implied by "all phases"). Used by Tier 3 nightly to skip Phase 11 (which is reserved for Tier 4).

## Local smoke (Tier 1)

Recommended before every `git push`. Runs Phases 1 (basic), 3 (message), 12 (other), and 14 (unit tests) under the virtual clock:

```bash
RUN_VIRTUAL=1 ./run_tests_ordered.sh 1,3,12 14
# ~25 tests, ≤2 min on M-series. No CI workflow — this is the dev pre-push gate.
```

## CI pipeline (Tier 2 / 3 / 4)

Three GitHub Actions workflows live in `toxee/.github/workflows/`. Virtual-clock tiers (2) give fast PR feedback; wall-clock tiers (3, 4) catch real-timing protocol regressions that the virtual clock can hide.

| Tier | Workflow                  | Trigger                                                       | Mode                  | Phases             | Runner               | Budget |
|------|---------------------------|---------------------------------------------------------------|-----------------------|--------------------|----------------------|--------|
| 2    | `auto_tests.yml`          | every PR + push to `main` / `master`                          | virtual, `RETRY_COUNT=1` | 1–8, 10, 12–14   | ubuntu               | 30 min |
| 3    | `auto_tests_nightly.yml`  | cron `02:00 UTC` + `workflow_dispatch`                        | wall-clock            | 1–10, 12–14 (Phase 11 skipped via `SKIP_PHASES=11`) | ubuntu | 90 min |
| 4    | `auto_tests_full.yml`     | `workflow_dispatch`, PR label `ci:full`, push to `release/**` | wall-clock            | 1–14 (full, incl. 11) | ubuntu + macOS matrix | 120 min |

Tier 4 is the only path that exercises Phase 11 (`scenario_dht_nodes_response_api_test`, real-DHT bootstrap, LAN discovery) — keep large protocol-layer changes behind a `ci:full`-labeled PR. `tool/ci/build_tim2tox.sh` builds the FFI lib for each tier; Tiers 2/3/4 pass `--toxav --dht-bootstrap` so the suite has the same feature surface as a developer build (production app builds keep both flags off).

## Troubleshooting

### Native crash (SIGSEGV / exit 139)

**Symptom**: process exits 139, or log shows `[callback_bridge] FATAL: end backtrace`.

**Steps**:
1. **Capture the native stack**: follow [DEBUG_NATIVE_CRASH.md](DEBUG_NATIVE_CRASH.md) — the `run_conversation_test_with_lldb.sh` / `run_pin_test_with_lldb.sh` scripts already wrap lldb. On a stop, run `bt` and `frame variable`.
2. **Common causes**: dangling `lastMessage` in conversation callbacks; cross-thread use of `user_data`; missing `instance_id` propagation in multi-instance; `Dart_PostCObject_DL` after the isolate is destroyed. Check recent commits in `ffi/callback_bridge.cpp` and `ffi/dart_compat_listeners.cpp`.

### Native libraries not found

**Symptom**: test fails to load the native library.

**Steps**:
1. `flutter pub get`
2. Build the native library (auto_tests is already inside `tim2tox/`, so just go up one level):
   ```bash
   cd ..
   ./build_ffi.sh
   ```
3. Verify library path config.

### Environment-dependent failures

**Symptom**: tests behave inconsistently across machines.

**Steps**:
1. `flutter doctor`
2. Dart >= 3.0.0
3. Make sure the test data directory is writable.

## Best practices

### 1. Test structure

```dart
void main() {
  group('Test Group', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUp(() async {
      await setupTestEnvironment();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      await scenario.loginAllNodes();
      await configureLocalBootstrap(scenario);
    });

    tearDown(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test('test case', () async {
      // test code
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
```

### 2. Waiting / sync

- Use `waitUntil()` for predicate-based waits
- Use `waitForConnection()` for network readiness
- Use `waitForFriendConnection()` for friend handshake completion
- Set explicit timeouts on async operations

### 3. Error handling

- Always check the return code and error message
- Provide assertion messages that are useful when something fails
- On timeout, include diagnostic information

### 4. Resource cleanup

- Tear down in `tearDown()`
- `scenario.dispose()` cleans up every node
- `teardownTestEnvironment()` cleans the global env

## Build & test status

- ✅ **Compile**: All compile errors resolved; tests build cleanly.
- ✅ **Phase 13 Binary Replacement**: 15/15 passing (2026-02-10 baseline).
- **Latest regression status**: see [VALIDATION_RESULTS.md](VALIDATION_RESULTS.md).
- **Native crash debugging**: see [DEBUG_NATIVE_CRASH.md](DEBUG_NATIVE_CRASH.md).
