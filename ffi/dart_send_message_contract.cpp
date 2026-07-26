#include "dart_send_message_contract.h"

#include <utility>

const char* StoreDartSendMessageReturnId(std::string message_id) {
    thread_local std::string stored_message_id;
    stored_message_id = std::move(message_id);
    return stored_message_id.c_str();
}

bool TerminalCallbackGate::TryComplete() noexcept {
    return attempt_count_.fetch_add(1, std::memory_order_acq_rel) == 0;
}

std::uint32_t TerminalCallbackGate::attempt_count() const noexcept {
    return attempt_count_.load(std::memory_order_acquire);
}
