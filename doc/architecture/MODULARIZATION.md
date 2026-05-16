# Tim2Tox FFI 层模块化
> 语言 / Language: [中文](MODULARIZATION.md) | [English](MODULARIZATION.en.md)

## 概述

`Dart*` 兼容层（被 Binary Replacement 路径中的 `NativeLibraryManager` 动态查找）历史上是一个单文件，后来按职责拆分为 **13 个 `.cpp` 模块 + 2 个共享头**。本文档记录每个模块的职责和当前规模。

> 行数为撰写时实测（`wc -l ffi/dart_compat_*.{cpp,h}`），会随实现增改而漂移；如果差异较大请直接以 `wc -l` 输出为准并更新本表。

## 模块结构

### 基础架构模块

#### dart_compat_internal.h
- **职责**: 共享声明和前置声明（全局变量 extern、工具函数、Listener / Callback 类前置声明、统一头文件包含）
- **行数**: ~157

#### dart_compat_utils.cpp
- **职责**: 工具函数和全局变量。包括 `StoreCallbackUserData` / `GetCallbackUserData` / `UserDataToString` / `SafeGetV2TIMManager` / `CStringToString` / `SendApiCallbackResult*` / `ParseJsonConfig` / `SafeGetCString` / `ConversationVectorToJson` 等。
- **行数**: ~576

### 监听器和回调模块

#### dart_compat_listeners.cpp
- **职责**: 所有 `*ListenerImpl` 与 `DartSet*Callback` 注册函数。
  - `DartSDKListenerImpl`、`DartAdvancedMsgListenerImpl`、`DartConversationListenerImpl`、`DartGroupListenerImpl`、`DartFriendshipListenerImpl`、`DartSignalingListenerImpl`、`DartCommunityListenerImpl`
  - ~65 个 `DartSet*Callback` 回调注册函数
- **行数**: ~2800

#### dart_compat_callbacks.cpp
- **职责**: `Dart*Callback` 系列回调类与 JSON 序列化辅助函数（`MessageVectorToJson`、`FriendInfoVectorToJson`、`ConversationResultToJson`、`GroupInfoVectorToJson`、`FriendOperationResultToJson`、`FriendOperationResultVectorToJson`、`FriendInfoResultVectorToJson` 等）。
- **行数**: ~965

### 功能模块

#### dart_compat_sdk.cpp
- **职责**: SDK 初始化与认证。`DartInitSDK(uint64_t sdk_app_id, const char* json_sdk_config)`、`DartUnitSDK`、`DartGetSDKVersion`、`DartGetServerTime`、`DartSetConfig`、`DartLogin(const char* user_id, const char* user_sig, void* user_data)`、`DartLogout`、`DartGetLoginUserID`。
- **行数**: ~177

> `DartGetLoginStatus` 实现在 `dart_compat_user.cpp` 而不是 sdk.cpp。

#### dart_compat_message.cpp
- **职责**: 消息发送 / 查询 / 撤回 / 修改 / 删除 / 历史 / 已读标记 / 本地自定义数据 / 元素下载等。包含 `DartSendMessage`、`DartFindMessages`、`DartRevokeMessage`、`DartModifyMessage`、`DartDeleteMessages`、`DartClearHistoryMessage`、`DartGetHistoryMessageList`、`DartGetMessageList`、`DartMarkAllMessageAsRead` / `DartMarkC2CMessageAsRead` / `DartMarkGroupMessageAsRead`、`DartSetLocalCustomData`、`DartDownloadElemToPath`、`DartDownloadMergerMessage` 等。
- **行数**: ~1732

#### dart_compat_friendship.cpp
- **职责**: 好友 CRUD、好友申请、好友资料、黑名单。`DartGetFriendList`、`DartAddFriend`、`DartDeleteFromFriendList`、`DartGetFriendsInfo`、`DartSetFriendInfo`、`DartGetFriendApplicationList`、`DartAcceptFriendApplication`、`DartRefuseFriendApplication`、`DartCheckFriend`、`DartAddToBlackList`、`DartDeleteFromBlackList`、`DartGetBlackList`、`DartSetFriendApplicationRead` 等。
- **行数**: ~934

#### dart_compat_conversation.cpp
- **职责**: 会话查询 / 删除 / 置顶 / 草稿 / 标记 / 自定义数据 / 会话分组。`DartGetConversationList`、`DartGetConversation`、`DartDeleteConversation`、`DartSetConversationDraft`、`DartCancelConversationDraft`、`DartPinConversation`、`DartMarkConversation`、`DartGetTotalUnreadMessageCount`、`DartGetUnreadMessageCountByFilter`、`DartGetConversationListByFilter`、`DartSetConversationCustomData`、`DartCreateConversationGroup`、`DartDeleteConversationGroup`、`DartRenameConversationGroup`、`DartGetConversationGroupList`、`DartAddConversationsToGroup`、`DartDeleteConversationsFromGroup`。
- **行数**: ~690

#### dart_compat_group.cpp
- **职责**: 群组生命周期、群成员、群属性、群计数器、群搜索。`DartCreateGroup`、`DartJoinGroup`、`DartQuitGroup`、`DartDeleteGroup`、`DartGetJoinedGroupList`、`DartGetGroupsInfo`、`DartSetGroupInfo`、`DartGetGroupMemberList`、`DartGetGroupMembersInfo`、`DartInviteUserToGroup`、`DartKickGroupMember`、`DartModifyGroupMemberInfo`、`DartSetGroupAttributes` / `DartGetGroupAttributes` / `DartInitGroupAttributes` / `DartDeleteGroupAttributes`、`DartSetGroupCounters` / `DartGetGroupCounters` / `DartIncreaseGroupCounter` / `DartDecreaseGroupCounter`、`DartSearchGroups` 等。
- **行数**: ~1818

> 部分被 V2TIM 抽象类列出的群方法（如 `DartGetOnlineMemberCount`、`DartMarkGroupMemberList`、`DartGetGroupPendencyList`、`DartHandleGroupPendency`、`DartSearchCloudGroups`、`DartSearchCloudGroupMembers`）目前没有实现 —— 如果业务侧调用会走到 SDK 默认行为。`Dart*` 实现以本模块的 `extern "C"` 块为准（用 `grep -hE '^\\s*(int|void|const char\\*) Dart[A-Z]' ffi/dart_compat_group.cpp` 列举）。

#### dart_compat_user.cpp
- **职责**: 用户信息、订阅、状态、登录状态、消息接收选项。`DartGetUsersInfo`、`DartSetSelfInfo`、`DartSubscribeUserInfo`、`DartUnsubscribeUserInfo`、`DartGetUserStatus`、`DartSetSelfStatus`、`DartSetC2CReceiveMessageOpt` / `DartGetC2CReceiveMessageOpt`、`DartSetAllReceiveMessageOpt` / `DartGetAllReceiveMessageOpt`、`DartGetLoginStatus`。
- **行数**: ~765

#### dart_compat_signaling.cpp
- **职责**: 信令邀请 / 修改 / 取消 / 接受 / 拒绝。`DartInvite`、`DartInviteInGroup`、`DartGetSignalingInfo`、`DartModifyInvitation`、`DartCancel`（邀请）、`DartAccept`、`DartReject`。
- **行数**: ~576

#### dart_compat_community.cpp
- **职责**: 社区 / 话题 / 权限组（占位）
- **状态**: 当前为占位（仅头文件 include + extern "C" 空块）；社区相关 `Dart*` 尚未实现
- **行数**: ~14

#### dart_compat_other.cpp
- **职责**: 其他杂项 —— 主要是 `DartCallExperimentalAPI`
- **状态**: `DartCallExperimentalAPI` **已实现**，处理 `set_ui_platform`、`set_network_info`、`write_log`、`is_commercial_ability_enabled` 这几种内部操作；其余实验性 API 走 fallback（return success）。
- **行数**: ~98

### 主入口文件

#### dart_compat_layer.cpp
- **职责**: 历史上的"主入口"，现已退化为说明性文件 —— 只有注释和 include，无 `Dart*` 实现。
- **行数**: 28

## 模块依赖关系

```
dart_compat_internal.h (共享头文件)
    ↑
    ├── dart_compat_utils.cpp
    ├── dart_compat_listeners.cpp
    ├── dart_compat_callbacks.cpp
    ├── dart_compat_sdk.cpp
    ├── dart_compat_message.cpp
    ├── dart_compat_friendship.cpp
    ├── dart_compat_conversation.cpp
    ├── dart_compat_group.cpp
    ├── dart_compat_user.cpp
    ├── dart_compat_signaling.cpp
    ├── dart_compat_community.cpp (占位)
    ├── dart_compat_other.cpp
    └── dart_compat_layer.cpp (说明，无业务逻辑)
```

## 代码统计（snapshot）

| 模块 | 行数 | 状态 |
|------|------|------|
| dart_compat_internal.h | ~157 | ✅ |
| dart_compat_utils.cpp | ~576 | ✅ |
| dart_compat_listeners.cpp | ~2800 | ✅ |
| dart_compat_callbacks.cpp | ~965 | ✅ |
| dart_compat_sdk.cpp | ~177 | ✅ |
| dart_compat_message.cpp | ~1732 | ✅ |
| dart_compat_friendship.cpp | ~934 | ✅ |
| dart_compat_conversation.cpp | ~690 | ✅ |
| dart_compat_group.cpp | ~1818 | ✅ |
| dart_compat_user.cpp | ~765 | ✅ |
| dart_compat_signaling.cpp | ~576 | ✅ |
| dart_compat_community.cpp | ~14 | ⏳ 占位 |
| dart_compat_other.cpp | ~98 | ✅ |
| dart_compat_layer.cpp | 28 | ℹ️ 仅注释 |
| **总计** | **~11,330** | — |

> 重新统计：`wc -l ffi/dart_compat_*.{cpp,h}`

## 模块化优势

1. **可维护性**: 每个模块专注于特定功能。
2. **编译效率**: 修改单个模块只需重新编译该模块。
3. **代码组织**: 相关 `Dart*` 集中在一起。
4. **团队协作**: 多人并行开发互不冲突。
5. **测试友好**: 每个模块可独立测试。

## 开发指南

### 添加新函数

1. **确定模块**: 根据职责决定加入哪个 `.cpp`。
2. **添加实现**: 在该模块文件的 `extern "C"` 块中实现。
3. **更新文档**: 更新本文档的函数列表或本模块条目。
4. **匹配 Dart 端**: 确保签名与 patched 后的 `native_imsdk_bindings_generated.dart` 一致（这是 ABI），改动需要双侧同步。
5. **写作规范**: 见 [doc/api/API_REFERENCE_TEMPLATE.md](../api/API_REFERENCE_TEMPLATE.md)。

### 修改现有函数

1. **定位模块**: `grep -rn 'Dart<Name>' ffi/dart_compat_*.cpp`。
2. **修改实现**: 在对应模块文件中。
3. **测试验证**: `auto_tests/scenarios_binary/` 是 binary-replacement 路径的回归套件。

### 添加新模块

1. 创建 `dart_compat_<module>.cpp`，`#include "dart_compat_internal.h"`，`extern "C" { ... }`。
2. 在 `ffi/CMakeLists.txt` 的源文件列表中加入新文件。
3. 在 `dart_compat_layer.cpp` 的注释里登记。

## 相关文档

- [Tim2Tox FFI 兼容层](FFI_COMPAT_LAYER.md) — Dart* 兼容层详细说明
- [Tim2Tox 架构](ARCHITECTURE.md) — 整体架构
- [开发指南](../development/DEVELOPMENT_GUIDE.md)
- [FFI 函数声明指南](../development/FFI_FUNCTION_DECLARATION_GUIDE.md)
