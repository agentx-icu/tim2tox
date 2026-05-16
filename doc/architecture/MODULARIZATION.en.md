# Tim2Tox FFI Layer Modularization
> Language: [Chinese](MODULARIZATION.md) | [English](MODULARIZATION.en.md)

## Overview

The `Dart*` compatibility layer (loaded dynamically by `NativeLibraryManager` on the binary-replacement path) was historically a single file. It has been split by responsibility into **13 `.cpp` modules + 2 shared headers**. This document records each module's role and current size.

> Line counts are snapshots from `wc -l ffi/dart_compat_*.{cpp,h}` at the time of writing and will drift as the implementation grows. If they look significantly off, just re-run `wc -l` and update this table.

## Module structure

### Infrastructure modules

#### dart_compat_internal.h
- **Role**: Shared declarations and forward declarations (global-variable `extern`s, utility-function prototypes, Listener / Callback class forward declarations, and a single point for shared `#include`s).
- **Lines**: ~157

#### dart_compat_utils.cpp
- **Role**: Utility functions and global state. Provides `StoreCallbackUserData` / `GetCallbackUserData` / `UserDataToString` / `SafeGetV2TIMManager` / `CStringToString` / `SendApiCallbackResult*` / `ParseJsonConfig` / `SafeGetCString` / `ConversationVectorToJson`, etc.
- **Lines**: ~576

### Listener / callback modules

#### dart_compat_listeners.cpp
- **Role**: All `*ListenerImpl` classes plus `DartSet*Callback` registration functions.
  - `DartSDKListenerImpl`, `DartAdvancedMsgListenerImpl`, `DartConversationListenerImpl`, `DartGroupListenerImpl`, `DartFriendshipListenerImpl`, `DartSignalingListenerImpl`, `DartCommunityListenerImpl`
  - ~65 `DartSet*Callback` registration functions
- **Lines**: ~2800

#### dart_compat_callbacks.cpp
- **Role**: The `Dart*Callback` callback-class family and the JSON serialization helpers (`MessageVectorToJson`, `FriendInfoVectorToJson`, `ConversationResultToJson`, `GroupInfoVectorToJson`, `FriendOperationResultToJson`, `FriendOperationResultVectorToJson`, `FriendInfoResultVectorToJson`, ...).
- **Lines**: ~965

### Functional modules

#### dart_compat_sdk.cpp
- **Role**: SDK initialization and authentication. `DartInitSDK(uint64_t sdk_app_id, const char* json_sdk_config)`, `DartUnitSDK`, `DartGetSDKVersion`, `DartGetServerTime`, `DartSetConfig`, `DartLogin(const char* user_id, const char* user_sig, void* user_data)`, `DartLogout`, `DartGetLoginUserID`.
- **Lines**: ~177

> `DartGetLoginStatus` lives in `dart_compat_user.cpp`, not in `sdk.cpp`.

#### dart_compat_message.cpp
- **Role**: Message send / query / revoke / modify / delete / history / read-mark / local custom data / element download. Includes `DartSendMessage`, `DartFindMessages`, `DartRevokeMessage`, `DartModifyMessage`, `DartDeleteMessages`, `DartClearHistoryMessage`, `DartGetHistoryMessageList`, `DartGetMessageList`, `DartMarkAllMessageAsRead` / `DartMarkC2CMessageAsRead` / `DartMarkGroupMessageAsRead`, `DartSetLocalCustomData`, `DartDownloadElemToPath`, `DartDownloadMergerMessage`, and others.
- **Lines**: ~1732

#### dart_compat_friendship.cpp
- **Role**: Friend CRUD, friend applications, friend profile, blacklist. `DartGetFriendList`, `DartAddFriend`, `DartDeleteFromFriendList`, `DartGetFriendsInfo`, `DartSetFriendInfo`, `DartGetFriendApplicationList`, `DartAcceptFriendApplication`, `DartRefuseFriendApplication`, `DartCheckFriend`, `DartAddToBlackList`, `DartDeleteFromBlackList`, `DartGetBlackList`, `DartSetFriendApplicationRead`, ...
- **Lines**: ~934

#### dart_compat_conversation.cpp
- **Role**: Conversation query / delete / pin / draft / mark / custom data / conversation groups. `DartGetConversationList`, `DartGetConversation`, `DartDeleteConversation`, `DartSetConversationDraft`, `DartCancelConversationDraft`, `DartPinConversation`, `DartMarkConversation`, `DartGetTotalUnreadMessageCount`, `DartGetUnreadMessageCountByFilter`, `DartGetConversationListByFilter`, `DartSetConversationCustomData`, `DartCreateConversationGroup`, `DartDeleteConversationGroup`, `DartRenameConversationGroup`, `DartGetConversationGroupList`, `DartAddConversationsToGroup`, `DartDeleteConversationsFromGroup`.
- **Lines**: ~690

#### dart_compat_group.cpp
- **Role**: Group lifecycle, members, attributes, counters, search. `DartCreateGroup`, `DartJoinGroup`, `DartQuitGroup`, `DartDeleteGroup`, `DartGetJoinedGroupList`, `DartGetGroupsInfo`, `DartSetGroupInfo`, `DartGetGroupMemberList`, `DartGetGroupMembersInfo`, `DartInviteUserToGroup`, `DartKickGroupMember`, `DartModifyGroupMemberInfo`, `DartSetGroupAttributes` / `DartGetGroupAttributes` / `DartInitGroupAttributes` / `DartDeleteGroupAttributes`, `DartSetGroupCounters` / `DartGetGroupCounters` / `DartIncreaseGroupCounter` / `DartDecreaseGroupCounter`, `DartSearchGroups`, ...
- **Lines**: ~1818

> Some methods that the V2TIM abstract class exposes (e.g. `DartGetOnlineMemberCount`, `DartMarkGroupMemberList`, `DartGetGroupPendencyList`, `DartHandleGroupPendency`, `DartSearchCloudGroups`, `DartSearchCloudGroupMembers`) are not implemented here today — calls fall through to default SDK behavior. The authoritative `Dart*` list is the `extern "C"` block of this module (`grep -hE '^\\s*(int|void|const char\\*) Dart[A-Z]' ffi/dart_compat_group.cpp`).

#### dart_compat_user.cpp
- **Role**: User info / subscribe / status / login status / message receive opt. `DartGetUsersInfo`, `DartSetSelfInfo`, `DartSubscribeUserInfo`, `DartUnsubscribeUserInfo`, `DartGetUserStatus`, `DartSetSelfStatus`, `DartSetC2CReceiveMessageOpt` / `DartGetC2CReceiveMessageOpt`, `DartSetAllReceiveMessageOpt` / `DartGetAllReceiveMessageOpt`, `DartGetLoginStatus`.
- **Lines**: ~765

#### dart_compat_signaling.cpp
- **Role**: Signaling invite / modify / cancel / accept / reject. `DartInvite`, `DartInviteInGroup`, `DartGetSignalingInfo`, `DartModifyInvitation`, `DartCancel` (invitation), `DartAccept`, `DartReject`.
- **Lines**: ~576

#### dart_compat_community.cpp
- **Role**: Community / topics / permission groups (placeholder).
- **Status**: Currently a placeholder (header include + empty `extern "C"` block); no community `Dart*` implemented yet.
- **Lines**: ~14

#### dart_compat_other.cpp
- **Role**: Other miscellany — primarily `DartCallExperimentalAPI`.
- **Status**: `DartCallExperimentalAPI` is **implemented** and handles `set_ui_platform`, `set_network_info`, `write_log`, and `is_commercial_ability_enabled`; other experimental operations fall through with a success return.
- **Lines**: ~98

### Entry-point file

#### dart_compat_layer.cpp
- **Role**: Historically the "main entry"; has degenerated into a documentary file — only comments and includes, no `Dart*` implementations.
- **Lines**: 28

## Module dependency graph

```
dart_compat_internal.h (shared header)
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
    ├── dart_compat_community.cpp (placeholder)
    ├── dart_compat_other.cpp
    └── dart_compat_layer.cpp (comments only)
```

## Code stats (snapshot)

| Module | Lines | Status |
|--------|-------|--------|
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
| dart_compat_community.cpp | ~14 | ⏳ placeholder |
| dart_compat_other.cpp | ~98 | ✅ |
| dart_compat_layer.cpp | 28 | ℹ️ comments only |
| **Total** | **~11,330** | — |

> Refresh: `wc -l ffi/dart_compat_*.{cpp,h}`

## Benefits of modularization

1. **Maintainability**: Each module focuses on a specific surface.
2. **Build speed**: Editing one module only recompiles that module.
3. **Code organization**: Related `Dart*` symbols are grouped.
4. **Team workflow**: Multiple developers can edit different modules without conflict.
5. **Testability**: Each module can be exercised independently.

## Development guide

### Adding a new function

1. **Pick the module** by responsibility (and add it to the right `.cpp`).
2. **Add the implementation** inside that file's `extern "C"` block.
3. **Update the doc** — this file's module entry.
4. **Stay binary-compatible with Dart**: the signature must match the patched `native_imsdk_bindings_generated.dart`. This is an ABI; changes must be made on both sides.
5. **Writing style**: see [doc/api/API_REFERENCE_TEMPLATE.en.md](../api/API_REFERENCE_TEMPLATE.en.md).

### Modifying an existing function

1. **Find it**: `grep -rn 'Dart<Name>' ffi/dart_compat_*.cpp`.
2. **Modify** in the relevant `.cpp`.
3. **Verify**: `auto_tests/scenarios_binary/` is the regression suite for the binary-replacement path.

### Adding a new module

1. Create `dart_compat_<module>.cpp` with `#include "dart_compat_internal.h"` and an `extern "C" { ... }` block.
2. Add the new file to the source list in `ffi/CMakeLists.txt`.
3. Note it in the `dart_compat_layer.cpp` comments.

## Related documents

- [Tim2Tox FFI Compatibility Layer](FFI_COMPAT_LAYER.en.md)
- [Tim2Tox Architecture](ARCHITECTURE.en.md)
- [Development Guide](../development/DEVELOPMENT_GUIDE.en.md)
- [FFI Function Declaration Guide](../development/FFI_FUNCTION_DECLARATION_GUIDE.en.md)
