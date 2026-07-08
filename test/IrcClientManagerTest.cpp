#include <gtest/gtest.h>

#include "IrcClientManager.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <openssl/ssl.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using socket_handle_t = SOCKET;
constexpr socket_handle_t kInvalidSocket = INVALID_SOCKET;
static void close_socket(socket_handle_t socket) { closesocket(socket); }
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netdb.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_handle_t = int;
constexpr socket_handle_t kInvalidSocket = -1;
static void close_socket(socket_handle_t socket) { close(socket); }
#endif

namespace {

class FakeIrcServer {
public:
    FakeIrcServer() {
#ifdef _WIN32
        WSADATA data;
        WSAStartup(MAKEWORD(2, 2), &data);
#endif
        listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
        EXPECT_NE(listen_fd_, kInvalidSocket);

        int opt = 1;
        setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR,
                   reinterpret_cast<const char*>(&opt), sizeof(opt));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;

        EXPECT_EQ(bind(listen_fd_, reinterpret_cast<sockaddr*>(&addr),
                       sizeof(addr)), 0);
        EXPECT_EQ(listen(listen_fd_, 1), 0);

        socklen_t len = sizeof(addr);
        EXPECT_EQ(getsockname(listen_fd_, reinterpret_cast<sockaddr*>(&addr),
                              &len), 0);
        port_ = ntohs(addr.sin_port);

        thread_ = std::thread([this] { run(); });
    }

    ~FakeIrcServer() {
        stop();
#ifdef _WIN32
        WSACleanup();
#endif
    }

    int port() const { return port_; }

    void sendLine(const std::string& line) {
        std::unique_lock<std::mutex> lock(mutex_);
        ASSERT_TRUE(waitForClientLocked(lock));
        const std::string payload = line + "\r\n";
        send(client_fd_, payload.c_str(), static_cast<int>(payload.size()), 0);
    }

    bool waitForCommandContaining(const std::string& needle,
                                  std::chrono::milliseconds timeout =
                                      std::chrono::milliseconds(3000)) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] {
            return std::any_of(commands_.begin(), commands_.end(),
                               [&](const std::string& command) {
                                   return command.find(needle) !=
                                          std::string::npos;
                               });
        });
    }

    std::vector<std::string> commands() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return commands_;
    }

    int commandCountContaining(const std::string& needle) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return static_cast<int>(std::count_if(
            commands_.begin(), commands_.end(),
            [&](const std::string& command) {
                return command.find(needle) != std::string::npos;
            }));
    }

private:
    bool waitForClientLocked(std::unique_lock<std::mutex>& lock) {
        return cv_.wait_for(lock, std::chrono::milliseconds(3000), [&] {
            return client_fd_ != kInvalidSocket;
        });
    }

    void run() {
        sockaddr_in client_addr{};
        socklen_t client_len = sizeof(client_addr);
        const auto accepted = accept(listen_fd_,
                                     reinterpret_cast<sockaddr*>(&client_addr),
                                     &client_len);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            client_fd_ = accepted;
        }
        cv_.notify_all();
        if (accepted == kInvalidSocket) return;

        char buffer[1024];
        std::string pending;
        while (!stopped_) {
            const int n = recv(accepted, buffer, sizeof(buffer) - 1, 0);
            if (n <= 0) break;
            buffer[n] = '\0';
            pending += buffer;

            std::size_t pos;
            while ((pos = pending.find('\n')) != std::string::npos) {
                auto line = pending.substr(0, pos);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    commands_.push_back(line);
                }
                cv_.notify_all();
                pending.erase(0, pos + 1);
            }
        }
    }

    void stop() {
        if (stopped_.exchange(true)) return;
        if (client_fd_ != kInvalidSocket) {
            close_socket(client_fd_);
            client_fd_ = kInvalidSocket;
        }
        if (listen_fd_ != kInvalidSocket) {
            close_socket(listen_fd_);
            listen_fd_ = kInvalidSocket;
        }
        if (thread_.joinable()) thread_.join();
    }

    int port_ = 0;
    socket_handle_t listen_fd_ = kInvalidSocket;
    socket_handle_t client_fd_ = kInvalidSocket;
    std::atomic<bool> stopped_{false};
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<std::string> commands_;
    std::thread thread_;
};

class PublicIrcPeer {
public:
    PublicIrcPeer(const std::string& server, int port, bool use_ssl,
                  const std::string& nick)
        : nick_(nick), use_ssl_(use_ssl) {
#ifdef _WIN32
        WSADATA data;
        WSAStartup(MAKEWORD(2, 2), &data);
#endif
        connectSocket(server, port);
        if (use_ssl_) startSsl(server);
        sendLine("NICK " + nick_);
        sendLine("USER " + nick_ + " 0 * :toxee public irc smoke");
        waitFor([&](const std::string& line) {
            return line.find(" 376 " + nick_ + " ") != std::string::npos ||
                   line.find(" 422 " + nick_ + " ") != std::string::npos;
        }, std::chrono::seconds(90));
    }

    ~PublicIrcPeer() {
        try {
            quit("peer shutdown");
        } catch (...) {
        }
#ifdef _WIN32
        WSACleanup();
#endif
    }

    void join(const std::string& channel) {
        sendLine("JOIN " + channel);
        waitFor([&](const std::string& line) {
            return isJoinFrom(line, nick_, channel) ||
                   isChannelError(line, channel);
        }, std::chrono::seconds(90));
    }

    void sendLine(const std::string& line) {
        const std::string payload = line + "\r\n";
        const char* data = payload.c_str();
        int remaining = static_cast<int>(payload.size());
        while (remaining > 0) {
            const int sent = use_ssl_ && ssl_
                                 ? SSL_write(ssl_, data, remaining)
                                 : static_cast<int>(send(sock_fd_, data,
                                                         remaining,
                                                         MSG_NOSIGNAL));
            if (sent <= 0) {
                throw std::runtime_error("failed to send IRC line: " + line);
            }
            data += sent;
            remaining -= sent;
        }
    }

    void privmsg(const std::string& channel, const std::string& message) {
        sendLine("PRIVMSG " + channel + " :" + message);
    }

    bool waitForPrivmsg(const std::string& channel,
                        const std::string& sender,
                        const std::string& message,
                        std::chrono::seconds timeout) {
        return waitFor([&](const std::string& line) {
            return line.rfind(":" + sender + "!", 0) == 0 &&
                   line.find(" PRIVMSG " + channel + " :" + message) !=
                       std::string::npos;
        }, timeout);
    }

    bool waitForJoin(const std::string& nick, const std::string& channel,
                     std::chrono::seconds timeout) {
        return waitFor([&](const std::string& line) {
            return isJoinFrom(line, nick, channel);
        }, timeout);
    }

    bool waitForQuit(const std::string& nick, std::chrono::seconds timeout) {
        return waitFor([&](const std::string& line) {
            return line.rfind(":" + nick + "!", 0) == 0 &&
                   line.find(" QUIT ") != std::string::npos;
        }, timeout);
    }

    void quit(const std::string& reason) {
        if (sock_fd_ == kInvalidSocket) return;
        sendLine("QUIT :" + reason);
        if (ssl_) {
            SSL_shutdown(ssl_);
            SSL_free(ssl_);
            ssl_ = nullptr;
        }
        if (ssl_ctx_) {
            SSL_CTX_free(ssl_ctx_);
            ssl_ctx_ = nullptr;
        }
        close_socket(sock_fd_);
        sock_fd_ = kInvalidSocket;
    }

private:
    static bool isJoinFrom(const std::string& line, const std::string& nick,
                           const std::string& channel) {
        return line.rfind(":" + nick + "!", 0) == 0 &&
               (line.find(" JOIN " + channel) != std::string::npos ||
                line.find(" JOIN :" + channel) != std::string::npos);
    }

    bool isChannelError(const std::string& line,
                        const std::string& channel) const {
        return line.find(" " + nick_ + " " + channel) != std::string::npos &&
               (line.find(" 471 ") != std::string::npos ||
                line.find(" 473 ") != std::string::npos ||
                line.find(" 474 ") != std::string::npos ||
                line.find(" 475 ") != std::string::npos ||
                line.find(" 477 ") != std::string::npos);
    }

    void connectSocket(const std::string& server, int port) {
        addrinfo hints{};
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;

        addrinfo* result = nullptr;
        const int rc = getaddrinfo(server.c_str(), std::to_string(port).c_str(),
                                   &hints, &result);
        if (rc != 0) {
            throw std::runtime_error("getaddrinfo failed for " + server);
        }

        for (addrinfo* rp = result; rp != nullptr; rp = rp->ai_next) {
            sock_fd_ = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
            if (sock_fd_ == kInvalidSocket) continue;
            if (connect(sock_fd_, rp->ai_addr, rp->ai_addrlen) == 0) break;
            close_socket(sock_fd_);
            sock_fd_ = kInvalidSocket;
        }
        freeaddrinfo(result);

        if (sock_fd_ == kInvalidSocket) {
            throw std::runtime_error("failed to connect IRC peer socket");
        }
    }

    void startSsl(const std::string& server) {
        SSL_library_init();
        ssl_ctx_ = SSL_CTX_new(TLS_client_method());
        if (!ssl_ctx_) throw std::runtime_error("SSL_CTX_new failed");

        ssl_ = SSL_new(ssl_ctx_);
        if (!ssl_) throw std::runtime_error("SSL_new failed");
        SSL_set_tlsext_host_name(ssl_, server.c_str());
        SSL_set_fd(ssl_, static_cast<int>(sock_fd_));
        if (SSL_connect(ssl_) <= 0) {
            throw std::runtime_error("SSL_connect failed");
        }
    }

    bool waitFor(const std::function<bool(const std::string&)>& predicate,
                 std::chrono::seconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        while (std::chrono::steady_clock::now() < deadline) {
            const auto line = readLine(deadline);
            if (line.empty()) continue;
            if (line.rfind("PING ", 0) == 0) {
                sendLine("PONG " + line.substr(5));
                continue;
            }
            if (line.rfind("ERROR ", 0) == 0) {
                throw std::runtime_error("IRC server error: " + line);
            }
            if (predicate(line)) return true;
        }
        return false;
    }

    std::string readLine(std::chrono::steady_clock::time_point deadline) {
        while (std::chrono::steady_clock::now() < deadline) {
            const auto newline = buffer_.find('\n');
            if (newline != std::string::npos) {
                std::string line = buffer_.substr(0, newline);
                buffer_.erase(0, newline + 1);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                return line;
            }

            fd_set read_fds;
            FD_ZERO(&read_fds);
            FD_SET(sock_fd_, &read_fds);
            timeval timeout{};
            timeout.tv_sec = 1;
            const int ready =
                select(static_cast<int>(sock_fd_) + 1, &read_fds, nullptr,
                       nullptr, &timeout);
            if (ready <= 0) continue;

            char chunk[2048];
            int received = 0;
            if (use_ssl_ && ssl_) {
                received = SSL_read(ssl_, chunk, sizeof(chunk));
                if (received <= 0) {
                    const int error = SSL_get_error(ssl_, received);
                    if (error == SSL_ERROR_WANT_READ ||
                        error == SSL_ERROR_WANT_WRITE) {
                        continue;
                    }
                    throw std::runtime_error("SSL_read failed");
                }
            } else {
                received = static_cast<int>(
                    recv(sock_fd_, chunk, sizeof(chunk), 0));
                if (received <= 0) {
                    throw std::runtime_error("IRC peer socket closed");
                }
            }
            buffer_.append(chunk, received);
        }
        return "";
    }

    std::string nick_;
    bool use_ssl_ = false;
    socket_handle_t sock_fd_ = kInvalidSocket;
    SSL_CTX* ssl_ctx_ = nullptr;
    SSL* ssl_ = nullptr;
    std::string buffer_;
};

template <typename Predicate>
bool waitUntil(Predicate predicate,
               std::chrono::milliseconds timeout =
                   std::chrono::milliseconds(3000)) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (predicate()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return predicate();
}

class IrcClientManagerTest : public ::testing::Test {
protected:
    void TearDown() override {
        auto& manager = IrcClientManager::getInstance();
        manager.shutdown();
        manager.setConnectionStatusCallback(nullptr);
        manager.setUserListCallback(nullptr);
        manager.setUserJoinPartCallback(nullptr);
        manager.setToxMessageCallback(nullptr);
        manager.setToxGroupMessageCallback(nullptr);
    }
};

struct IrcTestState {
    std::mutex mutex;
    std::vector<int> statuses;
    std::vector<std::vector<std::string>> user_lists;
    std::vector<std::string> joined;
    std::vector<std::string> parted;
    std::vector<std::string> error_messages;
    std::vector<std::string> tox_messages;
};

std::string publicIrcSuffix() {
    const auto now = std::chrono::steady_clock::now().time_since_epoch().count();
    std::ostringstream stream;
    stream << std::hex << now;
    std::string suffix = stream.str();
    if (suffix.size() > 8) suffix = suffix.substr(suffix.size() - 8);
    return suffix;
}

}  // namespace

TEST_F(IrcClientManagerTest, JoinsAfterPrefixedWelcomeAndPublishesNames) {
    FakeIrcServer server;
    auto state = std::make_shared<IrcTestState>();

    auto& manager = IrcClientManager::getInstance();
    manager.setConnectionStatusCallback(
        [state](const std::string&, IrcClientManager::ConnectionStatus status,
            const std::string&) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->statuses.push_back(static_cast<int>(status));
        });
    manager.setUserListCallback(
        [state](const std::string&, const std::vector<std::string>& users) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->user_lists.push_back(users);
        });

    ASSERT_TRUE(manager.connectChannel("127.0.0.1", server.port(), "#test", "",
                                       "group_test", "", "", false,
                                       "toxee_test"));
    ASSERT_TRUE(server.waitForCommandContaining("NICK toxee_test"));

    server.sendLine(":irc.example 001 toxee_test :Welcome to IRC");
    ASSERT_TRUE(server.waitForCommandContaining("JOIN #test"));
    server.sendLine(":toxee_test!u@h JOIN :#test");
    server.sendLine(":irc.example 353 toxee_test = #test :@alice +bob carol");
    server.sendLine(":irc.example 366 toxee_test #test :End of /NAMES list.");

    ASSERT_TRUE(waitUntil([&] {
        std::lock_guard<std::mutex> lock(state->mutex);
        return std::any_of(state->statuses.begin(), state->statuses.end(), [](int status) {
                   return status == static_cast<int>(
                                        IrcClientManager::ConnectionStatus::
                                            Connected);
               }) &&
               !state->user_lists.empty() && state->user_lists.back().size() == 3;
    }));

    std::lock_guard<std::mutex> lock(state->mutex);
    EXPECT_EQ(state->user_lists.back(), (std::vector<std::string>{"alice", "bob",
                                                                  "carol"}));
}

TEST_F(IrcClientManagerTest, TracksJoinPartAndChannelErrorsWithPrefixedLines) {
    FakeIrcServer server;
    auto state = std::make_shared<IrcTestState>();

    auto& manager = IrcClientManager::getInstance();
    manager.setUserJoinPartCallback(
        [state](const std::string&, const std::string& nick, bool is_join) {
            std::lock_guard<std::mutex> lock(state->mutex);
            (is_join ? state->joined : state->parted).push_back(nick);
        });
    manager.setConnectionStatusCallback(
        [state](const std::string&, IrcClientManager::ConnectionStatus status,
            const std::string& message) {
            if (status == IrcClientManager::ConnectionStatus::Error) {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->error_messages.push_back(message);
            }
        });

    ASSERT_TRUE(manager.connectChannel("127.0.0.1", server.port(), "#test", "",
                                       "group_test", "", "", false,
                                       "toxee_test"));
    ASSERT_TRUE(server.waitForCommandContaining("NICK toxee_test"));

    server.sendLine(":irc.example 001 toxee_test :Welcome to IRC");
    ASSERT_TRUE(server.waitForCommandContaining("JOIN #test"));
    server.sendLine(":alice!u@h JOIN #test");
    server.sendLine(":alice!u@h PART #test :bye");
    server.sendLine(":irc.example 475 toxee_test #test :Cannot join channel (+k)");

    ASSERT_TRUE(waitUntil([&] {
        std::lock_guard<std::mutex> lock(state->mutex);
        return state->joined == std::vector<std::string>{"alice"} &&
               state->parted == std::vector<std::string>{"alice"} &&
               !state->error_messages.empty();
    }));
}

TEST_F(IrcClientManagerTest, SendsSingleJoinAcrossWelcomeBurst) {
    FakeIrcServer server;
    auto& manager = IrcClientManager::getInstance();

    ASSERT_TRUE(manager.connectChannel("127.0.0.1", server.port(), "#test", "",
                                       "group_test", "", "", false,
                                       "toxee_test"));
    ASSERT_TRUE(server.waitForCommandContaining("NICK toxee_test"));

    server.sendLine(":irc.example 001 toxee_test :Welcome to IRC");
    server.sendLine(":irc.example 002 toxee_test :Your host is irc.example");
    server.sendLine(":irc.example 003 toxee_test :This server was created today");

    ASSERT_TRUE(server.waitForCommandContaining("JOIN #test"));
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    EXPECT_EQ(server.commandCountContaining("JOIN #test"), 1);
}

TEST_F(IrcClientManagerTest, BridgesMessagesBothDirectionsAfterJoin) {
    FakeIrcServer server;
    auto state = std::make_shared<IrcTestState>();

    auto& manager = IrcClientManager::getInstance();
    manager.setToxMessageCallback(
        [state](const std::string& group_id, const std::string& sender,
                const std::string& message) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->tox_messages.push_back(group_id + "|" + sender + "|" +
                                          message);
        });

    ASSERT_TRUE(manager.connectChannel("127.0.0.1", server.port(), "#test", "",
                                       "group_test", "", "", false,
                                       "toxee_test"));
    ASSERT_TRUE(server.waitForCommandContaining("NICK toxee_test"));
    server.sendLine(":irc.example 001 toxee_test :Welcome to IRC");
    ASSERT_TRUE(server.waitForCommandContaining("JOIN #test"));
    server.sendLine(":toxee_test!u@h JOIN #test");
    ASSERT_TRUE(waitUntil([&] { return manager.isChannelConnected("#test"); }));

    manager.onToxGroupMessage("group_test", "local_user", "hello irc");
    EXPECT_TRUE(server.waitForCommandContaining("PRIVMSG #test :hello irc"));

    server.sendLine(":alice!u@h PRIVMSG #test :hello tox");
    ASSERT_TRUE(waitUntil([&] {
        std::lock_guard<std::mutex> lock(state->mutex);
        return state->tox_messages ==
               std::vector<std::string>{"group_test|alice|hello tox"};
    }));
}

TEST_F(IrcClientManagerTest, JoinsBridgesMessagesAndQuitsIrcSession) {
    FakeIrcServer server;
    auto state = std::make_shared<IrcTestState>();

    auto& manager = IrcClientManager::getInstance();
    manager.setToxMessageCallback(
        [state](const std::string& group_id, const std::string& sender,
                const std::string& message) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->tox_messages.push_back(group_id + "|" + sender + "|" +
                                          message);
        });

    ASSERT_TRUE(manager.connectChannel("127.0.0.1", server.port(), "#test", "",
                                       "group_test", "", "", false,
                                       "toxee_test"));
    ASSERT_TRUE(server.waitForCommandContaining("NICK toxee_test"));

    server.sendLine(":irc.example 001 toxee_test :Welcome to IRC");
    ASSERT_TRUE(server.waitForCommandContaining("JOIN #test"));
    server.sendLine(":toxee_test!u@h JOIN #test");
    ASSERT_TRUE(waitUntil([&] { return manager.isChannelConnected("#test"); }));

    manager.onToxGroupMessage("group_test", "local_user", "hello irc");
    ASSERT_TRUE(server.waitForCommandContaining("PRIVMSG #test :hello irc"));

    server.sendLine(":alice!u@h PRIVMSG #test :hello tox");
    ASSERT_TRUE(waitUntil([&] {
        std::lock_guard<std::mutex> lock(state->mutex);
        return state->tox_messages ==
               std::vector<std::string>{"group_test|alice|hello tox"};
    }));

    ASSERT_TRUE(manager.disconnectChannel("#test"));
    EXPECT_TRUE(server.waitForCommandContaining("QUIT :Disconnecting from IRC"));
}

TEST_F(IrcClientManagerTest, DISABLED_PublicIrcJoinSendReceiveAndQuit) {
    ASSERT_NE(std::getenv("TIM2TOX_RUN_PUBLIC_IRC_TEST"), nullptr)
        << "Set TIM2TOX_RUN_PUBLIC_IRC_TEST=1 to run against public IRC.";

    const std::string server =
        std::getenv("TIM2TOX_PUBLIC_IRC_SERVER")
            ? std::getenv("TIM2TOX_PUBLIC_IRC_SERVER")
            : "irc.oftc.net";
    const int port = std::getenv("TIM2TOX_PUBLIC_IRC_PORT")
                         ? std::atoi(std::getenv("TIM2TOX_PUBLIC_IRC_PORT"))
                         : 6697;
    const bool use_ssl = !std::getenv("TIM2TOX_PUBLIC_IRC_NO_SSL");
    const std::string suffix = publicIrcSuffix();
    const std::string channel = "#toxee-smoke-" + suffix;
    const std::string manager_nick = "toxM" + suffix;
    const std::string peer_nick = "toxP" + suffix;
    const std::string manager_to_peer = "toxee-public-manager-" + suffix;
    const std::string peer_to_manager = "toxee-public-peer-" + suffix;
    auto state = std::make_shared<IrcTestState>();

    PublicIrcPeer peer(server, port, use_ssl, peer_nick);
    peer.join(channel);

    auto& manager = IrcClientManager::getInstance();
    manager.setToxMessageCallback(
        [state](const std::string& group_id, const std::string& sender,
                const std::string& message) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->tox_messages.push_back(group_id + "|" + sender + "|" +
                                          message);
        });

    ASSERT_TRUE(manager.connectChannel(server, port, channel, "",
                                       "public_group", "", "", use_ssl,
                                       manager_nick));
    ASSERT_TRUE(peer.waitForJoin(manager_nick, channel, std::chrono::seconds(30)));
    ASSERT_TRUE(waitUntil([&] { return manager.isChannelConnected(channel); },
                          std::chrono::milliseconds(90000)));

    manager.onToxGroupMessage("public_group", "local_user", manager_to_peer);
    ASSERT_TRUE(peer.waitForPrivmsg(channel, manager_nick, manager_to_peer,
                                    std::chrono::seconds(45)));

    peer.privmsg(channel, peer_to_manager);
    ASSERT_TRUE(waitUntil([&] {
        std::lock_guard<std::mutex> lock(state->mutex);
        return std::find(state->tox_messages.begin(), state->tox_messages.end(),
                         "public_group|" + peer_nick + "|" +
                             peer_to_manager) != state->tox_messages.end();
    }, std::chrono::milliseconds(45000)));

    ASSERT_TRUE(manager.disconnectChannel(channel));
    ASSERT_TRUE(peer.waitForQuit(manager_nick, std::chrono::seconds(45)));
    peer.quit("public test complete");
}
