# Tim2Tox

> 语言 / Language: [中文](README.md) | [English](README.en.md)

---

## 项目定位

**Tim2Tox** 是连接 **Tencent Cloud Chat UIKit** 与 **Tox** 的可复用兼容层/框架。它让现有基于腾讯云 IM SDK（V2TIM）的 Flutter 聊天 UI 与业务逻辑，在**不替换 UI 与调用习惯**的前提下，改为走 Tox P2P 网络。

**明确定义**：

- **它是**：可复用的兼容层/框架——提供 C++ 核心、C FFI、Dart 封装与 SDK Platform 接入能力，供任意 Flutter 客户端集成。
- **它不是**：最终客户端应用（不包含完整 App、账号体系或产品 UI）。
- **它不是**：单纯的 Tox 协议封装（除协议外，还实现 V2TIM 语义映射、回调桥接、历史与轮询等与 UIKit 对接所需的能力）。

---

## 解决的问题

**核心兼容问题**：UIKit 与上层业务按 **V2TIM 风格** 调用（如 `TIMManager.instance.login()`、`getMessageManager().sendMessage()`）并依赖 **原生 SDK 的回调格式**（如 `apiCallback` / `globalCallback` JSON）。若直接换成 Tox，需重写大量业务与 UI。Tim2Tox 在**协议层**实现 V2TIM 语义并保持回调契约，使：

- 调用方仍使用 `TIMManager`、各 Manager、Listener 等现有习惯；
- 底层实际执行 Tox 的 init、login、发消息、好友/群组等操作；
- 事件通过既有回调/JSON 格式回传到 Dart，监听器与 UI 无需改协议层。

即：**解决“在保留 UIKit 调用与回调习惯的前提下，将后端从云 IM 换为 Tox P2P”的兼容问题**。

---

## 架构总览

技术栈自下而上分为四层，**两条调用入口**在 C FFI 层汇合后共用同一套 C++ 实现与 Tox 核心。

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Flutter / UIKit 应用层                                                   │
│  调用方: TIMManager.instance / TencentCloudChatSdkPlatform.instance      │
└─────────────────────────────┬─────────────────────────────────────────────┘
                              │
    ┌─────────────────────────┴─────────────────────────┐
    │  Dart 层 (tim2tox_dart)                            │
    │  Tim2ToxSdkPlatform → FfiChatService → Tim2ToxFfi  │  (Platform 路径)
    │  或 NativeLibraryManager → bindings.Dart*()        │  (二进制替换路径)
    └─────────────────────────────┬─────────────────────────────────────────┘
                                  │
┌─────────────────────────────────┴─────────────────────────────────────────┐
│  C FFI 层 (libtim2tox_ffi)                                                 │
│  tim2tox_ffi_* (高级 API)  │  Dart* (dart_compat_*) 兼容层                │
└─────────────────────────────┬─────────────────────────────────────────────┘
                              │
┌─────────────────────────────┴─────────────────────────────────────────┐
│  C++ 核心 (source/)                                                      │
│  V2TIMManagerImpl, V2TIMMessageManagerImpl, ToxManager, ...             │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │
┌─────────────────────────────┴─────────────────────────────────────────┐
│  c-toxcore (P2P 协议)                                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 调用链总图（两条入口如何汇合）

```
                    UIKit / 业务代码
                           │
         ┌─────────────────┴─────────────────┐
         │                                     │
    路径 A: 二进制替换                    路径 B: Platform
    TIMManager.instance                 TencentCloudChatSdkPlatform.instance
         │                                     │
    NativeLibraryManager                  Tim2ToxSdkPlatform
         │                                     │
    bindings.DartXXX(...)                 FfiChatService
         │                                     │
         └──────────────┬──────────────────────┘
                        │
              libtim2tox_ffi (C)
              ├─ dart_compat_*.cpp (Dart* 实现)   ← 路径 A
              └─ tim2tox_ffi_* (C API)            ← 路径 B
                        │
              V2TIMManagerImpl / V2TIMMessageManagerImpl / ...
                        │
              ToxManager → c-toxcore
```

### 各层为什么存在

| 层 | 存在原因 |
|----|----------|
| **C++ 核心** | 实现 V2TIM 语义（登录、消息、好友、群组、会话等）并对接 c-toxcore；不依赖 Dart，便于测试与复用。 |
| **C FFI** | Dart 只能通过 FFI 调用 C 接口；C 层负责“无 C++ 泄漏”的边界、参数/返回值约定，以及二进制替换所需的 Dart* 符号。 |
| **Dart 封装** | 封装 FFI 调用、管理轮询与历史等状态、提供 Stream/Future；FfiChatService 是 Platform 路径的统一被调用方。 |
| **SDK Platform** | 当 SDK 使用 `isCustomPlatform` 时，部分能力（如历史、轮询、自定义回调）必须由客户端提供实现；Tim2ToxSdkPlatform 实现该接口并委托给 FfiChatService。 |

---

## 核心能力

- **V2TIM 语义实现**：Init/Login、消息收发、好友/群组/会话管理、信令等，与腾讯云 IM SDK 的 V2TIM API 风格一致。
- **双入口**：**二进制替换**（替换动态库，SDK 仍走 NativeLibraryManager → Dart*）与 **Platform**（设置 `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform`，部分或全部方法走 FfiChatService）。
- **回调桥接**：C++ 事件经 JSON 与 SendPort 投递到 Dart，格式与原生 SDK 约定一致，监听器可复用。
- **历史与轮询**：历史在 Dart 侧持久化（MessageHistoryPersistence）；轮询（startPolling）从 C++ 事件队列拉取连接/消息/文件等事件并更新状态。
- **依赖注入**：通过接口注入 Preferences、Logger、Bootstrap、EventBus、ConversationManager 等，不绑定具体客户端。
- **多实例**：支持多 Tox 实例（主要用于测试）；生产环境使用默认单例即可。

---

## 目录结构

| 目录/文件 | 职责 |
|-----------|------|
| `source/` | C++ 核心：V2TIMManagerImpl、V2TIMMessageManagerImpl、ToxManager 等，实现 V2TIM 并对接 c-toxcore。 |
| `include/` | V2TIM 风格 C++ 头文件（API 定义）。 |
| `ffi/` | C FFI：tim2tox_ffi.h/cpp（C API）、dart_compat_*.cpp（Dart* 兼容层）、callback_bridge、json_parser。 |
| `dart/lib/ffi/` | Dart 对 tim2tox_ffi_* 的 FFI 绑定（Tim2ToxFfi）。 |
| `dart/lib/service/` | FfiChatService：init、login、轮询、发送、历史、Stream、多实例注册。 |
| `dart/lib/sdk/` | Tim2ToxSdkPlatform：实现 TencentCloudChatSdkPlatform，将 SDK 调用路由到 FfiChatService。 |
| `dart/lib/interfaces/` | 可注入接口（BootstrapService、LoggerService、ExtendedPreferencesService 等）。 |
| `dart/lib/utils/` | MessageHistoryPersistence 等工具。 |
| `third_party/` | c-toxcore 等依赖。 |
| `doc/` | 架构、API 参考、接入与维护文档。 |
| `auto_tests/` | 自动化集成测试。 |

---

## 两种接入路径与集成步骤

Tim2Tox 支持**二进制替换**（最少改业务、仅换库）与 **Platform / FfiChatService**（历史、轮询、Bootstrap、通话等由 Dart 实现）两种接入方式，可择一或混合使用。路径对比、选择建议与**集成五步**见 [doc/integration/INTEGRATION_OVERVIEW.md](doc/integration/INTEGRATION_OVERVIEW.md)。

**使用 Tim2Tox 的客户端**：当前采用本仓库的示例客户端包括 [toxee](https://github.com/agentx-icu/toxee)（基于 Tox 的 Flutter 聊天客户端，混合架构、接口实现、Bootstrap 与历史等见其项目文档）。

---

## 构建方式

### 最小构建与验证路径

> 详细构建选项、脚本说明与故障排除请统一参考 [README_BUILD.md](README_BUILD.md)。

1. **构建 C++ / FFI 库（推荐，增量编译）**

```bash
# 从仓库根目录执行（在 toxee 中是 third_party/tim2tox/）
./build_ffi.sh
```

产物：`build/ffi/libtim2tox_ffi.dylib`（macOS） / `build/ffi/libtim2tox_ffi.so`（Linux）。注意：`build/source/libtim2tox.a` **不是** `build_ffi.sh` 的产物 —— 它由 `bash build.sh` 生成（详见 [README_BUILD.md](README_BUILD.md)）。

2. **Dart 包**

```bash
cd dart
flutter pub get
```

3. **验证**

- 在依赖本库的 Flutter 工程中引用 `tim2tox_dart`（path 或 发布包），执行 `flutter run` 并完成一次 init → login → 发消息。
- 或运行自动化测试：`cd auto_tests && ./run_tests_ordered.sh`（需先构建 FFI 库；`run_all_tests.sh` 是其兼容入口）。详见 [auto_tests/README.md](auto_tests/README.md)。

---

## 面向维护者的阅读入口

- **架构与边界**：[doc/architecture/ARCHITECTURE.md](doc/architecture/ARCHITECTURE.md) — 分层、调用链、FFI/回调、Bootstrap/轮询、双路径、风险与测试。
- **FFI 与二进制替换**：[doc/architecture/FFI_COMPAT_LAYER.md](doc/architecture/FFI_COMPAT_LAYER.md)、[doc/architecture/BINARY_REPLACEMENT.md](doc/architecture/BINARY_REPLACEMENT.md)。
- **开发与模块**：[doc/development/DEVELOPMENT_GUIDE.md](doc/development/DEVELOPMENT_GUIDE.md)、[doc/architecture/MODULARIZATION.md](doc/architecture/MODULARIZATION.md)。
- **API 与模板**：[doc/api/API_REFERENCE.md](doc/api/API_REFERENCE.md)、[doc/api/API_REFERENCE_TEMPLATE.md](doc/api/API_REFERENCE_TEMPLATE.md)。

---

## 已知限制与边界

- **历史**：消息历史在 Dart 侧（MessageHistoryPersistence），C++ 不落库；拉取历史走 Platform/FfiChatService。
- **多实例**：多 Tox 实例主要用于测试；生产默认单例，不创建 test instance。
- **回调线程**：C++ 回调经 SendPort 投递到 Dart，需在主 isolate 处理 UI/状态。
- **双路径**：混合架构下需避免历史/回调重复（由 BinaryReplacementHistoryHook 与 Platform 分工约定）。
- **平台**：当前构建与测试以 macOS/桌面为主；移动端需自行验证 FFI 库加载与路径。

---

## 文档索引

### 先读哪份文档（建议）

| 角色 | 建议阅读顺序 |
|------|----------------|
| **想理解项目定位的工程师** | 本 README → [doc/architecture/ARCHITECTURE.md](doc/architecture/ARCHITECTURE.md) §1–3（定位、约束、分层）。 |
| **要集成到客户端的开发者** | 本 README（项目定位、两种接入路径、如何集成）→ [doc/architecture/BINARY_REPLACEMENT.md](doc/architecture/BINARY_REPLACEMENT.md) 或 [doc/architecture/ARCHITECTURE.md](doc/architecture/ARCHITECTURE.md) §10（与客户端关系）→ [doc/integration/BOOTSTRAP_AND_POLLING.md](doc/integration/BOOTSTRAP_AND_POLLING.md)（若做 Bootstrap/联网）。 |
| **要改底层实现的维护者** | [doc/architecture/ARCHITECTURE.md](doc/architecture/ARCHITECTURE.md) 全文 → [doc/architecture/FFI_COMPAT_LAYER.md](doc/architecture/FFI_COMPAT_LAYER.md)、[doc/api/API_REFERENCE_TEMPLATE.md](doc/api/API_REFERENCE_TEMPLATE.md) → [doc/development/DEVELOPMENT_GUIDE.md](doc/development/DEVELOPMENT_GUIDE.md)、[doc/architecture/MODULARIZATION.md](doc/architecture/MODULARIZATION.md)。 |

### 按受众分类

| 文档 | 更适合 |
|------|--------|
| 本 README、[ARCHITECTURE](doc/architecture/ARCHITECTURE.md) §1–4、§10、[BINARY_REPLACEMENT](doc/architecture/BINARY_REPLACEMENT.md)、[BOOTSTRAP_AND_POLLING](doc/integration/BOOTSTRAP_AND_POLLING.md) | **接入者**（理解定位、接入方式、集成步骤）。 |
| [ARCHITECTURE](doc/architecture/ARCHITECTURE.md) 全文、[FFI_COMPAT_LAYER](doc/architecture/FFI_COMPAT_LAYER.md)、[API_REFERENCE](doc/api/API_REFERENCE.md)、[API_REFERENCE_TEMPLATE](doc/api/API_REFERENCE_TEMPLATE.md)、[DEVELOPMENT_GUIDE](doc/development/DEVELOPMENT_GUIDE.md)、[MODULARIZATION](doc/architecture/MODULARIZATION.md)、[MULTI_INSTANCE_SUPPORT](doc/development/MULTI_INSTANCE_SUPPORT.md) | **维护者**（实现细节、扩展方式、测试与风险）。 |

### 完整索引入口

- [doc/README.md](doc/README.md) — 文档总索引与推荐阅读路径
- [README_BUILD.md](README_BUILD.md) — 构建说明（唯一入口）

---

## 许可证

本项目采用 GPL-3.0 许可证。详见 [LICENSE](LICENSE) 文件。
