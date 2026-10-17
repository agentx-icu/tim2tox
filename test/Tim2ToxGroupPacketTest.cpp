// Framing of tim2tox NGC custom packets (Tim2ToxGroupPacket.{h,cpp}): the
// header is a wire constant shared by the chat kinds and the rendezvous kind.

#include "Tim2ToxGroupPacket.h"

#include <gtest/gtest.h>

#include <cstring>
#include <vector>

namespace {

using namespace tim2tox::group_packet;

TEST(Tim2ToxGroupPacketTest, WrapProducesMagicVersionKindPayload) {
    const uint8_t payload[] = {1, 2, 3};
    const std::vector<uint8_t> frame = Wrap(kRendezvous, payload, sizeof(payload));
    ASSERT_EQ(frame.size(), kHeaderSize + sizeof(payload));
    EXPECT_EQ(frame[0], 0xB7);
    EXPECT_EQ(frame[1], 'T');
    EXPECT_EQ(frame[2], '2');
    EXPECT_EQ(frame[3], 'T');
    EXPECT_EQ(frame[4], kVersion);
    EXPECT_EQ(frame[5], kRendezvous);
    EXPECT_EQ(0, memcmp(frame.data() + kHeaderSize, payload, sizeof(payload)));
}

TEST(Tim2ToxGroupPacketTest, WrapWithEmptyPayloadIsHeaderOnly) {
    const std::vector<uint8_t> frame = Wrap(kReceipt, nullptr, 0);
    EXPECT_EQ(frame.size(), kHeaderSize);
    EXPECT_EQ(PeekKind(frame.data(), frame.size()), kReceipt);
}

TEST(Tim2ToxGroupPacketTest, UnwrapMatchesOnlyTheRequestedKind) {
    const uint8_t payload[] = {9, 8};
    const std::vector<uint8_t> frame = Wrap(kRendezvous, payload, sizeof(payload));
    const uint8_t* out = nullptr;
    size_t out_len = 0;
    EXPECT_FALSE(Unwrap(kCustomMessage, frame.data(), frame.size(), &out, &out_len));
    EXPECT_FALSE(Unwrap(kReceipt, frame.data(), frame.size(), &out, &out_len));
    EXPECT_FALSE(Unwrap(kIdentityProof, frame.data(), frame.size(), &out, &out_len));
    ASSERT_TRUE(Unwrap(kRendezvous, frame.data(), frame.size(), &out, &out_len));
    ASSERT_EQ(out_len, sizeof(payload));
    EXPECT_EQ(0, memcmp(out, payload, sizeof(payload)));
}

TEST(Tim2ToxGroupPacketTest, ForeignOrShortPacketsAreNotOurs) {
    const uint8_t foreign[] = {0x01, 'T', '2', 'T', kVersion, kRendezvous, 0};
    EXPECT_EQ(PeekKind(foreign, sizeof(foreign)), -1);
    const uint8_t wrong_version[] = {0xB7, 'T', '2', 'T', static_cast<uint8_t>(kVersion + 1), kRendezvous};
    EXPECT_EQ(PeekKind(wrong_version, sizeof(wrong_version)), -1);
    const uint8_t too_short[] = {0xB7, 'T', '2', 'T', kVersion};
    EXPECT_EQ(PeekKind(too_short, sizeof(too_short)), -1);
    EXPECT_EQ(PeekKind(nullptr, 0), -1);
}

TEST(Tim2ToxGroupPacketTest, KindValuesAreWireConstants) {
    EXPECT_EQ(kCustomMessage, 1);
    EXPECT_EQ(kReceipt, 2);
    EXPECT_EQ(kIdentityProof, 3);
    EXPECT_EQ(kRendezvous, 4);
    EXPECT_EQ(kHeaderSize, 6u);
    EXPECT_EQ(kVersion, 1);
}

}  // namespace
