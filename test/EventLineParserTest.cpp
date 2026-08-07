#include "../ffi/event_line_parser.h"

#include <gtest/gtest.h>

#include <cstdint>

TEST(EventLineParserTest, ParsesAllRoutedEventPrefixes) {
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "progress_recv:1:user:10:10:path"),
              1);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_done:42:user:0:path"),
              42);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_request:9223372036854775807:user:1:2:0:name"),
              INT64_MAX);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "avatar_request:73:user:1:2:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
              73);
}

TEST(EventLineParserTest, ParsesIdAfterTheCompletePrefixDelimiter) {
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "progress_recv:73:user:1:2:path"),
              73);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_done:84:user:0:path"),
              84);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_request:95:user:1:2:0:name"),
              95);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "avatar_request:106:user:1:2:file-id"),
              106);
}

TEST(EventLineParserTest, RejectsMalformedAndBroadcastIds) {
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "progress_send:1:user:1:2"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine("file_done::x"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_request:-1:x"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "progress_recv:+1:x"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_done:9223372036854775808:x"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_request:12x:x"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine("file_done:42"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_request:0:x"),
              0);
}

TEST(EventLineParserTest,
     RejectsPeerFileControlLifecycleLinesFromTheGenericRouteParser) {
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_canceled:42:peer:7"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_paused:42:peer:7"),
              0);
    EXPECT_EQ(tim2tox::event_line::ParseInstanceIdFromLine(
                  "file_resumed:42:peer:7"),
              0);
}
