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

# Register tests
include(GoogleTest)
gtest_discover_tests(tox_util_test)
gtest_discover_tests(v2tim_string_test)
gtest_discover_tests(v2tim_message_test)
gtest_discover_tests(irc_client_manager_test)
