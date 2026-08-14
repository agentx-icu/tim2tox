#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#ifndef TIM2TOX_SOURCE_DIR
#error "TIM2TOX_SOURCE_DIR must point to the source directory"
#endif

#ifndef TIM2TOX_FFI_DIR
#error "TIM2TOX_FFI_DIR must point to the ffi directory"
#endif

#ifndef TIM2TOX_LOG_HEADER_PATH
#error "TIM2TOX_LOG_HEADER_PATH must point to source/V2TIMLog.h"
#endif

#ifndef TIM2TOX_LOG_SOURCE_PATH
#error "TIM2TOX_LOG_SOURCE_PATH must point to source/V2TIMLog.cpp"
#endif

namespace {

struct Finding {
    std::string file;
    int line;
    std::string token;
    std::string text;
};

std::string ReadSource(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    EXPECT_TRUE(input.good()) << path;
    return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

bool IsProductionSourceExtension(const std::filesystem::path& path) {
    static constexpr std::array<std::string_view, 17> kExtensions = {
        ".c",   ".cc",  ".cp",  ".cpp", ".cxx", ".c++", ".h", ".hh", ".hpp",
        ".hxx", ".h++", ".inc", ".inl", ".ipp", ".tpp", ".m", ".mm"};
    std::string extension = path.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   [](unsigned char value) { return static_cast<char>(std::tolower(value)); });
    return std::find(kExtensions.begin(), kExtensions.end(), extension) != kExtensions.end();
}

std::vector<std::filesystem::path> ProductionSourceFiles(const std::filesystem::path& directory) {
    std::vector<std::filesystem::path> files;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(
             directory, std::filesystem::directory_options::skip_permission_denied)) {
        if (entry.is_regular_file() && IsProductionSourceExtension(entry.path())) {
            files.push_back(entry.path());
        }
    }
    std::sort(files.begin(), files.end());
    return files;
}

bool IsIdentifierChar(char value) {
    return std::isalnum(static_cast<unsigned char>(value)) || value == '_';
}

std::string StripCommentsAndStrings(std::string_view source) {
    std::string stripped(source);
    enum class State { Normal, LineComment, BlockComment, String, Char };
    State state = State::Normal;
    bool escaped = false;

    for (size_t index = 0; index < source.size(); ++index) {
        const char current = source[index];
        const char next = index + 1 < source.size() ? source[index + 1] : '\0';
        switch (state) {
            case State::Normal:
                if (current == '/' && next == '/') {
                    stripped[index] = ' ';
                    stripped[index + 1] = ' ';
                    ++index;
                    state = State::LineComment;
                } else if (current == '/' && next == '*') {
                    stripped[index] = ' ';
                    stripped[index + 1] = ' ';
                    ++index;
                    state = State::BlockComment;
                } else if (current == '"') {
                    stripped[index] = ' ';
                    escaped = false;
                    state = State::String;
                } else if (current == '\'') {
                    stripped[index] = ' ';
                    escaped = false;
                    state = State::Char;
                }
                break;
            case State::LineComment:
                if (current == '\n') {
                    state = State::Normal;
                } else {
                    stripped[index] = ' ';
                }
                break;
            case State::BlockComment:
                if (current == '*' && next == '/') {
                    stripped[index] = ' ';
                    stripped[index + 1] = ' ';
                    ++index;
                    state = State::Normal;
                } else if (current != '\n') {
                    stripped[index] = ' ';
                }
                break;
            case State::String:
                if (current != '\n') {
                    stripped[index] = ' ';
                }
                if (current == '"' && !escaped) {
                    state = State::Normal;
                }
                escaped = current == '\\' && !escaped;
                if (current != '\\') {
                    escaped = false;
                }
                break;
            case State::Char:
                if (current != '\n') {
                    stripped[index] = ' ';
                }
                if (current == '\'' && !escaped) {
                    state = State::Normal;
                }
                escaped = current == '\\' && !escaped;
                if (current != '\\') {
                    escaped = false;
                }
                break;
        }
    }

    return stripped;
}

size_t NextNonSpace(std::string_view source, size_t index) {
    while (index < source.size() && std::isspace(static_cast<unsigned char>(source[index]))) {
        ++index;
    }
    return index;
}

int LineForPosition(std::string_view source, size_t position) {
    return 1 + static_cast<int>(std::count(source.begin(), source.begin() + position, '\n'));
}

std::string LineText(std::string_view source, size_t position) {
    const size_t line_start = source.rfind('\n', position);
    const size_t begin = line_start == std::string_view::npos ? 0 : line_start + 1;
    const size_t line_end = source.find('\n', position);
    const size_t end = line_end == std::string_view::npos ? source.size() : line_end;
    return std::string(source.substr(begin, end - begin));
}

bool HasLogicalLineContinuation(std::string_view line) {
    return !line.empty() && line.back() == '\\';
}

std::string LogicalDirectiveText(std::string_view source, size_t line_start,
                                 size_t* next_line_start) {
    std::string logical;
    size_t current_start = line_start;
    size_t current_end = source.find('\n', current_start);
    if (current_end == std::string_view::npos) {
        current_end = source.size();
    }

    while (true) {
        size_t physical_end = current_end;
        if (physical_end > current_start && source[physical_end - 1] == '\r') {
            --physical_end;
        }
        const std::string_view line = source.substr(current_start, physical_end - current_start);
        logical.append(line);
        if (current_end == source.size() || !HasLogicalLineContinuation(line)) {
            *next_line_start = current_end == source.size() ? source.size() : current_end + 1;
            return logical;
        }

        logical.pop_back();
        current_start = current_end + 1;
        current_end = source.find('\n', current_start);
        if (current_end == std::string_view::npos) {
            current_end = source.size();
        }
    }
}

size_t PreviousNonSpace(std::string_view source, size_t index) {
    while (index > 0 && std::isspace(static_cast<unsigned char>(source[index - 1]))) {
        --index;
    }
    return index;
}

std::string Trim(std::string_view text) {
    const size_t begin = NextNonSpace(text, 0);
    size_t end = text.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(text[end - 1]))) {
        --end;
    }
    return std::string(text.substr(begin, end - begin));
}

std::string WithoutWhitespace(std::string_view text) {
    std::string compact;
    compact.reserve(text.size());
    for (char value : text) {
        if (!std::isspace(static_cast<unsigned char>(value))) {
            compact.push_back(value);
        }
    }
    return compact;
}

bool HasIdentifierToken(std::string_view source, size_t position, std::string_view token) {
    if (source.substr(position, token.size()) != token ||
        (position > 0 && IsIdentifierChar(source[position - 1]))) {
        return false;
    }
    const size_t after_token = position + token.size();
    return after_token >= source.size() || !IsIdentifierChar(source[after_token]);
}

bool ContainsIdentifierToken(std::string_view source, std::string_view token) {
    for (size_t position = source.find(token); position != std::string_view::npos;
         position = source.find(token, position + token.size())) {
        if (HasIdentifierToken(source, position, token)) {
            return true;
        }
    }
    return false;
}

bool HasGlobalTokenCall(std::string_view stripped, size_t position, std::string_view token) {
    if (!HasIdentifierToken(stripped, position, token)) {
        return false;
    }
    const size_t before_token = PreviousNonSpace(stripped, position);
    if (before_token > 0 && stripped[before_token - 1] == '.') {
        return false;
    }
    if (before_token > 1 && stripped[before_token - 1] == '>' &&
        stripped[before_token - 2] == '-') {
        return false;
    }
    const size_t after_token = NextNonSpace(stripped, position + token.size());
    return after_token < stripped.size() && stripped[after_token] == '(';
}

bool HasOutputStreamUse(std::string_view stripped, size_t position, std::string_view token) {
    if (!HasIdentifierToken(stripped, position, token)) {
        return false;
    }
    if (token.find("::") == std::string_view::npos && position >= 2 &&
        stripped.substr(position - 2, 2) == "::") {
        return false;
    }
    const size_t after = NextNonSpace(stripped, position + token.size());
    if (after + 1 < stripped.size() && stripped.substr(after, 2) == "<<") {
        return true;
    }
    if (after >= stripped.size() || stripped[after] != '.') {
        return false;
    }
    const size_t method = NextNonSpace(stripped, after + 1);
    return stripped.substr(method, 4) == "put(" || stripped.substr(method, 6) == "write(" ||
           stripped.substr(method, 6) == "flush(";
}

bool IsExactPath(const std::filesystem::path& actual, const std::filesystem::path& expected) {
    return std::filesystem::absolute(actual).lexically_normal() ==
           std::filesystem::absolute(expected).lexically_normal();
}

bool IsExactApprovedLoggerSink(const std::filesystem::path& file, std::string_view line_text,
                               std::string_view token) {
    return IsExactPath(file, TIM2TOX_LOG_SOURCE_PATH) && token == "std::cout" &&
           Trim(line_text) == "std::cout << full_message;";
}

bool FindCallEnd(std::string_view stripped, size_t open_parenthesis, size_t* close_parenthesis) {
    int depth = 0;
    for (size_t position = open_parenthesis; position < stripped.size(); ++position) {
        if (stripped[position] == '(') {
            ++depth;
        } else if (stripped[position] == ')') {
            --depth;
            if (depth == 0) {
                *close_parenthesis = position;
                return true;
            }
        }
    }
    return false;
}

std::vector<std::string> CallArguments(std::string_view stripped, size_t open_parenthesis,
                                       size_t close_parenthesis) {
    std::vector<std::string> arguments;
    size_t argument_start = open_parenthesis + 1;
    int parenthesis_depth = 0;
    int bracket_depth = 0;
    int brace_depth = 0;
    for (size_t position = argument_start; position < close_parenthesis; ++position) {
        switch (stripped[position]) {
            case '(':
                ++parenthesis_depth;
                break;
            case ')':
                --parenthesis_depth;
                break;
            case '[':
                ++bracket_depth;
                break;
            case ']':
                --bracket_depth;
                break;
            case '{':
                ++brace_depth;
                break;
            case '}':
                --brace_depth;
                break;
            case ',':
                if (parenthesis_depth == 0 && bracket_depth == 0 && brace_depth == 0) {
                    arguments.push_back(
                        Trim(stripped.substr(argument_start, position - argument_start)));
                    argument_start = position + 1;
                }
                break;
            default:
                break;
        }
    }
    arguments.push_back(Trim(stripped.substr(argument_start, close_parenthesis - argument_start)));
    return arguments;
}

bool IsConsoleDescriptor(std::string_view argument) {
    const std::string compact = WithoutWhitespace(argument);
    for (std::string_view descriptor :
         {"1", "2", "STDOUT_FILENO", "STDERR_FILENO", "fileno(stdout)", "fileno(stderr)",
          "_fileno(stdout)", "_fileno(stderr)"}) {
        if (compact == descriptor) {
            return true;
        }
    }
    return false;
}

bool IsConsoleFile(std::string_view argument) {
    const std::string compact = WithoutWhitespace(argument);
    return compact == "stdout" || compact == "stderr" || compact == "::stdout" ||
           compact == "::stderr";
}

bool IsConsoleSinkCall(std::string_view token, const std::vector<std::string>& arguments) {
    if (token == "write" || token == "_write" || token == "writev") {
        return !arguments.empty() && IsConsoleDescriptor(arguments[0]);
    }
    if (token == "fwrite") {
        return arguments.size() >= 4 && IsConsoleFile(arguments[3]);
    }
    if (token == "fputs" || token == "fputc" || token == "putc") {
        return arguments.size() >= 2 && IsConsoleFile(arguments[1]);
    }
    return false;
}

bool IsApprovedFatalMarkerWrite(const std::filesystem::path& file, std::string_view stripped,
                                size_t position, size_t close_parenthesis, std::string_view token) {
    if (!IsExactPath(file, std::filesystem::path(TIM2TOX_FFI_DIR) / "callback_bridge.cpp")) {
        return false;
    }
    const std::string call =
        WithoutWhitespace(stripped.substr(position, close_parenthesis - position + 1));
    if (token == "write") {
        return call ==
               "write(STDERR_FILENO,kFatalSignalMarker,sizeof("
               "kFatalSignalMarker)-1)";
    }
    return token == "_write" && call ==
                                    "_write(2,kFatalSignalMarker,static_cast<unsignedint>(sizeof("
                                    "kFatalSignalMarker)-1))";
}

void AppendCallFindings(const std::filesystem::path& file, std::string_view source,
                        std::string_view stripped, std::string_view token,
                        std::vector<Finding>* findings) {
    for (size_t position = stripped.find(token); position != std::string_view::npos;
         position = stripped.find(token, position + token.size())) {
        if (HasGlobalTokenCall(stripped, position, token)) {
            findings->push_back(Finding{file.string(), LineForPosition(source, position),
                                        std::string(token), LineText(source, position)});
        }
    }
}

void AppendStreamFindings(const std::filesystem::path& file, std::string_view source,
                          std::string_view stripped, std::string_view token,
                          std::vector<Finding>* findings) {
    for (size_t position = stripped.find(token); position != std::string_view::npos;
         position = stripped.find(token, position + token.size())) {
        if (!HasOutputStreamUse(stripped, position, token)) {
            continue;
        }
        const std::string text = LineText(source, position);
        if (!IsExactApprovedLoggerSink(file, text, token)) {
            findings->push_back(Finding{file.string(), LineForPosition(source, position),
                                        std::string(token), text});
        }
    }
}

void AppendConditionalWriteFindings(const std::filesystem::path& file, std::string_view source,
                                    std::string_view stripped, std::string_view token,
                                    std::vector<Finding>* findings) {
    for (size_t position = stripped.find(token); position != std::string_view::npos;
         position = stripped.find(token, position + token.size())) {
        if (!HasGlobalTokenCall(stripped, position, token)) {
            continue;
        }
        const size_t open_parenthesis = NextNonSpace(stripped, position + token.size());
        size_t close_parenthesis = 0;
        if (!FindCallEnd(stripped, open_parenthesis, &close_parenthesis)) {
            continue;
        }
        const std::vector<std::string> arguments =
            CallArguments(stripped, open_parenthesis, close_parenthesis);
        if (!IsConsoleSinkCall(token, arguments) ||
            IsApprovedFatalMarkerWrite(file, stripped, position, close_parenthesis, token)) {
            continue;
        }
        findings->push_back(Finding{file.string(), LineForPosition(source, position),
                                    std::string(token), LineText(source, position)});
    }
}

bool IsMacroDefinitionName(std::string_view stripped, size_t position) {
    const size_t line_start = stripped.rfind('\n', position);
    const size_t begin = line_start == std::string_view::npos ? 0 : line_start + 1;
    size_t cursor = NextNonSpace(stripped, begin);
    if (cursor >= stripped.size() || stripped[cursor] != '#') {
        return false;
    }
    cursor = NextNonSpace(stripped, cursor + 1);
    constexpr std::string_view kDefine = "define";
    if (stripped.substr(cursor, kDefine.size()) != kDefine) {
        return false;
    }
    cursor = NextNonSpace(stripped, cursor + kDefine.size());
    return cursor == position;
}

bool ReferencesGlobalCallOrExactAlias(std::string_view replacement, std::string_view token) {
    const std::string trimmed = Trim(replacement);
    for (size_t position = replacement.find(token); position != std::string_view::npos;
         position = replacement.find(token, position + token.size())) {
        if (HasIdentifierToken(replacement, position, token) &&
            (trimmed == token || HasGlobalTokenCall(replacement, position, token))) {
            return true;
        }
    }
    return false;
}

bool ReplacementReferencesRawSink(std::string_view replacement) {
    for (std::string_view token : {"printf",
                                   "fprintf",
                                   "vprintf",
                                   "vfprintf",
                                   "dprintf",
                                   "vdprintf",
                                   "puts",
                                   "putchar",
                                   "perror",
                                   "backtrace",
                                   "backtrace_symbols",
                                   "backtrace_symbols_fd",
                                   "NSLog",
                                   "NSLogv",
                                   "__android_log_print",
                                   "__android_log_write",
                                   "__android_log_vprint",
                                   "__android_log_assert",
                                   "OutputDebugString",
                                   "OutputDebugStringA",
                                   "OutputDebugStringW",
                                   "syslog",
                                   "vsyslog",
                                   "os_log",
                                   "os_log_with_type",
                                   "write",
                                   "_write",
                                   "fwrite",
                                   "fputs",
                                   "fputc",
                                   "putc",
                                   "writev"}) {
        if (ReferencesGlobalCallOrExactAlias(replacement, token)) {
            return true;
        }
    }
    for (std::string_view token : {"std::cout", "std::cerr", "std::clog"}) {
        if (ContainsIdentifierToken(replacement, token)) {
            return true;
        }
    }
    return false;
}

void AppendMacroAliasFindings(const std::filesystem::path& file, std::string_view source,
                              std::string_view stripped, std::vector<Finding>* findings) {
    for (size_t line_start = 0; line_start < stripped.size();) {
        const size_t line_end = stripped.find('\n', line_start);
        const size_t end = line_end == std::string_view::npos ? stripped.size() : line_end;
        size_t physical_end = end;
        if (physical_end > line_start && stripped[physical_end - 1] == '\r') {
            --physical_end;
        }
        const std::string_view line = stripped.substr(line_start, physical_end - line_start);
        size_t cursor = NextNonSpace(line, 0);
        if (cursor < line.size() && line[cursor] == '#') {
            cursor = NextNonSpace(line, cursor + 1);
            constexpr std::string_view kDefine = "define";
            if (line.substr(cursor, kDefine.size()) == kDefine) {
                size_t next_line_start = line_start;
                const std::string logical_definition =
                    LogicalDirectiveText(stripped, line_start, &next_line_start);
                const std::string_view logical = logical_definition;
                size_t logical_cursor = NextNonSpace(logical, 0);
                if (logical_cursor < logical.size() && logical[logical_cursor] == '#') {
                    logical_cursor = NextNonSpace(logical, logical_cursor + 1);
                    if (logical.substr(logical_cursor, kDefine.size()) == kDefine) {
                        logical_cursor = NextNonSpace(logical, logical_cursor + kDefine.size());
                        const size_t name_start = logical_cursor;
                        while (logical_cursor < logical.size() &&
                               IsIdentifierChar(logical[logical_cursor])) {
                            ++logical_cursor;
                        }
                        const std::string name(
                            logical.substr(name_start, logical_cursor - name_start));
                        if (logical_cursor < logical.size() && logical[logical_cursor] == '(') {
                            int depth = 0;
                            do {
                                depth += logical[logical_cursor] == '(' ? 1 : 0;
                                depth -= logical[logical_cursor] == ')' ? 1 : 0;
                                ++logical_cursor;
                            } while (logical_cursor < logical.size() && depth > 0);
                        }
                        if (!name.empty() &&
                            ReplacementReferencesRawSink(logical.substr(logical_cursor))) {
                            const size_t position = line_start + name_start;
                            findings->push_back(Finding{file.string(),
                                                        LineForPosition(source, position), name,
                                                        LineText(source, position)});
                        }
                    }
                }
                line_start = next_line_start;
                continue;
            }
        }
        line_start = line_end == std::string_view::npos ? stripped.size() : line_end + 1;
    }
}

void SortAndDeduplicate(std::vector<Finding>* findings) {
    std::sort(findings->begin(), findings->end(), [](const Finding& left, const Finding& right) {
        if (left.file != right.file) {
            return left.file < right.file;
        }
        if (left.line != right.line) {
            return left.line < right.line;
        }
        return left.token < right.token;
    });
    findings->erase(std::unique(findings->begin(), findings->end(),
                                [](const Finding& left, const Finding& right) {
                                    return left.file == right.file && left.line == right.line &&
                                           left.token == right.token;
                                }),
                    findings->end());
}

std::vector<Finding> FindOutputBypassesInSource(const std::filesystem::path& file,
                                                std::string_view source) {
    std::vector<Finding> findings;
    const std::string stripped = StripCommentsAndStrings(source);
    for (std::string_view token : {"printf",
                                   "fprintf",
                                   "vprintf",
                                   "vfprintf",
                                   "dprintf",
                                   "vdprintf",
                                   "puts",
                                   "putchar",
                                   "perror",
                                   "backtrace",
                                   "backtrace_symbols",
                                   "backtrace_symbols_fd",
                                   "NSLog",
                                   "NSLogv",
                                   "__android_log_print",
                                   "__android_log_write",
                                   "__android_log_vprint",
                                   "__android_log_assert",
                                   "OutputDebugString",
                                   "OutputDebugStringA",
                                   "OutputDebugStringW",
                                   "syslog",
                                   "vsyslog",
                                   "os_log",
                                   "os_log_with_type"}) {
        AppendCallFindings(file, source, stripped, token, &findings);
    }
    for (std::string_view token :
         {"write", "_write", "writev", "fwrite", "fputs", "fputc", "putc"}) {
        AppendConditionalWriteFindings(file, source, stripped, token, &findings);
    }
    for (std::string_view token : {"std::cout", "std::cerr", "std::clog", "cout", "cerr", "clog"}) {
        AppendStreamFindings(file, source, stripped, token, &findings);
    }
    for (std::string_view token :
         {"LOG",      "LOGV",        "LOGD",      "LOGI",      "LOGW",        "LOGE",
          "LOGF",     "DLOG",        "DLOG_IF",   "ALOGV",     "ALOGD",       "ALOGI",
          "ALOGW",    "ALOGE",       "ALOGF",     "LOG_TRACE", "LOG_DEBUG",   "LOG_INFO",
          "LOG_WARN", "LOG_WARNING", "LOG_ERROR", "LOG_FATAL", "DEBUG_PRINT", "TRACE"}) {
        for (size_t position = stripped.find(token); position != std::string_view::npos;
             position = stripped.find(token, position + token.size())) {
            if (HasGlobalTokenCall(stripped, position, token) &&
                !IsMacroDefinitionName(stripped, position)) {
                findings.push_back(Finding{file.string(), LineForPosition(source, position),
                                           std::string(token), LineText(source, position)});
            }
        }
    }
    AppendMacroAliasFindings(file, source, stripped, &findings);
    SortAndDeduplicate(&findings);
    return findings;
}

std::vector<Finding> FindDirectOutputBypasses() {
    std::vector<Finding> findings;
    for (const std::filesystem::path directory :
         {std::filesystem::path(TIM2TOX_SOURCE_DIR), std::filesystem::path(TIM2TOX_FFI_DIR)}) {
        for (const auto& file : ProductionSourceFiles(directory)) {
            const std::string source = ReadSource(file);
            std::vector<Finding> file_findings = FindOutputBypassesInSource(file, source);
            findings.insert(findings.end(), file_findings.begin(), file_findings.end());
        }
    }
    SortAndDeduplicate(&findings);
    return findings;
}

std::string FormatFindings(const std::vector<Finding>& findings) {
    std::ostringstream output;
    const size_t limit = std::min<size_t>(findings.size(), 25);
    for (size_t index = 0; index < limit; ++index) {
        const Finding& finding = findings[index];
        output << finding.file << ':' << finding.line << " " << finding.token << " | "
               << finding.text << '\n';
    }
    if (findings.size() > limit) {
        output << "... " << (findings.size() - limit) << " more\n";
    }
    return output.str();
}

struct RedFixtureCase {
    const char* name;
    const char* source;
};

class NativeLogPrivacyRedFixture : public ::testing::TestWithParam<RedFixtureCase> {};

TEST_P(NativeLogPrivacyRedFixture, RejectsConsoleAndRawLoggingSink) {
    const RedFixtureCase& fixture = GetParam();
    const std::vector<Finding> findings = FindOutputBypassesInSource("fixture.cpp", fixture.source);
    EXPECT_FALSE(findings.empty()) << fixture.name << " was not rejected";
}

INSTANTIATE_TEST_SUITE_P(
    RequiredSinks, NativeLogPrivacyRedFixture,
    ::testing::Values(
        RedFixtureCase{"printf", "printf(\"secret\");"},
        RedFixtureCase{"fprintf", "fprintf(stderr, \"secret\");"},
        RedFixtureCase{"vprintf", "vprintf(\"secret\", args);"},
        RedFixtureCase{"dprintf", "dprintf(2, \"secret\");"},
        RedFixtureCase{"puts", "puts(\"secret\");"},
        RedFixtureCase{"perror", "perror(\"secret\");"},
        RedFixtureCase{"cout", "std::cout << secret;"},
        RedFixtureCase{"cerr", "std::cerr << secret;"},
        RedFixtureCase{"clog", "std::clog << secret;"},
        RedFixtureCase{"backtrace", "backtrace(frames, frame_count);"},
        RedFixtureCase{"NSLog", "NSLog(@\"secret\");"},
        RedFixtureCase{"android_log",
                       "__android_log_print(ANDROID_LOG_INFO, \"tag\", \"secret\");"},
        RedFixtureCase{"OutputDebugString", "OutputDebugStringA(\"secret\");"},
        RedFixtureCase{"syslog", "syslog(LOG_ERR, \"secret\");"},
        RedFixtureCase{"stdout_write", "write(STDOUT_FILENO, secret, secret_length);"},
        RedFixtureCase{"stderr_write", "write(STDERR_FILENO, secret, secret_length);"},
        RedFixtureCase{"numeric_stderr_write", "write(2, secret, secret_length);"},
        RedFixtureCase{"windows_stderr_write", "_write(2, secret, secret_length);"},
        RedFixtureCase{"stdout_fwrite", "fwrite(secret, 1, secret_length, stdout);"},
        RedFixtureCase{"stderr_fwrite", "fwrite(secret, 1, secret_length, stderr);"},
        RedFixtureCase{"stdout_fputs", "fputs(secret, stdout);"},
        RedFixtureCase{"stderr_fputs", "fputs(secret, stderr);"},
        RedFixtureCase{"stdout_fputc", "fputc(secret_byte, stdout);"},
        RedFixtureCase{"stderr_fputc", "fputc(secret_byte, stderr);"},
        RedFixtureCase{"stdout_putc", "putc(secret_byte, stdout);"},
        RedFixtureCase{"stderr_putc", "putc(secret_byte, stderr);"},
        RedFixtureCase{"putchar", "putchar(secret_byte);"},
        RedFixtureCase{"stdout_writev", "writev(STDOUT_FILENO, buffers, buffer_count);"},
        RedFixtureCase{"stderr_writev", "writev(STDERR_FILENO, buffers, buffer_count);"},
        RedFixtureCase{"numeric_stdout_writev", "writev(1, buffers, buffer_count);"},
        RedFixtureCase{"numeric_stderr_writev", "writev(2, buffers, buffer_count);"},
        RedFixtureCase{"object_like_macro_alias", "#define RAW_LOG printf\nRAW_LOG(\"secret\");"},
        RedFixtureCase{"function_like_macro_alias",
                       "#define RAW_LOG(...) printf(__VA_ARGS__)\n"
                       "RAW_LOG(\"secret\");"},
        RedFixtureCase{"android_print_macro_alias",
                       "#define RAW_LOG(...) __android_log_print(ANDROID_LOG_INFO, \"tag\","
                       " __VA_ARGS__)\n"
                       "RAW_LOG(\"secret\");"},
        RedFixtureCase{"android_assert_macro_alias_continued",
                       "#define RAW_LOG(...) __android_log_\\\n"
                       "assert(\"cond\", \"tag\", \"secret\");\n"
                       "RAW_LOG(\"secret\");"},
        RedFixtureCase{"write_macro_alias",
                       "#define RAW_WRITE(...) write(__VA_ARGS__)\n"
                       "RAW_WRITE(STDERR_FILENO, secret, secret_length);"},
        RedFixtureCase{"windows_write_macro_alias",
                       "#define RAW_WRITE(...) _write(__VA_ARGS__)\n"
                       "RAW_WRITE(2, secret, secret_length);"},
        RedFixtureCase{"fwrite_macro_alias",
                       "#define RAW_WRITE(...) fwrite(__VA_ARGS__)\n"
                       "RAW_WRITE(secret, 1, secret_length, stderr);"},
        RedFixtureCase{"fputs_macro_alias",
                       "#define RAW_WRITE(...) fputs(__VA_ARGS__)\n"
                       "RAW_WRITE(secret, stderr);"},
        RedFixtureCase{"fputc_macro_alias",
                       "#define RAW_WRITE(...) fputc(__VA_ARGS__)\n"
                       "RAW_WRITE(secret_byte, stderr);"},
        RedFixtureCase{"putc_macro_alias",
                       "#define RAW_WRITE(...) putc(__VA_ARGS__)\n"
                       "RAW_WRITE(secret_byte, stderr);"},
        RedFixtureCase{"putchar_macro_alias",
                       "#define RAW_WRITE(...) putchar(__VA_ARGS__)\n"
                       "RAW_WRITE(secret_byte);"},
        RedFixtureCase{"writev_macro_alias",
                       "#define RAW_WRITE(...) writev(__VA_ARGS__)\n"
                       "RAW_WRITE(STDERR_FILENO, buffers, buffer_count);"},
        RedFixtureCase{"logging_macro", "LOG_ERROR(\"secret\");"}),
    [](const ::testing::TestParamInfo<RedFixtureCase>& info) { return info.param.name; });

struct GreenFixtureCase {
    const char* name;
    const char* source;
};

class NativeLogPrivacyGreenFixture : public ::testing::TestWithParam<GreenFixtureCase> {};

TEST_P(NativeLogPrivacyGreenFixture, AcceptsNonConsoleFileIoAndSafeText) {
    const GreenFixtureCase& fixture = GetParam();
    const std::vector<Finding> findings = FindOutputBypassesInSource("fixture.cpp", fixture.source);
    EXPECT_TRUE(findings.empty()) << fixture.name << " produced:\n" << FormatFindings(findings);
}

INSTANTIATE_TEST_SUITE_P(
    RequiredNonSinks, NativeLogPrivacyGreenFixture,
    ::testing::Values(
        GreenFixtureCase{"file_descriptor_write", "write(file_descriptor, bytes, byte_count);"},
        GreenFixtureCase{"windows_file_descriptor_write",
                         "_write(file_descriptor, bytes, byte_count);"},
        GreenFixtureCase{"file_descriptor_writev",
                         "writev(file_descriptor, buffers, buffer_count);"},
        GreenFixtureCase{"file_fwrite", "fwrite(bytes, 1, byte_count, output_file);"},
        GreenFixtureCase{"file_fputs", "fputs(text, output_file);"},
        GreenFixtureCase{"file_fputc", "fputc(value, output_file);"},
        GreenFixtureCase{"file_putc", "putc(value, output_file);"},
        GreenFixtureCase{"ofstream_write", "output.write(bytes, byte_count);"},
        GreenFixtureCase{"pointer_stream_write", "output->write(bytes, byte_count);"},
        GreenFixtureCase{"member_write_macro",
                         "#define FILE_WRITE(...) output.write(__VA_ARGS__)\n"
                         "FILE_WRITE(bytes, byte_count);"},
        GreenFixtureCase{"format_to_buffer", "snprintf(buffer, sizeof(buffer), \"%s\", value);"},
        GreenFixtureCase{"comment_and_string",
                         "// printf(\"secret\");\nconst char* text = \"std::cerr\";"},
        GreenFixtureCase{"continued_non_console_macro",
                         "#define FILE_WRITE(...) output.\\\n"
                         "write(__VA_ARGS__)\n"
                         "FILE_WRITE(bytes, byte_count);"},
        GreenFixtureCase{"approved_logger_macro",
                         "V2TIM_LOG(kInfo, \"legacy caller text {}\", value);"},
        GreenFixtureCase{"approved_logger_macro_alias",
                         "V2TIM_LOG_ERROR(\"legacy caller text {}\", value);"},
        GreenFixtureCase{"approved_logger_macro_definition",
                         "#define V2TIM_LOG_ERROR(...) "
                         "V2TIM_LOG(kError, __VA_ARGS__)"}),
    [](const ::testing::TestParamInfo<GreenFixtureCase>& info) { return info.param.name; });

TEST(NativeLogPrivacyAllowlistTest, AllowsOnlyExactLoggerSinkStatement) {
    EXPECT_TRUE(
        FindOutputBypassesInSource(TIM2TOX_LOG_SOURCE_PATH, "std::cout << full_message;").empty());
    EXPECT_FALSE(
        FindOutputBypassesInSource(TIM2TOX_LOG_SOURCE_PATH, "std::cout << prefix << full_message;")
            .empty());
    EXPECT_FALSE(FindOutputBypassesInSource(
                     std::filesystem::path(TIM2TOX_SOURCE_DIR) / "nested" / "V2TIMLog.cpp",
                     "std::cout << full_message;")
                     .empty());
}

TEST(NativeLogPrivacyAllowlistTest, AllowsOnlyExactStaticCallbackFatalMarkerWrites) {
    const std::filesystem::path callback_bridge =
        std::filesystem::path(TIM2TOX_FFI_DIR) / "callback_bridge.cpp";
    EXPECT_TRUE(FindOutputBypassesInSource(callback_bridge,
                                           "write(STDERR_FILENO, kFatalSignalMarker, "
                                           "sizeof(kFatalSignalMarker) - 1);")
                    .empty());
    EXPECT_TRUE(
        FindOutputBypassesInSource(callback_bridge,
                                   "_write(2, kFatalSignalMarker, static_cast<unsigned int>("
                                   "sizeof(kFatalSignalMarker) - 1));")
            .empty());
    EXPECT_FALSE(FindOutputBypassesInSource(callback_bridge,
                                            "write(STDERR_FILENO, message, message_length);")
                     .empty());
}

class NativeLogPrivacyFileDiscoveryFixture : public ::testing::Test {
protected:
    void SetUp() override {
        const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
        root_ = std::filesystem::temp_directory_path() /
                ("tim2tox-log-source-guard-" + std::to_string(nonce));
        std::filesystem::create_directories(root_ / "nested");
    }

    void TearDown() override {
        std::error_code error;
        std::filesystem::remove_all(root_, error);
    }

    void Write(const std::filesystem::path& relative_path, std::string_view contents) {
        std::ofstream output(root_ / relative_path, std::ios::binary);
        ASSERT_TRUE(output.good());
        output << contents;
    }

    std::filesystem::path root_;
};

TEST_F(NativeLogPrivacyFileDiscoveryFixture,
       RecursivelyIncludesProductionCAndObjcSourceAndHeaderExtensions) {
    const std::vector<std::string> extensions = {".c",   ".cc",  ".cp",  ".cpp", ".cxx", ".c++",
                                                 ".h",   ".hh",  ".hpp", ".hxx", ".h++", ".inc",
                                                 ".inl", ".ipp", ".tpp", ".m",   ".mm"};
    for (const std::string& extension : extensions) {
        Write(std::filesystem::path("nested") / ("fixture" + extension), "printf(\"secret\");");
    }
    Write("nested/ignored.txt", "printf(\"secret\");");

    EXPECT_EQ(ProductionSourceFiles(root_).size(), extensions.size());
}

}  // namespace

TEST(NativeLogPrivacySourceRegressionTest, DirectOutputBypassesStayRedUntilMigrated) {
    const std::vector<Finding> findings = FindDirectOutputBypasses();
    if (!findings.empty()) {
        ADD_FAILURE() << "Found " << findings.size()
                      << " direct output bypass(es). Current RED count: " << findings.size() << "\n"
                      << FormatFindings(findings);
    }
}

TEST(NativeLogPrivacySourceRegressionTest, V2TIMLogDoesNotFormatLegacyCallerMessageIntoSink) {
    const std::string header = ReadSource(TIM2TOX_LOG_HEADER_PATH);
    const std::string source = ReadSource(TIM2TOX_LOG_SOURCE_PATH);

    EXPECT_EQ(header.find("formatMessage"), std::string::npos);
    EXPECT_EQ(source.find("formatMessage"), std::string::npos);
    EXPECT_NE(header.find("consteval StaticText"), std::string::npos);
    EXPECT_EQ(header.find("ss.str()"), std::string::npos);
    EXPECT_EQ(source.find("ss.str()"), std::string::npos);
    EXPECT_EQ(header.find("writeLog(level, ss.str())"), std::string::npos);
    EXPECT_EQ(source.find("writeLog(level, ss.str())"), std::string::npos);
}
