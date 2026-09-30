// Savedata-encryption-at-the-persistence-boundary contract.
//
// The weakness this pins down: a password-protected profile used to be
// decrypted in place before the session started and re-encrypted only on a
// clean teardown, so `tox_profile.tox` sat on disk as plaintext for the whole
// session. An OS kill of a backgrounded app (the normal way a mobile app dies)
// skips teardown and strands the private key, friend list and nospam in the
// clear. The fix moves encryption into ToxManager::saveTo/loadFromEx so the
// file is ciphertext every time it touches the filesystem.
//
// The three properties that make this safe to ship are asserted here:
//   1. With no passphrase, the bytes on disk are byte-identical to before.
//   2. With a passphrase, the bytes on disk are toxcore's OWN encrypted-save
//      container -- the same one the host's Dart at-rest encryption already
//      writes -- so the on-disk format does not change and an older build can
//      still open a profile written by a newer one (rollback safety).
//   3. An encrypted profile that cannot be opened is reported distinctly from a
//      corrupt one, so a caller never renames a perfectly good account aside.

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "ToxManager.h"
#include "../third_party/c-toxcore/toxencryptsave/toxencryptsave.h"

// ToxManager.cpp's group-peer callbacks reference GetCurrentInstanceId(), which
// is defined in the FFI translation unit (ffi/tim2tox_ffi.cpp). This unit test
// deliberately links only the core library, and never drives a group callback,
// so a stub is enough to satisfy the linker without dragging in the FFI layer.
int64_t GetCurrentInstanceId() { return 0; }

namespace {

const char* const kPassphrase = "correct horse battery staple";
const char* const kWrongPassphrase = "Tr0ub4dor&3";

std::vector<uint8_t> ReadAll(const std::string& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return {};
    const auto size = f.tellg();
    if (size <= 0) return {};
    std::vector<uint8_t> data(static_cast<size_t>(size));
    f.seekg(0);
    f.read(reinterpret_cast<char*>(data.data()), size);
    return data;
}

void WriteAll(const std::string& path, const std::vector<uint8_t>& data) {
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    ASSERT_TRUE(static_cast<bool>(f));
    f.write(reinterpret_cast<const char*>(data.data()),
            static_cast<std::streamsize>(data.size()));
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

std::vector<uint8_t> AsBytes(const char* s) {
    const uint8_t* p = reinterpret_cast<const uint8_t*>(s);
    return std::vector<uint8_t>(p, p + std::char_traits<char>::length(s));
}

class ToxProfileEncryptionAtRest : public ::testing::Test {
protected:
    void SetUp() override {
        ForceTcpOnly();
        dir_ = std::filesystem::temp_directory_path() /
               ("tim2tox_f5_" + std::to_string(::testing::UnitTest::GetInstance()
                                                   ->random_seed()) +
                "_" + std::to_string(reinterpret_cast<uintptr_t>(this)));
        std::filesystem::create_directories(dir_);
        path_ = (dir_ / "tox_profile.tox").string();
    }

    void TearDown() override {
        std::error_code ec;
        std::filesystem::remove_all(dir_, ec);
    }

    // A ToxManager holding a fresh identity, ready to save.
    static void MakeIdentity(ToxManager& m) {
        ASSERT_NO_THROW(m.initialize(nullptr));
        ASSERT_NE(m.getTox(), nullptr);
    }

    std::filesystem::path dir_;
    std::string path_;
};

// (1) No passphrase => the file is raw toxcore savedata, exactly as before.
TEST_F(ToxProfileEncryptionAtRest, WithoutPassphraseTheFileStaysPlaintext) {
    ToxManager m;
    MakeIdentity(m);
    ASSERT_FALSE(m.hasProfilePassphrase());
    ASSERT_TRUE(m.saveTo(path_));

    const auto on_disk = ReadAll(path_);
    ASSERT_GE(on_disk.size(), static_cast<size_t>(TOX_PASS_ENCRYPTION_EXTRA_LENGTH));
    EXPECT_FALSE(tox_is_data_encrypted(on_disk.data()));
    EXPECT_EQ(on_disk, m.getSaveData());

    ToxManager reader;
    EXPECT_EQ(reader.loadFromEx(path_), ToxManager::LoadOutcome::kOk);
    EXPECT_EQ(reader.getAddress(), m.getAddress());
}

// (2) With a passphrase => ciphertext on disk, and the plaintext savedata is
// nowhere in the file. This is the property the weakness is about.
TEST_F(ToxProfileEncryptionAtRest, WithPassphraseTheFileIsNeverPlaintextAtRest) {
    ToxManager m;
    MakeIdentity(m);
    const auto passphrase = AsBytes(kPassphrase);
    m.setProfilePassphrase(passphrase.data(), passphrase.size());
    ASSERT_TRUE(m.hasProfilePassphrase());

    const auto plaintext = m.getSaveData();
    ASSERT_FALSE(plaintext.empty());
    ASSERT_TRUE(m.saveTo(path_));

    const auto on_disk = ReadAll(path_);
    ASSERT_GE(on_disk.size(), static_cast<size_t>(TOX_PASS_ENCRYPTION_EXTRA_LENGTH));
    EXPECT_TRUE(tox_is_data_encrypted(on_disk.data()));
    EXPECT_EQ(on_disk.size(), plaintext.size() + TOX_PASS_ENCRYPTION_EXTRA_LENGTH);

    // The raw savedata must not appear anywhere in the file.
    const auto* begin = on_disk.data();
    const auto* end = begin + on_disk.size();
    EXPECT_EQ(std::search(begin, end, plaintext.begin(), plaintext.end()), end);
}

// (2b) Round trip: same passphrase reopens the account with the same identity.
TEST_F(ToxProfileEncryptionAtRest, EncryptedProfileRoundTrips) {
    std::string address;
    {
        ToxManager m;
        MakeIdentity(m);
        const auto passphrase = AsBytes(kPassphrase);
        m.setProfilePassphrase(passphrase.data(), passphrase.size());
        ASSERT_TRUE(m.saveTo(path_));
        address = m.getAddress();
    }

    ToxManager reader;
    const auto passphrase = AsBytes(kPassphrase);
    reader.setProfilePassphrase(passphrase.data(), passphrase.size());
    EXPECT_EQ(reader.loadFromEx(path_), ToxManager::LoadOutcome::kOk);
    EXPECT_EQ(reader.getAddress(), address);
}

// (2c) ROLLBACK SAFETY. A profile written by the new code is an ordinary
// toxcore encrypted save: an older build (which decrypts with tox_pass_decrypt
// on the Dart side and then hands plaintext savedata to a passphrase-less
// native layer) still opens the account.
TEST_F(ToxProfileEncryptionAtRest, OlderBuildCanStillOpenWhatWeWrite) {
    std::string address;
    {
        ToxManager m;
        MakeIdentity(m);
        const auto passphrase = AsBytes(kPassphrase);
        m.setProfilePassphrase(passphrase.data(), passphrase.size());
        ASSERT_TRUE(m.saveTo(path_));
        address = m.getAddress();
    }

    // Exactly what the old Dart `decryptProfileFile` does, in place.
    const auto ciphertext = ReadAll(path_);
    ASSERT_GT(ciphertext.size(), static_cast<size_t>(TOX_PASS_ENCRYPTION_EXTRA_LENGTH));
    std::vector<uint8_t> plaintext(ciphertext.size() - TOX_PASS_ENCRYPTION_EXTRA_LENGTH);
    const auto passphrase = AsBytes(kPassphrase);
    Tox_Err_Decryption err = TOX_ERR_DECRYPTION_OK;
    ASSERT_TRUE(tox_pass_decrypt(ciphertext.data(), ciphertext.size(),
                                 passphrase.data(), passphrase.size(),
                                 plaintext.data(), &err));
    ASSERT_EQ(err, TOX_ERR_DECRYPTION_OK);
    WriteAll(path_, plaintext);

    ToxManager legacy;  // no passphrase: the pre-change code path
    EXPECT_EQ(legacy.loadFromEx(path_), ToxManager::LoadOutcome::kOk);
    EXPECT_EQ(legacy.getAddress(), address);
}

// (2d) FORWARD COMPATIBILITY. A profile encrypted by the host's existing Dart
// at-rest path (a bare tox_pass_encrypt over the savedata) is opened by the new
// native layer without any conversion step.
TEST_F(ToxProfileEncryptionAtRest, OpensAProfileEncryptedByTheHostsDartPath) {
    std::string address;
    std::vector<uint8_t> plaintext;
    {
        ToxManager m;
        MakeIdentity(m);
        ASSERT_TRUE(m.saveTo(path_));  // plaintext, as an older session left it
        plaintext = ReadAll(path_);
        address = m.getAddress();
    }

    std::vector<uint8_t> ciphertext(plaintext.size() + TOX_PASS_ENCRYPTION_EXTRA_LENGTH);
    const auto passphrase = AsBytes(kPassphrase);
    Tox_Err_Encryption err = TOX_ERR_ENCRYPTION_OK;
    ASSERT_TRUE(tox_pass_encrypt(plaintext.data(), plaintext.size(),
                                 passphrase.data(), passphrase.size(),
                                 ciphertext.data(), &err));
    ASSERT_EQ(err, TOX_ERR_ENCRYPTION_OK);
    WriteAll(path_, ciphertext);

    ToxManager reader;
    reader.setProfilePassphrase(passphrase.data(), passphrase.size());
    EXPECT_EQ(reader.loadFromEx(path_), ToxManager::LoadOutcome::kOk);
    EXPECT_EQ(reader.getAddress(), address);
}

// (3) An encrypted profile we cannot open is NOT a corrupt profile. Both
// failure modes must be distinguishable, and neither may touch the file --
// the caller uses this to decide whether renaming it aside is safe (it is not).
TEST_F(ToxProfileEncryptionAtRest, EncryptedWithoutPassphraseIsNotCorruption) {
    {
        ToxManager m;
        MakeIdentity(m);
        const auto passphrase = AsBytes(kPassphrase);
        m.setProfilePassphrase(passphrase.data(), passphrase.size());
        ASSERT_TRUE(m.saveTo(path_));
    }
    const auto before = ReadAll(path_);

    ToxManager reader;
    EXPECT_EQ(reader.loadFromEx(path_), ToxManager::LoadOutcome::kNeedsPassphrase);
    EXPECT_EQ(reader.getTox(), nullptr);
    EXPECT_EQ(ReadAll(path_), before);
}

TEST_F(ToxProfileEncryptionAtRest, WrongPassphraseIsNotCorruption) {
    {
        ToxManager m;
        MakeIdentity(m);
        const auto passphrase = AsBytes(kPassphrase);
        m.setProfilePassphrase(passphrase.data(), passphrase.size());
        ASSERT_TRUE(m.saveTo(path_));
    }
    const auto before = ReadAll(path_);

    ToxManager reader;
    const auto wrong = AsBytes(kWrongPassphrase);
    reader.setProfilePassphrase(wrong.data(), wrong.size());
    EXPECT_EQ(reader.loadFromEx(path_), ToxManager::LoadOutcome::kBadPassphrase);
    EXPECT_EQ(reader.getTox(), nullptr);
    EXPECT_EQ(ReadAll(path_), before);
}

// A genuinely corrupt (unencrypted, non-savedata) blob still reports kCorrupt,
// so the existing rename-aside recovery keeps working for the case it was
// written for.
TEST_F(ToxProfileEncryptionAtRest, GarbageIsStillReportedAsCorrupt) {
    WriteAll(path_, std::vector<uint8_t>(256, 0x5A));
    ToxManager reader;
    EXPECT_EQ(reader.loadFromEx(path_), ToxManager::LoadOutcome::kCorrupt);
}

// An encrypted profile whose DECRYPTED payload toxcore refuses is still not
// eligible for rename-aside recovery: the failure may be operational, and the
// user's bytes are the only copy of their identity. (codex finding 4)
TEST_F(ToxProfileEncryptionAtRest, EncryptedButUnloadablePayloadIsPreserved) {
    const auto passphrase = AsBytes(kPassphrase);
    std::vector<uint8_t> garbage(256, 0x5A);
    std::vector<uint8_t> ciphertext(garbage.size() + TOX_PASS_ENCRYPTION_EXTRA_LENGTH);
    Tox_Err_Encryption err = TOX_ERR_ENCRYPTION_OK;
    ASSERT_TRUE(tox_pass_encrypt(garbage.data(), garbage.size(),
                                 passphrase.data(), passphrase.size(),
                                 ciphertext.data(), &err));
    ASSERT_EQ(err, TOX_ERR_ENCRYPTION_OK);
    WriteAll(path_, ciphertext);

    ToxManager reader;
    reader.setProfilePassphrase(passphrase.data(), passphrase.size());
    const auto outcome = reader.loadFromEx(path_);
    EXPECT_EQ(outcome, ToxManager::LoadOutcome::kEncryptedLoadFailed);
    EXPECT_TRUE(ToxManager::LoadOutcomeMustPreserveFile(outcome));
    EXPECT_EQ(ReadAll(path_), ciphertext);
}

// The preserve-the-file predicate must cover every encrypted failure and none
// of the others -- InitSDK's rename decision hangs off exactly this.
TEST_F(ToxProfileEncryptionAtRest, PreservePredicateCoversEveryEncryptedFailure) {
    EXPECT_FALSE(ToxManager::LoadOutcomeMustPreserveFile(ToxManager::LoadOutcome::kOk));
    EXPECT_FALSE(ToxManager::LoadOutcomeMustPreserveFile(ToxManager::LoadOutcome::kUnreadable));
    EXPECT_FALSE(ToxManager::LoadOutcomeMustPreserveFile(ToxManager::LoadOutcome::kCorrupt));
    EXPECT_TRUE(ToxManager::LoadOutcomeMustPreserveFile(ToxManager::LoadOutcome::kNeedsPassphrase));
    EXPECT_TRUE(ToxManager::LoadOutcomeMustPreserveFile(ToxManager::LoadOutcome::kBadPassphrase));
    EXPECT_TRUE(ToxManager::LoadOutcomeMustPreserveFile(ToxManager::LoadOutcome::kEncryptedLoadFailed));
}

// A re-key followed by a save must leave the file readable with the NEW
// passphrase and unreadable with the old one. (codex finding 3's happy path)
TEST_F(ToxProfileEncryptionAtRest, ReKeyThenSaveSwitchesThePassphrase) {
    std::string address;
    const auto first = AsBytes(kPassphrase);
    const auto second = AsBytes(kWrongPassphrase);
    {
        ToxManager m;
        MakeIdentity(m);
        m.setProfilePassphrase(first.data(), first.size());
        ASSERT_TRUE(m.saveTo(path_));
        m.setProfilePassphrase(second.data(), second.size());
        ASSERT_TRUE(m.saveTo(path_));
        address = m.getAddress();
    }

    ToxManager stale;
    stale.setProfilePassphrase(first.data(), first.size());
    EXPECT_EQ(stale.loadFromEx(path_), ToxManager::LoadOutcome::kBadPassphrase);

    ToxManager fresh;
    fresh.setProfilePassphrase(second.data(), second.size());
    EXPECT_EQ(fresh.loadFromEx(path_), ToxManager::LoadOutcome::kOk);
    EXPECT_EQ(fresh.getAddress(), address);
}

TEST_F(ToxProfileEncryptionAtRest, MissingFileIsUnreadable) {
    ToxManager reader;
    EXPECT_EQ(reader.loadFromEx((dir_ / "nope.tox").string()),
              ToxManager::LoadOutcome::kUnreadable);
}

// Clearing the passphrase restores the legacy plaintext behaviour, which is
// what an account whose password is removed mid-session must end up with.
TEST_F(ToxProfileEncryptionAtRest, ClearingThePassphraseRestoresPlaintextSaves) {
    ToxManager m;
    MakeIdentity(m);
    const auto passphrase = AsBytes(kPassphrase);
    m.setProfilePassphrase(passphrase.data(), passphrase.size());
    ASSERT_TRUE(m.saveTo(path_));
    ASSERT_TRUE(tox_is_data_encrypted(ReadAll(path_).data()));

    m.setProfilePassphrase(nullptr, 0);
    EXPECT_FALSE(m.hasProfilePassphrase());
    ASSERT_TRUE(m.saveTo(path_));
    EXPECT_FALSE(tox_is_data_encrypted(ReadAll(path_).data()));
}

// rekeyAndSave is the one-step re-key: on success the file is readable with
// the NEW passphrase only, and the manager keeps that passphrase for later
// autosaves.
TEST_F(ToxProfileEncryptionAtRest, RekeyAndSaveSwitchesThePassphraseInOneStep) {
    std::string address;
    const auto first = AsBytes(kPassphrase);
    const auto second = AsBytes(kWrongPassphrase);
    {
        ToxManager m;
        MakeIdentity(m);
        m.setProfilePassphrase(first.data(), first.size());
        ASSERT_TRUE(m.saveTo(path_));
        ASSERT_TRUE(m.rekeyAndSave(path_, second.data(), second.size()));
        EXPECT_TRUE(m.hasProfilePassphrase());
        address = m.getAddress();
        // A later autosave keeps writing under the new key.
        ASSERT_TRUE(m.saveTo(path_));
    }

    ToxManager stale;
    stale.setProfilePassphrase(first.data(), first.size());
    EXPECT_EQ(stale.loadFromEx(path_), ToxManager::LoadOutcome::kBadPassphrase);

    ToxManager fresh;
    fresh.setProfilePassphrase(second.data(), second.size());
    EXPECT_EQ(fresh.loadFromEx(path_), ToxManager::LoadOutcome::kOk);
    EXPECT_EQ(fresh.getAddress(), address);
}

// The failure half of the contract (codex finding P1): when the re-keyed
// profile cannot reach disk, the previous passphrase stays in force -- a
// later autosave must NOT silently write the new key that the host's
// verifier never recorded -- and the file on disk is untouched.
TEST_F(ToxProfileEncryptionAtRest, RekeyThatCannotReachDiskKeepsThePreviousPassphrase) {
    const auto first = AsBytes(kPassphrase);
    const auto second = AsBytes(kWrongPassphrase);
    ToxManager m;
    MakeIdentity(m);
    m.setProfilePassphrase(first.data(), first.size());
    ASSERT_TRUE(m.saveTo(path_));
    const auto before = ReadAll(path_);
    ASSERT_FALSE(before.empty());

    // A destination whose directory does not exist cannot be written.
    const std::string unwritable = (dir_ / "missing" / "tox_profile.tox").string();
    EXPECT_FALSE(m.rekeyAndSave(unwritable, second.data(), second.size()));
    EXPECT_FALSE(std::filesystem::exists(unwritable));
    EXPECT_EQ(ReadAll(path_), before);
    EXPECT_TRUE(m.hasProfilePassphrase());

    // The next ordinary save still uses the FIRST passphrase.
    ASSERT_TRUE(m.saveTo(path_));
    ToxManager with_first;
    with_first.setProfilePassphrase(first.data(), first.size());
    EXPECT_EQ(with_first.loadFromEx(path_), ToxManager::LoadOutcome::kOk);
    ToxManager with_second;
    with_second.setProfilePassphrase(second.data(), second.size());
    EXPECT_EQ(with_second.loadFromEx(path_), ToxManager::LoadOutcome::kBadPassphrase);
}

// Re-keying to "no passphrase" through the same call ends in a plaintext file,
// which is the password-removal flow.
TEST_F(ToxProfileEncryptionAtRest, RekeyAndSaveToNoPassphraseWritesPlaintext) {
    ToxManager m;
    MakeIdentity(m);
    const auto passphrase = AsBytes(kPassphrase);
    m.setProfilePassphrase(passphrase.data(), passphrase.size());
    ASSERT_TRUE(m.saveTo(path_));
    ASSERT_TRUE(tox_is_data_encrypted(ReadAll(path_).data()));

    ASSERT_TRUE(m.rekeyAndSave(path_, nullptr, 0));
    EXPECT_FALSE(m.hasProfilePassphrase());
    EXPECT_FALSE(tox_is_data_encrypted(ReadAll(path_).data()));
}

// lastLoadWasEncrypted() is what lets InitSDK tell "opened a plaintext profile
// with a passphrase staged -- upgrade it now" from "opened ciphertext -- the
// file is already right". It reflects the most recent load only.
TEST_F(ToxProfileEncryptionAtRest, LastLoadWasEncryptedReflectsTheMostRecentLoad) {
    const auto passphrase = AsBytes(kPassphrase);
    const std::string plain_path = (dir_ / "plain.tox").string();
    {
        ToxManager m;
        MakeIdentity(m);
        ASSERT_TRUE(m.saveTo(plain_path));
        m.setProfilePassphrase(passphrase.data(), passphrase.size());
        ASSERT_TRUE(m.saveTo(path_));
    }

    // A plaintext file opened with a passphrase staged: the InitSDK
    // "upgrade it now" case.
    ToxManager plain_reader;
    EXPECT_FALSE(plain_reader.lastLoadWasEncrypted());
    plain_reader.setProfilePassphrase(passphrase.data(), passphrase.size());
    ASSERT_EQ(plain_reader.loadFromEx(plain_path), ToxManager::LoadOutcome::kOk);
    EXPECT_FALSE(plain_reader.lastLoadWasEncrypted());

    ToxManager cipher_reader;
    cipher_reader.setProfilePassphrase(passphrase.data(), passphrase.size());
    ASSERT_EQ(cipher_reader.loadFromEx(path_), ToxManager::LoadOutcome::kOk);
    EXPECT_TRUE(cipher_reader.lastLoadWasEncrypted());

    // The flag is reset at the start of every load, so a later load that does
    // not succeed (a manager already holding a Tox instance refuses a second
    // one) does not leave a stale "true" behind.
    EXPECT_NE(cipher_reader.loadFromEx(plain_path), ToxManager::LoadOutcome::kOk);
    EXPECT_FALSE(cipher_reader.lastLoadWasEncrypted());
}

}  // namespace
