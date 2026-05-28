# Tim2Tox API Support Matrix
> Language: [Chinese](API_SUPPORT_MATRIX.md) | [English](API_SUPPORT_MATRIX.en.md)

This document lists, per API, the **real support status** of the V2TIM API surface when Tim2Tox runs over the Tox P2P network. It is written for integrators and answers not "does the method exist / does it compile" but "what actually happens when you call it." Many V2TIM methods exist only to preserve call-signature compatibility but have no equivalent semantics on Tox — those are flagged explicitly here so integrators don't use them with Tencent Cloud IM expectations.

Signatures and the method inventory are authoritative in [API_REFERENCE_V2TIM.en.md](API_REFERENCE_V2TIM.en.md); the status conclusions in this table come from a code audit of `source/V2TIMMessageManagerImpl.cpp` and `source/V2TIMGroupManagerImpl.cpp` (with file:line evidence).

## How to read this

- Columns are `Domain | API | Status | Notes`.
- "Status" uses one of the fixed values in **Status categories** below.
- `Impl.cpp:line` in a row points at the implementation site at audit time; line numbers drift across versions and are only a locator.
- **Media and files**: do NOT use the V2TIM `CreateImageMessage` / `CreateSoundMessage` / `CreateVideoMessage` / `CreateFileMessage` to send real files — they are either not implemented or silently degraded to plain text. For real file/media transfer use the Dart-side `FfiChatService` file APIs (`tim2tox_ffi_send_file` / `tim2tox_ffi_file_control`); see [API_REFERENCE_FFI.en.md](API_REFERENCE_FFI.en.md) and [API_REFERENCE_DART.en.md](API_REFERENCE_DART.en.md).

## Status categories (legend)

| Status | Meaning |
| --- | --- |
| **native** | Real, over-the-network Tox semantics implemented in C++. |
| **dart-only** | Works only via the Dart `FfiChatService` / Platform path / `MessageHistoryPersistence`, NOT the C++ V2TIM API; calling the C++ V2TIM method directly returns nothing useful. |
| **local-only** | Succeeds, but only affects local state — no network effect (the peer is unaware). |
| **text-degraded** | Silently converted to a plain text message; the recipient receives text, NOT the structured type. |
| **no-op-success** | Returns success without doing anything. |
| **unsupported** | Returns `ERR_SDK_INTERFACE_NOT_SUPPORT` / `ERR_SDK_NOT_SUPPORTED`. |

> Note the difference between `dart-only` and `unsupported`: several message-query methods report "not supported" at the C++ layer, yet the same capability is reachable through the Dart side in a full integrator such as toxee. For those methods this table gives both the C++ status (`unsupported`) and the working path (`dart-only`).

## Authentication / Login

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Auth | `Login(userID, userSig)` | local-only | **Does NOT verify `userSig`**; `userSig` is accepted only for V2TIM call-signature compatibility and ignored. Login = open/bind the **LOCAL** Tox identity/profile, NOT server-side authentication. Integrators must NOT treat it as auth. See "Authentication & login semantics" in [API_REFERENCE_V2TIM.en.md](API_REFERENCE_V2TIM.en.md). |
| Auth | `GetLoginStatus()` | local-only | Returns `LOGINED` as soon as a local alias is set; reflects **local** login state, NOT Tox DHT/network connectivity. For actual connectivity, observe the connection-status listener/callback. |
| Auth | `Logout()` / `GetLoginUser()` | native | Log out / read the current local login user. |

## Messages (`source/V2TIMMessageManagerImpl.cpp`)

### Create message

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Message | `CreateTextMessage` | native | Text message, works. |
| Message | `CreateCustomMessage` | native | Custom message, works. |
| Message | `CreateImageMessage` (:154) | unsupported | Logs "not implemented" and sets message status to `SEND_FAIL`; nothing is sent. |
| Message | `CreateSoundMessage` (:161) | unsupported | Same: "not implemented" + `SEND_FAIL`. |
| Message | `CreateVideoMessage` (:168) | unsupported | Same: "not implemented" + `SEND_FAIL`. |
| Message | `CreateFileMessage` (:175) | text-degraded | Builds a `V2TIMFileElem`, but the send path **never** wires it to Tox file transfer; on send it effectively degrades to a plain text description. For real file transfer use the `FfiChatService` file APIs. |

### Send message

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Message | `SendMessage` — TEXT | native | C2C text and group text, real over Tox. |
| Message | `SendMessage` — CUSTOM | native | C2C custom and group custom, real over Tox. |
| Message | `SendMessage` — IMAGE (:487 switch, :602-689) | text-degraded | Degraded to text `[转发图片]` (forwarded image). Recipient receives text, not an image. |
| Message | `SendMessage` — SOUND | text-degraded | Degraded to text `[转发语音]` (forwarded voice). |
| Message | `SendMessage` — VIDEO | text-degraded | Degraded to text `[转发视频]` (forwarded video). |
| Message | `SendMessage` — FILE | text-degraded | Degraded to text `[转发文件]` (forwarded file). For real files use the `FfiChatService` file APIs. |
| Message | `SendMessage` — LOCATION | text-degraded | Degraded to text `[转发位置]` (forwarded location). |
| Message | `SendMessage` — FACE | text-degraded | Degraded to text `[转发表情]` (forwarded emoji). |

### Query / history

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Message | `GetHistoryMessageList` (:828) | dart-only | Not supported at the C++ layer; history lives in the Dart `MessageHistoryPersistence`, served by the Platform / `FfiChatService`. |
| Message | `FindMessages` (:1084) | dart-only | Returns empty at the C++ layer; fetch via the Dart side. |
| Message | `SearchLocalMessages` (:1121) | dart-only | Returns empty at the C++ layer; fetch via the Dart side. |
| Message | `SearchCloudMessages` (:1142) | unsupported | No cloud on Tox; returns not-supported. |

### Read / receipts

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Message | `MarkC2CMessageAsRead` (:1155) | no-op-success | Returns success; no network effect. |
| Message | `MarkGroupMessageAsRead` (:1160) | no-op-success | Same. |
| Message | `MarkAllMessageAsRead` (:1170) | no-op-success | Same. |
| Message | `SendMessageReadReceipts` (:1143) | unsupported | |
| Message | `GetMessageReadReceipts` (:1144) | unsupported | |
| Message | `GetGroupMessageReadMemberList` (:1145) | unsupported | |

### Modify / receive options

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Message | `ModifyMessage` (:927) | unsupported | |
| Message | `SetAllReceiveMessageOpt` (:824) | unsupported | |
| Message | `GetAllReceiveMessageOpt` (:826) | unsupported | |

### Extensions / reactions / translate / pin / merger

| Domain | API | Status | Notes |
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

## Groups (`source/V2TIMGroupManagerImpl.cpp`)

### Group and members (real implementations)

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Group | `CreateGroup` | native | Really creates a group (`tox_group_new` / `tox_conference_new`). |
| Group | `JoinGroup` | native | Real join (hangs on `V2TIMManager`). |
| Group | `QuitGroup` | native | Real quit (hangs on `V2TIMManager`). |
| Group | `InviteUserToGroup` (:2549) | native | Real implementation. |
| Group | `KickGroupMember` (:2869 / :3047) | native | Real implementation. |
| Group | `SetGroupMemberRole` (:3057) | native | Real implementation. |
| Group | `TransferGroupOwner` (:3179) | native | Real implementation. |
| Group | `GetGroupMemberList` (:1495) | native | Real implementation. |
| Group | Group online member count | partial / unreliable | `ToxManager::getGroupPeerCount` is currently unreliable; the online count may be inaccurate. Do not rely on it for strong-consistency decisions. |

### Mute

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Group | `MuteGroupMember` (:2535) | no-op-success | Returns success, but Tox has no timed-mute mechanism, so it has no effect. |
| Group | `MuteAllGroupMembers` (:2546) | unsupported | |

### Search

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Group | `SearchGroupMembers` (:2383) | unsupported | |
| Group | `SearchCloudGroupMembers` (:2388) | unsupported | |
| Group | `SearchCloudGroups` (:1300) | unsupported | No cloud group directory on Tox. |

### Group attributes / counters

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Group | `InitGroupAttributes` (:1445) | unsupported | |
| Group | `SetGroupAttributes` (:1451) | unsupported | |
| Group | `DeleteGroupAttributes` (:1456) | unsupported | |
| Group | `GetGroupAttributes` (:1461) | unsupported | |
| Group | `SetGroupCounters` (:1476) | unsupported | |
| Group | `GetGroupCounters` (:1481) | unsupported | |
| Group | `IncreaseGroupCounter` (:1486) | unsupported | |
| Group | `DecreaseGroupCounter` (:1491) | unsupported | |

### Group applications / member marking

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Group | `GetGroupApplicationList` (:3278) | unsupported | |
| Group | `AcceptGroupApplication` (:3284) | unsupported | |
| Group | `RefuseGroupApplication` (:3288) | unsupported | |
| Group | `SetGroupApplicationRead` (:3292) | unsupported | |
| Group | `MarkGroupMemberList` (:3176) | unsupported | |

### Community / topics

| Domain | API | Status | Notes |
| --- | --- | --- | --- |
| Community | `GetJoinedCommunityList` (:3297) | unsupported | |
| Community | `CreateTopicInCommunity` (:3303) | unsupported | |
| Community | `DeleteTopicFromCommunity` (:3308) | unsupported | |
| Community | `SetTopicInfo` (:3312) | unsupported | |
| Community | `GetTopicInfoList` (:3316) | unsupported | |

## Related documents

- [API_REFERENCE_V2TIM.en.md](API_REFERENCE_V2TIM.en.md) — V2TIM C++ signatures and tim2tox behavior notes
- [API_REFERENCE_FFI.en.md](API_REFERENCE_FFI.en.md) — C FFI interface (file transfer `tim2tox_ffi_send_file` / `tim2tox_ffi_file_control` live here)
- [API_REFERENCE_DART.en.md](API_REFERENCE_DART.en.md) — Dart package API (`FfiChatService` file and history methods)
- [API_REFERENCE.en.md](API_REFERENCE.en.md) — index, data types, error codes, examples
