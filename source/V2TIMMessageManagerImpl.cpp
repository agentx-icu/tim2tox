#include "V2TIMMessageManagerImpl.h"
#include "V2TIMManagerImpl.h" // To call Send C2C/Group messages
#include "ToxManager.h" // Potentially needed for direct Tox calls?
#include <V2TIMErrorCode.h>
#include <chrono> // For timestamps
#include <atomic>
#include <cstdio>
#include <filesystem>
#include "TIMResultDefine.h"
#include "MergerMessageUtil.h"
#include "RevokeMessageUtil.h"
#include "MessageReplyUtil.h"

// Constructor (R-06: owned by V2TIMManagerImpl, no singleton)
V2TIMMessageManagerImpl::V2TIMMessageManagerImpl(V2TIMManagerImpl* owner) : manager_impl_(owner) {
    V2TIM_LOG(kInfo, "V2TIMMessageManagerImpl initialized.");
}

// Destructor
V2TIMMessageManagerImpl::~V2TIMMessageManagerImpl() {
    // TODO: Close database connection if needed
    // Don't log in destructor to avoid mutex issues during static destruction
    // V2TIM_LOG(kInfo, "V2TIMMessageManagerImpl destroyed.");
}

// --- Listener Management ---
void V2TIMMessageManagerImpl::AddAdvancedMsgListener(V2TIMAdvancedMsgListener* listener) {
    std::lock_guard<std::mutex> lock(listener_mutex_);
    if (listener) {
        listeners_.insert(listener);
    } else {
        V2TIM_LOG(kWarning, "[V2TIMMessageManagerImpl] AddAdvancedMsgListener: ERROR - Attempted to add null listener");
    }
}

void V2TIMMessageManagerImpl::RemoveAdvancedMsgListener(V2TIMAdvancedMsgListener* listener) {
    std::lock_guard<std::mutex> lock(listener_mutex_);
    if (listener) {
        listeners_.erase(listener);
    }
}

namespace {
std::string MakeLocalMessageIdFallback() {
    static std::atomic<uint64_t> s_seq{1};
    auto now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    uint64_t seq = s_seq.fetch_add(1, std::memory_order_relaxed);
    return "local_" + std::to_string(now_ns) + "_" + std::to_string(seq);
}
}  // namespace

// --- Internal Helper for Creating Base Message ---
V2TIMMessage V2TIMMessageManagerImpl::CreateBaseMessage() {
    V2TIMMessage msg;
    std::string msg_id_str;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        if (manager_impl_) {
            msg_id_str = manager_impl_->MakeMessageId();
        } else {
            msg_id_str = MakeLocalMessageIdFallback();
        }
    }
    msg.msgID = msg_id_str.c_str();

    msg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    // Use manager_impl_ instead of V2TIMManagerImpl::GetInstance() for multi-instance support
    V2TIMManagerImpl* manager = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager = manager_impl_;
    }
    if (manager) {
        msg.sender = manager->GetLoginUser(); // Set current user as sender
    }
    msg.status = V2TIM_MSG_STATUS_SENDING;
    msg.isSelf = true;
    // Other fields (receiver, groupID, etc.) set by SendMessage
    return msg;
}

// --- Message Creation Methods (Initial Implementations) ---
V2TIMMessage V2TIMMessageManagerImpl::CreateTextMessage(const V2TIMString& text) {
    V2TIMMessage msg = CreateBaseMessage();
    V2TIMTextElem* textElem = new V2TIMTextElem();
    textElem->elemType = V2TIM_ELEM_TYPE_TEXT;
    textElem->text = text;
    msg.elemList.PushBack(textElem);
    V2TIM_LOG(kInfo, "Created Text Message: {}", msg.msgID.CString());
    return msg;
}

// --- Helper for Reporting Not Implemented --- 
void V2TIMMessageManagerImpl::ReportNotImplemented(V2TIMCallback* callback) {
    if (callback) {
        callback->OnError(ERR_SDK_NOT_SUPPORTED, "Feature not implemented in tim2tox");
    }
}

template <typename T>
void V2TIMMessageManagerImpl::ReportNotImplemented(V2TIMValueCallback<T>* callback) {
    if (callback) {
        callback->OnError(ERR_SDK_NOT_SUPPORTED, "Feature not implemented in tim2tox");
    }
}

template <typename T>
void V2TIMMessageManagerImpl::ReportNotImplemented(V2TIMCompleteCallback<T>* callback) {
    if (callback) {
        callback->OnComplete(ERR_SDK_NOT_SUPPORTED, "Feature not implemented in tim2tox", T());
    }
}

// --- Placeholder Implementations for Remaining Methods ---

V2TIMMessage V2TIMMessageManagerImpl::CreateTextAtMessage(const V2TIMString& text, const V2TIMStringVector& atUserList) {
    // Basic implementation: create text message, add atUserList to V2TIMMessage
    V2TIMMessage msg = CreateTextMessage(text);
    msg.groupAtUserList = atUserList;
    // TODO: Actual sending logic needs to handle @ users potentially
    V2TIM_LOG(kWarning, "CreateTextAtMessage created basic text message, @ handling not fully implemented for send.");
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateCustomMessage(const V2TIMBuffer& data) {
    V2TIMMessage msg = CreateBaseMessage();
    V2TIMCustomElem* customElem = new V2TIMCustomElem();
    customElem->elemType = V2TIM_ELEM_TYPE_CUSTOM;
    customElem->data = data;
    msg.elemList.PushBack(customElem);
    V2TIM_LOG(kInfo, "Created Custom Message: {}", msg.msgID.CString());
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateCustomMessage(const V2TIMBuffer& data, const V2TIMString& description, const V2TIMString& extension) {
    V2TIMMessage msg = CreateCustomMessage(data);
    
    // Get the custom element from the elemList and update its properties
    if (msg.elemList.Size() > 0) {
        V2TIMElem* elem = msg.elemList[0];
        if (elem && elem->elemType == V2TIM_ELEM_TYPE_CUSTOM) {
            V2TIMCustomElem* customElem = static_cast<V2TIMCustomElem*>(elem);
            customElem->desc = description;
            customElem->extension = extension;
        }
    }
    
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateImageMessage(const V2TIMString& imagePath) {
    V2TIM_LOG(kError, "CreateImageMessage not implemented. path={}", imagePath.CString());
    V2TIMMessage msg = CreateBaseMessage();
    msg.status = V2TIM_MSG_STATUS_SEND_FAIL;
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateSoundMessage(const V2TIMString& soundPath, uint32_t duration) {
    V2TIM_LOG(kError, "CreateSoundMessage not implemented. path={}", soundPath.CString());
    V2TIMMessage msg = CreateBaseMessage();
    msg.status = V2TIM_MSG_STATUS_SEND_FAIL;
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateVideoMessage(const V2TIMString& videoFilePath, const V2TIMString& type, uint32_t duration, const V2TIMString& snapshotPath) {
    V2TIM_LOG(kError, "CreateVideoMessage not implemented. path={}", videoFilePath.CString());
    V2TIMMessage msg = CreateBaseMessage();
    msg.status = V2TIM_MSG_STATUS_SEND_FAIL;
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateFileMessage(const V2TIMString& filePath, const V2TIMString& fileName) {
    V2TIMMessage msg = CreateBaseMessage();
    V2TIMFileElem* fileElem = new V2TIMFileElem();
    fileElem->elemType = V2TIM_ELEM_TYPE_FILE;
    fileElem->path = filePath;
    fileElem->filename = fileName;
    fileElem->fileSize = 0;
    if (filePath.Length() > 0) {
        try {
            const std::string path = filePath.CString();
            if (std::filesystem::is_regular_file(path)) {
                fileElem->fileSize = static_cast<uint64_t>(std::filesystem::file_size(path));
            }
        } catch (...) {
            // If the path is invalid or inaccessible, just keep fileSize=0.
        }
    }
    msg.elemList.PushBack(fileElem);
    V2TIM_LOG(kInfo, "Created File Message: {} (path: {}, fileName: {}, size: {})",
              msg.msgID.CString(), filePath.CString(), fileName.CString(), fileElem->fileSize);
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateLocationMessage(const V2TIMString& desc, double longitude, double latitude) {
    V2TIMMessage msg = CreateBaseMessage();
    V2TIMLocationElem* locationElem = new V2TIMLocationElem();
    locationElem->elemType = V2TIM_ELEM_TYPE_LOCATION;
    locationElem->desc = desc;
    locationElem->longitude = longitude;
    locationElem->latitude = latitude;
    msg.elemList.PushBack(locationElem);
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateFaceMessage(uint32_t index, const V2TIMBuffer& data) {
    V2TIMMessage msg = CreateBaseMessage();
    V2TIMFaceElem* faceElem = new V2TIMFaceElem();
    faceElem->elemType = V2TIM_ELEM_TYPE_FACE;
    faceElem->index = index;
    faceElem->data = data;
    msg.elemList.PushBack(faceElem);
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateMergerMessage(const V2TIMMessageVector& messageList, const V2TIMString& title, const V2TIMStringVector& abstractList, const V2TIMString& compatibleText) {
    V2TIMMessage msg = CreateBaseMessage();
    
    // 创建合并消息元素
    V2TIMMergerElem* mergerElem = new V2TIMMergerElem();
    mergerElem->elemType = V2TIM_ELEM_TYPE_MERGER;
    mergerElem->title = title;
    mergerElem->abstractList = abstractList;
    mergerElem->layersOverLimit = false; // 默认不超过限制
    
    msg.elemList.PushBack(mergerElem);
    
    // 将messageIDList保存到cloudCustomData中，以便发送时使用
    // 格式：{"mergerMessageIDs":["msg1","msg2",...]}
    std::ostringstream json;
    json << "{\"mergerMessageIDs\":[";
    for (size_t i = 0; i < messageList.Size(); i++) {
        if (i > 0) json << ",";
        json << "\"";
        std::string msgID(messageList[i].msgID.CString());
        // 转义JSON特殊字符
        for (char c : msgID) {
            if (c == '"') json << "\\\"";
            else if (c == '\\') json << "\\\\";
            else json << c;
        }
        json << "\"";
    }
    json << "]}";
    
    std::string customDataStr = json.str();
    msg.cloudCustomData = V2TIMBuffer(reinterpret_cast<const uint8_t*>(customDataStr.c_str()), customDataStr.length());
    
    V2TIM_LOG(kInfo, "Created Merger Message: {} (title: {}, {} messages)", 
              msg.msgID.CString(), title.CString(), messageList.Size());
    return msg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateForwardMessage(const V2TIMMessage& message) {
    // 创建新的基础消息
    V2TIMMessage forwardMsg = CreateBaseMessage();
    
    // 复制原消息的所有元素
    for (size_t i = 0; i < message.elemList.Size(); i++) {
        V2TIMElem* origElem = message.elemList[i];
        if (!origElem) {
            continue;
        }
        
        V2TIMElem* newElem = nullptr;
        
        switch (origElem->elemType) {
            case V2TIM_ELEM_TYPE_TEXT: {
                V2TIMTextElem* origText = static_cast<V2TIMTextElem*>(origElem);
                V2TIMTextElem* newText = new V2TIMTextElem();
                newText->elemType = V2TIM_ELEM_TYPE_TEXT;
                newText->text = origText->text;
                newElem = newText;
                break;
            }
            case V2TIM_ELEM_TYPE_CUSTOM: {
                V2TIMCustomElem* origCustom = static_cast<V2TIMCustomElem*>(origElem);
                V2TIMCustomElem* newCustom = new V2TIMCustomElem();
                newCustom->elemType = V2TIM_ELEM_TYPE_CUSTOM;
                newCustom->data = origCustom->data;
                newCustom->desc = origCustom->desc;
                newCustom->extension = origCustom->extension;
                newElem = newCustom;
                break;
            }
            case V2TIM_ELEM_TYPE_IMAGE: {
                V2TIMImageElem* origImage = static_cast<V2TIMImageElem*>(origElem);
                V2TIMImageElem* newImage = new V2TIMImageElem();
                newImage->elemType = V2TIM_ELEM_TYPE_IMAGE;
                // 复制图片信息（简化处理，实际可能需要深拷贝）
                newImage->path = origImage->path;
                newImage->imageList = origImage->imageList;
                newElem = newImage;
                break;
            }
            case V2TIM_ELEM_TYPE_SOUND: {
                V2TIMSoundElem* origSound = static_cast<V2TIMSoundElem*>(origElem);
                V2TIMSoundElem* newSound = new V2TIMSoundElem();
                newSound->elemType = V2TIM_ELEM_TYPE_SOUND;
                newSound->path = origSound->path;
                newSound->dataSize = origSound->dataSize;
                newSound->duration = origSound->duration;
                newElem = newSound;
                break;
            }
            case V2TIM_ELEM_TYPE_VIDEO: {
                V2TIMVideoElem* origVideo = static_cast<V2TIMVideoElem*>(origElem);
                V2TIMVideoElem* newVideo = new V2TIMVideoElem();
                newVideo->elemType = V2TIM_ELEM_TYPE_VIDEO;
                newVideo->videoPath = origVideo->videoPath;
                newVideo->videoType = origVideo->videoType;
                newVideo->videoSize = origVideo->videoSize;
                newVideo->duration = origVideo->duration;
                newVideo->snapshotPath = origVideo->snapshotPath;
                newVideo->snapshotSize = origVideo->snapshotSize;
                newVideo->snapshotWidth = origVideo->snapshotWidth;
                newVideo->snapshotHeight = origVideo->snapshotHeight;
                newVideo->videoUUID = origVideo->videoUUID;
                newVideo->snapshotUUID = origVideo->snapshotUUID;
                newElem = newVideo;
                break;
            }
            case V2TIM_ELEM_TYPE_FILE: {
                V2TIMFileElem* origFile = static_cast<V2TIMFileElem*>(origElem);
                V2TIMFileElem* newFile = new V2TIMFileElem();
                newFile->elemType = V2TIM_ELEM_TYPE_FILE;
                newFile->path = origFile->path;
                newFile->filename = origFile->filename;
                newFile->fileSize = origFile->fileSize;
                newFile->uuid = origFile->uuid;
                newElem = newFile;
                break;
            }
            case V2TIM_ELEM_TYPE_LOCATION: {
                V2TIMLocationElem* origLoc = static_cast<V2TIMLocationElem*>(origElem);
                V2TIMLocationElem* newLoc = new V2TIMLocationElem();
                newLoc->elemType = V2TIM_ELEM_TYPE_LOCATION;
                newLoc->desc = origLoc->desc;
                newLoc->longitude = origLoc->longitude;
                newLoc->latitude = origLoc->latitude;
                newElem = newLoc;
                break;
            }
            case V2TIM_ELEM_TYPE_FACE: {
                V2TIMFaceElem* origFace = static_cast<V2TIMFaceElem*>(origElem);
                V2TIMFaceElem* newFace = new V2TIMFaceElem();
                newFace->elemType = V2TIM_ELEM_TYPE_FACE;
                newFace->index = origFace->index;
                newFace->data = origFace->data;
                newElem = newFace;
                break;
            }
            case V2TIM_ELEM_TYPE_MERGER: {
                // 合并消息也可以转发
                V2TIMMergerElem* origMerger = static_cast<V2TIMMergerElem*>(origElem);
                V2TIMMergerElem* newMerger = new V2TIMMergerElem();
                newMerger->elemType = V2TIM_ELEM_TYPE_MERGER;
                newMerger->title = origMerger->title;
                newMerger->abstractList = origMerger->abstractList;
                newMerger->layersOverLimit = origMerger->layersOverLimit;
                newElem = newMerger;
                break;
            }
            default:
                V2TIM_LOG(kWarning, "CreateForwardMessage: Unsupported element type {}, skipping", static_cast<int>(origElem->elemType));
                continue;
        }
        
        if (newElem) {
            forwardMsg.elemList.PushBack(newElem);
        }
    }
    
    // 复制其他重要字段（但不复制msgID、timestamp等，这些会由CreateBaseMessage生成）
    forwardMsg.sender = message.sender;
    forwardMsg.nickName = message.nickName;
    forwardMsg.friendRemark = message.friendRemark;
    forwardMsg.nameCard = message.nameCard;
    forwardMsg.faceURL = message.faceURL;
    forwardMsg.groupID = message.groupID;
    forwardMsg.userID = message.userID;
    // 转发消息时，需要移除cloudCustomData中的引用回复信息，避免转发时错误地包含引用信息
    forwardMsg.cloudCustomData = MessageReplyUtil::RemoveReplyFromCloudCustomData(message.cloudCustomData);
    // localCustomData 和 localCustomInt 通过 SetLocalCustomData/SetLocalCustomInt 设置，不在这里复制
    forwardMsg.isExcludedFromUnreadCount = message.isExcludedFromUnreadCount;
    forwardMsg.isExcludedFromLastMessage = message.isExcludedFromLastMessage;
    forwardMsg.isExcludedFromContentModeration = message.isExcludedFromContentModeration;
    forwardMsg.groupAtUserList = message.groupAtUserList;
    
    return forwardMsg;
}

V2TIMMessage V2TIMMessageManagerImpl::CreateTargetedGroupMessage(const V2TIMMessage& message, const V2TIMStringVector& receiverList) {
     V2TIM_LOG(kError, "CreateTargetedGroupMessage not implemented.");
     // TODO: Create new message marking targeted receivers
    return CreateBaseMessage();
}

V2TIMMessage V2TIMMessageManagerImpl::CreateAtSignedGroupMessage(const V2TIMMessage& message, const V2TIMStringVector& atUserList) {
     V2TIM_LOG(kWarning, "CreateAtSignedGroupMessage handling not fully implemented.");
     V2TIMMessage msg = message; // Copy original
     msg.groupAtUserList = atUserList;
     return msg;
}

// --- Message Sending --- 
V2TIMString V2TIMMessageManagerImpl::SendMessage(
    V2TIMMessage& message, 
    const V2TIMString& receiver, 
    const V2TIMString& groupID, 
    V2TIMMessagePriority priority, 
    bool onlineUserOnly, 
    const V2TIMOfflinePushInfo& offlinePushInfo, 
    V2TIMSendCallback* callback) 
{
    V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] ========== ENTRY ==========");
    V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] msgID={}, receiver={}, groupID={}", 
             message.msgID.CString(), receiver.CString(), groupID.CString());
    
    // --- Validate Destination ---
    bool isC2C = !receiver.Empty();
    bool isGroup = !groupID.Empty();
    bool isGroupPrivate = isC2C && isGroup; // receiver + groupID => group private message

    if (!isGroupPrivate && !isC2C && !isGroup) {
        V2TIM_LOG(kError, "[V2TIMMessageManagerImpl::SendMessage] Failed: Must specify receiver or groupID.");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Must specify receiver or groupID");
        message.status = V2TIM_MSG_STATUS_SEND_FAIL;
        return "";
    }

    V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] Message type: {}", isGroupPrivate ? "GROUP_PRIVATE" : (isGroup ? "GROUP" : "C2C"));
    
    // --- Update Message Fields ---
    message.userID = receiver;  // Store intended receiver
    message.groupID = groupID;  // Store intended group
    message.status = V2TIM_MSG_STATUS_SENDING; // Mark as sending
    // Note: We ignore onlineUserOnly and offlinePushInfo for now as Tox doesn't support them directly.
    if (onlineUserOnly) {
        V2TIM_LOG(kWarning, "[V2TIMMessageManagerImpl::SendMessage] onlineUserOnly flag is not supported by tim2tox.");
    }
    if (!offlinePushInfo.title.Empty() || !offlinePushInfo.desc.Empty()) {
         V2TIM_LOG(kWarning, "[V2TIMMessageManagerImpl::SendMessage] offlinePushInfo is not supported by tim2tox.");
    }

    // --- Get Lower-Level Manager Instance ---
    // Use manager_impl_ instead of V2TIMManagerImpl::GetInstance() for multi-instance support
    V2TIMManagerImpl* manager = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager = manager_impl_;
    }
    if (!manager) {
         V2TIM_LOG(kError, "[V2TIMMessageManagerImpl::SendMessage] Failed: V2TIMManagerImpl instance is null.");
         if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "V2TIMManagerImpl instance is null");
         message.status = V2TIM_MSG_STATUS_SEND_FAIL;
         return "";
    }

    // --- Extract Payload and Call Appropriate Send Method ---
    V2TIMString sentMsgID = ""; // Store the ID returned by the lower-level send

    if (message.elemList.Size() == 0) {
        V2TIM_LOG(kError, "SendMessage failed: Message has no elements.");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Message has no elements");
        message.status = V2TIM_MSG_STATUS_SEND_FAIL;
        return "";
    }
    if (message.elemList.Size() != 1) {
        V2TIM_LOG(kError, "SendMessage failed: tim2tox supports exactly one message element, got {}", message.elemList.Size());
        if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "tim2tox currently supports exactly one message element");
        message.status = V2TIM_MSG_STATUS_SEND_FAIL;
        return "";
    }

    V2TIMElem* elem = message.elemList[0];
    if (!elem) {
        V2TIM_LOG(kError, "SendMessage failed: First element is null.");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "First element is null");
        message.status = V2TIM_MSG_STATUS_SEND_FAIL;
        return "";
    }

    switch (elem->elemType) {
        case V2TIM_ELEM_TYPE_TEXT: {
            V2TIMTextElem* textElem = static_cast<V2TIMTextElem*>(elem);
            V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] Sending TEXT message, isGroupPrivate={}, isGroup={}, text_length={}", 
                     isGroupPrivate, isGroup, textElem->text.Length());
            if (isGroupPrivate) {
                V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] Calling SendGroupPrivateTextMessage groupID={}, receiver={}", groupID.CString(), receiver.CString());
                sentMsgID = manager->SendGroupPrivateTextMessage(groupID, receiver, textElem->text, callback);
                V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] SendGroupPrivateTextMessage returned msgID={}", sentMsgID.CString());
            } else if (isC2C) {
                V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] Calling SendC2CTextMessage");
                sentMsgID = manager->SendC2CTextMessage(textElem->text, receiver, message.cloudCustomData, callback);
            } else { // isGroup
                V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] Calling SendGroupTextMessage for groupID={}", groupID.CString());
                sentMsgID = manager->SendGroupTextMessage(textElem->text, groupID, priority, message.cloudCustomData, callback);
                V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::SendMessage] SendGroupTextMessage returned msgID={}", sentMsgID.CString());
            }
            break;
        }
        case V2TIM_ELEM_TYPE_MERGER: {
            // 处理合并消息（多选转发）
            V2TIMMergerElem* mergerElem = static_cast<V2TIMMergerElem*>(elem);
            if (!mergerElem) {
                V2TIM_LOG(kError, "SendMessage failed: Merger element is null.");
                if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Merger element is null");
                sentMsgID = "";
                break;
            }
            
            // 从cloudCustomData中提取messageIDList
            std::string cloudDataStr;
            if (message.cloudCustomData.Data() && message.cloudCustomData.Size() > 0) {
                cloudDataStr = std::string(reinterpret_cast<const char*>(message.cloudCustomData.Data()), message.cloudCustomData.Size());
            }
            
            std::vector<std::string> messageIDList;
            if (!cloudDataStr.empty()) {
                // 从cloudCustomData中提取mergerMessageIDs数组
                messageIDList = MergerMessageUtil::ExtractMessageIDs(cloudDataStr);
            }
            
            // 使用兼容文本作为消息内容
            std::string compatibleText = "转发消息"; // 默认兼容文本
            if (!mergerElem->abstractList.Empty()) {
                // 使用第一个摘要作为兼容文本
                compatibleText = mergerElem->abstractList[0].CString();
            }
            
            // 构建合并消息JSON，包含title、abstractList和messageIDList
            std::ostringstream json;
            json << "{\"title\":\"";
            std::string titleStr(mergerElem->title.CString());
            for (char c : titleStr) {
                if (c == '"') json << "\\\"";
                else if (c == '\\') json << "\\\\";
                else json << c;
            }
            json << "\",\"abstractList\":[";
            for (size_t i = 0; i < mergerElem->abstractList.Size(); i++) {
                if (i > 0) json << ",";
                json << "\"";
                std::string abstractStr(mergerElem->abstractList[i].CString());
                for (char c : abstractStr) {
                    if (c == '"') json << "\\\"";
                    else if (c == '\\') json << "\\\\";
                    else json << c;
                }
                json << "\"";
            }
            json << "],\"messageIDList\":[";
            for (size_t i = 0; i < messageIDList.size(); i++) {
                if (i > 0) json << ",";
                json << "\"";
                for (char c : messageIDList[i]) {
                    if (c == '"') json << "\\\"";
                    else if (c == '\\') json << "\\\\";
                    else json << c;
                }
                json << "\"";
            }
            json << "]}";
            
            std::string mergerJson = json.str();
            std::string messageText = MergerMessageUtil::BuildMessageWithMerger(mergerJson, compatibleText);
            
            // 检查长度
            if (MergerMessageUtil::IsMessageTooLong(messageText)) {
                // 如果太长，只发送兼容文本
                messageText = compatibleText;
            }
            
            V2TIMString textToSend(messageText.c_str());
            // 发送时不传递cloudCustomData，因为合并消息信息已经编码到文本中了
            if (isC2C) {
                sentMsgID = manager->SendC2CTextMessage(textToSend, receiver, V2TIMBuffer(), callback);
            } else {
                sentMsgID = manager->SendGroupTextMessage(textToSend, groupID, priority, V2TIMBuffer(), callback);
            }
            break;
        }
        case V2TIM_ELEM_TYPE_CUSTOM: {
            V2TIMCustomElem* customElem = static_cast<V2TIMCustomElem*>(elem);
            if (!customElem) {
                V2TIM_LOG(kError, "SendMessage failed: Custom element is null.");
                if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Custom element is null");
                sentMsgID = "";
                break;
            }
            if (isC2C) {
                sentMsgID = manager->SendC2CCustomMessage(customElem->data, receiver, callback);
            } else {
                sentMsgID = manager->SendGroupCustomMessage(customElem->data, groupID, priority, callback);
            }
            break;
        }
        case V2TIM_ELEM_TYPE_IMAGE: {
            // 图片消息转发：转换为文本消息说明
            V2TIMImageElem* imageElem = static_cast<V2TIMImageElem*>(elem);
            std::string forwardText = "[转发图片]";
            if (imageElem && !imageElem->path.Empty()) {
                forwardText += " " + std::string(imageElem->path.CString());
            }
            V2TIMString textToSend(forwardText.c_str());
            if (isC2C) {
                sentMsgID = manager->SendC2CTextMessage(textToSend, receiver, message.cloudCustomData, callback);
            } else {
                sentMsgID = manager->SendGroupTextMessage(textToSend, groupID, priority, message.cloudCustomData, callback);
            }
            break;
        }
        case V2TIM_ELEM_TYPE_SOUND: {
            // 语音消息转发：转换为文本消息说明
            V2TIMSoundElem* soundElem = static_cast<V2TIMSoundElem*>(elem);
            std::string forwardText = "[转发语音]";
            if (soundElem && soundElem->duration > 0) {
                forwardText += " (" + std::to_string(soundElem->duration) + "秒)";
            }
            V2TIMString textToSend(forwardText.c_str());
            if (isC2C) {
                sentMsgID = manager->SendC2CTextMessage(textToSend, receiver, message.cloudCustomData, callback);
            } else {
                sentMsgID = manager->SendGroupTextMessage(textToSend, groupID, priority, message.cloudCustomData, callback);
            }
            break;
        }
        case V2TIM_ELEM_TYPE_VIDEO: {
            // 视频消息转发：转换为文本消息说明
            V2TIMVideoElem* videoElem = static_cast<V2TIMVideoElem*>(elem);
            std::string forwardText = "[转发视频]";
            if (videoElem && videoElem->duration > 0) {
                forwardText += " (" + std::to_string(videoElem->duration) + "秒)";
            }
            V2TIMString textToSend(forwardText.c_str());
            if (isC2C) {
                sentMsgID = manager->SendC2CTextMessage(textToSend, receiver, message.cloudCustomData, callback);
            } else {
                sentMsgID = manager->SendGroupTextMessage(textToSend, groupID, priority, message.cloudCustomData, callback);
            }
            break;
        }
        case V2TIM_ELEM_TYPE_FILE: {
            // 文件消息转发：转换为文本消息说明
            V2TIMFileElem* fileElem = static_cast<V2TIMFileElem*>(elem);
            std::string forwardText = "[转发文件]";
            if (fileElem && !fileElem->filename.Empty()) {
                forwardText += " " + std::string(fileElem->filename.CString());
            }
            if (fileElem && fileElem->fileSize > 0) {
                forwardText += " (" + std::to_string(fileElem->fileSize) + " 字节)";
            }
            V2TIMString textToSend(forwardText.c_str());
            if (isC2C) {
                sentMsgID = manager->SendC2CTextMessage(textToSend, receiver, message.cloudCustomData, callback);
            } else {
                sentMsgID = manager->SendGroupTextMessage(textToSend, groupID, priority, message.cloudCustomData, callback);
            }
            break;
        }
        case V2TIM_ELEM_TYPE_LOCATION: {
            // 位置消息转发：转换为文本消息说明
            V2TIMLocationElem* locationElem = static_cast<V2TIMLocationElem*>(elem);
            std::string forwardText = "[转发位置]";
            if (locationElem && !locationElem->desc.Empty()) {
                forwardText += " " + std::string(locationElem->desc.CString());
            }
            V2TIMString textToSend(forwardText.c_str());
            if (isC2C) {
                sentMsgID = manager->SendC2CTextMessage(textToSend, receiver, message.cloudCustomData, callback);
            } else {
                sentMsgID = manager->SendGroupTextMessage(textToSend, groupID, priority, message.cloudCustomData, callback);
            }
            break;
        }
        case V2TIM_ELEM_TYPE_FACE: {
            // 表情消息转发：转换为文本消息说明
            std::string forwardText = "[转发表情]";
            V2TIMString textToSend(forwardText.c_str());
            if (isC2C) {
                sentMsgID = manager->SendC2CTextMessage(textToSend, receiver, message.cloudCustomData, callback);
            } else {
                sentMsgID = manager->SendGroupTextMessage(textToSend, groupID, priority, message.cloudCustomData, callback);
            }
            break;
        }
        default: {
             V2TIM_LOG(kError, "SendMessage failed: Unsupported message element type: {}", static_cast<int>(elem->elemType));
             if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Unsupported message element type for sending");
             sentMsgID = ""; // Indicate immediate failure
             break;
        }
    }

    // --- Final Status Update and Return ---
    if (sentMsgID.Empty()) {
        // The send call failed immediately (e.g., invalid params, not implemented)
        message.status = V2TIM_MSG_STATUS_SEND_FAIL;
        // callback->OnError should have been called by the failed function or above check
    } else {
        // Send initiated, status remains SENDING. The callback will indicate final success/failure.
        // We return the original message ID generated during creation.
    }

    return message.msgID; // Return the client-generated message ID
}

// --- Other Methods (Placeholders) ---
void V2TIMMessageManagerImpl::SetC2CReceiveMessageOpt(const V2TIMStringVector& userIDList, V2TIMReceiveMessageOpt opt, V2TIMCallback* callback) {
    // CRITICAL: Copy userIDList immediately to avoid lifetime issues
    std::vector<std::string> user_id_strings;  // Store C-strings safely
    try {
        for (size_t i = 0; i < userIDList.Size(); i++) {
            try {
                const V2TIMString& userID = userIDList[i];
                const char* user_id_cstr = nullptr;
                size_t user_id_len = 0;
                try {
                    user_id_len = userID.Length();
                    user_id_cstr = userID.CString();
                } catch (...) {
                    continue;
                }
                if (!user_id_cstr || user_id_len == 0) {
                    continue;
                }
                user_id_strings.push_back(std::string(user_id_cstr, user_id_len));
            } catch (...) {
                continue;
            }
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to copy user ID list");
        return;
    }
    
    std::lock_guard<std::mutex> lock(receive_opt_mutex_);
    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    for (const auto& user_id_str : user_id_strings) {
        c2c_receive_opts_[user_id_str] = opt;
        V2TIM_LOG(kInfo, "SetC2CReceiveMessageOpt: userID={}, opt={}", user_id_str.c_str(), static_cast<int>(opt));
    }
    if (callback) callback->OnSuccess();
}

void V2TIMMessageManagerImpl::GetC2CReceiveMessageOpt(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMReceiveMessageOptInfoVector>* callback) {
    // CRITICAL: Copy userIDList immediately to avoid lifetime issues
    std::vector<std::string> user_id_strings;  // Store C-strings safely
    try {
        for (size_t i = 0; i < userIDList.Size(); i++) {
            try {
                const V2TIMString& userID = userIDList[i];
                const char* user_id_cstr = nullptr;
                size_t user_id_len = 0;
                try {
                    user_id_len = userID.Length();
                    user_id_cstr = userID.CString();
                } catch (...) {
                    continue;
                }
                if (!user_id_cstr || user_id_len == 0) {
                    continue;
                }
                user_id_strings.push_back(std::string(user_id_cstr, user_id_len));
            } catch (...) {
                continue;
            }
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to copy user ID list");
        return;
    }
    
    V2TIMReceiveMessageOptInfoVector resultVector;
    std::lock_guard<std::mutex> lock(receive_opt_mutex_);
    
    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    for (const auto& user_id_str : user_id_strings) {
        V2TIMReceiveMessageOptInfo info;
        // Create new V2TIMString directly from the safe std::string
        info.userID = V2TIMString(user_id_str.c_str());
        auto it = c2c_receive_opts_.find(user_id_str);
        if (it != c2c_receive_opts_.end()) {
            info.receiveOpt = it->second;
        } else {
            info.receiveOpt = V2TIM_RECEIVE_MESSAGE; // Default: receive messages
        }
        resultVector.PushBack(info);
    }
    
    if (callback) callback->OnSuccess(resultVector);
}
void V2TIMMessageManagerImpl::SetGroupReceiveMessageOpt(const V2TIMString& groupID, V2TIMReceiveMessageOpt opt, V2TIMCallback* callback) {
    std::lock_guard<std::mutex> lock(receive_opt_mutex_);
    std::string gid(groupID.CString());
    group_receive_opts_[gid] = opt;
    V2TIM_LOG(kInfo, "SetGroupReceiveMessageOpt: groupID={}, opt={}", gid.c_str(), static_cast<int>(opt));
    if (callback) callback->OnSuccess();
}
void V2TIMMessageManagerImpl::SetAllReceiveMessageOpt(V2TIMReceiveMessageOpt opt, int32_t startHour, int32_t startMinute, int32_t startSecond, uint32_t duration, V2TIMCallback* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::SetAllReceiveMessageOpt(V2TIMReceiveMessageOpt opt, uint32_t startTimeStamp, uint32_t duration, V2TIMCallback* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::GetAllReceiveMessageOpt(V2TIMValueCallback<V2TIMReceiveMessageOptInfo>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::GetHistoryMessageList(const V2TIMMessageListGetOption& option, V2TIMValueCallback<V2TIMMessageVector>* callback) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "GetHistoryMessageList");
}
void V2TIMMessageManagerImpl::RevokeMessage(const V2TIMMessage& message, V2TIMCallback* callback) {
    // 检查消息是否可以撤回
    if (!RevokeMessageUtil::CanRevokeMessage(message)) {
        if (callback) {
            callback->OnError(ERR_SVR_MSG_REVOKE_TIME_LIMIT, "Message cannot be revoked (time limit exceeded or already revoked)");
        }
        return;
    }
    
    // 获取当前用户ID - 使用 manager_impl_ 而不是 V2TIMManager::GetInstance() 以支持多实例
    V2TIMManagerImpl* manager = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager = manager_impl_;
    }
    
    if (!manager) {
        if (callback) {
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "V2TIMManager not initialized");
        }
        return;
    }
    
    V2TIMString currentUserID = manager->GetLoginUser();
    if (currentUserID.Empty()) {
        if (callback) {
            callback->OnError(ERR_SDK_NOT_LOGGED_IN, "User not logged in");
        }
        return;
    }
    
    // 检查权限：只能撤回自己的消息（群组中管理员可以撤回其他人的消息，这里简化处理）
    if (message.sender != currentUserID) {
        if (callback) {
            callback->OnError(ERR_SVR_GROUP_REVOKE_MSG_DENY, "Can only revoke own messages");
        }
        return;
    }
    
    // 构建撤回通知
    std::string msgID(message.msgID.CString());
    std::string revoker(currentUserID.CString());
    std::string revokeJson = RevokeMessageUtil::BuildRevokeJson(msgID, revoker, "");
    V2TIMBuffer revokeMessage = RevokeMessageUtil::BuildRevokeMessage(revokeJson);
    
    // 判断是C2C还是群组消息
    bool isGroup = !message.groupID.Empty();
    
    if (isGroup) {
        // 发送群组撤回通知
        V2TIMString groupID = message.groupID;
        V2TIMString sentMsgID = manager->SendGroupCustomMessage(
            revokeMessage, 
            groupID, 
            V2TIM_PRIORITY_NORMAL, 
            nullptr  // 撤回通知不需要回调
        );
        
        if (!sentMsgID.Empty()) {
            // 本地标记消息为已撤回
            // 注意：这里无法直接修改message对象，需要通过其他方式通知UIKit
            // UIKit会通过OnRecvMessageRevoked回调来处理UI更新
            
            // 触发撤回回调（通知自己）
            NotifyMessageRevoked(message.msgID, currentUserID, "");
            
            if (callback) {
                callback->OnSuccess();
            }
        } else {
            if (callback) {
                callback->OnError(ERR_SDK_INTERNAL_ERROR, "Failed to send revoke notification");
            }
        }
    } else {
        // 发送C2C撤回通知
        V2TIMString userID = message.userID;
        V2TIMString sentMsgID = manager->SendC2CCustomMessage(
            revokeMessage, 
            userID, 
            nullptr  // 撤回通知不需要回调
        );
        
        if (!sentMsgID.Empty()) {
            // 触发撤回回调（通知自己）
            NotifyMessageRevoked(message.msgID, currentUserID, "");
            
            if (callback) {
                callback->OnSuccess();
            }
        } else {
            if (callback) {
                callback->OnError(ERR_SDK_INTERNAL_ERROR, "Failed to send revoke notification");
            }
        }
    }
}
void V2TIMMessageManagerImpl::ModifyMessage(const V2TIMMessage& message, V2TIMCompleteCallback<V2TIMMessage>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::DeleteMessages(const V2TIMMessageVector& messages, V2TIMCallback* callback) {
    // Tox协议不支持从网络中删除消息，只能删除本地存储
    // 这里我们只返回成功，实际的本地删除由Flutter层处理
    
    if (messages.Size() == 0) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Message list is empty");
        }
        return;
    }
    
    // 检查消息数量限制（最多50条）
    if (messages.Size() > 50) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Cannot delete more than 50 messages at once");
        }
        return;
    }
    
    // 验证所有消息属于同一会话
    V2TIMString firstGroupID;
    V2TIMString firstUserID;
    bool isGroup = false;
    
    for (size_t i = 0; i < messages.Size(); i++) {
        const V2TIMMessage& msg = messages[i];
        if (i == 0) {
            firstGroupID = msg.groupID;
            firstUserID = msg.userID;
            isGroup = !firstGroupID.Empty();
        } else {
            if (isGroup) {
                if (msg.groupID != firstGroupID) {
                    if (callback) {
                        callback->OnError(ERR_INVALID_PARAMETERS, "All messages must belong to the same conversation");
                    }
                    return;
                }
            } else {
                if (msg.userID != firstUserID) {
                    if (callback) {
                        callback->OnError(ERR_INVALID_PARAMETERS, "All messages must belong to the same conversation");
                    }
                    return;
                }
            }
        }
    }
    
    // Tox协议不支持从网络中删除消息，只能删除本地存储
    // 实际的本地删除由Flutter层通过数据库操作完成
    // 这里我们返回成功，表示删除操作已接受
    
    V2TIM_LOG(kInfo, "DeleteMessages: {} messages from {} (local only, Tox doesn't support network deletion)", 
              messages.Size(), isGroup ? firstGroupID.CString() : firstUserID.CString());
    
    if (callback) {
        callback->OnSuccess();
    }
}
void V2TIMMessageManagerImpl::ClearC2CHistoryMessage(const V2TIMString& userID, V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "ClearC2CHistoryMessage: userID={} (local only, Tox doesn't support message deletion)", userID.CString());
    // Tox doesn't support message deletion, so we just return success
    // The Flutter layer will handle clearing local message history
    if (callback) callback->OnSuccess();
}
void V2TIMMessageManagerImpl::ClearGroupHistoryMessage(const V2TIMString& groupID, V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "ClearGroupHistoryMessage: groupID={} (local only, Tox doesn't support message deletion)", groupID.CString());
    // Tox doesn't support message deletion, so we just return success
    // The Flutter layer will handle clearing local message history
    if (callback) callback->OnSuccess();
}
V2TIMString V2TIMMessageManagerImpl::InsertGroupMessageToLocalStorage(V2TIMMessage &message, const V2TIMString &groupID, const V2TIMString &sender, V2TIMValueCallback<V2TIMMessage> *callback) {
    // 设置消息属性
    message.groupID = groupID;
    message.sender = sender;
    // Use manager_impl_ instead of V2TIMManagerImpl::GetInstance() for multi-instance support
    V2TIMManagerImpl* manager = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager = manager_impl_;
    }
    if (manager) {
        message.isSelf = (sender == manager->GetLoginUser());
    } else {
        message.isSelf = false; // Default to false if manager is not available
    }
    
    if (message.msgID.Empty()) {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        message.msgID = manager_impl_ ? manager_impl_->MakeMessageId().c_str() : MakeLocalMessageIdFallback().c_str();
    }
    
    // 设置时间戳
    if (message.timestamp == 0) {
        message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                            std::chrono::system_clock::now().time_since_epoch()).count();
    }
    
    // 设置状态为本地导入
    message.status = V2TIM_MSG_STATUS_LOCAL_IMPORTED;
    
    V2TIM_LOG(kInfo, "InsertGroupMessageToLocalStorage: msgID={}, groupID={}, sender={}", 
              message.msgID.CString(), groupID.CString(), sender.CString());
    
    // 通知监听器（如果需要）
    // 注意：本地插入的消息通常不需要通知，但为了兼容性可以通知
    
    if (callback) {
        callback->OnSuccess(message);
    }
    
    return message.msgID;
}
V2TIMString V2TIMMessageManagerImpl::InsertC2CMessageToLocalStorage(V2TIMMessage &message, const V2TIMString &userID, const V2TIMString &sender, V2TIMValueCallback<V2TIMMessage> *callback) {
    // 设置消息属性
    message.userID = userID;
    message.sender = sender;
    // Use manager_impl_ instead of V2TIMManagerImpl::GetInstance() for multi-instance support
    V2TIMManagerImpl* manager = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager = manager_impl_;
    }
    if (manager) {
        message.isSelf = (sender == manager->GetLoginUser());
    } else {
        message.isSelf = false; // Default to false if manager is not available
    }
    
    if (message.msgID.Empty()) {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        message.msgID = manager_impl_ ? manager_impl_->MakeMessageId().c_str() : MakeLocalMessageIdFallback().c_str();
    }
    
    // 设置时间戳
    if (message.timestamp == 0) {
        message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                            std::chrono::system_clock::now().time_since_epoch()).count();
    }
    
    // 设置状态为本地导入
    message.status = V2TIM_MSG_STATUS_LOCAL_IMPORTED;
    
    V2TIM_LOG(kInfo, "InsertC2CMessageToLocalStorage: msgID={}, userID={}, sender={}", 
              message.msgID.CString(), userID.CString(), sender.CString());
    
    // 通知监听器（如果需要）
    // 注意：本地插入的消息通常不需要通知，但为了兼容性可以通知
    
    if (callback) {
        callback->OnSuccess(message);
    }
    
    return message.msgID;
}
void V2TIMMessageManagerImpl::FindMessages(const V2TIMStringVector& messageIDList, V2TIMValueCallback<V2TIMMessageVector>* callback) {
    // Tox协议没有服务器存储，消息都在Flutter层的本地数据库中
    // 这里返回错误，提示需要从本地数据库查找
    // 注意：Flutter SDK的createForwardMessage需要先调用FindMessages，如果返回错误，
    // 它会尝试从本地数据库查找消息，所以这个实现是合理的
    
    if (!callback) {
        return;
    }
    
    // CRITICAL: Copy messageIDList immediately to avoid lifetime issues
    // Even though we don't use the IDs, we need to safely access Size()
    size_t message_id_count = 0;
    try {
        message_id_count = messageIDList.Size();
    } catch (...) {
        callback->OnError(ERR_INVALID_PARAMETERS, "Failed to access message ID list");
        return;
    }
    
    if (message_id_count == 0) {
        callback->OnError(ERR_INVALID_PARAMETERS, "Message ID list is empty");
        return;
    }
    
    // 由于Tox协议没有服务器存储，消息都在Flutter层的本地数据库中
    // 返回空列表，让Flutter层从本地数据库查找
    // 注意：Flutter SDK的createForwardMessage会检查返回的消息列表是否为空
    // 如果为空，它会返回"message not found"错误，但Flutter层应该能够从本地数据库查找
    V2TIMMessageVector result;
    
    V2TIM_LOG(kInfo, "FindMessages: {} message IDs requested, but Tox doesn't support server-side message storage. Messages should be found from local database.", message_id_count);
    
    // 返回空列表，表示消息不在服务器端（Tox没有服务器）
    // Flutter层应该从本地数据库查找这些消息
    callback->OnSuccess(result);
}
void V2TIMMessageManagerImpl::SearchLocalMessages(const V2TIMMessageSearchParam& searchParam, V2TIMValueCallback<V2TIMMessageSearchResult>* callback) {
    V2TIM_LOG(kInfo, "SearchLocalMessages: searching with {} keywords", searchParam.keywordList.Size());
    
    if (!callback) {
        V2TIM_LOG(kWarning, "SearchLocalMessages: callback is null");
        return;
    }
    
    // Note: Message history is managed by Flutter layer (FfiChatService)
    // C++ layer doesn't have access to message storage
    // Return empty result - actual search should be handled by Flutter layer
    // This allows the search UI to work, but search results will be empty from C++ layer
    // The Flutter layer should implement its own search logic using local database
    
    V2TIMMessageSearchResult result;
    result.totalCount = 0;
    result.messageSearchResultItems.Clear();
    
    V2TIM_LOG(kInfo, "SearchLocalMessages: returning empty result (messages are stored in Flutter layer)");
    callback->OnSuccess(result);
}
void V2TIMMessageManagerImpl::SearchCloudMessages(const V2TIMMessageSearchParam& searchParam, V2TIMValueCallback<V2TIMMessageSearchResult>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::SendMessageReadReceipts(const V2TIMMessageVector& messageList, V2TIMCallback* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::GetMessageReadReceipts(const V2TIMMessageVector& messageList, V2TIMValueCallback<V2TIMMessageReceiptVector>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::GetGroupMessageReadMemberList(const V2TIMMessage& message, V2TIMGroupMessageReadMembersFilter filter, uint64_t nextSeq, uint32_t count, V2TIMValueCallback<V2TIMGroupMessageReadMemberList>* callback) { ReportNotImplemented(callback); }
// Mark-as-read: Tox has no per-message read-receipt protocol like Tencent IM.
// The authoritative local-state implementation lives on the Dart side
// (Tim2ToxSdkPlatform.markC2CMessageAsRead / markGroupMessageAsRead) and updates
// the Flutter-owned MessageHistoryPersistence. On the binary-replacement path
// these C++ entrypoints would otherwise return ERR_SDK_NOT_SUPPORTED (6015),
// which V2TIM-style callers treat as a hard failure. Mirror the Platform-path
// semantic by reporting success without doing any over-the-wire work. The
// Flutter-side BinaryReplacementHistoryHook / persistence layer remains the
// source of truth for local read state.
void V2TIMMessageManagerImpl::MarkC2CMessageAsRead(const V2TIMString& userID, V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "MarkC2CMessageAsRead: userID={} (local no-op; Tox has no read-receipt protocol)", userID.CString());
    if (callback) {
        callback->OnSuccess();
    }
}
void V2TIMMessageManagerImpl::MarkGroupMessageAsRead(const V2TIMString& groupID, V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "MarkGroupMessageAsRead: groupID={} (local no-op; Tox has no read-receipt protocol)", groupID.CString());
    if (callback) {
        callback->OnSuccess();
    }
}
void V2TIMMessageManagerImpl::MarkAllMessageAsRead(V2TIMCallback *callback) {
    V2TIM_LOG(kInfo, "MarkAllMessageAsRead (local no-op; Tox has no read-receipt protocol)");
    if (callback) {
        callback->OnSuccess();
    }
}
void V2TIMMessageManagerImpl::SetMessageExtensions(const V2TIMMessage& message, const V2TIMMessageExtensionVector& extensions, V2TIMValueCallback<V2TIMMessageExtensionResultVector>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::GetMessageExtensions(const V2TIMMessage& message, V2TIMValueCallback<V2TIMMessageExtensionVector>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::DeleteMessageExtensions(const V2TIMMessage& message, const V2TIMStringVector& keys, V2TIMValueCallback<V2TIMMessageExtensionResultVector>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::AddMessageReaction(const V2TIMMessage& message, const V2TIMString& reactionID, V2TIMCallback* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::RemoveMessageReaction(const V2TIMMessage& message, const V2TIMString& reactionID, V2TIMCallback* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::GetMessageReactions(const V2TIMMessageVector& messageList, uint32_t maxUserCountPerReaction, V2TIMValueCallback<V2TIMMessageReactionResultVector>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::GetAllUserListOfMessageReaction(const V2TIMMessage& message, const V2TIMString& reactionID, uint32_t nextSeq, uint32_t count, V2TIMValueCallback<V2TIMMessageReactionUserResult>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::TranslateText(const V2TIMStringVector& sourceTextList, const V2TIMString& sourceLanguage, const V2TIMString& targetLanguage, V2TIMValueCallback<V2TIMStringToV2TIMStringMap>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::PinGroupMessage(const V2TIMString& groupID, const V2TIMMessage& message, bool isPinned, V2TIMCallback* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::GetPinnedGroupMessageList(const V2TIMString& groupID, V2TIMValueCallback<V2TIMMessageVector>* callback) { ReportNotImplemented(callback); }
void V2TIMMessageManagerImpl::DownloadMergerMessage(const V2TIMMessage &message, V2TIMValueCallback<V2TIMMessageVector> *callback) { ReportNotImplemented(callback); }

// --- Internal method to notify listeners ---
void V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage(const V2TIMMessage& message) {
    V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage] ========== ENTRY ==========");
    V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage] msgID={}, groupID={}, sender={}", 
             message.msgID.CString(), message.groupID.CString(), message.sender.CString());
    
    std::vector<V2TIMAdvancedMsgListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_to_notify.assign(listeners_.begin(), listeners_.end());
        V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage] Found {} listeners to notify", 
                 listeners_to_notify.size());
    }

    for (V2TIMAdvancedMsgListener* listener : listeners_to_notify) {
        if (listener) {
            V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage] Calling OnRecvNewMessage on listener={}", 
                     (void*)listener);
            // TODO: Add more checks/details if needed
            listener->OnRecvNewMessage(message);
            V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage] OnRecvNewMessage completed");
        } else {
            V2TIM_LOG(kWarning, "[V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage] Found null listener, skipping");
        }
    }
    
    V2TIM_LOG(kInfo, "[V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage] ========== EXIT ==========");
}

void V2TIMMessageManagerImpl::NotifyMessageRevoked(const V2TIMString& msgID, const V2TIMString& revoker, const V2TIMString& reason) {
    // 创建撤回者信息
    V2TIMUserFullInfo revokerInfo;
    revokerInfo.userID = revoker;
    // TODO: 可以从本地缓存获取更完整的用户信息
    
    // 通知所有监听器
    std::vector<V2TIMAdvancedMsgListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_to_notify.assign(listeners_.begin(), listeners_.end());
    }
    
    for (V2TIMAdvancedMsgListener* listener : listeners_to_notify) {
        if (listener) {
            // 调用新接口（带撤回者信息和原因）
            listener->OnRecvMessageRevoked(msgID, revokerInfo, reason);
            // 同时调用旧接口（兼容性）
            listener->OnRecvMessageRevoked(msgID);
        }
    }
}
