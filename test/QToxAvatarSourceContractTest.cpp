#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_FFI_HEADER_PATH
#error "TIM2TOX_FFI_HEADER_PATH is required"
#endif
#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH is required"
#endif

namespace {

std::string ReadSource(const char* path) {
    std::ifstream input(path, std::ios::binary);
    EXPECT_TRUE(input.good()) << path;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

std::string SourceSection(const std::string& source,
                          const char* start_marker,
                          const char* end_marker) {
    const std::size_t start = source.find(start_marker);
    EXPECT_NE(start, std::string::npos) << start_marker;
    if (start == std::string::npos) return {};
    const std::size_t end = source.find(end_marker, start + 1);
    EXPECT_NE(end, std::string::npos) << end_marker;
    if (end == std::string::npos) return {};
    return source.substr(start, end - start);
}

TEST(QToxAvatarSourceContractTest, ExposesExactExplicitAvatarCAbi) {
    const std::string header = ReadSource(TIM2TOX_FFI_HEADER_PATH);
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    constexpr const char* kSendSignature =
        "int tim2tox_ffi_send_avatar(int64_t instance_id, const char* user_id, const uint8_t* avatar_data, size_t avatar_size)";
    constexpr const char* kDeleteSignature =
        "int tim2tox_ffi_delete_avatar(int64_t instance_id, const char* user_id)";

    EXPECT_NE(header.find(kSendSignature), std::string::npos);
    EXPECT_NE(header.find(kDeleteSignature), std::string::npos);
    EXPECT_NE(source.find(kSendSignature), std::string::npos);
    EXPECT_NE(source.find(kDeleteSignature), std::string::npos);
}

TEST(QToxAvatarSourceContractTest, SendsOwnedQToxCompatibleAvatarBytes) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string avatar = SourceSection(
        source, "int tim2tox_ffi_send_avatar(",
        "int tim2tox_ffi_delete_avatar(");

    EXPECT_NE(avatar.find("avatar_size > kAvatarMaxBytes"), std::string::npos);
    EXPECT_NE(avatar.find("std::vector<uint8_t>(avatar_data"),
              std::string::npos);
    EXPECT_NE(avatar.find("tox_hash("), std::string::npos);
    EXPECT_NE(avatar.find("LowerHex("), std::string::npos);
    EXPECT_NE(avatar.find("TOX_FILE_KIND_AVATAR"), std::string::npos);
    EXPECT_NE(avatar.find("file_id.data()"), std::string::npos);
}

TEST(QToxAvatarSourceContractTest, UsesMinusEightOnlyForOversizeAvatar) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string avatar = SourceSection(
        source, "int tim2tox_ffi_send_avatar(",
        "int tim2tox_ffi_delete_avatar(");
    const std::size_t oversize =
        avatar.find("if (avatar_size > kAvatarMaxBytes)");
    const std::size_t oversize_return = avatar.find("return -8;", oversize);
    const std::size_t invalid =
        avatar.find("if (avatar_data == nullptr || avatar_size == 0)");
    const std::size_t invalid_return = avatar.find("return -1;", invalid);

    ASSERT_NE(oversize, std::string::npos);
    ASSERT_NE(oversize_return, std::string::npos);
    ASSERT_NE(invalid, std::string::npos);
    ASSERT_NE(invalid_return, std::string::npos);
    EXPECT_LT(oversize, oversize_return);
    EXPECT_LT(invalid, invalid_return);
    EXPECT_EQ(avatar.find("return -8;", oversize_return + 1),
              std::string::npos);
}

TEST(QToxAvatarSourceContractTest, SendsAvatarDeletionAsEmptyKindOneTransfer) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string deletion = SourceSection(
        source, "int tim2tox_ffi_delete_avatar(",
        "int tim2tox_ffi_iterate_current_instance(");

    EXPECT_NE(deletion.find("TOX_FILE_KIND_AVATAR"), std::string::npos);
    EXPECT_NE(deletion.find("0, nullptr, nullptr, 0"), std::string::npos);
}

TEST(QToxAvatarSourceContractTest, GenericFilesAreAlwaysData) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string generic = SourceSection(
        source, "int tim2tox_ffi_send_file(",
        "int tim2tox_ffi_send_avatar(");

    EXPECT_NE(generic.find("TOX_FILE_KIND_DATA"), std::string::npos);
    EXPECT_EQ(generic.find("TOX_FILE_KIND_AVATAR"), std::string::npos);
    EXPECT_EQ(generic.find("avatar_name_pattern"), std::string::npos);
    EXPECT_EQ(generic.find("from_avatar_dir"), std::string::npos);
}

TEST(QToxAvatarSourceContractTest, SendContextsOwnFileOrMemoryAndCleanUp) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);

    EXPECT_NE(source.find("struct SendContext"), std::string::npos);
    EXPECT_NE(source.find("std::unique_ptr<FILE, FileCloser>"),
              std::string::npos);
    EXPECT_NE(source.find("std::vector<uint8_t> memory"), std::string::npos);
    EXPECT_NE(source.find("position > size || length > size - position"),
              std::string::npos);
    EXPECT_NE(source.find("setFileControlCallback"), std::string::npos);
    EXPECT_NE(source.find("previous_file_control_callback"),
              std::string::npos);
    EXPECT_NE(source.find("TOX_FILE_CONTROL_CANCEL"), std::string::npos);
    EXPECT_NE(source.find("EraseSendContext(instance_id, key)"),
              std::string::npos);
    EXPECT_NE(source.find("insert_or_assign"), std::string::npos);
}

TEST(QToxAvatarSourceContractTest, InboundAvatarCarriesFileIdAndUses10MiBCap) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);

    EXPECT_NE(source.find("kAvatarMaxBytes = 10ULL * 1024ULL * 1024ULL"),
              std::string::npos);
    EXPECT_NE(source.find("tox_file_get_file_id("), std::string::npos);
    EXPECT_NE(source.find("\"avatar_request:\" + std::to_string(instance_id)"),
              std::string::npos);
    EXPECT_NE(source.find("LowerHex(file_id.data(), file_id.size())"),
              std::string::npos);
}

TEST(QToxAvatarSourceContractTest,
     InboundAvatarDeletionDoesNotRetainReceiveContext) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string receive = SourceSection(
        source, "setFileRecvCallback", "setFileRecvChunkCallback");

    EXPECT_NE(receive.find("const bool is_avatar_deletion ="),
              std::string::npos);
    EXPECT_NE(receive.find("if (!is_avatar_deletion)"), std::string::npos);
}

TEST(QToxAvatarSourceContractTest,
     AvatarReachableFileLogsExcludeTransferIdentifiers) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string callbacks = SourceSection(
        source, "static void RegisterToxManagerFileCallbacks(",
        "// Test instance management functions");
    const std::string control = SourceSection(
        source, "int tim2tox_ffi_file_control(",
        "int tim2tox_ffi_set_file_recv_dir(");

    for (const char* leak : {
             "friend={}",
             "file={}",
             "instance={}",
             "path_length={}",
             "key={}",
         }) {
        EXPECT_EQ(callbacks.find(leak), std::string::npos) << leak;
        EXPECT_EQ(control.find(leak), std::string::npos) << leak;
    }
}

TEST(QToxAvatarSourceContractTest,
     ToxManagerFileReceiveLogContainsOnlySafeMetadata) {
    const std::string source = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string receive = SourceSection(
        source, "void ToxManager::onFileRecv(",
        "void ToxManager::onFileControl(");
    const std::size_t log_start = receive.find("V2TIM_LOG(");
    const std::size_t log_end = receive.find("ToxManager* manager =", log_start);

    ASSERT_NE(log_start, std::string::npos);
    ASSERT_NE(log_end, std::string::npos);
    const std::string log = receive.substr(log_start, log_end - log_start);
    EXPECT_NE(log.find("kind={}"), std::string::npos);
    EXPECT_NE(log.find("size={}"), std::string::npos);
    EXPECT_NE(log.find("has_cb={}"), std::string::npos);

    for (const char* leak : {
             "tox={}",
             "friend={}",
             "file={}",
             "manager={}",
             "(void*)",
             "reinterpret_cast",
             "static_cast<void*",
             "%p",
             "{:p}",
             "filename",
             "payload",
             "content",
         }) {
        EXPECT_EQ(log.find(leak), std::string::npos) << leak;
    }
}

TEST(QToxAvatarSourceContractTest,
     ReceiveContextsAreClosedAndRemovedDuringInstanceTeardown) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string helper = SourceSection(
        source, "static void EraseRecvContextsForInstance(",
        "// R-08: Per-instance inited state");
    const std::string destroy = SourceSection(
        source, "int tim2tox_ffi_destroy_test_instance(",
        "// Helper function to get current instance");
    const std::string uninit = SourceSection(
        source, "void tim2tox_ffi_uninit(",
        "void tim2tox_ffi_save_tox_profile(");

    EXPECT_NE(helper.find("std::lock_guard<std::mutex> lock(G.send_mtx)"),
              std::string::npos);
    EXPECT_NE(helper.find("G.recv_files.find(instance_id)"),
              std::string::npos);
    EXPECT_NE(helper.find("if (instance_it == G.recv_files.end()) return;"),
              std::string::npos);
    EXPECT_NE(helper.find("fclose(it->second.fp)"), std::string::npos);
    EXPECT_NE(helper.find("tim2tox::file_io::RemoveUtf8(it->second.path)"),
              std::string::npos);
    EXPECT_NE(helper.find("G.recv_files.erase(instance_id)"),
              std::string::npos);
    EXPECT_NE(helper.find("type=context status=teardown count={}"),
              std::string::npos);

    for (const std::string& teardown : {destroy, uninit}) {
        const std::size_t uninit_call = teardown.find("UnInitSDK()");
        const std::size_t recv_cleanup =
            teardown.find("EraseRecvContextsForInstance(");
        const std::size_t send_cleanup =
            teardown.find("EraseSendContextsForInstance(");
        ASSERT_NE(uninit_call, std::string::npos);
        ASSERT_NE(recv_cleanup, std::string::npos);
        ASSERT_NE(send_cleanup, std::string::npos);
        EXPECT_LT(uninit_call, recv_cleanup);
        EXPECT_LT(recv_cleanup, send_cleanup);
    }
}

}
