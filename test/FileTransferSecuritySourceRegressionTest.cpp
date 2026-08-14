#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH must point to ffi/tim2tox_ffi.cpp"
#endif

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH must point to source/ToxManager.cpp"
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
     PeerFileControlLifecycleEventsUseExplicitInstanceRoutingAndNoPayloadLeaks) {
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string manager_source = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);

    const size_t callback_start =
        ffi_source.find("const auto previous_file_control_callback =");
    ASSERT_NE(callback_start, std::string::npos);
    const size_t callback_end = ffi_source.find(
        "tox_manager->setFileChunkRequestCallback(", callback_start);
    ASSERT_NE(callback_end, std::string::npos);
    const std::string callback =
        ffi_source.substr(callback_start, callback_end - callback_start);

    EXPECT_NE(callback.find("GetInstanceIdFromManager(manager_impl)"),
              std::string::npos);
    EXPECT_NE(callback.find("tox_friend_get_public_key(tox, friend_number"),
              std::string::npos);
    EXPECT_NE(callback.find("ToxUtil::tox_bytes_to_hex(pubkey, TOX_PUBLIC_KEY_SIZE)"),
              std::string::npos);
    EXPECT_NE(callback.find("enqueue_text_line_for_instance("),
              std::string::npos);
    EXPECT_NE(callback.find(
                  "std::string line = std::string(event_name) + \":\" + sender_hex + \":\" +"),
              std::string::npos);
    EXPECT_NE(callback.find("std::to_string(file_number)"), std::string::npos);
    EXPECT_NE(callback.find("file_canceled"), std::string::npos);
    EXPECT_NE(callback.find("file_paused"), std::string::npos);
    EXPECT_NE(callback.find("file_resumed"), std::string::npos);
    EXPECT_NE(callback.find("previous_file_control_callback"),
              std::string::npos);
    EXPECT_NE(callback.find("EraseSendContext(instance_id, key)"),
              std::string::npos);
    EXPECT_EQ(callback.find("ParseInstanceIdFromLine"), std::string::npos);
    EXPECT_EQ(callback.find("GetReceiverInstanceOverride"), std::string::npos);

    for (const char* leak : {
             "path",
             "filename",
             "payload",
             "exception",
             "file_id",
         }) {
        EXPECT_EQ(callback.find(leak), std::string::npos) << leak;
    }

    const size_t manager_start =
        manager_source.find("void ToxManager::onFileControl(Tox*");
    ASSERT_NE(manager_start, std::string::npos);
    const size_t manager_end = manager_source.find(
        "void ToxManager::onFileChunkRequest(", manager_start);
    ASSERT_NE(manager_end, std::string::npos);
    const std::string manager_control =
        manager_source.substr(manager_start, manager_end - manager_start);

    EXPECT_NE(manager_control.find("file_control_cb_("), std::string::npos);
    EXPECT_EQ(manager_control.find("V2TIM_LOG"), std::string::npos);
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
