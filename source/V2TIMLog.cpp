#include "V2TIMLog.h"
#include <iostream>
#include <sstream>
#if defined(_WIN32) || defined(_WIN64)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#ifdef ERROR
#undef ERROR
#endif
#ifdef WARNING
#undef WARNING
#endif
#ifdef INFO
#undef INFO
#endif
#ifdef DEBUG
#undef DEBUG
#endif
#ifdef FATAL
#undef FATAL
#endif
#endif

// Define the static instance getter
V2TIMLog& V2TIMLog::getInstance() {
    static V2TIMLog instance; // Thread-safe in C++11 and later
    return instance;
}

// Constructor
V2TIMLog::V2TIMLog()
    : min_level_(LogLevel::INFO),
      console_output_(true),
      destroyed_(false)
{
}

// Destructor: Close the log file if open
V2TIMLog::~V2TIMLog() {
    destroyed_.store(true);
    std::lock_guard<std::mutex> lock(mutex_);
    if (log_file_ && log_file_->is_open()) {
        log_file_->close();
    }
}

// Set the path for the log file
void V2TIMLog::setLogFile(const std::string& path) {
    if (destroyed_.load()) return;
    bool open_failed = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (destroyed_.load()) return;
        if (log_file_ && log_file_->is_open()) {
            log_file_->close();
        }
        log_file_ = std::make_unique<std::ofstream>(path, std::ios::app);
        if (!log_file_ || !log_file_->is_open()) {
            log_file_.reset();
            console_output_ = true;
            open_failed = true;
        }
    }
    if (open_failed) {
        Error("log_file_open_failed");
    }
}

// Set the minimum log level to record
void V2TIMLog::setLogLevel(LogLevel level) {
    if (destroyed_.load()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    if (destroyed_.load()) return;
    min_level_.store(level, std::memory_order_relaxed);
}

// Enable or disable logging to the console
void V2TIMLog::enableConsoleOutput(bool enable) {
    if (destroyed_.load()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    if (destroyed_.load()) return;
    console_output_ = enable;
}

void V2TIMLog::writeLog(LogLevel level, const char* component, const char* event,
                        const tim2tox::diag::Field* fields, size_t field_count) {
    if (destroyed_.load()) return;
    // unique_lock (not lock_guard): the console write below is done with the
    // mutex released, so it must be unlockable early.
    std::unique_lock<std::mutex> lock(mutex_);
    if (destroyed_.load()) return;
    if (level < min_level_.load(std::memory_order_relaxed)) return;

    std::stringstream line;
    line << "[" << getLevelString(level) << "] component="
         << component << " event=" << event;
    for (size_t index = 0; fields && index < field_count; ++index) {
        line << " " << getFieldString(fields[index].kind) << "="
             << fields[index].value;
    }
    line << "\n";
    std::string full_message = line.str();

    if (log_file_ && log_file_->is_open()) {
        *log_file_ << full_message;
        log_file_->flush();
    }

    const bool write_console = console_output_;
    lock.unlock();

    if (write_console) {
        // MUST flush. When stdout is a terminal this is nearly free, but the
        // automated harness launches the app with stdout redirected to a file
        // (`nohup … >toxee_stdio.log`), where libstdc++ switches to full
        // buffering — and the app is always killed rather than exited, so the
        // buffer was never drained. Every console log line written during a
        // real-UI run was silently discarded, which is why the native side
        // looked completely silent while the logger was in fact working.
        //
        // Done with `mutex_` RELEASED: a flush blocks until the reader drains,
        // so a paused/stalled consumer on the other end of a pipe would
        // otherwise hold the logger mutex and wedge every logging thread —
        // including the Tox event thread — taking the whole native core down.
        std::cout << full_message << std::flush;
    }
}

// Get the string representation of a log level (unified: DEBUG/INFO/WARN/ERROR/FATAL)
const char* V2TIMLog::getLevelString(LogLevel level) {
    switch (level) {
        case LogLevel::DEBUG:   return "DEBUG";
        case LogLevel::INFO:    return "INFO";
        case LogLevel::WARNING: return "WARN";
        case LogLevel::ERROR:   return "ERROR";
        case LogLevel::FATAL:   return "FATAL";
        default:                return "UNKNOWN";
    }
}

const char* V2TIMLog::getFieldString(tim2tox::diag::FieldKind kind) {
    switch (kind) {
        case tim2tox::diag::FieldKind::Count:  return "count";
        case tim2tox::diag::FieldKind::Length: return "length";
        case tim2tox::diag::FieldKind::Status: return "status";
        case tim2tox::diag::FieldKind::Bool:   return "bool";
        case tim2tox::diag::FieldKind::Enum:   return "enum";
        default:                               return "enum";
    }
}
