# Virtual Clock Mode — Engineer Guide

A detailed guide for writing or migrating a `tim2tox/auto_tests` test to virtual-clock mode. Pair with `README.md` (which has a high-level overview); this file covers the API surface, patterns, gotchas, and internals.

**Audience:** engineers authoring new `*_virtual_test.dart` files or porting wall-clock tests over.

---

## 1. Why virtual clock

The Tox protocol is full of multi-second timers:

| Constant | Value | Purpose |
|---|---|---|
| `PING_INTERVAL` | 60 s | DHT keep-alive |
| `BAD_NODE_TIMEOUT` | 122 s | DHT node eviction |
| Onion path timeout | 10 s | Path rotation |
| Friend reconnect | 5–10 s | P2P retry cadence |
| Group announce / connect | seconds | NGC discovery |

In wall-clock mode each timer eats real wall seconds — a multi-instance setUpAll easily burns 30–60 s before the first test body runs. Virtual mode decouples Tox-protocol time from wall time: 60 s of protocol time can pass in milliseconds.

What virtual mode does **not** compress:

- **Loopback UDP delivery.** Packets between sibling instances still need real wall time to traverse the OS socket buffer. `pumpTestTick` interleaves a small `wallSleep` (default 5 ms) between iterate bursts for exactly this reason.
- **Kernel operations** (UDP bind, file I/O). `configureLocalBootstrapVirtual` keeps a real 500 ms wall sleep around UDP listener bind because that's a kernel op, not a Tox timer.

---

## 2. Core API (in `test/test_helper.dart`)

### `VirtualClock`

Static-only class — there is exactly one virtual clock per process.

| Member | Purpose |
|---|---|
| `VirtualClock.enableEarly()` | Call **BEFORE** `scenario.initAllNodes()`. Sets the process-global default `test_mode` flag via `tim2tox_ffi_set_default_test_mode(1)` so the `V2TIMManagerImpl` constructor inherits it and `InitSDK` never spawns an `event_thread`. **Required** for signaling and any other flow that depends on `task_queue` being driven by `tim2tox_ffi_iterate_instance` rather than the suppressed event_thread. Also seeds the clock at 1000 ms. |
| `VirtualClock.enableForScenario(scenario)` | Call **AFTER** `scenario.initAllNodes()`. Calls `tim2tox_ffi_set_test_mode(handle, 1)` on every node's test instance, then seeds the clock at 1000 ms. Idempotent — safe to call multiple times. For group-only tests this is sufficient because group flows go through `tox_iterate` which both event_thread and `pumpTestTick` drive. |
| `VirtualClock.advance(ms)` | Bump the shared clock by `ms` virtual milliseconds. Does **not** iterate; callers must follow up with iteration. Prefer `pumpTestTick` for the combined advance-then-iterate pattern. |
| `VirtualClock.nowMs` | Current virtual clock value (read-only int). |
| `VirtualClock.enabled` | Whether test mode is currently enabled for this process. The `*Virtual` helpers below transparently fall back to wall-clock behavior when `false`. |

### Pump primitives

| Function | Purpose |
|---|---|
| `pumpTestTick(scenario, {advanceMs, iterationsPerInstance, wallSleep})` | Advance virtual clock by `advanceMs`, iterate each instance, then wall-sleep `wallSleep` for loopback delivery. Defaults: `advanceMs: 50`, `iterationsPerInstance: 1`, `wallSleep: 5 ms`. Iterations auto-scale with `advanceMs` (formula: `floor(advanceMs / 50)`, lower-bounded by the caller's `iterationsPerInstance`). Batches large iterate counts (≥10) into 10 chunks with 2 ms wall yields between batches so loopback UDP packets settle. |
| `pumpTestTickAv(scenario, ...)` | Same as `pumpTestTick` but also calls `tim2tox_ffi_av_iterate` on each instance. Use for ToxAV tests — the default `pumpTestTick` does **not** advance ToxAV's separate iterate loop. |
| `waitUntilWithVirtualPump(scenario, cond, {timeout, advanceMs, iterationsPerInstance, wallSleep, description})` | Poll `cond` while ticking the virtual clock. `timeout` is interpreted as virtual milliseconds when enabled, real milliseconds otherwise. Throws `TimeoutException` after the virtual budget elapses. Includes a 10-iteration microtask drain after the deadline so native-callback → ReceivePort → listener chains can settle. |
| `waitUntilWithAvVirtualPump(scenario, cond, ...)` | AV-aware sibling — pumps both Tox and ToxAV iterate per loop. |

When `VirtualClock.enabled == false`, every pump primitive delegates to its wall-clock equivalent (`pumpAllInstancesOnce` / `waitUntilWithPump`), so a single helper can serve both modes.

---

## 3. `*Virtual` drop-in replacements

Each wall-clock helper has a virtual sibling that threads `scenario` through and drives the shared clock instead of `Future.delayed`.

| Wall-clock | Virtual |
|---|---|
| `configureLocalBootstrap(scenario)` | `configureLocalBootstrapVirtual(scenario)` |
| `establishFriendship(a, b, timeout: t)` | `establishFriendshipVirtual(scenario, a, b, timeout: t)` |
| `node.waitForConnection(timeout: t)` | `waitForConnectionVirtual(scenario, node, timeout: t)` |
| `node.waitForFriendConnection(fid, timeout: t)` | `waitForFriendConnectionVirtual(scenario, node, fid, timeout: t)` |
| `pumpFriendConnection(a, b, duration: d)` | `pumpFriendConnectionVirtual(scenario, a, b, duration: d)` |
| `pumpGroupPeerDiscovery(a, b, duration: d)` | `pumpGroupPeerDiscoveryVirtual(scenario, a, b, duration: d)` |
| `waitUntilFounderSeesMemberInGroup(f, o, gid, timeout: t)` | `waitUntilFounderSeesMemberInGroupVirtual(scenario, f, o, gid, timeout: t)` |
| `waitUntilWithPump(cond, timeout: t)` | `waitUntilWithVirtualPump(scenario, cond, timeout: t)` |
| `Future.delayed(Duration(milliseconds: N))` | `pumpTestTick(scenario, advanceMs: N)` |
| `pumpAllInstancesOnce(iterations: N)` | `pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: N)` |

Rule of thumb: if the original test waits, sleeps, or pumps, the virtual variant should call the corresponding `*Virtual` helper instead. Mixing wall-clock `Future.delayed` into a virtual test does not corrupt anything — it just wastes wall time while the virtual clock stands still.

---

## 4. Canonical `setUpAll` pattern

```dart
setUpAll(() async {
  await setupTestEnvironment();

  // Step 1: enable test mode BEFORE any test instance is created.
  // This sets the process-global default so V2TIMManagerImpl's constructor
  // reads test_mode = true and InitSDK never spawns event_thread.
  await VirtualClock.enableEarly();

  scenario = await createTestScenario(['alice', 'bob']);
  alice = scenario.getNode('alice')!;
  bob = scenario.getNode('bob')!;

  await scenario.initAllNodes();

  // Step 2: seed virtual clock & sync the per-instance flag for the handles
  // that now exist. Idempotent w.r.t. enableEarly.
  await VirtualClock.enableForScenario(scenario);

  await Future.wait([
    alice.login(),
    bob.login(),
  ]);
  await waitUntil(() => alice.loggedIn && bob.loggedIn);

  // Step 3: use *Virtual helpers from here on
  await configureLocalBootstrapVirtual(scenario);
  await Future.wait([
    establishFriendshipVirtual(scenario, alice, bob),
  ]);
});
```

**Order matters.** `enableEarly` must run before `initAllNodes` so the constructor inherits the flag; if you forget and only call `enableForScenario` later, signaling tests will hang because `event_thread` is already running and `task_queue` ownership is ambiguous. Group-only tests that don't touch signaling can skip `enableEarly` — but defaulting to "always call `enableEarly` first" costs nothing.

---

## 5. Group invite retry pattern

Group invites can race with NGC peer discovery on loopback. When waiting for `onGroupInvited`, wrap the wait in a small retry loop and re-issue `inviteUserToGroup` after each miss:

```dart
var arrived = false;
for (var attempt = 0; !arrived && attempt < 3; attempt++) {
  if (attempt > 0) {
    member.clearCallbackReceived('onGroupInvited');
    await founder.runWithInstanceAsync(() async =>
        TIMGroupManager.instance.inviteUserToGroup(
          groupID: groupId,
          userList: [member.getPublicKey()],
        ));
  }
  try {
    await waitUntilWithVirtualPump(
      scenario,
      () => member.callbackReceived['onGroupInvited'] == true,
      timeout: const Duration(seconds: 15),
      description: '${member.alias} onGroupInvited (attempt ${attempt + 1})',
    );
    arrived = true;
  } catch (_) {
    // Retry up to 3 times.
  }
}
expect(arrived, isTrue,
    reason: '${member.alias} did not receive onGroupInvited after 3 attempts');
```

The first `inviteUserToGroup` happens before the loop (omitted above for brevity); the loop only re-issues on retry.

---

## 6. Gotchas

- **`wallSleep` is NOT optional.** Loopback UDP round-trips need real wall time. Default 5 ms works for friend P2P handshake; bump to 30–200 ms for conference-style flows with multi-step packet delivery (e.g. `wallSleep: const Duration(milliseconds: 50)` in `pumpTestTickAv` for conference audio).
- **`pumpTestTick` runs one round of iterates per call** — but auto-scales with `advanceMs`. `pumpTestTick(advanceMs: 3000)` fires 60 iterates per instance (floor(3000/50)), not 1. If you need extra iterate density without advancing more time, pass `iterationsPerInstance: N` and the helper will use `max(N, advanceMs/50)`.
- **Batched iterates.** When effective iterations ≥10 the helper splits into 10 batches with 2 ms wall yields between them, so packet bursts don't pile up in the OS socket buffer.
- **`RunOnEventThread` runs inline** in test mode — no future-wait deadlock, no event_thread dispatch.
- **`task_queue` is drained synchronously** by `tim2tox_ffi_iterate_instance` (called by every `pumpTestTick`), so `PostToEventThread` tasks (signaling dispatch, conversation manager work, etc.) still execute, just on the test thread instead of the event thread.
- **ToxAV requires the AV pump.** Use `pumpTestTickAv` / `waitUntilWithAvVirtualPump` for any test that depends on call-state transitions or audio/video frame delivery. The default `pumpTestTick` does **not** touch ToxAV.
- **`enableEarly` is process-global.** Once flipped, every subsequently constructed `V2TIMManagerImpl` is in test mode. A test that wants to mix test-mode and non-test-mode instances in the same process needs to use `tim2tox_ffi_set_test_mode(handle, 0)` to opt specific instances out.
- **Virtual mode does not fix protocol flakes.** DHT / friend P2P / group announce flakes exist independently of clock source. If a test is flaky in wall mode, expect equivalent flake (not worse, not better) in virtual mode.

---

## 7. C++ internals (for engineers reading the source)

| Symbol | Location | Purpose |
|---|---|---|
| `g_default_test_mode` | `source/V2TIMManagerImpl.cpp` | Process-global atomic flag the `V2TIMManagerImpl` constructor reads into `test_mode_`. |
| `tim2tox_ffi_set_default_test_mode(int)` | `ffi/tim2tox_ffi.cpp` | Flips `g_default_test_mode`. Called by `VirtualClock.enableEarly()`. |
| `tim2tox_ffi_set_test_mode(handle, int)` | `ffi/tim2tox_ffi.cpp` | Flips an existing instance's `test_mode_` post-construction. Called by `VirtualClock.enableForScenario()` for each node. |
| `tim2tox_ffi_set_virtual_time_ms(uint64_t)` | `ffi/tim2tox_ffi.cpp` | Stores the shared virtual clock value read by `tim2tox_virtual_time_cb`. |
| `tim2tox_ffi_iterate_instance(handle)` | `ffi/tim2tox_ffi.cpp` | Drains `task_queue` + calls `tox_iterate` + (in `V2TIMSignalingManagerImpl`) checks invite timeouts via `mono_time`. The single chokepoint the test harness drives. |
| `mono_time_set_current_time_callback` | c-toxcore public API | Per-Tox-instance callback that returns the current time. Installed once per instance during `InitSDK` in test mode (`V2TIMManagerImpl.cpp` line ~404), wired to `tim2tox_virtual_time_cb` which reads the global virtual clock. |

This means every Tox internal timer (`mono_time_is_timeout`, `PING_INTERVAL`, `BAD_NODE_TIMEOUT`, onion path expiry) reads from the same shared clock — advancing it from Dart instantly fast-forwards every instance's internal timers in lockstep.

---

## 8. Performance expectations

Empirical numbers from a recent `RUN_VIRTUAL=1` cross-phase run (macOS, M-series, loopback):

| Phase | Wall | Virtual | Speed-up |
|---|---|---|---|
| Phase 4 (group)         | 269 s | 213 s | 1.26× |
| Phase 10 (group ext)    | 569 s | 287 s | 1.98× |
| Phase 12 (other)        | 218 s | 158 s | 1.38× |

Typical multi-instance phase setUpAll-heavy work: ~2×. Single-instance / small phases (Phase 1 basic, Phase 14 unit) gain little because they don't sit on Tox-protocol timers.

The ceiling is set by loopback wall sleeps inside `pumpTestTick` — increasing `advanceMs` past ~3000 doesn't reduce wall time further because real packet delivery dominates.

---

## 9. Migration checklist (wall → virtual)

1. Copy `scenario_foo_test.dart` to `scenario_foo_virtual_test.dart`.
2. Add `await VirtualClock.enableEarly();` immediately after `setupTestEnvironment()`.
3. Add `await VirtualClock.enableForScenario(scenario);` immediately after `initAllNodes()`.
4. Replace every helper in the table from §3 with its `*Virtual` sibling, threading `scenario` through.
5. Replace `Future.delayed(Duration(milliseconds: N))` with `pumpTestTick(scenario, advanceMs: N)`.
6. For ToxAV tests, replace `pumpTestTick` / `waitUntilWithVirtualPump` with the `*Av` siblings.
7. Run `flutter test test/scenarios/scenario_foo_virtual_test.dart` and compare against the wall-clock baseline — virtual mode should match wall reliability, not exceed it.
8. Add the new file under `test/scenarios/`. `run_tests_ordered.sh` auto-detects `*_virtual_test.dart` siblings when `RUN_VIRTUAL=1`.

---

## See also

- `auto_tests/README.md` — high-level overview and Phase coverage table
- `auto_tests/test/test_helper.dart` — authoritative source for every helper above
- `ffi/tim2tox_ffi.{h,cpp}` — FFI symbol declarations
- `source/V2TIMManagerImpl.cpp` — `g_default_test_mode`, `tim2tox_virtual_time_cb` wiring
