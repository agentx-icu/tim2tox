[English](./API_REFERENCE_TEMPLATE.md)

# Tim2Tox API 参考文档写作模板

本文档定义 Tim2Tox API 参考条目的写作规范，用于维护 [API_REFERENCE.md](API_REFERENCE.md) 或按模块拆分的 API 文档。每条 API 需包含规定字段，并明确区分**面向客户端接入方的 API** 与 **内部维护 API**，以及 **稳定接口** 与 **内部实现细节**。

---

## 1. 适用范围

本模板适用于：

- **C FFI 接口**（`tim2tox_ffi.h` 中声明的 `tim2tox_ffi_*` 函数）
- **Dart 包对外 API**（如 `FfiChatService`、`Tim2ToxSdkPlatform`、`Tim2ToxFfi` 的公开方法与属性）
- **V2TIM C++ 对 FFI 暴露部分**（即被 Dart* 或 tim2tox_ffi 直接调用的 V2TIM 行为，用于说明“被调用方”语义）

不要求为每个 Dart* 内部符号单独写条目，但若某 Dart* 函数被客户端或 SDK 通过 NativeLibraryManager 间接调用，应按“客户端 API”或“稳定接口”撰写。

---

## 2. 单条 API 条目结构（必须包含）

每个 API 条目应包含下表所列字段；可选字段可标注“可选”或“若适用则写”。

| 字段 | 说明 |
|------|------|
| **用途** | 一句话说明该 API 的职责与典型使用场景。 |
| **参数** | 名称、类型、含义；是否可空/可选；对 buffer 类参数注明“由调用方分配，由实现写入”或“由实现填充，调用方传入缓冲区与长度”。 |
| **返回值** | 类型与取值含义（如 0=失败/1=成功、写入字节数、handle、负数错误码）。 |
| **调用时机** | 前置条件（如 init 之后、login 之后）；是否可重复调用、是否必须在某阶段前/后调用。 |
| **线程/异步语义** | 是否阻塞、在哪个线程执行、回调或 Future 的完成线程/isolate。 |
| **失败情况** | 返回码或异常、错误信息含义、典型失败路径（未初始化、无效 handle、超时、参数无效等）。 |
| **与上层模块关系** | 调用方（如 FfiChatService、NativeLibraryManager、应用代码）；被调用方（如 V2TIMManagerImpl、ToxManager）；若为内部 API 则注明“仅由 xx 调用”。 |
| **示例** | 最小可运行代码片段（伪代码或真实语言均可），便于集成方仿写。 |

---

## 3. Markdown 条目示例

以下为一条符合上述结构的示例（C FFI 风格）。

```markdown
### tim2tox_ffi_send_c2c_text

**分类**: [Client] [Stable]

- **用途**: 向指定好友发送单聊文本消息；调用方通常为 FfiChatService.sendText，最终由 V2TIMMessageManagerImpl 经 ToxManager 发送到 c-toxcore。
- **参数**:
  - `user_id`: `const char*`，好友 userID（通常为 64 字符 hex 公钥），非空。
  - `text`: `const char*`，UTF-8 文本内容，非空。
- **返回值**: `int`。1 表示已提交发送，0 表示失败（如未登录、好友不存在、参数无效）。
- **调用时机**: 必须在 init 且 login 成功后调用；可重复调用。
- **线程/异步语义**: 调用线程不限制；实际发送与送达为异步，结果通过消息状态回调或轮询事件反馈。
- **失败情况**: 返回 0 时无额外错误码；典型原因：当前实例未登录、user_id 非好友、空指针或无效编码。
- **与上层模块关系**: 调用方 FfiChatService → Tim2ToxFfi；被调用方 V2TIMMessageManagerImpl → ToxManager → tox_friend_send_message。
- **示例**:
  ```c
  const char* uid = "0123..."; // 64-char hex
  const char* msg = "hello";
  int ok = tim2tox_ffi_send_c2c_text(uid, msg);
  if (!ok) { /* 处理失败 */ }
  ```
```

---

## 4. 分类与标记约定

在每条 API 标题或首行用以下标记标明**受众**与**稳定性**。

### 4.1 受众

| 标记 | 含义 |
|------|------|
| **[Client]** | 面向客户端接入方的 API。SDK 或 Flutter 应用直接或间接使用（如通过 TIMManager、Platform、FfiChatService 对外方法）。 |
| **[Internal]** | 内部维护 API。仅由 tim2tox 内部使用（如 dart_compat_* 实现、FfiChatService 私有方法、Dart* 符号仅供 NativeLibraryManager 动态调用，不推荐应用直接依赖）。 |

### 4.2 稳定性

| 标记 | 含义 |
|------|------|
| **[Stable]** | 稳定接口。承诺长期兼容，不随意变更签名或语义；适合第三方集成与文档化。 |
| **[Implementation]** | 内部实现细节。可能随实现重构而变更或移除，不承诺跨版本稳定。 |

### 4.3 组合示例

| 条目类型 | 建议标记 | 说明 |
|----------|----------|------|
| tim2tox_ffi_init / login / send 等 | [Client] [Stable] | 对外 C API，客户端或 FfiChatService 调用。 |
| FfiChatService.init / login / getHistory | [Client] [Stable] | Dart 层对外服务 API。 |
| Dart* 函数（如 DartInitSDK） | [Internal] [Stable] 或 [Implementation] | 由 SDK 动态查找调用，签名与原生 bindings 一致；若承诺与原生 SDK 同步则标 Stable，否则标 Implementation。 |
| FfiChatService 内部方法（如 _loadAndApplySavedBootstrapNode） | [Internal] [Implementation] | 仅框架内部使用，可能重命名或删除。 |

---

## 5. 按层示例（可选参考）

维护者可按层撰写时参考以下简表，确保每条都至少包含 §2 的八个字段。

| 层 | API 示例 | 用途一句话 |
|----|----------|------------|
| C FFI | `tim2tox_ffi_init_with_path` | 使用指定目录初始化 SDK，用于多账号或测试实例。 |
| C FFI | `tim2tox_ffi_poll_text` | 从指定实例的事件队列拉取下一条文本/事件行。 |
| Dart | `FfiChatService.startPolling()` | 启动轮询定时器，消费 C++ 侧事件队列并更新连接/消息/文件状态。 |
| Dart | `Tim2ToxSdkPlatform.getHistoryMessageList` | Platform 实现：按会话拉取历史消息，委托 FfiChatService.getHistory 与 MessageHistoryPersistence。 |

每条在正文中展开为完整条目（用途、参数、返回值、调用时机、线程/异步、失败、与上下层关系、示例），并加上 [Client]/[Internal] 与 [Stable]/[Implementation] 标记。

---

## 6. 与现有 API_REFERENCE 的关系

- [API_REFERENCE.md](API_REFERENCE.md) 为当前已编写的 API 列表与说明；后续新增或修订条目时应遵循**本模板**的结构与标记。
- 若将 API 文档按模块拆分（如 C FFI、Dart Service、Dart Platform 分文件），每个文件内仍应使用同一套条目结构和分类标记，并在总索引中注明“写作规范见 API_REFERENCE_TEMPLATE”。
