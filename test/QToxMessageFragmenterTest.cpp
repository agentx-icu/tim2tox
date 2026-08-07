#include <gtest/gtest.h>

#include <algorithm>
#include <string>
#include <string_view>
#include <vector>

#include "QToxMessageFragmenter.h"

namespace {

std::string Join(const std::vector<std::string>& fragments) {
    std::string joined;
    for (const auto& fragment : fragments) {
        joined += fragment;
    }
    return joined;
}

void ExpectValidFragments(
    const std::string& original,
    const std::vector<std::string>& fragments) {
    ASSERT_FALSE(fragments.empty());
    EXPECT_EQ(Join(fragments), original);
    for (const auto& fragment : fragments) {
        EXPECT_FALSE(fragment.empty());
        EXPECT_LE(fragment.size(), tim2tox::qtox::kMessagePayloadLimit);
    }
}

TEST(QToxMessageFragmenterTest, UsesQToxPayloadBudget) {
    EXPECT_EQ(tim2tox::qtox::kMessagePayloadLimit, 1322U);

    const std::string text(tim2tox::qtox::kMessagePayloadLimit, 'a');
    const auto fragments = tim2tox::qtox::FragmentMessage(text);

    ASSERT_TRUE(fragments.has_value());
    ASSERT_EQ(fragments->size(), 1U);
    EXPECT_EQ(fragments->front(), text);
}

TEST(QToxMessageFragmenterTest, PrefersLastNewlineAndKeepsIt) {
    const std::string text =
        std::string(1200, 'a') + "\n" + std::string(100, 'b') +
        " " + std::string(100, 'c');

    const auto fragments = tim2tox::qtox::FragmentMessage(text);

    ASSERT_TRUE(fragments.has_value());
    ExpectValidFragments(text, *fragments);
    ASSERT_EQ(fragments->size(), 2U);
    EXPECT_EQ(fragments->front().size(), 1201U);
    EXPECT_EQ(fragments->front().back(), '\n');
}

TEST(QToxMessageFragmenterTest, UsesLastAsciiSpaceOrTabWithoutLosingIt) {
    const std::string text =
        std::string(1290, 'a') + "\t" + std::string(10, 'b') +
        " " + std::string(100, 'c');

    const auto fragments = tim2tox::qtox::FragmentMessage(text);

    ASSERT_TRUE(fragments.has_value());
    ExpectValidFragments(text, *fragments);
    ASSERT_EQ(fragments->size(), 2U);
    EXPECT_EQ(fragments->front().size(), 1302U);
    EXPECT_EQ(fragments->front().back(), ' ');
}

TEST(QToxMessageFragmenterTest, FallsBackToAValidUtf8Boundary) {
    const std::string text =
        std::string(1321, 'a') + "\xE2\x82\xAC" + std::string(20, 'b');

    const auto fragments = tim2tox::qtox::FragmentMessage(text);

    ASSERT_TRUE(fragments.has_value());
    ExpectValidFragments(text, *fragments);
    ASSERT_EQ(fragments->size(), 2U);
    EXPECT_EQ(fragments->front().size(), 1321U);
    EXPECT_EQ(fragments->at(1).substr(0, 3), "\xE2\x82\xAC");
}

TEST(QToxMessageFragmenterTest, RejectsEmptyNulAndInvalidUtf8Input) {
    EXPECT_FALSE(tim2tox::qtox::FragmentMessage("").has_value());

    const std::string with_nul("abc\0def", 7);
    EXPECT_FALSE(tim2tox::qtox::FragmentMessage(with_nul).has_value());

    const std::string invalid_utf8("ok\xE2\x28\xA1", 5);
    EXPECT_FALSE(tim2tox::qtox::FragmentMessage(invalid_utf8).has_value());
}

TEST(QToxMessageFragmenterTest, ParsesCaseInsensitiveMeCommandOnlyWithSpace) {
    const auto action = tim2tox::qtox::PrepareTextMessage("/ME waves", false);
    ASSERT_TRUE(action.has_value());
    EXPECT_EQ(action->type, TOX_MESSAGE_TYPE_ACTION);
    EXPECT_EQ(action->body, "waves");

    const auto no_space = tim2tox::qtox::PrepareTextMessage("/me", false);
    ASSERT_TRUE(no_space.has_value());
    EXPECT_EQ(no_space->type, TOX_MESSAGE_TYPE_NORMAL);
    EXPECT_EQ(no_space->body, "/me");

    const auto tab = tim2tox::qtox::PrepareTextMessage("/me\twaves", false);
    ASSERT_TRUE(tab.has_value());
    EXPECT_EQ(tab->type, TOX_MESSAGE_TYPE_NORMAL);
    EXPECT_EQ(tab->body, "/me\twaves");
}

TEST(QToxMessageFragmenterTest, ExplicitActionAcceptsBodyAndStripsMePrefix) {
    const auto body = tim2tox::qtox::PrepareTextMessage("waves", true);
    ASSERT_TRUE(body.has_value());
    EXPECT_EQ(body->type, TOX_MESSAGE_TYPE_ACTION);
    EXPECT_EQ(body->body, "waves");

    const auto command = tim2tox::qtox::PrepareTextMessage("/me waves", true);
    ASSERT_TRUE(command.has_value());
    EXPECT_EQ(command->type, TOX_MESSAGE_TYPE_ACTION);
    EXPECT_EQ(command->body, "waves");

    EXPECT_FALSE(tim2tox::qtox::PrepareTextMessage("/me ", false).has_value());
    EXPECT_FALSE(tim2tox::qtox::PrepareTextMessage("", true).has_value());
}

}
