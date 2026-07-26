#include "file_io_compat.h"

#include <algorithm>
#include <limits>
#include <sys/stat.h>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <io.h>
#else
#include <sys/types.h>
#include <unistd.h>
#endif

namespace tim2tox::file_io {
namespace {

size_t Utf8PrefixLength(const std::string& value, size_t max_bytes) {
    if (value.size() <= max_bytes) return value.size();

    size_t end = max_bytes;
    while (end > 0 &&
           (static_cast<unsigned char>(value[end]) & 0xc0) == 0x80) {
        --end;
    }
    return end;
}

#ifdef _WIN32
bool Utf8ToWide(const std::string& value, std::wstring* result) {
    if (result == nullptr || value.empty() ||
        value.find('\0') != std::string::npos ||
        value.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
        return false;
    }
    const int value_size = static_cast<int>(value.size());
    const int required = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), value_size, nullptr, 0);
    if (required <= 0) return false;
    result->resize(static_cast<size_t>(required));
    const int converted = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), value_size,
        result->data(), required);
    if (converted != required) {
        result->clear();
        return false;
    }
    return true;
}
#endif

#if defined(__ANDROID__) && !defined(__LP64__)
bool CheckedAndroidOffset(uint64_t position, off64_t* offset) {
    constexpr uint64_t max_offset =
        static_cast<uint64_t>(std::numeric_limits<off64_t>::max());
    if (position > max_offset) return false;
    *offset = static_cast<off64_t>(position);
    return true;
}
#endif

}

FILE* OpenUtf8(const std::string& path, const char* mode) {
    if (mode == nullptr) return nullptr;
#ifdef _WIN32
    std::wstring wide_path;
    std::wstring wide_mode;
    if (!Utf8ToWide(path, &wide_path) ||
        !Utf8ToWide(std::string(mode), &wide_mode)) {
        return nullptr;
    }
    return _wfopen(wide_path.c_str(), wide_mode.c_str());
#else
    return fopen(path.c_str(), mode);
#endif
}

bool RemoveUtf8(const std::string& path) {
#ifdef _WIN32
    std::wstring wide_path;
    if (!Utf8ToWide(path, &wide_path)) return false;
    return _wunlink(wide_path.c_str()) == 0;
#else
    return unlink(path.c_str()) == 0;
#endif
}

bool GetFileSizeUtf8(const std::string& path, uint64_t* size) {
    if (size == nullptr) return false;
#ifdef _WIN32
    std::wstring wide_path;
    if (!Utf8ToWide(path, &wide_path)) return false;
    struct _stat64 status {};
    if (_wstat64(wide_path.c_str(), &status) != 0 || status.st_size < 0) {
        return false;
    }
#elif defined(__ANDROID__) && !defined(__LP64__)
    struct stat64 status {};
    if (stat64(path.c_str(), &status) != 0 || status.st_size < 0) return false;
#else
    struct stat status {};
    if (stat(path.c_str(), &status) != 0 || status.st_size < 0) return false;
#endif
    *size = static_cast<uint64_t>(status.st_size);
    return true;
}

bool Seek64(FILE* file, uint64_t position) {
    if (file == nullptr) return false;

#ifdef _WIN32
    if (position >
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        return false;
    }
    return _fseeki64(file, static_cast<int64_t>(position), SEEK_SET) == 0;
#elif defined(__ANDROID__) && !defined(__LP64__)
    off64_t offset = 0;
    if (!CheckedAndroidOffset(position, &offset)) return false;
#if __ANDROID_API__ >= 24
    return fseeko64(file, offset, SEEK_SET) == 0;
#else
    if (fpurge(file) != 0) return false;
    clearerr(file);
    const int descriptor = fileno(file);
    if (descriptor < 0) return false;
    return lseek64(descriptor, offset, SEEK_SET) == offset;
#endif
#else
    constexpr uint64_t max_offset =
        static_cast<uint64_t>(std::numeric_limits<off_t>::max());
    if (position > max_offset) return false;
    return fseeko(file, static_cast<off_t>(position), SEEK_SET) == 0;
#endif
}

size_t ReadAt64(FILE* file, uint64_t position, void* buffer, size_t length) {
    if (file == nullptr || buffer == nullptr || length == 0) return 0;

#if defined(__ANDROID__) && !defined(__LP64__)
    off64_t offset = 0;
    if (!CheckedAndroidOffset(position, &offset)) return 0;
    const int descriptor = fileno(file);
    if (descriptor < 0) return 0;
    const ssize_t read = pread64(descriptor, buffer, length, offset);
    return read > 0 ? static_cast<size_t>(read) : 0;
#else
    if (!Seek64(file, position)) return 0;
    return fread(buffer, 1, length, file);
#endif
}

size_t WriteAt64(FILE* file, uint64_t position, const void* buffer,
                 size_t length) {
    if (file == nullptr || buffer == nullptr || length == 0) return 0;

#if defined(__ANDROID__) && !defined(__LP64__)
    off64_t offset = 0;
    if (!CheckedAndroidOffset(position, &offset)) return 0;
    const int descriptor = fileno(file);
    if (descriptor < 0) return 0;
    const ssize_t written = pwrite64(descriptor, buffer, length, offset);
    return written > 0 ? static_cast<size_t>(written) : 0;
#else
    if (!Seek64(file, position)) return 0;
    return fwrite(buffer, 1, length, file);
#endif
}

bool CheckedEndPosition(uint64_t position, size_t written, uint64_t* end) {
    if (end == nullptr ||
        written > std::numeric_limits<uint64_t>::max() - position) {
        return false;
    }
    *end = position + static_cast<uint64_t>(written);
    return true;
}

bool CheckedWriteRange(uint64_t position, size_t length,
                       uint64_t expected_size, uint64_t* end) {
    return CheckedEndPosition(position, length, end) && *end <= expected_size;
}

bool HasExactFileSize(const std::string& path, uint64_t expected_size) {
    uint64_t actual_size = 0;
    return GetFileSizeUtf8(path, &actual_size) && actual_size == expected_size;
}

std::string TruncateUtf8Filename(const std::string& filename,
                                 size_t max_bytes) {
    const size_t budget = std::min(max_bytes, kMaxFilenameBytes);
    if (filename.size() <= budget) return filename;
    if (budget == 0) return {};

    const size_t extension_start = filename.find_last_of('.');
    if (extension_start != std::string::npos) {
        const std::string extension = filename.substr(extension_start);
        if (extension.size() <= budget) {
            const size_t stem_budget = budget - extension.size();
            const std::string stem = filename.substr(0, extension_start);
            const size_t stem_length = Utf8PrefixLength(stem, stem_budget);
            return stem.substr(0, stem_length) + extension;
        }
    }

    return filename.substr(0, Utf8PrefixLength(filename, budget));
}

std::string ComposeStorageBasename(const std::string& prefix,
                                   const std::string& filename,
                                   size_t max_bytes) {
    const size_t budget = std::min(max_bytes, kMaxFilenameBytes);
    if (prefix.size() >= budget) return prefix.substr(0, budget);
    return prefix + TruncateUtf8Filename(filename, budget - prefix.size());
}

}
