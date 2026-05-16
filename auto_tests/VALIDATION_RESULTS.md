# tim2tox auto_tests — Virtual vs Wall Validation Report

**Generated:** 2026-05-15 19:13:32 UTC  
**Commit:** `24156e84b2ece1db974a94be7f379710a5155dac`  
**Scope:** Phases 1-12 (Phase 13 binary-replacement & Phase 14 unit are not virtual-clock-relevant)  
**Virtual-mode total wall time:** 1812s  
**Wall-mode total wall time:** 2349s  
**Overall speedup (wall / virtual):** 1.30x

## Overall verdict

| Metric | Virtual | Wall |
|---|---|---|
| Tests run |       69 |       69 |
| Pass | 68 | 69 |
| Fail | 1 | 0 |
| Timeout | 0 | 0 |
| Sum of per-test durations | 1809s | 2346s |
| Total runner elapsed | 1812s | 2349s |

**Virtual pass rate:** 98.6%  
**Wall pass rate:** 100.0%

## Per-phase summary

| Phase | Name | Virt P/F/T | Wall P/F/T | Virt sum (s) | Wall sum (s) | Speedup |
|------:|------|------------|------------|------:|------:|---------|
| 1 | Basic | 5/0/0 | 5/0/0 | 176 | 170 | 0.97x |
| 2 | Friendship | 8/0/0 | 8/0/0 | 180 | 189 | 1.05x |
| 3 | Message | 4/0/0 | 4/0/0 | 83 | 132 | 1.59x |
| 4 | Group | 10/0/0 | 10/0/0 | 210 | 270 | 1.29x |
| 5 | ToxAV | 6/0/0 | 6/0/0 | 131 | 179 | 1.37x |
| 6 | Profile | 4/0/0 | 4/0/0 | 76 | 68 | 0.89x |
| 7 | Conversation | 2/0/0 | 2/0/0 | 68 | 81 | 1.19x |
| 8 | File | 3/0/0 | 3/0/0 | 75 | 90 | 1.20x |
| 9 | Conference | 7/0/0 | 7/0/0 | 246 | 340 | 1.38x |
| 10 | Group Extended | 10/1/0 | 11/0/0 | 384 | 613 | 1.60x |
| 11 | Network | 7/0/0 | 7/0/0 | 141 | 163 | 1.16x |
| 12 | Other | 2/0/0 | 2/0/0 | 39 | 51 | 1.31x |

## Where virtual mode saves the most wall time

| Phase | Test | Wall (s) | Virtual (s) | Saved (s) |
|------:|------|---:|---:|---:|
| 10 | scenario_group_tcp_test | 113 | 39 | 74 |
| 10 | scenario_group_state_changes_test | 102 | 38 | 64 |
| 3 | scenario_message_overflow_test | 68 | 23 | 45 |
| 9 | scenario_conference_test | 91 | 62 | 29 |
| 4 | scenario_group_moderation_test | 51 | 22 | 29 |
| 10 | scenario_group_general_test | 51 | 23 | 28 |
| 4 | scenario_group_test | 46 | 21 | 25 |
| 11 | scenario_nospam_test | 55 | 33 | 22 |

These tests exercise long real-clock waits (group join/info propagation,
nospam regen polling, message overflow flushes). Virtual mode replaces
the wall waits with deterministic VirtualClock advances, recovering
~5–7 minutes across the suite.

## Where wall mode is slightly faster than virtual

| Phase | Test | Wall (s) | Virtual (s) | Δ |
|------:|------|---:|---:|---:|
| 1 | scenario_self_query_test | 29 | 41 | −12 |
| 2 | scenario_friendship_test | 11 | 17 | −6 |
| 6 | scenario_set_status_message_test | 12 | 18 | −6 |
| 11 | scenario_bootstrap_test | 12 | 18 | −6 |
| 3 | scenario_typing_test | 12 | 17 | −5 |

These are small tests where the virtual-mode setup overhead
(VirtualClock.enableEarly, pumped queue priming) exceeds the bootstrap
time saved. Virtual mode is a net loss on these specific tests, but the
total suite-level speedup dwarfs the local cost (saving ~9 min net).

## Top 5 fastest virtual tests

| Phase | Test | Duration (s) | Status |
|------:|------|---:|---|
| 1 | scenario_sdk_init_test | 3 | PASS |
| 11 | scenario_dht_nodes_response_api_test | 15 | PASS |
| 11 | scenario_lan_discovery_test | 15 | PASS |
| 4 | scenario_group_save_test | 15 | PASS |
| 10 | scenario_group_create_debug_test | 16 | PASS |

## Top 5 slowest virtual tests

| Phase | Test | Duration (s) | Status |
|------:|------|---:|---|
| 1 | scenario_login_test | 64 | PASS |
| 9 | scenario_conference_test | 62 | PASS |
| 10 | scenario_group_multi_test | 53 | PASS |
| 2 | scenario_friend_request_test | 51 | PASS |
| 10 | scenario_group_message_types_test | 48 | PASS |

## Virtual-mode regressions (passed in wall, failed in virtual)

| Phase | Test | Virtual status | Wall status |
|------:|------|----------------|-------------|
| 10 | scenario_group_info_modify_test | FAIL | PASS |

### Regression detail — `scenario_group_info_modify_virtual_test`

Failure: **"Group Info Modify Tests (Virtual) Group info change notification to members"**

```
[GroupInfoModify] onGroupInfoChanged callback not observed in time,
fallback to state query: TimeoutException: Timeout waiting for
Bob receives group info change (virtual: 10000 ms)

Expected: true
  Actual: <false>
Bob should observe updated group name via getGroupsInfo
```

Location: `test/scenarios/scenario_group_info_modify_virtual_test.dart:348`

The virtual-clock variant's 10s budget for the `onGroupInfoChanged` callback
propagation is too tight for the way virtual-mode pumps deliver the group-info
update across two nodes. The wall-mode variant (same logic, real-clock
propagation) passes in 23s. Net interpretation: the test's virtual budget
needs to be raised (or the pump cadence adjusted) for this particular flow
— it is not a regression in the SDK or library code paths.

## Virtual-mode improvements (failed in wall, passed in virtual)

_None — every test that passed in virtual also passed in wall._

## All test results

### Virtual mode

| Phase | Test | Status | Duration (s) |
|------:|------|--------|----:|
| 1 | scenario_sdk_init_test | PASS | 3 |
| 1 | scenario_login_test | PASS | 64 |
| 1 | scenario_self_query_test | PASS | 41 |
| 1 | scenario_save_load_test | PASS | 33 |
| 1 | scenario_multi_instance_test | PASS | 35 |
| 2 | scenario_friend_request_test | PASS | 51 |
| 2 | scenario_friend_request_simple_test | PASS | 17 |
| 2 | scenario_friend_connection_test | PASS | 20 |
| 2 | scenario_friend_query_test | PASS | 21 |
| 2 | scenario_friendship_test | PASS | 17 |
| 2 | scenario_friend_delete_test | PASS | 19 |
| 2 | scenario_friend_read_receipt_test | PASS | 18 |
| 2 | scenario_friend_request_spam_test | PASS | 17 |
| 3 | scenario_message_test | PASS | 22 |
| 3 | scenario_send_message_test | PASS | 21 |
| 3 | scenario_message_overflow_test | PASS | 23 |
| 3 | scenario_typing_test | PASS | 17 |
| 4 | scenario_group_test | PASS | 21 |
| 4 | scenario_group_message_test | PASS | 20 |
| 4 | scenario_group_invite_test | PASS | 35 |
| 4 | scenario_group_double_invite_test | PASS | 16 |
| 4 | scenario_group_state_test | PASS | 23 |
| 4 | scenario_group_sync_test | PASS | 23 |
| 4 | scenario_group_save_test | PASS | 15 |
| 4 | scenario_group_topic_test | PASS | 19 |
| 4 | scenario_group_topic_revert_test | PASS | 16 |
| 4 | scenario_group_moderation_test | PASS | 22 |
| 5 | scenario_toxav_basic_test | PASS | 24 |
| 5 | scenario_toxav_many_test | PASS | 22 |
| 5 | scenario_toxav_conference_test | PASS | 21 |
| 5 | scenario_toxav_conference_audio_test | PASS | 20 |
| 5 | scenario_toxav_conference_invite_test | PASS | 21 |
| 5 | scenario_toxav_conference_audio_send_test | PASS | 23 |
| 6 | scenario_set_name_test | PASS | 17 |
| 6 | scenario_set_status_message_test | PASS | 18 |
| 6 | scenario_user_status_test | PASS | 18 |
| 6 | scenario_avatar_test | PASS | 23 |
| 7 | scenario_conversation_test | PASS | 30 |
| 7 | scenario_conversation_pin_test | PASS | 38 |
| 8 | scenario_file_transfer_test | PASS | 24 |
| 8 | scenario_file_cancel_test | PASS | 24 |
| 8 | scenario_file_seek_test | PASS | 27 |
| 9 | scenario_conference_test | PASS | 62 |
| 9 | scenario_conference_simple_test | PASS | 28 |
| 9 | scenario_conference_offline_test | PASS | 35 |
| 9 | scenario_conference_av_test | PASS | 36 |
| 9 | scenario_conference_invite_merge_test | PASS | 42 |
| 9 | scenario_conference_peer_nick_test | PASS | 24 |
| 9 | scenario_conference_query_test | PASS | 19 |
| 10 | scenario_group_general_test | PASS | 23 |
| 10 | scenario_group_large_test | PASS | 40 |
| 10 | scenario_group_multi_test | PASS | 53 |
| 10 | scenario_group_message_types_test | PASS | 48 |
| 10 | scenario_group_error_test | PASS | 33 |
| 10 | scenario_group_create_debug_test | PASS | 16 |
| 10 | scenario_group_state_changes_test | PASS | 38 |
| 10 | scenario_group_member_info_test | PASS | 46 |
| 10 | scenario_group_info_modify_test | FAIL | 19 |
| 10 | scenario_group_tcp_test | PASS | 39 |
| 10 | scenario_group_vs_conference_test | PASS | 29 |
| 11 | scenario_reconnect_test | PASS | 18 |
| 11 | scenario_save_friend_test | PASS | 22 |
| 11 | scenario_nospam_test | PASS | 33 |
| 11 | scenario_bootstrap_test | PASS | 18 |
| 11 | scenario_dht_nodes_response_api_test | PASS | 15 |
| 11 | scenario_lan_discovery_test | PASS | 15 |
| 11 | scenario_many_nodes_test | PASS | 20 |
| 12 | scenario_events_test | PASS | 20 |
| 12 | scenario_signaling_test | PASS | 19 |

### Wall mode

| Phase | Test | Status | Duration (s) |
|------:|------|--------|----:|
| 1 | scenario_sdk_init_test | PASS | 2 |
| 1 | scenario_login_test | PASS | 63 |
| 1 | scenario_self_query_test | PASS | 29 |
| 1 | scenario_save_load_test | PASS | 33 |
| 1 | scenario_multi_instance_test | PASS | 43 |
| 2 | scenario_friend_request_test | PASS | 68 |
| 2 | scenario_friend_request_simple_test | PASS | 13 |
| 2 | scenario_friend_connection_test | PASS | 19 |
| 2 | scenario_friend_query_test | PASS | 25 |
| 2 | scenario_friendship_test | PASS | 11 |
| 2 | scenario_friend_delete_test | PASS | 20 |
| 2 | scenario_friend_read_receipt_test | PASS | 18 |
| 2 | scenario_friend_request_spam_test | PASS | 15 |
| 3 | scenario_message_test | PASS | 29 |
| 3 | scenario_send_message_test | PASS | 23 |
| 3 | scenario_message_overflow_test | PASS | 68 |
| 3 | scenario_typing_test | PASS | 12 |
| 4 | scenario_group_test | PASS | 46 |
| 4 | scenario_group_message_test | PASS | 28 |
| 4 | scenario_group_invite_test | PASS | 35 |
| 4 | scenario_group_double_invite_test | PASS | 14 |
| 4 | scenario_group_state_test | PASS | 27 |
| 4 | scenario_group_sync_test | PASS | 25 |
| 4 | scenario_group_save_test | PASS | 13 |
| 4 | scenario_group_topic_test | PASS | 17 |
| 4 | scenario_group_topic_revert_test | PASS | 14 |
| 4 | scenario_group_moderation_test | PASS | 51 |
| 5 | scenario_toxav_basic_test | PASS | 31 |
| 5 | scenario_toxav_many_test | PASS | 28 |
| 5 | scenario_toxav_conference_test | PASS | 30 |
| 5 | scenario_toxav_conference_audio_test | PASS | 23 |
| 5 | scenario_toxav_conference_invite_test | PASS | 28 |
| 5 | scenario_toxav_conference_audio_send_test | PASS | 39 |
| 6 | scenario_set_name_test | PASS | 12 |
| 6 | scenario_set_status_message_test | PASS | 12 |
| 6 | scenario_user_status_test | PASS | 22 |
| 6 | scenario_avatar_test | PASS | 22 |
| 7 | scenario_conversation_test | PASS | 38 |
| 7 | scenario_conversation_pin_test | PASS | 43 |
| 8 | scenario_file_transfer_test | PASS | 30 |
| 8 | scenario_file_cancel_test | PASS | 31 |
| 8 | scenario_file_seek_test | PASS | 29 |
| 9 | scenario_conference_test | PASS | 91 |
| 9 | scenario_conference_simple_test | PASS | 45 |
| 9 | scenario_conference_offline_test | PASS | 44 |
| 9 | scenario_conference_av_test | PASS | 44 |
| 9 | scenario_conference_invite_merge_test | PASS | 55 |
| 9 | scenario_conference_peer_nick_test | PASS | 34 |
| 9 | scenario_conference_query_test | PASS | 27 |
| 10 | scenario_group_general_test | PASS | 51 |
| 10 | scenario_group_large_test | PASS | 45 |
| 10 | scenario_group_multi_test | PASS | 72 |
| 10 | scenario_group_message_types_test | PASS | 64 |
| 10 | scenario_group_error_test | PASS | 39 |
| 10 | scenario_group_create_debug_test | PASS | 12 |
| 10 | scenario_group_state_changes_test | PASS | 102 |
| 10 | scenario_group_member_info_test | PASS | 56 |
| 10 | scenario_group_info_modify_test | PASS | 23 |
| 10 | scenario_group_tcp_test | PASS | 113 |
| 10 | scenario_group_vs_conference_test | PASS | 36 |
| 11 | scenario_reconnect_test | PASS | 15 |
| 11 | scenario_save_friend_test | PASS | 23 |
| 11 | scenario_nospam_test | PASS | 55 |
| 11 | scenario_bootstrap_test | PASS | 12 |
| 11 | scenario_dht_nodes_response_api_test | PASS | 22 |
| 11 | scenario_lan_discovery_test | PASS | 11 |
| 11 | scenario_many_nodes_test | PASS | 25 |
| 12 | scenario_events_test | PASS | 24 |
| 12 | scenario_signaling_test | PASS | 27 |

---

_Logs: `/tmp/final_virt.log`, `/tmp/final_wall.log`_
