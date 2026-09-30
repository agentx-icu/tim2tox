#include <gtest/gtest.h>

#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "Nat64Synthesis.h"

#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH must point to ffi/tim2tox_ffi.cpp"
#endif

using tim2tox::nat64::BootstrapHostCandidates;
using tim2tox::nat64::IsIpv4Literal;

TEST(Nat64SynthesisTest, Ipv4LiteralParserIsStrict) {
    EXPECT_TRUE(IsIpv4Literal("144.217.167.73"));
    EXPECT_TRUE(IsIpv4Literal("0.0.0.0"));
    EXPECT_TRUE(IsIpv4Literal("255.255.255.255"));
    EXPECT_TRUE(IsIpv4Literal("001.002.003.004"));

    EXPECT_FALSE(IsIpv4Literal(nullptr));
    EXPECT_FALSE(IsIpv4Literal(""));
    EXPECT_FALSE(IsIpv4Literal("256.1.1.1"));
    EXPECT_FALSE(IsIpv4Literal("1.2.3"));
    EXPECT_FALSE(IsIpv4Literal("1.2.3.4.5"));
    EXPECT_FALSE(IsIpv4Literal("1.2.3.4."));
    EXPECT_FALSE(IsIpv4Literal(".1.2.3.4"));
    EXPECT_FALSE(IsIpv4Literal("1..2.3"));
    EXPECT_FALSE(IsIpv4Literal("1.2.3.0004"));
    EXPECT_FALSE(IsIpv4Literal("1.2.3.4 "));
    EXPECT_FALSE(IsIpv4Literal("tox.abilinski.com"));
    EXPECT_FALSE(IsIpv4Literal("2400:8902::f03c:93ff:fe69:bf77"));
    EXPECT_FALSE(IsIpv4Literal("::ffff:1.2.3.4"));
}

TEST(Nat64SynthesisTest, NonLiteralsAreNeverExpanded) {
    for (const char* host : {"tox.abilinski.com", "2600:3c04::f03c:92ff:fe30:5df",
                             "localhost", "not a host"}) {
        const std::vector<std::string> candidates = BootstrapHostCandidates(host);
        ASSERT_EQ(candidates.size(), 1u) << host;
        EXPECT_EQ(candidates[0], host);
    }
    EXPECT_TRUE(BootstrapHostCandidates(nullptr).empty());
}

TEST(Nat64SynthesisTest, Ipv4LiteralEndsWithTheLiteralAndNeverYieldsMappedOrV4) {
    // The test host is not on a NAT64 network, so on Apple getaddrinfo returns
    // only the IPv4 address and the list is just {literal}; elsewhere synthesis
    // is never attempted. Either way: the literal is LAST and nothing before it
    // is an IPv4 or IPv4-mapped address.
    const std::vector<std::string> candidates = BootstrapHostCandidates("192.0.2.1");
    ASSERT_FALSE(candidates.empty());
    EXPECT_EQ(candidates.back(), "192.0.2.1");
    for (size_t i = 0; i + 1 < candidates.size(); ++i) {
        EXPECT_FALSE(IsIpv4Literal(candidates[i].c_str())) << candidates[i];
        EXPECT_EQ(candidates[i].find("::ffff:"), std::string::npos) << candidates[i];
    }
}

#if !defined(_WIN32)
namespace {

struct FakeAddrinfoChain {
    std::vector<sockaddr_in> v4;
    std::vector<sockaddr_in6> v6;
    std::vector<addrinfo> nodes;

    // Built in two passes so the vectors never reallocate under the pointers.
    FakeAddrinfoChain(const std::vector<const char*>& v4_addrs,
                      const std::vector<const char*>& v6_addrs) {
        v4.resize(v4_addrs.size());
        v6.resize(v6_addrs.size());
        for (size_t i = 0; i < v4_addrs.size(); ++i) {
            std::memset(&v4[i], 0, sizeof(v4[i]));
            v4[i].sin_family = AF_INET;
            EXPECT_EQ(inet_pton(AF_INET, v4_addrs[i], &v4[i].sin_addr), 1);
        }
        for (size_t i = 0; i < v6_addrs.size(); ++i) {
            std::memset(&v6[i], 0, sizeof(v6[i]));
            v6[i].sin6_family = AF_INET6;
            EXPECT_EQ(inet_pton(AF_INET6, v6_addrs[i], &v6[i].sin6_addr), 1);
        }
        nodes.resize(v4.size() + v6.size());
        size_t n = 0;
        // Interleave: v4 first, then the v6 entries, like a real UNSPEC answer.
        for (auto& a : v4) {
            std::memset(&nodes[n], 0, sizeof(addrinfo));
            nodes[n].ai_family = AF_INET;
            nodes[n].ai_addr = reinterpret_cast<sockaddr*>(&a);
            nodes[n].ai_addrlen = sizeof(a);
            ++n;
        }
        for (auto& a : v6) {
            std::memset(&nodes[n], 0, sizeof(addrinfo));
            nodes[n].ai_family = AF_INET6;
            nodes[n].ai_addr = reinterpret_cast<sockaddr*>(&a);
            nodes[n].ai_addrlen = sizeof(a);
            ++n;
        }
        for (size_t i = 0; i + 1 < nodes.size(); ++i) nodes[i].ai_next = &nodes[i + 1];
    }
    const addrinfo* head() const { return nodes.empty() ? nullptr : &nodes[0]; }
};

}  // namespace

TEST(Nat64SynthesisTest, AddrinfoFilterKeepsOnlySynthesizedIpv6) {
    // What an Apple NAT64 answer for the literal 1.2.3.4 can contain: the
    // IPv4 address, an IPv4-mapped duplicate, and the synthesized address
    // (possibly repeated for several socket types).
    FakeAddrinfoChain chain({"1.2.3.4"},
                            {"::ffff:1.2.3.4", "64:ff9b::102:304", "64:ff9b::102:304",
                             "2001:db8:64::102:304"});
    const std::vector<std::string> out =
        tim2tox::nat64::Ipv6StringsFromAddrinfo(chain.head());
    ASSERT_EQ(out.size(), 2u);
    EXPECT_EQ(out[0], "64:ff9b::102:304");
    EXPECT_EQ(out[1], "2001:db8:64::102:304");
}

TEST(Nat64SynthesisTest, AddrinfoFilterOnPlainIpv4AnswerIsEmpty) {
    FakeAddrinfoChain chain({"1.2.3.4"}, {"::ffff:1.2.3.4"});
    EXPECT_TRUE(tim2tox::nat64::Ipv6StringsFromAddrinfo(chain.head()).empty());
    EXPECT_TRUE(tim2tox::nat64::Ipv6StringsFromAddrinfo(nullptr).empty());
}
#endif

namespace {

std::string ReadSource(const char* path) {
    std::ifstream input(path, std::ios::binary);
    EXPECT_TRUE(input.good()) << path;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

std::string FunctionBody(const std::string& source, const std::string& signature) {
    const size_t start = source.find(signature);
    if (start == std::string::npos) return {};
    const size_t open = source.find('{', start);
    if (open == std::string::npos) return {};
    int depth = 0;
    for (size_t i = open; i < source.size(); ++i) {
        if (source[i] == '{') ++depth;
        if (source[i] == '}' && --depth == 0) return source.substr(open, i - open + 1);
    }
    return {};
}

}  // namespace

// The FFI entry points need a live Tox instance to run, so pin their wiring:
// both must hand toxcore the NAT64 candidates, never the raw host directly.
TEST(Nat64SynthesisTest, FfiBootstrapEntryPointsUseTheCandidates) {
    const std::string source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string add = FunctionBody(
        source, "int tim2tox_ffi_add_bootstrap_node(int64_t instance_id, const char* host");
    ASSERT_FALSE(add.empty());
    EXPECT_NE(add.find("tim2tox::nat64::BootstrapHostCandidates(host)"), std::string::npos);
    EXPECT_EQ(add.find("tox_bootstrap(tox, host"), std::string::npos);
    EXPECT_EQ(add.find("tox_add_tcp_relay(tox, host"), std::string::npos);

    const std::string probe = FunctionBody(
        source, "int tim2tox_ffi_dht_send_nodes_request(const char* public_key, const char* ip");
    ASSERT_FALSE(probe.empty());
    EXPECT_NE(probe.find("tim2tox::nat64::BootstrapHostCandidates(ip)"), std::string::npos);
    EXPECT_EQ(probe.find("tox_dht_send_nodes_request(tox, public_key_bin, ip,"), std::string::npos);
}
