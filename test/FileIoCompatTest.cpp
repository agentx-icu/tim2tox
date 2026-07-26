#include "../ffi/file_io_compat.h"

#include <gtest/gtest.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <limits>
#include <memory>
#include <string>

namespace {

using FilePtr = std::unique_ptr<FILE, decltype(&std::fclose)>;

class TempPath {
public:
    explicit TempPath(const std::string& suffix = {}) {
        const auto stamp = std::chrono::steady_clock::now()
                               .time_since_epoch()
                               .count();
        const auto temp_path =
            std::filesystem::temp_directory_path().u8string();
        path_.assign(reinterpret_cast<const char*>(temp_path.data()),
                     temp_path.size());
#ifdef _WIN32
        path_.push_back('\\');
#else
        path_.push_back('/');
#endif
        path_ += "tim2tox_file_io_" + std::to_string(stamp) + suffix;
    }

    ~TempPath() { tim2tox::file_io::RemoveUtf8(path_); }

    const std::string& value() const { return path_; }

private:
    std::string path_;
};

bool IsValidUtf8(const std::string& value) {
    size_t index = 0;
    while (index < value.size()) {
        const auto first = static_cast<unsigned char>(value[index]);
        size_t length = 0;
        if (first <= 0x7f) {
            length = 1;
        } else if (first >= 0xc2 && first <= 0xdf) {
            length = 2;
        } else if (first >= 0xe0 && first <= 0xef) {
            length = 3;
        } else if (first >= 0xf0 && first <= 0xf4) {
            length = 4;
        } else {
            return false;
        }

        if (index + length > value.size()) return false;
        for (size_t offset = 1; offset < length; ++offset) {
            const auto next = static_cast<unsigned char>(value[index + offset]);
            if ((next & 0xc0) != 0x80) return false;
        }

        if (length == 3) {
            const auto second = static_cast<unsigned char>(value[index + 1]);
            if ((first == 0xe0 && second < 0xa0) ||
                (first == 0xed && second >= 0xa0)) {
                return false;
            }
        } else if (length == 4) {
            const auto second = static_cast<unsigned char>(value[index + 1]);
            if ((first == 0xf0 && second < 0x90) ||
                (first == 0xf4 && second >= 0x90)) {
                return false;
            }
        }
        index += length;
    }
    return true;
}

TEST(FileIoCompatTest, SeeksWritesAndReadsBeyondInt32Max) {
    FilePtr file(std::tmpfile(), &std::fclose);
    ASSERT_NE(file, nullptr);

    constexpr uint64_t position =
        static_cast<uint64_t>(std::numeric_limits<int32_t>::max()) + 4096;
    constexpr unsigned char marker = 0xa5;
    ASSERT_TRUE(tim2tox::file_io::Seek64(file.get(), position));
    ASSERT_EQ(std::fwrite(&marker, 1, 1, file.get()), 1u);
    ASSERT_EQ(std::fflush(file.get()), 0);

    ASSERT_TRUE(tim2tox::file_io::Seek64(file.get(), position));
    unsigned char actual = 0;
    ASSERT_EQ(std::fread(&actual, 1, 1, file.get()), 1u);
    EXPECT_EQ(actual, marker);
}

TEST(FileIoCompatTest, RejectsOffsetsOutsidePlatformRange) {
    FilePtr file(std::tmpfile(), &std::fclose);
    ASSERT_NE(file, nullptr);

    EXPECT_FALSE(tim2tox::file_io::Seek64(
        file.get(), std::numeric_limits<uint64_t>::max()));
}

TEST(FileIoCompatTest, PositionallyWritesAndReadsBeyondInt32Max) {
    FilePtr file(std::tmpfile(), &std::fclose);
    ASSERT_NE(file, nullptr);

    constexpr uint64_t position =
        static_cast<uint64_t>(std::numeric_limits<int32_t>::max()) + 8192;
    const std::string expected = "sparse-data";
    ASSERT_EQ(tim2tox::file_io::WriteAt64(
                  file.get(), position, expected.data(), expected.size()),
              expected.size());

    std::string actual(expected.size(), '\0');
    ASSERT_EQ(tim2tox::file_io::ReadAt64(
                  file.get(), position, actual.data(), actual.size()),
              actual.size());
    EXPECT_EQ(actual, expected);
}

TEST(FileIoCompatTest, PositionalIoHandlesPartialAndInvalidRequests) {
    FilePtr file(std::tmpfile(), &std::fclose);
    ASSERT_NE(file, nullptr);

    const std::string expected = "abc";
    ASSERT_EQ(tim2tox::file_io::WriteAt64(
                  file.get(), 0, expected.data(), expected.size()),
              expected.size());

    char buffer[8] = {};
    EXPECT_EQ(tim2tox::file_io::ReadAt64(file.get(), 0, buffer,
                                         sizeof(buffer)),
              expected.size());
    EXPECT_EQ(std::string(buffer, expected.size()), expected);
    EXPECT_EQ(tim2tox::file_io::ReadAt64(nullptr, 0, buffer, sizeof(buffer)),
              0u);
    EXPECT_EQ(tim2tox::file_io::WriteAt64(nullptr, 0, buffer, sizeof(buffer)),
              0u);
    EXPECT_EQ(tim2tox::file_io::ReadAt64(file.get(), 0, nullptr, 1), 0u);
    EXPECT_EQ(tim2tox::file_io::WriteAt64(file.get(), 0, nullptr, 1), 0u);
    EXPECT_EQ(tim2tox::file_io::ReadAt64(file.get(), 0, nullptr, 0), 0u);
    EXPECT_EQ(tim2tox::file_io::WriteAt64(file.get(), 0, nullptr, 0), 0u);
    EXPECT_EQ(tim2tox::file_io::ReadAt64(
                  file.get(), std::numeric_limits<uint64_t>::max(), buffer, 1),
              0u);
    EXPECT_EQ(tim2tox::file_io::WriteAt64(
                  file.get(), std::numeric_limits<uint64_t>::max(), buffer, 1),
              0u);
}

TEST(FileIoCompatTest, ComputesEndFromActualWrittenBytes) {
    uint64_t end = 0;
    EXPECT_TRUE(tim2tox::file_io::CheckedEndPosition(100, 3, &end));
    EXPECT_EQ(end, 103u);
    EXPECT_FALSE(tim2tox::file_io::CheckedEndPosition(
        std::numeric_limits<uint64_t>::max(), 1, &end));
    EXPECT_FALSE(tim2tox::file_io::CheckedEndPosition(0, 1, nullptr));
}

TEST(FileIoCompatTest, ValidatesRequestedWriteRangeAgainstAdvertisedSize) {
    uint64_t end = 0;
    EXPECT_TRUE(tim2tox::file_io::CheckedWriteRange(7, 3, 10, &end));
    EXPECT_EQ(end, 10u);
    EXPECT_FALSE(tim2tox::file_io::CheckedWriteRange(7, 4, 10, &end));
    EXPECT_FALSE(tim2tox::file_io::CheckedWriteRange(
        std::numeric_limits<uint64_t>::max(), 1,
        std::numeric_limits<uint64_t>::max(), &end));
    EXPECT_FALSE(tim2tox::file_io::CheckedWriteRange(0, 1, 1, nullptr));
}

TEST(FileIoCompatTest, RecognizesExactAndShortSparseFileSizes) {
    TempPath path;
    constexpr uint64_t position =
        static_cast<uint64_t>(std::numeric_limits<int32_t>::max()) + 16384;
    constexpr unsigned char marker = 0x5a;
    {
        FilePtr file(std::fopen(path.value().c_str(), "w+b"), &std::fclose);
        ASSERT_NE(file, nullptr);
        ASSERT_EQ(tim2tox::file_io::WriteAt64(
                      file.get(), position, &marker, sizeof(marker)),
                  sizeof(marker));
        ASSERT_EQ(std::fflush(file.get()), 0);
    }

    EXPECT_TRUE(tim2tox::file_io::HasExactFileSize(path.value(),
                                                   position + 1));
    EXPECT_FALSE(tim2tox::file_io::HasExactFileSize(path.value(),
                                                    position + 2));
    EXPECT_FALSE(tim2tox::file_io::HasExactFileSize(path.value() + ".missing",
                                                    0));
}

TEST(FileIoCompatTest, OpensStatsAndRemovesUtf8Path) {
    TempPath path("_文件😀.bin");
    constexpr unsigned char payload[] = {0x10, 0x20, 0x30, 0x40};
    {
        FilePtr file(tim2tox::file_io::OpenUtf8(path.value(), "wb"),
                     &std::fclose);
        ASSERT_NE(file, nullptr);
        ASSERT_EQ(std::fwrite(payload, 1, sizeof(payload), file.get()),
                  sizeof(payload));
        ASSERT_EQ(std::fflush(file.get()), 0);
    }

    EXPECT_TRUE(
        tim2tox::file_io::HasExactFileSize(path.value(), sizeof(payload)));
    uint64_t file_size = 0;
    EXPECT_TRUE(tim2tox::file_io::GetFileSizeUtf8(path.value(), &file_size));
    EXPECT_EQ(file_size, sizeof(payload));
    EXPECT_TRUE(tim2tox::file_io::RemoveUtf8(path.value()));
    EXPECT_FALSE(tim2tox::file_io::HasExactFileSize(path.value(),
                                                    sizeof(payload)));
}

#ifdef _WIN32
TEST(FileIoCompatTest, RejectsInvalidUtf8WindowsPath) {
    const std::string invalid_utf8("\xc3\x28", 2);
    EXPECT_EQ(tim2tox::file_io::OpenUtf8(invalid_utf8, "wb"), nullptr);
    uint64_t file_size = 0;
    EXPECT_FALSE(
        tim2tox::file_io::GetFileSizeUtf8(invalid_utf8, &file_size));
    EXPECT_FALSE(tim2tox::file_io::HasExactFileSize(invalid_utf8, 0));
    EXPECT_FALSE(tim2tox::file_io::RemoveUtf8(invalid_utf8));
}
#endif

TEST(FileIoCompatTest, TruncatesLongAsciiNameAndPreservesExtension) {
    const std::string name = std::string(300, 'a') + ".png";
    const std::string expected = std::string(251, 'a') + ".png";

    const std::string result = tim2tox::file_io::TruncateUtf8Filename(name);

    EXPECT_EQ(result, expected);
    EXPECT_LE(result.size(), 255u);
    EXPECT_TRUE(IsValidUtf8(result));
}

TEST(FileIoCompatTest, TruncatesCjkAndEmojiWithoutSplittingCodePoints) {
    const std::string name = "报告😀报告😀.txt";

    const std::string result =
        tim2tox::file_io::TruncateUtf8Filename(name, 17);

    EXPECT_EQ(result, "报告😀报.txt");
    EXPECT_LE(result.size(), 17u);
    EXPECT_TRUE(IsValidUtf8(result));
}

TEST(FileIoCompatTest, LeavesExactBoundaryNameUnchanged) {
    const std::string name = std::string(251, 'b') + ".txt";

    ASSERT_EQ(name.size(), 255u);
    EXPECT_EQ(tim2tox::file_io::TruncateUtf8Filename(name), name);
}

TEST(FileIoCompatTest, HandlesExtensionOnlyAndPathologicalBudgets) {
    EXPECT_EQ(tim2tox::file_io::TruncateUtf8Filename("report.txt", 4),
              ".txt");
    EXPECT_EQ(tim2tox::file_io::TruncateUtf8Filename(".config", 3),
              ".co");
    EXPECT_EQ(tim2tox::file_io::TruncateUtf8Filename("report.txt", 0),
              "");
}

TEST(FileIoCompatTest, ComposesBoundedStorageBasename) {
    const std::string prefix(64, 'A');
    std::string filename;
    for (int index = 0; index < 80; ++index) filename += "文件😀";
    filename += ".png";

    const std::string result =
        tim2tox::file_io::ComposeStorageBasename(prefix, filename);

    EXPECT_LE(result.size(), 255u);
    EXPECT_EQ(result.substr(0, prefix.size()), prefix);
    EXPECT_EQ(result.substr(result.size() - 4), ".png");
    EXPECT_TRUE(IsValidUtf8(result));
}

TEST(FileIoCompatTest, LeavesShortStorageBasenameUnchanged) {
    const std::string prefix = std::string(64, 'B') + "_1_2_";
    const std::string filename = "文件😀.png";

    EXPECT_EQ(tim2tox::file_io::ComposeStorageBasename(prefix, filename),
              prefix + filename);
}

}
