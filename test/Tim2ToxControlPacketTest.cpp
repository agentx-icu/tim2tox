#include "Tim2ToxControlPacket.h"

#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

#include "toxcore/tox.h"

namespace {

using tim2tox::control::Decode;
using tim2tox::control::Encode;
using tim2tox::control::Type;

constexpr std::size_t kHeaderSize = 10;

std::vector<uint8_t> ValidReceiptFrame() {
    const std::string body =
        R"({"msgID":"m1","receiptType":"read","sender":"AABB","type":"receipt"})";
    const auto encoded = Encode(Type::kReceipt, body);
    EXPECT_TRUE(encoded.has_value());
    return encoded.value_or(std::vector<uint8_t>{});
}

TEST(Tim2ToxControlPacketTest, EncodesVersionedLosslessFrame) {
    const std::string body =
        R"({"msgID":"m1","receiptType":"read","sender":"AABB","type":"receipt"})";

    const auto encoded = Encode(Type::kReceipt, body);

    ASSERT_TRUE(encoded.has_value());
    ASSERT_EQ(encoded->size(), kHeaderSize + body.size());
    EXPECT_EQ((*encoded)[0], 0xA1);
    EXPECT_EQ(std::string(encoded->begin() + 1, encoded->begin() + 5), "T2TC");
    EXPECT_EQ((*encoded)[5], 1);
    EXPECT_EQ((*encoded)[6], static_cast<uint8_t>(Type::kReceipt));
    EXPECT_EQ((*encoded)[7], 0);
    EXPECT_EQ((*encoded)[8], static_cast<uint8_t>(body.size() >> 8));
    EXPECT_EQ((*encoded)[9], static_cast<uint8_t>(body.size()));
    EXPECT_TRUE(
        std::string(encoded->begin() + kHeaderSize, encoded->end()) == body);
}

TEST(Tim2ToxControlPacketTest, DecodesKnownTypeAndBody) {
    const auto decoded = Decode(ValidReceiptFrame());
    const std::string expected_body =
        R"({"msgID":"m1","receiptType":"read","sender":"AABB","type":"receipt"})";

    ASSERT_TRUE(decoded.has_value());
    EXPECT_EQ(decoded->type, Type::kReceipt);
    EXPECT_TRUE(decoded->body == expected_body);
}

TEST(Tim2ToxControlPacketTest, EncodesGenericCustomWithTim2ToxPacketId) {
    const std::string body("\x00\x7f\xff", 3);

    const auto encoded = Encode(Type::kGenericCustom, body);

    ASSERT_TRUE(encoded.has_value());
    ASSERT_EQ(encoded->size(), kHeaderSize + body.size());
    EXPECT_EQ((*encoded)[0], 0xA1);
    EXPECT_EQ((*encoded)[6], static_cast<uint8_t>(Type::kGenericCustom));

    const auto decoded = Decode(*encoded);
    ASSERT_TRUE(decoded.has_value());
    EXPECT_EQ(decoded->type, Type::kGenericCustom);
    EXPECT_EQ(decoded->body, body);
}

TEST(Tim2ToxControlPacketTest, RejectsMalformedMagicAndPacketId) {
    auto wrong_id = ValidReceiptFrame();
    wrong_id[0] = 0xA0;
    EXPECT_FALSE(Decode(wrong_id).has_value());

    auto wrong_magic = ValidReceiptFrame();
    wrong_magic[3] = 'X';
    EXPECT_FALSE(Decode(wrong_magic).has_value());
}

TEST(Tim2ToxControlPacketTest, RejectsEveryTruncatedHeader) {
    const auto frame = ValidReceiptFrame();
    for (std::size_t size = 0; size < kHeaderSize; ++size) {
        EXPECT_FALSE(Decode(std::span<const uint8_t>(frame.data(), size)).has_value())
            << "accepted truncated header length " << size;
    }
}

TEST(Tim2ToxControlPacketTest, RejectsUnknownVersionTypeAndFlags) {
    auto unknown_version = ValidReceiptFrame();
    unknown_version[5] = 2;
    EXPECT_FALSE(Decode(unknown_version).has_value());

    auto unknown_type = ValidReceiptFrame();
    unknown_type[6] = 0x7F;
    EXPECT_FALSE(Decode(unknown_type).has_value());

    auto unknown_flags = ValidReceiptFrame();
    unknown_flags[7] = 1;
    EXPECT_FALSE(Decode(unknown_flags).has_value());
}

TEST(Tim2ToxControlPacketTest, RejectsDeclaredLengthMismatchAndTrailingBytes) {
    auto truncated_body = ValidReceiptFrame();
    truncated_body.pop_back();
    EXPECT_FALSE(Decode(truncated_body).has_value());

    auto trailing_byte = ValidReceiptFrame();
    trailing_byte.push_back(0);
    EXPECT_FALSE(Decode(trailing_byte).has_value());

    auto false_length = ValidReceiptFrame();
    ++false_length[9];
    EXPECT_FALSE(Decode(false_length).has_value());
}

TEST(Tim2ToxControlPacketTest, EnforcesToxcorePacketLengthBound) {
    const std::size_t max_body_size = TOX_MAX_CUSTOM_PACKET_SIZE - kHeaderSize;
    const std::string prefix =
        R"({"action":"add","msgID":"m","reactionID":")";
    const std::string suffix = R"(","sender":"AABB","type":"reaction"})";
    ASSERT_LE(prefix.size() + suffix.size(), max_body_size);
    const std::string max_body =
        prefix + std::string(max_body_size - prefix.size() - suffix.size(), 'x') +
        suffix;
    const std::string oversized_body =
        prefix +
        std::string(max_body_size - prefix.size() - suffix.size() + 1, 'x') +
        suffix;

    const auto at_limit = Encode(Type::kReaction, max_body);
    ASSERT_TRUE(at_limit.has_value());
    EXPECT_EQ(at_limit->size(), TOX_MAX_CUSTOM_PACKET_SIZE);
    EXPECT_FALSE(Encode(Type::kReaction, oversized_body).has_value());
}

}
