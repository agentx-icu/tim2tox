[English](./README.md)

# Tim2Tox 排障索引

本文汇总 Tim2Tox 当前有效的排障入口，覆盖自动化测试失败、native 崩溃与环境问题。历史调查快照和生成式验证日志不再作为长期文档保留。

## 先从哪里开始

- **自动化测试失败、卡住或 flake**：先读 [auto_tests/README.zh-CN.md](../../auto_tests/README.zh-CN.md)，再按其中的故障排除和最佳实践定位。
- **Native 崩溃、FFI 符号问题、callback 崩溃或线程问题**：使用 [auto_tests/DEBUG_NATIVE_CRASH.zh-CN.md](../../auto_tests/DEBUG_NATIVE_CRASH.zh-CN.md) 中的 lldb 流程抓 native 栈。
- **虚拟时钟与 wall-clock 行为不一致**：阅读 [auto_tests/VIRTUAL_CLOCK.zh-CN.md](../../auto_tests/VIRTUAL_CLOCK.zh-CN.md)，理解 test-mode 模型与常见失败模式。

## 当前入口

- [auto_tests/README.zh-CN.md](../../auto_tests/README.zh-CN.md) — 测试套件总入口：运行方式、phase 覆盖、故障排除和最佳实践。
- [auto_tests/DEBUG_NATIVE_CRASH.zh-CN.md](../../auto_tests/DEBUG_NATIVE_CRASH.zh-CN.md) — 用 lldb 抓 native 栈的流程。
- [auto_tests/VIRTUAL_CLOCK.zh-CN.md](../../auto_tests/VIRTUAL_CLOCK.zh-CN.md) — 虚拟时钟模式设计与编写指南。
