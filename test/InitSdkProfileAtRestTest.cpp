// InitSDK-level contract for savedata at rest, driven through the FFI entry
// points the Dart host actually calls (tim2tox_ffi_set_profile_passphrase ->
// tim2tox_ffi_init_with_path -> ... -> tim2tox_ffi_uninit).
//
// ToxProfileEncryptionAtRestTest.cpp pins the ToxManager primitives; this file
// pins what InitSDK does with them:
//   1. A plaintext profile opened with a passphrase staged is re-written as
//      ciphertext DURING init -- not at the first autosave -- so an OS kill
//      right after login never finds plaintext on disk.
//   2. If that re-write cannot reach disk, init FAILS and the file is left
//      exactly as it was: a session never runs on a plaintext profile it
//      promised to encrypt, and the (valid) profile is not lost.
//   3. A live re-key is bound to the session epoch the host captured after
//      its own init; any other epoch is refused.
//
// The tests bring up the real default instance (network bootstrap included),
// so they run serially on the default instance and tear it down in TearDown.

#include <gtest/gtest.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "tim2tox_ffi.h"

namespace {

// toxcore's encrypted-save container magic (toxencryptsave.h TOX_ENC_SAVE_MAGIC_NUMBER).
const char kEncryptedMagic[] = "toxEsave";

std::vector<uint8_t> ReadAll(const std::filesystem::path& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return {};
    const auto size = f.tellg();
    if (size <= 0) return {};
    std::vector<uint8_t> data(static_cast<size_t>(size));
    f.seekg(0);
    f.read(reinterpret_cast<char*>(data.data()), size);
    return data;
}

// The tests create real Tox instances. TCP-only mode keeps them off UDP
// sockets, which a sandboxed CI runner may refuse to bind; persistence does
// not depend on the transport.
void ForceTcpOnly() {
#ifdef _WIN32
    _putenv_s("TOX_FORCE_TCP_ONLY", "1");
#else
    setenv("TOX_FORCE_TCP_ONLY", "1", 1);
#endif
}

bool IsEncrypted(const std::vector<uint8_t>& data) {
    return data.size() >= 8 && std::memcmp(data.data(), kEncryptedMagic, 8) == 0;
}

class InitSdkProfileAtRest : public ::testing::Test {
protected:
    void SetUp() override {
        ForceTcpOnly();
        dir_ = std::filesystem::temp_directory_path() /
               ("tim2tox_initsdk_" +
                std::to_string(::testing::UnitTest::GetInstance()->random_seed()) + "_" +
                std::to_string(reinterpret_cast<uintptr_t>(this)));
        std::filesystem::create_directories(dir_);
        // The default instance's profile lives at this name (PathUtils::BuildProfilePath).
        profile_ = dir_ / "tox_profile.tox";
    }

    void TearDown() override {
        tim2tox_ffi_uninit();
        std::error_code ec;
        std::filesystem::remove_all(dir_, ec);
    }

    // Stage `passphrase` (nullptr => plaintext) and init on dir_, exactly as
    // the host does. Returns the FFI result (1 ok / 0 failed).
    int Init(const char* passphrase) {
        const size_t len = passphrase ? std::strlen(passphrase) : 0;
        EXPECT_EQ(tim2tox_ffi_set_profile_passphrase(
                      reinterpret_cast<const uint8_t*>(passphrase), len),
                  1);
        return tim2tox_ffi_init_with_path(dir_.string().c_str());
    }

    int Rekey(const char* passphrase, int64_t epoch) {
        const size_t len = passphrase ? std::strlen(passphrase) : 0;
        return tim2tox_ffi_rekey_live_profile_passphrase(
            reinterpret_cast<const uint8_t*>(passphrase), len, epoch);
    }

    // A fresh identity saved in plaintext: what every pre-encryption install
    // (or one an OS kill left decrypted) has on disk.
    void MakePlaintextProfile() {
        ASSERT_EQ(Init(nullptr), 1);
        tim2tox_ffi_uninit();
        ASSERT_TRUE(std::filesystem::exists(profile_));
        ASSERT_FALSE(IsEncrypted(ReadAll(profile_)));
    }

    std::filesystem::path dir_;
    std::filesystem::path profile_;
};

TEST_F(InitSdkProfileAtRest, PlaintextProfileIsReWrittenEncryptedDuringInit) {
    MakePlaintextProfile();

    ASSERT_EQ(Init("correct horse battery staple"), 1);
    // Asserted BEFORE uninit: the whole point is what a kill right now finds.
    EXPECT_TRUE(IsEncrypted(ReadAll(profile_)));
    tim2tox_ffi_uninit();
    EXPECT_TRUE(IsEncrypted(ReadAll(profile_)));

    // Encrypted now: opening it without the passphrase fails and preserves it;
    // with the passphrase it opens.
    const auto encrypted = ReadAll(profile_);
    EXPECT_EQ(Init(nullptr), 0);
    EXPECT_EQ(ReadAll(profile_), encrypted);
    EXPECT_EQ(Init("correct horse battery staple"), 1);
}

TEST_F(InitSdkProfileAtRest, InitFailsWhenTheEncryptedReWriteCannotReachDisk) {
    MakePlaintextProfile();
    const auto plaintext = ReadAll(profile_);

    // Fault injection aimed at the profile write only: saveTo creates
    // "<profile>.tmp" with O_CREAT|O_TRUNC and renames it over the profile. A
    // DIRECTORY at that name makes the open fail (EISDIR) and nothing else in
    // init is affected.
    const std::filesystem::path blocker = profile_.string() + ".tmp";
    std::filesystem::create_directory(blocker);

    EXPECT_EQ(Init("correct horse battery staple"), 0);
    EXPECT_EQ(ReadAll(profile_), plaintext) << "a failed init must leave the profile untouched";
    EXPECT_EQ(tim2tox_ffi_is_instance_initialized(0), 0);

    // The profile is intact and the failure was transient: once the write can
    // succeed the same init works and encrypts.
    std::filesystem::remove(blocker);
    EXPECT_EQ(Init("correct horse battery staple"), 1);
    EXPECT_TRUE(IsEncrypted(ReadAll(profile_)));
}

TEST_F(InitSdkProfileAtRest, LiveReKeyIsBoundToTheSessionEpoch) {
    ASSERT_EQ(Init("one"), 1);
    const int64_t epoch = tim2tox_ffi_get_session_epoch(0);
    ASSERT_GT(epoch, 0);

    // Another session's epoch: refused, nothing changes.
    EXPECT_EQ(Rekey("two", epoch + 1), 0);
    EXPECT_EQ(Rekey("two", 0), 0);
    // This session's epoch: re-keyed and on disk.
    EXPECT_EQ(Rekey("two", epoch), 1);
    EXPECT_TRUE(IsEncrypted(ReadAll(profile_)));
    tim2tox_ffi_uninit();

    EXPECT_EQ(Init("one"), 0) << "the old passphrase must no longer open the profile";
    EXPECT_EQ(Init("two"), 1);
}

}  // namespace
