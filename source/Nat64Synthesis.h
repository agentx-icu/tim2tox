#ifndef TIM2TOX_NAT64_SYNTHESIS_H
#define TIM2TOX_NAT64_SYNTHESIS_H

// IPv6-only (DNS64/NAT64) support for bootstrap addresses.
//
// toxcore resolves a bootstrap host with net_getipport(): an IPv4 LITERAL is
// parsed directly and never reaches getaddrinfo (network.c), and IPv4
// destinations are then sent as IPv4-mapped `::ffff:a.b.c.d` on the
// dual-stack socket. On an IPv6-only network without CLAT — Apple's App Review
// NAT64 network, iOS in general — that address has no route, so every
// IPv4-literal bootstrap node / TCP relay is dead there. Apple's documented
// fix is to hand the literal to getaddrinfo with AI_DEFAULT: iOS >= 9.2 /
// macOS >= 10.11.2 then return the NAT64-synthesized IPv6 address
// (64:ff9b::/96 or the network-specific prefix). Android IPv6-only networks
// run 464XLAT/CLAT, which gives the device an IPv4 path, so the literal works
// there as-is — synthesis is only attempted on Apple platforms.
//
// Ordering matters: toxcore keeps only the FIRST address added per public key
// for the onion bootstrap list (onion_client.c onion_add_bs_path_node) and the
// TCP relay list (TCP_connection.c add_tcp_relay_global), so the synthesized
// address must be tried BEFORE the original literal.

#include <string>
#include <vector>

#if !defined(_WIN32)
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#endif

namespace tim2tox::nat64 {

// Strict dotted-quad IPv4 literal: exactly four decimal octets 0..255, each 1-3
// digits, nothing else. Deliberately parsed by hand (no socket headers) so it is
// identical on every platform, Windows included.
inline bool IsIpv4Literal(const char* host) {
    if (host == nullptr || *host == '\0') return false;
    int octets = 0;
    const char* p = host;
    while (true) {
        int value = 0;
        int digits = 0;
        while (*p >= '0' && *p <= '9') {
            value = value * 10 + (*p - '0');
            if (++digits > 3 || value > 255) return false;
            ++p;
        }
        if (digits == 0) return false;
        ++octets;
        if (*p == '\0') return octets == 4;
        if (*p != '.' || octets == 4) return false;
        ++p;
    }
}

#if !defined(_WIN32)
// Pure filter over a getaddrinfo result list: the AF_INET6 addresses that are
// NOT IPv4-mapped (::ffff:0:0/96), formatted with inet_ntop, de-duplicated,
// in result order. For an IPv4-literal query every such address is a NAT64
// synthesis; IPv4 results and v4-mapped results are dropped.
inline std::vector<std::string> Ipv6StringsFromAddrinfo(const struct addrinfo* list) {
    std::vector<std::string> out;
    for (const struct addrinfo* ai = list; ai != nullptr; ai = ai->ai_next) {
        if (ai->ai_family != AF_INET6 || ai->ai_addr == nullptr ||
            ai->ai_addrlen < sizeof(struct sockaddr_in6)) {
            continue;
        }
        const auto* sin6 = reinterpret_cast<const struct sockaddr_in6*>(ai->ai_addr);
        if (IN6_IS_ADDR_V4MAPPED(&sin6->sin6_addr)) continue;
        char buf[INET6_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET6, &sin6->sin6_addr, buf, sizeof(buf)) == nullptr) continue;
        std::string s(buf);
        bool dup = false;
        for (const auto& existing : out) {
            if (existing == s) {
                dup = true;
                break;
            }
        }
        if (!dup) out.push_back(std::move(s));
    }
    return out;
}
#endif

// NAT64-synthesized IPv6 addresses for an IPv4 literal on the current network.
// Empty on non-Apple platforms, for anything that is not an IPv4 literal, on a
// network without NAT64 (getaddrinfo then returns only the IPv4 address), and
// on any error. Blocking like any getaddrinfo, but a literal needs no DNS query
// except the OS's cached NAT64 prefix discovery on an IPv6-only network.
inline std::vector<std::string> SynthesizedIpv6ForIpv4Literal(const char* host) {
#if defined(__APPLE__)
    if (!IsIpv4Literal(host)) return {};
    struct addrinfo hints = {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_flags = AI_DEFAULT;
    struct addrinfo* res = nullptr;
    if (getaddrinfo(host, nullptr, &hints, &res) != 0 || res == nullptr) return {};
    std::vector<std::string> out = Ipv6StringsFromAddrinfo(res);
    freeaddrinfo(res);
    return out;
#else
    (void)host;
    return {};
#endif
}

// The hosts to hand toxcore for one bootstrap node, in order: any NAT64
// synthesis of an IPv4 literal FIRST (see the ordering note above), then the
// original host. On every network without NAT64 this is exactly `{host}`.
inline std::vector<std::string> BootstrapHostCandidates(const char* host) {
    std::vector<std::string> out;
    if (host == nullptr) return out;
    out = SynthesizedIpv6ForIpv4Literal(host);
    out.emplace_back(host);
    return out;
}

}  // namespace tim2tox::nat64

#endif  // TIM2TOX_NAT64_SYNTHESIS_H
