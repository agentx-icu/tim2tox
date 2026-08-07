#include "Tim2ToxControlPacket.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <limits>

#include "toxcore/tox.h"

namespace tim2tox::control {
namespace {

constexpr std::array<uint8_t, 4> kMagic{'T', '2', 'T', 'C'};
constexpr uint8_t kVersion = 1;
constexpr uint8_t kFlags = 0;
constexpr std::size_t kHeaderSize = 10;

bool IsKnownType(Type type) {
    switch (type) {
        case Type::kReceipt:
        case Type::kReaction:
        case Type::kGenericCustom:
            return true;
    }
    return false;
}

}

std::optional<std::vector<uint8_t>> Encode(Type type, std::string_view body) {
    if (!IsKnownType(type) ||
        body.size() > std::numeric_limits<uint16_t>::max() ||
        body.size() > TOX_MAX_CUSTOM_PACKET_SIZE - kHeaderSize) {
        return std::nullopt;
    }

    const auto body_size = static_cast<uint16_t>(body.size());
    std::vector<uint8_t> frame(kHeaderSize + body.size());
    frame[0] = kPacketId;
    std::copy(kMagic.begin(), kMagic.end(), frame.begin() + 1);
    frame[5] = kVersion;
    frame[6] = static_cast<uint8_t>(type);
    frame[7] = kFlags;
    frame[8] = static_cast<uint8_t>(body_size >> 8);
    frame[9] = static_cast<uint8_t>(body_size & 0xFF);
    std::copy(body.begin(), body.end(), frame.begin() + kHeaderSize);
    return frame;
}

std::optional<Packet> Decode(std::span<const uint8_t> frame) {
    if (frame.size() < kHeaderSize || frame.size() > TOX_MAX_CUSTOM_PACKET_SIZE ||
        frame[0] != kPacketId ||
        !std::equal(kMagic.begin(), kMagic.end(), frame.begin() + 1) ||
        frame[5] != kVersion || frame[7] != kFlags) {
        return std::nullopt;
    }

    const auto type = static_cast<Type>(frame[6]);
    if (!IsKnownType(type)) {
        return std::nullopt;
    }

    const std::size_t body_size =
        (static_cast<std::size_t>(frame[8]) << 8) |
        static_cast<std::size_t>(frame[9]);
    if (frame.size() != kHeaderSize + body_size) {
        return std::nullopt;
    }

    return Packet{
        type,
        std::string(
            reinterpret_cast<const char*>(frame.data() + kHeaderSize),
            body_size),
    };
}

}
