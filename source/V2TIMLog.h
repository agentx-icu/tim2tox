#ifndef V2TIM_LOG_H
#define V2TIM_LOG_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>

// Define log levels
enum class LogLevel {
    DEBUG,
    INFO,
    WARNING,
    ERROR,
    FATAL
};

// Use specific log level constants for clarity in calls
constexpr LogLevel kDebug = LogLevel::DEBUG;
constexpr LogLevel kInfo = LogLevel::INFO;
constexpr LogLevel kWarning = LogLevel::WARNING;
constexpr LogLevel kError = LogLevel::ERROR;
constexpr LogLevel kFatal = LogLevel::FATAL;

namespace tim2tox::diag {

enum class FieldKind {
    Count,
    Length,
    Status,
    Bool,
    Enum,
};

template <size_t Size>
struct StaticText {
    char value[Size];

    consteval StaticText(const char (&literal)[Size]) : value{} {
        if (literal[Size - 1] != '\0') {
            throw "diagnostic labels must be null-terminated string literals";
        }
        for (size_t index = 0; index < Size; ++index) {
            value[index] = literal[index];
        }
    }
};

struct Field {
    FieldKind kind;
    int64_t value;

    static constexpr Field Count(int64_t value) {
        return Field{FieldKind::Count, value};
    }

    static constexpr Field Length(int64_t value) {
        return Field{FieldKind::Length, value};
    }

    static constexpr Field Status(int64_t value) {
        return Field{FieldKind::Status, value};
    }

    static constexpr Field Bool(bool value) {
        return Field{FieldKind::Bool, value ? 1 : 0};
    }

    static constexpr Field Enum(int64_t value) {
        return Field{FieldKind::Enum, value};
    }
};

template <StaticText Component, StaticText EventName>
struct Event {
    const Field* fields;
    size_t field_count;

    constexpr Event(const Field* event_fields = nullptr,
                    size_t event_field_count = 0)
        : fields(event_fields),
          field_count(event_field_count) {}
};

}

// Singleton Logger Class
class V2TIMLog {
public:
    static V2TIMLog& getInstance();

    // Configuration methods
    void setLogFile(const std::string& path);
    void setLogLevel(LogLevel level);
    void enableConsoleOutput(bool enable);

    // Logging methods using variadic templates
    template<typename... Args>
    void Debug(const char* format, Args&&... args) {
        log(LogLevel::DEBUG, format, args...);
    }

    template<typename... Args>
    void Info(const char* format, Args&&... args) {
        log(LogLevel::INFO, format, args...);
    }

    template<typename... Args>
    void Warning(const char* format, Args&&... args) {
        log(LogLevel::WARNING, format, args...);
    }

    template<typename... Args>
    void Error(const char* format, Args&&... args) {
        log(LogLevel::ERROR, format, args...);
    }

    template<typename... Args>
    void Fatal(const char* format, Args&&... args) {
        log(LogLevel::FATAL, format, args...);
    }

    template <tim2tox::diag::StaticText Component, tim2tox::diag::StaticText EventName>
    void Debug(const tim2tox::diag::Event<Component, EventName>& event) {
        log(LogLevel::DEBUG, event);
    }

    template <tim2tox::diag::StaticText Component, tim2tox::diag::StaticText EventName>
    void Info(const tim2tox::diag::Event<Component, EventName>& event) {
        log(LogLevel::INFO, event);
    }

    template <tim2tox::diag::StaticText Component, tim2tox::diag::StaticText EventName>
    void Warning(const tim2tox::diag::Event<Component, EventName>& event) {
        log(LogLevel::WARNING, event);
    }

    template <tim2tox::diag::StaticText Component, tim2tox::diag::StaticText EventName>
    void Error(const tim2tox::diag::Event<Component, EventName>& event) {
        log(LogLevel::ERROR, event);
    }

    template <tim2tox::diag::StaticText Component, tim2tox::diag::StaticText EventName>
    void Fatal(const tim2tox::diag::Event<Component, EventName>& event) {
        log(LogLevel::FATAL, event);
    }

    template <tim2tox::diag::StaticText Component, tim2tox::diag::StaticText EventName>
    void FatalStatic() {
        log(LogLevel::FATAL, tim2tox::diag::Event<Component, EventName>{});
    }

    // Make log method public so it can be called via the macro
    //
    // Legacy printf/fmt-style call sites (`V2TIM_LOG(kInfo, "text %u", x)`).
    // The variadic ARGUMENTS are still dropped: the codebase mixes printf
    // (`%u`) and fmt (`{}`) placeholders in the same macro, so there is no one
    // safe way to substitute them here. The FORMAT STRING is now forwarded as
    // the event name instead of the constant "legacy_message" — that alone
    // turns several hundred previously indistinguishable records into
    // identifiable ones, which is what makes C++ control flow observable at
    // all. Before this, every legacy call emitted a byte-identical
    // content-free line, so no amount of log reading could tell which branch
    // ran.
    template<typename... Args>
    void log(LogLevel level, const char* format, Args&&...) {
        writeLog(level, "v2tim_log", format ? format : "legacy_message",
                 nullptr, 0);
    }

    template <tim2tox::diag::StaticText Component, tim2tox::diag::StaticText EventName>
    void log(LogLevel level,
             const tim2tox::diag::Event<Component, EventName>& event) {
        writeLog(level, Component.value, EventName.value, event.fields,
                 event.field_count);
    }

private:
    // Private constructor/destructor for singleton
    V2TIMLog();
    ~V2TIMLog();

    // Disable copy/move semantics
    V2TIMLog(const V2TIMLog&) = delete;
    V2TIMLog& operator=(const V2TIMLog&) = delete;
    V2TIMLog(V2TIMLog&&) = delete;
    V2TIMLog& operator=(V2TIMLog&&) = delete;

    void writeLog(LogLevel level, const char* component, const char* event,
                  const tim2tox::diag::Field* fields, size_t field_count);
    const char* getLevelString(LogLevel level);
    const char* getFieldString(tim2tox::diag::FieldKind kind);

    // Member variables
    std::unique_ptr<std::ofstream> log_file_;
    LogLevel min_level_;
    bool console_output_;
    std::mutex mutex_;
    std::atomic<bool> destroyed_;
};

#define V2TIM_LOG(level, ...) \
    do { \
        if (level == kDebug) V2TIMLog::getInstance().Debug(__VA_ARGS__); \
        else if (level == kInfo) V2TIMLog::getInstance().Info(__VA_ARGS__); \
        else if (level == kWarning) V2TIMLog::getInstance().Warning(__VA_ARGS__); \
        else if (level == kError) V2TIMLog::getInstance().Error(__VA_ARGS__); \
        else if (level == kFatal) V2TIMLog::getInstance().Fatal(__VA_ARGS__); \
    } while(0)


#endif // V2TIM_LOG_H
