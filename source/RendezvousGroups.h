#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace tim2tox {

// Rendezvous groups: NGC public groups whose Chat ID every participant derives
// from a shared label (toxee: a geohash cell) through a seeded keypair
// (tox_group_new_with_seed). They are TRANSPORT ONLY — never a V2TIM group,
// never listed, never persisted as a known group, never routed into history.
//
// This class is the bookkeeping and the planner. It performs NO Tox call: the
// owner (V2TIMManagerImpl, see V2TIMManagerImpl_Rendezvous.cpp) asks Plan()
// what to do, performs the Tox calls under its own pin / epoch / generation
// discipline, and reports the outcome back. toxcore callbacks only record
// state here and take home the event line(s) to publish.
//
// Thread-safe: one internal mutex, always a LEAF lock (nothing is called out
// of it), so it may be taken from inside toxcore callbacks. Owns() — the hot
// path at the top of every group callback — reads an immutable snapshot and
// takes no lock where the standard library offers atomic shared_ptr.
class RendezvousGroups {
public:
    static constexpr size_t kSeedSize = 32;
    static constexpr size_t kChatIdSize = 32;
    static constexpr size_t kPublicKeySize = 32;
    // One boundary for the whole frame (header + payload); toxcore allows 1373.
    static constexpr size_t kMaxFrameBytes = 1200;
    static constexpr size_t kHeaderBytes = 6;
    static constexpr size_t kMaxPayloadBytes = kMaxFrameBytes - kHeaderBytes;
    static constexpr size_t kNickLength = 8;  // lower-case hex, never a user name

    // Timers (milliseconds).
    static constexpr uint64_t kJoinToFoundMs = 30'000;    // join without any peer/self_join -> found
    static constexpr uint64_t kStaleMs = 90'000;          // joined, had peers, none left
    static constexpr uint64_t kBackoffMs = 15'000;        // after kicked / failed / stale
    static constexpr uint64_t kLeaveRetryMs = 5'000;      // tox_group_leave reported a real error
    static constexpr uint64_t kRetryWindowMs = 600'000;   // retries counted per window
    static constexpr uint64_t kUnavailableMs = 600'000;   // after too many retries
    static constexpr int kMaxRetriesPerWindow = 3;

    // Native per-sender budgets, enforced before anything is queued.
    static constexpr uint64_t kBudgetWindowMs = 10'000;
    static constexpr uint32_t kPeerPacketsPerWindow = 6;
    static constexpr uint64_t kPeerBytesPerWindow = 6 * 1024;
    static constexpr uint32_t kPeerEventsPerWindow = 60;
    static constexpr size_t kMaxBufferedLines = 64;

    // Name / seed convention used to recognise a rendezvous group that
    // survived in savedata (crash) without any registry: name =
    // name_prefix + label, seed = SHA-256(seed_prefix + label). The defaults
    // are toxee's protocol literals; a client may change them before init.
    struct Convention {
        std::string name_prefix = "toxee-nearby/v1/";
        std::string seed_prefix = "toxee/nearby/v1|";
    };

    enum class State : uint8_t {
        kJoining,      // tox_group_join issued (or about to be), waiting for self_join / a peer
        kJoined,       // in the group (joined or founded)
        kBackoff,      // left after kicked / failed / stale; re-plan after kBackoffMs
        kUnavailable,  // too many retries; re-plan after kUnavailableMs
        kRetiring,     // tox_group_leave issued; toxcore deletes the group on its next
                       // iteration — still owned until Tick() observes it gone (OnRetired)
    };

    enum class ActionKind : uint8_t { kJoin, kFound, kLeave };

    struct Action {
        ActionKind kind;
        std::string chat_id_hex;
        std::array<uint8_t, kSeedSize> seed{};
        std::array<uint8_t, kChatIdSize> chat_id{};
        std::string name;
        std::string nick;
        uint32_t group_number = UINT32_MAX;  // kLeave only
        std::string reason;                  // kLeave only: kicked|failed|stale|left|full|refound
        uint64_t generation = 0;             // Generation() when planned; recorded only if unchanged
        uint64_t attempt = 0;                // the cell attempt this action belongs to (see Cell::attempt)
    };

    enum class PacketVerdict : uint8_t { kEmit, kDropBudget, kDropUnknownPeer, kDropTooLarge };

    RendezvousGroups();
    RendezvousGroups(const RendezvousGroups&) = delete;
    RendezvousGroups& operator=(const RendezvousGroups&) = delete;

    // --- convention / derivation (pure; RendezvousGroupsCodec.cpp) ---------
    void SetConvention(Convention convention);
    Convention GetConvention() const;
    // True when `label` is a geohash: 1..12 chars of the base32 geohash alphabet.
    static bool IsValidLabel(const std::string& label);
    // kNickLength lower-case hex characters.
    static bool IsValidNick(const std::string& nick);
    // name_prefix + valid label -> label.
    static bool ParseLabel(const Convention& convention, const std::string& name, std::string* label);
    static std::array<uint8_t, kSeedSize> DeriveSeed(const Convention& convention, const std::string& label);
    // Chat ID (ed25519 public key) of the seeded keypair.
    static bool DeriveChatId(const std::array<uint8_t, kSeedSize>& seed, std::array<uint8_t, kChatIdSize>* chat_id);
    // The restore rule: prefix + valid label + chat_id == derivation.
    bool IsRendezvousGroup(const std::string& name, const uint8_t* chat_id) const;
    static std::string Hex(const uint8_t* bytes, size_t length);
    static bool Unhex(const std::string& hex, uint8_t* out, size_t length);

    // Line builders (also used by tests).
    static std::string JoinedLine(const std::string& chat_id_hex, bool founded);
    static std::string LeftLine(const std::string& chat_id_hex, const std::string& reason);
    static std::string PeerLine(const std::string& chat_id_hex, const std::string& peer_pk_hex, bool joined);
    static std::string PeersChangedLine(const std::string& chat_id_hex, size_t count);
    static std::string FullLine(const std::string& chat_id_hex);
    static std::string PacketLine(const std::string& chat_id_hex, const std::string& peer_pk_hex,
                                  bool is_private, const uint8_t* payload, size_t length);

    // --- admission / lifecycle -------------------------------------------
    void SetAccepting(bool accepting);
    bool Accepting() const;
    // Bumped by LeaveAll (client or shutdown) and by InitSDK; captured by every
    // admitted operation.
    uint64_t Generation() const;
    uint64_t BumpGeneration();
    // Admitted operations in flight (unlock -> pin -> Tox call -> record).
    void BeginInflight();
    void EndInflight();
    uint32_t Inflight() const;
    void Clear();

    // --- requests from the client ----------------------------------------
    // 1 accepted, 0 refused (not accepting / bad args), 2 already present.
    int RequestJoin(const std::array<uint8_t, kSeedSize>& seed, const std::string& name,
                    const std::string& nick, uint64_t now_ms);
    bool RequestLeave(const std::string& chat_id_hex, uint64_t now_ms);
    size_t RequestLeaveAll(uint64_t now_ms);

    // --- planner ------------------------------------------------------------
    // What the driver must do now. A cell appears at most once per call,
    // except for the leave + found pair of a refound, in that order.
    std::vector<Action> Plan(uint64_t now_ms);
    // Records the outcome of the Tox call the driver issued for `generation`
    // (the value of Generation() it captured at admission). False when
    // nothing was recorded: the cell is gone (left while the call was in
    // flight) or the registry moved on (generation mismatch) — both checked
    // under the registry lock, atomically with the record. The driver must
    // then leave `group_number` itself, nobody owns it.
    // `generation` / `attempt` are the action's stamps (Action::generation,
    // Action::attempt): a result is recorded only for the attempt it was
    // issued for, so a leave + rejoin of the same cell (new attempt) or a
    // LeaveAll (new generation) while the Tox call is in flight makes the
    // late result an orphan, never a record on the replacement.
    bool OnJoinIssued(const std::string& chat_id_hex, uint32_t group_number, bool ok, uint64_t now_ms,
                      uint64_t generation, uint64_t attempt);
    bool OnFoundIssued(const std::string& chat_id_hex, uint32_t group_number, bool ok, uint64_t now_ms,
                       uint64_t generation, uint64_t attempt);
    // tox_group_leave succeeded: toxcore only flags the group and deletes it
    // on its next iteration, so the cell becomes kRetiring (still owned, the
    // group number still diverted) until OnRetired(); a RequestJoin for it
    // meanwhile is remembered and admitted after retirement.
    // Applies only when the cell still holds `group_number` (a late leave of
    // an earlier group of the same cell records nothing).
    void OnLeaveIssued(const std::string& chat_id_hex, const std::string& reason, uint64_t now_ms,
                       uint32_t group_number);
    // A group that is not a cell but was just left (an orphan join/found, a
    // zombie) and still exists until toxcore's next iteration: owned, and no
    // join/found for its chat id is planned until it is gone.
    void NoteRetiringOrphan(uint32_t group_number, const std::string& chat_id_hex);
    // Everything waiting for toxcore to delete its group: (group number,
    // chat id) of retiring cells and retiring orphans.
    std::vector<std::pair<uint32_t, std::string>> Retiring() const;
    // The chat id a retiring entry (cell or orphan) holds `group_number` for.
    std::optional<std::string> RetiringChatIdOf(uint32_t group_number) const;
    // The driver observed `group_number` gone (or holding another chat id):
    // apply the deferred outcome of the leave (forget / back-off / refound /
    // rejoin) or drop the orphan.
    void OnRetired(const std::string& chat_id_hex, uint32_t group_number, uint64_t now_ms);
    std::optional<uint64_t> AttemptOf(const std::string& chat_id_hex) const;
    // tox_group_leave reported an error that left the group in toxcore: the
    // cell keeps its group number (still owned, callbacks still diverted) and
    // the leave is re-planned after kLeaveRetryMs.
    void OnLeaveFailed(const std::string& chat_id_hex, uint64_t now_ms);
    // Zombie: a group toxcore holds that is ours but is not a cell (restored
    // from savedata, orphaned by a stale join, or a leave that failed at
    // shutdown). Owned (callbacks diverted) until left; left by the driver
    // from Tick() or at shutdown, which emits `rendezvous_left` for it.
    void NoteZombie(uint32_t group_number, const std::string& chat_id_hex);
    bool IsZombie(uint32_t group_number) const;
    bool HasZombies() const;
    void ForgetZombie(uint32_t group_number);
    // Hand every pending zombie (group number, chat id hex) to the caller.
    std::vector<std::pair<uint32_t, std::string>> TakeZombies();

    // --- registry queries ---------------------------------------------------
    bool Owns(uint32_t group_number) const;
    bool HasCell(const std::string& chat_id_hex) const;
    bool GroupNumberFor(const std::string& chat_id_hex, uint32_t* group_number) const;
    bool PeerIdFor(const std::string& chat_id_hex, const std::string& peer_pk_hex,
                   uint32_t* group_number, uint32_t* peer_id) const;
    std::string PeerPkFor(uint32_t group_number, uint32_t peer_id) const;
    std::string ChatIdHexFor(uint32_t group_number) const;
    int PeerCount(const std::string& chat_id_hex) const;
    size_t CellCount() const;
    std::optional<State> StateOf(const std::string& chat_id_hex) const;

    // --- toxcore callbacks: record only, return the line(s) to publish -----
    std::optional<std::string> OnSelfJoin(uint32_t group_number, uint64_t now_ms);
    // A confirmed peer also means the join is real: a cell still kJoining
    // becomes kJoined and the joined line precedes the peer line.
    std::vector<std::string> OnPeerJoin(uint32_t group_number, uint32_t peer_id,
                                        const std::string& peer_pk_hex, uint64_t now_ms);
    std::optional<std::string> OnPeerExit(uint32_t group_number, uint32_t peer_id,
                                          bool self_disconnected, uint64_t now_ms);
    std::optional<std::string> OnJoinFail(uint32_t group_number, bool peer_limit, uint64_t now_ms);
    std::optional<std::string> OnKickedSelf(uint32_t group_number, uint64_t now_ms);
    // A kind-4 payload (already unwrapped) from `peer_id`; `peer_pk_hex` may be
    // empty when the peer is not in the map yet (then supply it via OnPeerJoin
    // first or it is dropped as unknown).
    PacketVerdict OnPacket(uint32_t group_number, uint32_t peer_id, const std::string& peer_pk_hex,
                           bool is_private, const uint8_t* payload, size_t length, uint64_t now_ms,
                           std::string* line);
    uint64_t DropCount() const;

    // --- event buffering (before an event sink is installed) ----------------
    // Returns false when the buffer is full (line dropped and counted).
    bool BufferLine(const std::string& line);
    std::vector<std::string> TakeBufferedLines();

private:
    struct Budget {
        uint64_t window_start_ms = 0;
        uint32_t packets = 0;
        uint64_t bytes = 0;
    };
    struct Cell {
        std::array<uint8_t, kSeedSize> seed{};
        std::array<uint8_t, kChatIdSize> chat_id{};
        std::string chat_id_hex;
        std::string name;
        std::string nick;
        State state = State::kJoining;
        uint64_t state_since_ms = 0;
        uint32_t group_number = UINT32_MAX;
        bool pending_join = true;       // Plan() must issue tox_group_join
        bool pending_found = false;     // Plan() must issue tox_group_new_with_seed
        bool pending_leave = false;     // Plan() must issue tox_group_leave
        uint64_t leave_not_before_ms = 0;  // a failed leave is retried after kLeaveRetryMs
        std::string leave_reason;
        bool leave_forgets = false;     // client asked: erase after the leave
        bool rejoin_after_retire = false;  // RequestJoin arrived while kRetiring
        std::string retire_reason;      // the leave's reason, applied at OnRetired()
        State state_before_retire = State::kJoining;
        uint64_t attempt = 0;           // bumped on every fresh attempt (new cell, rejoin, refound)
        bool founded = false;
        bool self_joined = false;
        bool announced = false;         // rendezvous_joined already emitted
        bool had_peers = false;
        uint64_t empty_since_ms = 0;
        std::unordered_map<uint32_t, std::string> peers;  // peer_id -> pk hex
        std::unordered_map<std::string, Budget> packet_budget;  // pk hex -> budget
        Budget event_budget;
        bool coalescing = false;
        int retries = 0;
        uint64_t retry_window_start_ms = 0;
    };
    using OwnedSet = std::unordered_set<uint32_t>;

    Cell* FindByGroupLocked(uint32_t group_number);
    const Cell* FindByGroupLocked(uint32_t group_number) const;
    void PublishOwnedLocked();
    void EnterBackoffLocked(Cell& cell, uint64_t now_ms);
    void FinishRetireLocked(std::unordered_map<std::string, Cell>::iterator it, uint64_t now_ms);
    std::optional<std::string> PeerEventLocked(Cell& cell, const std::string& pk, bool joined, uint64_t now_ms);
    static bool ConsumeBudget(Budget& budget, uint64_t now_ms, uint32_t max_count, uint64_t max_bytes,
                              size_t bytes);
    std::shared_ptr<const OwnedSet> LoadOwned() const;
    void StoreOwned(std::shared_ptr<const OwnedSet> owned);

    mutable std::mutex mutex_;
    Convention convention_;
    bool accepting_ = false;
    uint64_t generation_ = 1;
    uint64_t next_attempt_ = 1;
    uint32_t inflight_ = 0;
    uint64_t drops_ = 0;
    std::unordered_map<std::string, Cell> cells_;  // chat_id hex -> cell
    std::unordered_map<uint32_t, std::string> zombies_;  // group number -> chat id hex
    std::unordered_map<uint32_t, std::string> retiring_orphans_;  // group number -> chat id hex
    std::deque<std::string> buffered_lines_;
    // Immutable snapshot of (cell group numbers ∪ zombies) for Owns().
#if defined(__cpp_lib_atomic_shared_ptr)
    std::atomic<std::shared_ptr<const OwnedSet>> owned_;
#else
    mutable std::mutex owned_mutex_;
    std::shared_ptr<const OwnedSet> owned_;
#endif
};

}  // namespace tim2tox
