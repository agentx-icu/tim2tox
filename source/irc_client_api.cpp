// irc_client_api.cpp
// IRC Client Dynamic Library API Implementation
#include "irc_client_api.h"
#include "IrcClientManager.h"
#include "V2TIMLog.h"
#include <cstdio>
#include <mutex>

namespace {
    irc_message_callback_t g_irc_callback = nullptr;
    void* g_irc_user_data = nullptr;
    tox_group_message_callback_t g_tox_callback = nullptr;
    void* g_tox_user_data = nullptr;
    irc_connection_status_callback_t g_connection_status_callback = nullptr;
    void* g_connection_status_user_data = nullptr;
    irc_user_list_callback_t g_user_list_callback = nullptr;
    void* g_user_list_user_data = nullptr;
    irc_user_join_part_callback_t g_user_join_part_callback = nullptr;
    void* g_user_join_part_user_data = nullptr;
    std::mutex g_callback_mutex;
}

extern "C" {

int irc_client_init(void) {
    // Set up callbacks
    IrcClientManager::getInstance().setToxMessageCallback([](const std::string& group_id, const std::string& sender_nick, const std::string& message) {
        irc_message_callback_t callback = nullptr;
        void* user_data = nullptr;
        {
            std::lock_guard<std::mutex> lock(g_callback_mutex);
            callback = g_irc_callback;
            user_data = g_irc_user_data;
        }
        if (callback) {
            callback(group_id.c_str(), sender_nick.c_str(), message.c_str(), user_data);
        }
    });
    
    // Set up connection status callback
    IrcClientManager::getInstance().setConnectionStatusCallback([](const std::string& channel, IrcClientManager::ConnectionStatus status, const std::string& message) {
        irc_connection_status_t c_status;
        switch (status) {
            case IrcClientManager::ConnectionStatus::Disconnected:
                c_status = IRC_CONNECTION_DISCONNECTED;
                break;
            case IrcClientManager::ConnectionStatus::Connecting:
                c_status = IRC_CONNECTION_CONNECTING;
                break;
            case IrcClientManager::ConnectionStatus::Connected:
                c_status = IRC_CONNECTION_CONNECTED;
                break;
            case IrcClientManager::ConnectionStatus::Authenticating:
                c_status = IRC_CONNECTION_AUTHENTICATING;
                break;
            case IrcClientManager::ConnectionStatus::Reconnecting:
                c_status = IRC_CONNECTION_RECONNECTING;
                break;
            case IrcClientManager::ConnectionStatus::Error:
                c_status = IRC_CONNECTION_ERROR;
                break;
            default:
                c_status = IRC_CONNECTION_DISCONNECTED;
                break;
        }
        irc_connection_status_callback_t callback = nullptr;
        void* user_data = nullptr;
        {
            std::lock_guard<std::mutex> lock(g_callback_mutex);
            callback = g_connection_status_callback;
            user_data = g_connection_status_user_data;
        }
        if (callback) {
            callback(channel.c_str(), c_status, message.empty() ? nullptr : message.c_str(), user_data);
        }
    });
    
    // Set up user list callback
    IrcClientManager::getInstance().setUserListCallback([](const std::string& channel, const std::vector<std::string>& users) {
        std::string users_str;
        for (size_t i = 0; i < users.size(); ++i) {
            if (i > 0) users_str += ",";
            users_str += users[i];
        }
        irc_user_list_callback_t callback = nullptr;
        void* user_data = nullptr;
        {
            std::lock_guard<std::mutex> lock(g_callback_mutex);
            callback = g_user_list_callback;
            user_data = g_user_list_user_data;
        }
        if (callback) {
            callback(channel.c_str(), users_str.empty() ? nullptr : users_str.c_str(), user_data);
        }
    });
    
    // Set up user join/part callback
    IrcClientManager::getInstance().setUserJoinPartCallback([](const std::string& channel, const std::string& nickname, bool joined) {
        irc_user_join_part_callback_t callback = nullptr;
        void* user_data = nullptr;
        {
            std::lock_guard<std::mutex> lock(g_callback_mutex);
            callback = g_user_join_part_callback;
            user_data = g_user_join_part_user_data;
        }
        if (callback) {
            callback(channel.c_str(), nickname.c_str(), joined ? 1 : 0, user_data);
        }
    });
    
    return 1;
}

void irc_client_shutdown(void) {
    V2TIM_LOG(kInfo, "[IRC API] Shutting down IRC client library");
    IrcClientManager::getInstance().shutdown();
}

int irc_client_connect_channel(const char* server, int port, const char* channel, const char* password, const char* group_id, const char* sasl_username, const char* sasl_password, int use_ssl, const char* custom_nickname) {
    if (!server || !channel || !group_id) {
        V2TIM_LOG(kError, "[IRC API] connect_channel: invalid parameters");
        return 0;
    }

    std::string password_str = password ? password : "";
    std::string server_str = server;
    std::string sasl_username_str = sasl_username ? sasl_username : "";
    std::string sasl_password_str = sasl_password ? sasl_password : "";
    std::string custom_nickname_str = custom_nickname ? custom_nickname : "";
    bool use_ssl_bool = (use_ssl != 0);

    if (server_str.empty()) {
        server_str = "irc.libera.chat";
    }

    if (port <= 0) {
        port = use_ssl_bool ? 6697 : 6667;
    }

    std::string nick_suffix = !custom_nickname_str.empty() ? (" (nick: " + custom_nickname_str + ")") : "";
    V2TIM_LOG(kInfo, "[IRC API] connect_channel: connecting to {}:{}, channel {}, group_id {}{}{}{}",
              server_str, port, channel, group_id,
              (!sasl_username_str.empty()) ? " (with SASL)" : "",
              use_ssl_bool ? " (with SSL)" : "",
              nick_suffix);

    bool result = IrcClientManager::getInstance().connectChannel(
        server_str, port, channel, password_str, group_id, sasl_username_str, sasl_password_str, use_ssl_bool, custom_nickname_str);

    if (result) {
        V2TIM_LOG(kInfo, "[IRC API] connect_channel: success");
    } else {
        V2TIM_LOG(kError, "[IRC API] connect_channel: failed");
    }

    return result ? 1 : 0;
}

int irc_client_disconnect_channel(const char* channel) {
    if (!channel) {
        return 0;
    }

    V2TIM_LOG(kInfo, "[IRC API] disconnect_channel: disconnecting {}", channel);

    bool result = IrcClientManager::getInstance().disconnectChannel(channel);
    return result ? 1 : 0;
}

int irc_client_send_message(const char* channel, const char* message) {
    if (!channel || !message) {
        return 0;
    }
    
    bool result = IrcClientManager::getInstance().sendMessage(channel, message);
    return result ? 1 : 0;
}

int irc_client_is_connected(const char* channel) {
    if (!channel) {
        return 0;
    }
    
    bool result = IrcClientManager::getInstance().isChannelConnected(channel);
    return result ? 1 : 0;
}

void irc_client_set_message_callback(irc_message_callback_t callback, void* user_data) {
    std::lock_guard<std::mutex> lock(g_callback_mutex);
    g_irc_callback = callback;
    g_irc_user_data = user_data;
}

void irc_client_set_tox_message_callback(tox_group_message_callback_t callback, void* user_data) {
    std::lock_guard<std::mutex> lock(g_callback_mutex);
    g_tox_callback = callback;
    g_tox_user_data = user_data;
    
    // Set up callback in IrcClientManager to forward Tox messages to IRC
    // The callback will be called from V2TIMManagerImpl when sending group messages
    // For now, we just store it - the actual forwarding happens in onToxGroupMessage
    // which is called from V2TIMManagerImpl
}

int irc_client_forward_tox_message(const char* group_id, const char* sender, const char* message) {
    if (!group_id || !sender || !message) {
        return 0;
    }
    
    // Forward to IrcClientManager
    IrcClientManager::getInstance().onToxGroupMessage(group_id, sender, message);
    return 1;
}

void irc_client_set_connection_status_callback(irc_connection_status_callback_t callback, void* user_data) {
    std::lock_guard<std::mutex> lock(g_callback_mutex);
    g_connection_status_callback = callback;
    g_connection_status_user_data = user_data;
}

void irc_client_set_user_list_callback(irc_user_list_callback_t callback, void* user_data) {
    std::lock_guard<std::mutex> lock(g_callback_mutex);
    g_user_list_callback = callback;
    g_user_list_user_data = user_data;
}

void irc_client_set_user_join_part_callback(irc_user_join_part_callback_t callback, void* user_data) {
    std::lock_guard<std::mutex> lock(g_callback_mutex);
    g_user_join_part_callback = callback;
    g_user_join_part_user_data = user_data;
}

} // extern "C"
