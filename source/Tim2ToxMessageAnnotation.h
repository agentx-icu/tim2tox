#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>

namespace tim2tox::annotation {

inline constexpr size_t kMaxDataBytes = 1200;
inline constexpr size_t kMaxPending = 64;
inline constexpr auto kLifetime = std::chrono::seconds(30);

inline bool HasData(std::string_view data) {
    return !data.empty() && data.size() <= kMaxDataBytes &&
           data.find('\0') == std::string_view::npos;
}

inline void AppendNetworkInteger(std::string& bytes, uint64_t value, size_t length) {
    for (size_t i = length; i > 0; --i) {
        bytes.push_back(static_cast<char>(value >> ((i - 1) * 8)));
    }
}

inline uint64_t ReadNetworkInteger(std::string_view bytes) {
    uint64_t value = 0;
    for (const unsigned char byte : bytes)
        value = (value << 8) | byte;
    return value;
}

inline std::string Begin(uint64_t nonce, uint16_t count) {
    std::string bytes(1, '\x01');
    AppendNetworkInteger(bytes, nonce, 8);
    AppendNetworkInteger(bytes, count, 2);
    return bytes;
}

inline std::string Commit(uint64_t nonce, std::string_view data) {
    std::string bytes(1, '\x02');
    AppendNetworkInteger(bytes, nonce, 8);
    bytes.append(data);
    return bytes;
}

// C2C text and lossless control frames share Tox's ordered receive stream.
// A begin frame reserves a bracket, never an annotation. An incomplete send
// cannot commit and cannot annotate a later identical text. The first row is
// the logical message's annotation target when Tox has split the text.
class FriendBatches {
public:
    using Clock = std::chrono::steady_clock;

    void Start(const std::string& sender, uint64_t nonce, uint16_t count, Clock::time_point now) {
        if (nonce == 0 || count == 0)
            return;
        for (auto it = pending_.begin(); it != pending_.end();) {
            if (it->second.expires <= now)
                it = pending_.erase(it);
            else
                ++it;
        }
        if (pending_.size() >= kMaxPending && !pending_.contains(sender))
            return;
        pending_.insert_or_assign(sender, Batch{nonce, count, true, {}, now + kLifetime});
    }

    // Returns true only for the first text of a live bracket. The caller
    // publishes its receiver-local message id so the eventual update can
    // find exactly that row. An empty id still consumes its position.
    bool Observe(const std::string& sender, std::string_view local_id, Clock::time_point now) {
        auto it = pending_.find(sender);
        if (it == pending_.end())
            return false;
        if (it->second.expires <= now || it->second.remaining == 0) {
            pending_.erase(it);
            return false;
        }
        auto& batch = it->second;
        --batch.remaining;
        if (!batch.first)
            return false;
        batch.first = false;
        batch.local_id = local_id;
        return !batch.local_id.empty();
    }

    std::optional<std::string> Finish(const std::string& sender, uint64_t nonce,
                                      Clock::time_point now) {
        auto it = pending_.find(sender);
        if (it == pending_.end() || it->second.nonce != nonce)
            return std::nullopt;
        auto batch = std::move(it->second);
        pending_.erase(it);
        if (batch.expires <= now || batch.remaining != 0 || batch.local_id.empty()) {
            return std::nullopt;
        }
        return std::move(batch.local_id);
    }

    void Erase(const std::string& sender) {
        pending_.erase(sender);
    }
    void Clear() {
        pending_.clear();
    }

private:
    struct Batch {
        uint64_t nonce;
        uint16_t remaining;
        bool first;
        std::string local_id;
        Clock::time_point expires;
    };
    std::unordered_map<std::string, Batch> pending_;
};

}  // namespace tim2tox::annotation
