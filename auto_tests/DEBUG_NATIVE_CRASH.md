# 在崩溃时查看 Native 栈和变量
> 语言 / Language: [中文](DEBUG_NATIVE_CRASH.md) | [English](DEBUG_NATIVE_CRASH.en.md)

当 auto_tests 在 native 层（`libtim2tox_ffi.dylib` / `.so`）崩溃时（SIGSEGV / exit 139 / `[callback_bridge] FATAL` 等），用 lldb 启动测试可以在崩溃停住，查看 native 调用栈与变量。

> 历史上这份文档是围绕 `scenario_conversation_test` 的具体崩溃写的，那个崩溃当前已修复。但 lldb 流程是通用的 —— 把脚本里的目标测试换成你正在排查的那个就行。

## 方式一：在终端用 lldb 跑测试（推荐）

仓库里现成的 lldb 包装脚本：

- `run_conversation_test_with_lldb.sh` — 历史保留，跑 `scenario_conversation_test`
- `run_pin_test_with_lldb.sh` — 历史保留，跑会话置顶相关测试

用它们当模板，复制改一份成你想调试的测试，或者直接手敲下面的命令：

```bash
cd /Users/<you>/chat-uikit/toxee/third_party/tim2tox/auto_tests
lldb -- flutter test test/scenarios/scenario_<name>_test.dart \
  -o "settings set target.process.follow-fork-mode child" \
  -o "run"
```

要点：

- `target.process.follow-fork-mode child` 让 lldb 跟到实际加载 dylib 的 `flutter_tester` 子进程，否则你只会停在 flutter 启动器上。
- 崩溃后 lldb 会停在 SIGSEGV / `__abort()` 等位置：

  ```
  Process XXXXX stopped
  * thread #1, stop reason = signal SIGSEGV
      frame #0: 0x00000001xxxxxx libtim2tox_ffi.dylib`DartGetConversationListByFilter + 268
  (lldb)
  ```
- 常用命令：
  - `bt` — 完整 native 调用栈
  - `frame select <N>` 再 `frame variable` — 看指定帧的局部变量
  - `register read` — 寄存器
  - `image list -b libtim2tox_ffi.dylib` — 确认 dylib 实际加载路径，便于 `symbolicate`
  - `expression -- <expr>` — 评估表达式
  - `dis` — 当前帧反汇编

> 如果 stop 之后变量都是 `<unavailable>`：检查编译时是否开了 `-O3`；`./build_ffi.sh` 默认是 Release，必要时改 `-DCMAKE_BUILD_TYPE=RelWithDebInfo` 重新 build。

## 方式二：在 Xcode 里配成"自定义测试" Scheme

适合反复跑同一测试。**Xcode 控制台对 lldb 交互支持有限**，建议在崩溃后切到终端继续 `bt` / `frame variable`。

### 步骤 1：建一个 Xcode 工程占位

1. 打开 Xcode，**File → New → Project**
2. 选 **macOS → App**，Next
3. Product Name 填：`FlutterTestRunner`（或任意）
4. 把工程放到 `tim2tox/auto_tests/` 或项目根目录，Create

### 步骤 2：加一个新 Scheme

1. **Product → Scheme → New Scheme...**
2. Name 填：`Auto Test (lldb)`
3. 左侧选该 Scheme，**Edit...**

### 步骤 3：把 Run 配成 lldb 跑 flutter test

1. 左侧选 **Run**
2. **Info**：
   - **Executable**：**Other...** → `Cmd+Shift+G` → `/usr/bin/lldb`
   - **Arguments Passed**（每行一条）：
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
   - **Working Directory**：`tim2tox/auto_tests/` 的绝对路径
3. 若 `flutter` 不在系统 PATH，在 **Arguments → Environment Variables** 加 `PATH=...:/path/to/flutter/bin:/usr/bin:/bin`
4. Close 保存。

### 步骤 4：运行

1. Scheme 下拉选 **Auto Test (lldb)**
2. **Product → Run**（Cmd+R）

## 常见症状速查

| 现象 | 第一步看 |
|------|----------|
| `signal SIGSEGV` 在 `DartGetConversation*` / `DartGetGroup*` | 多半是 `lastMessage` 悬空或 list deep-copy 没做 |
| `signal SIGSEGV` 在 `SendCallbackToDart` / `Dart_PostCObject_DL` | 检查 isolate 是否还活着；`g_dart_port` 是否被并发清空 |
| `[callback_bridge] FATAL: end backtrace` | C++ 端主动 abort，看上一条 `V2TIM_LOG(kError, ...)` |
| 崩在 `tox_iterate` / `tox_friend_*` | toxcore 状态机问题，去 `source/ToxManager.cpp` 查最近改动 |
| 多实例下随机崩溃 | 多半是 `instance_id` 没传到 trampoline，`grep -rn instance_id ffi/dart_compat_listeners.cpp` 自查 |

## 小结

| 目的 | 做法 |
|------|------|
| 崩溃时看 native 栈和变量 | 在终端用 lldb 跑（脚本或手敲命令） |
| 在 Xcode 里一键复跑 | 配上面的 "Auto Test (lldb)" Scheme，崩溃时切回终端继续调试 |
| 看历史问题与修复 | `git log --diff-filter=M -- ffi/dart_compat_listeners.cpp ffi/callback_bridge.cpp` |
