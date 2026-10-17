// RendezvousGroups — the pure half: convention, derivation, hex, line
// builders. No state besides the convention, no Tox call.
#include "RendezvousGroups.h"

#include <cstring>

#include "toxcore/crypto_core.h"

namespace tim2tox {

namespace {
constexpr char kGeohashAlphabet[] = "0123456789bcdefghjkmnpqrstuvwxyz";
constexpr size_t kMaxLabelLength = 12;
}  // namespace

void RendezvousGroups::SetConvention(Convention convention) {
    std::lock_guard<std::mutex> lock(mutex_);
    convention_ = std::move(convention);
}

RendezvousGroups::Convention RendezvousGroups::GetConvention() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return convention_;
}

bool RendezvousGroups::IsValidLabel(const std::string& label) {
    if (label.empty() || label.size() > kMaxLabelLength) return false;
    for (const char c : label) {
        if (c == '\0' || std::strchr(kGeohashAlphabet, c) == nullptr) return false;
    }
    return true;
}

bool RendezvousGroups::IsValidNick(const std::string& nick) {
    if (nick.size() != kNickLength) return false;
    for (const char c : nick) {
        const bool digit = c >= '0' && c <= '9';
        const bool lower_hex = c >= 'a' && c <= 'f';
        if (!digit && !lower_hex) return false;
    }
    return true;
}

bool RendezvousGroups::ParseLabel(const Convention& convention, const std::string& name, std::string* label) {
    const std::string& prefix = convention.name_prefix;
    if (prefix.empty() || name.size() <= prefix.size() || name.compare(0, prefix.size(), prefix) != 0) {
        return false;
    }
    const std::string candidate = name.substr(prefix.size());
    if (!IsValidLabel(candidate)) return false;
    if (label != nullptr) *label = candidate;
    return true;
}

std::array<uint8_t, RendezvousGroups::kSeedSize> RendezvousGroups::DeriveSeed(const Convention& convention,
                                                                             const std::string& label) {
    const std::string material = convention.seed_prefix + label;
    std::array<uint8_t, kSeedSize> seed{};
    static_assert(kSeedSize == CRYPTO_SHA256_SIZE, "seed is one SHA-256 digest");
    crypto_sha256(seed.data(), reinterpret_cast<const uint8_t*>(material.data()), material.size());
    return seed;
}

bool RendezvousGroups::DeriveChatId(const std::array<uint8_t, kSeedSize>& seed,
                                    std::array<uint8_t, kChatIdSize>* chat_id) {
    Extended_Public_Key pk;
    Extended_Secret_Key sk;
    static_assert(kSeedSize == CRYPTO_SIGN_SEED_SIZE, "seed size must match toxcore");
    static_assert(kChatIdSize == CRYPTO_SIGN_PUBLIC_KEY_SIZE, "chat id is the ed25519 public key");
    const bool ok = create_extended_keypair_from_seed(&pk, &sk, seed.data());
    crypto_memzero(&sk, sizeof(sk));
    if (!ok) return false;
    std::memcpy(chat_id->data(), pk.sig, kChatIdSize);
    return true;
}

bool RendezvousGroups::IsRendezvousGroup(const std::string& name, const uint8_t* chat_id) const {
    if (chat_id == nullptr) return false;
    const Convention convention = GetConvention();
    std::string label;
    if (!ParseLabel(convention, name, &label)) return false;
    std::array<uint8_t, kChatIdSize> derived{};
    if (!DeriveChatId(DeriveSeed(convention, label), &derived)) return false;
    return std::memcmp(derived.data(), chat_id, kChatIdSize) == 0;
}

std::string RendezvousGroups::Hex(const uint8_t* bytes, size_t length) {
    static const char kDigits[] = "0123456789abcdef";
    std::string out;
    out.reserve(length * 2);
    for (size_t i = 0; i < length; ++i) {
        out.push_back(kDigits[bytes[i] >> 4]);
        out.push_back(kDigits[bytes[i] & 0x0F]);
    }
    return out;
}

bool RendezvousGroups::Unhex(const std::string& hex, uint8_t* out, size_t length) {
    if (hex.size() != length * 2) return false;
    auto nibble = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < length; ++i) {
        const int hi = nibble(hex[2 * i]);
        const int lo = nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}

std::string RendezvousGroups::JoinedLine(const std::string& chat_id_hex, bool founded) {
    return "rendezvous_joined:" + chat_id_hex + ":" + (founded ? "1" : "0");
}

std::string RendezvousGroups::LeftLine(const std::string& chat_id_hex, const std::string& reason) {
    return "rendezvous_left:" + chat_id_hex + ":" + reason;
}

std::string RendezvousGroups::PeerLine(const std::string& chat_id_hex, const std::string& peer_pk_hex, bool joined) {
    return "rendezvous_peer:" + chat_id_hex + ":" + peer_pk_hex + ":" + (joined ? "join" : "exit");
}

std::string RendezvousGroups::PeersChangedLine(const std::string& chat_id_hex, size_t count) {
    return "rendezvous_peers_changed:" + chat_id_hex + ":" + std::to_string(count);
}

std::string RendezvousGroups::FullLine(const std::string& chat_id_hex) {
    return "rendezvous_full:" + chat_id_hex;
}

std::string RendezvousGroups::PacketLine(const std::string& chat_id_hex, const std::string& peer_pk_hex,
                                         bool is_private, const uint8_t* payload, size_t length) {
    std::string line = "rendezvous_packet:" + chat_id_hex + ":" + peer_pk_hex + ":" + (is_private ? "p" : "b") + ":";
    line += Hex(payload, length);
    return line;
}

}  // namespace tim2tox
