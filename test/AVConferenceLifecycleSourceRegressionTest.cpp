#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef TIM2TOX_MANAGER_SOURCE_PATH
#error "TIM2TOX_MANAGER_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_GROUP_MANAGER_SOURCE_PATH
#error "TIM2TOX_GROUP_MANAGER_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_MANAGER_HEADER_PATH
#error "TIM2TOX_MANAGER_HEADER_PATH is required"
#endif
#ifndef TIM2TOX_FFI_SOURCE_PATH
#error "TIM2TOX_FFI_SOURCE_PATH is required"
#endif
#ifndef TIM2TOX_FFI_HEADER_PATH
#error "TIM2TOX_FFI_HEADER_PATH is required"
#endif
#ifndef TIM2TOX_DART_FFI_PATH
#error "TIM2TOX_DART_FFI_PATH is required"
#endif
#ifndef TIM2TOX_DART_SERVICE_PATH
#error "TIM2TOX_DART_SERVICE_PATH is required"
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
    const std::size_t end = end_marker == nullptr
                                ? source.size()
                                : source.find(end_marker, start + 1);
    EXPECT_NE(end, std::string::npos) << (end_marker ? end_marker : "EOF");
    if (end == std::string::npos) return {};
    return source.substr(start, end - start);
}

TEST(AVConferenceLifecycleSourceRegressionTest,
     ConferenceCreationAndRetryPersistStableConferenceIds) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string group_manager = ReadSource(TIM2TOX_GROUP_MANAGER_SOURCE_PATH);
    const std::string create_conference = SourceSection(
        manager,
        "void V2TIMManagerImpl::CreateGroup(",
        "void V2TIMManagerImpl::JoinGroup(");
    const std::string group_manager_create = SourceSection(
        group_manager,
        "void V2TIMGroupManagerImpl::CreateGroup(",
        "void V2TIMGroupManagerImpl::GetGroupsInfo(");
    const std::string av_join = SourceSection(
        manager,
        "                // Join AV conference using toxav_join_av_groupchat",
        "                // Store group type for this conference (both in memory and persistent)");
    const std::string text_join = SourceSection(
        manager,
        "            // For TEXT type, use tox_conference_join",
        "            // Store group type for this conference (both in memory and persistent)");
    const std::string manual_join = SourceSection(
        manager,
        "void V2TIMManagerImpl::JoinGroup(",
        "void V2TIMManagerImpl::QuitGroup(");
    const std::string identity_helper = SourceSection(
        manager,
        "bool V2TIMManagerImpl::StoreConferenceIdentity(",
        "#ifdef BUILD_TOXAV");

    EXPECT_NE(identity_helper.find("getConferenceId("), std::string::npos);
    EXPECT_NE(identity_helper.find("SetGroupChatIdInStorage("), std::string::npos);
    EXPECT_NE(identity_helper.find("group_id_to_chat_id_"), std::string::npos);
    EXPECT_NE(identity_helper.find("chat_id_to_group_id_"), std::string::npos);

    EXPECT_NE(create_conference.find("tox_conference_new("), std::string::npos);
    EXPECT_NE(create_conference.find("toxav_add_av_groupchat("), std::string::npos);
    EXPECT_NE(create_conference.find("StoreConferenceIdentity(finalGroupID, group_number)"),
              std::string::npos);
    EXPECT_NE(group_manager_create.find(
                  "manager_impl_->StoreConferenceIdentity(finalGroupID"),
              std::string::npos);

    EXPECT_NE(av_join.find("toxav_join_av_groupchat("), std::string::npos);
    EXPECT_NE(av_join.find("StoreConferenceIdentity("), std::string::npos);

    EXPECT_NE(text_join.find("tox_conference_join("), std::string::npos);
    EXPECT_NE(text_join.find("StoreConferenceIdentity(groupID"), std::string::npos);

    EXPECT_NE(manual_join.find("PendingInviteKind::kConferenceText"),
              std::string::npos);
    EXPECT_NE(manual_join.find("PendingInviteKind::kConferenceAv"),
              std::string::npos);
    EXPECT_NE(manual_join.find("StoreConferenceIdentity(groupID"),
              std::string::npos);
}

TEST(AVConferenceLifecycleSourceRegressionTest,
     StableConferenceIdentityMatchesPersistedIdsBeforeTypeFallback) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string peer_list_changed = SourceSection(
        manager,
        "void V2TIMManagerImpl::HandleGroupPeerListChanged(",
        "void V2TIMManagerImpl::HandleGroupConnected(");
    const std::string rejoin = SourceSection(
        manager,
        "void V2TIMManagerImpl::RejoinKnownGroups()",
        nullptr);

    EXPECT_NE(peer_list_changed.find("tox_conference_get_type("),
              std::string::npos);
    EXPECT_NE(peer_list_changed.find("GetGroupChatIdFromStorage("),
              std::string::npos);
    EXPECT_NE(peer_list_changed.find("getConferenceById("),
              std::string::npos);
    EXPECT_NE(peer_list_changed.find("legacy profiles without a stored conference ID"),
              std::string::npos);
    EXPECT_NE(peer_list_changed.find("tox_conf_"),
              std::string::npos);
    EXPECT_NE(peer_list_changed.find("group_id_to_chat_id_"),
              std::string::npos);

    EXPECT_NE(rejoin.find("getConferenceById("), std::string::npos);
    EXPECT_NE(rejoin.find("GetGroupChatIdFromStorage("), std::string::npos);
    EXPECT_NE(rejoin.find("legacy profiles without a stored conference ID"),
              std::string::npos);
    EXPECT_NE(rejoin.find("group_id_to_chat_id_"), std::string::npos);
    EXPECT_NE(rejoin.find("chat_id_to_group_id_"), std::string::npos);

    const std::size_t stored_id_lookup =
        rejoin.find("GetGroupChatIdFromStorage(");
    const std::size_t stable_lookup = rejoin.find("getConferenceById(");
    const std::size_t legacy_fallback =
        rejoin.find("legacy profiles without a stored conference ID");
    ASSERT_NE(stored_id_lookup, std::string::npos);
    ASSERT_NE(stable_lookup, std::string::npos);
    ASSERT_NE(legacy_fallback, std::string::npos);
    EXPECT_LT(stored_id_lookup, stable_lookup);
    EXPECT_LT(stable_lookup, legacy_fallback);
}

TEST(AVConferenceLifecycleSourceRegressionTest,
     RejoinKnownGroupsRestoresEnabledAvConferencesForAudioQueueing) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string rejoin = SourceSection(
        manager,
        "void V2TIMManagerImpl::RejoinKnownGroups()",
        nullptr);

    const std::size_t first_enable = rejoin.find("toxav_groupchat_enable_av(");
    const std::size_t first_insert =
        rejoin.find("enabled_av_conferences_.insert(conf_num)");
    const std::size_t second_enable = rejoin.find(
        "toxav_groupchat_enable_av(", first_enable + 1);
    const std::size_t second_insert = rejoin.find(
        "enabled_av_conferences_.insert(conf_num)", first_insert + 1);

    ASSERT_NE(first_enable, std::string::npos);
    ASSERT_NE(first_insert, std::string::npos);
    ASSERT_NE(second_enable, std::string::npos);
    ASSERT_NE(second_insert, std::string::npos);
    EXPECT_LT(first_enable, first_insert);
    EXPECT_LT(second_enable, second_insert);
}

TEST(AVConferenceLifecycleSourceRegressionTest,
     PendingInviteKindRoutesConferenceRetriesToToxAV) {
    const std::string header = ReadSource(TIM2TOX_MANAGER_HEADER_PATH);
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string join = SourceSection(
        manager,
        "void V2TIMManagerImpl::JoinGroup(",
        "void V2TIMManagerImpl::QuitGroup(");

    EXPECT_NE(header.find("enum class PendingInviteKind"), std::string::npos);
    EXPECT_NE(header.find("kGroupInvite"), std::string::npos);
    EXPECT_NE(header.find("kConferenceText"), std::string::npos);
    EXPECT_NE(header.find("kConferenceAv"), std::string::npos);

    EXPECT_NE(join.find("PendingInviteKind::kConferenceText"),
              std::string::npos);
    EXPECT_NE(join.find("PendingInviteKind::kConferenceAv"),
              std::string::npos);
    EXPECT_NE(join.find("toxav_join_av_groupchat("), std::string::npos);
    EXPECT_NE(join.find("tox_conference_join("), std::string::npos);
    EXPECT_NE(join.find("tox_group_invite_accept("), std::string::npos);
    EXPECT_NE(join.find("StoreConferenceIdentity(groupID"),
              std::string::npos);
    EXPECT_NE(join.find("SetGroupTypeInStorage(groupID.CString(), conference_type)"),
              std::string::npos);
    EXPECT_NE(join.find("pending_group_invites_.erase(used_pending_id)"),
              std::string::npos);
}

TEST(AVConferenceLifecycleSourceRegressionTest,
     ColdQuitRecoversConferencesByStableIdentityAndKeepsNgcLookup) {
    const std::string group_manager = ReadSource(TIM2TOX_GROUP_MANAGER_SOURCE_PATH);
    const std::string quit = SourceSection(
        group_manager,
        "void V2TIMGroupManagerImpl::QuitGroup(",
        "void V2TIMGroupManagerImpl::DismissGroup(");

    EXPECT_NE(quit.find("GetGroupTypeFromStorage("), std::string::npos);
    EXPECT_NE(quit.find("group_type == \"conference\""), std::string::npos);
    EXPECT_NE(quit.find("group_type == \"av_conference\""), std::string::npos);
    EXPECT_NE(quit.find("getConferenceById("), std::string::npos);
    EXPECT_NE(quit.find("TOX_CONFERENCE_TYPE_AV"), std::string::npos);
    EXPECT_NE(quit.find("getGroupByChatId("), std::string::npos);
}

TEST(AVConferenceLifecycleSourceRegressionTest,
     QuitAndDismissAreFailClosedAndWrapperOwnershipIsBounded) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string group_manager = ReadSource(TIM2TOX_GROUP_MANAGER_SOURCE_PATH);
    const std::string quit = SourceSection(
        group_manager,
        "void V2TIMGroupManagerImpl::QuitGroup(",
        "void V2TIMGroupManagerImpl::DismissGroup(");
    const std::string dismiss = SourceSection(
        group_manager,
        "void V2TIMGroupManagerImpl::DismissGroup(",
        "void V2TIMGroupManagerImpl::GetJoinedGroupList(");
    const std::string manager_quit = SourceSection(
        manager,
        "void V2TIMManagerImpl::QuitGroup(",
        "void V2TIMManagerImpl::DismissGroup(");
    const std::string manager_dismiss = SourceSection(
        manager,
        "void V2TIMManagerImpl::DismissGroup(",
        "void V2TIMManagerImpl::GetUsersInfo(");

    EXPECT_EQ(quit.find("group_count == 1"), std::string::npos);
    EXPECT_NE(quit.find("if (!deleted)"), std::string::npos);
    const std::string quit_failure = SourceSection(
        quit,
        "if (!deleted)",
        "// Remove from local group members map if exists");
    EXPECT_NE(quit_failure.find("callback->OnError"), std::string::npos);
    EXPECT_NE(quit_failure.find("return;"), std::string::npos);
    EXPECT_EQ(quit_failure.find("callback->OnSuccess"), std::string::npos);

    EXPECT_NE(dismiss.find("if (!deleted)"), std::string::npos);
    const std::string dismiss_failure = SourceSection(
        dismiss,
        "if (!deleted)",
        "std::lock_guard<std::mutex> lock(member_mutex_);");
    EXPECT_NE(dismiss_failure.find("callback->OnError"), std::string::npos);
    EXPECT_NE(dismiss_failure.find("return;"), std::string::npos);
    EXPECT_EQ(dismiss_failure.find("callback->OnSuccess"), std::string::npos);

    EXPECT_NE(manager_quit.find("QuitGroupCallbackWrapper wrapper_callback"),
              std::string::npos);
    EXPECT_EQ(manager_quit.find("new QuitGroupCallbackWrapper"), std::string::npos);
    EXPECT_NE(manager_quit.find("group_id_to_type_.erase"), std::string::npos);
    EXPECT_NE(manager_quit.find("OnQuitFromGroup"), std::string::npos);

    EXPECT_NE(manager_dismiss.find("DismissGroupCallbackWrapper wrapper_callback"),
              std::string::npos);
    EXPECT_EQ(manager_dismiss.find("new DismissGroupCallbackWrapper"), std::string::npos);
    EXPECT_NE(manager_dismiss.find("group_id_to_type_.erase"), std::string::npos);
    EXPECT_NE(manager_dismiss.find("OnGroupDismissed"), std::string::npos);
}

TEST(AVConferenceLifecycleSourceRegressionTest,
     PlatformDismissUsesCapturedInstanceAndRequiresOneNativeSuccess) {
    const std::string ffi_header = ReadSource(TIM2TOX_FFI_HEADER_PATH);
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string dart_ffi = ReadSource(TIM2TOX_DART_FFI_PATH);
    const std::string dart_service = ReadSource(TIM2TOX_DART_SERVICE_PATH);
    const std::string native_dismiss = SourceSection(
        ffi_source,
        "int32_t tim2tox_ffi_dismiss_group(",
        "int tim2tox_ffi_update_known_groups(");
    const std::string service_dismiss = SourceSection(
        dart_service,
        "  Future<void> dismissGroup(String groupId) async {",
        "  /// Connect to an IRC channel");
    const std::string known_groups_sync = SourceSection(
        dart_service,
        "  void _syncKnownGroupsToNative([int? instanceId]) {",
        "  /// Discover conferences restored from Tox savedata");

    EXPECT_NE(ffi_header.find(
                  "int32_t tim2tox_ffi_dismiss_group(int64_t instance_id, const char* group_id);"),
              std::string::npos);
    EXPECT_NE(native_dismiss.find("IsInstanceInited(instance_id)"),
              std::string::npos);
    EXPECT_NE(native_dismiss.find("GetManagerForInstanceId(instance_id)"),
              std::string::npos);
    EXPECT_NE(native_dismiss.find(
                  "struct DismissGroupCallback final : public V2TIMCallback"),
              std::string::npos);
    EXPECT_NE(native_dismiss.find("manager->DismissGroup("),
              std::string::npos);
    EXPECT_NE(native_dismiss.find(
                  "callback.terminal_count == 1 && callback.success ? 1 : 0"),
              std::string::npos);
    EXPECT_NE(native_dismiss.find("catch (...)"), std::string::npos);

    EXPECT_NE(dart_ffi.find(
                  "typedef _dismiss_group_c = ffi.Int32 Function(\n"
                  "    ffi.Int64, ffi.Pointer<pkgffi.Utf8>);"),
              std::string::npos);
    EXPECT_NE(dart_ffi.find("int dismissGroup(int instanceId, String groupId)"),
              std::string::npos);
    EXPECT_NE(service_dismiss.find(
                  "_ffi.dismissGroup(_serviceInstanceId, groupId)"),
              std::string::npos);
    const std::size_t native_call = service_dismiss.find("_ffi.dismissGroup(");
    const std::size_t local_cleanup = service_dismiss.find("_knownGroups.remove(");
    ASSERT_NE(native_call, std::string::npos);
    ASSERT_NE(local_cleanup, std::string::npos);
    EXPECT_LT(native_call, local_cleanup);
    EXPECT_NE(service_dismiss.find("throw StateError("), std::string::npos);
    EXPECT_NE(service_dismiss.find(
                  "_syncKnownGroupsToNative(_serviceInstanceId)"),
              std::string::npos);
    EXPECT_NE(known_groups_sync.find("targetInstanceId"), std::string::npos);
    EXPECT_EQ(known_groups_sync.find("_ffi.getCurrentInstanceId()"),
              std::string::npos);
}

TEST(AVConferenceLifecycleSourceRegressionTest,
     ConferenceAudioQueuesNewest64AndDrainsOnlyFromAvIterate) {
    const std::string manager = ReadSource(TIM2TOX_MANAGER_SOURCE_PATH);
    const std::string header = ReadSource(TIM2TOX_MANAGER_HEADER_PATH);
    const std::string ffi_source = ReadSource(TIM2TOX_FFI_SOURCE_PATH);
    const std::string handle_conference_audio = SourceSection(
        manager,
        "static void HandleAVConferenceAudio(",
        "#endif // BUILD_TOXAV");
    const std::string av_iterate = SourceSection(
        ffi_source,
        "void tim2tox_ffi_av_iterate(",
        "int tim2tox_ffi_av_start_call(");

    EXPECT_EQ(handle_conference_audio.find("ForwardAVConferenceAudioToDart("),
              std::string::npos);
    EXPECT_NE(handle_conference_audio.find("manager_impl->EnqueueAVConferenceAudioFrame("),
              std::string::npos);
    EXPECT_NE(header.find("AVConferenceAudioQueue"), std::string::npos);
    EXPECT_NE(header.find("EnqueueAVConferenceAudioFrame"), std::string::npos);
    EXPECT_NE(header.find("DrainPendingAVConferenceAudioFrames"), std::string::npos);
    EXPECT_NE(av_iterate.find("manager_impl->DrainPendingAVConferenceAudioFrames();"),
              std::string::npos);
    EXPECT_EQ(ffi_source.find("g_pending_av_conference_audio_frames"),
              std::string::npos);
    EXPECT_EQ(ffi_source.find("DrainAVConferenceAudioFrames("), std::string::npos);
    EXPECT_NE(ffi_source.find(
                  "void tim2tox_ffi_av_conference_clear_pending_audio("),
              std::string::npos);
    EXPECT_NE(ffi_source.find(
                  "manager->ClearPendingAVConferenceAudioFrames();"),
              std::string::npos);
    EXPECT_EQ(ffi_source.find("kMaxPendingAVConferenceAudioFrames"),
              std::string::npos);
}

}
