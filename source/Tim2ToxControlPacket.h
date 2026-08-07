#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace tim2tox::control {

inline constexpr uint8_t kPacketId = 0xA1;

enum class Type : uint8_t {
    kReceipt = 1,
    kReaction = 2,
    kGenericCustom = 3,
};

struct Packet {
    Type type;
    std::string body;
};

std::optional<std::vector<uint8_t>> Encode(Type type, std::string_view body);
std::optional<Packet> Decode(std::span<const uint8_t> frame);

}
