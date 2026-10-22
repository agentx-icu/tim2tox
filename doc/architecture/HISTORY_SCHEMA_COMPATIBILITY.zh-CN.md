[English](HISTORY_SCHEMA_COMPATIBILITY.md)

# 历史格式版本兼容

历史文档的 `version` 高于本库支持的版本时，应用必须升级。原文件路径及字节
保持不变；这不是损坏文件，不能被隔离，也不能被视为空会话。

每个会话的串行操作栅栏会在读写、清除或访问归档前检查主文件及备份。批量读取
将 `HistorySchemaNewerThanAppException` 向上传递，包括 `FfiChatService` 启动，
供应用显示升级提示。目录合并在恢复或重写目标前也会检查输入。

没有预先读取的直接保存同样受到保护。不支持版本的失败不重试；普通磁盘失败
保留原有的有限重试和失败通知。用户明确授权的整个存储/账号删除属于独立的破坏操作。

回归测试为 `dart/test/history_schema_downgrade_test.dart`，并结合接入应用的历史
并发和读取恢复测试。此共享 Dart 策略覆盖桌面和移动端；它不能代替存储独占，
也不保护无关进程并发修改同一文件。

GitHub Actions 的 `History persistence` 工作流在 PR 与 master push 时运行
schema 回归、写入失败通知、离线队列与失败消息持久化测试。它使用干净的库检出和
公开 Dart 依赖，不依赖集成方 overrides 或原生 FFI 二进制；格式和静态分析覆盖
schema guard 与其回归文件。该存储检查不代表 SDK/原生集成或安装包行为已验证。
