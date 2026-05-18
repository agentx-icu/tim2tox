# Tim2Tox Auto Tests

自动化测试套件，覆盖 tim2tox 的 Platform 路径和 Binary Replacement 路径下 UIKit/V2TIM 风格的接口。整体跑过的最新基线见 [VALIDATION_RESULTS.md](VALIDATION_RESULTS.md)。

**目录**：[概述](#概述) · [目录结构](#目录结构) · [测试框架](#测试框架) · [测试场景列表](#测试场景列表) · [运行测试](#运行测试) · [测试覆盖范围](#测试覆盖范围) · [测试失败记录与修复状态](#测试失败记录与修复状态) · [已知问题](#已知问题和限制) · [故障排除](#故障排除) · [最佳实践](#测试最佳实践) · [参考文档](#参考文档)

## 概述

本测试套件借鉴了 `c-toxcore/auto_tests` 的方案和用例，使用 Dart/Flutter 测试框架（`test`/`flutter_test`）实现场景式测试，覆盖所有 UIKit SDK 接口。

### 设计理念

- **场景式测试**：每个测试文件对应一个功能场景，模拟真实使用情况
- **多节点测试**：支持创建多个 TestNode 节点，模拟多用户交互
- **自动接受机制**：类似 c-toxcore 的 auto-accept，自动处理好友请求、群组邀请等
- **本地 Bootstrap**：支持本地 bootstrap 配置，加速节点连接

## 目录结构

```
tim2tox/auto_tests/
├── pubspec.yaml                    # 包配置和依赖
├── run_tests.sh                    # 基础测试运行脚本（带按名字过滤）
├── run_tests_verbose.sh            # 更啰嗦的输出
├── run_tests_ordered.sh            # **推荐**：按 Phase 1-14 顺序运行，单测 180s 超时
├── run_all_tests.sh                # 兼容入口，内部转给 run_tests_ordered.sh
├── run_group_tests.sh              # 群组相关 phase 的别名
├── run_tests_with_lib.sh           # 显式注入 DYLD_LIBRARY_PATH 的变体
├── check_test_assertions.sh        # 防止引入永真断言/空 catch 的静态检查
├── test/
│   ├── test_helper.dart            # 测试辅助库（TestNode、waitUntil、TestScenario）
│   ├── test_fixtures.dart          # 测试数据 / Mock
│   ├── scenarios/                  # 业务场景（共 139：70 wall-clock + 69 *_virtual_test 变体）
│   │   ├── scenario_sdk_init_test.dart
│   │   ├── scenario_sdk_init_virtual_test.dart
│   │   ├── scenario_login_test.dart
│   │   ├── scenario_login_virtual_test.dart
│   │   ├── scenario_virtual_clock_smoke_test.dart   # 虚拟时钟基础冒烟
│   │   └── ... (其余文件按相同命名规则成对存在)
│   ├── scenarios_binary/           # Binary Replacement 路径专测（Phase 13，3 个）
│   │   ├── scenario_native_callback_dispatch_test.dart  # NativeLibraryManager 静态 listener 分发
│   │   ├── scenario_custom_callback_handler_test.dart   # customCallbackHandler 注册与触发
│   │   └── scenario_library_loading_test.dart           # setNativeLibraryName 库加载验证
│   └── unit_tests/                 # 纯单元测试（Phase 14 当前只跑 test_listeners.dart）
│       ├── test_listeners.dart                          # Listener 接口测试
│       ├── ffi_chat_service_avatar_detection_test.dart  # 头像变更检测
│       └── ffi_chat_service_avatar_sync_test.dart       # 头像同步
├── VALIDATION_RESULTS.md           # 最近一次全量回归的通过/失败快照
├── VIRTUAL_CLOCK.md                # 虚拟时钟原理 / 使用 / 性能数据
├── DEBUG_NATIVE_CRASH.md           # 用 lldb 调试 native 栈
└── README.md                       # 本文档
```

## 测试框架

### TestNode 类

`TestNode` 代表测试场景中的一个用户节点，提供以下功能：

#### 核心方法

- **`initSDK()`** - 初始化 SDK，创建独立的测试实例
- **`login()`** - 登录节点，自动启用 auto-accept
- **`logout()`** - 登出节点
- **`unInitSDK()`** - 清理 SDK 资源

#### 实例上下文（多实例必读）

在有多节点（如 alice、bob）的场景中，所有访问 native 的 TIM*Manager 调用必须在对应节点的实例上下文中执行，否则会走到错误实例或默认实例导致失败（如 `ToxManager not initialized`）。

- **`runWithInstance(action)`** - 同步执行 `action`，期间当前实例为该节点
- **`runWithInstanceAsync(action)`** - 异步执行 `action`，期间当前实例为该节点

**规范**：在测试里调用 `TIMConversationManager.instance.*`、`TIMMessageManager.instance.*`、`TIMFriendshipManager.instance.*`、`TIMGroupManager.instance.*` 等时，必须包在对应节点的 `runWithInstanceAsync`（或 `runWithInstance`）中；接收方/监听方用该节点包裹 add/remove listener。例如：Alice 发消息用 `alice.runWithInstanceAsync(() => TIMMessageManager.instance.sendMessage(...))`，Bob 收消息的 listener 用 `bob.runWithInstance(() => TIMMessageManager.instance.addAdvancedMsgListener(...))`。使用 Tox ID 作为 C2C 的 receiver 时用 `bob.getToxId()`，不要用 `bob.userId`。

- **`getFriendListResultWithInstance()`** - 在当前节点实例上拉取好友列表结果（含 code），用于断言
- **`getConversationListWithInstance(nextSeq, count)`** - 在当前节点实例上拉取会话列表

#### 等待和同步

- **`waitForConnection()`** - 等待节点连接到 Tox 网络
- **`waitForFriendConnection(userId)`** - 等待好友连接建立
- **`waitForCallback(callbackName)`** - 等待特定回调触发
- **`waitForCondition(condition)`** - 等待条件满足

#### 状态查询

- **`getToxId()`** - 获取节点的 Tox ID（76 字符十六进制）
- **`getPublicKey()`** - 获取节点的公钥（64 字符十六进制）
- **`getFriendList()`** - 获取好友列表（带缓存）
- **`isFriend(userId)`** - 检查是否为好友

#### 自动接受机制

`TestNode` 在登录后自动启用 auto-accept，类似 c-toxcore 的 `tox_friend_add_norequest()`：
- 自动接受好友请求
- 自动处理群组邀请
- 自动处理文件传输请求

### TestScenario 类

`TestScenario` 管理多个节点的测试场景：

```dart
final scenario = await createTestScenario(['alice', 'bob']);
final alice = scenario.getNode('alice')!;
final bob = scenario.getNode('bob')!;

await scenario.initAllNodes();
await scenario.loginAllNodes();
await configureLocalBootstrap(scenario);
```

### 工具函数

#### `waitUntil(condition, {timeout, description})`

等待条件满足，类似 c-toxcore 的 `WAIT_UNTIL` 宏：

```dart
await waitUntil(
  () => alice.loggedIn && bob.loggedIn,
  timeout: const Duration(seconds: 10),
  description: 'both nodes logged in',
);
```

#### `establishFriendship(alice, bob)`

建立双向好友关系：

```dart
await establishFriendship(alice, bob);
// 现在 alice 和 bob 互为好友
```

#### `configureLocalBootstrap(scenario)`

配置本地 bootstrap，第一个节点作为 bootstrap 节点：

```dart
await configureLocalBootstrap(scenario);
// 其他节点会从第一个节点 bootstrap
```

## 虚拟时钟模式 (Virtual Clock Mode)

虚拟时钟模式是一种加速测试套件运行的可选机制：通过在 C++ 侧挂起每个测试实例的 `event_thread`，并把 Tox 内部读取的 `mono_time` 重定向到一个**进程级共享的虚拟时钟**，让测试代码手动推进时间、手动调用 `tox_iterate`。一次"虚拟前进 60 秒"可以在毫秒级 wall time 内完成，绕过 Tox 协议中 60s ping / 122s BAD_NODE / 10s onion path 等慢节奏定时器。

### 为什么需要

Tox 协议层的多个常数（DHT 心跳、好友重连、群组 announce）以秒为单位。在 wall-clock 模式下，多实例 setUpAll 阶段会被这些定时器拖到几十秒甚至几分钟。虚拟时钟把 Tox 协议时间和 wall time 解耦：协议时间可任意压缩，UDP loopback 仍走真实 wall time（通过 `pumpTestTick` 内置的小段 `wallSleep` 让 loopback 包顺利投递）。

### 核心模型

- **共享虚拟 mono_time**：`VirtualClock` 在 Dart 侧维护，C++ 侧通过 `tim2tox_ffi_set_virtual_time_ms()` 同步
- **手动 iterate**：每次 `pumpTestTick(scenario, ...)` 推进虚拟钟 + 在每个实例上调用 `tim2tox_ffi_iterate_instance()`
- **task_queue 同步派发**：`tim2tox_ffi_iterate_instance` 在测试模式下顺带 drain task_queue，所以 `PostToEventThread`（信令派发等）依然会执行
- **`RunOnEventThread` inline**：测试模式下 inline 执行，不会因等待 event_thread 而死锁

### 如何使用

```bash
# 全部 Phase 用虚拟时钟运行（已存在虚拟变体的测试切换到 *_virtual_test.dart；否则回退到 wall-clock 原版）
RUN_VIRTUAL=1 ./run_tests_ordered.sh

# 单 Phase / 范围 / 逗号列表照常工作
RUN_VIRTUAL=1 ./run_tests_ordered.sh 4
RUN_VIRTUAL=1 ./run_tests_ordered.sh 10-12
```

`RUN_VIRTUAL=0`（默认）保持现有 wall-clock 行为不变。

### 并行运行（PARALLEL_WORKERS）

```bash
# 2 个 worker 并发执行（每个 worker 独立 spawn flutter_tester）
PARALLEL_WORKERS=2 ./run_tests_ordered.sh

# 3 个 worker 并发执行，限定 Phase
PARALLEL_WORKERS=3 ./run_tests_ordered.sh 4 10
```

`PARALLEL_WORKERS=N` 把全部选中的测试合并成一条队列，跨 Phase 一起分发到 N 个并发的 `flutter test` 进程。默认值是 1（顺序执行）。开发机典型经验：2–3 个 worker 通常稳定，4+ 容易因 CPU 抢占触发 Tox DHT 超时和 friend P2P 握手失败。Phase 间不再有顺序依赖（每个测试文件已经各自 `setUpAll`），并行汇总后仍按 Phase 重新分组打印结果。

#### 让测试在并行模式下自动跳过

部分测试本质上不兼容并行执行（跨进程状态、独占型网络资源等）。这类文件可以在顶部（文件头注释之后、`void main()` 之前的前 ~40 行内任意位置）加一行标记：

```dart
// SKIP_IN_PARALLEL: <一行原因>
```

当 `PARALLEL_WORKERS>=2` 时，runner 会 grep 该标记并在分发前把命中文件从所有 Phase 数组里剔除，不管真正的分发路径是 bundle、parallel-xargs，还是 `PARALLEL_WORKERS>=2` 调用里顺序执行的那条 fallback —— 一律生效。标记是 sibling 对称的：只要 wall-clock 版 `_test.dart` 或 `_virtual_test.dart` 任一文件带了标记，两边都会被过滤。被跳过的文件会出现在 runner 的 "Skipped Tests" 汇总段落里，并附上声明的原因。

当前使用该标记的测试：

- `scenario_lan_discovery_test.dart` / `scenario_lan_discovery_virtual_test.dart` —— Tox LAN 多播在 loopback 33445-33545 端口需要独占；其他并行测试进程同时在该端口段广播会让发现路径产生歧义，断言失败。

### Phase 覆盖

Phase 1–12 已经有 `*_virtual_test.dart` 虚拟变体（约 69 个文件，加上 `scenario_virtual_clock_smoke_test.dart` 共 70 个；wall-clock 原版另有 ~70 个，详见 `test/scenarios/`），覆盖基础 / 好友 / 消息 / 群组 / ToxAV / Profile / 会话 / 文件 / 会议 / 群组扩展 / 网络 / 其他全部业务路径。Phase 13（Binary Replacement）和 Phase 14（unit_tests）不依赖 Tox 协议定时器，**无需**虚拟变体。

### 关于 flakes

虚拟模式的稳定性与 wall-clock 模式持平，但**不会修复 Tox 协议层本身的 flake**（DHT 抖动、好友 P2P 握手时序、群组 announce 收敛等）。如果某测试在 wall 模式偶发失败，切到虚拟模式不会让它稳定 —— 需要从测试逻辑或协议层定位根因。

### 详细指南

写虚拟变体或迁移已有测试时，请参考 [VIRTUAL_CLOCK.md](VIRTUAL_CLOCK.md)（包含核心 API、`*Virtual` 替换表、canonical setUpAll 模板、群邀请重试模式、性能数据、C++ 内部机制等）。

## 测试场景列表

### 基础测试 (5个)

| 测试文件 | 说明 |
|---------|------|
| `scenario_sdk_init_test.dart` | SDK 初始化、配置、版本查询 |
| `scenario_login_test.dart` | 登录/登出、登录状态查询 |
| `scenario_self_query_test.dart` | 自我信息查询 |
| `scenario_save_load_test.dart` | 数据保存和加载 |
| `scenario_multi_instance_test.dart` | 多实例支持测试 |

### 好友测试 (8个)

| 测试文件 | 说明 |
|---------|------|
| `scenario_friend_request_test.dart` | 好友请求发送和接收 |
| `scenario_friend_request_simple_test.dart` | 好友请求简单流程 |
| `scenario_friend_connection_test.dart` | 好友连接状态 |
| `scenario_friend_query_test.dart` | 好友信息查询 |
| `scenario_friendship_test.dart` | 好友关系管理 |
| `scenario_friend_delete_test.dart` | 删除好友 |
| `scenario_friend_read_receipt_test.dart` | 已读回执 |
| `scenario_friend_request_spam_test.dart` | 好友请求防垃圾 |

### 消息测试 (4个)

| 测试文件 | 说明 |
|---------|------|
| `scenario_message_test.dart` | 消息发送和接收 |
| `scenario_send_message_test.dart` | 消息发送功能 |
| `scenario_message_overflow_test.dart` | 消息队列溢出处理 |
| `scenario_typing_test.dart` | 输入状态（正在输入） |

### 群组测试 (10个)

| 测试文件 | 说明 |
|---------|------|
| `scenario_group_test.dart` | 群组创建、加入、退出 |
| `scenario_group_message_test.dart` | 群组消息 |
| `scenario_group_invite_test.dart` | 群组邀请 |
| `scenario_group_double_invite_test.dart` | 重复邀请处理 |
| `scenario_group_state_test.dart` | 群组状态管理 |
| `scenario_group_sync_test.dart` | 群组状态同步 |
| `scenario_group_save_test.dart` | 群组数据保存 |
| `scenario_group_topic_test.dart` | 群组话题 |
| `scenario_group_topic_revert_test.dart` | 话题回滚 |
| `scenario_group_moderation_test.dart` | 群组管理（踢人、禁言等） |

### 音视频测试 (6个)

| 测试文件 | 说明 |
|---------|------|
| `scenario_toxav_basic_test.dart` | ToxAV 基础功能 |
| `scenario_toxav_many_test.dart` | 多节点音视频 |
| `scenario_toxav_conference_test.dart` | 音视频会议 |
| `scenario_toxav_conference_audio_test.dart` | 会议音频 |
| `scenario_toxav_conference_invite_test.dart` | 会议邀请 |
| `scenario_toxav_conference_audio_send_test.dart` | 会议音频发送 |

### 其他测试 (36个)

#### 会话相关
- `scenario_conversation_test.dart` - 会话列表
- `scenario_conversation_pin_test.dart` - 会话置顶

#### 用户信息
- `scenario_set_name_test.dart` - 设置昵称
- `scenario_set_status_message_test.dart` - 设置状态消息
- `scenario_user_status_test.dart` - 用户状态
- `scenario_avatar_test.dart` - 头像

#### 文件传输
- `scenario_file_transfer_test.dart` - 文件传输
- `scenario_file_cancel_test.dart` - 文件取消
- `scenario_file_seek_test.dart` - 文件定位

#### 网络和连接
- `scenario_reconnect_test.dart` - 重连测试
- `scenario_bootstrap_test.dart` - Bootstrap 测试
- `scenario_dht_nodes_response_api_test.dart` - DHT 节点响应 API
- `scenario_lan_discovery_test.dart` - 局域网发现

#### 会议功能
- `scenario_conference_test.dart` - 会议基础功能
- `scenario_conference_simple_test.dart` - 简单会议
- `scenario_conference_offline_test.dart` - 离线会议
- `scenario_conference_av_test.dart` - 会议音视频
- `scenario_conference_peer_nick_test.dart` - 会议成员昵称
- `scenario_conference_invite_merge_test.dart` - 会议邀请合并
- `scenario_conference_query_test.dart` - 会议查询

#### 群组扩展
- `scenario_group_general_test.dart` - 群组通用功能
- `scenario_group_large_test.dart` - 大群组测试
- `scenario_group_create_debug_test.dart` - 群组创建调试
- `scenario_group_message_types_test.dart` - 群组消息类型
- `scenario_group_error_test.dart` - 群组错误处理
- `scenario_group_multi_test.dart` - 多群组测试
- `scenario_group_vs_conference_test.dart` - 群组 vs 会议
- `scenario_group_member_info_test.dart` - 群组成员信息
- `scenario_group_state_changes_test.dart` - 群组状态变化
- `scenario_group_info_modify_test.dart` - 群组信息修改
- `scenario_group_tcp_test.dart` - 群组 TCP 连接

#### 其他功能
- `scenario_events_test.dart` - 事件处理
- `scenario_signaling_test.dart` - 信令
- `scenario_nospam_test.dart` - 防垃圾
- `scenario_many_nodes_test.dart` - 多节点测试
- `scenario_save_friend_test.dart` - 保存好友信息

### Binary Replacement 路径测试 (Phase 13, 3个/15用例)

通过 FFI callback 注入验证 `NativeLibraryManager` 的静态 listener 分发路径（`instance_id == 0` 单实例场景），覆盖二进制替换方案独有的代码路径。

| 测试文件 | 用例数 | 说明 |
|---------|--------|------|
| `scenario_native_callback_dispatch_test.dart` | 5 | NetworkStatus/ReceiveNewMessage/ConversationEvent/FriendAddRequest 注入 → 静态 listener 触发 |
| `scenario_custom_callback_handler_test.dart` | 6 | `customCallbackHandler` 注册/触发/null 安全、clearHistoryMessage/groupQuitNotification/groupChatIdStored 路由 |
| `scenario_library_loading_test.dart` | 4 | `setNativeLibraryName` 配置验证、registerPort、callback 到达、返回值 |

**运行方式**：
```bash
# 仅运行 Phase 13
./run_tests_ordered.sh 13
# 或
./run_tests_ordered.sh BINARY
```

## 运行测试

### 环境要求

1. **Flutter SDK**：需要 Flutter 和 Dart SDK
2. **Native 库**：需要编译好的 `libtim2tox_ffi.dylib`（macOS）或对应的库文件
3. **网络连接**（可选但推荐）：某些测试需要网络连接才能正常工作

### 安装依赖

```bash
cd tim2tox/auto_tests
flutter pub get
```

### 运行所有测试

```bash
# 基础运行（所有测试）
./run_tests.sh

# 按顺序运行（减少并发竞争）
./run_tests_ordered.sh

# 按顺序运行并跳过断言守卫（默认会先执行 ./check_test_assertions.sh）
ASSERTION_GUARD=0 ./run_tests_ordered.sh

# Phase 11 默认会**包含** scenario_dht_nodes_response_api_test（曾因 native trampoline
# 崩溃被 gate 起来，现在默认放进 phase 11）。要在本地跳过它：
RUN_NATIVE_CRASH_TESTS=0 ./run_tests_ordered.sh 11

# 仅运行 PHASE5_TOXAV + PHASE6_PROFILE，失败不停止、全部跑完并汇总到本 README 下方「最近执行汇总」
./run_tests_ordered.sh 5,6
# 或：./run_tests_ordered.sh PHASE5_TOXAV,PHASE6_PROFILE

# 仅运行 Phase 7/8/9（会话 / 文件 / 会议），失败不中断、继续执行并汇总到本 README
./run_tests_ordered.sh 7-9
# 或：./run_tests_ordered.sh 7,8,9  或  ./run_tests_ordered.sh 7 9

# 批量运行（兼容入口，等价于 run_tests_ordered.sh）
./run_all_tests.sh

# 运行断言反模式检查（防止引入永真断言/空 catch）
./check_test_assertions.sh

# 详细输出
./run_tests_verbose.sh
```

### 运行 Phase 10/11/12/13/14（Group Extended、Network、Other、Binary Replacement、Unit）

```bash
# 仅执行 PHASE10-12；失败不中断，继续执行后续用例
./run_tests_ordered.sh 10 11 12

# 仅执行 Phase 13（Binary Replacement 路径测试）
./run_tests_ordered.sh 13
# 或
./run_tests_ordered.sh BINARY

# 仅执行 Phase 14（unit_tests）
./run_tests_ordered.sh 14
# 或
./run_tests_ordered.sh UNIT
```

### 运行特定测试

```bash
# 运行单个测试文件
flutter test test/scenarios/scenario_login_test.dart

# 运行特定测试组
flutter test test/scenarios/scenario_sdk_init_test.dart

# 运行匹配名称的测试
flutter test --name "login"
```

### 运行测试分类

```bash
# 运行基础测试
flutter test test/scenarios/scenario_sdk_init_test.dart \
            test/scenarios/scenario_login_test.dart \
            test/scenarios/scenario_self_query_test.dart

# 运行好友测试
flutter test test/scenarios/scenario_friend_*.dart

# 运行群组测试
./run_group_tests.sh
```

### 测试超时设置

测试默认超时时间为 20-180 秒，根据测试复杂度设置。如需调整：

```dart
test('my test', () async {
  // test code
}, timeout: const Timeout(Duration(seconds: 120)));
```

### 环境变量

- `RUN_VIRTUAL=1` — 存在虚拟变体时，把每个测试替换为对应的 `*_virtual_test.dart`（详见 [虚拟时钟模式](#虚拟时钟模式-virtual-clock-mode)）。
- `PARALLEL_WORKERS=N` — 把所选测试拍平成一条队列，并发 N 路执行（详见上文）。
- `ASSERTION_GUARD=0` — 跳过前置 `check_test_assertions.sh` 检查。
- `RUN_NATIVE_CRASH_TESTS=0` — 在 Phase 11 中排除 `scenario_dht_nodes_response_api_test`。
- `RETRY_COUNT=N` — 每个失败用例最多重跑 N 次后才判定为失败。重跑通过的用例仍计入通过，但会在汇总的 "Flaky" 段单独列出。Tier 2 CI 默认 `RETRY_COUNT=1`。
- `SKIP_PHASES=N1,N2,...` — 即使所选范围（或"全部 phase"）包含这些 phase，也强制跳过。Tier 3 nightly 用它跳过 Phase 11（留给 Tier 4 跑）。

## 本地冒烟 (Tier 1)

每次 `git push` 之前推荐先跑一遍。覆盖 Phase 1 (basic)、3 (message)、12 (other) 与 14 (unit_tests)，全程用虚拟时钟：

```bash
RUN_VIRTUAL=1 ./run_tests_ordered.sh 1,3,12 14
# 约 25 个用例，M 系列芯片 ≤2 分钟。无对应 CI workflow —— 这是开发者 push 前的本地闸门。
```

## CI Pipeline (Tier 2 / 3 / 4)

三条 GitHub Actions 工作流位于 `toxee/.github/workflows/`。虚拟时钟层 (Tier 2) 负责 PR 的快反馈；wall-clock 层 (Tier 3、4) 用来抓虚拟模式会掩盖的协议层真实时序回归。

| Tier | Workflow                  | 触发条件                                                       | 模式                  | Phase 范围           | Runner               | 预算   |
|------|---------------------------|----------------------------------------------------------------|-----------------------|----------------------|----------------------|--------|
| 2    | `auto_tests.yml`          | 每个 PR + 推送到 `main` / `master`                              | virtual, `RETRY_COUNT=1` | 1–8, 10, 12–14    | ubuntu               | 30 min |
| 3    | `auto_tests_nightly.yml`  | cron `02:00 UTC` + `workflow_dispatch`                          | wall-clock            | 1–10, 12–14（通过 `SKIP_PHASES=11` 跳过 Phase 11） | ubuntu | 90 min |
| 4    | `auto_tests_full.yml`     | `workflow_dispatch`、PR 标签 `ci:full`、推送到 `release/**`     | wall-clock            | 1–14（完整，含 Phase 11） | ubuntu + macOS matrix | 120 min |

只有 Tier 4 会跑 Phase 11（`scenario_dht_nodes_response_api_test`、真实 DHT bootstrap、LAN discovery），涉及协议层大改动的 PR 请打 `ci:full` 标签触发。各 tier 都通过 `tool/ci/build_tim2tox.sh` 构建 FFI 库；Tier 2/3/4 都会传 `--toxav --dht-bootstrap`，以保证测试侧的特性面与开发构建一致（生产 App 构建两项均关）。

## 测试覆盖范围

### 基础功能 ✅
- ✅ SDK 初始化、配置、版本查询
- ✅ 登录/登出、登录状态
- ✅ 多实例支持
- ✅ 数据保存和加载

### 消息功能 ✅
- ✅ 消息发送和接收
- ✅ 消息查询
- ✅ 消息队列溢出处理
- ✅ 输入状态（正在输入）

### 好友功能 ✅
- ✅ 好友管理（添加、删除、查询）
- ✅ 好友请求处理
- ✅ 好友连接状态
- ✅ 好友信息查询
- ✅ 已读回执
- ✅ 防垃圾机制

### 群组功能 ✅
- ✅ 群组创建/加入/退出
- ✅ 群组邀请
- ✅ 群组消息
- ✅ 群组状态同步
- ✅ 群组管理（踢人、禁言等）
- ✅ 群组话题
- ✅ 大群组支持

### 会话功能 ✅
- ✅ 会话列表
- ✅ 会话置顶

### 文件传输 ✅
- ✅ 文件发送
- ✅ 文件取消
- ✅ 文件定位

### 音视频功能 ✅
- ✅ ToxAV 基础功能
- ✅ 多节点音视频
- ✅ 音视频会议
- ✅ 会议音频发送

### 其他功能 ✅
- ✅ 用户信息（昵称、状态、头像）
- ✅ 重连机制
- ✅ Bootstrap 配置
- ✅ DHT 网络
- ✅ 局域网发现
- ✅ 会议功能
- ✅ 信令
- ✅ 防垃圾

### Binary Replacement 路径 ✅
- ✅ NativeLibraryManager 静态 listener 分发（instance_id == 0）
- ✅ customCallbackHandler 注册与触发
- ✅ setNativeLibraryName 库加载配置
- ✅ FFI callback 注入与 Dart ReceivePort 到达验证

## 测试失败记录与修复状态

本节合并自原失败记录文档，基于各 Phase 的 log 解析。失败类型：**ASSERT**（断言/用例内失败）、**TIMEOUT**、**Other**（含 tearDown 中 GetInstanceIdFromManager WARNING、多实例清理顺序等）。

### 按根因归类与 Todo 映射

| Todo ID | 根因简述 | 受影响 scenario（仍可能失败） |
|--------|----------|------------------------------|
| **todo-connection-friend** | establishFriendship / waitForConnection 未在超时内满足；连接状态 0 时测试依赖已连接；好友/连接回调未按实例路由 | friend_delete、conversation、file_seek、avatar、message_overflow、file_cancel（setUpAll 相关） |
| **todo-conference-toxav** | 会议创建/加入/音频、ToxAV 状态未按 instance_id 路由或与测试期望不一致 | toxav_conference_audio_send、conference、conference_simple、conference_offline、conference_peer_nick、conference_query |
| **todo-signaling-events** | 信令/事件回调未按 instance_id 注册或未路由到测试实例；事件 45s 等待超时 | signaling、events |
| **todo-group-sync-message-error** | 群通用/大群/多群/消息类型/错误/create_debug 的断言或等待与实现不一致；已实施 runWithInstance、getPublicKey、waitForConnection、放宽错误码、延长消息等待 | group_general、group_large、group_multi、group_message_types、group_error（部分用例仍可能因群消息路由/时序超时） |
| **todo-group-member-info-tcp** | 群成员信息/群信息修改/群 TCP 相关断言或等待未满足 | group_member_info、group_info_modify、group_tcp（**已修复 12/12**） |
| **todo-network** | nospam 变更后连接/好友未在超时内就绪；多节点就绪等待未满足 | nospam、many_nodes（**已修复**） |
| **todo-message** | 连接/好友就绪后消息 round trip、自定义消息、溢出 | message、message_overflow（**已修复 6/6 通过**） |
| **todo-session-file-avatar** | 连接/好友就绪后仍失败的会话列表、文件取消、文件 seek、头像 | conversation、file_cancel、file_seek、avatar（已实施 2026-01-30，+11 -2） |

### 各 Phase 状态摘要

- **Phase 2 Friendship**：friend_connection_test、friend_delete_test 曾失败；fix-2.1 后 friend_connection 通过；friend_delete 仍与 establishFriendship/好友回调路由相关。
- **Phase 3 Message**：message_test、message_overflow_test **已修复**（todo-message，ReceiveNewMessage 按接收者 instance 派发）。
- **Phase 4 Group**：group_invite_test 曾失败；fix-2.1 后重跑通过。
- **Phase 5 ToxAV**：toxav_conference_audio_send_test 仍可能失败（ToxAV 回调/状态路由）。
- **Phase 6 Profile**：avatar_test 部分通过（todo-session-file-avatar 已做 pumpFriendConnection、waitForFriendConnection、fileSize 可空等）。
- **Phase 7 Conversation**：conversation_test 部分通过；onConversationChanged 仍可能因 waitForFriendConnection 超时（好友表为空）失败。
- **Phase 8 File**：file_cancel_test、file_seek_test 部分通过；file_seek「Seek and verify file integrity」仍可能因 transferComplete/progress 未在超时内满足失败。
- **Phase 9 Conference**：会议相关 6 个 scenario 仍可能失败（todo-conference-toxav）。
- **Phase 10 Group Extended**：group_general 等已部分修复（todo-group-sync-message-error）；group_create_debug、group_member_info、group_info_modify、group_tcp **已修复**。
- **Phase 11 Network**：nospam_test、many_nodes_test **已修复**（todo-network）。
- **Phase 12 Other**：signaling_test、events_test 仍可能失败（todo-signaling-events）。
- **Phase 13 Binary Replacement**：3 个测试文件 15 个用例 **全部通过**（2026-02-10）。通过 FFI callback 注入覆盖 NativeLibraryManager 静态 listener 分发、customCallbackHandler 注册触发、setNativeLibraryName 库加载。

### 关键修复实施记录（摘要）

- **todo-message**：scenario_message_test / message_overflow_test 增加 pumpFriendConnection、waitForConnection、waitForFriendConnection、waitUntilWithPump 收消息；用例 timeout 90s/120s；Native ReceiveNewMessage 按接收者 instance 派发后 6/6 通过。
- **todo-session-file-avatar**：conversation 用 waitUntilWithPump 等 onConversationChanged；file_cancel 用 message: fileResult.messageInfo! 避免 7012，并 pumpFriendConnection；file_seek 仅等 transferComplete(90s)；avatar 增加 pumpFriendConnection、waitForFriendConnection(90s)、fileSize 可空。重跑 +11 -2。
- **todo-network**：nospam 从 Bob 侧删除 Alice、isFromBob 匹配、Tim2ToxSdkPlatform.getFriendApplicationList、FFI get_friend_applications_for_instance；many_nodes waitForConnection(45s)、establishFriendship、getLastCallbackGroupId。
- **fix-2.3-2.6 / group_create_debug**：waitForConnection(15s)、runWithInstanceAsync createGroup、单用例超时 35s/50s。
- **group_member_info / group_info_modify / group_tcp**：FFI 跨实例 chat_id、JoinGroup 64 位 chat_id、SetGroupMemberRole 重试与 waitUntilFounderSeesMemberInGroup、TCP 前 establishFriendship。

### 简单修复判定结论

上述失败均涉及多实例 cleanup、GetInstanceIdFromManager、好友/群邀请/会议/信令等 SDK 或 FFI 行为，或测试内等待/断言与产品行为不一致。无仅靠“单文件内调大 timeout 或改一句 expect”即可解决的项；建议先按 Todo 根因处理后再重跑。

---

## 已知问题和限制

- **Tox 网络连接延迟**：连接建立 10–60 秒，好友连接需额外时间；已实现本地 bootstrap、超时 90–180s，建议有网环境运行。
- **好友关系要求**：消息发送需双方为好友；已实现 establishFriendship、自动接受、超时与重试。
- **群组 6017**：群组映射/初始化未就绪时可能返回 6017；测试已加等待与处理。
- **会话列表**：依赖好友连接与消息送达；测试已加连接等待与送达验证。

## 故障排除

### Native 崩溃 (SIGSEGV / exit 139)

**症状**：测试进程退出码 139，或日志出现 `[callback_bridge] FATAL: end backtrace`。

**排查顺序**：
1. **抓 native 栈**：按 [DEBUG_NATIVE_CRASH.md](DEBUG_NATIVE_CRASH.md) 中的步骤用 lldb 跑（`./run_conversation_test_with_lldb.sh` 等脚本会自动 attach），崩溃时执行 `bt`、`frame variable` 看具体帧。
2. **常见根因**：会话回调里 `lastMessage` 悬空、跨线程使用 `user_data` 字符串、多实例下 `instance_id` 没正确传到 trampoline、`Dart_PostCObject_DL` 在 isolate 被销毁后调用。可以用 `git log -- ffi/callback_bridge.cpp ffi/dart_compat_listeners.cpp` 翻历史修复点参考。

### 网络连接问题

**症状**：测试超时，节点无法连接

**解决方案**：
1. 检查网络连接
2. 使用代理（如需要）：
   ```bash
   export all_proxy=http://127.0.0.1:7890
   ```
3. 检查本地 bootstrap 配置
4. 增加测试超时时间

### 超时问题

**症状**：测试在等待连接或好友关系时超时

**解决方案**：
1. 增加超时时间：
   ```dart
   timeout: const Timeout(Duration(seconds: 180))
   ```
2. 检查节点是否已连接：
   ```dart
   await node.waitForConnection(timeout: const Duration(seconds: 30));
   ```
3. 查看详细日志输出：
   ```bash
   ./run_tests_verbose.sh
   ```

### 依赖问题

**症状**：编译错误或运行时找不到库

**解决方案**：
1. 确保已安装依赖：
   ```bash
   flutter pub get
   ```
2. 确保 native 库已编译：
   ```bash
   # auto_tests 已在 tim2tox/ 内，回到上一级即可
   cd ..
   ./build_ffi.sh
   ```
3. 检查库路径配置

### 环境配置

**症状**：测试在不同环境中表现不一致

**解决方案**：
1. 确保 Flutter 环境正确：
   ```bash
   flutter doctor
   ```
2. 检查 Dart 版本（需要 >= 3.0.0）
3. 确保测试数据目录有写权限

## 测试最佳实践

### 1. 测试结构

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

### 2. 等待和同步

- 使用 `waitUntil()` 等待条件满足
- 使用 `waitForConnection()` 等待网络连接
- 使用 `waitForFriendConnection()` 等待好友连接
- 为异步操作设置适当的超时时间

### 3. 错误处理

- 检查返回码和错误消息
- 提供有意义的断言消息
- 在超时时提供诊断信息

### 4. 资源清理

- 在 `tearDown()` 中清理所有资源
- 调用 `scenario.dispose()` 清理所有节点
- 调用 `teardownTestEnvironment()` 清理测试环境

## 编译与测试状态

- ✅ **编译**：所有编译错误已修复，测试可正常编译。
- ✅ **Phase 13 Binary Replacement**：15/15 通过（2026-02-10 基线）。
- **最新回归状态**：见 [VALIDATION_RESULTS.md](VALIDATION_RESULTS.md)。
- **Native 崩溃调试**：见 [DEBUG_NATIVE_CRASH.md](DEBUG_NATIVE_CRASH.md)。

### 最近执行汇总

（由 `./run_tests_ordered.sh` 或 `./run_tests_ordered.sh 7-9` 等运行后自动更新，汇总当次所有用例执行情况。）

<!-- AUTO_GEN_LAST_RUN_START -->
（运行脚本后此处会写入当次执行结果：通过/失败数量、失败用例列表、所有用例执行情况。）
<!-- AUTO_GEN_LAST_RUN_END -->

## 参考文档

- [c-toxcore/auto_tests](https://github.com/TokTok/c-toxcore/tree/master/auto_tests) - 原始测试框架
- [Tencent Cloud Chat SDK 文档](https://cloud.tencent.com/document/product/269) - API 参考
- [Flutter 测试文档](https://docs.flutter.dev/testing) - Flutter 测试框架

## 贡献指南

1. 添加新测试时，请遵循现有的测试模式
2. 确保测试有适当的超时设置
3. 添加必要的等待逻辑，处理异步操作
4. 在 `tearDown()` 中清理所有资源
5. 更新本文档，添加新测试的说明

## 许可证

本测试套件遵循 GPL-3.0 许可证。
