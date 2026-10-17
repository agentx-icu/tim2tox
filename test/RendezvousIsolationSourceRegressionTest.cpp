// Rendezvous groups are transport only. The guarantee is structural: every
// group callback / handler in V2TIMManagerImpl diverts an owned group number
// before any V2TIM bookkeeping runs, the invite callback drops invites to a
// cell, restored cells are left on init, UnInitSDK leaves cells before the
// final save, and the FFI layer installs the instance-stamping sink before
// InitSDK. This pins the source text of those seams (the behaviour itself
// needs a live Tox and is covered by auto_tests/scenario_rendezvous_group).

#include <gtest/gtest.h>

#include <algorithm>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_RENDEZVOUS_SOURCE_PATH
#error "TIM2TOX_RENDEZVOUS_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_GROUP_MANAGER_SOURCE_PATH
#error "TIM2TOX_GROUP_MANAGER_SOURCE_PATH is required"
#endif

namespace {

std::string ReadFile(const char* path) {
    std::ifstream in(path);
    std::stringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

const std::string& ManagerSource() {
    static const std::string src = ReadFile(TIM2TOX_MANAGER_SOURCE_PATH);
    return src;
}

const std::string& FfiSource() {
    static const std::string src = ReadFile(TIM2TOX_FFI_SOURCE_PATH);
    return src;
}

const std::string& DriverSource() {
    static const std::string src = ReadFile(TIM2TOX_RENDEZVOUS_SOURCE_PATH);
    return src;
}

// The guard must be the first statement of the handler body.
void ExpectGuardedHandler(const std::string& name) {
    const std::regex def("void V2TIMManagerImpl::" + name + R"(\(([^)]*)\)\s*\{\s*if \(rendezvous_\.Owns\()");
    EXPECT_TRUE(std::regex_search(ManagerSource(), def)) << name << " is not guarded by rendezvous_.Owns at entry";
}

TEST(RendezvousIsolationSourceRegressionTest, EveryGroupHandlerDivertsOwnedGroupsFirst) {
    for (const char* name : {
             "HandleGroupMessageGroup", "HandleGroupPrivateMessage", "HandleGroupTopic", "HandleGroupPeerNameGroup",
             "HandleGroupPrivacyState", "HandleGroupVoiceState", "HandleGroupPeerStatus", "HandleGroupPeerConfirmed",
             "HandleGroupCustomPacket", "HandleGroupCustomPrivatePacket", "HandleGroupPeerJoin", "HandleGroupPeerExit",
             "HandleGroupModeration", "HandleGroupJoinFail", "HandleGroupSelfJoin",
         }) {
        ExpectGuardedHandler(name);
    }
}

TEST(RendezvousIsolationSourceRegressionTest, CallbackLambdasWithBookkeepingAreGuarded) {
    const std::string& src = ManagerSource();
    // self_join: readiness + identity announce bookkeeping lives in the lambda.
    const std::regex self_join(
        R"(setGroupSelfJoinCallback\(\s*\[this\]\(Tox_Group_Number group_number\) \{\s*if \(rendezvous_\.Owns\(group_number\)\))");
    EXPECT_TRUE(std::regex_search(src, self_join));
    // peer_exit: readiness PeerExited lives in the lambda.
    const std::regex peer_exit(
        R"(setGroupPeerExitCallback\(\s*\[this\]\([^)]*\) \{\s*if \(rendezvous_\.Owns\(group_number\)\))");
    EXPECT_TRUE(std::regex_search(src, peer_exit));
}

TEST(RendezvousIsolationSourceRegressionTest, InviteToACellIsDroppedBeforeAutoAccept) {
    const std::string& src = ManagerSource();
    const std::regex invite(
        R"(setGroupInviteGroupCallback\(\s*\[this\]\([^)]*\) \{\s*if \(RendezvousInviteIsOurs\(invite_data, invite_data_length, invited_group_name\)\))");
    EXPECT_TRUE(std::regex_search(src, invite));
}

TEST(RendezvousIsolationSourceRegressionTest, RestoreSweepLeavesCellsAndOpensAdmissionAfterwards) {
    const std::string& src = ManagerSource();
    const size_t sweep = src.find("if (RendezvousRestoredZombie(tox, group_number)) continue;");
    const size_t start = src.find("RendezvousStart();");
    const size_t self_join_cb = src.find("setGroupSelfJoinCallback(");
    ASSERT_NE(sweep, std::string::npos);
    ASSERT_NE(start, std::string::npos);
    ASSERT_NE(self_join_cb, std::string::npos);
    EXPECT_LT(sweep, start) << "admission must open after the restore sweep";
    EXPECT_LT(start, self_join_cb) << "admission opens before the self-join callback is registered";
}

TEST(RendezvousIsolationSourceRegressionTest, UnInitLeavesCellsBeforeStoppingTheEventThread) {
    const std::string& src = ManagerSource();
    const size_t uninit = src.find("void V2TIMManagerImpl::UnInitSDK() {");
    ASSERT_NE(uninit, std::string::npos);
    const size_t shutdown = src.find("RendezvousShutdown();", uninit);
    const size_t running_false = src.find("running_.store(false, std::memory_order_release);", uninit);
    const size_t close_admission = src.find("closeAdmission();", uninit);
    ASSERT_NE(shutdown, std::string::npos);
    ASSERT_NE(running_false, std::string::npos);
    ASSERT_NE(close_admission, std::string::npos);
    EXPECT_LT(shutdown, running_false);
    EXPECT_LT(shutdown, close_admission);
}

TEST(RendezvousIsolationSourceRegressionTest, ResetClearsTheRegistryAndTheLoopTicks) {
    const std::string& src = ManagerSource();
    EXPECT_NE(src.find("void V2TIMManagerImpl::ResetGroupSessionState() {\n    rendezvous_.Clear();"), std::string::npos);
    EXPECT_NE(src.find("RendezvousTick();"), std::string::npos);
    // Ownership survives the shutdown leaves: the event thread may iterate
    // again before UnInitSDK stops it, and toxcore delivers the pending
    // packets of a flagged group before deleting it. Only the reset (after
    // StopBackgroundTasks) clears the registry.
    EXPECT_EQ(DriverSource().find("rendezvous_.Clear()"), std::string::npos)
        << "the driver must never clear ownership itself";
    const size_t uninit = src.find("void V2TIMManagerImpl::UnInitSDK() {");
    const size_t stop = src.find("StopBackgroundTasks();", uninit);
    const size_t reset = src.find("ResetGroupSessionState();", uninit);
    ASSERT_NE(stop, std::string::npos);
    ASSERT_NE(reset, std::string::npos);
    EXPECT_LT(stop, reset);
}

TEST(RendezvousIsolationSourceRegressionTest, DriverChecksEpochBeforeAndGenerationAfterEveryToxCall) {
    const std::string& src = DriverSource();
    // Pre-call: pin + epoch + Expired.
    EXPECT_NE(src.find("if (session.Expired() || GetSessionEpoch() != epoch) return;"), std::string::npos);
    EXPECT_NE(src.find("session.epoch() != epoch || session.Expired()) return 0;"), std::string::npos);
    // Post-call: the captured generation is handed to the registry, which
    // compares it under its lock atomically with the record (an orphan is
    // undone); the leave path re-checks it before recording.
    EXPECT_NE(src.find("rendezvous_.OnJoinIssued(action.chat_id_hex, gn, ok, now_ms, generation, action.attempt)"),
              std::string::npos);
    EXPECT_NE(src.find("rendezvous_.OnFoundIssued(action.chat_id_hex, gn, ok, now_ms, generation, action.attempt)"),
              std::string::npos);
    EXPECT_NE(src.find("if (rendezvous_.Generation() == generation) {"), std::string::npos);
    // The generation is the one the action was planned under, not re-read.
    EXPECT_NE(src.find("const uint64_t generation = action.generation;"), std::string::npos);
    // Left cells stay owned until toxcore deleted the group (observed per tick).
    EXPECT_NE(src.find("RendezvousConfirmRetired(tox, now);"), std::string::npos);
    // A number is only left while it still holds our chat id, and a
    // successful leave is recorded whatever the generation did meanwhile.
    EXPECT_NE(src.find("RendezvousGroupIs(tox, action.group_number, action.chat_id_hex);"), std::string::npos);
    EXPECT_NE(src.find("rendezvous_.OnLeaveIssued(action.chat_id_hex, action.reason, now_ms, action.group_number);"),
              std::string::npos);
    // Every successful leave of a non-cell group notes a retiring orphan.
    size_t orphans = 0;
    for (size_t pos = src.find("rendezvous_.NoteRetiringOrphan("); pos != std::string::npos;
         pos = src.find("rendezvous_.NoteRetiringOrphan(", pos + 1)) {
        ++orphans;
    }
    EXPECT_EQ(orphans, 3u) << "undo, zombies and the restore sweep";
    // A reused number is released before the self-join is diverted.
    const std::string& mgr = ManagerSource();
    EXPECT_NE(mgr.find("if (rendezvous_.Owns(group_number) && !RendezvousReleaseIfReused(group_number)) {"),
              std::string::npos);
    // Callbacks never leave inside toxcore: the zombie path only marks and
    // nudges Tick(), which leaves on the event thread.
    EXPECT_NE(src.find("rendezvous_.NoteZombie(group_number, RendezvousGroups::Hex(chat_id, sizeof(chat_id)));\n"
                       "    PostToEventThread([this]() { RendezvousTick(); });"),
              std::string::npos);
    EXPECT_EQ(src.find("LeaveQuietly"), std::string::npos) << "every tox_group_leave result is checked";
    // A zombie is noted only through a pin that is still current: a group
    // number from an expired session must never enter the next registry.
    EXPECT_NE(src.find("if (session.Expired() || GetSessionEpoch() != epoch) return;\n"
                       "        if (LeaveGroup(tox, gn, why)) {"),
              std::string::npos);
    EXPECT_NE(src.find("} else if (!session.Expired() && GetSessionEpoch() == epoch) {\n"
                       "                    rendezvous_.NoteZombie(action.group_number, action.chat_id_hex);"),
              std::string::npos);
}

TEST(RendezvousIsolationSourceRegressionTest, EveryLeaveResultIsCheckedAndShutdownNeverDropsAZombie) {
    const std::string& src = DriverSource();
    // The one leave helper returns whether toxcore let go of the group, and
    // every caller acts on a false (zombie / re-plan), never ignores it.
    EXPECT_NE(src.find("bool LeaveGroup(Tox* tox, Tox_Group_Number group_number, const char* why)"), std::string::npos);
    size_t calls = 0, checked = 0;
    for (size_t pos = src.find("LeaveGroup("); pos != std::string::npos; pos = src.find("LeaveGroup(", pos + 1)) {
        ++calls;
        const std::string before = src.substr(pos >= 40 ? pos - 40 : 0, pos >= 40 ? 40 : pos);
        if (before.find("if (") != std::string::npos || before.find("|| !") != std::string::npos ||
            before.find("|| ") != std::string::npos || before.find("bool ") != std::string::npos ||  // the definition
            before.find("bool gone") != std::string::npos || before.find("UINT32_MAX || ") != std::string::npos) {
            ++checked;
        }
    }
    EXPECT_GE(calls, 5u);
    EXPECT_EQ(calls, checked) << "a LeaveGroup() result was ignored";
    // Shutdown asks for zombies without consuming them, then leaves them.
    EXPECT_NE(src.find("rendezvous_.CellCount() == 0 && rendezvous_.Inflight() == 0 && !rendezvous_.HasZombies()"),
              std::string::npos);
    const size_t leave_all_now = src.find("bool V2TIMManagerImpl::RendezvousLeaveAllNow()");
    ASSERT_NE(leave_all_now, std::string::npos);
    EXPECT_NE(src.find("RendezvousLeaveZombies(session.tox());", leave_all_now), std::string::npos);
    // Tick() leaves zombies too, and still runs when only zombies remain.
    EXPECT_NE(src.find("if (rendezvous_.CellCount() == 0 && !rendezvous_.HasZombies() && rendezvous_.Retiring().empty()) return;"),
              std::string::npos);
    // A synchronous join/found failure is reported to the client.
    EXPECT_NE(src.find("if (!ok) RendezvousEmit(RendezvousGroups::LeftLine(action.chat_id_hex, \"failed\"));"),
              std::string::npos);
    EXPECT_NE(src.find(": RendezvousGroups::LeftLine(action.chat_id_hex, \"failed\"));"), std::string::npos);
}

TEST(RendezvousIsolationSourceRegressionTest, IdentityAnnounceAndGroupManagerSkipOwnedGroups) {
    const std::string& src = ManagerSource();
    const size_t announce = src.find("void V2TIMManagerImpl::AnnounceGroupIdentities(");
    ASSERT_NE(announce, std::string::npos);
    const size_t guard = src.find("if (rendezvous_.Owns(group_number)) continue;", announce);
    const size_t digests = src.find("std::string digests;", announce);
    ASSERT_NE(guard, std::string::npos);
    ASSERT_NE(digests, std::string::npos);
    EXPECT_LT(digests, guard);
    EXPECT_LT(guard, digests + 400) << "the guard must sit in the per-group loop";
    const std::string gm = ReadFile(TIM2TOX_GROUP_MANAGER_SOURCE_PATH);
    size_t count = 0;
    for (size_t pos = gm.find("manager_impl_->IsRendezvousGroupNumber(group_number)) continue;"); pos != std::string::npos;
         pos = gm.find("manager_impl_->IsRendezvousGroupNumber(group_number)) continue;", pos + 1)) {
        ++count;
    }
    EXPECT_EQ(count, 2u) << "both toxcore group-list walks in V2TIMGroupManagerImpl skip rendezvous cells";
}

TEST(RendezvousIsolationSourceRegressionTest, EveryTestModeIterateHookTicksThePlanner) {
    const std::string& src = FfiSource();
    for (const char* fn : {"int tim2tox_ffi_iterate_current_instance(", "int tim2tox_ffi_iterate_instance(",
                           "int tim2tox_ffi_iterate_all_instances("}) {
        const size_t start = src.find(fn);
        ASSERT_NE(start, std::string::npos) << fn;
        const size_t end = src.find("\n}\n", start);
        ASSERT_NE(end, std::string::npos) << fn;
        EXPECT_NE(src.substr(start, end - start).find("RendezvousTick();"), std::string::npos) << fn;
    }
}

TEST(RendezvousIsolationSourceRegressionTest, LeaveAllIsAGenerationBoundaryAndSendsAdmitFirst) {
    const std::string& src = DriverSource();
    const size_t leave_all = src.find("int V2TIMManagerImpl::RendezvousLeaveAll()");
    ASSERT_NE(leave_all, std::string::npos);
    EXPECT_NE(src.find("rendezvous_.BumpGeneration();", leave_all), std::string::npos);
    const size_t send = src.find("int V2TIMManagerImpl::RendezvousSend(");
    ASSERT_NE(send, std::string::npos);
    const size_t admission = src.find("const Admission admission(rendezvous_);", send);
    const size_t lookup = src.find("rendezvous_.GroupNumberFor(", send);
    ASSERT_NE(admission, std::string::npos);
    ASSERT_NE(lookup, std::string::npos);
    EXPECT_LT(admission, lookup) << "in-flight + generation + epoch are captured before the registry lookup";
    // Shutdown leaves zombies inline rather than discarding them.
    EXPECT_NE(src.find("rendezvous_.TakeZombies()"), std::string::npos);
}

TEST(RendezvousIsolationSourceRegressionTest, FfiInstallsTheSinkBeforeInitSdkAndClassifiesPackets) {
    const std::string& src = FfiSource();
    const size_t default_sink = src.find("InstallRendezvousEventSink(manager_impl);");
    ASSERT_NE(default_sink, std::string::npos);
    const size_t default_init = src.find("manager_impl->InitSDK(0, cfg);", default_sink);
    ASSERT_NE(default_init, std::string::npos);
    const size_t instance_sink = src.find("InstallRendezvousEventSink(instance);");
    ASSERT_NE(instance_sink, std::string::npos);
    const size_t instance_init = src.find("instance->InitSDK(0, cfg);", instance_sink);
    ASSERT_NE(instance_init, std::string::npos);
    EXPECT_NE(src.find("HasPrefix(line, \"rendezvous_packet:\")"), std::string::npos);
}

}  // namespace
