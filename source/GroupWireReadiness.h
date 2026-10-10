#pragma once

#include <cstdint>
#include <unordered_map>
#include <unordered_set>

namespace tim2tox {

// Whether a lossless send to an NGC group can reach anyone right now.
//
// tox_group_is_connected() is true for CS_CONNECTING too, and in that state
// gc_send_message() reports success while delivering to nobody: after a
// rejoin (gc_rejoin_group) or a restart every old peer connection is pending
// deletion, and send_gc_lossless_packet_all_peers() returns
// `sent > 0 || confirmed_peers == 0`. toxcore's own callbacks are the exact
// signal instead: self_join ends the sync, peer_join fires when a peer becomes
// confirmed (the only peers a lossless send reaches) and peer_exit fires only
// for confirmed peers.
//
// Plain bookkeeping, NOT thread-safe: the owner guards it with its own mutex.
class GroupWireReadiness {
public:
    using GroupNumber = uint32_t;
    using PeerId = uint32_t;

    // A join, rejoin, invite accept or restore started a sync: the group is
    // not ready until toxcore's self_join, and no peer is confirmed for this
    // new connection yet (the old ones are all pending deletion).
    void BeginSync(GroupNumber group) {
        awaiting_sync_.insert(group);
        confirmed_peers_.erase(group);
    }

    // toxcore's self_join: the sync handshake is done. True when the group is
    // ready from here on (a peer confirmed before the sync response arrived).
    bool SyncDone(GroupNumber group) {
        awaiting_sync_.erase(group);
        return Ready(group);
    }

    // toxcore's peer_join. True when this made the group ready, i.e. the
    // moment queued sends become deliverable.
    bool PeerConfirmed(GroupNumber group, PeerId peer) {
        const bool was_ready = Ready(group);
        confirmed_peers_[group].insert(peer);
        return !was_ready && Ready(group);
    }

    // toxcore's peer_exit (only ever fired for a confirmed peer).
    void PeerExited(GroupNumber group, PeerId peer) {
        auto it = confirmed_peers_.find(group);
        if (it == confirmed_peers_.end()) return;
        it->second.erase(peer);
        if (it->second.empty()) confirmed_peers_.erase(it);
    }

    // The group left the session (leave, kick, refused join): its number may
    // be reused by an unrelated group.
    void Forget(GroupNumber group) {
        awaiting_sync_.erase(group);
        confirmed_peers_.erase(group);
    }

    void Clear() {
        awaiting_sync_.clear();
        confirmed_peers_.clear();
    }

    bool AwaitingSync(GroupNumber group) const {
        return awaiting_sync_.count(group) != 0;
    }

    bool Ready(GroupNumber group) const {
        if (AwaitingSync(group)) return false;
        auto it = confirmed_peers_.find(group);
        return it != confirmed_peers_.end() && !it->second.empty();
    }

private:
    std::unordered_set<GroupNumber> awaiting_sync_;
    std::unordered_map<GroupNumber, std::unordered_set<PeerId>> confirmed_peers_;
};

}  // namespace tim2tox
