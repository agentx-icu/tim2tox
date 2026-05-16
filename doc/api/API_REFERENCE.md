# Tim2Tox API 参考
> 语言 / Language: [中文](API_REFERENCE.md) | [English](API_REFERENCE.en.md)

本文档为 Tim2Tox 的 API 索引入口，详细接口按模块拆分到子文档。

## 目录

- [V2TIM C++ API](API_REFERENCE_V2TIM.md) — C++ V2TIM 接口（与腾讯云 IM SDK 兼容）
- [C FFI 接口](API_REFERENCE_FFI.md) — C 语言绑定，供 Dart FFI 调用
- [Dart 包 API](API_REFERENCE_DART.md) — Dart 高级 API 与接口定义
- [数据类型](#数据类型) — 通用数据类型（本文档）
- [回调类型](#回调类型)
- [错误码](#错误码)
- [使用示例](#使用示例)
- [相关文档](#相关文档)

## 数据类型

### V2TIMString

字符串类型，兼容 C++ 和 Dart。

```cpp
class V2TIMString {
    const char* CString() const;
    // ...
};
```

### V2TIMBuffer

二进制数据缓冲区。

```cpp
class V2TIMBuffer {
    const uint8_t* Data() const;
    size_t Size() const;
    // ...
};
```

### V2TIMMessage

消息对象。仅列出最常用字段，完整定义见 `include/V2TIMMessage.h:302`。

```cpp
struct V2TIMMessage : V2TIMBaseObject {
    V2TIMString msgID;
    int64_t     timestamp;
    V2TIMString sender;
    V2TIMString groupID;        // 群消息所属群组 ID（C2C 消息为空）
    V2TIMString userID;         // 对端账号 ID（C2C 场景）
    V2TIMElemVector elemList;   // 消息元素列表（文本 / 图片 / 文件 / 自定义等）
    // ...（status, isSelf, isRead, cloudCustomData, localCustomData 等）
};
```

### V2TIMFriendInfo

好友信息（`include/V2TIMFriendship.h:249`）。注意 `nickName` / `faceURL` 不在顶层，位于嵌套的 `userFullInfo` 字段中。

```cpp
struct V2TIMFriendInfo {
    V2TIMString        userID;            // 好友 ID
    V2TIMString        friendRemark;       // 好友备注（不超过 96 字节）
    uint64_t           friendAddTime;      // 添加好友的 UTC 时间戳
    V2TIMCustomInfo    friendCustomInfo;   // 好友自定义字段
    V2TIMStringVector  friendGroups;       // 好友所在分组列表
    V2TIMUserFullInfo  userFullInfo;       // 嵌套：包含 nickName / faceURL 等基础资料
    uint32_t           modifyFlag;         // 修改标记位（V2TIMFriendInfoModifyFlag 按位或）
};
```

### V2TIMGroupInfo

群组信息（`include/V2TIMGroup.h:324`，实际字段顺序为 groupID → groupType → groupName）。

```cpp
struct V2TIMGroupInfo {
    V2TIMString groupID;
    V2TIMString groupType;      // "group" (新 API) 或 "conference" (旧 API)
    V2TIMString groupName;
    V2TIMString notification;   // 群公告（仅 Group 类型支持，对应 tox_group_topic）
    V2TIMString introduction;
    // ...（faceURL, owner, createTime, memberCount 等）
};
```

**V2TIMGroupMemberFullInfo**（`include/V2TIMGroup.h:211`，继承自 `V2TIMGroupMemberInfo`）：

```cpp
// 父类 V2TIMGroupMemberInfo 提供：userID / nickName / friendRemark / nameCard / faceURL / onlineDevices
struct V2TIMGroupMemberFullInfo : public V2TIMGroupMemberInfo {
    V2TIMCustomInfo customInfo;
    uint32_t        role;        // V2TIM_GROUP_MEMBER_ROLE_{OWNER,ADMIN,MEMBER}
    uint32_t        muteUntil;   // 禁言结束时间戳
    int64_t         joinTime;
    bool            isOnline;
    uint32_t        modifyFlag;
};
```

> tim2tox 实现：`nickName` 取自好友资料；`nameCard` 取自 `tox_group_peer_get_name`，仅 Group 类型支持。

## 回调类型

### V2TIMCallback

通用回调接口（`include/V2TIMCallback.h:34`）。它是抽象类，请通过继承覆写两个虚函数，不能用 lambda 直接构造。

```cpp
class V2TIMCallback : public V2TIMBaseCallback {
    virtual void OnSuccess() = 0;
    virtual void OnError(int error_code, const V2TIMString& error_message) = 0;
};
```

### V2TIMValueCallback

带返回值的回调接口（`include/V2TIMCallback.h:59`）。

```cpp
template<class T>
class V2TIMValueCallback : public V2TIMBaseCallback {
    virtual void OnSuccess(const T& value) = 0;
    virtual void OnError(int error_code, const V2TIMString& error_message) = 0;
};
```

### V2TIMSendCallback

消息发送回调接口（`include/V2TIMCallback.h:101`，继承自 `V2TIMValueCallback<V2TIMMessage>`，因此 `OnSuccess(const V2TIMMessage&)` 来自基类）。

```cpp
class V2TIMSendCallback : public V2TIMValueCallback<V2TIMMessage> {
    // OnSuccess(const V2TIMMessage&) 和 OnError(...) 继承自父类
    virtual void OnProgress(uint32_t progress) = 0;
};
```

## 错误码

常见错误码定义在 `include/V2TIMErrorCode.h` 中：

- `ERR_SUCC` (0): 成功
- `ERR_SDK_NOT_INITIALIZED` (6013): SDK 未初始化
- `ERR_INVALID_PARAMETERS` (6017): 无效参数
- `ERR_USER_SIG_EXPIRED` (6206): 用户签名过期
- `ERR_SDK_COMM_API_CALL_FREQUENCY_LIMIT` (7008): API 调用频率限制

## 使用示例

### C++ 使用示例

`V2TIMCallback` / `V2TIMSendCallback` 都是抽象类，请用继承的方式提供实现：

```cpp
#include <V2TIMManager.h>

// 自定义一个无返回值回调
class MyCallback : public V2TIMCallback {
public:
    void OnSuccess() override { /* 成功 */ }
    void OnError(int code, const V2TIMString& msg) override { /* 失败 */ }
};

int main() {
    // 初始化 SDK
    V2TIMSDKConfig config;
    config.logLevel = V2TIM_LOG_DEBUG;
    V2TIMManager::GetInstance()->InitSDK(123456, config);

    // 登录
    V2TIMManager::GetInstance()->Login(
        V2TIMString("user123"),
        V2TIMString("userSig"),
        new MyCallback()
    );

    // 发送消息
    // 真实签名（include/V2TIMMessageManager.h:235）：
    //   virtual V2TIMString SendMessage(V2TIMMessage& message,
    //                                   const V2TIMString& receiver,
    //                                   const V2TIMString& groupID,
    //                                   V2TIMMessagePriority priority,
    //                                   bool onlineUserOnly,
    //                                   const V2TIMOfflinePushInfo& offlinePushInfo,
    //                                   V2TIMSendCallback* callback) = 0;
    auto* msgMgr = V2TIMManager::GetInstance()->GetMessageManager();
    V2TIMMessage msg = msgMgr->CreateTextMessage(V2TIMString("Hello"));
    V2TIMOfflinePushInfo emptyPushInfo;
    V2TIMString msgID = msgMgr->SendMessage(
        msg,
        /*receiver=*/V2TIMString("friend123"),
        /*groupID=*/V2TIMString(),                       // C2C 时留空
        V2TIMMessagePriority::V2TIM_PRIORITY_NORMAL,
        /*onlineUserOnly=*/false,
        emptyPushInfo,
        new MySendCallback()                              // 自定义子类
    );
    return 0;
}
```

### Dart 使用示例

```dart
import 'package:tim2tox_dart/tim2tox_dart.dart';

// 创建服务
final ffiService = FfiChatService(
  preferencesService: prefsAdapter,           // ExtendedPreferencesService 实现
  loggerService: loggerAdapter,
  bootstrapService: bootstrapAdapter,
);

// 初始化
await ffiService.init();

// 登录
await ffiService.login(userId: userID, userSig: userSig);

// 发送 C2C 文本消息（注意方法名是 sendText，不是 sendMessage）
await ffiService.sendText(peerId, "Hello");

// 监听消息
ffiService.messages.listen((message) {
  print('Received: ${message.text}');
});
```

> Platform 路径（`Tim2ToxSdkPlatform`）暴露的接口更接近 V2TIM 风格（`sendMessage` 等），见 [API_REFERENCE_DART.md](API_REFERENCE_DART.md)。`FfiChatService` 自身使用更直接的小写方法名（`sendText` / `sendTyping` / `sendC2CCustom` 等），不要混淆两者。

## 相关文档

- [开发指南](../development/DEVELOPMENT_GUIDE.md) - 如何添加新功能和扩展
- [Tim2Tox 架构](../architecture/ARCHITECTURE.md) - 整体架构设计
- [Tim2Tox FFI 兼容层](../architecture/FFI_COMPAT_LAYER.md) - Dart* 函数兼容层说明
