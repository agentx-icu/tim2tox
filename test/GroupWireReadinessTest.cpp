// tim2tox_ffi_group_wire_ready used to be tox_group_is_connected(), which is
// also true for CS_CONNECTING: right after a rejoin or a restart a group send
// "succeeded" while reaching nobody, so Dart never queued it (tim2tox#28).
// The first half pins the bookkeeping, the second that the manager feeds it
// from every join site and toxcore's self_join / peer_join / peer_exit.

#include "GroupWireReadiness.h"

#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH is required"
#endif

namespace {

using tim2tox::GroupWireReadiness;

constexpr GroupWireReadiness::GroupNumber kGroup = 3;
constexpr GroupWireReadiness::GroupNumber kOtherGroup = 4;

TEST(GroupWireReadinessTest, UnknownGroupIsNotReady) {
    GroupWireReadiness r;
    EXPECT_FALSE(r.Ready(kGroup));
    EXPECT_FALSE(r.AwaitingSync(kGroup));
}

TEST(GroupWireReadinessTest, SyncedGroupWithoutConfirmedPeerIsNotReady) {
    // A founder alone, or self_join arriving one round trip before the first
    // peer-info response confirms anyone.
    GroupWireReadiness r;
    r.BeginSync(kGroup);
    EXPECT_FALSE(r.SyncDone(kGroup));
    EXPECT_FALSE(r.Ready(kGroup));
}

TEST(GroupWireReadinessTest, FirstConfirmedPeerAfterSyncMakesReadyOnce) {
    GroupWireReadiness r;
    r.BeginSync(kGroup);
    r.SyncDone(kGroup);
    EXPECT_TRUE(r.PeerConfirmed(kGroup, 7));   // the drain trigger
    EXPECT_TRUE(r.Ready(kGroup));
    EXPECT_FALSE(r.PeerConfirmed(kGroup, 8));  // already ready: no 2nd trigger
    EXPECT_FALSE(r.PeerConfirmed(kGroup, 7));  // duplicate
    EXPECT_FALSE(r.Ready(kOtherGroup));
}

TEST(GroupWireReadinessTest, PeerConfirmedBeforeSyncWaitsForSelfJoin) {
    GroupWireReadiness r;
    r.BeginSync(kGroup);
    EXPECT_FALSE(r.PeerConfirmed(kGroup, 1));
    EXPECT_FALSE(r.Ready(kGroup));
    // self_join then reports ready; its own notification does the drain.
    EXPECT_TRUE(r.SyncDone(kGroup));
    EXPECT_TRUE(r.Ready(kGroup));
}

TEST(GroupWireReadinessTest, RejoinDropsPeersOfTheOldConnection) {
    // gc_rejoin_group marks every peer for deletion; they stay "confirmed"
    // until the next iterate and never fire peer_join again.
    GroupWireReadiness r;
    r.SyncDone(kGroup);
    r.PeerConfirmed(kGroup, 1);
    ASSERT_TRUE(r.Ready(kGroup));
    r.BeginSync(kGroup);
    EXPECT_FALSE(r.Ready(kGroup));
    r.SyncDone(kGroup);
    EXPECT_FALSE(r.Ready(kGroup));
    // The old connection's late peer_exit must not disturb the new one.
    r.PeerExited(kGroup, 1);
    EXPECT_TRUE(r.PeerConfirmed(kGroup, 2));
    EXPECT_TRUE(r.Ready(kGroup));
}

TEST(GroupWireReadinessTest, LastPeerExitEndsReadinessAndNextPeerRetriggers) {
    GroupWireReadiness r;
    r.SyncDone(kGroup);
    r.PeerConfirmed(kGroup, 1);
    r.PeerConfirmed(kGroup, 2);
    r.PeerExited(kGroup, 1);
    EXPECT_TRUE(r.Ready(kGroup));
    r.PeerExited(kGroup, 2);
    EXPECT_FALSE(r.Ready(kGroup));
    EXPECT_TRUE(r.PeerConfirmed(kGroup, 3));
}

TEST(GroupWireReadinessTest, ForgetAndClearDropEverything) {
    GroupWireReadiness r;
    r.PeerConfirmed(kGroup, 1);
    r.BeginSync(kOtherGroup);
    r.Forget(kGroup);
    EXPECT_FALSE(r.Ready(kGroup));
    EXPECT_TRUE(r.AwaitingSync(kOtherGroup));
    r.Clear();
    EXPECT_FALSE(r.AwaitingSync(kOtherGroup));
}

TEST(GroupWireReadinessTest, RefusedJoinSlotReusedByCreatedGroupBecomesReady) {
    // A refused invite join leaves its group number awaiting a sync that never
    // comes; toxcore then deletes the group and hands the number to the next
    // one. A group WE create gets no BeginSync (and no self_join), so only
    // Forget on the refusal lets its first confirmed peer make it ready.
    GroupWireReadiness r;
    r.BeginSync(kGroup);   // the accept
    r.Forget(kGroup);      // the refusal
    EXPECT_TRUE(r.PeerConfirmed(kGroup, 5));  // created group, slot reused
    EXPECT_TRUE(r.Ready(kGroup));
}

TEST(GroupWireReadinessTest, UnforgottenRefusedJoinBlocksTheReusedSlot) {
    // The bug pinned above: without Forget the reused slot never turns ready.
    GroupWireReadiness r;
    r.BeginSync(kGroup);
    EXPECT_FALSE(r.PeerConfirmed(kGroup, 5));
    EXPECT_FALSE(r.Ready(kGroup));
}

std::string ReadSource(const char* path) {
    std::ifstream input(path, std::ios::binary);
    EXPECT_TRUE(input.good()) << path;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

std::string SourceSection(const std::string& source,
                          const char* start_marker,
                          const char* end_marker) {
    const std::size_t start = source.find(start_marker);
    EXPECT_NE(start, std::string::npos) << start_marker;
    if (start == std::string::npos) return {};
    const std::size_t end = source.find(end_marker, start + 1);
    EXPECT_NE(end, std::string::npos) << end_marker;
    if (end == std::string::npos) return {};
    return source.substr(start, end - start);
}

std::size_t Count(const std::string& haystack, const std::string& needle) {
    std::size_t n = 0;
    for (std::size_t pos = haystack.find(needle); pos != std::string::npos;
         pos = haystack.find(needle, pos + needle.size())) {
        ++n;
    }
    return n;
}

TEST(GroupWireReadinessSourceTest, WireReadyRequiresSyncAndConfirmedPeer) {
    const std::string ffi = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string body = SourceSection(
        ffi, "int tim2tox_ffi_group_wire_ready(", "int tim2tox_ffi_send_group_action(");
    EXPECT_NE(body.find("if (!connected) return 0;"), std::string::npos);
    EXPECT_NE(body.find("manager_impl->IsGroupWireReady(group_number) ? 1 : 0"),
              std::string::npos);
    EXPECT_EQ(body.find("return connected ? 1 : 0;"), std::string::npos);
}

TEST(GroupWireReadinessSourceTest, EveryJoinSiteBeginsASync) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    // tox_group_invite_accept x2 (auto accept, JoinGroup invite path),
    // tox_manager->joinGroup x2 (JoinGroup by chat id, RejoinKnownGroups),
    // and the restore loop.
    EXPECT_EQ(Count(manager, "tox_group_invite_accept("), 2u);
    EXPECT_EQ(Count(manager, "tox_manager->joinGroup("), 2u);
    EXPECT_EQ(Count(manager, "BeginGroupWireSync(group_number);"), 5u);

    const std::string join = SourceSection(
        manager, "void V2TIMManagerImpl::JoinGroup(", "void V2TIMManagerImpl::QuitGroup(");
    // The rejoin path (existing group number) must begin a sync too.
    const std::string after_join = SourceSection(
        join, "if (existing_group_number != UINT32_MAX) {\n            // Reconnect",
        "SetGroupChatIdInStorage(");
    EXPECT_NE(after_join.find("BeginGroupWireSync(group_number);"), std::string::npos);
}

TEST(GroupWireReadinessSourceTest, ToxcoreCallbacksFeedTheTracker) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    EXPECT_NE(manager.find("group_wire_readiness_.SyncDone(group_number);"),
              std::string::npos);
    EXPECT_NE(manager.find("this->HandleGroupPeerConfirmed(group_number, peer_id);"),
              std::string::npos);
    EXPECT_NE(manager.find("group_wire_readiness_.PeerExited(group_number, peer_id);"),
              std::string::npos);
    EXPECT_NE(manager.find("group_wire_readiness_.Clear();"), std::string::npos);
    // Per-number state is forgotten in exactly one place, which forgets the
    // fresh join, the accepted invite and the peer cache along with it.
    EXPECT_EQ(Count(manager, "group_wire_readiness_.Forget("), 1u);
    const std::string forget = SourceSection(
        manager, "void V2TIMManagerImpl::ForgetGroupNumberLocked(",
        "void V2TIMManagerImpl::EraseGroupLocalState(");
    EXPECT_NE(forget.find("group_wire_readiness_.Forget(group_number);"), std::string::npos);
    EXPECT_NE(forget.find("fresh_group_joins_.erase(group_number);"), std::string::npos);
    EXPECT_NE(forget.find("accepted_invites_.erase(group_number);"), std::string::npos);
    EXPECT_NE(forget.find("group_peer_id_cache_.erase(group_number);"), std::string::npos);
    // Quit and dismiss both go through it (they used to skip the peer cache).
    EXPECT_EQ(Count(manager, "ForgetGroupNumberLocked(resolved_group_number);"), 2u);

    const std::string confirmed = SourceSection(
        manager, "void V2TIMManagerImpl::HandleGroupPeerConfirmed(",
        "void V2TIMManagerImpl::HandleGroupPrivacyState(");
    // Notify only on the transition, and outside mutex_.
    EXPECT_NE(confirmed.find("if (!group_wire_readiness_.PeerConfirmed(group_number, peer_id)) return;"),
              std::string::npos);
    const std::size_t unlock = confirmed.find("    }\n");
    const std::size_t notify = confirmed.find("DartNotifyGroupJoin(");
    ASSERT_NE(notify, std::string::npos);
    EXPECT_LT(unlock, notify);
}

TEST(GroupWireReadinessSourceTest, LeavingGroupForgetsItsNumberNotJustItsId) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string erase = SourceSection(
        manager, "void V2TIMManagerImpl::EraseGroupLocalStateLocked(",
        "void V2TIMManagerImpl::HandleGroupModeration(");
    // The caller's number is forgotten before (and independently of) the id
    // lookup, which finds nothing once an alias mapping is gone.
    const std::size_t direct = erase.find("ForgetGroupNumberLocked(group_number);");
    const std::size_t by_id = erase.find("group_id_to_group_number_.find(groupID)");
    ASSERT_NE(direct, std::string::npos);
    ASSERT_NE(by_id, std::string::npos);
    EXPECT_LT(direct, by_id);
    // Reverse entries are only erased when they still name this group.
    EXPECT_EQ(erase.find("group_number_to_group_id_.erase(gnum);"), std::string::npos);
    EXPECT_EQ(erase.find("chat_id_to_group_id_.erase(chat_id_hex);"), std::string::npos);

    // A self-kick passes toxcore's number.
    EXPECT_NE(manager.find("EraseGroupLocalState(groupID, group_number);"), std::string::npos);
    EXPECT_EQ(manager.find("EraseGroupLocalState(groupID);"), std::string::npos);
}

TEST(GroupWireReadinessSourceTest, RefusedJoinForgetsItsNumberBeforeDroppingTheAlias) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string fail = SourceSection(
        manager, "void V2TIMManagerImpl::HandleGroupJoinFail(",
        "void V2TIMManagerImpl::MarkFreshGroupJoin(");
    const std::size_t restore = fail.find("accepted_invites_.erase(accepted);");
    const std::size_t erase = fail.find("EraseGroupLocalStateLocked(groupID, group_number);");
    const std::size_t alias = fail.find("group_id_to_group_number_.erase(alias_number);");
    const std::size_t notify = fail.find("DartNotifyGroupJoinFailed(");
    ASSERT_NE(restore, std::string::npos);
    ASSERT_NE(erase, std::string::npos);
    ASSERT_NE(alias, std::string::npos);
    ASSERT_NE(notify, std::string::npos);
    // Invite handed back first (its record is per-number state), then the
    // number forgotten, then the alias dropped; all before Dart hears of it.
    EXPECT_LT(restore, erase);
    EXPECT_LT(erase, alias);
    EXPECT_LT(alias, notify);
    // Undone only for a join started this session, and not a second time
    // after the notifications.
    EXPECT_NE(fail.find("if (fresh) {"), std::string::npos);
    EXPECT_EQ(fail.find("EraseGroupLocalState(groupID"), std::string::npos);
}

}  // namespace
