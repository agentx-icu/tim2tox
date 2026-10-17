// RendezvousGroups — bookkeeping and planner. See RendezvousGroups.h; the
// pure helpers (derivation, hex, line builders) live in
// RendezvousGroupsCodec.cpp and the toxcore-callback side (peer events,
// packet budgets, buffered lines) in RendezvousGroupsEvents.cpp.
#include "RendezvousGroups.h"

#include <algorithm>
#include <unordered_set>

namespace tim2tox {

RendezvousGroups::RendezvousGroups() { StoreOwned(std::make_shared<const OwnedSet>()); }

// --- owned snapshot -------------------------------------------------------------

std::shared_ptr<const RendezvousGroups::OwnedSet> RendezvousGroups::LoadOwned() const {
#if defined(__cpp_lib_atomic_shared_ptr)
    return owned_.load(std::memory_order_acquire);
#else
    std::lock_guard<std::mutex> lock(owned_mutex_);
    return owned_;
#endif
}

void RendezvousGroups::StoreOwned(std::shared_ptr<const OwnedSet> owned) {
#if defined(__cpp_lib_atomic_shared_ptr)
    owned_.store(std::move(owned), std::memory_order_release);
#else
    std::lock_guard<std::mutex> lock(owned_mutex_);
    owned_ = std::move(owned);
#endif
}

void RendezvousGroups::PublishOwnedLocked() {
    auto owned = std::make_shared<OwnedSet>();
    for (const auto& pair : cells_) {
        if (pair.second.group_number != UINT32_MAX) owned->insert(pair.second.group_number);
    }
    for (const auto& pair : zombies_) owned->insert(pair.first);
    for (const auto& pair : retiring_orphans_) owned->insert(pair.first);
    StoreOwned(std::shared_ptr<const OwnedSet>(std::move(owned)));
}

bool RendezvousGroups::Owns(uint32_t group_number) const {
    const std::shared_ptr<const OwnedSet> owned = LoadOwned();
    return owned && owned->count(group_number) != 0;
}

// --- admission / lifecycle ----------------------------------------------------

void RendezvousGroups::SetAccepting(bool accepting) {
    std::lock_guard<std::mutex> lock(mutex_);
    accepting_ = accepting;
}

bool RendezvousGroups::Accepting() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return accepting_;
}

uint64_t RendezvousGroups::Generation() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return generation_;
}

uint64_t RendezvousGroups::BumpGeneration() {
    std::lock_guard<std::mutex> lock(mutex_);
    return ++generation_;
}

void RendezvousGroups::BeginInflight() {
    std::lock_guard<std::mutex> lock(mutex_);
    ++inflight_;
}

void RendezvousGroups::EndInflight() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (inflight_ > 0) --inflight_;
}

uint32_t RendezvousGroups::Inflight() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return inflight_;
}

void RendezvousGroups::Clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    cells_.clear();
    zombies_.clear();
    retiring_orphans_.clear();
    buffered_lines_.clear();
    accepting_ = false;
    PublishOwnedLocked();
}

// --- requests -----------------------------------------------------------------

int RendezvousGroups::RequestJoin(const std::array<uint8_t, kSeedSize>& seed, const std::string& name,
                                  const std::string& nick, uint64_t now_ms) {
    std::array<uint8_t, kChatIdSize> chat_id{};
    if (name.empty() || !IsValidNick(nick) || !DeriveChatId(seed, &chat_id)) return 0;
    const std::string chat_id_hex = Hex(chat_id.data(), chat_id.size());
    std::lock_guard<std::mutex> lock(mutex_);
    if (!accepting_) return 0;
    auto existing = cells_.find(chat_id_hex);
    if (existing != cells_.end()) {
        if (existing->second.state != State::kRetiring) return 2;
        // Left, but toxcore has not deleted the group yet: a rejoin now would
        // find the flagged group (tox_group_join rejoins it). Admit it after
        // retirement instead.
        existing->second.rejoin_after_retire = true;
        existing->second.leave_forgets = false;
        return 1;
    }
    Cell cell;
    cell.attempt = next_attempt_++;
    cell.seed = seed;
    cell.chat_id = chat_id;
    cell.chat_id_hex = chat_id_hex;
    cell.name = name;
    cell.nick = nick;
    cell.state = State::kJoining;
    cell.state_since_ms = now_ms;
    cell.pending_join = true;
    cell.retry_window_start_ms = now_ms;
    cells_.emplace(chat_id_hex, std::move(cell));
    return 1;
}

bool RendezvousGroups::RequestLeave(const std::string& chat_id_hex, uint64_t now_ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end()) return false;
    Cell& cell = it->second;
    cell.pending_join = false;
    cell.pending_found = false;
    cell.leave_forgets = true;
    cell.rejoin_after_retire = false;
    if (cell.state == State::kRetiring) return true;  // already left; forgotten at retirement
    cell.leave_reason = "left";
    cell.leave_not_before_ms = 0;  // a client leave (and shutdown) is immediate
    cell.state_since_ms = now_ms;
    if (cell.group_number == UINT32_MAX) {
        // Nothing to leave in toxcore yet. A join still in flight finds the
        // cell gone when it reports back and leaves its group itself.
        cells_.erase(it);
        PublishOwnedLocked();
        return true;
    }
    cell.pending_leave = true;
    return true;
}

size_t RendezvousGroups::RequestLeaveAll(uint64_t now_ms) {
    std::vector<std::string> ids;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ids.reserve(cells_.size());
        for (const auto& pair : cells_) ids.push_back(pair.first);
    }
    size_t n = 0;
    for (const std::string& id : ids) {
        if (RequestLeave(id, now_ms)) ++n;
    }
    return n;
}

// --- planner --------------------------------------------------------------------

void RendezvousGroups::EnterBackoffLocked(Cell& cell, uint64_t now_ms) {
    if (now_ms - cell.retry_window_start_ms > kRetryWindowMs) {
        cell.retry_window_start_ms = now_ms;
        cell.retries = 0;
    }
    ++cell.retries;
    cell.self_joined = false;
    cell.announced = false;
    cell.founded = false;
    cell.had_peers = false;
    cell.peers.clear();
    cell.packet_budget.clear();
    cell.state = cell.retries > kMaxRetriesPerWindow ? State::kUnavailable : State::kBackoff;
    cell.state_since_ms = now_ms;
}

std::vector<RendezvousGroups::Action> RendezvousGroups::Plan(uint64_t now_ms) {
    std::vector<Action> actions;
    std::lock_guard<std::mutex> lock(mutex_);
    // Chat ids whose previous group still exists in toxcore (a retiring
    // orphan): a join/found for them would rejoin that group.
    std::unordered_set<std::string> blocked;
    for (const auto& pair : retiring_orphans_) blocked.insert(pair.second);
    for (auto& entry : cells_) {
        Cell& cell = entry.second;
        // A retiring cell waits for the driver's OnRetired(): no timer, no action.
        if (cell.state == State::kRetiring) continue;
        // 1. Timers: decide what the cell needs now (may set pending flags).
        if (!cell.pending_leave && !cell.pending_join && !cell.pending_found) {
            switch (cell.state) {
                case State::kJoining:
                    if (cell.group_number != UINT32_MAX && !cell.self_joined && cell.peers.empty() &&
                        now_ms - cell.state_since_ms >= kJoinToFoundMs) {
                        // Nobody answered: leave the empty join; the found follows
                        // once toxcore let go of the group (OnRetired).
                        cell.pending_leave = true;
                        cell.leave_reason = "refound";
                        cell.state_since_ms = now_ms;
                    }
                    break;
                case State::kJoined:
                    if (cell.had_peers && cell.peers.empty() && now_ms - cell.empty_since_ms >= kStaleMs) {
                        cell.pending_leave = true;
                        cell.leave_reason = "stale";
                        EnterBackoffLocked(cell, now_ms);
                    }
                    break;
                case State::kBackoff:
                    if (now_ms - cell.state_since_ms >= kBackoffMs) cell.pending_join = true;
                    break;
                case State::kUnavailable:
                    if (now_ms - cell.state_since_ms >= kUnavailableMs) {
                        cell.retries = 0;
                        cell.retry_window_start_ms = now_ms;
                        cell.pending_join = true;
                    }
                    break;
                case State::kRetiring:
                    break;
            }
        }
        // 2. Emit. A leave is the only action of its cell in a batch: the
        //    join/found that follows it is planned after retirement.
        if (cell.pending_leave) {
            // A leave that failed is owed again only after kLeaveRetryMs, and
            // nothing new starts for the cell while a leave is owed.
            if (now_ms < cell.leave_not_before_ms) continue;
            cell.leave_not_before_ms = 0;
            Action a;
            a.kind = ActionKind::kLeave;
            a.chat_id_hex = cell.chat_id_hex;
            a.group_number = cell.group_number;
            a.reason = cell.leave_reason.empty() ? "left" : cell.leave_reason;
            a.generation = generation_;
            a.attempt = cell.attempt;
            actions.push_back(std::move(a));
            cell.pending_leave = false;
            continue;
        }
        if (!accepting_) continue;  // shutting down: nothing new is started
        if (blocked.count(cell.chat_id_hex) != 0) continue;  // wait for the old group to be gone
        if (cell.pending_join || cell.pending_found) {
            Action a;
            a.kind = cell.pending_join ? ActionKind::kJoin : ActionKind::kFound;
            a.chat_id_hex = cell.chat_id_hex;
            a.seed = cell.seed;
            a.chat_id = cell.chat_id;
            a.name = cell.name;
            a.nick = cell.nick;
            a.generation = generation_;
            a.attempt = cell.attempt;
            actions.push_back(std::move(a));
            if (cell.pending_join) cell.state = State::kJoining;
            cell.pending_join = false;
            cell.pending_found = false;
            cell.state_since_ms = now_ms;
        }
    }
    return actions;
}

bool RendezvousGroups::OnJoinIssued(const std::string& chat_id_hex, uint32_t group_number, bool ok, uint64_t now_ms,
                                    uint64_t generation, uint64_t attempt) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end()) return false;  // left meanwhile: the caller owns the leave
    Cell& cell = it->second;
    // The registry moved on under this operation (LeaveAll / re-init, or a
    // leave + rejoin of this very cell, between the Tox call and here):
    // record nothing, the caller leaves what it created. The cell found here
    // is a replacement with its own attempt and pending flags: never touched.
    if (generation_ != generation || cell.attempt != attempt) return false;
    if (cell.state == State::kRetiring) return false;
    if (ok && group_number != UINT32_MAX) {
        cell.group_number = group_number;
        cell.state = State::kJoining;
        cell.state_since_ms = now_ms;
        cell.founded = false;
        cell.announced = false;
        cell.self_joined = false;
    } else {
        cell.group_number = UINT32_MAX;
        EnterBackoffLocked(cell, now_ms);
    }
    PublishOwnedLocked();
    return true;
}

bool RendezvousGroups::OnFoundIssued(const std::string& chat_id_hex, uint32_t group_number, bool ok, uint64_t now_ms,
                                     uint64_t generation, uint64_t attempt) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end()) return false;
    Cell& cell = it->second;
    if (generation_ != generation || cell.attempt != attempt) return false;  // see OnJoinIssued
    // A leave is still owed or retiring for this cell: the found must not
    // overwrite the group we still hold. Refused -> the driver leaves the new
    // group; the found is planned again after retirement.
    if (cell.pending_leave || cell.state == State::kRetiring) return false;
    if (ok && group_number != UINT32_MAX) {
        cell.group_number = group_number;
        cell.state = State::kJoined;
        cell.state_since_ms = now_ms;
        cell.founded = true;
        cell.self_joined = true;  // the founder is connected at once
        cell.announced = true;    // the driver emits the joined line itself
    } else {
        cell.group_number = UINT32_MAX;
        EnterBackoffLocked(cell, now_ms);
    }
    PublishOwnedLocked();
    return true;
}

void RendezvousGroups::OnLeaveIssued(const std::string& chat_id_hex, const std::string& reason, uint64_t now_ms,
                                     uint32_t group_number) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end()) return;
    Cell& cell = it->second;
    if (cell.group_number != group_number) return;  // not the group this cell holds now
    cell.peers.clear();
    cell.packet_budget.clear();
    cell.self_joined = false;
    cell.announced = false;
    cell.pending_leave = false;
    cell.pending_join = false;
    cell.pending_found = false;
    cell.retire_reason = reason;
    cell.state_before_retire = cell.state;  // kBackoff / kUnavailable were entered at event time
    cell.state_since_ms = now_ms;
    if (cell.group_number == UINT32_MAX) {
        FinishRetireLocked(it, now_ms);  // nothing for toxcore to delete
    } else {
        cell.state = State::kRetiring;  // still owned until the driver sees the group gone
    }
    PublishOwnedLocked();
}

void RendezvousGroups::FinishRetireLocked(std::unordered_map<std::string, Cell>::iterator it, uint64_t now_ms) {
    Cell& cell = it->second;
    const std::string reason = cell.retire_reason;
    const State before = cell.state_before_retire;
    cell.group_number = UINT32_MAX;
    cell.retire_reason.clear();
    if (cell.rejoin_after_retire) {
        // The client asked for the cell again while it was retiring: a fresh
        // attempt, as if it had just been requested.
        cell.rejoin_after_retire = false;
        cell.leave_forgets = false;
        cell.state = State::kJoining;
        cell.pending_join = true;
        cell.attempt = next_attempt_++;
        cell.retries = 0;
        cell.retry_window_start_ms = now_ms;
        cell.state_since_ms = now_ms;
        return;
    }
    if (cell.leave_forgets || reason == "left") {
        cells_.erase(it);
        return;
    }
    if (reason == "refound") {
        cell.state = State::kJoining;
        cell.pending_found = true;
        cell.attempt = next_attempt_++;
        cell.state_since_ms = now_ms;
        return;
    }
    // kicked / failed / stale / full: the back-off (or unavailable) state was
    // entered when the event was recorded; its timer runs from now.
    if (before == State::kBackoff || before == State::kUnavailable) {
        cell.state = before;
        cell.state_since_ms = now_ms;
    } else {
        EnterBackoffLocked(cell, now_ms);
    }
}

void RendezvousGroups::NoteRetiringOrphan(uint32_t group_number, const std::string& chat_id_hex) {
    std::lock_guard<std::mutex> lock(mutex_);
    retiring_orphans_[group_number] = chat_id_hex;
    PublishOwnedLocked();
}

std::vector<std::pair<uint32_t, std::string>> RendezvousGroups::Retiring() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::pair<uint32_t, std::string>> out;
    for (const auto& pair : cells_) {
        if (pair.second.state == State::kRetiring) out.emplace_back(pair.second.group_number, pair.first);
    }
    for (const auto& pair : retiring_orphans_) out.emplace_back(pair.first, pair.second);
    return out;
}

std::optional<std::string> RendezvousGroups::RetiringChatIdOf(uint32_t group_number) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto orphan = retiring_orphans_.find(group_number);
    if (orphan != retiring_orphans_.end()) return orphan->second;
    const Cell* cell = FindByGroupLocked(group_number);
    if (cell != nullptr && cell->state == State::kRetiring) return cell->chat_id_hex;
    return std::nullopt;
}

void RendezvousGroups::OnRetired(const std::string& chat_id_hex, uint32_t group_number, uint64_t now_ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto orphan = retiring_orphans_.find(group_number);
    if (orphan != retiring_orphans_.end() && orphan->second == chat_id_hex) retiring_orphans_.erase(orphan);
    auto it = cells_.find(chat_id_hex);
    if (it != cells_.end() && it->second.state == State::kRetiring && it->second.group_number == group_number) {
        FinishRetireLocked(it, now_ms);
    }
    PublishOwnedLocked();
}

std::optional<uint64_t> RendezvousGroups::AttemptOf(const std::string& chat_id_hex) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end()) return std::nullopt;
    return it->second.attempt;
}

void RendezvousGroups::OnLeaveFailed(const std::string& chat_id_hex, uint64_t now_ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end()) return;
    Cell& cell = it->second;
    cell.pending_leave = true;  // group_number and ownership are kept
    cell.leave_not_before_ms = now_ms + kLeaveRetryMs;
}

void RendezvousGroups::NoteZombie(uint32_t group_number, const std::string& chat_id_hex) {
    std::lock_guard<std::mutex> lock(mutex_);
    zombies_[group_number] = chat_id_hex;
    PublishOwnedLocked();
}

bool RendezvousGroups::IsZombie(uint32_t group_number) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return zombies_.count(group_number) != 0;
}

bool RendezvousGroups::HasZombies() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !zombies_.empty();
}

void RendezvousGroups::ForgetZombie(uint32_t group_number) {
    std::lock_guard<std::mutex> lock(mutex_);
    zombies_.erase(group_number);
    PublishOwnedLocked();
}

std::vector<std::pair<uint32_t, std::string>> RendezvousGroups::TakeZombies() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::pair<uint32_t, std::string>> out(zombies_.begin(), zombies_.end());
    zombies_.clear();
    PublishOwnedLocked();
    return out;
}

// --- registry queries ------------------------------------------------------------

RendezvousGroups::Cell* RendezvousGroups::FindByGroupLocked(uint32_t group_number) {
    if (group_number == UINT32_MAX) return nullptr;
    for (auto& pair : cells_) {
        if (pair.second.group_number == group_number) return &pair.second;
    }
    return nullptr;
}

const RendezvousGroups::Cell* RendezvousGroups::FindByGroupLocked(uint32_t group_number) const {
    if (group_number == UINT32_MAX) return nullptr;
    for (const auto& pair : cells_) {
        if (pair.second.group_number == group_number) return &pair.second;
    }
    return nullptr;
}

bool RendezvousGroups::HasCell(const std::string& chat_id_hex) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return cells_.count(chat_id_hex) != 0;
}

bool RendezvousGroups::GroupNumberFor(const std::string& chat_id_hex, uint32_t* group_number) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end() || it->second.group_number == UINT32_MAX) return false;
    if (group_number != nullptr) *group_number = it->second.group_number;
    return true;
}

bool RendezvousGroups::PeerIdFor(const std::string& chat_id_hex, const std::string& peer_pk_hex,
                                 uint32_t* group_number, uint32_t* peer_id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end() || it->second.group_number == UINT32_MAX) return false;
    for (const auto& peer : it->second.peers) {
        if (peer.second == peer_pk_hex) {
            if (group_number != nullptr) *group_number = it->second.group_number;
            if (peer_id != nullptr) *peer_id = peer.first;
            return true;
        }
    }
    return false;
}

std::string RendezvousGroups::PeerPkFor(uint32_t group_number, uint32_t peer_id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const Cell* cell = FindByGroupLocked(group_number);
    if (cell == nullptr) return "";
    auto it = cell->peers.find(peer_id);
    return it == cell->peers.end() ? "" : it->second;
}

std::string RendezvousGroups::ChatIdHexFor(uint32_t group_number) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const Cell* cell = FindByGroupLocked(group_number);
    return cell == nullptr ? "" : cell->chat_id_hex;
}

int RendezvousGroups::PeerCount(const std::string& chat_id_hex) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end()) return -1;
    return static_cast<int>(it->second.peers.size());
}

size_t RendezvousGroups::CellCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return cells_.size();
}

std::optional<RendezvousGroups::State> RendezvousGroups::StateOf(const std::string& chat_id_hex) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cells_.find(chat_id_hex);
    if (it == cells_.end()) return std::nullopt;
    return it->second.state;
}

}  // namespace tim2tox
