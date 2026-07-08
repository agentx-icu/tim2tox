# Tim2Tox 集成概览

> 本文为接入方单页入口：两种路径对比、选择建议、集成五步与延伸阅读。项目定位与架构图见 [主 README](../README.md)。

---

## 两种接入路径

| 维度 | 二进制替换方案 | Platform / FfiChatService 方案 |
|------|----------------|----------------------------------|
| **做法** | App 启动时 `setNativeLibraryName('tim2tox_ffi')`，SDK 加载 tim2tox 动态库；业务仍通过 `TIMManager.instance` 等调用，底层走 Dart* → V2TIM。 | 设置 `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(ffiService: ffiChatService)`；当 `isCustomPlatform == true` 时，SDK 将配置的方法路由到 Platform，由 FfiChatService 实现。 |
| **适用场景** | 希望**最少改业务代码**、仅替换后端为 Tox；适合快速验证或以“兼容原生调用”为主的客户端。 | 需要**历史消息、轮询、自定义回调、Bootstrap 配置、通话桥**等由 Dart 侧统一实现时；适合完整产品化客户端。 |
| **Dart 改动** | 仅需在 main 中设置库名并保证 FFI 库可用；无需实现 Platform。 | 需构造 FfiChatService、实现注入接口、设置 Platform 实例。 |
| **能力侧重** | 登录、发消息、好友/群组等与原生 SDK 调用方式一致的能力。 | 在上述基础上，补足历史、轮询、会话联动、Bootstrap、通话等需 Dart 状态与持久化的能力。 |

### 接入方式选择表

| 你的目标 | 建议 |
|----------|------|
| 最小改动、仅验证“换 Tox 能跑” | 二进制替换：`setNativeLibraryName('tim2tox_ffi')` + 提供 FFI 库；不设 Platform。 |
| 完整聊天产品（历史、会话、Bootstrap、可选通话） | Platform + FfiChatService：实现接口、创建 FfiChatService、注册 Tim2ToxSdkPlatform；可同时保留二进制替换（混合架构）。 |
| 混合（推荐） | 二进制替换 + Tim2ToxSdkPlatform，历史/轮询/Bootstrap 等走 Platform。 |

---

## 如何集成到客户端（五步）

1. **依赖**：在客户端 `pubspec.yaml` 中增加 `tim2tox_dart`（path 指向本仓库 `dart` 或使用发布版本）。
2. **二进制替换（可选）**：在 `main()` 最早处调用 `setNativeLibraryName('tim2tox_ffi')`，并确保 App 能加载到 `libtim2tox_ffi`（构建产物需放入工程指定位置）。
3. **接口与 FfiChatService**：实现 `ExtendedPreferencesService`、`LoggerService`、`BootstrapService` 等（见 [`dart/lib/interfaces/`](../../dart/lib/interfaces/) 目录与 [API_REFERENCE_DART.md](../api/API_REFERENCE_DART.md)），构造 `FfiChatService` 并 `await ffiService.init()`。
4. **Platform（若用）**：`TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(ffiService: ffiService, ...)`。
5. **UIKit**：按原有方式使用 Tencent Cloud Chat UIKit，登录、发消息、会话列表等会经 Tim2Tox 落到 Tox。

**参考实现**：使用 Tim2Tox 的客户端包括 [toxee](https://github.com/agentx-icu/toxee)；混合架构、接口实现、Bootstrap 与历史等见 [toxee 文档](https://github.com/agentx-icu/toxee)。

---

## 延伸阅读

- [BINARY_REPLACEMENT.md](../architecture/BINARY_REPLACEMENT.md) — 二进制替换原理、配置方式与调用链路
- [API_REFERENCE_DART.md](../api/API_REFERENCE_DART.md) — Dart 包 API（FfiChatService / Tim2ToxSdkPlatform / 接口）
- [BOOTSTRAP_AND_POLLING.md](BOOTSTRAP_AND_POLLING.md) — Bootstrap 节点与轮询（若做联网/启动配置）
- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §10 — 与接入客户端的关系
- [README_BUILD.md](../../README_BUILD.md) — 构建产物与脚本
