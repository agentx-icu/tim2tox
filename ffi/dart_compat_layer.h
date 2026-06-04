// Dart* function compatibility layer
// This file exports all Dart* functions that match the signatures in
// native_imsdk_bindings_generated.dart
#pragma once

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// Infrastructure functions
int DartInitDartApiDL(void* data);
// Note: Dart_Port is int64_t (64-bit), not int (32-bit)
void DartRegisterSendPort(int64_t send_port);
void DartUnregisterSendPort(int64_t send_port);

// SDK global callbacks
void DartSetNetworkStatusListenerCallback(void* user_data);
void DartSetKickedOfflineCallback(void* user_data);
void DartSetUserSigExpiredCallback(void* user_data);
void DartSetSelfInfoUpdatedCallback(void* user_data);
void DartSetUserStatusChangedCallback(void* user_data);
void DartSetUserInfoChangedCallback(void* user_data);
void DartSetMsgAllMessageReceiveOptionCallback(void* user_data);
void DartSetLogCallback(void* user_data);
// Introduced in tencent_cloud_chat_sdk 8.9.7540+3; no-op stub on Tim2Tox.
void DartSetExperimentalNotifyCallback(void* user_data);

// Message callbacks
void DartAddReceiveNewMsgCallback(void* user_data);
void DartSetMsgElemUploadProgressCallback(void* user_data);
void DartSetMsgReadReceiptCallback(void* user_data);
void DartSetMsgRevokeCallback(void* user_data);
void DartSetMsgUpdateCallback(void* user_data);
void DartSetMsgExtensionsChangedCallback(void* user_data);
void DartSetMsgExtensionsDeletedCallback(void* user_data);
void DartSetMsgReactionsChangedCallback(void* user_data);
void DartSetMsgGroupPinnedMessageChangedCallback(void* user_data);

// Conversation callbacks
void DartSetConvEventCallback(void* user_data);
void DartSetConvTotalUnreadMessageCountChangedCallback(void* user_data);
void DartSetConvUnreadMessageCountChangedByFilterCallback(void* user_data);
void DartSetConvConversationGroupCreatedCallback(void* user_data);
void DartSetConvConversationGroupDeletedCallback(void* user_data);
void DartSetConvConversationGroupNameChangedCallback(void* user_data);
void DartSetConvConversationsAddedToGroupCallback(void* user_data);
void DartSetConvConversationsDeletedFromGroupCallback(void* user_data);

// Group callbacks
void DartSetGroupTipsEventCallback(void* user_data);
void DartSetGroupAttributeChangedCallback(void* user_data);
void DartSetGroupCounterChangedCallback(void* user_data);

// Group notification functions
void DartNotifyGroupQuit(const char* group_id);
void DartNotifyGroupJoin(const char* group_id);

// Friendship callbacks
void DartSetOnAddFriendCallback(void* user_data);
void DartSetOnDeleteFriendCallback(void* user_data);
void DartSetUpdateFriendProfileCallback(void* user_data);
void DartSetFriendAddRequestCallback(void* user_data);
void DartSetFriendApplicationListDeletedCallback(void* user_data);
void DartSetFriendApplicationListReadCallback(void* user_data);
void DartSetFriendBlackListAddedCallback(void* user_data);
void DartSetFriendBlackListDeletedCallback(void* user_data);
void DartSetFriendGroupCreatedCallback(void* user_data);
void DartSetFriendGroupDeletedCallback(void* user_data);
void DartSetFriendGroupNameChangedCallback(void* user_data);
void DartSetFriendsAddedToGroupCallback(void* user_data);
void DartSetFriendsDeletedFromGroupCallback(void* user_data);
void DartSetOfficialAccountSubscribedCallback(void* user_data);
void DartSetOfficialAccountUnsubscribedCallback(void* user_data);
void DartSetOfficialAccountDeletedCallback(void* user_data);
void DartSetOfficialAccountInfoChangedCallback(void* user_data);
void DartSetMyFollowingListChangedCallback(void* user_data);
void DartSetMyFollowersListChangedCallback(void* user_data);
void DartSetMutualFollowersListChangedCallback(void* user_data);

// Signaling callbacks
void DartSetSignalingReceiveNewInvitationCallback(void* user_data);
void DartSetSignalingInvitationCancelledCallback(void* user_data);
void DartSetSignalingInviteeAcceptedCallback(void* user_data);
void DartSetSignalingInviteeRejectedCallback(void* user_data);
void DartSetSignalingInvitationTimeoutCallback(void* user_data);
void DartSetSignalingInvitationModifiedCallback(void* user_data);
void DartRemoveSignalingListenerForCurrentInstance(void);

// Community callbacks
void DartSetCommunityCreateTopicCallback(void* user_data);
void DartSetCommunityDeleteTopicCallback(void* user_data);
void DartSetCommunityChangeTopicInfoCallback(void* user_data);
void DartSetCommunityReceiveTopicRESTCustomDataCallback(void* user_data);
void DartSetCommunityCreatePermissionGroupCallback(void* user_data);
void DartSetCommunityDeletePermissionGroupCallback(void* user_data);
void DartSetCommunityChangePermissionGroupInfoCallback(void* user_data);
void DartSetCommunityAddMembersToPermissionGroupCallback(void* user_data);
void DartSetCommunityRemoveMembersFromPermissionGroupCallback(void* user_data);
void DartSetCommunityAddTopicPermissionCallback(void* user_data);
void DartSetCommunityDeleteTopicPermissionCallback(void* user_data);
void DartSetCommunityModifyTopicPermissionCallback(void* user_data);

#ifdef __cplusplus
}
#endif


