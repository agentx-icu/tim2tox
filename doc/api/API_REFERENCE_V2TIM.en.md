# Tim2Tox API Reference — V2TIM C++
> Language: [Chinese](API_REFERENCE_V2TIM.md) | [English](API_REFERENCE_V2TIM.en.md)

This document is the V2TIM C++ sub-volume of [API_REFERENCE.en.md](API_REFERENCE.en.md). All signatures are authoritative against `include/V2TIM*.h`; only the commonly used surface is listed. Methods marked "Not covered" should be looked up directly in the header.

## V2TIM C++ API

Tim2Tox implements the V2TIM core methods in C++ (see `source/V2TIMManagerImpl.*` and friends), keeping binary/semantic compatibility with the Tencent Cloud IM SDK contract.

### V2TIMManager

Core manager: SDK init, login/logout, and access to sub-managers.

**Header**: `include/V2TIMManager.h`

#### Initialization and version

```cpp
// Singleton
static V2TIMManager* GetInstance();

// Init / uninit
virtual bool InitSDK(uint32_t sdkAppID, const V2TIMSDKConfig& config) = 0;
virtual void UnInitSDK() = 0;

// Version and server time
virtual V2TIMString GetVersion() = 0;
virtual int64_t     GetServerTime() = 0;
```

#### Listeners

```cpp
virtual void AddSDKListener(V2TIMSDKListener* listener) = 0;
virtual void RemoveSDKListener(V2TIMSDKListener* listener) = 0;
```

#### Login / logout

```cpp
virtual void        Login(const V2TIMString& userID, const V2TIMString& userSig, V2TIMCallback* callback) = 0;
virtual void        Logout(V2TIMCallback* callback) = 0;
virtual V2TIMString GetLoginUser() = 0;
```

#### Sub-manager accessors

```cpp
virtual V2TIMMessageManager*      GetMessageManager() = 0;
virtual V2TIMGroupManager*        GetGroupManager() = 0;
virtual V2TIMConversationManager* GetConversationManager() = 0;
virtual V2TIMFriendshipManager*   GetFriendshipManager() = 0;
virtual V2TIMSignalingManager*    GetSignalingManager() = 0;
virtual V2TIMCommunityManager*    GetCommunityManager() = 0;
virtual V2TIMOfflinePushManager*  GetOfflinePushManager() = 0;
```

#### Group shortcuts (hung directly on V2TIMManager)

```cpp
virtual void JoinGroup(const V2TIMString& groupID, const V2TIMString& message, V2TIMCallback* callback) = 0;
virtual void QuitGroup(const V2TIMString& groupID, V2TIMCallback* callback) = 0;
virtual void DismissGroup(const V2TIMString& groupID, V2TIMCallback* callback) = 0;
```

> `JoinGroup` / `QuitGroup` / `DismissGroup` live on `V2TIMManager`, **not** on `V2TIMGroupManager`.

### V2TIMMessageManager

Message manager: build, send, query, read-mark, revoke.

**Header**: `include/V2TIMMessageManager.h`

#### Listeners

```cpp
virtual void AddAdvancedMsgListener(V2TIMAdvancedMsgListener* listener) = 0;
virtual void RemoveAdvancedMsgListener(V2TIMAdvancedMsgListener* listener) = 0;
```

#### Create message

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

#### Send message

```cpp
// Real signature: returns V2TIMString (msgID); parameters are
// receiver, groupID, priority, onlineUserOnly, offlinePushInfo, callback.
// Header location: include/V2TIMMessageManager.h:235
virtual V2TIMString SendMessage(V2TIMMessage& message,
                                const V2TIMString& receiver,
                                const V2TIMString& groupID,
                                V2TIMMessagePriority priority,
                                bool onlineUserOnly,
                                const V2TIMOfflinePushInfo& offlinePushInfo,
                                V2TIMSendCallback* callback) = 0;
```

> For **C2C** pass `receiver=<peer userID>`, `groupID=V2TIMString()`. For **group** messages pass `receiver=V2TIMString()`, `groupID=<group ID>`. There is no separate "with cloudCustomData" overload — set `message.cloudCustomData` on the message itself.

#### Query

```cpp
virtual void FindMessages(const V2TIMStringVector& messageIDList,
                          V2TIMValueCallback<V2TIMMessageVector>* callback) = 0;

// Real signature: a single option struct carries all parameters; the callback yields a V2TIMMessageVector.
virtual void GetHistoryMessageList(const V2TIMMessageListGetOption& option,
                                   V2TIMValueCallback<V2TIMMessageVector>* callback) = 0;
```

> `V2TIMMessageListGetOption` lives in `include/V2TIMMessage.h` (fields include `userID` / `groupID` / `lastMsg` / `getType` / `count` / ...). In tim2tox, history reads are intercepted by the Platform / `FfiChatService` and served from the Dart-side `MessageHistoryPersistence`.

#### Operations

```cpp
virtual void RevokeMessage(const V2TIMMessage& message, V2TIMCallback* callback) = 0;

// Read-mark: there is **no** unified MarkMessageAsRead — three separate methods:
virtual void MarkC2CMessageAsRead(const V2TIMString& userID, V2TIMCallback* callback) = 0;
virtual void MarkGroupMessageAsRead(const V2TIMString& groupID, V2TIMCallback* callback) = 0;
virtual void MarkAllMessageAsRead(V2TIMCallback* callback) = 0;

// Delete: the parameter is a V2TIMMessageVector, not a V2TIMStringVector of IDs
virtual void DeleteMessages(const V2TIMMessageVector& messages, V2TIMCallback* callback) = 0;
```

#### Not covered

`ModifyMessage`, `ClearC2CHistoryMessage`, `ClearGroupHistoryMessage`, `InsertC2CMessageToLocalStorage`, `InsertGroupMessageToLocalStorage`, `SendMessageReadReceipts`, `GetMessageReadReceipts`, `GetGroupMessageReadMemberList`, `SetC2CReceiveMessageOpt`, `GetC2CReceiveMessageOpt`, and the rest of the read-receipt / receive-option surface are not expanded here.

### V2TIMFriendshipManager

Friend manager.

**Header**: `include/V2TIMFriendshipManager.h`

#### Listeners

```cpp
virtual void AddFriendListener(V2TIMFriendshipListener* listener) = 0;
virtual void RemoveFriendListener(V2TIMFriendshipListener* listener) = 0;
```

#### Friend list / info

```cpp
virtual void GetFriendList(V2TIMValueCallback<V2TIMFriendInfoVector>* callback) = 0;
virtual void GetFriendsInfo(const V2TIMStringVector& userIDList,
                            V2TIMValueCallback<V2TIMFriendInfoResultVector>* callback) = 0;
virtual void SetFriendInfo(const V2TIMFriendInfo& info, V2TIMCallback* callback) = 0;
```

#### Friend operations

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

#### Friend applications

```cpp
virtual void GetFriendApplicationList(V2TIMValueCallback<V2TIMFriendApplicationResult>* callback) = 0;

// The real enum is V2TIMFriendAcceptType (not V2TIMFriendResponseType).
// Two overloads: with and without remark.
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

#### Not covered

`DeleteFriendApplication`, `SetFriendApplicationRead`, `AddToBlackList` / `DeleteFromBlackList` / `GetBlackList`, the `CreateFriendGroup` family.

### V2TIMGroupManager

Group manager.

**Header**: `include/V2TIMGroupManager.h`

> Note: `JoinGroup` / `QuitGroup` / `DismissGroup` are not in this interface — they hang on [V2TIMManager](#v2timmanager).

#### Listeners

```cpp
virtual void AddGroupListener(V2TIMGroupListener* listener) = 0;
virtual void RemoveGroupListener(V2TIMGroupListener* listener) = 0;
```

#### Group operations

```cpp
virtual void CreateGroup(const V2TIMGroupInfo& info,
                         const V2TIMCreateGroupMemberInfoVector& memberList,
                         V2TIMValueCallback<V2TIMString>* callback) = 0;

virtual void GetJoinedGroupList(V2TIMValueCallback<V2TIMGroupInfoVector>* callback) = 0;
virtual void GetGroupsInfo(const V2TIMStringVector& groupIDList,
                           V2TIMValueCallback<V2TIMGroupInfoResultVector>* callback) = 0;
virtual void SetGroupInfo(const V2TIMGroupInfo& info, V2TIMCallback* callback) = 0;
```

**tim2tox behavior** (implemented in `V2TIMGroupManagerImpl.cpp`):

- `info.groupType`: `"group"` (new API, `tox_group_new`, supports `chat_id` persistence — preferred) or `"conference"` (old API, `tox_conference_new`, savedata-only recovery — compatibility only). Defaults to `"group"` when omitted.
- `info.groupID`: optional; auto-generated as `tox_<id>` when omitted.
- `groupType` is always persisted; `"group"` type additionally persists the `chat_id`.
- `GetGroupsInfo` returns `V2TIMGroupInfo.notification` from `tox_group_get_topic`, which is **Group-type only**.

#### Group members

```cpp
// filter is uint32_t (V2TIMGroupMemberFilter bitmask or custom marker); nextSeq is uint64_t
virtual void GetGroupMemberList(const V2TIMString& groupID,
                                uint32_t filter,
                                uint64_t nextSeq,
                                V2TIMValueCallback<V2TIMGroupMemberInfoResult>* callback) = 0;

// memberList is passed by value (V2TIMStringVector), not by const reference
virtual void GetGroupMembersInfo(const V2TIMString& groupID,
                                 V2TIMStringVector memberList,
                                 V2TIMValueCallback<V2TIMGroupMemberFullInfoVector>* callback) = 0;

// Mutate a member: the userID is carried inside info.userID (no separate parameter)
virtual void SetGroupMemberInfo(const V2TIMString& groupID,
                                const V2TIMGroupMemberFullInfo& info,
                                V2TIMCallback* callback) = 0;
```

#### Not covered

`InviteUserToGroup`, `KickGroupMember`, `MuteGroupMember`, `MuteAllGroupMembers`, `TransferGroupOwner`, `SearchGroupMembers`, `SearchCloudGroupMembers`, `GetGroupApplicationList` and its Accept/Refuse, `MarkGroupMemberList`, `HandleGroupPendency`, `SearchCloudGroups`, etc.

### V2TIMConversationManager

Conversation manager.

**Header**: `include/V2TIMConversationManager.h`

#### Listeners

```cpp
virtual void AddConversationListener(V2TIMConversationListener* listener) = 0;
virtual void RemoveConversationListener(V2TIMConversationListener* listener) = 0;
```

#### Conversation operations

```cpp
// Two GetConversationList overloads (by seq / by ID list)
virtual void GetConversationList(uint64_t nextSeq,
                                 uint32_t count,
                                 V2TIMValueCallback<V2TIMConversationResult>* callback) = 0;
virtual void GetConversationList(const V2TIMStringVector& conversationIDList,
                                 V2TIMValueCallback<V2TIMConversationOperationResultVector>* callback) = 0;

// Filtered variant is GetConversationListByFilter; nextSeq is also uint64_t
virtual void GetConversationListByFilter(const V2TIMConversationListFilter& filter,
                                         uint64_t nextSeq,
                                         uint32_t count,
                                         V2TIMValueCallback<V2TIMConversationResult>* callback) = 0;

// Single-conversation ops: no conversationType parameter (the ID is self-prefixed)
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

#### Not covered

`PinConversation` / `MarkConversation` / `GetTotalUnreadMessageCount` / `GetUnreadMessageCountByFilter` / `SetConversationCustomData`, plus the conversation-group subsystem (`GetConversationGroupList` / `DeleteConversationGroup` / `DeleteConversationsFromGroup` / ...).

### V2TIMSignalingManager

Signaling manager: invite / cancel / accept / reject (a generic mechanism that AV calling uses, but it is not AV-specific).

**Header**: `include/V2TIMSignalingManager.h`

#### Listeners

```cpp
virtual void AddSignalingListener(V2TIMSignalingListener* listener) = 0;
virtual void RemoveSignalingListener(V2TIMSignalingListener* listener) = 0;
```

#### Signaling operations

```cpp
// Real return type is V2TIMString (inviteID); callback type is V2TIMCallback*, NOT V2TIMValueCallback.
// Invite requires a V2TIMOfflinePushInfo argument.
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

#### Not covered

`GetSignalingInfo`, `AddInvitedSignaling`, `ModifyInvitation`.

### V2TIMCommunityManager

Community manager (topics & permission groups).

**Header**: `include/V2TIMCommunityManager.h`

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

> Permission-group APIs (`CreatePermissionGroupInCommunity`, etc.) exist in the header but are not expanded here.

### V2TIMOfflinePushManager

Offline-push manager (`include/V2TIMOfflinePushManager.h`). tim2tox provides only placeholder implementations because the Tox network has no cloud push service; calls typically succeed but are no-ops. Refer to the header for the surface.

## Related documents

- [API_REFERENCE.en.md](API_REFERENCE.en.md) — index, data types, error codes, examples
- [API_REFERENCE_FFI.en.md](API_REFERENCE_FFI.en.md) — C FFI interface
- [API_REFERENCE_DART.en.md](API_REFERENCE_DART.en.md) — Dart package API
