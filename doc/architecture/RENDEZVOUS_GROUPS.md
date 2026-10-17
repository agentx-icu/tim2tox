# Rendezvous groups — transport-only NGC cells

Rendezvous groups let clients that never met find each other through the Tox
DHT without a directory or a server. Every client derives the same 32-byte
seed from shared knowledge (toxee: a geohash cell), the seed yields a
deterministic NGC keypair, and therefore a deterministic Chat ID that
`tox_group_join` can look up through the ordinary DHT announces. Whoever
finds nobody within 30 s founds the group with that same keypair
(`tox_group_new_with_seed`, a private toxcore API carried by the
`agentx-icu/c-toxcore` fork, branch `agentx/group-new-with-seed`).

Tim2Tox treats such a group as **transport only**:

- it is never a V2TIM group — no `OnJoinedGroup`, no member callbacks, no
  `GetJoinedGroupList` entry, no group identity announce to friends;
- it is never persisted as a known group and never rejoined by
  `RejoinKnownGroups`;
- its packets never enter message history; the client receives opaque
  payload bytes and owns their meaning (toxee: presence records and friend
  request intents, see toxee `doc/reference/LOCATION_AND_NEARBY.md`);
- everything the group says about itself (name, topic, roles, moderation,
  password, privacy) is ignored: with a derivable founder secret every
  participant is a founder, so the group has no moderation boundary.

## Pieces

| Where | What |
|---|---|
| `source/Tim2ToxGroupPacket.{h,cpp}` | The NGC custom-packet framing shared by the chat kinds (1–3) and the rendezvous kind (4) |
| `source/RendezvousGroups.{h,cpp}` + `RendezvousGroupsCodec.cpp` + `RendezvousGroupsEvents.cpp` | Bookkeeping + planner: cells, states, timers, peer map, budgets, restore rule, event lines. **No Tox call** in it; unit-tested in `test/RendezvousGroupsTest.cpp` |
| `source/V2TIMManagerImpl_Rendezvous.cpp` | The driver: executes the planner's actions under the session rules, records toxcore callbacks, emits events |
| `V2TIMManagerImpl.{h,cpp}` | The isolation guards (every group callback / handler diverts an owned group first), the restore sweep in `InitSDK`, `RendezvousShutdown()` first in `UnInitSDK`, `RendezvousTick()` in the event loop |
| `ffi/tim2tox_ffi.{h,cpp}` | `tim2tox_ffi_rendezvous_*`, `tim2tox_ffi_dht_announce_capable_count`, the instance-stamping event sink installed **before** `InitSDK` |
| `dart/lib/service/rendezvous_transport.dart` | `RendezvousTransport`: the calls and the parsed `Stream<RendezvousEvent>`; `FfiChatService.rendezvous` feeds it from the poll loop before any message branch |

## Cell lifecycle (planner)

```
RequestJoin ──► kJoining ──(self_join or peer_join)──► kJoined
                  │ 30 s without either: leave + found (same seed) ──► kJoined (founded)
kJoined ──(had peers, none for 90 s)──► leave "stale" ──► kBackoff (15 s) ──► kJoining
join_fail / kicked (moderation target self) ──► leave ──► kBackoff
more than 3 retries in 10 min ──► kUnavailable (10 min) ──► kJoining
RequestLeave / RequestLeaveAll ──► leave "left" ──► forgotten
```

toxcore callbacks **only record** state and queue the next `Tick()`; every
membership change (join, found, leave) runs on the event thread between
iterations, through `PostToEventThread`, never inside a toxcore callback.

### Session rules (why the driver looks the way it does)

- **Admission**: `accepting_` is opened by `InitSDK` after the savedata
  restore sweep and closed first thing in `UnInitSDK`.
- **Generation + epoch**: every admitted operation captures the registry
  generation and the session epoch, pins the session
  (`AcquireToxSession`), re-checks the pin's epoch and `Expired()` *before*
  the Tox call, and re-checks the generation *after* it; a join/found that
  outlived its session leaves what it created and records nothing.
- **Shutdown**: `RendezvousShutdown()` bumps the generation, waits (bounded)
  for in-flight operations, leaves every cell on the event thread
  (`RunOnEventThread<bool>` with an inline fallback), all before `running_`
  is cleared and before the final profile save. The registry is **not**
  cleared there: the event thread may iterate once more before UnInitSDK
  stops it, and toxcore delivers the pending packets of a flagged group
  before deleting it, so the retiring entries keep diverting callbacks until
  `ResetGroupSessionState()` (after `StopBackgroundTasks`) clears them.
- **Restore**: a cell left behind by a crash is recognised in the restore
  sweep by name prefix **and** a valid label **and**
  `chat_id == derive(SHA-256(seed_prefix + label))`; it is left at once and
  never registered. The same test guards `HandleGroupSelfJoin`
  (`RendezvousSelfJoinOfZombie`, leave deferred to the event thread).
- **Invites**: an invite whose first 32 bytes (the chat_id) belong to a cell,
  or whose name derives to the chat_id, is dropped before auto-accept.
- **Orphans and zombies**: the registry compares the captured generation
  under its own lock, atomically with the record (`OnJoinIssued` /
  `OnFoundIssued`); a join or found it refuses is an orphan the driver
  leaves. Every `tox_group_leave` result is checked (`LeaveGroup()`):
  toxcore deletes the group even on `FAIL_SEND`, so only an unknown error
  keeps it, and then the group stays **owned** — as a re-planned cell leave
  (`OnLeaveFailed`, retried after `kLeaveRetryMs`) or as a zombie (group
  number + chat id). Zombies are left from `Tick()` and again at shutdown,
  each with its `rendezvous_left`; whatever still fails at shutdown is left
  by the next restore sweep.
- **Retiring**: `tox_group_leave` only flags the group; toxcore deletes it on
  its next iteration, and a join of the same chat id meanwhile would rejoin
  the flagged group. A left cell therefore stays owned as *retiring* (its
  callbacks still diverted, nothing planned for it) until a tick observes
  the group number gone or holding another chat id; only then is the
  leave's outcome applied (forget, back-off, the found of a refound, or the
  rejoin a client asked for meanwhile). Every action also carries the
  generation it was planned under and the cell's *attempt* number, and a
  result is recorded only for that exact attempt — a leave + rejoin of the
  same cell, or a LeaveAll, while the Tox call is in flight makes the late
  result an orphan that the driver leaves. A left orphan (or zombie, or a
  group left by the restore sweep) is a *retiring orphan*: owned until gone,
  and no join/found of its chat id is planned meanwhile. A leave is only
  issued while the number still holds our chat id; a successful leave is
  recorded whatever the generation did meanwhile (never a second leave of a
  number toxcore may have reused). In the one window left — toxcore deleted
  the group inside `tox_iterate` and an ordinary group creation reused the
  number before the next tick — the self-join path checks the chat id and
  releases the retiring entry instead of diverting the callback.
- **Failed attempts are reported**: a `tox_group_join` /
  `tox_group_new_with_seed` that fails synchronously emits
  `rendezvous_left:<chat_id>:failed` (the registry backs off and retries),
  so a client that got `1` from `join` always learns the outcome.
- **Shutdown lines do not reach Dart**: `tim2tox_ffi_uninit` purges the
  instance queue right after `UnInitSDK`, so the `rendezvous_left` lines of
  the shutdown leaves are never polled. The Dart `RendezvousTransport`
  tracks joined cells per instance and reports each one `left` on
  `dispose()` (called first in `FfiChatService.dispose()`; it does not wait
  for paused subscribers and re-opens a fresh stream for a re-init of the
  same service), so the consumer's session view is closed either way.

## Wire and events

Kind-4 frame: `0xB7 'T' '2' 'T' 0x01 0x04 <payload>`; the complete frame is
at most **1200 bytes** (payload ≤ 1194). Kind 4 is accepted only in owned
groups; other kinds in an owned group, and kind 4 elsewhere, are dropped.

Native per-sender budget, enforced before anything is queued: 6 packets and
6 KiB per 10 s per (group, peer key); 60 peer events per 10 s per group,
then one coalesced `rendezvous_peers_changed`. Drops are counted
(`tim2tox_ffi_rendezvous_drop_count`).

Poll lines (instance-stamped; `rendezvous_packet:` is evictable like chat):

```
rendezvous_joined:<chat_id_hex>:<founded 0|1>
rendezvous_left:<chat_id_hex>:<kicked|failed|stale|left|full>
rendezvous_peer:<chat_id_hex>:<peer_pk_hex>:<join|exit>
rendezvous_peers_changed:<chat_id_hex>:<count>
rendezvous_full:<chat_id_hex>
rendezvous_packet:<chat_id_hex>:<peer_pk_hex>:<b|p>:<hex payload>
```

## Convention

Defaults are toxee's protocol literals and can be changed before init with
`tim2tox_ffi_rendezvous_set_convention`:

| | Default | Used for |
|---|---|---|
| group name | `toxee-nearby/v1/` + label | what the founder sets; what the restore sweep parses |
| seed | `SHA-256("toxee/nearby/v1|" + label)` | what the client passes to `join`; what the restore sweep re-derives |

A label is 1–12 characters of the geohash base32 alphabet.

## Tests

- `test/Tim2ToxGroupPacketTest.cpp`, `test/RendezvousGroupsTest.cpp`,
  `test/RendezvousIsolationSourceRegressionTest.cpp` (gtest,
  `-DTIM2TOX_BUILD_TESTS=ON`).
- `dart/test/rendezvous_transport_event_test.dart` (line parsing).
- `auto_tests/test/scenarios/scenario_rendezvous_group_test.dart` (phase 4):
  found → join → broadcast → private → isolation → budget → leave, two
  instances in one process.
- toxcore fork: `auto_tests/group_seeded_test.c` (seed determinism).
