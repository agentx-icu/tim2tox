#include "Tim2ToxGroupPacket.h"

#include <cstring>

namespace tim2tox::group_packet {

std::vector<uint8_t> Wrap(uint8_t kind, const uint8_t* data, size_t length) {
    std::vector<uint8_t> packet;
    packet.reserve(kHeaderSize + length);
    packet.insert(packet.end(), kMagic, kMagic + 4);
    packet.push_back(kVersion);
    packet.push_back(kind);
    if (length > 0 && data != nullptr) packet.insert(packet.end(), data, data + length);
    return packet;
}

bool Unwrap(uint8_t kind, const uint8_t* data, size_t length, const uint8_t** payload,
            size_t* payload_length) {
    if (PeekKind(data, length) != static_cast<int>(kind)) return false;
    *payload = data + kHeaderSize;
    *payload_length = length - kHeaderSize;
    return true;
}

int PeekKind(const uint8_t* data, size_t length) {
    if (data == nullptr || length < kHeaderSize || memcmp(data, kMagic, 4) != 0 ||
        data[4] != kVersion) {
        return -1;
    }
    return data[5];
}

}  // namespace tim2tox::group_packet
