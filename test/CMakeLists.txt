cmake_minimum_required(VERSION 3.4.1)

# Enable testing
enable_testing()

# Find GTest without network access. Pass a local checkout through
# FETCHCONTENT_SOURCE_DIR_GOOGLETEST or TIM2TOX_GOOGLETEST_SOURCE_DIR when GTest
# is not installed on the host.
find_package(GTest CONFIG QUIET)
if(TARGET GTest::gtest_main)
    set(TIM2TOX_GTEST_MAIN_TARGET GTest::gtest_main)
elseif(TARGET GTest::Main)
    set(TIM2TOX_GTEST_MAIN_TARGET GTest::Main)
else()
    find_package(GTest QUIET)
    if(TARGET GTest::gtest_main)
        set(TIM2TOX_GTEST_MAIN_TARGET GTest::gtest_main)
    elseif(TARGET GTest::Main)
        set(TIM2TOX_GTEST_MAIN_TARGET GTest::Main)
    else()
        set(_tim2tox_googletest_source "${FETCHCONTENT_SOURCE_DIR_GOOGLETEST}")
        if(NOT _tim2tox_googletest_source AND DEFINED ENV{TIM2TOX_GOOGLETEST_SOURCE_DIR})
            set(_tim2tox_googletest_source "$ENV{TIM2TOX_GOOGLETEST_SOURCE_DIR}")
        endif()
        if(_tim2tox_googletest_source AND EXISTS "${_tim2tox_googletest_source}/CMakeLists.txt")
            include(FetchContent)
            FetchContent_Declare(googletest SOURCE_DIR "${_tim2tox_googletest_source}")
            # For Windows: Prevent overriding the parent project's compiler/linker settings
            set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
            FetchContent_MakeAvailable(googletest)
            set(TIM2TOX_GTEST_MAIN_TARGET gtest_main)
        else()
            message(FATAL_ERROR
                "GTest not found. Set FETCHCONTENT_SOURCE_DIR_GOOGLETEST or "
                "TIM2TOX_GOOGLETEST_SOURCE_DIR to a local googletest checkout; "
                "network fetch is intentionally disabled.")
        endif()
    endif()
endif()
if(TARGET GTest::gtest)
    set(TIM2TOX_GTEST_TARGET GTest::gtest)
elseif(TARGET GTest::GTest)
    set(TIM2TOX_GTEST_TARGET GTest::GTest)
elseif(TARGET gtest)
    set(TIM2TOX_GTEST_TARGET gtest)
else()
    message(FATAL_ERROR "GTest library target not found")
endif()

# Include directories
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/source
    ${CMAKE_SOURCE_DIR}/third_party/c-toxcore
    ${CMAKE_SOURCE_DIR}/third_party/c-toxcore/toxcore
    ${CMAKE_BINARY_DIR}/third_party/c-toxcore
)

# Test executables
add_executable(tox_util_test ToxUtilTest.cpp)
add_executable(v2tim_string_test V2TIMStringTest.cpp)
add_executable(v2tim_message_test V2TIMMessageTest.cpp)
add_executable(v2tim_log_test
    V2TIMLogTest.cpp
    ${CMAKE_SOURCE_DIR}/source/V2TIMLog.cpp)
add_executable(irc_client_manager_test IrcClientManagerTest.cpp
    ${CMAKE_SOURCE_DIR}/source/IrcClientManager.cpp)
add_executable(file_io_compat_test
    FileIoCompatTest.cpp
    ${CMAKE_SOURCE_DIR}/ffi/file_io_compat.cpp)
add_executable(event_line_parser_test
    EventLineParserTest.cpp
    ${CMAKE_SOURCE_DIR}/ffi/event_line_parser.cpp)
add_executable(dart_send_message_source_regression_test
    DartSendMessageSourceRegressionTest.cpp)
target_compile_definitions(dart_send_message_source_regression_test PRIVATE
    DART_COMPAT_MESSAGE_SOURCE_PATH="${CMAKE_SOURCE_DIR}/ffi/dart_compat_message.cpp")
add_executable(dart_send_message_contract_test
    DartSendMessageContractTest.cpp
    ${CMAKE_SOURCE_DIR}/ffi/dart_send_message_contract.cpp)
target_include_directories(dart_send_message_contract_test PRIVATE
    ${CMAKE_SOURCE_DIR}/ffi)
add_executable(file_transfer_security_source_regression_test
    FileTransferSecuritySourceRegressionTest.cpp)
target_compile_definitions(file_transfer_security_source_regression_test PRIVATE
    TIM2TOX_FFI_SOURCE_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.cpp"
    TIM2TOX_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/ToxManager.cpp")
add_executable(tim2tox_control_packet_test Tim2ToxControlPacketTest.cpp)
add_executable(qtox_message_fragmenter_test QToxMessageFragmenterTest.cpp)
add_executable(qtox_transport_source_regression_test
    QToxTransportSourceRegressionTest.cpp)
target_compile_definitions(qtox_transport_source_regression_test PRIVATE
    TIM2TOX_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.cpp"
    TIM2TOX_MANAGER_HEADER_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.h"
    TIM2TOX_FFI_SOURCE_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.cpp"
    TIM2TOX_FFI_HEADER_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.h")
add_executable(av_conference_lifecycle_source_regression_test
    AVConferenceLifecycleSourceRegressionTest.cpp)
target_compile_definitions(av_conference_lifecycle_source_regression_test PRIVATE
    TIM2TOX_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.cpp"
    TIM2TOX_MANAGER_HEADER_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.h"
    TIM2TOX_GROUP_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMGroupManagerImpl.cpp"
    TIM2TOX_FFI_SOURCE_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.cpp"
    TIM2TOX_FFI_HEADER_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.h"
    TIM2TOX_DART_FFI_PATH="${CMAKE_SOURCE_DIR}/dart/lib/ffi/tim2tox_ffi.dart"
    TIM2TOX_DART_SERVICE_PATH="${CMAKE_SOURCE_DIR}/dart/lib/service/ffi_chat_service.dart")
add_executable(av_conference_audio_queue_test
    AVConferenceAudioQueueTest.cpp
    ${CMAKE_SOURCE_DIR}/source/AVConferenceAudioQueue.cpp)
target_include_directories(av_conference_audio_queue_test PRIVATE
    ${CMAKE_SOURCE_DIR})
add_executable(group_canonical_identity_source_regression_test
    GroupCanonicalIdentitySourceRegressionTest.cpp)
target_compile_definitions(group_canonical_identity_source_regression_test PRIVATE
    TIM2TOX_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.cpp"
    TIM2TOX_MANAGER_HEADER_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.h")
add_executable(qtox_avatar_source_contract_test
    QToxAvatarSourceContractTest.cpp)
target_compile_definitions(qtox_avatar_source_contract_test PRIVATE
    TIM2TOX_FFI_SOURCE_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.cpp"
    TIM2TOX_FFI_HEADER_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.h"
    TIM2TOX_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/ToxManager.cpp")
add_executable(control_path_source_regression_test
    ControlPathSourceRegressionTest.cpp)
target_compile_definitions(control_path_source_regression_test PRIVATE
    TIM2TOX_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.cpp"
    TIM2TOX_MANAGER_HEADER_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.h"
    TIM2TOX_MESSAGE_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMMessageManagerImpl.cpp"
    TIM2TOX_FFI_SOURCE_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.cpp"
    TIM2TOX_FFI_HEADER_PATH="${CMAKE_SOURCE_DIR}/ffi/tim2tox_ffi.h"
    TIM2TOX_DART_FFI_PATH="${CMAKE_SOURCE_DIR}/dart/lib/ffi/tim2tox_ffi.dart"
    TIM2TOX_ROOT_CMAKE_PATH="${CMAKE_SOURCE_DIR}/CMakeLists.txt"
    TIM2TOX_SOURCE_CMAKE_PATH="${CMAKE_SOURCE_DIR}/source/CMakeLists.txt"
    TIM2TOX_FFI_CMAKE_PATH="${CMAKE_SOURCE_DIR}/ffi/CMakeLists.txt")
add_executable(native_log_privacy_source_regression_test
    NativeLogPrivacySourceRegressionTest.cpp)
target_compile_definitions(native_log_privacy_source_regression_test PRIVATE
    TIM2TOX_SOURCE_DIR="${CMAKE_SOURCE_DIR}/source"
    TIM2TOX_FFI_DIR="${CMAKE_SOURCE_DIR}/ffi"
    TIM2TOX_LOG_HEADER_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMLog.h"
    TIM2TOX_LOG_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMLog.cpp")

# Link dependencies
target_link_libraries(tox_util_test
    PRIVATE
    tim2tox
    toxcore_static
    ${TIM2TOX_GTEST_MAIN_TARGET}
)

target_link_libraries(v2tim_string_test
    PRIVATE
    tim2tox
    toxcore_static
    ${TIM2TOX_GTEST_MAIN_TARGET}
)

target_link_libraries(v2tim_message_test
    PRIVATE
    tim2tox
    toxcore_static
    ${TIM2TOX_GTEST_MAIN_TARGET}
)

target_link_libraries(v2tim_log_test
    PRIVATE
    ${TIM2TOX_GTEST_TARGET}
)

find_package(OpenSSL REQUIRED)
target_link_libraries(irc_client_manager_test
    PRIVATE
    tim2tox
    toxcore_static
    OpenSSL::SSL
    OpenSSL::Crypto
    ${TIM2TOX_GTEST_MAIN_TARGET}
)
if(WIN32)
    target_link_libraries(irc_client_manager_test PRIVATE ws2_32)
endif()

target_link_libraries(file_io_compat_test PRIVATE ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(event_line_parser_test PRIVATE ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(dart_send_message_source_regression_test PRIVATE ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(file_transfer_security_source_regression_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(tim2tox_control_packet_test PRIVATE
    tim2tox
    toxcore_static
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(qtox_message_fragmenter_test PRIVATE
    tim2tox
    toxcore_static
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(qtox_transport_source_regression_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(av_conference_lifecycle_source_regression_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(av_conference_audio_queue_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(group_canonical_identity_source_regression_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(qtox_avatar_source_contract_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(control_path_source_regression_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET})
target_link_libraries(native_log_privacy_source_regression_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET})
find_package(Threads REQUIRED)
target_link_libraries(dart_send_message_contract_test PRIVATE
    ${TIM2TOX_GTEST_MAIN_TARGET}
    Threads::Threads)
if(MSVC)
    target_compile_options(file_io_compat_test PRIVATE /utf-8)
endif()

# Register tests
include(GoogleTest)
gtest_discover_tests(tox_util_test)
gtest_discover_tests(v2tim_string_test)
gtest_discover_tests(v2tim_message_test)
gtest_discover_tests(v2tim_log_test)
gtest_discover_tests(irc_client_manager_test)
add_test(NAME file_io_compat_test COMMAND file_io_compat_test)
add_test(NAME event_line_parser_test COMMAND event_line_parser_test)
add_test(NAME dart_send_message_source_regression_test
    COMMAND dart_send_message_source_regression_test)
add_test(NAME dart_send_message_contract_test
    COMMAND dart_send_message_contract_test)
add_test(NAME file_transfer_security_source_regression_test
    COMMAND file_transfer_security_source_regression_test)
gtest_discover_tests(tim2tox_control_packet_test)
gtest_discover_tests(qtox_message_fragmenter_test)
add_test(NAME qtox_transport_source_regression_test
    COMMAND qtox_transport_source_regression_test)
add_test(NAME av_conference_lifecycle_source_regression_test
    COMMAND av_conference_lifecycle_source_regression_test)
add_test(NAME av_conference_audio_queue_test
    COMMAND av_conference_audio_queue_test)
add_test(NAME group_canonical_identity_source_regression_test
    COMMAND group_canonical_identity_source_regression_test)
add_test(NAME qtox_avatar_source_contract_test
    COMMAND qtox_avatar_source_contract_test)
add_test(NAME control_path_source_regression_test
    COMMAND control_path_source_regression_test)
add_test(NAME native_log_privacy_source_regression_test
    COMMAND native_log_privacy_source_regression_test)
