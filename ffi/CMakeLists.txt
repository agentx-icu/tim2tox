cmake_minimum_required(VERSION 3.4.1)

# Add nlohmann/json library (header-only)
#
# We avoid CMake FetchContent here because the generated ExternalProject build
# step can fail on some toolchain/CMake combinations (the logs show `gmake &&`).
# Since nlohmann/json is header-only, we only need to download+extract once and
# provide include directories.
set(NLOHMANN_JSON_VERSION "3.12.0")
set(NLOHMANN_JSON_URL
    "https://github.com/nlohmann/json/releases/download/v${NLOHMANN_JSON_VERSION}/json.tar.xz"
)

set(_json_deps_dir "${CMAKE_BINARY_DIR}/_deps")
set(_json_tar "${_json_deps_dir}/nlohmann_json_${NLOHMANN_JSON_VERSION}.tar.xz")
set(_json_src_dir "${_json_deps_dir}/nlohmann_json-src")
set(_json_include_dir "${_json_src_dir}/single_include")

if(NOT EXISTS "${_json_include_dir}/nlohmann/json.hpp")
    file(MAKE_DIRECTORY "${_json_deps_dir}")

    if(NOT EXISTS "${_json_tar}")
        message(STATUS "Downloading nlohmann/json ${NLOHMANN_JSON_VERSION} ...")
        file(DOWNLOAD
            "${NLOHMANN_JSON_URL}"
            "${_json_tar}"
            SHOW_PROGRESS
            STATUS status
            LOG log
        )
        list(GET status 0 _json_download_status)
        if(NOT _json_download_status EQUAL 0)
            message(FATAL_ERROR "Failed to download nlohmann/json: ${log}")
        endif()
    endif()

    # Extract into a temp directory, then rename the single top-level folder.
    set(i 1234)
    while(EXISTS "${_json_deps_dir}/ex-nlohmann-json${i}")
        math(EXPR i "${i} + 1")
    endwhile()
    set(ut_dir "${_json_deps_dir}/ex-nlohmann-json${i}")
    file(MAKE_DIRECTORY "${ut_dir}")

    message(STATUS "Extracting nlohmann/json ...")
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E tar xfz "${_json_tar}"
        WORKING_DIRECTORY "${ut_dir}"
        RESULT_VARIABLE rv
    )
    if(NOT rv EQUAL 0)
        file(REMOVE_RECURSE "${ut_dir}")
        message(FATAL_ERROR "Failed to extract nlohmann/json tarball (rv=${rv})")
    endif()

    file(GLOB contents "${ut_dir}/*")
    list(REMOVE_ITEM contents "${ut_dir}/.DS_Store")
    list(LENGTH contents n)
    if(NOT n EQUAL 1 OR NOT IS_DIRECTORY "${contents}")
        set(contents "${ut_dir}")
    endif()

    file(REMOVE_RECURSE "${_json_src_dir}")
    file(RENAME ${contents} "${_json_src_dir}")
    file(REMOVE_RECURSE "${ut_dir}")
endif()

add_library(nlohmann_json::nlohmann_json INTERFACE IMPORTED)
set_target_properties(nlohmann_json::nlohmann_json PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${_json_include_dir}"
)

# FFI shared library for Flutter/Dart bindings
# Note: dart_api_dl.c will be added after we find it
add_library(tim2tox_ffi SHARED 
    tim2tox_ffi.cpp
    callback_bridge.cpp
    json_parser.cpp
    dart_compat_layer.cpp
    dart_compat_utils.cpp
    dart_compat_listeners.cpp
    dart_compat_callbacks.cpp
    dart_compat_sdk.cpp
    dart_compat_message.cpp
    dart_compat_friendship.cpp
    dart_compat_conversation.cpp
    dart_compat_group.cpp
    dart_compat_user.cpp
    dart_compat_signaling.cpp
    dart_compat_community.cpp
    dart_compat_other.cpp
)

# On Windows, ensure plain C/C++ API symbols are exported from the shared DLL.
# This is required for FFI entrypoints like tim2tox_ffi_set_log_file that are
# declared in headers but not explicitly decorated with __declspec(dllexport).
if(WIN32)
    set_target_properties(tim2tox_ffi PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
endif()

# For Windows builds, tim2tox_ffi is SHARED and links against the static tim2tox.
# Define TIM_EXPORT so TIM_API doesn't force dllimport-only behavior (which breaks static linking).
if(WIN32)
    target_compile_definitions(tim2tox_ffi PRIVATE TIM_EXPORT=1)
endif()

# Set include directories
target_include_directories(tim2tox_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../source
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/c-toxcore
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/c-toxcore/toxcore
)

# MSVC: ensure UTF-8 source files are parsed correctly.
# This project vendors some C/C++ headers with UTF-8 content/comments; without /utf-8
# MSVC can mis-parse them and trigger cascading syntax errors (e.g. in V2TIMFriendship.h).
if(MSVC)
    target_compile_options(tim2tox_ffi PRIVATE /utf-8)
endif()

# Add Dart API DL include path
# Try to find Flutter/Dart SDK include directory
if(DEFINED ENV{FLUTTER_ROOT})
    set(FLUTTER_ROOT $ENV{FLUTTER_ROOT})
else()
    # Try to find Flutter from PATH
    find_program(FLUTTER_BIN flutter)
    if(FLUTTER_BIN)
        # Get the directory containing the flutter binary (bin/)
        get_filename_component(FLUTTER_BIN_DIR ${FLUTTER_BIN} DIRECTORY)
        # Get the parent directory (Flutter root)
        get_filename_component(FLUTTER_ROOT ${FLUTTER_BIN_DIR} DIRECTORY)
    endif()
endif()

# Try Flutter root paths
set(DART_SDK_PATHS)
if(FLUTTER_ROOT)
    list(APPEND DART_SDK_PATHS "${FLUTTER_ROOT}/bin/cache/dart-sdk/include")
endif()
# Add fallback paths
list(APPEND DART_SDK_PATHS
    "$ENV{HOME}/flutter/bin/cache/dart-sdk/include"
    "/usr/local/flutter/bin/cache/dart-sdk/include"
    "/opt/flutter/bin/cache/dart-sdk/include"
)

# Find and add Dart API DL include path and source file
set(DART_API_DL_C_PATH "")
foreach(DART_PATH IN LISTS DART_SDK_PATHS)
    if(EXISTS "${DART_PATH}/dart_api_dl.h")
        target_include_directories(tim2tox_ffi PRIVATE ${DART_PATH})
        message(STATUS "Found Dart API DL at: ${DART_PATH}")
        # Also find dart_api_dl.c source file
        if(EXISTS "${DART_PATH}/dart_api_dl.c")
            set(DART_API_DL_C_PATH "${DART_PATH}/dart_api_dl.c")
            message(STATUS "Found Dart API DL source at: ${DART_API_DL_C_PATH}")
            # Add dart_api_dl.c to the library sources
            target_sources(tim2tox_ffi PRIVATE "${DART_API_DL_C_PATH}")
        else()
            message(WARNING "dart_api_dl.c not found at ${DART_PATH}, Dart API DL symbols may not be available")
        endif()
        break()
    endif()
endforeach()

# If dart_api_dl.c was not found, warn but continue
if(NOT DART_API_DL_C_PATH)
    message(WARNING "dart_api_dl.c not found in any Dart SDK path. Dart_PostCObject_DL symbols will not be available.")
endif()

# Platform-specific include directories
if(APPLE)
    if(DEFINED TIM2TOX_DEP_PREFIX AND EXISTS "${TIM2TOX_DEP_PREFIX}/include")
        target_include_directories(tim2tox_ffi PRIVATE "${TIM2TOX_DEP_PREFIX}/include")
    # macOS - check for both Intel and Apple Silicon homebrew paths
    elseif(EXISTS "/opt/homebrew/include")
        target_include_directories(tim2tox_ffi PRIVATE /opt/homebrew/include)
    elseif(EXISTS "/usr/local/include")
        target_include_directories(tim2tox_ffi PRIVATE /usr/local/include)
    endif()
elseif(UNIX AND NOT APPLE)
    # Linux - use standard system paths and pkg-config
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SODIUM libsodium)
    if(SODIUM_FOUND)
        target_include_directories(tim2tox_ffi PRIVATE ${SODIUM_INCLUDE_DIRS})
    endif()
elseif(WIN32)
    # Windows - support vcpkg and standard paths
    set(_vcpkg_triplet "x64-windows")
    if(DEFINED CMAKE_VS_PLATFORM_NAME AND (CMAKE_VS_PLATFORM_NAME STREQUAL "ARM64"))
        set(_vcpkg_triplet "arm64-windows")
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|aarch64")
        set(_vcpkg_triplet "arm64-windows")
    endif()

    if(DEFINED ENV{VCPKG_ROOT})
        target_include_directories(tim2tox_ffi PRIVATE $ENV{VCPKG_ROOT}/installed/${_vcpkg_triplet}/include)
    endif()
    # Also check standard Windows include paths
    target_include_directories(tim2tox_ffi PRIVATE "C:/vcpkg/installed/${_vcpkg_triplet}/include")
endif()

# Link dependencies
target_link_libraries(tim2tox_ffi
    tim2tox
    toxcore_static
    nlohmann_json::nlohmann_json  # Add nlohmann/json library
)

# Platform-specific library linking
if(APPLE)
    if(DEFINED TIM2TOX_DEP_PREFIX AND EXISTS "${TIM2TOX_DEP_PREFIX}/lib")
        find_library(SODIUM_LIB
            NAMES sodium libsodium
            PATHS "${TIM2TOX_DEP_PREFIX}/lib"
            NO_DEFAULT_PATH)
        if(SODIUM_LIB)
            target_link_libraries(tim2tox_ffi ${SODIUM_LIB})
        else()
            message(WARNING "libsodium not found under TIM2TOX_DEP_PREFIX=${TIM2TOX_DEP_PREFIX}")
        endif()
    # macOS - check for both Intel and Apple Silicon homebrew paths
    elseif(EXISTS "/opt/homebrew/lib/libsodium.dylib")
        target_link_libraries(tim2tox_ffi /opt/homebrew/lib/libsodium.dylib)
    elseif(EXISTS "/usr/local/lib/libsodium.dylib")
        target_link_libraries(tim2tox_ffi /usr/local/lib/libsodium.dylib)
    else()
        # Try to find libsodium using find_library
        find_library(SODIUM_LIB
            NAMES sodium libsodium
            PATHS
                /opt/homebrew/lib
                /usr/local/lib
                /usr/lib
        )
        if(SODIUM_LIB)
            target_link_libraries(tim2tox_ffi ${SODIUM_LIB})
        else()
            message(WARNING "libsodium not found, linking may fail")
        endif()
    endif()
elseif(UNIX AND NOT APPLE)
    # Linux - use pkg-config to find libsodium
    if(SODIUM_FOUND)
        target_link_libraries(tim2tox_ffi ${SODIUM_LIBRARIES})
    else()
        # Fallback to find_library
        find_library(SODIUM_LIB
            NAMES sodium libsodium
            PATHS
                /usr/lib
                /usr/local/lib
                /lib
        )
        if(SODIUM_LIB)
            target_link_libraries(tim2tox_ffi ${SODIUM_LIB})
        else()
            message(WARNING "libsodium not found, linking may fail")
        endif()
    endif()
elseif(WIN32)
    # Windows - support vcpkg and standard paths
    set(_vcpkg_triplet "x64-windows")
    if(DEFINED CMAKE_VS_PLATFORM_NAME AND (CMAKE_VS_PLATFORM_NAME STREQUAL "ARM64"))
        set(_vcpkg_triplet "arm64-windows")
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|aarch64")
        set(_vcpkg_triplet "arm64-windows")
    endif()

    if(DEFINED ENV{VCPKG_ROOT})
        find_library(SODIUM_LIB
            NAMES libsodium sodium
            PATHS
                $ENV{VCPKG_ROOT}/installed/${_vcpkg_triplet}/lib
                $ENV{VCPKG_ROOT}/installed/${_vcpkg_triplet}/debug/lib
        )
        if(SODIUM_LIB)
            target_link_libraries(tim2tox_ffi ${SODIUM_LIB})
        endif()
    endif()
    # Also check standard Windows library paths
    find_library(SODIUM_LIB_WIN
        NAMES libsodium sodium
        PATHS
            C:/vcpkg/installed/${_vcpkg_triplet}/lib
            C:/vcpkg/installed/${_vcpkg_triplet}/debug/lib
    )
    if(SODIUM_LIB_WIN)
        target_link_libraries(tim2tox_ffi ${SODIUM_LIB_WIN})
    endif()
endif()

# Link toxav dependencies if BUILD_TOXAV is enabled
# Note: toxav code is compiled into toxcore_static, so we don't need to link toxav_static
# But we need to link OPUS and VPX libraries that toxav depends on
if(BUILD_TOXAV)
    # Define preprocessor macro for conditional compilation
    target_compile_definitions(tim2tox_ffi PRIVATE BUILD_TOXAV=1)
    
    # Link OPUS and VPX libraries
    if(TARGET Opus::opus AND TARGET libvpx::libvpx)
        target_link_libraries(tim2tox_ffi Opus::opus libvpx::libvpx)
    elseif(TARGET PkgConfig::OPUS AND TARGET PkgConfig::VPX)
        target_link_libraries(tim2tox_ffi PkgConfig::OPUS PkgConfig::VPX)
    else()
        # Fallback: use pkg-config variables
        if(OPUS_FOUND)
            target_link_libraries(tim2tox_ffi ${OPUS_LIBRARIES})
            target_include_directories(tim2tox_ffi PRIVATE ${OPUS_INCLUDE_DIRS})
        endif()
        if(VPX_FOUND)
            target_link_libraries(tim2tox_ffi ${VPX_LIBRARIES})
            target_include_directories(tim2tox_ffi PRIVATE ${VPX_INCLUDE_DIRS})
        endif()
    endif()
endif()

# Platform-specific linker options
if(APPLE)
    # macOS: Use undefined dynamic lookup for Dart API DL functions
    # These functions are provided by the Dart VM at runtime
    set_target_properties(tim2tox_ffi PROPERTIES
        LINK_FLAGS "-undefined dynamic_lookup"
    )
elseif(ANDROID)
    # Android ELF: export ONLY the C FFI ABI (the Dart* binary-replacement
    # entrypoints + the tim2tox_ffi_* C API) and hide everything else — the ~5k
    # C++ mangled symbols and the vendored libsodium/toxcore symbols — so the
    # library can't collide with or interpose symbols in the host Flutter
    # process. See ffi/tim2tox_ffi_exports.map. Scoped to Android deliberately:
    # the Linux native test harness (e.g. account_export tox_profile_factory.dart)
    # dlsym's tox_* directly, so Linux must keep the full export surface.
    set_target_properties(tim2tox_ffi PROPERTIES
        LINK_FLAGS "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/tim2tox_ffi_exports.map"
    )
endif()

# Set library properties
set_target_properties(tim2tox_ffi PROPERTIES
    OUTPUT_NAME "tim2tox_ffi"
    POSITION_INDEPENDENT_CODE ON
)

# Install rules
install(TARGETS tim2tox_ffi
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

# Install FFI header
install(FILES tim2tox_ffi.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/tim2tox
)
