# Tim2Tox API 支持矩阵
> 语言 / Language: [中文](API_SUPPORT_MATRIX.md) | [English](API_SUPPORT_MATRIX.en.md)

本文档逐接口列出 Tim2Tox 在 Tox P2P 网络上对 V2TIM API 的**真实支持状态**。它面向接入方，回答的不是"接口是否存在/能否编译通过"，而是"调用之后真的发生了什么"。许多 V2TIM 接口为了保持调用签名兼容而存在，但在 Tox 网络上没有对应语义——这类接口在这里被明确标注，避免接入方按腾讯云 IM 的预期去使用它们。

签名与接口清单以 [API_REFERENCE_V2TIM.md](API_REFERENCE_V2TIM.md) 为准；本表的状态结论来自对 `source/V2TIMMessageManagerImpl.cpp` 与 `source/V2TIMGroupManagerImpl.cpp` 的代码审计（含 file:line 证据）。

## 如何阅读本表

- 表头为 `域 | API | 状态 | 说明`。
- "状态"使用下面**状态分类**中的固定取值。
- 行内的 `Impl.cpp:行号` 指向审计时的实现位置；行号随版本会漂移，仅作定位参考。
- **媒体与文件**：不要使用 V2TIM 的 `CreateImageMessage` / `CreateSoundMessage` / `CreateVideoMessage` / `CreateFileMessage` 发送真实文件——它们要么未实现、要么会被降级为纯文本。真实文件/媒体传输请走 Dart 侧 `FfiChatService` 的文件 API（`tim2tox_ffi_send_file` / `tim2tox_ffi_file_control`），见 [API_REFERENCE_FFI.md](API_REFERENCE_FFI.md) 与 [API_REFERENCE_DART.md](API_REFERENCE_DART.md)。

## 状态分类（图例）

| 状态 | 含义 |
| --- | --- |
| **native** | C++ 侧有真实的、走 Tox 网络的语义实现。 |
| **dart-only** | 只能经 Dart 的 `FfiChatService` / Platform 路径 / `MessageHistoryPersistence` 工作，**不**经 C++ 的 V2TIM 接口；直接调 C++ V2TIM 接口拿不到结果。 |
| **local-only** | 调用成功，但只影响本地状态，没有网络副作用（对端无感知）。 |
| **text-degraded** | 被静默转换成一条纯文本消息；接收方收到的是文本，**不是**结构化类型。 |
| **no-op-success** | 返回成功，但实际什么都没做。 |
| **unsupported** | 返回 `ERR_SDK_INTERFACE_NOT_SUPPORT` / `ERR_SDK_NOT_SUPPORTED`。 |

> 注意 `dart-only` 与 `unsupported` 的区别：很多消息查询接口在 C++ 层报"不支持"，但同一能力在 toxee 这类完整接入方里通过 Dart 侧拿得到结果。本表对这些接口同时给出 C++ 状态（`unsupported`）与可用路径（`dart-only`）。

## 认证 / 登录

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Auth | `Login(userID, userSig)` | local-only | **不校验 `userSig`**；`userSig` 仅为兼容 V2TIM 调用签名而保留，被忽略。登录 = 打开/绑定**本地** Tox 身份/profile，**不是**服务器侧鉴权。接入方不得当作认证使用。详见 [API_REFERENCE_V2TIM.md](API_REFERENCE_V2TIM.md) 的"认证与登录语义"。 |
| Auth | `GetLoginStatus()` | local-only | 一旦设置了本地别名即返回 `LOGINED`；反映的是**本地**登录状态，**不是** Tox DHT/网络连通性。真实连通性请监听连接状态回调。 |
| Auth | `Logout()` / `GetLoginUser()` | native | 登出/读取当前本地登录用户。 |

## 消息（`source/V2TIMMessageManagerImpl.cpp`）

### 构造消息

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Message | `CreateTextMessage` | native | 文本消息，真实可用。 |
| Message | `CreateCustomMessage` | native | 自定义消息，真实可用。 |
| Message | `CreateImageMessage` (:154) | unsupported | 记录 "not implemented"，并将消息状态置为 `SEND_FAIL`；不会发出。 |
| Message | `CreateSoundMessage` (:161) | unsupported | 同上，"not implemented" + `SEND_FAIL`。 |
| Message | `CreateVideoMessage` (:168) | unsupported | 同上，"not implemented" + `SEND_FAIL`。 |
| Message | `CreateFileMessage` (:175) | text-degraded | 会构造出 `V2TIMFileElem`，但发送路径**从未**把它接到 Tox 文件传输上；发送时实际降级为纯文本描述。真实文件传输请用 `FfiChatService` 文件 API。 |

### 发送消息

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Message | `SendMessage` — TEXT | native | C2C 文本、群文本，真实走 Tox。 |
| Message | `SendMessage` — CUSTOM | native | C2C 自定义、群自定义，真实走 Tox。 |
| Message | `SendMessage` — IMAGE (:487 switch, :602-689) | text-degraded | 降级为文本 `[转发图片]`。接收方收到文本，不是图片。 |
| Message | `SendMessage` — SOUND | text-degraded | 降级为文本 `[转发语音]`。 |
| Message | `SendMessage` — VIDEO | text-degraded | 降级为文本 `[转发视频]`。 |
| Message | `SendMessage` — FILE | text-degraded | 降级为文本 `[转发文件]`。真实文件请用 `FfiChatService` 文件 API。 |
| Message | `SendMessage` — LOCATION | text-degraded | 降级为文本 `[转发位置]`。 |
| Message | `SendMessage` — FACE | text-degraded | 降级为文本 `[转发表情]`。 |

### 查询 / 历史

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Message | `GetHistoryMessageList` (:828) | dart-only | C++ 层不支持；历史存放在 Dart 的 `MessageHistoryPersistence`，由 Platform/`FfiChatService` 提供。 |
| Message | `FindMessages` (:1084) | dart-only | C++ 层返回空；通过 Dart 侧获取。 |
| Message | `SearchLocalMessages` (:1121) | dart-only | C++ 层返回空；通过 Dart 侧获取。 |
| Message | `SearchCloudMessages` (:1142) | unsupported | Tox 无云端，返回不支持。 |

### 已读 / 回执

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Message | `MarkC2CMessageAsRead` (:1155) | no-op-success | 返回成功，无网络副作用。 |
| Message | `MarkGroupMessageAsRead` (:1160) | no-op-success | 同上。 |
| Message | `MarkAllMessageAsRead` (:1170) | no-op-success | 同上。 |
| Message | `SendMessageReadReceipts` (:1143) | unsupported | |
| Message | `GetMessageReadReceipts` (:1144) | unsupported | |
| Message | `GetGroupMessageReadMemberList` (:1145) | unsupported | |

### 修改 / 接收选项

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Message | `ModifyMessage` (:927) | unsupported | |
| Message | `SetAllReceiveMessageOpt` (:824) | unsupported | |
| Message | `GetAllReceiveMessageOpt` (:826) | unsupported | |

### 扩展 / 表态 / 翻译 / 置顶 / 合并

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Message | `SetMessageExtensions` (:1173) | unsupported | |
| Message | `GetMessageExtensions` (:1174) | unsupported | |
| Message | `DeleteMessageExtensions` (:1175) | unsupported | |
| Message | `AddMessageReaction` (:1176) | unsupported | |
| Message | `RemoveMessageReaction` (:1177) | unsupported | |
| Message | `GetMessageReactions` (:1178) | unsupported | |
| Message | `GetAllUserListOfMessageReaction` (:1179) | unsupported | |
| Message | `TranslateText` (:1180) | unsupported | |
| Message | `PinGroupMessage` (:1181) | unsupported | |
| Message | `GetPinnedGroupMessageList` (:1182) | unsupported | |
| Message | `DownloadMergerMessage` (:1183) | unsupported | |

## 群组（`source/V2TIMGroupManagerImpl.cpp`）

### 群与成员（真实实现）

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Group | `CreateGroup` | native | 真实创建群（`tox_group_new` / `tox_conference_new`）。 |
| Group | `JoinGroup` | native | 真实加群（挂在 `V2TIMManager` 上）。 |
| Group | `QuitGroup` | native | 真实退群（挂在 `V2TIMManager` 上）。 |
| Group | `InviteUserToGroup` (:2549) | native | 真实实现。 |
| Group | `KickGroupMember` (:2869 / :3047) | native | 真实实现。 |
| Group | `SetGroupMemberRole` (:3057) | native | 真实实现。 |
| Group | `TransferGroupOwner` (:3179) | native | 真实实现。 |
| Group | `GetGroupMemberList` (:1495) | native | 真实实现。 |
| Group | 群在线成员数 | partial / unreliable | `ToxManager::getGroupPeerCount` 当前不可靠；在线人数可能不准。请勿据此做强一致判断。 |

### 禁言

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Group | `MuteGroupMember` (:2535) | no-op-success | 返回成功，但 Tox 没有定时禁言机制，实际不生效。 |
| Group | `MuteAllGroupMembers` (:2546) | unsupported | |

### 搜索

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Group | `SearchGroupMembers` (:2383) | unsupported | |
| Group | `SearchCloudGroupMembers` (:2388) | unsupported | |
| Group | `SearchCloudGroups` (:1300) | unsupported | Tox 无云端群目录。 |

### 群属性 / 计数器

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Group | `InitGroupAttributes` (:1445) | unsupported | |
| Group | `SetGroupAttributes` (:1451) | unsupported | |
| Group | `DeleteGroupAttributes` (:1456) | unsupported | |
| Group | `GetGroupAttributes` (:1461) | unsupported | |
| Group | `SetGroupCounters` (:1476) | unsupported | |
| Group | `GetGroupCounters` (:1481) | unsupported | |
| Group | `IncreaseGroupCounter` (:1486) | unsupported | |
| Group | `DecreaseGroupCounter` (:1491) | unsupported | |

### 入群申请 / 成员标记

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Group | `GetGroupApplicationList` (:3278) | unsupported | |
| Group | `AcceptGroupApplication` (:3284) | unsupported | |
| Group | `RefuseGroupApplication` (:3288) | unsupported | |
| Group | `SetGroupApplicationRead` (:3292) | unsupported | |
| Group | `MarkGroupMemberList` (:3176) | unsupported | |

### 社区 / 话题

| 域 | API | 状态 | 说明 |
| --- | --- | --- | --- |
| Community | `GetJoinedCommunityList` (:3297) | unsupported | |
| Community | `CreateTopicInCommunity` (:3303) | unsupported | |
| Community | `DeleteTopicFromCommunity` (:3308) | unsupported | |
| Community | `SetTopicInfo` (:3312) | unsupported | |
| Community | `GetTopicInfoList` (:3316) | unsupported | |

## 相关文档

- [API_REFERENCE_V2TIM.md](API_REFERENCE_V2TIM.md) — V2TIM C++ 接口签名与 tim2tox 行为说明
- [API_REFERENCE_FFI.md](API_REFERENCE_FFI.md) — C FFI 接口（文件传输 `tim2tox_ffi_send_file` / `tim2tox_ffi_file_control` 在此）
- [API_REFERENCE_DART.md](API_REFERENCE_DART.md) — Dart 包 API（`FfiChatService` 文件与历史接口）
- [API_REFERENCE.md](API_REFERENCE.md) — 总索引、数据类型、错误码、示例
