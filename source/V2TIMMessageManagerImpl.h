#pragma once

#ifndef __V2TIM_MESSAGE_MANAGER_IMPL_H__
#define __V2TIM_MESSAGE_MANAGER_IMPL_H__

#include "tox.h"

#include "V2TIMManager.h"
#include "V2TIMMessageManager.h"
#include "ToxManager.h"

#include <unordered_set>
#include <unordered_map>
#include <mutex>
#include <vector>
#include "V2TIMLog.h" // Optional for logging

// Forward declarations if needed
// class SQLiteDatabase; 
class V2TIMManagerImpl;

class V2TIMMessageManagerImpl : public V2TIMMessageManager {
private:
    std::unordered_set<V2TIMAdvancedMsgListener*> listeners_;
    std::mutex listener_mutex_;
    uint32_t GetFriendNumber(const V2TIMString& userID);
    uint32_t GetConferenceNumber(const V2TIMString& groupID);

public:
    explicit V2TIMMessageManagerImpl(V2TIMManagerImpl* owner);

    // Destructor
    ~V2TIMMessageManagerImpl() override;
    
    // Internal notification methods
    void NotifyMessageRevoked(const V2TIMString& msgID, const V2TIMString& revoker, const V2TIMString& reason);

    // Listener Management
    void AddAdvancedMsgListener(V2TIMAdvancedMsgListener* listener) override;
    void RemoveAdvancedMsgListener(V2TIMAdvancedMsgListener* listener) override;

    // --- Message Creation Methods (Implementations will be in .cpp) ---
    V2TIMMessage CreateTextMessage(const V2TIMString& text) override;
    V2TIMMessage CreateTextAtMessage(const V2TIMString& text, const V2TIMStringVector& atUserList) override;
    V2TIMMessage CreateCustomMessage(const V2TIMBuffer& data) override;
    V2TIMMessage CreateCustomMessage(const V2TIMBuffer& data, const V2TIMString& description, const V2TIMString& extension) override;
    V2TIMMessage CreateImageMessage(const V2TIMString& imagePath) override;
    V2TIMMessage CreateSoundMessage(const V2TIMString& soundPath, uint32_t duration) override;
    V2TIMMessage CreateVideoMessage(const V2TIMString& videoFilePath, const V2TIMString& type, uint32_t duration, const V2TIMString& snapshotPath) override;
    V2TIMMessage CreateFileMessage(const V2TIMString& filePath, const V2TIMString& fileName) override;
    V2TIMMessage CreateLocationMessage(const V2TIMString& desc, double longitude, double latitude) override;
    V2TIMMessage CreateFaceMessage(uint32_t index, const V2TIMBuffer& data) override;
    V2TIMMessage CreateMergerMessage(const V2TIMMessageVector& messageList, const V2TIMString& title, const V2TIMStringVector& abstractList, const V2TIMString& compatibleText) override;
    V2TIMMessage CreateForwardMessage(const V2TIMMessage& message) override;
    V2TIMMessage CreateTargetedGroupMessage(const V2TIMMessage& message, const V2TIMStringVector& receiverList) override;
    V2TIMMessage CreateAtSignedGroupMessage(const V2TIMMessage& message, const V2TIMStringVector& atUserList) override;

    // --- Message Sending --- 
    V2TIMString SendMessage(V2TIMMessage& message, const V2TIMString& receiver, const V2TIMString& groupID, V2TIMMessagePriority priority, bool onlineUserOnly, const V2TIMOfflinePushInfo& offlinePushInfo, V2TIMSendCallback* callback) override;

    // --- Receiving Options (Placeholders for now) ---
    void SetC2CReceiveMessageOpt(const V2TIMStringVector& userIDList, V2TIMReceiveMessageOpt opt, V2TIMCallback* callback) override;
    void GetC2CReceiveMessageOpt(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMReceiveMessageOptInfoVector>* callback) override;
    // Synchronous read of the per-peer C2C receive option (mute/DND) from the
    // authoritative in-memory map. Used by the conversation manager so EVERY
    // C2C conversation emit/materialization carries the current opt — a
    // hardcoded/stale 0 in any emit is treated by the Dart projection cache as
    // an un-mute (the recvOpt "clobber" bug). Short mutex read; never invokes
    // callbacks/listeners while holding receive_opt_mutex_.
    int GetC2CReceiveOptSync(const std::string& userID);
    void SetGroupReceiveMessageOpt(const V2TIMString& groupID, V2TIMReceiveMessageOpt opt, V2TIMCallback* callback) override;
    void SetAllReceiveMessageOpt(V2TIMReceiveMessageOpt opt, int32_t startHour, int32_t startMinute, int32_t startSecond, uint32_t duration, V2TIMCallback* callback) override;
    void SetAllReceiveMessageOpt(V2TIMReceiveMessageOpt opt, uint32_t startTimeStamp, uint32_t duration, V2TIMCallback* callback) override;
    void GetAllReceiveMessageOpt(V2TIMValueCallback<V2TIMReceiveMessageOptInfo>* callback) override;

    // --- History/Storage (Placeholders for now) ---
    void GetHistoryMessageList(const V2TIMMessageListGetOption& option, V2TIMValueCallback<V2TIMMessageVector>* callback) override;
    void RevokeMessage(const V2TIMMessage& message, V2TIMCallback* callback) override;
    void ModifyMessage(const V2TIMMessage& message, V2TIMCompleteCallback<V2TIMMessage>* callback) override;
    void DeleteMessages(const V2TIMMessageVector& messages, V2TIMCallback* callback) override;
    void ClearC2CHistoryMessage(const V2TIMString& userID, V2TIMCallback* callback) override;
    void ClearGroupHistoryMessage(const V2TIMString& groupID, V2TIMCallback* callback) override;
    V2TIMString InsertGroupMessageToLocalStorage(V2TIMMessage &message, const V2TIMString &groupID, const V2TIMString &sender, V2TIMValueCallback<V2TIMMessage> *callback) override;
    V2TIMString InsertC2CMessageToLocalStorage(V2TIMMessage &message, const V2TIMString &userID, const V2TIMString &sender, V2TIMValueCallback<V2TIMMessage> *callback) override;
    void FindMessages(const V2TIMStringVector& messageIDList, V2TIMValueCallback<V2TIMMessageVector>* callback) override;
    void SearchLocalMessages(const V2TIMMessageSearchParam& searchParam, V2TIMValueCallback<V2TIMMessageSearchResult>* callback) override;
    void SearchCloudMessages(const V2TIMMessageSearchParam& searchParam, V2TIMValueCallback<V2TIMMessageSearchResult>* callback) override;

    // --- Read Receipts (Placeholders for now) ---
    void SendMessageReadReceipts(const V2TIMMessageVector& messageList, V2TIMCallback* callback) override;
    void GetMessageReadReceipts(const V2TIMMessageVector& messageList, V2TIMValueCallback<V2TIMMessageReceiptVector>* callback) override;
    void GetGroupMessageReadMemberList(const V2TIMMessage& message, V2TIMGroupMessageReadMembersFilter filter, uint64_t nextSeq, uint32_t count, V2TIMValueCallback<V2TIMGroupMessageReadMemberList>* callback) override;
    void MarkC2CMessageAsRead(const V2TIMString& userID, V2TIMCallback* callback) override;
    void MarkGroupMessageAsRead(const V2TIMString& groupID, V2TIMCallback* callback) override;
    void MarkAllMessageAsRead(V2TIMCallback *callback) override;

    // --- Extensions/Reactions (Placeholders for now) ---
    void SetMessageExtensions(const V2TIMMessage& message, const V2TIMMessageExtensionVector& extensions, V2TIMValueCallback<V2TIMMessageExtensionResultVector>* callback) override;
    void GetMessageExtensions(const V2TIMMessage& message, V2TIMValueCallback<V2TIMMessageExtensionVector>* callback) override;
    void DeleteMessageExtensions(const V2TIMMessage& message, const V2TIMStringVector& keys, V2TIMValueCallback<V2TIMMessageExtensionResultVector>* callback) override;
    void AddMessageReaction(const V2TIMMessage& message, const V2TIMString& reactionID, V2TIMCallback* callback) override;
    void RemoveMessageReaction(const V2TIMMessage& message, const V2TIMString& reactionID, V2TIMCallback* callback) override;
    void GetMessageReactions(const V2TIMMessageVector& messageList, uint32_t maxUserCountPerReaction, V2TIMValueCallback<V2TIMMessageReactionResultVector>* callback) override;
    void GetAllUserListOfMessageReaction(const V2TIMMessage& message, const V2TIMString& reactionID, uint32_t nextSeq, uint32_t count, V2TIMValueCallback<V2TIMMessageReactionUserResult>* callback) override;
    
    // --- Misc (Placeholders for now) ---
    void TranslateText(const V2TIMStringVector& sourceTextList, const V2TIMString& sourceLanguage, const V2TIMString& targetLanguage, V2TIMValueCallback<V2TIMStringToV2TIMStringMap>* callback) override;
    void PinGroupMessage(const V2TIMString& groupID, const V2TIMMessage& message, bool isPinned, V2TIMCallback* callback) override;
    void GetPinnedGroupMessageList(const V2TIMString& groupID, V2TIMValueCallback<V2TIMMessageVector>* callback) override;
    void DownloadMergerMessage(const V2TIMMessage &message, V2TIMValueCallback<V2TIMMessageVector> *callback);

    // --- Internal methods for V2TIMManagerImpl to call ---
    // Used by V2TIMManagerImpl::HandleFriendMessage / HandleGroupMessage
    void NotifyAdvancedListenersReceivedMessage(const V2TIMMessage& message);

private:

    // Delete copy/move constructors and assignment operators
    V2TIMMessageManagerImpl(const V2TIMMessageManagerImpl&) = delete;
    V2TIMMessageManagerImpl& operator=(const V2TIMMessageManagerImpl&) = delete;
    V2TIMMessageManagerImpl(V2TIMMessageManagerImpl&&) = delete;
    V2TIMMessageManagerImpl& operator=(V2TIMMessageManagerImpl&&) = delete;

    // Helper to create a base V2TIMMessage object
    V2TIMMessage CreateBaseMessage();

    // Local storage for receive message options
    std::unordered_map<std::string, V2TIMReceiveMessageOpt> c2c_receive_opts_;
    std::unordered_map<std::string, V2TIMReceiveMessageOpt> group_receive_opts_;
    std::mutex receive_opt_mutex_;

    // Reference to V2TIMManagerImpl for multi-instance support
    V2TIMManagerImpl* manager_impl_;
    std::mutex manager_impl_mutex_;

    // Callback with appropriate error for unimplemented features
    void ReportNotImplemented(V2TIMCallback* callback);
    template <typename T> void ReportNotImplemented(V2TIMValueCallback<T>* callback);
    template <typename T> void ReportNotImplemented(V2TIMCompleteCallback<T>* callback);
};

#endif // __V2TIM_MESSAGE_MANAGER_IMPL_H__
