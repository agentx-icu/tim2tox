#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

// Framing of every NGC custom packet tim2tox sends. NGC custom packets are an
// open channel other clients use for their own protocols (file sync, history
// sync, ...); without a signature every foreign packet became a "[Custom
// Message]" bubble, a history row and a notification.
//
//   0xB7 'T' '2' 'T' <version=1> <kind> <payload...>
//
// Shared by V2TIMManagerImpl (chat kinds 1-3) and RendezvousGroups (kind 4).
namespace tim2tox::group_packet {

inline constexpr uint8_t kMagic[4] = {0xB7, 'T', '2', 'T'};
inline constexpr uint8_t kVersion = 1;
inline constexpr size_t kHeaderSize = 6;

enum Kind : uint8_t {
    kCustomMessage = 1,  // broadcast: V2TIM custom elem payload
    kReceipt = 2,        // private: receipt JSON for the author
    kIdentityProof = 3,  // private: MM-6 identity proof
    kRendezvous = 4,     // broadcast or private: opaque rendezvous payload
};

// Header + payload.
std::vector<uint8_t> Wrap(uint8_t kind, const uint8_t* data, size_t length);

// Returns the payload of a tim2tox group packet of the given kind, or false
// for anything else (foreign packets are ignored, never rendered).
bool Unwrap(uint8_t kind, const uint8_t* data, size_t length, const uint8_t** payload,
            size_t* payload_length);

// The kind of a well-formed tim2tox packet, or -1 for a foreign packet.
int PeekKind(const uint8_t* data, size_t length);

}  // namespace tim2tox::group_packet
