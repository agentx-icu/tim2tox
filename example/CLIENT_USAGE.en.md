# Echo Bot Client Usage
> Language: [Chinese](CLIENT_USAGE.md) | [English](CLIENT_USAGE.en.md)

There are **two** client binaries with very different UX:

| Binary | Mode | Use case |
|--------|------|----------|
| `echo_bot_client` (`echo_bot_client.cpp`) | **Non-interactive**, only accepts `--auto <user_id> <message> [--extended]` | One-shot "add friend → wait online → send → verify echo" runs; designed for scripts and CI |
| `tim2tox_client` (`tim2tox_client.cpp`) | **Interactive** REPL with `connect / send / status / help / quit` | Manual debugging. Only built if `../build/source/libtim2tox.a` exists |

> An older version of this document described `echo_bot_client` as an interactive C client with `add / send / status / friends / help / quit` commands. That description was wrong — the current code is C++ and only supports `--auto`.

## Build

```bash
# 1. Main project (optional; only required to produce libtim2tox.a for tim2tox_client)
cd ..
./build.sh

# 2. Examples
cd example
./build_examples.sh
```

After a successful build, `example/build/` contains `echo_bot_server` and `echo_bot_client`, plus `tim2tox_client` if `libtim2tox.a` was produced.

## Usage — `echo_bot_server` + `echo_bot_client --auto`

### 1. Start the echo bot server

```bash
cd example/build
./echo_bot_server
```

Output (from `echo_bot_server.cpp:118-122`):

```
=== Echo Bot Server ===
User ID: <64-char hex user id>
Status: Echoing your messages
=======================
Server starting...
Press Ctrl+C to stop
```

Note the hex string after `User ID:`.

### 2. Run `echo_bot_client --auto`

```bash
cd example/build
./echo_bot_client --auto <server_user_id> "ping"
./echo_bot_client --auto <server_user_id> "ping" --extended   # adds Unicode / long-text / burst checks
```

You can also skip the extended suite via env var:

```bash
TIM2TOX_SKIP_EXTENDED=1 ./echo_bot_client --auto <server_user_id> "ping"
```

Flow (see `echo_bot_client.cpp:124-229`):

1. Wait up to 120 s for the local client to come online (`wait_connected`).
2. `AddFriend`; the server-side auto-accept handles the rest.
3. Wait for the server side to appear online via the V2TIM SDK `OnUserStatusChanged` listener.
4. Send `<message>` via `SendC2CTextMessage`, **retrying for up to 60 s** until send succeeds.
5. Wait up to 60 s for the message to be echoed back verbatim.
6. With `--extended`: also runs Unicode, long-text (1350 bytes — near the Tox text packet limit), and 5 burst sends.

Exit codes:

| code | meaning |
|------|---------|
| 0 | Success |
| 2 | Client did not come online within 120 s |
| 6 | Basic message echo not received within 60 s |
| 7 | Extended Unicode failure |
| 9 | Extended long-text failure |
| 10 | Extended burst failure |

## Usage — `tim2tox_client` (interactive)

```bash
cd example/build
./tim2tox_client <server_user_id>
```

REPL commands:

- `connect` — send a friend request
- `send <message>` — send a message
- `status` — show connection status / friend list
- `help` — help
- `quit` / `exit` — exit

You can also type any text directly to send as a regular message.

## Test scenarios

- **Basic echo**: `echo_bot_client --auto ... "hello"` — expect `hello` echoed back within 60 s.
- **Unicode**: with `--extended`, automatically verifies `"Hello/你好/Привет/😀"`.
- **Long text**: with `--extended`, builds a 1350-byte `'L'` packet (near the upper limit) to verify near-max payloads aren't truncated.
- **Burst**: with `--extended`, sends 5 consecutive `burst_<i>_<unix_ts>` messages and verifies they all come back.

## Troubleshooting

- **Client does not come online within 120 s**: check Bootstrap nodes / firewall; try the interactive `tim2tox_client` first and use `status` to inspect.
- **Sends keep failing**: usually the server hasn't auto-accepted yet — the client already retries for 60 s; if it still fails, the server side is not running properly.
- **No echo**: check the server logs for `Echoing ...`; verify `simpleListener::OnRecvC2CTextMessage` was hit.
- **`tim2tox_client` was not built**: run `bash ../build.sh` first to produce `../build/source/libtim2tox.a`.
- **`libsodium` / `openssl` missing**: macOS — `brew install libsodium openssl`; Linux — install `libsodium-dev` / `libssl-dev`.

## Related files

- `echo_bot_server.cpp` — server implementation
- `echo_bot_client.cpp` — non-interactive client
- `tim2tox_client.cpp` — interactive client
- `test_echo.sh` — server + client smoke test
- `build_examples.sh` — build wrapper

## Notes

1. First-time connection to the Tox network can take tens of seconds.
2. Tox profile (savedata) is managed implicitly by `V2TIMManager::GetInstance()->InitSDK(...)`. The **default** flow does not explicitly write a `.tox` file unless you specify a profile directory via `tim2tox_ffi_init_with_path(...)` or `V2TIMSDKConfig.initPath`. Older docs mentioning `echo_bot_savedata.tox` / `echo_bot_client_savedata.tox` files don't necessarily reflect the current behavior.
3. The server's `V2TIMFriendshipListener` auto-accepts every friend request by default.
4. Use Ctrl+C to exit; the process calls `UnInitSDK` on shutdown.
