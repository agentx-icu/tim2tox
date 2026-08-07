cmake_minimum_required(VERSION 3.10)
project(tim2tox_examples)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Ensure version.h is available for the embedded tim2tox build in this example tree.
# We generate a local copy under this build dir and add it to the include path so
# source/V2TIMManagerImpl.cpp can include "version.h" when compiled from tim2tox_build.
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/generated)
configure_file(
    ${CMAKE_SOURCE_DIR}/../source/version.h.in
    ${CMAKE_BINARY_DIR}/generated/version.h
    @ONLY
)
include_directories(${CMAKE_BINARY_DIR}/generated)

# Find required packages
find_package(PkgConfig REQUIRED)
pkg_check_modules(SODIUM REQUIRED libsodium)

# Find OpenSSL for IRC SSL/TLS support
find_package(OpenSSL REQUIRED)
if(OpenSSL_FOUND)
    message(STATUS "OpenSSL found: ${OPENSSL_VERSION}")
    message(STATUS "OpenSSL include dir: ${OPENSSL_INCLUDE_DIR}")
    message(STATUS "OpenSSL libraries: ${OPENSSL_LIBRARIES}")
else()
    message(FATAL_ERROR "OpenSSL not found. Please install OpenSSL (e.g., brew install openssl)")
endif()

# Configure toxcore build options and add subdirectory
set(BUILD_TOXAV OFF CACHE BOOL "Disable toxav" FORCE)
set(BOOTSTRAP_DAEMON OFF CACHE BOOL "Disable bootstrap daemon" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "Disable toxcore tests" FORCE)
add_subdirectory(${CMAKE_SOURCE_DIR}/../third_party/c-toxcore ${CMAKE_BINARY_DIR}/toxcore_build)

# Include directories
include_directories(
    ${CMAKE_SOURCE_DIR}/../include
    ${CMAKE_SOURCE_DIR}/../source
    ${CMAKE_SOURCE_DIR}/../third_party/c-toxcore
    ${SODIUM_INCLUDE_DIRS}
    ${OPENSSL_INCLUDE_DIR}
)

# Build tim2tox static library within this build
add_subdirectory(${CMAKE_SOURCE_DIR}/../source ${CMAKE_BINARY_DIR}/tim2tox_build)

# Echo Bot Server (C++) using V2TIM*
add_executable(echo_bot_server echo_bot_server.cpp)
target_link_libraries(echo_bot_server
    /opt/homebrew/lib/libsodium.dylib
    tim2tox
)

# Echo Bot Client (C++) using V2TIM*
add_executable(echo_bot_client echo_bot_client.cpp)
target_link_libraries(echo_bot_client
    /opt/homebrew/lib/libsodium.dylib
    tim2tox
)

# Note: FFI library (tim2tox_ffi) is now built in the main tim2tox CMakeLists.txt
# and should be built separately before building examples that depend on it.

# IRC Client Dynamic Library (loaded on demand when IRC app is installed)
add_library(irc_client SHARED 
    ${CMAKE_SOURCE_DIR}/../source/irc_client_api.cpp
    ${CMAKE_SOURCE_DIR}/../source/IrcClientManager.cpp
)
target_include_directories(irc_client PRIVATE 
    ${CMAKE_SOURCE_DIR}/../include 
    ${CMAKE_SOURCE_DIR}/../source
    ${OPENSSL_INCLUDE_DIR}
)
target_link_libraries(irc_client
    tim2tox
    /opt/homebrew/lib/libsodium.dylib
    ${OPENSSL_LIBRARIES}
)
set_target_properties(irc_client PROPERTIES
    OUTPUT_NAME "irc_client"
    POSITION_INDEPENDENT_CODE ON
)
# Fix OpenSSL library paths for macOS
if(APPLE)
    add_custom_command(TARGET irc_client POST_BUILD
        COMMAND install_name_tool -change 
            /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib 
            @rpath/libssl.3.dylib 
            $<TARGET_FILE:irc_client>
        COMMAND install_name_tool -change 
            /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib 
            @rpath/libcrypto.3.dylib 
            $<TARGET_FILE:irc_client>
        COMMAND install_name_tool -add_rpath /opt/homebrew/opt/openssl@3/lib 
            $<TARGET_FILE:irc_client>
        COMMENT "Fixing OpenSSL library paths for irc_client"
    )
endif()

# Tim2Tox Client (C++) - optional, only if libtim2tox exists
if (EXISTS "${CMAKE_SOURCE_DIR}/../build/source/libtim2tox.a")
    add_executable(tim2tox_client tim2tox_client.cpp)
    target_link_libraries(tim2tox_client
        /opt/homebrew/lib/libsodium.dylib
        ${CMAKE_SOURCE_DIR}/../build/source/libtim2tox.a
        toxcore_static
    )
else()
    message(WARNING "libtim2tox.a not found; skipping tim2tox_client target")
endif()

# Set compiler flags
target_compile_options(echo_bot_server PRIVATE ${SODIUM_CFLAGS_OTHER})
target_compile_options(echo_bot_client PRIVATE ${SODIUM_CFLAGS_OTHER})
if (TARGET tim2tox_client)
    target_compile_options(tim2tox_client PRIVATE ${SODIUM_CFLAGS_OTHER})
endif()

# Link directories
link_directories(${SODIUM_LIBRARY_DIRS})

# Set RPATH for macOS
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)
set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE) 
