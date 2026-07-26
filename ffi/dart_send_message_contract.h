#pragma once

#include <atomic>
#include <cstdint>
#include <string>

// Returns a C-owned, non-freeable pointer valid until the next same-thread
// StoreDartSendMessageReturnId call or until that thread exits.
const char* StoreDartSendMessageReturnId(std::string message_id);

class TerminalCallbackGate {
public:
    bool TryComplete() noexcept;
    std::uint32_t attempt_count() const noexcept;

private:
    std::atomic<std::uint32_t> attempt_count_{0};
};
