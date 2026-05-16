# Tim2Tox Restore and Persistence
> Language: [Chinese](RESTORE_AND_PERSISTENCE.md) | [English](RESTORE_AND_PERSISTENCE.en.md)


This document details the persistence and recovery mechanism of group chat in Tim2Tox, including two types of processing methods: Group and Conference.

## Overview

Tim2Tox needs to persist the following information to ensure that the group can be restored correctly after the client restarts:

1. **groupType**: group type ("group" or "conference")
2. **chat_id**: Unique identifier of Group type (Group type only)
3. **group_id**: Application layer group identifier
4. **savedata**: Tox’s savedata (including Conference information)

## Persistent data

### 1. groupType

**Storage location**: `SharedPreferences` (via FFI callback)

**Storage format**: String "group" or "conference"

**Storage Timing**: When creating a group

**Storage**:
```cpp
// C++ side (multi-instance: first arg is int64_t instance_id; pass 0 for the production singleton)
extern "C" int tim2tox_ffi_set_group_type(int64_t instance_id,
                                          const char* group_id,
                                          const char* group_type);
tim2tox_ffi_set_group_type(/*instance=*/0, groupID, "group");  // or "conference"
```

Dart side: the current `Tim2ToxSdkPlatform` customCallback only handles `groupChatIdStored`, `clearHistoryMessage`, and `groupQuitNotification`. `groupType` is persisted by the C++ side directly through the injected `ExtendedPreferencesService.setGroupType(...)` — there is no separate `case "groupTypeStored"` on the Dart side.

**Reading**:
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

### 2. chat_id (Group type only)

**Storage location**: `SharedPreferences` (via FFI callback)

**Storage Format**: 64-character hexadecimal string (32 bytes)

**Storage Timing**: When creating or joining a Group type group

**Storage**:
```cpp
extern "C" int tim2tox_ffi_set_group_chat_id(int64_t instance_id,
                                             const char* group_id,
                                             const char* chat_id);
tim2tox_ffi_set_group_chat_id(/*instance=*/0, groupID, chat_id_hex);

// Dart side: Tim2ToxSdkPlatform's customCallback handles "groupChatIdStored"
// (see tim2tox_sdk_platform.dart)
case "groupChatIdStored":
    await preferencesService.setGroupChatId(groupId, chatId);
    break;
```

**Reading**:
```cpp
extern "C" int tim2tox_ffi_get_group_chat_id_from_storage(int64_t instance_id,
                                                          const char* group_id,
                                                          char* out_chat_id,
                                                          int out_len);
char stored_chat_id[65];
if (tim2tox_ffi_get_group_chat_id_from_storage(/*instance=*/0, group_id,
                                               stored_chat_id, sizeof(stored_chat_id)) == 1) {
    // use stored_chat_id
}
```

### 3. savedata (Conference type)

**Storage location**: Tox automatically managed (via `tox_get_savedata` / `tox_new`)

**Storage format**: Binary data

**Storage timing**: Tox is saved regularly (through `tox_save` callback)

**Recovery method**: Load savedata through `tox_new` during Tox initialization

## Recovery process

### Recovery when InitSDK

In `V2TIMManagerImpl::InitSDK()`:

1. **Load savedata**: Tox is automatically loaded during initialization, and conferences will be automatically restored.
2. **Query restored groups**: Call `tox_manager_->getGroupListSize()` and `getGroupList()`
3. **Manual trigger callback**: Call `HandleGroupSelfJoin()` to rebuild the mapping for each restored group
4. **Query resumed conferences**: Call `tox_conference_get_chatlist_size()` and `tox_conference_get_chatlist()`
5. **Call RejoinKnownGroups()**: Start the recovery process

### RejoinKnownGroups recovery process

**File**: `tim2tox/source/V2TIMManagerImpl.cpp::RejoinKnownGroups()`

#### Group type recovery

```
1. Get all knownGroups from Dart layer
   ↓
2. For each group_id:
   a. Check if mapped (skip)
   b. Read groupType
   c. If it is "group" type:
      - Read chat_id
      - Convert hex string to binary
      - Call tox_group_join(chat_id)
      - Wait for onGroupSelfJoin callback
      - Rebuild mapping in HandleGroupSelfJoin
```

#### Conference type recovery

```
1. Query tox_conference_get_chatlist() to obtain restored conferences
   ↓
2. For each known group_id:
   a. Check groupType
   b. If it is "conference" type:
      - Find unmapped conference_number
      - Map conference_number to group_id
      - Rebuild mapping relationship
```

### Recovery after connection establishment

When the network connection is established (`HandleSelfConnectionStatus`), `RejoinKnownGroups()` will be called again:

```cpp
void V2TIMManagerImpl::HandleSelfConnectionStatus(...) {
    if (status == TOX_CONNECTION_UDP || status == TOX_CONNECTION_TCP) {
        // The connection is established, and recovery is triggered after a delay (to ensure a stable connection)
        std::thread([this]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            if (this->IsRunning()) {
                this->RejoinKnownGroups();
            }
        }).detach();
    }
}
```

## Mapping relationship reconstruction

### Group type mapping reconstruction

**Trigger timing**: `onGroupSelfJoin` callback

**Process**:
```cpp
void V2TIMManagerImpl::HandleGroupSelfJoin(Tox_Group_Number group_number) {
    // 1. Get chat_id
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    tox_manager_->getGroupChatId(group_number, chat_id, ...);
    
    // 2. Convert to hex string
    std::string chat_id_hex = chatIdToHexString(chat_id);
    
    // 3. Find the corresponding group_id (through the stored chat_id)
    V2TIMString groupID;
    if (tim2tox_ffi_get_group_chat_id_from_storage(...)) {
        // Find matching group_id
        groupID = V2TIMString(found_group_id);
    }
    
    // 4. Rebuild mapping
    group_id_to_group_number_[groupID] = group_number;
    group_number_to_group_id_[group_number] = groupID;
    group_id_to_chat_id_[groupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
    chat_id_to_group_id_[chat_id_hex] = groupID;
}
```

### Conference type mapping reconstruction

**Trigger Timing**: `RejoinKnownGroups()` Medium

**Process**:
```cpp
void V2TIMManagerImpl::RejoinKnownGroups() {
    // 1. Query restored conferences
    size_t conference_count = tox_conference_get_chatlist_size(tox);
    std::vector<Tox_Conference_Number> conference_list(conference_count);
    tox_conference_get_chatlist(tox, conference_list.data());
    
    // 2. For each known group_id (conference type)
    for (each group_id) {
        if (group_type == "conference") {
            // 3. Find unmapped conference_number
            for (Tox_Conference_Number conf_num : conference_list) {
                if (!conf_num mapped) {
                    // 4. Map to group_id
                    group_id_to_group_number_[groupID] = conf_num;
                    group_number_to_group_id_[conf_num] = groupID;
                    break;
                }
            }
        }
    }
}
```

## Data consistency

### Ensure data consistency

1. **Store immediately upon creation**: Store `groupType` and `chat_id` immediately after creating the group (if applicable)
2. **Verification during recovery**: Check whether `groupType` matches during recovery
3. **Default value processing**: If `groupType` is missing, the "group" type will be used by default

### Data migration

For old data (no `groupType` information):
- Default assumes type "group"
- If `chat_id` is not found, it may be of type "conference"
- The type can be inferred by checking if there is `chat_id`

## Troubleshooting

### Group recovery failed

**Symptoms**: Groups of type Group cannot be restored after restarting

**CHECKLIST**:
1. ✅ Is `groupType` correctly stored as "group"
2. ✅ Is `chat_id` stored correctly?
3. ✅ Is the network connection established?
4. ✅ Are there other online peers in the group?

**Log check**:
```
RejoinKnownGroups: Attempting to rejoin group <group_id> using chat_id <chat_id>
RejoinKnownGroups: Successfully rejoined group <group_id>, group_number=<number>
```

### Conference recovery failed

**Symptom**: Conference type groups cannot be restored after restarting

**CHECKLIST**:
1. ✅ Is `groupType` correctly stored as "conference"
2. ✅ Whether the savedata file exists and is valid?
3. ✅ Is `conference_number` successfully matched to `group_id`?

**Log check**:
```
RejoinKnownGroups: Found <count> conferences restored from savedata
RejoinKnownGroups: Matched conference_number=<number> to groupID=<group_id>
```

### Type information is lost

**Symptoms**: Unable to distinguish between group and conference types

**Solution**:
1. Check whether `groupType` storage is successful
2. If lost, infer the type based on whether there is `chat_id`
3. For newly created groups, make sure `groupType` is stored correctly

## Best Practices

1. **Group type is preferred**: more complete functions and more reliable recovery
2. **Ensure type information is stored**: Immediately after creating the group, verify whether `groupType` is stored successfully
3. **Regular backup savedata**: Ensure that the Conference type can be restored
4. **Monitor recovery log**: Discover recovery problems in time
5. **Network connection check**: Make sure the network connection is established and then check the recovery status

## Related documents

- [ARCHITECTURE.en.md](../architecture/ARCHITECTURE.en.md) - Tim2Tox architecture (including group-chat implementation notes)
- [API_REFERENCE.en.md](../api/API_REFERENCE.en.md) - API reference documentation
- For client-side group chat and UI, see each client project’s documentation (e.g. when Tim2Tox is used as a submodule, the parent repo’s doc).