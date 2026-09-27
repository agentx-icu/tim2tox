#ifndef __V2TIM_MANAGER_IMPL_H__
#define __V2TIM_MANAGER_IMPL_H__

#include <mutex>
#include <condition_variable>
#include <atomic>
#include <functional>
#include <future>
#include <queue>
#include <chrono>
#include <type_traits>
#include "toxcore/tox_struct.h"
#include "V2TIMLog.h"
#include "V2TIMManager.h"
#include "V2TIMMessageManager.h"
#include "V2TIMGroupManager.h"
#include "V2TIMConversationManager.h"
#include "V2TIMFriendshipManager.h"
#include "V2TIMOfflinePushManager.h"
#include "V2TIMSignalingManager.h"
#include "V2TIMCommunityManager.h"
#include "Tim2ToxControlPacket.h"

class V2TIMSignalingManagerImpl;
class V2TIMMessageManagerImpl;
class V2TIMGroupManagerImpl;
class V2TIMConversationManagerImpl;
class V2TIMCommunityManagerImpl;
class V2TIMFriendshipManagerImpl;
#include "ToxManager.h"
#include <memory>
#include <vector>
#include <unordered_set>
#include <thread>
#include "V2TIMStringHash.h"
#include <unordered_map>
#include <deque>
#include <vector>
#include <string>
#include "AVConferenceAudioQueue.h"

enum class PendingInviteKind {
    kGroupInvite,
    kConferenceText,
    kConferenceAv,
};

#ifdef BUILD_TOXAV
#include "ToxAVManager.h"
#endif

class V2TIMManagerImpl : public V2TIMManager {
public:
    // Constructor (now public for multi-instance support)
    V2TIMManagerImpl();
    
    // Destructor
    ~V2TIMManagerImpl();
    
    // Backward compatibility: Get default instance
    static V2TIMManagerImpl* GetInstance();

    // SDK Listener Management
    void AddSDKListener(V2TIMSDKListener* listener) override;
    void RemoveSDKListener(V2TIMSDKListener* listener) override;
    // TEST SEAM: current SDK-listener registration count — lets the native
    // lifecycle test prove detach -> re-init registers callbacks exactly
    // once (no dangling duplicate wiring).
    size_t DebugSDKListenerCountForTest();

    // SDK Initialization and Cleanup
    bool InitSDK(uint32_t sdkAppID, const V2TIMSDKConfig& config) override;
    void UnInitSDK() override;

    // SDK Information
    V2TIMString GetVersion() override;
    int64_t GetServerTime() override;

    // User Authentication
    void Login(const V2TIMString& userID, const V2TIMString& userSig, V2TIMCallback* callback) override;
    void Logout(V2TIMCallback* callback) override;
    V2TIMString GetLoginUser() override;
    V2TIMLoginStatus GetLoginStatus() override;

    /// Returns the actual self Tox address (76-hex-char public key + nospam +
    /// checksum), populated by HandleSelfConnectionStatus once the Tox stack
    /// establishes a connection. Distinct from GetLoginUser(), which returns
    /// the login alias (the userID passed to Login). Returns an empty string
    /// when not yet known.
    V2TIMString GetSelfToxAddress();

    /** Return true if this instance has group_id in its group mapping (used for join/peer sync). */
    bool HasGroup(const V2TIMString& group_id) const;

    // Messaging
    void AddSimpleMsgListener(V2TIMSimpleMsgListener* listener) override;
    void RemoveSimpleMsgListener(V2TIMSimpleMsgListener* listener) override;
    V2TIMString SendC2CTextMessage(const V2TIMString& text, const V2TIMString& userID, V2TIMSendCallback* callback) override;
    V2TIMString SendC2CTextMessage(const V2TIMString& text, const V2TIMString& userID, const V2TIMBuffer& cloudCustomData, V2TIMSendCallback* callback) override;
    V2TIMString SendC2CActionMessage(const V2TIMString& text, const V2TIMString& userID, V2TIMSendCallback* callback);
    V2TIMString SendC2CCustomMessage(const V2TIMBuffer& customData, const V2TIMString& userID, V2TIMSendCallback* callback) override;
    V2TIMString SendC2CControlMessage(const V2TIMBuffer& customData, const V2TIMString& userID, uint8_t controlType, V2TIMSendCallback* callback);
    V2TIMString SendGroupTextMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback) override;
    V2TIMString SendGroupTextMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, const V2TIMBuffer& cloudCustomData, V2TIMSendCallback* callback) override;
    V2TIMString SendGroupActionMessage(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback);
    V2TIMString SendGroupPrivateTextMessage(const V2TIMString& groupID, const V2TIMString& receiverPublicKey64, const V2TIMString& text, V2TIMSendCallback* callback);
    // Deliver a "received"/"read" receipt for one group message to its AUTHOR
    // only (NGC custom private packet under the tim2tox group-packet header).
    // Returns 1 sent, -2 not possible on this kind of group (legacy
    // conference: no private packets), -3 the author is not a live NGC peer
    // right now (the caller may park the receipt and retry when it is), 0
    // failure.
    int SendGroupReceipt(const V2TIMString& groupID, const std::string& author_key_hex,
                         const std::string& msg_id, const std::string& receipt_type);
    Tox_Group_Peer_Number ResolveGroupPeerIdForKey(Tox_Group_Number group_number, const std::string& receiver_hex);
    V2TIMString SendGroupCustomMessage(const V2TIMBuffer& customData, const V2TIMString& groupID, V2TIMMessagePriority priority, V2TIMSendCallback* callback) override;

    // Group Management
    void AddGroupListener(V2TIMGroupListener* listener) override;
    void RemoveGroupListener(V2TIMGroupListener* listener) override;
    void CreateGroup(const V2TIMString& groupType, const V2TIMString& groupID, const V2TIMString& groupName, V2TIMValueCallback<V2TIMString>* callback) override;
    void JoinGroup(const V2TIMString& groupID, const V2TIMString& message, V2TIMCallback* callback) override;
    // JoinGroup for a password-protected group (join by chat id, or accepting
    // an invite to one). Synchronous like JoinGroup.
    void JoinGroupWithPassword(const V2TIMString& groupID, const std::string& password, V2TIMCallback* callback);
    void QuitGroup(const V2TIMString& groupID, V2TIMCallback* callback) override;
    void DismissGroup(const V2TIMString& groupID, V2TIMCallback* callback) override;

    // User Info
    void GetUsersInfo(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMUserFullInfoVector>* callback) override;
    void SetSelfInfo(const V2TIMUserFullInfo& info, V2TIMCallback* callback) override;

    // Search & Status
    void SearchUsers(const V2TIMUserSearchParam& param, V2TIMValueCallback<V2TIMUserSearchResult>* callback) override;
    void GetUserStatus(const V2TIMStringVector& userIDList, V2TIMValueCallback<V2TIMUserStatusVector>* callback) override;
    void SetSelfStatus(const V2TIMUserStatus& status, V2TIMCallback* callback) override;
    void SubscribeUserStatus(const V2TIMStringVector& userIDList, V2TIMCallback* callback) override;
    void UnsubscribeUserStatus(const V2TIMStringVector& userIDList, V2TIMCallback* callback) override;
    void SubscribeUserInfo(const V2TIMStringVector& userIDList, V2TIMCallback* callback) override;
    void UnsubscribeUserInfo(const V2TIMStringVector& userIDList, V2TIMCallback* callback) override;

    // Advanced Managers
    V2TIMMessageManager* GetMessageManager() override;
    V2TIMGroupManager* GetGroupManager() override;
    V2TIMCommunityManager* GetCommunityManager() override;
    V2TIMConversationManager* GetConversationManager() override;
    V2TIMFriendshipManager* GetFriendshipManager() override;
    V2TIMOfflinePushManager* GetOfflinePushManager() override;
    V2TIMSignalingManager* GetSignalingManager() override;

    // Experimental API
    void CallExperimentalAPI(const V2TIMString& api, const void* param, V2TIMValueCallback<V2TIMBaseObject>* callback) override;

    // Helper methods for accessing private data
    bool GetGroupNumberFromID(const V2TIMString& groupID, Tox_Group_Number& group_number);
    bool GetChatIdFromGroupID(const V2TIMString& groupID, uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE]);
    bool GetGroupIDFromChatId(const uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE], V2TIMString& groupID);
    bool IsTemporaryInviteGroupID(const V2TIMString& groupID) const;
    V2TIMString CanonicalGroupIDForChatIdLocked(
        const V2TIMString& requested_group_id,
        const std::string& chat_id_hex) const;
    // Turn a `tox_inv_*` invite alias into a stable local group id, rewriting
    // every mapping that referenced the alias. Returns an empty string when the
    // group's chat id cannot be read (the only case where the alias must stay).
    V2TIMString PromoteTemporaryInviteGroupID(const V2TIMString& temp_group_id,
                                              Tox_Group_Number group_number);
    bool StoreConferenceIdentity(const V2TIMString& groupID, Tox_Group_Number conference_number);
    // The live 32-byte identity of a mapped group: tox_conference_get_id for a
    // conference map key (IsConferenceMapKey), the NGC chat id otherwise. Both
    // kinds share group_id_to_chat_id_, so callers must never read one kind's
    // identity through the other kind's API. Must not be called with mutex_ held.
    bool GetLiveGroupIdentity(Tox_Group_Number group_number,
                              uint8_t out_id[TOX_GROUP_CHAT_ID_SIZE]);
    // Rebuild the groupID -> map-key mapping of a group that is live in Tox but
    // missing from group_id_to_group_number_ (e.g. queried after a restart,
    // before RejoinKnownGroups ran). The stored identity is resolved by the
    // stored kind: a "conference"/"av_conference" identity only through
    // tox_conference_by_id (stored as ConferenceMapKey), never as an NGC chat
    // id; a labelled NGC identity only through the NGC lookup; an unlabelled
    // identity is tried as NGC, then as a conference. allow_unmapped_ngc_bind
    // keeps the legacy last-resort "bind the first unmapped NGC group" step for
    // an identity-less, non-conference groupID. Returns the map key or
    // UINT32_MAX. Must not be called with mutex_ held.
    Tox_Group_Number RecoverGroupMapping(const std::string& group_id,
                                         bool allow_unmapped_ngc_bind,
                                         bool* has_stored_identity = nullptr);
    bool IsRunning() const;  // Implementation in .cpp file to avoid inline optimization issues
    bool IsEventThreadRunning() const;
    
    // Helper method to notify group listeners about member kicked
    void NotifyGroupMemberKicked(const V2TIMString& groupID, const V2TIMGroupMemberInfoVector& memberList);
    
    // Helper method to get all group IDs from mapping (for GetJoinedGroupList)
    std::vector<V2TIMString> GetAllGroupIDs();

    // R-07: Instance metadata (Core-owned; FFI forwards to these)
    std::vector<std::string> GetKnownGroupIDs();
    void SetKnownGroupIDs(const std::vector<std::string>& group_ids);
    bool GetGroupChatIdFromStorage(const std::string& group_id, char* out_chat_id_hex, int out_len);
    // LOCKING CONTRACT: SetGroupChatIdInStorage acquires mutex_ internally and
    // MUST NOT be called while mutex_ is held — std::mutex is non-recursive, so
    // a re-lock self-deadlocks the calling thread forever (proven by the
    // 2026-06-03 Toxee .hang report: main thread stuck in
    // GetGroupMemberList -> SetGroupChatIdInStorage -> mutex_.lock()).
    // Inside a scope that already holds mutex_, call the *Locked variant.
    // from_dart: the value came FROM the Dart preferences (startup replay):
    // record it as known there instead of echoing it back.
    void SetGroupChatIdInStorage(const std::string& group_id, const std::string& chat_id_hex,
                                 bool from_dart = false);
    // Same write, no locking: caller must already hold mutex_.
    void SetGroupChatIdInStorageLocked(const std::string& group_id, const std::string& chat_id_hex,
                                       bool from_dart = false);
    bool GetGroupTypeFromStorage(const std::string& group_id, char* out_type, int out_len);
    void SetGroupTypeInStorage(const std::string& group_id, const std::string& group_type,
                               bool from_dart = false);
    // Every persistable (non-temporary) group identity and kind known now, as
    // "<group_id>\t<chat_id_hex_lower>\t<group_type>\n" lines (either value may
    // be empty). The pull side of groupChatIdStored / groupTypeStored: those
    // pushes are lost when they fire before the client can persist them.
    std::string SnapshotGroupIdentitiesForClient() const;
    bool GetAutoAcceptGroupInvites();
    void SetAutoAcceptGroupInvites(bool enabled);
    // Highest tox_<n> suffix this account ever used, including groups it has
    // since left, been kicked from or dismissed (pushed from Dart, which keeps
    // those ids). Newly minted ids go above it: a reused id inherited the old
    // group's persisted chat_id (-> silent rejoin of the left group), settings
    // and retained history.
    void SetRetiredGroupIdMax(uint64_t max_id) { retired_group_id_max_.store(max_id); }
    uint64_t GetRetiredGroupIdMax() const { return retired_group_id_max_.load(); }
    // Publish a group edit to the Tox network (field 1 = name, 3 =
    // notification; see V2TIMGroupManagerImpl::SetGroupInfo for the wire
    // mapping). Returns 1 ok, -2 not permitted, 0 failure.
    int PublishGroupInfoField(const std::string& group_id, int field, const std::string& value);
    // Would toxcore let us set this NGC group's topic (= its announcement)
    // right now? Mirrors gc_set_topic's rule: observers never; with the topic
    // lock on (the default for a new group) only the founder and moderators.
    // Returns 1 yes, 0 no, -1 unknown (not an NGC group, not mapped, or the
    // state query failed) — callers fall back to their own role rule.
    int CanSetGroupTopic(const std::string& group_id);
    // MM-6 (see friend_group_digests_). friend_number UINT32_MAX = every
    // friend that is online right now.
    // only_friend / only_group UINT32_MAX = all online friends / all groups.
    void AnnounceGroupIdentities(uint32_t only_friend, Tox_Group_Number only_group);
    void NoteFriendConnectionForIdentity(uint32_t friend_number, bool online);
    // A friend was deleted: drop every hint, pending challenge, proven member
    // mapping and rate window tied to it. friend_hex is its long-term key
    // (toxcore can no longer map the number once the friend is gone).
    void PurgeFriendIdentityState(uint32_t friend_number, const std::string& friend_hex);
    void HandleGroupIdentityAnnouncement(uint32_t friend_number, const uint8_t* data, size_t length);
    // A peer (re)appeared in an NGC group: index its digest and challenge
    // every friend that claimed it.
    void MatchGroupIdentityDigests(Tox_Group_Number group_number, const std::string& member_key);
    void HandleGroupIdentityProof(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                  const uint8_t* data, size_t length);
    // Long-term key (hex) of the friend behind an NGC per-group member key, or "".
    std::string FriendForGroupMemberKey(const std::string& member_key_hex);
    // MM-6 observability: counters plus the last identity-proof payload we
    // received (hex), as a small JSON object. Read-only.
    std::string Mm6DiagJson();
#ifdef TIM2TOX_ENABLE_TEST_HOOKS
    // TEST-ONLY, and gated by the SAME macro as its C wrapper
    // (tim2tox_ffi_mm6_send_crafted_challenge) on purpose: gating only the
    // wrapper left this method compiled into libtim2tox.a, where on Linux its
    // mangled symbol stays exported and the primitive remains callable from a
    // shipped library (codex 2026-09-26). CMake defines the macro for BOTH the
    // tim2tox and tim2tox_ffi targets, so the two halves can never disagree.
    //
    // MM-6 harness hook: send `friend_key_hex` an identity challenge that
    // names `claimed_member_key_hex` as OUR per-group key in `groupID`. That
    // is the shape of the MM-6 abuse case -- naming a member key that is not
    // ours -- and there is no way to reach it through the honest API, because
    // the honest path always fills that slot with our own key. Exposed so the
    // auto_tests can prove the answer is unreadable to the member named; it
    // grants an attacker nothing it could not already send by hand.
    int Mm6SendCraftedChallenge(const V2TIMString& groupID, const std::string& friend_key_hex,
                                const std::string& claimed_member_key_hex);
#endif  // TIM2TOX_ENABLE_TEST_HOOKS
    // NGC name / conference title (or a real cached name); "" if unknown.
    std::string ResolveSharedGroupName(const std::string& group_id);
    
#ifdef BUILD_TOXAV
    // Helper to resolve group_number (e.g. conference_number) to groupID (for AV callbacks)
    bool GetGroupIDFromGroupNumber(Tox_Group_Number group_number, V2TIMString& out_group_id);
    using AVConferenceAudioCallback = std::function<void(
        const char* group_id, uint32_t conference_number,
        uint32_t peer_number, const int16_t* pcm, size_t sample_count,
        uint8_t channels, uint32_t sampling_rate)>;
    void SetAVConferenceAudioCallback(AVConferenceAudioCallback callback);
    void ClearAVConferenceAudioCallback();
    void EnqueueAVConferenceAudioFrame(
        const char* group_id, uint32_t conference_number,
        uint32_t peer_number, const int16_t* pcm, size_t sample_count,
        uint8_t channels, uint32_t sampling_rate);
    void DrainPendingAVConferenceAudioFrames();
    bool SendAVConferenceAudioFrame(const V2TIMString& group_id,
                                    const int16_t* pcm, size_t sample_count,
                                    uint8_t channels, uint32_t sampling_rate);
    bool EnableAVConferenceAudio(const V2TIMString& group_id);
    bool DisableAVConferenceAudio(const V2TIMString& group_id);
    bool IsAVConferenceAudioEnabled(const V2TIMString& group_id) const;

    /// Tri-state form of [IsAVConferenceAudioEnabled]: 1 = enabled,
    /// 0 = a known conference with AV off, -1 = nothing to answer about (no
    /// mapping, not a conference, no AV manager). Callers that cache "AV is
    /// on" need the third value: a plain false made "the group is gone" look
    /// like "still enabled but the disable failed", and the stale cache then
    /// skipped a later enable and left a joined session with no audio.
    int QueryAVConferenceAudioEnabled(const V2TIMString& group_id) const;
    bool MuteAVConferenceAudio(const V2TIMString& group_id, bool mute);
#endif
    void ClearPendingAVConferenceAudioFrames();
    
    // Helper method to get ToxManager instance (for internal use).
    // UNPINNED: UnInitSDK() destroys the ToxManager and tox_kill()s the Tox
    // from whatever thread calls it, so the returned pointer (and any Tox*
    // fetched from it) is only safe while the caller is provably serialized
    // with teardown — i.e. inside a tox callback, where UnInitSDK /
    // ToxManager::shutdown defer themselves (IterateReentryScope). Every entry
    // point reachable from ANOTHER thread — the whole FFI surface — must use
    // AcquireToxSession() instead.
    ToxManager* GetToxManager() { return tox_manager_.get(); }

    // RAII pin over one session's ToxManager + Tox.
    //
    // Holding it guarantees only that the objects stay ALIVE for the duration
    // of a call sequence; it does not block UnInitSDK and does not make the
    // sequence atomic. That is deliberate: a lock held across whole operations
    // would have to be ranked against ToxManager::iterate_mutex_ (which
    // shutdown() takes first, and which callers take via lockIterate()) and
    // would deadlock one way or the other, and blocking teardown would break
    // the deferred-teardown-from-a-callback contract. What it removes is the
    // use-after-free: without it, a concurrent UnInitSDK can free the Tox
    // BETWEEN two tox_*() calls of the same operation (codex 2026-09-23 on
    // SendGroupReceipt's tox_group_self_get_public_key +
    // tox_group_send_custom_private_packet pair). Callers that also need
    // "still the same session" semantics keep their session_epoch_ re-checks —
    // Expired() exposes the same test for loops that pump between calls.
    class ToxSessionGuard {
    public:
        ToxSessionGuard() = default;
        ToxSessionGuard(std::shared_ptr<ToxManager> manager, std::shared_ptr<Tox> tox,
                        const V2TIMManagerImpl* owner, int64_t epoch)
            : manager_(std::move(manager)), tox_(std::move(tox)), owner_(owner), epoch_(epoch) {}
        ToxSessionGuard(const ToxSessionGuard&) = delete;
        ToxSessionGuard& operator=(const ToxSessionGuard&) = delete;
        ToxSessionGuard(ToxSessionGuard&&) = default;
        ToxSessionGuard& operator=(ToxSessionGuard&&) = default;

        // False when there is no live session (refuse the operation).
        explicit operator bool() const { return tox_ != nullptr; }
        Tox* tox() const { return tox_.get(); }
        ToxManager* manager() const { return manager_.get(); }
        // The manager WITHOUT the Tox pin. For the one caller that must keep
        // the manager alive across a call that waits for iterate_mutex_ and
        // therefore must not still hold a pin (see
        // tim2tox_ffi_iterate_current_instance and ToxManager::getSaveData).
        std::shared_ptr<ToxManager> manager_shared() const { return manager_; }
        int64_t epoch() const { return epoch_; }
        // True once the session this guard belongs to has ended. The pinned
        // pointers stay VALID (that is the point of the pin), but the work is
        // pointless and must not be published; pump loops break on it.
        bool Expired() const {
            return owner_ == nullptr || epoch_ == 0 ||
                   owner_->GetSessionEpoch() != epoch_;
        }

    private:
        std::shared_ptr<ToxManager> manager_;
        std::shared_ptr<Tox> tox_;
        const V2TIMManagerImpl* owner_{nullptr};
        int64_t epoch_{0};
    };

    // Pin the current session. Empty (operator bool == false) when the SDK is
    // not initialized / is tearing down. Takes no long-lived lock, so it can
    // be called from anywhere GetToxManager() could be called.
    ToxSessionGuard AcquireToxSession() const;

    // Identifies one InitSDK..UnInitSDK session of this object; 0 = no live
    // session. Process-unique and never reused, so a notification stamped
    // with it (instance_id + session_epoch, see the DartNotifyGroup* family)
    // can be told apart from one the previous account's session emitted on
    // the same instance id (an account switch reuses instance 0).
    int64_t GetSessionEpoch() const { return session_epoch_.load(std::memory_order_acquire); }

    // Test-mode controls (auto_tests harness only). When enabled, InitSDK skips
    // starting the per-instance event_thread and installs a process-global
    // virtual-clock callback on the underlying Tox's mono_time.
    // Must be set after construction and BEFORE InitSDK is called.
    void setTestMode(bool enabled) { test_mode_.store(enabled, std::memory_order_release); }
    bool isTestMode() const { return test_mode_.load(std::memory_order_acquire); }

    /** Generate a unique message ID (instance + time + seq). Safe for multi-instance. */
    std::string MakeMessageId();
    /** Generate a unique group/send ID (instance + seq). Safe for multi-instance. */
    std::string MakeGroupId();

    // Save Tox profile to disk (call after friend list changes to persist state)
    void SaveToxProfile();
    
    // Upper bound for how long RunOnEventThread will block waiting for the event
    // thread to start queued work. If the task is still pending at timeout it is
    // cancelled before f() can run; once f() is running the caller waits for the
    // real result so side-effecting calls cannot execute after a false failure.
    static constexpr std::chrono::seconds kRunOnEventThreadTimeout{10};

    /** Run a function on the event thread (tox iterate loop). Use to avoid deadlock when calling tox API from another thread.
     *  If already on the event thread, runs f() inline to avoid self-deadlock.
     *  In test_mode there is no event thread; we execute inline so the caller
     *  doesn't deadlock waiting on a future no one will fulfil.
     *  If the event thread is not running we also run inline as a best-effort fallback.
     *  Queued calls time out only while still pending; running work is waited on so the
     *  caller observes the real value or exception. */
    template<typename R>
    R RunOnEventThread(std::function<R()> f) {
        enum class RunOnEventThreadTaskState { pending, running, completed, cancelled };

        if (std::this_thread::get_id() == event_thread_id_) {
            return f.operator()();
        }
        if (test_mode_.load(std::memory_order_acquire)) {
            return f.operator()();
        }
        // If the event thread isn't running (e.g. during/after UnInitSDK, where
        // the loop break()s without draining task_queue_), enqueue-and-block would
        // hang forever. Run inline as a best-effort fallback instead — same
        // approach as the same-thread / test_mode_ short-circuits above.
        if (!running_.load(std::memory_order_acquire)) {
            return f.operator()();
        }
        auto state = std::make_shared<std::atomic<RunOnEventThreadTaskState>>(RunOnEventThreadTaskState::pending);
        auto promise = std::make_shared<std::promise<R>>();
        auto future = promise->get_future();
        std::function<void()> task = [f, promise, state]() {
            auto pending = RunOnEventThreadTaskState::pending;
            if (!state->compare_exchange_strong(
                    pending,
                    RunOnEventThreadTaskState::running,
                    std::memory_order_acq_rel,
                    std::memory_order_acquire)) {
                return;
            }
            try {
                if constexpr (std::is_void_v<R>) {
                    f();
                    promise->set_value();
                    state->store(RunOnEventThreadTaskState::completed, std::memory_order_release);
                } else {
                    promise->set_value(f());
                    state->store(RunOnEventThreadTaskState::completed, std::memory_order_release);
                }
            } catch (...) {
                state->store(RunOnEventThreadTaskState::completed, std::memory_order_release);
                promise->set_exception(std::current_exception());
            }
        };
        {
            std::lock_guard<std::mutex> lock(task_mutex_);
            task_queue_.push(task);
        }
        task_cv_.notify_one();
        // Bounded wait before the event thread starts the task. Timeout may cancel
        // only a still-pending task. If the task already reached running/completed,
        // wait for future.get() so callers receive the real value or exception and
        // never report failure while a side-effecting tox call continues.
        if (future.wait_for(kRunOnEventThreadTimeout) != std::future_status::ready) {
            auto pending = RunOnEventThreadTaskState::pending;
            if (state->compare_exchange_strong(
                    pending,
                    RunOnEventThreadTaskState::cancelled,
                    std::memory_order_acq_rel,
                    std::memory_order_acquire)) {
                V2TIM_LOG(kError, "[V2TIMManagerImpl::RunOnEventThread] Timed out after {}s waiting for event thread to start task; pending work was cancelled before execution and a default value is being returned",
                          (long long)kRunOnEventThreadTimeout.count());
                if constexpr (std::is_void_v<R>) {
                    return;
                } else {
                    return R{};
                }
            }
            V2TIM_LOG(kError, "[V2TIMManagerImpl::RunOnEventThread] Timed out after {}s, but event-thread work is already running/completed; waiting for the real result",
                      (long long)kRunOnEventThreadTimeout.count());
            return future.get();
        }
        return future.get();
    }

    /** Post a void task to the event thread without waiting. Safe to call from within event thread (e.g. Tox callbacks).
     *  In test_mode the task is still queued — the Dart-side tick loop drains it via drainTaskQueue(). */
    void PostToEventThread(std::function<void()> task) {
        std::lock_guard<std::mutex> lock(task_mutex_);
        task_queue_.push(std::move(task));
        task_cv_.notify_one();
    }

    /** Drain all currently-queued tasks synchronously on the calling thread.
     *  Test-mode helper: pumpTestTick invokes this through the FFI iterate hook
     *  so PostToEventThread tasks (signaling dispatch etc.) still execute. */
    void DrainTaskQueue() {
        while (true) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(task_mutex_);
                if (task_queue_.empty()) return;
                task = std::move(task_queue_.front());
                task_queue_.pop();
            }
            try { task(); } catch (...) { /* swallow; mirror event_thread */ }
        }
    }
    
#ifdef BUILD_TOXAV
    // Helper method to get ToxAVManager instance (for internal use)
    ToxAVManager* GetToxAVManager();
#endif
    
    // Rejoin all known groups using stored chat_id (c-toxcore recommended approach)
    // This can be called from InitSDK or from Dart layer after init() completes
    // Should be called after Tox connection is established for best success rate
    void RejoinKnownGroups();

    // Stop background tasks (refresh cache, rejoin groups). Called from UnInitSDK and destructor.
    void StopBackgroundTasks();

private:
    struct PendingDeliveryRoot {
        V2TIMString msg_id;
        V2TIMString user_id;
        uint32_t friend_number;
        std::size_t remaining_fragments;
        std::chrono::steady_clock::time_point created_at;
    };

    struct PendingInvite {
        uint32_t friend_number{0};
        std::vector<uint8_t> cookie;
        // UINT32_MAX until the invite has been accepted. Initialized: several
        // conference paths build a PendingInvite without setting it, and
        // GetPendingGroupInvites() tells "unanswered" from "accepted" by it.
        Tox_Group_Number group_number{UINT32_MAX};
        std::string inviter_userID;     // Store inviter's userID for onMemberInvited callback
        PendingInviteKind kind{PendingInviteKind::kGroupInvite};
        std::string group_name;         // From the invite packet (NGC only; empty for conferences)
        int64_t received_ms{0};         // Wall clock when the invite arrived
    };
    // Tox profile path used in InitSDK; UnInitSDK and SaveToxProfile use this instead of recomputing
    std::string save_path_;

    // ToxManager instance (owned by this V2TIMManagerImpl instance).
    // shared_ptr so AcquireToxSession() can pin it across a call sequence:
    // UnInitSDK drops this reference from an arbitrary thread, and an
    // in-flight operation must not be left with a dangling manager. Only
    // AcquireToxSession() / UnInitSDK touch it under tox_manager_mutex_;
    // everything else keeps using GetToxManager().
    std::shared_ptr<ToxManager> tox_manager_;
    // Guards ONLY the tox_manager_ pointer itself (not the object). Separate
    // from mutex_ so acquiring a session never participates in the group-state
    // lock order. Never held while calling into ToxManager.
    mutable std::mutex tox_manager_mutex_;
    
#ifdef BUILD_TOXAV
    // ToxAVManager instance (owned by this V2TIMManagerImpl instance).
    // Custom deleter required because ToxAVManager has a private destructor.
    std::unique_ptr<ToxAVManager, void(*)(ToxAVManager*)> toxav_manager_;
    AVConferenceAudioCallback av_conference_audio_callback_;
    std::unordered_set<Tox_Group_Number> enabled_av_conferences_;
    std::unordered_set<Tox_Group_Number> muted_av_conferences_;
#endif
    tim2tox::AVConferenceAudioQueue av_conference_audio_queue_;
    
    std::thread event_thread_;
    std::thread::id event_thread_id_;  // Set by event thread at start; used to avoid deadlock when RunOnEventThread is called from event thread
    std::atomic<bool> event_thread_running_{false};
    std::atomic<bool> running_{true};  // Use atomic to prevent compiler optimization issues
    std::shared_ptr<int> uninit_alive_token_ = std::make_shared<int>(0);  // a deferred UnInitSDK no-ops once this object is gone
    std::atomic<int64_t> session_epoch_{0};  // see GetSessionEpoch()
    // Test mode: when true, InitSDK skips event_thread start and installs the
    // virtual-clock callback on tox->mono_time. Auto_tests harness only.
    std::atomic<bool> test_mode_{false};
    // Joinable background tasks (no detach) to avoid UAF when instance is destroyed.
    // Use std::thread + atomic stop flag for compatibility (std::jthread is C++20 and not on all toolchains).
    std::thread refresh_task_;
    std::thread rejoin_task_;
    std::atomic<bool> refresh_task_running_{false};
    std::atomic<bool> refresh_stop_requested_{false};
    std::atomic<bool> rejoin_stop_requested_{false};
    std::mutex task_mutex_;
    std::queue<std::function<void()>> task_queue_;
    std::condition_variable task_cv_;  // Signalled when a task is pushed so event thread can process
    V2TIMString logged_in_user_;
    mutable std::mutex mutex_;

    // --- Listener Sets ---
    std::unordered_set<V2TIMSDKListener*> sdk_listeners_;
    std::unordered_set<V2TIMSimpleMsgListener*> simple_msg_listeners_;
    std::unordered_set<V2TIMGroupListener*> group_listeners_;

    // --- Mappings ---
    // Map V2TIM GroupID string to Tox group_number
    std::unordered_map<V2TIMString, Tox_Group_Number> group_id_to_group_number_;
    // Map Tox group_number back to V2TIM GroupID string (for receiving messages)
    std::unordered_map<Tox_Group_Number, V2TIMString> group_number_to_group_id_;
    // Map V2TIM GroupID string to the stable 32-byte Tox identifier.
    // For conference / av_conference this stores tox_conference_get_id bytes.
    std::unordered_map<V2TIMString, std::vector<uint8_t>> group_id_to_chat_id_;
    // Map stable 32-byte Tox identifiers (group chat_id or conference id)
    // back to V2TIM GroupID string.
    std::unordered_map<std::string, V2TIMString> chat_id_to_group_id_;
    // Map V2TIM GroupID string to group type ("group" or "conference")
    std::unordered_map<V2TIMString, std::string> group_id_to_type_;
    // R-07: Instance metadata (known groups list + auto-accept; chat_id/type use maps above)
    std::vector<std::string> known_groups_;
    bool auto_accept_group_invites_{false};
    std::mutex metadata_mutex_;
    // Pending group invites awaiting JoinGroup
    std::unordered_map<V2TIMString, PendingInvite> pending_group_invites_;
    // Flag to track if RejoinKnownGroups has been triggered after connection establishment
    std::atomic<bool> rejoin_triggered_{false};
    // User-facing login alias (from Login(userID)); GetLoginUser() returns this
    V2TIMString login_user_alias_;
    // Member list snapshots for each group (for detecting join/leave)
    std::unordered_map<Tox_Group_Number, std::unordered_set<std::string>> group_peer_snapshots_;
    // (group_number, peer_public_key_hex_lower) -> peer_id, populated from HandleGroupPeerJoin for group private send
    std::unordered_map<Tox_Group_Number, std::unordered_map<std::string, Tox_Group_Peer_Number>> group_peer_id_cache_;
    // Global counter for generating unique group IDs (to avoid reusing IDs from deleted groups)
    uint64_t next_group_id_counter_;
    std::atomic<uint64_t> retired_group_id_max_{0};
    // What the Dart preferences already hold (sent or replayed), guarded by
    // mutex_. Compared against instead of the live maps: most writers fill the
    // live maps directly and then call the setter, so "changed vs live map"
    // was false on exactly the paths that needed persisting.
    std::unordered_map<std::string, std::string> dart_known_chat_id_;
    std::unordered_map<std::string, std::string> dart_known_type_;
    // MM-6: NGC members are named by per-group keys. A friend proves which
    // per-group key is theirs over the authenticated friend channel by sending
    // sha256(chat_id || key) digests; a match against our group's peers maps
    // that member to the friend, which it confirms with a proof sealed to our
    // long-term key (MM-6 proof v2; see the block comment in the .cpp).
    // Confidentiality, stated exactly: no third party can READ any of it --
    // the hint is a digest of two values every member already knows, and the
    // proof is an authenticated box only the asker can open. What a third
    // party can still OBSERVE is traffic: a friend that names its per-group
    // key makes us address one unreadable NGC private packet to that key, so
    // a member can tell it was named, but not by whom or as what.
    // Everything below is guarded by mutex_, bounded (per friend AND
    // globally) and expires; see the kIdentity* limits in the .cpp.
    using IdentityClock = std::chrono::steady_clock;
    // friend pk hex (upper) -> digest hex -> when the friend last sent it.
    // Held only while the friend is online: it re-announces on reconnect.
    std::unordered_map<std::string, std::unordered_map<std::string, IdentityClock::time_point>> friend_group_digests_;
    // Reverse index: digest hex -> EVERY friend claiming it. A hint is not a
    // proof, so a second claimant must never displace the first.
    std::unordered_map<std::string, std::unordered_set<std::string>> digest_claimants_;
    size_t identity_claim_count_ = 0;
    // Our side of the match: sha256(chat_id || key) of every known NGC peer,
    // so a hint costs a lookup instead of rehashing every group.
    struct IndexedGroupMember {
        Tox_Group_Number group_number;
        std::string member_key;  // lower-case hex
    };
    std::unordered_map<std::string, std::vector<IndexedGroupMember>> member_digest_index_;  // digest hex ->
    std::unordered_map<std::string, std::string> member_digest_by_slot_;  // "<group>|<key lower>" -> digest hex
    struct ProvenGroupMember {
        std::string friend_hex;
        Tox_Group_Number group_number;
        IdentityClock::time_point proven_at;
    };
    std::unordered_map<std::string, ProvenGroupMember> member_key_to_friend_;  // member key (lower) -> PROVEN friend
    struct PendingIdentityChallenge {
        std::string friend_hex;
        Tox_Group_Number group_number;
        std::string member_key;
        IdentityClock::time_point sent_at;
    };
    std::unordered_map<std::string, PendingIdentityChallenge> pending_identity_challenges_;  // nonce hex ->
    // Responder side: challenges already answered, "<friend>|<chat_id>|<nonce>"
    // -> when; the deque holds the same keys oldest-first for expiry/eviction.
    std::unordered_map<std::string, IdentityClock::time_point> answered_identity_challenges_;
    std::deque<std::pair<IdentityClock::time_point, std::string>> answered_identity_challenge_order_;
    struct IdentityRateWindow {
        IdentityClock::time_point window_start{};
        uint32_t hint_packets = 0;
        uint32_t new_digests = 0;
        uint32_t proofs_sent = 0;
        // Opening received proofs. Only ever charged to the GLOBAL window: the
        // sender is an NGC group peer, and its long-term key is precisely what
        // we do not know yet, so there is no friend to charge it to.
        uint32_t proof_verifies = 0;
        // Received GROUP RECEIPTS, charged per authenticated NGC sender. The
        // replay filter only stops the SAME receipt twice; distinct msgIDs from
        // one member were unbounded, and each one costs a Dart event plus two
        // history scans on the way to the tally.
        uint32_t receipts_in = 0;
    };
    std::unordered_map<std::string, IdentityRateWindow> identity_rate_by_friend_;  // friend pk hex ->
    // Received-proof windows keyed by the AUTHENTICATED NGC group sender (lower
    // hex). Charged before any per-packet work, so an unchallenged member
    // cannot make us scan and record for free and a single hostile member
    // cannot spend the global crypto window. Bounded by kMaxProofVerifySenders
    // and pruned with the rest of the identity state.
    std::unordered_map<std::string, IdentityRateWindow> identity_rate_by_group_sender_;
    // Received-RECEIPT windows, keyed the same way but in a SEPARATE table on
    // purpose (codex 2026-09-26): sharing the proof table let the two budgets
    // evict each other. Across public groups, kMaxProofVerifySenders distinct
    // member keys can each send one structurally valid receipt with an invented
    // msgID, fill the table, and have it refuse both a new honest reader's
    // receipt AND a challenged member's MM-6 proof until the entries expire —
    // i.e. a receipt flood could starve the identity proofs the fill-up bound
    // exists to protect. Separate tables, separate caps
    // (kMaxGroupReceiptSenders); both pruned in PruneIdentityStateLocked.
    std::unordered_map<std::string, IdentityRateWindow> group_receipt_rate_by_sender_;
    IdentityRateWindow identity_rate_global_;
    // The receipt counterpart, kept separate for the same reason its per-sender
    // table is: a receipt flood must not spend the proofs' global budget
    // (kMaxGroupReceiptsGlobal explains the ordering and the size).
    IdentityRateWindow group_receipt_rate_global_;
    // MM-6 observability (guarded by mutex_). Counters plus the last proof
    // payload we received, verbatim: the auto_tests use it to assert that what
    // a named-but-uninvolved member receives is a box, not a readable proof.
    struct Mm6Diag {
        uint64_t proofs_sent = 0;
        uint64_t proofs_in = 0;
        uint64_t proofs_accepted = 0;
        uint64_t proofs_rejected = 0;
        std::string last_proof_payload_hex;
        // Group receipts arriving on the same private channel. `in` counts every
        // structurally valid receipt from an authenticated member (i.e. every
        // one that reached the per-sender meter), and the three below say what
        // happened to it. Exported as the "groupReceipts" block of
        // Mm6DiagJson so auto_tests can assert the budget from the outside.
        uint64_t group_receipts_in = 0;
        uint64_t group_receipts_refused = 0;
        // Refused by the SHARED ceiling rather than by the sender's own window:
        // told apart so "one flooder" and "everyone at once" are distinguishable
        // in the diag.
        uint64_t group_receipts_refused_global = 0;
        uint64_t group_receipts_replayed = 0;
        uint64_t group_receipts_forwarded = 0;
    };
    Mm6Diag mm6_diag_;
    IdentityClock::time_point identity_last_prune_{};
    std::unordered_set<uint32_t> online_identity_friends_;  // friends already sent our hints this session
    // Group receipt replay filter: "<group id>|<sender key lower>|<type>|<msgID>"
    // -> first seen; the deque holds the same keys oldest-first.
    std::unordered_map<std::string, IdentityClock::time_point> seen_group_receipts_;
    std::deque<std::pair<IdentityClock::time_point, std::string>> seen_group_receipt_order_;
    // Helpers for the state above; callers hold mutex_.
    // (not "force": toxcore's attributes.h #defines that word away)
    void PruneIdentityStateLocked(IdentityClock::time_point now, bool force_prune);
    void EraseIdentityClaimLocked(const std::string& friend_hex, const std::string& digest);
    void DropFriendIdentityClaimsLocked(const std::string& friend_hex);
    void EraseIndexedGroupMemberLocked(Tox_Group_Number group_number, const std::string& member_key_lower);
    bool TakeIdentityBudgetLocked(IdentityRateWindow& window, IdentityClock::time_point now,
                                  uint32_t IdentityRateWindow::*counter, uint32_t limit);
    // One received-proof verification charged to this NGC sender. False = over
    // budget, or the sender table is full: drop the packet before spending
    // anything on it.
    // Whether WE have an unexpired identity challenge outstanding for this
    // (group, authenticated sender). Cheap, crypto-free, and the gate that
    // keeps an unchallenged sender from consuming metering state at all.
    bool HasPendingChallengeForSenderLocked(Tox_Group_Number group_number,
                                           const std::string& sender_hex,
                                           IdentityClock::time_point now) const;
    bool TakeGroupSenderProofBudgetLocked(const std::string& sender_hex,
                                          IdentityClock::time_point now);
    // One received GROUP RECEIPT charged to this NGC sender. False = over
    // budget, or the receipt sender table is full: drop the packet before it
    // costs a replay-cache slot, a Dart event and two history scans. Metered in
    // group_receipt_rate_by_sender_, NOT the proof table, so neither budget can
    // evict the other.
    bool TakeGroupSenderReceiptBudgetLocked(const std::string& sender_hex,
                                            IdentityClock::time_point now);
    // Pending challenges for (group, member) whose asker no longer claims that
    // member's digest. They hold a slot the verifier scans and an honest
    // claimant needs; nothing will ever answer them.
    void DropStaleChallengesForMemberLocked(Tox_Group_Number group_number,
                                            const std::string& member_key_lower,
                                            const std::string& digest);
    // Index every cached NGC peer that is not indexed yet (and drop entries
    // whose peer left the cache). Takes mutex_ itself; hashes outside it.
    void SyncMemberDigestIndex(Tox* tox);
    // Sends one friend-channel challenge per (friend, group, member) candidate,
    // skipping those already pending and those over the per-friend cap.
    void IssueIdentityChallenges(Tox* tox, const std::vector<PendingIdentityChallenge>& candidates);
    // NGC group numbers created by a join/accept in THIS session that have not
    // connected yet: only these are undone when the group refuses us.
    std::unordered_set<Tox_Group_Number> fresh_group_joins_;
    // Invites accepted in this session whose join toxcore has not confirmed
    // yet: group_number -> (invite id, the invite). Restored on refusal.
    std::unordered_map<Tox_Group_Number, std::pair<std::string, PendingInvite>> accepted_invites_;
    void MarkFreshGroupJoin(Tox_Group_Number group_number);
    std::atomic<uint64_t> next_message_seq_{1};
    std::atomic<uint64_t> next_group_seq_{1};
    uint64_t next_pending_delivery_root_id_{1};
    std::unordered_map<uint64_t, PendingDeliveryRoot> pending_delivery_roots_;
    std::unordered_map<uint64_t, uint64_t> pending_delivery_fragments_;
    std::mutex pending_deliveries_mutex_;
    static constexpr std::chrono::minutes kPendingDeliveryTtl{10};
    static constexpr std::size_t kMaxPendingDeliveries = 4096;
    // Per-instance sub-managers (R-06: owned by this instance, no singleton)
    std::unique_ptr<V2TIMMessageManagerImpl> message_manager_;
    std::unique_ptr<V2TIMGroupManagerImpl> group_manager_;
    std::unique_ptr<V2TIMConversationManagerImpl> conversation_manager_;
    std::unique_ptr<V2TIMCommunityManagerImpl> community_manager_;
    std::unique_ptr<V2TIMFriendshipManagerImpl> friendship_manager_;
    // Per-instance signaling manager (multi-instance support)
    std::unique_ptr<V2TIMSignalingManagerImpl> signaling_manager_;
    
    // TODO: Consider mapping for friend numbers to UserIDs if needed frequently
    // std::unordered_map<uint32_t, V2TIMString> friend_number_to_user_id_;
    // std::unordered_map<V2TIMString, uint32_t> user_id_to_friend_number_;

    // --- Internal Handler Methods ---
    void HandleGroupMessage(uint32_t conference_number, uint32_t peer_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length);
    void HandleFriendMessage(uint32_t friend_number, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length);
    void HandleFriendCustomMessage(uint32_t friend_number, const uint8_t* data, size_t length);
    void HandleFriendControlMessage(uint32_t friend_number, tim2tox::control::Type packet_type, const uint8_t* data, size_t length);
    void DeliverFriendMessage(V2TIMMessage& message, const V2TIMString& sender_user_id, const uint8_t* sender_public_key, uint8_t custom_route);
    void NotifyFriendActionMessage(const V2TIMString& sender_user_id, const uint8_t* text, size_t length);
    void NotifyGroupActionMessage(const V2TIMString& group_id, const V2TIMString& sender_user_id, const uint8_t* text, size_t length);
    void HandleFriendReadReceipt(uint32_t friend_number, uint32_t tox_message_number);
    void TrackPendingDelivery(uint32_t friend_number, const std::vector<uint32_t>& tox_message_numbers, const V2TIMString& msg_id, const V2TIMString& user_id);
    void RemovePendingDeliveryRootLocked(uint64_t root_id);
    void ClearPendingDeliveries();
public:
    // An invite the user has not answered yet (auto-accept off). `id` is the
    // key JoinGroup() accepts it under.
    struct PendingGroupInviteInfo {
        std::string id;
        std::string inviter_userID;
        PendingInviteKind kind;
        std::string group_name;
        int64_t received_ms;
        std::vector<uint8_t> cookie;
    };
    std::vector<PendingGroupInviteInfo> GetPendingGroupInvites();
    // Re-create an unanswered invite saved by the client in an earlier
    // session. The inviter is looked up by public key (friend numbers are not
    // a stable identity); false if they are no longer a friend.
    bool RestorePendingGroupInvite(const PendingGroupInviteInfo& invite);
    // Decline: Tox has no "reject" packet, so this only forgets the cookie.
    bool RejectPendingGroupInvite(const V2TIMString& inviteID);
private:
    // Insert an unanswered invite unless the same friend already has the same
    // cookie pending (inviters re-send; one prompt per invitation). Returns the
    // id the invite is stored under. Caller must NOT hold mutex_.
    V2TIMString StorePendingInvite(const V2TIMString& inviteID, PendingInvite&& inv);
    // Clears all per-session group/conference state; see UnInitSDK.
    void ResetGroupSessionState();
    void ClearPendingDeliveriesForFriend(uint32_t friend_number);
    void PrunePendingDeliveriesLocked(std::chrono::steady_clock::time_point now);
    V2TIMString SendC2CTextMessageWithType(const V2TIMString& text, const V2TIMString& userID, const V2TIMBuffer& cloudCustomData, V2TIMSendCallback* callback, bool force_action);
    V2TIMString SendGroupTextMessageWithType(const V2TIMString& text, const V2TIMString& groupID, V2TIMMessagePriority priority, const V2TIMBuffer& cloudCustomData, V2TIMSendCallback* callback, bool force_action);
    V2TIMString SendC2CCustomMessageWithType(const V2TIMBuffer& customData, const V2TIMString& userID, uint8_t controlType, V2TIMSendCallback* callback);
    void HandleSelfConnectionStatus(TOX_CONNECTION connection_status);
    void HandleFriendRequest(const uint8_t* public_key, const uint8_t* message, size_t length);
    void HandleFriendName(uint32_t friend_number, const uint8_t* name, size_t length);
    void HandleFriendStatusMessage(uint32_t friend_number, const uint8_t* message, size_t length);
    void HandleFriendStatus(uint32_t friend_number, TOX_USER_STATUS status);
    void HandleFriendConnectionStatus(uint32_t friend_number, TOX_CONNECTION connection_status);
    void HandleGroupTitle(uint32_t conference_number, uint32_t peer_number, const uint8_t* title, size_t length);
    void HandleGroupPeerName(uint32_t conference_number, uint32_t peer_number, const uint8_t* name, size_t length);
    void HandleGroupPeerListChanged(uint32_t conference_number);
    void HandleGroupConnected(uint32_t conference_number);
    
    // Tox group handlers
    void HandleGroupMessageGroup(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id);
    void HandleGroupCustomPacket(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* data, size_t length);
    void HandleGroupCustomPrivatePacket(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* data, size_t length);
    void HandleGroupPrivateMessage(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_MESSAGE_TYPE type, const uint8_t* message, size_t length, Tox_Group_Message_Id message_id);
    void HandleGroupTopic(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* topic, size_t length);
    void HandleGroupPeerNameGroup(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, const uint8_t* name, size_t length);
    void HandleGroupPeerJoin(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id);
    void HandleGroupPeerExit(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, Tox_Group_Exit_Type exit_type, const uint8_t* name, size_t name_length);
    void HandleGroupModeration(Tox_Group_Number group_number, Tox_Group_Peer_Number source_peer_id, Tox_Group_Peer_Number target_peer_id, Tox_Group_Mod_Event mod_type);
    // Erase all NON-Tox local state for a group (group_number/chat-id maps + the
    // peer-id cache). Mirrors the inline cleanup in QuitGroup; used when this
    // client is removed from a group WITHOUT a local QuitGroup call (e.g. being
    // kicked). Acquires mutex_ internally — callers must NOT hold it.
    void EraseGroupLocalState(const V2TIMString& groupID);
    // Drop one (group, public key) -> peer_id cache entry. Case-insensitive on
    // the key. Acquires mutex_ internally.
    void ErasePeerIdCacheEntry(Tox_Group_Number group_number, const std::string& public_key_hex);
    void HandleGroupSelfJoin(Tox_Group_Number group_number);
    void HandleGroupJoinFail(Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type);
    void HandleGroupPrivacyState(Tox_Group_Number group_number, Tox_Group_Privacy_State privacy_state);
    void HandleGroupVoiceState(Tox_Group_Number group_number, Tox_Group_Voice_State voice_state);
    void HandleGroupPeerStatus(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id, TOX_USER_STATUS status);
    // TODO: Add handlers for other Tox callbacks (read receipts, file transfer, etc.)

    // Constructor and destructor are now public (declared above)

    // Delete copy constructor and assignment operator
    V2TIMManagerImpl(const V2TIMManagerImpl&) = delete;
    V2TIMManagerImpl& operator=(const V2TIMManagerImpl&) = delete;

    friend class V2TIMManager; // Allow V2TIMManager::GetInstance() potentially
    friend class V2TIMGroupManagerImpl; // Allow V2TIMGroupManagerImpl to access private members
    // Allow tim2tox_ffi functions to access private members for chat ID lookup
    friend int tim2tox_ffi_get_group_chat_id(int64_t instance_id, const char* group_id, char* out_chat_id, int out_len);
};

#endif // __V2TIM_MANAGER_IMPL_H__
