# Tim2Tox API 参考 — V2TIM C++
> 语言 / Language: [中文](API_REFERENCE_V2TIM.md) | [English](API_REFERENCE_V2TIM.en.md)

本文档是 [API_REFERENCE.md](API_REFERENCE.md) 的 V2TIM C++ 分册。所有签名以 `include/V2TIM*.h` 为准；下面只列出常用接口，未列出的方法（标 "未覆盖" 的类别）请直接查阅头文件。

## V2TIM C++ API

Tim2Tox 在 C++ 侧实现了 V2TIM 的核心方法，与腾讯云 IM SDK 的同名接口保持二进制/语义兼容（参见 `source/V2TIMManagerImpl.*` 等实现）。

### V2TIMManager

核心管理器，提供 SDK 初始化、登录登出、获取其他管理器。

**头文件**：`include/V2TIMManager.h`

#### 初始化与版本

```cpp
// 单例
static V2TIMManager* GetInstance();

// 初始化 / 反初始化
virtual bool InitSDK(uint32_t sdkAppID, const V2TIMSDKConfig& config) = 0;
virtual void UnInitSDK() = 0;

// 版本与服务器时间
virtual V2TIMString GetVersion() = 0;
virtual int64_t     GetServerTime() = 0;
```

#### 监听器

```cpp
virtual void AddSDKListener(V2TIMSDKListener* listener) = 0;
virtual void RemoveSDKListener(V2TIMSDKListener* listener) = 0;
```

#### 登录登出

```cpp
virtual void        Login(const V2TIMString& userID, const V2TIMString& userSig, V2TIMCallback* callback) = 0;
virtual void        Logout(V2TIMCallback* callback) = 0;
virtual V2TIMString GetLoginUser() = 0;
```

#### 认证与登录语义（务必阅读）

Tim2Tox 跑在 Tox P2P 网络上，没有腾讯云 IM 那样的鉴权服务器。登录语义因此与 V2TIM 有本质区别：

- **`Login(userID, userSig)` 不校验 `userSig`**。`userSig` 仅为兼容 V2TIM 的调用签名而保留，会被忽略。登录的真实含义是**打开/绑定本地 Tox 身份/profile**，**不是**服务器侧鉴权。接入方**不得**把 `Login` 成功当作"用户已通过认证"。
- **`GetLoginStatus()` 反映的是本地登录状态，不是网络连通性**。一旦设置了本地别名，它就会返回 `LOGINED`——这只表示本地 profile 已打开，**不**代表已接入 Tox DHT/已联网。要判断真实连通性，请监听连接状态回调（connection-status listener/callback），不要依赖 `GetLoginStatus()`。

逐接口状态见 [API_SUPPORT_MATRIX.md](API_SUPPORT_MATRIX.md) 的"认证 / 登录"小节。

#### 子管理器入口

```cpp
virtual V2TIMMessageManager*      GetMessageManager() = 0;
virtual V2TIMGroupManager*        GetGroupManager() = 0;
virtual V2TIMConversationManager* GetConversationManager() = 0;
virtual V2TIMFriendshipManager*   GetFriendshipManager() = 0;
virtual V2TIMSignalingManager*    GetSignalingManager() = 0;
virtual V2TIMCommunityManager*    GetCommunityManager() = 0;
virtual V2TIMOfflinePushManager*  GetOfflinePushManager() = 0;
```

#### 群组（直接挂在 Manager 上的快捷方法）

```cpp
virtual void JoinGroup(const V2TIMString& groupID, const V2TIMString& message, V2TIMCallback* callback) = 0;
virtual void QuitGroup(const V2TIMString& groupID, V2TIMCallback* callback) = 0;
virtual void DismissGroup(const V2TIMString& groupID, V2TIMCallback* callback) = 0;
```

> 注意 `JoinGroup` / `QuitGroup` / `DismissGroup` 直接挂在 `V2TIMManager` 上，**不在** `V2TIMGroupManager` 接口里。

### V2TIMMessageManager

消息管理器：消息构造、发送、查询、读已读、撤回。

**头文件**：`include/V2TIMMessageManager.h`

#### 监听器

```cpp
virtual void AddAdvancedMsgListener(V2TIMAdvancedMsgListener* listener) = 0;
virtual void RemoveAdvancedMsgListener(V2TIMAdvancedMsgListener* listener) = 0;
```

#### 创建消息

```cpp
virtual V2TIMMessage CreateTextMessage(const V2TIMString& text) = 0;
virtual V2TIMMessage CreateCustomMessage(const V2TIMBuffer& data) = 0;
virtual V2TIMMessage CreateCustomMessage(const V2TIMBuffer& data,
                                         const V2TIMString& description,
                                         const V2TIMString& extension) = 0;
virtual V2TIMMessage CreateImageMessage(const V2TIMString& imagePath) = 0;
virtual V2TIMMessage CreateSoundMessage(const V2TIMString& soundPath, uint32_t duration) = 0;
virtual V2TIMMessage CreateVideoMessage(const V2TIMString& videoFilePath,
                                        const V2TIMString& type,
                                        uint32_t duration,
                                        const V2TIMString& snapshotPath) = 0;
virtual V2TIMMessage CreateFileMessage(const V2TIMString& filePath, const V2TIMString& fileName) = 0;
virtual V2TIMMessage CreateLocationMessage(const V2TIMString& desc, double longitude, double latitude) = 0;
virtual V2TIMMessage CreateFaceMessage(uint32_t index, const V2TIMBuffer& data) = 0;
virtual V2TIMMessage CreateMergerMessage(const V2TIMMessageVector& messageList,
                                         const V2TIMString& title,
                                         const V2TIMStringVector& abstractList,
                                         const V2TIMStringVector& compatibleText) = 0;
```

> **媒体消息注意（务必阅读）**：`CreateImageMessage` / `CreateSoundMessage` / `CreateVideoMessage` **未实现**——调用后会把消息状态置为 `SEND_FAIL`（不会发出）。`CreateFileMessage` 以及 LOCATION / FACE 等媒体/位置/表情类型在**发送时会被降级为一条纯文本描述**（例如 `[转发文件]`），接收方收到的是文本，**不是**结构化消息。真实文件传输请改用 `FfiChatService` 文件 API（`tim2tox_ffi_send_file` / `tim2tox_ffi_file_control`）。逐接口的真实状态见 [API_SUPPORT_MATRIX.md](API_SUPPORT_MATRIX.md)。

#### 发送消息

```cpp
// 真实签名：返回 V2TIMString（msgID），参数顺序为 receiver, groupID, priority, onlineUserOnly, offlinePushInfo, callback
// 头文件位置：include/V2TIMMessageManager.h:235
virtual V2TIMString SendMessage(V2TIMMessage& message,
                                const V2TIMString& receiver,
                                const V2TIMString& groupID,
                                V2TIMMessagePriority priority,
                                bool onlineUserOnly,
                                const V2TIMOfflinePushInfo& offlinePushInfo,
                                V2TIMSendCallback* callback) = 0;
```

> **C2C** 传 `receiver=<对端 userID>`，`groupID=V2TIMString()`；**群消息**传 `receiver=V2TIMString()`，`groupID=<群 ID>`。`SendMessage` 没有"带 `cloudCustomData` 的重载" —— 直接在 `message.cloudCustomData` 上设置即可。

#### 消息查询

```cpp
virtual void FindMessages(const V2TIMStringVector& messageIDList,
                          V2TIMValueCallback<V2TIMMessageVector>* callback) = 0;

// 真实签名：通过单个 option 结构传所有参数，回调返回 V2TIMMessageVector
virtual void GetHistoryMessageList(const V2TIMMessageListGetOption& option,
                                   V2TIMValueCallback<V2TIMMessageVector>* callback) = 0;
```

> `V2TIMMessageListGetOption` 在 `include/V2TIMMessage.h` 中定义，包含 `userID` / `groupID` / `lastMsg` / `getType` / `count` 等字段。tim2tox 实际历史读取走 Dart 侧的 `MessageHistoryPersistence`，C++ 层调用最终由 Platform/FfiChatService 拦截。

#### 消息操作

```cpp
virtual void RevokeMessage(const V2TIMMessage& message, V2TIMCallback* callback) = 0;

// 已读标记：**没有** MarkMessageAsRead 这一个统一接口，分三个：
virtual void MarkC2CMessageAsRead(const V2TIMString& userID, V2TIMCallback* callback) = 0;
virtual void MarkGroupMessageAsRead(const V2TIMString& groupID, V2TIMCallback* callback) = 0;
virtual void MarkAllMessageAsRead(V2TIMCallback* callback) = 0;

// 删除消息：参数是 V2TIMMessageVector，而不是 ID 字符串列表
virtual void DeleteMessages(const V2TIMMessageVector& messages, V2TIMCallback* callback) = 0;
```

#### 未覆盖（请直接查头文件）

`ModifyMessage`、`ClearC2CHistoryMessage`、`ClearGroupHistoryMessage`、`InsertC2CMessageToLocalStorage`、`InsertGroupMessageToLocalStorage`、`SendMessageReadReceipts`、`GetMessageReadReceipts`、`GetGroupMessageReadMemberList`、`SetC2CReceiveMessageOpt`、`GetC2CReceiveMessageOpt` 等读已读/消息修改/接收选项相关接口未在本文档展开。

### V2TIMFriendshipManager

好友管理器。

**头文件**：`include/V2TIMFriendshipManager.h`

#### 监听器

```cpp
virtual void AddFriendListener(V2TIMFriendshipListener* listener) = 0;
virtual void RemoveFriendListener(V2TIMFriendshipListener* listener) = 0;
```

#### 好友列表 / 资料

```cpp
virtual void GetFriendList(V2TIMValueCallback<V2TIMFriendInfoVector>* callback) = 0;
virtual void GetFriendsInfo(const V2TIMStringVector& userIDList,
                            V2TIMValueCallback<V2TIMFriendInfoResultVector>* callback) = 0;
virtual void SetFriendInfo(const V2TIMFriendInfo& info, V2TIMCallback* callback) = 0;
```

#### 好友操作

```cpp
virtual void AddFriend(const V2TIMFriendAddApplication& application,
                       V2TIMValueCallback<V2TIMFriendOperationResult>* callback) = 0;
virtual void DeleteFromFriendList(const V2TIMStringVector& userIDList,
                                  V2TIMFriendType deleteType,
                                  V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) = 0;
virtual void CheckFriend(const V2TIMStringVector& userIDList,
                         V2TIMFriendType checkType,
                         V2TIMValueCallback<V2TIMFriendCheckResultVector>* callback) = 0;
```

#### 好友申请

```cpp
virtual void GetFriendApplicationList(V2TIMValueCallback<V2TIMFriendApplicationResult>* callback) = 0;

// 真实枚举是 V2TIMFriendAcceptType（不是 V2TIMFriendResponseType）。两个重载：带 / 不带 remark。
virtual void AcceptFriendApplication(const V2TIMFriendApplication& application,
                                     V2TIMFriendAcceptType acceptType,
                                     V2TIMValueCallback<V2TIMFriendOperationResult>* callback) = 0;
virtual void AcceptFriendApplication(const V2TIMFriendApplication& application,
                                     V2TIMFriendAcceptType acceptType,
                                     const V2TIMString& remark,
                                     V2TIMValueCallback<V2TIMFriendOperationResult>* callback) = 0;

virtual void RefuseFriendApplication(const V2TIMFriendApplication& application,
                                     V2TIMValueCallback<V2TIMFriendOperationResult>* callback) = 0;
```

#### 未覆盖

`DeleteFriendApplication`、`SetFriendApplicationRead`、`AddToBlackList` / `DeleteFromBlackList` / `GetBlackList`、`CreateFriendGroup` 系列等。

### V2TIMGroupManager

群组管理器。

**头文件**：`include/V2TIMGroupManager.h`

> 注意：`JoinGroup` / `QuitGroup` / `DismissGroup` 不在本接口里，挂在 [V2TIMManager](#v2timmanager) 上。

#### 监听器

```cpp
virtual void AddGroupListener(V2TIMGroupListener* listener) = 0;
virtual void RemoveGroupListener(V2TIMGroupListener* listener) = 0;
```

#### 群操作

```cpp
virtual void CreateGroup(const V2TIMGroupInfo& info,
                         const V2TIMCreateGroupMemberInfoVector& memberList,
                         V2TIMValueCallback<V2TIMString>* callback) = 0;

virtual void GetJoinedGroupList(V2TIMValueCallback<V2TIMGroupInfoVector>* callback) = 0;
virtual void GetGroupsInfo(const V2TIMStringVector& groupIDList,
                           V2TIMValueCallback<V2TIMGroupInfoResultVector>* callback) = 0;
virtual void SetGroupInfo(const V2TIMGroupInfo& info, V2TIMCallback* callback) = 0;
```

**tim2tox 行为说明**（实现在 `V2TIMGroupManagerImpl.cpp`）：

- `info.groupType`：`"group"`（新 API，`tox_group_new`，支持 `chat_id` 持久化，推荐）/ `"conference"`（旧 API，`tox_conference_new`，仅 savedata 恢复，仅做兼容性留存）。不指定时默认 `"group"`。
- `info.groupID`：可选，未提供时自动生成 `tox_<id>` 形式。
- `groupType` 总会被写入持久化存储；`"group"` 类型还会写入 `chat_id`。
- `GetGroupsInfo` 返回的 `V2TIMGroupInfo.notification` 取自 `tox_group_get_topic`，**仅 Group 类型**有意义。

#### 群成员

```cpp
// filter 是 uint32_t（V2TIMGroupMemberFilter 的位掩码值或自定义标记），nextSeq 是 uint64_t
virtual void GetGroupMemberList(const V2TIMString& groupID,
                                uint32_t filter,
                                uint64_t nextSeq,
                                V2TIMValueCallback<V2TIMGroupMemberInfoResult>* callback) = 0;

// memberList 是按值传递（V2TIMStringVector），不是 const&
virtual void GetGroupMembersInfo(const V2TIMString& groupID,
                                 V2TIMStringVector memberList,
                                 V2TIMValueCallback<V2TIMGroupMemberFullInfoVector>* callback) = 0;

// 修改群成员：info 携带要改的字段（userID 在 info.userID 上，没有独立参数）
virtual void SetGroupMemberInfo(const V2TIMString& groupID,
                                const V2TIMGroupMemberFullInfo& info,
                                V2TIMCallback* callback) = 0;
```

#### 未覆盖

`InviteUserToGroup`、`KickGroupMember`、`MuteGroupMember`、`MuteAllGroupMembers`、`TransferGroupOwner`、`SearchGroupMembers`、`SearchCloudGroupMembers`、`GetGroupApplicationList` 及其 Accept/Refuse、`MarkGroupMemberList`、`HandleGroupPendency`、`SearchCloudGroups` 等。

### V2TIMConversationManager

会话管理器。

**头文件**：`include/V2TIMConversationManager.h`

#### 监听器

```cpp
virtual void AddConversationListener(V2TIMConversationListener* listener) = 0;
virtual void RemoveConversationListener(V2TIMConversationListener* listener) = 0;
```

#### 会话操作

```cpp
// 两个 GetConversationList 重载（分别按 seq / 按 ID 列表）
virtual void GetConversationList(uint64_t nextSeq,
                                 uint32_t count,
                                 V2TIMValueCallback<V2TIMConversationResult>* callback) = 0;
virtual void GetConversationList(const V2TIMStringVector& conversationIDList,
                                 V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) = 0;

// 带过滤器的版本叫 GetConversationListByFilter，nextSeq 也是 uint64_t
virtual void GetConversationListByFilter(const V2TIMConversationListFilter& filter,
                                         uint64_t nextSeq,
                                         uint32_t count,
                                         V2TIMValueCallback<V2TIMConversationResult>* callback) = 0;

// 单会话操作：不需要 conversationType 参数（conversationID 已自带前缀）
virtual void GetConversation(const V2TIMString& conversationID,
                             V2TIMValueCallback<V2TIMConversation>* callback) = 0;
virtual void DeleteConversation(const V2TIMString& conversationID, V2TIMCallback* callback) = 0;
virtual void DeleteConversationList(const V2TIMStringVector& conversationIDList,
                                    bool clearMessage,
                                    V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) = 0;
virtual void SetConversationDraft(const V2TIMString& conversationID,
                                  const V2TIMString& draftText,
                                  V2TIMCallback* callback) = 0;
```

#### 未覆盖

`PinConversation` / `MarkConversation` / `GetTotalUnreadMessageCount` / `GetUnreadMessageCountByFilter` / `SetConversationCustomData`、整套 conversation-group（`GetConversationGroupList` / `DeleteConversationGroup` / `DeleteConversationsFromGroup` 等）未在本文档展开。

### V2TIMSignalingManager

信令管理器：邀请/取消/接受/拒绝（音视频通话信令的通用机制，不限于 AV）。

**头文件**：`include/V2TIMSignalingManager.h`

#### 监听器

```cpp
virtual void AddSignalingListener(V2TIMSignalingListener* listener) = 0;
virtual void RemoveSignalingListener(V2TIMSignalingListener* listener) = 0;
```

#### 信令操作

```cpp
// 真实返回类型是 V2TIMString（inviteID）；callback 类型是 V2TIMCallback*，不是 V2TIMValueCallback。
// Invite 还要求传入 V2TIMOfflinePushInfo。
virtual V2TIMString Invite(const V2TIMString& invitee,
                           const V2TIMString& data,
                           bool onlineUserOnly,
                           const V2TIMOfflinePushInfo& offlinePushInfo,
                           int timeout,
                           V2TIMCallback* callback) = 0;

virtual V2TIMString InviteInGroup(const V2TIMString& groupID,
                                  const V2TIMStringVector& inviteeList,
                                  const V2TIMString& data,
                                  bool onlineUserOnly,
                                  int timeout,
                                  V2TIMCallback* callback) = 0;

virtual void Cancel(const V2TIMString& inviteID, const V2TIMString& data, V2TIMCallback* callback) = 0;
virtual void Accept(const V2TIMString& inviteID, const V2TIMString& data, V2TIMCallback* callback) = 0;
virtual void Reject(const V2TIMString& inviteID, const V2TIMString& data, V2TIMCallback* callback) = 0;
```

#### 未覆盖

`GetSignalingInfo`、`AddInvitedSignaling`、`ModifyInvitation` 等。

### V2TIMCommunityManager

社区管理器（话题与权限组）。

**头文件**：`include/V2TIMCommunityManager.h`

```cpp
virtual void AddCommunityListener(V2TIMCommunityListener* listener) = 0;
virtual void RemoveCommunityListener(V2TIMCommunityListener* listener) = 0;

virtual void CreateTopicInCommunity(const V2TIMString& groupID,
                                    const V2TIMTopicInfo& topicInfo,
                                    V2TIMValueCallback<V2TIMString>* callback) = 0;
virtual void DeleteTopicFromCommunity(const V2TIMString& groupID,
                                      const V2TIMStringVector& topicIDList,
                                      V2TIMValueCallback<V2TIMTopicOperationResultVector>* callback) = 0;
virtual void SetTopicInfo(const V2TIMTopicInfo& topicInfo, V2TIMCallback* callback) = 0;
virtual void GetTopicInfoList(const V2TIMString& groupID,
                              const V2TIMStringVector& topicIDList,
                              V2TIMValueCallback<V2TIMTopicInfoResultVector>* callback) = 0;
```

> 权限组相关方法（`CreatePermissionGroupInCommunity` 等）未在本文档展开，但接口存在于头文件中。

### V2TIMOfflinePushManager

离线推送管理器（`include/V2TIMOfflinePushManager.h`）。tim2tox 仅提供占位实现，因为 Tox 网络不存在云端推送服务；调用通常返回成功但无副作用。具体接口请直接查头文件。

## 相关文档

- [API_SUPPORT_MATRIX.md](API_SUPPORT_MATRIX.md) — **逐接口真实支持状态矩阵**（native / dart-only / local-only / text-degraded / no-op-success / unsupported）
- [API_REFERENCE.md](API_REFERENCE.md) — 总索引、数据类型、错误码、示例
- [API_REFERENCE_FFI.md](API_REFERENCE_FFI.md) — C FFI 接口
- [API_REFERENCE_DART.md](API_REFERENCE_DART.md) — Dart 包 API
