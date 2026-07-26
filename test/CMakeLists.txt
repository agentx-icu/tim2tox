cmake_minimum_required(VERSION 3.4.1)

# Enable testing
enable_testing()

# Find or fetch GTest
include(FetchContent)
FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG release-1.12.1
)
# For Windows: Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

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
    TIM2TOX_MANAGER_SOURCE_PATH="${CMAKE_SOURCE_DIR}/source/V2TIMManagerImpl.cpp")

# Link dependencies
target_link_libraries(tox_util_test
    PRIVATE
    tim2tox
    toxcore_static
    gtest_main
)

target_link_libraries(v2tim_string_test
    PRIVATE
    tim2tox
    toxcore_static
    gtest_main
)

target_link_libraries(v2tim_message_test
    PRIVATE
    tim2tox
    toxcore_static
    gtest_main
)

find_package(OpenSSL REQUIRED)
target_link_libraries(irc_client_manager_test
    PRIVATE
    tim2tox
    toxcore_static
    OpenSSL::SSL
    OpenSSL::Crypto
    gtest_main
)
if(WIN32)
    target_link_libraries(irc_client_manager_test PRIVATE ws2_32)
endif()

target_link_libraries(file_io_compat_test PRIVATE gtest_main)
target_link_libraries(event_line_parser_test PRIVATE gtest_main)
target_link_libraries(dart_send_message_source_regression_test PRIVATE gtest_main)
target_link_libraries(file_transfer_security_source_regression_test PRIVATE
    gtest_main)
find_package(Threads REQUIRED)
target_link_libraries(dart_send_message_contract_test PRIVATE
    gtest_main
    Threads::Threads)
if(MSVC)
    target_compile_options(file_io_compat_test PRIVATE /utf-8)
endif()

# Register tests
include(GoogleTest)
gtest_discover_tests(tox_util_test)
gtest_discover_tests(v2tim_string_test)
gtest_discover_tests(v2tim_message_test)
gtest_discover_tests(irc_client_manager_test)
add_test(NAME file_io_compat_test COMMAND file_io_compat_test)
add_test(NAME event_line_parser_test COMMAND event_line_parser_test)
add_test(NAME dart_send_message_source_regression_test
    COMMAND dart_send_message_source_regression_test)
add_test(NAME dart_send_message_contract_test
    COMMAND dart_send_message_contract_test)
add_test(NAME file_transfer_security_source_regression_test
    COMMAND file_transfer_security_source_regression_test)
