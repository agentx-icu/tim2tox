// Copyright (c) 2021 Tencent. All rights reserved.

#ifndef __V2TIM_GROUP_H__
#define __V2TIM_GROUP_H__

#include "V2TIMCommon.h"
#include "V2TIMDefine.h"

/////////////////////////////////////////////////////////////////////////////////
//
//                    （一）枚举值定义
//
/////////////////////////////////////////////////////////////////////////////////

/// 群成员角色
enum V2TIMGroupMemberRole {
    /// 未定义（没有获取该字段）
    V2TIM_GROUP_MEMBER_UNDEFINED = 0,
    /// 群成员
    V2TIM_GROUP_MEMBER_ROLE_MEMBER = 200,
    /// 群管理员
    V2TIM_GROUP_MEMBER_ROLE_ADMIN = 300,
    /// 群主
    V2TIM_GROUP_MEMBER_ROLE_SUPER = 400,
};

/// 群变更信息 Tips 类型
enum V2TIMGroupInfoChangeType {
    /// 群名修改
    V2TIM_GROUP_INFO_CHANGE_TYPE_NAME = 0x01,
    /// 群简介修改
    V2TIM_GROUP_INFO_CHANGE_TYPE_INTRODUCTION = 0x02,
    /// 群公告修改
    V2TIM_GROUP_INFO_CHANGE_TYPE_NOTIFICATION = 0x03,
    /// 群头像修改
    V2TIM_GROUP_INFO_CHANGE_TYPE_FACE = 0x04,
    /// 群主变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_OWNER = 0x05,
    /// 群自定义字段变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_CUSTOM = 0x06,
    /// 全员禁言字段变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_SHUT_UP_ALL = 0x08,
    /// 话题自定义字段变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_TOPIC_CUSTOM_DATA = 0x09,
    /// 消息接收选项变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_RECEIVE_MESSAGE_OPT = 0x0A,
    /// 申请加群方式下管理员审批选项变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_GROUP_ADD_OPT = 0x0B,
    /// 邀请进群方式下管理员审批选项变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_GROUP_APPROVE_OPT = 0x0C,
    /// 是否开启权限组功能变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_ENABLE_PERMISSION_GROUP = 0x0D,
    /// 群默认权限变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_DEFAULT_PERMISSIONS = 0x0E,
    /// 申请加入私密话题时管理员的审批选项变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_TOPIC_ADD_OPT = 0x0F,
    /// 邀请进入私密话题时管理员的审批选项变更
    V2TIM_GROUP_INFO_CHANGE_TYPE_TOPIC_APPROVE_OPT = 0x10,
    /// 私密话题最大成员数量
    V2TIM_GROUP_INFO_CHANGE_TYPE_TOPIC_MEMBER_MAX_COUNT = 0x11,
};

/// 加群选项
enum V2TIMGroupAddOpt {
    /// 禁止加群
    V2TIM_GROUP_ADD_FORBID = 0,
    /// 需要管理员审批
    V2TIM_GROUP_ADD_AUTH = 1,
    /// 任何人可以加入
    V2TIM_GROUP_ADD_ANY = 2,
    /// 未定义
    V2TIM_GROUP_ADD_UNKNOWN = 3,
};

/// 群资料修改标记位
enum V2TIMGroupInfoModifyFlag {
    /// 未定义
    V2TIM_GROUP_INFO_MODIFY_FLAG_UNKNOWN = 0x00,
    /// 名称
    V2TIM_GROUP_INFO_MODIFY_FLAG_GROUP_NAME = 0x01,
    /// 公告
    V2TIM_GROUP_INFO_MODIFY_FLAG_NOTIFICATION = 0x01 << 1,
    /// 简介
    V2TIM_GROUP_INFO_MODIFY_FLAG_INTRODUCTION = 0x01 << 2,
    /// 头像
    V2TIM_GROUP_INFO_MODIFY_FLAG_FACE_URL = 0x01 << 3,
    /// 申请加群管理员审批选项
    V2TIM_GROUP_INFO_MODIFY_FLAG_GROUP_ADD_OPTION = 0x01 << 4,
    /// 禁言
    V2TIM_GROUP_INFO_MODIFY_FLAG_SHUTUP_ALL = 0x01 << 8,
    /// 群自定义数据
    V2TIM_GROUP_INFO_MODIFY_FLAG_CUSTOM_INFO = 0x01 << 9,
    /// 话题自定义字段
    V2TIM_TOPIC_INFO_MODIFY_FLAG_CUSTOM_STRING = 0x1 << 11,
    /// 邀请进群管理员审批选项
    V2TIM_GROUP_INFO_MODIFY_FLAG_GROUP_APPROVE_OPTION = 0x1 << 12,
    /// 开启权限组功能，仅支持社群，7.8 版本开始支持
    V2TIM_GROUP_INFO_MODIFY_FLAG_ENABLE_PERMISSION_GROUP = 0x1 << 13,
    /// 群默认权限，仅支持社群，7.8 版本开始支持
    V2TIM_GROUP_INFO_MODIFY_FLAG_DEFAULT_PERMISSIONS = 0x1 << 14,
};

///  群组操作结果
enum V2TIMGroupMemberResult {
    /// 操作失败
    V2TIM_GROUP_MEMBER_RESULT_FAIL = 0,
    /// 操作成功
    V2TIM_GROUP_MEMBER_RESULT_SUCC = 1,
    /// 无效操作，加群时已经是群成员，移除群组时不在群内
    V2TIM_GROUP_MEMBER_RESULT_INVALID = 2,
    /// 等待处理，邀请入群时等待审批
    V2TIM_GROUP_MEMBER_RESULT_PENDING = 3,
    /// 操作失败，创建群指定初始群成员列表或邀请入群时，被邀请者加入的群总数超限
    V2TIM_GROUP_MEMBER_RESULT_OVERLIMIT = 4,
};

/// 群成员角色过滤方式
enum V2TIMGroupMemberFilter {
    /// 全部成员
    V2TIM_GROUP_MEMBER_FILTER_ALL = 0x00,
    /// 群主
    V2TIM_GROUP_MEMBER_FILTER_OWNER = 0x01,
    /// 管理员
    V2TIM_GROUP_MEMBER_FILTER_ADMIN = 0x02,
    /// 普通成员
    V2TIM_GROUP_MEMBER_FILTER_COMMON = 0x04,
};

/// 群成员资料修改标记位
enum V2TIMGroupMemberInfoModifyFlag {
    /// 未定义
    V2TIM_GROUP_MEMBER_INFO_MODIFY_FLAG_UNKNOWN = 0x00,
    /// 群内角色
    V2TIM_GROUP_MEMBER_INFO_MODIFY_FLAG_MEMBER_ROLE = 0x01 << 1,
    /// 禁言时间
    V2TIM_GROUP_MEMBER_INFO_MODIFY_FLAG_SHUTUP_TIME = 0x01 << 2,
    /// 群名片
    V2TIM_GROUP_MEMBER_INFO_MODIFY_FLAG_NAME_CARD = 0x01 << 3,
    /// 群成员自定义数据
    V2TIM_GROUP_MEMBER_INFO_MODIFY_FLAG_CUSTOM_INFO = 0x01 << 4,
};

/// 群组未决请求类型
enum V2TIMGroupApplicationType {
    /// 申请入群
    V2TIM_GROUP_JOIN_APPLICATION_NEED_APPROVED_BY_ADMIN = 0x0,
    /// 等待被邀请者同意的邀请入群请求
    V2TIM_GROUP_INVITE_APPLICATION_NEED_APPROVED_BY_INVITEE = 0x1,
    /// 等待被群主或管理员审批的邀请入群请求
    V2TIM_GROUP_INVITE_APPLICATION_NEED_APPROVED_BY_ADMIN = 0x2,
};

/// 群组已决标志
enum V2TIMGroupApplicationHandleStatus {
    /// 未处理
    V2TIM_GROUP_APPLICATION_HANDLE_STATUS_UNHANDLED = 0,
    /// 被他人处理
    V2TIM_GROUP_APPLICATION_HANDLE_STATUS_HANDLED_BY_OTHER = 1,
    /// 自己已处理
    V2TIM_GROUP_APPLICATION_HANDLE_STATUS_HANDLED_BY_SELF = 2,
};

/// 群组已决结果
enum V2TIMGroupApplicationHandleResult {
    /// 拒绝申请
    V2TIM_GROUP_APPLICATION_HANDLE_RESULT_REFUSE = 0,
    /// 同意申请
    V2TIM_GROUP_APPLICATION_HANDLE_RESULT_AGREE = 1,
};

/// @ 类型
enum V2TIMGroupAtType {
    /// @ 我
    V2TIM_AT_ME = 1,
    /// @ 群里所有人
    V2TIM_AT_ALL = 2,
    /// @ 群里所有人并且单独 @ 我
    V2TIM_AT_ALL_AT_ME = 3,
};

/////////////////////////////////////////////////////////////////////////////////
//
//                     （二）结构体定义
//
/////////////////////////////////////////////////////////////////////////////////

/// 群成员基本资料
struct TIM_API V2TIMGroupMemberInfo {
    /// 用户 ID
    V2TIMString userID;
    /// 用户昵称
    V2TIMString nickName;
    /// 用户好友备注
    V2TIMString friendRemark;
    /// 群成员名片
    V2TIMString nameCard;
    /// 用户头像
    V2TIMString faceURL;
    /// 在线终端列表
    V2TIMStringVector onlineDevices;
    
    V2TIMGroupMemberInfo();
    V2TIMGroupMemberInfo(const V2TIMGroupMemberInfo& groupMemberInfo);
    ~V2TIMGroupMemberInfo();
};

DEFINE_VECTOR(V2TIMGroupMemberInfo)
typedef TXV2TIMGroupMemberInfoVector V2TIMGroupMemberInfoVector;

/// 群成员详细资料
struct TIM_API V2TIMGroupMemberFullInfo : public V2TIMGroupMemberInfo {
    /// 群成员自定义字段
    /// 首先要在 [控制台](https://console.cloud.tencent.com/im) (功能配置 -> 群成员自定义字段)
    /// 配置用户自定义字段，然后再调用该接口进行设置。
    V2TIMCustomInfo customInfo;
    /// 群成员角色,修改群成员角色请调用 V2TIMManagerGroup.h -> SetGroupMemberRole 接口
    uint32_t role = 0;
    /// 群成员禁言结束时间戳，禁言用户请调用 V2TIMManagerGroup.h -> MuteGroupMember 接口
    uint32_t muteUntil = 0;
    /// 群成员入群时间，自动生成，不可修改
    int64_t joinTime = 0;
    /// 群成员是否在线
    /// @note 请注意：
    /// - 不支持直播群 AVChatRoom；
    /// - 该字段仅在调用 getGroupMemberList 接口时有效；
    /// - 7.3 及其以上版本支持，需要您购买旗舰版套餐。
    bool isOnline = false;
    /// 群成员资料修改标记位
    /// 枚举 V2TIMGroupMemberInfoModifyFlag 列出哪些字段支持修改，如果您修改群成员资料，请设置这个字段值
    /// 支持同时修改多个字段，多个枚举值按位或 | 组合，例如，同时修改群成员名片和群成员角色
    /// info.nameCard = "new name card";
    /// info.role = V2TIM_GROUP_MEMBER_ROLE_ADMIN;
    /// info.modifyFlag = V2TIM_GROUP_MEMBER_INFO_MODIFY_FLAG_NAME_CARD | V2TIM_GROUP_MEMBER_INFO_MODIFY_FLAG_MEMBER_ROLE;
    uint32_t modifyFlag = 0;

    V2TIMGroupMemberFullInfo();
    V2TIMGroupMemberFullInfo(const V2TIMGroupMemberFullInfo& groupMemberFullInfo);
    ~V2TIMGroupMemberFullInfo();
};

DEFINE_VECTOR(V2TIMGroupMemberFullInfo)
typedef TXV2TIMGroupMemberFullInfoVector V2TIMGroupMemberFullInfoVector;

/// 获取群成员信息的结果
struct TIM_API V2TIMGroupMemberInfoResult {
    ///获取分页拉取的 seq。如果为 0 表示拉取结束
    uint64_t nextSequence = 0;
    // 群成员信息列表
    V2TIMGroupMemberFullInfoVector memberInfoList;

    V2TIMGroupMemberInfoResult();
    V2TIMGroupMemberInfoResult(const V2TIMGroupMemberInfoResult& groupMemberInfoResult);
    ~V2TIMGroupMemberInfoResult();
};

/// 群 tips，群变更信息
struct TIM_API V2TIMGroupChangeInfo {
    /// 变更类型
    V2TIMGroupInfoChangeType type = static_cast<V2TIMGroupInfoChangeType>(0);
    /// 根据变更类型表示不同的值,例如 type = V2TIM_GROUP_INFO_CHANGE_TYPE_NAME，value 表示群新的
    /// groupName
    V2TIMString value;
    /// 变更自定义字段的 key 值（type = V2TIM_GROUP_INFO_CHANGE_TYPE_CUSTOM 生效）
    /// 因为历史遗留原因，如果只修改了群自定义字段，当前消息不会存漫游和 DB
    V2TIMString key;
    
    /// 根据变更类型表示不同的值
    /// 当前在 type = V2TIM_GROUP_INFO_CHANGE_TYPE_SHUT_UP_ALL 或者 V2TIM_GROUP_INFO_CHANGE_TYPE_ENABLE_PERMISSION_GROUP 时有效
    bool boolValue = false;
    
    /// 根据变更类型表示不同的值
    /// @note 仅针对以下类型有效：
    /// - 从 6.5 版本开始，当 type 为 V2TIM_GROUP_INFO_CHANGE_TYPE_RECEIVE_MESSAGE_OPT 时，该字段标识了群消息接收选项发生了变化，其取值详见 @V2TIMReceiveMessageOpt；
    /// - 从 6.5 版本开始，当 type 为 V2TIM_GROUP_INFO_CHANGE_TYPE_GROUP_ADD_OPT 时，该字段标识了申请加群审批选项发生了变化，其取值详见 @V2TIMGroupAddOpt;
    /// - 从 7.1 版本开始，当 type 为 V2TIM_GROUP_INFO_CHANGE_TYPE_GROUP_APPROVE_OPT 时，该字段标识了邀请进群审批选项发生了变化，取值类型详见 @V2TIMGroupAddOpt。
    /// - 从 8.4 版本开始，当 type 为 V2TIM_GROUP_INFO_CHANGE_TYPE_TOPIC_ADD_OPT 时，该字段标识了申请加私密话题审批选项发生了变化，其取值详见 @V2TIMGroupAddOpt;
    /// - 从 8.4 版本开始，当 type 为 V2TIM_GROUP_INFO_CHANGE_TYPE_TOPIC_APPROVE_OPT 时，该字段标识了邀请进私密话题审批选项发生了变化，取值类型详见 @V2TIMGroupAddOpt。
    uint32_t intValue = 0;

    /// 根据变更类型表示不同的值
    /// 当前只有 type = V2TIM_GROUP_INFO_CHANGE_TYPE_DEFAULT_PERMISSIONS 时有效
    uint64_t uint64Value = 0;

    V2TIMGroupChangeInfo();
    V2TIMGroupChangeInfo(const V2TIMGroupChangeInfo& groupChangeInfo);
    ~V2TIMGroupChangeInfo();
};

DEFINE_VECTOR(V2TIMGroupChangeInfo)
typedef TXV2TIMGroupChangeInfoVector V2TIMGroupChangeInfoVector;

/// 群tips，成员变更信息
struct TIM_API V2TIMGroupMemberChangeInfo {
    /// 变更用户
    V2TIMString userID;
    /// 禁言时间（秒，表示还剩多少秒可以发言）
    uint32_t muteTime = 0;

    V2TIMGroupMemberChangeInfo();
    V2TIMGroupMemberChangeInfo(const V2TIMGroupMemberChangeInfo& groupMemberChangeInfo);
    ~V2TIMGroupMemberChangeInfo();
};

DEFINE_VECTOR(V2TIMGroupMemberChangeInfo)
typedef TXV2TIMGroupMemberChangeInfoVector V2TIMGroupMemberChangeInfoVector;

/// 群 @ 信息
struct TIM_API V2TIMGroupAtInfo {
    /// 消息序列号，即带有 “@我” 或者 “@所有人” 标记的消息的序列号
    uint64_t seq = 0;
    /// @ 提醒类型，分成 “@我” 、“@所有人” 以及 “@我并@所有人” 三类
    V2TIMGroupAtType atType = static_cast<V2TIMGroupAtType>(0);

    V2TIMGroupAtInfo();
    V2TIMGroupAtInfo(const V2TIMGroupAtInfo& groupAtInfo);
    V2TIMGroupAtInfo& operator=(const V2TIMGroupAtInfo& conversation);
    ~V2TIMGroupAtInfo();
};

DEFINE_VECTOR(V2TIMGroupAtInfo)
typedef TXV2TIMGroupAtInfoVector V2TIMGroupAtInfoVector;

/// 群资料
struct TIM_API V2TIMGroupInfo {
    /// 群组 ID
    /// 自定义群组 ID 必须为可打印 ASCII 字符（0x20-0x7e），最长 48 个字节，且前缀不能为
    /// @TGS#（避免与默认分配的群组 ID 混淆）
    V2TIMString groupID;
    /// 群类型
    V2TIMString groupType;
    /// 社群是否支持创建话题，只在群类型为 Community 时有效
    bool isSupportTopic = false;
    /// 群名称
    /// 群名称最长 100 字节，使用 UTF-8 编码
    V2TIMString groupName;
    /// 群公告
    /// 群公告最长 400 字节，使用 UTF-8 编码
    V2TIMString notification;
    /// 群简介
    /// 群简介最长 400 字节，使用 UTF-8 编码
    V2TIMString introduction;
    /// 群头像
    /// 群头像 URL 最长 500 字节，使用 UTF-8 编码
    V2TIMString faceURL;
    /// 是否全员禁言
    bool allMuted = false;
    /// 设置群自定义字段需要两个步骤：
    /// 1.在 [控制台](https://console.cloud.tencent.com/im) (功能配置 -> 群自定义字段)
    /// 配置群自定义字段的 key 值，Key 为 V2TIMString 类型，长度不超过 16 字节。 2.调用 SetGroupInfo
    /// 接口设置该字段，value 为 V2TIMSBuffer 数据，长度不超过 512 字节。
    V2TIMCustomInfo customInfo;
    /// 群创建人/管理员
    V2TIMString owner;
    /// 创建群组的 UTC 时间戳
    uint32_t createTime = 0;
    /// 申请进群是否需要管理员审批：工作群（Work）默认值为 V2TIM_GROUP_ADD_FORBID，即默认不允许申请入群，您可以修改该字段打开申请入群方式。
    V2TIMGroupAddOpt groupAddOpt = V2TIM_GROUP_ADD_FORBID;
    /// 邀请进群是否需要管理员审批 （从 7.1 版本开始支持）
    /// - 除工作群（Work）之外的其他群类型默认值都为 V2TIM_GROUP_ADD_FORBID，即默认不允许邀请入群，您可以修改该字段打开邀请入群方式。
    /// - 直播群、社群和话题默认不允许邀请入群，也不支持修改。
    V2TIMGroupAddOpt groupApproveOpt = V2TIM_GROUP_ADD_FORBID;
    /// 上次修改群信息的 UTC 时间戳
    uint32_t lastInfoTime = 0;
    /// 群最近一次发消息时间
    uint32_t lastMessageTime = 0;
    /// 已加入的群成员数量
    uint32_t memberCount = 0;
    /// 在线的群成员数量（待废弃字段，请使用 getGroupOnlineMemberCount 接口获取群在线人数）
    uint32_t onlineCount = 0;
    /// 最多允许加入的群成员数量
    /// 各类群成员人数限制详见:
    /// https://cloud.tencent.com/document/product/269/1502#.E7.BE.A4.E7.BB.84.E9.99.90.E5.88.B6.E5.B7.AE.E5.BC.82
    uint32_t memberMaxCount = 0;
    /// 当前用户在此群组中的角色，切换角色请调用 setGroupMemberRole 接口
    uint32_t role = 0;
    /// 当前用户在此群组中的消息接收选项,修改群消息接收选项请调用 SetGroupReceiveMessageOpt 接口
    V2TIMReceiveMessageOpt recvOpt = V2TIM_RECEIVE_MESSAGE;
    /// 当前用户加入此群的 UTC 时间戳，不支持设置，系统自动生成
    uint32_t joinTime = 0;
    /// 是否开启权限组功能，仅支持社群，7.8 版本开始支持
    /// 开启后，管理员角色的权限失效，用群权限、话题权限和权限组能力来对社群、话题进行管理。
    bool enablePermissionGroup = false;
    /// 群默认权限，仅支持社群，7.8 版本开始支持
    /// 群成员在没有加入任何权限组时的默认权限，仅在 enablePermissionGroup = true 打开权限组之后生效
    uint64_t defaultPermissions = 0;
    /// 群资料修改标记位
    /// 枚举 V2TIMGroupInfoModifyFlag 列出哪些字段支持修改，如果您修改群资料，请设置这个字段值
    /// 如果您同时修改多个字段，多个枚举值按位或 | 组合，例如，同时修改群名称和头像
    /// info.groupName = "new group name";
    /// info.faceURL = "new face url";
    /// info.modifyFlag = V2TIM_GROUP_INFO_MODIFY_FLAG_GROUP_NAME |
    /// V2TIM_GROUP_INFO_MODIFY_FLAG_FACE_URL;
    uint32_t modifyFlag = 0;

    V2TIMGroupInfo();
    V2TIMGroupInfo(const V2TIMGroupInfo& groupInfo);
    ~V2TIMGroupInfo();
};

DEFINE_VECTOR(V2TIMGroupInfo)
typedef TXV2TIMGroupInfoVector V2TIMGroupInfoVector;

/// 获取群组资料结果
struct TIM_API V2TIMGroupInfoResult {
    /// 结果 0：成功；非0：失败
    int resultCode = 0;
    /// 如果获取失败，会返回错误信息
    V2TIMString resultMsg;
    /// 如果获取成功，会返回对应的 info
    V2TIMGroupInfo info;

    V2TIMGroupInfoResult();
    V2TIMGroupInfoResult(const V2TIMGroupInfoResult& groupInfoResult);
    ~V2TIMGroupInfoResult();
};

DEFINE_VECTOR(V2TIMGroupInfoResult)
typedef TXV2TIMGroupInfoResultVector V2TIMGroupInfoResultVector;

/// 群申请信息
struct TIM_API V2TIMGroupApplication : V2TIMBaseObject {
    /// 群组 ID
    V2TIMString groupID;
    /// 请求者 userID
    V2TIMString fromUser;
    /// 请求者昵称
    V2TIMString fromUserNickName;
    /// 请求者头像
    V2TIMString fromUserFaceUrl;
    /// 判决者id，有人请求加群:0，邀请其他人加群:被邀请人用户 ID
    V2TIMString toUser;
    /// 申请时间
    uint64_t addTime = 0;
    /// 申请或邀请附加信息
    V2TIMString requestMsg;
    /// 审批信息：同意或拒绝信息
    V2TIMString handledMsg;
    /// 请求类型
    V2TIMGroupApplicationType applicationType = V2TIM_GROUP_JOIN_APPLICATION_NEED_APPROVED_BY_ADMIN;
    /// 处理标志
    V2TIMGroupApplicationHandleStatus handleStatus = V2TIM_GROUP_APPLICATION_HANDLE_STATUS_UNHANDLED;
    /// 处理结果
    V2TIMGroupApplicationHandleResult handleResult = V2TIM_GROUP_APPLICATION_HANDLE_RESULT_REFUSE;

    V2TIMGroupApplication();
    V2TIMGroupApplication(const V2TIMGroupApplication& groupApplication);
    V2TIMGroupApplication& operator=(const V2TIMGroupApplication& groupApplication);
    ~V2TIMGroupApplication() override;
};

DEFINE_VECTOR(V2TIMGroupApplication)
typedef TXV2TIMGroupApplicationVector V2TIMGroupApplicationVector;

/// 邀请其他人入群的操作结果
struct TIM_API V2TIMGroupMemberOperationResult {
    /// 被操作成员
    V2TIMString userID;
    /// 返回状态
    V2TIMGroupMemberResult result = V2TIM_GROUP_MEMBER_RESULT_FAIL;

    V2TIMGroupMemberOperationResult();
    V2TIMGroupMemberOperationResult(
        const V2TIMGroupMemberOperationResult& groupMemberOperationResult);
    ~V2TIMGroupMemberOperationResult();
};

DEFINE_VECTOR(V2TIMGroupMemberOperationResult)
typedef TXV2TIMGroupMemberOperationResultVector V2TIMGroupMemberOperationResultVector;

/// 创建群时指定群成员
struct TIM_API V2TIMCreateGroupMemberInfo {
    // 被操作成员
    V2TIMString userID;
    /// 群成员类型，需要注意一下事项：
    /// 1. role 不设置或则设置为 V2TIM_GROUP_MEMBER_UNDEFINED，进群后默认为群成员。
    /// 2. 工作群（Work）不支持设置 role 为管理员。
    /// 3. 所有的群都不支持设置 role 为群主。
    uint32_t role = 0;

    V2TIMCreateGroupMemberInfo();
    V2TIMCreateGroupMemberInfo(const V2TIMCreateGroupMemberInfo& createGroupMemberInfo);
    ~V2TIMCreateGroupMemberInfo();
};

DEFINE_VECTOR(V2TIMCreateGroupMemberInfo)
typedef TXV2TIMCreateGroupMemberInfoVector V2TIMCreateGroupMemberInfoVector;

/// 加群申请列表
struct TIM_API V2TIMGroupApplicationResult {
    /// 未读的申请数量
    uint64_t unreadCount = 0;
    /// 加群申请的列表
    V2TIMGroupApplicationVector applicationList;

    V2TIMGroupApplicationResult();
    V2TIMGroupApplicationResult(const V2TIMGroupApplicationResult& groupApplicationResult);
    ~V2TIMGroupApplicationResult();
};

/// 群搜索的参数
struct TIM_API V2TIMGroupSearchParam {
    /// 搜索关键字列表，最多支持5个。
    /// 如果是本地搜索，您需主动设置 keyword 是否匹配群 ID、群名称。
    /// 如果是云端搜索，keyword 会自动匹配群 ID、群名称。
    V2TIMStringVector keywordList;
    /// 设置是否搜索群 ID（仅本地搜索有效）
    bool isSearchGroupID = false;
    /// 设置是否搜索群名称（仅本地搜索有效）
    bool isSearchGroupName = false;
    /// 指定关键字列表匹配类型，可设置为“或”关系搜索或者“与”关系搜索（仅云端搜索有效）
    /// 取值分别为 V2TIM_KEYWORD_LIST_MATCH_TYPE_OR 和 V2TIM_KEYWORD_LIST_MATCH_TYPE_AND，默认为“或”关系搜索。
    V2TIMKeywordListMatchType keywordListMatchType = V2TIM_KEYWORD_LIST_MATCH_TYPE_OR;
    /// 每次云端搜索返回结果的条数（必须大于 0，最大支持 100，默认 20，仅云端搜索有效）
    uint32_t searchCount = 0;
    /// 每次云端搜索的起始位置。第一次填空字符串，续拉时填写 V2TIMGroupSearchResult 中的返回值（仅云端搜索有效）
    V2TIMString searchCursor;

    V2TIMGroupSearchParam();
    V2TIMGroupSearchParam(const V2TIMGroupSearchParam& groupSearchParam);
    ~V2TIMGroupSearchParam();
};

/// 群搜索结果的参数
struct TIM_API V2TIMGroupSearchResult {
    /// 满足搜索条件的群列表是否已经全部返回
    bool isFinished = false;
    /// 满足搜索条件的群总数量
    uint32_t totalCount = 0;
    /// 下一次云端搜索的起始位置
    V2TIMString nextCursor;
    /// 当前一次云端搜索返回的群列表
    V2TIMGroupInfoVector groupList;

    V2TIMGroupSearchResult();
    V2TIMGroupSearchResult(const V2TIMGroupSearchResult& groupSearchResult);
    ~V2TIMGroupSearchResult();
};

/// 搜索群成员的参数
struct TIM_API V2TIMGroupMemberSearchParam {
    /// 搜索关键字列表，最多支持5个
    /// 如果是本地搜索，您需主动设置 keyword 是否匹配群成员 ID、昵称、备注、群名片。
    /// 如果是云端搜索，keyword 会自动匹配群成员 ID、昵称、群名片。
    V2TIMStringVector keywordList;
    /// 指定群 ID 列表，若为空的 V2TIMStringVector 则搜索全部群中的群成员
    V2TIMStringVector groupIDList;
    /// 设置是否搜索群成员 userID（仅本地搜索有效）
    bool isSearchMemberUserID = false;
    /// 设置是否搜索群成员昵称（仅本地搜索有效）
    bool isSearchMemberNickName = false;
    /// 设置是否搜索群成员备注（仅本地搜索有效）
    bool isSearchMemberRemark = false;
    /// 设置是否搜索群成员名片（仅本地搜索有效）
    bool isSearchMemberNameCard = false;
    /// 指定关键字列表匹配类型，可设置为“或”关系搜索或者“与”关系搜索（仅云端搜索有效）
    /// 取值分别为 V2TIM_KEYWORD_LIST_MATCH_TYPE_OR 和 V2TIM_KEYWORD_LIST_MATCH_TYPE_AND，默认为“或”关系搜索。
    V2TIMKeywordListMatchType keywordListMatchType = V2TIM_KEYWORD_LIST_MATCH_TYPE_OR;
    /// 每次云端搜索返回结果的条数（必须大于 0，最大支持 100，默认 20，仅云端搜索有效）
    uint32_t searchCount = 0;
    /// 每次云端搜索的起始位置。第一次填空字符串，续拉时填写 V2TIMGroupMemberSearchResult 中的返回值（仅云端搜索有效）
    V2TIMString searchCursor;

    V2TIMGroupMemberSearchParam();
    V2TIMGroupMemberSearchParam(const V2TIMGroupMemberSearchParam& groupMemberSearchParam);
    ~V2TIMGroupMemberSearchParam();
};

/// 搜索本地群成员的结果参数
DEFINE_MAP(V2TIMString, V2TIMGroupMemberFullInfoVector)
typedef TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap V2TIMGroupSearchGroupMembersMap;

/// 搜索云端群成员的结果参数
struct TIM_API V2TIMGroupMemberSearchResult {
    /// 满足搜索条件的群成员列表是否已经全部返回
    bool isFinished = false;
    /// 满足搜索条件的群成员总数量
    uint32_t totalCount = 0;
    /// 下一次云端搜索的起始位置
    V2TIMString nextCursor;
    /// 当前一次云端搜索返回的群成员列表
    TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap memberList;

    V2TIMGroupMemberSearchResult();
    V2TIMGroupMemberSearchResult(const V2TIMGroupMemberSearchResult& groupMemberSearchResult);
    ~V2TIMGroupMemberSearchResult();
};

#endif /* __V2TIM_GROUP_H__ */
