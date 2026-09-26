// Regression: the Tox handle must survive a concurrent teardown for as long as
// an in-flight operation is using it.
//
// WHY THIS EXISTS: every FFI entry point used to do
//
//     ToxManager* m = GetToxManager();
//     Tox* tox = m ? m->getTox() : nullptr;      // raw, unpinned
//     ... several tox_*() calls ...
//
// while UnInitSDK() on another thread destroys the ToxManager and tox_kill()s
// the instance. Codex flagged SendGroupReceipt's
// tox_group_self_get_public_key + tox_group_send_custom_private_packet pair as
// reachable (2026-09-23), and the shape recurred throughout the file. Taking
// ToxManager's mutex for the whole sequence is NOT the fix: shutdown() takes
// iterate_mutex_ first and callers legitimately take it through lockIterate(),
// so a lock held across an operation deadlocks one way or the other, and
// blocking teardown would break deferred-teardown-from-a-callback.
//
// The fix is a refcount: ToxManager::acquireTox() hands out a shared_ptr that
// keeps the instance alive, and V2TIMManagerImpl::AcquireToxSession() wraps it
// together with the ToxManager itself. shutdown() still returns immediately; it
// just hands the tox_kill() to whoever is still inside an operation.

#include <gtest/gtest.h>

#include <atomic>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <thread>

#include "ToxManager.h"
#include "toxcore/tox.h"

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_MANAGER_HEADER_PATH
#error "TIM2TOX_MANAGER_HEADER_PATH is required"
#endif
#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_TOX_MANAGER_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_GROUP_MANAGER_SOURCE_PATH
#error "TIM2TOX_GROUP_MANAGER_SOURCE_PATH is required"
#endif

// ToxManager.cpp reaches for the FFI layer's instance registry in one group
// callback; nothing in this test drives a callback, and linking libtim2tox_ffi
// here would pull in the whole Dart bridge. Stub it, like the other unit tests
// that link only the static core.
extern "C++" int64_t GetCurrentInstanceId() { return 0; }

namespace {

std::string ReadSource(const char* path) {
    std::ifstream input(path, std::ios::binary);
    EXPECT_TRUE(input.good()) << path;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

// The text from start_marker up to end_marker, or to the end of the file when
// end_marker is null (RejoinKnownGroups is the last function in the file).
std::string SourceSection(
    const std::string& source,
    const char* start_marker,
    const char* end_marker) {
    const std::size_t start = source.find(start_marker);
    EXPECT_NE(start, std::string::npos) << start_marker;
    if (start == std::string::npos) return {};
    if (end_marker == nullptr) return source.substr(start);
    const std::size_t end = source.find(end_marker, start + 1);
    EXPECT_NE(end, std::string::npos) << end_marker;
    if (end == std::string::npos) return {};
    return source.substr(start, end - start);
}

// Drops `// ...` comments so the assertions below are about CODE. (A comment
// explaining the old idiom is not a use of it.)
std::string StripLineComments(const std::string& source) {
    std::string out;
    out.reserve(source.size());
    for (std::size_t i = 0; i < source.size();) {
        if (source[i] == '/' && i + 1 < source.size() && source[i + 1] == '/') {
            while (i < source.size() && source[i] != '\n') ++i;
            continue;
        }
        out.push_back(source[i]);
        ++i;
    }
    return out;
}

// A ToxManager with a live Tox, or nullptr when this host cannot create one
// (no sockets in the sandbox); the caller skips rather than fails.
std::unique_ptr<ToxManager> MakeLiveManager() {
    auto manager = std::make_unique<ToxManager>();
    try {
        manager->initialize();
    } catch (...) {
        return nullptr;
    }
    return manager->getTox() != nullptr ? std::move(manager) : nullptr;
}

std::string SelfPublicKeyHex(Tox* tox) {
    uint8_t key[TOX_PUBLIC_KEY_SIZE];
    tox_self_get_public_key(tox, key);
    std::ostringstream out;
    for (uint8_t byte : key) {
        out << std::hex << (static_cast<unsigned>(byte) >> 4)
            << (static_cast<unsigned>(byte) & 0xF);
    }
    return out.str();
}

TEST(ToxSessionPinTest, AcquireRefusesWhenThereIsNoSession) {
    ToxManager manager;
    EXPECT_EQ(manager.acquireTox(), nullptr)
        << "no Tox has been created yet: the operation must refuse, not "
           "receive a handle";
}

TEST(ToxSessionPinTest, PinnedHandleOutlivesShutdown) {
    std::unique_ptr<ToxManager> manager = MakeLiveManager();
    if (!manager) GTEST_SKIP() << "tox_new unavailable on this host";

    // What an FFI entry point does at its boundary.
    std::shared_ptr<Tox> pin = manager->acquireTox();
    ASSERT_NE(pin, nullptr);
    const std::string before = SelfPublicKeyHex(pin.get());

    // ... and what UnInitSDK does meanwhile.
    manager->shutdown();

    // New callers are refused: the session is over.
    EXPECT_EQ(manager->getTox(), nullptr);
    EXPECT_EQ(manager->acquireTox(), nullptr);
    EXPECT_TRUE(manager->isShuttingDown());

    // The in-flight operation still has a LIVE instance: before the pin,
    // tox_kill() ran inside shutdown() and every tox_*() after it was a
    // use-after-free.
    ASSERT_NE(pin.get(), nullptr);
    EXPECT_EQ(SelfPublicKeyHex(pin.get()), before);
    uint8_t address[TOX_ADDRESS_SIZE];
    tox_self_get_address(pin.get(), address);

    // tox_kill() happens here, on the operation's thread.
    pin.reset();
}

TEST(ToxSessionPinTest, ShutdownDoesNotBlockOnAPinAndThePinStaysUsable) {
    std::unique_ptr<ToxManager> manager = MakeLiveManager();
    if (!manager) GTEST_SKIP() << "tox_new unavailable on this host";

    std::shared_ptr<Tox> pin = manager->acquireTox();
    ASSERT_NE(pin, nullptr);

    // Teardown must complete while the pin is held — it must not wait for the
    // operation (that is the deadlock the refcount design avoids).
    std::atomic<bool> shutdown_done{false};
    std::thread tearer([&] {
        manager->shutdown();
        shutdown_done.store(true, std::memory_order_release);
    });
    tearer.join();
    EXPECT_TRUE(shutdown_done.load(std::memory_order_acquire));

    for (int i = 0; i < 64; ++i) {
        uint8_t key[TOX_PUBLIC_KEY_SIZE];
        tox_self_get_public_key(pin.get(), key);
    }
    pin.reset();
}

TEST(ToxSessionPinTest, NextSessionIsIndependentOfAnOldPin) {
    std::unique_ptr<ToxManager> manager = MakeLiveManager();
    if (!manager) GTEST_SKIP() << "tox_new unavailable on this host";

    std::shared_ptr<Tox> old_pin = manager->acquireTox();
    ASSERT_NE(old_pin, nullptr);
    const std::string old_key = SelfPublicKeyHex(old_pin.get());
    manager->shutdown();

    // An account switch (UnInitSDK -> InitSDK) while an operation is still
    // finishing: the new session gets its own instance, the old pin keeps
    // pointing at the old one.
    try {
        manager->initialize();
    } catch (...) {
        GTEST_SKIP() << "second tox_new unavailable on this host";
    }
    std::shared_ptr<Tox> fresh = manager->acquireTox();
    ASSERT_NE(fresh, nullptr);
    EXPECT_NE(fresh.get(), old_pin.get());
    EXPECT_EQ(SelfPublicKeyHex(old_pin.get()), old_key);

    old_pin.reset();
    fresh.reset();
    manager->shutdown();
}

// The conversion itself: the entry points reachable from a thread other than
// the tox-iterate one must take a session pin, not a raw handle. (Handle*
// callbacks deliberately keep the raw idiom — they run inside tox_iterate,
// where UnInitSDK / ToxManager::shutdown defer themselves.)
TEST(ToxSessionPinTest, FfiReachableEntryPointsPinTheSession) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string header = ReadSource(TIM2TOX_MANAGER_HEADER_PATH);

    EXPECT_NE(header.find("class ToxSessionGuard"), std::string::npos);
    EXPECT_NE(header.find("ToxSessionGuard AcquireToxSession() const"),
              std::string::npos);
    EXPECT_NE(header.find("std::shared_ptr<ToxManager> tox_manager_"),
              std::string::npos)
        << "the manager must be refcounted for a guard to pin it";

    struct Section {
        const char* name;
        const char* start;
        const char* end;
    };
    const Section sections[] = {
        {"SendGroupReceipt", "int V2TIMManagerImpl::SendGroupReceipt(",
         "void V2TIMManagerImpl::HandleGroupPrivateMessage("},
        {"SendGroupPrivateTextMessage",
         "V2TIMString V2TIMManagerImpl::SendGroupPrivateTextMessage(",
         "// Send group custom message"},
        {"SendGroupCustomMessage",
         "V2TIMString V2TIMManagerImpl::SendGroupCustomMessage(",
         "void V2TIMManagerImpl::CreateGroup("},
        {"CreateGroup", "void V2TIMManagerImpl::CreateGroup(",
         "void V2TIMManagerImpl::JoinGroup("},
        {"JoinGroup", "void V2TIMManagerImpl::JoinGroup(",
         "void V2TIMManagerImpl::QuitGroup("},
        {"GetUsersInfo", "void V2TIMManagerImpl::GetUsersInfo(",
         "void V2TIMManagerImpl::SubscribeUserInfo("},
        {"SetSelfInfo", "void V2TIMManagerImpl::SetSelfInfo(",
         "void V2TIMManagerImpl::SearchUsers("},
        {"ResolveGroupPeerIdForKey",
         "Tox_Group_Peer_Number V2TIMManagerImpl::ResolveGroupPeerIdForKey(",
         "V2TIMString V2TIMManagerImpl::SendGroupPrivateTextMessage("},
        {"RejoinKnownGroups", "void V2TIMManagerImpl::RejoinKnownGroups(",
         nullptr},
    };
    for (const Section& section : sections) {
        const std::string body =
            StripLineComments(SourceSection(manager, section.start, section.end));
        EXPECT_NE(body.find("AcquireToxSession()"), std::string::npos)
            << section.name << " must pin the session at its boundary";
        EXPECT_EQ(body.find("GetToxManager()->getTox()"), std::string::npos)
            << section.name << " must not re-fetch a raw, unpinned handle";
        EXPECT_EQ(body.find("tox_manager_->"), std::string::npos)
            << section.name
            << " must not reach through the member pointer: UnInitSDK nulls it";
    }

    // JoinGroup pumps tox_iterate() on the caller's thread; a teardown that a
    // callback deferred runs when that iterate returns, so every pump must be
    // followed by a currency check (the pin keeps the memory valid, not the
    // session current).
    const std::string join = SourceSection(manager,
                                           "void V2TIMManagerImpl::JoinGroup(",
                                           "void V2TIMManagerImpl::QuitGroup(");
    EXPECT_NE(join.find("session.Expired()"), std::string::npos);
    EXPECT_NE(join.find("join_session_ended()"), std::string::npos);
}

// --- codex 2026-09-24: the conversion was incomplete in these places --------

// Finding 1. ResolveFilePeer took the guard as a LOCAL, copied the raw Tox* into
// ResolvedFilePeer and returned — destroying the pin. Every caller then did its
// file sizing, context setup and tox_file_send() on an unpinned handle, and the
// comment claiming the pin covered "friend lookup + file_send + first chunk"
// was false. The guard now lives IN the struct.
TEST(ToxSessionPinTest, TheFilePathKeepsItsPinPastResolve) {
    const std::string ffi = StripLineComments(ReadSource(TIM2TOX_FFI_SOURCE_PATH));
    const std::string resolved =
        SourceSection(ffi, "struct ResolvedFilePeer {", "bool DecodePeerPublicKey(");
    EXPECT_NE(resolved.find("ToxSessionGuard session;"), std::string::npos)
        << "ResolvedFilePeer must CARRY the pin, not a raw handle";
    EXPECT_EQ(resolved.find("Tox* tox = nullptr;"), std::string::npos)
        << "a raw Tox* member is exactly the copy that outlived the pin";

    // Each of the three senders must run tox_file_send() off the pinned handle
    // and must re-check currency before publishing success.
    struct Sender {
        const char* name;
        const char* start;
        const char* end;
    };
    const Sender senders[] = {
        {"send_file", "int tim2tox_ffi_send_file(", "int tim2tox_ffi_send_avatar("},
        {"send_avatar", "int tim2tox_ffi_send_avatar(", "int tim2tox_ffi_delete_avatar("},
        {"delete_avatar", "int tim2tox_ffi_delete_avatar(",
         "int tim2tox_ffi_iterate_current_instance("},
    };
    for (const Sender& sender : senders) {
        const std::string body = SourceSection(ffi, sender.start, sender.end);
        EXPECT_EQ(body.find("peer.tox,"), std::string::npos)
            << sender.name << " must not use a raw handle copied out of the guard";
        EXPECT_NE(body.find("peer.tox()"), std::string::npos)
            << sender.name << " must read the handle through the pin";
        EXPECT_NE(body.find("peer.session_ended()"), std::string::npos)
            << sender.name
            << " must refuse a send whose session ended: the pin keeps the memory "
               "valid, not the session current";
    }
}

// Finding 4. Two Dart-exposed entry points still used unpinned managers: one
// null-checked GetToxManager() and then dereferenced a SECOND lookup, the other
// retained the raw ToxManager* across the call.
TEST(ToxSessionPinTest, TheLastTwoFfiEntryPointsPinTheirManager) {
    const std::string ffi = StripLineComments(ReadSource(TIM2TOX_FFI_SOURCE_PATH));
    struct Entry {
        const char* name;
        const char* start;
        const char* end;
    };
    const Entry entries[] = {
        {"group_wire_ready", "int tim2tox_ffi_group_wire_ready(",
         "int tim2tox_ffi_send_group_action("},
        {"get_friend_connection_status", "int tim2tox_ffi_get_friend_connection_status(",
         "#ifdef BUILD_TOXAV"},
    };
    for (const Entry& entry : entries) {
        const std::string body = SourceSection(ffi, entry.start, entry.end);
        EXPECT_NE(body.find("AcquireToxSession()"), std::string::npos)
            << entry.name << " is reachable from Dart and must pin the session";
        EXPECT_EQ(body.find("GetToxManager()"), std::string::npos)
            << entry.name << " must not reach for the unpinned manager";
    }
}

// Finding 3. Pinning keeps the memory valid; it does not make the session
// current. A logout that stops the event thread mid-send leaves the fragments
// on an instance nothing will ever iterate, so OnSuccess would be a lie.
TEST(ToxSessionPinTest, C2CSendRejectsAnEndedSession) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string body = StripLineComments(SourceSection(
        manager, "V2TIMString V2TIMManagerImpl::SendC2CTextMessage(",
        "V2TIMString V2TIMManagerImpl::SendC2CCustomMessage("));
    EXPECT_NE(body.find("AcquireToxSession()"), std::string::npos);
    // Once before the send loop, once before the result is published.
    std::size_t checks = 0;
    for (std::size_t at = body.find("session.Expired()"); at != std::string::npos;
         at = body.find("session.Expired()", at + 1)) {
        ++checks;
    }
    EXPECT_GE(checks, 2u)
        << "the send must be refused both before it starts and before its "
           "success is published";
}

// Finding 5. HandleGroupSelfJoin dereferenced a raw manager, and CreateGroup
// invokes it MANUALLY from the FFI caller's thread after the inner guard ended
// — outside IterateReentryScope, so teardown does not defer there.
TEST(ToxSessionPinTest, ManualSelfJoinRunsOnAPinnedSession) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string body = StripLineComments(SourceSection(
        manager, "void V2TIMManagerImpl::HandleGroupSelfJoin(",
        "void V2TIMManagerImpl::HandleGroupJoinFail("));
    EXPECT_NE(body.find("AcquireToxSession()"), std::string::npos)
        << "the handler itself must pin, so every manual call site is covered";
    EXPECT_EQ(body.find("GetToxManager()->"), std::string::npos)
        << "no raw manager dereference may remain in the handler";

    const std::string group_manager =
        StripLineComments(ReadSource(TIM2TOX_GROUP_MANAGER_SOURCE_PATH));
    const std::string create = SourceSection(
        group_manager, "void V2TIMGroupManagerImpl::CreateGroup(",
        "void V2TIMGroupManagerImpl::GetGroupsInfo(");
    EXPECT_NE(create.find("AcquireToxSession()"), std::string::npos)
        << "the outer create must pin for its whole span";
    EXPECT_EQ(create.find("GetToxManagerFromImpl(manager_impl_)->"), std::string::npos)
        << "the create path must not re-fetch a raw manager per call";
    EXPECT_NE(create.find("session.Expired()"), std::string::npos)
        << "a create finished after a logout must not publish a self-join";
    // A create whose session ended is still a create: the group exists in Tox
    // and in the profile, so it is reported as done and only the session-scoped
    // publication is skipped. Answering OnError instead invited a retry that
    // created a second group (codex 2026-09-26).
    EXPECT_EQ(create.find("session ended during group creation"), std::string::npos)
        << "a committed create must not be reported as a failure";
}

// Finding 2. tox_get_savedata_size() and tox_get_savedata() take toxcore's
// (non-recursive) instance mutex separately, so a mutation landing between them
// makes toxcore write more bytes than the buffer we sized. The save therefore
// quiesces the mutators Tim2Tox owns: tox_iterate and every pin.
TEST(ToxSessionPinTest, SaveDataWaitsForAnInFlightOperation) {
    std::unique_ptr<ToxManager> manager = MakeLiveManager();
    if (!manager) GTEST_SKIP() << "tox_new unavailable on this host";

    // An operation on another thread that could still enlarge the savedata.
    std::shared_ptr<Tox> pin = manager->acquireTox();
    ASSERT_NE(pin, nullptr);

    std::atomic<bool> finished{false};
    std::thread saver([&] {
        const std::vector<uint8_t> data = manager->getSaveData();
        EXPECT_FALSE(data.empty());
        finished.store(true, std::memory_order_release);
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    EXPECT_FALSE(finished.load(std::memory_order_acquire))
        << "the save read the savedata while a mutator was still in flight";

    pin.reset();
    saver.join();
    EXPECT_TRUE(finished.load(std::memory_order_acquire));
}

// ... and it must NOT wait for a pin the saving thread holds itself: a profile
// save reached from a tox callback on the manually-iterating FFI thread would
// otherwise stall for the whole quiesce timeout and then skip the save.
TEST(ToxSessionPinTest, SaveDataDoesNotWaitForItsOwnPin) {
    std::unique_ptr<ToxManager> manager = MakeLiveManager();
    if (!manager) GTEST_SKIP() << "tox_new unavailable on this host";

    std::shared_ptr<Tox> pin = manager->acquireTox();
    ASSERT_NE(pin, nullptr);

    const auto started = std::chrono::steady_clock::now();
    const std::vector<uint8_t> data = manager->getSaveData();
    const auto elapsed = std::chrono::steady_clock::now() - started;

    EXPECT_FALSE(data.empty());
    EXPECT_LT(elapsed, std::chrono::seconds(2))
        << "a save on the pin's own thread waited for itself";
}

// The poll loop is the one hot caller of the pin-then-iterate order, and the
// thing that made the stall above happen on ordinary use: it must keep the
// ToxManager alive across the iterate WITHOUT still holding the Tox pin.
TEST(ToxSessionPinTest, PollLoopDoesNotHoldAPinAcrossTheIterate) {
    const std::string ffi = StripLineComments(ReadSource(TIM2TOX_FFI_SOURCE_PATH));
    const std::string loop =
        SourceSection(ffi, "int tim2tox_ffi_iterate_current_instance(",
                      "extern \"C\" uint64_t tim2tox_virtual_time_cb(");
    ASSERT_FALSE(loop.empty()) << "the poll loop moved; update this test";
    EXPECT_EQ(loop.find("session.manager()->iterate("), std::string::npos)
        << "iterating through the guard holds the pin across the iterate";
    EXPECT_NE(loop.find("manager_shared()"), std::string::npos)
        << "the loop must keep the manager, not the pin, across the iterate";
}

// The lock order the quiesce has to survive: a caller holds a pin and THEN
// waits for iterate_mutex_ (the FFI poll loop did exactly that every round).
// A saver that took iterate_mutex_ first would hold the lock that caller is
// waiting for while waiting for its pin — so every save overlapping the poll
// loop burned the full timeout and was skipped (codex 2026-09-26). Quiescing
// before taking the iterate lock holds nothing while waiting, so the pin
// holder always gets through.
TEST(ToxSessionPinTest, SaveDataDoesNotStallAgainstAPinnedIterateLock) {
    std::unique_ptr<ToxManager> manager = MakeLiveManager();
    if (!manager) GTEST_SKIP() << "tox_new unavailable on this host";

    std::atomic<bool> pinned{false};
    std::atomic<bool> got_iterate{false};
    std::thread worker([&] {
        std::shared_ptr<Tox> pin = manager->acquireTox();
        EXPECT_NE(pin, nullptr);
        pinned.store(true, std::memory_order_release);
        // Let the saver reach its quiesce, then do what the poll loop does:
        // take the iterate lock while still holding the pin.
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        {
            auto iterate_lock = manager->lockIterate();
            got_iterate.store(true, std::memory_order_release);
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        pin.reset();
    });
    while (!pinned.load(std::memory_order_acquire)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    const auto started = std::chrono::steady_clock::now();
    const std::vector<uint8_t> data = manager->getSaveData();
    const auto elapsed = std::chrono::steady_clock::now() - started;
    worker.join();

    EXPECT_TRUE(got_iterate.load(std::memory_order_acquire))
        << "the pinned caller never got the iterate lock";
    EXPECT_FALSE(data.empty())
        << "the save was skipped: it deadlocked against a pinned iterate until "
           "the quiesce timed out";
    EXPECT_LT(elapsed, ToxManager::kSaveQuiesceTimeout)
        << "the save waited out a timeout it should never have hit";
}

// The residual cycle the quiesce order cannot break: a save reached from a tox
// callback owns iterate_mutex_, so a pin holder waiting for that mutex can only
// let go once the callback returns. Such a save is DEFERRED to the end of the
// iterate rather than left to time out.
TEST(ToxSessionPinTest, SaveFromInsideAnIterateIsDeferredNotStalled) {
    const std::string manager = StripLineComments(ReadSource(TIM2TOX_TOX_MANAGER_SOURCE_PATH));
    const std::string save = SourceSection(manager, "bool ToxManager::saveTo(",
                                           "bool ToxManager::loadFrom(");
    ASSERT_FALSE(save.empty());
    const std::size_t owner_check = save.find("isIterateOwner()");
    const std::size_t defer = save.find("IterateReentryScope::Defer");
    const std::size_t quiesce = save.find("getSaveData(");
    ASSERT_NE(owner_check, std::string::npos)
        << "a save on the iterating thread must be recognised";
    ASSERT_NE(defer, std::string::npos)
        << "it must be deferred to the end of the iterate";
    ASSERT_NE(quiesce, std::string::npos);
    EXPECT_LT(defer, quiesce)
        << "the deferral has to happen BEFORE the quiesce it cannot win";
    // A strong reference for the deferred run: the deferred work happens after
    // iterate_mutex_ is released, so a weak liveness token alone can be locked
    // just as a teardown starts destroying the manager.
    EXPECT_NE(save.find("weak_from_this()"), std::string::npos)
        << "the deferred save must hold the manager alive while it runs";
    // ...and the caller must be able to tell a queued save from a written one.
    EXPECT_NE(save.find("*queued = true"), std::string::npos)
        << "a deferred save must not be reported as durable";
    // The teardown save gets the longer quiesce budget: it is the save an
    // in-flight operation (a group create racing logout) has to land in, and
    // there is no later save to retry.
    EXPECT_NE(save.find("kFinalSaveQuiesceAttempts"), std::string::npos)
        << "the final save must get more than the ordinary quiesce budget";
    const std::string uninit = StripLineComments(SourceSection(
        ReadSource(TIM2TOX_MANAGER_SOURCE_PATH), "void V2TIMManagerImpl::UnInitSDK(",
        "void V2TIMManagerImpl::SaveToxProfile("));
    EXPECT_NE(uninit.find("/*final_save=*/true"), std::string::npos)
        << "the logout save must ask for the final-save budget";
}

// Admission order: a pin must be COUNTED before its holder can read the Tox
// handle, or a save can quiesce against a count of zero while an operation is
// already under way with the handle in hand (codex 2026-09-26).
TEST(ToxSessionPinTest, AcquireCountsThePinBeforeItReadsTheHandle) {
    const std::string manager = StripLineComments(ReadSource(TIM2TOX_TOX_MANAGER_SOURCE_PATH));
    const std::string acquire = SourceSection(manager, "std::shared_ptr<Tox> ToxManager::acquireTox(",
                                              "ToxManager::SaveQuiesce::SaveQuiesce(");
    ASSERT_FALSE(acquire.empty());
    const std::size_t admit = acquire.find("++state->count");
    const std::size_t read_handle = acquire.find("tox = tox_;");
    ASSERT_NE(admit, std::string::npos);
    ASSERT_NE(read_handle, std::string::npos);
    EXPECT_LT(admit, read_handle)
        << "the handle must not be read before the pin is admitted";
    EXPECT_NE(acquire.find("AdmissionRelease"), std::string::npos)
        << "an admitted pin must be released on every failure path";
}

// Admission closes for good at teardown, BEFORE the final save, so no operation
// can be admitted between that save's snapshot and the shutdown and then do work
// nothing will ever persist (codex 2026-09-26).
TEST(ToxSessionPinTest, ClosedAdmissionRefusesNewPinsAndLogoutClosesItFirst) {
    std::unique_ptr<ToxManager> manager = MakeLiveManager();
    if (!manager) GTEST_SKIP() << "tox_new unavailable on this host";

    std::shared_ptr<Tox> before = manager->acquireTox();
    EXPECT_NE(before, nullptr);
    manager->closeAdmission();
    // The pin taken earlier stays valid — the final save is waiting for exactly
    // that work — and the thread holding it may still nest, so an operation
    // already under way is not broken half-way through.
    EXPECT_NE(before, nullptr);
    std::shared_ptr<Tox> nested = manager->acquireTox();
    EXPECT_NE(nested, nullptr) << "an admitted operation must still be able to nest";
    nested.reset();
    // Another thread, which holds nothing, is refused.
    std::atomic<bool> other_got_a_pin{true};
    std::thread other([&] {
        other_got_a_pin.store(manager->acquireTox() != nullptr, std::memory_order_release);
    });
    other.join();
    EXPECT_FALSE(other_got_a_pin.load(std::memory_order_acquire))
        << "a pin was handed out after admission closed";
    before.reset();
    std::atomic<bool> later_got_a_pin{true};
    std::thread later([&] {
        later_got_a_pin.store(manager->acquireTox() != nullptr, std::memory_order_release);
    });
    later.join();
    EXPECT_FALSE(later_got_a_pin.load(std::memory_order_acquire))
        << "closing is irreversible";
    // ...and the savedata is still readable, so the final save can run.
    EXPECT_FALSE(manager->getSaveData().empty());

    const std::string uninit = StripLineComments(SourceSection(
        ReadSource(TIM2TOX_MANAGER_SOURCE_PATH), "void V2TIMManagerImpl::UnInitSDK(",
        "void V2TIMManagerImpl::SaveToxProfile("));
    const std::size_t close_at = uninit.find("closeAdmission()");
    const std::size_t save_at = uninit.find("saveTo(save_path");
    ASSERT_NE(close_at, std::string::npos) << "logout must close admission";
    ASSERT_NE(save_at, std::string::npos);
    EXPECT_LT(close_at, save_at) << "admission must close BEFORE the final save";
}

// A pin taken while a save is quiescing must wait for it, which is what makes
// the size/copy pair atomic.
TEST(ToxSessionPinTest, SaveDataBlocksNewPinsWhileItReads) {
    std::unique_ptr<ToxManager> manager = MakeLiveManager();
    if (!manager) GTEST_SKIP() << "tox_new unavailable on this host";

    std::shared_ptr<Tox> blocker = manager->acquireTox();
    ASSERT_NE(blocker, nullptr);

    std::atomic<bool> save_running{false};
    std::thread saver([&] {
        save_running.store(true, std::memory_order_release);
        (void)manager->getSaveData();
    });
    while (!save_running.load(std::memory_order_acquire)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    std::atomic<bool> pinned{false};
    std::thread latecomer([&] {
        std::shared_ptr<Tox> late = manager->acquireTox();
        pinned.store(late != nullptr, std::memory_order_release);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    EXPECT_FALSE(pinned.load(std::memory_order_acquire))
        << "a new operation started while the save was quiescing";

    blocker.reset();
    saver.join();
    latecomer.join();
    EXPECT_TRUE(pinned.load(std::memory_order_acquire));
}

// The MM-6 caps must agree: the issuing side may never create more unexpired
// challenges for one (group, member) than HandleGroupIdentityProof scans, and a
// received proof must be metered by its authenticated sender BEFORE the scan.
TEST(ToxSessionPinTest, Mm6ProofWorkIsMeteredAndTheCandidateSetCannotOverflow) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);

    const std::string issue = StripLineComments(SourceSection(
        manager, "void V2TIMManagerImpl::IssueIdentityChallenges(",
        "void V2TIMManagerImpl::HandleGroupIdentityAnnouncement("));
    EXPECT_NE(issue.find("pending_for_member >= kMaxClaimantsPerDigest"), std::string::npos)
        << "without a per-(group, member) cap the verifier truncates the "
           "candidate set in hash order and can drop the honest asker";

    const std::string proof = StripLineComments(SourceSection(
        manager, "void V2TIMManagerImpl::HandleGroupIdentityProof(",
        "std::string V2TIMManagerImpl::FriendForGroupMemberKey("));
    const std::size_t meter = proof.find("TakeGroupSenderProofBudgetLocked");
    const std::size_t record = proof.find("last_proof_payload_hex");
    const std::size_t scan = proof.find("for (const auto& [nonce_hex, pending]");
    const std::size_t cheap_gate = proof.find("HasPendingChallengeForSenderLocked");
    ASSERT_NE(cheap_gate, std::string::npos)
        << "an unchallenged sender must be dropped before it can reserve one of "
           "the bounded per-sender metering windows";
    EXPECT_LT(cheap_gate, meter);
    ASSERT_NE(meter, std::string::npos)
        << "a received proof must be charged to its authenticated NGC sender";
    ASSERT_NE(record, std::string::npos);
    ASSERT_NE(scan, std::string::npos);
    // The payload hex is recorded BEFORE the meter, on purpose: the packet is
    // fixed-size (rejected at entry otherwise), so it is one bounded 200-byte
    // conversion, and the "is the payload really opaque to a member that was
    // merely named?" diagnostic can only answer that if it sees the proofs
    // NOBODY challenged for — which is exactly what the gates below drop.
    EXPECT_LT(record, meter)
        << "the payload diagnostic must see dropped proofs too";
    EXPECT_NE(proof.find("length != kIdentityProofPacketSize"), std::string::npos)
        << "recording before the meter is only bounded because the packet size "
           "is validated at entry";
    // What must stay behind a gate is the state and the crypto.
    EXPECT_LT(meter, scan)
        << "scanning the pending challenges is work an unchallenged member got "
           "for free";
    EXPECT_NE(proof.find("DropStaleChallengesForMemberLocked"), std::string::npos)
        << "askers that no longer claim the member only occupy scan slots";
    EXPECT_NE(proof.find("kMaxProofVerifiesGlobal"), std::string::npos)
        << "the global crypto cap stays";

    // A friend going offline must take its pending challenges with its claims;
    // leaving them behind is what let hostile claimants starve an honest one.
    const std::string offline = StripLineComments(SourceSection(
        manager, "void V2TIMManagerImpl::NoteFriendConnectionForIdentity(",
        "void V2TIMManagerImpl::PurgeFriendIdentityState("));
    EXPECT_NE(offline.find("pending_identity_challenges_.erase"), std::string::npos)
        << "an offline friend cannot answer a challenge; the entry must go";
}

}  // namespace
