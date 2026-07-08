// IrcClientManager.h
#pragma once

#include <string>
#include <unordered_map>
#include <mutex>
#include <thread>
#include <atomic>
#include <memory>
#include <functional>
#include <vector>
#include <chrono>

// Forward declarations
struct IrcChannel;
struct ssl_st;
typedef struct ssl_st SSL;
struct ssl_ctx_st;
typedef struct ssl_ctx_st SSL_CTX;

class IrcClientManager {
public:
    // 删除拷贝构造函数和赋值运算符
    IrcClientManager(const IrcClientManager&) = delete;
    IrcClientManager& operator=(const IrcClientManager&) = delete;

    // 获取单例实例
    static IrcClientManager& getInstance();

    // 连接IRC服务器并加入频道
    // server: IRC服务器地址（如 "irc.libera.chat"）
    // port: IRC服务器端口（默认6667，6697 for SSL）
    // channel: 频道名称（如 "#libera"）
    // password: 频道密码（可选）
    // group_id: 对应的Tox群组ID
    // sasl_username: SASL认证用户名（可选，如果提供则启用SASL）
    // sasl_password: SASL认证密码（可选，如果提供则启用SASL）
    // use_ssl: 是否使用SSL/TLS连接（默认false）
    // custom_nickname: 自定义昵称（可选，如果不提供则自动生成）
    // Returns: true on success, false on failure
    bool connectChannel(const std::string& server, int port, 
                       const std::string& channel, 
                       const std::string& password,
                       const std::string& group_id,
                       const std::string& sasl_username = "",
                       const std::string& sasl_password = "",
                       bool use_ssl = false,
                       const std::string& custom_nickname = "");

    // 断开IRC频道连接
    // channel: 频道名称
    // Returns: true on success, false if channel not found
    bool disconnectChannel(const std::string& channel);

    // 发送消息到IRC频道
    // channel: 频道名称
    // message: 消息内容
    // Returns: true on success, false on failure
    bool sendMessage(const std::string& channel, const std::string& message);

    // 检查频道是否已连接
    bool isChannelConnected(const std::string& channel) const;

    // 设置Tox消息回调（当收到IRC消息时，调用此回调发送到Tox群组）
    // callback: function(group_id, sender_nick, message)
    void setToxMessageCallback(std::function<void(const std::string&, const std::string&, const std::string&)> callback);

    // 设置Tox群组消息回调（当收到Tox群组消息时，转发到IRC）
    // callback: function(group_id, sender, message) or nullptr to disable
    void setToxGroupMessageCallback(std::function<void(const std::string&, const std::string&, const std::string&)> callback);

    // 连接状态枚举
    enum class ConnectionStatus {
        Disconnected,    // 未连接
        Connecting,     // 连接中
        Connected,      // 已连接
        Authenticating, // 认证中
        Reconnecting,   // 重连中
        Error           // 错误
    };

    // 设置连接状态回调
    // callback: function(channel, status, message)
    typedef std::function<void(const std::string&, ConnectionStatus, const std::string&)> ConnectionStatusCallback;
    void setConnectionStatusCallback(ConnectionStatusCallback callback);

    // 设置用户列表更新回调
    // callback: function(channel, users) - users is vector of nicknames
    typedef std::function<void(const std::string&, const std::vector<std::string>&)> UserListCallback;
    void setUserListCallback(UserListCallback callback);

    // 设置用户加入/离开回调
    // callback: function(channel, nickname, joined) - joined=true for join, false for part
    typedef std::function<void(const std::string&, const std::string&, bool)> UserJoinPartCallback;
    void setUserJoinPartCallback(UserJoinPartCallback callback);

    // 设置自定义昵称（如果不设置，使用自动生成的昵称）
    void setCustomNickname(const std::string& channel, const std::string& nickname);

    // 获取用户列表
    std::vector<std::string> getUserList(const std::string& channel) const;

    // 处理Tox群组消息（转发到IRC）
    // 这个回调会在V2TIMMessageManagerImpl中注册
    void onToxGroupMessage(const std::string& group_id, const std::string& sender, const std::string& message);

    // 清理所有连接
    void shutdown();

private:
    IrcClientManager();
    ~IrcClientManager();

    // 内部频道结构
    struct IrcChannel {
        std::string server;
        int port;
        std::string channel;
        std::string password;
        std::string group_id;
        std::string sasl_username;
        std::string sasl_password;
        std::string custom_nickname;
        bool use_sasl;
        bool use_ssl;
        bool sasl_authenticated;
        bool join_sent;
        std::atomic<int> sock_fd;
        void* ssl_ctx;  // SSL_CTX* for SSL connections
        void* ssl;      // SSL* for SSL connections
        mutable std::mutex io_mutex;
        mutable std::mutex lifecycle_mutex;
        std::atomic<bool> connected;
        std::atomic<bool> should_stop;
        std::atomic<ConnectionStatus> status;
        std::unique_ptr<std::thread> thread;
        
        // 重连相关
        int reconnect_attempts;
        std::chrono::steady_clock::time_point last_reconnect_time;
        static constexpr int max_reconnect_attempts = 10;
        static constexpr int reconnect_delay_seconds = 5;
        
        // 用户列表
        std::vector<std::string> user_list;
        mutable std::mutex user_list_mutex;
        
        // 昵称冲突处理
        std::string base_nickname;
        int nickname_suffix;
        
        IrcChannel() : port(6667), use_sasl(false), use_ssl(false),
                      sasl_authenticated(false), join_sent(false), sock_fd(-1),
                      ssl_ctx(nullptr), ssl(nullptr), connected(false),
                      should_stop(false), status(ConnectionStatus::Disconnected),
                      reconnect_attempts(0),
                      nickname_suffix(0) {}
    };

    // 频道处理线程
    void channelThread(IrcChannel* channel);

    // 连接到IRC服务器
    int connectToServer(const std::string& server, int port, bool use_ssl = false);

    // 发送IRC命令（重载：使用socket）
    bool sendIrcCommand(int sock, const std::string& command);
    
    // 发送IRC命令（重载：使用channel，支持SSL）
    bool sendIrcCommand(IrcChannel* channel, const std::string& command);

    // 发送 JOIN，避免 welcome burst 或 SASL completion 重复加入同一频道
    bool sendJoinIfNeeded(IrcChannel* channel);

    // 执行SSL/TLS握手（如果使用SSL）
    bool performSslHandshake(IrcChannel* channel);
    
    // SSL发送数据
    ssize_t sslSend(SSL* ssl, const void* buf, size_t len);
    
    // SSL接收数据
    ssize_t sslRecv(SSL* ssl, void* buf, size_t len);

    // 内部辅助函数：发送消息但不加锁（调用者必须持有mutex）
    bool sendMessageUnlocked(const std::string& channel, const std::string& message);

    // 处理IRC消息
    void processIrcMessage(IrcChannel* channel, const std::string& line);

    // 解析PRIVMSG
    void handlePrivmsg(IrcChannel* channel, const std::string& line);

    // 处理PING
    void handlePing(IrcChannel* channel, const std::string& line);

    // 处理SASL认证
    void handleSaslAuth(IrcChannel* channel, const std::string& line);

    // Base64编码（用于SASL）
    std::string base64Encode(const std::string& data);

    // 处理昵称冲突
    void handleNickConflict(IrcChannel* channel);

    // 自动重连
    void attemptReconnect(IrcChannel* channel);

    // 更新连接状态
    void updateConnectionStatus(IrcChannel* channel, ConnectionStatus status, const std::string& message = "");

    // 处理NAMES命令响应
    void handleNamesResponse(IrcChannel* channel, const std::string& line);

    // 处理JOIN/PART消息
    void handleJoinPart(IrcChannel* channel, const std::string& line, bool is_join);

    // 生成昵称
    std::string generateNickname(IrcChannel* channel);

    mutable std::mutex mutex_;
    std::unordered_map<std::string, std::shared_ptr<IrcChannel>> channels_;
    bool shutting_down_ = false;
    std::function<void(const std::string&, const std::string&, const std::string&)> tox_message_callback_;
    std::function<void(const std::string&, const std::string&, const std::string&)> tox_group_message_callback_;
    ConnectionStatusCallback connection_status_callback_;
    UserListCallback user_list_callback_;
    UserJoinPartCallback user_join_part_callback_;
};
