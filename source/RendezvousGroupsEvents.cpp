// RendezvousGroups — the toxcore-callback side: self/peer join and exit,
// kick, packet budgets and the pre-sink line buffer. Same object, same
// leaf mutex as RendezvousGroups.cpp; split only to keep each file readable.
#include "RendezvousGroups.h"

#include <algorithm>

namespace tim2tox {

std::optional<std::string> RendezvousGroups::OnSelfJoin(uint32_t group_number, uint64_t now_ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    Cell* cell = FindByGroupLocked(group_number);
    if (cell == nullptr || cell->state == State::kRetiring) return std::nullopt;
    cell->self_joined = true;
    cell->state = State::kJoined;
    cell->state_since_ms = now_ms;
    cell->retries = 0;
    if (cell->announced) return std::nullopt;  // a peer_join already announced it
    cell->announced = true;
    return JoinedLine(cell->chat_id_hex, cell->founded);
}

bool RendezvousGroups::ConsumeBudget(Budget& budget, uint64_t now_ms, uint32_t max_count, uint64_t max_bytes,
                                     size_t bytes) {
    if (now_ms - budget.window_start_ms >= kBudgetWindowMs) {
        budget.window_start_ms = now_ms;
        budget.packets = 0;
        budget.bytes = 0;
    }
    if (budget.packets + 1 > max_count || budget.bytes + bytes > max_bytes) return false;
    ++budget.packets;
    budget.bytes += bytes;
    return true;
}

std::optional<std::string> RendezvousGroups::PeerEventLocked(Cell& cell, const std::string& pk, bool joined,
                                                             uint64_t now_ms) {
    if (ConsumeBudget(cell.event_budget, now_ms, kPeerEventsPerWindow, UINT64_MAX, 0)) {
        cell.coalescing = false;
        return PeerLine(cell.chat_id_hex, pk, joined);
    }
    if (cell.coalescing) return std::nullopt;
    cell.coalescing = true;
    return PeersChangedLine(cell.chat_id_hex, cell.peers.size());
}

std::vector<std::string> RendezvousGroups::OnPeerJoin(uint32_t group_number, uint32_t peer_id,
                                                      const std::string& peer_pk_hex, uint64_t now_ms) {
    std::vector<std::string> lines;
    std::lock_guard<std::mutex> lock(mutex_);
    Cell* cell = FindByGroupLocked(group_number);
    if (cell == nullptr || cell->state == State::kRetiring || peer_pk_hex.empty()) return lines;
    cell->peers[peer_id] = peer_pk_hex;
    cell->had_peers = true;
    if (cell->state == State::kJoining) {
        // A confirmed peer means the join is real even before self_join.
        cell->state = State::kJoined;
        cell->state_since_ms = now_ms;
        cell->retries = 0;
    }
    if (!cell->announced) {
        cell->announced = true;
        lines.push_back(JoinedLine(cell->chat_id_hex, cell->founded));
    }
    if (const auto line = PeerEventLocked(*cell, peer_pk_hex, true, now_ms)) lines.push_back(*line);
    return lines;
}

std::optional<std::string> RendezvousGroups::OnPeerExit(uint32_t group_number, uint32_t peer_id,
                                                        bool self_disconnected, uint64_t now_ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    Cell* cell = FindByGroupLocked(group_number);
    if (cell == nullptr || cell->state == State::kRetiring) return std::nullopt;
    auto it = cell->peers.find(peer_id);
    if (it == cell->peers.end()) return std::nullopt;
    const std::string pk = it->second;
    cell->peers.erase(it);
    if (cell->peers.empty()) cell->empty_since_ms = now_ms;
    if (self_disconnected) {
        // WE dropped off; toxcore reports every peer this way and reconnects
        // on its own. The watchdog (kStaleMs) decides if that never happens.
        return std::nullopt;
    }
    return PeerEventLocked(*cell, pk, false, now_ms);
}

std::optional<std::string> RendezvousGroups::OnJoinFail(uint32_t group_number, bool peer_limit, uint64_t now_ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    Cell* cell = FindByGroupLocked(group_number);
    if (cell == nullptr || cell->state == State::kRetiring) return std::nullopt;
    cell->pending_leave = true;
    cell->leave_reason = peer_limit ? "full" : "failed";
    cell->pending_join = false;
    cell->pending_found = false;
    EnterBackoffLocked(*cell, now_ms);
    return peer_limit ? std::make_optional(FullLine(cell->chat_id_hex)) : std::nullopt;
}

std::optional<std::string> RendezvousGroups::OnKickedSelf(uint32_t group_number, uint64_t now_ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    Cell* cell = FindByGroupLocked(group_number);
    if (cell == nullptr || cell->state == State::kRetiring) return std::nullopt;
    cell->pending_leave = true;
    cell->leave_reason = "kicked";
    cell->pending_join = false;
    cell->pending_found = false;
    EnterBackoffLocked(*cell, now_ms);
    return std::nullopt;
}

RendezvousGroups::PacketVerdict RendezvousGroups::OnPacket(uint32_t group_number, uint32_t peer_id,
                                                           const std::string& peer_pk_hex, bool is_private,
                                                           const uint8_t* payload, size_t length,
                                                           uint64_t now_ms, std::string* line) {
    std::lock_guard<std::mutex> lock(mutex_);
    Cell* cell = FindByGroupLocked(group_number);
    if (cell == nullptr || cell->state == State::kRetiring) {
        ++drops_;
        return PacketVerdict::kDropUnknownPeer;
    }
    if (length > kMaxPayloadBytes) {
        ++drops_;
        return PacketVerdict::kDropTooLarge;
    }
    std::string pk = peer_pk_hex;
    if (pk.empty()) {
        auto it = cell->peers.find(peer_id);
        if (it != cell->peers.end()) pk = it->second;
    } else if (cell->peers.count(peer_id) == 0) {
        cell->peers[peer_id] = pk;
    }
    if (pk.empty()) {
        ++drops_;
        return PacketVerdict::kDropUnknownPeer;
    }
    if (!ConsumeBudget(cell->packet_budget[pk], now_ms, kPeerPacketsPerWindow, kPeerBytesPerWindow, length)) {
        ++drops_;
        return PacketVerdict::kDropBudget;
    }
    if (line != nullptr) *line = PacketLine(cell->chat_id_hex, pk, is_private, payload, length);
    return PacketVerdict::kEmit;
}

uint64_t RendezvousGroups::DropCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return drops_;
}

// --- event buffering ------------------------------------------------------------------

bool RendezvousGroups::BufferLine(const std::string& line) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (buffered_lines_.size() >= kMaxBufferedLines) {
        ++drops_;
        return false;
    }
    buffered_lines_.push_back(line);
    return true;
}

std::vector<std::string> RendezvousGroups::TakeBufferedLines() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::string> out(buffered_lines_.begin(), buffered_lines_.end());
    buffered_lines_.clear();
    return out;
}

}  // namespace tim2tox
