#ifndef V2TIM_LOG_H
#define V2TIM_LOG_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <memory>
#include <mutex>
#include <cstring>
#include <sstream>
#include <string_view>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

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

    // Legacy-format substitution (2026-09-04). The mix of printf (`%u`,
    // `%zu`, `%s`, `%p`, ...) and fmt (`{}`) placeholders IS substitutable
    // because the argument TYPES are known here: each placeholder — either
    // form, in order — takes the next argument. `%%` stays a literal percent;
    // a placeholder past the last argument is left as written; surplus
    // arguments are appended as ` |extra=...` so nothing is silently lost.
    // Before this, every legacy call printed its placeholders literally
    // ("error: {} ({})") and the values were dropped on the floor.
    //
    // What is rendered follows the logger's no-caller-data contract (the
    // typed diag events carry static metadata + integers ONLY; see
    // V2TIMLogTest): numbers, bools and enums are substituted verbatim
    // (hex for %x/%X/%p, integral promotion for 8-bit values, char for %c);
    // C strings / std::string become `<str:LEN>` ("(null)" for a null C
    // string) and pointers become `<ptr>`. Tox IDs, message payloads, file
    // paths and addresses therefore never reach the log, while status codes,
    // friend/group numbers, sizes and counts — what the diagnostics actually
    // need — do.
    //
    // Never throws (a logger must not turn a diagnostic into a crash on the
    // Tox event thread): any exception while rendering (a user operator<< or
    // allocation failure) degrades to the bare format string.
    template<typename... Args>
    void log(LogLevel level, const char* format, Args&&... args) {
        // Level gate BEFORE any rendering: ~1700 legacy call sites, many on
        // the tox poll path, must cost nothing when suppressed.
        if (level < min_level_.load(std::memory_order_relaxed)) return;
        if (!format) { writeLog(level, "v2tim_log", "legacy_message", nullptr, 0); return; }
        std::string text;
        try {
            std::vector<LegacyArg> rendered;
            rendered.reserve(sizeof...(Args));
            (rendered.push_back(legacyArg(std::forward<Args>(args))), ...);
            text = legacyFormat(format, rendered);
        } catch (...) {
            writeLog(level, "v2tim_log", format, nullptr, 0);
            return;
        }
        writeLog(level, "v2tim_log", text.c_str(), nullptr, 0);
    }

    // A rendered argument plus what it WAS, so %x/%X/%p/%c can re-interpret
    // integral values without sniffing the rendered text (an MSVC pointer
    // renders as bare uppercase hex and could otherwise parse as decimal).
    struct LegacyArg {
        std::string text;
        bool integral = false;       // integral or enum (not bool)
        unsigned long long value = 0; // its magnitude when integral
    };

    template<typename T>
    static LegacyArg legacyArg(T&& value) {
        using U = std::decay_t<T>;
        LegacyArg out;
        if constexpr (std::is_same_v<U, bool>) {
            out.text = value ? "true" : "false";
        } else if constexpr (std::is_same_v<U, char*> || std::is_same_v<U, const char*>) {
            out.text = value ? "<str:" + std::to_string(std::strlen(value)) + ">" : "(null)";
        } else if constexpr (std::is_same_v<U, std::string> || std::is_same_v<U, std::string_view>) {
            out.text = "<str:" + std::to_string(value.size()) + ">";
        } else if constexpr (std::is_enum_v<U>) {
            // Render through the underlying type so signedness (and width) is
            // preserved — an unsigned enumerator above LLONG_MAX must not go
            // through an implementation-defined signed conversion.
            return legacyArg(static_cast<std::underlying_type_t<U>>(value));
        } else if constexpr (std::is_integral_v<U>) {
            // 8-bit types (char, uint8_t) are numbers here, never characters.
            if constexpr (sizeof(U) == 1) out.text = std::to_string(static_cast<int>(value));
            else out.text = std::to_string(value);
            out.integral = true;
            out.value = static_cast<unsigned long long>(value);
            // Hex re-interpretation (%x / {:x}) is width-faithful like printf:
            // an int -1 renders ffffffff, not ffffffffffffffff.
            if constexpr (sizeof(U) < sizeof(unsigned long long)) {
                out.value &= (1ULL << (sizeof(U) * 8)) - 1;
            }
        } else if constexpr (std::is_floating_point_v<U>) {
            std::ostringstream os;
            os << value;
            out.text = os.str();
        } else if constexpr (std::is_null_pointer_v<U>) {
            out.text = "(null)";
        } else if constexpr (std::is_pointer_v<U>) {
            // void*, object, function pointers alike: the address is never logged.
            out.text = value ? "<ptr>" : "(null)";
        } else {
            out.text = "<obj>";  // arbitrary objects are not rendered (contract)
        }
        return out;
    }

    // Render one argument for a fmt `{:spec}` placeholder. Supports the
    // subset the codebase uses: fill/align, sign, `#`, `0`, width, precision
    // (accepted, ignored), and the x/X/c/d presentation types. Unknown types
    // fall back to the plain rendering. `spec` is "" or ":<spec>".
    static std::string legacyFmtSpec(const LegacyArg& a, const std::string& spec) {
        if (spec.empty()) return a.text;
        size_t i = 1;  // skip ':'
        char fill = ' ';
        char align = 0;
        if (i + 1 < spec.size() && std::strchr("<>^", spec[i + 1])) {
            fill = spec[i]; align = spec[i + 1]; i += 2;
        } else if (i < spec.size() && std::strchr("<>^", spec[i])) {
            align = spec[i]; ++i;
        }
        char sign = 0;
        if (i < spec.size() && std::strchr("+- ", spec[i])) sign = spec[i++];
        bool alt = false;
        if (i < spec.size() && spec[i] == '#') { alt = true; ++i; }
        bool zero = false;
        if (i < spec.size() && spec[i] == '0') { zero = true; ++i; }
        size_t width = 0;
        while (i < spec.size() && spec[i] >= '0' && spec[i] <= '9') width = width * 10 + (spec[i++] - '0');
        if (i < spec.size() && spec[i] == '.') {
            ++i;
            while (i < spec.size() && spec[i] >= '0' && spec[i] <= '9') ++i;
        }
        const char type = i < spec.size() ? spec[i] : '\0';
        std::string body;
        if (a.integral && (type == 'x' || type == 'X')) {
            std::ostringstream hex;
            hex << (alt ? (type == 'X' ? "0X" : "0x") : "")
                << (type == 'X' ? std::uppercase : std::nouppercase) << std::hex << a.value;
            body = hex.str();
        } else if (a.integral && type == 'c') {
            body = std::string(1, static_cast<char>(a.value));
        } else {
            body = a.text;
        }
        // `+` / space sign flags apply to numbers that are not negative.
        if (a.integral && (sign == '+' || sign == ' ') &&
            (body.empty() || body[0] != '-')) {
            body.insert(0, 1, sign);
        }
        if (body.size() < width) {
            const size_t pad = width - body.size();
            if (zero && a.integral && align == 0) {
                // Zero padding goes after a sign / 0x prefix, like fmt.
                size_t at = (!body.empty() && (body[0] == '-' || body[0] == '+' || body[0] == ' ')) ? 1 : 0;
                if (body.compare(at, 2, "0x") == 0 || body.compare(at, 2, "0X") == 0) at += 2;
                body.insert(at, pad, '0');
            } else if (align == '<' || (align == 0 && !a.integral)) {
                body.append(pad, fill);
            } else if (align == '^') {
                body.insert(0, pad / 2, fill);
                body.append(pad - pad / 2, fill);
            } else {
                body.insert(0, pad, fill);  // numbers right-align by default
            }
        }
        return body;
    }

    static std::string legacyFormat(const char* format,
                                    const std::vector<LegacyArg>& args) {
        std::string out;
        size_t next = 0;
        for (const char* p = format; *p; ++p) {
            if (*p == '{') {
                // fmt placeholder: `{}` or `{:spec}` (e.g. `{:02x}`, `{:>4}`);
                // `{{` is a literal brace. A spec'd placeholder MUST consume an
                // argument too, or every later `{}` shifts onto the wrong value.
                if (p[1] == '{') { out += '{'; ++p; continue; }
                const char* close = p + 1;
                if (*close == ':') {
                    while (*close && *close != '}' && *close != '{') ++close;
                }
                if (*close == '}') {
                    if (next < args.size()) {
                        out += legacyFmtSpec(args[next++], std::string(p + 1, close));
                    } else {
                        out.append(p, close - p + 1);
                    }
                    p = close;
                    continue;
                }
                if (p[1] == ':') {
                    // Unterminated spec: keep the scanned text verbatim (a `%d`
                    // inside it is not a printf placeholder) and resume after it.
                    out.append(p, close - p);
                    p = close - 1;
                    continue;
                }
            }
            if (*p != '%') { out += *p; continue; }
            if (p[1] == '%') { out += '%'; ++p; continue; }
            // printf spec: flags/width/precision/length, then a conversion char.
            const char* q = p + 1;
            while (*q && std::strchr("-+ #0123456789.lhzjtL", *q)) ++q;
            if (*q && std::strchr("diuxXoscpfFeEgGaA", *q)) {
                if (next < args.size()) {
                    const LegacyArg& a = args[next++];
                    if (a.integral && (*q == 'x' || *q == 'X' || *q == 'p')) {
                        std::ostringstream hex;  // never throws: value is numeric
                        hex << (*q == 'p' ? "0x" : "")
                            << (*q == 'X' ? std::uppercase : std::nouppercase)
                            << std::hex << a.value;
                        out += hex.str();
                    } else if (a.integral && *q == 'c') {
                        out += static_cast<char>(a.value);
                    } else {
                        out += a.text;
                    }
                } else {
                    out.append(p, q - p + 1);
                }
                p = q;
                continue;
            }
            out += *p;
        }
        for (; next < args.size(); ++next) out += " |extra=" + args[next].text;
        return out;
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
    std::atomic<LogLevel> min_level_;
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
