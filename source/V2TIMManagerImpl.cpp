#include "V2TIMManagerImpl.h"
#include "PathUtils.h"
#include "V2TIMUtils.h"
#include "Tim2ToxControlPacket.h"
extern "C" {
#include "toxcore/crypto_core.h"  // crypto_sha256 / encrypt_data (MM-6 digests + sealed proof)
#include "toxcore/os_random.h"    // os_random (MM-6 challenge + box nonces)
#include "toxcore/os_memory.h"    // os_memory (the Memory* encrypt_data/decrypt_data take)
}
#include "Tim2ToxPacketIds.h"
#include <random>
#include <map>
#include "QToxMessageFragmenter.h"
#include "version.h"
#include <V2TIMErrorCode.h>
#include "ToxManager.h"
#include "tox.h"
#include "tox_options.h"
#include "toxcore/mono_time.h"
#include "ToxUtil.h"
#include <cstdlib>
#include <ctime>
#include <cstdio>
#include <cstring>
#include <unordered_map>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <atomic>
#include <sstream>
#include <iomanip>
#include "V2TIMLog.h" // Updated include
#include <vector> // For buffer operations
#include <algorithm> // For std::all_of
#include <cctype>    // std::isxdigit / std::tolower (receipt + MM-6 parsing)
#include <limits>

// Global group-id counter so "tox_0","tox_1",... are unique across instances.
// Avoids cross-instance collision when one instance's "tox_0" is used by
// another instance's JoinGroup (e.g. "Join private group" test).
static std::atomic<uint64_t> g_next_group_id_global{0};

// Multi-instance auto_tests share one process while each Tox instance keeps
// its own group-ID map. The invite cookie carries only the Tox chat ID, so
// retain the creator's stable application ID for invitee-side resolution.
//
// Entries remember which instance recorded them so UnInitSDK can drop exactly
// that instance's entries. The production default instance is never
// destroyed; without the owner tag an account switch left the previous
// account's chat_id -> groupID bindings here, and the next account's groups
// were canonicalised onto the previous account's IDs.
struct CrossInstanceGroupIdentity {
    std::string group_id;
    int64_t owner_instance_id;
};
static std::mutex g_cross_instance_group_identity_mutex;
static std::unordered_map<std::string, CrossInstanceGroupIdentity>
    g_cross_instance_group_identity;

static void RememberCrossInstanceGroupIdentity(
    const std::string& group_id, const std::string& chat_id_hex,
    int64_t owner_instance_id) {
    if (group_id.empty() || chat_id_hex.empty()) return;
    std::lock_guard<std::mutex> lock(g_cross_instance_group_identity_mutex);
    g_cross_instance_group_identity[chat_id_hex] = {group_id, owner_instance_id};
}

static void ForgetCrossInstanceGroupIdentities(int64_t owner_instance_id) {
    std::lock_guard<std::mutex> lock(g_cross_instance_group_identity_mutex);
    for (auto it = g_cross_instance_group_identity.begin();
         it != g_cross_instance_group_identity.end();) {
        if (it->second.owner_instance_id == owner_instance_id) {
            it = g_cross_instance_group_identity.erase(it);
        } else {
            ++it;
        }
    }
}

// Forward declaration for GetTestInstanceOptions (defined in tim2tox_ffi.cpp with extern "C" linkage)
extern "C" bool GetTestInstanceOptions(int64_t instance_id, int* out_local_discovery, int* out_ipv6);
// Per-instance UDP bind range (defined in tim2tox_ffi.cpp); false = keep toxcore defaults.
extern "C" bool GetTestInstanceUdpPortRange(int64_t instance_id, int* out_start_port, int* out_end_port);

// Forward declaration for DartNotifyGroupQuit (defined in ffi/dart_compat_group.cpp
// with extern "C" linkage). Posts a "groupQuitNotification" callback that the
// Platform path maps to FfiChatService.cleanupGroupState (removes the group from
// _knownGroups). The voluntary-quit path already uses it; the self-kick path
// (HandleGroupModeration) reuses it so a kicked member drops the group too.
//
// Every DartNotifyGroup* takes the emitting session's (instance_id,
// session_epoch) — pass GetInstanceIdFromManager(this) / GetSessionEpoch(). These posts
// have no user_data and reach one process-global Dart handler, so the stamp is
// the only thing that lets Dart drop a notification from another test node or
// from the previous account's session after an account switch.
extern "C" void DartNotifyGroupQuit(const char* group_id, int64_t instance_id, int64_t session_epoch);
// Inverse of the above: posts "groupJoinNotification" → FfiChatService
// .registerJoinedGroupState (ADDS the group to _knownGroups). Used from
// HandleGroupSelfJoin so an invite auto-join (which the Dart layer did not
// initiate via joinGroup) still surfaces in B's knownGroups.
extern "C" void DartNotifyGroupJoin(const char* group_id, int64_t instance_id, int64_t session_epoch);
extern "C" void DartNotifyGroupInvite(const char* invite_id, int64_t instance_id, int64_t session_epoch);
extern "C" void DartNotifyGroupKicked(const char* group_id, int64_t instance_id, int64_t session_epoch);
// Persist a group's stable identity (NGC chat_id / conference id) and kind in
// the Dart preferences. Emitted whenever the in-memory value changes, so every
// create / join / invite path persists it — not just opening the profile page.
extern "C" void DartNotifyGroupIdentityStored(const char* group_id, const char* chat_id_hex, int64_t instance_id, int64_t session_epoch);
extern "C" void DartNotifyGroupTypeStored(const char* group_id, const char* group_type, int64_t instance_id, int64_t session_epoch);
// A join the group refused: reason is invalid_password / peer_limit / unknown.
extern "C" void DartNotifyGroupJoinFailed(const char* group_id, const char* chat_id_hex, const char* reason, bool established, const char* invite_id, int64_t instance_id, int64_t session_epoch);
// Drops durable notifications still waiting for a Dart port that an ended
// session of this instance emitted (defined in ffi/callback_bridge.cpp).
void DiscardDurableCallbacksForInstance(int64_t instance_id);

// Process-wide source of V2TIMManagerImpl session epochs (see GetSessionEpoch).
static std::atomic<int64_t> g_next_session_epoch{0};

// Forward declaration for the process-global virtual-clock callback
// (defined in tim2tox_ffi.cpp). Used when test_mode_ is enabled to make
// mono_time read from the auto_tests harness's virtual clock instead of
// the wall clock.
extern "C" uint64_t tim2tox_virtual_time_cb(void* user_data);

// Forward declarations for instance management functions (defined in tim2tox_ffi.cpp as C++ functions)
// Note: These are NOT extern "C" because they are defined as regular C++ functions in tim2tox_ffi.cpp
extern int64_t GetCurrentInstanceId();
extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
// Receiver instance override: set before NotifyAdvancedListenersReceivedMessage so OnRecvNewMessage routes to correct instance
extern int64_t GetReceiverInstanceOverride(void);
extern void SetReceiverInstanceOverride(int64_t id);
extern void ClearReceiverInstanceOverride(void);
extern int GetReceiverCustomRouteOverride(void);
extern void SetReceiverCustomRouteOverride(uint8_t route);
extern void ClearReceiverCustomRouteOverride(void);
extern int GetReceiverTextKindOverride(void);
extern void SetReceiverTextKindOverride(int kind);
extern void ClearReceiverTextKindOverride(void);
extern int64_t GetReceiverGroupMessageIdOverride(void);
extern void SetReceiverGroupMessageIdOverride(int64_t id);
extern void ClearReceiverGroupMessageIdOverride(void);
extern void SetLastGroupSendMessageId(int64_t id);
extern void SetLastGroupSendSelfKey(const char* hex);
#include <string> // For std::string
#include <filesystem>
#include <sys/stat.h>
#include <sys/types.h>
#ifndef _WIN32
#include <unistd.h>
#endif
#include <fstream>
#include <thread>
#include <system_error> // For std::system_error
#include <stdexcept> // For std::runtime_error
#include "MessageReplyUtil.h"
#include "MergerMessageUtil.h"
#include "V2TIMMessageManagerImpl.h"
#include "V2TIMGroupManagerImpl.h"
#include "V2TIMConversationManagerImpl.h"
#include "V2TIMCommunityManagerImpl.h"
#include "V2TIMFriendshipManagerImpl.h"

namespace {

using tim2tox::control::Type;

uint64_t PendingDeliveryKey(uint32_t friend_number, uint32_t tox_message_number) {
    return (static_cast<uint64_t>(friend_number) << 32) |
           static_cast<uint64_t>(tox_message_number);
}

class ReceiverInstanceOverrideGuard {
public:
    explicit ReceiverInstanceOverrideGuard(int64_t instance_id)
        : previous_instance_id_(GetReceiverInstanceOverride()) {
        SetReceiverInstanceOverride(instance_id);
    }

    ~ReceiverInstanceOverrideGuard() noexcept {
        if (previous_instance_id_ == 0) {
            ClearReceiverInstanceOverride();
        } else {
            SetReceiverInstanceOverride(previous_instance_id_);
        }
    }

    ReceiverInstanceOverrideGuard(const ReceiverInstanceOverrideGuard&) = delete;
    ReceiverInstanceOverrideGuard& operator=(const ReceiverInstanceOverrideGuard&) = delete;

private:
    int64_t previous_instance_id_;
};

class ReceiverCustomRouteOverrideGuard {
public:
    explicit ReceiverCustomRouteOverrideGuard(uint8_t route)
        : previous_route_(GetReceiverCustomRouteOverride()) {
        SetReceiverCustomRouteOverride(route);
    }

    ~ReceiverCustomRouteOverrideGuard() noexcept {
        if (previous_route_ == -1) {
            ClearReceiverCustomRouteOverride();
        } else {
            SetReceiverCustomRouteOverride(static_cast<uint8_t>(previous_route_));
        }
    }

    ReceiverCustomRouteOverrideGuard(const ReceiverCustomRouteOverrideGuard&) = delete;
    ReceiverCustomRouteOverrideGuard& operator=(const ReceiverCustomRouteOverrideGuard&) = delete;

private:
    int previous_route_;
};

/// Publishes the Tox NGC pseudo message id of the group message being
/// delivered, so the FFI simple listener can put it in the polled event line.
/// Thread-local and scope-bound like its siblings; -1 restores "absent".
// Every NGC custom packet tim2tox sends starts with this header. NGC custom
// packets are an open channel other clients use for their own protocols
// (file sync, history sync, ...); without a signature every foreign packet
// became a "[Custom Message]" bubble, a history row and a notification.
//   0xB7 'T' '2' 'T' <version=1> <kind>
static constexpr uint8_t kTim2ToxGroupPacketMagic[4] = {0xB7, 'T', '2', 'T'};
static constexpr uint8_t kTim2ToxGroupPacketVersion = 1;
static constexpr size_t kTim2ToxGroupPacketHeaderSize = 6;
enum : uint8_t {
    kTim2ToxGroupPacketCustomMessage = 1,  // broadcast: V2TIM custom elem payload
    kTim2ToxGroupPacketReceipt = 2,        // private: receipt JSON for the author
    kTim2ToxGroupPacketIdentityProof = 3,  // private: MM-6 identity proof
};

static std::string EscapeJsonForReceipt(const std::string& value) {
    std::string out;
    out.reserve(value.size());
    for (const char c : value) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            default:
                if (static_cast<unsigned char>(c) >= 0x20) out += c;
        }
    }
    return out;
}

// Well-formed UTF-8 only: no overlong forms, no UTF-16 surrogates, nothing
// above U+10FFFF. Dart would otherwise decode such bytes differently (or
// reject the body) after the native side had already accepted it.
static bool IsValidUtf8(const uint8_t* data, size_t length) {
    size_t i = 0;
    while (i < length) {
        const uint8_t c = data[i];
        if (c < 0x80) {
            ++i;
            continue;
        }
        size_t extra = 0;
        uint32_t cp = 0;
        uint32_t min_cp = 0;
        if ((c & 0xE0) == 0xC0) {
            extra = 1; cp = c & 0x1F; min_cp = 0x80;
        } else if ((c & 0xF0) == 0xE0) {
            extra = 2; cp = c & 0x0F; min_cp = 0x800;
        } else if ((c & 0xF8) == 0xF0) {
            extra = 3; cp = c & 0x07; min_cp = 0x10000;
        } else {
            return false;
        }
        if (length - i <= extra) return false;
        for (size_t k = 1; k <= extra; ++k) {
            const uint8_t cc = data[i + k];
            if ((cc & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (cp < min_cp || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        i += extra + 1;
    }
    return true;
}

static void AppendUtf8(std::string& out, uint32_t cp) {
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
}

struct StrictGroupReceipt {
    std::string msg_id;
    std::string receipt_type;
    std::string sender;
};

// True when body is exactly {"type":"receipt","msgID":..,"receiptType":
// "received"|"read","sender":<64 hex>} with string values and no other keys —
// the same schema the Dart side consumes as a control. Anything else would be
// rendered as a visible ACTION row, so it must not ride the receipt channel.
// Strings are validated and DECODED per RFC 8259 (only \" \\ \/ \b \f \n \r
// \t and \uXXXX, surrogates paired), so what is compared here is exactly what
// Dart's jsonDecode will see: "receipt" is "receipt" on both sides, and
// a body Dart would reject never gets past this gate.
static bool ParseStrictReceiptJson(const uint8_t* data, size_t length, StrictGroupReceipt* out_receipt) {
    if (!IsValidUtf8(data, length)) return false;
    size_t i = 0;
    auto skip_ws = [&]() {
        while (i < length && (data[i] == ' ' || data[i] == '\t' || data[i] == '\n' || data[i] == '\r')) ++i;
    };
    auto parse_hex4 = [&](size_t at, uint32_t& value) -> bool {
        if (at > length || length - at < 4) return false;
        value = 0;
        for (size_t k = 0; k < 4; ++k) {
            const uint8_t h = data[at + k];
            uint32_t v = 0;
            if (h >= '0' && h <= '9') v = h - '0';
            else if (h >= 'a' && h <= 'f') v = h - 'a' + 10;
            else if (h >= 'A' && h <= 'F') v = h - 'A' + 10;
            else return false;
            value = (value << 4) | v;
        }
        return true;
    };
    auto parse_string = [&](std::string& out) -> bool {
        if (i >= length || data[i] != '"') return false;
        ++i;
        while (i < length && data[i] != '"') {
            const uint8_t c = data[i];
            if (c < 0x20) return false;
            if (c != '\\') {
                out.push_back(static_cast<char>(c));
                ++i;
                continue;
            }
            if (i + 1 >= length) return false;
            const uint8_t esc = data[i + 1];
            i += 2;
            switch (esc) {
                case '"': out.push_back('"'); continue;
                case '\\': out.push_back('\\'); continue;
                case '/': out.push_back('/'); continue;
                case 'b': out.push_back('\b'); continue;
                case 'f': out.push_back('\f'); continue;
                case 'n': out.push_back('\n'); continue;
                case 'r': out.push_back('\r'); continue;
                case 't': out.push_back('\t'); continue;
                case 'u': {
                    uint32_t cp = 0;
                    if (!parse_hex4(i, cp)) return false;
                    i += 4;
                    if (cp >= 0xDC00 && cp <= 0xDFFF) return false;  // unpaired low surrogate
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        uint32_t low = 0;
                        if (length - i < 6 || data[i] != '\\' || data[i + 1] != 'u' ||
                            !parse_hex4(i + 2, low) || low < 0xDC00 || low > 0xDFFF) {
                            return false;  // unpaired high surrogate
                        }
                        i += 6;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    }
                    AppendUtf8(out, cp);
                    continue;
                }
                default:
                    return false;  // not a JSON escape
            }
        }
        if (i >= length) return false;
        ++i;  // closing quote
        return true;
    };
    std::map<std::string, std::string> fields;
    skip_ws();
    if (i >= length || data[i] != '{') return false;
    ++i;
    while (true) {
        skip_ws();
        std::string key, value;
        if (!parse_string(key)) return false;
        skip_ws();
        if (i >= length || data[i] != ':') return false;
        ++i;
        skip_ws();
        if (!parse_string(value)) return false;
        if (!fields.emplace(std::move(key), std::move(value)).second) return false;
        skip_ws();
        if (i < length && data[i] == ',') { ++i; continue; }
        if (i < length && data[i] == '}') { ++i; break; }
        return false;
    }
    skip_ws();
    if (i != length || fields.size() != 4) return false;
    const auto type = fields.find("type");
    const auto msg_id = fields.find("msgID");
    const auto receipt_type = fields.find("receiptType");
    const auto sender = fields.find("sender");
    const bool ok = type != fields.end() && type->second == "receipt" &&
                    msg_id != fields.end() && !msg_id->second.empty() &&
                    receipt_type != fields.end() &&
                    (receipt_type->second == "received" || receipt_type->second == "read") &&
                    sender != fields.end() &&
                    sender->second.size() == static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2) &&
                    std::all_of(sender->second.begin(), sender->second.end(),
                                [](unsigned char ch) { return std::isxdigit(ch) != 0; });
    if (!ok) return false;
    if (out_receipt != nullptr) {
        out_receipt->msg_id = msg_id->second;
        out_receipt->receipt_type = receipt_type->second;
        out_receipt->sender = sender->second;
    }
    return true;
}

static std::vector<uint8_t> WrapTim2ToxGroupPacket(uint8_t kind, const uint8_t* data, size_t length) {
    std::vector<uint8_t> packet;
    packet.reserve(kTim2ToxGroupPacketHeaderSize + length);
    packet.insert(packet.end(), kTim2ToxGroupPacketMagic, kTim2ToxGroupPacketMagic + 4);
    packet.push_back(kTim2ToxGroupPacketVersion);
    packet.push_back(kind);
    if (length > 0) packet.insert(packet.end(), data, data + length);
    return packet;
}

// Returns the payload of a tim2tox group packet of the given kind, or false
// for anything else (foreign packets are ignored, never rendered).
static bool UnwrapTim2ToxGroupPacket(uint8_t kind, const uint8_t* data, size_t length,
                                     const uint8_t** payload, size_t* payload_length) {
    if (data == nullptr || length < kTim2ToxGroupPacketHeaderSize ||
        memcmp(data, kTim2ToxGroupPacketMagic, 4) != 0 ||
        data[4] != kTim2ToxGroupPacketVersion || data[5] != kind) {
        return false;
    }
    *payload = data + kTim2ToxGroupPacketHeaderSize;
    *payload_length = length - kTim2ToxGroupPacketHeaderSize;
    return true;
}

class ReceiverGroupMessageIdOverrideGuard {
public:
    explicit ReceiverGroupMessageIdOverrideGuard(int64_t id)
        : previous_id_(GetReceiverGroupMessageIdOverride()) {
        SetReceiverGroupMessageIdOverride(id);
    }

    ~ReceiverGroupMessageIdOverrideGuard() noexcept {
        SetReceiverGroupMessageIdOverride(previous_id_);
    }

    ReceiverGroupMessageIdOverrideGuard(
        const ReceiverGroupMessageIdOverrideGuard&) = delete;
    ReceiverGroupMessageIdOverrideGuard& operator=(
        const ReceiverGroupMessageIdOverrideGuard&) = delete;

private:
    const int64_t previous_id_;
};

class ReceiverTextKindOverrideGuard {
public:
    explicit ReceiverTextKindOverrideGuard(int kind)
        : previous_kind_(GetReceiverTextKindOverride()) {
        SetReceiverTextKindOverride(kind);
    }

    ~ReceiverTextKindOverrideGuard() noexcept {
        if (previous_kind_ == -1) {
            ClearReceiverTextKindOverride();
        } else {
            SetReceiverTextKindOverride(previous_kind_);
        }
    }

    ReceiverTextKindOverrideGuard(const ReceiverTextKindOverrideGuard&) = delete;
    ReceiverTextKindOverrideGuard& operator=(const ReceiverTextKindOverrideGuard&) = delete;

private:
    int previous_kind_;
};

}

#ifdef BUILD_TOXAV
#include "ToxAVManager.h"
#include "toxav/toxav.h"
#endif

// Forward declaration for FFI functions
// NOTE: All tim2tox_ffi_* functions are defined in extern "C" blocks in tim2tox_ffi.cpp
// They MUST be declared here with extern "C" to avoid C++ name mangling issues
extern "C" {
int tim2tox_ffi_save_friend_nickname(const char* friend_id, const char* nickname);
int tim2tox_ffi_save_friend_status_message(const char* friend_id, const char* status_message);
int tim2tox_ffi_irc_forward_tox_message(const char* group_id, const char* sender, const char* message);
int tim2tox_ffi_set_current_instance(int64_t instance_handle);
// Note: GetCurrentInstanceId is declared above at line 27, not in extern "C" block
}

// Forward declaration for Dart listener (to avoid circular dependency)
class DartFriendshipListenerImpl;
extern DartFriendshipListenerImpl* GetCurrentInstanceFriendshipListener();
extern DartFriendshipListenerImpl* GetFriendshipListenerForManager(V2TIMManagerImpl* manager);
extern DartFriendshipListenerImpl* GetOrCreateFriendshipListenerForInstance(int64_t instance_id);
extern void RegisterFriendshipListenerWithManager(DartFriendshipListenerImpl* listener, V2TIMManagerImpl* manager);
extern void NotifyFriendInfoChangedToListener(DartFriendshipListenerImpl* listener, const void* friendInfoList_ptr);

namespace {
using tim2tox::diag::Event;
using tim2tox::diag::Field;
using tim2tox::diag::StaticText;

template <StaticText Component, StaticText EventName, size_t FieldCount>
void LogEvent(LogLevel level, const Field (&fields)[FieldCount]) {
    V2TIMLog::getInstance().log(level, Event<Component, EventName>{fields, FieldCount});
}

template <StaticText Component, StaticText EventName>
void LogEvent(LogLevel level) {
    V2TIMLog::getInstance().log(level, Event<Component, EventName>{});
}

void NotSupported(V2TIMCallback* callback, const char* api_name) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, api_name);
}
template <typename T>
void NotSupportedValue(V2TIMValueCallback<T>* callback, const char* api_name) {
    if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, api_name);
}
}  // namespace

#ifdef BUILD_TOXAV
static bool IsValidAVConferenceAudioFrame(const int16_t* pcm, uint32_t samples,
                                          uint8_t channels,
                                          uint32_t sample_rate) {
    if (pcm == nullptr || samples == 0 || (channels != 1 && channels != 2)) {
        return false;
    }
    switch (sample_rate) {
        case 8000:
        case 12000:
        case 16000:
        case 24000:
        case 48000:
            break;
        default:
            return false;
    }
    return samples == sample_rate / 400 || samples == sample_rate / 200 ||
           samples == sample_rate / 100 || samples == sample_rate / 50 ||
           samples == sample_rate / 25 || samples == (sample_rate * 3) / 50;
}

// Static callback function for AV conference audio data
// This is called when audio data is received from peers in an AV conference
static void HandleAVConferenceAudio(void* tox_ptr, Tox_Conference_Number conference_number,
                                    Tox_Conference_Peer_Number peer_number,
                                    const int16_t* pcm, uint32_t samples,
                                    uint8_t channels, uint32_t sample_rate,
                                    void* userdata) {
    // userdata points to V2TIMManagerImpl instance
    V2TIMManagerImpl* manager_impl = static_cast<V2TIMManagerImpl*>(userdata);
    if (!manager_impl) {
        return;
    }
    
    V2TIMString groupID;
    if (!manager_impl->GetGroupIDFromGroupNumber(
            ConferenceMapKey(conference_number), groupID) ||
        groupID.Empty() ||
        !IsValidAVConferenceAudioFrame(pcm, samples, channels, sample_rate)) {
        return;
    }
    manager_impl->EnqueueAVConferenceAudioFrame(
        groupID.CString(), conference_number, peer_number, pcm, samples,
        channels, sample_rate);
}
#endif // BUILD_TOXAV

// Forward declaration for helper function to notify friend application list added
// This avoids including the full DartFriendshipListenerImpl definition
extern void NotifyFriendApplicationListAddedToListener(DartFriendshipListenerImpl* listener, const void* applications_ptr);

// Include implementation headers for sub-managers
#include "V2TIMMessageManagerImpl.h"
#include "V2TIMGroupManagerImpl.h"
#include "V2TIMCommunityManagerImpl.h"
#include "V2TIMConversationManagerImpl.h"
#include "V2TIMFriendshipManagerImpl.h"
#include "V2TIMSignalingManagerImpl.h"

// V2TIMManager::GetInstance() 实现，转发到 V2TIMManagerImpl
V2TIMManager* V2TIMManager::GetInstance() {
    return V2TIMManagerImpl::GetInstance();
}

// Default instance (for backward compatibility)
static V2TIMManagerImpl* g_default_instance = nullptr;
static std::mutex g_default_instance_mutex;

V2TIMManagerImpl* V2TIMManagerImpl::GetInstance() {
    std::lock_guard<std::mutex> lock(g_default_instance_mutex);
    if (!g_default_instance) {
        g_default_instance = new V2TIMManagerImpl();
    }
    return g_default_instance;
}

// Process-global default test_mode flag. New V2TIMManagerImpl instances
// inherit this in their constructor, so tim2tox_ffi_set_default_test_mode(1)
// can be called BEFORE the test creates any instance to ensure event_thread
// is never spawned by InitSDK.
std::atomic<bool> g_default_test_mode{false};

// Constructor (now public for multi-instance support)
V2TIMManagerImpl::V2TIMManagerImpl()
#ifdef BUILD_TOXAV
    : toxav_manager_(nullptr, &ToxAVManager::Destroy), running_(true), next_group_id_counter_(0)
#else
    : running_(true), next_group_id_counter_(0)
#endif
{
    // running_ is initialized to true via member initializer list (atomic)
    // tox_manager_ will be created in InitSDK
    // Inherit process-global default test_mode (set by FFI before instance creation).
    test_mode_.store(g_default_test_mode.load(std::memory_order_acquire),
                     std::memory_order_release);
}

V2TIMManagerImpl::~V2TIMManagerImpl() {
    ClearPendingDeliveries();
#ifdef BUILD_TOXAV
    ClearAVConferenceAudioCallback();
#endif
    // Stop background tasks first so no detach'd thread holds raw this
    try {
        StopBackgroundTasks();
    } catch (...) {
    }
    // Signal event thread to stop and join it without busy-wait polling.
    try {
        running_.store(false, std::memory_order_release);
        task_cv_.notify_all();
        if (event_thread_.joinable()) {
            event_thread_.join();
        }
    } catch (const std::system_error&) {
        // Thread may have already exited or mutex is invalid - ignore.
    } catch (...) {
        // Swallow any exception at process exit.
    }
}

void V2TIMManagerImpl::StopBackgroundTasks() {
    refresh_stop_requested_.store(true, std::memory_order_release);
    rejoin_stop_requested_.store(true, std::memory_order_release);
    if (refresh_task_.joinable()) {
        refresh_task_.join();
    }
    refresh_task_running_.store(false, std::memory_order_release);
    if (rejoin_task_.joinable()) {
        rejoin_task_.join();
    }
}

// SDK Listener methods
void V2TIMManagerImpl::AddSDKListener(V2TIMSDKListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    sdk_listeners_.insert(listener);
}

void V2TIMManagerImpl::RemoveSDKListener(V2TIMSDKListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    sdk_listeners_.erase(listener);
}

size_t V2TIMManagerImpl::DebugSDKListenerCountForTest() {
    std::lock_guard<std::mutex> lock(mutex_);
    return sdk_listeners_.size();
}

// SDK initialization and shutdown
bool V2TIMManagerImpl::InitSDK(uint32_t sdkAppID, const V2TIMSDKConfig& config) {
    int64_t this_instance_id = GetInstanceIdFromManager(this);
    if (tox_manager_) {
        return true;
    }
    // An UnInitSDK that ran ON the event thread could not join it (see there);
    // that loop has exited or is exiting. Reap it before a new one is assigned
    // (assigning over a joinable std::thread calls std::terminate).
    if (event_thread_.joinable()) {
        if (event_thread_.get_id() == std::this_thread::get_id()) {
            V2TIM_LOG(kError, "[InitSDK] refused: called on the previous session's event thread");
            return false;
        }
        event_thread_.join();
    }
    // A new session starts here, before anything below can emit a
    // DartNotifyGroup* (profile restore, rejoin and the tox callbacks all run
    // after this point), so every notification of this session carries it.
    session_epoch_.store(++g_next_session_epoch, std::memory_order_release);

    V2TIM_LOG(kInfo, "[InitSDK] creating new ToxManager instance for this={} (instance_id={})",
              (void*)this, (long long)this_instance_id);
    {
        // Published under tox_manager_mutex_ so AcquireToxSession() on another
        // thread either sees no session or sees a fully constructed one.
        std::lock_guard<std::mutex> manager_lock(tox_manager_mutex_);
        tox_manager_ = std::make_shared<ToxManager>();
    }
    // Only the default/session instance may run the harness TCP relay server on
    // its fixed port; an auxiliary instance that tried would fail tox_new with
    // TOX_ERR_NEW_PORT_ALLOC and never come up at all.
    tox_manager_->setTcpRelayServerAllowed(this_instance_id == 0);
    // A creator may pin the UDP bind range (LAN bootstrap node honouring the
    // user's port). Applied on the ToxManager rather than on the Tox_Options
    // built below because loadFrom() builds its own options on profile reload.
    {
        int udp_start = 0;
        int udp_end = 0;
        if (this_instance_id > 0 && GetTestInstanceUdpPortRange(this_instance_id, &udp_start, &udp_end)) {
            tox_manager_->setUdpPortRange(static_cast<uint16_t>(udp_start), static_cast<uint16_t>(udp_end));
            V2TIM_LOG(kInfo, "[InitSDK] instance_id={} UDP port range pinned to {}..{}",
                      (long long)this_instance_id, udp_start, udp_end);
        }
    }
    V2TIM_LOG(kInfo, "[InitSDK] Created ToxManager={} for this={} (instance_id={})",
              (void*)tox_manager_.get(), (void*)this, (long long)this_instance_id);
#ifdef BUILD_TOXAV
    toxav_manager_.reset(new ToxAVManager());
    V2TIM_LOG(kInfo, "[InitSDK] Created ToxAVManager={} for this={} (instance_id={})",
              (void*)toxav_manager_.get(), (void*)this, (long long)this_instance_id);
#endif
    V2TIM_LOG(kInfo, "[InitSDK] Step 1: Computing save path...");
    // Compute save path using config.initPath if provided; otherwise platform default
    std::filesystem::path save_dir = config.initPath.Empty()
        ? tim2tox::path::GetDefaultDataDir()
        : std::filesystem::path(config.initPath.CString());
    V2TIM_LOG(kInfo, "[InitSDK] Using data dir: {}", save_dir.string());

    std::string mkdir_err;
    if (!tim2tox::path::EnsureDirectoryExists(save_dir, &mkdir_err)) {
        V2TIM_LOG(kError, "[InitSDK] Failed to create data dir: {}", mkdir_err);
        return false;
    }

    int64_t instance_id = GetInstanceIdFromManager(this);
    std::string save_path = tim2tox::path::BuildProfilePath(save_dir, instance_id).string();
    V2TIM_LOG(kInfo, "[InitSDK] Save path: {}", save_path);
    save_path_ = save_path;

    V2TIM_LOG(kInfo, "[InitSDK] Step 4: Checking for saved profile...");
    bool loaded = false;
    {
        std::ifstream f(save_path, std::ios::binary);
        loaded = f.good();
        V2TIM_LOG(kInfo, "[InitSDK] Profile loaded check: {}", loaded ? "true" : "false");
    }
    // Test-instance reload fallback: when auto_tests do unInitSDK/initSDK in
    // sequence, the new test instance gets a fresh instance_id, so the
    // BuildProfilePath above yields a `tox_profile_<new_id>.tox` path that
    // doesn't exist on disk. The previous instance saved its profile under
    // `tox_profile_<old_id>.tox` in the same directory. Tests use one
    // instance per init_path (per-userId subdir), so we can safely fall back
    // to *any* `tox_profile_*.tox` in the directory. Production (instance_id
    // 0 with the stable `tox_profile.tox` name) never enters this branch.
    if (!loaded && instance_id != 0) {
        try {
            std::filesystem::path dir(save_dir);
            std::error_code ec;
            std::filesystem::path fallback;
            std::filesystem::directory_iterator it(dir, ec);
            if (!ec) {
                for (const auto& entry : it) {
                    const auto& p = entry.path();
                    const auto fn = p.filename().string();
                    if (fn.rfind("tox_profile", 0) == 0 &&
                        p.extension() == ".tox" &&
                        fn.find(".corrupted") == std::string::npos) {
                        fallback = p;
                        break;
                    }
                }
            }
            if (!fallback.empty()) {
                V2TIM_LOG(kInfo,
                    "[InitSDK] Reload fallback: instance-id-keyed profile missing; loading sibling {}",
                    fallback.string());
                save_path = fallback.string();
                save_path_ = save_path;
                std::ifstream f2(save_path, std::ios::binary);
                loaded = f2.good();
            }
        } catch (const std::exception& e) {
            V2TIM_LOG(kWarning, "[InitSDK] Reload fallback failed: {}", e.what());
        }
    }
    V2TIM_LOG(kInfo, "[InitSDK] Step 5: Getting test instance options...");
    V2TIM_LOG(kInfo, "[InitSDK] About to call GetTestInstanceOptions with instance_id={}", (long long)this_instance_id);
    int local_discovery = 1;
    int ipv6 = 1;
    bool has_options = GetTestInstanceOptions(this_instance_id, &local_discovery, &ipv6);
    V2TIM_LOG(kInfo, "[InitSDK] GetTestInstanceOptions returned: has_options={}, local_discovery={}, ipv6={}",
              has_options ? "true" : "false", local_discovery, ipv6);
    V2TIM_LOG(kInfo, "[InitSDK] Test options: has_options={}, local_discovery={}, ipv6={}",
              has_options ? "true" : "false", local_discovery, ipv6);

    V2TIM_LOG(kInfo, "[InitSDK] Step 6: Creating Tox_Options...");
    Tox_Options* tox_options = nullptr;
    Tox_Err_Options_New opt_err;
    V2TIM_LOG(kInfo, "[InitSDK] About to call tox_options_new...");
    tox_options = tox_options_new(&opt_err);
    V2TIM_LOG(kInfo, "[InitSDK] tox_options_new returned: options={}, err={}", (void*)tox_options, opt_err);
    if (tox_options && opt_err == TOX_ERR_OPTIONS_NEW_OK) {
        tox_options_default(tox_options);
        tox_options_set_udp_enabled(tox_options, true);
        tox_options_set_hole_punching_enabled(tox_options, true);
        tox_options_set_local_discovery_enabled(tox_options, has_options ? (local_discovery != 0) : true);
        tox_options_set_dht_announcements_enabled(tox_options, true);
        tox_options_set_ipv6_enabled(tox_options, has_options ? (ipv6 != 0) : true);
        V2TIM_LOG(kInfo, "[InitSDK] Using tox options: udp_enabled=1, hole_punching_enabled=1, local_discovery_enabled={}, dht_announcements_enabled=1, ipv6_enabled={}",
                  has_options ? local_discovery : 1, has_options ? ipv6 : 1);
    } else {
        V2TIM_LOG(kError, "[InitSDK] Failed to create Tox_Options, using defaults");
        tox_options = nullptr;
    }

    V2TIM_LOG(kInfo, "[InitSDK] Step 7: Checking loaded status...");
    
    // CRITICAL: Set running_ flag BEFORE calling tox_manager_->initialize()
    // This ensures that connection status callbacks triggered during initialization
    // can be properly handled (they check IsRunning() before processing)
    // Note: We set it early to handle callbacks that may be triggered during initialize()
    running_.store(true, std::memory_order_release);
    // Register group message callbacks BEFORE initialize/loadFrom so ToxManager::initialize()
    // can register them on the new tox instance. Otherwise group_private_message may never fire.
    tox_manager_->setGroupMessageGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id) {
            this->HandleGroupMessageGroup(group_number, peer_id, type, message, length, message_id);
        }
    );
    tox_manager_->setGroupCustomPacketCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* data, size_t length) {
            this->HandleGroupCustomPacket(group_number, peer_id, data, length);
        }
    );
    tox_manager_->setGroupCustomPrivatePacketCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* data, size_t length) {
            this->HandleGroupCustomPrivatePacket(group_number, peer_id, data, length);
        }
    );
    tox_manager_->setGroupPrivateMessageGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id) {
            this->HandleGroupPrivateMessage(group_number, peer_id, type, message, length, message_id);
        }
    );
    
    if (loaded) {
        V2TIM_LOG(kInfo, "[InitSDK] Profile exists, loading from {}", save_path);
        if (!tox_manager_->loadFrom(save_path)) {
            V2TIM_LOG(kWarning, "[InitSDK] Profile load failed (encrypted or corrupted), creating new profile and backing up old file");
            std::string backup_path = save_path + ".corrupted";
            if (std::rename(save_path.c_str(), backup_path.c_str()) == 0) {
                V2TIM_LOG(kInfo, "[InitSDK] Backed up unloadable profile to {}", backup_path);
            } else {
                V2TIM_LOG(kWarning, "[InitSDK] Could not rename profile to backup, new profile will overwrite");
            }
            try {
                tox_manager_->initialize(tox_options);
                tox_manager_->saveTo(save_path);
            } catch (const std::runtime_error& e) {
                V2TIM_LOG(kError, "InitSDK: Tox initialization failed - {}", e.what());
                if (tox_options) tox_options_free(tox_options);
                return false;
            }
        }
    } else {
        try {
            tox_manager_->initialize(tox_options);
            tox_manager_->saveTo(save_path);
        } catch (const std::runtime_error& e) {
            V2TIM_LOG(kError, "InitSDK: Tox initialization failed - {}", e.what());
            if (tox_options) tox_options_free(tox_options);
            return false;
        }
    }

    if (tox_options) {
        tox_options_free(tox_options);
        tox_options = nullptr;
    }
    if (tox_options) {
        tox_options_free(tox_options);
    }
    V2TIM_LOG(kInfo, "InitSDK: after initialize");
    Tox* tox = tox_manager_->getTox();
    if (!tox) {
        V2TIM_LOG(kError, "InitSDK: tox is null");
        return false;
    }

    // Test-mode hook: route mono_time off the virtual clock owned by tim2tox_ffi.cpp.
    // No-op for production callers (test_mode_ defaults to false).
    if (test_mode_.load(std::memory_order_acquire)) {
        if (tox->mono_time) {
            mono_time_set_current_time_callback(tox->mono_time, &tim2tox_virtual_time_cb, nullptr);
            static_cast<void>(0);
            static_cast<void>(0);
        } else {
            static_cast<void>(0);
            static_cast<void>(0);
        }
    }

    tox_manager_->setGroupMessageGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id) {
            this->HandleGroupMessageGroup(group_number, peer_id, type, message, length, message_id);
        }
    );
    tox_manager_->setGroupCustomPacketCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* data, size_t length) {
            this->HandleGroupCustomPacket(group_number, peer_id, data, length);
        }
    );
    tox_manager_->setGroupCustomPrivatePacketCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* data, size_t length) {
            this->HandleGroupCustomPrivatePacket(group_number, peer_id, data, length);
        }
    );
    tox_manager_->setGroupPrivateMessageGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id) {
            this->HandleGroupPrivateMessage(group_number, peer_id, type, message, length, message_id);
        }
    );
    static_cast<void>(0);
    static_cast<void>(0);
    tox_manager_->setGroupTopicCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* topic, size_t length) {
            this->HandleGroupTopic(group_number, peer_id, topic, length);
        }
    );
    tox_manager_->setGroupPeerNameGroupCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* name, size_t length) {
            this->HandleGroupPeerNameGroup(group_number, peer_id, name, length);
        }
    );
    static_cast<void>(0);
    static_cast<void>(0);
    tox_manager_->setGroupPeerJoinCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id) {
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            this->HandleGroupPeerJoin(group_number, peer_id);
        }
    );
    static_cast<void>(0);
    static_cast<void>(0);
    tox_manager_->setGroupPeerExitCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, Tox_Group_Exit_Type exit_type, const uint8_t* name, size_t name_length) {
            this->HandleGroupPeerExit(group_number, peer_id, exit_type, name, name_length);
        }
    );
    tox_manager_->setGroupModerationCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number source_peer_id, Tox_Group_Peer_Number target_peer_id, Tox_Group_Mod_Event mod_type) {
            this->HandleGroupModeration(group_number, source_peer_id, target_peer_id, mod_type);
        }
    );
    // CRITICAL: Before registering callbacks, query existing groups and conferences from Tox
    // and manually trigger HandleGroupSelfJoin/HandleConferenceSelfJoin for each to rebuild mappings.
    // This is necessary because callbacks are NOT triggered for groups/conferences
    // that are restored from savedata - they only trigger for newly joined ones.
    // By manually querying and processing existing groups/conferences, we ensure mappings are
    // rebuilt immediately after Tox initialization.
    {
        Tox* tox = tox_manager_->getTox();
        if (tox) {
            // Restore groups (new API)
            size_t group_count = tox_manager_->getGroupListSize();
            if (group_count > 0) {
                std::vector<Tox_Group_Number> group_list(group_count);
                tox_manager_->getGroupList(group_list.data(), group_count);
                for (Tox_Group_Number group_number : group_list) {
                    this->HandleGroupSelfJoin(group_number);
                }
            }
            // Restore conferences (old API) - they are automatically restored from savedata
            (void)tox_conference_get_chatlist_size(tox);
            // Conference mappings will be rebuilt in RejoinKnownGroups when known groups are synced
        }
    }
    
    // Register callback for future group joins (new groups will trigger this callback)
    tox_manager_->setGroupSelfJoinCallback(
        [this](Tox_Group_Number group_number) {
            {
                // toxcore's own self-join: we are really in. From here on a
                // rejection is a failed RE-join (the manual HandleGroupSelfJoin
                // calls right after a join/accept must not clear this).
                std::lock_guard<std::mutex> lock(mutex_);
                fresh_group_joins_.erase(group_number);
                accepted_invites_.erase(group_number);
            }
            this->HandleGroupSelfJoin(group_number);
            // Really in: tell online friends which member we are here (MM-6).
            this->AnnounceGroupIdentities(UINT32_MAX, group_number);
        }
    );
    tox_manager_->setGroupJoinFailCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type) {
            this->HandleGroupJoinFail(group_number, fail_type);
        }
    );
    tox_manager_->setGroupPrivacyStateCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Privacy_State privacy_state) {
            this->HandleGroupPrivacyState(group_number, privacy_state);
        }
    );
    tox_manager_->setGroupVoiceStateCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Voice_State voice_state) {
            this->HandleGroupVoiceState(group_number, voice_state);
        }
    );
    tox_manager_->setGroupPeerStatusCallback(
        [this](Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_USER_STATUS status) {
            this->HandleGroupPeerStatus(group_number, peer_id, status);
        }
    );
    
    // Register group invite handling: automatically accept invite and join group
    // NOTE: Register both new group API and old conference API for compatibility
    // Register new group API callback (tox_callback_group_invite)
    tox_manager_->setGroupInviteGroupCallback(
        [this](Tox_Friend_Number friend_number, const uint8_t* invite_data, size_t invite_data_length, const std::string& invited_group_name) {
            V2TIM_LOG(kInfo, "[GroupInvite] ========== Received group invite ==========");
            V2TIM_LOG(kInfo, "[GroupInvite] friend_number={}, invite_data_length={}", friend_number, invite_data_length);
            
            // Log a redacted prefix of invite_data for debugging (avoid leaking the full invite bytes)
            if (invite_data && invite_data_length > 0) {
                std::ostringstream invite_hex;
                size_t bytes_to_log = std::min(invite_data_length, static_cast<size_t>(4));
                for (size_t i = 0; i < bytes_to_log; ++i) {
                    invite_hex << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(invite_data[i]);
                }
                V2TIM_LOG(kInfo, "[GroupInvite] invite_data (first 8 hex chars): {}…", invite_hex.str().substr(0, 8));
            }
            
            // Get inviter's public key for onMemberInvited callback
            std::string inviterUserID;
            Tox* tox_for_inviter = GetToxManager()->getTox();
            if (tox_for_inviter) {
                uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox_friend_get_public_key(tox_for_inviter, friend_number, inviter_pubkey, nullptr)) {
                    inviterUserID = ToxUtil::tox_bytes_to_hex(inviter_pubkey, TOX_PUBLIC_KEY_SIZE);
                    V2TIM_LOG(kInfo, "[GroupInvite] Got inviter public key: {}… (length={})", inviterUserID.substr(0, 8), inviterUserID.length());
                } else {
                    V2TIM_LOG(kWarning, "[GroupInvite] Failed to get inviter public key for friend_number={}", friend_number);
                }
            }
            
            // Generate a temporary groupID for this invite (before accepting)
            char gid[64];
            auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            snprintf(gid, sizeof(gid), "tox_inv_%u_%llu", friend_number, (unsigned long long)now_ms);
            V2TIMString tempGroupID(gid);
            
            // When auto-accept is disabled: store pending BEFORE notifying listeners, so that when
            // Dart's waitForCallback('onGroupInvited') returns and the test calls joinGroup, the
            // pending is already present on this instance (avoids 6017 "Pending invite not found").
            bool auto_accept_enabled = GetAutoAcceptGroupInvites();
            V2TIM_LOG(kInfo, "[GroupInvite] Auto-accept group invites setting: {}", auto_accept_enabled);
            if (!auto_accept_enabled) {
                V2TIM_LOG(kInfo, "[GroupInvite] Auto-accept is disabled, storing as pending invite before notifying");
                PendingInvite inv;
                inv.friend_number = friend_number;
                inv.cookie.assign(invite_data, invite_data + invite_data_length);
                inv.group_number = UINT32_MAX;  // Not yet accepted
                inv.inviter_userID = inviterUserID;
                inv.group_name = invited_group_name;
                inv.received_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::system_clock::now().time_since_epoch()).count();
                const V2TIMString stored_as = StorePendingInvite(tempGroupID, std::move(inv));
                if (stored_as != tempGroupID) {
                    // Same friend re-sent the same invite: keep the one prompt.
                    V2TIM_LOG(kInfo, "[GroupInvite] Duplicate of pending invite {}; refreshed", stored_as.CString());
                    DartNotifyGroupInvite(stored_as.CString(), GetInstanceIdFromManager(this), GetSessionEpoch());
                    return;
                }
                V2TIM_LOG(kInfo, "[GroupInvite] Stored pending group invite as ID {} for manual join later", gid);
                // The product's group listeners never see OnMemberInvited (UIKit's
                // self-match compares a 64-hex key with the 76-hex login id), so
                // without this an invite with auto-accept off was invisible: no
                // row, no badge, nothing to accept. Tell the Dart layer directly.
                DartNotifyGroupInvite(gid, GetInstanceIdFromManager(this), GetSessionEpoch());
            }
            
            // Trigger onMemberInvited callback when invite is received (after pending is stored when !auto_accept)
            // This notifies listeners that we received an invitation
            // Note: We use temporary groupID here, and will trigger again with actual groupID in HandleGroupSelfJoin
            if (!inviterUserID.empty()) {
                V2TIM_LOG(kInfo, "[GroupInvite] Triggering onMemberInvited callback immediately: tempGroupID={}, inviter={}…", gid, inviterUserID.substr(0, 8));
                
                // Build member list (contains self, as we are being invited)
                V2TIMGroupMemberInfoVector memberList;
                V2TIMGroupMemberInfo selfMember;
                // Get self public key
                uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox_for_inviter) {
                    tox_self_get_public_key(tox_for_inviter, self_pubkey);
                    std::string selfUserID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                    selfMember.userID = V2TIMString(selfUserID.c_str());
                    memberList.PushBack(selfMember);
                    V2TIM_LOG(kInfo, "[GroupInvite] Added self to member list: {}…", selfUserID.substr(0, 8));
                }
                
                // Build opUser (inviter)
                V2TIMGroupMemberInfo opUser;
                opUser.userID = V2TIMString(inviterUserID.c_str());
                
                // Notify group listeners with temporary groupID
                std::vector<V2TIMGroupListener*> listeners_copy;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
                }
                
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        V2TIM_LOG(kInfo, "[GroupInvite] Calling OnMemberInvited immediately: tempGroupID={}, inviter={}…, memberCount={}",
                                 gid, inviterUserID.substr(0, 8), memberList.Size());
                        listener->OnMemberInvited(tempGroupID, opUser, memberList);
                    }
                }
            }
            
            // If auto-accept is disabled, we already stored pending and notified; nothing more to do.
            if (!auto_accept_enabled) {
                return;
            }
            
            Tox* tox = GetToxManager()->getTox();
            if (!tox) {
                V2TIM_LOG(kError, "[GroupInvite] ERROR: Tox instance not available, cannot accept invite");
                return;
            }
            V2TIM_LOG(kInfo, "[GroupInvite] Tox instance available, proceeding with auto-accept");
            // tempGroupID already generated above
            V2TIM_LOG(kInfo, "[GroupInvite] Using temporary groupID: {}", gid);
            
            // Accept invite using tox_group_invite_accept
            std::string self_name = GetToxManager()->getName();
            if (self_name.empty()) {
                self_name = "User";
            }
            V2TIM_LOG(kInfo, "[GroupInvite] Using self_name: {} (length={})", self_name, self_name.length());
            
            V2TIM_LOG(kInfo, "[GroupInvite] Calling tox_group_invite_accept: friend_number={}, invite_data_length={}, self_name_length={}", 
                     friend_number, invite_data_length, self_name.length());
            
            Tox_Err_Group_Invite_Accept err_accept;
            Tox_Group_Number group_number = tox_group_invite_accept(
                tox,
                friend_number,
                invite_data, invite_data_length,
                reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
                nullptr, 0, // No password
                &err_accept
            );
            
            V2TIM_LOG(kInfo, "[GroupInvite] tox_group_invite_accept returned: group_number={}, err_accept={}", 
                     group_number, static_cast<int>(err_accept));
            
            if (err_accept != TOX_ERR_GROUP_INVITE_ACCEPT_OK || group_number == UINT32_MAX) {
                V2TIM_LOG(kError, "[GroupInvite] FAILED to accept group invite");
                V2TIM_LOG(kError, "[GroupInvite] Error code: {} (0=OK, 1=BAD_INVITE, 2=INIT_FAILED, 3=TOO_LONG, 4=EMPTY, 5=PASSWORD, 6=FRIEND_NOT_FOUND, 7=FAIL_SEND, 8=NULL)", 
                         static_cast<int>(err_accept));
                V2TIM_LOG(kError, "[GroupInvite] group_number={} (UINT32_MAX={})", group_number, UINT32_MAX);
                
                // Store as pending invite for manual join later
                PendingInvite inv;
                inv.friend_number = friend_number;
                inv.cookie.assign(invite_data, invite_data + invite_data_length);
                inv.group_number = UINT32_MAX;  // Not yet accepted
                inv.inviter_userID = inviterUserID;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[tempGroupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite] Stored pending group invite as ID {} for manual join later", gid);
                V2TIM_LOG(kInfo, "[GroupInvite] Pending invite stored: friend_number={}, cookie_size={}", 
                         inv.friend_number, inv.cookie.size());
                return;
            }
            
            V2TIM_LOG(kInfo, "[GroupInvite] ✅ Successfully accepted group invite");
            V2TIM_LOG(kInfo, "[GroupInvite] group_number={}, tempGroupID={}", group_number, gid);
            MarkFreshGroupJoin(group_number);
            
            // Store temporary group mapping (will be updated to actual groupID in HandleGroupSelfJoin)
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_group_number_[tempGroupID] = group_number;
                group_number_to_group_id_[group_number] = tempGroupID;
                
                // Update pending invite with group_number
                auto it = pending_group_invites_.find(tempGroupID);
                if (it != pending_group_invites_.end()) {
                    it->second.group_number = group_number;
                    V2TIM_LOG(kInfo, "[GroupInvite] Updated pending invite with group_number={}", group_number);
                } else {
                    // Create new pending invite entry
                    PendingInvite inv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(invite_data, invite_data + invite_data_length);
                    inv.group_number = group_number;
                    inv.inviter_userID = inviterUserID;
                    pending_group_invites_[tempGroupID] = std::move(inv);
                    V2TIM_LOG(kInfo, "[GroupInvite] Created pending invite entry with group_number={}", group_number);
                }
                
                accepted_invites_[group_number] = {tempGroupID.CString(), pending_group_invites_[tempGroupID]};
                V2TIM_LOG(kInfo, "[GroupInvite] Stored temporary group mapping: tempGroupID={} <-> group_number={}", gid, group_number);
                V2TIM_LOG(kInfo, "[GroupInvite] Total groups in mapping: {}", group_id_to_group_number_.size());
            }
            
            // Get chat_id and store it for persistence
            V2TIM_LOG(kInfo, "[GroupInvite] Attempting to get chat_id for group_number={}", group_number);
            uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
            Tox_Err_Group_State_Query err_chat_id;
            bool got_chat_id = GetToxManager()->getGroupChatId(group_number, chat_id, &err_chat_id);
            V2TIM_LOG(kInfo, "[GroupInvite] getGroupChatId returned: got_chat_id={}, err_chat_id={}", 
                     got_chat_id, static_cast<int>(err_chat_id));
            
            if (got_chat_id && err_chat_id == TOX_ERR_GROUP_STATE_QUERY_OK) {
                // Convert to hex string
                std::ostringstream oss;
                for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                    oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
                }
                std::string chat_id_hex = oss.str();
                V2TIM_LOG(kInfo, "[GroupInvite] Retrieved chat_id (hex): {} (length={})", chat_id_hex, chat_id_hex.length());
                
                V2TIMString canonicalGroupID;
                bool has_canonical_group_id = false;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    canonicalGroupID = CanonicalGroupIDForChatIdLocked(tempGroupID, chat_id_hex);
                    if (!IsTemporaryInviteGroupID(canonicalGroupID)) {
                        has_canonical_group_id = true;
                        group_id_to_group_number_[canonicalGroupID] = group_number;
                        group_number_to_group_id_[group_number] = canonicalGroupID;
                        group_id_to_chat_id_[canonicalGroupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                        chat_id_to_group_id_[chat_id_hex] = canonicalGroupID;
                        V2TIM_LOG(kInfo, "[GroupInvite] Stored canonical chat_id mapping: groupID={} <-> chat_id={}", canonicalGroupID.CString(), chat_id_hex);
                    } else {
                        V2TIM_LOG(kInfo, "[GroupInvite] Kept temporary invite ID {} as group_number lookup alias only", gid);
                    }
                    V2TIM_LOG(kInfo, "[GroupInvite] Total chat_id mappings: {}", group_id_to_chat_id_.size());
                }
                if (has_canonical_group_id) {
                    SetGroupChatIdInStorage(canonicalGroupID.CString(), chat_id_hex);
                    V2TIM_LOG(kInfo, "[GroupInvite] Persisted canonical chat_id for auto-joined group {}: {}", canonicalGroupID.CString(), chat_id_hex);
                }
            } else {
                V2TIM_LOG(kWarning, "[GroupInvite] ⚠️ Failed to get chat_id for group_number={}", group_number);
                V2TIM_LOG(kWarning, "[GroupInvite] Error details: got_chat_id={}, err_chat_id={} (0=OK, 1=GROUP_NOT_FOUND, 2=INVALID_POINTER)", 
                         got_chat_id, static_cast<int>(err_chat_id));
                V2TIM_LOG(kWarning, "[GroupInvite] chat_id will be retrieved later when group is fully connected");
            }
            
            // HandleGroupSelfJoin will be triggered by Tox callback when group is fully joined
            // This will notify listeners about the new group
            V2TIM_LOG(kInfo, "[GroupInvite] Group invite accepted successfully, HandleGroupSelfJoin will be triggered when group is fully joined");
            V2TIM_LOG(kInfo, "[GroupInvite] ========== Group invite processing completed ==========");
        }
    );
    
    // Also register old conference API callback for backward compatibility
    // Some clients may still use tox_conference_invite (old API)
    tox_manager_->setGroupInviteCallback(
        [this](uint32_t friend_number, TOX_CONFERENCE_TYPE type, const uint8_t* cookie, size_t length) {
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== Received conference invite (old API) ==========");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] friend_number={}, cookie_length={}", friend_number, length);
            
            // Detailed type analysis
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== TOX_CONFERENCE_TYPE ANALYSIS ==========");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Raw type value: {} (as int)", static_cast<int>(type));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] TOX_CONFERENCE_TYPE_TEXT enum value: {} (as int)", static_cast<int>(TOX_CONFERENCE_TYPE_TEXT));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] TOX_CONFERENCE_TYPE_AV enum value: {} (as int)", static_cast<int>(TOX_CONFERENCE_TYPE_AV));
            
            // Check conference type with detailed comparison
            const char* type_name = "UNKNOWN";
            bool is_text = (type == TOX_CONFERENCE_TYPE_TEXT);
            bool is_av = (type == TOX_CONFERENCE_TYPE_AV);
            
            if (is_text) {
                type_name = "TEXT";
            } else if (is_av) {
                type_name = "AV";
            }
            
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Type comparison results:");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   type == TOX_CONFERENCE_TYPE_TEXT ? {}", is_text ? "YES" : "NO");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   type == TOX_CONFERENCE_TYPE_AV ? {}", is_av ? "YES" : "NO");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Determined type: {} (value={})", type_name, static_cast<int>(type));
            
            // Also check cookie type byte for comparison
            if (length > 2) {
                uint8_t cookie_type_byte = cookie[2];
                const char* cookie_type_name = (cookie_type_byte == 0) ? "TEXT (GROUPCHAT_TYPE_TEXT)" : 
                                               (cookie_type_byte == 1) ? "AV (GROUPCHAT_TYPE_AV)" : "UNKNOWN";
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie type byte (offset 2): {} ({})", 
                         static_cast<int>(cookie_type_byte), cookie_type_name);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Type consistency check: callback type={} ({}), cookie type={} ({})", 
                         static_cast<int>(type), type_name, 
                         static_cast<int>(cookie_type_byte), cookie_type_name);
                
                if (static_cast<int>(type) != static_cast<int>(cookie_type_byte)) {
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] WARNING: Type mismatch! Callback type ({}) != cookie type byte ({})", 
                             static_cast<int>(type), static_cast<int>(cookie_type_byte));
                } else {
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Type consistency: callback type matches cookie type byte");
                }
            }
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] =================================================");
            
            Tox* tox = GetToxManager()->getTox();
            if (!tox) {
                V2TIM_LOG(kError, "[GroupInvite-Conference] ERROR: Tox instance not available, cannot join conference");
                return;
            }
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Tox instance available, proceeding with auto-join");
            
            // Generate a temporary groupID for this invite
            char gid[64];
            auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            snprintf(gid, sizeof(gid), "tox_conf_%u_%llu", friend_number, (unsigned long long)now_ms);
            V2TIMString groupID(gid);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Generated groupID: {}", gid);
            
            // Notify UI: trigger OnMemberInvited so the interface can show "XXX invited you to the group"
            // (Text group path always does this; conference path was missing it, so invite had no notification.)
            std::string inviterUserID;
            if (tox) {
                uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox_friend_get_public_key(tox, friend_number, inviter_pubkey, nullptr)) {
                    inviterUserID = ToxUtil::tox_bytes_to_hex(inviter_pubkey, TOX_PUBLIC_KEY_SIZE);
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Got inviter public key: {}… (length={})", inviterUserID.substr(0, 8), inviterUserID.length());
                } else {
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] Failed to get inviter public key for friend_number={}", friend_number);
                }
            }
            if (!inviterUserID.empty()) {
                V2TIMGroupMemberInfoVector memberList;
                V2TIMGroupMemberInfo selfMember;
                uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                if (tox) {
                    tox_self_get_public_key(tox, self_pubkey);
                    std::string selfUserID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                    selfMember.userID = V2TIMString(selfUserID.c_str());
                    memberList.PushBack(selfMember);
                }
                V2TIMGroupMemberInfo opUser;
                opUser.userID = V2TIMString(inviterUserID.c_str());
                std::vector<V2TIMGroupListener*> listeners_copy;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
                }
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        V2TIM_LOG(kInfo, "[GroupInvite-Conference] Triggering OnMemberInvited: tempGroupID={}, inviter={}…, memberCount={}",
                                 gid, inviterUserID.substr(0, 8), memberList.Size());
                        listener->OnMemberInvited(groupID, opUser, memberList);
                    }
                }
            }
            
            // Honor "auto-accept group invites". This handler used to join
            // unconditionally — the setting was only consulted on the NGC path —
            // so any friend (e.g. on qTox) could pull a user who had it OFF into
            // a conference, and for an AV conference toxcore started decoding
            // every peer's audio right away. Park the invite instead; JoinGroup
            // redeems kConferenceText / kConferenceAv entries.
            if (!GetAutoAcceptGroupInvites()) {
                PendingInvite inv;
                inv.kind = (type == TOX_CONFERENCE_TYPE_AV)
                    ? PendingInviteKind::kConferenceAv
                    : PendingInviteKind::kConferenceText;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                inv.group_number = UINT32_MAX;
                inv.inviter_userID = inviterUserID;
                inv.received_ms = now_ms;
                const V2TIMString stored_as = StorePendingInvite(groupID, std::move(inv));
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Auto-accept is off; stored pending {} invite as {}", type_name, stored_as.CString());
                DartNotifyGroupInvite(stored_as.CString(), GetInstanceIdFromManager(this), GetSessionEpoch());
                return;
            }

            // Handle AV type conference (requires toxav support)
            if (type == TOX_CONFERENCE_TYPE_AV) {
#ifdef BUILD_TOXAV
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Received AV type conference invite, attempting to join");
                
                // Get ToxAVManager instance
                ToxAVManager* av_mgr = GetToxAVManager();
                if (!av_mgr) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Failed to get ToxAVManager instance");
                    // Store as pending invite
                    PendingInvite inv;
                    inv.kind = PendingInviteKind::kConferenceAv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(cookie, cookie + length);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_group_invites_[groupID] = std::move(inv);
                    }
                    return;
                }
                
                // Ensure ToxAV is initialized (pass this so ToxAVManager does not call GetCurrentInstance() again)
                bool toxav_ready = false;
                try {
                    av_mgr->initialize(this);
                    toxav_ready = true;
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] ToxAV initialized successfully");
                } catch (const std::runtime_error& e) {
                    // Check if the error is because it's already initialized
                    std::string error_msg = e.what();
                    if (error_msg.find("already initialized") != std::string::npos) {
                        toxav_ready = true;
                        V2TIM_LOG(kInfo, "[GroupInvite-Conference] ToxAV already initialized");
                    } else {
                        V2TIM_LOG(kError, "[GroupInvite-Conference] ToxAV initialization failed: {}", error_msg);
                    }
                } catch (const std::exception& e) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ToxAV initialization exception: {}", e.what());
                }
                
                if (!toxav_ready) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ToxAV is not ready, cannot join AV conference");
                    // Store as pending invite
                    PendingInvite inv;
                    inv.kind = PendingInviteKind::kConferenceAv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(cookie, cookie + length);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_group_invites_[groupID] = std::move(inv);
                    }
                    return;
                }
                
                // Get Tox instance
                Tox* tox = tox_manager_->getTox();
                if (!tox) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Tox instance is null, cannot join AV conference");
                    // Store as pending invite
                    PendingInvite inv;
                    inv.kind = PendingInviteKind::kConferenceAv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(cookie, cookie + length);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_group_invites_[groupID] = std::move(inv);
                    }
                    return;
                }
                
                // Set up audio callback for AV conference
                // The callback will be called when audio data is received from peers
                // Use the static function HandleAVConferenceAudio defined above
                toxav_audio_data_cb* audio_callback = HandleAVConferenceAudio;
                
                // Validate cookie length
                // AV conference cookie should have the same format as TEXT conference
                const size_t expected_length = sizeof(uint16_t) + 1 + 32; // 2 + 1 + 32 = 35
                if (length != expected_length) {
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] AV conference cookie length mismatch: got {}, expected {}", length, expected_length);
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] Will attempt to join anyway with actual length");
                }
                
                // Log cookie details for debugging
                if (length > 0) {
                    std::ostringstream cookie_hex;
                    size_t log_len = std::min(length, size_t(16)); // Log first 16 bytes
                    for (size_t i = 0; i < log_len; ++i) {
                        cookie_hex << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(cookie[i]);
                        if (i < log_len - 1) cookie_hex << " ";
                    }
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] AV conference cookie first {} bytes (hex): {}", log_len, cookie_hex.str());
                }
                
                // Join AV conference using toxav_join_av_groupchat
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Calling toxav_join_av_groupchat: friend_number={}, cookie_length={}",
                         friend_number, length);
                
                int32_t conference_number = toxav_join_av_groupchat(
                    tox,
                    friend_number,
                    cookie,
                    static_cast<uint16_t>(length),
                    audio_callback,
                    this  // userdata
                );
                
                if (conference_number < 0) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Failed to join AV conference, toxav_join_av_groupchat returned {}", conference_number);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Possible reasons: friend not found, invalid cookie, or network issue");
                    // Store as pending invite for manual join later
                    PendingInvite inv;
                    inv.kind = PendingInviteKind::kConferenceAv;
                    inv.friend_number = friend_number;
                    inv.cookie.assign(cookie, cookie + length);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_group_invites_[groupID] = std::move(inv);
                    }
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending AV conference invite as ID {} for manual join later", gid);
                    return;
                }
                
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] ✅ Successfully joined AV conference");
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] conference_number={}, groupID={}", conference_number, gid);
                
                // Store conference mapping (treating conference_number as group_number for compatibility)
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    // Map conference_number to groupID
                    group_id_to_group_number_[groupID] = ConferenceMapKey(static_cast<uint32_t>(conference_number));
                    group_number_to_group_id_[ConferenceMapKey(static_cast<uint32_t>(conference_number))] = groupID;
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored AV conference mapping: groupID={} <-> conference_number={}", gid, conference_number);
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Total groups in mapping: {}", group_id_to_group_number_.size());
                }

                if (!StoreConferenceIdentity(
                        groupID,
                        ConferenceMapKey(static_cast<uint32_t>(conference_number)))) {
                    V2TIM_LOG(kWarning,
                              "[GroupInvite-Conference] Failed to persist stable identity for AV conference {}",
                              conference_number);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] AV conference joined successfully, HandleGroupConnected will be triggered when connected");

                // Store group type for this conference (both in memory and persistent)
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    group_id_to_type_[groupID] =
                        type == TOX_CONFERENCE_TYPE_AV ? "av_conference"
                                                       : "conference";
                }
                const std::string stored_type =
                    type == TOX_CONFERENCE_TYPE_AV ? "av_conference"
                                                   : "conference";
                SetGroupTypeInStorage(gid, stored_type);

                // Notify Dart layer about the new conference so UI can update group list
                // HandleGroupSelfJoin will look up groupID from the mapping we just stored
                HandleGroupSelfJoin(ConferenceMapKey(static_cast<uint32_t>(conference_number)));
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Called HandleGroupSelfJoin for conference_number={}", conference_number);

                V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== AV Conference invite processing completed ==========");
                return;
#else // BUILD_TOXAV not enabled
                V2TIM_LOG(kWarning, "[GroupInvite-Conference] Received AV type conference invite, but BUILD_TOXAV is not enabled");
                V2TIM_LOG(kWarning, "[GroupInvite-Conference] AV conferences require toxav_join_av_groupchat, which needs BUILD_TOXAV=ON");
                V2TIM_LOG(kWarning, "[GroupInvite-Conference] Storing as pending invite - AV conference join not available");
                
                // Store as pending invite for manual join later
                PendingInvite inv;
                inv.kind = PendingInviteKind::kConferenceAv;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[groupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending AV conference invite as ID {} for manual join later", gid);
                return;
#endif // BUILD_TOXAV
            }
            
            // For TEXT type, use tox_conference_join
            // Note: join_groupchat expects length to be exactly sizeof(uint16_t) + 1 + GROUP_ID_LENGTH = 35 bytes
            // GROUP_ID_LENGTH = CRYPTO_SYMMETRIC_KEY_SIZE = 32 bytes
            const size_t expected_length = sizeof(uint16_t) + 1 + 32; // 2 + 1 + 32 = 35
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] TEXT type conference, calling tox_conference_join: friend_number={}, cookie_length={}, expected_length={}", 
                     friend_number, length, expected_length);
            
            // Log first few bytes of cookie for debugging
            if (length > 0) {
                std::ostringstream cookie_hex;
                size_t log_len = std::min(length, size_t(16)); // Log first 16 bytes
                for (size_t i = 0; i < log_len; ++i) {
                    cookie_hex << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(cookie[i]);
                    if (i < log_len - 1) cookie_hex << " ";
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie first {} bytes (hex): {}", log_len, cookie_hex.str());
            }
            
            if (length != expected_length) {
                V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie length mismatch: got {}, expected {}", length, expected_length);
                // Store as pending invite for manual join later
                PendingInvite inv;
                inv.kind = PendingInviteKind::kConferenceText;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[groupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending conference invite as ID {} for manual join later", gid);
                return;
            }
            
            // Check cookie type byte (at offset sizeof(uint16_t) = 2)
            // GROUPCHAT_TYPE_TEXT = 0, GROUPCHAT_TYPE_AV = 1
            if (length > 2) {
                uint8_t cookie_type = cookie[2];
                const char* cookie_type_name = (cookie_type == 0) ? "TEXT" : 
                                               (cookie_type == 1) ? "AV" : "UNKNOWN";
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie type byte at offset 2: {} ({}) - expected 0 (GROUPCHAT_TYPE_TEXT) for TEXT conference", 
                         static_cast<int>(cookie_type), cookie_type_name);
                
                // Log the uint16_t value at the beginning of cookie (groupchat_num)
                if (length >= sizeof(uint16_t)) {
                    uint16_t groupchat_num = 0;
                    memcpy(&groupchat_num, cookie, sizeof(uint16_t));
                    // Note: may need to handle endianness, but for logging purposes this is fine
                    V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie groupchat_num (first 2 bytes): {} (raw bytes: {:02x} {:02x})", 
                             groupchat_num, cookie[0], cookie[1]);
                }
                
                // Warn if type mismatch
                if (cookie_type != 0) {
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] WARNING: Cookie type byte is {} ({}), but tox_conference_join expects 0 (TEXT)", 
                             static_cast<int>(cookie_type), cookie_type_name);
                    V2TIM_LOG(kWarning, "[GroupInvite-Conference] This will cause WRONG_TYPE error - cookie may be for AV conference");
                }
            }
            
            // Verify length can fit in uint16_t (join_groupchat expects uint16_t)
            if (length > UINT16_MAX) {
                V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie length {} exceeds UINT16_MAX ({})", length, UINT16_MAX);
                PendingInvite inv;
                inv.kind = PendingInviteKind::kConferenceText;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[groupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending conference invite as ID {} for manual join later", gid);
                return;
            }
            
            // Log all cookie bytes for detailed debugging
            std::ostringstream cookie_full_hex;
            for (size_t i = 0; i < length; ++i) {
                cookie_full_hex << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(cookie[i]);
                if (i < length - 1) cookie_full_hex << " ";
            }
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Full cookie ({} bytes, hex): {}", length, cookie_full_hex.str());
            
            // Detailed pre-call validation and logging
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== PRE-CALL VALIDATION ==========");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] tox pointer: {}", static_cast<void*>(tox));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] friend_number: {} (uint32_t)", friend_number);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] cookie pointer: {}", static_cast<const void*>(cookie));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] length: {} (size_t)", length);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] length as uint16_t: {} (cast)", static_cast<uint16_t>(length));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] expected_length: {} (size_t)", expected_length);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] sizeof(uint16_t): {}", sizeof(uint16_t));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Expected: sizeof(uint16_t) + 1 + GROUP_ID_LENGTH = {} + 1 + 32 = {}", 
                     sizeof(uint16_t), sizeof(uint16_t) + 1 + 32);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Length match check: {} == {} ? {}", length, expected_length, (length == expected_length ? "YES" : "NO"));
            
            // Verify cookie structure
            if (length >= 3) {
                uint16_t groupchat_num_le = 0;
                memcpy(&groupchat_num_le, cookie, sizeof(uint16_t));
                uint8_t type_byte = cookie[2];
                const char* type_byte_name = (type_byte == 0) ? "TEXT" : 
                                            (type_byte == 1) ? "AV" : "UNKNOWN";
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Cookie structure: bytes[0-1]={:02x} {:02x} (groupchat_num={}), byte[2]={:02x} (type={}, {}), bytes[3-34]=GROUP_ID (32 bytes)", 
                         cookie[0], cookie[1], groupchat_num_le, type_byte, static_cast<int>(type_byte), type_byte_name);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Expected type byte: {} (GROUPCHAT_TYPE_TEXT = 0)", 0);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Type byte match: {} == 0 ? {} ({} vs TEXT)", 
                         static_cast<int>(type_byte), (type_byte == 0 ? "YES" : "NO"), type_byte_name);
                
                if (type_byte != 0) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ERROR: Cookie type byte mismatch! Cookie has type {} ({}), but tox_conference_join expects 0 (TEXT)", 
                             static_cast<int>(type_byte), type_byte_name);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] This will cause WRONG_TYPE error. Cookie is for {} conference, but we're trying to join as TEXT", type_byte_name);
                }
            }
            
            // Check friend connection status
            TOX_CONNECTION friend_conn = TOX_CONNECTION_NONE;
            try {
                friend_conn = tox_friend_get_connection_status(tox, friend_number, nullptr);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Friend {} connection status: {} (0=NONE, 1=UDP, 2=TCP)", 
                         friend_number, static_cast<int>(friend_conn));
            } catch (...) {
                V2TIM_LOG(kWarning, "[GroupInvite-Conference] Failed to get friend connection status");
            }
            
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== CALLING tox_conference_join ==========");
            // [tim2tox-debug] Record invite receive and cookie parsing for HandleGroupInvite
            V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupInvite: Received conference invite - friend_number={}, type={}, cookie_length={}", 
                     friend_number, static_cast<int>(type), length);
            if (length >= 3) {
                uint16_t groupchat_num = 0;
                memcpy(&groupchat_num, cookie, sizeof(uint16_t));
                uint8_t cookie_type = cookie[2];
                V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupInvite: Cookie parsed - groupchat_num={}, type_byte={}", 
                         groupchat_num, static_cast<int>(cookie_type));
            }
            Tox_Err_Conference_Join err_join = TOX_ERR_CONFERENCE_JOIN_OK;
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Parameters before call:");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   tox={}", static_cast<void*>(tox));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   friend_number={} (uint32_t)", friend_number);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   cookie={}", static_cast<const void*>(cookie));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   length={} (size_t) = {} (uint16_t)", length, static_cast<uint16_t>(length));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference]   error_ptr={}", static_cast<void*>(&err_join));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Calling tox_conference_join now...");
            // [tim2tox-debug] Record tox_conference_join call
            V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupInvite: Calling tox_conference_join");
            
            Tox_Conference_Number conference_number = tox_conference_join(
                tox,
                friend_number,
                cookie, length,
                &err_join
            );
            
            V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupInvite: tox_conference_join returned: conference_number={}, err_join={}", 
                     conference_number, static_cast<int>(err_join));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] tox_conference_join call completed");
            
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== tox_conference_join RETURNED ==========");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Return value: conference_number={}", conference_number);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Error code: {} (enum value)", static_cast<int>(err_join));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] UINT32_MAX: {}", UINT32_MAX);
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] conference_number == UINT32_MAX ? {}", (conference_number == UINT32_MAX ? "YES" : "NO"));
            
            // Map error code to string
            const char* err_name = "UNKNOWN";
            switch (err_join) {
                case TOX_ERR_CONFERENCE_JOIN_OK: err_name = "OK"; break;
                case TOX_ERR_CONFERENCE_JOIN_NULL: err_name = "NULL"; break;
                case TOX_ERR_CONFERENCE_JOIN_INVALID_LENGTH: err_name = "INVALID_LENGTH"; break;
                case TOX_ERR_CONFERENCE_JOIN_WRONG_TYPE: err_name = "WRONG_TYPE"; break;
                case TOX_ERR_CONFERENCE_JOIN_FRIEND_NOT_FOUND: err_name = "FRIEND_NOT_FOUND"; break;
                case TOX_ERR_CONFERENCE_JOIN_DUPLICATE: err_name = "DUPLICATE"; break;
                case TOX_ERR_CONFERENCE_JOIN_INIT_FAIL: err_name = "INIT_FAIL"; break;
                case TOX_ERR_CONFERENCE_JOIN_FAIL_SEND: err_name = "FAIL_SEND"; break;
            }
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Error name: {}", err_name);
            
            if (err_join != TOX_ERR_CONFERENCE_JOIN_OK || conference_number == UINT32_MAX) {
                V2TIM_LOG(kError, "[GroupInvite-Conference] ========== JOIN FAILED ==========");
                V2TIM_LOG(kError, "[GroupInvite-Conference] Error code: {} ({})", static_cast<int>(err_join), err_name);
                V2TIM_LOG(kError, "[GroupInvite-Conference] Error code meanings: 0=OK, 1=NULL, 2=INVALID_LENGTH, 3=WRONG_TYPE, 4=FRIEND_NOT_FOUND, 5=DUPLICATE, 6=INIT_FAIL, 7=FAIL_SEND");
                V2TIM_LOG(kError, "[GroupInvite-Conference] conference_number={} (UINT32_MAX={})", conference_number, UINT32_MAX);
                
                // Detailed diagnostics for each error type
                if (err_join == TOX_ERR_CONFERENCE_JOIN_INVALID_LENGTH) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== INVALID_LENGTH DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie length received: {} (size_t)", length);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie length as uint16_t: {} (cast)", static_cast<uint16_t>(length));
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Expected length: {} (size_t)", expected_length);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] sizeof(uint16_t): {}", sizeof(uint16_t));
                    V2TIM_LOG(kError, "[GroupInvite-Conference] GROUP_ID_LENGTH (CRYPTO_SYMMETRIC_KEY_SIZE): 32");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] join_groupchat check: length != sizeof(uint16_t) + 1 + GROUP_ID_LENGTH");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] join_groupchat check: {} != {} + 1 + 32", length, sizeof(uint16_t));
                    V2TIM_LOG(kError, "[GroupInvite-Conference] join_groupchat check: {} != {}", length, sizeof(uint16_t) + 1 + 32);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Length difference: {} - {} = {}", 
                             length, sizeof(uint16_t) + 1 + 32, static_cast<long long>(length) - static_cast<long long>(sizeof(uint16_t) + 1 + 32));
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_WRONG_TYPE) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== WRONG_TYPE DIAGNOSTICS ==========");
                    if (length > 2) {
                        uint8_t cookie_type = cookie[2];
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie type byte at offset 2: {} (received)", static_cast<int>(cookie_type));
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Expected type: {} (GROUPCHAT_TYPE_TEXT)", 1);
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Type mismatch: {} != 1", static_cast<int>(cookie_type));
                    } else {
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Cookie too short to check type byte (length={})", length);
                    }
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_FRIEND_NOT_FOUND) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== FRIEND_NOT_FOUND DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] friend_number: {}", friend_number);
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Friend connection status: {} (0=NONE, 1=UDP, 2=TCP)", static_cast<int>(friend_conn));
                    if (friend_conn == TOX_CONNECTION_NONE) {
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Friend is not connected - this may cause FRIEND_NOT_FOUND error");
                    }
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_DUPLICATE) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== DUPLICATE DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Client may already be in this conference");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] join_groupchat check: get_group_num() != -1 (group already exists)");
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_INIT_FAIL) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== INIT_FAIL DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] create_group_chat() returned -1 (group instance failed to initialize)");
                } else if (err_join == TOX_ERR_CONFERENCE_JOIN_FAIL_SEND) {
                    V2TIM_LOG(kError, "[GroupInvite-Conference] ========== FAIL_SEND DIAGNOSTICS ==========");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] send_invite_response() returned false (join packet failed to send)");
                    V2TIM_LOG(kError, "[GroupInvite-Conference] Friend connection status: {} (0=NONE, 1=UDP, 2=TCP)", static_cast<int>(friend_conn));
                    if (friend_conn == TOX_CONNECTION_NONE) {
                        V2TIM_LOG(kError, "[GroupInvite-Conference] Friend is not connected - this may cause FAIL_SEND error");
                    }
                }
                
                // Store as pending invite for manual join later
                PendingInvite inv;
                inv.kind = PendingInviteKind::kConferenceText;
                inv.friend_number = friend_number;
                inv.cookie.assign(cookie, cookie + length);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_group_invites_[groupID] = std::move(inv);
                }
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored pending conference invite as ID {} for manual join later", gid);
                return;
            }
            
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ✅ Successfully joined conference");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] conference_number={}, groupID={}", conference_number, gid);
            
            // Store conference mapping (old API uses conference_number, which may be same as group_number in some cases)
            // Note: In modern c-toxcore, conference_number and group_number may be the same value
            // We'll treat conference_number as group_number for mapping purposes
            {
                std::lock_guard<std::mutex> lock(mutex_);
                // Map conference_number to groupID (treating it as group_number for compatibility)
                group_id_to_group_number_[groupID] = ConferenceMapKey(conference_number);
                group_number_to_group_id_[ConferenceMapKey(conference_number)] = groupID;
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored conference mapping: groupID={} <-> conference_number={}", gid, conference_number);
                V2TIM_LOG(kInfo, "[GroupInvite-Conference] Total groups in mapping: {}", group_id_to_group_number_.size());
            }

            if (!StoreConferenceIdentity(groupID, ConferenceMapKey(conference_number))) {
                V2TIM_LOG(kWarning,
                          "[GroupInvite-Conference] Failed to persist stable identity for text conference {}",
                          conference_number);
            }

            // Store group type for this conference (both in memory and persistent)
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_type_[groupID] = "conference";
            }
            SetGroupTypeInStorage(gid, "conference");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Stored group type 'conference' for groupID={}", gid);

            // Notify Dart layer about the new conference so UI can update group list
            // HandleGroupSelfJoin will look up groupID from the mapping we just stored
            HandleGroupSelfJoin(ConferenceMapKey(conference_number));
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Called HandleGroupSelfJoin for conference_number={}", conference_number);

            V2TIM_LOG(kInfo, "[GroupInvite-Conference] Conference joined successfully, HandleGroupConnected will be triggered when connected");
            V2TIM_LOG(kInfo, "[GroupInvite-Conference] ========== Conference invite processing completed ==========");
        }
    );
    
    // CRITICAL: Rejoin all known groups using stored chat_id (c-toxcore recommended approach)
    // This ensures groups are properly restored after client restart, even if they're not in savedata
    // The onGroupSelfJoin callback will be triggered for each successfully joined group to rebuild mappings
    // Note: This may be called before Dart layer has synced known groups, so it may find no groups.
    // Dart layer will call RejoinKnownGroups() again after init() completes.
    // IMPORTANT: Don't call RejoinKnownGroups here during InitSDK - it will be called when connection is established
    // This prevents crashes during initialization when objects may not be fully ready
    
    // Conference (old API) messages: route to same handler as group messages so receivers get OnRecvNewMessage.
    // tox_callback_conference_message fires for conferences; tox_callback_group_message for new groups only.
    tox_manager_->setGroupMessageCallback(
        [this](uint32_t conference_number, uint32_t peer_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length) {
            this->HandleGroupMessageGroup(ConferenceMapKey(conference_number),
                    static_cast<Tox_Group_Peer_Number>(peer_number), type, message, length, static_cast<Tox_Group_Message_Id>(0));
        }
    );
    tox_manager_->setFriendMessageCallback(
        [this](uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length) {
            this->HandleFriendMessage(friend_number, type, message, length);
        }
    );
    // Signaling: route lossless packets to this instance's signaling manager
    tox_manager_->setFriendLosslessPacketCallback(
        [this](uint32_t friend_number, const uint8_t* data, size_t length) {
            if (data == nullptr || length == 0) {
                V2TIM_LOG(kWarning, "Dropped empty lossless packet");
                return;
            }
            if (data[0] == tim2tox::control::kPacketId) {
                const auto packet = tim2tox::control::Decode(
                    std::span<const uint8_t>(data, length));
                if (!packet.has_value()) {
                    V2TIM_LOG(kWarning, "Dropped malformed control packet with length {}", length);
                    return;
                }
                const auto* body = reinterpret_cast<const uint8_t*>(
                    packet->body.data());
                if (packet->type == Type::kGenericCustom) {
                    this->HandleFriendCustomMessage(
                        friend_number, body, packet->body.size());
                } else if (packet->type == Type::kGroupIdentity) {
                    this->HandleGroupIdentityAnnouncement(
                        friend_number, body, packet->body.size());
                } else {
                    this->HandleFriendControlMessage(
                        friend_number, packet->type, body, packet->body.size());
                }
                return;
            }
            if (data[0] == tim2tox::packet_ids::kSignaling) {
                V2TIMSignalingManager* sig = GetSignalingManager();
                if (sig) {
                    static_cast<V2TIMSignalingManagerImpl*>(sig)->OnToxMessage(friend_number, data, length);
                }
                return;
            }
            V2TIM_LOG(kWarning, "Dropped unknown lossless packet type with length {}", length);
        }
    );
    tox_manager_->setFriendReadReceiptCallback(
        [this](uint32_t friend_number, uint32_t message_number) {
            this->HandleFriendReadReceipt(friend_number, message_number);
        }
    );
    // Use callback that captures 'this' directly (safe now that we have instance-specific ToxManager)
    tox_manager_->setSelfConnectionStatusCallback(
        [this](TOX_CONNECTION connection_status) {
            // DEBUG: Detailed analysis in callback
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            
            // Note: Cannot access memory directly for atomic, removed
            
            static_cast<void>(0);
            
            static_cast<void>(0);
            static_cast<void>(0);
            
            // Use atomic load for thread safety
            bool is_running = this->running_.load(std::memory_order_acquire);
            extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
            int64_t instance_id = GetInstanceIdFromManager(this);
            // connection_status: 0=NONE, 1=TCP, 2=UDP
            V2TIM_LOG(kInfo, "SelfConnectionStatusCallback: instance_id={}, connection_status={}, IsRunning()={}", 
                     instance_id, connection_status, is_running ? 1 : 0);
            if (is_running) {
                this->HandleSelfConnectionStatus(connection_status);
            } else {
                V2TIM_LOG(kWarning, "SelfConnectionStatusCallback: SDK not running (instance_id={}), skipping HandleSelfConnectionStatus", instance_id);
            }
        }
    );
    tox_manager_->setFriendRequestCallback(
        [this](const uint8_t* public_key, const uint8_t* message, size_t length) {
            this->HandleFriendRequest(public_key, message, length);
        }
    );
    tox_manager_->setFriendNameCallback(
        [this](uint32_t friend_number, const uint8_t* name, size_t length) {
            this->HandleFriendName(friend_number, name, length);
        }
    );
    tox_manager_->setFriendStatusMessageCallback(
        [this](uint32_t friend_number, const uint8_t* message, size_t length) {
            this->HandleFriendStatusMessage(friend_number, message, length);
        }
    );
    tox_manager_->setFriendStatusCallback(
        [this](uint32_t friend_number, TOX_USER_STATUS status) {
            static_cast<void>(0);
            static_cast<void>(0);
            this->HandleFriendStatus(friend_number, status);
            static_cast<void>(0);
            static_cast<void>(0);
        }
    );
    tox_manager_->setFriendConnectionStatusCallback(
        [this](uint32_t friend_number, TOX_CONNECTION connection_status) {
            this->HandleFriendConnectionStatus(friend_number, connection_status);
        }
    );
    tox_manager_->setGroupTitleCallback(
        [this](uint32_t conference_number, uint32_t peer_number, const uint8_t* title, size_t length) {
            this->HandleGroupTitle(ConferenceMapKey(conference_number), peer_number, title, length);
        }
    );
    tox_manager_->setGroupPeerNameCallback(
        [this](uint32_t conference_number, uint32_t peer_number, const uint8_t* name, size_t length) {
            this->HandleGroupPeerName(ConferenceMapKey(conference_number), peer_number, name, length);
        }
    );
    tox_manager_->setGroupPeerListChangedCallback(
        [this](uint32_t conference_number) {
            this->HandleGroupPeerListChanged(ConferenceMapKey(conference_number));
        }
    );
    tox_manager_->setGroupConnectedCallback(
        [this](uint32_t conference_number) {
            this->HandleGroupConnected(ConferenceMapKey(conference_number));
        }
    );
    // TODO: Register handlers for other callbacks (read receipts, file transfer, etc.)

    // CRITICAL: Set running_ flag AFTER all callbacks are registered
    // Note: running_ was already set to true before initialize() to handle early callbacks
    // This ensures consistency and that all callbacks are ready before processing events
    // running_ is already true, so we just log here for clarity
    static_cast<void>(0);
    static_cast<void>(0);
    
    // Start the Tox event loop thread.
    // In test mode, the auto_tests harness drives iteration manually via
    // tim2tox_ffi_iterate_instance() with a shared virtual clock, so we skip
    // starting the per-instance event_thread entirely.
    if (!test_mode_.load(std::memory_order_acquire)) {
        static_cast<void>(0);
        event_thread_running_.store(true, std::memory_order_release);
        try {
            event_thread_ = std::thread([this] {
                event_thread_id_ = std::this_thread::get_id();
                while (running_.load(std::memory_order_acquire)) {
                    try {
                    // Process pending tasks first (Invite/signaling etc. run on this thread to avoid tox lock deadlock)
                    {
                        std::unique_lock<std::mutex> lock(task_mutex_);
                        task_cv_.wait_for(lock, std::chrono::milliseconds(50),
                            [this] { return !task_queue_.empty() || !running_.load(std::memory_order_relaxed); });
                        while (!task_queue_.empty()) {
                            auto task = std::move(task_queue_.front());
                            task_queue_.pop();
                            lock.unlock();
                            task();
                            lock.lock();
                        }
                    }
                    if (!running_.load(std::memory_order_acquire)) break;
                    if (!tox_manager_ || tox_manager_->isShuttingDown()) break;
                    // Centralized iterate through ToxManager to ensure correct user_data
                    tox_manager_->iterate();
                    if (!running_.load(std::memory_order_acquire)) break;
                    if (!tox_manager_ || tox_manager_->isShuttingDown()) break;
                    // Dispatch any expired signaling invite timeouts. Iterate-driven
                    // (replaces the per-invite std::thread that used to back
                    // OnInvitationTimeout) so virtual-clock tests work and a
                    // long-timeout invite no longer blocks a subsequent short-
                    // timeout Invite() from firing on schedule.
                    if (signaling_manager_) {
                        signaling_manager_->CheckTimeouts();
                    }
                    // Same for timed group mutes (NGC has no expiry of its own).
                    if (group_manager_) {
                        group_manager_->CheckMuteExpiries();
                    }
                    Tox* t = tox_manager_->getTox();
                    uint32_t interval = t ? tox_iteration_interval(t) : 50;
                    std::this_thread::sleep_for(std::chrono::milliseconds(interval));
                    } catch (...) {
                        break;
                    }
                }
                event_thread_running_.store(false, std::memory_order_release);
            });
        } catch (...) {
            event_thread_running_.store(false, std::memory_order_release);
            throw;
        }
    } else {
        static_cast<void>(0);
        static_cast<void>(0);
    }

    static_cast<void>(0);
    return true;
}

// See ToxSessionGuard in the header for why this pins rather than locks.
V2TIMManagerImpl::ToxSessionGuard V2TIMManagerImpl::AcquireToxSession() const {
    std::shared_ptr<ToxManager> manager;
    {
        std::lock_guard<std::mutex> manager_lock(tox_manager_mutex_);
        manager = tox_manager_;
    }
    if (!manager) return ToxSessionGuard();
    // Released tox_manager_mutex_ first: ToxManager takes its own mutex here,
    // and nothing may hold the two at once (UnInitSDK holds tox_manager_mutex_
    // only to swap the pointer out).
    std::shared_ptr<Tox> tox = manager->acquireTox();
    if (!tox) return ToxSessionGuard();
    return ToxSessionGuard(std::move(manager), std::move(tox), this,
                           session_epoch_.load(std::memory_order_acquire));
}

void V2TIMManagerImpl::UnInitSDK() {
    // Called from a listener/callback while this thread is inside a
    // tox_iterate() or toxav_iterate() (possibly ON event_thread_): the
    // teardown below would join the current thread, re-lock the iterate's
    // non-recursive mutex (ToxManager/ToxAVManager::shutdown) and free the
    // Tox/ToxAV that iterate is still walking. Run it on this same thread as
    // soon as the outermost iterate returns (see IterateReentryScope).
    if (IterateReentryScope::Active()) {
        std::weak_ptr<int> alive = uninit_alive_token_;
        if (IterateReentryScope::Defer([this, alive] {
                if (alive.lock()) UnInitSDK();
            })) {
            V2TIM_LOG(kWarning, "[UnInitSDK] called from inside an iterate callback; deferred until the iterate returns");
            return;
        }
    }
    ClearPendingDeliveries();
#ifdef BUILD_TOXAV
    ClearAVConferenceAudioCallback();
#endif
    // Stop background tasks (refresh/rejoin threads) so they don't access this after shutdown
    StopBackgroundTasks();
    // First, stop the event thread and wait for it to exit
    // This MUST happen before calling ToxManager::shutdown() to prevent race conditions
    running_.store(false, std::memory_order_release);
    task_cv_.notify_all();  // Wake event thread so it exits promptly
    // On event_thread_ itself (a RunOnEventThread task, or the deferral above
    // draining at the end of that thread's iterate) it cannot be joined: the
    // loop exits by itself once this returns (running_ is false), and InitSDK
    // / the destructor reap it.
    if (event_thread_.joinable() && event_thread_.get_id() != std::this_thread::get_id()) {
        try {
            event_thread_.join();
        } catch (const std::system_error&) {
            // Thread may have already exited - ignore
        } catch (...) {
            // Ignore any other exception during thread join
        }
    }
    // The event loop break()s without draining task_queue_, and this object is
    // reused by the next InitSDK. A task queued for THIS session (it captures
    // group/friend numbers of this profile) must not run against the next
    // profile's Tox instance. Blocked RunOnEventThread callers keep their own
    // reference to the promise, so dropping the tasks just lets them time out.
    {
        std::lock_guard<std::mutex> lock(task_mutex_);
        std::queue<std::function<void()>> discarded;
        task_queue_.swap(discarded);
    }
    // Now that event thread has exited, it's safe to shutdown ToxManager
    // Persist tox profile on shutdown using path from InitSDK
    std::string save_path = save_path_;
    if (save_path.empty()) {
        std::filesystem::path save_dir = tim2tox::path::GetDefaultDataDir();
        std::string mkdir_err;
        (void)tim2tox::path::EnsureDirectoryExists(save_dir, &mkdir_err);
        save_path = tim2tox::path::BuildProfilePath(save_dir, GetInstanceIdFromManager(this)).string();
    }
    try {
#ifdef BUILD_TOXAV
        if (toxav_manager_) {
            toxav_manager_->shutdown();
            toxav_manager_.reset();
        }
#endif
        // Unpublish FIRST, so an AcquireToxSession() racing with this teardown
        // refuses outright instead of starting an operation we are about to
        // tear down. Whoever already holds a pin keeps the manager and the Tox
        // alive through the end of their call sequence; the tox_kill() then
        // runs when that last pin drops (see ToxManager::acquireTox).
        std::shared_ptr<ToxManager> tox_manager;
        {
            std::lock_guard<std::mutex> manager_lock(tox_manager_mutex_);
            tox_manager.swap(tox_manager_);
        }
        if (tox_manager) {
            tox_manager->saveTo(save_path);
            tox_manager->shutdown();
        }
    } catch (...) {
        // Ignore exceptions during shutdown
    }
    save_path_.clear();
    ResetGroupSessionState();
    // Sent/received invites address this profile's friend numbers.
    if (signaling_manager_) signaling_manager_->ResetSessionState();
    // The session is over: whatever it posted and Dart has not handled yet is
    // now recognisably stale (Dart compares the stamp with
    // tim2tox_ffi_get_session_epoch), and what it could not post at all
    // (durable notifications waiting for a port) must not be replayed into
    // the next session of this instance id.
    DiscardDurableCallbacksForInstance(GetInstanceIdFromManager(this));
    session_epoch_.store(0, std::memory_order_release);
}

// The default instance is a process singleton that is never destroyed, so an
// account switch (UnInitSDK -> InitSDK with another profile) reuses this very
// object. Tox group numbers restart at 0 for every profile; any mapping left
// here made the next account's InitSDK restore loop resolve ITS group #0 to the
// previous account's groupID, publish a join for it, and write the new
// account's chat_id under the old ID. Runs after the event/background threads
// are joined and tox_manager_ is gone, so nothing else touches these maps.
void V2TIMManagerImpl::ResetGroupSessionState() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        group_id_to_group_number_.clear();
        group_number_to_group_id_.clear();
        group_id_to_chat_id_.clear();
        chat_id_to_group_id_.clear();
        group_id_to_type_.clear();
        pending_group_invites_.clear();
        group_peer_snapshots_.clear();
        group_peer_id_cache_.clear();
        fresh_group_joins_.clear();
        accepted_invites_.clear();
        online_identity_friends_.clear();
        pending_identity_challenges_.clear();
        dart_known_chat_id_.clear();
        dart_known_type_.clear();
    }
    retired_group_id_max_.store(0);  // the next account pushes its own
    {
        std::lock_guard<std::mutex> lock(mutex_);
        friend_group_digests_.clear();
        digest_claimants_.clear();
        identity_claim_count_ = 0;
        member_digest_index_.clear();
        member_digest_by_slot_.clear();
        member_key_to_friend_.clear();
        answered_identity_challenges_.clear();
        answered_identity_challenge_order_.clear();
        identity_rate_by_friend_.clear();
        identity_rate_global_ = IdentityRateWindow{};
        identity_last_prune_ = IdentityClock::time_point{};
        seen_group_receipts_.clear();
        seen_group_receipt_order_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(metadata_mutex_);
        known_groups_.clear();
        auto_accept_group_invites_ = false;
    }
    rejoin_triggered_.store(false);
    if (group_manager_) {
        group_manager_->ClearAllState();
    }
    ForgetCrossInstanceGroupIdentities(GetInstanceIdFromManager(this));
}

void V2TIMManagerImpl::SaveToxProfile() {
    if (!tox_manager_) {
        V2TIM_LOG(kWarning, "[SaveToxProfile] tox_manager_ is null, skipping");
        return;
    }
    std::string save_path = save_path_;
    if (save_path.empty()) {
        std::filesystem::path save_dir = tim2tox::path::GetDefaultDataDir();
        std::string mkdir_err;
        (void)tim2tox::path::EnsureDirectoryExists(save_dir, &mkdir_err);
        save_path = tim2tox::path::BuildProfilePath(save_dir, GetInstanceIdFromManager(this)).string();
    }
    if (tox_manager_->saveTo(save_path)) {
        V2TIM_LOG(kInfo, "[SaveToxProfile] Saved tox profile to {}", save_path);
    } else {
        V2TIM_LOG(kError, "[SaveToxProfile] Failed to save tox profile to {}", save_path);
    }
}

// SDK Information
V2TIMString V2TIMManagerImpl::GetVersion() {
    return TIM2TOX_VERSION_STRING;
}

std::string V2TIMManagerImpl::MakeMessageId() {
    int64_t instance_id = GetInstanceIdFromManager(this);
    auto now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    uint64_t seq = next_message_seq_.fetch_add(1, std::memory_order_relaxed);
    std::ostringstream oss;
    oss << "msg_" << instance_id << "_" << now_ns << "_" << seq;
    return oss.str();
}

std::string V2TIMManagerImpl::MakeGroupId() {
    int64_t instance_id = GetInstanceIdFromManager(this);
    uint64_t seq = next_group_seq_.fetch_add(1, std::memory_order_relaxed);
    std::ostringstream oss;
    oss << "group_" << instance_id << "_" << seq;
    return oss.str();
}

int64_t V2TIMManagerImpl::GetServerTime() {
    return std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()
    ).count();
}

// User Authentication: Login completes locally; connection state is reported via SDK listeners.
void V2TIMManagerImpl::Login(const V2TIMString& userID, const V2TIMString& userSig, V2TIMCallback* callback) {
    if (!tox_manager_) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }
    if (userID.Empty()) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "userID is empty");
        return;
    }
    // TIM 风格的 userSig 在 tim2tox 中不会被验证，只作兼容透传；这里忽略非空 userSig，
    // 保持登录流程继续，以便沿用上层现有调用约定。

    {
        std::lock_guard<std::mutex> lock(mutex_);
        login_user_alias_ = userID;
    }

    // Set logged_in_user_ from tox when available (used for status/self identity
    // in callbacks). Pinned: this is an FFI entry point, and the pubkey read and
    // the address read must see the same live instance.
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (tox) {
        uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, pubkey);
        std::string pk_hex = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        std::string address = session.manager()->getAddress();
        if (address.length() >= 76) {
            logged_in_user_ = (pk_hex + address.substr(64, 12)).c_str();
        } else {
            logged_in_user_ = pk_hex.c_str();
        }
    } else if (session.manager()) {
        std::string address = session.manager()->getAddress();
        if (address.length() > 0) {
            logged_in_user_ = address.c_str();
        }
    }

    if (callback) callback->OnSuccess();
}

void V2TIMManagerImpl::Logout(V2TIMCallback* callback) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        login_user_alias_ = "";
    }
    logged_in_user_ = "";
    if (callback) callback->OnSuccess();
}

V2TIMString V2TIMManagerImpl::GetLoginUser() {
    std::lock_guard<std::mutex> lock(mutex_);
    return login_user_alias_;
}

V2TIMString V2TIMManagerImpl::GetSelfToxAddress() {
    std::lock_guard<std::mutex> lock(mutex_);
    return logged_in_user_;
}

V2TIMLoginStatus V2TIMManagerImpl::GetLoginStatus() {
    std::lock_guard<std::mutex> lock(mutex_);
    bool is_empty = login_user_alias_.Empty();
    return is_empty ? V2TIMLoginStatus::V2TIM_STATUS_LOGOUT : V2TIMLoginStatus::V2TIM_STATUS_LOGINED;
}

bool V2TIMManagerImpl::HasGroup(const V2TIMString& group_id) const {
    return group_id_to_group_number_.find(group_id) != group_id_to_group_number_.end();
}

// IsRunning() implementation - moved to .cpp to avoid inline optimization issues
bool V2TIMManagerImpl::IsRunning() const {
    return running_.load(std::memory_order_acquire);
}

bool V2TIMManagerImpl::IsEventThreadRunning() const {
    return event_thread_running_.load(std::memory_order_acquire);
}

// Messaging
void V2TIMManagerImpl::AddSimpleMsgListener(V2TIMSimpleMsgListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    simple_msg_listeners_.insert(listener);
}

void V2TIMManagerImpl::RemoveSimpleMsgListener(V2TIMSimpleMsgListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    simple_msg_listeners_.erase(listener);
}

V2TIMString V2TIMManagerImpl::SendC2CTextMessage(
    const V2TIMString& text, 
    const V2TIMString& userID,
    V2TIMSendCallback* callback) {
    return SendC2CTextMessageWithType(
        text, userID, V2TIMBuffer(), callback, false);
}

V2TIMString V2TIMManagerImpl::SendC2CTextMessage(
    const V2TIMString& text, 
    const V2TIMString& userID,
    const V2TIMBuffer& cloudCustomData,
    V2TIMSendCallback* callback) {
    return SendC2CTextMessageWithType(
        text, userID, cloudCustomData, callback, false);
}

V2TIMString V2TIMManagerImpl::SendC2CActionMessage(
    const V2TIMString& text,
    const V2TIMString& userID,
    V2TIMSendCallback* callback) {
    return SendC2CTextMessageWithType(
        text, userID, V2TIMBuffer(), callback, true);
}

V2TIMString V2TIMManagerImpl::SendC2CTextMessageWithType(
    const V2TIMString& text,
    const V2TIMString& userID,
    const V2TIMBuffer& cloudCustomData,
    V2TIMSendCallback* callback,
    bool force_action) {
    // ===================================================================
    // Step 1: Validate parameters
    // ===================================================================
    auto prepared = tim2tox::qtox::PrepareTextMessage(
        std::string_view(text.CString(), text.Length()), force_action);
    if (!prepared.has_value()) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, 
                            "Message text must be valid non-empty UTF-8 without NUL bytes");
        }
        return "";
    }

    if (userID.Empty()) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, 
                            "UserID cannot be empty");
        }
        return "";
    }

    // ===================================================================
    // Step 2: Convert UserID (assuming hex public key) to Tox public key bytes
    // ===================================================================
    uint8_t public_key[TOX_PUBLIC_KEY_SIZE] = {0};
    bool convert_result = false;
    if (userID.Length() == TOX_PUBLIC_KEY_SIZE * 2) {
        convert_result = ToxUtil::tox_hex_to_bytes(userID.CString(), userID.Length(), public_key, TOX_PUBLIC_KEY_SIZE);
    } else if (userID.Length() == TOX_ADDRESS_SIZE * 2) {
        uint8_t address[TOX_ADDRESS_SIZE] = {0};
        if (ToxUtil::tox_hex_to_bytes(userID.CString(), userID.Length(), address, TOX_ADDRESS_SIZE)) {
            memcpy(public_key, address, TOX_PUBLIC_KEY_SIZE);
            convert_result = true;
        }
    }

    if (!convert_result) {
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS,
                            "Invalid userID format (must be hex Tox ID)");
        }
        return "";
    }

    // ===================================================================
    // Step 3: Look up friend number by public key
    // ===================================================================
    std::unique_lock<std::mutex> lock(mutex_); // Use the main mutex
    // Pinned for the whole send sequence below (FFI caller thread); same lock
    // cost as the getTox() it replaces, and taken in the same order.
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox) {
         if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
         return "";
    }
    
    TOX_ERR_FRIEND_BY_PUBLIC_KEY find_err;
    uint32_t friend_number = tox_friend_by_public_key(
        tox, 
        public_key, 
        &find_err
    );

    if (find_err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        lock.unlock();
        if (callback) {
            // Use appropriate error code based on V2TIMErrorCode.h
            int v2_err = (find_err == TOX_ERR_FRIEND_BY_PUBLIC_KEY_NOT_FOUND)
                       ? ERR_SVR_FRIENDSHIP_ACCOUNT_NOT_FOUND
                       : ERR_INVALID_PARAMETERS;
            const char* err_msg = (find_err == TOX_ERR_FRIEND_BY_PUBLIC_KEY_NOT_FOUND)
                                ? "Target user is not your friend"
                                : "Friend lookup failed";
            V2TIM_LOG(kError, "SendC2CTextMessage friend lookup failed with status {}", find_err);
            callback->OnError(v2_err, err_msg);
        }
        return "";
    }
    
    // Check friend connection status before sending
    TOX_CONNECTION connection_status = tox_friend_get_connection_status(tox, friend_number, nullptr);
    V2TIM_LOG(kInfo, "SendC2CTextMessage connection status {}", connection_status);
    
    // If friend is not connected, wait a bit and retry once (for test scenarios)
    if (connection_status == TOX_CONNECTION_NONE) {
        lock.unlock(); // Release lock before waiting
        std::this_thread::sleep_for(std::chrono::seconds(2));
        lock.lock(); // Re-acquire lock
        
        // Re-check connection status
        connection_status = tox_friend_get_connection_status(tox, friend_number, nullptr);
        V2TIM_LOG(kInfo, "SendC2CTextMessage retry connection status {}", connection_status);
        
        if (connection_status == TOX_CONNECTION_NONE) {
            lock.unlock();
            if (callback) callback->OnError(ERR_SDK_NET_DISCONNECT, "Friend not connected");
            return "";
        }
    }

    // ===================================================================
    // Step 4: Process reply reference if present
    // ===================================================================
    std::string finalMessageText(prepared->body);
    
    // 检查是否有引用回复信息
    std::string replyJson = MessageReplyUtil::ExtractReplyJsonFromCloudCustomData(cloudCustomData);
    if (prepared->type == TOX_MESSAGE_TYPE_NORMAL && !replyJson.empty()) {
        // 构建包含引用回复的消息
        std::string messageWithReply = MessageReplyUtil::BuildMessageWithReply(replyJson, finalMessageText);
        
        // 检查消息长度
        if (MessageReplyUtil::IsMessageTooLong(messageWithReply)) {
            // 如果消息过长，尝试压缩引用信息
            std::string compressedReply = MessageReplyUtil::CompressReplyJson(replyJson);
            messageWithReply = MessageReplyUtil::BuildMessageWithReply(compressedReply, finalMessageText);
            
            // 如果还是太长，只保留messageID
            if (MessageReplyUtil::IsMessageTooLong(messageWithReply)) {
                // 提取messageID
                std::string messageID = MessageReplyUtil::ExtractJsonValue(replyJson, "messageID");
                if (!messageID.empty()) {
                    std::string minimalReply = "{\"version\":1,\"messageID\":\"" + messageID + "\"}";
                    messageWithReply = MessageReplyUtil::BuildMessageWithReply(minimalReply, finalMessageText);
                }
            }
        }
        
        finalMessageText = messageWithReply;
    }

    prepared->body = finalMessageText;
    
    // ===================================================================
    // Step 5: Send the message
    // ===================================================================
    V2TIMString msg_id = MakeMessageId().c_str();

    const auto fragments = tim2tox::qtox::FragmentMessage(prepared->body);
    if (!fragments.has_value()) {
        lock.unlock();
        if (callback) {
            callback->OnError(ERR_INVALID_PARAMETERS, "Message cannot be fragmented");
        }
        return "";
    }

    TOX_ERR_FRIEND_SEND_MESSAGE send_err = TOX_ERR_FRIEND_SEND_MESSAGE_OK;
    std::vector<uint32_t> tox_message_numbers;
    tox_message_numbers.reserve(fragments->size());
    V2TIM_LOG(kInfo, "SendC2CTextMessage sending {} fragments", fragments->size());
    for (const auto& fragment : *fragments) {
        const uint32_t tox_message_number = tox_friend_send_message(
            tox,
            friend_number,
            prepared->type,
            reinterpret_cast<const uint8_t*>(fragment.data()),
            fragment.size(),
            &send_err);
        if (send_err != TOX_ERR_FRIEND_SEND_MESSAGE_OK) {
            break;
        }
        tox_message_numbers.push_back(tox_message_number);
    }
    V2TIM_LOG(kInfo, "SendC2CTextMessage completed with status {}", send_err);

    lock.unlock();

    // ===================================================================
    // Step 5: Handle send result
    // ===================================================================
    if (send_err == TOX_ERR_FRIEND_SEND_MESSAGE_OK &&
        tox_message_numbers.size() == fragments->size()) {
        TrackPendingDelivery(
            friend_number, tox_message_numbers, msg_id, userID);
        if (callback) {
            // Create a V2TIMMessage from the message ID
            V2TIMMessage resultMsg;
            resultMsg.msgID = msg_id;
            // Add a text elem to the message (使用原始text，不包含引用标记)
            V2TIMTextElem* textElem = new V2TIMTextElem();
            textElem->text = text;
            resultMsg.elemList.PushBack(textElem);
            // Set basic message properties
            resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
            resultMsg.userID = userID;
            resultMsg.sender = session.manager()->getAddress();
            // 保留cloudCustomData
            resultMsg.cloudCustomData = cloudCustomData;
            
            // Pass the V2TIMMessage to the callback
            callback->OnSuccess(resultMsg);
        }
        return msg_id;
    }
    else {
         // Map Tox error to V2TIM error code
        int v2_err_code = ERR_INVALID_PARAMETERS; // Default
        const char* v2_err_msg = "Unknown Tox error during send";

        switch (send_err) {
            case TOX_ERR_FRIEND_SEND_MESSAGE_FRIEND_NOT_FOUND:
                 v2_err_code = ERR_SVR_FRIENDSHIP_ACCOUNT_NOT_FOUND; // Should not happen if lookup succeeded
                 v2_err_msg = "Friend not found internally";
                 break;
            case TOX_ERR_FRIEND_SEND_MESSAGE_FRIEND_NOT_CONNECTED:
                 v2_err_code = ERR_SDK_NET_DISCONNECT;
                 v2_err_msg = "Friend not connected";
                 break;
            case TOX_ERR_FRIEND_SEND_MESSAGE_SENDQ:
                 v2_err_code = ERR_INVALID_PARAMETERS; // Or ERR_SDK_NET_REQ_COUNT_LIMIT?
                 v2_err_msg = "Send queue full";
                 break;
             case TOX_ERR_FRIEND_SEND_MESSAGE_TOO_LONG:
                 v2_err_code = ERR_SDK_MSG_BODY_SIZE_LIMIT;
                 v2_err_msg = "Message too long (Tox limit)";
                 break;
             case TOX_ERR_FRIEND_SEND_MESSAGE_EMPTY:
                  v2_err_code = ERR_INVALID_PARAMETERS;
                  v2_err_msg = "Message text cannot be empty (Tox check)";
                  break;
            default:
                  v2_err_code = ERR_INVALID_PARAMETERS;
                  v2_err_msg = "Unknown Tox error during send";
                  break;
            // Add other specific Tox errors if needed
        }
        V2TIM_LOG(kError, "SendC2CTextMessage failed with status {}", send_err);
        if (callback) callback->OnError(v2_err_code, v2_err_msg);
        return "";
    }
}

V2TIMString V2TIMManagerImpl::SendC2CCustomMessage(
    const V2TIMBuffer& customData,
    const V2TIMString& userID,
    V2TIMSendCallback* callback) {
    return SendC2CCustomMessageWithType(
        customData,
        userID,
        static_cast<uint8_t>(Type::kGenericCustom),
        callback);
}

V2TIMString V2TIMManagerImpl::SendC2CControlMessage(
    const V2TIMBuffer& customData,
    const V2TIMString& userID,
    uint8_t controlType,
    V2TIMSendCallback* callback) {
    if (controlType != static_cast<uint8_t>(Type::kReceipt) &&
        controlType != static_cast<uint8_t>(Type::kReaction)) {
        if (callback) {
            callback->OnError(
                ERR_INVALID_PARAMETERS,
                "Control type must be receipt or reaction");
        }
        return "";
    }
    return SendC2CCustomMessageWithType(
        customData, userID, controlType, callback);
}

V2TIMString V2TIMManagerImpl::SendC2CCustomMessageWithType(
    const V2TIMBuffer& customData,
    const V2TIMString& userID,
    uint8_t controlType,
    V2TIMSendCallback* callback) {
    // Validate
    if (customData.Data() == nullptr || customData.Size() == 0) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Custom data cannot be empty");
        return "";
    }
    if (userID.Empty()) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "UserID cannot be empty");
        return "";
    }

    // Resolve friend number (pinned for the whole send sequence below).
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox instance not available");
        return "";
    }

    uint8_t public_key[TOX_PUBLIC_KEY_SIZE] = {0};
    bool converted = false;
    if (userID.Length() == TOX_PUBLIC_KEY_SIZE * 2) {
        converted = ToxUtil::tox_hex_to_bytes(userID.CString(), userID.Length(), public_key, TOX_PUBLIC_KEY_SIZE);
    } else if (userID.Length() == TOX_ADDRESS_SIZE * 2) {
        uint8_t address[TOX_ADDRESS_SIZE] = {0};
        if (ToxUtil::tox_hex_to_bytes(userID.CString(), userID.Length(), address, TOX_ADDRESS_SIZE)) {
            memcpy(public_key, address, TOX_PUBLIC_KEY_SIZE);
            converted = true;
        }
    }
    if (!converted) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid userID format (must be hex Tox ID)");
        return "";
    }

    TOX_ERR_FRIEND_BY_PUBLIC_KEY find_err;
    uint32_t friend_number = tox_friend_by_public_key(tox, public_key, &find_err);
    if (find_err != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        V2TIM_LOG(kError, "SendC2CCustomMessage friend lookup failed with status {}", find_err);
        if (callback) callback->OnError(ERR_SVR_FRIENDSHIP_ACCOUNT_NOT_FOUND, "Target user is not your friend");
        return "";
    }
    
    // Check friend connection status before sending
    TOX_CONNECTION connection_status = tox_friend_get_connection_status(tox, friend_number, nullptr);
    V2TIM_LOG(kInfo, "SendC2CCustomMessage connection status {}", connection_status);
    
    // If friend is not connected, wait a bit and retry once (for test scenarios)
    if (connection_status == TOX_CONNECTION_NONE) {
        std::this_thread::sleep_for(std::chrono::seconds(2));
        
        // Re-check connection status
        connection_status = tox_friend_get_connection_status(tox, friend_number, nullptr);
        V2TIM_LOG(kInfo, "SendC2CCustomMessage retry connection status {}", connection_status);
        
        if (connection_status == TOX_CONNECTION_NONE) {
            if (callback) callback->OnError(ERR_SDK_NET_DISCONNECT, "Friend not connected");
            return "";
        }
    }

    const std::string body(
        reinterpret_cast<const char*>(customData.Data()), customData.Size());
    const auto frame = tim2tox::control::Encode(
        static_cast<Type>(controlType), body);
    if (!frame.has_value()) {
        if (callback) callback->OnError(ERR_SDK_MSG_BODY_SIZE_LIMIT, "Custom data exceeds packet limit");
        return "";
    }

    Tox_Err_Friend_Custom_Packet send_err;
    const bool sent = tox_friend_send_lossless_packet(
        tox, friend_number, frame->data(), frame->size(), &send_err);
    V2TIM_LOG(kInfo, "SendC2CCustomMessage sent {} bytes with status {}", frame->size(), send_err);

    if (sent && send_err == TOX_ERR_FRIEND_CUSTOM_PACKET_OK) {
        V2TIMString msg_id = MakeMessageId().c_str();
        if (callback) {
            V2TIMMessage resultMsg;
            resultMsg.msgID = msg_id;
            if (controlType == static_cast<uint8_t>(Type::kGenericCustom)) {
                V2TIMCustomElem* customElem = new V2TIMCustomElem();
                customElem->data = customData;
                resultMsg.elemList.PushBack(customElem);
            }
            resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
            resultMsg.userID = userID;
            resultMsg.sender = session.manager()->getAddress();
            callback->OnSuccess(resultMsg);
        }
        return msg_id;
    } else {
        int v2_err_code = ERR_INVALID_PARAMETERS;
        const char* v2_err_msg = "Custom packet send failed";
        switch (send_err) {
            case TOX_ERR_FRIEND_CUSTOM_PACKET_FRIEND_NOT_FOUND:
                v2_err_code = ERR_SVR_FRIENDSHIP_ACCOUNT_NOT_FOUND;
                v2_err_msg = "Friend not found internally";
                break;
            case TOX_ERR_FRIEND_CUSTOM_PACKET_FRIEND_NOT_CONNECTED:
                v2_err_code = ERR_SDK_NET_DISCONNECT;
                v2_err_msg = "Friend not connected";
                break;
            case TOX_ERR_FRIEND_CUSTOM_PACKET_SENDQ:
                v2_err_code = ERR_INVALID_PARAMETERS;
                v2_err_msg = "Send queue full";
                break;
            case TOX_ERR_FRIEND_CUSTOM_PACKET_TOO_LONG:
                v2_err_code = ERR_SDK_MSG_BODY_SIZE_LIMIT;
                v2_err_msg = "Custom data exceeds packet limit";
                break;
            case TOX_ERR_FRIEND_CUSTOM_PACKET_EMPTY:
                v2_err_code = ERR_INVALID_PARAMETERS;
                v2_err_msg = "Custom data cannot be empty";
                break;
            default:
                break;
        }
        if (callback) callback->OnError(v2_err_code, v2_err_msg);
        return "";
    }
}

// Send group text message
V2TIMString V2TIMManagerImpl::SendGroupTextMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback) {
    return SendGroupTextMessageWithType(
        text, groupID, priority, V2TIMBuffer(), callback, false);
}

V2TIMString V2TIMManagerImpl::SendGroupTextMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, const V2TIMBuffer& cloudCustomData, V2TIMSendCallback* callback) {
    return SendGroupTextMessageWithType(
        text, groupID, priority, cloudCustomData, callback, false);
}

V2TIMString V2TIMManagerImpl::SendGroupActionMessage(
    const V2TIMString& text,
    const V2TIMString& groupID,
    V2TIMMessagePriority priority,
    V2TIMSendCallback* callback) {
    return SendGroupTextMessageWithType(
        text, groupID, priority, V2TIMBuffer(), callback, true);
}

V2TIMString V2TIMManagerImpl::SendGroupTextMessageWithType(
    const V2TIMString& text,
    const V2TIMString& groupID,
    V2TIMMessagePriority priority,
    const V2TIMBuffer& cloudCustomData,
    V2TIMSendCallback* callback,
    bool force_action) {
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] ========== ENTRY ==========");
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] groupID={}, text_length={}", groupID.CString(), text.Length());
    
    // ===================================================================
    // Step 1: Validate parameters
    // ===================================================================
    auto prepared = tim2tox::qtox::PrepareTextMessage(
        std::string_view(text.CString(), text.Length()), force_action);
    if (!prepared.has_value()) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupTextMessage] Message text is empty");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Message text must be valid non-empty UTF-8 without NUL bytes");
        return "";
    }
    if (groupID.Empty()) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupTextMessage] Group ID is empty");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group ID cannot be empty");
        return "";
    }

    // Ignore priority for now, as Tox core doesn't directly support it for group messages

    // ===================================================================
    // Step 2: Find the group number for the group ID
    // ===================================================================
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_); // Protect access to the map
        auto it = group_id_to_group_number_.find(groupID);
        if (it == group_id_to_group_number_.end()) {
            V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupTextMessage] Group not found in map: groupID={}", groupID.CString());
            V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupTextMessage] Available groups in map: {}", group_id_to_group_number_.size());
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group not found or user not in group");
            return "";
        }
        group_number = it->second;
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Found group_number={} for groupID={}", group_number, groupID.CString());
    }

    // ===================================================================
    // Step 3: Process reply reference if present
    // ===================================================================
    std::string finalMessageText(prepared->body);
    
    // 检查是否有引用回复信息
    std::string replyJson = MessageReplyUtil::ExtractReplyJsonFromCloudCustomData(cloudCustomData);
    if (prepared->type == TOX_MESSAGE_TYPE_NORMAL && !replyJson.empty()) {
        // 构建包含引用回复的消息
        std::string messageWithReply = MessageReplyUtil::BuildMessageWithReply(replyJson, finalMessageText);
        
        // 检查消息长度
        if (MessageReplyUtil::IsMessageTooLong(messageWithReply)) {
            // 如果消息过长，尝试压缩引用信息
            std::string compressedReply = MessageReplyUtil::CompressReplyJson(replyJson);
            messageWithReply = MessageReplyUtil::BuildMessageWithReply(compressedReply, finalMessageText);
            
            // 如果还是太长，只保留messageID
            if (MessageReplyUtil::IsMessageTooLong(messageWithReply)) {
                // 提取messageID
                std::string messageID = MessageReplyUtil::ExtractJsonValue(replyJson, "messageID");
                if (!messageID.empty()) {
                    std::string minimalReply = "{\"version\":1,\"messageID\":\"" + messageID + "\"}";
                    messageWithReply = MessageReplyUtil::BuildMessageWithReply(minimalReply, finalMessageText);
                }
            }
        }
        
        finalMessageText = messageWithReply;
    }

    prepared->body = finalMessageText;

    const auto fragments = tim2tox::qtox::FragmentMessage(prepared->body);
    if (!fragments.has_value()) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Message cannot be fragmented");
        return "";
    }

    // ===================================================================
    // Step 5: Send the message using ToxManager
    V2TIMString msgID = MakeMessageId().c_str();

    // The map key alone decides the kind: every in-memory conference entry is
    // tagged (the maps are rebuilt each session). Decided up front so no NGC
    // API below is ever handed a tagged conference key.
    const bool use_conference = IsConferenceMapKey(group_number);

    // Pinned for everything below (preflight, fragment loop, result build):
    // this runs on the FFI caller's thread, so a concurrent UnInitSDK could
    // otherwise free the manager/Tox between two of these calls.
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return "";
    }

    // NGC-only diagnostic preflight (group connection, self peer, peer scan).
    if (!use_conference) {
        Tox_Err_Group_Is_Connected err_conn;
        bool group_connected = session.manager()->isGroupConnected(group_number, &err_conn);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Group connection status: connected={}, err={}",
                 group_connected, static_cast<int>(err_conn));
    }

    // Check self connection status
    Tox* tox = session.tox();
    if (tox && !use_conference) {
        TOX_CONNECTION self_conn = tox_self_get_connection_status(tox);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Self connection status: {}", static_cast<int>(self_conn));
        static_cast<void>(0);
        static_cast<void>(0);
        
        // Check group peer count (approximate by trying to get peer IDs)
        int peer_count = 0;
        Tox_Err_Group_Self_Query err_self;
        Tox_Group_Peer_Number self_peer_id = tox_group_self_get_peer_id(tox, group_number, &err_self);
        
        // Get self public key for comparison
        uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, self_pubkey);
        std::string self_pubkey_hex = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
        
        if (err_self == TOX_ERR_GROUP_SELF_QUERY_OK) {
            static_cast<void>(0);
            static_cast<void>(0);
            
            // Try to count peers by iterating
            for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                Tox_Err_Group_Peer_Query err_peer;
                if (tox_group_peer_get_public_key(tox, group_number, peer_id, peer_pubkey, &err_peer) &&
                    err_peer == TOX_ERR_GROUP_PEER_QUERY_OK) {
                    peer_count++;
                    std::string peer_userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
                    bool is_self = (memcmp(peer_pubkey, self_pubkey, TOX_PUBLIC_KEY_SIZE) == 0);
                    if (peer_count <= 3) { // Log first 3 peers
                        static_cast<void>(0);
                        static_cast<void>(0);
                    }
                    // Check if self_peer_id matches actual self peer
                    if (is_self && peer_id != self_peer_id) {
                        static_cast<void>(0);
                        static_cast<void>(0);
                    }
                } else if (peer_id > 10) {
                    // Stop after 10 consecutive errors
                    break;
                }
            }
            static_cast<void>(0);
            static_cast<void>(0);
        }
    }
    
    // Check if this is a conference-type group (needs different send API)
    std::string group_type_val;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto type_it = group_id_to_type_.find(groupID);
        if (type_it != group_id_to_type_.end()) {
            group_type_val = type_it->second;
        }
    }

    Tox_Group_Message_Id message_id = 0;
    // Publish the FIRST fragment's cross-peer id for the Dart caller. Reset up
    // front so a conference send or a failure cannot leave a stale id behind
    // for the next caller to mis-stamp onto its row.
    bool first_pseudo_id_published = false;
    SetLastGroupSendMessageId(-1);
    // Publish the identity peers will attribute this message to. An NGC peer
    // is known by a PER-GROUP key, not by its long-term Tox ID, so the author
    // must scope its own alias by the same key the receivers will see in the
    // event line — otherwise the two sides derive different aliases for the
    // very same message and nothing correlates.
    // A conference send publishes no message id, hence no alias: leave it "".
    SetLastGroupSendSelfKey("");
    if (tox && !use_conference) {
        uint8_t self_group_pubkey[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Self_Query err_self_key = TOX_ERR_GROUP_SELF_QUERY_OK;
        if (tox_group_self_get_public_key(tox, group_number, self_group_pubkey,
                                          &err_self_key) &&
            err_self_key == TOX_ERR_GROUP_SELF_QUERY_OK) {
            SetLastGroupSendSelfKey(
                ToxUtil::tox_bytes_to_hex(self_group_pubkey,
                                          TOX_PUBLIC_KEY_SIZE)
                    .c_str());
        }
    }
    Tox_Err_Group_Send_Message send_err = TOX_ERR_GROUP_SEND_MESSAGE_OK;
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] About to send {} fragments to group_number={} group_type='{}'",
             fragments->size(), group_number, group_type_val);

    bool success = true;
    // use_conference (decided above from the map key): an untagged key with a
    // "conference" label means the LABEL is stale — honouring it would send
    // this text into an unrelated conference with the same number.
    if (!use_conference && (group_type_val == "conference" || group_type_val == "av_conference")) {
        V2TIM_LOG(kWarning, "[SendGroupTextMessage] {} is labelled '{}' but mapped to an NGC group; sending as NGC",
                  groupID.CString(), group_type_val);
    }
    for (const auto& fragment : *fragments) {
        if (use_conference) {
            if (!tox) {
                success = false;
                send_err = TOX_ERR_GROUP_SEND_MESSAGE_FAIL_SEND;
                break;
            }
            Tox_Err_Conference_Send_Message conference_error;
            success = tox_conference_send_message(
                tox,
                ConferenceNumberFromKey(group_number),
                prepared->type,
                reinterpret_cast<const uint8_t*>(fragment.data()),
                fragment.size(),
                &conference_error);
            if (!success) {
                send_err = TOX_ERR_GROUP_SEND_MESSAGE_FAIL_SEND;
                break;
            }
            continue;
        }

        success = session.manager()->groupSendMessage(
            group_number,
            prepared->type,
            reinterpret_cast<const uint8_t*>(fragment.data()),
            fragment.size(),
            &message_id,
            &send_err);
        if (success) {
            if (!first_pseudo_id_published) {
                SetLastGroupSendMessageId(static_cast<int64_t>(message_id));
                first_pseudo_id_published = true;
            }
            continue;
        }

        // No "NGC group not found -> try a conference with the same number"
        // fallback: the two number spaces overlap, so that fallback sent the
        // text into an unrelated conference.
        break;
    }

    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] groupSendMessage returned: success={}, message_id={}, send_err={}",
             success, message_id, static_cast<int>(send_err));
    static_cast<void>(0);
    static_cast<void>(0);

    // ===================================================================
    // Step 5: Forward to IRC if this is an IRC channel (handled by dynamic library)
    // ===================================================================
    // Forward Tox message to IRC via FFI (if library is loaded)
    std::string sender_nick = session.manager()->getName();
    if (sender_nick.empty()) {
        sender_nick = "ToxUser";
    }
    tim2tox_ffi_irc_forward_tox_message(groupID.CString(), sender_nick.c_str(), finalMessageText.c_str());

    // ===================================================================
    // Step 6: Handle the result
    // ===================================================================
    if (success) {
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupTextMessage] Message sent successfully, msgID: {}", msgID.CString());
        // Tox group send is fire-and-forget, success means it was queued.
        if (callback) {
             // Create a V2TIMMessage
             V2TIMMessage resultMsg;
             resultMsg.msgID = msgID;

             // Add text element
             V2TIMTextElem* textElem = new V2TIMTextElem();
             textElem->text = text;
             resultMsg.elemList.PushBack(textElem);

             // Set basic message properties
             resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                 std::chrono::system_clock::now().time_since_epoch()).count();
             resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
             resultMsg.groupID = groupID;
             resultMsg.sender = session.manager()->getAddress();
             // 保留cloudCustomData
             resultMsg.cloudCustomData = cloudCustomData;

             // Pass the message to the callback
             callback->OnSuccess(resultMsg);
        }
        return msgID;
    } else {
        // Map Tox error to V2TIM error code
        int v2_err_code = ERR_INVALID_PARAMETERS; // Default error
        const char* v2_err_msg = "Failed to send group message";
        switch (send_err) {
            case TOX_ERR_GROUP_SEND_MESSAGE_GROUP_NOT_FOUND:
                 // This implies the group_number became invalid between lookup and send,
                 // or the ToxManager instance disappeared.
                 v2_err_code = ERR_INVALID_PARAMETERS; // Or perhaps ERR_SDK_NOT_INITIALIZED
                 v2_err_msg = "Internal error: Group number invalid or Tox instance gone";
                 break;
            case TOX_ERR_GROUP_SEND_MESSAGE_TOO_LONG:
                 v2_err_code = ERR_SDK_MSG_BODY_SIZE_LIMIT;
                 v2_err_msg = "Message too long";
                 break;
            case TOX_ERR_GROUP_SEND_MESSAGE_DISCONNECTED:
                  v2_err_code = ERR_SDK_NET_DISCONNECT; // Map to general network error
                  v2_err_msg = "Not connected to the group chat network";
                  break;
            case TOX_ERR_GROUP_SEND_MESSAGE_FAIL_SEND:
                  v2_err_code = ERR_INVALID_PARAMETERS;
                  v2_err_msg = "Failed to send message to group";
                  break;
            default:
                  v2_err_code = ERR_INVALID_PARAMETERS;
                  v2_err_msg = "Unknown error sending group message";
                  break;
             // Add more cases as needed based on toxcore version/errors
        }
        V2TIM_LOG(kError, "SendGroupTextMessage failed: groupID=%s, error=%d (%s), tox_err=%d", groupID.CString(), v2_err_code, v2_err_msg, send_err);
        if (callback) callback->OnError(v2_err_code, v2_err_msg);
        return "";
    }
}

// The CURRENT peer id of the member whose per-group public key is
// receiver_hex, or UINT32_MAX. Cached ids are revalidated: toxcore re-issues
// the lowest free id, so a stale entry would address whoever joined after the
// member left.
Tox_Group_Peer_Number V2TIMManagerImpl::ResolveGroupPeerIdForKey(Tox_Group_Number group_number, const std::string& receiver_hex) {
    // Own pin: callers reach this from the FFI thread (send / receipt paths)
    // and from tox callbacks alike, and the loop below makes up to 256 manager
    // calls. Without it, an UnInitSDK mid-loop leaves GetToxManager() null
    // (the manager is unpublished before it is torn down) and the unchecked
    // derefs below would fault.
    const ToxSessionGuard session = AcquireToxSession();
    ToxManager* tox_manager = session.manager();
    if (!tox_manager) return UINT32_MAX;
    Tox_Group_Peer_Number peer_id = UINT32_MAX;
    {
        std::string key_lower = receiver_hex;
        std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(), ::tolower);
        std::lock_guard<std::mutex> lock(mutex_);
        auto it_grp = group_peer_id_cache_.find(group_number);
        if (it_grp != group_peer_id_cache_.end()) {
            auto it_pk = it_grp->second.find(key_lower);
            if (it_pk != it_grp->second.end()) {
                peer_id = it_pk->second;
                V2TIM_LOG(kInfo, "[ResolveGroupPeerIdForKey] Resolved peer_id={} from cache for receiver {}", peer_id, receiver_hex);
            }
        }
    }
    if (peer_id != UINT32_MAX) {
        // A cached peer_id is only usable if it STILL belongs to the receiver:
        // toxcore re-issues the lowest free id, so a stale entry would deliver
        // this PRIVATE message to whoever joined after the receiver left.
        uint8_t expected_pubkey[TOX_PUBLIC_KEY_SIZE];
        uint8_t current_pubkey[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Peer_Query err_current;
        const bool still_owner =
            ToxUtil::tox_hex_to_bytes(receiver_hex.c_str(), receiver_hex.size(), expected_pubkey, TOX_PUBLIC_KEY_SIZE) &&
            tox_manager->getGroupPeerPublicKey(group_number, peer_id, current_pubkey, &err_current) &&
            err_current == TOX_ERR_GROUP_PEER_QUERY_OK &&
            memcmp(expected_pubkey, current_pubkey, TOX_PUBLIC_KEY_SIZE) == 0;
        if (!still_owner) {
            V2TIM_LOG(kWarning, "[ResolveGroupPeerIdForKey] cached peer_id={} no longer belongs to receiver {}; dropping stale cache entry", peer_id, receiver_hex);
            ErasePeerIdCacheEntry(group_number, receiver_hex);
            peer_id = UINT32_MAX;
        }
    }
    if (peer_id == UINT32_MAX) {
        // Fallback: iterate group peers by public key
        uint8_t target_pubkey[TOX_PUBLIC_KEY_SIZE];
        if (!ToxUtil::tox_hex_to_bytes(receiver_hex.c_str(), receiver_hex.size(), target_pubkey, TOX_PUBLIC_KEY_SIZE)) {
            return UINT32_MAX;
        }
        uint32_t consecutive_fail = 0;
        for (Tox_Group_Peer_Number p = 0; p < 256; ++p) {
            uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_Peer_Query err;
            if (tox_manager->getGroupPeerPublicKey(group_number, p, peer_pubkey, &err) && err == TOX_ERR_GROUP_PEER_QUERY_OK) {
                consecutive_fail = 0;
                if (memcmp(peer_pubkey, target_pubkey, TOX_PUBLIC_KEY_SIZE) == 0) {
                    peer_id = p;
                    break;
                }
            } else {
                if (++consecutive_fail > 48) break;
            }
        }
    }
    return peer_id;
}

V2TIMString V2TIMManagerImpl::SendGroupPrivateTextMessage(const V2TIMString& groupID, const V2TIMString& receiverPublicKey64, const V2TIMString& text, V2TIMSendCallback* callback) {
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] groupID={}, receiver_len={}, text_length={}", groupID.CString(), receiverPublicKey64.Length(), text.Length());
    if (groupID.Empty() || receiverPublicKey64.Empty() || text.Empty()) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Empty groupID, receiver or text");
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "GroupID, receiver and text cannot be empty");
        return "";
    }
    std::string receiver_hex(receiverPublicKey64.CString());
    if (receiver_hex.size() != static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2)) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Receiver must be 64-char hex public key, got length {}", receiver_hex.size());
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Receiver must be 64-char hex public key");
        return "";
    }
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it == group_id_to_group_number_.end()) {
            V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Group not found: groupID={}", groupID.CString());
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group not found or user not in group");
            return "";
        }
        group_number = it->second;
    }
    // Legacy conferences have no private messages; a tagged key must never
    // reach tox_group_send_private_message (it would only report not-found).
    if (IsConferenceMapKey(group_number)) {
        V2TIM_LOG(kWarning, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] {} is a conference: private messages are not supported",
                  groupID.CString());
        if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Private messages are not supported in conferences");
        return "";
    }
    // Pinned across the peer lookup + send below (FFI caller thread).
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NET_DISCONNECT, "Tox not available");
        return "";
    }
    const Tox_Group_Peer_Number peer_id = ResolveGroupPeerIdForKey(group_number, receiver_hex);
    if (peer_id == UINT32_MAX) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::SendGroupPrivateTextMessage] Peer not found in group for receiver {}", receiver_hex);
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Receiver not found in group");
        return "";
    }
    Tox_Err_Group_Send_Private_Message err_priv;
    Tox_Group_Message_Id msg_id = tox_group_send_private_message(
        tox, group_number, peer_id, TOX_MESSAGE_TYPE_NORMAL,
        reinterpret_cast<const uint8_t*>(text.CString()), text.Length(), &err_priv);
    if (err_priv != TOX_ERR_GROUP_SEND_PRIVATE_MESSAGE_OK) {
        const char* err_msg = "Failed to send group private message";
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, err_msg);
        return "";
    }
    uint64_t ts = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    char msg_id_buf[80];
    snprintf(msg_id_buf, sizeof(msg_id_buf), "gp%llu-%llu", (unsigned long long)ts, (unsigned long long)msg_id);
    V2TIMString msgID = msg_id_buf;
    if (callback) {
        V2TIMMessage resultMsg;
        resultMsg.msgID = msgID;
        V2TIMTextElem* textElem = new V2TIMTextElem();
        textElem->text = text;
        resultMsg.elemList.PushBack(textElem);
        resultMsg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        resultMsg.status = V2TIM_MSG_STATUS_SEND_SUCC;
        resultMsg.groupID = groupID;
        resultMsg.sender = session.manager()->getAddress();
        callback->OnSuccess(resultMsg);
    }
    return msgID;
}

// Send group custom message
V2TIMString V2TIMManagerImpl::SendGroupCustomMessage(const V2TIMBuffer& customData, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback) {
    (void)priority;
    if (customData.Size() == 0 || groupID.Empty()) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Custom data and group ID are required");
        return "";
    }

    // Pinned for the whole send sequence (FFI caller thread).
    const ToxSessionGuard session = AcquireToxSession();
    ToxManager* tox_manager = session.manager();
    Tox* tox = session.tox();
    if (!tox || !running_) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return "";
    }

    Tox_Group_Number group_number = UINT32_MAX;
    std::string group_type;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto group_it = group_id_to_group_number_.find(groupID);
        if (group_it == group_id_to_group_number_.end()) {
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group not found or user not in group");
            return "";
        }
        group_number = group_it->second;
        const auto type_it = group_id_to_type_.find(groupID);
        if (type_it != group_id_to_type_.end()) group_type = type_it->second;
    }

    if (IsConferenceMapKey(group_number)) {
        if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT, "Legacy conferences do not support custom packets");
        return "";
    }

    const std::vector<uint8_t> packet = WrapTim2ToxGroupPacket(
        kTim2ToxGroupPacketCustomMessage, customData.Data(), customData.Size());
    Tox_Err_Group_Send_Custom_Packet send_error;
    const bool sent = tox_group_send_custom_packet(
        tox,
        group_number,
        true,
        packet.data(),
        packet.size(),
        &send_error);
    if (!sent) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to send group custom message");
        return "";
    }

    const V2TIMString msg_id = MakeMessageId().c_str();
    if (callback) {
        V2TIMMessage result = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager())
            ->CreateCustomMessage(customData);
        result.msgID = msg_id;
        result.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        result.status = V2TIM_MSG_STATUS_SEND_SUCC;
        result.groupID = groupID;
        result.sender = tox_manager->getAddress();
        callback->OnSuccess(result);
    }
    return msg_id;
}

// Group Management
void V2TIMManagerImpl::AddGroupListener(V2TIMGroupListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_listeners_.insert(listener);
}

void V2TIMManagerImpl::RemoveGroupListener(V2TIMGroupListener* listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    group_listeners_.erase(listener);
}

void V2TIMManagerImpl::CreateGroup(const V2TIMString& groupType, const V2TIMString& groupID, const V2TIMString& groupName, V2TIMValueCallback<V2TIMString>* callback) {
    V2TIM_LOG(kInfo, "CreateGroup: ENTRY - groupType={}, groupID={}, groupName={}, callback={}",
              groupType.CString() ? groupType.CString() : "null",
              groupID.CString() ? groupID.CString() : "null",
              groupName.CString() ? groupName.CString() : "null",
              (void*)callback);
    
    // Step 1: Get ToxManager. Pinned for the whole create sequence (group
    // creation, name/topic writes, the optional AV groupchat) — an FFI entry
    // point, so UnInitSDK can otherwise land between any two of those calls.
    V2TIM_LOG(kInfo, "CreateGroup: Step 1 - Getting ToxManager");
    const ToxSessionGuard session = AcquireToxSession();
    ToxManager* tox_manager = session.manager();
    V2TIM_LOG(kInfo, "CreateGroup: Step 1 - AcquireToxSession() returned {}", (void*)tox_manager);
    
    if (!tox_manager) {
        V2TIM_LOG(kError, "CreateGroup: ERROR - ToxManager is null, cannot proceed");
        if (callback) {
            V2TIM_LOG(kInfo, "CreateGroup: Calling callback->OnError with ERR_SDK_NOT_INITIALIZED");
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: callback is null, cannot report error");
        }
        V2TIM_LOG(kInfo, "CreateGroup: EXIT - Early return due to null ToxManager");
        return;
    }
    
    // Step 2: Get Tox instance
    V2TIM_LOG(kInfo, "CreateGroup: Step 2 - Getting Tox instance from ToxManager");
    Tox* tox = session.tox();
    V2TIM_LOG(kInfo, "CreateGroup: Step 2 - pinned Tox is {}", (void*)tox);
    
    if (!tox) {
        V2TIM_LOG(kError, "CreateGroup: ERROR - Tox instance is null, cannot proceed");
        if (callback) {
            V2TIM_LOG(kInfo, "CreateGroup: Calling callback->OnError with ERR_SDK_NOT_INITIALIZED");
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: callback is null, cannot report error");
        }
        V2TIM_LOG(kInfo, "CreateGroup: EXIT - Early return due to null Tox instance");
        return;
    }

    // Step 3: Check group type and determine privacy state
    V2TIM_LOG(kInfo, "CreateGroup: Step 3 - Checking group type");
    std::string group_type_str = groupType.CString() ? std::string(groupType.CString()) : "";
    V2TIM_LOG(kInfo, "CreateGroup: Step 3 - group_type_str={}", group_type_str);
    bool is_conference = (group_type_str == "conference");
    bool is_av_conference = (group_type_str == "av_conference");
    bool is_legacy_conference = is_conference || is_av_conference;
    
    // "Private" (kTIMGroup_Private) -> PRIVATE: peer discovery via friend connections (faster in test)
    // "conference" -> PRIVATE (invite-only)
    // "Public" or "Meeting" -> PUBLIC (DHT discovery)
    // "group" (default) -> PUBLIC
    Tox_Group_Privacy_State privacy_state = TOX_GROUP_PRIVACY_STATE_PUBLIC;
    if (group_type_str == "Private" || is_legacy_conference) {
        privacy_state = TOX_GROUP_PRIVACY_STATE_PRIVATE;
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kInfo, "CreateGroup: Step 3 - Setting privacy_state to PRIVATE");
    } else if (group_type_str == "Public" || group_type_str == "Meeting") {
        privacy_state = TOX_GROUP_PRIVACY_STATE_PUBLIC;
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kInfo, "CreateGroup: Step 3 - Setting privacy_state to PUBLIC");
    } else {
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kInfo, "CreateGroup: Step 3 - Using default privacy_state PUBLIC");
    }
    
    // Step 4: Get group name and self name
    V2TIM_LOG(kInfo, "CreateGroup: Step 4 - Getting group name and self name");
    std::string group_name_str = groupName.Empty() ? "Group" : (groupName.CString() ? std::string(groupName.CString()) : "Group");
    V2TIM_LOG(kInfo, "CreateGroup: Step 4 - group_name_str={}, length={}", group_name_str, group_name_str.length());
    
    std::string self_name = tox_manager->getName();
    V2TIM_LOG(kInfo, "CreateGroup: Step 4 - Initial self_name={}, length={}", self_name, self_name.length());
    if (self_name.empty()) {
        self_name = "User";
        V2TIM_LOG(kInfo, "CreateGroup: Step 4 - self_name was empty, using default 'User'");
    }
    V2TIM_LOG(kInfo, "CreateGroup: Step 4 - Final self_name={}, length={}", self_name, self_name.length());
    
    // Step 5: Create group or conference based on type
    uint32_t group_number = UINT32_MAX;
    bool creation_success = false;
    Tox_Err_Group_New err_new = TOX_ERR_GROUP_NEW_OK; // Initialize for group type
    
    if (is_conference) {
        // Create conference using tox_conference_new (old API)
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - Creating conference (old API) using tox_conference_new");
        Tox_Err_Conference_New err_conf;
        // [tim2tox-debug] Record tox_conference_new call for conference creation
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: Calling tox_conference_new for conference creation");
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: tox={}, err_conf_ptr={}", (void*)tox, (void*)&err_conf);
        Tox_Conference_Number conference_number = tox_conference_new(tox, &err_conf);
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: tox_conference_new returned: conference_number={}, err_conf={}", 
                 conference_number, static_cast<int>(err_conf));
        
        if (err_conf != TOX_ERR_CONFERENCE_NEW_OK || conference_number == UINT32_MAX) {
            V2TIM_LOG(kError, "CreateGroup: ERROR - Failed to create conference: err_conf={}, conference_number={}", 
                     static_cast<int>(err_conf), conference_number);
            if (callback) {
                callback->OnError(ERR_INVALID_PARAMETERS, "Failed to create Tox conference");
            }
            V2TIM_LOG(kInfo, "CreateGroup: EXIT - Early return due to conference creation failure");
            return;
        }
        
        // Conferences live under a tagged map key (see ConferenceMapKey).
        group_number = ConferenceMapKey(conference_number);
        creation_success = true;
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - SUCCESS - Conference created with conference_number={}", conference_number);
    } else if (is_av_conference) {
#ifdef BUILD_TOXAV
        ToxAVManager* av_manager = GetToxAVManager();
        if (av_manager == nullptr) {
            if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT,
                                             "ToxAV manager unavailable");
            return;
        }
        try {
            av_manager->initialize(this);
        } catch (const std::exception& error) {
            if (std::string(error.what()).find("already initialized") ==
                std::string::npos) {
                if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT,
                                                 "ToxAV initialization failed");
                return;
            }
        }
        Tox* av_tox = session.tox();
        // Legacy group AV takes no toxcore lock; keep it out of tox_iterate()
        // (see ToxAVManager::lockToxIterate).
        int32_t created = -1;
        {
            auto av_iterate_lock = tox_manager->lockIterate();
            created = toxav_add_av_groupchat(
                av_tox, HandleAVConferenceAudio, this);
        }
        if (created < 0) {
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS,
                                             "Failed to create AV conference");
            return;
        }
        group_number = ConferenceMapKey(static_cast<uint32_t>(created));
        creation_success = true;
#else
        if (callback) callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT,
                                         "ToxAV is unavailable");
        return;
#endif
    } else {
        // Create group using tox_group_new (new API)
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - Creating group (new API) using tox_manager->createGroup");
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - Parameters: privacy_state={}, group_name_len={}, self_name_len={}", 
                  privacy_state, group_name_str.length(), self_name.length());
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - group_name_str.c_str()={}, self_name.c_str()={}", 
                  (void*)group_name_str.c_str(), (void*)self_name.c_str());
        
        // [tim2tox-debug] Record tox_group_new call for group creation
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: Calling tox_manager->createGroup (tox_group_new)");
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: privacy_state={}, group_name_len={}, self_name_len={}", 
                 privacy_state, group_name_str.length(), self_name.length());
        Tox_Group_Number created_group_number = tox_manager->createGroup(
            privacy_state,
            reinterpret_cast<const uint8_t*>(group_name_str.c_str()), group_name_str.length(),
            reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
            &err_new
        );
        V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: tox_manager->createGroup returned: group_number={}, err_new={}", 
                 created_group_number, static_cast<int>(err_new));
        
        V2TIM_LOG(kInfo, "CreateGroup: Step 5 - createGroup returned: group_number={}, err_new={}", 
                  created_group_number, static_cast<int>(err_new));

        if (err_new != TOX_ERR_GROUP_NEW_OK || created_group_number == UINT32_MAX) {
            group_number = UINT32_MAX;
            creation_success = false;
        } else {
            group_number = created_group_number;
            creation_success = true;
        }
    }
    
    if (!creation_success || group_number == UINT32_MAX) {
        // Map Tox error to specific error messages for better debugging
        const char* tox_error_name = "UNKNOWN";
        std::string detailed_msg = "Failed to create Tox group";
        
        switch (err_new) {
            case TOX_ERR_GROUP_NEW_OK:
                tox_error_name = "OK";
                break;
            case TOX_ERR_GROUP_NEW_TOO_LONG:
                tox_error_name = "TOO_LONG";
                detailed_msg = "Group name or self name exceeds maximum length";
                break;
            case TOX_ERR_GROUP_NEW_EMPTY:
                tox_error_name = "EMPTY";
                detailed_msg = "Group name or self name is empty";
                break;
            case TOX_ERR_GROUP_NEW_INIT:
                tox_error_name = "INIT";
                detailed_msg = "Group instance failed to initialize (Tox may not be ready)";
                break;
            case TOX_ERR_GROUP_NEW_STATE:
                tox_error_name = "STATE";
                detailed_msg = "Group state failed to initialize (cryptographic signing error)";
                break;
            case TOX_ERR_GROUP_NEW_ANNOUNCE:
                tox_error_name = "ANNOUNCE";
                detailed_msg = "Group failed to announce to DHT (network error, may need connection)";
                break;
            default:
                tox_error_name = "UNKNOWN";
                detailed_msg = "Unknown error from tox_group_new";
                break;
        }
        
        V2TIM_LOG(kError, "CreateGroup: ERROR - Failed to create group: err_new={} ({}), group_number={}, group_name_len={}, self_name_len={}", 
                  static_cast<int>(err_new), tox_error_name, group_number, group_name_str.length(), self_name.length());
        V2TIM_LOG(kError, "CreateGroup: ERROR - Detailed message: {}", detailed_msg);
        
        // Check connection status for network-related errors
        if (err_new == TOX_ERR_GROUP_NEW_ANNOUNCE || err_new == TOX_ERR_GROUP_NEW_INIT) {
            TOX_CONNECTION connection = tox_self_get_connection_status(tox);
            V2TIM_LOG(kError, "CreateGroup: ERROR - Tox connection status: {} (0=NONE, 1=UDP, 2=TCP)", static_cast<int>(connection));
            if (connection == TOX_CONNECTION_NONE) {
                detailed_msg += " (Tox not connected to network)";
            }
        }
        
        // Map Tox error to V2TIM error
        int v2_err = ERR_INVALID_PARAMETERS;
        if (callback) {
            V2TIM_LOG(kInfo, "CreateGroup: Calling callback->OnError with v2_err={}, detailed_msg={}", v2_err, detailed_msg);
            callback->OnError(v2_err, detailed_msg.c_str());
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: callback is null, cannot report error");
        }
        V2TIM_LOG(kInfo, "CreateGroup: EXIT - Early return due to createGroup failure");
        return;
    }
    
    V2TIM_LOG(kInfo, "CreateGroup: Step 5 - SUCCESS - Group created with group_number={}", group_number);

    // Determine the final Group ID
    V2TIMString finalGroupID = groupID;
    if (finalGroupID.Empty()) {
        // Generate a unique ID if none provided.
        // IMPORTANT: Do NOT use conference_number directly, as Tox may reuse conference numbers
        // when groups are deleted. Instead, use a global counter to ensure uniqueness.
        
        // First, find the maximum ID number from all existing group IDs to avoid conflicts
        // This handles the case where groups were restored from persistence but mappings were cleared
        // We scan both the mapping and V2TIMGroupManagerImpl to find the highest numeric ID
        uint64_t max_existing_id = 0;
        
        // Scan the mapping (need to lock for this)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto& pair : group_id_to_group_number_) {
                const std::string& existing_id = pair.first.CString();
                // Check if it matches "tox_<number>" pattern
                if (existing_id.length() > 4 && existing_id.substr(0, 4) == "tox_") {
                    try {
                        uint64_t id_num = std::stoull(existing_id.substr(4));
                        if (id_num > max_existing_id) {
                            max_existing_id = id_num;
                        }
                    } catch (...) {
                        // Ignore parsing errors for non-numeric IDs (e.g., "tox_community_123")
                    }
                }
            }
        }
        
        // Also check from Dart layer's persistence storage to get groups that might be restored
        // but not yet in the mapping (e.g., during startup before GetJoinedGroupList is called)
        // This is critical to avoid ID conflicts with restored groups
        // Note: We call this OUTSIDE the mutex lock to avoid deadlock
        // R-07: Use Core metadata (known groups)
        std::vector<std::string> known = GetKnownGroupIDs();
        if (!known.empty()) {
            V2TIM_LOG(kInfo, "CreateGroup: GetKnownGroupIDs returned {} group IDs", known.size());
            for (const auto& line : known) {
                if (line.empty()) continue;
                V2TIM_LOG(kInfo, "CreateGroup: checking existing group ID: {}", line);
                if (line.length() > 4 && line.substr(0, 4) == "tox_") {
                    try {
                        uint64_t id_num = std::stoull(line.substr(4));
                        if (id_num > max_existing_id) {
                            max_existing_id = id_num;
                            V2TIM_LOG(kInfo, "CreateGroup: updated max_existing_id to {}", max_existing_id);
                        }
                    } catch (...) {
                        V2TIM_LOG(kWarning, "CreateGroup: failed to parse ID number from {}", line);
                    }
                }
            }
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: GetKnownGroupIDs returned 0, falling back to GetAllGroupIDsSync");
            // Fallback to GetAllGroupIDsSync if FFI call fails
            V2TIMGroupManagerImpl* groupManagerImpl = static_cast<V2TIMGroupManagerImpl*>(GetGroupManager());
            if (groupManagerImpl) {
                std::vector<std::string> all_group_ids = groupManagerImpl->GetAllGroupIDsSync();
                V2TIM_LOG(kInfo, "CreateGroup: GetAllGroupIDsSync returned {} group IDs", all_group_ids.size());
                for (const auto& existing_id : all_group_ids) {
                    V2TIM_LOG(kInfo, "CreateGroup: checking existing group ID: {}", existing_id);
                    // Check if it matches "tox_<number>" pattern
                    if (existing_id.length() > 4 && existing_id.substr(0, 4) == "tox_") {
                        try {
                            uint64_t id_num = std::stoull(existing_id.substr(4));
                            V2TIM_LOG(kInfo, "CreateGroup: parsed ID number: {} from {}", id_num, existing_id);
                            if (id_num > max_existing_id) {
                                max_existing_id = id_num;
                                V2TIM_LOG(kInfo, "CreateGroup: updated max_existing_id to {}", max_existing_id);
                            }
                        } catch (...) {
                            // Ignore parsing errors for non-numeric IDs
                            V2TIM_LOG(kWarning, "CreateGroup: failed to parse ID number from {}", existing_id);
                        }
                    }
                }
            }
        }
        
        max_existing_id = std::max(max_existing_id, GetRetiredGroupIdMax());

        // Now lock again to update the counter and generate the new ID
        {
            std::lock_guard<std::mutex> lock(mutex_);
            // Use global counter so "tox_0","tox_1",... are unique across all instances.
            // Prevents JoinGroup(on instance B) from matching stored_chat_id from instance A
            // when both use the same string "tox_0" for different groups.
            uint64_t candidate_id = g_next_group_id_global.fetch_add(1);
            next_group_id_counter_ = candidate_id + 1; // Keep per-instance in sync for local use

            // CRITICAL FIX: Ensure candidate_id is at least max_existing_id + 1
            // Without this, the global counter may start at 0 and generate "tox_0" which
            // already exists in Dart persistence (from a previous session), causing ID reuse
            // and historical messages being loaded for the new group.
            if (candidate_id <= max_existing_id) {
                candidate_id = max_existing_id + 1;
                // Update global counter so subsequent calls also start from the right place
                uint64_t expected = g_next_group_id_global.load();
                while (expected <= candidate_id) {
                    if (g_next_group_id_global.compare_exchange_weak(expected, candidate_id + 1)) {
                        break;
                    }
                }
                next_group_id_counter_ = candidate_id + 1;
                V2TIM_LOG(kInfo, "CreateGroup: Bumped candidate_id to {} (was <= max_existing_id={})",
                          candidate_id, max_existing_id);
            }

            V2TIM_LOG(kInfo, "CreateGroup: max_existing_id={}, candidate_id={} (global)",
                      max_existing_id, candidate_id);

            char generated_id_buf[32]; // Enough for "tox_" + uint64_t
            snprintf(generated_id_buf, sizeof(generated_id_buf), "tox_%llu", (unsigned long long)candidate_id);

            // Double-check: collect known group IDs for collision check (R-07: Core metadata)
            std::unordered_set<std::string> dart_known_ids;
            for (const auto& g : GetKnownGroupIDs()) dart_known_ids.insert(g);
            while (group_id_to_group_number_.find(generated_id_buf) != group_id_to_group_number_.end() ||
                   dart_known_ids.count(std::string(generated_id_buf)) > 0) {
                candidate_id = g_next_group_id_global.fetch_add(1);
                if (candidate_id <= max_existing_id) candidate_id = max_existing_id + 1;
                snprintf(generated_id_buf, sizeof(generated_id_buf), "tox_%llu", (unsigned long long)candidate_id);
            }
            
            finalGroupID = generated_id_buf;
            // [tim2tox-debug] Record groupID generation
            V2TIM_LOG(kInfo, "[tim2tox-debug] CreateGroup: Generated groupID={} from candidate_id={}, max_existing_id={}", 
                     finalGroupID.CString(), candidate_id, max_existing_id);
        }
    } else {
        // Validate provided groupID uniqueness
        std::lock_guard<std::mutex> lock(mutex_);
        if (group_id_to_group_number_.find(finalGroupID) != group_id_to_group_number_.end()) {
            V2TIM_LOG(kWarning, "CreateGroup: Provided groupID {} already exists, will overwrite mapping", finalGroupID.CString());
        }
    }

    // Step 8: Get chat_id and store it for persistence (only for group type, not conference)
    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Attempting to get chat_id and store for persistence");
    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Pre-check: is_conference={}, group_number={}, finalGroupID.Empty()={}, tox_manager={}", 
              is_conference, group_number, finalGroupID.Empty(), (void*)tox_manager);
    
    // Note: Only attempt to get chat_id for group type (not conference)
    // Conference doesn't support chat_id, it will be restored from savedata automatically
    if (!is_legacy_conference && group_number != UINT32_MAX && !finalGroupID.Empty() && tox_manager) {
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - All pre-checks passed, proceeding to get chat_id");
        
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat_id;
        
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Calling tox_manager->getGroupChatId for group_number={}", group_number);
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - chat_id buffer address={}, size={}", (void*)chat_id, TOX_GROUP_CHAT_ID_SIZE);
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - err_chat_id pointer={}", (void*)&err_chat_id);
        
        bool get_chat_id_result = tox_manager->getGroupChatId(group_number, chat_id, &err_chat_id);
        V2TIM_LOG(kInfo, "CreateGroup: Step 8 - getGroupChatId returned: result={}, err_chat_id={}", 
                  get_chat_id_result, static_cast<int>(err_chat_id));
        
        if (get_chat_id_result && err_chat_id == TOX_ERR_GROUP_STATE_QUERY_OK) {
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Successfully retrieved chat_id");
            
            // Convert to hex string (32 bytes = 64 hex characters)
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Converting chat_id to hex string");
            std::ostringstream oss;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
            }
            std::string chat_id_hex = oss.str();
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - chat_id_hex length={}, first 16 chars={}", 
                      chat_id_hex.length(), chat_id_hex.substr(0, std::min<size_t>(16, chat_id_hex.length())));
            
            // Validate finalGroupID before using CString()
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Validating finalGroupID before calling CString()");
            const char* group_id_cstr = finalGroupID.CString();
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - finalGroupID.CString() returned: {}", (void*)group_id_cstr);
            
            if (group_id_cstr) {
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - group_id_cstr is valid, value={}", group_id_cstr);
            } else {
                V2TIM_LOG(kError, "CreateGroup: Step 8 - ERROR - group_id_cstr is NULL!");
            }
            
            V2TIM_LOG(kInfo, "CreateGroup: Step 8 - chat_id_hex.empty()={}", chat_id_hex.empty());
            
            if (group_id_cstr && !chat_id_hex.empty()) {
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - All validations passed, storing chat_id");
                
                // Store chat_id via FFI for persistence
                // Note: Function is already declared with extern "C" at file scope (line 38)
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Calling tim2tox_ffi_set_group_chat_id");
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Parameters: group_id={}, chat_id={}", 
                          group_id_cstr, chat_id_hex.substr(0, std::min<size_t>(16, chat_id_hex.length())));
                
                // Add protection around FFI call
                try {
                    SetGroupChatIdInStorage(group_id_cstr, chat_id_hex.c_str());
                    int ffi_result = 1;
                    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - tim2tox_ffi_set_group_chat_id returned: {}", ffi_result);
                } catch (...) {
                    V2TIM_LOG(kError, "CreateGroup: Step 8 - EXCEPTION caught in tim2tox_ffi_set_group_chat_id!");
                    // Continue execution even if FFI call fails
                }
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - tim2tox_ffi_set_group_chat_id completed");
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Stored chat_id for group {}: {}", group_id_cstr, chat_id_hex.c_str());
                
                // Store in memory mapping
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Storing chat_id in memory mapping");
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Acquired mutex for memory mapping");
                    group_id_to_chat_id_[finalGroupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                    chat_id_to_group_id_[chat_id_hex] = finalGroupID;
                    V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Memory mapping updated successfully");
                }
                V2TIM_LOG(kInfo, "CreateGroup: Step 8 - Released mutex");
            } else {
                V2TIM_LOG(kWarning, "CreateGroup: Step 8 - Skipping chat_id storage - group_id_cstr={}, chat_id_hex.empty()={}", 
                         (void*)group_id_cstr, chat_id_hex.empty());
            }
        } else {
            V2TIM_LOG(kWarning, "CreateGroup: Step 8 - Failed to get chat_id for group_number={}, get_result={}, error={}", 
                     group_number, get_chat_id_result, static_cast<int>(err_chat_id));
        }
    } else {
        V2TIM_LOG(kWarning, "CreateGroup: Step 8 - Skipping chat_id retrieval - group_number={}, finalGroupID.Empty()={}, tox_manager={}", 
                 group_number, finalGroupID.Empty(), (void*)tox_manager);
    }
    
    // Step 9: Store the mapping (both ways)
    V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Storing group mapping");
    V2TIM_LOG(kInfo, "CreateGroup: Step 9 - finalGroupID={}, group_number={}", 
              finalGroupID.CString() ? finalGroupID.CString() : "null", group_number);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Acquired mutex for mapping storage");
        // Check if groupID already exists? V2TIM allows providing ID, Tox assigns number.
        // If finalGroupID exists in group_id_to_conference_number_, maybe error? Or overwrite?
        // For now, assume overwrite is fine or provided IDs are unique.
        auto existing_it = group_id_to_group_number_.find(finalGroupID);
        if (existing_it != group_id_to_group_number_.end()) {
            V2TIM_LOG(kWarning, "CreateGroup: Step 9 - finalGroupID {} already exists in mapping with group_number {}, overwriting", 
                     finalGroupID.CString() ? finalGroupID.CString() : "null", existing_it->second);
        }
        
        group_id_to_group_number_[finalGroupID] = group_number;
        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Stored group_id_to_group_number_ mapping");
        
        group_number_to_group_id_[group_number] = finalGroupID;
        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Stored group_number_to_group_id_ mapping");
        
        // Store group type mapping.
        // Preserve the original group_type_str supplied by the caller (e.g. 'Meeting',
        // 'Public', 'Private', 'Work', 'AVChatRoom', 'Community') so that
        // GetGroupsInfo/JSON-serialization round-trips return the same label the
        // caller created the group with. Old API (Tox conference) is always tagged
        // as "conference"; new API groups fall back to "group" only when the
        // caller did not supply a more specific label.
        std::string type_for_map;
        if (is_legacy_conference) {
            type_for_map = "conference";
            if (is_av_conference) type_for_map = "av_conference";
        } else if (!group_type_str.empty()) {
            type_for_map = group_type_str;
        } else {
            type_for_map = "group";
        }
        group_id_to_type_[finalGroupID] = type_for_map;
        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Stored group type: {}", type_for_map);

        V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Mapping storage completed");
    }
    V2TIM_LOG(kInfo, "CreateGroup: Step 9 - Released mutex");

    if (is_legacy_conference &&
        !StoreConferenceIdentity(finalGroupID, group_number)) {
        V2TIM_LOG(kWarning,
                  "CreateGroup: Failed to persist stable conference identity");
    }

    // Step 9.5: Store group type to persistent storage. Mirrors the in-memory
    // mapping above so that joiner instances and post-restart lookups can recover
    // the original label.
    if (!finalGroupID.Empty()) {
        const char* group_id_cstr = finalGroupID.CString();
        if (group_id_cstr) {
            std::string type_to_store;
            if (is_legacy_conference) {
                type_to_store = "conference";
                if (is_av_conference) type_to_store = "av_conference";
            } else if (!group_type_str.empty()) {
                type_to_store = group_type_str;
            } else {
                type_to_store = "group";
            }
            V2TIM_LOG(kInfo, "CreateGroup: Step 9.5 - Storing group type to persistent storage: group_id={}, type={}",
                     group_id_cstr, type_to_store);
            try {
                SetGroupTypeInStorage(group_id_cstr, type_to_store);
                V2TIM_LOG(kInfo, "CreateGroup: Step 9.5 - Successfully stored group type");
            } catch (...) {
                V2TIM_LOG(kError, "CreateGroup: Step 9.5 - EXCEPTION caught in tim2tox_ffi_set_group_type!");
            }
        }
    }

    V2TIM_LOG(kInfo, "CreateGroup: Step 10 - Calling success callback");
    V2TIM_LOG(kInfo, "CreateGroup: Created group {} (group_number {})", 
              finalGroupID.CString() ? finalGroupID.CString() : "null", group_number);
    
    // Step 10.5: Manually trigger HandleGroupSelfJoin to notify listeners about group creation
    // This is necessary because tox_group_new/createGroup may not immediately trigger
    // the on_group_self_join callback, but we need to notify listeners via OnGroupCreated
    V2TIM_LOG(kInfo, "CreateGroup: Step 10.5 - Manually calling HandleGroupSelfJoin to trigger OnGroupCreated callback");
    static_cast<void>(0);
    static_cast<void>(0);
    HandleGroupSelfJoin(group_number);
    V2TIM_LOG(kInfo, "CreateGroup: Step 10.5 - HandleGroupSelfJoin completed");
    
    if (callback) {
        V2TIM_LOG(kInfo, "CreateGroup: Step 10 - callback is valid, calling OnSuccess");
        const char* final_group_id_cstr = finalGroupID.CString();
        V2TIM_LOG(kInfo, "CreateGroup: Step 10 - finalGroupID.CString()={}", (void*)final_group_id_cstr);
        if (final_group_id_cstr) {
            V2TIM_LOG(kInfo, "CreateGroup: Step 10 - Calling callback->OnSuccess with groupID={}", final_group_id_cstr);
            callback->OnSuccess(finalGroupID);
            V2TIM_LOG(kInfo, "CreateGroup: Step 10 - callback->OnSuccess completed");
        } else {
            V2TIM_LOG(kError, "CreateGroup: Step 10 - ERROR - finalGroupID.CString() returned NULL, cannot call OnSuccess");
        }
    } else {
        V2TIM_LOG(kWarning, "CreateGroup: Step 10 - callback is null, skipping OnSuccess");
    }
    
    V2TIM_LOG(kInfo, "CreateGroup: EXIT - Successfully completed");
}

// Password for the JoinGroup running on this thread (JoinGroupWithPassword);
// JoinGroup is synchronous, so a scoped thread-local is enough and keeps the
// V2TIMManager::JoinGroup signature intact.
static thread_local const std::string* t_join_password = nullptr;
static const uint8_t* JoinPasswordData() {
    return t_join_password && !t_join_password->empty()
               ? reinterpret_cast<const uint8_t*>(t_join_password->data())
               : nullptr;
}
static size_t JoinPasswordLength() {
    return t_join_password ? t_join_password->size() : 0;
}

void V2TIMManagerImpl::JoinGroupWithPassword(const V2TIMString& groupID, const std::string& password,
                                             V2TIMCallback* callback) {
    if (password.size() > TOX_GROUP_MAX_PASSWORD_SIZE) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Group password is too long");
        return;
    }
    // Restored on every exit, exceptions included: a stale pointer here would
    // hand the next join on this thread a freed (or wrong) password.
    struct PasswordScope {
        const std::string* previous;
        explicit PasswordScope(const std::string* next) : previous(t_join_password) {
            t_join_password = next;
        }
        ~PasswordScope() { t_join_password = previous; }
    } scope(&password);
    JoinGroup(groupID, V2TIMString(""), callback);
}

void V2TIMManagerImpl::JoinGroup(const V2TIMString& groupID, const V2TIMString& message, V2TIMCallback* callback) {
    // Get start timestamp for detailed timing
    auto start_time = std::chrono::steady_clock::now();
    
    static_cast<void>(0);
    static_cast<void>(0);
    static_cast<void>(0);
    // Note: GetCurrentInstanceId and GetInstanceIdFromManager are already declared at file scope (lines 27-28)
    int64_t current_instance_id = GetCurrentInstanceId();
    int64_t this_instance_id = GetInstanceIdFromManager(this);
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "[JoinGroup] ========== JoinGroup called ==========");
    V2TIM_LOG(kInfo, "[JoinGroup] this=%p, current_instance_id=%lld, this_instance_id=%lld", 
              (void*)this, (long long)current_instance_id, (long long)this_instance_id);
    V2TIM_LOG(kInfo, "[JoinGroup] groupID: {}", groupID.CString() ? groupID.CString() : "null");
    V2TIM_LOG(kInfo, "[JoinGroup] message: {}", message.CString() ? message.CString() : "null");
    V2TIM_LOG(kInfo, "[JoinGroup] callback: {}", (void*)callback);
    
    // Get ToxManager and verify it's valid. PINNED for the whole join — this
    // runs on the FFI caller's thread AND pumps tox_iterate() below, so a
    // listener's UnInitSDK (deferred to the end of that iterate) used to free
    // the manager and the Tox while this function still held raw pointers to
    // both. The pin keeps them valid; join_session_ended() below still stops
    // the work, because valid is not the same as current.
    const ToxSessionGuard session = AcquireToxSession();
    ToxManager* tox_manager = session.manager();
    if (!tox_manager) {
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kError, "[JoinGroup] ERROR: ToxManager is null");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "ToxManager not available");
        return;
    }
    
    Tox* tox = session.tox();
    if (!tox) {
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kError, "[JoinGroup] ERROR: Tox instance not available");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "[JoinGroup] Tox instance available");

    // Idempotent join for conferences: AV/text conferences auto-join inside the
    // invite callback (see the conference invite handler's toxav_join_av_groupchat /
    // tox_conference_join path) and then map the invite's tox_conf_<friend>_<ts> ID
    // with their persisted conference type. A caller that then follows V2TIM semantics — join with
    // the groupID it received in onMemberInvited — would fall through to the pending
    // path, find no pending (we auto-joined, so none was stored) and a non-creator
    // ID, and fail with 6017 ERR_INVALID_PARAMETERS. For an already-joined conference
    // the join is a no-op success. Scoped to conferences so NGCv2 ("group") join
    // flows keep their existing pending/chat_id behaviour untouched. The KIND is
    // decided by the mapped key's tag, never by the type label: a stale label
    // must neither skip a real NGC join nor treat a conference as NGC.
    Tox_Group_Number mapped_number = UINT32_MAX;
    std::string group_type;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto mapped_it = group_id_to_group_number_.find(groupID);
        if (mapped_it != group_id_to_group_number_.end()) {
            mapped_number = mapped_it->second;
        }
        auto type_it = group_id_to_type_.find(groupID);
        if (type_it != group_id_to_type_.end()) {
            group_type = type_it->second;
        }
    }
    const bool conference_labelled = group_type == "conference" ||
                                     group_type == "av_conference";
    if (mapped_number == UINT32_MAX && conference_labelled) {
        // Restored conference whose mapping has not been rebuilt yet (queried
        // before RejoinKnownGroups): resolve it by its CONFERENCE identity.
        mapped_number = RecoverGroupMapping(groupID.CString() ? groupID.CString() : "",
                                            /*allow_unmapped_ngc_bind=*/false);
    }
    if (IsConferenceMapKey(mapped_number)) {
        V2TIM_LOG(kInfo, "[JoinGroup] conference groupID {} already mapped (already a member) — returning success (idempotent join)",
                  groupID.CString());
        if (callback) callback->OnSuccess();
        return;
    }

    // Single-instance real client: allow joining a public group by passing chat_id (64-char hex) as groupID
    // so the creator can share the chat_id (e.g. link/QR) and others join without invite or cross-instance storage.
    char stored_chat_id[65]; // 32 bytes * 2 (hex) + 1 (null terminator)
    bool has_stored_chat_id = false;
    std::string groupID_str(groupID.CString() ? groupID.CString() : "");
    if (groupID_str.length() == 64) {
        bool all_hex = true;
        for (size_t i = 0; i < 64; ++i) {
            char c = groupID_str[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
                all_hex = false;
                break;
            }
        }
        if (all_hex) {
            memcpy(stored_chat_id, groupID_str.c_str(), 64);
            stored_chat_id[64] = '\0';
            has_stored_chat_id = true;
            V2TIM_LOG(kInfo, "[JoinGroup] groupID is 64-char hex, using as chat_id for join (single-instance join public group)");
        }
    }
    if (!has_stored_chat_id && conference_labelled && mapped_number == UINT32_MAX) {
        // The stored identity of an unmapped conference is a CONFERENCE id:
        // handing it to tox_group_join would try to join a non-existent NGC
        // group. A conference can only be (re)entered through its invite, so
        // fall through to the pending-invite path.
        V2TIM_LOG(kInfo, "[JoinGroup] {} is an unmapped conference; not joining its identity as an NGC chat id",
                  groupID.CString());
    } else if (!has_stored_chat_id) {
        // Try to get chat_id from storage (or cross-instance in tests)
        V2TIM_LOG(kInfo, "[JoinGroup] Checking for stored chat_id for groupID: {}", groupID.CString());
        has_stored_chat_id = GetGroupChatIdFromStorage(groupID.CString(), stored_chat_id, sizeof(stored_chat_id));
        V2TIM_LOG(kInfo, "[JoinGroup] has_stored_chat_id: {}", has_stored_chat_id);
    }
    if (has_stored_chat_id) {
        V2TIM_LOG(kInfo, "[JoinGroup] Found stored chat_id: {} (length={})", stored_chat_id, strlen(stored_chat_id));
    } else {
        V2TIM_LOG(kInfo, "[JoinGroup] No stored chat_id found, will check for pending invite");
    }
    
    Tox_Group_Number group_number = UINT32_MAX;
    V2TIMString publicGroupID = groupID;
    V2TIMString used_pending_id;
    
    if (has_stored_chat_id) {
        V2TIM_LOG(kInfo, "[JoinGroup] Path 1: Joining group using stored chat_id");
        // Convert hex string to binary chat_id
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        std::string chat_id_hex(stored_chat_id);
        V2TIM_LOG(kInfo, "[JoinGroup] Converting chat_id hex to binary: {}", chat_id_hex);
        std::istringstream iss(chat_id_hex);
        for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
            std::string byte_str = chat_id_hex.substr(i * 2, 2);
            char* endptr;
            unsigned long byte_val = strtoul(byte_str.c_str(), &endptr, 16);
            if (*endptr != '\0' || byte_val > 255) {
                V2TIM_LOG(kError, "[JoinGroup] ERROR: Invalid chat_id hex string at byte {}, byte_str={}, byte_val={}", i, byte_str, byte_val);
                if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Invalid chat_id");
                return;
            }
            chat_id[i] = static_cast<uint8_t>(byte_val);
        }
        V2TIM_LOG(kInfo, "[JoinGroup] Successfully converted chat_id hex to binary");

        // tox_group_join() on a chat_id we are already in does NOT return that
        // group's number: gc_group_join() routes to gc_rejoin_group() and hands
        // back its 0-on-success status, which reads as "group number 0" here.
        // Resolve the real number up front (RejoinKnownGroups does the same).
        const Tox_Group_Number existing_group_number = tox_manager->getGroupByChatId(chat_id);
        if (existing_group_number != UINT32_MAX) {
            V2TIMString existing_group_id;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto existing_it = group_number_to_group_id_.find(existing_group_number);
                if (existing_it != group_number_to_group_id_.end()) {
                    existing_group_id = existing_it->second;
                }
            }
            if (!existing_group_id.Empty() && existing_group_id != groupID &&
                !IsTemporaryInviteGroupID(existing_group_id)) {
                // Already a member under another group ID (e.g. joined through an
                // invite as tox_N, now pasting the 64-hex chat_id). Binding a
                // second ID to the same group would split one group across two
                // conversations, so refuse and name the existing one.
                V2TIM_LOG(kWarning, "[JoinGroup] chat_id already joined as groupID={} (group_number={}); refusing duplicate join as {}",
                          existing_group_id.CString(), existing_group_number, groupID.CString());
                if (callback) callback->OnError(ERR_SVR_GROUP_ALLREADY_MEMBER, existing_group_id);
                return;
            }
        }

        // Join group using chat_id
        std::string self_name = tox_manager->getName();
        if (self_name.empty()) {
            self_name = "User";
        }
        V2TIM_LOG(kInfo, "[JoinGroup] Using self_name: {} (length={})", self_name, self_name.length());
        
        V2TIM_LOG(kInfo, "[JoinGroup] Calling ToxManager::joinGroup with chat_id");
        Tox_Err_Group_Join err_join;
        group_number = tox_manager->joinGroup(
            chat_id,
            reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
            JoinPasswordData(), JoinPasswordLength(),
            &err_join
        );
        
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kInfo, "[JoinGroup] joinGroup returned: group_number={}, err_join={}", group_number, static_cast<int>(err_join));
        if (err_join != TOX_ERR_GROUP_JOIN_OK || group_number == UINT32_MAX) {
            static_cast<void>(0);
            static_cast<void>(0);
            V2TIM_LOG(kError, "[JoinGroup] FAILED to join group using chat_id");
            V2TIM_LOG(kError, "[JoinGroup] Error code: {} (0=OK, 1=INVALID_CHAT_ID, 2=TOO_LONG, 3=FAIL)", static_cast<int>(err_join));
            V2TIM_LOG(kError, "[JoinGroup] group_number={} (UINT32_MAX={})", group_number, UINT32_MAX);
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to join Tox group");
            return;
        }
        static_cast<void>(0);
        static_cast<void>(0);
        if (existing_group_number != UINT32_MAX) {
            // Reconnect of a group we already hold under this same ID: the value
            // tox_group_join returned is a status, not a group number.
            group_number = existing_group_number;
        } else {
            MarkFreshGroupJoin(group_number);
        }
        V2TIM_LOG(kInfo, "[JoinGroup] ✅ Successfully joined group using chat_id, group_number={}", group_number);
        // Persist chat_id for this instance (groupID may be 64-char chat_id when joining public group)
        SetGroupChatIdInStorage(groupID.CString(), stored_chat_id);
    } else {
        V2TIM_LOG(kInfo, "[JoinGroup] Path 2: Joining group using pending invite");
        // Try to use pending invite if available
        PendingInvite inv;
        // Report "not found" only after mutex_ is released: a callback that
        // calls back into the manager (or a listener that does) would
        // self-deadlock on this non-recursive mutex.
        bool pending_invite_missing = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            V2TIM_LOG(kInfo, "[JoinGroup] Checking pending invites, total pending: {}", pending_group_invites_.size());
            auto it = pending_group_invites_.find(groupID);
            if (it == pending_group_invites_.end()) {
                // No exact match: use first pending only when groupID looks like creator-assigned (tox_group_*).
                // Invite flow: app passes creator's groupID e.g. tox_group_0, tox_group_1, pending is stored as tox_inv_%u_%llu.
                // Do not use first pending for custom IDs (e.g. tox_private_*) so "join without invite" fails with 6017.
                // Note: "tox_group_0" has 11 chars; prefix "tox_group_" is 10 chars, digit at index 10.
                std::string gidStr(groupID.CString());
                bool isCreatorStyleGroupId = (gidStr.size() >= 11 && gidStr.substr(0, 10) == "tox_group_" && gidStr[10] >= '0' && gidStr[10] <= '9');
                if (pending_group_invites_.size() >= 1 && isCreatorStyleGroupId) {
                    V2TIM_LOG(kInfo, "[JoinGroup] No exact match for groupID: {}, but {} pending invite(s), using first (creator-style ID)",
                              groupID.CString(), pending_group_invites_.size());
                    it = pending_group_invites_.begin();
                    used_pending_id = it->first;
                    V2TIM_LOG(kInfo, "[JoinGroup] Using pending invite with ID: {}", used_pending_id.CString());
                } else if (pending_group_invites_.size() >= 1 && !isCreatorStyleGroupId) {
                    int64_t join_instance_id = GetInstanceIdFromManager(this);
                    V2TIM_LOG(kError, "[JoinGroup] ERROR: No exact match for groupID: {} (custom ID, not using first pending), instance_id={}",
                              groupID.CString(), (long long)join_instance_id);
                    pending_invite_missing = true;
                } else {
                    int64_t join_instance_id = GetInstanceIdFromManager(this);
                    V2TIM_LOG(kError, "[JoinGroup] ERROR: Pending invite not found for groupID: {} (pending count=0, instance_id={})",
                              groupID.CString(), (long long)join_instance_id);
                    static_cast<void>(0);
                    static_cast<void>(0);
                    pending_invite_missing = true;
                }
            } else {
                used_pending_id = it->first;
            }
            if (!pending_invite_missing) {
                inv = it->second;
                V2TIM_LOG(kInfo, "[JoinGroup] Found pending invite: friend_number={}, cookie_size={}, pending_id={}",
                         inv.friend_number, inv.cookie.size(), used_pending_id.CString());
            }
        }
        if (pending_invite_missing) {
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Pending invite not found for groupID and no chat_id stored");
            return;
        }

        if (inv.kind == PendingInviteKind::kConferenceAv ||
            inv.kind == PendingInviteKind::kConferenceText) {
            Tox_Conference_Number conference_number = UINT32_MAX;
            const bool is_av_invite =
                inv.kind == PendingInviteKind::kConferenceAv;

            if (is_av_invite) {
#ifdef BUILD_TOXAV
                ToxAVManager* av_manager = GetToxAVManager();
                if (av_manager == nullptr) {
                    if (callback) {
                        callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT,
                                          "ToxAV manager unavailable");
                    }
                    return;
                }
                try {
                    av_manager->initialize(this);
                } catch (const std::exception& error) {
                    if (std::string(error.what()).find("already initialized") ==
                        std::string::npos) {
                        if (callback) {
                            callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT,
                                              "ToxAV initialization failed");
                        }
                        return;
                    }
                }
                if (inv.cookie.size() > UINT16_MAX) {
                    if (callback) {
                        callback->OnError(ERR_INVALID_PARAMETERS,
                                          "Invalid AV conference invite");
                    }
                    return;
                }
                int32_t joined = -1;
                {
                    // Legacy group AV takes no toxcore lock (see
                    // ToxAVManager::lockToxIterate).
                    auto av_iterate_lock = tox_manager->lockIterate();
                    joined = toxav_join_av_groupchat(
                        tox, inv.friend_number, inv.cookie.data(),
                        static_cast<uint16_t>(inv.cookie.size()),
                        HandleAVConferenceAudio, this);
                }
                if (joined < 0) {
                    if (callback) {
                        callback->OnError(ERR_INVALID_PARAMETERS,
                                          "Failed to join AV conference");
                    }
                    return;
                }
                conference_number =
                    static_cast<Tox_Conference_Number>(joined);
#else
                if (callback) {
                    callback->OnError(ERR_SDK_INTERFACE_NOT_SUPPORT,
                                      "ToxAV is unavailable");
                }
                return;
#endif
            } else {
                Tox_Err_Conference_Join conference_error =
                    TOX_ERR_CONFERENCE_JOIN_OK;
                conference_number = tox_conference_join(
                    tox, inv.friend_number, inv.cookie.data(),
                    inv.cookie.size(), &conference_error);
                if (conference_error != TOX_ERR_CONFERENCE_JOIN_OK ||
                    conference_number == UINT32_MAX) {
                    if (callback) {
                        callback->OnError(ERR_INVALID_PARAMETERS,
                                          "Failed to join text conference");
                    }
                    return;
                }
            }

            const std::string conference_type =
                is_av_invite ? "av_conference" : "conference";
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_group_number_[groupID] = ConferenceMapKey(conference_number);
                group_number_to_group_id_[ConferenceMapKey(conference_number)] = groupID;
                group_id_to_type_[groupID] = conference_type;
            }
            SetGroupTypeInStorage(groupID.CString(), conference_type);
            if (!StoreConferenceIdentity(groupID, ConferenceMapKey(conference_number))) {
                V2TIM_LOG(kWarning,
                          "[JoinGroup] Failed to persist stable identity for conference {}",
                          conference_number);
            }

            {
                std::lock_guard<std::mutex> lock(mutex_);
                pending_group_invites_.erase(used_pending_id);
            }

            V2TIMGroupManager* group_manager = GetGroupManager();
            if (group_manager) {
                static_cast<V2TIMGroupManagerImpl*>(group_manager)
                    ->EnsureGroupInfoExists(groupID);
            }
            HandleGroupSelfJoin(ConferenceMapKey(conference_number));
            if (callback) callback->OnSuccess();
            return;
        }
        
        // Accept invite using tox_group_invite_accept
        std::string self_name = tox_manager->getName();
        if (self_name.empty()) {
            self_name = "User";
        }
        V2TIM_LOG(kInfo, "[JoinGroup] Using self_name: {} (length={})", self_name, self_name.length());
        V2TIM_LOG(kInfo, "[JoinGroup] Calling tox_group_invite_accept: friend_number={}, cookie_size={}", 
                 inv.friend_number, inv.cookie.size());
        
        Tox_Err_Group_Invite_Accept err_accept;
        group_number = tox_group_invite_accept(
            tox,
            inv.friend_number,
            inv.cookie.data(), inv.cookie.size(),
            reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
            JoinPasswordData(), JoinPasswordLength(),
            &err_accept
        );
        
        V2TIM_LOG(kInfo, "[JoinGroup] tox_group_invite_accept returned: group_number={}, err_accept={}", 
                 group_number, static_cast<int>(err_accept));
        if (err_accept != TOX_ERR_GROUP_INVITE_ACCEPT_OK || group_number == UINT32_MAX) {
            V2TIM_LOG(kError, "[JoinGroup] FAILED to accept invite");
            V2TIM_LOG(kError, "[JoinGroup] Error code: {} (0=OK, 1=FRIEND_NOT_FOUND, 2=INVALID_LENGTH, 3=INVITE_FAIL)", 
                     static_cast<int>(err_accept));
            V2TIM_LOG(kError, "[JoinGroup] group_number={} (UINT32_MAX={})", group_number, UINT32_MAX);
            if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to accept Tox group invite");
            return;
        }
        V2TIM_LOG(kInfo, "[JoinGroup] ✅ Successfully accepted invite, group_number={}", group_number);
        MarkFreshGroupJoin(group_number);
        {
            // Kept until toxcore confirms the join: a refusal (password,
            // full) hands the invite back so it can be redeemed again.
            std::lock_guard<std::mutex> lock(mutex_);
            accepted_invites_[group_number] = {
                used_pending_id.Empty() ? std::string(groupID.CString())
                                        : std::string(used_pending_id.CString()),
                inv};
        }
        
        // Get chat_id and store it for persistence
        V2TIM_LOG(kInfo, "[JoinGroup] Attempting to get chat_id for group_number={}", group_number);
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat_id;
        bool got_chat_id = tox_manager->getGroupChatId(group_number, chat_id, &err_chat_id);
        V2TIM_LOG(kInfo, "[JoinGroup] getGroupChatId returned: got_chat_id={}, err_chat_id={}", 
                 got_chat_id, static_cast<int>(err_chat_id));
        
        if (got_chat_id && err_chat_id == TOX_ERR_GROUP_STATE_QUERY_OK) {
            // Convert to hex string
            std::ostringstream oss;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
            }
            std::string chat_id_hex = oss.str();
            V2TIM_LOG(kInfo, "[JoinGroup] Retrieved chat_id (hex): {} (length={})", chat_id_hex, chat_id_hex.length());

            {
                std::lock_guard<std::mutex> lock(mutex_);
                publicGroupID = CanonicalGroupIDForChatIdLocked(groupID, chat_id_hex);
            }

            // Store chat_id via FFI for persistence
            // Note: Function is already declared with extern "C" at file scope (line 38)
            SetGroupChatIdInStorage(publicGroupID.CString(), chat_id_hex);
            V2TIM_LOG(kInfo, "[JoinGroup] SetGroupChatIdInStorage completed");
            V2TIM_LOG(kInfo, "[JoinGroup] Stored chat_id for joined group {}", publicGroupID.CString());

            // Store in memory mapping
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_chat_id_[publicGroupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                chat_id_to_group_id_[chat_id_hex] = publicGroupID;
                if (!used_pending_id.Empty() && used_pending_id != publicGroupID) {
                    group_id_to_chat_id_[used_pending_id] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                    group_id_to_group_number_[used_pending_id] = group_number;
                }
                V2TIM_LOG(kInfo, "[JoinGroup] Stored chat_id mapping for groupID={}", publicGroupID.CString());
            }
        } else {
            V2TIM_LOG(kWarning, "[JoinGroup] ⚠️ Failed to get chat_id for group_number={}, error={}", 
                     group_number, static_cast<int>(err_chat_id));
        }
        
        // Before removing pending invite, trigger onMemberInvited callback with actual groupID
        // This handles the case where JoinGroup was called with actual groupID but pending invite has temp ID
        if (!used_pending_id.Empty() && used_pending_id != publicGroupID) {
            V2TIM_LOG(kInfo, "[JoinGroup] Triggering onMemberInvited with actual groupID={} (was temp={})", 
                     publicGroupID.CString(), used_pending_id.CString());
            
            // Get inviter info from pending invite. Copied out by value: a
            // PendingInvite* is only valid while mutex_ is held (the invite
            // callback on the tox thread inserts into the same map).
            bool has_pending_inv = false;
            std::string pending_inviter_userID;
            uint32_t pending_friend_number = 0;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = pending_group_invites_.find(used_pending_id);
                if (it != pending_group_invites_.end()) {
                    has_pending_inv = true;
                    pending_inviter_userID = it->second.inviter_userID;
                    pending_friend_number = it->second.friend_number;
                }
            }

            if (has_pending_inv) {
                // Build member list (contains self)
                V2TIMGroupMemberInfoVector memberList;
                V2TIMGroupMemberInfo selfMember;
                Tox* tox = session.tox();
                if (tox) {
                    uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                    tox_self_get_public_key(tox, self_pubkey);
                    std::string selfUserID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                    selfMember.userID = V2TIMString(selfUserID.c_str());
                    memberList.PushBack(selfMember);
                }
                
                // Build opUser (inviter)
                V2TIMGroupMemberInfo opUser;
                if (!pending_inviter_userID.empty()) {
                    opUser.userID = V2TIMString(pending_inviter_userID.c_str());
                } else {
                    // Fallback: get inviter's public key from friend_number
                    Tox* tox = session.tox();
                    if (tox) {
                        uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
                        if (tox_friend_get_public_key(tox, pending_friend_number, inviter_pubkey, nullptr)) {
                            std::string inviterUserID = ToxUtil::tox_bytes_to_hex(inviter_pubkey, TOX_PUBLIC_KEY_SIZE);
                            opUser.userID = V2TIMString(inviterUserID.c_str());
                        }
                    }
                }
                
                // Notify listeners with actual groupID
                std::vector<V2TIMGroupListener*> listeners_copy;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
                }
                
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        static_cast<void>(0);
                        static_cast<void>(0);
                        V2TIM_LOG(kInfo, "[JoinGroup] Calling OnMemberInvited: groupID={}, inviter={}, memberCount={}",
                                 publicGroupID.CString(), opUser.userID.CString(), memberList.Size());
                        listener->OnMemberInvited(publicGroupID, opUser, memberList);
                    }
                }
            }
        }
        
        // Remove pending invite (use the ID that was actually used, not necessarily groupID)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            size_t erased = 0;
            if (!used_pending_id.Empty()) {
                erased = pending_group_invites_.erase(used_pending_id);
                V2TIM_LOG(kInfo, "[JoinGroup] Removed pending invite with ID: {} (erased={})", used_pending_id.CString(), erased);
            } else {
                erased = pending_group_invites_.erase(groupID);
                V2TIM_LOG(kInfo, "[JoinGroup] Removed pending invite for groupID: {} (erased={})", groupID.CString(), erased);
            }
        }
    }
    
    // Store group mappings IMMEDIATELY after tox_group_join succeeds
    // This ensures the mapping exists even if onGroupSelfJoin hasn't been triggered yet
    // Note: onGroupSelfJoin will be triggered later when DHT discovers peers
    {
        std::lock_guard<std::mutex> lock(mutex_);
        group_id_to_group_number_[publicGroupID] = group_number;
        group_number_to_group_id_[group_number] = publicGroupID;
        if (!used_pending_id.Empty() && used_pending_id != publicGroupID) {
            group_id_to_group_number_[used_pending_id] = group_number;
        }
        // [tim2tox-debug] Record conference_number mapping for JoinGroup
        V2TIM_LOG(kInfo, "[tim2tox-debug] JoinGroup: Stored conference_number mapping: groupID={} <-> group_number={}", 
                 publicGroupID.CString(), group_number);
        V2TIM_LOG(kInfo, "[JoinGroup] Stored group mapping: groupID={} <-> group_number={}", publicGroupID.CString(), group_number);
        V2TIM_LOG(kInfo, "[JoinGroup] Total groups in mapping: {}", group_id_to_group_number_.size());
    }
    
    // Ensure group_info_ has an entry so GetGroupsInfo finds the group before topic/name broadcast arrives
    V2TIMGroupManager* grp_mgr = GetGroupManager();
    if (grp_mgr) {
        V2TIMGroupManagerImpl* grp_impl = static_cast<V2TIMGroupManagerImpl*>(grp_mgr);
        grp_impl->EnsureGroupInfoExists(publicGroupID);
    }
    
    V2TIM_LOG(kInfo, "[JoinGroup] ✅ Successfully joined group {} (group_number={})", publicGroupID.CString(), group_number);
    
    // CRITICAL: tox_group_join is asynchronous and requires DHT peer discovery
    // We need to wait for network synchronization and trigger tox_iterate multiple times
    // to ensure callbacks (onGroupSelfJoin, onGroupPeerJoin) are processed
    // With local bootstrap, this should be much faster - reduce wait time
    // We'll wait up to 1 second for the group to become connected
    // The sleep-and-iterate loops below exist for callers that have NO event
    // thread driving tox_iterate (test_mode_ auto_tests, where nothing else
    // would make the join progress). In the product the event thread iterates
    // continuously and delivers self_join / peer_join on its own, while THIS
    // call runs synchronously on the Flutter UI thread: pumping here froze the
    // UI for 1.5-4.5 s per join (no spinner frame, input dropped; close to the
    // Android ANR threshold) and ran tox callbacks on the UI thread.
    const bool pump_on_caller =
        test_mode_.load(std::memory_order_acquire) || !IsEventThreadRunning();
    // Every pump below runs tox callbacks on this thread. One that ends the
    // session (a listener calling UnInitSDK) is deferred by
    // IterateReentryScope to the moment that iterate returns — so by the time
    // control is back here it has already run: tox_manager_ is null and (after
    // a re-InitSDK) the group numbers belong to another profile. The manager
    // and the Tox themselves stay ALIVE for as long as `session` is held, so a
    // pump that returns into this frame no longer touches freed memory; this
    // check is about currency, not validity — abandon the join rather than
    // publish work for a session that is over.
    auto join_session_ended = [this, &session]() {
        return session.Expired() || !running_.load(std::memory_order_acquire);
    };
    auto abandon_join = [&groupID, callback]() {
        V2TIM_LOG(kWarning, "[JoinGroup] session ended while pumping the join of {}; abandoning it",
                  groupID.CString() ? groupID.CString() : "null");
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "SDK uninitialized during JoinGroup");
    };
    if (tox_manager) {
        V2TIM_LOG(kInfo, "[JoinGroup] Waiting for group to become connected (up to 1 second)...");
        static_cast<void>(0);
        static_cast<void>(0);
        
        bool is_connected = false;
        const int max_wait_iterations = 20; // 20 * 50ms = 1 second (reduced from 2 seconds)
        auto wait_start_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        static_cast<void>(0);
        static_cast<void>(0);
        
        for (int i = 0; pump_on_caller && i < max_wait_iterations; i++) {
            // Check if group is connected
            Tox_Err_Group_Is_Connected err_connected;
            is_connected = tox_manager->isGroupConnected(group_number, &err_connected);
            
            if (is_connected) {
                auto connected_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::system_clock::now().time_since_epoch()).count();
                auto wait_duration_ms = connected_ms - wait_start_ms;
                static_cast<void>(0);
                static_cast<void>(0);
                V2TIM_LOG(kInfo, "[JoinGroup] Group is now connected after {} iterations ({} ms)", i + 1, wait_duration_ms);
                break;
            }
            
            // Trigger tox_iterate to process network events
            tox_manager->iterate(0);
            if (join_session_ended()) {
                abandon_join();
                return;
            }

            // Small delay between iterations
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        
        if (!is_connected) {
            static_cast<void>(0);
            static_cast<void>(0);
            V2TIM_LOG(kWarning, "[JoinGroup] Group is not connected after {} iterations, but continuing anyway", max_wait_iterations);
        }
        
        // Continue iterating a few more times to ensure callbacks are processed
        // With local bootstrap, this should be much faster - reduce to 10 iterations (0.5 seconds)
        static_cast<void>(0);
        static_cast<void>(0);
        for (int i = 0; pump_on_caller && i < 10; i++) {  // Reduced to 10 iterations (0.5 seconds) for local bootstrap
            tox_manager->iterate(0);
            if (join_session_ended()) {
                abandon_join();
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        static_cast<void>(0);
        static_cast<void>(0);

        bool final_mapping_exists = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            final_mapping_exists = (group_number_to_group_id_.find(group_number) != group_number_to_group_id_.end());
        }
        
        // Final peer count check after all iterations
        int final_peer_count = 0;
        for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
            uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_Peer_Query err_key;
            if (tox_manager->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) &&
                err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
                final_peer_count++;
            } else {
                break;
            }
        }
        
        // Check if we can see other peers (this instance just joined, so we should see founder)
        if (final_peer_count == 1) {
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            
            // Check group privacy state
            Tox_Err_Group_State_Query err_privacy;
            Tox_Group_Privacy_State privacy_state = tox_group_get_privacy_state(tox, group_number, &err_privacy);
            
            // Additional wait and iteration for DHT peer discovery (PUBLIC groups need time for DHT sync)
            // With local bootstrap, this should be much faster - reduce wait time
            if (err_privacy == TOX_ERR_GROUP_STATE_QUERY_OK && 
                privacy_state == TOX_GROUP_PRIVACY_STATE_PUBLIC && final_peer_count == 1) {
            static_cast<void>(0);
            static_cast<void>(0);
            // Wait additional 1 second (reduced from 2 seconds) with more iterations for DHT peer discovery
            for (int i = 0; pump_on_caller && i < 10; i++) {
                tox_manager->iterate();
                if (join_session_ended()) {
                    abandon_join();
                    return;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                
                // Check peer count every 3 iterations (more frequent for faster detection)
                if (i % 3 == 0) {
                    int current_peer_count = 0;
                    for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                        Tox_Err_Group_Peer_Query err_key;
                        if (tox_manager->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) &&
                            err_key == TOX_ERR_GROUP_PEER_QUERY_OK) {
                            current_peer_count++;
                        } else {
                            break;
                        }
                    }
                    static_cast<void>(0);
                    static_cast<void>(0);
                    if (current_peer_count > 1) {
                        static_cast<void>(0);
                        static_cast<void>(0);
                        break;
                    }
                }
            }
            }
        }
        
        // CRITICAL: If mapping exists but onGroupSelfJoin hasn't been triggered yet,
        // manually call HandleGroupSelfJoin to ensure listeners are notified.
        // This is necessary because tox_group_join is asynchronous and onGroupSelfJoin
        // may not be triggered immediately, but we've already stored the mapping.
        if (final_mapping_exists) {
            static_cast<void>(0);
            static_cast<void>(0);
            V2TIM_LOG(kInfo, "[JoinGroup] Manually calling HandleGroupSelfJoin for group_number={}", group_number);
            HandleGroupSelfJoin(group_number);
        }
        
        // CRITICAL: For local bootstrap, we need to ensure other peers can see this peer join
        // Check if there are other peers in the group and manually trigger HandleGroupPeerJoin
        // for those peers if DHT discovery hasn't completed yet
        // This helps with local bootstrap where DHT sync should be fast
        static_cast<void>(0);
        static_cast<void>(0);
        
        // Get self peer_id to identify which peer we are
        Tox_Err_Group_Self_Query err_self_final;
        Tox_Group_Peer_Number self_peer_id_final = tox_group_self_get_peer_id(tox, group_number, &err_self_final);
        if (err_self_final == TOX_ERR_GROUP_SELF_QUERY_OK) {
            static_cast<void>(0);
            static_cast<void>(0);
            
            // Check all peers in the group
            // If we see other peers, they should see us join via onGroupPeerJoin callback
            // But if DHT sync is slow, we can help by ensuring tox_iterate is called
            // The callback will be triggered automatically when tox_iterate processes the event
            int visible_peer_count = 0;
            for (Tox_Group_Peer_Number peer_id = 0; peer_id < 100; ++peer_id) {
                uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
                Tox_Err_Group_Peer_Query err_peer_check;
                if (tox_group_peer_get_public_key(tox, group_number, peer_id, peer_pubkey, &err_peer_check) &&
                    err_peer_check == TOX_ERR_GROUP_PEER_QUERY_OK) {
                    visible_peer_count++;
                    if (peer_id != self_peer_id_final) {
                        static_cast<void>(0);
                        static_cast<void>(0);
                        static_cast<void>(0);
                    }
                } else {
                    break; // Stop after first error
                }
            }
            static_cast<void>(0);
            static_cast<void>(0);
            
            // If we only see ourselves, DHT sync hasn't completed yet
            // Continue iterating to help DHT discovery
            if (visible_peer_count == 1) {
                static_cast<void>(0);
                static_cast<void>(0);
                static_cast<void>(0);
                
                // For PUBLIC groups, DHT discovery should work but may take time
                // For local bootstrap, we can try to accelerate by:
                // 1. Ensuring both instances are iterating
                // 2. Checking if we need to wait longer
                // 3. Verifying bootstrap configuration
                static_cast<void>(0);
                static_cast<void>(0);
                
                // Do more iterations to help DHT discovery (increased from 5 to 20 for better discovery)
                // With local bootstrap, this should help peers discover each other faster
                // Note: DHT discovery for PUBLIC groups can take time even with local bootstrap
                // c-toxcore tests use WAIT_UNTIL which continuously iterates until peers are found
                static_cast<void>(0);
                static_cast<void>(0);
                
                for (int i = 0; pump_on_caller && i < 20; i++) {
                    // Call iterate on both instances to help DHT discovery
                    // The event_thread_ should be doing this, but we can help by calling it directly
                    tox_manager->iterate(0);
                    if (join_session_ended()) {
                        abandon_join();
                        return;
                    }

                    // Also try to iterate on the other instance if we can identify it
                    // For now, just iterate on current instance
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    
                    // Check peer count every 5 iterations to see if discovery progressed
                    if (i % 5 == 0 && i > 0) {
                        int check_peer_count = 0;
                        for (Tox_Group_Peer_Number check_peer_id = 0; check_peer_id < 100; ++check_peer_id) {
                            uint8_t check_pubkey[TOX_PUBLIC_KEY_SIZE];
                            Tox_Err_Group_Peer_Query err_check;
                            if (tox_group_peer_get_public_key(tox, group_number, check_peer_id, check_pubkey, &err_check) &&
                                err_check == TOX_ERR_GROUP_PEER_QUERY_OK) {
                                check_peer_count++;
                            } else {
                                break;
                            }
                        }
                        static_cast<void>(0);
                        static_cast<void>(0);
                        if (check_peer_count > 1) {
                            static_cast<void>(0);
                            static_cast<void>(0);
                            break;
                        }
                    }
                }
                static_cast<void>(0);
                static_cast<void>(0);
            }
        }
    } else {
        static_cast<void>(0);
        static_cast<void>(0);
    }
    
    // Calculate total duration
    auto end_time = std::chrono::steady_clock::now();
    auto total_duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        end_time - start_time).count();
    
    static_cast<void>(0);
    static_cast<void>(0);
    static_cast<void>(0);
    static_cast<void>(0);
    
    V2TIM_LOG(kInfo, "[JoinGroup] Calling callback->OnSuccess");
    if (callback) {
        callback->OnSuccess();
        V2TIM_LOG(kInfo, "[JoinGroup] callback->OnSuccess completed");
    } else {
        V2TIM_LOG(kWarning, "[JoinGroup] callback is null, skipping OnSuccess");
    }
    
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "[JoinGroup] ========== JoinGroup completed (total={} ms) ==========", total_duration_ms);
}

void V2TIMManagerImpl::QuitGroup(const V2TIMString& groupID, V2TIMCallback* callback) {
    V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: ENTRY - groupID=%s", groupID.CString());
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it != group_id_to_group_number_.end()) {
            group_number = it->second;
            V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Found group_number=%u in group_id_to_group_number_ mapping", group_number);
        }
    }

    V2TIMGroupManagerImpl* groupManagerImpl = static_cast<V2TIMGroupManagerImpl*>(GetGroupManager());
    if (!groupManagerImpl) {
        V2TIM_LOG(kError, "V2TIMManagerImpl::QuitGroup: ERROR - GroupManagerImpl not available");
        if (callback) {
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "GroupManager not available");
        }
        return;
    }

    class QuitGroupCallbackWrapper final : public V2TIMCallback {
    public:
        explicit QuitGroupCallbackWrapper(Tox_Group_Number group_number)
            : group_number_(group_number) {}

        void OnSuccess() override { succeeded_ = true; }

        void OnError(int error_code, const V2TIMString& error_message) override {
            succeeded_ = false;
            error_code_ = error_code;
            error_message_ = error_message;
        }

        bool succeeded() const { return succeeded_; }
        Tox_Group_Number group_number() const { return group_number_; }
        int error_code() const { return error_code_; }
        const V2TIMString& error_message() const { return error_message_; }

    private:
        Tox_Group_Number group_number_;
        bool succeeded_{false};
        int error_code_{ERR_INVALID_PARAMETERS};
        V2TIMString error_message_;
    };

    QuitGroupCallbackWrapper wrapper_callback(group_number);
    V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Calling V2TIMGroupManagerImpl::QuitGroup");
    groupManagerImpl->QuitGroup(groupID, &wrapper_callback);

    if (!wrapper_callback.succeeded()) {
        if (callback) {
            callback->OnError(wrapper_callback.error_code(), wrapper_callback.error_message());
        }
        return;
    }

    Tox_Group_Number resolved_group_number = wrapper_callback.group_number();
    if (resolved_group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it != group_id_to_group_number_.end()) {
            resolved_group_number = it->second;
        }
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        group_id_to_group_number_.erase(groupID);
        if (resolved_group_number != UINT32_MAX) {
            group_number_to_group_id_.erase(resolved_group_number);
            fresh_group_joins_.erase(resolved_group_number);
            accepted_invites_.erase(resolved_group_number);
            dart_known_chat_id_.erase(groupID.CString());
            dart_known_type_.erase(groupID.CString());
        } else {
            for (auto it = group_number_to_group_id_.begin();
                 it != group_number_to_group_id_.end(); ++it) {
                if (it->second == groupID) {
                    group_number_to_group_id_.erase(it);
                    break;
                }
            }
        }
        bool legacy_conference_identity = false;
        auto type_it = group_id_to_type_.find(groupID);
        if (type_it != group_id_to_type_.end()) {
            legacy_conference_identity = type_it->second == "conference" ||
                                         type_it->second == "av_conference";
        }
        const bool is_legacy_conference = legacy_conference_identity;
        if (is_legacy_conference) {
            auto chat_it = group_id_to_chat_id_.find(groupID);
            if (chat_it != group_id_to_chat_id_.end()) {
                std::ostringstream oss;
                for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                    oss << std::hex << std::setw(2) << std::setfill('0')
                        << static_cast<int>(chat_it->second[i]);
                }
                std::string chat_id_hex = oss.str();
                group_id_to_chat_id_.erase(chat_it);
                chat_id_to_group_id_.erase(chat_id_hex);
                V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Removed legacy conference identity mappings (identity_hex=%s)", chat_id_hex.c_str());
            }
        } else {
            // Preserve stable NGCv2 chat_id mappings across leave/reinvite so
            // tox_inv_* aliases can resolve back to the original public groupID.
            V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Preserving canonical group chat_id mapping for groupID=%s", groupID.CString());
        }
        group_id_to_type_.erase(groupID);
    }

    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: Notifying %zu group listeners", listeners_copy.size());
    for (auto* listener : listeners_copy) {
        if (listener) {
            listener->OnQuitFromGroup(groupID);
        }
    }

    if (callback) {
        callback->OnSuccess();
    }
    V2TIM_LOG(kInfo, "V2TIMManagerImpl::QuitGroup: EXIT - Completed for groupID=%s", groupID.CString());
}

void V2TIMManagerImpl::DismissGroup(const V2TIMString& groupID, V2TIMCallback* callback) {
    std::string group_id_str = groupID.CString();
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "DismissGroup: dismissing group %s", group_id_str.c_str());
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it != group_id_to_group_number_.end()) {
            group_number = it->second;
        }
    }

    V2TIMGroupManagerImpl* groupManagerImpl = static_cast<V2TIMGroupManagerImpl*>(GetGroupManager());
    if (!groupManagerImpl) {
        if (callback) {
            callback->OnError(ERR_SDK_NOT_INITIALIZED, "GroupManager not available");
        }
        return;
    }

    class DismissGroupCallbackWrapper final : public V2TIMCallback {
    public:
        explicit DismissGroupCallbackWrapper(Tox_Group_Number group_number)
            : group_number_(group_number) {}

        void OnSuccess() override { succeeded_ = true; }

        void OnError(int error_code, const V2TIMString& error_message) override {
            succeeded_ = false;
            error_code_ = error_code;
            error_message_ = error_message;
        }

        bool succeeded() const { return succeeded_; }
        Tox_Group_Number group_number() const { return group_number_; }
        int error_code() const { return error_code_; }
        const V2TIMString& error_message() const { return error_message_; }

    private:
        Tox_Group_Number group_number_;
        bool succeeded_{false};
        int error_code_{ERR_INVALID_PARAMETERS};
        V2TIMString error_message_;
    };

    DismissGroupCallbackWrapper wrapper_callback(group_number);
    groupManagerImpl->DismissGroup(groupID, &wrapper_callback);

    if (!wrapper_callback.succeeded()) {
        if (callback) {
            callback->OnError(wrapper_callback.error_code(), wrapper_callback.error_message());
        }
        return;
    }

    Tox_Group_Number resolved_group_number = wrapper_callback.group_number();
    if (resolved_group_number == UINT32_MAX) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_id_to_group_number_.find(groupID);
        if (it != group_id_to_group_number_.end()) {
            resolved_group_number = it->second;
        }
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        group_id_to_group_number_.erase(groupID);
        if (resolved_group_number != UINT32_MAX) {
            group_number_to_group_id_.erase(resolved_group_number);
            fresh_group_joins_.erase(resolved_group_number);
            accepted_invites_.erase(resolved_group_number);
            dart_known_chat_id_.erase(groupID.CString());
            dart_known_type_.erase(groupID.CString());
        } else {
            for (auto it = group_number_to_group_id_.begin();
                 it != group_number_to_group_id_.end(); ++it) {
                if (it->second == groupID) {
                    group_number_to_group_id_.erase(it);
                    break;
                }
            }
        }
        auto chat_it = group_id_to_chat_id_.find(groupID);
        if (chat_it != group_id_to_chat_id_.end()) {
            std::ostringstream oss;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                oss << std::hex << std::setw(2) << std::setfill('0')
                    << static_cast<int>(chat_it->second[i]);
            }
            std::string chat_id_hex = oss.str();
            group_id_to_chat_id_.erase(chat_it);
            chat_id_to_group_id_.erase(chat_id_hex);
        }
        group_id_to_type_.erase(groupID);
    }

    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    for (auto* listener : listeners_copy) {
        if (listener) {
            V2TIMGroupMemberInfo opUser;
            opUser.userID = GetLoginUser();
            listener->OnGroupDismissed(groupID, opUser);
        }
    }

    if (callback) {
        callback->OnSuccess();
    }
}

// User Info
void V2TIMManagerImpl::GetUsersInfo(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMUserFullInfoVector>* callback) {
    V2TIMUserFullInfoVector infos; // Corrected typo: TXV2TIMUserFullInfoVector -> V2TIMUserFullInfoVector
    // Pinned across the whole per-user query loop below (FFI entry point).
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }

    // CRITICAL: Copy userIDList immediately to avoid lifetime issues
    // The userIDList reference may point to a temporary that gets destroyed
    // before this async function executes
    // Extract C-strings first and store them in std::string to avoid
    // accessing potentially invalid impl_ pointers from V2TIMString objects
    std::vector<std::string> user_id_strings;  // Store C-strings safely
    try {
        for (size_t i = 0; i < userIDList.Size(); i++) {
            try {
                const V2TIMString& userID = userIDList[i];
                // CRITICAL: Extract C-string immediately before copying
                // This avoids accessing potentially invalid impl_ pointers
                const char* user_id_cstr = nullptr;
                size_t user_id_len = 0;
                try {
                    user_id_len = userID.Length();
                    user_id_cstr = userID.CString();
                } catch (...) {
                    // Skip invalid userID
                    continue;
                }
                if (!user_id_cstr || user_id_len == 0) {
                    continue;
                }
                // Store C-string in std::string for safety (thread-safe copy)
                user_id_strings.push_back(std::string(user_id_cstr, user_id_len));
            } catch (...) {
                // Skip invalid userID
            }
        }
    } catch (...) {
        if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Failed to copy user ID list");
        return;
    }

    // CRITICAL: Use the safe std::string copies instead of V2TIMString objects
    // This avoids any potential race conditions or invalid pointer access
    for (const auto& user_id_str : user_id_strings) {
        V2TIMUserFullInfo info;
        try {
            // Create new V2TIMString directly from the safe std::string
            // This avoids accessing potentially invalid impl_ pointers
            info.userID = V2TIMString(user_id_str.c_str());
        } catch (...) {
            // Skip invalid userID
            continue;
        }

        // Assume userID is the hex public key string
        uint8_t pub_key[TOX_PUBLIC_KEY_SIZE];
        // CRITICAL: Use the safe std::string directly instead of accessing V2TIMString
        const char* user_id_cstr = user_id_str.c_str();
        size_t user_id_len = user_id_str.length();
        if (!user_id_cstr || user_id_len == 0) {
            continue;
        }
        // if (V2TIMUtils::HexToBytes(userID.CString(), pub_key, TOX_PUBLIC_KEY_SIZE)) {
        if (ToxUtil::tox_hex_to_bytes(user_id_cstr, user_id_len, pub_key, TOX_PUBLIC_KEY_SIZE)) {
            TOX_ERR_FRIEND_BY_PUBLIC_KEY err_find;
            uint32_t friend_number = tox_friend_by_public_key(tox, pub_key, &err_find);
            if (err_find == TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
                // Get Nickname from Tox
                TOX_ERR_FRIEND_QUERY err_name;
                size_t name_size = tox_friend_get_name_size(tox, friend_number, &err_name);
                if (err_name == TOX_ERR_FRIEND_QUERY_OK && name_size > 0) {
                    std::vector<uint8_t> name_buffer(name_size);
                    tox_friend_get_name(tox, friend_number, name_buffer.data(), &err_name);
                    if (err_name == TOX_ERR_FRIEND_QUERY_OK) {
                        try {
                            info.nickName = V2TIMString(reinterpret_cast<const char*>(name_buffer.data()), name_size);
                            // CRITICAL: Use the safe std::string directly instead of accessing V2TIMString
                            const char* nick_cstr = info.nickName.CString();
                            if (user_id_cstr && nick_cstr) {
                                tim2tox_ffi_save_friend_nickname(user_id_cstr, nick_cstr);
                            }
                        } catch (...) {
                            // Skip nickname assignment on error
                        }
                    }
                }
                // Note: If nickname is not available from Tox, Flutter layer will load from local cache
                // Get status message (selfSignature)
                TOX_ERR_FRIEND_QUERY err_status;
                size_t status_size = tox_friend_get_status_message_size(tox, friend_number, &err_status);
                if (err_status == TOX_ERR_FRIEND_QUERY_OK && status_size > 0) {
                    std::vector<uint8_t> status_buffer(status_size);
                    tox_friend_get_status_message(tox, friend_number, status_buffer.data(), &err_status);
                    if (err_status == TOX_ERR_FRIEND_QUERY_OK) {
                        try {
                            info.selfSignature = V2TIMString(reinterpret_cast<const char*>(status_buffer.data()), status_size);
                            // CRITICAL: Use the safe std::string directly instead of accessing V2TIMString
                            const char* sig_cstr = info.selfSignature.CString();
                            if (user_id_cstr && sig_cstr) {
                                tim2tox_ffi_save_friend_status_message(user_id_cstr, sig_cstr);
                            }
                        } catch (...) {
                            // Skip status message assignment on error
                        }
                    }
                }
                // Note: If status message is not available from Tox, Flutter layer will load from local cache
                // TODO: Get other fields like faceURL etc. (Tox has limited profile data)
                // info.status = ...; // V2TIMUserFullInfo doesn't have status. Use GetUserStatus instead.
            }
        }
        try {
            infos.PushBack(info);
        } catch (...) {
            // Skip invalid info on error
        }
    }
    if (callback) callback->OnSuccess(infos);
}

// Commented out SetSelfStatus due to cast issue
// void V2TIMManagerImpl::SetSelfStatus(const V2TIMUserStatus& status, V2TIMCallback* callback) {
//     // TODO: Need mapping from V2TIMUserStatus to TOX_USER_STATUS
//     // tox_self_set_status(GetToxManager()->getTox(), (TOX_USER_STATUS)status);
//     if (callback) callback->OnSuccess();
// }

void V2TIMManagerImpl::SubscribeUserInfo(const V2TIMStringVector& userIDList, V2TIMCallback* callback) {
    NotSupported(callback, "SubscribeUserInfo");
}

void V2TIMManagerImpl::UnsubscribeUserInfo(const V2TIMStringVector& userIDList, V2TIMCallback* callback) {
    NotSupported(callback, "UnsubscribeUserInfo");
}

void V2TIMManagerImpl::SetSelfInfo(const V2TIMUserFullInfo& info, V2TIMCallback* callback) {
    // Pinned across the name + status writes below (FFI entry point).
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox) {
        if (callback) callback->OnError(ERR_SDK_NOT_INITIALIZED, "Tox not initialized");
        return;
    }

    bool has_nickname = !info.nickName.Empty();
    bool has_status = !info.selfSignature.Empty();
    
    if (!has_nickname && !has_status) {
        if (callback) callback->OnSuccess();
        return;
    }

    if (has_nickname) {
        const char* nick_cstr = info.nickName.CString();
        if (nick_cstr) {
            TOX_ERR_SET_INFO err_name;
            tox_self_set_name(tox, reinterpret_cast<const uint8_t*>(nick_cstr), info.nickName.Length(), &err_name);
            if (err_name != TOX_ERR_SET_INFO_OK) {
                if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Set self nickname failed");
                return;
            }
        }
    }

    if (has_status) {
        const char* status_cstr = info.selfSignature.CString();
        if (status_cstr) {
            TOX_ERR_SET_INFO err_status;
            tox_self_set_status_message(tox, reinterpret_cast<const uint8_t*>(status_cstr), info.selfSignature.Length(), &err_status);
            if (err_status != TOX_ERR_SET_INFO_OK) {
                if (callback) callback->OnError(ERR_INVALID_PARAMETERS, "Set self status message failed");
                return;
            }
        }
    }

    // Notify SDK listeners of self info update (so onSelfInfoUpdated fires in Dart)
    {
        std::vector<V2TIMSDKListener*> listeners_to_notify;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            listeners_to_notify.assign(sdk_listeners_.begin(), sdk_listeners_.end());
        }
        for (V2TIMSDKListener* listener : listeners_to_notify) {
            if (listener) {
                listener->OnSelfInfoUpdated(info);
            }
        }
    }

    if (callback) callback->OnSuccess();
}

// Search & Status
void V2TIMManagerImpl::SearchUsers(const V2TIMUserSearchParam& param, V2TIMValueCallback<V2TIMUserSearchResult>* callback) {
    NotSupportedValue(callback, "SearchUsers");
}

void V2TIMManagerImpl::GetUserStatus(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMUserStatusVector>* callback) {
    NotSupportedValue(callback, "GetUserStatus");
}

void V2TIMManagerImpl::SetSelfStatus(const V2TIMUserStatus& status, V2TIMCallback* callback) {
    auto fail = [&](int code, const char* msg) {
        if (callback) {
            callback->OnError(code, msg);
        }
    };

    if (!tox_manager_) {
        fail(ERR_SDK_NOT_INITIALIZED, "ToxManager not initialized");
        return;
    }

    const char* custom_cstr = status.customStatus.CString();
    const std::string custom = custom_cstr ? custom_cstr : "";

    TOX_USER_STATUS tox_status = TOX_USER_STATUS_NONE;
    switch (status.statusType) {
        case V2TIM_USER_STATUS_ONLINE:
            // Online in TIM terms maps to \"no special\" status in tox.
            tox_status = TOX_USER_STATUS_NONE;
            break;
        case V2TIM_USER_STATUS_OFFLINE:
            // Offline is represented by connection state; keep status \"none\".
            tox_status = TOX_USER_STATUS_NONE;
            break;
        default:
            if (custom == "BUSY") {
                tox_status = TOX_USER_STATUS_BUSY;
            } else if (custom == "AWAY") {
                tox_status = TOX_USER_STATUS_AWAY;
            } else {
                tox_status = TOX_USER_STATUS_NONE;
            }
            break;
    }

    if (!tox_manager_->setStatus(tox_status)) {
        fail(ERR_IO_OPERATION_FAILED, "SetSelfStatus failed");
        return;
    }

    if (callback) {
        callback->OnSuccess();
    }
}

void V2TIMManagerImpl::SubscribeUserStatus(const V2TIMStringVector& userIDList, V2TIMCallback* callback) {
    NotSupported(callback, "SubscribeUserStatus");
}

void V2TIMManagerImpl::UnsubscribeUserStatus(const V2TIMStringVector& userIDList, V2TIMCallback* callback) {
    NotSupported(callback, "UnsubscribeUserStatus");
}

// Advanced Managers (R-06: owned by this instance, lazy-created)
V2TIMMessageManager* V2TIMManagerImpl::GetMessageManager() {
    if (!message_manager_) {
        message_manager_ = std::make_unique<V2TIMMessageManagerImpl>(this);
    }
    return message_manager_.get();
}

V2TIMGroupManager* V2TIMManagerImpl::GetGroupManager() {
    if (!group_manager_) {
        group_manager_ = std::make_unique<V2TIMGroupManagerImpl>(this);
    }
    std::atomic_thread_fence(std::memory_order_acquire);
    return group_manager_.get();
}

V2TIMCommunityManager* V2TIMManagerImpl::GetCommunityManager() {
    if (!community_manager_) {
        community_manager_ = std::make_unique<V2TIMCommunityManagerImpl>(this);
    }
    return community_manager_.get();
}

V2TIMConversationManager* V2TIMManagerImpl::GetConversationManager() {
    if (!conversation_manager_) {
        conversation_manager_ = std::make_unique<V2TIMConversationManagerImpl>(this);
    }
    return conversation_manager_.get();
}

V2TIMFriendshipManager* V2TIMManagerImpl::GetFriendshipManager() {
    if (!friendship_manager_) {
        friendship_manager_ = std::make_unique<V2TIMFriendshipManagerImpl>(this);
    }
    return friendship_manager_.get();
}

V2TIMOfflinePushManager* V2TIMManagerImpl::GetOfflinePushManager() {
    return nullptr;  // Unsupported; do not fake success elsewhere
}

V2TIMSignalingManager* V2TIMManagerImpl::GetSignalingManager() {
    // Per-instance signaling manager for multi-instance support
    if (!signaling_manager_) {
        signaling_manager_ = std::make_unique<V2TIMSignalingManagerImpl>();
        if (signaling_manager_) {
            signaling_manager_->SetManagerImpl(this);
        }
    }
    return signaling_manager_.get();
}

// Experimental API
void V2TIMManagerImpl::CallExperimentalAPI(const V2TIMString& api, const void* param, V2TIMValueCallback<V2TIMBaseObject>* callback) {
    NotSupportedValue(callback, "CallExperimentalAPI");
}

// Remove find_conference_by_id helper for now, will be handled within JoinGroup/Map logic
// uint32_t V2TIMManagerImpl::find_conference_by_id(const V2TIMString& groupID) { ... }

// Helper method to get all group IDs from mapping
std::vector<V2TIMString> V2TIMManagerImpl::GetAllGroupIDs() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<V2TIMString> groupIDs;
    for (const auto& pair : group_id_to_group_number_) {
        groupIDs.push_back(pair.first);
    }
    return groupIDs;
}

// R-07: Instance metadata (Core-owned; FFI forwards to these)
std::vector<std::string> V2TIMManagerImpl::GetKnownGroupIDs() {
    std::lock_guard<std::mutex> lock(metadata_mutex_);
    return known_groups_;
}

void V2TIMManagerImpl::SetKnownGroupIDs(const std::vector<std::string>& group_ids) {
    std::lock_guard<std::mutex> lock(metadata_mutex_);
    known_groups_ = group_ids;
}

bool V2TIMManagerImpl::GetGroupChatIdFromStorage(const std::string& group_id, char* out_chat_id_hex, int out_len) {
    if (!out_chat_id_hex || out_len < 65) return false;
    V2TIMString gid(group_id.c_str());
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_chat_id_.find(gid);
    if (it == group_id_to_chat_id_.end() || it->second.size() != TOX_GROUP_CHAT_ID_SIZE) return false;
    std::ostringstream oss;
    for (size_t i = 0; i < it->second.size(); ++i)
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(it->second[i]);
    std::string hex = oss.str();
    int n = (int)std::min(hex.size(), (size_t)(out_len - 1));
    memcpy(out_chat_id_hex, hex.c_str(), n);
    out_chat_id_hex[n] = '\0';
    return true;
}

void V2TIMManagerImpl::SetGroupChatIdInStorage(const std::string& group_id, const std::string& chat_id_hex,
                                               bool from_dart) {
    // See the LOCKING CONTRACT note in the header: this variant takes mutex_;
    // never call it from a scope that already holds mutex_ (self-deadlock).
    if (chat_id_hex.length() != TOX_GROUP_CHAT_ID_SIZE * 2) return;
    std::lock_guard<std::mutex> lock(mutex_);
    SetGroupChatIdInStorageLocked(group_id, chat_id_hex, from_dart);
}

void V2TIMManagerImpl::SetGroupChatIdInStorageLocked(const std::string& group_id, const std::string& chat_id_hex,
                                                     bool from_dart) {
    // Caller must hold mutex_. Length validation is repeated here so the
    // Locked variant can be called directly. (Note: like the original code,
    // strtoul-based parsing does not reject non-hex characters — pre-existing
    // behavior, kept byte-identical on purpose.)
    if (chat_id_hex.length() != TOX_GROUP_CHAT_ID_SIZE * 2) return;
    std::vector<uint8_t> bin(TOX_GROUP_CHAT_ID_SIZE);
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        unsigned long byte_val = strtoul(chat_id_hex.substr(i * 2, 2).c_str(), nullptr, 16);
        if (byte_val > 255) return;
        bin[i] = (uint8_t)byte_val;
    }
    const V2TIMString stable_group_id(group_id.c_str());
    group_id_to_chat_id_[stable_group_id] = std::move(bin);
    if (!IsTemporaryInviteGroupID(stable_group_id)) {
        RememberCrossInstanceGroupIdentity(group_id, chat_id_hex,
                                           GetInstanceIdFromManager(this));
        std::string normalized = chat_id_hex;
        std::transform(normalized.begin(), normalized.end(), normalized.begin(), ::tolower);
        std::string& known = dart_known_chat_id_[group_id];
        if (known != normalized) {
            known = normalized;
            // Leaf lock only (the Dart port mutex): safe under mutex_.
            if (!from_dart) {
                DartNotifyGroupIdentityStored(group_id.c_str(), normalized.c_str(),
                                              GetInstanceIdFromManager(this), GetSessionEpoch());
            }
        }
    }
}

bool V2TIMManagerImpl::GetGroupTypeFromStorage(const std::string& group_id, char* out_type, int out_len) {
    if (!out_type || out_len < 16) return false;
    V2TIMString gid(group_id.c_str());
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_type_.find(gid);
    if (it == group_id_to_type_.end()) return false;
    int n = (int)std::min(it->second.size(), (size_t)(out_len - 1));
    memcpy(out_type, it->second.c_str(), n);
    out_type[n] = '\0';
    return true;
}

void V2TIMManagerImpl::SetGroupTypeInStorage(const std::string& group_id, const std::string& group_type,
                                             bool from_dart) {
    const V2TIMString gid(group_id.c_str());
    bool notify = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        group_id_to_type_[gid] = group_type;
        if (!group_type.empty() && !IsTemporaryInviteGroupID(gid)) {
            std::string& known = dart_known_type_[group_id];
            if (known != group_type) {
                known = group_type;
                notify = !from_dart;
            }
        }
    }
    if (notify) {
        DartNotifyGroupTypeStored(group_id.c_str(), group_type.c_str(),
                                  GetInstanceIdFromManager(this), GetSessionEpoch());
    }
}

std::string V2TIMManagerImpl::SnapshotGroupIdentitiesForClient() const {
    static constexpr char kHexDigits[] = "0123456789abcdef";
    std::map<std::string, std::pair<std::string, std::string>> rows;  // id -> (chat id, type)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto& [gid, bin] : group_id_to_chat_id_) {
            if (bin.size() != TOX_GROUP_CHAT_ID_SIZE || IsTemporaryInviteGroupID(gid)) continue;
            std::string hex(bin.size() * 2, '0');
            for (size_t i = 0; i < bin.size(); ++i) {
                hex[i * 2] = kHexDigits[bin[i] >> 4];
                hex[i * 2 + 1] = kHexDigits[bin[i] & 0x0f];
            }
            rows[gid.CString()].first = std::move(hex);
        }
        for (const auto& [gid, type] : group_id_to_type_) {
            if (type.empty() || IsTemporaryInviteGroupID(gid)) continue;
            rows[gid.CString()].second = type;
        }
    }
    std::string out;
    for (const auto& [id, value] : rows) {
        // Fields are tab-separated: ids and kinds never contain tabs/newlines.
        if (id.empty() || id.find_first_of("\t\n") != std::string::npos) continue;
        out.append(id).append(1, '\t').append(value.first).append(1, '\t')
            .append(value.second).append(1, '\n');
    }
    return out;
}

int V2TIMManagerImpl::PublishGroupInfoField(const std::string& group_id, int field, const std::string& value) {
    auto* group_manager = static_cast<V2TIMGroupManagerImpl*>(GetGroupManager());
    if (!group_manager) return 0;
    V2TIMGroupInfo info;
    info.groupID = group_id.c_str();
    if (field == V2TIM_GROUP_INFO_CHANGE_TYPE_NAME) {
        info.groupName = value.c_str();
    } else if (field == V2TIM_GROUP_INFO_CHANGE_TYPE_NOTIFICATION) {
        info.notification = value.c_str();
    } else {
        return 0;
    }
    struct Cb : public V2TIMCallback {
        int result = 0;
        void OnSuccess() override { result = 1; }
        // -2 = "not permitted": SetGroupInfo reports a topic-lock / role
        // refusal as ERR_SVR_GROUP_PERMISSION_DENY.
        void OnError(int code, const V2TIMString&) override {
            result = code == ERR_SVR_GROUP_PERMISSION_DENY ? -2 : 0;
        }
    } cb;
    group_manager->SetGroupInfo(info, &cb);  // completes synchronously
    return cb.result;
}

int V2TIMManagerImpl::CanSetGroupTopic(const std::string& group_id) {
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager || group_id.empty()) return -1;
    Tox_Group_Number group_number = UINT32_MAX;
    if (!GetGroupNumberFromID(V2TIMString(group_id.c_str()), group_number) ||
        group_number == UINT32_MAX || IsConferenceMapKey(group_number)) {
        return -1;  // conferences have no topic; unmapped: unknown
    }
    Tox_Err_Group_Self_Query err_self = TOX_ERR_GROUP_SELF_QUERY_OK;
    const Tox_Group_Role self_role = tox_manager->getSelfRole(group_number, &err_self);
    if (err_self != TOX_ERR_GROUP_SELF_QUERY_OK) return -1;
    if (self_role == TOX_GROUP_ROLE_FOUNDER || self_role == TOX_GROUP_ROLE_MODERATOR) return 1;
    if (self_role == TOX_GROUP_ROLE_OBSERVER) return 0;
    Tox_Err_Group_State_Query err_lock = TOX_ERR_GROUP_STATE_QUERY_OK;
    const Tox_Group_Topic_Lock lock = tox_manager->getGroupTopicLock(group_number, &err_lock);
    if (err_lock != TOX_ERR_GROUP_STATE_QUERY_OK) return -1;
    return lock == TOX_GROUP_TOPIC_LOCK_DISABLED ? 1 : 0;
}

// ---------------------------------------------------------------------------
// MM-6: which NGC member is my friend?
//
// NGC names members by per-group keys; nothing links one to a friend's
// long-term key. Protocol (all tim2tox peers):
//  1. HINT. Friends send each other, over the friend channel (authenticated by
//     the long-term key), sha256(chat_id || own per-group key) for each group.
//     A hint proves nothing: both inputs are public to every group member.
//  2. CHALLENGE. When a hint matches member K of group G, we send that friend
//     F a nonce over the friend channel: chat_id || our per-group key || nonce.
//  3. PROOF (v2, encrypted). F sends, from its per-group key and over NGC's
//     authenticated private channel, an authenticated box that only the ASKER
//     can open: it is sealed with F's long-term SECRET key to the asker's
//     long-term PUBLIC key, and the asker's public key is taken from the
//     authenticated friend connection the challenge arrived on — never from
//     the challenge body. Accepted only from K itself, for an unexpired
//     pending nonce of ours, with every transcript field matching what we
//     asked. See kIdentityProof* below for the byte layout and for what each
//     bound field buys.
//
//     Why encrypted (the MM-6 leak, fixed 2026-09-23): the challenge body
//     names "the challenger's per-group key", and that value is whatever the
//     friend put in the packet. Per-group keys are visible to every member,
//     so a friend F could name ANY member M and we would then send M, from
//     our per-group key, a PLAINTEXT "nonce || F's long-term key" — telling M
//     that our per-group key belongs to a friend of F's, one member per
//     challenge and 32 per minute. Gating the answer on "F must have hinted
//     that key" does NOT work, and the reason is ORDERING, not reachability:
//     the asker does announce its own digests to every online friend, but
//     MatchGroupIdentityDigests fires the challenge from the peer-join path
//     before that announcement has gone out, and a challenger never retries.
//     Encrypting the proof to the asker's long-term key fixes it without
//     touching the honest flow: we still answer whatever key F names, but
//     only F can read the answer. What M can still observe is that our
//     per-group key sent it one unreadable tim2tox private packet — a traffic
//     fact, not an identity. Wire-format change with no v1 fallback: the
//     plaintext proof is neither sent nor accepted any more.
//
// Everything a friend can make us do here runs on the tox event thread, so
// every step is bounded per friend and globally and every cache expires:
//  - hints: a rate window on packets and on NEW digests; a new digest costs
//    one lookup in member_digest_index_ (our peers' digests, hashed once per
//    peer), never a rehash of every group.
//  - claims: a digest keeps ALL its claimants (bounded), each is challenged,
//    so a friend replaying a real friend's hint cannot divert the challenge.
//  - challenges: at most one pending per (friend, group, member), a per-friend
//    cap, a TTL; a proof consumes only the entry it exactly matches.
//  - answering: each (friend, chat id, nonce) is answered at most once, and
//    proofs sent per friend are rate limited. Sealing the answer costs one
//    box per answered challenge, so the same budgets still bound the work.
//  - verifying: a received proof is only opened against OUR pending
//    challenges for (this group, this authenticated NGC sender) — at most
//    kMaxClaimantsPerDigest of them — and the attempts share a global rate
//    window, so a member cannot turn NGC packets into unbounded crypto.
// ---------------------------------------------------------------------------
namespace {
constexpr uint8_t kIdentityHints = 1;
constexpr uint8_t kIdentityChallenge = 2;
constexpr size_t kIdentityNonceSize = 16;
constexpr size_t kDigestsPerPacket = 40;
// --- MM-6 proof v2 wire format -------------------------------------------
// NGC private packet payload (after the 6-byte tim2tox group-packet header,
// kind = kTim2ToxGroupPacketIdentityProof):
//
//   box_nonce[CRYPTO_NONCE_SIZE=24] || box(plain)[kIdentityProofPlainSize+16]
//
// box() = toxcore encrypt_data(responder long-term SECRET, asker long-term
// PUBLIC, box_nonce) — an authenticated (crypto_box) seal, so only the asker
// can open it and only the responder can have produced it. toxcore has no
// sealed-box primitive, hence the explicit nonce prefix.
//
//   plain = kIdentityProofDomain[16]      domain separation: a box made for
//                                         any other tim2tox purpose between
//                                         the same two long-term keys can
//                                         never be replayed as a proof.
//        || chat_id[32]                   binds the group: a proof earned in
//                                         one group cannot be replayed into
//                                         another.
//        || asker_group_key[32]           the per-group key the challenge
//                                         claimed for the asker; the asker
//                                         re-derives its own and compares, so
//                                         a proof cannot be lifted from a
//                                         challenge we did not send.
//        || responder_group_key[32]       the responder's per-group key. The
//                                         asker requires it to equal the
//                                         toxcore-authenticated NGC envelope
//                                         sender: that is what ties "this
//                                         long-term key" (box authorship) to
//                                         "this member" (envelope) and is the
//                                         whole MM-6 claim.
//        || challenge_nonce[16]           identifies the pending challenge:
//                                         freshness + replay protection.
//        || asker_long_term_key[32]       names US as the asker, so a friend
//                                         cannot relay our nonce to a third
//                                         member and pass that member's proof
//                                         back as its own.
constexpr char kIdentityProofDomain[] = "T2T-MM6-proof-v2";
constexpr size_t kIdentityProofDomainSize = sizeof(kIdentityProofDomain) - 1;  // no NUL on the wire
static_assert(kIdentityProofDomainSize == 16, "proof domain tag must stay 16 bytes");
constexpr size_t kIdentityProofPlainSize = kIdentityProofDomainSize + TOX_GROUP_CHAT_ID_SIZE +
                                           TOX_PUBLIC_KEY_SIZE + TOX_PUBLIC_KEY_SIZE +
                                           kIdentityNonceSize + TOX_PUBLIC_KEY_SIZE;
constexpr size_t kIdentityProofPacketSize =
    CRYPTO_NONCE_SIZE + kIdentityProofPlainSize + CRYPTO_MAC_SIZE;
// Offsets inside plain.
constexpr size_t kIdentityProofOffChatId = kIdentityProofDomainSize;
constexpr size_t kIdentityProofOffAskerGroupKey = kIdentityProofOffChatId + TOX_GROUP_CHAT_ID_SIZE;
constexpr size_t kIdentityProofOffResponderGroupKey =
    kIdentityProofOffAskerGroupKey + TOX_PUBLIC_KEY_SIZE;
constexpr size_t kIdentityProofOffNonce =
    kIdentityProofOffResponderGroupKey + TOX_PUBLIC_KEY_SIZE;
constexpr size_t kIdentityProofOffAskerLongTermKey = kIdentityProofOffNonce + kIdentityNonceSize;
// Asking side.
constexpr size_t kMaxPendingIdentityChallenges = 256;
constexpr size_t kMaxPendingChallengesPerFriend = 32;
constexpr auto kIdentityChallengeTtl = std::chrono::seconds(60);
constexpr size_t kMaxClaimsPerFriend = 256;
constexpr size_t kMaxIdentityClaims = 4096;
constexpr size_t kMaxClaimantsPerDigest = 8;
constexpr auto kIdentityClaimTtl = std::chrono::hours(24);
constexpr size_t kMaxProvenMembers = 4096;
constexpr size_t kMaxIndexedMembers = 16384;
// Rate windows (per kIdentityRateWindow).
constexpr auto kIdentityRateWindow = std::chrono::seconds(60);
constexpr uint32_t kMaxHintPacketsPerFriend = 32;
constexpr uint32_t kMaxNewDigestsPerFriend = 128;
constexpr uint32_t kMaxNewDigestsGlobal = 512;
constexpr uint32_t kMaxProofsPerFriend = 32;
// Well above per-friend x a realistic friend count: at 4x, four hostile
// friends could spend the whole global window and every legitimate challenge
// from a fifth friend went unanswered for 60s (the challenger times out and
// does not retry).
constexpr uint32_t kMaxProofsGlobal = 2048;
// Opening a received proof: capped globally because the sender is an NGC group
// peer, not a friend, so there is no per-friend window to charge it to. Far
// above any honest volume (one proof per member per group), and reaching it at
// all needs the sender to be a member we have an unexpired challenge out for.
constexpr uint32_t kMaxProofVerifiesGlobal = 4096;
// Answering side replay cache.
constexpr size_t kMaxAnsweredChallenges = 1024;
constexpr auto kAnsweredChallengeTtl = std::chrono::minutes(10);
// Group receipt replay filter (see HandleGroupCustomPrivatePacket).
constexpr size_t kMaxSeenGroupReceipts = 4096;
constexpr auto kSeenGroupReceiptTtl = std::chrono::minutes(10);
constexpr auto kIdentityPruneInterval = std::chrono::seconds(30);

std::string IdentitySlotKey(Tox_Group_Number group_number, const std::string& member_key_lower) {
    return std::to_string(group_number) + "|" + member_key_lower;
}

std::string LowerHex(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    return value;
}

std::string GroupIdentityDigestHex(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE],
                                   const uint8_t member_key[TOX_PUBLIC_KEY_SIZE]) {
    uint8_t input[TOX_GROUP_CHAT_ID_SIZE + TOX_PUBLIC_KEY_SIZE];
    memcpy(input, chat_id, TOX_GROUP_CHAT_ID_SIZE);
    memcpy(input + TOX_GROUP_CHAT_ID_SIZE, member_key, TOX_PUBLIC_KEY_SIZE);
    uint8_t digest[CRYPTO_SHA256_SIZE];
    crypto_sha256(digest, input, sizeof(input));
    return ToxUtil::tox_bytes_to_hex(digest, CRYPTO_SHA256_SIZE);
}

void SendFriendIdentityFrame(Tox* tox, uint32_t friend_number, const std::string& body) {
    const auto frame = tim2tox::control::Encode(tim2tox::control::Type::kGroupIdentity, body);
    if (!frame.has_value()) return;
    Tox_Err_Friend_Custom_Packet err_send;
    tox_friend_send_lossless_packet(tox, friend_number, frame->data(), frame->size(), &err_send);
}

// A scratch copy of our long-term secret key, wiped on scope exit. Fetching it
// costs a tox call, so callers pull it once and keep it out of inner loops (and
// out of any scope that holds V2TIMManagerImpl::mutex_ across a tox call).
class SelfSecretKey {
public:
    explicit SelfSecretKey(const Tox* tox) { tox_self_get_secret_key(tox, key_); }
    ~SelfSecretKey() { crypto_memzero(key_, sizeof(key_)); }
    SelfSecretKey(const SelfSecretKey&) = delete;
    SelfSecretKey& operator=(const SelfSecretKey&) = delete;
    const uint8_t* get() const { return key_; }

private:
    uint8_t key_[CRYPTO_SECRET_KEY_SIZE];
};

// Build the MM-6 proof v2 NGC packet (header + box). Sealed with OUR long-term
// secret key to the asker's long-term public key, which the caller must have
// taken from the authenticated friend connection -- never from the challenge
// body, or the box would be readable by whoever the challenge named.
// Returns false (and sends nothing) when the CSPRNG or the box is unavailable:
// a proof that cannot be sealed must not fall back to plaintext.
bool SealIdentityProof(const Tox* tox, const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE],
                       const uint8_t asker_group_key[TOX_PUBLIC_KEY_SIZE],
                       const uint8_t responder_group_key[TOX_PUBLIC_KEY_SIZE],
                       const uint8_t challenge_nonce[kIdentityNonceSize],
                       const uint8_t asker_long_term_key[TOX_PUBLIC_KEY_SIZE],
                       std::vector<uint8_t>* out_packet) {
    const Random* rng = os_random();
    const Memory* mem = os_memory();
    if (rng == nullptr || mem == nullptr || out_packet == nullptr) return false;
    uint8_t plain[kIdentityProofPlainSize];
    memcpy(plain, kIdentityProofDomain, kIdentityProofDomainSize);
    memcpy(plain + kIdentityProofOffChatId, chat_id, TOX_GROUP_CHAT_ID_SIZE);
    memcpy(plain + kIdentityProofOffAskerGroupKey, asker_group_key, TOX_PUBLIC_KEY_SIZE);
    memcpy(plain + kIdentityProofOffResponderGroupKey, responder_group_key, TOX_PUBLIC_KEY_SIZE);
    memcpy(plain + kIdentityProofOffNonce, challenge_nonce, kIdentityNonceSize);
    memcpy(plain + kIdentityProofOffAskerLongTermKey, asker_long_term_key, TOX_PUBLIC_KEY_SIZE);
    std::vector<uint8_t> payload(kIdentityProofPacketSize);
    random_nonce(rng, payload.data());
    const SelfSecretKey self_secret(tox);
    const int32_t sealed = encrypt_data(mem, asker_long_term_key, self_secret.get(), payload.data(),
                                        plain, sizeof(plain), payload.data() + CRYPTO_NONCE_SIZE);
    crypto_memzero(plain, sizeof(plain));
    if (sealed != static_cast<int32_t>(kIdentityProofPlainSize + CRYPTO_MAC_SIZE)) return false;
    *out_packet = WrapTim2ToxGroupPacket(kTim2ToxGroupPacketIdentityProof, payload.data(), payload.size());
    return true;
}
}  // namespace

void V2TIMManagerImpl::AnnounceGroupIdentities(uint32_t only_friend, Tox_Group_Number only_group) {
    // Reachable from the FFI thread (group create/join) as well as from tox
    // callbacks, and it walks every group with the same handle: pinned.
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox || !running_) return;
    std::vector<Tox_Group_Number> groups;
    if (only_group != UINT32_MAX) {
        if (!IsConferenceMapKey(only_group)) groups.push_back(only_group);
    } else {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto& entry : group_number_to_group_id_) {
            if (!IsConferenceMapKey(entry.first)) groups.push_back(entry.first);
        }
    }
    std::string digests;  // raw 32-byte digests, concatenated
    for (const Tox_Group_Number group_number : groups) {
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        uint8_t self_key[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_State_Query err_chat;
        Tox_Err_Group_Self_Query err_self;
        if (!tox_group_get_chat_id(tox, group_number, chat_id, &err_chat) ||
            !tox_group_self_get_public_key(tox, group_number, self_key, &err_self)) {
            continue;
        }
        uint8_t input[TOX_GROUP_CHAT_ID_SIZE + TOX_PUBLIC_KEY_SIZE];
        memcpy(input, chat_id, TOX_GROUP_CHAT_ID_SIZE);
        memcpy(input + TOX_GROUP_CHAT_ID_SIZE, self_key, TOX_PUBLIC_KEY_SIZE);
        uint8_t digest[CRYPTO_SHA256_SIZE];
        crypto_sha256(digest, input, sizeof(input));
        digests.append(reinterpret_cast<const char*>(digest), CRYPTO_SHA256_SIZE);
    }
    if (digests.empty()) return;

    std::vector<uint32_t> targets;
    if (only_friend != UINT32_MAX) {
        targets.push_back(only_friend);
    } else {
        std::lock_guard<std::mutex> lock(mutex_);
        targets.assign(online_identity_friends_.begin(), online_identity_friends_.end());
    }
    for (const uint32_t f : targets) {
        for (size_t off = 0; off < digests.size(); off += kDigestsPerPacket * CRYPTO_SHA256_SIZE) {
            std::string body(1, static_cast<char>(kIdentityHints));
            body.append(digests, off, kDigestsPerPacket * CRYPTO_SHA256_SIZE);
            SendFriendIdentityFrame(tox, f, body);
        }
    }
}

void V2TIMManagerImpl::NoteFriendConnectionForIdentity(uint32_t friend_number, bool online) {
    if (!online) {
        // The friend re-sends every hint when it next comes online, so its
        // claims are only worth holding while it is connected (a challenge
        // needs the friend channel anyway). Proven mappings stay: they are
        // backed by a proof, not by the hint.
        std::string friend_hex;
        Tox* tox = GetToxManager() ? GetToxManager()->getTox() : nullptr;
        if (tox) {
            uint8_t friend_key[TOX_PUBLIC_KEY_SIZE];
            TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
            if (tox_friend_get_public_key(tox, friend_number, friend_key, &err_key)) {
                friend_hex = ToxUtil::tox_bytes_to_hex(friend_key, TOX_PUBLIC_KEY_SIZE);
            }
        }
        std::lock_guard<std::mutex> lock(mutex_);
        online_identity_friends_.erase(friend_number);
        if (!friend_hex.empty()) DropFriendIdentityClaimsLocked(friend_hex);
        return;
    }
    bool newly_online = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        newly_online = online_identity_friends_.insert(friend_number).second;
    }
    // Only on offline -> online, not on every TCP <-> UDP switch.
    if (newly_online) AnnounceGroupIdentities(friend_number, UINT32_MAX);
}

void V2TIMManagerImpl::PurgeFriendIdentityState(uint32_t friend_number, const std::string& friend_hex_in) {
    const std::string friend_hex = [&] {
        std::string upper = friend_hex_in.substr(0, TOX_PUBLIC_KEY_SIZE * 2);
        std::transform(upper.begin(), upper.end(), upper.begin(),
                       [](unsigned char ch) { return static_cast<char>(std::toupper(ch)); });
        return upper;  // the spelling ToxUtil::tox_bytes_to_hex produces
    }();
    std::lock_guard<std::mutex> lock(mutex_);
    online_identity_friends_.erase(friend_number);
    if (friend_hex.empty()) return;
    DropFriendIdentityClaimsLocked(friend_hex);
    for (auto it = pending_identity_challenges_.begin(); it != pending_identity_challenges_.end();) {
        it = it->second.friend_hex == friend_hex ? pending_identity_challenges_.erase(it) : std::next(it);
    }
    // Their group members are no longer "my friend": attributing them would
    // keep showing a deleted friend's identity on NGC rows.
    for (auto it = member_key_to_friend_.begin(); it != member_key_to_friend_.end();) {
        it = it->second.friend_hex == friend_hex ? member_key_to_friend_.erase(it) : std::next(it);
    }
    identity_rate_by_friend_.erase(friend_hex);
}

void V2TIMManagerImpl::EraseIdentityClaimLocked(const std::string& friend_hex, const std::string& digest) {
    const auto friend_it = friend_group_digests_.find(friend_hex);
    if (friend_it != friend_group_digests_.end()) {
        if (friend_it->second.erase(digest) > 0 && identity_claim_count_ > 0) --identity_claim_count_;
        if (friend_it->second.empty()) friend_group_digests_.erase(friend_it);
    }
    const auto claim_it = digest_claimants_.find(digest);
    if (claim_it != digest_claimants_.end()) {
        claim_it->second.erase(friend_hex);
        if (claim_it->second.empty()) digest_claimants_.erase(claim_it);
    }
}

void V2TIMManagerImpl::DropFriendIdentityClaimsLocked(const std::string& friend_hex) {
    const auto friend_it = friend_group_digests_.find(friend_hex);
    if (friend_it == friend_group_digests_.end()) return;
    for (const auto& entry : friend_it->second) {
        const auto claim_it = digest_claimants_.find(entry.first);
        if (claim_it != digest_claimants_.end()) {
            claim_it->second.erase(friend_hex);
            if (claim_it->second.empty()) digest_claimants_.erase(claim_it);
        }
    }
    const size_t dropped = friend_it->second.size();
    identity_claim_count_ = identity_claim_count_ > dropped ? identity_claim_count_ - dropped : 0;
    friend_group_digests_.erase(friend_it);
}

void V2TIMManagerImpl::EraseIndexedGroupMemberLocked(Tox_Group_Number group_number,
                                                     const std::string& member_key_lower) {
    const auto slot_it = member_digest_by_slot_.find(IdentitySlotKey(group_number, member_key_lower));
    if (slot_it == member_digest_by_slot_.end()) return;
    const auto index_it = member_digest_index_.find(slot_it->second);
    if (index_it != member_digest_index_.end()) {
        auto& members = index_it->second;
        members.erase(std::remove_if(members.begin(), members.end(),
                                     [&](const IndexedGroupMember& m) {
                                         return m.group_number == group_number &&
                                                m.member_key == member_key_lower;
                                     }),
                      members.end());
        if (members.empty()) member_digest_index_.erase(index_it);
    }
    member_digest_by_slot_.erase(slot_it);
}

bool V2TIMManagerImpl::TakeIdentityBudgetLocked(IdentityRateWindow& window, IdentityClock::time_point now,
                                                uint32_t IdentityRateWindow::*counter, uint32_t limit) {
    const bool window_unset = window.window_start == IdentityClock::time_point();
    if (window_unset || (now - window.window_start) >= kIdentityRateWindow) {
        window = IdentityRateWindow{};
        window.window_start = now;
    }
    if (window.*counter >= limit) return false;
    ++(window.*counter);
    return true;
}

void V2TIMManagerImpl::PruneIdentityStateLocked(IdentityClock::time_point now, bool force_prune) {
    const bool pruned_before = identity_last_prune_ != IdentityClock::time_point();
    const bool pruned_recently = pruned_before && (now - identity_last_prune_) < kIdentityPruneInterval;
    if (!force_prune && pruned_recently) return;
    identity_last_prune_ = now;
    std::vector<std::pair<std::string, std::string>> expired_claims;
    for (const auto& [friend_hex, digests] : friend_group_digests_) {
        for (const auto& [digest, seen_at] : digests) {
            if (now - seen_at > kIdentityClaimTtl) expired_claims.emplace_back(friend_hex, digest);
        }
    }
    for (const auto& [friend_hex, digest] : expired_claims) EraseIdentityClaimLocked(friend_hex, digest);
    for (auto it = pending_identity_challenges_.begin(); it != pending_identity_challenges_.end();) {
        it = now - it->second.sent_at > kIdentityChallengeTtl ? pending_identity_challenges_.erase(it) : std::next(it);
    }
    // Keys are unique in each deque (a key is inserted only while absent), so
    // popping the front always removes the entry it was queued for.
    while (!answered_identity_challenge_order_.empty() &&
           now - answered_identity_challenge_order_.front().first > kAnsweredChallengeTtl) {
        answered_identity_challenges_.erase(answered_identity_challenge_order_.front().second);
        answered_identity_challenge_order_.pop_front();
    }
    while (!seen_group_receipt_order_.empty() &&
           now - seen_group_receipt_order_.front().first > kSeenGroupReceiptTtl) {
        seen_group_receipts_.erase(seen_group_receipt_order_.front().second);
        seen_group_receipt_order_.pop_front();
    }
    // Proven members of NGC groups we no longer hold.
    for (auto it = member_key_to_friend_.begin(); it != member_key_to_friend_.end();) {
        it = group_number_to_group_id_.count(it->second.group_number) == 0 ? member_key_to_friend_.erase(it)
                                                                          : std::next(it);
    }
    // An idle window would be reset on its next use anyway.
    for (auto it = identity_rate_by_friend_.begin(); it != identity_rate_by_friend_.end();) {
        it = now - it->second.window_start >= kIdentityRateWindow ? identity_rate_by_friend_.erase(it)
                                                                  : std::next(it);
    }
}

void V2TIMManagerImpl::SyncMemberDigestIndex(Tox* tox) {
    if (!tox) return;
    std::vector<std::pair<Tox_Group_Number, std::string>> missing;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        // Drop members that left the peer cache (exit, kick, group gone).
        std::vector<std::pair<Tox_Group_Number, std::string>> stale;
        for (const auto& [digest, members] : member_digest_index_) {
            for (const auto& m : members) {
                const auto group_it = group_peer_id_cache_.find(m.group_number);
                if (group_it == group_peer_id_cache_.end() || group_it->second.count(m.member_key) == 0) {
                    stale.emplace_back(m.group_number, m.member_key);
                }
            }
        }
        for (const auto& [group_number, key] : stale) EraseIndexedGroupMemberLocked(group_number, key);
        // Peers only ever seen through a message (no join event) are cached
        // without being indexed: pick them up here, hashing each ONCE.
        for (const auto& [group_number, peers] : group_peer_id_cache_) {
            if (IsConferenceMapKey(group_number)) continue;
            for (const auto& peer : peers) {
                if (member_digest_by_slot_.size() + missing.size() >= kMaxIndexedMembers) break;
                if (member_digest_by_slot_.count(IdentitySlotKey(group_number, peer.first)) == 0) {
                    missing.emplace_back(group_number, peer.first);
                }
            }
        }
    }
    if (missing.empty()) return;
    std::unordered_map<Tox_Group_Number, std::string> chat_ids;  // raw bytes; "" = unavailable
    std::vector<std::tuple<Tox_Group_Number, std::string, std::string>> computed;  // group, key, digest
    computed.reserve(missing.size());
    for (const auto& [group_number, key_hex] : missing) {
        auto chat_it = chat_ids.find(group_number);
        if (chat_it == chat_ids.end()) {
            uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
            Tox_Err_Group_State_Query err_chat;
            std::string raw;
            if (tox_group_get_chat_id(tox, group_number, chat_id, &err_chat)) {
                raw.assign(reinterpret_cast<const char*>(chat_id), TOX_GROUP_CHAT_ID_SIZE);
            }
            chat_it = chat_ids.emplace(group_number, std::move(raw)).first;
        }
        if (chat_it->second.empty()) continue;
        uint8_t key[TOX_PUBLIC_KEY_SIZE];
        if (!ToxUtil::tox_hex_to_bytes(key_hex.c_str(), key_hex.size(), key, TOX_PUBLIC_KEY_SIZE)) continue;
        computed.emplace_back(group_number, key_hex,
                              GroupIdentityDigestHex(reinterpret_cast<const uint8_t*>(chat_it->second.data()), key));
    }
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& [group_number, key_hex, digest] : computed) {
        const auto group_it = group_peer_id_cache_.find(group_number);
        if (group_it == group_peer_id_cache_.end() || group_it->second.count(key_hex) == 0) continue;  // left meanwhile
        if (!member_digest_by_slot_.emplace(IdentitySlotKey(group_number, key_hex), digest).second) continue;
        member_digest_index_[digest].push_back(IndexedGroupMember{group_number, key_hex});
    }
}

void V2TIMManagerImpl::IssueIdentityChallenges(Tox* tox, const std::vector<PendingIdentityChallenge>& candidates) {
    if (!tox || candidates.empty()) return;
    // chat_id || our per-group key, per group; "" = unavailable.
    std::unordered_map<Tox_Group_Number, std::string> prefixes;
    std::vector<std::pair<uint32_t, std::string>> sends;
    for (const auto& candidate : candidates) {
        auto prefix_it = prefixes.find(candidate.group_number);
        if (prefix_it == prefixes.end()) {
            uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
            uint8_t self_key[TOX_PUBLIC_KEY_SIZE];
            Tox_Err_Group_State_Query err_chat;
            Tox_Err_Group_Self_Query err_self;
            std::string prefix;
            if (tox_group_get_chat_id(tox, candidate.group_number, chat_id, &err_chat) &&
                tox_group_self_get_public_key(tox, candidate.group_number, self_key, &err_self)) {
                prefix.assign(reinterpret_cast<const char*>(chat_id), TOX_GROUP_CHAT_ID_SIZE);
                prefix.append(reinterpret_cast<const char*>(self_key), TOX_PUBLIC_KEY_SIZE);
            }
            prefix_it = prefixes.emplace(candidate.group_number, std::move(prefix)).first;
        }
        if (prefix_it->second.empty()) continue;
        uint8_t friend_key[TOX_PUBLIC_KEY_SIZE];
        if (!ToxUtil::tox_hex_to_bytes(candidate.friend_hex.c_str(), candidate.friend_hex.size(), friend_key,
                                       TOX_PUBLIC_KEY_SIZE)) {
            continue;
        }
        TOX_ERR_FRIEND_BY_PUBLIC_KEY err_by_key;
        const uint32_t friend_number = tox_friend_by_public_key(tox, friend_key, &err_by_key);
        if (friend_number == UINT32_MAX) continue;
        uint8_t nonce[kIdentityNonceSize];
        // toxcore's CSPRNG, not std::random_device: the latter's quality is
        // implementation-defined (historically deterministic on some builds)
        // and it can throw when /dev/urandom is unavailable.
        const Random* rng = os_random();
        if (rng == nullptr) continue;  // no CSPRNG: do not send a weak nonce
        random_bytes(rng, nonce, sizeof(nonce));
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto now = IdentityClock::now();
            if (member_key_to_friend_.count(candidate.member_key) > 0) continue;  // proven meanwhile
            size_t pending_for_friend = 0;
            bool already_pending = false;
            for (const auto& [n, pending] : pending_identity_challenges_) {
                if (now - pending.sent_at > kIdentityChallengeTtl || pending.friend_hex != candidate.friend_hex) continue;
                ++pending_for_friend;
                if (pending.group_number == candidate.group_number && pending.member_key == candidate.member_key) {
                    already_pending = true;
                    break;
                }
            }
            if (already_pending || pending_for_friend >= kMaxPendingChallengesPerFriend) continue;
            if (pending_identity_challenges_.size() >= kMaxPendingIdentityChallenges) {
                // Evict the oldest, never everything: proofs still on their
                // way for the rest must keep resolving.
                auto oldest = pending_identity_challenges_.begin();
                for (auto it = pending_identity_challenges_.begin(); it != pending_identity_challenges_.end(); ++it) {
                    if (it->second.sent_at < oldest->second.sent_at) oldest = it;
                }
                pending_identity_challenges_.erase(oldest);
            }
            pending_identity_challenges_[ToxUtil::tox_bytes_to_hex(nonce, kIdentityNonceSize)] =
                PendingIdentityChallenge{candidate.friend_hex, candidate.group_number, candidate.member_key, now};
        }
        std::string body(1, static_cast<char>(kIdentityChallenge));
        body.append(prefix_it->second);
        body.append(reinterpret_cast<const char*>(nonce), kIdentityNonceSize);
        sends.emplace_back(friend_number, std::move(body));
    }
    for (const auto& [friend_number, body] : sends) SendFriendIdentityFrame(tox, friend_number, body);
}

void V2TIMManagerImpl::HandleGroupIdentityAnnouncement(uint32_t friend_number, const uint8_t* data, size_t length) {
    if (data == nullptr || length < 1) return;
    Tox* tox = GetToxManager() ? GetToxManager()->getTox() : nullptr;
    if (!tox) return;
    uint8_t friend_key[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (!tox_friend_get_public_key(tox, friend_number, friend_key, &err_key)) return;
    const std::string friend_hex = ToxUtil::tox_bytes_to_hex(friend_key, TOX_PUBLIC_KEY_SIZE);
    const uint8_t subtype = data[0];
    ++data;
    --length;

    if (subtype == kIdentityChallenge) {
        // chat_id || challenger's per-group key || nonce: answer from OUR
        // per-group key in that group, in a box only THIS friend can open.
        if (length != TOX_GROUP_CHAT_ID_SIZE + TOX_PUBLIC_KEY_SIZE + kIdentityNonceSize) return;
        {
            // Answer each (friend, group, nonce) once, and only so many per
            // window: a replayed or flooded challenge must not turn into a
            // stream of NGC proofs. Checked before any peer lookup, which
            // can walk the whole group.
            const auto now = IdentityClock::now();
            const std::string replay_key =
                friend_hex + "|" + ToxUtil::tox_bytes_to_hex(data, TOX_GROUP_CHAT_ID_SIZE) + "|" +
                ToxUtil::tox_bytes_to_hex(data + TOX_GROUP_CHAT_ID_SIZE + TOX_PUBLIC_KEY_SIZE, kIdentityNonceSize);
            std::lock_guard<std::mutex> lock(mutex_);
            PruneIdentityStateLocked(now, false);
            // `challenger_key` below is still whatever the friend put in the
            // packet -- it has to be, because the asker's per-group key is
            // exactly what we do not know yet (see the block comment for why
            // gating on a prior hint breaks the honest flow). So a friend can
            // still make us address one NGC private packet to ANY member it
            // names. What that member gets is a box sealed to THIS friend's
            // long-term key, which it cannot open, so naming someone else
            // buys the friend nothing but our silence towards it. Bounded by
            // the replay key and the budgets right here.
            if (answered_identity_challenges_.count(replay_key) > 0) return;
            if (!TakeIdentityBudgetLocked(identity_rate_by_friend_[friend_hex], now,
                                          &IdentityRateWindow::proofs_sent, kMaxProofsPerFriend) ||
                !TakeIdentityBudgetLocked(identity_rate_global_, now,
                                          &IdentityRateWindow::proofs_sent, kMaxProofsGlobal)) {
                return;
            }
            while (answered_identity_challenges_.size() >= kMaxAnsweredChallenges &&
                   !answered_identity_challenge_order_.empty()) {
                answered_identity_challenges_.erase(answered_identity_challenge_order_.front().second);
                answered_identity_challenge_order_.pop_front();
            }
            answered_identity_challenges_.emplace(replay_key, now);
            answered_identity_challenge_order_.emplace_back(now, replay_key);
        }
        const Tox_Group_Number group_number = GetToxManager()->getGroupByChatId(data);
        if (group_number == UINT32_MAX) return;
        const std::string challenger_key = ToxUtil::tox_bytes_to_hex(
            data + TOX_GROUP_CHAT_ID_SIZE, TOX_PUBLIC_KEY_SIZE);
        const Tox_Group_Peer_Number peer_id = ResolveGroupPeerIdForKey(group_number, challenger_key);
        if (peer_id == UINT32_MAX) return;
        uint8_t self_group_key[TOX_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Self_Query err_self = TOX_ERR_GROUP_SELF_QUERY_OK;
        if (!tox_group_self_get_public_key(tox, group_number, self_group_key, &err_self) ||
            err_self != TOX_ERR_GROUP_SELF_QUERY_OK) {
            return;
        }
        std::vector<uint8_t> packet;
        if (!SealIdentityProof(tox, data, data + TOX_GROUP_CHAT_ID_SIZE, self_group_key,
                               data + TOX_GROUP_CHAT_ID_SIZE + TOX_PUBLIC_KEY_SIZE, friend_key,
                               &packet)) {
            return;
        }
        Tox_Err_Group_Send_Custom_Private_Packet err_send;
        const bool sent = tox_group_send_custom_private_packet(tox, group_number, peer_id, true,
                                                              packet.data(), packet.size(), &err_send);
        if (sent && err_send == TOX_ERR_GROUP_SEND_CUSTOM_PRIVATE_PACKET_OK) {
            std::lock_guard<std::mutex> lock(mutex_);
            ++mm6_diag_.proofs_sent;
        }
        return;
    }
    if (subtype != kIdentityHints || length == 0 || length % CRYPTO_SHA256_SIZE != 0) return;
    const auto now = IdentityClock::now();
    std::vector<std::string> added;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        PruneIdentityStateLocked(now, false);
        if (!TakeIdentityBudgetLocked(identity_rate_by_friend_[friend_hex], now,
                                      &IdentityRateWindow::hint_packets, kMaxHintPacketsPerFriend)) {
            return;
        }
        // A frame never legitimately carries more than one packet's worth;
        // the rest of an oversized frame is ignored, not queued.
        const size_t digest_count = std::min(length / CRYPTO_SHA256_SIZE, kDigestsPerPacket);
        for (size_t n = 0; n < digest_count; ++n) {
            const std::string digest = ToxUtil::tox_bytes_to_hex(data + n * CRYPTO_SHA256_SIZE, CRYPTO_SHA256_SIZE);
            const auto friend_it = friend_group_digests_.find(friend_hex);
            if (friend_it != friend_group_digests_.end()) {
                const auto known = friend_it->second.find(digest);
                if (known != friend_it->second.end()) {
                    known->second = now;  // refresh only: a repeated hint re-challenges nothing
                    continue;
                }
            }
            const auto claim_it = digest_claimants_.find(digest);
            if (claim_it != digest_claimants_.end() && claim_it->second.size() >= kMaxClaimantsPerDigest) continue;
            // Stale hints (groups they left) match nothing and age out; a
            // flood of fresh ones runs out of budget here instead of into
            // work below.
            if (!TakeIdentityBudgetLocked(identity_rate_by_friend_[friend_hex], now,
                                          &IdentityRateWindow::new_digests, kMaxNewDigestsPerFriend) ||
                !TakeIdentityBudgetLocked(identity_rate_global_, now,
                                          &IdentityRateWindow::new_digests, kMaxNewDigestsGlobal)) {
                break;
            }
            auto evict_oldest_of = [&](const std::string& owner) {
                const auto owner_it = friend_group_digests_.find(owner);
                if (owner_it == friend_group_digests_.end() || owner_it->second.empty()) return;
                auto oldest = owner_it->second.begin();
                for (auto it = owner_it->second.begin(); it != owner_it->second.end(); ++it) {
                    if (it->second < oldest->second) oldest = it;
                }
                const std::string victim = oldest->first;
                EraseIdentityClaimLocked(owner, victim);
            };
            if (friend_it != friend_group_digests_.end() && friend_it->second.size() >= kMaxClaimsPerFriend) {
                evict_oldest_of(friend_hex);
            }
            if (identity_claim_count_ >= kMaxIdentityClaims) {
                // Fair share: the heaviest claimant pays, so one noisy friend
                // cannot push everyone else's hints out.
                std::string heaviest;
                size_t heaviest_size = 0;
                for (const auto& [owner, digests] : friend_group_digests_) {
                    if (digests.size() > heaviest_size) {
                        heaviest = owner;
                        heaviest_size = digests.size();
                    }
                }
                if (!heaviest.empty()) evict_oldest_of(heaviest);
            }
            if (friend_group_digests_[friend_hex].emplace(digest, now).second) ++identity_claim_count_;
            digest_claimants_[digest].insert(friend_hex);
            added.push_back(digest);
        }
    }
    if (added.empty()) return;
    // Only what this packet newly taught us is matched, by index lookup.
    SyncMemberDigestIndex(tox);
    std::vector<PendingIdentityChallenge> candidates;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const std::string& digest : added) {
            const auto hit = member_digest_index_.find(digest);
            if (hit == member_digest_index_.end()) continue;
            for (const auto& member : hit->second) {
                if (member_key_to_friend_.count(member.member_key) > 0) continue;
                // A hint is not proof: challenge the friend to answer from the key.
                candidates.push_back(PendingIdentityChallenge{friend_hex, member.group_number, member.member_key, {}});
            }
        }
    }
    IssueIdentityChallenges(tox, candidates);
}

void V2TIMManagerImpl::MatchGroupIdentityDigests(Tox_Group_Number group_number, const std::string& member_key) {
    if (IsConferenceMapKey(group_number) || member_key.size() != static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2)) return;
    Tox* tox = GetToxManager() ? GetToxManager()->getTox() : nullptr;
    if (!tox) return;
    const std::string key_lower = LowerHex(member_key);
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    uint8_t key[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_State_Query err_chat;
    if (!tox_group_get_chat_id(tox, group_number, chat_id, &err_chat) ||
        !ToxUtil::tox_hex_to_bytes(key_lower.c_str(), key_lower.size(), key, TOX_PUBLIC_KEY_SIZE)) {
        return;
    }
    // A peer joined: only its key needs hashing, once.
    const std::string digest = GroupIdentityDigestHex(chat_id, key);
    std::vector<PendingIdentityChallenge> candidates;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto slot_it = member_digest_by_slot_.find(IdentitySlotKey(group_number, key_lower));
        if (slot_it == member_digest_by_slot_.end() || slot_it->second != digest) {
            // A reused group number (another chat id) re-indexes the slot.
            if (slot_it != member_digest_by_slot_.end()) EraseIndexedGroupMemberLocked(group_number, key_lower);
            if (member_digest_by_slot_.size() < kMaxIndexedMembers) {
                member_digest_by_slot_.emplace(IdentitySlotKey(group_number, key_lower), digest);
                member_digest_index_[digest].push_back(IndexedGroupMember{group_number, key_lower});
            }
        }
        if (member_key_to_friend_.count(key_lower) > 0) return;
        const auto claim_it = digest_claimants_.find(digest);
        if (claim_it == digest_claimants_.end()) return;
        // Every claimant (bounded by kMaxClaimantsPerDigest): whoever holds
        // the key's secret proves it; the others' challenges just expire.
        for (const std::string& friend_hex : claim_it->second) {
            candidates.push_back(PendingIdentityChallenge{friend_hex, group_number, key_lower, {}});
        }
    }
    IssueIdentityChallenges(tox, candidates);
}

void V2TIMManagerImpl::HandleGroupIdentityProof(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                                const uint8_t* data, size_t length) {
    // v2 only: the old plaintext proof is neither produced nor accepted.
    if (data == nullptr || length != kIdentityProofPacketSize) return;
    Tox* tox = GetToxManager() ? GetToxManager()->getTox() : nullptr;
    if (!tox) return;
    const Memory* mem = os_memory();
    if (mem == nullptr) return;
    // The toxcore-authenticated NGC envelope sender. Everything below is
    // verified against THIS, not against anything the packet claims.
    uint8_t sender_key[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_peer;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, sender_key, &err_peer) ||
        err_peer != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }
    std::string sender_hex = ToxUtil::tox_bytes_to_hex(sender_key, TOX_PUBLIC_KEY_SIZE);
    std::transform(sender_hex.begin(), sender_hex.end(), sender_hex.begin(), ::tolower);
    // What we put in the challenge for this group, re-derived: the proof must
    // echo both, or it answers some challenge we never sent.
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    uint8_t self_group_key[TOX_PUBLIC_KEY_SIZE];
    uint8_t self_key[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_State_Query err_chat = TOX_ERR_GROUP_STATE_QUERY_OK;
    Tox_Err_Group_Self_Query err_self = TOX_ERR_GROUP_SELF_QUERY_OK;
    if (!tox_group_get_chat_id(tox, group_number, chat_id, &err_chat) ||
        !tox_group_self_get_public_key(tox, group_number, self_group_key, &err_self)) {
        return;
    }
    tox_self_get_public_key(tox, self_key);
    // Pulled before the lock: no tox call happens while mutex_ is held below.
    const SelfSecretKey self_secret(tox);
    const auto now = IdentityClock::now();
    std::lock_guard<std::mutex> lock(mutex_);
    ++mm6_diag_.proofs_in;
    mm6_diag_.last_proof_payload_hex = ToxUtil::tox_bytes_to_hex(data, length);
    PruneIdentityStateLocked(now, false);
    // Candidate askers come from OUR pending challenges for exactly this
    // (group, authenticated sender) -- never from the packet, because the
    // responder's long-term key is the very thing being proven. At most
    // kMaxClaimantsPerDigest of them exist for one member key, so this is a
    // handful of box opens, and only for a member we actually challenged.
    std::vector<std::pair<std::string, std::string>> candidates;  // nonce hex, friend hex
    for (const auto& [nonce_hex, pending] : pending_identity_challenges_) {
        if (pending.group_number != group_number || now - pending.sent_at > kIdentityChallengeTtl ||
            LowerHex(pending.member_key) != sender_hex) {
            continue;
        }
        candidates.emplace_back(nonce_hex, pending.friend_hex);
        if (candidates.size() >= kMaxClaimantsPerDigest) break;
    }
    if (candidates.empty()) {
        ++mm6_diag_.proofs_rejected;
        return;
    }
    if (!TakeIdentityBudgetLocked(identity_rate_global_, now, &IdentityRateWindow::proof_verifies,
                                  kMaxProofVerifiesGlobal)) {
        ++mm6_diag_.proofs_rejected;
        return;
    }
    std::string friend_hex;
    uint8_t plain[kIdentityProofPlainSize];
    for (const auto& [nonce_hex, candidate_friend] : candidates) {
        uint8_t friend_key[TOX_PUBLIC_KEY_SIZE];
        if (!ToxUtil::tox_hex_to_bytes(candidate_friend.c_str(), candidate_friend.size(), friend_key,
                                       TOX_PUBLIC_KEY_SIZE)) {
            continue;
        }
        const int32_t opened = decrypt_data(mem, friend_key, self_secret.get(), data,
                                            data + CRYPTO_NONCE_SIZE,
                                            length - CRYPTO_NONCE_SIZE, plain);
        if (opened != static_cast<int32_t>(kIdentityProofPlainSize)) continue;
        // Authorship is settled (only this friend's long-term key could have
        // sealed it); now every transcript field must be the one we asked
        // about. Any mismatch means a box from some other exchange.
        uint8_t nonce_bytes[kIdentityNonceSize];
        const bool bound =
            memcmp(plain, kIdentityProofDomain, kIdentityProofDomainSize) == 0 &&
            memcmp(plain + kIdentityProofOffChatId, chat_id, TOX_GROUP_CHAT_ID_SIZE) == 0 &&
            memcmp(plain + kIdentityProofOffAskerGroupKey, self_group_key, TOX_PUBLIC_KEY_SIZE) == 0 &&
            memcmp(plain + kIdentityProofOffResponderGroupKey, sender_key, TOX_PUBLIC_KEY_SIZE) == 0 &&
            memcmp(plain + kIdentityProofOffAskerLongTermKey, self_key, TOX_PUBLIC_KEY_SIZE) == 0;
        memcpy(nonce_bytes, plain + kIdentityProofOffNonce, kIdentityNonceSize);
        crypto_memzero(plain, sizeof(plain));
        if (!bound) continue;
        if (LowerHex(ToxUtil::tox_bytes_to_hex(nonce_bytes, kIdentityNonceSize)) != LowerHex(nonce_hex)) {
            continue;
        }
        friend_hex = candidate_friend;
        break;
    }
    if (friend_hex.empty()) {
        ++mm6_diag_.proofs_rejected;
        return;
    }
    ++mm6_diag_.proofs_accepted;
    if (member_key_to_friend_.count(sender_hex) == 0 && member_key_to_friend_.size() >= kMaxProvenMembers) {
        auto oldest = member_key_to_friend_.begin();
        for (auto p = member_key_to_friend_.begin(); p != member_key_to_friend_.end(); ++p) {
            if (p->second.proven_at < oldest->second.proven_at) oldest = p;
        }
        member_key_to_friend_.erase(oldest);
    }
    member_key_to_friend_[sender_hex] = ProvenGroupMember{friend_hex, group_number, now};
    // Every other challenge for this member (other claimants) is moot now.
    for (auto p = pending_identity_challenges_.begin(); p != pending_identity_challenges_.end();) {
        p = p->second.group_number == group_number && LowerHex(p->second.member_key) == sender_hex
                ? pending_identity_challenges_.erase(p)
                : std::next(p);
    }
}

std::string V2TIMManagerImpl::FriendForGroupMemberKey(const std::string& member_key_hex) {
    std::string key = member_key_hex.substr(0, TOX_PUBLIC_KEY_SIZE * 2);
    std::transform(key.begin(), key.end(), key.begin(), ::tolower);
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = member_key_to_friend_.find(key);
    return it == member_key_to_friend_.end() ? std::string() : it->second.friend_hex;
}

std::string V2TIMManagerImpl::Mm6DiagJson() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::ostringstream out;
    out << "{\"proofsSent\":" << mm6_diag_.proofs_sent
        << ",\"proofsIn\":" << mm6_diag_.proofs_in
        << ",\"proofsAccepted\":" << mm6_diag_.proofs_accepted
        << ",\"proofsRejected\":" << mm6_diag_.proofs_rejected
        << ",\"lastProofPayloadHex\":\"" << mm6_diag_.last_proof_payload_hex << "\"}";
    return out.str();
}

int V2TIMManagerImpl::Mm6SendCraftedChallenge(const V2TIMString& groupID, const std::string& friend_key_hex,
                                              const std::string& claimed_member_key_hex) {
    if (groupID.Empty() || friend_key_hex.size() != static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2) ||
        claimed_member_key_hex.size() != static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2)) {
        return 0;
    }
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = group_id_to_group_number_.find(groupID);
        if (it == group_id_to_group_number_.end()) return 0;
        group_number = it->second;
    }
    if (IsConferenceMapKey(group_number)) return 0;
    // FFI (harness) entry point: pinned across chat-id, friend lookup and send.
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox) return 0;
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    Tox_Err_Group_State_Query err_chat = TOX_ERR_GROUP_STATE_QUERY_OK;
    if (!tox_group_get_chat_id(tox, group_number, chat_id, &err_chat)) return 0;
    uint8_t friend_key[TOX_PUBLIC_KEY_SIZE];
    uint8_t claimed_key[TOX_PUBLIC_KEY_SIZE];
    if (!ToxUtil::tox_hex_to_bytes(friend_key_hex.c_str(), friend_key_hex.size(), friend_key,
                                   TOX_PUBLIC_KEY_SIZE) ||
        !ToxUtil::tox_hex_to_bytes(claimed_member_key_hex.c_str(), claimed_member_key_hex.size(),
                                   claimed_key, TOX_PUBLIC_KEY_SIZE)) {
        return 0;
    }
    TOX_ERR_FRIEND_BY_PUBLIC_KEY err_by_key;
    const uint32_t friend_number = tox_friend_by_public_key(tox, friend_key, &err_by_key);
    if (friend_number == UINT32_MAX) return 0;
    const Random* rng = os_random();
    if (rng == nullptr) return 0;
    uint8_t nonce[kIdentityNonceSize];
    random_bytes(rng, nonce, sizeof(nonce));
    // Deliberately NOT registered in pending_identity_challenges_: this is the
    // hostile shape, where the asker never intends to consume an answer.
    std::string body(1, static_cast<char>(kIdentityChallenge));
    body.append(reinterpret_cast<const char*>(chat_id), TOX_GROUP_CHAT_ID_SIZE);
    body.append(reinterpret_cast<const char*>(claimed_key), TOX_PUBLIC_KEY_SIZE);
    body.append(reinterpret_cast<const char*>(nonce), kIdentityNonceSize);
    SendFriendIdentityFrame(tox, friend_number, body);
    return 1;
}

std::string V2TIMManagerImpl::ResolveSharedGroupName(const std::string& group_id) {
    auto* group_manager = static_cast<V2TIMGroupManagerImpl*>(GetGroupManager());
    if (!group_manager) return "";
    const std::string name = group_manager->ResolveGroupName(group_id);
    return name == group_id ? "" : name;
}

bool V2TIMManagerImpl::GetAutoAcceptGroupInvites() {
    std::lock_guard<std::mutex> lock(metadata_mutex_);
    return auto_accept_group_invites_;
}

void V2TIMManagerImpl::SetAutoAcceptGroupInvites(bool enabled) {
    std::lock_guard<std::mutex> lock(metadata_mutex_);
    auto_accept_group_invites_ = enabled;
}

// --- Implementation of Internal Handlers ---

void V2TIMManagerImpl::HandleGroupMessageGroup(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message_data, size_t length, Tox_Group_Message_Id message_id) {
    // Publish the shared pseudo id for the whole synchronous delivery below:
    // BOTH the ACTION branch (NotifyGroupActionMessage) and the normal-text
    // branch notify the FFI simple listener, which stamps it into the polled
    // event line. Scope-bound and thread-local, so nothing leaks to the next
    // message on this thread.
    // Legacy conferences arrive here under a tagged map key and have no
    // message id (the callback passes 0): publishing 0 would give every
    // conference message the same cross-path identity, so publish none.
    const bool is_conference = IsConferenceMapKey(group_number);
    ReceiverGroupMessageIdOverrideGuard group_msg_id_guard(
        is_conference ? -1 : static_cast<int64_t>(message_id));
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] ========== ENTRY ==========");
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] group_number={}, peer_id={}, type={}, length={}, message_id={}", 
             group_number, peer_id, static_cast<int>(type), length, message_id);
    
    Tox* tox = GetToxManager()->getTox();
    V2TIMMessageManagerImpl* msgManager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !running_) {
        V2TIM_LOG(kError, "[V2TIMManagerImpl::HandleGroupMessageGroup] Skipped: Dependencies missing or shutting down. tox={}, msgManager={}, running_={}", 
                 tox ? "non-null" : "null", msgManager ? "non-null" : "null", running_ ? "true" : "false");
        return; // Not initialized or shutting down
    }

    V2TIMString groupID;
    V2TIMString senderUserID;

    // Avoid self-messages by checking if peer_id is ours. The kind is known
    // from the map key: never ask one API about the other kind's number.
    Tox_Err_Group_Peer_Query err_self = TOX_ERR_GROUP_PEER_QUERY_OK;
    bool is_ours = false;
    if (is_conference) {
        TOX_ERR_CONFERENCE_PEER_QUERY err_c_ours;
        is_ours = GetToxManager()->isConferencePeerOurs(group_number, static_cast<uint32_t>(peer_id), &err_c_ours);
    } else {
        is_ours = GetToxManager()->isGroupPeerOurs(group_number, peer_id, &err_self);
    }
    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Self-check: is_ours={}, err_self={}", 
             is_ours, static_cast<int>(err_self));
    static_cast<void>(0);
    static_cast<void>(0);
    
    // Ignore self-messages whenever we determined the sender is us (do not rely on err_self being OK,
    // since isGroupPeerOurs may return true without setting error in some code paths).
    if (is_ours) {
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Ignoring self-message in group.");
        static_cast<void>(0);
        static_cast<void>(0);
        return; // Don't process messages sent by self
    }
    
    // Get sender public key with the API that matches the kind.
    uint8_t sender_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_peer = TOX_ERR_GROUP_PEER_QUERY_OK;
    bool got_key = false;
    if (is_conference) {
        TOX_ERR_CONFERENCE_PEER_QUERY err_c_peer;
        got_key = GetToxManager()->getConferencePeerPublicKey(group_number, static_cast<uint32_t>(peer_id), sender_pubkey, &err_c_peer) &&
                  err_c_peer == TOX_ERR_CONFERENCE_PEER_QUERY_OK;
        // A conference peer we cannot resolve is dropped (not synthesized).
        err_peer = got_key ? TOX_ERR_GROUP_PEER_QUERY_OK : TOX_ERR_GROUP_PEER_QUERY_GROUP_NOT_FOUND;
    } else {
        got_key = GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, sender_pubkey, &err_peer);
    }

    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] getGroupPeerPublicKey: group_number={}, peer_id={}, got_key={}, err_peer={}", 
             group_number, peer_id, got_key ? 1 : 0, static_cast<int>(err_peer));
    static_cast<void>(0);
    static_cast<void>(0);
    
    // Get self public key for comparison
    uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
    tox_self_get_public_key(tox, self_pubkey);
    std::string self_pubkey_hex = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
    static_cast<void>(0);
    static_cast<void>(0);
    
    if (!got_key || err_peer != TOX_ERR_GROUP_PEER_QUERY_OK) {
        if (err_peer == TOX_ERR_GROUP_PEER_QUERY_PEER_NOT_FOUND) {
            // Peer is temporarily not found in Tox state (e.g., just joined, state not yet stable).
            // Use a synthetic sender ID based on peer_id so the message is still delivered instead of dropped.
            V2TIM_LOG(kWarning, "HandleGroupMessage: Peer not found (err_peer=PEER_NOT_FOUND), using synthetic sender for group_number={}, peer_id={}", group_number, peer_id);
            static_cast<void>(0);
            static_cast<void>(0);
            // Fill sender_pubkey with synthetic value: 0xFF + peer_id bytes so it's distinct
            memset(sender_pubkey, 0xFF, TOX_PUBLIC_KEY_SIZE);
            sender_pubkey[0] = static_cast<uint8_t>((peer_id >> 24) & 0xFF);
            sender_pubkey[1] = static_cast<uint8_t>((peer_id >> 16) & 0xFF);
            sender_pubkey[2] = static_cast<uint8_t>((peer_id >> 8) & 0xFF);
            sender_pubkey[3] = static_cast<uint8_t>(peer_id & 0xFF);
        } else {
            V2TIM_LOG(kError, "HandleGroupMessage: Failed to get peer public key: got_key={}, err_peer={}", got_key ? 1 : 0, static_cast<int>(err_peer));
            static_cast<void>(0);
            static_cast<void>(0);
            return;
        }
    }

    // --- Find GroupID --- 
    {
        std::lock_guard<std::mutex> lock(mutex_);
        V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupMessageGroup: Received message - group_number={}, peer_id={}, type={}, length={}, message_id={}", 
                 group_number, peer_id, static_cast<int>(type), length, message_id);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Looking up groupID for group_number={}, map size={}", 
                 group_number, group_number_to_group_id_.size());
        auto it = group_number_to_group_id_.find(group_number);
        if (it != group_number_to_group_id_.end()) {
            groupID = it->second;
            V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Found groupID={} for group_number={}", 
                     groupID.CString(), group_number);
        }
    }
    // If not in map, try to resolve on-the-fly. Two strategies:
    // (1) Get chat_id from Tox for this group_number and match to stored group_id (getGroupChatId can fail for some group states).
    // (2) Iterate known_groups, get stored chat_id, getGroupByChatId(stored_chat_id); if result == group_number, we found group_id.
    if (groupID.Empty() && !is_conference) {
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Unknown group_number {}, attempting on-the-fly resolve", group_number);
        uint8_t chat_id_bin[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat;
        if (GetToxManager()->getGroupChatId(group_number, chat_id_bin, &err_chat) && err_chat == TOX_ERR_GROUP_STATE_QUERY_OK) {
            std::string chat_id_hex;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                char buf[4];
                snprintf(buf, sizeof(buf), "%02x", chat_id_bin[i]);
                chat_id_hex += buf;
            }
            std::vector<std::string> known = GetKnownGroupIDs();
            if (!known.empty()) {
                for (const auto& line : known) {
                    if (line.empty()) continue;
                    char stored_chat_id[65];
                    if (!GetGroupChatIdFromStorage(line, stored_chat_id, sizeof(stored_chat_id))) continue;
                    #if defined(_WIN32) || defined(_WIN64)
                    if (strlen(stored_chat_id) == chat_id_hex.size() && _strnicmp(stored_chat_id, chat_id_hex.c_str(), chat_id_hex.size()) == 0) {
                    #else
                    if (strlen(stored_chat_id) == chat_id_hex.size() && strncasecmp(stored_chat_id, chat_id_hex.c_str(), chat_id_hex.size()) == 0) {
                    #endif
                        V2TIMString resolvedID(line.c_str());
                        {
                            std::lock_guard<std::mutex> lock(mutex_);
                            group_number_to_group_id_[group_number] = resolvedID;
                            group_id_to_group_number_[resolvedID] = group_number;
                        }
                        groupID = resolvedID;
                        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Resolved unknown group_number {} -> groupID={} (via getGroupChatId)", group_number, groupID.CString());
                        static_cast<void>(0);
                        static_cast<void>(0);
                        break;
                    }
                }
            }
        }
        // Strategy 2: iterate known_groups, getGroupByChatId(stored_chat_id) and match to group_number (works when getGroupChatId(group_number) fails)
        if (groupID.Empty() && tox_manager_) {
            std::vector<std::string> known2 = GetKnownGroupIDs();
            if (!known2.empty()) {
                for (const auto& line2 : known2) {
                    if (line2.empty()) continue;
                    char stored_chat_id[65];
                    if (!GetGroupChatIdFromStorage(line2, stored_chat_id, sizeof(stored_chat_id))) continue;
                    size_t len = strlen(stored_chat_id);
                    if (len != static_cast<size_t>(TOX_GROUP_CHAT_ID_SIZE * 2)) continue;
                    uint8_t cid_bin[TOX_GROUP_CHAT_ID_SIZE];
                    bool ok = true;
                    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                        char byte_str[3] = { stored_chat_id[i*2], stored_chat_id[i*2+1], '\0' };
                        char* end = nullptr;
                        unsigned long v = strtoul(byte_str, &end, 16);
                        if (!end || *end || v > 255) { ok = false; break; }
                        cid_bin[i] = static_cast<uint8_t>(v);
                    }
                    if (!ok) continue;
                    Tox_Group_Number actual = tox_manager_->getGroupByChatId(cid_bin);
                    if (actual != group_number) continue;
                    V2TIMString resolvedID(line2.c_str());
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        group_number_to_group_id_[group_number] = resolvedID;
                        group_id_to_group_number_[resolvedID] = group_number;
                    }
                    groupID = resolvedID;
                    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Resolved unknown group_number {} -> groupID={} (via getGroupByChatId)", group_number, groupID.CString());
                    static_cast<void>(0);
                    static_cast<void>(0);
                    break;
                }
            }
        }
        // Fallback: use synthetic groupID so the message is still delivered (e.g. group has no stored chat_id or Tox returns error for getGroupChatId)
        if (groupID.Empty()) {
            char synthetic_buf[32];
            snprintf(synthetic_buf, sizeof(synthetic_buf), "tox_group_%u", (unsigned)group_number);
            V2TIMString syntheticID(synthetic_buf);
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_number_to_group_id_[group_number] = syntheticID;
                group_id_to_group_number_[syntheticID] = group_number;
            }
            groupID = syntheticID;
            V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Using synthetic groupID {} for unknown group_number {}", groupID.CString(), group_number);
            static_cast<void>(0);
            static_cast<void>(0);
        }
    }

    // An unmapped conference is resolved exactly like a peer-list change
    // (stored conference id, then legacy tox_conf_N candidates, then a new
    // tox_conf_N) instead of the NGC chat-id strategies above.
    if (groupID.Empty() && is_conference) {
        HandleGroupPeerListChanged(group_number);
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it != group_number_to_group_id_.end()) groupID = it->second;
    }
    if (groupID.Empty()) {
        V2TIM_LOG(kWarning, "[V2TIMManagerImpl::HandleGroupMessageGroup] Dropping message for unresolvable conference key {}", group_number);
        return;
    }

    // --- Find Sender UserID (Public Key Hex) --- 
    char sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
    std::string hex_id = ToxUtil::tox_bytes_to_hex(sender_pubkey, TOX_PUBLIC_KEY_SIZE);
    strcpy(sender_hex_id, hex_id.c_str());
    sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0'; 
    senderUserID = sender_hex_id;

    V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Received group msg type {} group_number={} peer_id={} length={}",
             type, group_number, peer_id, length);
    static_cast<void>(0);
    static_cast<void>(0);

    // Populate the peer_id cache so GetGroupMemberList can list this peer even if
    // HandleGroupPeerJoin never fired (e.g. because the group join never fully completed).
    // NGC only: conference peer numbers are dense indices that shift on every
    // peer-list change, and the member list enumerates conferences directly.
    if (!is_conference && got_key && err_peer == TOX_ERR_GROUP_PEER_QUERY_OK) {
        std::string key_lower = std::string(senderUserID.CString());
        std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(), ::tolower);
        std::lock_guard<std::mutex> lock(mutex_);
        group_peer_id_cache_[group_number][key_lower] = peer_id;
        static_cast<void>(0);
        static_cast<void>(0);
    }

    if (type == TOX_MESSAGE_TYPE_ACTION) {
        NotifyGroupActionMessage(
            groupID, senderUserID, message_data, length);
        return;
    }
    if (!msgManager) return;

    // --- Create V2TIMMessage Object --- 
    V2TIMMessage v2_message; // Will be populated based on type
    bool message_created = false;

    if (type == TOX_MESSAGE_TYPE_NORMAL) {
        // 解析消息，检查是否包含引用回复或合并消息
        std::string messageStr(reinterpret_cast<const char*>(message_data), length);
        std::string replyJson;
        std::string mergerJson;
        std::string actualText;
        std::string compatibleText;
        
        // 先检查合并消息
        bool hasMerger = MergerMessageUtil::ParseMessageWithMerger(messageStr, mergerJson, compatibleText);
        
        if (hasMerger && !mergerJson.empty()) {
            // 有合并消息，创建合并消息对象
            // 使用CreateTextMessage创建基础消息，然后替换元素
            V2TIMMessage mergerMsg = msgManager->CreateTextMessage("");
            // 清空文本元素，添加合并元素
            mergerMsg.elemList.Clear();
            V2TIMMergerElem* mergerElem = new V2TIMMergerElem();
            mergerElem->elemType = V2TIM_ELEM_TYPE_MERGER;
            
            // 从JSON中提取title
            std::string title = MessageReplyUtil::ExtractJsonValue(mergerJson, "title");
            mergerElem->title = title.c_str();
            
            // 提取abstractList
            std::vector<std::string> abstractVec = MergerMessageUtil::ExtractAbstractList(mergerJson);
            for (const auto& abstract : abstractVec) {
                mergerElem->abstractList.PushBack(abstract.c_str());
            }
            
            // 如果没有abstractList，使用兼容文本
            if (mergerElem->abstractList.Empty() && !compatibleText.empty()) {
                mergerElem->abstractList.PushBack(compatibleText.c_str());
            }
            
            mergerElem->layersOverLimit = false;
            
            mergerMsg.elemList.PushBack(mergerElem);
            v2_message = mergerMsg;
            message_created = true;
        } else {
            // 检查引用回复
            bool hasReply = MessageReplyUtil::ParseMessageWithReply(messageStr, replyJson, actualText);
            
            if (hasReply && !replyJson.empty()) {
                // 有引用回复，使用实际文本创建消息
                V2TIMString messageText(actualText.c_str());
                v2_message = msgManager->CreateTextMessage(messageText);
                // 设置cloudCustomData
                v2_message.cloudCustomData = MessageReplyUtil::BuildCloudCustomDataFromReplyJson(replyJson);
            } else {
                // 没有特殊标记，正常处理
                V2TIMString messageText(reinterpret_cast<const char*>(message_data), length);
                v2_message = msgManager->CreateTextMessage(messageText);
            }
            message_created = true;
        }
    } else {
        V2TIM_LOG(kWarning, "Received unhandled group message type {}", type);
        return; // Don't notify for unsupported types
    }

    if (message_created) {
        // --- Populate received message fields --- 
        v2_message.sender = senderUserID;
        v2_message.userID = senderUserID; // So Dart/listeners can match sender (e.g. message.userID == alicePublicKey)
        v2_message.groupID = groupID;
        v2_message.isSelf = false; // Message received from others
        v2_message.status = V2TIM_MSG_STATUS_SEND_SUCC; // Mark as received successfully
        // Use current time as Tox doesn't provide a timestamp for received messages
        v2_message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                                    std::chrono::system_clock::now().time_since_epoch()).count();
        // Sender display name from the peer's group name. Group members are
        // identified by per-group keys that never resolve to a friend, so
        // without this the app had nothing but a hex prefix to show — in
        // notifications the title read "3FA91C02B7D4…: see you at 8". Same
        // lock as the key lookup above (safe from this callback). A conference
        // peer's name comes from the conference API with the untagged number:
        // the NGC query on a tagged key only fails, leaving the name empty.
        if (is_conference) {
            const uint32_t conference_number = ConferenceNumberFromKey(group_number);
            Tox_Err_Conference_Peer_Query err_name_size = TOX_ERR_CONFERENCE_PEER_QUERY_OK;
            const size_t name_size = tox_conference_peer_get_name_size(
                tox, conference_number, static_cast<uint32_t>(peer_id), &err_name_size);
            if (err_name_size == TOX_ERR_CONFERENCE_PEER_QUERY_OK &&
                name_size > 0 && name_size <= TOX_MAX_NAME_LENGTH) {
                uint8_t peer_name[TOX_MAX_NAME_LENGTH + 1] = {0};
                Tox_Err_Conference_Peer_Query err_name = TOX_ERR_CONFERENCE_PEER_QUERY_OK;
                if (tox_conference_peer_get_name(tox, conference_number,
                                                 static_cast<uint32_t>(peer_id),
                                                 peer_name, &err_name) &&
                    err_name == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
                    v2_message.nickName = V2TIMString(
                        std::string(reinterpret_cast<const char*>(peer_name), name_size).c_str());
                }
            }
        } else {
            uint8_t peer_name[TOX_MAX_NAME_LENGTH + 1] = {0};
            Tox_Err_Group_Peer_Query err_name;
            if (GetToxManager()->getGroupPeerName(group_number, peer_id, peer_name, TOX_MAX_NAME_LENGTH, &err_name) &&
                err_name == TOX_ERR_GROUP_PEER_QUERY_OK) {
                const size_t name_len = strnlen(reinterpret_cast<const char*>(peer_name), TOX_MAX_NAME_LENGTH);
                if (name_len > 0) {
                    v2_message.nickName = V2TIMString(std::string(reinterpret_cast<const char*>(peer_name), name_len).c_str());
                }
            }
        }
        
        // [tim2tox-debug] Record message creation completion
        V2TIM_LOG(kInfo, "[tim2tox-debug] HandleGroupMessageGroup: Message creation completed elemCount={}",
                 v2_message.elemList.Size());
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Message created: timestamp={}",
                 v2_message.timestamp);
        static_cast<void>(0);
        static_cast<void>(0);
        
        // --- Notify Advanced Listeners --- 
        // Set receiver instance override so OnRecvNewMessage (in dart_compat_listeners) routes to this instance.
        int64_t receiver_instance_id = GetInstanceIdFromManager(this);
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] About to notify advanced listeners, msgManager={}, receiver_instance_id={}", 
                 (void*)msgManager, (long long)receiver_instance_id);
        {
            ReceiverInstanceOverrideGuard receiver_instance_guard(
                receiver_instance_id);
            msgManager->NotifyAdvancedListenersReceivedMessage(v2_message);
        }
        V2TIM_LOG(kInfo, "[V2TIMManagerImpl::HandleGroupMessageGroup] Advanced listeners notified");
        static_cast<void>(0);
        static_cast<void>(0);

        // --- Notify Simple Listeners (Optional - Keep for now) --- 
        std::vector<V2TIMSimpleMsgListener*> listeners_to_notify;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            listeners_to_notify.assign(simple_msg_listeners_.begin(), simple_msg_listeners_.end());
        }
        
        // Check message type from the message's elemList first element
        if (!v2_message.elemList.Empty()) {
            V2TIMElem* elem = v2_message.elemList[0];
            if (elem->elemType == V2TIM_ELEM_TYPE_TEXT) {
                V2TIMTextElem* textElem = static_cast<V2TIMTextElem*>(elem);
                
                // Create simplified member info for the notification
                V2TIMGroupMemberFullInfo senderInfo;
                senderInfo.userID = senderUserID;
                // TODO: Add more sender info if available
                
                for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
                    if (listener) {
                        try {
                            listener->OnRecvGroupTextMessage(
                                v2_message.msgID,
                                groupID,
                                senderInfo,
                                textElem->text);
                        } catch (...) {
                            V2TIM_LOG(
                                kWarning,
                                "[Callback] category=group-text status=threw");
                        }
                    }
                }
            } else if (elem->elemType == V2TIM_ELEM_TYPE_CUSTOM) {
                V2TIMCustomElem* customElem = static_cast<V2TIMCustomElem*>(elem);
                
                // Create simplified member info for the notification
                V2TIMGroupMemberFullInfo senderInfo;
                senderInfo.userID = senderUserID;
                // TODO: Add more sender info if available
                
                for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
                    if (listener) {
                        try {
                            listener->OnRecvGroupCustomMessage(
                                v2_message.msgID,
                                groupID,
                                senderInfo,
                                customElem->data);
                        } catch (...) {
                            V2TIM_LOG(
                                kWarning,
                                "[Callback] category=group-custom status=threw");
                        }
                    }
                }
            }
        }
    }
}

void V2TIMManagerImpl::HandleGroupCustomPacket(
    Tox_Group_Number group_number,
    Tox_Group_Peer_Number peer_id,
    const uint8_t* data,
    size_t length) {
    if (data == nullptr || length == 0 || !running_) return;
    // Only tim2tox's own custom messages are chat content; other clients'
    // packets on this shared channel are their protocols, not messages.
    const uint8_t* payload = nullptr;
    size_t payload_length = 0;
    if (!UnwrapTim2ToxGroupPacket(kTim2ToxGroupPacketCustomMessage, data, length,
                                  &payload, &payload_length) ||
        payload_length == 0) {
        return;
    }
    data = payload;
    length = payload_length;

    ToxManager* tox_manager = GetToxManager();
    Tox* tox = tox_manager ? tox_manager->getTox() : nullptr;
    auto* msg_manager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !msg_manager) return;

    Tox_Err_Group_Peer_Query peer_error;
    if (tox_manager->isGroupPeerOurs(group_number, peer_id, &peer_error) &&
        peer_error == TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }

    uint8_t sender_public_key[TOX_PUBLIC_KEY_SIZE];
    if (!tox_manager->getGroupPeerPublicKey(
            group_number, peer_id, sender_public_key, &peer_error) ||
        peer_error != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }

    V2TIMString group_id;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto group_it = group_number_to_group_id_.find(group_number);
        if (group_it == group_number_to_group_id_.end()) return;
        group_id = group_it->second;
    }

    const V2TIMString sender_id =
        ToxUtil::tox_bytes_to_hex(sender_public_key, TOX_PUBLIC_KEY_SIZE).c_str();
    V2TIMMessage message = msg_manager->CreateCustomMessage(V2TIMBuffer(data, length));
    message.sender = sender_id;
    message.userID = sender_id;
    message.groupID = group_id;
    message.isSelf = false;
    message.status = V2TIM_MSG_STATUS_SEND_SUCC;
    message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();

    const int64_t receiver_instance_id = GetInstanceIdFromManager(this);
    {
        ReceiverInstanceOverrideGuard receiver_instance_guard(receiver_instance_id);
        msg_manager->NotifyAdvancedListenersReceivedMessage(message);

        std::vector<V2TIMSimpleMsgListener*> listeners;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            listeners.assign(simple_msg_listeners_.begin(), simple_msg_listeners_.end());
        }
        V2TIMGroupMemberFullInfo sender_info;
        sender_info.userID = sender_id;
        V2TIMCustomElem* custom_elem = nullptr;
        if (!message.elemList.Empty() &&
            message.elemList[0]->elemType == V2TIM_ELEM_TYPE_CUSTOM) {
            custom_elem = static_cast<V2TIMCustomElem*>(message.elemList[0]);
        }
        if (custom_elem != nullptr) {
            for (V2TIMSimpleMsgListener* listener : listeners) {
                if (!listener) continue;
                try {
                    listener->OnRecvGroupCustomMessage(
                        message.msgID, group_id, sender_info, custom_elem->data);
                } catch (...) {
                    V2TIM_LOG(kWarning, "[Callback] category=group-custom status=threw");
                }
            }
        }
    }
}

void V2TIMManagerImpl::HandleGroupCustomPrivatePacket(
    Tox_Group_Number group_number,
    Tox_Group_Peer_Number peer_id,
    const uint8_t* data,
    size_t length) {
    if (!running_) return;
    const uint8_t* payload = nullptr;
    size_t payload_length = 0;
    if (UnwrapTim2ToxGroupPacket(kTim2ToxGroupPacketIdentityProof, data, length,
                                 &payload, &payload_length)) {
        HandleGroupIdentityProof(group_number, peer_id, payload, payload_length);
        return;
    }
    if (!UnwrapTim2ToxGroupPacket(kTim2ToxGroupPacketReceipt, data, length,
                                  &payload, &payload_length) ||
        payload_length == 0 || payload_length > 1024) {
        return;
    }
    // Only a receipt may ride this channel: it is forwarded on the ACTION
    // control line, where anything that is not a recognised control would
    // render as a public-looking "/me" line from the sender.
    StrictGroupReceipt receipt;
    if (!ParseStrictReceiptJson(payload, payload_length, &receipt)) return;
    ToxManager* tox_manager = GetToxManager();
    if (!tox_manager) return;
    uint8_t sender_public_key[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query peer_error;
    if (!tox_manager->getGroupPeerPublicKey(group_number, peer_id, sender_public_key, &peer_error) ||
        peer_error != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }
    const std::string sender_hex = ToxUtil::tox_bytes_to_hex(sender_public_key, TOX_PUBLIC_KEY_SIZE);
    const std::string sender_lower = LowerHex(sender_hex);
    // The payload "sender" must BE the authenticated envelope key (the
    // per-group key SendGroupReceipt writes, compared case-insensitively):
    // this schema is new with the private channel, so nothing legitimate
    // sends anything else, and a receipt naming another member must not reach
    // a consumer that reads the payload field instead of the envelope.
    if (LowerHex(receipt.sender) != sender_lower) {
        V2TIM_LOG(kWarning, "[HandleGroupCustomPrivatePacket] dropped receipt whose sender does not match its envelope key");
        return;
    }
    V2TIMString group_id;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto group_it = group_number_to_group_id_.find(group_number);
        if (group_it == group_number_to_group_id_.end()) return;
        group_id = group_it->second;
        // Replay filter: the same member's same receipt for the same message
        // is forwarded once per kSeenGroupReceiptTtl. Every copy used to cost
        // Dart an event, a history rewrite and a UI refresh. (Dart's handler
        // is idempotent too, for anything that slips past a bounded cache.)
        const auto now = IdentityClock::now();
        PruneIdentityStateLocked(now, false);
        std::string replay_key = std::string(group_id.CString()) + "|" + sender_lower + "|" +
                                 receipt.receipt_type + "|" + receipt.msg_id;
        if (seen_group_receipts_.count(replay_key) > 0) return;
        while (seen_group_receipts_.size() >= kMaxSeenGroupReceipts && !seen_group_receipt_order_.empty()) {
            seen_group_receipts_.erase(seen_group_receipt_order_.front().second);
            seen_group_receipt_order_.pop_front();
        }
        seen_group_receipts_.emplace(replay_key, now);
        seen_group_receipt_order_.emplace_back(now, std::move(replay_key));
    }
    // Hand it to Dart on the group ACTION control line, where receipts have
    // always been consumed (and never rendered); the envelope sender is the
    // toxcore-authenticated per-group key, which is what the tally counts.
    const V2TIMString sender_id = sender_hex.c_str();
    NotifyGroupActionMessage(group_id, sender_id, payload, payload_length);
}

int V2TIMManagerImpl::SendGroupReceipt(const V2TIMString& groupID, const std::string& author_key_hex,
                                       const std::string& msg_id, const std::string& receipt_type) {
    if (groupID.Empty() || msg_id.empty() ||
        author_key_hex.size() != static_cast<size_t>(TOX_PUBLIC_KEY_SIZE * 2) ||
        (receipt_type != "received" && receipt_type != "read")) {
        return 0;
    }
    Tox_Group_Number group_number = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = group_id_to_group_number_.find(groupID);
        if (it == group_id_to_group_number_.end()) return 0;
        group_number = it->second;
    }
    if (IsConferenceMapKey(group_number)) return -2;
    // Pinned for the WHOLE sequence below (peer lookup, self-key query, send):
    // this runs on the FFI caller's thread, where a concurrent UnInitSDK used
    // to be able to tox_kill() the instance between two of these calls.
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox) return 0;
    const Tox_Group_Peer_Number peer_id = ResolveGroupPeerIdForKey(group_number, author_key_hex);
    if (peer_id == UINT32_MAX) return 0;
    // The payload keeps the legacy receipt schema (type/msgID/receiptType/
    // sender) so every toxee version consumes it, but "sender" is our
    // PER-GROUP key: the long-term key it used to carry deanonymized every
    // reader to the whole group (NGC identifies members per group on purpose).
    uint8_t self_group_key[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Self_Query err_self = TOX_ERR_GROUP_SELF_QUERY_OK;
    if (!tox_group_self_get_public_key(tox, group_number, self_group_key, &err_self) ||
        err_self != TOX_ERR_GROUP_SELF_QUERY_OK) {
        return 0;
    }
    const std::string body =
        std::string("{\"type\":\"receipt\",\"msgID\":\"") + EscapeJsonForReceipt(msg_id) +
        "\",\"receiptType\":\"" + receipt_type + "\",\"sender\":\"" +
        ToxUtil::tox_bytes_to_hex(self_group_key, TOX_PUBLIC_KEY_SIZE) + "\"}";
    const std::vector<uint8_t> packet = WrapTim2ToxGroupPacket(
        kTim2ToxGroupPacketReceipt, reinterpret_cast<const uint8_t*>(body.data()), body.size());
    Tox_Err_Group_Send_Custom_Private_Packet err_send;
    const bool sent = tox_group_send_custom_private_packet(
        tox, group_number, peer_id, true, packet.data(), packet.size(), &err_send);
    return sent && err_send == TOX_ERR_GROUP_SEND_CUSTOM_PRIVATE_PACKET_OK ? 1 : 0;
}

void V2TIMManagerImpl::HandleGroupPrivateMessage(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message_data, size_t length, Tox_Group_Message_Id message_id) {
    static_cast<void>(0);
    static_cast<void>(0);
    Tox* tox = GetToxManager()->getTox();
    V2TIMMessageManagerImpl* msgManager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !running_) return;
    Tox_Err_Group_Peer_Query err_self;
    if (GetToxManager()->isGroupPeerOurs(group_number, peer_id, &err_self) && err_self == TOX_ERR_GROUP_PEER_QUERY_OK) return;
    uint8_t sender_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_peer;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, sender_pubkey, &err_peer) || err_peer != TOX_ERR_GROUP_PEER_QUERY_OK) return;
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) return;
        groupID = it->second;
    }
    V2TIMString senderUserID(ToxUtil::tox_bytes_to_hex(sender_pubkey, TOX_PUBLIC_KEY_SIZE).c_str());
    // A private ("whisper") message from another client — qTox, Toxic, ... —
    // addressed to us alone. It used to land in the group timeline as an
    // ordinary public line (inviting a public reply to a private remark) and
    // never counted as unread. It keeps its place in the group conversation,
    // but carries a lock marker IN its text, so the marking survives history
    // reloads, search, previews and notifications on every platform, and it
    // takes the same path as a public line (unread, dedupe by message id).
    static const std::string kPrivateMarker = "\xF0\x9F\x94\x92 ";  // "🔒 "
    std::string text_str = kPrivateMarker +
        std::string(reinterpret_cast<const char*>(message_data), length);
    ReceiverGroupMessageIdOverrideGuard group_msg_id_guard(static_cast<int64_t>(message_id));
    if (type == TOX_MESSAGE_TYPE_ACTION) {
        NotifyGroupActionMessage(
            groupID, senderUserID,
            reinterpret_cast<const uint8_t*>(text_str.data()), text_str.size());
        return;
    }
    if (type != TOX_MESSAGE_TYPE_NORMAL || !msgManager) return;
    V2TIMMessage v2_message = msgManager->CreateTextMessage(V2TIMString(text_str.c_str()));
    v2_message.sender = senderUserID;
    v2_message.userID = senderUserID; // So Dart/listeners can match sender
    v2_message.groupID = groupID;
    v2_message.isSelf = false;
    v2_message.status = V2TIM_MSG_STATUS_SEND_SUCC;
    v2_message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    // Set receiver instance override so OnRecvNewMessage routes to this instance (group private message).
    int64_t receiver_instance_id = GetInstanceIdFromManager(this);
    ReceiverInstanceOverrideGuard receiver_instance_guard(receiver_instance_id);
    msgManager->NotifyAdvancedListenersReceivedMessage(v2_message);

    // The polled group-text line owns unread counting and notifications.
    std::vector<V2TIMSimpleMsgListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(simple_msg_listeners_.begin(), simple_msg_listeners_.end());
    }
    V2TIMGroupMemberFullInfo senderInfo;
    senderInfo.userID = senderUserID;
    const V2TIMString text(text_str.c_str());
    for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
        if (!listener) continue;
        try {
            listener->OnRecvGroupTextMessage(v2_message.msgID, groupID, senderInfo, text);
        } catch (...) {
            V2TIM_LOG(kWarning, "[Callback] category=group-private-text status=threw");
        }
    }
}

void V2TIMManagerImpl::NotifyFriendActionMessage(
    const V2TIMString& sender_user_id,
    const uint8_t* text,
    size_t length) {
    if (text == nullptr || length == 0) return;

    V2TIMUserFullInfo sender_info;
    sender_info.userID = sender_user_id;
    V2TIMString action_text(reinterpret_cast<const char*>(text), length);
    std::vector<V2TIMSimpleMsgListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(
            simple_msg_listeners_.begin(), simple_msg_listeners_.end());
    }

    ReceiverInstanceOverrideGuard receiver_instance_guard(
        GetInstanceIdFromManager(this));
    ReceiverTextKindOverrideGuard text_kind_guard(1);
    for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
        if (!listener) continue;
        try {
            listener->OnRecvC2CTextMessage(
                "", sender_info, action_text);
        } catch (...) {
            V2TIM_LOG(
                kWarning,
                "[Callback] category=c2c-action status=threw");
        }
    }
}

void V2TIMManagerImpl::NotifyGroupActionMessage(
    const V2TIMString& group_id,
    const V2TIMString& sender_user_id,
    const uint8_t* text,
    size_t length) {
    if (text == nullptr || length == 0) return;

    V2TIMGroupMemberFullInfo sender_info;
    sender_info.userID = sender_user_id;
    V2TIMString action_text(reinterpret_cast<const char*>(text), length);
    std::vector<V2TIMSimpleMsgListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(
            simple_msg_listeners_.begin(), simple_msg_listeners_.end());
    }

    ReceiverInstanceOverrideGuard receiver_instance_guard(
        GetInstanceIdFromManager(this));
    ReceiverTextKindOverrideGuard text_kind_guard(1);
    for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
        if (!listener) continue;
        try {
            listener->OnRecvGroupTextMessage(
                "", group_id, sender_info, action_text);
        } catch (...) {
            V2TIM_LOG(
                kWarning,
                "[Callback] category=group-action status=threw");
        }
    }
}

void V2TIMManagerImpl::HandleFriendCustomMessage(uint32_t friend_number, const uint8_t* data, size_t length) {
    Tox* tox = GetToxManager()->getTox();
    auto* msg_manager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !msg_manager || !running_ || data == nullptr) {
        V2TIM_LOG(kWarning, "Dropped custom message because dependencies were unavailable");
        return;
    }

    uint8_t sender_public_key[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY key_error;
    if (!tox_friend_get_public_key(tox, friend_number, sender_public_key, &key_error) ||
        key_error != TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        V2TIM_LOG(kWarning, "Dropped custom message because sender lookup failed with status {}", key_error);
        return;
    }

    const std::string sender_hex =
        ToxUtil::tox_bytes_to_hex(sender_public_key, TOX_PUBLIC_KEY_SIZE);
    V2TIMString sender_user_id(sender_hex.c_str());
    V2TIMBuffer custom_data(data, length);
    V2TIMMessage message = msg_manager->CreateCustomMessage(custom_data);
    DeliverFriendMessage(
        message,
        sender_user_id,
        sender_public_key,
        static_cast<uint8_t>(Type::kGenericCustom));
}

void V2TIMManagerImpl::HandleFriendControlMessage(
    uint32_t friend_number,
    tim2tox::control::Type packet_type,
    const uint8_t* data,
    size_t length) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_ || data == nullptr) {
        V2TIM_LOG(kWarning, "Dropped control message because dependencies were unavailable");
        return;
    }

    uint8_t sender_public_key[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY key_error;
    if (!tox_friend_get_public_key(
            tox, friend_number, sender_public_key, &key_error) ||
        key_error != TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        V2TIM_LOG(
            kWarning,
            "Dropped control message because sender lookup failed with status {}",
            key_error);
        return;
    }

    const std::string sender_hex =
        ToxUtil::tox_bytes_to_hex(sender_public_key, TOX_PUBLIC_KEY_SIZE);
    V2TIMUserFullInfo sender_info;
    sender_info.userID = sender_hex.c_str();
    V2TIMBuffer custom_data(data, length);

    std::vector<V2TIMSimpleMsgListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(
            simple_msg_listeners_.begin(), simple_msg_listeners_.end());
    }

    const int64_t receiver_instance_id = GetInstanceIdFromManager(this);
    ReceiverInstanceOverrideGuard receiver_instance_guard(receiver_instance_id);
    ReceiverCustomRouteOverrideGuard receiver_custom_route_guard(
        static_cast<uint8_t>(packet_type));
    for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
        if (listener) {
            try {
                listener->OnRecvC2CCustomMessage("", sender_info, custom_data);
            } catch (...) {
                V2TIM_LOG(
                    kWarning,
                    "[Callback] category=simple-custom status=threw");
            }
        }
    }
}

void V2TIMManagerImpl::DeliverFriendMessage(
    V2TIMMessage& message,
    const V2TIMString& sender_user_id,
    const uint8_t* sender_public_key,
    uint8_t custom_route) {
    Tox* tox = GetToxManager()->getTox();
    auto* msg_manager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !msg_manager || sender_public_key == nullptr) {
        return;
    }

    message.sender = sender_user_id;
    message.userID = sender_user_id;
    message.groupID = "";

    uint8_t self_public_key[TOX_PUBLIC_KEY_SIZE];
    tox_self_get_public_key(tox, self_public_key);
    message.isSelf =
        memcmp(sender_public_key, self_public_key, TOX_PUBLIC_KEY_SIZE) == 0;
    message.status = V2TIM_MSG_STATUS_SEND_SUCC;
    message.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();

    const int64_t receiver_instance_id = GetInstanceIdFromManager(this);
    {
        ReceiverInstanceOverrideGuard advanced_receiver_guard(receiver_instance_id);
        msg_manager->NotifyAdvancedListenersReceivedMessage(message);
    }

    std::vector<V2TIMSimpleMsgListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(
            simple_msg_listeners_.begin(), simple_msg_listeners_.end());
    }

    ReceiverInstanceOverrideGuard simple_receiver_guard(receiver_instance_id);
    if (!message.elemList.Empty()) {
        V2TIMElem* elem = message.elemList[0];
        V2TIMUserFullInfo sender_info;
        sender_info.userID = sender_user_id;
        if (elem->elemType == V2TIM_ELEM_TYPE_TEXT) {
            auto* text_elem = static_cast<V2TIMTextElem*>(elem);
            for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
                if (listener) {
                    try {
                        listener->OnRecvC2CTextMessage(
                            message.msgID, sender_info, text_elem->text);
                    } catch (...) {
                        V2TIM_LOG(
                            kWarning,
                            "[Callback] category=simple-text status=threw");
                    }
                }
            }
        } else if (elem->elemType == V2TIM_ELEM_TYPE_CUSTOM) {
            auto* custom_elem = static_cast<V2TIMCustomElem*>(elem);
            ReceiverCustomRouteOverrideGuard receiver_custom_route_guard(custom_route);
            for (V2TIMSimpleMsgListener* listener : listeners_to_notify) {
                if (listener) {
                    try {
                        listener->OnRecvC2CCustomMessage(
                            message.msgID, sender_info, custom_elem->data);
                    } catch (...) {
                        V2TIM_LOG(
                            kWarning,
                            "[Callback] category=simple-custom status=threw");
                    }
                }
            }
        }
    }
}

void V2TIMManagerImpl::HandleFriendMessage(uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message_data, size_t length) {
    V2TIM_LOG(kInfo, "HandleFriendMessage received type {} with length {}", type, length);
    
    Tox* tox = GetToxManager()->getTox();
    V2TIMMessageManagerImpl* msgManager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!tox || !running_) {
        V2TIM_LOG(kWarning, "HandleFriendMessage dropped because dependencies were unavailable");
        return; // Not initialized or shutting down
    }

    V2TIMString senderUserID;

    // --- Find Sender UserID (Public Key Hex) --- 
    uint8_t sender_pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    bool got_key = tox_friend_get_public_key(tox, friend_number, sender_pubkey, &err_key);
    if (!got_key || err_key != TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        V2TIM_LOG(kWarning, "HandleFriendMessage sender lookup failed with status {}", err_key);
        return;
    }
    char sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
    std::string hex_id = ToxUtil::tox_bytes_to_hex(sender_pubkey, TOX_PUBLIC_KEY_SIZE);
    strcpy(sender_hex_id, hex_id.c_str());
    sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
    senderUserID = sender_hex_id;

    if (type == TOX_MESSAGE_TYPE_ACTION) {
        NotifyFriendActionMessage(senderUserID, message_data, length);
        return;
    }
    if (!msgManager) return;

    // --- Create V2TIMMessage Object --- 
    V2TIMMessage v2_message; // Will be populated based on type
    bool message_created = false;

    if (type == TOX_MESSAGE_TYPE_NORMAL) {
        // 解析消息，检查是否包含引用回复或合并消息
        std::string messageStr(reinterpret_cast<const char*>(message_data), length);
        std::string replyJson;
        std::string mergerJson;
        std::string actualText;
        std::string compatibleText;
        
        // 先检查合并消息
        bool hasMerger = MergerMessageUtil::ParseMessageWithMerger(messageStr, mergerJson, compatibleText);
        
        if (hasMerger && !mergerJson.empty()) {
            // 有合并消息，创建合并消息对象
            // 使用CreateTextMessage创建基础消息，然后替换元素
            V2TIMMessage mergerMsg = msgManager->CreateTextMessage("");
            // 清空文本元素，添加合并元素
            mergerMsg.elemList.Clear();
            V2TIMMergerElem* mergerElem = new V2TIMMergerElem();
            mergerElem->elemType = V2TIM_ELEM_TYPE_MERGER;
            
            // 从JSON中提取title
            std::string title = MessageReplyUtil::ExtractJsonValue(mergerJson, "title");
            mergerElem->title = title.c_str();
            
            // 提取abstractList
            std::vector<std::string> abstractVec = MergerMessageUtil::ExtractAbstractList(mergerJson);
            for (const auto& abstract : abstractVec) {
                mergerElem->abstractList.PushBack(abstract.c_str());
            }
            
            // 如果没有abstractList，使用兼容文本
            if (mergerElem->abstractList.Empty() && !compatibleText.empty()) {
                mergerElem->abstractList.PushBack(compatibleText.c_str());
            }
            
            mergerElem->layersOverLimit = false;
            
            mergerMsg.elemList.PushBack(mergerElem);
            v2_message = mergerMsg;
            message_created = true;
        } else {
            // 检查引用回复
            bool hasReply = MessageReplyUtil::ParseMessageWithReply(messageStr, replyJson, actualText);
            
            if (hasReply && !replyJson.empty()) {
                // 有引用回复，使用实际文本创建消息
                V2TIMString messageText(actualText.c_str());
                v2_message = msgManager->CreateTextMessage(messageText);
                // 设置cloudCustomData
                v2_message.cloudCustomData = MessageReplyUtil::BuildCloudCustomDataFromReplyJson(replyJson);
            } else {
                // 没有特殊标记，正常处理
                V2TIMString messageText(reinterpret_cast<const char*>(message_data), length);
                v2_message = msgManager->CreateTextMessage(messageText);
            }
            message_created = true;
        }
    } else {
        V2TIM_LOG(kWarning, "Received unhandled C2C message type {}", type);
        return; // Don't notify for unsupported types
    }

    if (message_created) {
        DeliverFriendMessage(v2_message, senderUserID, sender_pubkey, 0);
    }
}

void V2TIMManagerImpl::PrunePendingDeliveriesLocked(
    std::chrono::steady_clock::time_point now) {
    for (auto it = pending_delivery_roots_.begin();
         it != pending_delivery_roots_.end();) {
        if (now - it->second.created_at >= kPendingDeliveryTtl) {
            const uint64_t root_id = it->first;
            ++it;
            RemovePendingDeliveryRootLocked(root_id);
        } else {
            ++it;
        }
    }
}

void V2TIMManagerImpl::RemovePendingDeliveryRootLocked(uint64_t root_id) {
    pending_delivery_roots_.erase(root_id);
    for (auto it = pending_delivery_fragments_.begin();
         it != pending_delivery_fragments_.end();) {
        if (it->second == root_id) {
            it = pending_delivery_fragments_.erase(it);
        } else {
            ++it;
        }
    }
}

void V2TIMManagerImpl::TrackPendingDelivery(
    uint32_t friend_number,
    const std::vector<uint32_t>& tox_message_numbers,
    const V2TIMString& msg_id,
    const V2TIMString& user_id) {
    if (tox_message_numbers.empty()) return;

    const auto now = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(pending_deliveries_mutex_);
    PrunePendingDeliveriesLocked(now);
    while (pending_delivery_roots_.size() >= kMaxPendingDeliveries) {
        const auto oldest = std::min_element(
            pending_delivery_roots_.begin(), pending_delivery_roots_.end(),
            [](const auto& lhs, const auto& rhs) {
                return lhs.second.created_at < rhs.second.created_at;
            });
        if (oldest == pending_delivery_roots_.end()) break;
        RemovePendingDeliveryRootLocked(oldest->first);
    }

    for (const uint32_t message_number : tox_message_numbers) {
        const auto existing = pending_delivery_fragments_.find(
            PendingDeliveryKey(friend_number, message_number));
        if (existing != pending_delivery_fragments_.end()) {
            RemovePendingDeliveryRootLocked(existing->second);
        }
    }

    const uint64_t root_id = next_pending_delivery_root_id_++;
    pending_delivery_roots_.emplace(
        root_id,
        PendingDeliveryRoot{
            msg_id,
            user_id,
            friend_number,
            tox_message_numbers.size(),
            now});
    for (const uint32_t message_number : tox_message_numbers) {
        pending_delivery_fragments_.emplace(
            PendingDeliveryKey(friend_number, message_number), root_id);
    }
    V2TIM_LOG(kInfo, "Tracked pending toxcore delivery root; root count {} fragment count {}",
              pending_delivery_roots_.size(),
              pending_delivery_fragments_.size());
}

void V2TIMManagerImpl::HandleFriendReadReceipt(
    uint32_t friend_number,
    uint32_t tox_message_number) {
    V2TIM_LOG(kInfo, "Handling toxcore delivery receipt");
    PendingDeliveryRoot completed_root;
    bool completed = false;
    {
        std::lock_guard<std::mutex> lock(pending_deliveries_mutex_);
        PrunePendingDeliveriesLocked(std::chrono::steady_clock::now());
        const auto fragment = pending_delivery_fragments_.find(
            PendingDeliveryKey(friend_number, tox_message_number));
        if (fragment == pending_delivery_fragments_.end()) return;

        const uint64_t root_id = fragment->second;
        pending_delivery_fragments_.erase(fragment);
        const auto root_it = pending_delivery_roots_.find(root_id);
        if (root_it == pending_delivery_roots_.end()) return;

        PendingDeliveryRoot& root = root_it->second;
        if (root.remaining_fragments > 0) {
            --root.remaining_fragments;
        }
        if (root.remaining_fragments == 0) {
            completed_root = root;
            RemovePendingDeliveryRootLocked(root_id);
            completed = true;
        }
    }
    if (!completed) return;
    V2TIM_LOG(kInfo, "Matched toxcore delivery receipt");

    auto* msg_manager = static_cast<V2TIMMessageManagerImpl*>(GetMessageManager());
    if (!msg_manager) {
        return;
    }
    V2TIMMessageReceipt receipt;
    receipt.msgID = completed_root.msg_id;
    receipt.userID = completed_root.user_id;
    receipt.isPeerRead = false;
    receipt.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    msg_manager->NotifyMessageDeliveryReceipt(receipt);
}

void V2TIMManagerImpl::ClearPendingDeliveries() {
    std::lock_guard<std::mutex> lock(pending_deliveries_mutex_);
    pending_delivery_roots_.clear();
    pending_delivery_fragments_.clear();
}

void V2TIMManagerImpl::ClearPendingDeliveriesForFriend(uint32_t friend_number) {
    std::lock_guard<std::mutex> lock(pending_deliveries_mutex_);
    std::vector<uint64_t> roots_to_remove;
    for (const auto& entry : pending_delivery_roots_) {
        if (entry.second.friend_number == friend_number) {
            roots_to_remove.push_back(entry.first);
        }
    }
    for (const uint64_t root_id : roots_to_remove) {
        RemovePendingDeliveryRootLocked(root_id);
    }
}

void V2TIMManagerImpl::HandleSelfConnectionStatus(TOX_CONNECTION connection_status) {
    if (connection_status == TOX_CONNECTION_NONE) {
        ClearPendingDeliveries();
    }
    extern int64_t GetInstanceIdFromManager(V2TIMManagerImpl* manager);
    int64_t instance_id = GetInstanceIdFromManager(this);
    V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: ENTRY - instance_id={}, connection_status={}, running_={}", 
              instance_id, connection_status, running_.load() ? 1 : 0);
    
    // CRITICAL: Check if SDK is fully initialized before processing connection status
    // This prevents crashes during startup when callbacks are triggered before initialization completes
    if (!running_.load(std::memory_order_acquire)) {
        V2TIM_LOG(kWarning, "HandleSelfConnectionStatus: SDK not running (instance_id={}), ignoring connection status", instance_id);
        return;
    }
    
    // Additional check: Ensure tox_manager_ is valid
    if (!tox_manager_) {
        V2TIM_LOG(kWarning, "HandleSelfConnectionStatus: tox_manager_ is null, SDK may not be fully initialized");
        return;
    }
    
    // When connection is established, ensure logged_in_user_ is set for status/callbacks
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if ((connection_status == TOX_CONNECTION_TCP || connection_status == TOX_CONNECTION_UDP) && logged_in_user_.Empty() && tox_manager_) {
            Tox* tox = tox_manager_->getTox();
            if (tox) {
                uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
                tox_self_get_public_key(tox, pubkey);
                std::string pk_hex = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
                std::string address = tox_manager_->getAddress();
                if (address.length() >= 76) {
                    logged_in_user_ = (pk_hex + address.substr(64, 12)).c_str();
                } else {
                    logged_in_user_ = pk_hex.c_str();
                }
            } else {
                std::string address = tox_manager_->getAddress();
                if (address.length() > 0) {
                    logged_in_user_ = address.c_str();
                }
            }
        }
    }
    
    std::vector<V2TIMSDKListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_); // Protect listener access
        listeners_to_notify.assign(sdk_listeners_.begin(), sdk_listeners_.end());
    }

    for (V2TIMSDKListener* listener : listeners_to_notify) {
        if (!listener) {
            continue;
        }
        
        switch (connection_status) {
            case TOX_CONNECTION_NONE:
                listener->OnConnectFailed(ERR_SDK_NET_DISCONNECT, "Disconnected from Tox network");
                break;
            case TOX_CONNECTION_TCP:
            case TOX_CONNECTION_UDP:
                GetToxManager()->setStatus(TOX_USER_STATUS_NONE);
                listener->OnConnectSuccess();
                
                // OPTIMIZATION: Immediately refresh cache on connection, then schedule periodic refreshes.
                // Use per-instance joinable jthread (no detach) so StopBackgroundTasks() can join before destroy.
                refresh_stop_requested_.store(false, std::memory_order_release);
                bool expected = false;
                if (refresh_task_running_.compare_exchange_strong(expected, true)) {
                    V2TIMConversationManagerImpl* cm = static_cast<V2TIMConversationManagerImpl*>(GetConversationManager());
                    if (cm) {
                        cm->RefreshCache();
                        // Reap the previous run's thread handle. The worker resets
                        // refresh_task_running_ at the very end, so the thread has
                        // either already exited or is unwinding — but the std::thread
                        // object is still joinable, and operator= on a joinable
                        // target calls std::terminate.
                        if (refresh_task_.joinable()) {
                            refresh_task_.join();
                        }
                        refresh_task_ = std::thread([this]() {
                            auto refresh_once = [this]() {
                                if (!running_.load(std::memory_order_acquire)) return;
                                V2TIMConversationManagerImpl* c = static_cast<V2TIMConversationManagerImpl*>(GetConversationManager());
                                if (c) c->RefreshCache();
                            };
                            const long delays_ms[] = { 500, 1000, 2000 };
                            for (long delay_ms : delays_ms) {
                                for (long elapsed = 0; elapsed < delay_ms && !refresh_stop_requested_.load(std::memory_order_acquire); elapsed += 10) {
                                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                                }
                                if (refresh_stop_requested_.load(std::memory_order_acquire)) break;
                                refresh_once();
                            }
                            refresh_task_running_.store(false, std::memory_order_release);
                        });
                    } else {
                        refresh_task_running_.store(false, std::memory_order_release);
                    }
                } else {
                    V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: RefreshCache task already running, skipping");
                }
                break;
        }
        // TODO: Map other V2TIMSDKListener connection callbacks like OnConnecting, OnKickedOffline?
        // OnKickedOffline might need a specific signal/callback from Tox, not just connection status.
    }
    
    // Notify self online status change when connection is established
    // This ensures the UI layer knows the user is online
    // Note: Use full address (76 chars) for self status to match currentUser.userID in Dart layer
    if (connection_status == TOX_CONNECTION_TCP || connection_status == TOX_CONNECTION_UDP) {
        if (!logged_in_user_.Empty()) {
            std::string user_id_str = logged_in_user_.CString();
            // Use full address (76 chars) for self status to match currentUser.userID
            // This ensures buildUserStatusList can correctly match and update self status
            
            V2TIMUserStatus self_status;
            self_status.userID = user_id_str.c_str();
            self_status.statusType = V2TIM_USER_STATUS_ONLINE;
            
            V2TIMUserStatusVector statusVector;
            statusVector.PushBack(self_status);
            
            // Notify all SDK listeners about self status change
            for (V2TIMSDKListener* listener : listeners_to_notify) {
                if (listener) {
                    listener->OnUserStatusChanged(statusVector);
                }
            }
            
            V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: Notified self online status with identifier length {}",
                     user_id_str.length());
        }
        
        // CRITICAL: Rejoin known groups after connection is established and online status is set
        // This ensures tox_group_join has network connectivity and is more likely to succeed
        // We use a flag to avoid multiple rejoin attempts
        // IMPORTANT: Only trigger rejoin if SDK is fully initialized (running_ is true and tox_manager_ is valid)
        {
            bool expected = false;
            if (rejoin_triggered_.compare_exchange_strong(expected, true)) {
                // Double-check that SDK is still running before creating thread
                if (!running_.load(std::memory_order_acquire) || !tox_manager_) {
                    V2TIM_LOG(kWarning, "HandleSelfConnectionStatus: SDK not fully initialized, skipping RejoinKnownGroups");
                    rejoin_triggered_.store(false); // Reset flag so it can be retried later
                    return;
                }
                
                V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: Connection established, triggering RejoinKnownGroups");
                rejoin_stop_requested_.store(false, std::memory_order_release);
                // Reap the previous run's thread handle before reassigning;
                // assigning to a joinable std::thread calls std::terminate.
                // The previous task may have finished long ago (rejoin_triggered_
                // is reset on disconnect, so a reconnect re-enters this branch).
                if (rejoin_task_.joinable()) {
                    rejoin_task_.join();
                }
                rejoin_task_ = std::thread([this]() {
                    for (int i = 0; i < 50 && !rejoin_stop_requested_.load(std::memory_order_acquire); ++i) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    }
                    if (rejoin_stop_requested_.load(std::memory_order_acquire)) return;
                    try {
                        if (!running_.load(std::memory_order_acquire) || !tox_manager_) return;
                        RejoinKnownGroups();
                    } catch (const std::bad_alloc&) {
                    } catch (const std::exception&) {
                    } catch (...) {
                    }
                });
                V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: RejoinKnownGroups task started (joinable)");
            } else {
                V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: RejoinKnownGroups already triggered, skipping");
            }
        }
    } else if (connection_status == TOX_CONNECTION_NONE) {
        // Reset rejoin flag when disconnected, so it can be triggered again on reconnect
        rejoin_triggered_.store(false);
        // Notify self offline status when disconnected
        // Note: Use full address (76 chars) for self status to match currentUser.userID in Dart layer
        if (!logged_in_user_.Empty()) {
            std::string user_id_str = logged_in_user_.CString();
            // Use full address (76 chars) for self status to match currentUser.userID
            // This ensures buildUserStatusList can correctly match and update self status
            
            V2TIMUserStatus self_status;
            self_status.userID = user_id_str.c_str();
            self_status.statusType = V2TIM_USER_STATUS_OFFLINE;
            
            V2TIMUserStatusVector statusVector;
            statusVector.PushBack(self_status);
            
            // Notify all SDK listeners about self status change
            for (V2TIMSDKListener* listener : listeners_to_notify) {
                if (listener) {
                    listener->OnUserStatusChanged(statusVector);
                }
            }
            
            V2TIM_LOG(kInfo, "HandleSelfConnectionStatus: Notified self offline status with identifier length {}",
                     user_id_str.length());
        }
    }
}

void V2TIMManagerImpl::HandleFriendRequest(const uint8_t* public_key, const uint8_t* message_data, size_t length) {
    char sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
    std::string hex_id = ToxUtil::tox_bytes_to_hex(public_key, TOX_PUBLIC_KEY_SIZE);
    strcpy(sender_hex_id, hex_id.c_str());
    sender_hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
    V2TIMString senderUserID = sender_hex_id;
    V2TIMString requestMessage(reinterpret_cast<const char*>(message_data), length);

    V2TIM_LOG(kInfo, "HandleFriendRequest received message_length={}", length);

    // Create the friend application
    V2TIMFriendApplication application;
    application.userID = senderUserID;
    application.addWording = requestMessage;
    application.addSource = "Tox"; // Default source
    application.type = V2TIM_FRIEND_APPLICATION_COME_IN; 
    // TODO: Get nickname/faceURL for the application if possible via GetUsersInfo?
    // Requires potentially making GetUsersInfo synchronous or caching.
    
    V2TIMFriendApplicationVector applications;
    applications.PushBack(application);
    
    static_cast<void>(0);
    static_cast<void>(0);
    
    // Notify only the current instance's listener (not all instances)
    // This is critical for multi-instance support, as each instance should only
    // receive friend requests intended for it
    // Use GetFriendshipListenerForManager(this) instead of GetCurrentInstanceFriendshipListener()
    // because HandleFriendRequest is called from Tox callback thread, where g_current_instance_id
    // may not be set correctly. Using 'this' pointer ensures we get the correct instance.
    V2TIM_LOG(kInfo, "HandleFriendRequest: Calling GetFriendshipListenerForManager(this={})", (void*)this);
    static_cast<void>(0);
    static_cast<void>(0);
    DartFriendshipListenerImpl* listener = GetFriendshipListenerForManager(this);
    V2TIM_LOG(kInfo, "HandleFriendRequest: GetFriendshipListenerForManager() returned: {}", (void*)listener);
    static_cast<void>(0);
    static_cast<void>(0);
    
    // If no listener found, try to get or create one for this instance
    if (!listener) {
        int64_t this_instance_id = GetInstanceIdFromManager(this);
        
        V2TIM_LOG(kInfo, "HandleFriendRequest: No listener found, creating one for instance {}", this_instance_id);
        static_cast<void>(0);
        static_cast<void>(0);
        
        // Create listener directly for this instance_id
        listener = GetOrCreateFriendshipListenerForInstance(this_instance_id);
        
        // Note: The listener is already stored in g_friendship_listeners map by GetOrCreateFriendshipListenerForInstance
        // We don't need to register it with friendship manager here, as it will be used directly
        if (listener) {
            V2TIM_LOG(kInfo, "HandleFriendRequest: Created friendship listener for instance {}", this_instance_id);
            static_cast<void>(0);
            static_cast<void>(0);
        }
    }
    
    if (listener) {
        V2TIM_LOG(kInfo, "HandleFriendRequest: Notifying current instance's listener about friend request from {}", senderUserID.CString());
        V2TIM_LOG(kInfo, "HandleFriendRequest: Calling NotifyFriendApplicationListAddedToListener with {} applications", applications.Size());
        static_cast<void>(0);
        static_cast<void>(0);
        NotifyFriendApplicationListAddedToListener(listener, &applications);
        V2TIM_LOG(kInfo, "HandleFriendRequest: NotifyFriendApplicationListAddedToListener completed");
        static_cast<void>(0);
        static_cast<void>(0);
        
        // CRITICAL: Also store the application in pending_applications_ so GetFriendApplicationList works
        // This is needed because NotifyFriendApplicationListAddedToListener only notifies listeners,
        // but doesn't store applications in the pending list
        V2TIMFriendshipManagerImpl* fm = static_cast<V2TIMFriendshipManagerImpl*>(GetFriendshipManager());
        if (fm) {
            V2TIM_LOG(kInfo, "HandleFriendRequest: Storing application in pending_applications_ for GetFriendApplicationList");
            static_cast<void>(0);
            static_cast<void>(0);
            fm->NotifyFriendApplicationListAdded(applications);
            static_cast<void>(0);
            static_cast<void>(0);
        } else {
            static_cast<void>(0);
            static_cast<void>(0);
        }
    } else {
        V2TIM_LOG(kWarning, "HandleFriendRequest: No listener found for current instance, friend request from {} will not be notified", senderUserID.CString());
        static_cast<void>(0);
        static_cast<void>(0);
        // Fallback: Also notify through the global FriendshipManagerImpl for backward compatibility
        // This ensures that if no per-instance listener is registered, the request is still processed
        V2TIMFriendshipManagerImpl* fm = static_cast<V2TIMFriendshipManagerImpl*>(GetFriendshipManager());
        if (fm) {
            V2TIM_LOG(kInfo, "HandleFriendRequest: Falling back to global FriendshipManagerImpl");
            static_cast<void>(0);
            static_cast<void>(0);
            fm->NotifyFriendApplicationListAdded(applications);
        }
    }
    static_cast<void>(0);
    static_cast<void>(0);
    static_cast<void>(0);
    static_cast<void>(0);
}

void V2TIMManagerImpl::HandleFriendName(uint32_t friend_number, const uint8_t* name_data, size_t length) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;
    V2TIMFriendshipManagerImpl* fm = static_cast<V2TIMFriendshipManagerImpl*>(GetFriendshipManager());
    if (!fm) return;

    // CRITICAL: Safely construct V2TIMString objects with exception handling
    V2TIMString friendUserID;
    V2TIMString friendName;
    
    try {
        // CRITICAL: Verify name_data is valid before constructing V2TIMString
        if (name_data && length > 0 && length < 10000) { // Reasonable length limit
            friendName = V2TIMString(reinterpret_cast<const char*>(name_data), length);
        } else {
            friendName = V2TIMString("");
        }
    } catch (const std::exception& e) {
        friendName = V2TIMString("");
    } catch (...) {
        friendName = V2TIMString("");
    }
    
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (tox_friend_get_public_key(tox, friend_number, pubkey, &err_key) && err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendUserID = hex_id;

        V2TIM_LOG(kInfo, "HandleFriendName: Friend {} ({}) changed name to: {}", friendUserID.CString(), friend_number, friendName.CString());
        
        // Notify Flutter layer to save nickname to local cache via FFI
        tim2tox_ffi_save_friend_nickname(friendUserID.CString(), friendName.CString());
        
        // CRITICAL: Safely construct V2TIMFriendInfoResult with exception handling
        V2TIMFriendInfoResult infoResult;
        try {
            infoResult.resultCode = 0;
            
            // CRITICAL: Verify friendUserID and friendName are valid before assignment
            try {
                const char* user_id_cstr = friendUserID.CString();
                const char* friend_name_cstr = friendName.CString();
                
                if (user_id_cstr && friend_name_cstr) {
                    infoResult.friendInfo.userID = friendUserID;
                    infoResult.friendInfo.userFullInfo.nickName = friendName;
                } else {
                    return;
                }
            } catch (...) {
                return;
            }
            
            V2TIMFriendInfoResultVector infoResultVector;
            try {
                infoResultVector.PushBack(infoResult);
            } catch (...) {
                return;
            }
            
            // Notify the friendship listener for THIS instance (receiver of the name change),
            // so the callback is sent with the correct instance_id (e.g. bob=2).
            V2TIMFriendInfoVector friendInfoList;
            for (size_t i = 0; i < infoResultVector.Size(); i++) {
                const V2TIMFriendInfoResult& r = infoResultVector[i];
                if (r.resultCode == 0) friendInfoList.PushBack(r.friendInfo);
            }
            if (!friendInfoList.Empty()) {
                DartFriendshipListenerImpl* listener = GetFriendshipListenerForManager(this);
                if (!listener) {
                    int64_t inst_id = GetInstanceIdFromManager(this);
                    listener = GetOrCreateFriendshipListenerForInstance(inst_id);
                    if (listener) RegisterFriendshipListenerWithManager(listener, this);
                }
                if (listener) NotifyFriendInfoChangedToListener(listener, &friendInfoList);
            }
        } catch (const std::exception& e) {
        } catch (...) {
            // Skip notification on error
        }

    } else {
        V2TIM_LOG(kError, "HandleFriendName: Failed to get public key for friend number {}", friend_number);
    }
}

void V2TIMManagerImpl::HandleFriendStatusMessage(uint32_t friend_number, const uint8_t* message_data, size_t length) {
     Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;
    V2TIMFriendshipManagerImpl* fm = static_cast<V2TIMFriendshipManagerImpl*>(GetFriendshipManager());
    if (!fm) return;

    // CRITICAL: Safely construct V2TIMString objects with exception handling
    V2TIMString friendUserID;
    V2TIMString statusMessage;
    
    try {
        // CRITICAL: Verify message_data is valid before constructing V2TIMString
        if (message_data && length > 0 && length < 10000) { // Reasonable length limit
            statusMessage = V2TIMString(reinterpret_cast<const char*>(message_data), length);
        } else {
            statusMessage = V2TIMString("");
        }
    } catch (const std::exception& e) {
        statusMessage = V2TIMString("");
    } catch (...) {
        statusMessage = V2TIMString("");
    }
    
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (tox_friend_get_public_key(tox, friend_number, pubkey, &err_key) && err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendUserID = hex_id;

        V2TIM_LOG(kInfo, "HandleFriendStatusMessage: Friend {} ({}) changed status message to: {}", friendUserID.CString(), friend_number, statusMessage.CString());

        // Notify Flutter layer to save status message to local cache via FFI
        tim2tox_ffi_save_friend_status_message(friendUserID.CString(), statusMessage.CString());

        // CRITICAL: Safely construct V2TIMFriendInfoResult with exception handling
        V2TIMFriendInfoResult infoResult;
        try {
            infoResult.resultCode = 0;
            
            // CRITICAL: Verify friendUserID and statusMessage are valid before assignment
            try {
                const char* user_id_cstr = friendUserID.CString();
                const char* status_msg_cstr = statusMessage.CString();
                
                if (user_id_cstr && status_msg_cstr) {
                    infoResult.friendInfo.userID = friendUserID;
                    infoResult.friendInfo.userFullInfo.selfSignature = statusMessage; // Map Tox status message to V2TIM selfSignature
                } else {
                    return;
                }
            } catch (...) {
                return;
            }
            
            V2TIMFriendInfoResultVector infoResultVector;
            try {
                infoResultVector.PushBack(infoResult);
            } catch (...) {
                return;
            }
            
            // Notify the friendship listener for THIS instance (receiver of the status message change)
            V2TIMFriendInfoVector friendInfoList;
            for (size_t i = 0; i < infoResultVector.Size(); i++) {
                const V2TIMFriendInfoResult& r = infoResultVector[i];
                if (r.resultCode == 0) friendInfoList.PushBack(r.friendInfo);
            }
            if (!friendInfoList.Empty()) {
                DartFriendshipListenerImpl* listener = GetFriendshipListenerForManager(this);
                if (!listener) {
                    int64_t inst_id = GetInstanceIdFromManager(this);
                    listener = GetOrCreateFriendshipListenerForInstance(inst_id);
                    if (listener) RegisterFriendshipListenerWithManager(listener, this);
                }
                if (listener) NotifyFriendInfoChangedToListener(listener, &friendInfoList);
            }
        } catch (const std::exception& e) {
        } catch (...) {
            // Skip notification on error
        }
    } else {
        V2TIM_LOG(kError, "HandleFriendStatusMessage: Failed to get public key for friend number {}", friend_number);
    }
}

void V2TIMManagerImpl::HandleFriendConnectionStatus(uint32_t friend_number, TOX_CONNECTION connection_status) {
    if (connection_status == TOX_CONNECTION_NONE) {
        ClearPendingDeliveriesForFriend(friend_number);
    }
    NoteFriendConnectionForIdentity(friend_number, connection_status != TOX_CONNECTION_NONE);
    V2TIM_LOG(kInfo, "HandleFriendConnectionStatus received status {}", connection_status);
    
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) {
        return;
    }

    V2TIMString friendUserID;

    // Get UserID from friend_number
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (tox_friend_get_public_key(tox, friend_number, pubkey, &err_key) && err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendUserID = hex_id;
    } else {
        V2TIM_LOG(kWarning, "HandleFriendConnectionStatus peer lookup failed with status {}", err_key);
        return;
    }

    // Map TOX_CONNECTION to V2TIMUserStatusType
    // In Tox, online status is determined by connection status, not user status
    V2TIMUserStatus v2_status;
    v2_status.userID = friendUserID;
    v2_status.statusType = (connection_status != TOX_CONNECTION_NONE) ? V2TIM_USER_STATUS_ONLINE : V2TIM_USER_STATUS_OFFLINE;

    V2TIM_LOG(kInfo, "HandleFriendConnectionStatus mapped status {} to type {}",
              connection_status, v2_status.statusType);

    // Notify SDK Listeners
    std::vector<V2TIMSDKListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(sdk_listeners_.begin(), sdk_listeners_.end());
    }
    
    V2TIM_LOG(kInfo, "HandleFriendConnectionStatus notifying {} listeners",
              listeners_to_notify.size());
    
    V2TIMUserStatusVector statusVector;
    statusVector.PushBack(v2_status);
    
    for (V2TIMSDKListener* listener : listeners_to_notify) {
        if (listener) {
            try {
                listener->OnUserStatusChanged(statusVector);
            } catch (const std::exception&) {
                V2TIM_LOG(kWarning, "HandleFriendConnectionStatus listener failed");
            } catch (...) {
                V2TIM_LOG(kWarning, "HandleFriendConnectionStatus listener failed");
            }
        }
    }
    
    // When a friend connects, ensure our status is set so they can see us as online
    // This is especially important for newly added friends
    if (connection_status != TOX_CONNECTION_NONE) {
        // Ensure our status is set to online when a friend connects
        // This ensures newly added friends can see us as online immediately
        Tox* our_tox = GetToxManager()->getTox();
        if (our_tox) {
            TOX_CONNECTION our_status = tox_self_get_connection_status(our_tox);
            if (our_status != TOX_CONNECTION_NONE) {
                // We're connected, ensure status is set to online
                GetToxManager()->setStatus(TOX_USER_STATUS_NONE);
            }
        }
        
        // NOTE: Do NOT call NotifyFriendListAdded here.
        // OnFriendListAdded should only fire when a NEW friend is actually added (via AddFriend
        // or AcceptFriendApplication), not when an existing friend's connection status changes.
        // Firing it on every connection change causes the Dart UI to re-add deleted friends
        // and write them back into local persistence, preventing proper deletion.
        // The OnUserStatusChanged callback (already fired above) handles status updates.
    }
}

void V2TIMManagerImpl::HandleFriendStatus(uint32_t friend_number, TOX_USER_STATUS status) {
    static_cast<void>(0);
    static_cast<void>(0);
    
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) {
        static_cast<void>(0);
        static_cast<void>(0);
        return;
    }

    V2TIMString friendUserID;

    // Get UserID from friend_number
    uint8_t pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_FRIEND_GET_PUBLIC_KEY err_key;
    if (tox_friend_get_public_key(tox, friend_number, pubkey, &err_key) && err_key == TOX_ERR_FRIEND_GET_PUBLIC_KEY_OK) {
        char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0';
        friendUserID = hex_id;
    } else {
        V2TIM_LOG(kError, "HandleFriendStatus: Failed to get public key for friend number {}", friend_number);
        return;
    }

    // Map TOX_USER_STATUS to V2TIMUserStatusType
    V2TIMUserStatus v2_status;
    v2_status.userID = friendUserID;
    switch (status) {
        case TOX_USER_STATUS_NONE:
            v2_status.statusType = V2TIM_USER_STATUS_OFFLINE;
            break;
        case TOX_USER_STATUS_AWAY:
            v2_status.statusType = V2TIM_USER_STATUS_OFFLINE; // Or map to a custom status? V2TIM only has Online/Offline/Unkown.
            break;
        case TOX_USER_STATUS_BUSY:
             v2_status.statusType = V2TIM_USER_STATUS_ONLINE; // Map Busy to Online for simplicity?
            break;
        default: // Includes TOX_USER_STATUS_INVALID and any others
             v2_status.statusType = V2TIM_USER_STATUS_UNKNOWN;
             break;
    }
     // v2_status.customStatus = ...; // Tox doesn't provide custom status string in this callback

    V2TIM_LOG(kInfo, "HandleFriendStatus: Friend {} ({}) changed status to: {} (V2TIM type: {})", friendUserID.CString(), friend_number, status, v2_status.statusType);

    // Notify SDK Listeners
    std::vector<V2TIMSDKListener*> listeners_to_notify;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_to_notify.assign(sdk_listeners_.begin(), sdk_listeners_.end());
    }
    
    static_cast<void>(0);
    static_cast<void>(0);
    
    V2TIMUserStatusVector statusVector;
    statusVector.PushBack(v2_status);
    
    static_cast<void>(0);
    static_cast<void>(0);
    
    for (size_t i = 0; i < listeners_to_notify.size(); i++) {
        V2TIMSDKListener* listener = listeners_to_notify[i];
        if (listener) {
            static_cast<void>(0);
            static_cast<void>(0);
            try {
                listener->OnUserStatusChanged(statusVector); // Notify with the status vector
                static_cast<void>(0);
            } catch (const std::exception& e) {
                static_cast<void>(0);
                static_cast<void>(0);
            } catch (...) {
                static_cast<void>(0);
                static_cast<void>(0);
            }
            static_cast<void>(0);
        } else {
            static_cast<void>(0);
            static_cast<void>(0);
        }
    }
    
    static_cast<void>(0);
    static_cast<void>(0);
}

void V2TIMManagerImpl::HandleGroupTitle(uint32_t conference_number, uint32_t peer_number, const uint8_t* title_data, size_t length) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;

    V2TIMString groupID;
    V2TIMString groupName(reinterpret_cast<const char*>(title_data), length);
    V2TIMString opUserID;

    // Find GroupID
    {
        std::lock_guard<std::mutex> lock(mutex_); 
        auto it = group_number_to_group_id_.find(conference_number);
        if (it == group_number_to_group_id_.end()) return; // Unknown group
        groupID = it->second;
    }

    // Find Operator UserID (who changed the title)
    uint8_t op_pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_CONFERENCE_PEER_QUERY err_peer;
    if (GetToxManager()->getConferencePeerPublicKey(conference_number, peer_number, op_pubkey, &err_peer) && err_peer == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
         char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(op_pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0'; 
        opUserID = hex_id;
    } else {
        V2TIM_LOG(kWarning, "HandleGroupTitle: Could not get operator user ID for peer {} in group {}", peer_number, groupID.CString());
        // Continue, but opUserID will be empty
    }
    
    V2TIM_LOG(kInfo, "HandleGroupTitle: Group {} title changed to '{}' by {} ({})", groupID.CString(), groupName.CString(), opUserID.CString(), peer_number);

    // Notify Listeners
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }

    // Construct V2TIMGroupChangeInfo for the name change
    V2TIMGroupChangeInfo changeInfo;
    changeInfo.type = V2TIM_GROUP_INFO_CHANGE_TYPE_NAME;
    changeInfo.value = groupName;
    
    // Create a vector for group changes
    V2TIMGroupChangeInfoVector changeInfoVector;
    changeInfoVector.PushBack(changeInfo);

    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            // Construct V2TIMGroupMemberInfo for the operator
            V2TIMGroupMemberInfo opMemberInfo;
            opMemberInfo.userID = opUserID;
            // TODO: Fill other opMemberInfo fields if possible (nickname, role etc.)
            
            // OnGroupInfoChanged only takes two parameters
            listener->OnGroupInfoChanged(groupID, changeInfoVector);
            
            // Note: If you need to pass the operator info, consider adding it to your own field
            // or using a different callback that accepts the operator parameter
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerName(uint32_t conference_number, uint32_t peer_number, const uint8_t* name_data, size_t length) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;

    V2TIMString groupID;
    V2TIMString memberUserID;
    V2TIMString memberName(reinterpret_cast<const char*>(name_data), length);

    // Find GroupID
    {
        std::lock_guard<std::mutex> lock(mutex_); 
        auto it = group_number_to_group_id_.find(conference_number);
        if (it == group_number_to_group_id_.end()) return; // Unknown group
        groupID = it->second;
    }

    // Find Member UserID 
    uint8_t member_pubkey[TOX_PUBLIC_KEY_SIZE];
    TOX_ERR_CONFERENCE_PEER_QUERY err_peer;
    if (GetToxManager()->getConferencePeerPublicKey(conference_number, peer_number, member_pubkey, &err_peer) && err_peer == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
         char hex_id[TOX_PUBLIC_KEY_SIZE * 2 + 1];
        std::string hex_id_str = ToxUtil::tox_bytes_to_hex(member_pubkey, TOX_PUBLIC_KEY_SIZE);
        strcpy(hex_id, hex_id_str.c_str());
        hex_id[TOX_PUBLIC_KEY_SIZE * 2] = '\0'; 
        memberUserID = hex_id;
    } else {
        V2TIM_LOG(kError, "HandleGroupPeerName: Could not get user ID for peer {} in group {}", peer_number, groupID.CString());
        return;
    }

    V2TIM_LOG(kInfo, "HandleGroupPeerName: Member {} in group {} changed name to '{}'", memberUserID.CString(), groupID.CString(), memberName.CString());

    // Notify Listeners
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }

    V2TIMGroupMemberChangeInfo changeInfo;
    changeInfo.userID = memberUserID;
    changeInfo.muteTime = 0; // Name change doesn't involve mute time
    
    V2TIMGroupMemberChangeInfoVector changeInfoVector;
    changeInfoVector.PushBack(changeInfo);

    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
             // V2TIM lacks a specific "member name changed" callback. 
             // Use OnMemberInfoChanged, but it requires a list of changes.
             // For simplicity, we send just the name change.
             V2TIM_LOG(kWarning, "Mapping PeerName change to OnMemberInfoChanged (may lack other details).");
            listener->OnMemberInfoChanged(groupID, changeInfoVector);
            // Ideally, fetch full member info and send that?
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerListChanged(uint32_t conference_number) {
    // conference_number is the tagged map key (ConferenceMapKey); raw_number is
    // what toxcore's conference API and the tox_conf_<n> ids use.
    const uint32_t raw_number = ConferenceNumberFromKey(conference_number);
    ToxManager* tox_manager = GetToxManager();
    Tox* tox = tox_manager ? tox_manager->getTox() : nullptr;
    if (!tox || !running_) return;
    V2TIM_LOG(kInfo, "HandleGroupPeerListChanged called for conference {}", conference_number);

    Tox_Err_Conference_Get_Type type_error;
    const Tox_Conference_Type conference_type = tox_conference_get_type(
        tox, raw_number, &type_error);
    if (type_error != TOX_ERR_CONFERENCE_GET_TYPE_OK) {
        V2TIM_LOG(kError,
                  "HandleGroupPeerListChanged: Failed to get conference {} type, error: {}",
                  conference_number, static_cast<int>(type_error));
        return;
    }
    if (conference_type != TOX_CONFERENCE_TYPE_AV &&
        conference_type != TOX_CONFERENCE_TYPE_TEXT) {
        V2TIM_LOG(kError,
                  "HandleGroupPeerListChanged: Unsupported conference {} type: {}",
                  conference_number, static_cast<int>(conference_type));
        return;
    }
    const std::string conference_group_type =
        conference_type == TOX_CONFERENCE_TYPE_AV ? "av_conference"
                                                   : "conference";

    V2TIMString stable_group_id;
    std::vector<uint8_t> stable_conference_id;
    std::string stable_conference_id_hex;
    std::vector<V2TIMString> legacy_conference_candidates;
    const std::vector<std::string> known_conferences = GetKnownGroupIDs();
    for (const std::string& known_group : known_conferences) {
        if (known_group.rfind("tox_conf_", 0) != 0) continue;

        char stored_identity[TOX_CONFERENCE_ID_SIZE * 2 + 1];
        if (!GetGroupChatIdFromStorage(known_group, stored_identity,
                                       sizeof(stored_identity))) {
            // List-order matching is retained only for legacy profiles without a stored conference ID.
            legacy_conference_candidates.emplace_back(known_group.c_str());
            continue;
        }

        const std::size_t identity_length = std::strlen(stored_identity);
        uint8_t conference_id[TOX_CONFERENCE_ID_SIZE];
        if (identity_length != TOX_CONFERENCE_ID_SIZE * 2 ||
            !ToxUtil::tox_hex_to_bytes(stored_identity, identity_length,
                                       conference_id,
                                       TOX_CONFERENCE_ID_SIZE)) {
            continue;
        }

        char stored_type[16] = {};
        if (GetGroupTypeFromStorage(known_group, stored_type,
                                    sizeof(stored_type)) &&
            conference_group_type != stored_type) {
            continue;
        }

        Tox_Err_Conference_By_Id lookup_error;
        const Tox_Conference_Number resolved = tox_manager->getConferenceById(
            conference_id, &lookup_error);
        if (lookup_error == TOX_ERR_CONFERENCE_BY_ID_OK &&
            ConferenceMapKey(resolved) == conference_number) {
            stable_group_id = V2TIMString(known_group.c_str());
            stable_conference_id.assign(
                conference_id, conference_id + TOX_CONFERENCE_ID_SIZE);
            stable_conference_id_hex = stored_identity;
            break;
        }
    }
    
    // Find GroupID for this conference
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(conference_number);
        if (!stable_group_id.Empty() &&
            (it == group_number_to_group_id_.end() ||
             it->second != stable_group_id)) {
            auto old_number = group_id_to_group_number_.find(stable_group_id);
            if (old_number != group_id_to_group_number_.end() &&
                old_number->second != conference_number) {
                auto old_reverse =
                    group_number_to_group_id_.find(old_number->second);
                if (old_reverse != group_number_to_group_id_.end() &&
                    old_reverse->second == stable_group_id) {
                    group_number_to_group_id_.erase(old_reverse);
                }
            }
            group_number_to_group_id_[conference_number] = stable_group_id;
            group_id_to_group_number_[stable_group_id] = conference_number;
            group_id_to_type_[stable_group_id] = conference_group_type;
            group_id_to_chat_id_[stable_group_id] = stable_conference_id;
            chat_id_to_group_id_[stable_conference_id_hex] = stable_group_id;
            groupID = stable_group_id;
        } else if (it == group_number_to_group_id_.end()) {
            // Conference not yet mapped. Before creating a new synthetic ID,
            // check g_known_groups_list for an existing ID (e.g. tox_conf_N)
            // to avoid duplicating IDs for the same conference.
            V2TIMString resolvedGroupID;

            char conf_id[64];
            snprintf(conf_id, sizeof(conf_id), "tox_conf_%u",
                     raw_number);
            for (const V2TIMString& candidate :
                 legacy_conference_candidates) {
                if (candidate == conf_id) {
                    resolvedGroupID = candidate;
                    break;
                }
            }
            if (resolvedGroupID.Empty()) {
                for (const V2TIMString& candidate :
                     legacy_conference_candidates) {
                    if (group_id_to_group_number_.find(candidate) ==
                        group_id_to_group_number_.end()) {
                        resolvedGroupID = candidate;
                        break;
                    }
                }
            }

            // Fallback: register it as tox_conf_N only if no known group
            // found. (A tox_group_N id here collided with NGC synthetic and
            // locally-minted tox_group_<counter> ids.)
            if (resolvedGroupID.Empty()) {
                const char* synthetic_id = conf_id;
                resolvedGroupID = V2TIMString(synthetic_id);
                V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: No known group found, auto-registered conference {} as groupID={}", conference_number, synthetic_id);
            }

            group_number_to_group_id_[conference_number] = resolvedGroupID;
            group_id_to_group_number_[resolvedGroupID] = conference_number;
            group_id_to_type_[resolvedGroupID] = conference_group_type;
            groupID = resolvedGroupID;
        } else {
            groupID = it->second;
            // The entry sits under a conference-tagged key, so it IS this
            // conference; keep its recorded type in sync with toxcore's.
            auto& type_ref = group_id_to_type_[groupID];
            if (type_ref != conference_group_type) {
                V2TIM_LOG(kInfo,
                          "HandleGroupPeerListChanged: Updating groupID={} type to '{}' (was '{}')",
                          groupID.CString(), conference_group_type,
                          type_ref.c_str());
            }
            group_id_to_type_[groupID] = conference_group_type;
        }
    }
    SetGroupTypeInStorage(groupID.CString(), conference_group_type);
    // Persist its conference id too (no-op when unchanged), so a restart
    // rebinds it by identity instead of by list order.
    StoreConferenceIdentity(groupID, conference_number);

    // Get current peer list
    TOX_ERR_CONFERENCE_PEER_QUERY err_peer;
    uint32_t peer_count = tox_conference_peer_count(tox, raw_number, &err_peer);
    if (err_peer != TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
        V2TIM_LOG(kError, "HandleGroupPeerListChanged: Failed to get peer count, error: %d", err_peer);
        return;
    }
    
    // Build current peer set (by public key hex)
    std::unordered_set<std::string> current_peers;
    for (uint32_t peer_number = 0; peer_number < peer_count; peer_number++) {
        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
        TOX_ERR_CONFERENCE_PEER_QUERY err_key;
        if (GetToxManager()->getConferencePeerPublicKey(conference_number, peer_number, peer_pubkey, &err_key) &&
            err_key == TOX_ERR_CONFERENCE_PEER_QUERY_OK) {
            std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
            current_peers.insert(userID);
        }
    }
    
    // Get previous snapshot
    std::unordered_set<std::string> previous_peers;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_peer_snapshots_.find(conference_number);
        if (it != group_peer_snapshots_.end()) {
            previous_peers = it->second;
        }
        // Update snapshot
        group_peer_snapshots_[conference_number] = current_peers;
    }
    
    // Find new members (in current but not in previous)
    std::vector<std::string> new_members;
    for (const auto& userID : current_peers) {
        if (previous_peers.find(userID) == previous_peers.end()) {
            new_members.push_back(userID);
        }
    }
    
    // Find left members (in previous but not in current)
    std::vector<std::string> left_members;
    for (const auto& userID : previous_peers) {
        if (current_peers.find(userID) == current_peers.end()) {
            left_members.push_back(userID);
        }
    }
    
    // Get listeners
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    // Notify about new members
    if (!new_members.empty()) {
        V2TIMGroupMemberInfoVector newMemberList;
        for (const auto& userID : new_members) {
            V2TIMGroupMemberInfo memberInfo;
            memberInfo.userID = V2TIMString(userID.c_str());
            newMemberList.PushBack(memberInfo);
            V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Member {} joined group {}", userID, groupID.CString());
        }
        
        for (V2TIMGroupListener* listener : listeners_copy) {
            if (listener) {
                listener->OnMemberEnter(groupID, newMemberList);
            }
        }
    }
    
    // Notify about left members
    for (const auto& userID : left_members) {
        V2TIMGroupMemberInfo memberInfo;
        memberInfo.userID = V2TIMString(userID.c_str());
        V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Member {} left group {}", userID, groupID.CString());
        
        for (V2TIMGroupListener* listener : listeners_copy) {
            if (listener) {
                listener->OnMemberLeave(groupID, memberInfo);
            }
        }
    }
    
    // If this is the first time (previous_peers was empty), don't notify
    // This prevents false notifications when the snapshot is first created
    if (previous_peers.empty() && !current_peers.empty()) {
        V2TIM_LOG(kInfo, "HandleGroupPeerListChanged: Initial snapshot created for conference {}, skipping notifications", conference_number);
    }
}

void V2TIMManagerImpl::HandleGroupConnected(uint32_t conference_number) {
    Tox* tox = GetToxManager()->getTox();
    if (!tox || !running_) return;
    
    V2TIM_LOG(kInfo, "HandleGroupConnected: Conference {} connected successfully", conference_number);
    
    // Find GroupID for this conference
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(conference_number);
        if (it == group_number_to_group_id_.end()) {
            // Conference not yet mapped, might be from a join operation
            // Generate a temporary ID or wait for JoinGroup to complete
            V2TIM_LOG(kWarning, "HandleGroupConnected: Conference {} not found in mapping, may be from join operation", conference_number);
            return;
        }
        groupID = it->second;
    }
    
    // Notify group listeners about connection
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            // V2TIM doesn't have a specific "group connected" callback
            // We can use OnGroupInfoChanged or just log it
            // For now, we'll trigger a refresh of group info
            V2TIM_LOG(kInfo, "HandleGroupConnected: Notifying listeners for group {}", groupID.CString());
            // Note: V2TIM API doesn't have a direct "connected" event, so we'll just log
            // In a real implementation, you might want to refresh group info here
        }
    }
}

// Helper method to access private data
bool V2TIMManagerImpl::GetGroupNumberFromID(const V2TIMString& groupID, Tox_Group_Number& group_number) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_group_number_.find(groupID);
    if (it == group_id_to_group_number_.end()) {
        return false;
    }
    group_number = it->second;
    return true;
}

bool V2TIMManagerImpl::GetChatIdFromGroupID(const V2TIMString& groupID, uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_chat_id_.find(groupID);
    if (it == group_id_to_chat_id_.end() || it->second.size() != TOX_GROUP_CHAT_ID_SIZE) {
        return false;
    }
    memcpy(chat_id, it->second.data(), TOX_GROUP_CHAT_ID_SIZE);
    return true;
}

bool V2TIMManagerImpl::IsTemporaryInviteGroupID(const V2TIMString& groupID) const {
    const char* value = groupID.CString();
    return value != nullptr && std::strncmp(value, "tox_inv_", 8) == 0;
}

// Promote a `tox_inv_<friend>_<ms>` invite alias to a stable `tox_<n>` id.
//
// WHY THIS EXISTS: an invitee that has never seen the group before reaches
// HandleGroupSelfJoin holding only the temporary alias. Publishing that alias
// is wrong (it is per-invite, not per-group), but simply refusing to publish —
// which is what happened before — dropped the self-join on the floor: the Dart
// layer was never told it had joined, so the group never appeared in
// knownGroups, never got a conversation, and could not accrue unread. The
// invitee's whole group surface stayed invisible.
//
// It only reproduced in the two-process real-UI campaign: in single-process
// auto_tests A and B share `g_cross_instance_group_identity`, so the invitee
// resolved the inviter's canonical id and the alias never survived to the
// guard. Separate processes have separate maps, so it always survived.
V2TIMString V2TIMManagerImpl::PromoteTemporaryInviteGroupID(
    const V2TIMString& temp_group_id, Tox_Group_Number group_number) {
    // A conference key carries a conference id, not an NGC chat id: read it
    // with the conference API and never run NGC (cross-instance chat id)
    // canonicalisation on it.
    const bool is_conference = IsConferenceMapKey(group_number);
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    if (!GetLiveGroupIdentity(group_number, chat_id)) {
        return V2TIMString();
    }
    std::ostringstream oss;
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        oss << std::hex << std::setw(2) << std::setfill('0')
            << static_cast<int>(chat_id[i]);
    }
    const std::string chat_id_hex = oss.str();

    // Highest `tox_<n>` already in use, from BOTH sources CreateGroup consults.
    // Skipping this is not cosmetic: `g_next_group_id_global` is a process
    // static that restarts at 0, while `tox_0` may already exist in Dart
    // persistence from a previous session — CreateGroup's own comment calls out
    // that reusing it makes the new group load the old group's history. Read
    // the Dart-side list OUTSIDE `mutex_`, as CreateGroup does.
    std::unordered_set<std::string> taken;
    uint64_t max_existing_id = 0;
    auto note_existing = [&](const std::string& existing_id) {
        if (existing_id.rfind("tox_", 0) != 0 || existing_id.length() <= 4) {
            return;
        }
        try {
            const uint64_t id_num = std::stoull(existing_id.substr(4));
            if (id_num > max_existing_id) max_existing_id = id_num;
        } catch (...) {
            // Non-numeric suffix (e.g. "tox_community_1") — not our namespace.
        }
    };
    for (const auto& g : GetKnownGroupIDs()) {
        taken.insert(g);
        note_existing(g);
    }
    max_existing_id = std::max(max_existing_id, GetRetiredGroupIdMax());

    V2TIMString canonical;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        // Prefer an id already agreed for this chat_id (same-process peers, or
        // a rejoin after the alias was minted) before allocating a new one.
        // A conference only reuses a local id already bound to its conference id.
        if (is_conference) {
            for (const auto& entry : group_id_to_chat_id_) {
                if (IsTemporaryInviteGroupID(entry.first)) continue;
                if (entry.second.size() == TOX_GROUP_CHAT_ID_SIZE &&
                    memcmp(entry.second.data(), chat_id, TOX_GROUP_CHAT_ID_SIZE) == 0) {
                    canonical = entry.first;
                    break;
                }
            }
        } else {
            canonical = CanonicalGroupIDForChatIdLocked(temp_group_id, chat_id_hex);
        }
        if (canonical.Empty() || IsTemporaryInviteGroupID(canonical)) {
            for (const auto& pair : group_id_to_group_number_) {
                note_existing(std::string(pair.first.CString()));
            }
            char buf[32];
            uint64_t candidate = g_next_group_id_global.fetch_add(1);
            if (candidate <= max_existing_id) {
                candidate = max_existing_id + 1;
                uint64_t expected = g_next_group_id_global.load();
                while (expected <= candidate &&
                       !g_next_group_id_global.compare_exchange_weak(
                           expected, candidate + 1)) {
                    // retry with the refreshed `expected`
                }
            }
            snprintf(buf, sizeof(buf), "tox_%llu",
                     (unsigned long long)candidate);
            while (group_id_to_group_number_.find(buf) !=
                       group_id_to_group_number_.end() ||
                   taken.count(std::string(buf)) > 0) {
                candidate = g_next_group_id_global.fetch_add(1);
                if (candidate <= max_existing_id) candidate = max_existing_id + 1;
                snprintf(buf, sizeof(buf), "tox_%llu",
                         (unsigned long long)candidate);
            }
            canonical = V2TIMString(buf);
        }

        // Move every alias-keyed entry over, then drop the alias so nothing can
        // resolve through it again.
        group_id_to_group_number_.erase(temp_group_id);
        group_id_to_chat_id_.erase(temp_group_id);
        pending_group_invites_.erase(temp_group_id);
        group_id_to_group_number_[canonical] = group_number;
        group_number_to_group_id_[group_number] = canonical;
        group_id_to_chat_id_[canonical] =
            std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
        if (!is_conference) chat_id_to_group_id_[chat_id_hex] = canonical;
    }
    if (is_conference) {
        // Conference identity + its real kind (StoreConferenceIdentity keys
        // chat_id_to_group_id_ with its own hex spelling).
        StoreConferenceIdentity(canonical, group_number);
        TOX_ERR_CONFERENCE_GET_TYPE err_type = TOX_ERR_CONFERENCE_GET_TYPE_OK;
        const Tox_Conference_Type conference_type =
            GetToxManager()->getConferenceType(group_number, &err_type);
        const char* type_label =
            (err_type == TOX_ERR_CONFERENCE_GET_TYPE_OK &&
             conference_type == TOX_CONFERENCE_TYPE_AV) ? "av_conference" : "conference";
        SetGroupTypeInStorage(canonical.CString(), type_label);
        V2TIM_LOG(kInfo,
                  "PromoteTemporaryInviteGroupID: promoted conference %s -> %s for key=%u",
                  temp_group_id.CString(), canonical.CString(), group_number);
        return canonical;
    }
    // Through the setter so the Dart preferences learn the new id's chat id
    // (it also records the cross-instance identity).
    SetGroupChatIdInStorage(canonical.CString(), chat_id_hex);
    SetGroupTypeInStorage(canonical.CString(), "group");
    V2TIM_LOG(kInfo,
              "PromoteTemporaryInviteGroupID: promoted %s -> %s for group_number=%u",
              temp_group_id.CString(), canonical.CString(), group_number);
    return canonical;
}

V2TIMString V2TIMManagerImpl::CanonicalGroupIDForChatIdLocked(
    const V2TIMString& requested_group_id,
    const std::string& chat_id_hex) const {
    {
        std::lock_guard<std::mutex> lock(g_cross_instance_group_identity_mutex);
        auto cross_instance = g_cross_instance_group_identity.find(chat_id_hex);
        if (cross_instance != g_cross_instance_group_identity.end()) {
            const V2TIMString candidate(cross_instance->second.group_id.c_str());
            if (!IsTemporaryInviteGroupID(candidate)) return candidate;
        }
    }
    auto existing = chat_id_to_group_id_.find(chat_id_hex);
    if (existing != chat_id_to_group_id_.end() &&
        !IsTemporaryInviteGroupID(existing->second)) {
        return existing->second;
    }
    for (const auto& entry : group_id_to_chat_id_) {
        if (IsTemporaryInviteGroupID(entry.first)) continue;
        if (entry.second.size() != TOX_GROUP_CHAT_ID_SIZE) continue;
        std::ostringstream candidate_hex;
        for (uint8_t byte : entry.second) {
            candidate_hex << std::hex << std::setw(2) << std::setfill('0')
                          << static_cast<int>(byte);
        }
        if (candidate_hex.str() == chat_id_hex) {
            return entry.first;
        }
    }
    if (!IsTemporaryInviteGroupID(requested_group_id)) {
        return requested_group_id;
    }
    return requested_group_id;
}

bool V2TIMManagerImpl::GetGroupIDFromChatId(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE], V2TIMString& groupID) {
    std::lock_guard<std::mutex> lock(mutex_);
    // Convert chat_id to hex string for lookup
    std::ostringstream oss;
    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
    }
    std::string chat_id_hex = oss.str();
    
    auto it = chat_id_to_group_id_.find(chat_id_hex);
    if (it == chat_id_to_group_id_.end()) {
        return false;
    }
    groupID = it->second;
    return true;
}

bool V2TIMManagerImpl::StoreConferenceIdentity(const V2TIMString& groupID,
                                               Tox_Group_Number conference_number) {
    if (groupID.Empty() || conference_number == UINT32_MAX || !tox_manager_) {
        return false;
    }

    uint8_t conference_id[TOX_CONFERENCE_ID_SIZE];
    if (!tox_manager_->getConferenceId(conference_number, conference_id)) {
        return false;
    }

    std::string conference_id_hex =
        ToxUtil::tox_bytes_to_hex(conference_id, TOX_CONFERENCE_ID_SIZE);
    if (conference_id_hex.empty()) {
        return false;
    }
    // chat_id_to_group_id_ readers (GetGroupIDFromChatId,
    // CanonicalGroupIDForChatIdLocked) look up lowercase hex; an uppercase key
    // made every conference reverse lookup miss.
    std::transform(conference_id_hex.begin(), conference_id_hex.end(),
                   conference_id_hex.begin(), ::tolower);

    if (const char* group_id_cstr = groupID.CString()) {
        SetGroupChatIdInStorage(group_id_cstr, conference_id_hex);
    } else {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        group_id_to_chat_id_[groupID] =
            std::vector<uint8_t>(conference_id,
                                 conference_id + TOX_CONFERENCE_ID_SIZE);
        chat_id_to_group_id_[conference_id_hex] = groupID;
    }
    return true;
}

static_assert(TOX_CONFERENCE_ID_SIZE == TOX_GROUP_CHAT_ID_SIZE,
              "conference ids and NGC chat ids share group_id_to_chat_id_");

bool V2TIMManagerImpl::GetLiveGroupIdentity(Tox_Group_Number group_number,
                                            uint8_t out_id[TOX_GROUP_CHAT_ID_SIZE]) {
    if (group_number == UINT32_MAX || !out_id || !tox_manager_) return false;
    if (IsConferenceMapKey(group_number)) {
        // getConferenceId strips the tag itself.
        return tox_manager_->getConferenceId(group_number, out_id);
    }
    Tox_Err_Group_State_Query err = TOX_ERR_GROUP_STATE_QUERY_OK;
    return tox_manager_->getGroupChatId(group_number, out_id, &err) &&
           err == TOX_ERR_GROUP_STATE_QUERY_OK;
}

Tox_Group_Number V2TIMManagerImpl::RecoverGroupMapping(const std::string& group_id,
                                                       bool allow_unmapped_ngc_bind,
                                                       bool* has_stored_identity) {
    if (has_stored_identity) *has_stored_identity = false;
    if (group_id.empty() || !tox_manager_) return UINT32_MAX;
    const V2TIMString gid(group_id.c_str());

    uint8_t identity[TOX_GROUP_CHAT_ID_SIZE];
    bool has_identity = false;
    std::string stored_type;
    Tox_Group_Number reverse_candidate = UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto mapped = group_id_to_group_number_.find(gid);
        if (mapped != group_id_to_group_number_.end()) {
            auto id_it = group_id_to_chat_id_.find(gid);
            if (has_stored_identity) {
                *has_stored_identity = id_it != group_id_to_chat_id_.end() &&
                                       id_it->second.size() == TOX_GROUP_CHAT_ID_SIZE;
            }
            return mapped->second;
        }
        auto id_it = group_id_to_chat_id_.find(gid);
        if (id_it != group_id_to_chat_id_.end() &&
            id_it->second.size() == TOX_GROUP_CHAT_ID_SIZE) {
            memcpy(identity, id_it->second.data(), TOX_GROUP_CHAT_ID_SIZE);
            has_identity = true;
        }
        auto type_it = group_id_to_type_.find(gid);
        if (type_it != group_id_to_type_.end()) stored_type = type_it->second;
        // A reverse entry without its forward half (the forward map was
        // dropped while the number was still bound to this id).
        for (const auto& entry : group_number_to_group_id_) {
            if (entry.second == gid) {
                reverse_candidate = entry.first;
                break;
            }
        }
    }
    if (has_stored_identity) *has_stored_identity = has_identity;
    const bool conference_type =
        stored_type == "conference" || stored_type == "av_conference";
    const bool ngc_type = !stored_type.empty() && !conference_type;

    Tox_Group_Number key = UINT32_MAX;
    if (has_identity) {
        if (!conference_type) {
            key = tox_manager_->getGroupByChatId(identity);
        }
        if (key == UINT32_MAX && !ngc_type) {
            TOX_ERR_CONFERENCE_BY_ID err_by_id = TOX_ERR_CONFERENCE_BY_ID_OK;
            const uint32_t conference_number =
                tox_manager_->getConferenceById(identity, &err_by_id);
            if (err_by_id == TOX_ERR_CONFERENCE_BY_ID_OK &&
                conference_number != UINT32_MAX) {
                key = ConferenceMapKey(conference_number);
            }
        }
    }

    // The reverse entry is only trusted when it names a live group of a kind
    // the stored label allows (and, when both are readable, the same identity).
    if (key == UINT32_MAX && reverse_candidate != UINT32_MAX &&
        !(conference_type && !IsConferenceMapKey(reverse_candidate)) &&
        !(ngc_type && IsConferenceMapKey(reverse_candidate))) {
        bool live = false;
        if (IsConferenceMapKey(reverse_candidate)) {
            const size_t count = tox_manager_->getConferenceListSize();
            std::vector<uint32_t> list(count);
            if (count > 0) tox_manager_->getConferenceList(list.data(), count);
            live = std::find(list.begin(), list.end(),
                             ConferenceNumberFromKey(reverse_candidate)) != list.end();
        } else {
            const size_t count = tox_manager_->getGroupListSize();
            std::vector<Tox_Group_Number> list(count);
            if (count > 0) tox_manager_->getGroupList(list.data(), count);
            live = std::find(list.begin(), list.end(), reverse_candidate) != list.end();
        }
        uint8_t live_identity[TOX_GROUP_CHAT_ID_SIZE];
        if (live && has_identity &&
            GetLiveGroupIdentity(reverse_candidate, live_identity) &&
            memcmp(live_identity, identity, TOX_GROUP_CHAT_ID_SIZE) != 0) {
            live = false;
        }
        if (live) key = reverse_candidate;
    }

    // Last resort (legacy): an identity-less NGC groupID adopts the first NGC
    // group nobody has claimed. Never for a conference-labelled id: that would
    // bind an unrelated NGC group and persist its chat id as the identity.
    if (key == UINT32_MAX && allow_unmapped_ngc_bind && !has_identity &&
        !conference_type) {
        const size_t group_count = tox_manager_->getGroupListSize();
        if (group_count > 0) {
            std::vector<Tox_Group_Number> group_list(group_count);
            tox_manager_->getGroupList(group_list.data(), group_count);
            // TODO(fallback2-misbind, codex 2026-06-04 P2): only auto-bind when
            // EXACTLY ONE unmapped candidate exists; first-unmapped-wins can
            // persist a wrong chat_id/group mapping when 2+ groups are unmapped.
            std::lock_guard<std::mutex> lock(mutex_);
            for (Tox_Group_Number group_num : group_list) {
                if (group_number_to_group_id_.count(group_num) != 0) continue;
                uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
                Tox_Err_Group_State_Query err_chat_id = TOX_ERR_GROUP_STATE_QUERY_OK;
                if (!tox_manager_->getGroupChatId(group_num, chat_id, &err_chat_id) ||
                    err_chat_id != TOX_ERR_GROUP_STATE_QUERY_OK) {
                    continue;
                }
                const std::string chat_id_hex = ToxUtil::tox_bytes_to_hex(chat_id, TOX_GROUP_CHAT_ID_SIZE);
                std::string chat_id_lower = chat_id_hex;
                std::transform(chat_id_lower.begin(), chat_id_lower.end(),
                               chat_id_lower.begin(), ::tolower);
                // *Locked variant: mutex_ is held (non-recursive).
                SetGroupChatIdInStorageLocked(group_id, chat_id_lower);
                group_id_to_group_number_[gid] = group_num;
                group_number_to_group_id_[group_num] = gid;
                chat_id_to_group_id_[chat_id_lower] = gid;
                V2TIM_LOG(kInfo, "RecoverGroupMapping: bound unmapped NGC group_number={} to identity-less groupID={}",
                          group_num, group_id);
                return group_num;
            }
        }
        return UINT32_MAX;
    }

    if (key == UINT32_MAX) return UINT32_MAX;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        group_id_to_group_number_[gid] = key;
        group_number_to_group_id_[key] = gid;
        if (has_identity) {
            // chat_id_to_group_id_ is keyed by LOWERCASE hex (its readers,
            // GetGroupIDFromChatId / CanonicalGroupIDForChatIdLocked, format so).
            std::string identity_hex =
                ToxUtil::tox_bytes_to_hex(identity, TOX_GROUP_CHAT_ID_SIZE);
            std::transform(identity_hex.begin(), identity_hex.end(),
                           identity_hex.begin(), ::tolower);
            chat_id_to_group_id_[identity_hex] = gid;
        }
    }
    V2TIM_LOG(kInfo, "RecoverGroupMapping: rebuilt groupID={} <-> key={} ({})",
              group_id, key, IsConferenceMapKey(key) ? "conference" : "ngc");
    return key;
}

#ifdef BUILD_TOXAV
bool V2TIMManagerImpl::GetGroupIDFromGroupNumber(Tox_Group_Number group_number, V2TIMString& out_group_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_number_to_group_id_.find(group_number);
    if (it == group_number_to_group_id_.end()) {
        return false;
    }
    out_group_id = it->second;
    return true;
}

void V2TIMManagerImpl::SetAVConferenceAudioCallback(
    AVConferenceAudioCallback callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    av_conference_audio_callback_ = std::move(callback);
}

void V2TIMManagerImpl::ClearAVConferenceAudioCallback() {
    std::lock_guard<std::mutex> lock(mutex_);
    av_conference_audio_callback_ = nullptr;
    enabled_av_conferences_.clear();
    muted_av_conferences_.clear();
    av_conference_audio_queue_.ClearAll();
}

void V2TIMManagerImpl::EnqueueAVConferenceAudioFrame(
    const char* group_id, uint32_t conference_number,
    uint32_t peer_number, const int16_t* pcm, size_t sample_count,
    uint8_t channels, uint32_t sampling_rate) {
    if (group_id == nullptr || group_id[0] == '\0' || pcm == nullptr ||
        sample_count == 0 || (channels != 1 && channels != 2)) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!av_conference_audio_callback_ ||
            enabled_av_conferences_.find(conference_number) ==
                enabled_av_conferences_.end() ||
            muted_av_conferences_.find(conference_number) !=
            muted_av_conferences_.end()) {
            return;
        }
    }
    if (sample_count > std::numeric_limits<size_t>::max() / channels) {
        return;
    }
    const size_t total_samples = sample_count * channels;
    tim2tox::AVConferenceAudioFrame frame;
    frame.group_id = group_id;
    frame.conference_number = conference_number;
    frame.peer_number = peer_number;
    frame.pcm.assign(pcm, pcm + total_samples);
    frame.sample_count = sample_count;
    frame.channels = channels;
    frame.sampling_rate = sampling_rate;
    av_conference_audio_queue_.Enqueue(std::move(frame));
}

void V2TIMManagerImpl::DrainPendingAVConferenceAudioFrames() {
    std::vector<tim2tox::AVConferenceAudioFrame> frames =
        av_conference_audio_queue_.Drain();
    if (frames.empty()) return;

    AVConferenceAudioCallback callback;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        callback = av_conference_audio_callback_;
    }
    if (!callback) return;

    for (const auto& frame : frames) {
        if (frame.pcm.empty()) continue;
        callback(frame.group_id.c_str(), frame.conference_number,
                 frame.peer_number, frame.pcm.data(), frame.sample_count,
                 frame.channels, frame.sampling_rate);
    }
}

bool V2TIMManagerImpl::SendAVConferenceAudioFrame(
    const V2TIMString& group_id, const int16_t* pcm, size_t sample_count,
    uint8_t channels, uint32_t sampling_rate) {
    Tox_Group_Number conference_number;
    if (!GetGroupNumberFromID(group_id, conference_number) ||
        !IsConferenceMapKey(conference_number)) {
        return false;  // unknown, or an NGC group (never drive group AV on it)
    }
    // AV bookkeeping (enabled/muted sets, received frames) uses raw numbers.
    conference_number = ConferenceNumberFromKey(conference_number);
    ToxAVManager* av_manager = GetToxAVManager();
    return av_manager != nullptr && av_manager->sendConferenceAudioFrame(
        conference_number, pcm, sample_count, channels, sampling_rate);
}

bool V2TIMManagerImpl::EnableAVConferenceAudio(
    const V2TIMString& group_id) {
    Tox_Group_Number conference_number;
    if (!GetGroupNumberFromID(group_id, conference_number) ||
        !IsConferenceMapKey(conference_number)) {
        return false;  // unknown, or an NGC group (never drive group AV on it)
    }
    // AV bookkeeping (enabled/muted sets, received frames) uses raw numbers.
    conference_number = ConferenceNumberFromKey(conference_number);
    ToxAVManager* av_manager = GetToxAVManager();
    if (av_manager == nullptr) return false;
    if (!av_manager->setConferenceAudioCallbackContext(
            HandleAVConferenceAudio, this)) {
        return false;
    }
    if (av_manager->isConferenceAudioEnabled(conference_number)) {
        std::lock_guard<std::mutex> lock(mutex_);
        enabled_av_conferences_.insert(conference_number);
        return true;
    }
    const bool result = av_manager->enableConferenceAudio(conference_number);
    if (result) {
        std::lock_guard<std::mutex> lock(mutex_);
        enabled_av_conferences_.insert(conference_number);
    }
    return result;
}

bool V2TIMManagerImpl::DisableAVConferenceAudio(
    const V2TIMString& group_id) {
    Tox_Group_Number conference_number;
    if (!GetGroupNumberFromID(group_id, conference_number) ||
        !IsConferenceMapKey(conference_number)) {
        return false;  // unknown, or an NGC group (never drive group AV on it)
    }
    // AV bookkeeping (enabled/muted sets, received frames) uses raw numbers.
    conference_number = ConferenceNumberFromKey(conference_number);
    ToxAVManager* av_manager = GetToxAVManager();
    if (av_manager == nullptr) return false;
    const bool result = av_manager->isConferenceAudioEnabled(conference_number)
                            ? av_manager->disableConferenceAudio(conference_number)
                            : true;
    if (result) {
        std::lock_guard<std::mutex> lock(mutex_);
        enabled_av_conferences_.erase(conference_number);
        muted_av_conferences_.erase(conference_number);
        av_conference_audio_queue_.ClearGroup(group_id.CString());
    }
    return result;
}

int V2TIMManagerImpl::QueryAVConferenceAudioEnabled(
    const V2TIMString& group_id) const {
    Tox_Group_Number conference_number;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = group_id_to_group_number_.find(group_id);
        if (it == group_id_to_group_number_.end() ||
            !IsConferenceMapKey(it->second)) {
            return -1;  // unknown / not a conference: nothing to answer
        }
        conference_number = ConferenceNumberFromKey(it->second);
    }
    ToxAVManager* av_manager = const_cast<V2TIMManagerImpl*>(this)->GetToxAVManager();
    if (av_manager == nullptr) return -1;
    return av_manager->isConferenceAudioEnabled(conference_number) ? 1 : 0;
}

bool V2TIMManagerImpl::IsAVConferenceAudioEnabled(
    const V2TIMString& group_id) const {
    Tox_Group_Number conference_number;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = group_id_to_group_number_.find(group_id);
        if (it == group_id_to_group_number_.end() ||
            !IsConferenceMapKey(it->second)) {
            return false;
        }
        conference_number = ConferenceNumberFromKey(it->second);
    }
    ToxAVManager* av_manager = const_cast<V2TIMManagerImpl*>(this)->GetToxAVManager();
    return av_manager != nullptr &&
           av_manager->isConferenceAudioEnabled(conference_number);
}

bool V2TIMManagerImpl::MuteAVConferenceAudio(
    const V2TIMString& group_id, bool mute) {
    Tox_Group_Number conference_number;
    if (!GetGroupNumberFromID(group_id, conference_number) ||
        !IsConferenceMapKey(conference_number)) {
        return false;  // unknown, or an NGC group (never drive group AV on it)
    }
    // AV bookkeeping (enabled/muted sets, received frames) uses raw numbers.
    conference_number = ConferenceNumberFromKey(conference_number);
    std::lock_guard<std::mutex> lock(mutex_);
    if (mute) {
        muted_av_conferences_.insert(conference_number);
        av_conference_audio_queue_.ClearGroup(group_id.CString());
    } else {
        muted_av_conferences_.erase(conference_number);
    }
    return true;
}
#endif

void V2TIMManagerImpl::ClearPendingAVConferenceAudioFrames() {
    av_conference_audio_queue_.ClearAll();
}

// Helper method to notify group listeners about member kicked
void V2TIMManagerImpl::NotifyGroupMemberKicked(const V2TIMString& groupID, const V2TIMGroupMemberInfoVector& memberList) {
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    // Get current user as operator
    V2TIMGroupMemberInfo opUser;
    opUser.userID = GetLoginUser();
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnMemberKicked(groupID, opUser, memberList);
        }
    }
}

// Tox group callback handlers
// HandleGroupMessageGroup is already defined above at line 1878

void V2TIMManagerImpl::HandleGroupTopic(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* topic, size_t length) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            V2TIM_LOG(kWarning, "HandleGroupTopic: Unknown group_number {}", group_number);
            return;
        }
        groupID = it->second;
    }
    
    std::string topic_value(reinterpret_cast<const char*>(topic), length);
    // The topic is the group's announcement (see V2TIMGroupManagerImpl::
    // SetGroupInfo). Announcing it as a NAME change let any member, from any
    // client, retitle the group for every toxee member.
    V2TIMGroupManager* grp_mgr = GetGroupManager();
    if (grp_mgr) {
        V2TIMGroupManagerImpl* grp_impl = static_cast<V2TIMGroupManagerImpl*>(grp_mgr);
        grp_impl->UpdateGroupInfoFromTopic(groupID, topic_value);
    }
    
    // Notify group listeners about the announcement change
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    V2TIMGroupChangeInfo changeInfo;
    changeInfo.type = V2TIM_GROUP_INFO_CHANGE_TYPE_NOTIFICATION;
    changeInfo.value = topic_value;
    
    V2TIMGroupChangeInfoVector changeList;
    changeList.PushBack(changeInfo);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnGroupInfoChanged(groupID, changeList);
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerNameGroup(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* name, size_t length) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }
    
    // Get peer public key to find userID
    Tox* tox = GetToxManager()->getTox();
    if (!tox) return;
    
    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
        err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }
    
    std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
    
    // Notify group listeners about member info change
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    V2TIMGroupMemberChangeInfo changeInfo;
    changeInfo.userID = userID;
    // Note: V2TIMGroupMemberChangeInfo doesn't have nickName field, only userID and muteTime
    
    V2TIMGroupMemberChangeInfoVector changeList;
    changeList.PushBack(changeInfo);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnMemberInfoChanged(groupID, changeList);
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerJoin(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id) {
    // Log which instance is handling peer join (for multi-instance debugging)
    // Note: GetCurrentInstanceId is already declared at file scope (line 27)
    int64_t current_instance_id = GetCurrentInstanceId();
    static_cast<void>(0);
    static_cast<void>(0);
    
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] ENTRY - instance_id=%lld, group_number=%u, peer_id=%u", 
              (long long)current_instance_id, group_number, peer_id);
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            static_cast<void>(0);
            static_cast<void>(0);
            V2TIM_LOG(kWarning, "[HandleGroupPeerJoin] Group_number=%u not found in mapping (size=%zu), cannot notify listeners", 
                     group_number, group_number_to_group_id_.size());
            // Print all mappings for debugging
            static_cast<void>(0);
            for (const auto& pair : group_number_to_group_id_) {
                static_cast<void>(0);
                V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Mapping: group_number=%u -> groupID=%s", 
                         pair.first, pair.second.CString());
            }
            static_cast<void>(0);
            return;
        }
        groupID = it->second;
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Found mapping: group_number=%u -> groupID=%s", group_number, groupID.CString());
    }
    
    // Get peer public key to find userID
    Tox* tox = GetToxManager()->getTox();
    if (!tox) {
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kError, "[HandleGroupPeerJoin] Tox instance is null");
        return;
    }
    
    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
        err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
        static_cast<void>(0);
        static_cast<void>(0);
        V2TIM_LOG(kError, "[HandleGroupPeerJoin] Failed to get peer public key: group_number=%u, peer_id=%u, err=%d", 
                 group_number, peer_id, err_key);
        return;
    }
    
    std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Peer userID=%s (length=%zu)", userID.c_str(), userID.length());
    std::string key_lower_for_identity = userID;
    std::transform(key_lower_for_identity.begin(), key_lower_for_identity.end(),
                   key_lower_for_identity.begin(), ::tolower);
    // Cache (group_number, public_key_hex) -> peer_id for SendGroupPrivateTextMessage peer lookup
    {
        std::string key_lower = userID;
        std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(), ::tolower);
        std::lock_guard<std::mutex> lock(mutex_);
        group_peer_id_cache_[group_number][key_lower] = peer_id;
    }
    MatchGroupIdentityDigests(group_number, key_lower_for_identity);

    // Get peer name (buffer may not be NUL-terminated; use strnlen to avoid OOB read)
    uint8_t name_buffer[TOX_MAX_NAME_LENGTH + 1] = {};
    std::string peer_name;
    Tox_Err_Group_Peer_Query err_name;
    if (GetToxManager()->getGroupPeerName(group_number, peer_id, name_buffer, TOX_MAX_NAME_LENGTH, &err_name) &&
        err_name == TOX_ERR_GROUP_PEER_QUERY_OK) {
        size_t name_len = strnlen(reinterpret_cast<const char*>(name_buffer), TOX_MAX_NAME_LENGTH);
        peer_name = std::string(reinterpret_cast<const char*>(name_buffer), name_len);
        static_cast<void>(0);
        static_cast<void>(0);
    } else {
        static_cast<void>(0);
        static_cast<void>(0);
    }
    
    // Get peer role
    Tox_Group_Role peer_role = tox_group_peer_get_role(tox, group_number, peer_id, &err_key);
    static_cast<void>(0);
    static_cast<void>(0);
    
    // Notify group listeners about member enter
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (group_listeners_.size() > 0) {
            static_cast<void>(0);
        } else {
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
            static_cast<void>(0);
        }
        static_cast<void>(0);
        static_cast<void>(0);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
        static_cast<void>(0);
        static_cast<void>(0);
        static_cast<void>(0);
    }
    
    // Build member list for OnMemberEnter callback
    V2TIMGroupMemberFullInfo memberInfo;
    memberInfo.userID = V2TIMString(userID.c_str());
    memberInfo.nickName = peer_name.empty() ? V2TIMString(userID.c_str()) : V2TIMString(peer_name.c_str());
    
    // Map Tox role to V2TIM role
    switch (peer_role) {
        case TOX_GROUP_ROLE_FOUNDER:
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_SUPER;
            break;
        case TOX_GROUP_ROLE_MODERATOR:
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_ADMIN;
            break;
        case TOX_GROUP_ROLE_USER:
        case TOX_GROUP_ROLE_OBSERVER:
        default:
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_MEMBER;
            break;
    }
    
    V2TIMGroupMemberInfoVector memberList;
    V2TIMGroupMemberInfo memberInfoBasic;
    memberInfoBasic.userID = memberInfo.userID;
    // Note: V2TIMGroupMemberInfo doesn't have role or muteUntil fields
    memberList.PushBack(memberInfoBasic);
    
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Notifying %zu listeners about member enter", listeners_copy.size());
    
    if (listeners_copy.empty()) {
        static_cast<void>(0);
        static_cast<void>(0);
        static_cast<void>(0);
        static_cast<void>(0);
    } else {
        static_cast<void>(0);
        static_cast<void>(0);
    }
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            static_cast<void>(0);
            static_cast<void>(0);
            V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] Calling OnMemberEnter for listener=%p, groupID=%s, memberCount=%zu", 
                     listener, groupID.CString(), memberList.Size());
            listener->OnMemberEnter(groupID, memberList);
        }
    }
    
    static_cast<void>(0);
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "[HandleGroupPeerJoin] EXIT - Completed notification");
}

void V2TIMManagerImpl::HandleGroupPeerExit(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, Tox_Group_Exit_Type exit_type, const uint8_t* name, size_t name_length) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }
    
    Tox* tox = GetToxManager()->getTox();
    if (!tox) return;

    // Resolve the exiting peer's key from OUR peer-id cache, and drop the entry.
    // toxcore cannot answer any more: peer_delete() removes the peer from the
    // group array BEFORE it invokes this callback, so
    // tox_group_peer_get_public_key(peer_id) fails for every exit. Asking it
    // (as this used to) returned early on every exit — no OnMemberLeave, and
    // the cache entry stayed. toxcore hands the lowest free peer_id to the next
    // joiner, so a stale entry then resolved the DEPARTED member's key to the
    // NEWCOMER's peer_id (kick / group private message hit the wrong person).
    std::string userID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto cache_it = group_peer_id_cache_.find(group_number);
        if (cache_it != group_peer_id_cache_.end()) {
            for (auto peer_it = cache_it->second.begin(); peer_it != cache_it->second.end();) {
                if (peer_it->second == peer_id) {
                    if (userID.empty()) userID = peer_it->first;
                    peer_it = cache_it->second.erase(peer_it);
                } else {
                    ++peer_it;
                }
            }
        }
    }
    // Cache keys are lower-case; member events (HandleGroupPeerJoin) publish the
    // upper-case hex of ToxUtil::tox_bytes_to_hex. Publish the same spelling so
    // the leave matches the row the enter created.
    std::transform(userID.begin(), userID.end(), userID.begin(), ::toupper);
    Tox_Err_Group_Peer_Query err_key = TOX_ERR_GROUP_PEER_QUERY_PEER_NOT_FOUND;
    if (userID.empty()) {
        // Never cached (exit raced ahead of the join/message that caches it).
        uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
        if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
            err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
            V2TIM_LOG(kWarning, "HandleGroupPeerExit: peer_id={} of group {} has no cached key; cannot attribute the exit",
                      peer_id, groupID.CString());
            return;
        }
        userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
    }
    {
        // MM-6 lifecycle: the member left this group's peer set, so its index
        // slot and every challenge about it are dead. The PROOF survives only
        // our own disconnect: then the member did not leave, and its key is
        // still its own when we rejoin.
        const std::string key_lower = LowerHex(userID);
        std::lock_guard<std::mutex> lock(mutex_);
        EraseIndexedGroupMemberLocked(group_number, key_lower);
        for (auto it = pending_identity_challenges_.begin(); it != pending_identity_challenges_.end();) {
            it = it->second.group_number == group_number && it->second.member_key == key_lower
                     ? pending_identity_challenges_.erase(it)
                     : std::next(it);
        }
        if (exit_type != TOX_GROUP_EXIT_TYPE_SELF_DISCONNECTED) member_key_to_friend_.erase(key_lower);
    }

    if (exit_type == TOX_GROUP_EXIT_TYPE_SELF_DISCONNECTED) {
        // WE dropped off the group; toxcore reports every peer this way. They
        // did not leave, so there is no member event to publish — the cache
        // prune above is all that is needed (peer ids are re-issued on rejoin).
        return;
    }

    // Notify group listeners about member leave
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }

    V2TIMGroupMemberFullInfo memberInfo;
    memberInfo.userID = userID;
    if (name_length > 0) {
        memberInfo.nickName = std::string(reinterpret_cast<const char*>(name), name_length);
    }
    
    V2TIMGroupMemberInfo memberInfoBasic;
    memberInfoBasic.userID = memberInfo.userID;
    // Note: V2TIMGroupMemberInfo doesn't have role or muteUntil fields
    
    if (exit_type == TOX_GROUP_EXIT_TYPE_KICK) {
        // A moderator removed this member. HandleGroupModeration defers
        // other-peer kicks to this callback; the moderator's identity is not
        // part of the exit event, so opUser stays empty.
        V2TIMGroupMemberInfoVector kickedList;
        kickedList.PushBack(memberInfoBasic);
        for (V2TIMGroupListener* listener : listeners_copy) {
            if (listener) {
                listener->OnMemberKicked(groupID, V2TIMGroupMemberInfo(), kickedList);
            }
        }
        return;
    }

    // Normal member leave notification
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnMemberLeave(groupID, memberInfoBasic);
        }
    }
}

std::vector<V2TIMManagerImpl::PendingGroupInviteInfo> V2TIMManagerImpl::GetPendingGroupInvites() {
    std::vector<PendingGroupInviteInfo> out;
    std::lock_guard<std::mutex> lock(mutex_);
    out.reserve(pending_group_invites_.size());
    for (const auto& entry : pending_group_invites_) {
        // group_number set => already accepted (auto-accept / in-flight join);
        // that entry only survives as a lookup alias, not as a prompt.
        if (entry.second.group_number != UINT32_MAX) continue;
        out.push_back({entry.first.CString(), entry.second.inviter_userID, entry.second.kind,
                       entry.second.group_name, entry.second.received_ms, entry.second.cookie});
    }
    std::sort(out.begin(), out.end(), [](const PendingGroupInviteInfo& a, const PendingGroupInviteInfo& b) {
        return a.received_ms != b.received_ms ? a.received_ms < b.received_ms : a.id < b.id;
    });
    return out;
}

V2TIMString V2TIMManagerImpl::StorePendingInvite(const V2TIMString& inviteID, PendingInvite&& inv) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto& entry : pending_group_invites_) {
        if (entry.second.group_number == UINT32_MAX &&
            entry.second.friend_number == inv.friend_number &&
            entry.second.kind == inv.kind &&
            entry.second.cookie == inv.cookie) {
            entry.second.received_ms = inv.received_ms;
            if (!inv.group_name.empty()) entry.second.group_name = inv.group_name;
            return entry.first;
        }
    }
    pending_group_invites_[inviteID] = std::move(inv);
    return inviteID;
}

bool V2TIMManagerImpl::RestorePendingGroupInvite(const PendingGroupInviteInfo& invite) {
    if (invite.id.empty() || invite.cookie.empty()) return false;
    // Runs on the restore path and from the FFI surface: pinned.
    const ToxSessionGuard session = AcquireToxSession();
    Tox* tox = session.tox();
    if (!tox) return false;
    uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
    if (!ToxUtil::tox_hex_to_bytes(invite.inviter_userID.c_str(), invite.inviter_userID.size(),
                                   inviter_pubkey, TOX_PUBLIC_KEY_SIZE)) {
        return false;
    }
    Tox_Err_Friend_By_Public_Key err_friend;
    const uint32_t friend_number = tox_friend_by_public_key(tox, inviter_pubkey, &err_friend);
    if (err_friend != TOX_ERR_FRIEND_BY_PUBLIC_KEY_OK) {
        return false; // no longer a friend: the cookie can never be redeemed
    }
    PendingInvite inv;
    inv.friend_number = friend_number;
    inv.cookie = invite.cookie;
    inv.inviter_userID = invite.inviter_userID;
    inv.kind = invite.kind;
    inv.group_name = invite.group_name;
    inv.received_ms = invite.received_ms;
    StorePendingInvite(V2TIMString(invite.id.c_str()), std::move(inv));
    return true;
}

bool V2TIMManagerImpl::RejectPendingGroupInvite(const V2TIMString& inviteID) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = pending_group_invites_.find(inviteID);
    if (it == pending_group_invites_.end() || it->second.group_number != UINT32_MAX) {
        return false;
    }
    pending_group_invites_.erase(it);
    return true;
}

void V2TIMManagerImpl::ErasePeerIdCacheEntry(Tox_Group_Number group_number, const std::string& public_key_hex) {
    std::string key_lower = public_key_hex;
    std::transform(key_lower.begin(), key_lower.end(), key_lower.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    std::lock_guard<std::mutex> lock(mutex_);
    auto cache_it = group_peer_id_cache_.find(group_number);
    if (cache_it != group_peer_id_cache_.end()) {
        cache_it->second.erase(key_lower);
    }
}

void V2TIMManagerImpl::EraseGroupLocalState(const V2TIMString& groupID) {
    // Mirrors the inline map cleanup in QuitGroup (group_id_to_group_number_ /
    // group_number_to_group_id_ / chat-id maps) and additionally prunes the
    // peer-id cache GetGroupMemberList reads. Non-Tox state only — the caller
    // (e.g. a self-kick) has already lost the Tox group connection, so there is
    // no tox_group_leave to make.
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = group_id_to_group_number_.find(groupID);
    if (it != group_id_to_group_number_.end()) {
        const Tox_Group_Number gnum = it->second;
        group_id_to_group_number_.erase(it);
        group_number_to_group_id_.erase(gnum);
        group_peer_id_cache_.erase(gnum);
        fresh_group_joins_.erase(gnum);
        accepted_invites_.erase(gnum);
        // Dart forgets a left/refused group's identity; so must this record,
        // or a same-session rejoin under the same id is never re-persisted.
        dart_known_chat_id_.erase(groupID.CString());
        dart_known_type_.erase(groupID.CString());
        V2TIM_LOG(kInfo, "EraseGroupLocalState: removed group_number={} maps + peer cache for group {}", gnum, groupID.CString());
    }
    auto chat_it = group_id_to_chat_id_.find(groupID);
    if (chat_it != group_id_to_chat_id_.end()) {
        std::ostringstream oss;
        for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
            oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_it->second[i]);
        }
        const std::string chat_id_hex = oss.str();
        group_id_to_chat_id_.erase(chat_it);
        chat_id_to_group_id_.erase(chat_id_hex);
        V2TIM_LOG(kInfo, "EraseGroupLocalState: removed chat_id maps (chat_id_hex={}) for group {}", chat_id_hex, groupID.CString());
    }
}

void V2TIMManagerImpl::HandleGroupModeration(Tox_Group_Number group_number, Tox_Group_Peer_Number source_peer_id, Tox_Group_Peer_Number target_peer_id, Tox_Group_Mod_Event mod_type) {
    V2TIM_LOG(kInfo, "[HandleGroupModeration] ENTRY instance_id={} group_number={} source_peer={} target_peer={} mod_type={}",
              (long long)GetInstanceIdFromManager(this), group_number, source_peer_id, target_peer_id, static_cast<int>(mod_type));
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }

    Tox* tox = GetToxManager()->getTox();
    if (!tox) return;

    // Resolve whether this moderation targets our own peer FIRST. The self peer is
    // not reachable through tox_group_peer_get_public_key — it resolves peers via
    // their GC_Connection, and a peer has no connection to itself, so the peer API
    // returns PEER_NOT_FOUND for the self peer_id. When the founder grants/revokes
    // OUR role, the moderation event arrives with target_peer_id == self_peer_id, so
    // we must take the self public-key path. Doing the self check before the key
    // lookup is what lets the "my role changed" notification below actually fire;
    // previously the early return on the failed peer lookup swallowed it (the cause
    // of scenario_group_state_changes_test's role-change timeout).
    Tox_Err_Group_Self_Query err_self;
    Tox_Group_Peer_Number self_peer_id = tox_group_self_get_peer_id(tox, group_number, &err_self);
    const bool self_is_target =
        (err_self == TOX_ERR_GROUP_SELF_QUERY_OK && target_peer_id == self_peer_id);

    // Get target peer public key (self vs. other-peer path).
    uint8_t target_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key = TOX_ERR_GROUP_PEER_QUERY_OK;
    bool got_target_key = false;
    if (self_is_target) {
        Tox_Err_Group_Self_Query err_self_key;
        got_target_key = tox_group_self_get_public_key(tox, group_number, target_pubkey, &err_self_key)
                         && err_self_key == TOX_ERR_GROUP_SELF_QUERY_OK;
    } else {
        got_target_key = GetToxManager()->getGroupPeerPublicKey(group_number, target_peer_id, target_pubkey, &err_key)
                         && err_key == TOX_ERR_GROUP_PEER_QUERY_OK;
    }
    if (!got_target_key) {
        return;
    }

    std::string target_userID = ToxUtil::tox_bytes_to_hex(target_pubkey, TOX_PUBLIC_KEY_SIZE);
    if (self_is_target) {
        // Our own row in every member list (GetGroupMemberList /
        // GetGroupMembersInfo) is keyed by the long-term public key, not by the
        // per-group key above. Announcing the per-group key meant no UI ever
        // matched "my role changed": a promoted user got no admin actions and a
        // demoted one kept them.
        uint8_t self_long_term_key[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(tox, self_long_term_key);
        target_userID = ToxUtil::tox_bytes_to_hex(self_long_term_key, TOX_PUBLIC_KEY_SIZE);
    }

    // Get target peer role after moderation (for future use if needed). Only meaningful
    // for non-self peers; the self role would use tox_group_self_get_role.
    if (!self_is_target) {
        Tox_Group_Role new_role = tox_group_peer_get_role(tox, group_number, target_peer_id, &err_key);
        (void)new_role; // Suppress unused variable warning
    }

    // Notify group listeners based on moderation type
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }

    // When this client is the target of the moderation (e.g. role changed by someone else),
    // notify listeners with OnMemberInfoChanged so the app sees "my role changed".
    // EXCLUDE KICK: being kicked is a removal, not an info change — firing
    // OnMemberInfoChanged for a self-kick would spuriously look like "my role
    // changed" an instant before the group is removed (the KICK case below
    // handles self-removal).
    if (self_is_target && mod_type != TOX_GROUP_MOD_EVENT_KICK && !listeners_copy.empty()) {
        V2TIMGroupMemberChangeInfo changeInfo;
        changeInfo.userID = V2TIMString(target_userID.c_str());
        changeInfo.muteTime = 0;
        V2TIMGroupMemberChangeInfoVector changeList;
        changeList.PushBack(changeInfo);
        for (V2TIMGroupListener* listener : listeners_copy) {
            if (listener) {
                listener->OnMemberInfoChanged(groupID, changeList);
            }
        }
    }
    
    V2TIMGroupMemberFullInfo memberInfo;
    memberInfo.userID = target_userID;
    
    switch (mod_type) {
        case TOX_GROUP_MOD_EVENT_KICK:
            if (self_is_target) {
                // WE were kicked. Tox does NOT fire group_peer_exit for our own
                // removal (that callback is documented for peers OTHER than self),
                // and the Platform path owns knownGroups — so nothing would drop
                // the group otherwise (S37 A3). (1) Erase native local group state
                // so stale lookups (GetGroupMemberList, chat-id maps) don't persist
                // until restart, then (2) drive the SAME Dart cleanup the
                // voluntary-quit path uses: DartNotifyGroupQuit ->
                // "groupQuitNotification" -> Tim2ToxSdkPlatform ->
                // FfiChatService.cleanupGroupState (removes from _knownGroups, adds
                // to _quitGroups, clears history). groupID is a local copy, so
                // erasing the maps does not invalidate it.
                V2TIM_LOG(kInfo, "HandleGroupModeration: SELF was kicked from group {}; erasing local state + notifying Dart cleanup", groupID.CString());
                EraseGroupLocalState(groupID);
                DartNotifyGroupKicked(groupID.CString(), GetInstanceIdFromManager(this), GetSessionEpoch());
                // toxcore keeps a kicked group around as CS_DISCONNECTED (and
                // writes it to the savefile). While it exists,
                // group_not_added() is false for its chat_id, so Messenger
                // DROPS every later invite to that group before any callback
                // fires — a kicked member could never be re-invited, not even
                // after a restart. Delete it, but not from inside this
                // callback: handle_gc_kick_peer is still using the chat. The
                // event thread runs queued tasks between iterations.
                const Tox_Group_Number kicked_group_number = group_number;
                PostToEventThread([this, kicked_group_number]() {
                    if (!tox_manager_) return;
                    {
                        // The slot cannot be re-issued while the zombie holds
                        // it; a mapping here means something else already
                        // claimed the number, so leave it alone.
                        std::lock_guard<std::mutex> lock(mutex_);
                        if (group_number_to_group_id_.find(kicked_group_number) != group_number_to_group_id_.end()) {
                            return;
                        }
                    }
                    Tox_Err_Group_Leave err_leave;
                    tox_manager_->deleteGroup(kicked_group_number, &err_leave);
                    V2TIM_LOG(kInfo, "HandleGroupModeration: removed kicked group_number={} from toxcore (err={})",
                              kicked_group_number, static_cast<int>(err_leave));
                    SaveToxProfile();
                });
            }
            // Other-peer kicks are handled by HandleGroupPeerExit.
            break;
        case TOX_GROUP_MOD_EVENT_MODERATOR:
            // Grant administrator
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_ADMIN;
            {
                V2TIMGroupMemberInfo memberInfoBasic;
                memberInfoBasic.userID = memberInfo.userID;
                V2TIMGroupMemberInfoVector memberList;
                memberList.PushBack(memberInfoBasic);
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        listener->OnGrantAdministrator(groupID, V2TIMGroupMemberInfo(), memberList);
                    }
                }
            }
            break;
        case TOX_GROUP_MOD_EVENT_USER:
            // Revoke administrator
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_MEMBER;
            {
                V2TIMGroupMemberInfo memberInfoBasic;
                memberInfoBasic.userID = memberInfo.userID;
                V2TIMGroupMemberInfoVector memberList;
                memberList.PushBack(memberInfoBasic);
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        listener->OnRevokeAdministrator(groupID, V2TIMGroupMemberInfo(), memberList);
                    }
                }
            }
            break;
        case TOX_GROUP_MOD_EVENT_OBSERVER:
            // Similar to USER role
            memberInfo.role = V2TIM_GROUP_MEMBER_ROLE_MEMBER;
            {
                V2TIMGroupMemberInfo memberInfoBasic;
                memberInfoBasic.userID = memberInfo.userID;
                V2TIMGroupMemberInfoVector memberList;
                memberList.PushBack(memberInfoBasic);
                for (V2TIMGroupListener* listener : listeners_copy) {
                    if (listener) {
                        listener->OnRevokeAdministrator(groupID, V2TIMGroupMemberInfo(), memberList);
                    }
                }
            }
            break;
        default:
            break;
    }
}

void V2TIMManagerImpl::HandleGroupSelfJoin(Tox_Group_Number group_number) {
    static_cast<void>(0);
    static_cast<void>(0);
    static_cast<void>(0);
    // Get current instance ID for debugging
    // Note: GetCurrentInstanceId and GetInstanceIdFromManager are already declared at file scope (lines 27-28)
    int64_t current_instance_id = GetCurrentInstanceId();
    static_cast<void>(0);
    // Get instance ID from manager
    int64_t this_instance_id = GetInstanceIdFromManager(this);
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIM_LOG(kInfo, "HandleGroupSelfJoin: ENTRY - group_number=%u, this=%p, current_instance_id=%lld, this_instance_id=%lld", 
              group_number, (void*)this, (long long)current_instance_id, (long long)this_instance_id);
    V2TIMString groupID;
    bool found_in_mapping = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it != group_number_to_group_id_.end()) {
            groupID = it->second;
            found_in_mapping = true;
            static_cast<void>(0);
            static_cast<void>(0);
            V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Group_number=%u already mapped to groupID=%s", group_number, groupID.CString());
        } else {
            static_cast<void>(0);
            static_cast<void>(0);
        }
    }

    // A conference key is identified by its conference id; the NGC chat-id
    // canonicalisation below must never run on it (a tagged key handed to
    // tox_group_get_chat_id only fails, leaving the identity unpersisted).
    const bool is_conference_key = IsConferenceMapKey(group_number);
    if (found_in_mapping && is_conference_key) {
        uint8_t stored_identity[TOX_GROUP_CHAT_ID_SIZE];
        if (!IsTemporaryInviteGroupID(groupID) &&
            !GetChatIdFromGroupID(groupID, stored_identity) &&
            !StoreConferenceIdentity(groupID, group_number)) {
            V2TIM_LOG(kWarning, "HandleGroupSelfJoin: could not persist conference identity for groupID=%s key=%u",
                      groupID.CString(), group_number);
        }
    } else if (found_in_mapping) {
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err_chat_id;
        if (GetToxManager()->getGroupChatId(group_number, chat_id, &err_chat_id) &&
            err_chat_id == TOX_ERR_GROUP_STATE_QUERY_OK) {
            std::ostringstream oss;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
            }
            std::string chat_id_hex = oss.str();
            V2TIMString canonicalGroupID;
            bool should_store_canonical_chat_id = false;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                canonicalGroupID = CanonicalGroupIDForChatIdLocked(groupID, chat_id_hex);
                should_store_canonical_chat_id =
                    !canonicalGroupID.Empty() &&
                    !IsTemporaryInviteGroupID(canonicalGroupID);
                if (canonicalGroupID != groupID) {
                    group_id_to_group_number_[canonicalGroupID] = group_number;
                    group_number_to_group_id_[group_number] = canonicalGroupID;
                    group_id_to_chat_id_[canonicalGroupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                    if (!IsTemporaryInviteGroupID(groupID)) {
                        group_id_to_chat_id_[groupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                    }
                    chat_id_to_group_id_[chat_id_hex] = canonicalGroupID;
                }
            }
            if (!canonicalGroupID.Empty()) {
                groupID = canonicalGroupID;
            }
            if (should_store_canonical_chat_id) {
                SetGroupChatIdInStorage(groupID.CString(), chat_id_hex);
            }
        }
    }
    
    // If not in mapping, try to rebuild it from stored chat_id
    if (!found_in_mapping) {
        // Live identity with the API matching the key's kind (conference id
        // for a tagged key, NGC chat id otherwise).
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        if (GetLiveGroupIdentity(group_number, chat_id)) {
            // Convert to hex string
            std::ostringstream oss;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
            }
            std::string chat_id_hex = oss.str();
            
            // Try to find groupID by checking stored chat_id for all known groups (R-07: Core metadata)
            std::vector<std::string> known_groups_vec = GetKnownGroupIDs();
            if (!known_groups_vec.empty()) {
                for (const auto& line : known_groups_vec) {
                    if (line.empty()) continue;
                    char stored_chat_id[65];
                    if (!GetGroupChatIdFromStorage(line, stored_chat_id, sizeof(stored_chat_id))) continue;
                    std::string stored_hex(stored_chat_id);
                    if (stored_hex == chat_id_hex) {
                            // Found matching groupID!
                            groupID = V2TIMString(line.c_str());
                            found_in_mapping = true;
                            
                            // Rebuild the mapping, and look up a pending invite for
                            // this group_number in the same critical section.
                            // mutex_ is NOT recursive: this guard must end before
                            // the listener fan-out and the erase block below take
                            // it again (holding it across them self-deadlocked the
                            // tox iterate thread). The invite's fields are copied
                            // out by value because a PendingInvite* is only valid
                            // while mutex_ is held.
                            V2TIMString temp_groupID;
                            bool has_pending_inv = false;
                            std::string pending_inviter_userID;
                            uint32_t pending_friend_number = 0;
                            {
                                std::lock_guard<std::mutex> lock(mutex_);
                                group_id_to_group_number_[groupID] = group_number;
                                group_number_to_group_id_[group_number] = groupID;

                                // Also store chat_id mapping
                                group_id_to_chat_id_[groupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                                chat_id_to_group_id_[chat_id_hex] = groupID;

                                // Find pending invite with matching group_number
                                for (auto it = pending_group_invites_.begin(); it != pending_group_invites_.end(); ++it) {
                                    if (it->second.group_number == group_number) {
                                        temp_groupID = it->first;
                                        has_pending_inv = true;
                                        pending_inviter_userID = it->second.inviter_userID;
                                        pending_friend_number = it->second.friend_number;
                                        break;
                                    }
                                }
                            }

                            V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Rebuilt mapping from stored chat_id: groupID=%s <-> group_number=%u, chat_id=%s",
                                     groupID.CString(), group_number, chat_id_hex.c_str());

                            // If this was from a pending invite, trigger onMemberInvited with actual groupID
                            if (has_pending_inv && !temp_groupID.Empty()) {
                                V2TIM_LOG(kInfo, "HandleGroupSelfJoin: This group was from a pending invite, triggering onMemberInvited with actual groupID=%s", groupID.CString());
                                static_cast<void>(0);
                                static_cast<void>(0);
                                
                                // Get inviter info from pending invite
                                V2TIMGroupMemberInfo opUser;
                                if (!pending_inviter_userID.empty()) {
                                    opUser.userID = V2TIMString(pending_inviter_userID.c_str());
                                    V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Using stored inviter userID: {}", pending_inviter_userID);
                                } else {
                                    // Fallback: get inviter's public key from friend_number
                                    Tox* tox = GetToxManager()->getTox();
                                    if (tox) {
                                        uint8_t inviter_pubkey[TOX_PUBLIC_KEY_SIZE];
                                        if (tox_friend_get_public_key(tox, pending_friend_number, inviter_pubkey, nullptr)) {
                                            std::string inviterUserID = ToxUtil::tox_bytes_to_hex(inviter_pubkey, TOX_PUBLIC_KEY_SIZE);
                                            opUser.userID = V2TIMString(inviterUserID.c_str());
                                            V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Got inviter public key: {}", inviterUserID);
                                        }
                                    }
                                }
                                
                                // Build member list (contains self)
                                V2TIMGroupMemberInfoVector memberList;
                                V2TIMGroupMemberInfo selfMember;
                                Tox* tox = GetToxManager()->getTox();
                                if (tox) {
                                    uint8_t self_pubkey[TOX_PUBLIC_KEY_SIZE];
                                    tox_self_get_public_key(tox, self_pubkey);
                                    std::string selfUserID = ToxUtil::tox_bytes_to_hex(self_pubkey, TOX_PUBLIC_KEY_SIZE);
                                    selfMember.userID = V2TIMString(selfUserID.c_str());
                                    memberList.PushBack(selfMember);
                                }
                                
                                // Notify listeners with actual groupID
                                std::vector<V2TIMGroupListener*> listeners_copy;
                                {
                                    std::lock_guard<std::mutex> lock(mutex_);
                                    listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
                                }
                                
                                for (V2TIMGroupListener* listener : listeners_copy) {
                                    if (listener) {
                                        static_cast<void>(0);
                                        static_cast<void>(0);
                                        V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Calling OnMemberInvited: groupID={}, inviter={}, memberCount={}",
                                                 groupID.CString(), opUser.userID.CString(), memberList.Size());
                                        listener->OnMemberInvited(groupID, opUser, memberList);
                                    }
                                }
                                
                                // Remove pending invite and update mapping
                                {
                                    std::lock_guard<std::mutex> lock(mutex_);
                                    // Remove temporary groupID mapping
                                    group_id_to_group_number_.erase(temp_groupID);
                                    // Update to actual groupID
                                    group_id_to_group_number_[groupID] = group_number;
                                    group_number_to_group_id_[group_number] = groupID;
                                    // Remove pending invite
                                    pending_group_invites_.erase(temp_groupID);
                                    V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Updated mapping from temp_groupID={} to actual groupID={}", 
                                             temp_groupID.CString(), groupID.CString());
                                }
                            }
                            
                            break;
                    }
                }
            }
            
            if (!found_in_mapping) {
                // No stored groupID for this chat_id, might be a new group or group without stored chat_id
                // Store the chat_id anyway so it can be used later for mapping recovery
                // Note: Function is already declared with extern "C" at file scope (line 38)
                // We don't have a groupID yet, but we can store the chat_id with a temporary key
                // or wait for GetGroupsInfo to assign a groupID. For now, we'll just log it.
                V2TIM_LOG(kInfo, "HandleGroupSelfJoin: Group_number=%u not in mapping and no stored groupID found for chat_id=%s, will be handled by GetGroupsInfo", 
                         group_number, chat_id_hex.c_str());
                // Note: chat_id will be stored when GetGroupsInfo assigns a groupID to this group
                return;
            }
        } else {
            V2TIM_LOG(kWarning, "HandleGroupSelfJoin: key=%u (%s) not in mapping and its identity is unreadable",
                     group_number, is_conference_key ? "conference" : "ngc");
            return;
        }
    }

    if (IsTemporaryInviteGroupID(groupID)) {
        // Publishing the per-invite alias would be wrong, but returning here
        // silently discarded the self-join entirely — see
        // PromoteTemporaryInviteGroupID. Promote it to a stable id and carry on
        // so listeners and the Dart layer still learn about the join.
        const V2TIMString promoted =
            PromoteTemporaryInviteGroupID(groupID, group_number);
        if (promoted.Empty()) {
            V2TIM_LOG(kWarning,
                      "HandleGroupSelfJoin: temporary alias %s could not be promoted (chat id unreadable); not publishing",
                      groupID.CString());
            return;
        }
        groupID = promoted;
    }

    // Notify group listeners about self join
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
        static_cast<void>(0);
        static_cast<void>(0);
    }
    
    static_cast<void>(0);
    static_cast<void>(0);
    
    if (listeners_copy.empty()) {
        static_cast<void>(0);
        static_cast<void>(0);
    }
    
    for (size_t i = 0; i < listeners_copy.size(); i++) {
        V2TIMGroupListener* listener = listeners_copy[i];
        if (listener) {
            static_cast<void>(0);
            static_cast<void>(0);
            try {
                listener->OnGroupCreated(groupID);
                static_cast<void>(0);
                static_cast<void>(0);
            } catch (const std::exception& e) {
                static_cast<void>(0);
                static_cast<void>(0);
            } catch (...) {
                static_cast<void>(0);
                static_cast<void>(0);
            }
        } else {
            static_cast<void>(0);
            static_cast<void>(0);
        }
    }
    
    // Surface this self-join to the Dart layer so an invite auto-join (which the
    // Dart layer did NOT initiate via joinGroup) lands in _knownGroups. groupID
    // is resolved above (existing mapping or rebuilt from the stored chat_id);
    // skip if still empty. Idempotent on the Dart side for the create/normal-join
    // paths that already track the group.
    if (!groupID.Empty()) {
        DartNotifyGroupJoin(groupID.CString(), GetInstanceIdFromManager(this), GetSessionEpoch());
    }


    static_cast<void>(0);
    static_cast<void>(0);
}

void V2TIMManagerImpl::HandleGroupJoinFail(Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type) {
    // The group refused us (wrong/missing password, full, or unknown). This
    // used to be only logged, so the group sat in the list "joined" forever
    // with no peers and no explanation.
    const char* reason =
        fail_type == TOX_GROUP_JOIN_FAIL_INVALID_PASSWORD ? "invalid_password"
        : fail_type == TOX_GROUP_JOIN_FAIL_PEER_LIMIT     ? "peer_limit"
                                                          : "unknown";
    V2TIMString groupID;
    std::string chat_id_hex;
    std::string invite_id;
    bool fresh = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it != group_number_to_group_id_.end()) groupID = it->second;
        fresh = fresh_group_joins_.erase(group_number) > 0;
        auto accepted = accepted_invites_.find(group_number);
        if (fresh && accepted != accepted_invites_.end()) {
            // The join came from an invite: hand the invite back (unanswered)
            // so a retry — with a password — can redeem it. A private group
            // can only be entered through its invite.
            invite_id = accepted->second.first;
            PendingInvite restored = accepted->second.second;
            restored.group_number = UINT32_MAX;
            const V2TIMString invite_key(invite_id.c_str());
            pending_group_invites_[invite_key] = std::move(restored);
            accepted_invites_.erase(accepted);
            // The accept left the invite id mapped (number + chat id): a
            // retry through it would then take the join-by-chat-id path,
            // which cannot enter a private group. Back to a bare invite.
            auto alias_number = group_id_to_group_number_.find(invite_key);
            if (alias_number != group_id_to_group_number_.end()) {
                auto reverse = group_number_to_group_id_.find(alias_number->second);
                if (reverse != group_number_to_group_id_.end() && reverse->second == invite_key) {
                    group_number_to_group_id_.erase(reverse);
                }
                group_id_to_group_number_.erase(alias_number);
            }
            group_id_to_chat_id_.erase(invite_key);
        }
    }
    if (!invite_id.empty()) {
        // Back on the user's list of invites to answer (and persisted there).
        DartNotifyGroupInvite(invite_id.c_str(), GetInstanceIdFromManager(this), GetSessionEpoch());
    }
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    Tox_Err_Group_State_Query err_chat = TOX_ERR_GROUP_STATE_QUERY_OK;
    if (GetToxManager() && GetToxManager()->getGroupChatId(group_number, chat_id, &err_chat) &&
        err_chat == TOX_ERR_GROUP_STATE_QUERY_OK) {
        chat_id_hex = ToxUtil::tox_bytes_to_hex(chat_id, TOX_GROUP_CHAT_ID_SIZE);
    }
    V2TIM_LOG(kWarning, "HandleGroupJoinFail: group_number={} groupID={} reason={} fresh={}",
              group_number, groupID.CString(), reason, fresh);
    if (groupID.Empty()) return;
    // Only a join started in this session is undone. A group we already had
    // (reconnecting after a restart, say, and the founder has since set a
    // password or the group filled up) keeps its mapping, its identity and
    // the user's history: the user is told, and can retry with a password
    // (gc_rejoin_group accepts a new one) — dropping it on the peer's say-so
    // would destroy the only copy of that history.
    DartNotifyGroupJoinFailed(groupID.CString(), chat_id_hex.c_str(), reason, !fresh,
                              invite_id.c_str(), GetInstanceIdFromManager(this), GetSessionEpoch());
    if (!fresh) return;
    EraseGroupLocalState(groupID);
    // toxcore leaves a rejected join as a CS_DISCONNECTED group, and while it
    // exists every later invite to (or join of) that group is dropped as
    // "already added" — a retry with the right password could never work.
    // Delete it outside this callback, like the self-kick path does.
    const Tox_Group_Number rejected_group_number = group_number;
    PostToEventThread([this, rejected_group_number]() {
        if (!tox_manager_) return;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (group_number_to_group_id_.find(rejected_group_number) != group_number_to_group_id_.end()) {
                return;  // the slot was already claimed by something else
            }
        }
        Tox_Err_Group_Leave err_leave;
        tox_manager_->deleteGroup(rejected_group_number, &err_leave);
        SaveToxProfile();
    });
}

void V2TIMManagerImpl::MarkFreshGroupJoin(Tox_Group_Number group_number) {
    if (group_number == UINT32_MAX || IsConferenceMapKey(group_number)) return;
    std::lock_guard<std::mutex> lock(mutex_);
    fresh_group_joins_.insert(group_number);
}

void V2TIMManagerImpl::HandleGroupPrivacyState(Tox_Group_Number group_number, Tox_Group_Privacy_State privacy_state) {
    static_cast<void>(0);
    static_cast<void>(0);
    static_cast<void>(0);
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            static_cast<void>(0);
            static_cast<void>(0);
            return;
        }
        groupID = it->second;
        static_cast<void>(0);
        static_cast<void>(0);
    }
    
    // Notify group listeners about privacy state change
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    V2TIMGroupChangeInfo changeInfo;
    changeInfo.type = V2TIM_GROUP_INFO_CHANGE_TYPE_CUSTOM; // Privacy state is a custom change
    
    V2TIMGroupChangeInfoVector changeList;
    changeList.PushBack(changeInfo);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnGroupInfoChanged(groupID, changeList);
        }
    }
}

void V2TIMManagerImpl::HandleGroupVoiceState(Tox_Group_Number group_number, Tox_Group_Voice_State voice_state) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }
    
    // Notify group listeners about voice state change (maps to mute all)
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    bool isMuted = (voice_state == TOX_GROUP_VOICE_STATE_MODERATOR || voice_state == TOX_GROUP_VOICE_STATE_FOUNDER);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnAllGroupMembersMuted(groupID, isMuted);
        }
    }
}

void V2TIMManagerImpl::HandleGroupPeerStatus(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_USER_STATUS status) {
    V2TIMString groupID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = group_number_to_group_id_.find(group_number);
        if (it == group_number_to_group_id_.end()) {
            return;
        }
        groupID = it->second;
    }
    
    // Get peer public key to find userID
    Tox* tox = GetToxManager()->getTox();
    if (!tox) return;
    
    uint8_t peer_pubkey[TOX_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err_key;
    if (!GetToxManager()->getGroupPeerPublicKey(group_number, peer_id, peer_pubkey, &err_key) ||
        err_key != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }
    
    std::string userID = ToxUtil::tox_bytes_to_hex(peer_pubkey, TOX_PUBLIC_KEY_SIZE);
    
    // Notify group listeners about member status change
    std::vector<V2TIMGroupListener*> listeners_copy;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listeners_copy.assign(group_listeners_.begin(), group_listeners_.end());
    }
    
    V2TIMGroupMemberChangeInfo changeInfo;
    changeInfo.userID = userID;
    // Note: V2TIM doesn't have a direct status field in GroupMemberChangeInfo
    // We'll just notify that member info changed
    
    V2TIMGroupMemberChangeInfoVector changeList;
    changeList.PushBack(changeInfo);
    
    for (V2TIMGroupListener* listener : listeners_copy) {
        if (listener) {
            listener->OnMemberInfoChanged(groupID, changeList);
        }
    }
}

#ifdef BUILD_TOXAV
// Helper method to get ToxAVManager instance (for internal use).
// ToxAVManager is created in InitSDK (same as ToxManager), not lazily, to avoid
// crashes when first creating it from FFI callback context.
ToxAVManager* V2TIMManagerImpl::GetToxAVManager() {
    return toxav_manager_.get();
}
#endif

void V2TIMManagerImpl::RejoinKnownGroups() {
    // Runs on the rejoin background task and from InitSDK/connection changes,
    // i.e. never inside a tox callback that would defer teardown: pin the
    // session for the whole restore pass instead of re-reading tox_manager_
    // (which UnInitSDK can null between any two of the calls below).
    const ToxSessionGuard session = AcquireToxSession();
    ToxManager* tox_manager = session.manager();
    if (!tox_manager) {
        static_cast<void>(0);
        static_cast<void>(0);
        return;
    }

    // R-07: Get known groups from Core metadata
    std::vector<std::string> known_groups_list = GetKnownGroupIDs();
    if (known_groups_list.empty()) {
        return;
    }
    
    int rejoin_attempts = 0;
    int rejoin_successes = 0;
    int conference_restored = 0;
    
    // First, restore conferences from savedata (they are automatically restored by Tox)
    Tox* tox = nullptr;
    try {
        tox = session.tox();
    } catch (const std::exception& e) {
        static_cast<void>(0);
        static_cast<void>(0);
        return;
    } catch (...) {
        static_cast<void>(0);
        static_cast<void>(0);
        return;
    }
    
    if (tox) {
        size_t conference_count = 0;
        try {
            conference_count = tox_conference_get_chatlist_size(tox);
        } catch (const std::exception& e) {
            static_cast<void>(0);
            static_cast<void>(0);
            conference_count = 0;
        } catch (...) {
            static_cast<void>(0);
            static_cast<void>(0);
            conference_count = 0;
        }
        
        if (conference_count > 0) {
            std::vector<Tox_Conference_Number> conference_list(conference_count);
            try {
                tox_conference_get_chatlist(tox, conference_list.data());
            } catch (const std::exception& e) {
                static_cast<void>(0);
                static_cast<void>(0);
                conference_count = 0;
            } catch (...) {
                static_cast<void>(0);
                static_cast<void>(0);
                conference_count = 0;
            }
            
            if (conference_count > 0) {
                for (const auto& line : known_groups_list) {
                    try {
                        std::string line_trim = line;
                        while (!line_trim.empty() && line_trim.back() == '\n') line_trim.pop_back();
                        if (line_trim.empty()) continue;
                        
                        // Check group type
                        char stored_type[16] = {};
                        std::string group_type = "group"; // Default
                        if (GetGroupTypeFromStorage(line_trim, stored_type, sizeof(stored_type))) {
                            group_type = std::string(stored_type);
                        }
                        
                        const bool is_text_conference =
                            group_type == "conference";
                        const bool is_av_conference =
                            group_type == "av_conference";
                        if (is_text_conference || is_av_conference) {
                            char stored_identity[TOX_CONFERENCE_ID_SIZE * 2 + 1];
                            const bool has_stored_identity =
                                GetGroupChatIdFromStorage(
                                    line_trim, stored_identity,
                                    sizeof(stored_identity));
                            if (has_stored_identity) {
                                const std::size_t identity_length =
                                    std::strlen(stored_identity);
                                uint8_t conference_id[TOX_CONFERENCE_ID_SIZE];
                                if (identity_length !=
                                        TOX_CONFERENCE_ID_SIZE * 2 ||
                                    !ToxUtil::tox_hex_to_bytes(
                                        stored_identity, identity_length,
                                        conference_id,
                                        TOX_CONFERENCE_ID_SIZE)) {
                                    continue;
                                }

                                Tox_Err_Conference_By_Id lookup_error;
                                const Tox_Conference_Number conf_num =
                                    tox_manager->getConferenceById(
                                        conference_id, &lookup_error);
                                if (lookup_error !=
                                        TOX_ERR_CONFERENCE_BY_ID_OK ||
                                    conf_num == UINT32_MAX) {
                                    continue;
                                }

                                Tox_Err_Conference_Get_Type type_error;
                                const Tox_Conference_Type conference_type =
                                    tox_conference_get_type(
                                        tox, conf_num, &type_error);
                                const bool type_matches =
                                    type_error ==
                                        TOX_ERR_CONFERENCE_GET_TYPE_OK &&
                                    ((is_av_conference &&
                                      conference_type ==
                                          TOX_CONFERENCE_TYPE_AV) ||
                                     (is_text_conference &&
                                      conference_type ==
                                          TOX_CONFERENCE_TYPE_TEXT));
                                if (!type_matches) {
                                    continue;
                                }
#ifdef BUILD_TOXAV
                                bool av_restore_failed = false;
                                if (is_av_conference) {
                                    // Legacy group AV takes no toxcore lock (see
                                    // ToxAVManager::lockToxIterate); this runs on the rejoin thread.
                                    auto av_iterate_lock = tox_manager->lockIterate();
                                    av_restore_failed =
                                        !toxav_groupchat_av_enabled(tox, conf_num) &&
                                        toxav_groupchat_enable_av(tox, conf_num, HandleAVConferenceAudio, this) != 0;
                                }
                                if (av_restore_failed) {
                                    V2TIM_LOG(kWarning,
                                              "RejoinKnownGroups: Failed to enable restored AV conference {}",
                                              conf_num);
                                    continue;
                                }
#else
                                if (is_av_conference) {
                                    V2TIM_LOG(kWarning,
                                              "RejoinKnownGroups: Cannot restore AV conference {} without ToxAV",
                                              conf_num);
                                    continue;
                                }
#endif
                                V2TIMString groupID(line_trim.c_str());
                                {
                                    std::lock_guard<std::mutex> lock(mutex_);
                                    auto old_number =
                                        group_id_to_group_number_.find(groupID);
                                    if (old_number !=
                                            group_id_to_group_number_.end() &&
                                        old_number->second != ConferenceMapKey(conf_num)) {
                                        auto old_reverse =
                                            group_number_to_group_id_.find(
                                                old_number->second);
                                        if (old_reverse !=
                                                group_number_to_group_id_.end() &&
                                            old_reverse->second == groupID) {
                                            group_number_to_group_id_.erase(
                                                old_reverse);
                                        }
                                    }
                                    group_id_to_group_number_[groupID] = ConferenceMapKey(conf_num);
                                    group_number_to_group_id_[ConferenceMapKey(conf_num)] = groupID;
                                    group_id_to_type_[groupID] = group_type;
                                    group_id_to_chat_id_[groupID] =
                                        std::vector<uint8_t>(
                                            conference_id,
                                            conference_id +
                                                TOX_CONFERENCE_ID_SIZE);
                                    chat_id_to_group_id_[stored_identity] = groupID;
#ifdef BUILD_TOXAV
                                    if (is_av_conference) {
                                        enabled_av_conferences_.insert(conf_num);
                                    }
#endif
                                }
                                conference_restored++;
                                continue;
                            }

                            // Type/list matching is only for legacy profiles without a stored conference ID.
                            bool already_mapped = false;
                            try {
                                std::lock_guard<std::mutex> lock(mutex_);
                                for (const auto& pair : group_number_to_group_id_) {
                                    std::string pair_str = pair.second.CString();
                                    if (pair_str == line_trim) {
                                        already_mapped = true;
                                        break;
                                    }
                                }
                            } catch (const std::exception& e) {
                                static_cast<void>(0);
                                static_cast<void>(0);
                                continue;
                            } catch (...) {
                                static_cast<void>(0);
                                static_cast<void>(0);
                                continue;
                            }
                            
                            if (!already_mapped) {
                                for (Tox_Conference_Number conf_num : conference_list) {
                                    bool conf_mapped = false;
                                    try {
                                        std::lock_guard<std::mutex> lock(mutex_);
                                        if (group_number_to_group_id_.find(ConferenceMapKey(conf_num)) != group_number_to_group_id_.end()) {
                                            conf_mapped = true;
                                        }
                                    } catch (...) {
                                        static_cast<void>(0);
                                        static_cast<void>(0);
                                        break;
                                    }
                                    
                                    if (!conf_mapped) {
                                        Tox_Err_Conference_Get_Type type_error;
                                        const Tox_Conference_Type conference_type =
                                            tox_conference_get_type(
                                                tox, conf_num, &type_error);
                                        if (type_error !=
                                            TOX_ERR_CONFERENCE_GET_TYPE_OK) {
                                            continue;
                                        }
                                        const bool type_matches =
                                            (is_av_conference &&
                                             conference_type ==
                                                 TOX_CONFERENCE_TYPE_AV) ||
                                            (is_text_conference &&
                                             conference_type ==
                                                 TOX_CONFERENCE_TYPE_TEXT);
                                        if (!type_matches) {
                                            continue;
                                        }
#ifdef BUILD_TOXAV
                                        bool av_restore_failed = false;
                                        if (is_av_conference) {
                                            // Legacy group AV takes no toxcore lock (see
                                            // ToxAVManager::lockToxIterate); this runs on the rejoin thread.
                                            auto av_iterate_lock = tox_manager->lockIterate();
                                            av_restore_failed =
                                                !toxav_groupchat_av_enabled(tox, conf_num) &&
                                                toxav_groupchat_enable_av(tox, conf_num, HandleAVConferenceAudio, this) != 0;
                                        }
                                        if (av_restore_failed) {
                                            V2TIM_LOG(kWarning, "RejoinKnownGroups: Failed to enable restored AV conference {}",
                                                      conf_num);
                                            continue;
                                        }
#else
                                        if (is_av_conference) {
                                            V2TIM_LOG(kWarning, "RejoinKnownGroups: Cannot restore AV conference {} without ToxAV",
                                                      conf_num);
                                            continue;
                                        }
#endif
                                        V2TIMString groupID(line_trim.c_str());
                                        try {
                                            std::lock_guard<std::mutex> lock(mutex_);
                                            group_id_to_group_number_[groupID] = ConferenceMapKey(conf_num);
                                            group_number_to_group_id_[ConferenceMapKey(conf_num)] = groupID;
                                            group_id_to_type_[groupID] = group_type;
#ifdef BUILD_TOXAV
                                            if (is_av_conference) {
                                                enabled_av_conferences_.insert(conf_num);
                                            }
#endif
                                        } catch (...) {
                                            static_cast<void>(0);
                                            static_cast<void>(0);
                                            break;
                                        }
                                        StoreConferenceIdentity(groupID, conf_num);
                                        conference_restored++;
                                        break; // Match one conference per groupID
                                    }
                                }
                            }
                        }
                    } catch (const std::exception& e) {
                        static_cast<void>(0);
                        static_cast<void>(0);
                        continue;
                    } catch (...) {
                        static_cast<void>(0);
                        static_cast<void>(0);
                        continue;
                    }
                }
            }
        }
    }
    
    // Now restore groups using chat_id (R-07: iterate known_groups_list)
    for (const auto& line : known_groups_list) {
        try {
            std::string line_trim = line;
            while (!line_trim.empty() && line_trim.back() == '\n') line_trim.pop_back();
            if (line_trim.empty()) continue;
            
            bool already_mapped = false;
            try {
                std::lock_guard<std::mutex> lock(mutex_);
                for (const auto& pair : group_number_to_group_id_) {
                    std::string pair_str = pair.second.CString();
                    if (pair_str == line_trim) {
                        already_mapped = true;
                        break;
                    }
                }
            } catch (const std::exception& e) {
                static_cast<void>(0);
                static_cast<void>(0);
                continue;
            } catch (...) {
                static_cast<void>(0);
                static_cast<void>(0);
                continue;
            }
            
            if (already_mapped) {
                continue;
            }
            
            // Check group type
            char stored_type[16] = {};
            std::string group_type = "group"; // Default
            try {
                if (GetGroupTypeFromStorage(line_trim, stored_type, sizeof(stored_type))) {
                    group_type = std::string(stored_type);
                }
            } catch (const std::exception& e) {
                static_cast<void>(0);
                static_cast<void>(0);
                group_type = "group"; // Use default on error
            } catch (...) {
                static_cast<void>(0);
                static_cast<void>(0);
                group_type = "group"; // Use default on error
            }
            
            const bool is_legacy_conference =
                group_type == "conference" ||
                group_type == "av_conference";
            if (is_legacy_conference) {
                continue;
            }
            
            // Get stored chat_id for this group
            char stored_chat_id[65];
            bool has_stored_chat_id = GetGroupChatIdFromStorage(line_trim, stored_chat_id, sizeof(stored_chat_id));
            if (!has_stored_chat_id) {
                continue;
            }
            
            // Convert hex string to binary chat_id
            std::string chat_id_hex(stored_chat_id);
            if (chat_id_hex.length() != TOX_GROUP_CHAT_ID_SIZE * 2) {
                static_cast<void>(0);
                static_cast<void>(0);
                continue;
            }
            
            uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
            bool conversion_success = true;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                std::string byte_str = chat_id_hex.substr(i * 2, 2);
                char* endptr;
                unsigned long byte_val = strtoul(byte_str.c_str(), &endptr, 16);
                if (*endptr != '\0' || byte_val > 255) {
                    static_cast<void>(0);
                    static_cast<void>(0);
                    conversion_success = false;
                    break;
                }
                chat_id[i] = static_cast<uint8_t>(byte_val);
            }
            
            if (!conversion_success) {
                continue;
            }
            
            // The session may have ended while the loop was running; the pinned
            // manager stays valid, but joining for a session that is over would
            // map this profile's groups onto the next one's numbers.
            if (session.Expired()) {
                static_cast<void>(0);
                static_cast<void>(0);
                break;
            }

            // Before attempting to join, check if the group already exists in Tox (restored from savedata).
            // tox_group_join() on an already-existing group returns an unreliable group_number (often 0),
            // which causes all groups to get mapped to the same number. Use getGroupByChatId first.
            Tox_Group_Number existing_group_number = tox_manager->getGroupByChatId(chat_id);
            if (existing_group_number != UINT32_MAX) {
                // Group already exists in Tox - just record the mapping, no need to join
                rejoin_successes++;
                V2TIMString groupID(line_trim.c_str());
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    group_id_to_group_number_[groupID] = existing_group_number;
                    group_number_to_group_id_[existing_group_number] = groupID;
                }
                rejoin_attempts++;
                continue;
            }

            // Group not found in Tox - attempt to join using chat_id
            // Get self name for joining
            std::string self_name = tox_manager->getName();
            if (self_name.empty()) {
                self_name = "User";
            }

            // Attempt to rejoin group using chat_id
            rejoin_attempts++;
            Tox_Err_Group_Join err_join;
            Tox_Group_Number group_number = tox_manager->joinGroup(
                chat_id,
                reinterpret_cast<const uint8_t*>(self_name.c_str()), self_name.length(),
                nullptr, 0, // No password
                &err_join
            );

            if (err_join == TOX_ERR_GROUP_JOIN_OK && group_number != UINT32_MAX) {
                rejoin_successes++;
                V2TIMString groupID(line_trim.c_str());
                // Strategy:
                // 1. Pre-register chat_id→groupID (first-wins) so HandleGroupSelfJoin can resolve.
                // 2. ALSO store group_number→groupID immediately as a fallback, because
                //    HandleGroupSelfJoin may never fire when the underlying group join does not
                //    complete on the network (e.g. corrupt/ghost chat_id with no live peers).
                // 3. For duplicate groupIDs with the same stored chat_id (data corruption), route
                //    them to the SAME canonical group_number as the first-wins owner so that sends
                //    to tox_2/tox_3 still reach the physical group.
                {
                    std::ostringstream oss;
                    for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(chat_id[i]);
                    }
                    std::string chat_id_hex = oss.str();
                    std::lock_guard<std::mutex> lock(mutex_);

                    // --- Step 1: resolve owner for this chat_id ---
                    V2TIMString owner_groupID;
                    auto chat_it = chat_id_to_group_id_.find(chat_id_hex);
                    if (chat_it == chat_id_to_group_id_.end()) {
                        // First group with this chat_id becomes the owner.
                        chat_id_to_group_id_[chat_id_hex] = groupID;
                        group_id_to_chat_id_[groupID] = std::vector<uint8_t>(chat_id, chat_id + TOX_GROUP_CHAT_ID_SIZE);
                        owner_groupID = groupID;
                    } else {
                        owner_groupID = chat_it->second;
                        V2TIM_LOG(kWarning, "RejoinKnownGroups: Duplicate chat_id={} - owner={}, aliasing groupID={}",
                                  chat_id_hex, owner_groupID.CString(), groupID.CString());
                        static_cast<void>(0);
                    }

                    // --- Step 2: determine canonical group_number for this chat_id ---
                    // For the owner: use the returned group_number.
                    // For duplicates: reuse the owner's already-stored group_number if available.
                    Tox_Group_Number canonical_number = group_number;
                    if (groupID != owner_groupID) {
                        auto owner_num_it = group_id_to_group_number_.find(owner_groupID);
                        if (owner_num_it != group_id_to_group_number_.end()) {
                            canonical_number = owner_num_it->second;
                        }
                    }

                    // --- Step 3: store mappings ---
                    // Primary direction (group_number → groupID): first-wins to avoid overwrite.
                    if (group_number_to_group_id_.find(canonical_number) == group_number_to_group_id_.end()) {
                        group_number_to_group_id_[canonical_number] = owner_groupID;
                    }
                    // Reverse direction (groupID → group_number): update owner to latest join result.
                    group_id_to_group_number_[owner_groupID] = canonical_number;
                    // Alias groupIDs (duplicates) also point to canonical group_number.
                    if (groupID != owner_groupID) {
                        group_id_to_group_number_[groupID] = canonical_number;
                    }

                }
            } else {
                static_cast<void>(0);
                static_cast<void>(0);
            }
        } catch (const std::exception& e) {
            static_cast<void>(0);
            static_cast<void>(0);
            continue;
        } catch (...) {
            static_cast<void>(0);
            static_cast<void>(0);
            continue;
        }
    }
    
    // Rebuild group_number <-> groupID mapping from current Tox state (R-07: iterate known_groups_list).
    for (const auto& line_rebuild : known_groups_list) {
        try {
            std::string lr = line_rebuild;
            while (!lr.empty() && lr.back() == '\n') lr.pop_back();
            if (lr.empty()) continue;
            char stored_type[16] = {};
            std::string group_type = "group";
            if (GetGroupTypeFromStorage(lr, stored_type, sizeof(stored_type))) {
                group_type = std::string(stored_type);
            }
            const bool is_legacy_conference =
                group_type == "conference" ||
                group_type == "av_conference";
            if (is_legacy_conference) continue;
            char stored_chat_id[65];
            if (!GetGroupChatIdFromStorage(lr, stored_chat_id, sizeof(stored_chat_id))) continue;
            std::string chat_id_hex(stored_chat_id);
            if (chat_id_hex.length() != static_cast<size_t>(TOX_GROUP_CHAT_ID_SIZE * 2)) continue;
            uint8_t chat_id_bin[TOX_GROUP_CHAT_ID_SIZE];
            bool ok = true;
            for (size_t i = 0; i < TOX_GROUP_CHAT_ID_SIZE; ++i) {
                std::string byte_str = chat_id_hex.substr(i * 2, 2);
                char* endptr = nullptr;
                unsigned long v = strtoul(byte_str.c_str(), &endptr, 16);
                if (!endptr || *endptr != '\0' || v > 255) { ok = false; break; }
                chat_id_bin[i] = static_cast<uint8_t>(v);
            }
            if (!ok || session.Expired()) continue;
            Tox_Group_Number actual = tox_manager->getGroupByChatId(chat_id_bin);
            if (actual == UINT32_MAX) continue;
            V2TIMString groupID(lr.c_str());
            {
                std::lock_guard<std::mutex> lock(mutex_);
                group_id_to_group_number_[groupID] = actual;
                group_number_to_group_id_[actual] = groupID;
            }
        } catch (...) { continue; }
    }
    
    V2TIM_LOG(kInfo, "[RejoinKnownGroups] attempts={}, successes={}, conferences_restored={}",
              rejoin_attempts, rejoin_successes, conference_restored);
}
