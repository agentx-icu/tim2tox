#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "toxcore/tox.h"

namespace tim2tox::qtox {

inline constexpr std::size_t kMessagePayloadLimit =
    TOX_MAX_MESSAGE_LENGTH - 50;

struct PreparedTextMessage {
    TOX_MESSAGE_TYPE type;
    std::string body;
};

std::optional<PreparedTextMessage> PrepareTextMessage(
    std::string_view text,
    bool force_action);

std::optional<std::vector<std::string>> FragmentMessage(
    std::string_view text);

}
