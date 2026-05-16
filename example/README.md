# Tim2Tox Examples
> 语言 / Language: [中文](README.md) | [English](README.en.md)

这个目录包含使用 Tim2Tox 库的最小示例：一个 echo bot 服务端 + 两个客户端。它们直接使用 C++ 侧的 V2TIM API（不走 Dart），用来快速验证后端能不能跑通。

## 文件说明

| 文件 | 类型 | 说明 |
|------|------|------|
| `echo_bot_server.cpp` | C++ | Echo Bot 服务端：登录、加好友自动接受、把收到的 C2C 文本原样回发 |
| `echo_bot_client.cpp` | C++ | **非交互式**客户端，配合 `--auto <user_id> <message>` 自动建友 + 发送，主要供脚本化测试 |
| `tim2tox_client.cpp` | C++ | **交互式**客户端，支持 `connect / send / status / help / quit` 命令；仅当存在 `../build/source/libtim2tox.a` 时构建 |
| `CMakeLists.txt` | CMake | 构建配置 |
| `build_examples.sh` | sh | 包装脚本，等价于 `mkdir build && cd build && cmake .. && make` |
| `test_echo.sh` | sh | 启动 `echo_bot_server` 与 `echo_bot_client --auto`、做端到端冒烟测试的脚本 |

## 构建要求

- CMake 3.10+
- C++17 编译器
- libsodium、OpenSSL（macOS：`brew install libsodium openssl`）
- 可选：先在仓库根 `./build.sh` 生成 `build/source/libtim2tox.a`，这样 `tim2tox_client` 才会被构建（否则 CMake 会跳过它并打 warning）

## 构建步骤

```bash
# 1. 构建主项目静态库（用于 tim2tox_client；可选）
cd ..
./build.sh

# 2. 构建示例
cd example
./build_examples.sh        # 或手动 mkdir build && cd build && cmake .. && make
```

成功后 `example/build/` 下会出现：

- `echo_bot_server`
- `echo_bot_client`
- `tim2tox_client`（若 `../build/source/libtim2tox.a` 存在）
- `libirc_client.dylib` / `.so`（IRC 通道桥的动态加载库）

## 运行示例

### 1. 启动 Echo Bot 服务端

```bash
cd example/build
./echo_bot_server
```

启动后会打印登录后的 user ID（即 V2TIM 映射的对端 ID，64 字符十六进制），形如：

```
=== Echo Bot Server ===
User ID: F404ABAA1C99A9D37D61AB54898F56793E1DEF8BD46B1038B9D822E8460FAB67
Status: Echoing your messages
=======================
Server starting...
Press Ctrl+C to stop
```

> `User ID` 是 V2TIM 抽象层暴露给业务的 ID。下面的客户端示例把它作为对端 user ID 传入。

### 2. 运行交互式客户端（`tim2tox_client`）

```bash
cd example/build
./tim2tox_client F404ABAA1C99A9D37D61AB54898F56793E1DEF8BD46B1038B9D822E8460FAB67
```

进入交互模式后可用命令：

- `connect` — 发送好友请求
- `send <message>` — 发送消息
- `status` — 查看连接状态
- `help` — 帮助
- `quit` — 退出

或直接输入文本（默认作为消息体发送）。

### 3. 运行自动化客户端（`echo_bot_client`）

非交互模式，按一次性 `--auto` 跑完"加好友 → 等对端上线 → 发送 → 校验回显"：

```bash
cd example/build
./echo_bot_client --auto <server_user_id> "ping"                  # 基础冒烟
./echo_bot_client --auto <server_user_id> "ping" --extended        # 额外跑 Unicode / 长文本 / 突发消息测试
```

退出码：

| code | 含义 |
|------|------|
| 0 | 全部成功 |
| 2 | 客户端未在 120 秒内连上网 |
| 6 | 基础消息未在 60 秒内收到回显 |
| 7 / 9 / 10 | Extended 模式下分别是 Unicode / 长文本 / Burst 消息回显失败 |

也可以用 `test_echo.sh` 一键串起 server 与 client：

```bash
cd example
./test_echo.sh
```

## 故障排除

- **构建失败**：确认 `libsodium`、`openssl`、`cmake` 已安装。
- **`tim2tox_client` 没生成**：先 `bash ../build.sh` 产出 `../build/source/libtim2tox.a` 再重跑 `./build_examples.sh`。
- **连接失败 / 没建上好友**：检查防火墙、Bootstrap 节点配置；可临时改用本地 bootstrap（详见 [doc/integration/BOOTSTRAP_AND_POLLING.md](../doc/integration/BOOTSTRAP_AND_POLLING.md)）。
- **消息发送失败**：通常是好友关系未建立 —— `echo_bot_server` 的"自动接受好友请求"是异步的，给几秒缓冲再重试。

## 扩展方向

这些示例只覆盖最小路径（C2C 文本），可以基于它们进一步实验：

- 群组聊天（`V2TIMGroupManager` / `JoinGroup` / `SendGroupMessage`）
- 文件传输（`tim2tox_ffi_send_file` / `file_control`）
- 音视频通话（`tim2tox_ffi_av_*`）
- 自定义消息（`SendC2CCustomMessage` / `SendGroupCustomMessage`）
