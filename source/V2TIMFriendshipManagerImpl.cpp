#include "V2TIMFriendshipManagerImpl.h"
#include "V2TIMUtils.h"
#include "ToxManager.h"
#include "V2TIMErrorCode.h"
#include "V2TIMLog.h"
#include "V2TIMConversationManagerImpl.h"
#include <V2TIMManagerImpl.h> // May need for user info lookups?
#include <vector>
#include <algorithm> // For std::remove, std::transform
#include <cctype> // For std::tolower
#include <thread> // For std::this_thread::sleep_for
#include <chrono> // For std::chrono::milliseconds
#include "ToxUtils.h" // 添加工具函数头文件
#include "ToxUtil.h"

// Constructor (R-06: owned by V2TIMManagerImpl, no singleton)
V2TIMFriendshipManagerImpl::V2TIMFriendshipManagerImpl(V2TIMManagerImpl* owner) : manager_impl_(owner) {
    V2TIM_LOG(kInfo, "V2TIMFriendshipManagerImpl initialized.");
}

ToxManager* V2TIMFriendshipManagerImpl::GetToxManager() {
    return manager_impl_ ? manager_impl_->GetToxManager() : nullptr;
}

// Destructor
V2TIMFriendshipManagerImpl::~V2TIMFriendshipManagerImpl() {
    if (refresh_after_accept_thread_.joinable()) {
        try {
            refresh_after_accept_thread_.join();
        } catch (...) {}
    }
}

// 好友请求存储改由 NotifyFriendApplicationListAdded 统一处理

// --- Listener Management ---
void V2TIMFriendshipManagerImpl::AddFriendListener(V2TIMFriendshipListener* listener) {
    std::lock_guard<std::mutex> lock(listener_mutex_);
    if (listener) {
        // Avoid duplicates
        bool found = false;
        for (const auto& existing_listener : listeners_) {
            if (existing_listener == listener) {
                found = true;
                break;
            }
        }
        if (!found) {
            listeners_.push_back(listener);
        }
    }
}

void V2TIMFriendshipManagerImpl::RemoveFriendListener(V2TIMFriendshipListener* listener) {
    std::lock_guard<std::mutex> lock(listener_mutex_);
    if (listener) {
        listeners_.erase(std::remove(listeners_.begin(), listeners_.end(), listener), listeners_.end());
    }
}

// --- Helper for Reporting Not Implemented --- 
void V2TIMFriendshipManagerImpl::ReportNotImplemented(V2TIMCallback* callback) {
    if (callback) {
        callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Feature not supported in Tox wrapper");
    }
}

template <typename T>
void V2TIMFriendshipManagerImpl::ReportNotImplemented(V2TIMValueCallback<T>* callback) {
    if (callback) {
        callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Feature not supported in Tox wrapper");
    }
}

template <typename T>
void V2TIMFriendshipManagerImpl::ReportNotImplemented(V2TIMCompleteCallback<T>* callback) {
     if (callback) {
        callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Feature not supported in Tox wrapper");
    }
}

// --- Internal Notification Helpers ---
void V2TIMFriendshipManagerImpl::NotifyFriendApplicationListAdded(const V2TIMFriendApplicationVector& applicationList) {
    V2TIM_LOG(kInfo, "[NotifyFriendApplicationListAdded] ENTRY - Adding {} applications", applicationList.Size());
    {
        std::lock_guard<std::mutex> lock(application_mutex_);
        size_t before_size = pending_applications_.Size();
        for (size_t i = 0; i < applicationList.Size(); ++i) {
            V2TIM_LOG(kInfo, "[NotifyFriendApplicationListAdded] Adding application[{}]: userID={}, addWording={}",
                      i, applicationList[i].userID.CString(), applicationList[i].addWording.CString());
            pending_applications_.PushBack(applicationList[i]);
            if (pending_applications_.Size() > 100) {
                // 保持最多100条，简单丢弃最早的
                V2TIMFriendApplicationVector trimmed;
                for (size_t j = 1; j < pending_applications_.Size(); ++j) {
                    trimmed.PushBack(pending_applications_[j]);
                }
                pending_applications_ = trimmed;
            }
        }
        size_t after_size = pending_applications_.Size();
        V2TIM_LOG(kInfo, "[NotifyFriendApplicationListAdded] pending_applications_ size: {} -> {}", before_size, after_size);
    }
    std::vector<V2TIMFriendshipListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_copy = listeners_; // Copy to allow modification during callback
    }
    V2TIM_LOG(kInfo, "Notifying {} FriendshipListeners about new applications.", listeners_copy.size());
    for (V2TIMFriendshipListener* listener : listeners_copy) {
        if (listener) {
            listener->OnFriendApplicationListAdded(applicationList);
        }
    }
}

void V2TIMFriendshipManagerImpl::NotifyFriendApplicationListDeleted(const V2TIMStringVector& userIDList) {
    if (userIDList.Empty()) return;
    {
        std::lock_guard<std::mutex> lock(application_mutex_);
        for (size_t i = 0; i < userIDList.Size(); ++i) {
            const V2TIMString& uid = userIDList[i];
            for (size_t j = 0; j < pending_applications_.Size(); ) {
                if (pending_applications_[j].userID == uid) {
                    V2TIM_LOG(kInfo, "[NotifyFriendApplicationListDeleted] Removing application: userID={}", uid.CString());
                    pending_applications_.Erase(j);
                    continue;
                }
                ++j;
            }
        }
    }
    std::vector<V2TIMFriendshipListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_copy = listeners_;
    }
    V2TIM_LOG(kInfo, "Notifying {} FriendshipListeners about application list deleted.", listeners_copy.size());
    for (V2TIMFriendshipListener* listener : listeners_copy) {
        if (listener) {
            listener->OnFriendApplicationListDeleted(userIDList);
        }
    }
}

void V2TIMFriendshipManagerImpl::NotifyFriendInfoChanged(const V2TIMFriendInfoResultVector& infoList) {
     std::vector<V2TIMFriendshipListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_copy = listeners_; 
    }
    V2TIM_LOG(kInfo, "Notifying {} FriendshipListeners about friend info changes.", listeners_copy.size());
    V2TIMFriendInfoVector friendInfoList; 
    
    // CRITICAL: Use index-based loop instead of range-based for loop to avoid iterator issues
    // Range-based for loops may access beyond vector bounds if the vector is corrupted
    // The begin()/end() implementation uses operator[] which has bounds checking, but
    // range-based for loops can still cause issues if the vector size changes during iteration
    try {
        size_t info_list_size = infoList.Size();
        if (info_list_size > 0 && info_list_size < 100000) { // Reasonable size limit
            for (size_t i = 0; i < info_list_size; i++) {
                try {
                    // CRITICAL: Verify index is valid before accessing
                    // Re-check size on each iteration in case it changes
                    size_t current_size = infoList.Size();
                    if (i >= current_size) {
                        break;
                    }
                    
                    // CRITICAL: Safely access result using operator[] which has bounds checking
                    const V2TIMFriendInfoResult& result = infoList[i];
                    
                    if (result.resultCode == 0) { 
                        // CRITICAL: Safely copy result.friendInfo with exception handling
                        // The friendInfo may contain corrupted V2TIMString members
                        try {
                            // Try to access friendInfo to verify it's valid
                            // CString() now has built-in protection, so we can safely call it
                            const char* test_user_id = result.friendInfo.userID.CString();
                            if (test_user_id) {
                                friendInfoList.PushBack(result.friendInfo);
                            }
                        } catch (...) {
                            // Skip this result on error
                        }
                    }
                } catch (...) {
                    // Continue to next iteration on error
                }
            }
        }
    } catch (...) {
        // Ignore errors accessing infoList
    }
    if (!friendInfoList.Empty()) { // Only notify if there are actual changes
        // CRITICAL: Verify friendInfoList is valid before iterating
        try {
            size_t list_size = friendInfoList.Size();
            if (list_size > 0 && list_size < 100000) { // Reasonable size limit
                for (V2TIMFriendshipListener* listener : listeners_copy) {
                    if (listener) {
                        try {
                            listener->OnFriendInfoChanged(friendInfoList);
                        } catch (...) {
                            // Ignore listener errors
                        }
                    }
                }
            }
        } catch (...) {
            // Ignore errors accessing friendInfoList
        }
    }
}

void V2TIMFriendshipManagerImpl::NotifyFriendListAdded(const V2TIMFriendInfoVector& infoList) {
     std::vector<V2TIMFriendshipListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_copy = listeners_; 
    }
    V2TIM_LOG(kInfo, "Notifying {} FriendshipListeners about friend list added.", listeners_copy.size());
    if (!infoList.Empty()) {
        // CRITICAL: Verify infoList is valid before iterating
        try {
            size_t list_size = infoList.Size();
            if (list_size > 0 && list_size < 100000) { // Reasonable size limit
                for (V2TIMFriendshipListener* listener : listeners_copy) {
                    if (listener) {
                        try {
                            listener->OnFriendListAdded(infoList);
                        } catch (...) {
                            // Ignore listener errors
                        }
                    }
                }
            }
        } catch (...) {
            // Ignore errors accessing infoList
        }
    }
}
void V2TIMFriendshipManagerImpl::NotifyFriendListDeleted(const V2TIMStringVector& userIDList) {
     std::vector<V2TIMFriendshipListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_copy = listeners_; 
    }
    V2TIM_LOG(kInfo, "Notifying {} FriendshipListeners about friend list deleted.", listeners_copy.size());
     if (!userIDList.Empty()) {
        for (V2TIMFriendshipListener* listener : listeners_copy) {
            if (listener) {
                listener->OnFriendListDeleted(userIDList);
            }
        }
    }
}
void V2TIMFriendshipManagerImpl::NotifyBlackListAdded(const V2TIMFriendInfoVector& infoList) {
    std::vector<V2TIMFriendshipListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_copy = listeners_; 
    }
    V2TIM_LOG(kInfo, "Notifying {} FriendshipListeners about blacklist added.", listeners_copy.size());
     if (!infoList.Empty()) {
        for (V2TIMFriendshipListener* listener : listeners_copy) {
            if (listener) {
                listener->OnBlackListAdded(infoList);
            }
        }
    }
}
void V2TIMFriendshipManagerImpl::NotifyBlackListDeleted(const V2TIMStringVector& userIDList) {
     std::vector<V2TIMFriendshipListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(listener_mutex_);
        listeners_copy = listeners_; 
    }
    V2TIM_LOG(kInfo, "Notifying {} FriendshipListeners about blacklist deleted.", listeners_copy.size());
    if (!userIDList.Empty()) {
        for (V2TIMFriendshipListener* listener : listeners_copy) {
            if (listener) {
                listener->OnBlackListDeleted(userIDList);
            }
        }
    }
}


// --- Public API Implementations (Placeholders) ---
void V2TIMFriendshipManagerImpl::GetFriendList(V2TIMValueCallback<V2TIMFriendInfoVector>* callback) { 
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        // Teardown or default instance: avoid noisy stdout; still report via callback
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    Tox* tox = tox_manager->getTox();
    
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }
    
    V2TIMFriendInfoVector friendInfoVector;
    size_t friendCount = tox_self_get_friend_list_size(tox);
    
    if (friendCount > 0) {
        std::vector<uint32_t> friendList(friendCount);
        tox_self_get_friend_list(tox, friendList.data());
        
        for (uint32_t friendNumber : friendList) {
            V2TIMFriendInfo friendInfo;
            
            // Get friend public key (Tox ID) and use it as userID
            uint8_t friendId[TOX_PUBLIC_KEY_SIZE];
            if (tox_friend_get_public_key(tox, friendNumber, friendId, nullptr)) {
                // Manual conversion to hex string
                char hexId[TOX_PUBLIC_KEY_SIZE * 2 + 1];
                for (size_t i = 0; i < TOX_PUBLIC_KEY_SIZE; i++) {
                    sprintf(hexId + i * 2, "%02X", friendId[i]);
                }
                hexId[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
                friendInfo.userID = hexId;
                
                // Get friend name if available
                size_t nameLen = tox_friend_get_name_size(tox, friendNumber, nullptr);
                if (nameLen > 0) {
                    std::vector<uint8_t> nameBytes(nameLen);
                    if (tox_friend_get_name(tox, friendNumber, nameBytes.data(), nullptr)) {
                        friendInfo.friendRemark = std::string(nameBytes.begin(), nameBytes.end());
                    }
                }
                
                // Get friend status message if available
                size_t statusLen = tox_friend_get_status_message_size(tox, friendNumber, nullptr);
                if (statusLen > 0) {
                    std::vector<uint8_t> statusBytes(statusLen);
                    if (tox_friend_get_status_message(tox, friendNumber, statusBytes.data(), nullptr)) {
                        std::string statusStr(statusBytes.begin(), statusBytes.end());
                        V2TIMBuffer statusBuffer(statusBytes.data(), statusLen);
                        friendInfo.friendCustomInfo.Insert("statusMessage", statusBuffer);
                    }
                }
                
                // Get online status
                TOX_CONNECTION connection = tox_friend_get_connection_status(tox, friendNumber, nullptr);
                friendInfo.userFullInfo.role = (connection != TOX_CONNECTION_NONE) ? V2TIM_USER_STATUS_ONLINE : V2TIM_USER_STATUS_OFFLINE;
                
                friendInfoVector.PushBack(friendInfo);
            }
        }
    }
    if (callback) callback->OnSuccess(friendInfoVector);
}

void V2TIMFriendshipManagerImpl::GetFriendsInfo(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendInfoResultVector>* callback) { 
    V2TIM_LOG(kInfo, "GetFriendsInfo called");
     ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        ReportNotImplemented(callback); // Or specific error
        return;
    }
    
    // CRITICAL: Copy userIDList immediately to avoid lifetime issues
    // Extract C-strings first and store them in std::string to avoid
    // accessing potentially invalid impl_ pointers from V2TIMString objects
    std::vector<std::string> user_id_strings;  // Store C-strings safely
    try {
        for (size_t i = 0; i < userIDList.Size(); i++) {
            try {
                const V2TIMString& userID = userIDList[i];
                // CRITICAL: Extract C-string immediately before copying
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
                // Store C-string in std::string for safety (thread-safe copy)
                user_id_strings.push_back(std::string(user_id_cstr, user_id_len));
            } catch (...) {
                continue;
            }
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to copy user ID list");
        return;
    }
    
    V2TIMFriendInfoResultVector resultList;
    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    for (const auto& user_id_str : user_id_strings) {
        V2TIMFriendInfoResult result;
        // Create new V2TIMString directly from the safe std::string
        result.resultInfo = V2TIMString(user_id_str.c_str());
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
        const char* user_id_cstr = user_id_str.c_str();
        size_t user_id_len = user_id_str.length();
        if (ToxUtil::tox_hex_to_bytes(user_id_cstr, user_id_len, pubkey, TOX_PUBLIC_KEY_SIZE)) {
             TOX_ERR_FRIEND_BY_PUBLIC_KEY err_find;
             uint32_t friend_num = tox_friend_by_public_key(tox, pubkey, &err_find);
             if (err_find == TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
                 // Found friend
                 V2TIMFriendInfo info;
                 // Use the safe std::string to create new V2TIMString
                 info.userID = V2TIMString(user_id_str.c_str());
                 
                 // Get friend name
                 TOX_ERR_FRIEND_QUERY err_name;
                 size_t name_size = tox_friend_get_name_size(tox, friend_num, &err_name);
                 if (name_size > 0 && err_name == TOX_ERR_FRIEND_QUERY_OK) {
                     std::vector<uint8_t> name_buffer(name_size);
                     if (tox_friend_get_name(tox, friend_num, name_buffer.data(), &err_name) && err_name == TOX_ERR_FRIEND_QUERY_OK) {
                         // 修改为使用正确的属性
                         info.userFullInfo.nickName = V2TIMString(reinterpret_cast<const char*>(name_buffer.data()), name_size);
                     }
                  }
                  // TODO: Get remark, groups, etc.
                  
                  result.friendInfo = info;
                  result.resultCode = 0;
              } else {
                  result.resultCode = ERR_SVR_FRIENDSHIP_INVALID; // Not a friend
              }
          } else {
             result.resultCode = ERR_INVALID_PARAMETERS;
          }
         resultList.PushBack(result);
    }
    if (callback) callback->OnSuccess(resultList);
}
void V2TIMFriendshipManagerImpl::SetFriendInfo(const V2TIMFriendInfo& info, V2TIMCallback* callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::string userID(info.userID.CString());
    
    // Update or create friend info in local storage
    if (friend_info_db_.find(userID) != friend_info_db_.end()) {
        // Update existing friend info
        V2TIMFriendInfo& existing = friend_info_db_[userID];
        if (!info.friendRemark.Empty()) {
            existing.friendRemark = info.friendRemark;
        }
        if (info.friendCustomInfo.Size() > 0) {
            existing.friendCustomInfo = info.friendCustomInfo;
        }
        V2TIM_LOG(kInfo, "SetFriendInfo: Updated friend info for %s", userID.c_str());
    } else {
        // Create new friend info entry
        friend_info_db_[userID] = info;
        V2TIM_LOG(kInfo, "SetFriendInfo: Created friend info for %s", userID.c_str());
    }
    
    // Notify listeners about friend info change
    {
        std::lock_guard<std::mutex> listener_lock(listener_mutex_);
        V2TIMFriendInfoVector infoList;
        infoList.PushBack(friend_info_db_[userID]);
        for (auto* listener : listeners_) {
            if (listener) {
                listener->OnFriendInfoChanged(infoList);
            }
        }
    }
    
    if (callback) callback->OnSuccess();
}
void V2TIMFriendshipManagerImpl::SearchFriends(const V2TIMFriendSearchParam& searchParam, V2TIMValueCallback<V2TIMFriendInfoResultVector>* callback) { 
    V2TIM_LOG(kInfo, "SearchFriends: searching with %zu keywords", searchParam.keywordList.Size());
    
    if (!callback) {
        V2TIM_LOG(kWarning, "SearchFriends: callback is null");
        return;
    }
    
    if (searchParam.keywordList.Size() == 0) {
        V2TIM_LOG(kWarning, "SearchFriends: no keywords provided");
        V2TIMFriendInfoResultVector emptyResult;
        callback->OnSuccess(emptyResult);
        return;
    }
    
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "SearchFriends: tox is null");
        callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }
    
    V2TIMFriendInfoResultVector resultList;
    
    // Get all friends from Tox
    size_t friendCount = tox_self_get_friend_list_size(tox);
    if (friendCount == 0) {
        V2TIM_LOG(kInfo, "SearchFriends: no friends found");
        callback->OnSuccess(resultList);
        return;
    }
    
    std::vector<uint32_t> friendList(friendCount);
    tox_self_get_friend_list(tox, friendList.data());
    
    V2TIM_LOG(kInfo, "SearchFriends: searching through %zu friends", friendCount);
    
    // Search through all friends
    for (uint32_t friendNumber : friendList) {
        V2TIMFriendInfo friendInfo;
        bool matched = false;
        
        // Get friend public key (Tox ID) and use it as userID
        uint8_t friendId[TOX_PUBLIC_KEY_SIZE];
        if (!tox_friend_get_public_key(tox, friendNumber, friendId, nullptr)) {
            continue; // Skip if can't get public key
        }
        
        // Convert to hex string
        char hexId[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        for (size_t i = 0; i < TOX_PUBLIC_KEY_SIZE; i++) {
            sprintf(hexId + i * 2, "%02X", friendId[i]);
        }
        hexId[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendInfo.userID = hexId;
        
        // Get friend name (nickname)
        std::string nickName;
        size_t nameLen = tox_friend_get_name_size(tox, friendNumber, nullptr);
        if (nameLen > 0) {
            std::vector<uint8_t> nameBytes(nameLen);
            if (tox_friend_get_name(tox, friendNumber, nameBytes.data(), nullptr)) {
                nickName = std::string(nameBytes.begin(), nameBytes.end());
                friendInfo.friendRemark = nickName; // Use name as remark
            }
        }
        
        // Get friend status message
        size_t statusLen = tox_friend_get_status_message_size(tox, friendNumber, nullptr);
        if (statusLen > 0) {
            std::vector<uint8_t> statusBytes(statusLen);
            if (tox_friend_get_status_message(tox, friendNumber, statusBytes.data(), nullptr)) {
                std::string statusStr(statusBytes.begin(), statusBytes.end());
                V2TIMBuffer statusBuffer(statusBytes.data(), statusLen);
                friendInfo.friendCustomInfo.Insert("statusMessage", statusBuffer);
            }
        }
        
        // Get online status
        TOX_CONNECTION connection = tox_friend_get_connection_status(tox, friendNumber, nullptr);
        friendInfo.userFullInfo.role = (connection != TOX_CONNECTION_NONE) ? V2TIM_USER_STATUS_ONLINE : V2TIM_USER_STATUS_OFFLINE;
        
        // Check each keyword
        for (size_t i = 0; i < searchParam.keywordList.Size(); ++i) {
            const V2TIMString& keyword = searchParam.keywordList[i];
            const std::string keywordStr = keyword.CString();
            std::string keywordLower = keywordStr;
            std::transform(keywordLower.begin(), keywordLower.end(), keywordLower.begin(), ::tolower);
            
            // Search by userID if enabled (default to true if not specified)
            if (searchParam.isSearchUserID || (!searchParam.isSearchNickName && !searchParam.isSearchRemark)) {
                std::string userIdLower = hexId;
                std::transform(userIdLower.begin(), userIdLower.end(), userIdLower.begin(), ::tolower);
                if (userIdLower.find(keywordLower) != std::string::npos) {
                    matched = true;
                    break;
                }
            }
            
            // Search by nickname if enabled (default to true if not specified)
            if (searchParam.isSearchNickName || (!searchParam.isSearchUserID && !searchParam.isSearchRemark)) {
                if (!nickName.empty()) {
                    std::string nickNameLower = nickName;
                    std::transform(nickNameLower.begin(), nickNameLower.end(), nickNameLower.begin(), ::tolower);
                    if (nickNameLower.find(keywordLower) != std::string::npos) {
                        matched = true;
                        break;
                    }
                }
            }
            
            // Search by remark if enabled (default to true if not specified)
            // Note: In Tox, we use friend name as remark
            if (searchParam.isSearchRemark || (!searchParam.isSearchUserID && !searchParam.isSearchNickName)) {
                if (!nickName.empty()) {
                    std::string remarkLower = nickName;
                    std::transform(remarkLower.begin(), remarkLower.end(), remarkLower.begin(), ::tolower);
                    if (remarkLower.find(keywordLower) != std::string::npos) {
                        matched = true;
                        break;
                    }
                }
            }
        }
        
        if (matched) {
            V2TIMFriendInfoResult result;
            result.resultCode = 0;
            result.resultInfo = friendInfo.userID;
            result.relation = V2TIM_FRIEND_RELATION_TYPE_IN_MY_FRIEND_LIST; // Friend is in our list
            result.friendInfo = friendInfo;
            resultList.PushBack(result);
        }
    }
    
    V2TIM_LOG(kInfo, "SearchFriends: found %zu matching friends", resultList.Size());
    callback->OnSuccess(resultList);
}

void V2TIMFriendshipManagerImpl::AddFriend(const V2TIMFriendAddApplication& application, V2TIMValueCallback<V2TIMFriendOperationResult>* callback) {
    V2TIM_LOG(kInfo, "AddFriend ENTRY - userID length={}, userID={}, addWording length={}, addWording={}",
              application.userID.Length(), application.userID.CString(), application.addWording.Length(), application.addWording.CString());

    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[AddFriend] ToxManager not initialized");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    
    std::string current_address = tox_manager->getAddress();
    V2TIM_LOG(kInfo, "[AddFriend] Current node address (full): {}, Target userID (full): {}", current_address, application.userID.CString());
    
    Tox* tox = tox_manager->getTox();
    V2TIMFriendOperationResult result; // Declare outside if
    // Normalize userID to 64-char public key for consistent identification
    std::string normalized_uid(application.userID.CString());
    if (normalized_uid.length() > 64) {
        normalized_uid = normalized_uid.substr(0, 64);
    }
    result.userID = V2TIMString(normalized_uid.c_str());

    if (!tox) {
        result.resultCode=ERR_SDK_NOT_INITIALIZED;
        result.resultInfo = "Tox not initialized";
        if (callback) callback->OnSuccess(result); // Use OnSuccess as per V2TIM spec for this op
        return;
    }
    
    // Accept either full Tox address or raw public key hex.
    Tox_Err_Friend_Add err_add;
    uint32_t friend_number = UINT32_MAX; // Initialize to invalid value
    if (application.userID.Length() == TOX_ADDRESS_SIZE * 2) {
        uint8_t address[TOX_ADDRESS_SIZE] = {0};
        if (!ToxUtil::tox_hex_to_bytes(application.userID.CString(), application.userID.Length(), address, TOX_ADDRESS_SIZE)) {
            result.resultCode=ERR_INVALID_PARAMETERS;
            result.resultInfo = "Invalid Tox Address hex";
            if (callback) callback->OnSuccess(result);
            return;
        }
        V2TIM_LOG(kInfo, "[AddFriend] Calling tox_friend_add: target_address (first 20)={}, message_len={}",
                  std::string(application.userID.CString()).substr(0, 20), application.addWording.Length());
        {
            std::string hex10;
            for (int i = 0; i < 10 && i < TOX_ADDRESS_SIZE; ++i) {
                char buf[4];
                snprintf(buf, sizeof(buf), "%02X", address[i]);
                hex10 += buf;
            }
            V2TIM_LOG(kInfo, "[AddFriend] Address bytes (first 10): {}...", hex10);
        }
        TOX_CONNECTION self_connection = tox_self_get_connection_status(tox);
        V2TIM_LOG(kInfo, "[AddFriend] Current self connection status: {} (0=NONE, 1=TCP, 2=UDP)", static_cast<int>(self_connection));
        if (self_connection == TOX_CONNECTION_NONE) {
            V2TIM_LOG(kWarning, "[AddFriend] Self is not connected to Tox network! Friend request may not be delivered.");
        }

        friend_number = tox_friend_add(tox, address,
                       reinterpret_cast<const uint8_t*>(application.addWording.CString()),
                       application.addWording.Length(),
                       &err_add);
        V2TIM_LOG(kInfo, "[AddFriend] tox_friend_add returned: friend_number={}, err_add={} (0=pending, UINT32_MAX=error)", friend_number, err_add);
        if (err_add != TOX_ERR_FRIEND_ADD_OK) {
            V2TIM_LOG(kError, "[AddFriend] tox_friend_add failed with error code {}", err_add);
            switch(err_add) {
                case TOX_ERR_FRIEND_ADD_NULL: V2TIM_LOG(kError, "[AddFriend] TOX_ERR_FRIEND_ADD_NULL (Invalid arguments)"); break;
                case TOX_ERR_FRIEND_ADD_TOO_LONG: V2TIM_LOG(kError, "[AddFriend] TOX_ERR_FRIEND_ADD_TOO_LONG (Message too long)"); break;
                case TOX_ERR_FRIEND_ADD_ALREADY_SENT: V2TIM_LOG(kError, "[AddFriend] TOX_ERR_FRIEND_ADD_ALREADY_SENT (Already sent)"); break;
                case TOX_ERR_FRIEND_ADD_BAD_CHECKSUM: V2TIM_LOG(kError, "[AddFriend] TOX_ERR_FRIEND_ADD_BAD_CHECKSUM (Bad checksum)"); break;
                default: V2TIM_LOG(kError, "[AddFriend] Unknown error code {}", err_add); break;
            }
        }
    } else if (application.userID.Length() == TOX_PUBLIC_KEY_SIZE * 2) {
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE] = {0};
        if (!ToxUtil::tox_hex_to_bytes(application.userID.CString(), application.userID.Length(), pubkey, TOX_PUBLIC_KEY_SIZE)) {
            result.resultCode=ERR_INVALID_PARAMETERS;
            result.resultInfo = "Invalid Public Key hex";
            if (callback) callback->OnSuccess(result);
            return;
        }
        // Build a minimal address from pubkey is not correct; require full address for friend_add.
        result.resultCode=ERR_INVALID_PARAMETERS;
        result.resultInfo = "Friend add requires full Tox address";
        if (callback) callback->OnSuccess(result);
        return;
    } else {
        result.resultCode=ERR_INVALID_PARAMETERS;
        result.resultInfo = "UserID hex length invalid";
        if (callback) callback->OnSuccess(result);
        return;
    }

    if (err_add == TOX_ERR_FRIEND_ADD_OK) {
        result.resultCode = 0;
        result.resultInfo = "Friend request sent";
        if (friend_number != UINT32_MAX) {
            V2TIM_LOG(kInfo, "[AddFriend] SUCCESS: Friend request sent, friend_number={} (pending in Tox)", friend_number);
        } else {
            V2TIM_LOG(kInfo, "[AddFriend] SUCCESS: Friend request sent (no friend_number)");
        }
        V2TIM_LOG(kInfo, "[AddFriend] Friend request will be received by target when Tox network propagates it (may take several seconds)");

        // Notify listeners about new friend added.
        // IMPORTANT: Normalize userID to 64-char public key. application.userID may
        // be the 76-char Tox address (pubkey + nospam + checksum). If we send the
        // 76-char version, UIKit adds a contact with a 76-char userID that can never
        // be matched by deleteFromFriendList (which uses the 64-char public key from
        // GetFriendList / OnFriendListDeleted).
        V2TIMFriendInfoVector addedFriends;
        V2TIMFriendInfo friendInfo;
        std::string user_id_for_notify(application.userID.CString());
        if (user_id_for_notify.length() > 64) {
            user_id_for_notify = user_id_for_notify.substr(0, 64);
        }
        friendInfo.userID = V2TIMString(user_id_for_notify.c_str());
        addedFriends.PushBack(friendInfo);
        NotifyFriendListAdded(addedFriends);

        // Save Tox profile to disk so the new friend persists
        if (manager_impl_) {
            manager_impl_->SaveToxProfile();
        }

        // Refresh conversation cache so the new friend's conversation appears
        if (manager_impl_) {
            V2TIMConversationManager* cm = manager_impl_->GetConversationManager();
            if (cm) static_cast<V2TIMConversationManagerImpl*>(cm)->RefreshCache();
        }
    } else {
        // Map Tox error to V2TIM error code/info
        result.resultCode = ERR_SDK_FRIEND_ADD_FAILED; // General error
        switch(err_add) {
            case TOX_ERR_FRIEND_ADD_NULL: result.resultInfo = "Invalid arguments"; result.resultCode = ERR_INVALID_PARAMETERS; break;
            case TOX_ERR_FRIEND_ADD_TOO_LONG: result.resultInfo = "Request message too long"; result.resultCode = ERR_INVALID_PARAMETERS; break;
            case TOX_ERR_FRIEND_ADD_NO_MESSAGE: result.resultInfo = "Request message is empty"; result.resultCode = ERR_INVALID_PARAMETERS; break;
            case TOX_ERR_FRIEND_ADD_OWN_KEY: result.resultInfo = "Cannot add yourself"; result.resultCode = ERR_SDK_FRIEND_ADD_SELF; break;
            case TOX_ERR_FRIEND_ADD_ALREADY_SENT: result.resultInfo = "Friend request already sent"; result.resultCode = ERR_SDK_FRIEND_REQ_SENT; break;
            case TOX_ERR_FRIEND_ADD_BAD_CHECKSUM: result.resultInfo = "Invalid Tox ID checksum"; result.resultCode = ERR_INVALID_PARAMETERS; break;
            case TOX_ERR_FRIEND_ADD_SET_NEW_NOSPAM: result.resultInfo = "Invalid nospam value"; result.resultCode = ERR_INVALID_PARAMETERS; break;
            case TOX_ERR_FRIEND_ADD_MALLOC: result.resultInfo = "Memory allocation failed"; result.resultCode = ERR_OUT_OF_MEMORY; break;
            default: result.resultInfo = "Unknown error sending friend request"; break;
        }
        V2TIM_LOG(kError, "[AddFriend] FAILED: resultCode={}, resultInfo={}, err_add={}", result.resultCode, result.resultInfo.CString(), err_add);
    }
    V2TIM_LOG(kInfo, "[AddFriend] EXIT resultCode={}, callback={}", result.resultCode, (void*)callback);
    if (callback) {
        V2TIM_LOG(kInfo, "[AddFriend] Calling callback->OnSuccess with resultCode={}", result.resultCode);
        callback->OnSuccess(result);
        V2TIM_LOG(kInfo, "[AddFriend] callback->OnSuccess completed");
    } else {
        V2TIM_LOG(kWarning, "[AddFriend] callback is null, not calling OnSuccess");
    }
}

void V2TIMFriendshipManagerImpl::DeleteFromFriendList(const V2TIMStringVector& userIDList, V2TIMFriendType deleteType, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) { 
    V2TIM_LOG(kInfo, "DeleteFromFriendList called with %zu user(s)", userIDList.Size());
    
    // Check if Tox is initialized (more reliable than IsRunning check)
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "DeleteFromFriendList: Tox instance is null, cannot delete friends");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }
    V2TIM_LOG(kInfo, "DeleteFromFriendList: Tox instance is valid, proceeding with deletion");
    
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
    
    // Tox only offers "both" direction deletion.
    // It doesn't have a concept of single-sided friendship deletion.
    if (deleteType != V2TIM_FRIEND_TYPE_BOTH) {
        V2TIM_LOG(kWarning, "DeleteFromFriendList: Only V2TIM_FRIEND_TYPE_BOTH is supported by Tox.");
    }

    V2TIMFriendOperationResultVector results;
    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    for (const auto& user_id_str : user_id_strings) {
        V2TIMFriendOperationResult result;
        // Create new V2TIMString directly from the safe std::string
        result.userID = V2TIMString(user_id_str.c_str());
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE] = {0};
        bool ok = false;
        const char* user_id_cstr = user_id_str.c_str();
        size_t user_id_len = user_id_str.length();
        if (user_id_len == TOX_PUBLIC_KEY_SIZE * 2) {
            ok = ToxUtil::tox_hex_to_bytes(user_id_cstr, user_id_len, pubkey, TOX_PUBLIC_KEY_SIZE);
        } else if (user_id_len == TOX_ADDRESS_SIZE * 2) {
            uint8_t address[TOX_ADDRESS_SIZE] = {0};
            if (ToxUtil::tox_hex_to_bytes(user_id_cstr, user_id_len, address, TOX_ADDRESS_SIZE)) {
                memcpy(pubkey, address, TOX_PUBLIC_KEY_SIZE);
                ok = true;
            }
        }
        if (ok) {
            TOX_ERR_FRIEND_BY_PUBLIC_KEY err_find;
            uint32_t friend_num = tox_friend_by_public_key(tox, pubkey, &err_find);
            V2TIM_LOG(kInfo, "DeleteFromFriendList: Looking up friend %s, found friend_num=%u, err_find=%d", user_id_str.c_str(), friend_num, err_find);
            if (err_find == TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
                TOX_ERR_FRIEND_DELETE err_del;
                bool success = tox_friend_delete(tox, friend_num, &err_del);
                V2TIM_LOG(kInfo, "DeleteFromFriendList: tox_friend_delete returned success=%d, err_del=%d", success, err_del);
                if (success && err_del == TOX_ERR_FRIEND_DELETE_OK) {
                    result.resultCode = 0;
                    result.resultInfo = "Friend deleted successfully";
                    V2TIM_LOG(kInfo, "DeleteFromFriendList: Successfully deleted friend %s", user_id_str.c_str());
                } else {
                    result.resultCode = ERR_SDK_FRIEND_DELETE_FAILED;
                    result.resultInfo = "Failed to delete Tox friend";
                    V2TIM_LOG(kError, "DeleteFromFriendList: Failed to delete friend %s (num %u), success=%d, error: %d", user_id_str.c_str(), friend_num, success, err_del);
                }
            } else {
                 // Idempotent: if friend already not in Tox list (e.g. removed by DeleteConversation),
                 // treat as success so UI does not show "删除好友失败".
                 if (err_find == TOX_ERR_FRIEND_BY_PUBLIC_KEY_NOT_FOUND) {
                     result.resultCode = 0;
                     result.resultInfo = "Friend already removed";
                     V2TIM_LOG(kInfo, "DeleteFromFriendList: Friend %s already not in list (idempotent success)", user_id_str.c_str());
                 } else {
                     result.resultCode = ERR_SVR_FRIENDSHIP_INVALID;
                     result.resultInfo = "Friend not found";
                     V2TIM_LOG(kWarning, "DeleteFromFriendList: Friend %s not found (err_find=%d)", user_id_str.c_str(), err_find);
                 }
            }
        } else {
            result.resultCode = ERR_INVALID_PARAMETERS;
            result.resultInfo = "Invalid UserID format";
            V2TIM_LOG(kError, "DeleteFromFriendList: Invalid UserID format for %s (length=%zu)", user_id_str.c_str(), user_id_len);
        }
        results.PushBack(result);
    }
    
    // Notify listeners about deleted friends
    V2TIMStringVector deletedUserIDs;
    for (size_t i = 0; i < results.Size(); i++) {
        if (results[i].resultCode == 0) {
            deletedUserIDs.PushBack(results[i].userID);
        }
    }
    if (deletedUserIDs.Size() > 0) {
        V2TIM_LOG(kInfo, "DeleteFromFriendList: Notifying listeners about %zu deleted friend(s)", deletedUserIDs.Size());
        NotifyFriendListDeleted(deletedUserIDs);

        // Save Tox profile to disk immediately so the deletion persists
        if (manager_impl_) {
            manager_impl_->SaveToxProfile();
        }

        // Refresh conversation cache (without NotifyNewConversations) so deleted friends'
        // conversations are removed from cache. We must NOT call RefreshCache() because it
        // calls NotifyNewConversations() which fires OnNewConversation — Dart treats that as
        // "add if not present" and would re-add the just-deleted conversation.
        if (manager_impl_) {
            V2TIMConversationManager* cm = manager_impl_->GetConversationManager();
            if (cm) static_cast<V2TIMConversationManagerImpl*>(cm)->RefreshConversationCacheOnly();
        }
    } else {
        V2TIM_LOG(kWarning, "DeleteFromFriendList: No friends were successfully deleted");
    }

    V2TIM_LOG(kInfo, "DeleteFromFriendList: Returning results with %zu item(s), calling callback", results.Size());
    if (callback) callback->OnSuccess(results);
}

void V2TIMFriendshipManagerImpl::CheckFriend(const V2TIMStringVector& userIDList, V2TIMFriendType checkType, V2TIMValueCallback<V2TIMFriendCheckResultVector>* callback) { 
    V2TIM_LOG(kInfo, "CheckFriend called");
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }
    
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
    
    // Tox doesn't have a built-in concept of double-sided/mutual friends
    // Therefore, we can only properly support checkType=V2TIM_FRIEND_TYPE_SINGLE.
    if (checkType != V2TIM_FRIEND_TYPE_SINGLE) {
         V2TIM_LOG(kWarning, "CheckFriend: Only V2TIM_FRIEND_TYPE_SINGLE is reliably supported by Tox.");
    }

    V2TIMFriendCheckResultVector results;
    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    for (const auto& user_id_str : user_id_strings) {
        V2TIMFriendCheckResult result;
        // Create new V2TIMString directly from the safe std::string
        result.userID = V2TIMString(user_id_str.c_str());
        result.resultCode = 0; // Assume success in checking, relationType holds the result
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE] = {0};
        bool ok = false;
        const char* user_id_cstr = user_id_str.c_str();
        size_t user_id_len = user_id_str.length();
        if (user_id_len == TOX_PUBLIC_KEY_SIZE * 2) {
            ok = ToxUtil::tox_hex_to_bytes(user_id_cstr, user_id_len, pubkey, TOX_PUBLIC_KEY_SIZE);
        } else if (user_id_len == TOX_ADDRESS_SIZE * 2) {
            uint8_t address[TOX_ADDRESS_SIZE] = {0};
            if (ToxUtil::tox_hex_to_bytes(user_id_cstr, user_id_len, address, TOX_ADDRESS_SIZE)) {
                memcpy(pubkey, address, TOX_PUBLIC_KEY_SIZE);
                ok = true;
            }
        }
        if (ok) {
            TOX_ERR_FRIEND_BY_PUBLIC_KEY err_find;
            tox_friend_by_public_key(tox, pubkey, &err_find);
            if (err_find == TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
                // Is a friend
                result.relationType = V2TIM_FRIEND_RELATION_TYPE_BOTH_WAY;
            } else {
                // Not a friend
                result.relationType = V2TIM_FRIEND_RELATION_TYPE_NONE;
            }
        } else {
            result.resultCode = ERR_INVALID_PARAMETERS;
            result.relationType = V2TIM_FRIEND_RELATION_TYPE_NONE;
        }
        results.PushBack(result);
    }
    if (callback) callback->OnSuccess(results);
}

void V2TIMFriendshipManagerImpl::GetFriendApplicationList(V2TIMValueCallback<V2TIMFriendApplicationResult>* callback) {
    V2TIMFriendApplicationResult result;
    {
        std::lock_guard<std::mutex> lock(application_mutex_);
        result.applicationList = pending_applications_;
        result.unreadCount = static_cast<uint32_t>(pending_applications_.Size());
    }
    if (callback) callback->OnSuccess(result);
}

void V2TIMFriendshipManagerImpl::AcceptFriendApplication(const V2TIMFriendApplication& application, V2TIMFriendAcceptType acceptType, V2TIMValueCallback<V2TIMFriendOperationResult>* callback) {
    V2TIM_LOG(kInfo, "[AcceptFriendApplication] ENTRY - userID length={}, userID={}", application.userID.Length(), application.userID.CString());

    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "[AcceptFriendApplication] ToxManager not initialized");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    Tox* tox = tox_manager->getTox();
    V2TIMFriendOperationResult result;
    // Normalize userID to 64-char public key for consistent identification
    std::string accept_norm_uid(application.userID.CString());
    if (accept_norm_uid.length() > 64) {
        accept_norm_uid = accept_norm_uid.substr(0, 64);
    }
    result.userID = V2TIMString(accept_norm_uid.c_str());

    if (!tox) {
        V2TIM_LOG(kError, "[AcceptFriendApplication] Tox not initialized");
        result.resultCode = ERR_SDK_NOT_INITIALIZED;
        result.resultInfo = "Tox not initialized";
        if (callback) callback->OnSuccess(result);
        return;
    }
    
    uint8_t public_key[TOX_PUBLIC_KEY_SIZE];
    if (!tox_hex_to_bytes(application.userID.CString(), application.userID.Length(), public_key, TOX_PUBLIC_KEY_SIZE)) {
         V2TIM_LOG(kError, "[AcceptFriendApplication] Invalid UserID format");
         result.resultCode = ERR_INVALID_PARAMETERS;
         result.resultInfo = "Invalid UserID format";
         if (callback) callback->OnSuccess(result);
         return;
    }
        
    // NOTE: V2TIMFriendAcceptType is ignored, Tox just adds the friend back.
    if (acceptType != V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD) {
         V2TIM_LOG(kWarning, "AcceptFriendApplication: Only V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD behavior is supported.");
    }

    TOX_ERR_FRIEND_ADD err_add;
    V2TIM_LOG(kInfo, "[AcceptFriendApplication] Calling tox_friend_add_norequest with public_key (first 20)={}...", std::string(application.userID.CString()).substr(0, 20));
    tox_friend_add_norequest(tox, public_key, &err_add);
    V2TIM_LOG(kInfo, "[AcceptFriendApplication] tox_friend_add_norequest returned: err_add={} (0=OK, 4=SET_NEW_NOSPAM, 5=ALREADY_SENT)", err_add);

    if (err_add == TOX_ERR_FRIEND_ADD_OK) {
        result.resultCode = 0;
        result.resultInfo = "Friend added successfully";
        V2TIM_LOG(kInfo, "[AcceptFriendApplication] Success: Friend added");

        // Save Tox profile to disk so the accepted friend persists
        if (manager_impl_) manager_impl_->SaveToxProfile();

        // Notify OnFriendListAdded so UI can update
        // Normalize to 64-char public key (see AddFriend for explanation)
        V2TIMFriendInfo friendInfo;
        std::string accept_user_id(application.userID.CString());
        if (accept_user_id.length() > 64) {
            accept_user_id = accept_user_id.substr(0, 64);
        }
        friendInfo.userID = V2TIMString(accept_user_id.c_str());
        V2TIMFriendInfoVector friendList;
        friendList.PushBack(friendInfo);
        NotifyFriendListAdded(friendList);
        // Remove from pending and notify UI so "new application" badge/list is cleared (auto-accept case)
        V2TIMStringVector deleted_ids;
        deleted_ids.PushBack(application.userID);
        NotifyFriendApplicationListDeleted(deleted_ids);
        // OPTIMIZATION: Refresh conversation cache asynchronously without blocking
        // The debounce mechanism in RefreshConversationCache will prevent excessive refreshes
        // if multiple friend applications are accepted in quick succession
        if (refresh_after_accept_thread_.joinable()) {
            refresh_after_accept_thread_.join();
        }
        V2TIMManagerImpl* owner = manager_impl_;
        refresh_after_accept_thread_ = std::thread([owner]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            if (owner) {
                V2TIMConversationManager* cm = owner->GetConversationManager();
                if (cm) static_cast<V2TIMConversationManagerImpl*>(cm)->RefreshCache();
            }
        });
    } else {
        V2TIM_LOG(kInfo, "[AcceptFriendApplication] Error case: err_add={}", err_add);
        if (err_add == TOX_ERR_FRIEND_ADD_ALREADY_SENT || err_add == TOX_ERR_FRIEND_ADD_SET_NEW_NOSPAM) {
            result.resultCode = 0;
            result.resultInfo = "Friend already added";
            V2TIM_LOG(kInfo, "[AcceptFriendApplication] Treated as success: Friend already added (err: {})", err_add);
            
            // Still notify OnFriendListAdded to ensure UI is updated
            // Normalize to 64-char public key (see AddFriend for explanation)
            V2TIMFriendInfo friendInfo;
            std::string already_user_id(application.userID.CString());
            if (already_user_id.length() > 64) {
                already_user_id = already_user_id.substr(0, 64);
            }
            friendInfo.userID = V2TIMString(already_user_id.c_str());
            V2TIMFriendInfoVector friendList;
            friendList.PushBack(friendInfo);
            NotifyFriendListAdded(friendList);
            // Clear from pending so "new application" notification goes away
            V2TIMStringVector deleted_ids;
            deleted_ids.PushBack(application.userID);
            NotifyFriendApplicationListDeleted(deleted_ids);
        } else if (err_add == TOX_ERR_FRIEND_ADD_OWN_KEY) {
            result.resultCode = ERR_SDK_FRIEND_ADD_SELF;
            result.resultInfo = "Cannot add yourself as friend";
            V2TIM_LOG(kError, "[AcceptFriendApplication] Failed: Cannot add yourself (err: {})", err_add);
        } else {
            result.resultCode = ERR_SDK_FRIEND_ADD_FAILED;
            result.resultInfo = "Failed to add Tox friend";
            V2TIM_LOG(kError, "[AcceptFriendApplication] Failed: err_add={}, resultCode={}", err_add, result.resultCode);
        }
    }
    V2TIM_LOG(kInfo, "[AcceptFriendApplication] EXIT resultCode={}", result.resultCode);
    if (callback) callback->OnSuccess(result);
}
void V2TIMFriendshipManagerImpl::AcceptFriendApplication(const V2TIMFriendApplication& application, V2TIMFriendAcceptType acceptType, const V2TIMString& remark, V2TIMValueCallback<V2TIMFriendOperationResult>* callback) { 
    AcceptFriendApplication(application, acceptType, callback);
    if (!remark.Empty()) {
        V2TIM_LOG(kWarning, "AcceptFriendApplication with remark: Remarks are not supported by Tox.");
    }
}
void V2TIMFriendshipManagerImpl::RefuseFriendApplication(const V2TIMFriendApplication& application, V2TIMValueCallback<V2TIMFriendOperationResult>* callback) { 
    V2TIM_LOG(kInfo, "RefuseFriendApplication called");
    
    V2TIMFriendOperationResult result;
    result.resultCode = 0; // Success (ish)
    result.resultInfo = "Refusing not implemented, but not needed in Tox";
    // Normalize userID to 64-char public key
    std::string refuse_uid(application.userID.CString());
    if (refuse_uid.length() > 64) {
        refuse_uid = refuse_uid.substr(0, 64);
    }
    result.userID = V2TIMString(refuse_uid.c_str());
    
    V2TIM_LOG(kWarning, "RefuseFriendApplication: Tox doesn't support actively rejecting friend requests.");
    // Client-side dismissal still needs to clear the local pending queue so a
    // later request from the same peer can surface again. Without this the old
    // application stays in pending_applications_ forever, and higher layers may
    // keep filtering or reusing the stale entry instead of the fresh request.
    if (!application.userID.Empty()) {
        V2TIMStringVector deleted_ids;
        deleted_ids.PushBack(application.userID);
        NotifyFriendApplicationListDeleted(deleted_ids);
    }
    if (callback) callback->OnSuccess(result);
}
void V2TIMFriendshipManagerImpl::DeleteFriendApplication(const V2TIMFriendApplication& application, V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "DeleteFriendApplication called");
    
    V2TIM_LOG(kWarning, "DeleteFriendApplication: Friend application deletion is a client-side concept.");
    if (!application.userID.Empty()) {
        V2TIMStringVector deleted_ids;
        deleted_ids.PushBack(application.userID);
        NotifyFriendApplicationListDeleted(deleted_ids);
    }
    if (callback) callback->OnSuccess();
}
void V2TIMFriendshipManagerImpl::SetFriendApplicationRead(V2TIMCallback* callback) { 
    V2TIM_LOG(kInfo, "SetFriendApplicationRead called");
    {
        std::lock_guard<std::mutex> lock(application_mutex_);
        V2TIMFriendApplicationVector empty;
        pending_applications_ = empty;
    }
    if (callback) callback->OnSuccess();
}
void V2TIMFriendshipManagerImpl::AddToBlackList(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) {
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
    
    V2TIMFriendOperationResultVector resultVector;
    std::lock_guard<std::mutex> lock(mutex_);
    
    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    for (const auto& user_id_str : user_id_strings) {
        // Check if already in blacklist
        auto it = std::find(blacklist_.begin(), blacklist_.end(), user_id_str);
        if (it == blacklist_.end()) {
            blacklist_.push_back(user_id_str);
            V2TIM_LOG(kInfo, "AddToBlackList: Added {} to blacklist", user_id_str);
        }
        
        V2TIMFriendOperationResult result;
        // Create new V2TIMString directly from the safe std::string
        result.userID = V2TIMString(user_id_str.c_str());
        result.resultCode = 0;
        result.resultInfo = "Success";
        resultVector.PushBack(result);
    }
    
    // Notify listeners
    {
        std::lock_guard<std::mutex> listener_lock(listener_mutex_);
        V2TIMFriendInfoVector blackListInfo;
        // CRITICAL: Use the safe std::string copies to create V2TIMFriendInfo
        for (const auto& user_id_str : user_id_strings) {
            V2TIMFriendInfo info;
            // Create new V2TIMString directly from the safe std::string
            info.userID = V2TIMString(user_id_str.c_str());
            blackListInfo.PushBack(info);
        }
        for (auto* listener : listeners_) {
            if (listener) {
                listener->OnBlackListAdded(blackListInfo);
            }
        }
    }
    
    if (callback) callback->OnSuccess(resultVector);
}

void V2TIMFriendshipManagerImpl::DeleteFromBlackList(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) {
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
    
    V2TIMFriendOperationResultVector resultVector;
    std::lock_guard<std::mutex> lock(mutex_);
    
    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    for (const auto& user_id_str : user_id_strings) {
        auto it = std::find(blacklist_.begin(), blacklist_.end(), user_id_str);
        if (it != blacklist_.end()) {
            blacklist_.erase(it);
            V2TIM_LOG(kInfo, "DeleteFromBlackList: Removed %s from blacklist", user_id_str.c_str());
        }
        
        V2TIMFriendOperationResult result;
        // Create new V2TIMString directly from the safe std::string
        result.userID = V2TIMString(user_id_str.c_str());
        result.resultCode = 0;
        result.resultInfo = "Success";
        resultVector.PushBack(result);
    }
    
    // Notify listeners
    {
        std::lock_guard<std::mutex> listener_lock(listener_mutex_);
        // CRITICAL: Create V2TIMStringVector from safe std::string copies
        V2TIMStringVector safe_user_id_list;
        for (const auto& user_id_str : user_id_strings) {
            safe_user_id_list.PushBack(V2TIMString(user_id_str.c_str()));
        }
        for (auto* listener : listeners_) {
            if (listener) {
                listener->OnBlackListDeleted(safe_user_id_list);
            }
        }
    }
    
    if (callback) callback->OnSuccess(resultVector);
}

void V2TIMFriendshipManagerImpl::GetBlackList(V2TIMValueCallback<V2TIMFriendInfoVector>* callback) {
    V2TIMFriendInfoVector resultVector;
    std::lock_guard<std::mutex> lock(mutex_);
    
    for (const auto& userID : blacklist_) {
        V2TIMFriendInfo info;
        info.userID = V2TIMString(userID.c_str());
        resultVector.PushBack(info);
    }
    
    if (callback) callback->OnSuccess(resultVector);
}
void V2TIMFriendshipManagerImpl::CreateFriendGroup(const V2TIMString& groupName, const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) { 
    V2TIM_LOG(kInfo, "CreateFriendGroup called with name: %s", groupName.CString());
    
    // Tox doesn't support friend groups natively
    // We return success for the API but with a note that this is not supported
    V2TIMFriendOperationResultVector resultVector;
    
    for (size_t i = 0; i < userIDList.Size(); i++) {
        V2TIMFriendOperationResult result;
        result.userID = userIDList[i];
        result.resultCode = 0; // Success code
        result.resultInfo = "Friend groups not supported in Tox, but operation recorded";
        resultVector.PushBack(result);
    }
    
    if (callback) callback->OnSuccess(resultVector);
}
void V2TIMFriendshipManagerImpl::GetFriendGroups(const V2TIMStringVector& groupNameList, V2TIMValueCallback<V2TIMFriendGroupVector>* callback) { 
    V2TIM_LOG(kInfo, "GetFriendGroups called");
    
    // Tox doesn't support friend groups, so we return an empty list
    V2TIMFriendGroupVector groupVector;
    
    if (callback) callback->OnSuccess(groupVector);
}
void V2TIMFriendshipManagerImpl::DeleteFriendsFromFriendGroup(const V2TIMString& groupName, const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) {
    V2TIM_LOG(kInfo, "DeleteFriendsFromFriendGroup called with group %s and %zu users", groupName.CString(), userIDList.Size());
    
    // Tox doesn't support friend groups, but we'll return success with empty results
    V2TIMFriendOperationResultVector results;
    if (callback) {
        callback->OnSuccess(results);
    }
}

void V2TIMFriendshipManagerImpl::DeleteFriendGroup(const V2TIMStringVector& groupNameList, V2TIMCallback* callback) {
    V2TIM_LOG(kWarning, "DeleteFriendGroup ({} groups): Not supported in Tox", groupNameList.Size());
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::RenameFriendGroup(const V2TIMString& oldName, const V2TIMString& newName, V2TIMCallback* callback) {
    V2TIM_LOG(kWarning, "RenameFriendGroup: Not supported in Tox");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::AddFriendsToFriendGroup(const V2TIMString& groupName, const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMFriendOperationResultVector>* callback) {
    V2TIM_LOG(kWarning, "AddFriendsToFriendGroup: Not supported in Tox");
    ReportNotImplemented(callback);
}

// --- Official Account Management ---
void V2TIMFriendshipManagerImpl::SubscribeOfficialAccount(const V2TIMString& officialAccountID, V2TIMCallback* callback) {
    // V2TIM_LOG(kWarning, "SubscribeOfficialAccount: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::UnsubscribeOfficialAccount(const V2TIMString& officialAccountID, V2TIMCallback* callback) {
    // V2TIM_LOG(kWarning, "UnsubscribeOfficialAccount: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::GetOfficialAccountsInfo(const V2TIMStringVector& officialAccountIDList, 
                                                       V2TIMValueCallback<V2TIMOfficialAccountInfoResultVector>* callback) {
    // V2TIM_LOG(kWarning, "GetOfficialAccountsInfo: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

// --- Follow Management ---
void V2TIMFriendshipManagerImpl::FollowUser(const V2TIMStringVector& userIDList, 
                                          V2TIMValueCallback<V2TIMFollowOperationResultVector>* callback) {
    // V2TIM_LOG(kWarning, "FollowUser: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::UnfollowUser(const V2TIMStringVector& userIDList, 
                                            V2TIMValueCallback<V2TIMFollowOperationResultVector>* callback) {
    // V2TIM_LOG(kWarning, "UnfollowUser: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::GetMyFollowingList(const V2TIMString& nextCursor, 
                                                  V2TIMValueCallback<V2TIMUserInfoResult>* callback) {
    // V2TIM_LOG(kWarning, "GetMyFollowingList: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::GetMyFollowersList(const V2TIMString& nextCursor, 
                                                  V2TIMValueCallback<V2TIMUserInfoResult>* callback) {
    // V2TIM_LOG(kWarning, "GetMyFollowersList: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::GetMutualFollowersList(const V2TIMString& nextCursor, 
                                                      V2TIMValueCallback<V2TIMUserInfoResult>* callback) {
    // V2TIM_LOG(kWarning, "GetMutualFollowersList: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::GetUserFollowInfo(const V2TIMStringVector& userIDList, 
                                                 V2TIMValueCallback<V2TIMFollowInfoVector>* callback) {
    // V2TIM_LOG(kWarning, "GetUserFollowInfo: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}

void V2TIMFriendshipManagerImpl::CheckFollowType(const V2TIMStringVector& userIDList, 
                                               V2TIMValueCallback<V2TIMFollowTypeCheckResultVector>* callback) {
    // V2TIM_LOG(kWarning, "CheckFollowType: Not implemented in tim2tox.");
    ReportNotImplemented(callback);
}
