# Tim2Tox Bootstrap and Polling
> Language: [Chinese](BOOTSTRAP_AND_POLLING.md) | [English](BOOTSTRAP_AND_POLLING.en.md)


This document describes Tim2Tox’s Bootstrap node loading, connection establishment, and polling mechanisms. The client (integrator) is responsible for node sources, persistence, and UI; Tim2Tox only consumes the current node triple exposed via `BootstrapService` and drives the poll loop.

## 1. Scope

This link spans two layers:

- **Client**: Responsible for selecting and saving the current Bootstrap node, startup order, and node configuration UI (e.g. manual/auto/LAN); implements `BootstrapService` and injects it into `FfiChatService`.
- **tim2tox/dart**: Responsible for applying the `host/port/publicKey` from `BootstrapService` to the Tox instance and driving connection status, messages, files, and AV events via `startPolling()`.

Tim2Tox has no separate “LAN Bootstrap mode” branch; the framework always consumes the current Bootstrap node triple. LAN or other modes are client-side configuration concepts.

## 2. Bootstrap node sources (client side)

Sources are implemented by the client, for example:

1. Manual input
2. Pull from a public node list (e.g. `https://nodes.tox.chat/json`)
3. Local Bootstrap service on LAN (if the client supports it)

Tim2Tox only depends on the interface:

- `dart/lib/interfaces/bootstrap_service.dart`: Exposes reading and writing of the current node’s `host/port/publicKey`.
- `dart/lib/service/ffi_chat_service.dart`: Calls `_loadAndApplySavedBootstrapNode()` during `init()` to read from `BootstrapService` and apply.

## 3. Node selection and saving (client side)

The client must provide a usable node before or via `BootstrapService` when `FfiChatService.init()` runs, for example:

- **Automatic mode**: Before first `init()`, if no node is saved yet, fetch a public node list and write the current config so the first `init()` has a node.
- **Manual mode**: After the user enters a node on a settings page, write the current config; `FfiChatService.init()` reads and applies it in `_loadAndApplySavedBootstrapNode()`.
- **LAN mode** (if supported): Once the local Bootstrap service exposes `host/port/pubkey`, the client writes that triple into the current node config; Tim2Tox still only sees “current Bootstrap node”.

## 4. How Tim2Tox applies Bootstrap nodes

`FfiChatService.init()` will call `_loadAndApplySavedBootstrapNode()` at the end:

- `manual` mode: read `getCurrentBootstrapNode()` and call `addBootstrapNode(...)`
- Other modes: take `BootstrapService.getBootstrapHost/Port/PublicKey()` first; fall back to `getCurrentBootstrapNode()` when you can’t get it.

`addBootstrapNode(host, port, publicKeyHex)` will:

1. Call FFI `tim2tox_ffi_add_bootstrap_node`
2. When successful, save the node back to the current configuration.

This means that in pages with `service` instances, the "test node" is not a purely read-only operation. In the current implementation, a successful test will also write the node as the current node because it reuses `addBootstrapNode(...)`.

## 5. Login and network status

`FfiChatService.login(...)` is only responsible for:

- Call native `login`
- Read the current `selfId`
- Use `getSelfConnectionStatus()` to push the current connection status immediately

It does not guarantee that networking is complete at that time. Actual connection changes come from `conn:success` / `conn:failed` in the polling queue.

**Suggested client startup order**: After a usable Bootstrap node is available, initialize `FfiChatService`, then call `startPolling()` and listen to `connectionStatusStream`. `startPolling()` is the real starting point for networking and message consumption and must be called at the right time. For concrete order and UI flow, see each client project’s documentation.

## 6. Polling loop

`FfiChatService.startPolling()` currently does the following:

1. Cancel the old poller and old profile save timer
2. Start `saveToxProfileNow()` every 60 seconds
3. Push the current `_isConnected` first
4. Arrange the next round of poll according to the adaptive interval

Current polling interval policy:

- With file transfer: `50ms`
- Multi-instance or shared instance polling: `50ms`
- Activity in the last 2 seconds: `200ms`
- Idle state: `1000ms`

Each round of poll will:

1. First try to execute `avIterate(instanceId)`
2. Poll the text event queue by instance priority
3. A maximum of 200 events can be processed in batches at a time to avoid queue backlog during file transfer.

In multi-instance scenarios, non-zero instances will be polled first, and the receiver instance will be consumed first so that `file_request` can be processed faster.

## 7. What key events are there in the polling queue?

The events that currently require the most attention from maintainers are:

- `conn:success` / `conn:failed`
- `c2c:` / `gtext:`
-`file_request:`
- `file_done:`
- `typing:`

Among them:

- `conn:success` will set `_isConnected` to `true` and trigger avatar synchronization
- `file_request:` is a key pre-event of the file receiving link; if it is not polled in time, the receiving end cannot `acceptFileTransfer` in time
- `file_done:` will close the temporary reception status to historical messages and UI

This is why the poll interval is pressed to `50ms` during file transfer and a single round of batch drain queue is allowed.

## 8. Client-side notes (summary)

- **Switching nodes**: Call `service.addBootstrapNode(...)` to write a new node and optionally call `service.login(...)` again; no need to recreate `FfiChatService`.
- **Testing nodes**: If reusing `addBootstrapNode(...)` for probing, a successful test will also update the current node config; that is an implementation-side effect.
- **LAN Bootstrap** (if supported): The local service exposes `ip/port/pubkey`; the client must still write that triple into the current node config. Tim2Tox does not distinguish node sources.

For concrete implementation and maintenance order, see each client repo’s documentation. When working in the Tim2Tox repo, read `dart/lib/interfaces/bootstrap_service.dart` and `dart/lib/service/ffi_chat_service.dart` first.

## 9. Related documents

- [ARCHITECTURE.en.md](../architecture/ARCHITECTURE.en.md)
- [API Reference](../api/API_REFERENCE.en.md)
- For an example client’s startup, Bootstrap, and account/session docs, see that client’s project, e.g. [toxee](https://github.com/agentx-icu/toxee) (when Tim2Tox is used as a submodule, the parent repo’s doc).