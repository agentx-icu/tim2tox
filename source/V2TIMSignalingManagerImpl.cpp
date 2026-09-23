#include "V2TIMSignalingManagerImpl.h"
#include "toxcore/tox.h"
#include "Tim2ToxPacketIds.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>
#include "V2TIMUtils.h"
#include "ToxManager.h"
#include "ToxUtil.h"
#include "V2TIMLog.h"
#include "TIMResultDefine.h" // For error definitions
#include "V2TIMManagerImpl.h"

// Define error codes
#define ERR_USER_OFFLINE 10001
#define ERR_INVITE_NOT_FOUND 10002

// First byte of every lossless custom packet is the Tox packet ID; the value
// (and the registry that keeps it from colliding with other clients) lives in
// Tim2ToxPacketIds.h. Our signaling type (SIGNALING_INVITE=0x01 etc.) is
// carried inside the payload that follows it.
static const uint8_t kToxSignalingPacketId = tim2tox::packet_ids::kSignaling;

// Defined in ffi/tim2tox_ffi.cpp; returns the process-global virtual clock in ms.
// V2TIMManagerImpl.cpp also uses this for mono_time injection.
extern "C" uint64_t tim2tox_virtual_time_cb(void* user_data);

// Monotonic-time helper for signaling timeouts.
//
// - Test mode (auto_tests with VirtualClock): returns the shared virtual clock.
//   Timers advance with pumpTestTick() — no real-time sleep required.
// - Production: returns std::chrono::steady_clock::now() in ms. Independent of
//   wall-clock changes (NTP/DST), so a 5s invite timeout is exactly 5 real
//   seconds even if the system clock is adjusted.
static uint64_t NowMonoMs(V2TIMManagerImpl* manager_impl) {
    if (manager_impl && manager_impl->isTestMode()) {
        return tim2tox_virtual_time_cb(nullptr);
    }
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// Helper function to get ToxManager from current V2TIMManagerImpl instance
ToxManager* V2TIMSignalingManagerImpl::GetToxManager() {
    // Use manager_impl_ instead of V2TIMManagerImpl::GetInstance() for multi-instance support
    V2TIMManagerImpl* manager_impl = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager_impl = manager_impl_;
    }
    if (!manager_impl) {
        // Fallback to default instance for backward compatibility
        manager_impl = V2TIMManagerImpl::GetInstance();
    }
    if (!manager_impl) return nullptr;
    return manager_impl->GetToxManager();
}

void V2TIMSignalingManagerImpl::OnToxMessage(uint32_t friend_number, 
                                           const uint8_t* data, size_t length) {
    // First byte is Tox packet_id (kToxSignalingPacketId); our payload starts at data+1
    if (length < 2) return;
    SignalingPacket packet = ParsePacket(data + 1, length - 1);
    if (packet.type > SIGNALING_TIMEOUT) return;  // invalid or truncated packet

    switch (packet.type) {
        case SIGNALING_INVITE: {
            // 复制数据后投递到事件线程下一轮执行，避免在 Tox 回调栈中直接调用 listener 或 Tox API（易触发 SIGSEGV）
            std::string invite_id_copy = packet.inviteID;
            uint32_t fn = friend_number;
            std::string data_copy = packet.data;
            uint32_t timeout_s = packet.timeout;
            V2TIMManagerImpl* manager_impl = nullptr;
            {
                std::lock_guard<std::mutex> lock(manager_impl_mutex_);
                manager_impl = manager_impl_;
            }
            V2TIM_LOG(kInfo, "[Signaling] OnToxMessage INVITE received: manager_impl={}, friend_number={}, invite_id={}",
                      (void*)manager_impl, (unsigned)friend_number, packet.inviteID);
            if (manager_impl) {
                manager_impl->PostToEventThread([this, invite_id_copy, fn, data_copy, timeout_s, manager_impl]() {
                    std::string inviter_str = GetUserIDFromFriendNumber(fn);
                    V2TIMString info_inviteID(invite_id_copy.c_str());
                    V2TIMString info_inviter(inviter_str.c_str());
                    std::string group_id_parsed;
                    std::string data_parsed = data_copy;
                    if (data_copy.size() >= 4 && data_copy.compare(0, 4, "GID:") == 0) {
                        size_t semicolon = data_copy.find(';', 4);
                        if (semicolon != std::string::npos) {
                            group_id_parsed = data_copy.substr(4, semicolon - 4);
                            data_parsed = data_copy.substr(semicolon + 1);
                        } else {
                            // No semicolon: treat rest of string as group_id (legacy or malformed)
                            group_id_parsed = data_copy.substr(4);
                        }
                    }
                    V2TIM_LOG(kInfo, "[Signaling] OnReceiveNewInvitation: invite_id={} group_id_parsed={} bytes data_parsed={} bytes",
                              invite_id_copy, group_id_parsed.size(), data_parsed.size());
                    V2TIMString info_groupID(group_id_parsed.c_str());
                    V2TIMString info_data(data_parsed.c_str());
                    V2TIMStringVector empty_vec;
                    // Callee-side deadline from the invite's own timeout, so a
                    // ring ends even if the caller's TIMEOUT packet never comes.
                    ReceivedInviteInfo received{fn, 0};
                    if (timeout_s > 0) {
                        received.deadline_mono_ms =
                            NowMonoMs(manager_impl) + static_cast<uint64_t>(timeout_s) * 1000ULL;
                    }
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        received_invites_[invite_id_copy] = received;  // 接收方保存 invite_id -> inviter friend_number(+超时)，供 Accept/Reject 使用
                        size_t n_listeners = listeners_.size();
                        V2TIM_LOG(kInfo, "[Signaling] Task running: signaling_impl={}, manager_impl={}, listeners_.size()={}",
                                  (void*)this, (void*)manager_impl, n_listeners);
                        for (auto* listener : listeners_) {
                            listener->OnReceiveNewInvitation(info_inviteID, info_inviter, info_groupID, empty_vec, info_data);
                        }
                    }
                });
            }
            break;
        }
        case SIGNALING_ACCEPT: {
            std::string invite_id_copy = packet.inviteID;
            std::string data_copy = packet.data;
            uint32_t fn = friend_number;
            V2TIMManagerImpl* manager_impl = nullptr;
            {
                std::lock_guard<std::mutex> lock(manager_impl_mutex_);
                manager_impl = manager_impl_;
            }
            if (manager_impl) {
                manager_impl->PostToEventThread([this, invite_id_copy, data_copy, fn]() {
                    std::string invitee_str = GetUserIDFromFriendNumber(fn);
                    V2TIMString info_inviteID(invite_id_copy.c_str());
                    V2TIMString info_invitee(invitee_str.c_str());
                    V2TIMString info_data(data_copy.c_str());
                    std::lock_guard<std::mutex> lock(mutex_);
                    active_invites_.erase(invite_id_copy);
                    for (auto* listener : listeners_) {
                        listener->OnInviteeAccepted(info_inviteID, info_invitee, info_data);
                    }
                });
            }
            break;
        }
        case SIGNALING_REJECT: {
            std::string invite_id_copy = packet.inviteID;
            std::string data_copy = packet.data;
            uint32_t fn = friend_number;
            V2TIMManagerImpl* manager_impl = nullptr;
            {
                std::lock_guard<std::mutex> lock(manager_impl_mutex_);
                manager_impl = manager_impl_;
            }
            if (manager_impl) {
                manager_impl->PostToEventThread([this, invite_id_copy, data_copy, fn]() {
                    std::string invitee_str = GetUserIDFromFriendNumber(fn);
                    V2TIMString info_inviteID(invite_id_copy.c_str());
                    V2TIMString info_invitee(invitee_str.c_str());
                    V2TIMString info_data(data_copy.c_str());
                    std::lock_guard<std::mutex> lock(mutex_);
                    active_invites_.erase(invite_id_copy);
                    for (auto* listener : listeners_) {
                        listener->OnInviteeRejected(info_inviteID, info_invitee, info_data);
                    }
                });
            }
            break;
        }
        case SIGNALING_CANCEL: {
            std::string invite_id_copy = packet.inviteID;
            std::string data_copy = packet.data;
            uint32_t fn = friend_number;
            V2TIMManagerImpl* manager_impl = nullptr;
            {
                std::lock_guard<std::mutex> lock(manager_impl_mutex_);
                manager_impl = manager_impl_;
            }
            if (manager_impl) {
                manager_impl->PostToEventThread([this, invite_id_copy, data_copy, fn]() {
                    std::string inviter_str = GetUserIDFromFriendNumber(fn);
                    V2TIMString info_inviteID(invite_id_copy.c_str());
                    V2TIMString info_inviter(inviter_str.c_str());
                    V2TIMString info_data(data_copy.c_str());
                    std::lock_guard<std::mutex> lock(mutex_);
                    received_invites_.erase(invite_id_copy);
                    for (auto* listener : listeners_) {
                        listener->OnInvitationCancelled(info_inviteID, info_inviter, info_data);
                    }
                });
            }
            break;
        }
        case SIGNALING_TIMEOUT: {
            // The inviter's deadline passed: end the ring here too. Only an
            // invite still pending on this side (not yet accepted / rejected /
            // cancelled) fires, and only from its inviter.
            // CheckTimeouts() itself sends CANCEL rather than this type (older
            // peers ignore TIMEOUT — see the comment there); this handler stays
            // so a peer that does send it is understood.
            std::string invite_id_copy = packet.inviteID;
            uint32_t fn = friend_number;
            V2TIMManagerImpl* manager_impl = nullptr;
            {
                std::lock_guard<std::mutex> lock(manager_impl_mutex_);
                manager_impl = manager_impl_;
            }
            if (manager_impl) {
                manager_impl->PostToEventThread([this, invite_id_copy, fn]() {
                    std::vector<V2TIMSignalingListener*> listeners_copy;
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        auto it = received_invites_.find(invite_id_copy);
                        if (it == received_invites_.end() || it->second.inviter_friend_number != fn) {
                            return;
                        }
                        received_invites_.erase(it);
                        listeners_copy = listeners_;
                    }
                    V2TIMString info_inviteID(invite_id_copy.c_str());
                    V2TIMStringVector empty_vec;
                    for (auto* listener : listeners_copy) {
                        if (listener) listener->OnInvitationTimeout(info_inviteID, empty_vec);
                    }
                });
            }
            break;
        }
        // ... 其他类型
    }
}

V2TIMSignalingManagerImpl::V2TIMSignalingManagerImpl() : manager_impl_(nullptr), unique_id_counter_(0) {
    // NOTE: Do NOT call tox_callback_friend_message(tox, nullptr) here.
    // V2TIMManagerImpl::RegisterCallbacks() sets tox_callback_friend_message for C2C text messages.
    // This constructor runs when GetSignalingManager() is first called (e.g. when adding signaling
    // listeners). Calling tox_callback_friend_message(tox, nullptr) would overwrite the C2C callback
    // and cause received friend messages to never reach HandleFriendMessage / OnRecvNewMessage.
    // Signaling uses tox_callback_friend_lossless_packet (a separate callback), not friend_message.
}

// Multi-instance support: Set the associated V2TIMManagerImpl instance
void V2TIMSignalingManagerImpl::SetManagerImpl(V2TIMManagerImpl* manager_impl) {
    V2TIMManagerImpl* old_impl = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        old_impl = manager_impl_;
    }
    if (manager_impl != old_impl) {
        ResetSessionState();
    }
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager_impl_ = manager_impl;
    }
}

void V2TIMSignalingManagerImpl::ResetSessionState() {
    std::lock_guard<std::mutex> lock(mutex_);
    active_invites_.clear();
    received_invites_.clear();
}

V2TIMSignalingManagerImpl::~V2TIMSignalingManagerImpl() {
    // Nothing to clean up: timeouts are now iterate-driven (see CheckTimeouts)
    // rather than backed by per-invite std::thread instances. Active invites
    // are dropped along with the map when this manager is destroyed.
}

// Idempotent: the dart_compat layer registers the same per-instance listener
// once per callback setter (six of them), and every re-login registers it
// again. A duplicate entry would deliver every signaling event once per
// registration (six busy rejects for one invite, six timeouts, ...).
void V2TIMSignalingManagerImpl::AddSignalingListener(V2TIMSignalingListener* listener) {
    if (!listener) return;
    std::lock_guard<std::mutex> lock(mutex_);
    if (std::find(listeners_.begin(), listeners_.end(), listener) != listeners_.end()) {
        return;
    }
    listeners_.push_back(listener);
}

// Removes every occurrence, so no stale registration can survive a remove.
void V2TIMSignalingManagerImpl::RemoveSignalingListener(V2TIMSignalingListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    listeners_.erase(std::remove(listeners_.begin(), listeners_.end(), listener), listeners_.end());
}

V2TIMString V2TIMSignalingManagerImpl::Invite(const V2TIMString& invitee, const V2TIMString& data,
                                              bool onlineUserOnly,
                                              const V2TIMOfflinePushInfo& offlinePushInfo,
                                              int timeout, V2TIMCallback* callback) {
    V2TIMManagerImpl* manager_impl = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager_impl = manager_impl_;
    }
    if (!manager_impl) {
        if (callback) callback->OnError(ERR_USER_OFFLINE, "Manager not initialized");
        return V2TIMString("");
    }
    // Run all tox API calls on the event thread to avoid deadlock (event thread holds tox lock in tox_iterate)
    std::string inviteID = GenerateUniqueID();
    V2TIMString invitee_copy = invitee;
    V2TIMString data_copy = data;
    return manager_impl->RunOnEventThread<V2TIMString>([this, inviteID, invitee_copy, data_copy,
                                                        onlineUserOnly, timeout, callback,
                                                        manager_impl]() -> V2TIMString {
        uint32_t friend_number = this->GetFriendNumber(invitee_copy);
        if (friend_number == UINT32_MAX) {
            if (callback) callback->OnError(ERR_USER_OFFLINE, "Invitee not in friend list (GetFriendNumber failed)");
            return V2TIMString("");
        }
        if (onlineUserOnly) {
            ToxManager* tox_manager = GetToxManager();
            if (!tox_manager) {
                if (callback) callback->OnError(ERR_USER_OFFLINE, "ToxManager not initialized");
                return V2TIMString("");
            }
            Tox* tox = tox_manager->getTox();
            if (!tox) {
                if (callback) callback->OnError(ERR_USER_OFFLINE, "Tox instance not available");
                return V2TIMString("");
            }
            TOX_CONNECTION status = tox_friend_get_connection_status(tox, friend_number, nullptr);
            if (status == TOX_CONNECTION_NONE) {
                if (callback) callback->OnError(ERR_USER_OFFLINE, "User is offline");
                return V2TIMString(inviteID.c_str());
            }
        }
        SignalingPacket packet;
        packet.type = SIGNALING_INVITE;
        packet.inviteID = inviteID;
        packet.data = data_copy.CString();
        packet.timeout = timeout;
        std::vector<uint8_t> payload = ::SerializePacket(packet);
        payload.insert(payload.begin(), kToxSignalingPacketId);
        ToxManager* tox_manager = GetToxManager();
        if (!tox_manager) {
            if (callback) callback->OnError(ERR_USER_OFFLINE, "ToxManager not initialized");
            return V2TIMString("");
        }
        Tox* tox = tox_manager->getTox();
        if (!tox) {
            if (callback) callback->OnError(ERR_USER_OFFLINE, "Tox instance not available");
            return V2TIMString("");
        }
        tox_friend_send_lossless_packet(tox, friend_number, payload.data(), payload.size(), nullptr);
        // Record the invite with a monotonic-time deadline so CheckTimeouts()
        // (called from the event-thread / iterate loop) can fire
        // OnInvitationTimeout when the deadline passes. This avoids the
        // previous implementation's per-invite std::thread, which both leaked
        // wall-clock semantics into virtual-mode tests (5s sleep_for vs. ~1s
        // of real time inside a 10s virtual budget) and serialised invites
        // through a join() that blocked the event thread inside the next
        // Invite() call.
        const uint64_t now_ms = NowMonoMs(manager_impl);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            SignalingInviteInfo info;
            info.inviteID = inviteID;
            if (tox_manager) info.inviter = tox_manager->getAddress();
            info.data = data_copy;
            info.timeout = timeout;
            info.isOnlineOnly = onlineUserOnly;
            info.sender_friend_number = friend_number;
            info.deadline_mono_ms = (timeout > 0)
                ? (now_ms + static_cast<uint64_t>(timeout) * 1000ULL)
                : 0;
            active_invites_[inviteID] = info;
        }
        if (callback) callback->OnSuccess();
        return V2TIMString(inviteID.c_str());
    });
}

void V2TIMSignalingManagerImpl::CheckTimeouts() {
    // Snapshot under lock, then dispatch outside the lock so listener
    // callbacks (and any re-entrant signaling API they make) cannot deadlock
    // on mutex_. Same pattern as the rest of the dispatchers above.
    V2TIMManagerImpl* manager_impl = nullptr;
    {
        std::lock_guard<std::mutex> lock(manager_impl_mutex_);
        manager_impl = manager_impl_;
    }
    const uint64_t now_ms = NowMonoMs(manager_impl);
    // Sender side: (inviteID, invitee friend number) whose ring expired.
    std::vector<std::pair<std::string, uint32_t>> expired_sent;
    // Receiver side: invites whose caller never ended them (caller offline /
    // TIMEOUT packet lost) — the callee must stop ringing on its own.
    std::vector<std::string> expired_received;
    std::vector<V2TIMSignalingListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_invites_.empty() && received_invites_.empty()) return;
        for (auto& kv : active_invites_) {
            const SignalingInviteInfo& info = kv.second;
            if (info.deadline_mono_ms == 0) continue;  // no timeout requested
            if (now_ms >= info.deadline_mono_ms) {
                expired_sent.emplace_back(kv.first, info.sender_friend_number);
            }
        }
        for (auto& kv : received_invites_) {
            if (kv.second.deadline_mono_ms != 0 && now_ms >= kv.second.deadline_mono_ms) {
                expired_received.push_back(kv.first);
            }
        }
        if (expired_sent.empty() && expired_received.empty()) return;
        // Erase before dispatching so a re-entrant Cancel/Accept from the
        // listener can't double-erase or hit a stale entry.
        for (const auto& entry : expired_sent) {
            active_invites_.erase(entry.first);
        }
        for (const auto& id : expired_received) {
            received_invites_.erase(id);
        }
        listeners_copy = listeners_;
    }
    // Tell each invitee its ring is over (outside mutex_, like Cancel's send
    // but without holding the lock across the Tox call). Best effort: if it
    // is lost the invitee's own deadline above still ends the ring.
    //
    // CANCEL, not SIGNALING_TIMEOUT, deliberately: a peer built before the
    // callee-side deadline existed has an EMPTY handler for TIMEOUT (it only
    // ever logged it) and no deadline of its own, so its phone would ring
    // until the user answered a call that no longer exists. CANCEL is
    // understood by every build — it is the invitee-visible meaning of "the
    // caller gave up" — and a current peer treats either as the end of the
    // ring (whichever of the packet and its own deadline lands first).
    for (const auto& entry : expired_sent) {
        SignalingPacket packet;
        packet.type = SIGNALING_CANCEL;
        packet.inviteID = entry.first;
        packet.timeout = 0;
        SendToxPacket(entry.second, packet);
    }
    auto dispatch = [&listeners_copy](const std::string& id) {
        V2TIMString info_inviteID(id.c_str());
        V2TIMStringVector empty_vec;
        for (auto* listener : listeners_copy) {
            if (listener) listener->OnInvitationTimeout(info_inviteID, empty_vec);
        }
    };
    for (const auto& entry : expired_sent) dispatch(entry.first);
    for (const auto& id : expired_received) dispatch(id);
}

V2TIMString V2TIMSignalingManagerImpl::InviteInGroup(const V2TIMString& groupID,
                                                     const V2TIMStringVector& inviteeList,
                                                     const V2TIMString& data, bool onlineUserOnly,
                                                     int timeout, V2TIMCallback* callback) {
    std::string invite_id = GenerateUniqueID();
    std::string group_id_str = groupID.CString() ? groupID.CString() : "";
    std::string data_str = data.CString() ? data.CString() : "";
    // 在 data 前加 "GID:groupID;" 供接收方解析 groupID
    std::string data_with_gid = "GID:" + group_id_str + ";" + data_str;
    // 创建或获取会议 ID
    uint32_t conference_number = this->GetOrCreateConference(groupID);
    
    // 邀请每个成员加入会议，并发送 P2P 信令邀请（带 group_id）以便对方触发 OnReceiveNewInvitation
    for (size_t i = 0; i < inviteeList.Size(); i++) {
        const char* raw = inviteeList[i].CString();
        if (!raw || !*raw) continue;
        std::string invitee_copy(raw);
        uint32_t friend_number = this->GetFriendNumber(V2TIMString(invitee_copy.c_str()));
        ToxManager* tox_manager = GetToxManager();
        if (tox_manager && friend_number != UINT32_MAX) {
            tox_manager->inviteToConference(friend_number, conference_number, nullptr);
            SignalingPacket packet;
            packet.type = SIGNALING_INVITE;
            packet.inviteID = invite_id;
            packet.data = data_with_gid;
            packet.timeout = timeout;
            SendToxPacket(friend_number, packet);
        }
    }
    
    this->SendConferenceMessage(conference_number, data);
    
    if (callback) callback->OnSuccess();
    return V2TIMString(invite_id.c_str());
}

void V2TIMSignalingManagerImpl::Cancel(const V2TIMString& inviteID, const V2TIMString& data,
                                       V2TIMCallback* callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::string id_str(inviteID.CString() ? inviteID.CString() : "");
    auto it = active_invites_.find(id_str);
    if (it == active_invites_.end()) {
        if (callback) callback->OnError(ERR_INVITE_NOT_FOUND, "Invite not found");
        return;
    }
    SignalingPacket packet;
    packet.type = SIGNALING_CANCEL;
    packet.inviteID = id_str;
    packet.data = data.CString() ? data.CString() : "";
    SendToxPacket(it->second.sender_friend_number, packet);
    active_invites_.erase(it);
    if (callback) callback->OnSuccess();
}

void V2TIMSignalingManagerImpl::Accept(const V2TIMString& inviteID, const V2TIMString& data,
                                       V2TIMCallback* callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::string id_str(inviteID.CString() ? inviteID.CString() : "");
    // 接收方：从收到的邀请中查找 inviter friend_number
    auto recv_it = received_invites_.find(id_str);
    if (recv_it != received_invites_.end()) {
        SignalingPacket packet;
        packet.type = SIGNALING_ACCEPT;
        packet.inviteID = id_str;
        packet.data = data.CString() ? data.CString() : "";
        SendToxPacket(recv_it->second.inviter_friend_number, packet);
        received_invites_.erase(recv_it);
        if (callback) callback->OnSuccess();
        return;
    }
    // 发送方：从主动发出的邀请中查找（兼容旧逻辑）
    auto it = active_invites_.find(id_str);
    if (it == active_invites_.end()) {
        if (callback) callback->OnError(ERR_INVITE_NOT_FOUND, "Invite not found");
        return;
    }
    SignalingPacket packet;
    packet.type = SIGNALING_ACCEPT;
    packet.inviteID = id_str;
    packet.data = data.CString() ? data.CString() : "";
    SendToxPacket(it->second.sender_friend_number, packet);
    active_invites_.erase(it);
    if (callback) callback->OnSuccess();
}

void V2TIMSignalingManagerImpl::Reject(const V2TIMString& inviteID, const V2TIMString& data,
                                       V2TIMCallback* callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::string id_str(inviteID.CString() ? inviteID.CString() : "");
    auto recv_it = received_invites_.find(id_str);
    if (recv_it != received_invites_.end()) {
        SignalingPacket packet;
        packet.type = SIGNALING_REJECT;
        packet.inviteID = id_str;
        packet.data = data.CString() ? data.CString() : "";
        SendToxPacket(recv_it->second.inviter_friend_number, packet);
        received_invites_.erase(recv_it);
        if (callback) callback->OnSuccess();
        return;
    }
    if (callback) callback->OnError(ERR_INVITE_NOT_FOUND, "Invite not found");
}

V2TIMSignalingInfo V2TIMSignalingManagerImpl::GetSignalingInfo(const V2TIMMessage& msg) {
    // Implementation using third_party/c-toxcore
    return V2TIMSignalingInfo();
}

void V2TIMSignalingManagerImpl::AddInvitedSignaling(const V2TIMSignalingInfo& info,
                                                    V2TIMCallback* callback) {
    // Implementation using third_party/c-toxcore
}

void V2TIMSignalingManagerImpl::ModifyInvitation(const V2TIMString& inviteID,
                                                 const V2TIMString& data,
                                                 V2TIMCallback* callback) {
    // Implementation using third_party/c-toxcore
}

// 假设维护一个 friend_number -> UserID 的映射表
std::string V2TIMSignalingManagerImpl::GetUserIDFromFriendNumber(uint32_t friend_number) {
    uint8_t public_key[TOX_PUBLIC_KEY_SIZE];
        ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) return "";
    Tox* tox = tox_manager->getTox();
    if (!tox) return "";
    if (!tox_friend_get_public_key(tox, friend_number, public_key, nullptr))
        return "";

    // 将 Tox 公钥转换为十六进制字符串作为 UserID
    char hex[2 * TOX_PUBLIC_KEY_SIZE + 1];
    for (size_t i = 0; i < TOX_PUBLIC_KEY_SIZE; ++i) {
        sprintf(hex + 2 * i, "%02X", public_key[i]);
    }
    return std::string(hex, 2 * TOX_PUBLIC_KEY_SIZE);
}

uint32_t V2TIMSignalingManagerImpl::GetFriendNumber(const V2TIMString& userID) {
    const char* usePtr = userID.CString();
    if (!usePtr) return UINT32_MAX;
    size_t useLen = std::strlen(usePtr);
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) {
        V2TIM_LOG(kError, "V2TIMSignalingManagerImpl: ToxManager not initialized");
        return UINT32_MAX;
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) return UINT32_MAX;
    
    // userID 可能是 64 字符公钥或更长（如带前缀），取前 64 个十六进制字符作为公钥
    const size_t keyHexLen = TOX_PUBLIC_KEY_SIZE * 2;
    if (useLen < keyHexLen) {
        V2TIM_LOG(kError, "GetFriendNumber: Invalid UserID format (length=%zu, need at least %zu)", useLen, keyHexLen);
        return UINT32_MAX;
    }
    if (useLen > keyHexLen)
        useLen = keyHexLen;
    uint8_t public_key[TOX_PUBLIC_KEY_SIZE];
    if (!ToxUtil::tox_hex_to_bytes(usePtr, useLen, public_key, TOX_PUBLIC_KEY_SIZE)) {
        V2TIM_LOG(kError, "GetFriendNumber: Invalid UserID format (not hex or wrong length)");
        return UINT32_MAX;
    }
    
    TOX_ERR_FRIEND_BY_PUBLIC_KEY err;
    uint32_t friend_num = tox_friend_by_public_key(tox, public_key, &err);
    if (err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        V2TIM_LOG(kError, "GetFriendNumber: Failed to find friend, error code: {}", err);
        return UINT32_MAX;
    }
    
    return friend_num;
}

// Stub implementations for missing methods
std::string V2TIMSignalingManagerImpl::GenerateUniqueID() {
    // Per-instance counter for multi-instance support (replaces static counter)
    // Use mutex to ensure thread safety
    std::lock_guard<std::mutex> lock(mutex_);
    return "inv_" + std::to_string(time(nullptr)) + "_" + std::to_string(unique_id_counter_++);
}

std::vector<uint8_t> V2TIMSignalingManagerImpl::SerializePacket(const SignalingPacket& packet) {
    return ::SerializePacket(packet);
}

void V2TIMSignalingManagerImpl::SendToxPacket(uint32_t friend_number, const SignalingPacket& packet) {
    std::vector<uint8_t> data = ::SerializePacket(packet);
    data.insert(data.begin(), kToxSignalingPacketId);
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) return;
    Tox* tox = tox_manager->getTox();
    if (!tox) return;
    tox_friend_send_lossless_packet(tox, friend_number, data.data(), data.size(), nullptr);
}

uint32_t V2TIMSignalingManagerImpl::GetOrCreateConference(const V2TIMString& groupID) {
    // Placeholder implementation - would create or look up a conference number
    return 0;
}

void V2TIMSignalingManagerImpl::SendConferenceMessage(uint32_t conference_number, const V2TIMString& data) {
    // Placeholder implementation
    // In a real implementation, this would send a message to the conference
}
