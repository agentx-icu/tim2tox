#include "event_line_parser.h"

#include <array>
#include <charconv>
#include <system_error>

namespace tim2tox::event_line {
namespace {

constexpr std::array<std::string_view, 3> kRoutedPrefixes = {
    "progress_recv:",
    "file_done:",
    "file_request:",
};

}

int64_t ParseInstanceIdFromLine(std::string_view line) {
    std::string_view id_text;
    bool recognized = false;
    for (const std::string_view prefix : kRoutedPrefixes) {
        if (line.size() < prefix.size() ||
            line.compare(0, prefix.size(), prefix) != 0) {
            continue;
        }
        const size_t delimiter = line.find(':', prefix.size());
        if (delimiter == std::string_view::npos) return 0;
        id_text = line.substr(prefix.size(), delimiter - prefix.size());
        recognized = true;
        break;
    }

    if (!recognized || id_text.empty() || id_text.front() < '0' ||
        id_text.front() > '9') {
        return 0;
    }

    int64_t instance_id = 0;
    const char* const begin = id_text.data();
    const char* const end = begin + id_text.size();
    const auto result = std::from_chars(begin, end, instance_id, 10);
    if (result.ec != std::errc{} || result.ptr != end || instance_id <= 0) {
        return 0;
    }
    return instance_id;
}

}
