// RendezvousGroups is the bookkeeping + planner behind the transport-only
// rendezvous cells (people nearby). No Tox calls happen in it, so the whole
// state machine, the budgets and the restore rule are pinned here.

#include "RendezvousGroups.h"

#include <gtest/gtest.h>

#include <array>
#include <cstring>
#include <string>
#include <vector>

namespace {

using tim2tox::RendezvousGroups;
using Action = RendezvousGroups::Action;
using Kind = RendezvousGroups::ActionKind;
using State = RendezvousGroups::State;

std::array<uint8_t, 32> SeedFor(const std::string& label) {
    return RendezvousGroups::DeriveSeed(RendezvousGroups::Convention{}, label);
}

std::string ChatIdHexFor(const std::string& label) {
    std::array<uint8_t, 32> chat_id{};
    EXPECT_TRUE(RendezvousGroups::DeriveChatId(SeedFor(label), &chat_id));
    return RendezvousGroups::Hex(chat_id.data(), chat_id.size());
}

const std::string kPk1(64, 'a');
const std::string kPk2(64, 'b');

// A cell admitted and joined (tox_group_join issued -> group number 7).
void JoinCell(RendezvousGroups& r, const std::string& label, uint32_t group_number, uint64_t now) {
    ASSERT_EQ(r.RequestJoin(SeedFor(label), "toxee-nearby/v1/" + label, "0a1b2c3d", now), 1);
    const std::vector<Action> actions = r.Plan(now);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kJoin);
    EXPECT_EQ(actions[0].chat_id_hex, ChatIdHexFor(label));
    EXPECT_EQ(actions[0].nick, "0a1b2c3d");
    EXPECT_TRUE(r.OnJoinIssued(ChatIdHexFor(label), group_number, true, now, actions[0].generation,
                               actions[0].attempt));
}

// Toxcore deleted the group of a left cell (observed by the driver's Tick).
void Retire(RendezvousGroups& r, const std::string& label, uint64_t now) {
    uint32_t gn = UINT32_MAX;
    r.GroupNumberFor(ChatIdHexFor(label), &gn);
    r.OnRetired(ChatIdHexFor(label), gn, now);
}

TEST(RendezvousGroupsTest, DerivationIsDeterministicAndLabelAware) {
    const auto a = SeedFor("wx4g0");
    const auto b = SeedFor("wx4g0");
    const auto c = SeedFor("wx4g1");
    EXPECT_EQ(a, b);
    EXPECT_NE(a, c);
    EXPECT_EQ(ChatIdHexFor("wx4g0"), ChatIdHexFor("wx4g0"));
    EXPECT_NE(ChatIdHexFor("wx4g0"), ChatIdHexFor("wx4g1"));
    EXPECT_EQ(ChatIdHexFor("wx4g0").size(), 64u);
}

TEST(RendezvousGroupsTest, LabelsAreGeohashesOnly) {
    EXPECT_TRUE(RendezvousGroups::IsValidLabel("wx4g0"));
    EXPECT_TRUE(RendezvousGroups::IsValidLabel("0"));
    EXPECT_TRUE(RendezvousGroups::IsValidLabel("zzzzzzzzzzzz"));
    EXPECT_FALSE(RendezvousGroups::IsValidLabel(""));
    EXPECT_FALSE(RendezvousGroups::IsValidLabel("zzzzzzzzzzzzz"));  // 13
    EXPECT_FALSE(RendezvousGroups::IsValidLabel("wx4a0"));          // 'a' not in the alphabet
    EXPECT_FALSE(RendezvousGroups::IsValidLabel("WX4G0"));          // upper case
    EXPECT_FALSE(RendezvousGroups::IsValidLabel("wx4g0/x"));
    std::string label;
    RendezvousGroups::Convention conv;
    EXPECT_TRUE(RendezvousGroups::ParseLabel(conv, "toxee-nearby/v1/wx4g0", &label));
    EXPECT_EQ(label, "wx4g0");
    EXPECT_FALSE(RendezvousGroups::ParseLabel(conv, "toxee-nearby/v1/", &label));
    EXPECT_FALSE(RendezvousGroups::ParseLabel(conv, "my group wx4g0", &label));
    EXPECT_FALSE(RendezvousGroups::ParseLabel(conv, "toxee-nearby/v2/wx4g0", &label));
}

TEST(RendezvousGroupsTest, RestoreRuleNeedsPrefixLabelAndMatchingChatId) {
    RendezvousGroups r;
    std::array<uint8_t, 32> chat_id{};
    ASSERT_TRUE(RendezvousGroups::DeriveChatId(SeedFor("wx4g0"), &chat_id));
    EXPECT_TRUE(r.IsRendezvousGroup("toxee-nearby/v1/wx4g0", chat_id.data()));
    // A user group that merely carries the name fails the chat_id test.
    std::array<uint8_t, 32> other{};
    other.fill(0x42);
    EXPECT_FALSE(r.IsRendezvousGroup("toxee-nearby/v1/wx4g0", other.data()));
    // The right chat_id under another name is not ours either (no prefix).
    EXPECT_FALSE(r.IsRendezvousGroup("Friends of wx4g0", chat_id.data()));
    // A changed convention changes the derivation.
    r.SetConvention({"other/", "other|"});
    EXPECT_FALSE(r.IsRendezvousGroup("toxee-nearby/v1/wx4g0", chat_id.data()));
    EXPECT_FALSE(r.IsRendezvousGroup("other/wx4g0", chat_id.data()));
}

TEST(RendezvousGroupsTest, RequestsNeedAdmissionAndAProtocolNick) {
    RendezvousGroups r;
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1000), 0);  // not accepting
    r.SetAccepting(true);
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g0"), "", "0123abcd", 1000), 0);   // empty name
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "", 1000), 0);          // empty nick
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "Alice", 1000), 0);     // a user name is not a nick
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123ABCD", 1000), 0);  // upper case
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1000), 1);
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1000), 2);  // already present
    EXPECT_EQ(r.CellCount(), 1u);
    EXPECT_TRUE(RendezvousGroups::IsValidNick("deadbeef"));
    EXPECT_FALSE(RendezvousGroups::IsValidNick("deadbee"));
    EXPECT_FALSE(RendezvousGroups::IsValidNick("deadbeefx"));
}

TEST(RendezvousGroupsTest, JoinThenSelfJoinOwnsTheGroupNumber) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    EXPECT_TRUE(r.Owns(7));
    EXPECT_FALSE(r.Owns(8));
    uint32_t gn = 0;
    EXPECT_TRUE(r.GroupNumberFor(ChatIdHexFor("wx4g0"), &gn));
    EXPECT_EQ(gn, 7u);
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kJoining);
    const auto line = r.OnSelfJoin(7, 2000);
    ASSERT_TRUE(line.has_value());
    EXPECT_EQ(*line, "rendezvous_joined:" + ChatIdHexFor("wx4g0") + ":0");
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kJoined);
    EXPECT_FALSE(r.OnSelfJoin(7, 2001).has_value());  // idempotent
    EXPECT_TRUE(r.Plan(2500).empty());
}

TEST(RendezvousGroupsTest, SilentJoinIsRefoundedAfterThirtySeconds) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    EXPECT_TRUE(r.Plan(1000 + RendezvousGroups::kJoinToFoundMs - 1).empty());
    // One batch: the leave of the empty join, then the found; the driver
    // executes a batch in order.
    // The leave of the empty join first; the found only once toxcore let go
    // of group 7 (a found of the same chat id while it still exists would
    // rejoin it).
    std::vector<Action> actions = r.Plan(1000 + RendezvousGroups::kJoinToFoundMs);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kLeave);
    EXPECT_EQ(actions[0].group_number, 7u);
    EXPECT_EQ(actions[0].reason, "refound");
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "refound", 31000, 7);
    EXPECT_TRUE(r.Owns(7)) << "retiring: callbacks for 7 are still diverted";
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kRetiring);
    EXPECT_TRUE(r.Plan(31000).empty());
    Retire(r, "wx4g0", 31050);
    EXPECT_FALSE(r.Owns(7));
    actions = r.Plan(31050);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kFound);
    EXPECT_EQ(actions[0].seed, SeedFor("wx4g0"));
    EXPECT_EQ(actions[0].name, "toxee-nearby/v1/wx4g0");
    EXPECT_TRUE(r.Plan(31100).empty());  // nothing pending until the found reports back
    EXPECT_TRUE(r.OnFoundIssued(ChatIdHexFor("wx4g0"), 9, true, 31100, actions[0].generation, actions[0].attempt));
    EXPECT_TRUE(r.Owns(9));
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kJoined);
    EXPECT_TRUE(r.Plan(40000).empty());
}

TEST(RendezvousGroupsTest, PeerJoinBeforeSelfJoinKeepsTheJoinAlive) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    // A confirmed peer before self_join: the join is real -> kJoined, and the
    // joined line precedes the peer line.
    const std::vector<std::string> lines = r.OnPeerJoin(7, 3, kPk1, 20000);
    ASSERT_EQ(lines.size(), 2u);
    EXPECT_EQ(lines[0], "rendezvous_joined:" + ChatIdHexFor("wx4g0") + ":0");
    EXPECT_EQ(lines[1], "rendezvous_peer:" + ChatIdHexFor("wx4g0") + ":" + kPk1 + ":join");
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kJoined);
    // The later self_join is recorded but not announced twice.
    EXPECT_FALSE(r.OnSelfJoin(7, 20001).has_value());
    EXPECT_EQ(r.PeerCount(ChatIdHexFor("wx4g0")), 1);
    EXPECT_EQ(r.PeerPkFor(7, 3), kPk1);
    uint32_t gn = 0, pid = 0;
    EXPECT_TRUE(r.PeerIdFor(ChatIdHexFor("wx4g0"), kPk1, &gn, &pid));
    EXPECT_EQ(pid, 3u);
    // No refound while a peer is there.
    EXPECT_TRUE(r.Plan(1000 + RendezvousGroups::kJoinToFoundMs + 5000).empty());
}

TEST(RendezvousGroupsTest, StaleCellIsLeftAndBackedOff) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    r.OnSelfJoin(7, 2000);
    (void)r.OnPeerJoin(7, 3, kPk1, 2000);
    auto line = r.OnPeerExit(7, 3, false, 5000);
    ASSERT_TRUE(line.has_value());
    EXPECT_EQ(*line, "rendezvous_peer:" + ChatIdHexFor("wx4g0") + ":" + kPk1 + ":exit");
    EXPECT_TRUE(r.Plan(5000 + RendezvousGroups::kStaleMs - 1).empty());
    std::vector<Action> actions = r.Plan(5000 + RendezvousGroups::kStaleMs);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kLeave);
    EXPECT_EQ(actions[0].reason, "stale");
    const uint64_t left_at = 5000 + RendezvousGroups::kStaleMs;
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "stale", left_at, 7);
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kRetiring);
    Retire(r, "wx4g0", left_at);
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kBackoff);
    EXPECT_TRUE(r.Plan(left_at + RendezvousGroups::kBackoffMs - 1).empty());
    actions = r.Plan(left_at + RendezvousGroups::kBackoffMs);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kJoin);
}

TEST(RendezvousGroupsTest, SelfDisconnectedExitsAreSilentAndCountedByTheWatchdog) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    r.OnSelfJoin(7, 2000);
    (void)r.OnPeerJoin(7, 3, kPk1, 2000);
    EXPECT_FALSE(r.OnPeerExit(7, 3, true, 5000).has_value());
    EXPECT_EQ(r.PeerCount(ChatIdHexFor("wx4g0")), 0);
    const std::vector<Action> actions = r.Plan(5000 + RendezvousGroups::kStaleMs);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].reason, "stale");
}

TEST(RendezvousGroupsTest, TooManyRetriesMarkTheCellUnavailable) {
    RendezvousGroups r;
    r.SetAccepting(true);
    uint64_t now = 1000;
    JoinCell(r, "wx4g0", 7, now);
    for (int i = 0; i < RendezvousGroups::kMaxRetriesPerWindow; ++i) {
        // join_fail -> leave + backoff -> join again
        EXPECT_FALSE(r.OnJoinFail(7, false, now).has_value());
        std::vector<Action> actions = r.Plan(now);
        ASSERT_EQ(actions.size(), 1u);
        EXPECT_EQ(actions[0].kind, Kind::kLeave);
        EXPECT_EQ(actions[0].reason, "failed");
        r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "failed", now, 7);
        Retire(r, "wx4g0", now);
        EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kBackoff);
        now += RendezvousGroups::kBackoffMs;
        actions = r.Plan(now);
        ASSERT_EQ(actions.size(), 1u);
        EXPECT_EQ(actions[0].kind, Kind::kJoin);
        EXPECT_TRUE(r.OnJoinIssued(ChatIdHexFor("wx4g0"), 7, true, now, r.Generation(), *r.AttemptOf(ChatIdHexFor("wx4g0"))));
    }
    // The fourth failure within the window exhausts the retries.
    r.OnJoinFail(7, false, now);
    const std::vector<Action> actions = r.Plan(now);
    ASSERT_EQ(actions.size(), 1u);
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "failed", now, 7);
    Retire(r, "wx4g0", now);
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kUnavailable);
    EXPECT_TRUE(r.Plan(now + RendezvousGroups::kUnavailableMs - 1).empty());
    EXPECT_EQ(r.Plan(now + RendezvousGroups::kUnavailableMs).size(), 1u);
}

TEST(RendezvousGroupsTest, PeerLimitReportsFull) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    const auto line = r.OnJoinFail(7, true, 1500);
    ASSERT_TRUE(line.has_value());
    EXPECT_EQ(*line, "rendezvous_full:" + ChatIdHexFor("wx4g0"));
    const std::vector<Action> actions = r.Plan(1500);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].reason, "full");
}

TEST(RendezvousGroupsTest, KickedSelfLeavesAndRetries) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    r.OnSelfJoin(7, 2000);
    EXPECT_FALSE(r.OnKickedSelf(7, 3000).has_value());
    const std::vector<Action> actions = r.Plan(3000);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kLeave);
    EXPECT_EQ(actions[0].reason, "kicked");
}

TEST(RendezvousGroupsTest, ClientLeaveForgetsTheCell) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    EXPECT_TRUE(r.RequestLeave(ChatIdHexFor("wx4g0"), 1500));
    EXPECT_FALSE(r.RequestLeave(ChatIdHexFor("zzzz"), 1500));
    const std::vector<Action> actions = r.Plan(1500);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kLeave);
    EXPECT_EQ(actions[0].reason, "left");
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "left", 1500, 7);
    // Left in toxcore, but the group exists until its next iteration: still
    // owned, nothing planned, forgotten once the driver sees it gone.
    EXPECT_EQ(r.CellCount(), 1u);
    EXPECT_TRUE(r.Owns(7));
    EXPECT_TRUE(r.Plan(1600).empty());
    Retire(r, "wx4g0", 1700);
    EXPECT_EQ(r.CellCount(), 0u);
    EXPECT_FALSE(r.Owns(7));
}

TEST(RendezvousGroupsTest, ARetiringCellDefersARejoinAndIgnoresToxcoreEvents) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    r.OnSelfJoin(7, 1100);
    EXPECT_TRUE(r.RequestLeave(ChatIdHexFor("wx4g0"), 1500));
    ASSERT_EQ(r.Plan(1500).size(), 1u);
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "left", 1500, 7);
    // The client wants the cell again before toxcore deleted group 7: no
    // join is issued yet (it would rejoin the flagged group), the request is
    // kept and the events of the dying group are ignored.
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1600), 1);
    EXPECT_TRUE(r.Plan(1600).empty());
    EXPECT_TRUE(r.OnPeerJoin(7, 3, kPk1, 1600).empty());
    EXPECT_FALSE(r.OnSelfJoin(7, 1600).has_value());
    EXPECT_FALSE(r.OnJoinFail(7, false, 1600).has_value());
    std::string line;
    const uint8_t payload[1] = {0};
    EXPECT_EQ(r.OnPacket(7, 3, kPk1, false, payload, 1, 1600, &line),
              RendezvousGroups::PacketVerdict::kDropUnknownPeer);
    EXPECT_EQ(r.Retiring().size(), 1u);
    EXPECT_EQ(r.Retiring()[0].first, 7u);
    // Gone: the rejoin is a fresh attempt.
    const uint64_t old_attempt = *r.AttemptOf(ChatIdHexFor("wx4g0"));
    Retire(r, "wx4g0", 2000);
    EXPECT_FALSE(r.Owns(7));
    EXPECT_EQ(r.CellCount(), 1u);
    const std::vector<Action> actions = r.Plan(2000);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kJoin);
    EXPECT_NE(actions[0].attempt, old_attempt);
    // A leave that arrives while retiring simply forgets the cell at retirement.
    EXPECT_TRUE(r.OnJoinIssued(ChatIdHexFor("wx4g0"), 8, true, 2100, actions[0].generation, actions[0].attempt));
    EXPECT_TRUE(r.RequestLeave(ChatIdHexFor("wx4g0"), 2200));
    ASSERT_EQ(r.Plan(2200).size(), 1u);
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "left", 2200, 7);  // wrong number: ignored
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kJoining);
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "left", 2200, 8);
    EXPECT_EQ(r.StateOf(ChatIdHexFor("wx4g0")), State::kRetiring);
    EXPECT_TRUE(r.RequestLeave(ChatIdHexFor("wx4g0"), 2250));
    Retire(r, "wx4g0", 2300);
    EXPECT_EQ(r.CellCount(), 0u);
}

TEST(RendezvousGroupsTest, ARetiringOrphanOwnsItsNumberAndBlocksJoinsOfItsChatIdUntilGone) {
    RendezvousGroups r;
    r.SetAccepting(true);
    // An orphan join was left (undo): toxcore still holds group 7 for wx4g0.
    r.NoteRetiringOrphan(7, ChatIdHexFor("wx4g0"));
    EXPECT_TRUE(r.Owns(7));
    EXPECT_EQ(r.RetiringChatIdOf(7), ChatIdHexFor("wx4g0"));
    ASSERT_EQ(r.Retiring().size(), 1u);
    // The client wants the cell: admitted, but no join is planned while the
    // old group exists (it would be rejoined), other cells are unaffected.
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1000), 1);
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g1"), "n", "0123abcd", 1000), 1);
    std::vector<Action> actions = r.Plan(1000);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].chat_id_hex, ChatIdHexFor("wx4g1"));
    EXPECT_TRUE(r.Plan(1100).empty());
    // Gone (or the number now holds another chat id): released, and the join follows.
    r.OnRetired(ChatIdHexFor("wx4g0"), 7, 1200);
    EXPECT_FALSE(r.Owns(7));
    EXPECT_FALSE(r.RetiringChatIdOf(7).has_value());
    actions = r.Plan(1200);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kJoin);
    EXPECT_EQ(actions[0].chat_id_hex, ChatIdHexFor("wx4g0"));
    // Clear() drops orphans too.
    r.NoteRetiringOrphan(9, ChatIdHexFor("wx4g9"));
    r.Clear();
    EXPECT_FALSE(r.Owns(9));
}

TEST(RendezvousGroupsTest, ALeaveAndRejoinWhileTheJoinIsInFlightOrphansTheOldResult) {
    RendezvousGroups r;
    r.SetAccepting(true);
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1000), 1);
    const std::vector<Action> first = r.Plan(1000);
    ASSERT_EQ(first.size(), 1u);
    // Same generation: the client leaves (unjoined -> erased) and rejoins the
    // same cell while tox_group_join is in flight.
    EXPECT_TRUE(r.RequestLeave(ChatIdHexFor("wx4g0"), 1200));
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1300), 1);
    EXPECT_EQ(r.Generation(), first[0].generation);
    // The old result belongs to the old attempt: refused, the driver leaves
    // group 7, and the replacement keeps its own pending join.
    EXPECT_FALSE(r.OnJoinIssued(ChatIdHexFor("wx4g0"), 7, true, 1400, first[0].generation, first[0].attempt));
    EXPECT_FALSE(r.Owns(7));
    const std::vector<Action> second = r.Plan(1500);
    ASSERT_EQ(second.size(), 1u);
    EXPECT_EQ(second[0].kind, Kind::kJoin);
    EXPECT_NE(second[0].attempt, first[0].attempt);
    EXPECT_TRUE(r.OnJoinIssued(ChatIdHexFor("wx4g0"), 8, true, 1600, second[0].generation, second[0].attempt));
    EXPECT_TRUE(r.Owns(8));
}

TEST(RendezvousGroupsTest, LeaveOfAnUnjoinedCellNeedsNoToxCall) {
    RendezvousGroups r;
    r.SetAccepting(true);
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1000), 1);
    EXPECT_TRUE(r.RequestLeave(ChatIdHexFor("wx4g0"), 1000));
    EXPECT_EQ(r.CellCount(), 0u);
    EXPECT_TRUE(r.Plan(1000).empty());
}

TEST(RendezvousGroupsTest, NotAcceptingStopsNewJoinsButStillLeaves) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g1"), "n", "0123abcd", 1000), 1);
    r.SetAccepting(false);
    EXPECT_EQ(r.RequestJoin(SeedFor("wx4g2"), "n", "0123abcd", 1000), 0);
    EXPECT_EQ(r.RequestLeaveAll(1000), 2u);
    const std::vector<Action> actions = r.Plan(1000);
    ASSERT_EQ(actions.size(), 1u);  // only the joined one has a group to leave
    EXPECT_EQ(actions[0].kind, Kind::kLeave);
    EXPECT_EQ(actions[0].group_number, 7u);
}

TEST(RendezvousGroupsTest, GenerationAndInflightBookkeeping) {
    RendezvousGroups r;
    const uint64_t g0 = r.Generation();
    EXPECT_EQ(r.BumpGeneration(), g0 + 1);
    r.BeginInflight();
    r.BeginInflight();
    EXPECT_EQ(r.Inflight(), 2u);
    r.EndInflight();
    r.EndInflight();
    r.EndInflight();  // never negative
    EXPECT_EQ(r.Inflight(), 0u);
}

TEST(RendezvousGroupsTest, PacketsAreBudgetedPerPeer) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    r.OnSelfJoin(7, 2000);
    (void)r.OnPeerJoin(7, 3, kPk1, 2000);
    const uint8_t payload[] = {0x01, 0x02};
    std::string line;
    for (uint32_t i = 0; i < RendezvousGroups::kPeerPacketsPerWindow; ++i) {
        EXPECT_EQ(r.OnPacket(7, 3, "", false, payload, sizeof(payload), 3000, &line),
                  RendezvousGroups::PacketVerdict::kEmit);
    }
    EXPECT_EQ(line, "rendezvous_packet:" + ChatIdHexFor("wx4g0") + ":" + kPk1 + ":b:0102");
    EXPECT_EQ(r.OnPacket(7, 3, "", false, payload, sizeof(payload), 3000, &line),
              RendezvousGroups::PacketVerdict::kDropBudget);
    EXPECT_EQ(r.DropCount(), 1u);
    // The window rolls over.
    EXPECT_EQ(r.OnPacket(7, 3, "", true, payload, sizeof(payload), 3000 + RendezvousGroups::kBudgetWindowMs, &line),
              RendezvousGroups::PacketVerdict::kEmit);
    EXPECT_EQ(line, "rendezvous_packet:" + ChatIdHexFor("wx4g0") + ":" + kPk1 + ":p:0102");
    // Byte budget: one oversize-within-frame burst.
    std::vector<uint8_t> big(RendezvousGroups::kPeerBytesPerWindow, 0xAA);
    EXPECT_EQ(r.OnPacket(7, 3, "", false, big.data(), 1100, 50000, &line), RendezvousGroups::PacketVerdict::kEmit);
    for (int i = 0; i < 5; ++i) {
        const auto v = r.OnPacket(7, 3, "", false, big.data(), 1100, 50000, &line);
        if (v != RendezvousGroups::PacketVerdict::kEmit) {
            EXPECT_EQ(v, RendezvousGroups::PacketVerdict::kDropBudget);
            break;
        }
    }
    // Too large for the frame.
    std::vector<uint8_t> huge(RendezvousGroups::kMaxPayloadBytes + 1, 0);
    EXPECT_EQ(r.OnPacket(7, 3, "", false, huge.data(), huge.size(), 90000, &line),
              RendezvousGroups::PacketVerdict::kDropTooLarge);
    // Unknown group / unknown peer.
    EXPECT_EQ(r.OnPacket(8, 3, "", false, payload, sizeof(payload), 90000, &line),
              RendezvousGroups::PacketVerdict::kDropUnknownPeer);
    EXPECT_EQ(r.OnPacket(7, 99, "", false, payload, sizeof(payload), 90000, &line),
              RendezvousGroups::PacketVerdict::kDropUnknownPeer);
    // A packet with the key supplied learns the peer.
    EXPECT_EQ(r.OnPacket(7, 99, kPk2, false, payload, sizeof(payload), 90000, &line),
              RendezvousGroups::PacketVerdict::kEmit);
    EXPECT_EQ(r.PeerPkFor(7, 99), kPk2);
}

TEST(RendezvousGroupsTest, PeerEventsCoalesceBeyondTheBudget) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    r.OnSelfJoin(7, 2000);
    uint32_t emitted = 0;
    uint32_t coalesced = 0;
    for (uint32_t i = 0; i < RendezvousGroups::kPeerEventsPerWindow + 10; ++i) {
        std::string pk(64, static_cast<char>('a' + (i % 6)));
        pk[0] = static_cast<char>('0' + (i % 10));
        for (const std::string& line : r.OnPeerJoin(7, 100 + i, pk, 3000)) {
            if (line.rfind("rendezvous_peer:", 0) == 0) ++emitted;
            if (line.rfind("rendezvous_peers_changed:", 0) == 0) ++coalesced;
        }
    }
    EXPECT_EQ(emitted, RendezvousGroups::kPeerEventsPerWindow);
    EXPECT_EQ(coalesced, 1u);  // one summary per burst
}

TEST(RendezvousGroupsTest, BufferedLinesAreBoundedAndTaken) {
    RendezvousGroups r;
    for (size_t i = 0; i < RendezvousGroups::kMaxBufferedLines; ++i) EXPECT_TRUE(r.BufferLine("x"));
    EXPECT_FALSE(r.BufferLine("overflow"));
    EXPECT_EQ(r.DropCount(), 1u);
    EXPECT_EQ(r.TakeBufferedLines().size(), RendezvousGroups::kMaxBufferedLines);
    EXPECT_TRUE(r.TakeBufferedLines().empty());
}

TEST(RendezvousGroupsTest, ZombiesCountAsOwnedUntilForgottenOrTaken) {
    RendezvousGroups r;
    EXPECT_FALSE(r.HasZombies());
    r.NoteZombie(42, ChatIdHexFor("wx4g0"));
    EXPECT_TRUE(r.Owns(42));
    EXPECT_TRUE(r.IsZombie(42));
    EXPECT_TRUE(r.HasZombies());  // non-consuming: shutdown asks before it takes
    EXPECT_TRUE(r.HasZombies());
    r.ForgetZombie(42);
    EXPECT_FALSE(r.Owns(42));
    EXPECT_FALSE(r.HasZombies());
    r.NoteZombie(43, ChatIdHexFor("wx4g1"));
    r.NoteZombie(44, ChatIdHexFor("wx4g2"));
    const auto taken = r.TakeZombies();
    ASSERT_EQ(taken.size(), 2u);
    // Each zombie carries the chat id its `rendezvous_left` line needs.
    for (const auto& z : taken) {
        EXPECT_EQ(z.second, z.first == 43 ? ChatIdHexFor("wx4g1") : ChatIdHexFor("wx4g2"));
    }
    EXPECT_FALSE(r.Owns(43));
    EXPECT_FALSE(r.HasZombies());
    EXPECT_TRUE(r.TakeZombies().empty());
}

TEST(RendezvousGroupsTest, AJoinThatOutlivedItsGenerationIsAnOrphanAndTheReplacementCellIsUntouched) {
    RendezvousGroups r;
    r.SetAccepting(true);
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1000), 1);
    const std::vector<Action> first = r.Plan(1000);
    ASSERT_EQ(first.size(), 1u);  // kJoin issued with first[0]'s stamps
    // While tox_group_join is in flight the client leaves all (generation
    // bump; the unjoined cell is erased at once) and asks for the same cell
    // again: a replacement cell with its own pending join.
    r.BumpGeneration();
    EXPECT_EQ(r.RequestLeaveAll(1500), 1u);  // erased at once: nothing to leave in toxcore yet
    EXPECT_EQ(r.CellCount(), 0u);
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1500), 1);
    // The old join reports: refused under the lock, nothing owned, the driver
    // must leave group 7 — and the replacement is not touched.
    EXPECT_FALSE(r.OnJoinIssued(ChatIdHexFor("wx4g0"), 7, true, 1600, first[0].generation, first[0].attempt));
    EXPECT_FALSE(r.Owns(7));
    EXPECT_EQ(r.CellCount(), 1u);
    std::vector<Action> next = r.Plan(1700);
    ASSERT_EQ(next.size(), 1u);
    EXPECT_EQ(next[0].kind, Kind::kJoin);
    EXPECT_TRUE(r.Plan(1800).empty()) << "exactly one attempt for the replacement, never join + found";
    EXPECT_TRUE(r.OnJoinIssued(ChatIdHexFor("wx4g0"), 8, true, 1900, next[0].generation, next[0].attempt));
    EXPECT_TRUE(r.Owns(8));
    // A LeaveAll between Plan() and the Tox call is caught the same way: the
    // action carries the generation it was planned under.
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g1"), "n", "0123abcd", 2000), 1);
    const std::vector<Action> planned = r.Plan(2000);
    ASSERT_EQ(planned.size(), 1u);
    r.BumpGeneration();
    EXPECT_EQ(r.RequestLeaveAll(2050), 2u);
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g1"), "n", "0123abcd", 2050), 1);
    EXPECT_FALSE(r.OnFoundIssued(ChatIdHexFor("wx4g1"), 9, true, 2100, planned[0].generation, planned[0].attempt));
    EXPECT_FALSE(r.OnJoinIssued(ChatIdHexFor("wx4g1"), 9, true, 2100, planned[0].generation, planned[0].attempt));
    EXPECT_FALSE(r.Owns(9));
}

TEST(RendezvousGroupsTest, AFoundIsRefusedWhileALeaveIsOwedAndPlannedAgainAfterIt) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    // Nobody answered for 30 s: leave first (refound).
    const uint64_t t = 1000 + RendezvousGroups::kJoinToFoundMs;
    std::vector<Action> batch = r.Plan(t);
    ASSERT_EQ(batch.size(), 1u);
    EXPECT_EQ(batch[0].kind, Kind::kLeave);
    EXPECT_EQ(batch[0].reason, "refound");
    // The leave fails: group 7 is still held; a found that somehow reports
    // now must not overwrite it — refused, the driver leaves group 8.
    r.OnLeaveFailed(ChatIdHexFor("wx4g0"), t);
    EXPECT_FALSE(r.OnFoundIssued(ChatIdHexFor("wx4g0"), 8, true, t + 1, batch[0].generation, batch[0].attempt));
    EXPECT_TRUE(r.Owns(7));
    EXPECT_FALSE(r.Owns(8));
    // The retried leave succeeds -> retiring; still no found while toxcore
    // holds group 7.
    batch = r.Plan(t + RendezvousGroups::kLeaveRetryMs);
    ASSERT_EQ(batch.size(), 1u);
    EXPECT_EQ(batch[0].kind, Kind::kLeave);
    EXPECT_EQ(batch[0].group_number, 7u);
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "refound", t + RendezvousGroups::kLeaveRetryMs, 7);
    EXPECT_TRUE(r.Owns(7));
    EXPECT_TRUE(r.Plan(t + RendezvousGroups::kLeaveRetryMs + 1).empty());
    EXPECT_FALSE(r.OnFoundIssued(ChatIdHexFor("wx4g0"), 8, true, t + 2, batch[0].generation, batch[0].attempt));
    // Gone: the found is planned, with a fresh attempt.
    Retire(r, "wx4g0", t + RendezvousGroups::kLeaveRetryMs + 10);
    EXPECT_FALSE(r.Owns(7));
    batch = r.Plan(t + RendezvousGroups::kLeaveRetryMs + 10);
    ASSERT_EQ(batch.size(), 1u);
    EXPECT_EQ(batch[0].kind, Kind::kFound);
    EXPECT_TRUE(r.OnFoundIssued(ChatIdHexFor("wx4g0"), 9, true, t + RendezvousGroups::kLeaveRetryMs + 11,
                                batch[0].generation, batch[0].attempt));
    EXPECT_TRUE(r.Owns(9));
}

TEST(RendezvousGroupsTest, AFailedLeaveKeepsTheCellOwnedAndRetriesLater) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    EXPECT_TRUE(r.RequestLeave(ChatIdHexFor("wx4g0"), 2000));
    std::vector<Action> actions = r.Plan(2000);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kLeave);
    EXPECT_EQ(actions[0].group_number, 7u);
    // toxcore kept the group: ownership stays (callbacks are still diverted),
    // the left line is not emitted, and the leave is owed again later.
    r.OnLeaveFailed(ChatIdHexFor("wx4g0"), 2000);
    EXPECT_TRUE(r.Owns(7));
    EXPECT_EQ(r.CellCount(), 1u);
    EXPECT_TRUE(r.Plan(2000 + RendezvousGroups::kLeaveRetryMs - 1).empty());
    // A client leave-all (shutdown) does not wait for the retry delay.
    EXPECT_EQ(r.RequestLeaveAll(2500), 1u);
    actions = r.Plan(2500);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kLeave);
    r.OnLeaveFailed(ChatIdHexFor("wx4g0"), 2500);
    EXPECT_TRUE(r.Plan(2500 + RendezvousGroups::kLeaveRetryMs - 1).empty());
    actions = r.Plan(2500 + RendezvousGroups::kLeaveRetryMs);
    ASSERT_EQ(actions.size(), 1u);
    EXPECT_EQ(actions[0].kind, Kind::kLeave);
    EXPECT_EQ(actions[0].group_number, 7u);
    r.OnLeaveIssued(ChatIdHexFor("wx4g0"), "left", 2500 + RendezvousGroups::kLeaveRetryMs, 7);
    EXPECT_TRUE(r.Owns(7)) << "retiring until toxcore deleted it";
    Retire(r, "wx4g0", 2500 + RendezvousGroups::kLeaveRetryMs + 10);
    EXPECT_FALSE(r.Owns(7));
    EXPECT_EQ(r.CellCount(), 0u);
}

TEST(RendezvousGroupsTest, AJoinThatReportsAfterTheCellLeftIsAnOrphan) {
    RendezvousGroups r;
    r.SetAccepting(true);
    ASSERT_EQ(r.RequestJoin(SeedFor("wx4g0"), "n", "0123abcd", 1000), 1);
    const std::vector<Action> issued = r.Plan(1000);
    ASSERT_EQ(issued.size(), 1u);  // kJoin issued
    // The client leaves before toxcore answered: the cell is erased at once
    // (nothing to leave yet) ...
    EXPECT_TRUE(r.RequestLeave(ChatIdHexFor("wx4g0"), 1500));
    EXPECT_EQ(r.CellCount(), 0u);
    // ... so the join's report finds nobody: the driver must leave group 7.
    EXPECT_FALSE(r.OnJoinIssued(ChatIdHexFor("wx4g0"), 7, true, 1600, issued[0].generation, issued[0].attempt));
    EXPECT_FALSE(r.Owns(7));
    EXPECT_FALSE(r.OnFoundIssued(ChatIdHexFor("wx4g0"), 8, true, 1600, issued[0].generation, issued[0].attempt));
}

TEST(RendezvousGroupsTest, ClearDropsOwnershipAndAdmission) {
    RendezvousGroups r;
    r.SetAccepting(true);
    JoinCell(r, "wx4g0", 7, 1000);
    r.NoteZombie(9, ChatIdHexFor("wx4g9"));
    r.Clear();
    EXPECT_FALSE(r.Owns(7));
    EXPECT_FALSE(r.Owns(9));
    EXPECT_FALSE(r.Accepting());
    EXPECT_EQ(r.CellCount(), 0u);
}

TEST(RendezvousGroupsTest, HexRoundTrip) {
    const uint8_t bytes[] = {0x00, 0x7f, 0xab, 0xff};
    EXPECT_EQ(RendezvousGroups::Hex(bytes, sizeof(bytes)), "007fabff");
    uint8_t out[4];
    EXPECT_TRUE(RendezvousGroups::Unhex("007fabff", out, 4));
    EXPECT_EQ(0, memcmp(out, bytes, 4));
    EXPECT_FALSE(RendezvousGroups::Unhex("007fabf", out, 4));
    EXPECT_FALSE(RendezvousGroups::Unhex("007fabzz", out, 4));
}

}  // namespace
