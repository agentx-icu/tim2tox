#include <fstream>
#include <iterator>
#include <string>

#include <gtest/gtest.h>

#ifndef DART_COMPAT_MESSAGE_SOURCE_PATH
#error "DART_COMPAT_MESSAGE_SOURCE_PATH must name dart_compat_message.cpp"
#endif

namespace {

std::string ReadDartCompatMessageSource() {
    std::ifstream input(DART_COMPAT_MESSAGE_SOURCE_PATH);
    return std::string(std::istreambuf_iterator<char>(input),
                       std::istreambuf_iterator<char>());
}

TEST(DartSendMessageSourceRegressionTest,
     UsesScopedCallbackAndThreadLocalReturnContract) {
    const std::string source = ReadDartCompatMessageSource();
    ASSERT_FALSE(source.empty());

    EXPECT_EQ(source.find("static std::string temp_msg_id"), std::string::npos);
    EXPECT_EQ(source.find("new DartSendCallback"), std::string::npos);
    EXPECT_EQ(source.find("delete this"), std::string::npos);
    EXPECT_EQ(source.find(".release()"), std::string::npos);

    EXPECT_NE(source.find("DartSendCallback callback("), std::string::npos);
    EXPECT_NE(source.find("&callback"), std::string::npos);
    EXPECT_NE(source.find("borrowed"), std::string::npos);
    EXPECT_NE(source.find("synchronous/non-retaining"), std::string::npos);
    EXPECT_NE(source.find("callback.terminal_attempt_count()"),
              std::string::npos);
    EXPECT_NE(source.find("terminal_attempt_count != 1"), std::string::npos);
    EXPECT_NE(source.find("terminal_attempt_count == 0"), std::string::npos);
    EXPECT_NE(source.find("SendMessage returned without a terminal callback"),
              std::string::npos);

    const size_t success_start = source.find("void OnSuccess(");
    const size_t error_start = source.find("void OnError(", success_start);
    const size_t progress_start = source.find("void OnProgress(", error_start);
    ASSERT_NE(success_start, std::string::npos);
    ASSERT_NE(error_start, std::string::npos);
    ASSERT_NE(progress_start, std::string::npos);
    EXPECT_NE(source.substr(success_start, error_start - success_start)
                  .find("terminal_gate_.TryComplete()"),
              std::string::npos);
    EXPECT_NE(source.substr(error_start, progress_start - error_start)
                  .find("terminal_gate_.TryComplete()"),
              std::string::npos);

    const std::string store_call = "return StoreDartSendMessageReturnId(";
    const size_t first_store = source.find(store_call);
    ASSERT_NE(first_store, std::string::npos);
    EXPECT_NE(source.find(store_call, first_store + store_call.size()),
              std::string::npos);
}

TEST(DartSendMessageSourceRegressionTest, ProgressIsNotTerminal) {
    const std::string source = ReadDartCompatMessageSource();
    ASSERT_FALSE(source.empty());

    const size_t progress_start = source.find("void OnProgress(");
    ASSERT_NE(progress_start, std::string::npos);
    const size_t progress_end = source.find("\n            }", progress_start);
    ASSERT_NE(progress_end, std::string::npos);

    const std::string progress_method =
        source.substr(progress_start, progress_end - progress_start);
    EXPECT_EQ(progress_method.find("TryComplete"), std::string::npos);
}

}
