#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH must point to ffi/tim2tox_ffi.cpp"
#endif

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH must point to source/V2TIMManagerImpl.cpp"
#endif

namespace {

std::string ReadSource(const char* path) {
    std::ifstream input(path, std::ios::binary);
    EXPECT_TRUE(input.good()) << path;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

TEST(FileTransferSecuritySourceRegressionTest,
     RejectsInvalidReceiveRangeBeforeWriting) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const size_t callback = source.find("setFileRecvChunkCallback");
    const size_t expected_size = source.find("uint64_t expected_size", callback);
    const size_t range_check =
        source.find("file_io::CheckedWriteRange(", expected_size);
    const size_t write = source.find("file_io::WriteAt64(", range_check);

    ASSERT_NE(callback, std::string::npos);
    ASSERT_NE(expected_size, std::string::npos);
    ASSERT_NE(range_check, std::string::npos);
    ASSERT_NE(write, std::string::npos);
    EXPECT_LT(callback, expected_size);
    EXPECT_LT(expected_size, range_check);
    EXPECT_LT(range_check, write);
}

TEST(FileTransferSecuritySourceRegressionTest,
     DeletesIncompleteReceiveBeforeReturningWithoutCompletionEvents) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const size_t incomplete = source.find("if (io_failed ||");
    const size_t remove = source.find("file_io::RemoveUtf8(full)", incomplete);
    const size_t return_position = source.find("return;", incomplete);
    const size_t final_progress = source.find("/* Send final progress_recv", incomplete);

    ASSERT_NE(incomplete, std::string::npos);
    ASSERT_NE(remove, std::string::npos);
    ASSERT_NE(return_position, std::string::npos);
    ASSERT_NE(final_progress, std::string::npos);
    EXPECT_LT(incomplete, remove);
    EXPECT_LT(remove, return_position);
    EXPECT_LT(return_position, final_progress);
}

TEST(FileTransferSecuritySourceRegressionTest,
     ProductionDiagnosticsExcludeKnownBodiesIdentifiersAndPaths) {
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string manager_source = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);

    for (const char* leak : {
             "Sending file_done event: {}",
             "incomplete file {}, expected exact size",
             "failed to open local receive file {}",
             "successfully opened file {}",
             "set_file_recv_dir: set to {}",
             "send_file: file missing or empty {}",
             "send_file: fopen failed for {}",
         }) {
        EXPECT_EQ(ffi_source.find(leak), std::string::npos) << leak;
    }
    for (const char* leak : {
             "Text message content: %s",
             "Message text: %s",
             "sender_pubkey=%.64s",
             "Received C2C msg type {} from {}",
             "sender=%s, friend_number=",
             "Sender public key hex: {}",
             "Sender UserID: %s, GroupID: %s",
             "pubkey=%s",
         }) {
        EXPECT_EQ(manager_source.find(leak), std::string::npos) << leak;
    }
}

}
