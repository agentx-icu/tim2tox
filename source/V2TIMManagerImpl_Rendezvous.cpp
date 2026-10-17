// Rendezvous groups — the Tox-calling half. Bookkeeping and planning live in
// RendezvousGroups (no Tox calls); this file performs the calls under the
// session rules: admission flag -> in-flight count -> captured generation +
// session epoch -> pin (AcquireToxSession) -> epoch re-check -> Tox call ->
// generation re-check before anything is recorded. toxcore callbacks only
// record state and queue the next Tick; membership changes happen on the
// event thread.
//
// See doc/architecture/RENDEZVOUS_GROUPS.md.
#include "V2TIMManagerImpl.h"

#include <chrono>
#include <cstring>
#include <thread>

#include "RendezvousGroups.h"
#include "Tim2ToxGroupPacket.h"
#include "ToxUtil.h"
#include "V2TIMLog.h"
#include "tox.h"
#include "toxcore/mono_time.h"
#include "toxcore/tox_private.h"

using tim2tox::RendezvousGroups;

namespace {

constexpr std::chrono::milliseconds kInflightDrainTimeout{5000};
constexpr std::chrono::milliseconds kInflightPoll{10};

std::string GroupNameOf(Tox* tox, Tox_Group_Number group_number) {
    Tox_Err_Group_State_Query err;
    const size_t size = tox_group_get_name_size(tox, group_number, &err);
    if (err != TOX_ERR_GROUP_STATE_QUERY_OK || size == 0 || size > TOX_GROUP_MAX_GROUP_NAME_LENGTH) return "";
    std::string name(size, '\0');
    if (!tox_group_get_name(tox, group_number, reinterpret_cast<uint8_t*>(name.data()), &err) ||
        err != TOX_ERR_GROUP_STATE_QUERY_OK) {
        return "";
    }
    return name;
}

// True when the group is gone from toxcore afterwards. tox_group_leave deletes
// the group even when the part packet cannot be sent (toxcore tox.c: FAIL_SEND
// "the group was still successfully deleted"; gc_group_exit sets flag_exit
// before sending), and GROUP_NOT_FOUND means there was nothing to leave. Any
// other error (none exists today for an empty part message; defensive) means
// toxcore still holds the group: the caller keeps owning it and retries.
bool LeaveGroup(Tox* tox, Tox_Group_Number group_number, const char* why) {
    Tox_Err_Group_Leave err;
    const bool ok = tox_group_leave(tox, group_number, nullptr, 0, &err);
    const bool gone = ok || err == TOX_ERR_GROUP_LEAVE_OK || err == TOX_ERR_GROUP_LEAVE_GROUP_NOT_FOUND ||
                      err == TOX_ERR_GROUP_LEAVE_FAIL_SEND;
    if (!gone) {
        V2TIM_LOG(kWarning, "[Rendezvous] tox_group_leave({}) failed with {} ({}); the group is kept as a zombie",
                  group_number, static_cast<int>(err), why);
    }
    return gone;
}

// One admitted operation: counted in flight from before the registry lookup
// until its result is recorded, so LeaveAll() can wait for it and a later
// generation/epoch is detected before AND after the Tox call.
struct Admission {
    explicit Admission(RendezvousGroups& r) : registry(r) { registry.BeginInflight(); }
    ~Admission() { registry.EndInflight(); }
    Admission(const Admission&) = delete;
    Admission& operator=(const Admission&) = delete;
    RendezvousGroups& registry;
};

}  // namespace

uint64_t V2TIMManagerImpl::RendezvousNowMs(const Tox* tox) {
    if (tox != nullptr && tox->mono_time != nullptr) return mono_time_get_ms(tox->mono_time);
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

// --- event sink -----------------------------------------------------------------

void V2TIMManagerImpl::SetRendezvousEventSink(std::function<void(const std::string&)> sink) {
    bool installed = false;
    {
        std::lock_guard<std::mutex> lock(rendezvous_sink_mutex_);
        rendezvous_sink_ = std::move(sink);
        installed = static_cast<bool>(rendezvous_sink_);
    }
    if (!installed) return;
    for (const std::string& line : rendezvous_.TakeBufferedLines()) RendezvousEmit(line);
}

void V2TIMManagerImpl::RendezvousEmit(const std::string& line) {
    std::function<void(const std::string&)> sink;
    {
        std::lock_guard<std::mutex> lock(rendezvous_sink_mutex_);
        sink = rendezvous_sink_;
    }
    if (sink) {
        sink(line);
    } else {
        rendezvous_.BufferLine(line);
    }
}

void V2TIMManagerImpl::SetRendezvousConvention(const std::string& name_prefix, const std::string& seed_prefix) {
    RendezvousGroups::Convention convention;
    if (!name_prefix.empty()) convention.name_prefix = name_prefix;
    if (!seed_prefix.empty()) convention.seed_prefix = seed_prefix;
    rendezvous_.SetConvention(convention);
}

bool V2TIMManagerImpl::IsRendezvousGroupNumber(Tox_Group_Number group_number) const {
    return rendezvous_.Owns(group_number);
}

bool V2TIMManagerImpl::RendezvousInviteIsOurs(const uint8_t* invite_data, size_t length,
                                              const std::string& group_name) const {
    if (invite_data == nullptr || length < RendezvousGroups::kChatIdSize) return false;
    const std::string chat_id_hex = RendezvousGroups::Hex(invite_data, RendezvousGroups::kChatIdSize);
    if (rendezvous_.HasCell(chat_id_hex)) return true;
    return rendezvous_.IsRendezvousGroup(group_name, invite_data);
}

// --- client requests -------------------------------------------------------------

int V2TIMManagerImpl::RendezvousJoin(const uint8_t* seed, size_t seed_len, const char* name, const char* nick) {
    if (seed == nullptr || seed_len != RendezvousGroups::kSeedSize || name == nullptr || nick == nullptr ||
        name[0] == '\0') {
        return 0;
    }
    if (std::strlen(name) > TOX_GROUP_MAX_GROUP_NAME_LENGTH) return 0;
    // Protocol: the nick is 8 random lower-case hex characters, never a user
    // name (nothing identifying rides the group).
    if (!RendezvousGroups::IsValidNick(nick)) return 0;
    if (!rendezvous_.Accepting()) return 0;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return 0;
    std::array<uint8_t, RendezvousGroups::kSeedSize> seed_copy{};
    std::memcpy(seed_copy.data(), seed, seed_copy.size());
    const int rc = rendezvous_.RequestJoin(seed_copy, name, nick, RendezvousNowMs(session.tox()));
    if (rc == 1) PostToEventThread([this]() { RendezvousTick(); });
    return rc;
}

int V2TIMManagerImpl::RendezvousLeave(const char* chat_id_hex) {
    if (chat_id_hex == nullptr || chat_id_hex[0] == '\0' || !rendezvous_.Accepting()) return 0;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return 0;
    const bool ok = rendezvous_.RequestLeave(chat_id_hex, RendezvousNowMs(session.tox()));
    if (ok) PostToEventThread([this]() { RendezvousTick(); });
    return ok ? 1 : 0;
}

int V2TIMManagerImpl::RendezvousLeaveAll() {
    if (!rendezvous_.Accepting()) return -1;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return -1;
    // A client leave-all is a generation boundary: joins still in flight must
    // not publish into cells that are being left; they leave what they
    // created instead (RendezvousExecute).
    rendezvous_.BumpGeneration();
    const size_t n = rendezvous_.RequestLeaveAll(RendezvousNowMs(session.tox()));
    if (n > 0) PostToEventThread([this]() { RendezvousTick(); });
    return static_cast<int>(n);
}

int V2TIMManagerImpl::RendezvousPeerCount(const char* chat_id_hex) {
    if (chat_id_hex == nullptr || !rendezvous_.Accepting()) return -1;
    return rendezvous_.PeerCount(chat_id_hex);
}

uint64_t V2TIMManagerImpl::RendezvousDropCount() const {
    return rendezvous_.DropCount();
}

int V2TIMManagerImpl::RendezvousSend(const char* chat_id_hex, const char* peer_pk_hex, const uint8_t* data, int len) {
    if (chat_id_hex == nullptr || len < 0 || (len > 0 && data == nullptr)) return 0;
    if (static_cast<size_t>(len) > RendezvousGroups::kMaxPayloadBytes) return -1;
    // Admission FIRST: in flight, generation and epoch are captured before the
    // registry lookup, so a shutdown + re-init between the lookup and the pin
    // is caught by the epoch check and the group number is never sent into a
    // session it does not belong to.
    const Admission admission(rendezvous_);
    const uint64_t generation = rendezvous_.Generation();
    const int64_t epoch = GetSessionEpoch();
    if (epoch == 0 || !rendezvous_.Accepting()) return 0;
    Tox_Group_Number group_number = UINT32_MAX;
    Tox_Group_Peer_Number peer_id = UINT32_MAX;
    const bool is_private = peer_pk_hex != nullptr && peer_pk_hex[0] != '\0';
    if (is_private) {
        if (!rendezvous_.PeerIdFor(chat_id_hex, peer_pk_hex, &group_number, &peer_id)) {
            return rendezvous_.GroupNumberFor(chat_id_hex, &group_number) ? -2 : -3;
        }
    } else if (!rendezvous_.GroupNumberFor(chat_id_hex, &group_number)) {
        return -3;
    }
    const ToxSessionGuard session = AcquireToxSession();
    if (!session || session.epoch() != epoch || session.Expired()) return 0;
    const std::vector<uint8_t> frame =
        tim2tox::group_packet::Wrap(tim2tox::group_packet::kRendezvous, data, static_cast<size_t>(len));
    bool sent = false;
    int result = 0;
    if (is_private) {
        Tox_Err_Group_Send_Custom_Private_Packet err;
        sent = tox_group_send_custom_private_packet(session.tox(), group_number, peer_id, true, frame.data(),
                                                    frame.size(), &err) &&
               err == TOX_ERR_GROUP_SEND_CUSTOM_PRIVATE_PACKET_OK;
        if (!sent && err == TOX_ERR_GROUP_SEND_CUSTOM_PRIVATE_PACKET_PEER_NOT_FOUND) result = -2;
    } else {
        Tox_Err_Group_Send_Custom_Packet err;
        sent = tox_group_send_custom_packet(session.tox(), group_number, true, frame.data(), frame.size(), &err) &&
               err == TOX_ERR_GROUP_SEND_CUSTOM_PACKET_OK;
    }
    // A send has nothing to undo; a late generation mismatch only means the
    // result is not reported as a success.
    if (sent && rendezvous_.Generation() == generation) result = 1;
    return result;
}

// --- planner driver -------------------------------------------------------------------

void V2TIMManagerImpl::RendezvousTick() {
    if (!running_.load(std::memory_order_acquire)) return;
    if (rendezvous_.CellCount() == 0 && !rendezvous_.HasZombies() && rendezvous_.Retiring().empty()) return;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return;
    Tox* tox = session.tox();
    const uint64_t now = RendezvousNowMs(tox);
    // Zombies first (never cells): a group number is only meaningful inside
    // the session that noted it, and ResetGroupSessionState() (end of every
    // session) drops the set, so a zombie here belongs to this session.
    RendezvousLeaveZombies(tox);
    RendezvousConfirmRetired(tox, now);
    const std::vector<RendezvousGroups::Action> actions = rendezvous_.Plan(now);
    for (const RendezvousGroups::Action& action : actions) RendezvousExecute(session, action, now);
}

// tox_group_leave only flags the group; toxcore deletes it during its next
// iteration. Until then the group exists (a rejoin would find and reuse it),
// so a left cell stays owned as "retiring" and is only released once the
// group number is gone or already belongs to another group.
void V2TIMManagerImpl::RendezvousConfirmRetired(Tox* tox, uint64_t now_ms) {
    for (const auto& retiring : rendezvous_.Retiring()) {
        uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
        Tox_Err_Group_State_Query err;
        const bool present = tox_group_get_chat_id(tox, retiring.first, chat_id, &err) &&
                             err == TOX_ERR_GROUP_STATE_QUERY_OK &&
                             RendezvousGroups::Hex(chat_id, sizeof(chat_id)) == retiring.second;
        if (!present) rendezvous_.OnRetired(retiring.second, retiring.first, now_ms);
    }
}

// A group number of a retiring cell/orphan may be reused by an ordinary
// group created between toxcore's deletion and the next tick. Called from
// the self-join path: when the number now holds another chat id the
// retiring entry is released at once and the callback is NOT diverted.
bool V2TIMManagerImpl::RendezvousReleaseIfReused(Tox_Group_Number group_number) {
    const auto chat_id_hex = rendezvous_.RetiringChatIdOf(group_number);
    if (!chat_id_hex) return false;  // an active cell, or not ours: nothing to release here
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return false;
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    Tox_Err_Group_State_Query err;
    const bool same = tox_group_get_chat_id(session.tox(), group_number, chat_id, &err) &&
                      err == TOX_ERR_GROUP_STATE_QUERY_OK &&
                      RendezvousGroups::Hex(chat_id, sizeof(chat_id)) == *chat_id_hex;
    if (same) return false;
    rendezvous_.OnRetired(*chat_id_hex, group_number, RendezvousNowMs(session.tox()));
    return true;
}

// True when `group_number` currently holds `chat_id_hex` in toxcore.
bool V2TIMManagerImpl::RendezvousGroupIs(Tox* tox, Tox_Group_Number group_number, const std::string& chat_id_hex) {
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    Tox_Err_Group_State_Query err;
    return tox_group_get_chat_id(tox, group_number, chat_id, &err) && err == TOX_ERR_GROUP_STATE_QUERY_OK &&
           RendezvousGroups::Hex(chat_id, sizeof(chat_id)) == chat_id_hex;
}

void V2TIMManagerImpl::RendezvousLeaveZombies(Tox* tox) {
    for (const auto& zombie : rendezvous_.TakeZombies()) {
        if (LeaveGroup(tox, zombie.first, "zombie")) {
            V2TIM_LOG(kInfo, "[Rendezvous] zombie rendezvous group left: group_number={}", zombie.first);
            rendezvous_.NoteRetiringOrphan(zombie.first, zombie.second);  // exists until toxcore iterates
            RendezvousEmit(RendezvousGroups::LeftLine(zombie.second, "left"));
        } else {
            rendezvous_.NoteZombie(zombie.first, zombie.second);  // retried on the next tick
        }
    }
}

void V2TIMManagerImpl::RendezvousExecute(const ToxSessionGuard& session, const RendezvousGroups::Action& action,
                                         uint64_t now_ms) {
    using Kind = RendezvousGroups::ActionKind;
    Tox* tox = session.tox();
    const Admission admission(rendezvous_);
    // The generation the action was planned under (not read now: a LeaveAll
    // between Plan() and here must make this an orphan too).
    const uint64_t generation = action.generation;
    const int64_t epoch = session.epoch();
    if (action.kind != Kind::kLeave && !rendezvous_.Accepting()) return;
    if (session.Expired() || GetSessionEpoch() != epoch) return;

    // Undo for a join/found nobody recorded (the cell left or the registry
    // moved on while the call was in flight): leave what we just created,
    // through a pin that is still current; when the leave itself fails the
    // group stays owned as a zombie and is retried from Tick().
    auto undo = [&](Tox_Group_Number gn, const char* why) {
        if (gn == UINT32_MAX) return;
        // Only through a pin that is still current. A group number means
        // nothing outside the session that produced it: an operation that
        // outlived its session has nothing to leave (that Tox is gone with its
        // groups) and must never note a zombie into the next registry.
        if (session.Expired() || GetSessionEpoch() != epoch) return;
        if (LeaveGroup(tox, gn, why)) {
            // Left, but toxcore deletes it only on its next iteration: a
            // join for the same chat id meanwhile would rejoin it.
            rendezvous_.NoteRetiringOrphan(gn, action.chat_id_hex);
        } else {
            rendezvous_.NoteZombie(gn, action.chat_id_hex);
        }
    };

    switch (action.kind) {
        case Kind::kJoin: {
            Tox_Err_Group_Join err;
            const Tox_Group_Number gn = tox_group_join(
                tox, action.chat_id.data(), reinterpret_cast<const uint8_t*>(action.nick.data()), action.nick.size(),
                nullptr, 0, &err);
            const bool ok = err == TOX_ERR_GROUP_JOIN_OK && gn != UINT32_MAX;
            V2TIM_LOG(kInfo, "[Rendezvous] join cell={} ok={} err={} group_number={}", action.chat_id_hex.substr(0, 12),
                      ok, static_cast<int>(err), gn);
            // The generation is compared under the registry lock, atomically
            // with the record: a LeaveAll between the Tox call and here makes
            // this an orphan.
            if (!rendezvous_.OnJoinIssued(action.chat_id_hex, gn, ok, now_ms, generation, action.attempt)) {
                if (ok) undo(gn, "join outlived its cell or generation");
                return;
            }
            // A synchronous failure is reported like any other failed attempt:
            // the client learns the cell is backing off (the registry retries).
            if (!ok) RendezvousEmit(RendezvousGroups::LeftLine(action.chat_id_hex, "failed"));
            break;
        }
        case Kind::kFound: {
            Tox_Err_Group_New err;
            const Tox_Group_Number gn = tox_group_new_with_seed(
                tox, TOX_GROUP_PRIVACY_STATE_PUBLIC, reinterpret_cast<const uint8_t*>(action.name.data()),
                action.name.size(), reinterpret_cast<const uint8_t*>(action.nick.data()), action.nick.size(),
                action.seed.data(), &err);
            const bool ok = err == TOX_ERR_GROUP_NEW_OK && gn != UINT32_MAX;
            V2TIM_LOG(kInfo, "[Rendezvous] found cell={} ok={} err={} group_number={}", action.chat_id_hex.substr(0, 12),
                      ok, static_cast<int>(err), gn);
            if (!rendezvous_.OnFoundIssued(action.chat_id_hex, gn, ok, now_ms, generation, action.attempt)) {
                if (ok) undo(gn, "found outlived its cell or generation");
                return;
            }
            RendezvousEmit(ok ? RendezvousGroups::JoinedLine(action.chat_id_hex, true)
                              : RendezvousGroups::LeftLine(action.chat_id_hex, "failed"));
            break;
        }
        case Kind::kLeave: {
            // Identity first: a number is only left while it still holds our
            // chat id (toxcore may have deleted and reused it).
            const bool ours =
                action.group_number != UINT32_MAX && RendezvousGroupIs(tox, action.group_number, action.chat_id_hex);
            const bool gone = !ours || LeaveGroup(tox, action.group_number, action.reason.c_str());
            if (!gone) {
                // toxcore kept the group: still owned (re-planned leave), or
                // a zombie when the registry moved on under us; never lost.
                if (rendezvous_.Generation() == generation) {
                    rendezvous_.OnLeaveFailed(action.chat_id_hex, now_ms);
                } else if (!session.Expired() && GetSessionEpoch() == epoch) {
                    rendezvous_.NoteZombie(action.group_number, action.chat_id_hex);
                }
                return;
            }
            // Left (or already gone): the cell must reflect it whatever the
            // generation did meanwhile — a LeaveAll that preempted this leave
            // finds the cell retiring and marks it to be forgotten; it never
            // plans a second leave of a number toxcore may reuse.
            V2TIM_LOG(kInfo, "[Rendezvous] leave cell={} reason={} group_number={}", action.chat_id_hex.substr(0, 12),
                      action.reason, action.group_number);
            rendezvous_.OnLeaveIssued(action.chat_id_hex, action.reason, now_ms, action.group_number);
            if (action.reason != "refound") RendezvousEmit(RendezvousGroups::LeftLine(action.chat_id_hex, action.reason));
            break;
        }
    }
}

// --- lifecycle --------------------------------------------------------------------------

void V2TIMManagerImpl::RendezvousStart() {
    // The registry was cleared by ResetGroupSessionState() when the previous
    // session ended; the restore sweep that ran just before may have noted
    // zombies, which must survive here.
    rendezvous_.SetAccepting(true);
    rendezvous_.BumpGeneration();
    if (rendezvous_.HasZombies() || !rendezvous_.Retiring().empty()) PostToEventThread([this]() { RendezvousTick(); });
}

bool V2TIMManagerImpl::RendezvousLeaveAllNow() {
    // Wait (bounded) for admitted operations; the generation already excludes
    // anything that finishes later from publishing.
    const auto deadline = std::chrono::steady_clock::now() + kInflightDrainTimeout;
    while (rendezvous_.Inflight() > 0 && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(kInflightPoll);
    }
    const ToxSessionGuard session = AcquireToxSession();
    if (session) {
        const uint64_t now = RendezvousNowMs(session.tox());
        // Zombies whose Tick() has not run yet (the event loop may never tick
        // again during teardown): leave them inline, with their left line.
        RendezvousLeaveZombies(session.tox());
        rendezvous_.RequestLeaveAll(now);
        for (const RendezvousGroups::Action& action : rendezvous_.Plan(now)) {
            if (action.kind == RendezvousGroups::ActionKind::kLeave) RendezvousExecute(session, action, now);
        }
        // Whatever could not be left (a failed leave re-planned above, or a
        // zombie that failed again) is logged; the restore sweep of the next
        // InitSDK leaves it, the savedata carries only its group.
        for (const auto& zombie : rendezvous_.TakeZombies()) {
            V2TIM_LOG(kWarning, "[Rendezvous] group {} could not be left at shutdown; left on the next init",
                      zombie.first);
        }
    }
    // Ownership is NOT cleared here: the event thread may iterate again
    // before UnInitSDK stops it, and toxcore delivers pending packets of the
    // flagged groups before deleting them. The retiring cells and orphans
    // keep diverting those callbacks until ResetGroupSessionState() (after
    // the thread stopped) clears the registry.
    return true;
}

void V2TIMManagerImpl::RendezvousShutdown() {
    rendezvous_.SetAccepting(false);
    rendezvous_.BumpGeneration();
    // A non-consuming check: a zombie that is the only remaining state must
    // still be left below.
    // Nothing to leave: retiring entries (if any) keep diverting callbacks
    // until ResetGroupSessionState() clears the registry, see LeaveAllNow.
    const bool nothing_to_do =
        rendezvous_.CellCount() == 0 && rendezvous_.Inflight() == 0 && !rendezvous_.HasZombies();
    if (nothing_to_do) return;
    bool ran = false;
    const bool on_event_thread = event_thread_.joinable() && std::this_thread::get_id() == event_thread_.get_id();
    if (IsEventThreadRunning() && !on_event_thread) {
        ran = RunOnEventThread<bool>([this]() { return RendezvousLeaveAllNow(); });
    }
    if (!ran) RendezvousLeaveAllNow();
}

bool V2TIMManagerImpl::RendezvousRestoredZombie(Tox* tox, Tox_Group_Number group_number) {
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    Tox_Err_Group_State_Query err;
    if (!tox_group_get_chat_id(tox, group_number, chat_id, &err) || err != TOX_ERR_GROUP_STATE_QUERY_OK) return false;
    const std::string name = GroupNameOf(tox, group_number);
    if (name.empty() || !rendezvous_.IsRendezvousGroup(name, chat_id)) return false;
    const std::string chat_id_hex = RendezvousGroups::Hex(chat_id, sizeof(chat_id));
    if (LeaveGroup(tox, group_number, "restored from savedata")) {
        V2TIM_LOG(kInfo, "[Rendezvous] restored rendezvous group left on init: name={} group_number={}", name,
                  group_number);
        rendezvous_.NoteRetiringOrphan(group_number, chat_id_hex);  // gone once the loop iterates
        RendezvousEmit(RendezvousGroups::LeftLine(chat_id_hex, "left"));
    } else {
        // Still ours (callbacks diverted); Tick() retries the leave. Zombies
        // survive RendezvousStart(), which only opens admission.
        rendezvous_.NoteZombie(group_number, chat_id_hex);
    }
    return true;
}

// --- toxcore callbacks (record + queue only) ---------------------------------------------

void V2TIMManagerImpl::RendezvousOnSelfJoin(Tox_Group_Number group_number) {
    if (!rendezvous_.Accepting()) return;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return;
    if (const auto line = rendezvous_.OnSelfJoin(group_number, RendezvousNowMs(session.tox()))) RendezvousEmit(*line);
}

bool V2TIMManagerImpl::RendezvousSelfJoinOfZombie(Tox_Group_Number group_number) {
    if (rendezvous_.IsZombie(group_number)) return true;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return false;
    Tox* tox = session.tox();
    uint8_t chat_id[TOX_GROUP_CHAT_ID_SIZE];
    Tox_Err_Group_State_Query err;
    if (!tox_group_get_chat_id(tox, group_number, chat_id, &err) || err != TOX_ERR_GROUP_STATE_QUERY_OK) return false;
    const std::string name = GroupNameOf(tox, group_number);
    if (name.empty() || !rendezvous_.IsRendezvousGroup(name, chat_id)) return false;
    // Reached from the toxcore self-join callback: only mark here; Tick()
    // leaves it on the event thread between iterations (never from inside
    // the callback), and shutdown leaves whatever Tick() did not reach.
    rendezvous_.NoteZombie(group_number, RendezvousGroups::Hex(chat_id, sizeof(chat_id)));
    PostToEventThread([this]() { RendezvousTick(); });
    return true;
}

void V2TIMManagerImpl::RendezvousOnPeerJoin(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id) {
    if (!rendezvous_.Accepting()) return;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return;
    uint8_t pk[TOX_GROUP_PEER_PUBLIC_KEY_SIZE];
    Tox_Err_Group_Peer_Query err;
    if (!tox_group_peer_get_public_key(session.tox(), group_number, peer_id, pk, &err) ||
        err != TOX_ERR_GROUP_PEER_QUERY_OK) {
        return;
    }
    const std::string pk_hex = RendezvousGroups::Hex(pk, sizeof(pk));
    for (const std::string& line : rendezvous_.OnPeerJoin(group_number, peer_id, pk_hex, RendezvousNowMs(session.tox()))) {
        RendezvousEmit(line);
    }
}

void V2TIMManagerImpl::RendezvousOnPeerExit(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                            Tox_Group_Exit_Type exit_type) {
    if (!rendezvous_.Accepting()) return;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return;
    if (const auto line = rendezvous_.OnPeerExit(group_number, peer_id,
                                                 exit_type == TOX_GROUP_EXIT_TYPE_SELF_DISCONNECTED,
                                                 RendezvousNowMs(session.tox()))) {
        RendezvousEmit(*line);
    }
}

void V2TIMManagerImpl::RendezvousOnJoinFail(Tox_Group_Number group_number, Tox_Group_Join_Fail fail_type) {
    if (!rendezvous_.Accepting()) return;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return;
    if (const auto line = rendezvous_.OnJoinFail(group_number, fail_type == TOX_GROUP_JOIN_FAIL_PEER_LIMIT,
                                                 RendezvousNowMs(session.tox()))) {
        RendezvousEmit(*line);
    }
    PostToEventThread([this]() { RendezvousTick(); });
}

void V2TIMManagerImpl::RendezvousOnModeration(Tox_Group_Number group_number, Tox_Group_Peer_Number target_peer_id,
                                              Tox_Group_Mod_Event mod_type) {
    if (mod_type != TOX_GROUP_MOD_EVENT_KICK || !rendezvous_.Accepting()) return;
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return;
    Tox_Err_Group_Self_Query err;
    const Tox_Group_Peer_Number self_id = tox_group_self_get_peer_id(session.tox(), group_number, &err);
    if (err != TOX_ERR_GROUP_SELF_QUERY_OK || self_id != target_peer_id) return;
    if (const auto line = rendezvous_.OnKickedSelf(group_number, RendezvousNowMs(session.tox()))) RendezvousEmit(*line);
    PostToEventThread([this]() { RendezvousTick(); });
}

void V2TIMManagerImpl::RendezvousOnPacket(Tox_Group_Number group_number, Tox_Group_Peer_Number peer_id,
                                          const uint8_t* data, size_t length, bool is_private) {
    if (!rendezvous_.Accepting()) return;
    const uint8_t* payload = nullptr;
    size_t payload_length = 0;
    if (!tim2tox::group_packet::Unwrap(tim2tox::group_packet::kRendezvous, data, length, &payload, &payload_length)) {
        return;  // foreign or chat-kind packet in a rendezvous group: dropped
    }
    const ToxSessionGuard session = AcquireToxSession();
    if (!session) return;
    std::string pk_hex = rendezvous_.PeerPkFor(group_number, peer_id);
    if (pk_hex.empty()) {
        uint8_t pk[TOX_GROUP_PEER_PUBLIC_KEY_SIZE];
        Tox_Err_Group_Peer_Query err;
        if (tox_group_peer_get_public_key(session.tox(), group_number, peer_id, pk, &err) &&
            err == TOX_ERR_GROUP_PEER_QUERY_OK) {
            pk_hex = RendezvousGroups::Hex(pk, sizeof(pk));
        }
    }
    std::string line;
    const auto verdict = rendezvous_.OnPacket(group_number, peer_id, pk_hex, is_private, payload, payload_length,
                                              RendezvousNowMs(session.tox()), &line);
    if (verdict == RendezvousGroups::PacketVerdict::kEmit) RendezvousEmit(line);
}
