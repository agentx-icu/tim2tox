// Minimal shim to materialize vector/map wrappers and trivial ctors/dtors
// for V2TIM data types so the examples can link.

#include "V2TIMDataImpl.h"
#include "V2TIMDefine.h"
#include "V2TIMCommon.h"
#include "V2TIMMessage.h"
#include "V2TIMFriendship.h"
#include "V2TIMGroup.h"
#include "V2TIMConversation.h"
#include "V2TIMCommunity.h"
#include "V2TIMOfficialAccount.h"
#include "V2TIMListener.h"
#include "V2TIMCallback.h"
#include "V2TIMLog.h"

#include <vector>
#include <utility>
#include <cstdint> // For uintptr_t

// 0) Base classes and SDK config
V2TIMBaseObject::V2TIMBaseObject() = default;
V2TIMBaseObject::V2TIMBaseObject(const V2TIMBaseObject&) = default;
V2TIMBaseObject::~V2TIMBaseObject() = default;

V2TIMSDKConfig::V2TIMSDKConfig() = default;
V2TIMSDKConfig::V2TIMSDKConfig(const V2TIMSDKConfig&) = default;
V2TIMSDKConfig::~V2TIMSDKConfig() = default;

V2TIMSDKListener::V2TIMSDKListener() = default;
V2TIMSDKListener::~V2TIMSDKListener() = default;

V2TIMBaseCallback::V2TIMBaseCallback() = default;
V2TIMBaseCallback::~V2TIMBaseCallback() = default;

V2TIMSimpleMsgListener::V2TIMSimpleMsgListener() = default;
V2TIMSimpleMsgListener::~V2TIMSimpleMsgListener() = default;
V2TIMFriendshipListener::V2TIMFriendshipListener() = default;
V2TIMFriendshipListener::~V2TIMFriendshipListener() = default;
V2TIMSignalingListener::V2TIMSignalingListener() = default;
V2TIMSignalingListener::~V2TIMSignalingListener() = default;
V2TIMAdvancedMsgListener::V2TIMAdvancedMsgListener() = default;
V2TIMAdvancedMsgListener::~V2TIMAdvancedMsgListener() = default;
V2TIMGroupListener::V2TIMGroupListener() = default;
V2TIMGroupListener::~V2TIMGroupListener() = default;
V2TIMCommunityListener::V2TIMCommunityListener() = default;
V2TIMCommunityListener::~V2TIMCommunityListener() = default;
V2TIMConversationListener::V2TIMConversationListener() = default;
V2TIMConversationListener::~V2TIMConversationListener() = default;
V2TIMLogListener::V2TIMLogListener() = default;
V2TIMLogListener::~V2TIMLogListener() = default;

// 1) Implement vector wrappers for types declared via DEFINE_VECTOR(...)
#define SHIM_IMPL_VECTOR(class_name) \
class TX##class_name##VectorIMPL { \
public: \
    void PushBack(const class_name& obj) { data_.push_back(obj); } \
    void PopBack() { if (!data_.empty()) data_.pop_back(); } \
    class_name& operator[](size_t index) { \
        /* CRITICAL: Add bounds checking to prevent crashes */ \
        if (index >= data_.size()) { \
            static class_name dummy; \
            return dummy; \
        } \
        return data_[index]; \
    } \
    const class_name& operator[](size_t index) const { \
        /* CRITICAL: Add bounds checking to prevent crashes */ \
        if (index >= data_.size()) { \
            static class_name dummy; \
            return dummy; \
        } \
        return data_[index]; \
    } \
    size_t Size() const { return data_.size(); } \
    bool Empty() const { return data_.empty(); } \
    void Clear() { data_.clear(); } \
    void Erase(size_t index) { \
        /* CRITICAL: Add bounds checking to prevent crashes */ \
        if (index < data_.size()) { \
            data_.erase(data_.begin() + index); \
        } \
    } \
    TX##class_name##VectorIMPL() = default; \
    TX##class_name##VectorIMPL(const TX##class_name##VectorIMPL& other) : data_(other.data_) {} \
    TX##class_name##VectorIMPL& operator=(const TX##class_name##VectorIMPL& other) { \
        if (this != &other) data_ = other.data_; \
        return *this; \
    } \
private: \
    std::vector<class_name> data_; \
}; \
TX##class_name##Vector::TX##class_name##Vector() : impl_(new TX##class_name##VectorIMPL()) {} \
TX##class_name##Vector::TX##class_name##Vector(const TX##class_name##Vector& vect) { \
    /* Safely copy vect.impl_ with exception handling */ \
    if (vect.impl_) { \
        try { \
            impl_ = new TX##class_name##VectorIMPL(*vect.impl_); \
        } catch (const std::exception& e) { \
            V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - Copy constructor: Exception copying impl_: {}", e.what()); \
            impl_ = new TX##class_name##VectorIMPL(); /* Fallback to empty vector */ \
        } catch (...) { \
            V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - Copy constructor: Unknown exception copying impl_"); \
            impl_ = new TX##class_name##VectorIMPL(); /* Fallback to empty vector */ \
        } \
    } else { \
        impl_ = new TX##class_name##VectorIMPL(); \
    } \
} \
TX##class_name##Vector::~TX##class_name##Vector() { \
    if (impl_) { \
        try { \
            delete impl_; \
        } catch (const std::exception& e) { \
            V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - Destructor: Exception deleting impl_: {}", e.what()); \
        } catch (...) { \
            V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - Destructor: Unknown exception deleting impl_"); \
        } \
        impl_ = nullptr; \
    } \
} \
void TX##class_name##Vector::PushBack(class_name const& obj) { if (impl_) impl_->PushBack(obj); } \
void TX##class_name##Vector::PopBack() { \
    if (impl_) { \
        try { \
            impl_->PopBack(); \
        } catch (const std::exception& e) { \
            V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - PopBack: Exception: {}", e.what()); \
        } catch (...) { \
            V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - PopBack: Unknown exception"); \
        } \
    } \
} \
class_name& TX##class_name##Vector::operator[](size_t index) { \
    if (!impl_) { \
        impl_ = new TX##class_name##VectorIMPL(); \
    } \
    try { \
        return (*impl_)[index]; \
    } catch (const std::exception& e) { \
        V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - operator[]: Exception at index {}: {}", index, e.what()); \
        static class_name dummy; \
        return dummy; \
    } catch (...) { \
        V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - operator[]: Unknown exception at index {}", index); \
        static class_name dummy; \
        return dummy; \
    } \
} \
class_name const& TX##class_name##Vector::operator[](size_t index) const { \
    if (!impl_) { \
        const_cast<TX##class_name##Vector*>(this)->impl_ = new TX##class_name##VectorIMPL(); \
    } \
    try { \
        return (*impl_)[index]; \
    } catch (const std::exception& e) { \
        V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - operator[] const: Exception at index {}: {}", index, e.what()); \
        static class_name dummy; \
        return dummy; \
    } catch (...) { \
        V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - operator[] const: Unknown exception at index {}", index); \
        static class_name dummy; \
        return dummy; \
    } \
} \
TX##class_name##Vector& TX##class_name##Vector::operator=(const TX##class_name##Vector& vec) { \
    if (this != &vec) { \
        if (impl_ && vec.impl_) { \
            try { \
                *impl_ = *vec.impl_; \
            } catch (const std::exception& e) { \
                V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - operator=: Exception assigning impl_: {}", e.what()); \
            } catch (...) { \
                V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - operator=: Unknown exception assigning impl_"); \
            } \
        } else if (!impl_ && vec.impl_) { \
            try { \
                impl_ = new TX##class_name##VectorIMPL(*vec.impl_); \
            } catch (const std::exception& e) { \
                V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - operator=: Exception creating new impl_: {}", e.what()); \
                impl_ = new TX##class_name##VectorIMPL(); /* Fallback to empty vector */ \
            } catch (...) { \
                V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - operator=: Unknown exception creating new impl_"); \
                impl_ = new TX##class_name##VectorIMPL(); /* Fallback to empty vector */ \
            } \
        } \
    } \
    return *this; \
} \
size_t TX##class_name##Vector::Size() const { return impl_ ? impl_->Size() : 0; } \
bool TX##class_name##Vector::Empty() const { return impl_ ? impl_->Empty() : true; } \
void TX##class_name##Vector::Clear() { if (impl_) impl_->Clear(); } \
void TX##class_name##Vector::Erase(size_t index) { \
    if (impl_) { \
        try { \
            impl_->Erase(index); \
        } catch (const std::exception& e) { \
            V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - Erase: Exception at index {}: {}", index, e.what()); \
        } catch (...) { \
            V2TIM_LOG(kError, "[TXV2TIMVector] ERROR - Erase: Unknown exception at index {}", index); \
        } \
    } \
}

SHIM_IMPL_VECTOR(V2TIMUInt64)
SHIM_IMPL_VECTOR(V2TIMString)
SHIM_IMPL_VECTOR(V2TIMElemType)
SHIM_IMPL_VECTOR(V2TIMImage)
SHIM_IMPL_VECTOR(V2TIMMessage)
SHIM_IMPL_VECTOR(V2TIMMessageReceipt)
SHIM_IMPL_VECTOR(V2TIMMessageSearchResultItem)
SHIM_IMPL_VECTOR(V2TIMMessageExtension)
SHIM_IMPL_VECTOR(V2TIMMessageExtensionResult)
SHIM_IMPL_VECTOR(V2TIMMessageReaction)
SHIM_IMPL_VECTOR(V2TIMMessageReactionResult)
SHIM_IMPL_VECTOR(V2TIMMessageReactionChangeInfo)
SHIM_IMPL_VECTOR(V2TIMUserInfo)
SHIM_IMPL_VECTOR(V2TIMUserFullInfo)
SHIM_IMPL_VECTOR(V2TIMUserStatus)
SHIM_IMPL_VECTOR(V2TIMFriendInfo)
SHIM_IMPL_VECTOR(V2TIMFriendInfoResult)
SHIM_IMPL_VECTOR(V2TIMFriendApplication)
SHIM_IMPL_VECTOR(V2TIMFriendCheckResult)
SHIM_IMPL_VECTOR(V2TIMFriendOperationResult)
SHIM_IMPL_VECTOR(V2TIMFriendGroup)
SHIM_IMPL_VECTOR(V2TIMFollowOperationResult)
SHIM_IMPL_VECTOR(V2TIMFollowInfo)
SHIM_IMPL_VECTOR(V2TIMFollowTypeCheckResult)
SHIM_IMPL_VECTOR(V2TIMGroupMemberInfo)
SHIM_IMPL_VECTOR(V2TIMGroupMemberFullInfo)
SHIM_IMPL_VECTOR(V2TIMGroupChangeInfo)
SHIM_IMPL_VECTOR(V2TIMGroupMemberChangeInfo)
SHIM_IMPL_VECTOR(V2TIMGroupAtInfo)
SHIM_IMPL_VECTOR(V2TIMGroupInfo)
SHIM_IMPL_VECTOR(V2TIMGroupInfoResult)
SHIM_IMPL_VECTOR(V2TIMGroupApplication)
SHIM_IMPL_VECTOR(V2TIMGroupMemberOperationResult)
SHIM_IMPL_VECTOR(V2TIMCreateGroupMemberInfo)
SHIM_IMPL_VECTOR(V2TIMConversation)
SHIM_IMPL_VECTOR(V2TIMConversationOperationResult)
SHIM_IMPL_VECTOR(V2TIMOfficialAccountInfoResult)
SHIM_IMPL_VECTOR(V2TIMReceiveMessageOptInfo)

// Community (topic/permission group) vector wrappers
SHIM_IMPL_VECTOR(V2TIMTopicOperationResult)
SHIM_IMPL_VECTOR(V2TIMTopicInfoResult)
SHIM_IMPL_VECTOR(V2TIMTopicPermissionResult)
SHIM_IMPL_VECTOR(V2TIMPermissionGroupInfoResult)
SHIM_IMPL_VECTOR(V2TIMPermissionGroupMemberOperationResult)
SHIM_IMPL_VECTOR(V2TIMPermissionGroupOperationResult)

// 2) Implement pointer vector wrapper for V2TIMElem declared via DEFINE_POINT_VECTOR
class TXPV2TIMElemVectorIMPL {
public:
    void PushBack(V2TIMElem* const& obj) { data_.push_back(obj); }
    void PopBack() { if (!data_.empty()) data_.pop_back(); }
    V2TIMElem*& operator[](size_t index) {
        /* CRITICAL: Add bounds checking to prevent crashes */
        if (index >= data_.size()) {
            V2TIM_LOG(kError, "[TXPV2TIMElemVectorIMPL] ERROR - operator[]: index {} >= size {}", index, data_.size());
            static V2TIMElem* dummy = nullptr;
            return dummy;
        }
        return data_[index];
    }
    V2TIMElem* const& operator[](size_t index) const {
        /* CRITICAL: Add bounds checking to prevent crashes */
        if (index >= data_.size()) {
            V2TIM_LOG(kError, "[TXPV2TIMElemVectorIMPL] ERROR - operator[] const: index {} >= size {}", index, data_.size());
            static V2TIMElem* dummy = nullptr;
            return dummy;
        }
        return data_[index];
    }
    TXPV2TIMElemVectorIMPL() = default;
    TXPV2TIMElemVectorIMPL(const TXPV2TIMElemVectorIMPL& other) : data_(other.data_) {}
    TXPV2TIMElemVectorIMPL(TXPV2TIMElemVectorIMPL&& other) noexcept : data_(std::move(other.data_)) {}
    TXPV2TIMElemVectorIMPL& operator=(const TXPV2TIMElemVectorIMPL& other) {
        if (this != &other) data_ = other.data_;
        return *this;
    }
    TXPV2TIMElemVectorIMPL& operator=(TXPV2TIMElemVectorIMPL&& other) noexcept {
        if (this != &other) data_ = std::move(other.data_);
        return *this;
    }
    size_t Size() const { return data_.size(); }
    bool Empty() const { return data_.empty(); }
    void Clear() { data_.clear(); }
    void Erase(size_t index) {
        /* CRITICAL: Add bounds checking to prevent crashes */
        if (index < data_.size()) {
            data_.erase(data_.begin() + index);
        } else {
            V2TIM_LOG(kError, "[TXPV2TIMElemVectorIMPL] ERROR - Erase: index {} >= size {}", index, data_.size());
        }
    }
private:
    std::vector<V2TIMElem*> data_;
};

TXPV2TIMElemVector::TXPV2TIMElemVector() : impl_(new TXPV2TIMElemVectorIMPL()) {}
TXPV2TIMElemVector::TXPV2TIMElemVector(const TXPV2TIMElemVector& vect) {
    if (vect.impl_) {
        try {
            impl_ = new TXPV2TIMElemVectorIMPL(*vect.impl_);
        } catch (...) {
            V2TIM_LOG(kError, "[TXPV2TIMElemVector] ERROR - Copy constructor: Exception");
            impl_ = new TXPV2TIMElemVectorIMPL();
        }
    } else {
        impl_ = new TXPV2TIMElemVectorIMPL();
    }
}
TXPV2TIMElemVector::~TXPV2TIMElemVector() {
    if (impl_) {
        try {
            delete impl_;
        } catch (...) {
            V2TIM_LOG(kError, "[TXPV2TIMElemVector] ERROR - Destructor: Exception");
        }
        impl_ = nullptr;
    }
}
void TXPV2TIMElemVector::PushBack(V2TIMElem* const& obj) { if (impl_) impl_->PushBack(obj); }
void TXPV2TIMElemVector::PopBack() {
    if (impl_) {
        try {
            impl_->PopBack();
        } catch (...) {
            V2TIM_LOG(kError, "[TXPV2TIMElemVector] ERROR - PopBack: Exception");
        }
    }
}
V2TIMElem*& TXPV2TIMElemVector::operator[](size_t index) {
    if (!impl_) { impl_ = new TXPV2TIMElemVectorIMPL(); }
    try {
        return (*impl_)[index];
    } catch (...) {
        V2TIM_LOG(kError, "[TXPV2TIMElemVector] ERROR - operator[]: Exception at index {}", index);
        static V2TIMElem* dummy = nullptr;
        return dummy;
    }
}
V2TIMElem* const& TXPV2TIMElemVector::operator[](size_t index) const {
    if (!impl_) { const_cast<TXPV2TIMElemVector*>(this)->impl_ = new TXPV2TIMElemVectorIMPL(); }
    try {
        return (*impl_)[index];
    } catch (...) {
        V2TIM_LOG(kError, "[TXPV2TIMElemVector] ERROR - operator[] const: Exception at index {}", index);
        static V2TIMElem* dummy = nullptr;
        return dummy;
    }
}
TXPV2TIMElemVector& TXPV2TIMElemVector::operator=(const TXPV2TIMElemVector& vec) {
    if (this != &vec) {
        if (impl_ && vec.impl_) {
            *impl_ = *vec.impl_;
        } else if (!impl_ && vec.impl_) {
            impl_ = new TXPV2TIMElemVectorIMPL(*vec.impl_);
        }
    }
    return *this;
}
size_t TXPV2TIMElemVector::Size() const { return impl_ ? impl_->Size() : 0; }
bool TXPV2TIMElemVector::Empty() const { return impl_ ? impl_->Empty() : true; }
void TXPV2TIMElemVector::Clear() { if (impl_) impl_->Clear(); }
void TXPV2TIMElemVector::Erase(size_t index) {
    if (impl_) {
        try {
            impl_->Erase(index);
        } catch (...) {
            V2TIM_LOG(kError, "[TXPV2TIMElemVector] ERROR - Erase: Exception at index {}", index);
        }
    }
}

// 3) Implement a minimal map wrapper used in friendship (String -> Buffer)
class TXV2TIMStringToV2TIMBufferMapIMPL {
public:
    bool Insert(const V2TIMString& k, const V2TIMBuffer& v) {
        for (auto& kv : items_) {
            if (kv.first == k) { kv.second = v; return true; }
        }
        items_.emplace_back(k, v);
        return true;
    }
    void Erase(const V2TIMString& k) {
        for (size_t i = 0; i < items_.size(); ++i) {
            if (items_[i].first == k) { items_.erase(items_.begin() + i); return; }
        }
    }
    size_t Count(const V2TIMString& k) const {
        for (const auto& kv : items_) if (kv.first == k) return 1;
        return 0;
    }
    size_t Size() const { return items_.size(); }
    V2TIMBuffer Get(const V2TIMString& k) const {
        for (const auto& kv : items_) if (kv.first == k) return kv.second;
        return V2TIMBuffer();
    }
    V2TIMBuffer& operator[](const V2TIMString& k) {
        for (auto& kv : items_) if (kv.first == k) return kv.second;
        items_.emplace_back(k, V2TIMBuffer());
        return items_.back().second;
    }
    TXV2TIMStringVector AllKeys() const {
        TXV2TIMStringVector keys;
        for (const auto& kv : items_) keys.PushBack(kv.first);
        return keys;
    }
    TXV2TIMStringToV2TIMBufferMapIMPL() = default;
    TXV2TIMStringToV2TIMBufferMapIMPL(const TXV2TIMStringToV2TIMBufferMapIMPL& other) : items_(other.items_) {}
    TXV2TIMStringToV2TIMBufferMapIMPL& operator=(const TXV2TIMStringToV2TIMBufferMapIMPL& other) {
        if (this != &other) items_ = other.items_;
        return *this;
    }
private:
    std::vector<std::pair<V2TIMString, V2TIMBuffer>> items_;
};

TXV2TIMStringToV2TIMBufferMap::TXV2TIMStringToV2TIMBufferMap() : impl_(new TXV2TIMStringToV2TIMBufferMapIMPL()) {}
TXV2TIMStringToV2TIMBufferMap::TXV2TIMStringToV2TIMBufferMap(const TXV2TIMStringToV2TIMBufferMap& map)
    : impl_(map.impl_ ? new TXV2TIMStringToV2TIMBufferMapIMPL(*map.impl_) : new TXV2TIMStringToV2TIMBufferMapIMPL()) {}
TXV2TIMStringToV2TIMBufferMap::~TXV2TIMStringToV2TIMBufferMap() { if (impl_) { try { delete impl_; } catch (...) { } impl_ = nullptr; } }
bool TXV2TIMStringToV2TIMBufferMap::Insert(const V2TIMString& key, const V2TIMBuffer& value) { if (!impl_) impl_ = new TXV2TIMStringToV2TIMBufferMapIMPL(); return impl_->Insert(key, value); }
void TXV2TIMStringToV2TIMBufferMap::Erase(const V2TIMString& key) { if (impl_) impl_->Erase(key); }
size_t TXV2TIMStringToV2TIMBufferMap::Count(const V2TIMString& key) const { return impl_ ? impl_->Count(key) : 0; }
size_t TXV2TIMStringToV2TIMBufferMap::Size() const { return impl_ ? impl_->Size() : 0; }
V2TIMBuffer TXV2TIMStringToV2TIMBufferMap::Get(const V2TIMString& key) const { return impl_ ? impl_->Get(key) : V2TIMBuffer(); }
V2TIMBuffer& TXV2TIMStringToV2TIMBufferMap::operator[](const V2TIMString& key) { if (!impl_) impl_ = new TXV2TIMStringToV2TIMBufferMapIMPL(); return (*impl_)[key]; }
const V2TIMStringVector TXV2TIMStringToV2TIMBufferMap::AllKeys() const { return impl_ ? impl_->AllKeys() : V2TIMStringVector(); }
TXV2TIMStringToV2TIMBufferMap& TXV2TIMStringToV2TIMBufferMap::operator=(const TXV2TIMStringToV2TIMBufferMap& map) {
    if (this != &map) {
        if (impl_ && map.impl_) {
            *impl_ = *map.impl_;
        } else if (!impl_ && map.impl_) {
            impl_ = new TXV2TIMStringToV2TIMBufferMapIMPL(*map.impl_);
        }
    }
    return *this;
}

// 3) Implement minimal map wrapper (String -> String)
// Used by group/topic attribute handlers in community-related code paths.
class TXV2TIMStringToV2TIMStringMapIMPL {
public:
    bool Insert(const V2TIMString& k, const V2TIMString& v) {
        for (auto& kv : items_) {
            if (kv.first == k) { kv.second = v; return true; }
        }
        items_.emplace_back(k, v);
        return true;
    }

    void Erase(const V2TIMString& k) {
        for (size_t i = 0; i < items_.size(); ++i) {
            if (items_[i].first == k) { items_.erase(items_.begin() + i); return; }
        }
    }

    size_t Count(const V2TIMString& k) const {
        for (const auto& kv : items_) if (kv.first == k) return 1;
        return 0;
    }

    size_t Size() const { return items_.size(); }

    V2TIMString Get(const V2TIMString& k) const {
        for (const auto& kv : items_) if (kv.first == k) return kv.second;
        return V2TIMString();
    }

    V2TIMString& operator[](const V2TIMString& k) {
        for (auto& kv : items_) if (kv.first == k) return kv.second;
        items_.emplace_back(k, V2TIMString());
        return items_.back().second;
    }

    TXV2TIMStringVector AllKeys() const {
        TXV2TIMStringVector keys;
        for (const auto& kv : items_) keys.PushBack(kv.first);
        return keys;
    }

    TXV2TIMStringToV2TIMStringMapIMPL() = default;
    TXV2TIMStringToV2TIMStringMapIMPL(const TXV2TIMStringToV2TIMStringMapIMPL& other) : items_(other.items_) {}
    TXV2TIMStringToV2TIMStringMapIMPL& operator=(const TXV2TIMStringToV2TIMStringMapIMPL& other) {
        if (this != &other) items_ = other.items_;
        return *this;
    }

private:
    std::vector<std::pair<V2TIMString, V2TIMString>> items_;
};

TXV2TIMStringToV2TIMStringMap::TXV2TIMStringToV2TIMStringMap()
    : impl_(new TXV2TIMStringToV2TIMStringMapIMPL()) {}

TXV2TIMStringToV2TIMStringMap::TXV2TIMStringToV2TIMStringMap(const TXV2TIMStringToV2TIMStringMap& map)
    : impl_(map.impl_ ? new TXV2TIMStringToV2TIMStringMapIMPL(*map.impl_)
                       : new TXV2TIMStringToV2TIMStringMapIMPL()) {}

TXV2TIMStringToV2TIMStringMap::~TXV2TIMStringToV2TIMStringMap() {
    if (impl_) {
        try { delete impl_; } catch (...) {}
        impl_ = nullptr;
    }
}

bool TXV2TIMStringToV2TIMStringMap::Insert(const V2TIMString& key, const V2TIMString& value) {
    if (!impl_) impl_ = new TXV2TIMStringToV2TIMStringMapIMPL();
    return impl_->Insert(key, value);
}

void TXV2TIMStringToV2TIMStringMap::Erase(const V2TIMString& key) {
    if (impl_) impl_->Erase(key);
}

size_t TXV2TIMStringToV2TIMStringMap::Count(const V2TIMString& key) const {
    return impl_ ? impl_->Count(key) : 0;
}

size_t TXV2TIMStringToV2TIMStringMap::Size() const {
    return impl_ ? impl_->Size() : 0;
}

V2TIMString TXV2TIMStringToV2TIMStringMap::Get(const V2TIMString& key) const {
    return impl_ ? impl_->Get(key) : V2TIMString();
}

V2TIMString& TXV2TIMStringToV2TIMStringMap::operator[](const V2TIMString& key) {
    if (!impl_) impl_ = new TXV2TIMStringToV2TIMStringMapIMPL();
    return (*impl_)[key];
}

const V2TIMStringVector TXV2TIMStringToV2TIMStringMap::AllKeys() const {
    return impl_ ? impl_->AllKeys() : V2TIMStringVector();
}

TXV2TIMStringToV2TIMStringMap& TXV2TIMStringToV2TIMStringMap::operator=(const TXV2TIMStringToV2TIMStringMap& map) {
    if (this != &map) {
        if (impl_ && map.impl_) {
            *impl_ = *map.impl_;
        } else if (!impl_ && map.impl_) {
            impl_ = new TXV2TIMStringToV2TIMStringMapIMPL(*map.impl_);
        }
    }
    return *this;
}

// 3.x) Implement minimal map wrapper (String -> GroupMemberFullInfoVector)
class TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL {
public:
    bool Insert(const V2TIMString& k, const V2TIMGroupMemberFullInfoVector& v) {
        for (auto& kv : items_) {
            if (kv.first == k) { kv.second = v; return true; }
        }
        items_.emplace_back(k, v);
        return true;
    }

    void Erase(const V2TIMString& k) {
        for (size_t i = 0; i < items_.size(); ++i) {
            if (items_[i].first == k) { items_.erase(items_.begin() + i); return; }
        }
    }

    size_t Count(const V2TIMString& k) const {
        for (const auto& kv : items_) if (kv.first == k) return 1;
        return 0;
    }

    size_t Size() const { return items_.size(); }

    V2TIMGroupMemberFullInfoVector Get(const V2TIMString& k) const {
        for (const auto& kv : items_) if (kv.first == k) return kv.second;
        return V2TIMGroupMemberFullInfoVector();
    }

    V2TIMGroupMemberFullInfoVector& operator[](const V2TIMString& k) {
        for (auto& kv : items_) if (kv.first == k) return kv.second;
        items_.emplace_back(k, V2TIMGroupMemberFullInfoVector());
        return items_.back().second;
    }

    TXV2TIMStringVector AllKeys() const {
        TXV2TIMStringVector keys;
        for (const auto& kv : items_) keys.PushBack(kv.first);
        return keys;
    }

    TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL() = default;
    TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL(const TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL& other)
        : items_(other.items_) {}

    TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL& operator=(const TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL& other) {
        if (this != &other) items_ = other.items_;
        return *this;
    }

private:
    std::vector<std::pair<V2TIMString, V2TIMGroupMemberFullInfoVector>> items_;
};

TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap()
    : impl_(new TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL()) {}

TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap(
    const TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap& map)
    : impl_(map.impl_ ? new TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL(*map.impl_)
                       : new TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL()) {}

TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::~TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap() {
    if (impl_) {
        try { delete impl_; } catch (...) {}
        impl_ = nullptr;
    }
}

bool TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::Insert(
    const V2TIMString& key, const V2TIMGroupMemberFullInfoVector& value) {
    if (!impl_) impl_ = new TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL();
    return impl_->Insert(key, value);
}

void TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::Erase(const V2TIMString& key) {
    if (impl_) impl_->Erase(key);
}

size_t TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::Count(const V2TIMString& key) const {
    return impl_ ? impl_->Count(key) : 0;
}

size_t TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::Size() const {
    return impl_ ? impl_->Size() : 0;
}

V2TIMGroupMemberFullInfoVector TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::Get(const V2TIMString& key) const {
    return impl_ ? impl_->Get(key) : V2TIMGroupMemberFullInfoVector();
}

V2TIMGroupMemberFullInfoVector& TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::operator[](const V2TIMString& key) {
    if (!impl_) impl_ = new TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL();
    return (*impl_)[key];
}

const V2TIMStringVector TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::AllKeys() const {
    return impl_ ? impl_->AllKeys() : V2TIMStringVector();
}

TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap&
TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap::operator=(const TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMap& map) {
    if (this != &map) {
        if (impl_ && map.impl_) {
            *impl_ = *map.impl_;
        } else if (!impl_ && map.impl_) {
            impl_ = new TXV2TIMStringToV2TIMGroupMemberFullInfoVectorMapIMPL(*map.impl_);
        }
    }
    return *this;
}

// 4) Trivial out-of-line definitions for various V2TIM types
#define DEF_EMPTY_CTORS(type) \
    type::type() = default; \
    type::type(const type&) = default; \
    type::~type() = default;

#define DEF_EMPTY_CTORS_BASE(type) \
    type::type() = default; \
    type::type(const type&) = default; \
    type::~type() = default;

// Friendship-related
DEF_EMPTY_CTORS(V2TIMUserInfo)
DEF_EMPTY_CTORS_BASE(V2TIMUserFullInfo)
DEF_EMPTY_CTORS(V2TIMUserSearchParam)
DEF_EMPTY_CTORS(V2TIMUserSearchResult)
DEF_EMPTY_CTORS(V2TIMUserStatus)
// CRITICAL: V2TIMFriendInfo and V2TIMFriendInfoResult contain V2TIMString members
// which need proper initialization. Default constructors may not initialize them correctly.
// We need explicit constructors to ensure all V2TIMString members are properly initialized.
V2TIMFriendInfo::V2TIMFriendInfo() {
    // CRITICAL: Explicitly initialize all V2TIMString members to ensure they're valid
    // Default constructor may leave them in an invalid state
    try {
        userID = V2TIMString("");
        friendRemark = V2TIMString("");
        friendAddTime = 0;
        modifyFlag = 0;
        // friendGroups and friendCustomInfo are vectors, they initialize themselves
        // userFullInfo is a struct, it initializes itself
    } catch (...) {
        V2TIM_LOG(kError, "[V2TIMDataShim] ERROR - V2TIMFriendInfo::V2TIMFriendInfo(): Exception initializing members");
    }
}
V2TIMFriendInfo::V2TIMFriendInfo(const V2TIMFriendInfo& friendInfo) {
    // CRITICAL: Safely copy all members with exception handling
    try {
        userID = friendInfo.userID;
        friendRemark = friendInfo.friendRemark;
        friendAddTime = friendInfo.friendAddTime;
        friendCustomInfo = friendInfo.friendCustomInfo;
        friendGroups = friendInfo.friendGroups;
        userFullInfo = friendInfo.userFullInfo;
        modifyFlag = friendInfo.modifyFlag;
    } catch (const std::exception& e) {
        // Initialize to safe defaults
        userID = V2TIMString("");
        friendRemark = V2TIMString("");
        friendAddTime = 0;
        modifyFlag = 0;
    } catch (...) {
        // Initialize to safe defaults
        userID = V2TIMString("");
        friendRemark = V2TIMString("");
        friendAddTime = 0;
        modifyFlag = 0;
    }
}
V2TIMFriendInfo::~V2TIMFriendInfo() {
    // CRITICAL: Destructor should safely destroy all members
    // V2TIMString destructors have try-catch protection, but we add extra safety here
    try {
        // Explicitly clear V2TIMString members to ensure safe destruction
        userID = V2TIMString("");
        friendRemark = V2TIMString("");
    } catch (...) {
        // Silently handle exceptions during destruction
    }
    // Vectors and other members will be destroyed automatically
}

V2TIMFriendInfoResult::V2TIMFriendInfoResult() {
    // CRITICAL: Explicitly initialize all V2TIMString members
    try {
        resultCode = 0;
        resultInfo = V2TIMString("");
        relation = V2TIM_FRIEND_RELATION_TYPE_NONE;
        // friendInfo is a struct, it will use its own constructor
    } catch (...) {
        resultCode = 0;
        relation = V2TIM_FRIEND_RELATION_TYPE_NONE;
    }
}
V2TIMFriendInfoResult::V2TIMFriendInfoResult(const V2TIMFriendInfoResult& friendInfoResult) {
    // CRITICAL: Safely copy all members with exception handling
    try {
        resultCode = friendInfoResult.resultCode;
        resultInfo = friendInfoResult.resultInfo;
        relation = friendInfoResult.relation;
        friendInfo = friendInfoResult.friendInfo;
    } catch (const std::exception& e) {
        // Initialize to safe defaults
        resultCode = 0;
        resultInfo = V2TIMString("");
        relation = V2TIM_FRIEND_RELATION_TYPE_NONE;
    } catch (...) {
        // Initialize to safe defaults
        resultCode = 0;
        resultInfo = V2TIMString("");
        relation = V2TIM_FRIEND_RELATION_TYPE_NONE;
    }
}
V2TIMFriendInfoResult::~V2TIMFriendInfoResult() {
    // CRITICAL: Destructor should safely destroy all members
    try {
        // Explicitly clear V2TIMString members
        resultInfo = V2TIMString("");
    } catch (...) {
    }
    // friendInfo will be destroyed automatically
}
DEF_EMPTY_CTORS(V2TIMFriendAddApplication)
DEF_EMPTY_CTORS(V2TIMFriendApplication)
DEF_EMPTY_CTORS(V2TIMFriendApplicationResult)
DEF_EMPTY_CTORS(V2TIMFriendCheckResult)
DEF_EMPTY_CTORS(V2TIMFriendOperationResult)
DEF_EMPTY_CTORS(V2TIMFriendGroup)
DEF_EMPTY_CTORS(V2TIMFriendSearchParam)
DEF_EMPTY_CTORS(V2TIMUserInfoResult)
DEF_EMPTY_CTORS(V2TIMFollowOperationResult)
DEF_EMPTY_CTORS(V2TIMFollowTypeCheckResult)
DEF_EMPTY_CTORS(V2TIMFollowInfo)

// Message-related
DEF_EMPTY_CTORS(V2TIMOfflinePushConfig)
DEF_EMPTY_CTORS(V2TIMOfflinePushInfo)
V2TIMMessage::V2TIMMessage() = default;
V2TIMMessage::V2TIMMessage(const V2TIMMessage&) = default;
V2TIMMessage& V2TIMMessage::operator=(const V2TIMMessage&) = default;
V2TIMMessage::~V2TIMMessage() = default;
// Tox only exposes delivery receipts. Read state is authoritative on the Dart
// side in MessageHistoryPersistence, so these remain ABI shims for the V2TIM
// surface.
bool V2TIMMessage::IsRead() const { return false; }
bool V2TIMMessage::IsPeerRead() const { return false; }
V2TIMElem::V2TIMElem() = default;
V2TIMElem::V2TIMElem(const V2TIMElem&) = default;
V2TIMElem::~V2TIMElem() = default;
DEF_EMPTY_CTORS(V2TIMTextElem)
DEF_EMPTY_CTORS(V2TIMCustomElem)
DEF_EMPTY_CTORS(V2TIMImage)
DEF_EMPTY_CTORS(V2TIMImageElem)
DEF_EMPTY_CTORS(V2TIMSoundElem)
DEF_EMPTY_CTORS(V2TIMVideoElem)
DEF_EMPTY_CTORS(V2TIMFileElem)
DEF_EMPTY_CTORS(V2TIMLocationElem)
DEF_EMPTY_CTORS(V2TIMFaceElem)
DEF_EMPTY_CTORS(V2TIMMergerElem)
DEF_EMPTY_CTORS(V2TIMGroupTipsElem)
DEF_EMPTY_CTORS(V2TIMMessageReceipt)
DEF_EMPTY_CTORS(V2TIMGroupMessageReadMemberList)
DEF_EMPTY_CTORS(V2TIMReceiveMessageOptInfo)
DEF_EMPTY_CTORS(V2TIMMessageSearchParam)
V2TIMMessageSearchParam& V2TIMMessageSearchParam::operator=(const V2TIMMessageSearchParam&) = default;
DEF_EMPTY_CTORS(V2TIMMessageSearchResultItem)
DEF_EMPTY_CTORS(V2TIMMessageSearchResult)
DEF_EMPTY_CTORS(V2TIMMessageExtension)
DEF_EMPTY_CTORS(V2TIMMessageExtensionResult)
V2TIMMessageExtensionResult& V2TIMMessageExtensionResult::operator=(const V2TIMMessageExtensionResult&) = default;
DEF_EMPTY_CTORS(V2TIMMessageReaction)
DEF_EMPTY_CTORS(V2TIMMessageReactionResult)
DEF_EMPTY_CTORS(V2TIMMessageReactionUserResult)
DEF_EMPTY_CTORS(V2TIMMessageReactionChangeInfo)
// Provide explicit operator= where needed by std::vector internals
V2TIMMessageReaction& V2TIMMessageReaction::operator=(const V2TIMMessageReaction&) = default;
V2TIMMessageReactionResult& V2TIMMessageReactionResult::operator=(const V2TIMMessageReactionResult&) = default;
V2TIMMessageReactionChangeInfo& V2TIMMessageReactionChangeInfo::operator=(const V2TIMMessageReactionChangeInfo&) = default;
V2TIMMessageExtension& V2TIMMessageExtension::operator=(const V2TIMMessageExtension&) = default;

// Group-related
DEF_EMPTY_CTORS(V2TIMGroupMemberInfo)
DEF_EMPTY_CTORS(V2TIMGroupMemberFullInfo)
DEF_EMPTY_CTORS(V2TIMGroupChangeInfo)
DEF_EMPTY_CTORS(V2TIMGroupMemberChangeInfo)
DEF_EMPTY_CTORS(V2TIMGroupAtInfo)
V2TIMGroupAtInfo& V2TIMGroupAtInfo::operator=(const V2TIMGroupAtInfo&) = default;
DEF_EMPTY_CTORS(V2TIMGroupInfo)
DEF_EMPTY_CTORS(V2TIMGroupInfoResult)
DEF_EMPTY_CTORS(V2TIMGroupApplication)
V2TIMGroupApplication& V2TIMGroupApplication::operator=(const V2TIMGroupApplication&) = default;
DEF_EMPTY_CTORS(V2TIMGroupMemberOperationResult)
DEF_EMPTY_CTORS(V2TIMCreateGroupMemberInfo)
DEF_EMPTY_CTORS(V2TIMGroupMemberInfoResult)
DEF_EMPTY_CTORS(V2TIMGroupSearchParam)
DEF_EMPTY_CTORS(V2TIMGroupSearchResult)

// Conversation-related
DEF_EMPTY_CTORS(V2TIMConversation)
V2TIMConversation& V2TIMConversation::operator=(const V2TIMConversation&) = default;
DEF_EMPTY_CTORS(V2TIMConversationOperationResult)
V2TIMConversationOperationResult& V2TIMConversationOperationResult::operator=(const V2TIMConversationOperationResult&) = default;

// Conversation filter used by listener callbacks
DEF_EMPTY_CTORS(V2TIMConversationListFilter)
V2TIMConversationListFilter& V2TIMConversationListFilter::operator=(const V2TIMConversationListFilter& filter) = default;
// V2TIMConversationResult needs explicit constructor to ensure conversationList is initialized
V2TIMConversationResult::V2TIMConversationResult() : nextSeq(0), isFinished(false), conversationList() {}
V2TIMConversationResult::V2TIMConversationResult(const V2TIMConversationResult& other) 
    : nextSeq(other.nextSeq), isFinished(other.isFinished), conversationList(other.conversationList) {}
V2TIMConversationResult& V2TIMConversationResult::operator=(const V2TIMConversationResult& other) {
    if (this != &other) {
        nextSeq = other.nextSeq;
        isFinished = other.isFinished;
        conversationList = other.conversationList;
    }
    return *this;
}
V2TIMConversationResult::~V2TIMConversationResult() = default;

// Official account related
DEF_EMPTY_CTORS(V2TIMOfficialAccountInfoResult)
DEF_EMPTY_CTORS(V2TIMOfficialAccountInfo)

// CRITICAL: V2TIMMessageListGetOption needs explicit destructor to safely handle V2TIMString and vector members
// Default destructor may crash if impl_ pointers are corrupted
V2TIMMessageListGetOption::V2TIMMessageListGetOption() = default;
V2TIMMessageListGetOption::V2TIMMessageListGetOption(const V2TIMMessageListGetOption& other) = default;
V2TIMMessageListGetOption& V2TIMMessageListGetOption::operator=(const V2TIMMessageListGetOption& other) = default;
V2TIMMessageListGetOption::~V2TIMMessageListGetOption() {
    // CRITICAL: Explicit destructor to safely destroy members even if they're corrupted
    // The destructor will be called in reverse order of member declaration:
    // 1. messageSeqList (V2TIMUInt64Vector)
    // 2. messageTypeList (V2TIMElemTypeVector)
    // 3. groupID (V2TIMString)
    // 4. userID (V2TIMString)
    // 5. lastMsg (V2TIMMessage*)
    //
    // Each member's destructor has try-catch protection, but we add an extra layer here
    // to ensure the destructor completes even if one member fails
    
    // Ensure pointer is nullptr (should already be, but be safe)
    lastMsg = nullptr;
    
    // Vectors and V2TIMString destructors will be called automatically
    // They have try-catch protection in their own destructors
    // If they crash, we can't recover, but at least we've ensured lastMsg is safe
}

// Community/topic/permission group types and methods (minimal stubs for linkability).
DEF_EMPTY_CTORS(V2TIMTopicInfo)
V2TIMTopicInfo& V2TIMTopicInfo::operator=(const V2TIMTopicInfo& topicInfo) = default;

DEF_EMPTY_CTORS(V2TIMTopicOperationResult)
DEF_EMPTY_CTORS(V2TIMTopicInfoResult)
DEF_EMPTY_CTORS(V2TIMTopicPermissionResult)

DEF_EMPTY_CTORS(V2TIMPermissionGroupInfoResult)
DEF_EMPTY_CTORS(V2TIMPermissionGroupInfo)
DEF_EMPTY_CTORS(V2TIMPermissionGroupMemberInfoResult)
DEF_EMPTY_CTORS(V2TIMPermissionGroupMemberOperationResult)
DEF_EMPTY_CTORS(V2TIMPermissionGroupOperationResult)

DEF_EMPTY_CTORS(V2TIMSignalingInfo)

// V2TIMMessage local storage: locally saved, not sent to peer.
// For link-time compatibility we provide a minimal no-op implementation.
void V2TIMMessage::SetLocalCustomData(const V2TIMBuffer &localCustomData, V2TIMCallback *callback) {
    (void)localCustomData;
    (void)callback;
}
