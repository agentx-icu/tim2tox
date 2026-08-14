#include <array>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>

#if !defined(_WIN32)
#include <fcntl.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include <gtest/gtest.h>

#include "V2TIMLog.h"

namespace {

std::filesystem::path MakeLogPath(const char* test_name) {
    const auto suffix = std::chrono::steady_clock::now()
                            .time_since_epoch()
                            .count();
    return std::filesystem::temp_directory_path() /
           (std::string("tim2tox_v2timlog_") + test_name + "_" +
            std::to_string(suffix) + ".log");
}

std::string ReadFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input),
                       std::istreambuf_iterator<char>());
}

template <typename WriteLogs>
std::string CaptureLoggerOutput(const std::filesystem::path& log_path,
                                WriteLogs write_logs) {
    V2TIMLog& logger = V2TIMLog::getInstance();
    logger.setLogLevel(kDebug);
    logger.enableConsoleOutput(true);
    logger.setLogFile(log_path.string());

    testing::internal::CaptureStdout();
    write_logs(logger);
    const std::string console = testing::internal::GetCapturedStdout();

    return console + ReadFile(log_path);
}

void ExpectAbsent(const std::string& output, const std::string& sensitive) {
    EXPECT_EQ(output.find(sensitive), std::string::npos) << sensitive;
}

std::string InvalidLogPathSentinel() {
    return "/dev/null/tim2tox_v2timlog_secret_path.log";
}

#if !defined(_WIN32)

constexpr const char* kInvalidPathChildArg =
    "--tim2tox-v2timlog-invalid-path-child";

struct ChildResult {
    bool timed_out;
    int exit_code;
    std::string output;
};

std::string CurrentExecutablePath() {
#if defined(__APPLE__)
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string path(size, '\0');
    if (_NSGetExecutablePath(path.data(), &size) != 0) {
        return {};
    }
    path.resize(std::char_traits<char>::length(path.c_str()));
    return path;
#else
    std::array<char, 4096> path{};
    const ssize_t length = readlink("/proc/self/exe", path.data(), path.size() - 1);
    if (length <= 0) {
        return {};
    }
    return std::string(path.data(), static_cast<size_t>(length));
#endif
}

void DrainPipe(int pipe_fd, std::string* output) {
    std::array<char, 4096> buffer{};
    for (;;) {
        const ssize_t bytes = read(pipe_fd, buffer.data(), buffer.size());
        if (bytes > 0) {
            output->append(buffer.data(), static_cast<size_t>(bytes));
            continue;
        }
        if (bytes == 0 || errno == EAGAIN || errno == EWOULDBLOCK) {
            return;
        }
        return;
    }
}

ChildResult RunInvalidPathChild(std::chrono::milliseconds timeout) {
    ChildResult result{false, -1, {}};
    const std::string executable = CurrentExecutablePath();
    EXPECT_FALSE(executable.empty());

    int pipe_fds[2] = {-1, -1};
    EXPECT_EQ(pipe(pipe_fds), 0);
    const pid_t child = fork();
    EXPECT_GE(child, 0);
    if (child == 0) {
        close(pipe_fds[0]);
        dup2(pipe_fds[1], STDOUT_FILENO);
        dup2(pipe_fds[1], STDERR_FILENO);
        close(pipe_fds[1]);
        execl(executable.c_str(), executable.c_str(), kInvalidPathChildArg,
              nullptr);
        _exit(127);
    }

    close(pipe_fds[1]);
    fcntl(pipe_fds[0], F_SETFL, fcntl(pipe_fds[0], F_GETFL, 0) | O_NONBLOCK);
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    int status = 0;
    for (;;) {
        DrainPipe(pipe_fds[0], &result.output);
        const pid_t wait_result = waitpid(child, &status, WNOHANG);
        if (wait_result == child) {
            if (WIFEXITED(status)) {
                result.exit_code = WEXITSTATUS(status);
            }
            break;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            result.timed_out = true;
            kill(child, SIGKILL);
            waitpid(child, &status, 0);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    DrainPipe(pipe_fds[0], &result.output);
    close(pipe_fds[0]);
    return result;
}

int RunInvalidPathChildMode() {
    V2TIMLog& logger = V2TIMLog::getInstance();
    logger.setLogLevel(kDebug);
    logger.enableConsoleOutput(false);
    logger.setLogFile(InvalidLogPathSentinel());
    return 0;
}

#endif

}

TEST(V2TIMLogTest, LegacyLogMethodsPreserveLevelWithoutCallerData) {
    const std::filesystem::path log_path = MakeLogPath("legacy");
    const std::string sentinel_tox_id =
        "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
        "0123456789AB";
    ASSERT_EQ(sentinel_tox_id.size(), 76U);
    const std::string payload = "native-log-secret-payload";
    const std::string absolute_path =
        "/Users/bin.gao/chat-uikit/toxee/.slim/worktrees/macos-full-automation/"
        "third_party/tim2tox/source/private_payload.cpp";
    const std::string exception_text =
        "std::runtime_error: account bootstrap payload leaked";
    void* pointer_value = reinterpret_cast<void*>(0x1234abcd);

    const std::string output = CaptureLoggerOutput(
        log_path, [&](V2TIMLog& logger) {
            logger.Debug("debug {} {} {} {} {}", sentinel_tox_id, payload,
                         absolute_path, pointer_value, exception_text);
            logger.Info("info {} {} {} {} {}", sentinel_tox_id, payload,
                        absolute_path, pointer_value, exception_text);
            logger.Warning("warn {} {} {} {} {}", sentinel_tox_id, payload,
                           absolute_path, pointer_value, exception_text);
            logger.Error("error {} {} {} {} {}", sentinel_tox_id, payload,
                         absolute_path, pointer_value, exception_text);
            logger.Fatal("fatal {} {} {} {} {}", sentinel_tox_id, payload,
                         absolute_path, pointer_value, exception_text);
        });

    EXPECT_NE(output.find("[DEBUG]"), std::string::npos);
    EXPECT_NE(output.find("[INFO]"), std::string::npos);
    EXPECT_NE(output.find("[WARN]"), std::string::npos);
    EXPECT_NE(output.find("[ERROR]"), std::string::npos);
    EXPECT_NE(output.find("[FATAL]"), std::string::npos);
    EXPECT_NE(output.find("component=v2tim_log"), std::string::npos);
    EXPECT_NE(output.find("event=legacy_message"), std::string::npos);

    ExpectAbsent(output, sentinel_tox_id);
    ExpectAbsent(output, payload);
    ExpectAbsent(output, absolute_path);
    ExpectAbsent(output, "0x1234abcd");
    ExpectAbsent(output, exception_text);
}

TEST(V2TIMLogTest, TypedDiagnosticEventKeepsStaticMetadataAndIntegerFields) {
    const std::filesystem::path log_path = MakeLogPath("typed");
    const std::array fields = {
        tim2tox::diag::Field::Count(17),
        tim2tox::diag::Field::Length(76),
        tim2tox::diag::Field::Status(-4),
        tim2tox::diag::Field::Bool(true),
        tim2tox::diag::Field::Enum(3),
    };

    const std::string output = CaptureLoggerOutput(
        log_path, [&](V2TIMLog& logger) {
            logger.Info(
                tim2tox::diag::Event<"tox_core", "bootstrap_result">{
                    fields.data(), fields.size()});
        });

    EXPECT_NE(output.find("[INFO]"), std::string::npos);
    EXPECT_NE(output.find("component=tox_core"), std::string::npos);
    EXPECT_NE(output.find("event=bootstrap_result"), std::string::npos);
    EXPECT_NE(output.find("count=17"), std::string::npos);
    EXPECT_NE(output.find("length=76"), std::string::npos);
    EXPECT_NE(output.find("status=-4"), std::string::npos);
    EXPECT_NE(output.find("bool=1"), std::string::npos);
    EXPECT_NE(output.find("enum=3"), std::string::npos);

    ExpectAbsent(output, "path=");
    ExpectAbsent(output, "function=");
    ExpectAbsent(output, "0x");
}

TEST(V2TIMLogTest, FatalStaticLogsOnlyStaticMetadata) {
    const std::filesystem::path log_path = MakeLogPath("fatal_static");

    const std::string output = CaptureLoggerOutput(
        log_path, [](V2TIMLog& logger) {
            logger.FatalStatic<"tox_core", "fatal_boundary">();
        });

    EXPECT_NE(output.find("[FATAL]"), std::string::npos);
    EXPECT_NE(output.find("component=tox_core"), std::string::npos);
    EXPECT_NE(output.find("event=fatal_boundary"), std::string::npos);
    ExpectAbsent(output, "message=");
    ExpectAbsent(output, "0x");
}

#if !defined(_WIN32)
TEST(V2TIMLogTest, InvalidUnopenablePathCompletesWithoutLeakingPath) {
    const ChildResult result = RunInvalidPathChild(std::chrono::seconds(2));
    EXPECT_FALSE(result.timed_out) << result.output;
    EXPECT_EQ(result.exit_code, 0) << result.output;
    EXPECT_NE(result.output.find("[ERROR]"), std::string::npos);
    EXPECT_NE(result.output.find("component=v2tim_log"), std::string::npos);
    EXPECT_NE(result.output.find("event=legacy_message"), std::string::npos);
    ExpectAbsent(result.output, InvalidLogPathSentinel());
    ExpectAbsent(result.output, "Failed to open log file");
}
#endif

int main(int argc, char** argv) {
#if !defined(_WIN32)
    for (int index = 1; index < argc; ++index) {
        if (std::string(argv[index]) == kInvalidPathChildArg) {
            return RunInvalidPathChildMode();
        }
    }
#endif
    testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
