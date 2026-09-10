#pragma once

#include <cstdint>

// Tox custom-packet IDs used by tim2tox on the wire.
//
// Every lossless custom packet sent with tox_friend_send_lossless_packet()
// starts with a one-byte packet ID that the receiving client dispatches on,
// so two clients using the same ID mis-parse each other's traffic. toxcore
// only requires the ID to be within [160, 191] (PACKET_ID_RANGE_LOSSLESS_
// CUSTOM_START/END); which IDs are actually free is tracked by the community
// registry, which is not linked from any official toxcore documentation:
//
//   https://github.com/zoff99/toxcore_custom_packets_registry
//
// tim2tox originally took 160 and 161 -- the first two IDs of the legal
// range, and precisely the ones already claimed by ToxPhone and toxic
// (agentx-icu/toxee#98). Both were moved to 183/184 on 2026-09-10 and the
// pair was submitted to the registry above under tim2tox / toxee.
//
// These are WIRE-PROTOCOL constants: changing either one breaks call
// signalling / receipts between builds on different values. Check the
// registry before touching them, and update it afterwards.
namespace tim2tox::packet_ids {

inline constexpr uint8_t kLosslessCustomRangeStart = 160;
inline constexpr uint8_t kLosslessCustomRangeEnd = 191;

// Call signalling (V2TIMSignalingManagerImpl): invite / accept / reject / ...
inline constexpr uint8_t kSignaling = 183;  // 0xB7

// tim2tox control frames (Tim2ToxControlPacket): receipts, reactions,
// generic custom messages.
inline constexpr uint8_t kControl = 184;  // 0xB8

static_assert(kSignaling >= kLosslessCustomRangeStart &&
                  kSignaling <= kLosslessCustomRangeEnd,
              "signaling packet ID must be in the lossless custom range");
static_assert(kControl >= kLosslessCustomRangeStart &&
                  kControl <= kLosslessCustomRangeEnd,
              "control packet ID must be in the lossless custom range");
static_assert(kSignaling != kControl,
              "signaling and control packets must be distinguishable");

}  // namespace tim2tox::packet_ids
