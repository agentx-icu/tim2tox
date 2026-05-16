# Tim2Tox 持久化与恢复
> 语言 / Language: [中文](RESTORE_AND_PERSISTENCE.md) | [English](RESTORE_AND_PERSISTENCE.en.md)


本文档详细说明 Tim2Tox 中群聊的持久化和恢复机制，包括 Group 和 Conference 两种类型的处理方式。

## 概述

Tim2Tox 需要持久化以下信息以确保客户端重启后能正确恢复群组：

1. **groupType**: 群组类型（"group" 或 "conference"）
2. **chat_id**: Group 类型的唯一标识符（仅 Group 类型）
3. **group_id**: 应用层群组标识符
4. **savedata**: Tox 的 savedata（包含 Conference 信息）

## 持久化数据

### 1. groupType

**存储位置**: `SharedPreferences`（通过 FFI 回调）

**存储格式**: 字符串 "group" 或 "conference"

**存储时机**: 创建群组时

**存储方式**：
```cpp
// C++ 侧（多实例：首参是 int64_t instance_id；生产单例传 0）
extern "C" int tim2tox_ffi_set_group_type(int64_t instance_id,
                                          const char* group_id,
                                          const char* group_type);
tim2tox_ffi_set_group_type(/*instance=*/0, groupID, "group");  // 或 "conference"
```

Dart 侧：当前 `Tim2ToxSdkPlatform` 的 customCallback 默认会消费 `groupChatIdStored`、`clearHistoryMessage`、`groupQuitNotification` 三种事件；`groupType` 的持久化在 C++ 侧已**直接**写入 `ExtendedPreferencesService.setGroupType(...)`（通过注入的接口），不需要单独的 Dart-side `case "groupTypeStored"`。

**读取方式**：
```cpp
extern "C" int tim2tox_ffi_get_group_type_from_storage(int64_t instance_id,
                                                       const char* group_id,
                                                       char* out_group_type,
                                                       int out_len);
char stored_type[16];
if (tim2tox_ffi_get_group_type_from_storage(/*instance=*/0, group_id,
                                            stored_type, sizeof(stored_type)) == 1) {
    std::string group_type = std::string(stored_type);
}
```

### 2. chat_id（仅 Group 类型）

**存储位置**: `SharedPreferences`（通过 FFI 回调）

**存储格式**: 64 字符的十六进制字符串（32 字节）

**存储时机**: 创建或加入 Group 类型群组时

**存储方式**：
```cpp
extern "C" int tim2tox_ffi_set_group_chat_id(int64_t instance_id,
                                             const char* group_id,
                                             const char* chat_id);
tim2tox_ffi_set_group_chat_id(/*instance=*/0, groupID, chat_id_hex);

// Dart 侧：Tim2ToxSdkPlatform 的 customCallback 处理 "groupChatIdStored"
// （tim2tox_sdk_platform.dart）
case "groupChatIdStored":
    await preferencesService.setGroupChatId(groupId, chatId);
    break;
```

**读取方式**：
```cpp
extern "C" int tim2tox_ffi_get_group_chat_id_from_storage(int64_t instance_id,
                                                          const char* group_id,
                                                          char* out_chat_id,
                                                          int out_len);
char stored_chat_id[65];
if (tim2tox_ffi_get_group_chat_id_from_storage(/*instance=*/0, group_id,
                                               stored_chat_id, sizeof(stored_chat_id)) == 1) {
    // 使用 stored_chat_id
}
```

### 3. savedata（Conference 类型）

**存储位置**: Tox 自动管理（通过 `tox_get_savedata` / `tox_new`）

**存储格式**: 二进制数据

**存储时机**: Tox 定期保存（通过 `tox_save` 回调）

**恢复方式**: Tox 初始化时通过 `tox_new` 加载 savedata

## 恢复流程

### InitSDK 时的恢复

在 `V2TIMManagerImpl::InitSDK()` 中：

1. **加载 savedata**: Tox 初始化时自动加载，conferences 会自动恢复
2. **查询已恢复的 groups**: 调用 `tox_manager_->getGroupListSize()` 和 `getGroupList()`
3. **手动触发回调**: 对每个已恢复的 group 调用 `HandleGroupSelfJoin()` 重建映射
4. **查询已恢复的 conferences**: 调用 `tox_conference_get_chatlist_size()` 和 `tox_conference_get_chatlist()`
5. **调用 RejoinKnownGroups()**: 开始恢复流程

### RejoinKnownGroups 恢复流程

**文件**: `tim2tox/source/V2TIMManagerImpl.cpp::RejoinKnownGroups()`

#### Group 类型恢复

```
1. 从 Dart 层获取所有 knownGroups
   ↓
2. 对每个 group_id：
   a. 检查是否已映射（跳过）
   b. 读取 groupType
   c. 如果是 "group" 类型：
      - 读取 chat_id
      - 转换 hex 字符串为二进制
      - 调用 tox_group_join(chat_id)
      - 等待 onGroupSelfJoin 回调
      - 在 HandleGroupSelfJoin 中重建映射
```

#### Conference 类型恢复

```
1. 查询 tox_conference_get_chatlist() 获取已恢复的 conferences
   ↓
2. 对每个 known group_id：
   a. 检查 groupType
   b. 如果是 "conference" 类型：
      - 查找未映射的 conference_number
      - 将 conference_number 映射到 group_id
      - 重建映射关系
```

### 连接建立后的恢复

当网络连接建立后（`HandleSelfConnectionStatus`），会再次调用 `RejoinKnownGroups()`：

```cpp
void V2TIMManagerImpl::HandleSelfConnectionStatus(...) {
    if (status == TOX_CONNECTION_UDP || status == TOX_CONNECTION_TCP) {
        // 连接建立，延迟后触发恢复（确保连接稳定）
        std::thread([this]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            if (this->IsRunning()) {
                this->RejoinKnownGroups();
            }
        }).detach();
    }
}
```

## 映射关系重建

### Group 类型映射重建

**触发时机**: `onGroupSelfJoin` 回调

**流程**:
```cpp
void V2TIMManagerImpl::HandleGroupSelfJoin(Tox_Group_Number group_number) {
    // 1. 获取 chat_id
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    tox_manager_->getGroupChatId(group_number, chat_id, ...);
    
    // 2. 转换为 hex 字符串
    std::string chat_id_hex = chatIdToHexString(chat_id);
    
    // 3. 查找对应的 group_id（通过存储的 chat_id）
    V2TIMString groupID;
    if (tim2tox_ffi_get_group_chat_id_from_storage(...)) {
        // 找到匹配的 group_id
        groupID = V2TIMString(found_group_id);
    }
    
    // 4. 重建映射
    group_id_to_group_number_[groupID] = group_number;
    group_number_to_group_id_[group_number] = groupID;
    group_id_to_chat_id_[groupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
    chat_id_to_group_id_[chat_id_hex] = groupID;
}
```

### Conference 类型映射重建

**触发时机**: `RejoinKnownGroups()` 中

**流程**:
```cpp
void V2TIMManagerImpl::RejoinKnownGroups() {
    // 1. 查询已恢复的 conferences
    size_t conference_count = tox_conference_get_chatlist_size(tox);
    std::vector<Tox_Conference_Number> conference_list(conference_count);
    tox_conference_get_chatlist(tox, conference_list.data());
    
    // 2. 对每个 known group_id（conference 类型）
    for (每个 group_id) {
        if (group_type == "conference") {
            // 3. 查找未映射的 conference_number
            for (Tox_Conference_Number conf_num : conference_list) {
                if (!conf_num 已映射) {
                    // 4. 映射到 group_id
                    group_id_to_group_number_[groupID] = conf_num;
                    group_number_to_group_id_[conf_num] = groupID;
                    break;
                }
            }
        }
    }
}
```

## 数据一致性

### 确保数据一致性

1. **创建时立即存储**: 创建群组后立即存储 `groupType` 和 `chat_id`（如果适用）
2. **恢复时验证**: 恢复时检查 `groupType` 是否匹配
3. **默认值处理**: 如果 `groupType` 丢失，默认使用 "group" 类型

### 数据迁移

对于旧数据（没有 `groupType` 信息）：
- 默认假设为 "group" 类型
- 如果找不到 `chat_id`，可能是 "conference" 类型
- 可以通过检查是否有 `chat_id` 来推断类型

## 故障排除

### Group 恢复失败

**症状**: Group 类型的群组在重启后无法恢复

**检查清单**:
1. ✅ `groupType` 是否正确存储为 "group"
2. ✅ `chat_id` 是否正确存储
3. ✅ 网络连接是否建立
4. ✅ 群组中是否有其他在线 peer

**日志检查**:
```
RejoinKnownGroups: Attempting to rejoin group <group_id> using chat_id <chat_id>
RejoinKnownGroups: Successfully rejoined group <group_id>, group_number=<number>
```

### Conference 恢复失败

**症状**: Conference 类型的群组在重启后无法恢复

**检查清单**:
1. ✅ `groupType` 是否正确存储为 "conference"
2. ✅ savedata 文件是否存在且有效
3. ✅ `conference_number` 是否成功匹配到 `group_id`

**日志检查**:
```
RejoinKnownGroups: Found <count> conferences restored from savedata
RejoinKnownGroups: Matched conference_number=<number> to groupID=<group_id>
```

### 类型信息丢失

**症状**: 无法区分 group 和 conference 类型

**解决方法**:
1. 检查 `groupType` 存储是否成功
2. 如果丢失，根据是否有 `chat_id` 推断类型
3. 对于新创建的群组，确保 `groupType` 正确存储

## 最佳实践

1. **优先使用 Group 类型**: 功能更完整，恢复更可靠
2. **确保类型信息存储**: 创建群组后立即验证 `groupType` 是否存储成功
3. **定期备份 savedata**: 确保 Conference 类型可以恢复
4. **监控恢复日志**: 及时发现恢复问题
5. **网络连接检查**: 确保网络连接建立后再检查恢复状态

## 相关文档

- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) - Tim2Tox 架构（包含群聊实现说明）
- [API_REFERENCE.md](../api/API_REFERENCE.md) - API 参考文档
- 客户端群聊功能与 UI 说明见各客户端项目文档（当 Tim2Tox 作为 submodule 使用时，常见于上层仓库的 doc）。
