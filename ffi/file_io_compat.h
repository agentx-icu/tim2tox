#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>

namespace tim2tox::file_io {

inline constexpr size_t kMaxFilenameBytes = 255;

FILE* OpenUtf8(const std::string& path, const char* mode);

bool RemoveUtf8(const std::string& path);

bool GetFileSizeUtf8(const std::string& path, uint64_t* size);

bool Seek64(FILE* file, uint64_t position);

size_t ReadAt64(FILE* file, uint64_t position, void* buffer, size_t length);

size_t WriteAt64(FILE* file, uint64_t position, const void* buffer,
                 size_t length);

bool CheckedEndPosition(uint64_t position, size_t written, uint64_t* end);

bool CheckedWriteRange(uint64_t position, size_t length,
                       uint64_t expected_size, uint64_t* end);

bool HasExactFileSize(const std::string& path, uint64_t expected_size);

std::string TruncateUtf8Filename(
    const std::string& filename,
    size_t max_bytes = kMaxFilenameBytes);

std::string ComposeStorageBasename(
    const std::string& prefix,
    const std::string& filename,
    size_t max_bytes = kMaxFilenameBytes);

}
