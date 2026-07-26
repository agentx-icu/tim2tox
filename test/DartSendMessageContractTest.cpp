#include "dart_send_message_contract.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

namespace {

TEST(DartSendMessageReturnStorageTest, CallerCopiesBeforeSameThreadOverwrite) {
    const char* first = StoreDartSendMessageReturnId("client-message-1");
    ASSERT_NE(first, nullptr);
    EXPECT_STREQ(first, "client-message-1");

    const std::string copied(first);
    const char* second = StoreDartSendMessageReturnId("client-message-2");

    ASSERT_NE(second, nullptr);
    EXPECT_STREQ(second, "client-message-2");
    EXPECT_EQ(copied, "client-message-1");
}

TEST(DartSendMessageReturnStorageTest, SynchronizedThreadsHaveIsolatedStorage) {
    std::mutex mutex;
    std::condition_variable condition;
    bool first_stored = false;
    bool second_stored = false;
    std::string first_observed;
    std::string second_observed;

    std::thread first_thread([&] {
        const char* stored =
            StoreDartSendMessageReturnId("first-thread-message");
        {
            std::lock_guard<std::mutex> lock(mutex);
            first_stored = true;
        }
        condition.notify_all();

        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [&] { return second_stored; });
        first_observed = stored;
    });

    std::thread second_thread([&] {
        {
            std::unique_lock<std::mutex> lock(mutex);
            condition.wait(lock, [&] { return first_stored; });
        }
        const char* stored =
            StoreDartSendMessageReturnId("second-thread-message");
        second_observed = stored;
        {
            std::lock_guard<std::mutex> lock(mutex);
            second_stored = true;
        }
        condition.notify_all();
    });

    first_thread.join();
    second_thread.join();

    EXPECT_EQ(first_observed, "first-thread-message");
    EXPECT_EQ(second_observed, "second-thread-message");
}

TEST(TerminalCallbackGateTest, ForwardsOnlyFirstSuccessOrErrorAttempt) {
    enum class TerminalResult { kSuccess, kError };

    TerminalCallbackGate gate;
    std::vector<TerminalResult> forwarded;
    const auto attempt = [&](TerminalResult result) {
        if (gate.TryComplete()) {
            forwarded.push_back(result);
        }
    };

    attempt(TerminalResult::kSuccess);
    attempt(TerminalResult::kError);
    attempt(TerminalResult::kSuccess);

    ASSERT_EQ(forwarded.size(), 1U);
    EXPECT_EQ(forwarded.front(), TerminalResult::kSuccess);
    EXPECT_EQ(gate.attempt_count(), 3U);
}

TEST(TerminalCallbackGateTest, FirstErrorSuppressesLaterSuccess) {
    TerminalCallbackGate gate;
    unsigned int forwarded_errors = 0;
    unsigned int forwarded_successes = 0;

    if (gate.TryComplete()) {
        ++forwarded_errors;
    }
    if (gate.TryComplete()) {
        ++forwarded_successes;
    }

    EXPECT_EQ(forwarded_errors, 1U);
    EXPECT_EQ(forwarded_successes, 0U);
    EXPECT_EQ(gate.attempt_count(), 2U);
}

TEST(TerminalCallbackGateTest, ConcurrentAttemptsForwardExactlyOnce) {
    TerminalCallbackGate gate;
    std::atomic<bool> start{false};
    std::atomic<unsigned int> forwarded{0};
    std::vector<std::thread> threads;

    constexpr unsigned int kAttemptCount = 8;
    threads.reserve(kAttemptCount);
    for (unsigned int i = 0; i < kAttemptCount; ++i) {
        threads.emplace_back([&] {
            while (!start.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            if (gate.TryComplete()) {
                forwarded.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }

    start.store(true, std::memory_order_release);
    for (std::thread& thread : threads) {
        thread.join();
    }

    EXPECT_EQ(forwarded.load(std::memory_order_relaxed), 1U);
    EXPECT_EQ(gate.attempt_count(), kAttemptCount);
}

}
