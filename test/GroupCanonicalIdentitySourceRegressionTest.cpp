#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_MANAGER_HEADER_PATH
#error "TIM2TOX_MANAGER_HEADER_PATH is required"
#endif

namespace {

std::string ReadSource(const char* path) {
    std::ifstream input(path, std::ios::binary);
    EXPECT_TRUE(input.good()) << path;
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

std::string SourceSection(
    const std::string& source,
    const char* start_marker,
    const char* end_marker) {
    const std::size_t start = source.find(start_marker);
    EXPECT_NE(start, std::string::npos) << start_marker;
    if (start == std::string::npos) return {};
    const std::size_t end = source.find(end_marker, start + 1);
    EXPECT_NE(end, std::string::npos) << end_marker;
    if (end == std::string::npos) return {};
    return source.substr(start, end - start);
}

TEST(GroupCanonicalIdentitySourceRegressionTest,
     PendingInviteJoinPublishesCanonicalGroupIdForStableChatId) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string header = ReadSource(TIM2TOX_MANAGER_HEADER_PATH);
    const std::string join = SourceSection(
        manager,
        "void V2TIMManagerImpl::JoinGroup(",
        "void V2TIMManagerImpl::QuitGroup(");
    const std::string pending_accept = SourceSection(
        join,
        "V2TIM_LOG(kInfo, \"[JoinGroup] tox_group_invite_accept returned:",
        "// Remove pending invite");
    const std::string auto_accept = SourceSection(
        manager,
        "V2TIM_LOG(kInfo, \"[GroupInvite] Tox instance available, proceeding with auto-accept\");",
        "// Also register old conference API callback");
    const std::string quit_group = SourceSection(
        manager,
        "void V2TIMManagerImpl::QuitGroup(",
        "void V2TIMManagerImpl::DismissGroup(");
    const std::string helper = SourceSection(
        manager,
        "V2TIMManagerImpl::CanonicalGroupIDForChatIdLocked(",
        "V2TIMManagerImpl::GetGroupIDFromChatId(");
    const std::string self_join = SourceSection(
        manager,
        "void V2TIMManagerImpl::HandleGroupSelfJoin(",
        "void V2TIMManagerImpl::HandleGroupJoinFail(");

    EXPECT_NE(header.find("IsTemporaryInviteGroupID("), std::string::npos);
    EXPECT_NE(header.find("CanonicalGroupIDForChatIdLocked("),
              std::string::npos);

    EXPECT_NE(helper.find("chat_id_to_group_id_"), std::string::npos);
    EXPECT_NE(helper.find("!IsTemporaryInviteGroupID("), std::string::npos);
    EXPECT_EQ(helper.find("tox_group_%"), std::string::npos);
    EXPECT_NE(manager.find("RememberCrossInstanceGroupIdentity("),
              std::string::npos);
    EXPECT_NE(manager.find("g_cross_instance_group_identity.find(chat_id_hex)"),
              std::string::npos);

    EXPECT_NE(join.find("V2TIMString publicGroupID = groupID;"),
              std::string::npos);
    EXPECT_NE(
        pending_accept.find(
            "publicGroupID = CanonicalGroupIDForChatIdLocked(groupID, chat_id_hex)"),
        std::string::npos);
    EXPECT_NE(
        pending_accept.find(
            "SetGroupChatIdInStorage(publicGroupID.CString(), chat_id_hex)"),
        std::string::npos);
    EXPECT_EQ(
        pending_accept.find(
            "SetGroupChatIdInStorage(groupID.CString(), chat_id_hex)"),
        std::string::npos);

    EXPECT_NE(join.find("group_number_to_group_id_[group_number] = publicGroupID"),
              std::string::npos);
    EXPECT_NE(join.find("group_id_to_group_number_[used_pending_id] = group_number"),
              std::string::npos);
    EXPECT_NE(join.find("listener->OnMemberInvited(publicGroupID"),
              std::string::npos);
    EXPECT_NE(join.find("EnsureGroupInfoExists(publicGroupID)"),
              std::string::npos);

    EXPECT_NE(auto_accept.find("group_id_to_group_number_[tempGroupID] = group_number"),
              std::string::npos);
    EXPECT_EQ(
        auto_accept.find(
            "SetGroupChatIdInStorage(tempGroupID.CString(), chat_id_hex)"),
        std::string::npos);
    EXPECT_EQ(auto_accept.find("group_id_to_chat_id_[tempGroupID]"),
              std::string::npos);
    EXPECT_EQ(auto_accept.find("chat_id_to_group_id_[chat_id_hex] = tempGroupID"),
              std::string::npos);

    EXPECT_NE(quit_group.find("group_id_to_group_number_.erase(groupID)"),
              std::string::npos);
    EXPECT_NE(
        quit_group.find("group_number_to_group_id_.erase(resolved_group_number)"),
        std::string::npos);
    EXPECT_NE(quit_group.find("const bool is_legacy_conference"),
              std::string::npos);
    EXPECT_NE(quit_group.find("if (is_legacy_conference)"),
              std::string::npos);
    EXPECT_NE(quit_group.find("group_id_to_chat_id_.erase(chat_it)"),
              std::string::npos);
    EXPECT_NE(quit_group.find("chat_id_to_group_id_.erase(chat_id_hex)"),
              std::string::npos);
    EXPECT_NE(quit_group.find("Preserve stable NGCv2 chat_id mappings"),
              std::string::npos);
    const std::size_t legacy_branch = quit_group.find("if (is_legacy_conference)");
    ASSERT_NE(legacy_branch, std::string::npos);
    const std::size_t preserved_branch = quit_group.find("} else {", legacy_branch);
    ASSERT_NE(preserved_branch, std::string::npos);
    const std::size_t preserved_branch_end =
        quit_group.find("group_id_to_type_.erase(groupID)", preserved_branch);
    ASSERT_NE(preserved_branch_end, std::string::npos);
    const std::string preserved_branch_source = quit_group.substr(
        preserved_branch, preserved_branch_end - preserved_branch);
    EXPECT_NE(
        preserved_branch_source.find(
            "Preserving canonical group chat_id mapping"),
        std::string::npos);
    EXPECT_EQ(preserved_branch_source.find("group_id_to_chat_id_.erase"),
              std::string::npos);
    EXPECT_EQ(preserved_branch_source.find("chat_id_to_group_id_.erase"),
              std::string::npos);

    EXPECT_NE(
        self_join.find(
            "canonicalGroupID = CanonicalGroupIDForChatIdLocked(groupID, chat_id_hex)"),
        std::string::npos);
    EXPECT_NE(self_join.find("group_number_to_group_id_[group_number] = canonicalGroupID"),
              std::string::npos);
    EXPECT_NE(self_join.find("SetGroupChatIdInStorage(groupID.CString(), chat_id_hex)"),
              std::string::npos);
    EXPECT_NE(
        self_join.find(
            "HandleGroupSelfJoin: refusing to publish temporary group alias"),
        std::string::npos);
    EXPECT_NE(self_join.find("DartNotifyGroupJoin(groupID.CString())"),
              std::string::npos);
    EXPECT_EQ(self_join.find("DartNotifyGroupJoin(tempGroupID"),
              std::string::npos);

    EXPECT_NE(join.find("inv.kind == PendingInviteKind::kConferenceAv"),
              std::string::npos);
    EXPECT_NE(join.find("inv.kind == PendingInviteKind::kConferenceText"),
              std::string::npos);
    EXPECT_NE(join.find("is_av_invite ? \"av_conference\" : \"conference\""),
              std::string::npos);
    EXPECT_NE(manager.find("toxav_join_av_groupchat("), std::string::npos);
    EXPECT_NE(manager.find("tox_conference_join("), std::string::npos);
}

}
