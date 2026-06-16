cmake_minimum_required(VERSION 3.4.1)

# Binary name
set(BINARY_NAME "tim2tox")

# Compiler warnings
if(NOT MSVC)
    add_definitions(-Wfatal-errors)
endif()

# Find dependencies (libsodium)
find_package(Sodium QUIET)
if (NOT Sodium_FOUND)
    find_package(PkgConfig QUIET)
    if (PKG_CONFIG_FOUND)
        pkg_check_modules(SODIUM_PKG QUIET libsodium)
        if (SODIUM_PKG_FOUND)
            set(SODIUM_INCLUDE_DIR ${SODIUM_PKG_INCLUDE_DIRS})
            # Prefer full library path if available; otherwise rely on linker flags
            if (SODIUM_PKG_LIBRARIES)
                list(GET SODIUM_PKG_LIBRARIES 0 SODIUM_LIBRARY)
            endif()
        endif()
    endif()
    if (NOT SODIUM_INCLUDE_DIR AND DEFINED TIM2TOX_DEP_PREFIX AND EXISTS "${TIM2TOX_DEP_PREFIX}/include")
        set(SODIUM_INCLUDE_DIR "${TIM2TOX_DEP_PREFIX}/include")
    endif()
    if (NOT SODIUM_LIBRARY AND DEFINED TIM2TOX_DEP_PREFIX AND EXISTS "${TIM2TOX_DEP_PREFIX}/lib")
        find_library(SODIUM_LIBRARY
            NAMES sodium libsodium
            PATHS "${TIM2TOX_DEP_PREFIX}/lib"
            NO_DEFAULT_PATH)
    endif()
    if (NOT SODIUM_INCLUDE_DIR)
        set(SODIUM_INCLUDE_DIR "/opt/homebrew/include")
    endif()
    if (NOT SODIUM_LIBRARY)
        set(SODIUM_LIBRARY "/opt/homebrew/lib/libsodium.dylib")
    endif()
endif()

# Include paths
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/c-toxcore
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/c-toxcore/toxcore
    ${CMAKE_CURRENT_BINARY_DIR}/../third_party/c-toxcore
    ${CMAKE_CURRENT_BINARY_DIR}/../third_party/c-toxcore/toxcore
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/c-toxcore/build
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/c-toxcore/build/toxcore
    ${SODIUM_INCLUDE_DIR}
)

# Build source list explicitly and respect BUILD_TOXAV
set(TIM2TOX_CORE_SRCS
    PathUtils.cpp
    V2TIMManagerImpl.cpp
    V2TIMMessageManagerImpl.cpp
    V2TIMFriendshipManagerImpl.cpp
    V2TIMGroupManagerImpl.cpp
    V2TIMSignalingManagerImpl.cpp
    V2TIMCommunityManagerImpl.cpp
    V2TIMConversationManagerImpl.cpp
    V2TIMLog.cpp
    V2TIMString.cpp
    V2TIMUtils.cpp
    V2TIMDataShim.cpp
    ToxManager.cpp
    V2TIMBuffer.cpp
    MessageReplyUtil.cpp
    MergerMessageUtil.cpp
    RevokeMessageUtil.cpp
    # IrcClientManager.cpp removed - now in dynamic library
)
set(TIM2TOX_SRCS ${TIM2TOX_CORE_SRCS})
if(BUILD_TOXAV)
    list(APPEND TIM2TOX_SRCS ToxAVManager.cpp)
endif()

add_library(tim2tox STATIC ${TIM2TOX_SRCS})

if(WIN32)
    # tim2tox headers use TIM_API to switch between __declspec(dllexport)/__declspec(dllimport).
    # This project builds tim2tox as a static library, then links it into tim2tox_ffi (a SHARED library).
    # Marking TIM_EXPORT for the core build prevents MSVC from treating V2TIM* symbols as dllimport-only.
    target_compile_definitions(tim2tox PRIVATE TIM_EXPORT=1)
    # Link Winsock2 for IrcClientManager socket operations
    target_link_libraries(tim2tox PUBLIC ws2_32)
endif()

if(BUILD_TOXAV)
    target_compile_definitions(tim2tox PRIVATE BUILD_TOXAV=1)
endif()

# Set include directories for the library
target_include_directories(tim2tox
    PUBLIC
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/source
    ${CMAKE_SOURCE_DIR}/third_party/c-toxcore
    ${CMAKE_SOURCE_DIR}/third_party/c-toxcore/toxcore
)

# Link dependencies
target_link_libraries(tim2tox
    PUBLIC
    toxcore_static
    ${SODIUM_LIBRARY}
)

# V2TIMCommunityManagerImpl uses sqlite3 directly on non-Windows builds
# (the `_WIN32` guard skips it on MSVC). When sqlite3 is in the translation
# unit we must link the library too, otherwise libtim2tox_ffi.so ships with
# an undefined `sqlite3_open` symbol that aborts dlopen at runtime.
# Allow the integrator to opt out with `-DTIM2TOX_DISABLE_SQLITE=ON`, in
# which case the source-side `TIM2TOX_DISABLE_SQLITE` macro keeps the code
# out of the build (mobile FFI builds already rely on this).
option(TIM2TOX_DISABLE_SQLITE "Build without sqlite3 (skips V2TIMCommunityManager persistence)" OFF)
if(TIM2TOX_DISABLE_SQLITE)
    target_compile_definitions(tim2tox PRIVATE TIM2TOX_DISABLE_SQLITE=1)
elseif(NOT WIN32)
    find_package(SQLite3 QUIET)
    if(SQLite3_FOUND)
        target_link_libraries(tim2tox PUBLIC SQLite::SQLite3)
    else()
        find_library(SQLITE3_LIB NAMES sqlite3)
        if(SQLITE3_LIB)
            target_link_libraries(tim2tox PUBLIC ${SQLITE3_LIB})
        else()
            message(FATAL_ERROR
                "sqlite3 not found. Install libsqlite3-dev (Linux) or pass "
                "-DTIM2TOX_DISABLE_SQLITE=ON to skip V2TIMCommunityManager "
                "persistence.")
        endif()
    endif()
endif()

if(BUILD_TOXAV)
    # Note: toxav code is compiled into toxcore_static, so we don't need to link toxav_static
    # But we need to link OPUS and VPX libraries that toxav depends on
    if(TARGET Opus::opus AND TARGET libvpx::libvpx)
        target_link_libraries(tim2tox
            PUBLIC
            Opus::opus
            libvpx::libvpx
        )
    elseif(TARGET PkgConfig::OPUS AND TARGET PkgConfig::VPX)
        target_link_libraries(tim2tox
            PUBLIC
            PkgConfig::OPUS
            PkgConfig::VPX
        )
    else()
        # Fallback: use pkg-config variables
        if(OPUS_FOUND)
            target_link_libraries(tim2tox PUBLIC ${OPUS_LIBRARIES})
            target_include_directories(tim2tox PUBLIC ${OPUS_INCLUDE_DIRS})
        endif()
        if(VPX_FOUND)
            target_link_libraries(tim2tox PUBLIC ${VPX_LIBRARIES})
            target_include_directories(tim2tox PUBLIC ${VPX_INCLUDE_DIRS})
        endif()
    endif()
endif()

# Compiler options
if(MSVC)
    target_compile_options(tim2tox
        PRIVATE
        /W3
        /utf-8
    )
else()
    target_compile_options(tim2tox
        PRIVATE
        -Wall
        -Wextra
        -Werror
        -Wno-unused-parameter
        -fPIC
    )
    if(NOT APPLE)
        # uint64_t/int64_t are 'unsigned long'/'long' on LP64 (Android/Linux
        # arm64), so the codebase's %llu/%lld debug-log format strings trip
        # -Wformat there only — the values are 64-bit either way, so the mismatch
        # is benign at runtime. Keep the warning visible but don't fail the
        # cross build on it. Scoped to non-Apple deliberately: on Apple uint64_t
        # IS 'unsigned long long', so %llu matches and -Werror=format stays on to
        # catch genuinely wrong format strings (codex review 2026-06-16).
        target_compile_options(tim2tox PRIVATE -Wno-error=format)
    endif()
endif()

if(APPLE)
    target_compile_options(tim2tox
        PRIVATE
        -Wno-deprecated-declarations
    )
endif()

# Install rules
install(TARGETS tim2tox
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

# Install headers
install(DIRECTORY ${CMAKE_SOURCE_DIR}/include/
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/tim2tox
    FILES_MATCHING PATTERN "*.h"
    PATTERN "*.h.in" EXCLUDE)
