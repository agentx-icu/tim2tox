#include "QToxMessageFragmenter.h"

#include <algorithm>
#include <cstdint>

namespace tim2tox::qtox {
namespace {

bool IsContinuation(uint8_t value) {
    return (value & 0xC0U) == 0x80U;
}

bool HasContinuationBytes(
    std::string_view text,
    std::size_t offset,
    std::size_t count) {
    if (offset + count > text.size()) {
        return false;
    }
    for (std::size_t i = 0; i < count; ++i) {
        if (!IsContinuation(static_cast<uint8_t>(text[offset + i]))) {
            return false;
        }
    }
    return true;
}

bool IsValidUtf8(std::string_view text) {
    for (std::size_t i = 0; i < text.size();) {
        const uint8_t lead = static_cast<uint8_t>(text[i]);
        if (lead <= 0x7FU) {
            ++i;
            continue;
        }
        if (lead >= 0xC2U && lead <= 0xDFU) {
            if (!HasContinuationBytes(text, i + 1, 1)) return false;
            i += 2;
            continue;
        }
        if (lead >= 0xE0U && lead <= 0xEFU) {
            if (!HasContinuationBytes(text, i + 1, 2)) return false;
            const uint8_t second = static_cast<uint8_t>(text[i + 1]);
            if ((lead == 0xE0U && second < 0xA0U) ||
                (lead == 0xEDU && second > 0x9FU)) {
                return false;
            }
            i += 3;
            continue;
        }
        if (lead >= 0xF0U && lead <= 0xF4U) {
            if (!HasContinuationBytes(text, i + 1, 3)) return false;
            const uint8_t second = static_cast<uint8_t>(text[i + 1]);
            if ((lead == 0xF0U && second < 0x90U) ||
                (lead == 0xF4U && second > 0x8FU)) {
                return false;
            }
            i += 4;
            continue;
        }
        return false;
    }
    return true;
}

bool IsAsciiCaseEqual(char value, char lowercase) {
    return value == lowercase || value == lowercase - ('a' - 'A');
}

bool HasMePrefix(std::string_view text) {
    return text.size() >= 4 && text[0] == '/' &&
           IsAsciiCaseEqual(text[1], 'm') &&
           IsAsciiCaseEqual(text[2], 'e') && text[3] == ' ';
}

std::size_t FindPreferredSplit(
    std::string_view text,
    std::size_t offset,
    std::size_t budget_end) {
    for (std::size_t i = budget_end; i > offset; --i) {
        if (text[i - 1] == '\n') return i;
    }
    for (std::size_t i = budget_end; i > offset; --i) {
        if (text[i - 1] == ' ' || text[i - 1] == '\t') return i;
    }
    std::size_t split = budget_end;
    while (split > offset && split < text.size() &&
           IsContinuation(static_cast<uint8_t>(text[split]))) {
        --split;
    }
    return split;
}

bool IsValidInput(std::string_view text) {
    return !text.empty() && text.find('\0') == std::string_view::npos &&
           IsValidUtf8(text);
}

}

std::optional<PreparedTextMessage> PrepareTextMessage(
    std::string_view text,
    bool force_action) {
    if (!IsValidInput(text)) return std::nullopt;

    const bool has_me_prefix = HasMePrefix(text);
    const std::string_view body = has_me_prefix ? text.substr(4) : text;
    if (body.empty()) return std::nullopt;

    return PreparedTextMessage{
        force_action || has_me_prefix ? TOX_MESSAGE_TYPE_ACTION
                                      : TOX_MESSAGE_TYPE_NORMAL,
        std::string(body)};
}

std::optional<std::vector<std::string>> FragmentMessage(
    std::string_view text) {
    if (!IsValidInput(text)) return std::nullopt;

    std::vector<std::string> fragments;
    fragments.reserve((text.size() + kMessagePayloadLimit - 1) /
                      kMessagePayloadLimit);
    std::size_t offset = 0;
    while (text.size() - offset > kMessagePayloadLimit) {
        const std::size_t budget_end = offset + kMessagePayloadLimit;
        const std::size_t split = FindPreferredSplit(text, offset, budget_end);
        if (split <= offset) return std::nullopt;
        fragments.emplace_back(text.substr(offset, split - offset));
        offset = split;
    }
    if (offset < text.size()) {
        fragments.emplace_back(text.substr(offset));
    }
    if (fragments.empty() ||
        std::any_of(fragments.begin(), fragments.end(),
                    [](const std::string& fragment) {
                        return fragment.empty();
                    })) {
        return std::nullopt;
    }
    return fragments;
}

}
