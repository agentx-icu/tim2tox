# Tim2Tox 文档
> 语言 / Language: [中文](README.md) | [English](README.en.md)

## 推荐阅读路径（按角色）

- **新读者（先理解 Tim2Tox 是什么）**：先读 [主 README](../README.md) → 再读 [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) §1–3 → 按需回到本页继续深入
- **接入方（要集成到客户端）**：先读 [主 README](../README.md) 的“两种接入路径与集成步骤” → 再读 [integration/INTEGRATION_OVERVIEW.md](integration/INTEGRATION_OVERVIEW.md)（路径对比与五步）→ 按需 [architecture/BINARY_REPLACEMENT.md](architecture/BINARY_REPLACEMENT.md)、[architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) §10、[integration/BOOTSTRAP_AND_POLLING.md](integration/BOOTSTRAP_AND_POLLING.md) → 构建见 [README_BUILD.md](../README_BUILD.md)
- **维护者（要改底层/扩展功能）**：先读 [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) 全文 → 再读 [architecture/FFI_COMPAT_LAYER.md](architecture/FFI_COMPAT_LAYER.md)、[architecture/BINARY_REPLACEMENT.md](architecture/BINARY_REPLACEMENT.md) → API/写作规范见 [api/API_REFERENCE.md](api/API_REFERENCE.md)、[api/API_REFERENCE_TEMPLATE.md](api/API_REFERENCE_TEMPLATE.md) → 开发与规则见 [development/DEVELOPMENT_GUIDE.md](development/DEVELOPMENT_GUIDE.md)、[architecture/MODULARIZATION.md](architecture/MODULARIZATION.md)、[development/FFI_FUNCTION_DECLARATION_GUIDE.md](development/FFI_FUNCTION_DECLARATION_GUIDE.md)

## 构建、测试与排障入口

- **构建说明（唯一入口）**：[README_BUILD.md](../README_BUILD.md)
- **排障索引（入口页）**：[troubleshooting/README.md](troubleshooting/README.md)
- **自动化测试**：[auto_tests/README.md](../auto_tests/README.md)
- **Native 崩溃排障**：[auto_tests/DEBUG_NATIVE_CRASH.md](../auto_tests/DEBUG_NATIVE_CRASH.md)
- **回归基线**：[auto_tests/VALIDATION_RESULTS.md](../auto_tests/VALIDATION_RESULTS.md)（最近一次全量回归的通过/失败快照）

## 维护入口

- [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) - 整体架构（深度技术参考）：分层职责、调用链、FFI/回调/双路径、Bootstrap 与轮询、风险与测试
- [api/API_REFERENCE.md](api/API_REFERENCE.md) - V2TIM、FFI 与 Dart 层 API 参考（子页：[V2TIM](api/API_REFERENCE_V2TIM.md)、[FFI](api/API_REFERENCE_FFI.md)、[Dart](api/API_REFERENCE_DART.md)）
- [api/API_REFERENCE_TEMPLATE.md](api/API_REFERENCE_TEMPLATE.md) - API 参考文档写作模板（条目结构、分类与标记约定）
- [development/DEVELOPMENT_GUIDE.md](development/DEVELOPMENT_GUIDE.md) - 开发流程、构建、测试与调试建议
- [architecture/MODULARIZATION.md](architecture/MODULARIZATION.md) - FFI 模块拆分结构与模块职责

## 接入（集成方单页入口）

- [integration/INTEGRATION_OVERVIEW.md](integration/INTEGRATION_OVERVIEW.md) - 两种路径对比、选择建议、集成五步与延伸阅读

## 核心机制

- [architecture/BINARY_REPLACEMENT.md](architecture/BINARY_REPLACEMENT.md) - 动态库替换方案与调用链路
- [architecture/FFI_COMPAT_LAYER.md](architecture/FFI_COMPAT_LAYER.md) - Dart 兼容层回调机制、JSON 格式与实现状态
- [integration/RESTORE_AND_PERSISTENCE.md](integration/RESTORE_AND_PERSISTENCE.md) - 持久化与恢复流程
- [integration/TOXAV_AND_SIGNALING.md](integration/TOXAV_AND_SIGNALING.md) - ToxAV、signaling、TUICallKit 与实例路由
- [integration/BOOTSTRAP_AND_POLLING.md](integration/BOOTSTRAP_AND_POLLING.md) - Bootstrap 节点加载、联网建立与 poll loop

## 兼容性与专题

- [development/MULTI_INSTANCE_SUPPORT.md](development/MULTI_INSTANCE_SUPPORT.md) - 多实例支持场景与 API
- [development/FFI_FUNCTION_DECLARATION_GUIDE.md](development/FFI_FUNCTION_DECLARATION_GUIDE.md) - FFI 函数声明规则与自检清单
- `isCustomPlatform` 路由行为见 [architecture/BINARY_REPLACEMENT.md](architecture/BINARY_REPLACEMENT.md) 与 SDK 源码，无独立排障页。
- [architecture/PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.md](architecture/PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.md) - 二进制替换下 Platform 与 V2TIM 关系分析

## 示例客户端

- [主 README](../README.md)
- 使用 Tim2Tox 的客户端包括 [toxee](https://github.com/anonymoussoft/toxee)。其文档与账号/会话说明见 [toxee 仓库](https://github.com/anonymoussoft/toxee)；当 Tim2Tox 作为 submodule 被使用时，也可在上层仓库的 `doc/` 中查看。
