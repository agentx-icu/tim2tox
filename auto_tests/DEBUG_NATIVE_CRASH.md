[简体中文](./DEBUG_NATIVE_CRASH.zh-CN.md)

# Inspect native stacks at crash time

When an auto test crashes in the native layer (`libtim2tox_ffi.dylib` / `.so`) — SIGSEGV, exit 139, `[callback_bridge] FATAL`, etc. — running the test under lldb gives you a chance to stop at the crash site and inspect the native stack and locals.

> Historically this doc was written around a specific `scenario_conversation_test` crash that has since been fixed. The lldb flow is generic — just swap the script's target test for the one you are debugging.

## Option 1: Run the test under lldb in your terminal (recommended)

There are wrapper scripts in the repo:

- `run_conversation_test_with_lldb.sh` — historical; runs `scenario_conversation_test`
- `run_pin_test_with_lldb.sh` — historical; runs the conversation-pin scenario

Use either as a template, or just run the command directly:

```bash
cd /Users/<you>/chat-uikit/toxee/third_party/tim2tox/auto_tests
lldb -- flutter test test/scenarios/scenario_<name>_test.dart \\n  -o "settings set target.process.follow-fork-mode child" \\n  -o "run"
```

Key points:

- `target.process.follow-fork-mode child` makes lldb follow into the `flutter_tester` child process that actually loads the dylib; without it you'll stop at the flutter launcher.
- After the crash, lldb stops at the offending frame:

  ```
  Process XXXXX stopped
  * thread #1, stop reason = signal SIGSEGV
      frame #0: 0x00000001xxxxxx libtim2tox_ffi.dylib`DartGetConversationListByFilter + 268
  (lldb)
  ```
- Useful commands:
  - `bt` — full native backtrace
  - `frame select <N>` then `frame variable` — locals in a specific frame
  - `register read` — registers
  - `image list -b libtim2tox_ffi.dylib` — find the loaded dylib's path for symbolication
  - `expression -- <expr>` — evaluate an expression
  - `dis` — disassemble the current frame

> If locals show as `<unavailable>` on stop: check the optimization level — `./build_ffi.sh` uses Release by default. Rebuild with `-DCMAKE_BUILD_TYPE=RelWithDebInfo` if you need them.

## Option 2: Set up an Xcode "custom test" scheme

Good for repeating the same test. **Xcode's console support for lldb interaction is limited**; once it stops, drop into a terminal for `bt` / `frame variable`.

### Step 1: Create an Xcode project shell

1. Open Xcode, **File → New → Project**
2. Pick **macOS → App**, Next
3. Product Name: `FlutterTestRunner` (anything works)
4. Put it under `tim2tox/auto_tests/` or the project root, Create

### Step 2: Add a new Scheme

1. **Product → Scheme → New Scheme...**
2. Name it: `Auto Test (lldb)`
3. Select it on the left and click **Edit...**

### Step 3: Configure the Run action to use lldb

1. Select **Run** on the left
2. **Info**:
   - **Executable**: **Other...** → `Cmd+Shift+G` → `/usr/bin/lldb`
   - **Arguments Passed** (one per line):
     ```
     -o
     settings set target.process.follow-fork-mode child
     -o
     run
     --
     flutter
     test
     test/scenarios/scenario_<name>_test.dart
     ```
   - **Working Directory**: absolute path to `tim2tox/auto_tests/`
3. If `flutter` isn't on the system PATH, set **Arguments → Environment Variables** `PATH=...:/path/to/flutter/bin:/usr/bin:/bin`
4. Close to save.

### Step 4: Run

1. Pick **Auto Test (lldb)** in the Scheme dropdown
2. **Product → Run** (Cmd+R)

## Symptom cheat sheet

| Symptom | First place to look |
|---------|---------------------|
| `signal SIGSEGV` in `DartGetConversation*` / `DartGetGroup*` | Often a dangling `lastMessage` or a missed deep-copy of a list |
| `signal SIGSEGV` in `SendCallbackToDart` / `Dart_PostCObject_DL` | Check that the isolate is still alive; `g_dart_port` was not concurrently cleared |
| `[callback_bridge] FATAL: end backtrace` | The C++ side intentionally aborted; look at the previous `V2TIM_LOG(kError, ...)` |
| Crash in `tox_iterate` / `tox_friend_*` | toxcore state-machine issue — check recent changes in `source/ToxManager.cpp` |
| Random crash under multi-instance | Usually `instance_id` not threaded to the trampoline; `grep -rn instance_id ffi/dart_compat_listeners.cpp` |

## Summary

| Goal | Approach |
|------|----------|
| Inspect native stacks on crash | Run under lldb in a terminal (scripts or manual command) |
| Re-run repeatedly in Xcode | Use the "Auto Test (lldb)" Scheme above; drop to a terminal for live debugging |
| Look up past issues and fixes | `git log --diff-filter=M -- ffi/dart_compat_listeners.cpp ffi/callback_bridge.cpp` |
