# Tim2Tox Bootstrap 与轮询
> 语言 / Language: [中文](BOOTSTRAP_AND_POLLING.md) | [English](BOOTSTRAP_AND_POLLING.en.md)


本文档说明 Tim2Tox 的 Bootstrap 节点加载、连接建立与轮询机制。客户端（接入方）负责节点来源、保存与 UI；Tim2Tox 只消费通过 `BootstrapService` 暴露的当前节点三元组并驱动轮询。

## 1. 范围

这条链路横跨两层：

- **客户端**：负责选择和保存当前 Bootstrap 节点、决定启动顺序、提供节点配置 UI（如手动/自动/局域网等）；实现 `BootstrapService` 接口并注入给 `FfiChatService`。
- **tim2tox/dart**：负责把 `BootstrapService` 提供的 `host/port/publicKey` 应用到 Tox 实例，并通过 `startPolling()` 驱动连接状态、消息、文件与 AV 事件。

Tim2Tox 内部没有单独的“局域网 Bootstrap 模式”分支，框架消费的始终是当前 Bootstrap 节点三元组。局域网等模式是客户端的配置层概念。

## 2. Bootstrap 节点来源（客户端侧）

常见来源由客户端实现，例如：

1. 手动输入
2. 从公共节点列表（如 `https://nodes.tox.chat/json`）拉取
3. 局域网内的本地 Bootstrap 服务（若客户端支持）

Tim2Tox 侧仅依赖接口：

- `dart/lib/interfaces/bootstrap_service.dart`：暴露当前节点的 `host/port/publicKey` 读取与写入。
- `dart/lib/service/ffi_chat_service.dart`：在 `init()` 期间调用 `_loadAndApplySavedBootstrapNode()` 从 `BootstrapService` 读取并应用。

## 3. 节点选择与保存（客户端侧）

客户端需在 `FfiChatService.init()` 之前或通过 `BootstrapService` 提供可用节点，例如：

- **自动模式**：启动前若尚未保存节点，可拉取公共节点列表并写入当前配置，保证首次 `init()` 时已有可用节点。
- **手动模式**：设置页输入后写入当前配置；`FfiChatService.init()` 会在 `_loadAndApplySavedBootstrapNode()` 中读取并应用。
- **局域网模式**（若客户端支持）：本地 Bootstrap 服务暴露 `host/port/pubkey` 后，客户端将其写回当前节点配置，Tim2Tox 仍只识别“当前 Bootstrap 节点”。

## 4. Tim2Tox 如何应用 Bootstrap 节点

`FfiChatService.init()` 末尾会调用 `_loadAndApplySavedBootstrapNode()`：

- `manual` 模式：读取 `getCurrentBootstrapNode()` 并调用 `addBootstrapNode(...)`
- 其他模式：优先走 `BootstrapService.getBootstrapHost/Port/PublicKey()`；拿不到时再 fallback 到 `getCurrentBootstrapNode()`

`addBootstrapNode(host, port, publicKeyHex)` 会：

1. 调用 FFI `tim2tox_ffi_add_bootstrap_node`
2. 成功时把该节点保存回当前配置

这意味着在有 `service` 实例的页面里，“测试节点”不是纯只读操作。当前实现中，测试成功也会把该节点写成当前节点，因为它复用了 `addBootstrapNode(...)`。

## 5. 登录与联网状态

`FfiChatService.login(...)` 只负责：

- 调用原生 `login`
- 读取当前 `selfId`
- 立即用 `getSelfConnectionStatus()` 推送一次当前连接状态

它不保证此时已经完成联网。真正的连接变化依赖轮询队列中的 `conn:success` / `conn:failed` 事件。

**客户端启动顺序建议**：在具备可用 Bootstrap 节点后，初始化 `FfiChatService`，再调用 `startPolling()`，并监听 `connectionStatusStream`。`startPolling()` 是联网和消息消费的起点，需在适当时机调用。具体顺序与 UI 流程见各客户端项目文档。

## 6. 轮询循环

`FfiChatService.startPolling()` 当前会做这些事情：

1. 取消旧 poller 和旧 profile 保存定时器
2. 启动每 60 秒一次的 `saveToxProfileNow()`
3. 先推送一次当前 `_isConnected`
4. 按自适应间隔安排下一轮 poll

当前轮询间隔策略：

- 有文件传输：`50ms`
- 有多实例或共享实例轮询：`50ms`
- 最近 2 秒内有活动：`200ms`
- 空闲态：`1000ms`

每轮 poll 会：

1. 先尝试执行 `avIterate(instanceId)`
2. 按实例优先级轮询文本事件队列
3. 单次最多批量处理 200 个事件，避免文件传输时队列积压

多实例场景下会优先轮询非零实例，且倾向让接收方实例先被消费，以便 `file_request` 更快被处理。

## 7. 轮询队列里有哪些关键事件

当前文档最需要维护者关注的事件有：

- `conn:success` / `conn:failed`
- `c2c:` / `gtext:`
- `file_request:`
- `file_done:`
- `typing:`

其中：

- `conn:success` 会把 `_isConnected` 置为 `true`，并触发头像同步
- `file_request:` 是文件接收链路的关键前置事件；如果它没有及时被 poll 到，接收端就不能及时 `acceptFileTransfer`
- `file_done:` 会把临时接收状态收口到历史消息与 UI

这也是为什么文件传输期间会把 poll 间隔压到 `50ms`，并允许单轮批量 drain 队列。

## 8. 客户端侧注意点（摘要）

- **切换节点**：可调用 `service.addBootstrapNode(...)` 写入新节点并视需再次 `service.login(...)`，无需重建整个 `FfiChatService`。
- **测试节点**：若复用 `addBootstrapNode(...)` 做探测，成功时当前节点配置会被更新，属实现层面的副作用。
- **局域网 Bootstrap**（若客户端支持）：本地服务暴露 `ip/port/pubkey` 后，仍需将对应三元组写回当前节点配置，Tim2Tox 不区分节点来源。

具体实现与维护顺序见各客户端仓库文档；以 Tim2Tox 为本仓库时，优先阅读本仓库内 `dart/lib/interfaces/bootstrap_service.dart` 与 `dart/lib/service/ffi_chat_service.dart`。

## 9. 相关文档

- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- [API 参考](../api/API_REFERENCE.md)
- 示例客户端的启动、Bootstrap 与账号会话说明见该客户端项目文档，例如 [toxee](https://github.com/agentx-icu/toxee)（当 Tim2Tox 作为 submodule 被使用时，常见于上层仓库的 doc）。
