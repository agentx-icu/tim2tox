#pragma once

#include <cstdint>
#include <string_view>

namespace tim2tox::event_line {

int64_t ParseInstanceIdFromLine(std::string_view line);

}
