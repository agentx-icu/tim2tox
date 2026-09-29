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

// ---- Receiving under low storage (checklist M5) ----------------------------

// Free space kept for everything else (history, prefs, logs) when deciding
// whether an incoming file fits.
inline constexpr uint64_t kReceiveReserveBytes = 16ULL * 1024ULL * 1024ULL;

// Sidecar that marks a receive file as "not finalized yet":
//   <dir>/.<data basename>.t2t-receiving
// Storage basenames start with the sender's hex key, never with '.', so a
// marker can never be confused with a received file — even one whose own name
// ends in the suffix.
inline constexpr const char* kReceiveMarkerSuffix = ".t2t-receiving";

// True iff an incoming file of `size` bytes fits in `available` bytes while
// keeping `reserve` free. Overflow-safe.
bool HasRoomForReceive(uint64_t available, uint64_t size, uint64_t reserve);

// errno of a failed write -> the reason sent to Dart: "no_space" for
// ENOSPC / EDQUOT (disk or quota full), "io" otherwise.
const char* ClassifyWriteErrno(int err);
bool IsNoSpaceErrno(int err);

// "<dir>/.<basename>.t2t-receiving" for data file "<dir>/<basename>".
std::string ReceiveMarkerPath(const std::string& data_path);

// If `name` is a receive marker basename (".<data>.t2t-receiving"), the data
// file basename it guards; otherwise empty.
std::string DataNameForMarker(const std::string& name);

// Available bytes on the volume holding `dir`; false when unknown.
bool AvailableBytes(const std::string& dir, uint64_t* available);

}
