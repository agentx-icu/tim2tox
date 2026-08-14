#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH must point to source/V2TIMManagerImpl.cpp"
#endif
#ifndef TIM2TOX_MANAGER_HEADER_PATH
#error "TIM2TOX_MANAGER_HEADER_PATH must point to source/V2TIMManagerImpl.h"
#endif
#ifndef TIM2TOX_MESSAGE_MANAGER_SOURCE_PATH
#error "TIM2TOX_MESSAGE_MANAGER_SOURCE_PATH must point to source/V2TIMMessageManagerImpl.cpp"
#endif
#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH must point to ffi/tim2tox_ffi.cpp"
#endif
#ifndef TIM2TOX_FFI_HEADER_PATH
#error "TIM2TOX_FFI_HEADER_PATH must point to ffi/tim2tox_ffi.h"
#endif
#ifndef TIM2TOX_DART_FFI_PATH
#error "TIM2TOX_DART_FFI_PATH must point to dart/lib/ffi/tim2tox_ffi.dart"
#endif
#ifndef TIM2TOX_ROOT_CMAKE_PATH
#error "TIM2TOX_ROOT_CMAKE_PATH must point to CMakeLists.txt"
#endif
#ifndef TIM2TOX_SOURCE_CMAKE_PATH
#error "TIM2TOX_SOURCE_CMAKE_PATH must point to source/CMakeLists.txt"
#endif
#ifndef TIM2TOX_FFI_CMAKE_PATH
#error "TIM2TOX_FFI_CMAKE_PATH must point to ffi/CMakeLists.txt"
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
    const size_t start = source.find(start_marker);
    EXPECT_NE(start, std::string::npos) << start_marker;
    if (start == std::string::npos) return {};
    const size_t end = source.find(end_marker, start + 1);
    EXPECT_NE(end, std::string::npos) << end_marker;
    if (end == std::string::npos) return {};
    return source.substr(start, end - start);
}

TEST(ControlPathSourceRegressionTest,
     GenericCustomUsesExplicitWireTypeWithoutJsonInference) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string generic_send = SourceSection(
        manager,
        "V2TIMManagerImpl::SendC2CCustomMessage(",
        "V2TIMManagerImpl::SendC2CControlMessage(");

    EXPECT_EQ(manager.find("<nlohmann/json.hpp>"), std::string::npos);
    EXPECT_EQ(manager.find("InferControlType"), std::string::npos);
    EXPECT_NE(generic_send.find("Type::kGenericCustom"), std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     TypedCBoundaryStrictlyAcceptsReceiptAndReaction) {
    const std::string manager_source = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string manager_header = ReadSource(TIM2TOX_MANAGER_HEADER_PATH);
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string ffi_header = ReadSource(TIM2TOX_FFI_HEADER_PATH);
    const std::string dart_ffi = ReadSource(TIM2TOX_DART_FFI_PATH);
    const std::string typed_send = SourceSection(
        ffi_source,
        "int tim2tox_ffi_send_c2c_control(",
        "int tim2tox_ffi_poll_text(");
    const std::string core_send = SourceSection(
        manager_source,
        "V2TIMManagerImpl::SendC2CCustomMessageWithType(",
        "// Send group text message");

    EXPECT_NE(manager_header.find("SendC2CControlMessage("), std::string::npos);
    EXPECT_NE(
        ffi_header.find(
            "int tim2tox_ffi_send_c2c_control(const char* user_id, "
            "const unsigned char* data, int data_len, int control_type);"),
        std::string::npos);
    EXPECT_NE(typed_send.find("control_type != 1 && control_type != 2"),
              std::string::npos);
    EXPECT_NE(typed_send.find("SendC2CControlMessage("), std::string::npos);
    EXPECT_NE(
        core_send.find(
            "controlType == static_cast<uint8_t>(Type::kGenericCustom)"),
        std::string::npos);
    EXPECT_NE(dart_ffi.find("typedef _send_c2c_control_c"), std::string::npos);
    EXPECT_NE(dart_ffi.find("sendC2CControlNative"), std::string::npos);
    EXPECT_NE(dart_ffi.find("'tim2tox_ffi_send_c2c_control'"),
              std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     TypedReceiveBypassesAdvancedMessageConstruction) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string manager_header = ReadSource(TIM2TOX_MANAGER_HEADER_PATH);
    const std::string callback = SourceSection(
        manager,
        "if (data[0] == tim2tox::control::kPacketId)",
        "if (data[0] == 0xA0)");
    const std::string typed_receive = SourceSection(
        manager,
        "V2TIMManagerImpl::HandleFriendControlMessage(",
        "V2TIMManagerImpl::DeliverFriendMessage(");

    EXPECT_NE(callback.find("packet->type == Type::kGenericCustom"),
              std::string::npos);
    EXPECT_NE(
        callback.find(
            "friend_number, packet->type, body, packet->body.size()"),
        std::string::npos);
    EXPECT_NE(
        manager_header.find(
            "HandleFriendControlMessage(uint32_t friend_number, "
            "tim2tox::control::Type packet_type, const uint8_t* data, "
            "size_t length)"),
        std::string::npos);
    EXPECT_EQ(typed_receive.find("CreateCustomMessage"), std::string::npos);
    EXPECT_EQ(typed_receive.find("V2TIMCustomElem"), std::string::npos);
    EXPECT_EQ(typed_receive.find("NotifyAdvancedListenersReceivedMessage"),
              std::string::npos);
    EXPECT_NE(typed_receive.find("OnRecvC2CCustomMessage("), std::string::npos);
    EXPECT_NE(typed_receive.find("ReceiverCustomRouteOverrideGuard"),
              std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     CustomReceiveRoutesPreserveAdvancedAndSimpleDeliveryOwnership) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string generic_receive = SourceSection(
        manager,
        "V2TIMManagerImpl::HandleFriendCustomMessage(",
        "V2TIMManagerImpl::HandleFriendControlMessage(");
    const std::string delivery = SourceSection(
        manager,
        "V2TIMManagerImpl::DeliverFriendMessage(",
        "V2TIMManagerImpl::HandleFriendMessage(");
    const std::string legacy_receive = SourceSection(
        manager,
        "V2TIMManagerImpl::HandleFriendMessage(",
        "V2TIMManagerImpl::PrunePendingDeliveriesLocked(");

    EXPECT_NE(
        generic_receive.find(
            "static_cast<uint8_t>(Type::kGenericCustom)"),
        std::string::npos);
    EXPECT_NE(delivery.find("NotifyAdvancedListenersReceivedMessage(message)"),
              std::string::npos);
    const size_t custom_branch =
        delivery.find("elem->elemType == V2TIM_ELEM_TYPE_CUSTOM");
    const size_t route_guard = delivery.find(
        "ReceiverCustomRouteOverrideGuard receiver_custom_route_guard(custom_route)");
    const size_t simple_callback =
        delivery.find("listener->OnRecvC2CCustomMessage(");
    ASSERT_NE(custom_branch, std::string::npos);
    ASSERT_NE(route_guard, std::string::npos);
    ASSERT_NE(simple_callback, std::string::npos);
    EXPECT_LT(custom_branch, route_guard);
    EXPECT_LT(route_guard, simple_callback);
    EXPECT_NE(
        legacy_receive.find(
            "DeliverFriendMessage(v2_message, senderUserID, sender_pubkey, 0)"),
        std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     ReceiverOverridesAreScopedAcrossThrowingCustomCallbacks) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string control_receive = SourceSection(
        manager,
        "V2TIMManagerImpl::HandleFriendControlMessage(",
        "V2TIMManagerImpl::DeliverFriendMessage(");
    const std::string delivery = SourceSection(
        manager,
        "V2TIMManagerImpl::DeliverFriendMessage(",
        "V2TIMManagerImpl::HandleFriendMessage(");
    const std::string group_delivery = SourceSection(
        manager,
        "V2TIMManagerImpl::HandleGroupMessageGroup(",
        "V2TIMManagerImpl::HandleGroupPrivateMessage(");

    EXPECT_NE(manager.find("class ReceiverInstanceOverrideGuard"),
              std::string::npos);
    EXPECT_NE(manager.find("class ReceiverCustomRouteOverrideGuard"),
              std::string::npos);
    EXPECT_NE(manager.find("~ReceiverInstanceOverrideGuard() noexcept"),
              std::string::npos);
    EXPECT_NE(manager.find("~ReceiverCustomRouteOverrideGuard() noexcept"),
              std::string::npos);
    EXPECT_NE(
        manager.find(
            "previous_instance_id_(GetReceiverInstanceOverride())"),
        std::string::npos);
    EXPECT_NE(
        manager.find(
            "previous_route_(GetReceiverCustomRouteOverride())"),
        std::string::npos);
    EXPECT_NE(manager.find("if (previous_instance_id_ == 0)"),
              std::string::npos);
    EXPECT_NE(manager.find("if (previous_route_ == -1)"),
              std::string::npos);
    EXPECT_NE(
        manager.find("SetReceiverInstanceOverride(previous_instance_id_)"),
        std::string::npos);
    EXPECT_NE(
        manager.find(
            "SetReceiverCustomRouteOverride(static_cast<uint8_t>(previous_route_))"),
        std::string::npos);
    EXPECT_NE(manager.find("ClearReceiverInstanceOverride();"),
              std::string::npos);
    EXPECT_NE(manager.find("ClearReceiverCustomRouteOverride();"),
              std::string::npos);
    EXPECT_NE(control_receive.find("ReceiverInstanceOverrideGuard"),
              std::string::npos);
    EXPECT_NE(control_receive.find("ReceiverCustomRouteOverrideGuard"),
              std::string::npos);
    EXPECT_NE(delivery.find("ReceiverInstanceOverrideGuard"),
              std::string::npos);
    EXPECT_NE(delivery.find("ReceiverCustomRouteOverrideGuard"),
              std::string::npos);
    const size_t advanced_instance_guard = delivery.find(
        "ReceiverInstanceOverrideGuard advanced_receiver_guard(receiver_instance_id)");
    const size_t advanced_callback =
        delivery.find("NotifyAdvancedListenersReceivedMessage(message)");
    const size_t simple_instance_guard = delivery.find(
        "ReceiverInstanceOverrideGuard simple_receiver_guard(receiver_instance_id)");
    const size_t group_callback =
        group_delivery.find("listener->OnRecvGroupCustomMessage(");
    const size_t group_catch =
        group_delivery.find("catch (...)", group_callback);
    const size_t control_callback =
        control_receive.find("listener->OnRecvC2CCustomMessage(");
    const size_t control_catch =
        control_receive.find("catch (...)", control_callback);
    const size_t delivery_callback =
        delivery.find("listener->OnRecvC2CCustomMessage(");
    const size_t delivery_catch =
        delivery.find("catch (...)", delivery_callback);
    const size_t c2c_text_try = delivery.find(
        "try {\n                        listener->OnRecvC2CTextMessage(");
    const size_t group_text_try = group_delivery.find(
        "try {\n                            listener->OnRecvGroupTextMessage(");
    ASSERT_NE(control_callback, std::string::npos);
    ASSERT_NE(control_catch, std::string::npos);
    ASSERT_NE(advanced_instance_guard, std::string::npos);
    ASSERT_NE(advanced_callback, std::string::npos);
    ASSERT_NE(simple_instance_guard, std::string::npos);
    ASSERT_NE(delivery_callback, std::string::npos);
    ASSERT_NE(delivery_catch, std::string::npos);
    ASSERT_NE(group_callback, std::string::npos);
    ASSERT_NE(group_catch, std::string::npos);
    ASSERT_NE(c2c_text_try, std::string::npos);
    ASSERT_NE(group_text_try, std::string::npos);
    EXPECT_LT(control_callback, control_catch);
    EXPECT_LT(advanced_instance_guard, advanced_callback);
    EXPECT_LT(advanced_callback, simple_instance_guard);
    EXPECT_LT(delivery_callback, delivery_catch);
    EXPECT_LT(group_callback, group_catch);
}

TEST(ControlPathSourceRegressionTest,
     DeliveryReceiptCallbacksAreIsolatedAndPreserveReceiptSemantics) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string message_manager =
        ReadSource(TIM2TOX_MESSAGE_MANAGER_SOURCE_PATH);
    const std::string receipt = SourceSection(
        message_manager,
        "void V2TIMMessageManagerImpl::NotifyMessageDeliveryReceipt(",
        "void V2TIMMessageManagerImpl::NotifyMessageRevoked(");

    const size_t receipt_callback =
        receipt.find("OnRecvMessageReadReceipts(receipts)");
    const size_t receipt_catch = receipt.find("catch (...)", receipt_callback);
    ASSERT_NE(receipt_callback, std::string::npos);
    ASSERT_NE(receipt_catch, std::string::npos);
    EXPECT_LT(receipt_callback, receipt_catch);
    EXPECT_NE(receipt.find("[Callback]"), std::string::npos);
    EXPECT_NE(receipt.find("status"), std::string::npos);
    EXPECT_EQ(receipt.find("msgID"), std::string::npos);
    EXPECT_EQ(receipt.find("userID"), std::string::npos);
    EXPECT_NE(manager.find("receipt.isPeerRead = false;"), std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     AdvancedMessageCallbacksAreIsolated) {
    const std::string message_manager =
        ReadSource(TIM2TOX_MESSAGE_MANAGER_SOURCE_PATH);
    const std::string notify = SourceSection(
        message_manager,
        "void V2TIMMessageManagerImpl::NotifyAdvancedListenersReceivedMessage(",
        "void V2TIMMessageManagerImpl::NotifyMessageDeliveryReceipt(");

    const size_t callback = notify.find("listener->OnRecvNewMessage(message)");
    const size_t catch_block = notify.find("catch (...)", callback);
    ASSERT_NE(callback, std::string::npos);
    ASSERT_NE(catch_block, std::string::npos);
    EXPECT_LT(callback, catch_block);
    EXPECT_NE(notify.find("category=advanced-message status=threw"),
              std::string::npos);
    EXPECT_EQ(notify.find("msgID"), std::string::npos);
    EXPECT_EQ(notify.find("userID"), std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     C2CCustomPollingAtomicallyPrefixesInternalRouteByte) {
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string c2c_receive = SourceSection(
        ffi_source,
        "void OnRecvC2CCustomMessage(",
        "void OnRecvGroupTextMessage(");
    const std::string group_receive = SourceSection(
        ffi_source,
        "void OnRecvGroupCustomMessage(",
        "// instance_id:");

    EXPECT_NE(ffi_source.find("int GetReceiverCustomRouteOverride(void);"),
              std::string::npos);
    EXPECT_NE(ffi_source.find("void SetReceiverCustomRouteOverride(uint8_t route);"),
              std::string::npos);
    EXPECT_NE(ffi_source.find("void ClearReceiverCustomRouteOverride(void);"),
              std::string::npos);
    EXPECT_NE(
        ffi_source.find(
            "static thread_local int g_receiver_custom_route_override = -1;"),
        std::string::npos);
    EXPECT_NE(c2c_receive.find("c2cbin:"), std::string::npos);
    EXPECT_NE(
        c2c_receive.find(
            "HexEncodeWithRoute(route, customData.Data(), customData.Size())"),
        std::string::npos);
    EXPECT_NE(c2c_receive.find("GetReceiverCustomRouteOverride()"),
              std::string::npos);
    EXPECT_NE(c2c_receive.find(": 3;"), std::string::npos);
    EXPECT_EQ(c2c_receive.find("customData ="), std::string::npos);
    EXPECT_EQ(c2c_receive.find("custom_q_"), std::string::npos);
    EXPECT_NE(group_receive.find("gcustombin:"), std::string::npos);
    EXPECT_NE(
        group_receive.find("enqueue_text_line_for_instance(instance_id, line)"),
        std::string::npos);
    EXPECT_EQ(group_receive.find("custom_q_"), std::string::npos);
    EXPECT_NE(ffi_source.find("int tim2tox_ffi_poll_custom("),
              std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     PollTextResolvesDefaultInstanceBeforeQueueSelection) {
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string poll_text = SourceSection(
        ffi_source,
        "int tim2tox_ffi_poll_text(",
        "int tim2tox_ffi_poll_custom(");

    EXPECT_NE(
        poll_text.find(
            "int64_t id = (instance_id == 0) ? GetCurrentInstanceId() : instance_id;"),
        std::string::npos);
    EXPECT_NE(poll_text.find("IsInstanceInited(id)"), std::string::npos);
    EXPECT_NE(
        poll_text.find(
            "return G.simple_listener.poll_text(id, buffer, buffer_len);"),
        std::string::npos);
    EXPECT_EQ(
        poll_text.find(
            "return G.simple_listener.poll_text(instance_id, buffer, buffer_len);"),
        std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     PollTextKeepsOneQueuedRecordAndOpaqueNewlines) {
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string listener = SourceSection(
        ffi_source,
        "int poll_text(int64_t instance_id, char* buf, int len) {",
        "int poll_custom(int64_t instance_id, unsigned char* buf, int len) {");

    EXPECT_NE(listener.find("payload may legally contain newlines"),
              std::string::npos);
    EXPECT_NE(listener.find("text_q_.pop();"), std::string::npos);
    EXPECT_NE(listener.find("CopyPayloadOrReturnRequiredCapacity(s, buf, len)"),
              std::string::npos);
    EXPECT_NE(listener.find("if (n < 0) return n;"), std::string::npos);
}

TEST(ControlPathSourceRegressionTest,
     FriendApplicationListUsesNegativeRequiredCapacityForBothApis) {
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string capacity_helper = SourceSection(
        ffi_source,
        "static int CopyPayloadOrReturnRequiredCapacity(",
        "class SimpleMsgListenerImpl");
    const std::string impl = SourceSection(
        ffi_source,
        "static int get_friend_applications_impl(",
        "int tim2tox_ffi_get_friend_applications(");
    const std::string exact_api = SourceSection(
        ffi_source,
        "int tim2tox_ffi_get_friend_applications_for_instance(",
        "int tim2tox_ffi_accept_friend(");

    EXPECT_NE(
        capacity_helper.find(
            "static_cast<size_t>(std::numeric_limits<int>::max()) - 1"),
        std::string::npos);
    EXPECT_NE(
        capacity_helper.find("return std::numeric_limits<int>::min();"),
        std::string::npos);
    EXPECT_NE(
        capacity_helper.find(
            "const int required_capacity = static_cast<int>(payload_size) + 1;"),
        std::string::npos);
    EXPECT_NE(capacity_helper.find("return -required_capacity;"),
              std::string::npos);
    EXPECT_NE(
        capacity_helper.find(
            "if (buffer_len <= 0) return -required_capacity;"),
        std::string::npos);
    EXPECT_EQ(
        capacity_helper.find("if (!buffer || buffer_len <= 0) return 0;"),
        std::string::npos);
    EXPECT_NE(capacity_helper.find("buffer[bytes_written] = 0;"),
              std::string::npos);
    EXPECT_NE(
        impl.find(
            "return CopyPayloadOrReturnRequiredCapacity(rcb.out, buffer, buffer_len);"),
        std::string::npos);
    EXPECT_EQ(impl.find("std::min"), std::string::npos);
    EXPECT_EQ(impl.find("buffer_len <= 0"), std::string::npos);
    EXPECT_NE(
        ffi_source.find(
            "return get_friend_applications_impl(GetCurrentInstance(), buffer, buffer_len);"),
        std::string::npos);
    EXPECT_NE(
        ffi_source.find(
            "return get_friend_applications_impl(manager, buffer, buffer_len);"),
        std::string::npos);
    EXPECT_NE(exact_api.find("IsInstanceInited(instance_id)"),
              std::string::npos);
    EXPECT_NE(exact_api.find("GetManagerForInstanceId(instance_id)"),
              std::string::npos);
    EXPECT_EQ(exact_api.find("GetCurrentInstanceId()"), std::string::npos);
    EXPECT_EQ(exact_api.find("buffer_len <= 0"), std::string::npos);
}

TEST(ControlPathSourceRegressionTest, GroupCustomSendFailsClosed) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string manager_send = SourceSection(
        manager,
        "V2TIMManagerImpl::SendGroupCustomMessage(",
        "// Group Management");
    const std::string ffi_send = SourceSection(
        ffi_source,
        "int tim2tox_ffi_send_group_custom(",
        "int tim2tox_ffi_send_file(");

    EXPECT_NE(manager_send.find("ERR_SDK_INTERFACE_NOT_SUPPORT"),
              std::string::npos);
    EXPECT_EQ(manager_send.find("groupSendMessage("), std::string::npos);
    EXPECT_NE(ffi_send.find("return msg_id.Empty() ? 0 : 1;"),
              std::string::npos);
}

TEST(ControlPathSourceRegressionTest, NlohmannProvisioningIsFfiOnly) {
    const std::string root_cmake = ReadSource(TIM2TOX_ROOT_CMAKE_PATH);
    const std::string source_cmake = ReadSource(TIM2TOX_SOURCE_CMAKE_PATH);
    const std::string ffi_cmake = ReadSource(TIM2TOX_FFI_CMAKE_PATH);

    EXPECT_EQ(root_cmake.find("nlohmann"), std::string::npos);
    EXPECT_EQ(source_cmake.find("nlohmann"), std::string::npos);
    EXPECT_NE(
        ffi_cmake.find("if(NOT TARGET nlohmann_json::nlohmann_json)"),
        std::string::npos);
    EXPECT_NE(
        ffi_cmake.find(
            "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/nlohmann_json/single_include"),
        std::string::npos);
    EXPECT_NE(
        ffi_cmake.find(
            "add_library(nlohmann_json::nlohmann_json INTERFACE IMPORTED)"),
        std::string::npos);
    EXPECT_NE(ffi_cmake.find("nlohmann_json::nlohmann_json"),
              std::string::npos);
    EXPECT_EQ(ffi_cmake.find("file(DOWNLOAD"), std::string::npos);
    EXPECT_EQ(ffi_cmake.find("FetchContent"), std::string::npos);
    EXPECT_EQ(ffi_cmake.find("find_package(nlohmann"), std::string::npos);
    EXPECT_EQ(ffi_cmake.find("CMAKE_BINARY_DIR"), std::string::npos);
    EXPECT_EQ(ffi_cmake.find("execute_process"), std::string::npos);
}

}
