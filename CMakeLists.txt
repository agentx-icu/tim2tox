cmake_minimum_required(VERSION 3.16)

project(tim2tox VERSION 0.1.0 LANGUAGES C CXX)

# Single source of truth for version: generated/version.h is included by source
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/generated)
configure_file(
  ${CMAKE_SOURCE_DIR}/source/version.h.in
  ${CMAKE_BINARY_DIR}/generated/version.h
  @ONLY
)
include_directories(${CMAKE_BINARY_DIR}/generated)

# Set C/C++ standards
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Build settings
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Optional dependencies
option(BUILD_TOXAV "Whether to build the tox AV library" OFF)
option(MUST_BUILD_TOXAV "Fail the build if toxav cannot be built" OFF)
option(DHT_BOOTSTRAP "Enable building of DHT_bootstrap" OFF)
option(BOOTSTRAP_DAEMON "Enable building of tox-bootstrapd" OFF)
option(BUILD_FUZZ_TESTS "Build fuzzing harnesses" OFF)

# Feature options
option(USE_IPV6 "Use IPv6" ON)
option(EXPERIMENTAL_API "Enable experimental API features" OFF)
option(TRACE "Enable TRACE level logging" OFF)
option(DEBUG "Enable DEBUG level logging" OFF)
option(ERROR "Enable ERROR level logging" ON)
option(WARNING "Enable WARNING level logging" ON)
option(INFO "Enable INFO level logging" ON)

# Build options
option(FLAT_OUTPUT_STRUCTURE "Whether to produce output artifacts in bin/lib" OFF)
option(BUILD_MISC_TESTS "Build additional tests" OFF)
option(BUILD_FUN_UTILS "Build additional just for fun utilities" OFF)
option(UNITTEST "Enable unit tests" OFF)
option(AUTOTEST "Enable autotests (mainly for CI)" OFF)
option(NON_HERMETIC_TESTS "Whether to build and run tests that depend on an internet connection" OFF)
option(PROXY_TEST "Enable proxy test" OFF)

# Platform specific options
if(MSVC)
    option(MSVC_STATIC_SODIUM "Whether to link libsodium statically for MSVC" OFF)
endif()

# Library type options
option(ENABLE_SHARED "Build shared libraries" OFF)
option(ENABLE_STATIC "Build static libraries" ON)

# Additional build options
option(ENABLE_LOGGING "Enable logging support" ON)
option(ENABLE_TESTS "Build test suite" OFF)
option(ENABLE_EXAMPLES "Build example applications" OFF)
option(USE_SANITIZER "Enable sanitizer support (address, thread, undefined)" OFF)

# Set output directories
if(FLAT_OUTPUT_STRUCTURE)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
endif()

# Add module path
list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/source/cmake)

# Prevent multiple inclusion of toxcore
if(NOT TARGET toxcore_static)
    add_subdirectory(third_party/c-toxcore)
endif()

# Add include directories
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/c-toxcore
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/c-toxcore/toxcore
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

if(DEFINED TIM2TOX_DEP_PREFIX AND EXISTS "${TIM2TOX_DEP_PREFIX}")
    include_directories("${TIM2TOX_DEP_PREFIX}/include")
    link_directories("${TIM2TOX_DEP_PREFIX}/lib")
endif()

# Platform-specific include and library directories
if(APPLE)
    # macOS - check for both Intel and Apple Silicon homebrew paths
    if(EXISTS "/opt/homebrew/include")
        include_directories(/opt/homebrew/include)
        link_directories(/opt/homebrew/lib)
    elseif(EXISTS "/usr/local/include")
        include_directories(/usr/local/include)
        link_directories(/usr/local/lib)
    endif()
elseif(UNIX AND NOT APPLE)
    # Linux - use pkg-config for dependency management
    find_package(PkgConfig REQUIRED)
elseif(WIN32)
    # Windows - support vcpkg. The triplet must follow the TARGET arch:
    # hardcoding x64-windows broke ARM64 builds — the toxav fallback link
    # entries (bare opus.lib/vpx.lib, see source/CMakeLists.txt) resolve via
    # these link_directories, and an x64 LIBPATH on an arm64 link fails with
    # LNK1181. Prefer the explicit VCPKG_TARGET_TRIPLET (set by the vcpkg
    # toolchain / toxee's build_tim2tox.sh), then fall back to arch sniffing.
    if(DEFINED VCPKG_TARGET_TRIPLET)
        set(_tim2tox_vcpkg_triplet "${VCPKG_TARGET_TRIPLET}")
    elseif((DEFINED CMAKE_VS_PLATFORM_NAME AND CMAKE_VS_PLATFORM_NAME STREQUAL "ARM64")
           OR CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|aarch64")
        set(_tim2tox_vcpkg_triplet "arm64-windows")
    else()
        set(_tim2tox_vcpkg_triplet "x64-windows")
    endif()
    if(DEFINED ENV{VCPKG_ROOT})
        include_directories($ENV{VCPKG_ROOT}/installed/${_tim2tox_vcpkg_triplet}/include)
        link_directories($ENV{VCPKG_ROOT}/installed/${_tim2tox_vcpkg_triplet}/lib)
    endif()
    # Also check standard Windows paths
    if(EXISTS "C:/vcpkg/installed/${_tim2tox_vcpkg_triplet}/include")
        include_directories(C:/vcpkg/installed/${_tim2tox_vcpkg_triplet}/include)
        link_directories(C:/vcpkg/installed/${_tim2tox_vcpkg_triplet}/lib)
    endif()
endif()

# Find dependencies - platform-specific
if(APPLE OR WIN32)
    # macOS and Windows - try to find Sodium package
    find_package(Sodium QUIET)
    if(NOT Sodium_FOUND)
        # Fallback: try to find libsodium manually
        find_library(SODIUM_LIB
            NAMES sodium libsodium
            PATHS
                ${TIM2TOX_DEP_PREFIX}/lib
                /opt/homebrew/lib
                /usr/local/lib
                /usr/lib
                C:/vcpkg/installed/${_tim2tox_vcpkg_triplet}/lib
        )
        if(NOT SODIUM_LIB)
            message(WARNING "libsodium not found, some features may not work")
        endif()
    endif()
elseif(UNIX AND NOT APPLE)
    # Linux - use pkg-config
    pkg_check_modules(SODIUM libsodium)
    if(NOT SODIUM_FOUND)
        # Fallback: try find_package
        find_package(Sodium QUIET)
        if(NOT Sodium_FOUND)
            message(WARNING "libsodium not found via pkg-config or find_package, some features may not work")
        endif()
    endif()
endif()

# Add source directory
add_subdirectory(source)

# Add FFI directory for Flutter/Dart bindings
option(BUILD_FFI "Build FFI shared library for Flutter/Dart" ON)
if(BUILD_FFI)
  add_subdirectory(ffi)
endif()

# Add test directory if testing is enabled
option(TIM2TOX_BUILD_TESTS "Build tim2tox test suite" OFF)
if(TIM2TOX_BUILD_TESTS)
  add_subdirectory(test)
endif()
