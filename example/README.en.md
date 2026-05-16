# Tim2Tox Examples
> Language: [Chinese](README.md) | [English](README.en.md)

Minimal examples that exercise the Tim2Tox library: one echo bot server plus two clients. They use the C++ V2TIM API directly (no Dart) for quick backend smoke checks.

## File list

| File | Kind | Description |
|------|------|-------------|
| `echo_bot_server.cpp` | C++ | Echo bot server: logs in, auto-accepts friend requests, echoes received C2C text |
| `echo_bot_client.cpp` | C++ | **Non-interactive** client driven by `--auto <user_id> <message>` — script / CI friendly |
| `tim2tox_client.cpp` | C++ | **Interactive** client supporting `connect / send / status / help / quit`; only built if `../build/source/libtim2tox.a` exists |
| `CMakeLists.txt` | CMake | Build config |
| `build_examples.sh` | sh | Wrapper around `mkdir build && cd build && cmake .. && make` |
| `test_echo.sh` | sh | End-to-end smoke test that drives server + `echo_bot_client --auto` |

## Build requirements

- CMake 3.10+
- C++17 compiler
- libsodium, OpenSSL (macOS: `brew install libsodium openssl`)
- Optional: run `./build.sh` in the repo root first to produce `build/source/libtim2tox.a` — otherwise CMake will skip the `tim2tox_client` target and emit a warning

## Build

```bash
# 1. Build the main static library (optional; only needed for tim2tox_client)
cd ..
./build.sh

# 2. Build the examples
cd example
./build_examples.sh        # or manually: mkdir build && cd build && cmake .. && make
```

After a successful build, `example/build/` contains:

- `echo_bot_server`
- `echo_bot_client`
- `tim2tox_client` (only if `../build/source/libtim2tox.a` exists)
- `libirc_client.dylib` / `.so` (the dynamically loaded IRC channel bridge)

## Running

### 1. Start the echo bot server

```bash
cd example/build
./echo_bot_server
```

It prints the V2TIM-mapped user ID (64-char hex), e.g.:

```
=== Echo Bot Server ===
User ID: F404ABAA1C99A9D37D61AB54898F56793E1DEF8BD46B1038B9D822E8460FAB67
Status: Echoing your messages
=======================
Server starting...
Press Ctrl+C to stop
```

> `User ID` is the abstract ID that V2TIM exposes to the business layer. The clients below take that ID as their peer.

### 2. Run the interactive client (`tim2tox_client`)

```bash
cd example/build
./tim2tox_client F404ABAA1C99A9D37D61AB54898F56793E1DEF8BD46B1038B9D822E8460FAB67
```

REPL commands:

- `connect` — send a friend request
- `send <message>` — send a message
- `status` — show connection status
- `help` — help
- `quit` — exit

You can also type a message directly (treated as a normal send).

### 3. Run the automated client (`echo_bot_client`)

Non-interactive. A single `--auto` run does "add friend → wait online → send → verify echo":

```bash
cd example/build
./echo_bot_client --auto <server_user_id> "ping"                  # basic smoke
./echo_bot_client --auto <server_user_id> "ping" --extended        # Unicode / long text / burst messages
```

Or one-shot via `test_echo.sh`:

```bash
cd example
./test_echo.sh
```

Exit codes:

| code | meaning |
|------|---------|
| 0 | All checks passed |
| 2 | Client did not come online within 120 s |
| 6 | Basic message echo not received within 60 s |
| 7 / 9 / 10 | Extended mode: Unicode / long-text / burst echo failures, respectively |

## Troubleshooting

- **Build failures**: confirm `libsodium`, `openssl`, and `cmake` are installed.
- **`tim2tox_client` not produced**: run `bash ../build.sh` first to generate `../build/source/libtim2tox.a`, then re-run `./build_examples.sh`.
- **Connection fails / friendship doesn't form**: check firewall and Bootstrap-node config; for a local bootstrap setup see [doc/integration/BOOTSTRAP_AND_POLLING.en.md](../doc/integration/BOOTSTRAP_AND_POLLING.en.md).
- **Sends fail**: usually the friendship hasn't completed yet — the server's auto-accept is asynchronous; give it a few seconds and retry.

## Extension ideas

These examples cover only the minimal C2C text path. From here you can experiment with:

- Group chat (`V2TIMGroupManager` / `JoinGroup` / `SendGroupMessage`)
- File transfer (`tim2tox_ffi_send_file` / `file_control`)
- AV calls (`tim2tox_ffi_av_*`)
- Custom messages (`SendC2CCustomMessage` / `SendGroupCustomMessage`)
