#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_MANAGER_HEADER_PATH
#error "TIM2TOX_MANAGER_HEADER_PATH is required"
#endif
#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_FFI_HEADER_PATH
#error "TIM2TOX_FFI_HEADER_PATH is required"
#endif

namespace {

std::string ReadSource(const char* path) {
    std::ifstream input(path, std::ios::binary);
    EXPECT_TRUE(input.good()) << path;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

std::string SourceSection(
    const std::string& source,
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

TEST(QToxTransportSourceRegressionTest,
     TextSendsUsePreparedTypeFragmentsAndOneLogicalCallback) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string header = ReadSource(TIM2TOX_MANAGER_HEADER_PATH);
    const std::string c2c = SourceSection(
        manager,
        "V2TIMManagerImpl::SendC2CTextMessageWithType(",
        "V2TIMManagerImpl::SendC2CCustomMessage(");
    const std::string group = SourceSection(
        manager,
        "V2TIMManagerImpl::SendGroupTextMessageWithType(",
        "V2TIMManagerImpl::SendGroupPrivateTextMessage(");

    EXPECT_NE(header.find("SendC2CActionMessage("), std::string::npos);
    EXPECT_NE(header.find("SendGroupActionMessage("), std::string::npos);
    EXPECT_NE(c2c.find("PrepareTextMessage("), std::string::npos);
    EXPECT_NE(c2c.find("FragmentMessage(prepared->body)"), std::string::npos);
    EXPECT_NE(c2c.find("prepared->type"), std::string::npos);
    EXPECT_NE(c2c.find("tox_message_numbers.push_back"), std::string::npos);
    EXPECT_NE(c2c.find("TrackPendingDelivery(\n            friend_number, tox_message_numbers"),
              std::string::npos);
    EXPECT_EQ(c2c.find("TrackPendingDelivery(friend_number, tox_message_number"),
              std::string::npos);
    EXPECT_NE(group.find("PrepareTextMessage("), std::string::npos);
    EXPECT_NE(group.find("FragmentMessage(prepared->body)"), std::string::npos);
    EXPECT_NE(group.find("prepared->type"), std::string::npos);
}

TEST(QToxTransportSourceRegressionTest,
     ActionFfiApisUseExplicitNativeActionEntryPoints) {
    const std::string ffi = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string header = ReadSource(TIM2TOX_FFI_HEADER_PATH);

    EXPECT_NE(header.find("int tim2tox_ffi_send_c2c_action("),
              std::string::npos);
    EXPECT_NE(header.find("int tim2tox_ffi_send_group_action("),
              std::string::npos);
    EXPECT_NE(ffi.find("int tim2tox_ffi_send_c2c_action("),
              std::string::npos);
    EXPECT_NE(ffi.find("SendC2CActionMessage("), std::string::npos);
    EXPECT_NE(ffi.find("int tim2tox_ffi_send_group_action("),
              std::string::npos);
    EXPECT_NE(ffi.find("SendGroupActionMessage("), std::string::npos);
}

TEST(QToxTransportSourceRegressionTest,
     ActionReceiveUsesScopedSimpleTextRoutingOnly) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string ffi = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string friend_action = SourceSection(
        manager,
        "V2TIMManagerImpl::NotifyFriendActionMessage(",
        "V2TIMManagerImpl::NotifyGroupActionMessage(");
    const std::string group_action = SourceSection(
        manager,
        "V2TIMManagerImpl::NotifyGroupActionMessage(",
        "V2TIMManagerImpl::HandleFriendCustomMessage(");

    EXPECT_NE(manager.find("class ReceiverTextKindOverrideGuard"),
              std::string::npos);
    EXPECT_NE(manager.find("~ReceiverTextKindOverrideGuard() noexcept"),
              std::string::npos);
    EXPECT_NE(friend_action.find("OnRecvC2CTextMessage("), std::string::npos);
    EXPECT_NE(group_action.find("OnRecvGroupTextMessage("), std::string::npos);
    EXPECT_NE(friend_action.find("ReceiverTextKindOverrideGuard"),
              std::string::npos);
    EXPECT_NE(group_action.find("ReceiverTextKindOverrideGuard"),
              std::string::npos);
    EXPECT_EQ(friend_action.find("CreateCustomMessage"), std::string::npos);
    EXPECT_EQ(friend_action.find("NotifyAdvancedListenersReceivedMessage"),
              std::string::npos);
    EXPECT_EQ(group_action.find("CreateCustomMessage"), std::string::npos);
    EXPECT_EQ(group_action.find("NotifyAdvancedListenersReceivedMessage"),
              std::string::npos);
    EXPECT_NE(ffi.find("\"c2caction:\""), std::string::npos);
    EXPECT_NE(ffi.find("\"gaction:\""), std::string::npos);
    EXPECT_NE(ffi.find("static thread_local int g_receiver_text_kind_override = -1;"),
              std::string::npos);
}

TEST(QToxTransportSourceRegressionTest,
     FragmentReceiptsShareOneRootAndNotifyAtZero) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string header = ReadSource(TIM2TOX_MANAGER_HEADER_PATH);
    const std::string receipt = SourceSection(
        manager,
        "V2TIMManagerImpl::HandleFriendReadReceipt(",
        "V2TIMManagerImpl::ClearPendingDeliveries()");
    const std::string clear = SourceSection(
        manager,
        "V2TIMManagerImpl::ClearPendingDeliveries()",
        "V2TIMManagerImpl::HandleSelfConnectionStatus(");

    EXPECT_NE(header.find("struct PendingDeliveryRoot"), std::string::npos);
    EXPECT_NE(header.find("remaining_fragments"), std::string::npos);
    EXPECT_NE(header.find("pending_delivery_roots_"), std::string::npos);
    EXPECT_NE(header.find("pending_delivery_fragments_"), std::string::npos);
    EXPECT_NE(receipt.find("--root.remaining_fragments"), std::string::npos);
    EXPECT_NE(receipt.find("root.remaining_fragments == 0"),
              std::string::npos);
    EXPECT_NE(receipt.find("RemovePendingDeliveryRootLocked(root_id)"),
              std::string::npos);
    EXPECT_NE(receipt.find("NotifyMessageDeliveryReceipt(receipt)"),
              std::string::npos);
    EXPECT_NE(clear.find("pending_delivery_roots_.clear()"),
              std::string::npos);
    EXPECT_NE(clear.find("pending_delivery_fragments_.clear()"),
              std::string::npos);
}

}
