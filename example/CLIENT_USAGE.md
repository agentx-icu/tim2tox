# Echo Bot 客户端使用说明
> 语言 / Language: [中文](CLIENT_USAGE.md) | [English](CLIENT_USAGE.en.md)

这里有**两个**客户端二进制，UX 完全不同：

| 二进制 | 模式 | 用途 |
|--------|------|------|
| `echo_bot_client` (`echo_bot_client.cpp`) | **非交互**，只接受 `--auto <user_id> <message> [--extended]` | 一次性跑"加好友 → 等上线 → 发送 → 校验回显"，主要给脚本和 CI 用 |
| `tim2tox_client` (`tim2tox_client.cpp`) | **交互**，REPL 命令 `connect / send / status / help / quit` | 手工调试。仅当主项目已生成 `../build/source/libtim2tox.a` 时才会被构建 |

> 旧版本说明文档曾把 `echo_bot_client` 描述为带 `add / send / status / friends / help / quit` 命令的交互式 C 客户端 —— 那是误植。当前代码不是 C，也不是交互模式。

## 编译

```bash
# 1. 主项目（可选，只为产出 tim2tox_client 需要的 libtim2tox.a）
cd ..
./build.sh

# 2. 示例
cd example
./build_examples.sh
```

成功后 `example/build/` 下会有 `echo_bot_server` / `echo_bot_client`，以及（如果 `libtim2tox.a` 存在）`tim2tox_client`。

## 使用 — `echo_bot_server` + `echo_bot_client --auto`

### 1. 启动 Echo Bot 服务端

```bash
cd example/build
./echo_bot_server
```

启动后会打印（节选自 `echo_bot_server.cpp:118-122`）：

```
=== Echo Bot Server ===
User ID: <64-char hex user id>
Status: Echoing your messages
=======================
Server starting...
Press Ctrl+C to stop
```

记下 `User ID:` 后那串十六进制串。

### 2. 跑 `echo_bot_client --auto`

```bash
cd example/build
./echo_bot_client --auto <server_user_id> "ping"
./echo_bot_client --auto <server_user_id> "ping" --extended   # 加跑 Unicode / 长文本 / Burst 验证
```

也可以通过环境变量跳过 extended 套件：

```bash
TIM2TOX_SKIP_EXTENDED=1 ./echo_bot_client --auto <server_user_id> "ping"
```

执行流程（见 `echo_bot_client.cpp:124-229`）：

1. 等本地客户端在 120 秒内上线（`wait_connected`）。
2. `AddFriend`，自动接受由服务端那边处理。
3. 等服务端这一侧也"上线"（V2TIM SDK `OnUserStatusChanged`）。
4. 用 `SendC2CTextMessage` 发送 `<message>`，**重试最多 60 秒**直到 send 成功。
5. 等 60 秒内收到对端原样回显。
6. 如开启 extended：再跑 Unicode、长文本（1350 字节，靠近 Tox 文本单包上限）、5 条 burst。

退出码：

| code | 含义 |
|------|------|
| 0 | 全部成功 |
| 2 | 客户端未在 120 秒内上线 |
| 6 | 基础消息未在 60 秒内收到回显 |
| 7 | extended Unicode 失败 |
| 9 | extended 长文本失败 |
| 10 | extended Burst 失败 |

## 使用 — `tim2tox_client`（交互模式）

```bash
cd example/build
./tim2tox_client <server_user_id>
```

REPL 命令：

- `connect` — 发送好友请求
- `send <message>` — 发送消息
- `status` — 查看连接状态 / 好友列表
- `help` — 帮助
- `quit` / `exit` — 退出

也可以直接键入文本，会按"普通消息"语义发送。

## 测试场景

- **基本回显**：`echo_bot_client --auto ... "hello"`，期望 60 秒内收回 `hello`。
- **Unicode**：`--extended` 时自动验证 `"Hello/你好/Привет/😀"`。
- **长文本**：`--extended` 时自动构造 1350 字节 `'L'` 测包，验证接近上限的分片不丢。
- **连续消息**：`--extended` 时连发 5 条 `burst_<i>_<unix_ts>` 校验顺序。

## 故障排除

- **客户端 120 秒没连上网**：检查 Bootstrap 节点 / 防火墙；先用 `tim2tox_client` 交互模式 + `status` 命令观察。
- **消息一直 send fail**：通常是服务端还没接受好友 —— `echo_bot_client` 已经做了 60 秒重试，仍失败说明对端没起来。
- **收不到回显**：服务端是否打印了 `Echoing ...` 之类的日志？检查 `simpleListener::OnRecvC2CTextMessage` 是否被命中。
- **编译跳过 `tim2tox_client`**：先 `bash ../build.sh` 产出 `../build/source/libtim2tox.a`。
- **`libsodium` / `openssl` 找不到**：macOS 安装 `brew install libsodium openssl`；Linux 安装 `libsodium-dev` / `libssl-dev`。

## 相关文件

- `echo_bot_server.cpp` — 服务端实现
- `echo_bot_client.cpp` — 非交互客户端
- `tim2tox_client.cpp` — 交互客户端
- `test_echo.sh` — server + client 一体化烟雾测试
- `build_examples.sh` — 构建包装脚本

## 注意事项

1. 首次连接 Tox 网络可能要数十秒。
2. Tox profile（savedata）由 `V2TIMManager::GetInstance()->InitSDK(...)` 隐式管理，**默认实现没有显式写 `.tox` 文件**，除非通过 `tim2tox_ffi_init_with_path(...)` / `V2TIMSDKConfig.initPath` 指定持久化目录。旧文档提到的 `echo_bot_savedata.tox` / `echo_bot_client_savedata.tox` 在当前实现中**不一定存在**。
3. 服务端通过 `V2TIMFriendshipListener` 默认接受全部好友请求。
4. 用 Ctrl+C 退出；进程会调 `UnInitSDK`。
