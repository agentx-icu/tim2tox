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

}  // namespace
