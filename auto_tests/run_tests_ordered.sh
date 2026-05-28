#!/bin/bash
# Run tim2tox test scenarios in complexity order with 180s timeout per test
# Usage:
#   ./run_tests_ordered.sh                         # run all phases (1-14)
#   ./run_tests_ordered.sh 3                       # run only phase 3
#   ./run_tests_ordered.sh PHASE3                  # run only phase 3
#   ./run_tests_ordered.sh 5,6                     # run phase 5 and 6
#   ./run_tests_ordered.sh 7-9                     # run phase 7..9
#   ./run_tests_ordered.sh 7 9                     # run phase 7 and 9
#   ./run_tests_ordered.sh BINARY UNIT             # run phase 13 and 14
#   ./run_tests_ordered.sh --merge-output 13       # write phase13 logs to merged_results/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
  cat <<'EOF'
Usage:
  ./run_tests_ordered.sh [PHASE_SELECTOR ...] [--merge-output]

Phase selector formats:
  1) Single value: 3 / PHASE3 / MESSAGE / BINARY / UNIT
  2) Comma list:   5,6 / PHASE5_TOXAV,PHASE6_PROFILE
  3) Range:        7-9
  4) Multi args:   10 11 12

Options:
  --merge-output   When exactly one phase is selected, write logs to merged_results/phase{N}_*
  -h, --help       Show this help

Environment:
  RUN_VIRTUAL=1       Run scenarios under the virtual clock. Each scenario is a
                      single mode-aware file (no *_virtual_test.dart siblings);
                      it reads RUN_VIRTUAL via shouldRunVirtual (test_helper.dart)
                      and enables the virtual clock when set. Default (0) is
                      wall-clock. (The legacy *_virtual_test.dart swap below is a
                      harmless no-op now that siblings are unified.)
  PARALLEL_WORKERS=N  Run up to N tests concurrently (each spawns its own
                      flutter_tester). Default 1 (sequential). 2-3 is usually
                      safe on a developer Mac; higher values risk CPU
                      contention and flaky timing-sensitive tests.
                      In parallel mode, tests run in dispatch order (across
                      all selected phases as a single queue) and the
                      "Phase N: ..." banners are reconstructed from per-test
                      logs after the run.
  BUNDLE=1            Dispatch each phase as ONE `flutter test` invocation
                      (every file in the phase passed as a positional arg).
                      Tests that have been converted to call
                      `acquireSharedScenario(...)` reuse a cached Tox
                      bootstrap + friendship across files in the bundle,
                      saving the cold-start cost (10-22 s per file). Tests
                      still on the legacy `createTestScenario` path run
                      independently inside the bundle and pay their normal
                      cost. Bundle and PARALLEL_WORKERS can be combined,
                      in which case each phase is one queue entry.
  RETRY_COUNT=N       On failure, retry the same test up to N additional times
                      (default 0 = no retry, legacy behavior). A test that
                      passes on retry is counted as PASSED but also recorded
                      in the "Flaky Tests" section of the summary. Only takes
                      effect for the sequential path (PARALLEL_WORKERS=1).
  SKIP_PHASES=LIST    Comma-separated phase selectors to skip entirely (same
                      syntax as positional args: numbers or names). Tests in
                      skipped phases are counted as SKIPPED. Example:
                      SKIP_PHASES=11      # skip Phase 11 (Network)
                      SKIP_PHASES=NETWORK,OTHER
EOF
}

# ───────────────────────────────────────────────────────────────────────────
# Phase manifest — single source of truth for phase metadata.
#
# One entry per phase: num|ARRAY_VAR|Display Name|PARALLEL_LABEL|alias1,alias2
#
#   num            phase number (1..N)
#   ARRAY_VAR      name of the bash array holding this phase's test files
#                  (defined further down; the file list is the only per-phase
#                  data that is NOT derived from this manifest)
#   Display Name   shown as "Phase N: <Display Name>"
#   PARALLEL_LABEL single-token label emitted by parallel workers
#   aliases        extra selector tokens (comma-separated). Numbers, "PHASEn",
#                  and ARRAY_VAR itself are always accepted generically, so
#                  only the *semantic* aliases need to be listed here.
#
# Every phase->metadata mapping (selector resolution, display name, parallel
# label, array size, array contents, dispatch) derives from this table via the
# accessors below. Add a phase by adding one row here plus its ARRAY_VAR.
# ───────────────────────────────────────────────────────────────────────────
PHASE_MANIFEST=(
  "1|PHASE1_BASIC|Basic Tests|P1_BASIC|BASIC"
  "2|PHASE2_FRIENDSHIP|Friendship Tests|P2_FRIENDSHIP|FRIENDSHIP"
  "3|PHASE3_MESSAGE|Message Tests|P3_MESSAGE|MESSAGE"
  "4|PHASE4_GROUP|Group Tests|P4_GROUP|GROUP"
  "5|PHASE5_TOXAV|ToxAV Tests|P5_TOXAV|TOXAV"
  "6|PHASE6_PROFILE|Profile Tests|P6_PROFILE|PROFILE"
  "7|PHASE7_CONVERSATION|Conversation Tests|P7_CONVERSATION|CONVERSATION"
  "8|PHASE8_FILE|File Tests|P8_FILE|FILE"
  "9|PHASE9_CONFERENCE|Conference Tests|P9_CONFERENCE|CONFERENCE"
  "10|PHASE10_GROUP_EXT|Group Extended Tests|P10_GROUP_EXT|GROUP_EXT,GROUPEXT"
  "11|PHASE11_NETWORK|Network Tests|P11_NETWORK|NETWORK"
  "12|PHASE12_OTHER|Other Tests|P12_OTHER|OTHER"
  "13|PHASE13_BINARY_REPLACEMENT|Binary Replacement Tests|P13_BINARY|BINARY,BINARY_REPLACEMENT,PHASE13_BINARY"
  "14|PHASE14_UNIT|Unit Tests|P14_UNIT|UNIT,UNIT_TEST,UNIT_TESTS"
)

# Number of phases (derived — never hardcode 14 below this line).
PHASE_COUNT=${#PHASE_MANIFEST[@]}

# Return a manifest field for a phase number.
# field index (cut -f): 1=num 2=ARRAY_VAR 3=Display 4=Label 5=aliases
_manifest_field_for_num() {
  local num="$1" field="$2" entry
  for entry in "${PHASE_MANIFEST[@]}"; do
    if [ "${entry%%|*}" = "$num" ]; then
      printf '%s\n' "$entry" | cut -d'|' -f"$field"
      return 0
    fi
  done
  return 1
}

# num -> name of the PHASEN_* array variable holding its test files.
phase_varname_for_num() { _manifest_field_for_num "$1" 2; }

# num -> "Phase N: <Display Name>"
phase_name_for_num() {
  local d
  if d=$(_manifest_field_for_num "$1" 3); then
    echo "Phase $1: $d"
  else
    echo "Phase ?: Unknown"
  fi
}

# num -> single-token label used in parallel worker status output (e.g. P3_MESSAGE).
phase_label_for_num() { _manifest_field_for_num "$1" 4 || echo "P?"; }

# num -> number of test files in that phase's array.
# Indirect expansion (eval) keeps this bash-3.2 compatible (no `declare -A`).
phase_array_size_for_num() {
  local var
  var=$(phase_varname_for_num "$1") || { echo 0; return; }
  eval "echo \"\${#${var}[@]}\""
}

# Resolve a selector token (number / "PHASEn" / ARRAY_VAR / semantic alias) to
# a phase number. Echoes the empty string for unknown tokens.
resolve_phase_arg() {
  local arg="$1"
  if [ -z "$arg" ]; then
    echo ""
    return
  fi

  local upper
  upper=$(echo "$arg" | tr '[:lower:]' '[:upper:]')

  # Plain phase number.
  if [ "$upper" -eq "$upper" ] 2>/dev/null; then
    if [ "$upper" -ge 1 ] && [ "$upper" -le "$PHASE_COUNT" ]; then
      echo "$upper"
      return
    fi
  fi

  local entry e_num e_var e_aliases a
  for entry in "${PHASE_MANIFEST[@]}"; do
    e_num=$(printf '%s\n' "$entry" | cut -d'|' -f1)
    e_var=$(printf '%s\n' "$entry" | cut -d'|' -f2)
    e_aliases=$(printf '%s\n' "$entry" | cut -d'|' -f5)
    # "PHASE<n>" or the array variable name itself (e.g. PHASE3 / PHASE3_MESSAGE).
    if [ "$upper" = "PHASE${e_num}" ] || [ "$upper" = "$e_var" ]; then
      echo "$e_num"
      return
    fi
    # Semantic aliases (comma-separated).
    IFS=',' read -r -a _aliases <<< "$e_aliases"
    for a in "${_aliases[@]}"; do
      if [ -n "$a" ] && [ "$upper" = "$a" ]; then
        echo "$e_num"
        return
      fi
    done
  done

  echo ""
}

# Parse args
MERGE_MODE="${MERGE_MODE:-0}"
SELECTOR_TOKENS=()
for arg in "$@"; do
  case "$arg" in
    --merge-output)
      MERGE_MODE=1
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      SELECTOR_TOKENS+=("$arg")
      ;;
  esac
done

phase_selected() {
  local target="$1"
  local n
  for n in "${SELECTED_PHASES[@]}"; do
    if [ "$n" = "$target" ]; then
      return 0
    fi
  done
  return 1
}

add_phase() {
  local phase_num="$1"
  if ! phase_selected "$phase_num"; then
    SELECTED_PHASES+=("$phase_num")
  fi
}

SELECTED_PHASES=()
if [ ${#SELECTOR_TOKENS[@]} -eq 0 ]; then
  for p in $(seq 1 "$PHASE_COUNT"); do
    add_phase "$p"
  done
else
  for token in "${SELECTOR_TOKENS[@]}"; do
    IFS=',' read -r -a parts <<< "$token"
    for raw_part in "${parts[@]}"; do
      part=$(echo "$raw_part" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
      if [ -z "$part" ]; then
        continue
      fi

      if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
        start=${part%-*}
        end=${part#*-}
        if [ "$start" -gt "$end" ]; then
          echo -e "${RED}Invalid phase range: $part (start > end)${NC}"
          exit 2
        fi
        if [ "$start" -lt 1 ] || [ "$end" -gt 14 ]; then
          echo -e "${RED}Invalid phase range: $part (valid range is 1-14)${NC}"
          exit 2
        fi
        for p in $(seq "$start" "$end"); do
          add_phase "$p"
        done
      else
        phase_num=$(resolve_phase_arg "$part")
        if [ -z "$phase_num" ]; then
          echo -e "${RED}Unknown phase selector: $part${NC}"
          echo "Valid selectors include: 1-14, BASIC, FRIENDSHIP, MESSAGE, GROUP, TOXAV, PROFILE, CONVERSATION, FILE, CONFERENCE, GROUP_EXT, NETWORK, OTHER, BINARY, UNIT"
          echo "Examples: ./run_tests_ordered.sh 5,6    ./run_tests_ordered.sh 7-9    ./run_tests_ordered.sh 10 11 12"
          exit 2
        fi
        add_phase "$phase_num"
      fi
    done
  done
fi

if [ ${#SELECTED_PHASES[@]} -eq 0 ]; then
  echo -e "${RED}No phase selected.${NC}"
  exit 2
fi

# SKIP_PHASES: comma-separated phase selectors to drop from SELECTED_PHASES.
# Tests in skipped phases are accounted for in TOTAL_SKIPPED / SKIPPED_TESTS
# at the apply step below (after the phase arrays are defined).
SKIP_PHASE_NUMS=()
if [ -n "${SKIP_PHASES:-}" ]; then
  IFS=',' read -r -a _skip_parts <<< "$SKIP_PHASES"
  for raw_skip in "${_skip_parts[@]}"; do
    skip_part=$(echo "$raw_skip" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
    if [ -z "$skip_part" ]; then
      continue
    fi
    skip_num=$(resolve_phase_arg "$skip_part")
    if [ -z "$skip_num" ]; then
      echo -e "${RED}Unknown phase selector in SKIP_PHASES: $skip_part${NC}"
      exit 2
    fi
    # Dedupe.
    already=0
    for existing in "${SKIP_PHASE_NUMS[@]}"; do
      if [ "$existing" = "$skip_num" ]; then
        already=1
        break
      fi
    done
    if [ "$already" -eq 0 ]; then
      SKIP_PHASE_NUMS+=("$skip_num")
    fi
  done

  if [ ${#SKIP_PHASE_NUMS[@]} -gt 0 ]; then
    filtered_phases=()
    for p in "${SELECTED_PHASES[@]}"; do
      drop=0
      for sp in "${SKIP_PHASE_NUMS[@]}"; do
        if [ "$p" = "$sp" ]; then
          drop=1
          break
        fi
      done
      if [ "$drop" -eq 0 ]; then
        filtered_phases+=("$p")
      fi
    done
    SELECTED_PHASES=("${filtered_phases[@]}")
  fi
fi

if [ ${#SELECTED_PHASES[@]} -eq 0 ]; then
  echo -e "${RED}No phase selected (after applying SKIP_PHASES).${NC}"
  exit 2
fi

# Results file: use merged_results/ only when exactly one phase is selected.
if [ "$MERGE_MODE" = "1" ] && [ ${#SELECTED_PHASES[@]} -eq 1 ]; then
  MERGED_DIR="$SCRIPT_DIR/merged_results"
  mkdir -p "$MERGED_DIR"
  single_phase="${SELECTED_PHASES[0]}"
  RESULTS_FILE="$MERGED_DIR/phase${single_phase}_results.log"
  SUMMARY_FILE="$MERGED_DIR/phase${single_phase}_summary.txt"
else
  if [ "$MERGE_MODE" = "1" ] && [ ${#SELECTED_PHASES[@]} -gt 1 ]; then
    echo -e "${YELLOW}--merge-output is only supported for single phase. Falling back to timestamped output.${NC}"
  fi
  RESULTS_FILE="$SCRIPT_DIR/test_results_$(date +%Y%m%d_%H%M%S).log"
  SUMMARY_FILE="$SCRIPT_DIR/test_summary_$(date +%Y%m%d_%H%M%S).txt"
fi

echo -e "${GREEN}Running tim2tox test scenarios in complexity order...${NC}"
echo "Selected phases:"
for phase_num in "${SELECTED_PHASES[@]}"; do
  echo "  - $(phase_name_for_num "$phase_num")"
done
echo "Results will be logged to: $RESULTS_FILE"
echo "Summary will be written to: $SUMMARY_FILE"

# Optional assertion guard (enabled by default)
ASSERTION_GUARD="${ASSERTION_GUARD:-1}"
if [ "$ASSERTION_GUARD" = "1" ]; then
  if [ -x "./check_test_assertions.sh" ]; then
    echo -e "${YELLOW}Running assertion guard checks...${NC}"
    ./check_test_assertions.sh
  else
    echo -e "${YELLOW}Warning: check_test_assertions.sh not found or not executable, skipping assertion guard.${NC}"
  fi
fi

# Install dependencies.
# Skip `flutter pub get` when .dart_tool/package_config.json is newer than
# pubspec.yaml — saves ~5–15s per run. Force a refresh with SKIP_PUB_GET=0.
if [ "${SKIP_PUB_GET:-auto}" = "0" ] || \
   [ ! -f .dart_tool/package_config.json ] || \
   [ pubspec.yaml -nt .dart_tool/package_config.json ]; then
  echo -e "${YELLOW}Installing dependencies...${NC}"
  flutter pub get
else
  echo -e "${YELLOW}Dependencies appear up to date (skipping flutter pub get; set SKIP_PUB_GET=0 to force).${NC}"
fi

# Test files organized by complexity/dependencies (73 scenario + 3 binary + 1 unit)
PHASE1_BASIC=(
  "test/scenarios/scenario_sdk_init_test.dart"
  "test/scenarios/scenario_login_test.dart"
  "test/scenarios/scenario_self_query_test.dart"
  "test/scenarios/scenario_save_load_test.dart"
  "test/scenarios/scenario_multi_instance_test.dart"
)

PHASE2_FRIENDSHIP=(
  "test/scenarios/scenario_friend_request_test.dart"
  "test/scenarios/scenario_friend_request_simple_test.dart"
  "test/scenarios/scenario_friend_connection_test.dart"
  "test/scenarios/scenario_friend_query_test.dart"
  "test/scenarios/scenario_friendship_test.dart"
  "test/scenarios/scenario_friend_delete_test.dart"
  "test/scenarios/scenario_friend_read_receipt_test.dart"
  "test/scenarios/scenario_friend_request_spam_test.dart"
)

PHASE3_MESSAGE=(
  "test/scenarios/scenario_message_test.dart"
  "test/scenarios/scenario_send_message_test.dart"
  "test/scenarios/scenario_message_overflow_test.dart"
  "test/scenarios/scenario_typing_test.dart"
)

PHASE4_GROUP=(
  "test/scenarios/scenario_group_test.dart"
  "test/scenarios/scenario_group_message_test.dart"
  "test/scenarios/scenario_group_invite_test.dart"
  "test/scenarios/scenario_group_double_invite_test.dart"
  "test/scenarios/scenario_group_state_test.dart"
  "test/scenarios/scenario_group_sync_test.dart"
  "test/scenarios/scenario_group_save_test.dart"
  "test/scenarios/scenario_group_topic_test.dart"
  "test/scenarios/scenario_group_topic_revert_test.dart"
  "test/scenarios/scenario_group_moderation_test.dart"
)

PHASE5_TOXAV=(
  "test/scenarios/scenario_toxav_basic_test.dart"
  "test/scenarios/scenario_toxav_many_test.dart"
  "test/scenarios/scenario_toxav_peer_offline_test.dart"
  "test/scenarios/scenario_toxav_conference_test.dart"
  "test/scenarios/scenario_toxav_conference_audio_test.dart"
  "test/scenarios/scenario_toxav_conference_invite_test.dart"
  "test/scenarios/scenario_toxav_conference_audio_send_test.dart"
)

# Profile / user info (name, status, avatar)
PHASE6_PROFILE=(
  "test/scenarios/scenario_set_name_test.dart"
  "test/scenarios/scenario_set_status_message_test.dart"
  "test/scenarios/scenario_user_status_test.dart"
  "test/scenarios/scenario_avatar_test.dart"
)

# Conversation (conversation list, pin)
PHASE7_CONVERSATION=(
  "test/scenarios/scenario_conversation_test.dart"
  "test/scenarios/scenario_conversation_pin_test.dart"
  "test/scenarios/scenario_conversation_callback_test.dart"
)

# File transfer
PHASE8_FILE=(
  "test/scenarios/scenario_file_transfer_test.dart"
  "test/scenarios/scenario_file_cancel_test.dart"
  "test/scenarios/scenario_file_seek_test.dart"
)

# Conference (audio/video conference, distinct from group)
PHASE9_CONFERENCE=(
  "test/scenarios/scenario_conference_test.dart"
  "test/scenarios/scenario_conference_simple_test.dart"
  "test/scenarios/scenario_conference_two_test.dart"
  "test/scenarios/scenario_conference_offline_test.dart"
  "test/scenarios/scenario_conference_double_invite_test.dart"
  "test/scenarios/scenario_conference_av_test.dart"
  "test/scenarios/scenario_conference_invite_merge_test.dart"
  "test/scenarios/scenario_conference_peer_nick_test.dart"
  "test/scenarios/scenario_conference_query_test.dart"
)

# Group extended (additional group scenarios not in core PHASE4)
PHASE10_GROUP_EXT=(
  "test/scenarios/scenario_group_general_test.dart"
  "test/scenarios/scenario_group_large_test.dart"
  "test/scenarios/scenario_group_multi_test.dart"
  "test/scenarios/scenario_group_message_types_test.dart"
  "test/scenarios/scenario_group_error_test.dart"
  "test/scenarios/scenario_group_create_debug_test.dart"
  "test/scenarios/scenario_group_state_changes_test.dart"
  "test/scenarios/scenario_group_member_info_test.dart"
  "test/scenarios/scenario_group_info_modify_test.dart"
  "test/scenarios/scenario_group_tcp_test.dart"
  "test/scenarios/scenario_group_vs_conference_test.dart"
)

# Network / connectivity (reconnect, bootstrap, DHT, LAN, etc.)
PHASE11_NETWORK=(
  "test/scenarios/scenario_reconnect_test.dart"
  "test/scenarios/scenario_save_friend_test.dart"
  "test/scenarios/scenario_nospam_test.dart"
  "test/scenarios/scenario_bootstrap_test.dart"
  "test/scenarios/scenario_dht_nodes_response_api_test.dart"
  "test/scenarios/scenario_lan_discovery_test.dart"
  "test/scenarios/scenario_many_nodes_test.dart"
)

# Other (events, signaling)
PHASE12_OTHER=(
  "test/scenarios/scenario_events_test.dart"
  "test/scenarios/scenario_signaling_test.dart"
)

# Binary replacement path (NativeLibraryManager callback dispatch)
PHASE13_BINARY_REPLACEMENT=(
  "test/scenarios_binary/scenario_library_loading_test.dart"
  "test/scenarios_binary/scenario_native_callback_dispatch_test.dart"
  "test/scenarios_binary/scenario_custom_callback_handler_test.dart"
)

PHASE14_UNIT=(
  "test/unit_tests/test_listeners.dart"
)

# Initialize counters
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
TOTAL_FLAKY=0
FAILED_TESTS=()
SKIPPED_TESTS=()
FLAKY_TESTS=()

# RETRY_COUNT: number of additional attempts after a first failure.
# Default 0 preserves legacy "one shot" behavior. A pass on retry is counted
# as PASSED but also recorded in FLAKY_TESTS for visibility.
RETRY_COUNT="${RETRY_COUNT:-0}"
if ! [[ "$RETRY_COUNT" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}RETRY_COUNT must be a non-negative integer (got: $RETRY_COUNT)${NC}"
  exit 2
fi

# Formerly-unstable native tests are now enabled by default.
# scenario_dht_nodes_response_api_test was previously gated behind
# RUN_NATIVE_CRASH_TESTS=1 because the trampoline crashed when invoked from
# Tox's background event_thread. That root cause is fixed (NativeCallable.listener
# marshals into the registering isolate; user_data is heap-allocated; the C
# handler guards against destroyed instances). Verified stable on macOS over
# repeated runs; flip default to 1 so the test runs as part of the default suite.
# Set RUN_NATIVE_CRASH_TESTS=0 to opt out (escape hatch only).
RUN_NATIVE_CRASH_TESTS="${RUN_NATIVE_CRASH_TESTS:-1}"
apply_known_unstable_filters() {
  if [ "$RUN_NATIVE_CRASH_TESTS" = "1" ]; then
    return
  fi

  if phase_selected "11"; then
    local unstable_dht="test/scenarios/scenario_dht_nodes_response_api_test.dart"
    local filtered_phase11=()
    local removed_phase11=0
    local t11
    for t11 in "${PHASE11_NETWORK[@]}"; do
      if [ "$t11" = "$unstable_dht" ]; then
        removed_phase11=1
      else
        filtered_phase11+=("$t11")
      fi
    done
    PHASE11_NETWORK=("${filtered_phase11[@]}")
    if [ "$removed_phase11" -eq 1 ]; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
      SKIPPED_TESTS+=("scenario_dht_nodes_response_api_test (KNOWN_NATIVE_CRASH, set RUN_NATIVE_CRASH_TESTS=1 to run)")
      echo -e "${YELLOW}Skipping known unstable test: scenario_dht_nodes_response_api_test (set RUN_NATIVE_CRASH_TESTS=1 to include)${NC}"
    fi
  fi
}
apply_known_unstable_filters

# SKIP_IN_PARALLEL filter — drop tests that declare themselves incompatible
# with concurrent execution. Convention: a file marked with a top-level
# comment of the form
#   // SKIP_IN_PARALLEL: <reason>
# (anywhere in the first ~40 lines, typically right after the docstring)
# is filtered out whenever PARALLEL_WORKERS>=2, regardless of whether the
# actual dispatch path is sequential (the one inside an N>=2 invocation
# of this script that ends up routing through run_phase), bundle, or
# parallel-xargs. The marker is applied symmetrically: if either the
# wall-clock _test.dart or its _virtual_test.dart sibling carries it,
# both variants are filtered.
#
# Concrete known case: scenario_lan_discovery — Tox LAN multicast on the
# loopback interface (33445-33545) requires sole occupancy or the
# discovery becomes ambiguous between parallel test processes.
_parallel_workers_for_filter="${PARALLEL_WORKERS:-1}"
if [[ "$_parallel_workers_for_filter" =~ ^[0-9]+$ ]] && [ "$_parallel_workers_for_filter" -ge 2 ]; then
  # Prints the SKIP_IN_PARALLEL reason on stdout if either the file or its
  # _virtual / wall-clock sibling carries the marker; otherwise prints
  # nothing. Always returns 0 (the empty-vs-nonempty stdout is the signal,
  # so `set -e` and command substitution interact safely).
  parallel_skip_reason_for_file() {
    local f="$1"
    local sibling
    if [[ "$f" == *_virtual_test.dart ]]; then
      sibling="${f%_virtual_test.dart}_test.dart"
    else
      sibling="${f%_test.dart}_virtual_test.dart"
    fi
    local candidate reason
    for candidate in "$f" "$sibling"; do
      if [ -f "$candidate" ]; then
        reason=$(grep -m1 -E '^[[:space:]]*//[[:space:]]*SKIP_IN_PARALLEL:' "$candidate" 2>/dev/null \
                  | sed -E 's|^[[:space:]]*//[[:space:]]*SKIP_IN_PARALLEL:[[:space:]]*||' \
                  || true)
        if [ -n "$reason" ]; then
          echo "$reason"
          return 0
        fi
      fi
    done
    return 0
  }

  filter_phase_array_for_parallel() {
    # $1: name of phase array variable (e.g. PHASE11_NETWORK).
    local arr_name="$1"
    eval "local _items=(\"\${${arr_name}[@]}\")"
    local kept=()
    local item reason base
    for item in "${_items[@]}"; do
      reason=$(parallel_skip_reason_for_file "$item")
      if [ -n "$reason" ]; then
        base=$(basename "$item" .dart)
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        SKIPPED_TESTS+=("$base (SKIP_IN_PARALLEL: $reason)")
        echo -e "${YELLOW}Skipping in parallel mode: $base — $reason${NC}"
      else
        kept+=("$item")
      fi
    done
    # Reassign the array variable; use printf to safely round-trip quoted entries.
    local quoted=""
    local k
    for k in "${kept[@]}"; do
      quoted+=" $(printf '%q' "$k")"
    done
    eval "$arr_name=($quoted)"
  }

  for _manifest_entry in "${PHASE_MANIFEST[@]}"; do
    filter_phase_array_for_parallel "$(printf '%s\n' "$_manifest_entry" | cut -d'|' -f2)"
  done
fi

# Account for phases dropped via SKIP_PHASES (env var parsed earlier).
# Adds each skipped phase's test count to TOTAL_SKIPPED and records a single
# "Phase N (SKIP_PHASES env)" entry per skipped phase. Done here (after the
# PHASEN_* arrays are populated and unstable filters applied) so the counts
# match what would have actually run. phase_array_size_for_num is defined with
# the other manifest accessors near the top of this script.
if [ ${#SKIP_PHASE_NUMS[@]} -gt 0 ]; then
  for skipped in "${SKIP_PHASE_NUMS[@]}"; do
    skipped_count=$(phase_array_size_for_num "$skipped")
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + skipped_count))
    SKIPPED_TESTS+=("Phase $skipped (SKIP_PHASES env)")
    echo -e "${YELLOW}Skipping phase $skipped: $(phase_name_for_num "$skipped") (via SKIP_PHASES)${NC}"
  done
fi

# Function to parse and display test case timings from Flutter test output
parse_test_timings() {
    local output_file=$1
    if [ ! -f "$output_file" ]; then
        return
    fi
    
    # Extract test lines and parse timing
    # Format: "00:01 +4: Test Group test name"
    local temp_file="/tmp/test_timings_$$.txt"
    
    # Extract test lines, convert time to seconds
    grep -E "^\s*[0-9]+:[0-9]+\s+\+[0-9]+:" "$output_file" 2>/dev/null | \
    grep -v "All tests passed" | \
    grep -vE "\(setUpAll\)|\(tearDownAll\)|\(setUp\)|\(tearDown\)" | \
    while IFS= read -r line; do
        # Extract time (MM:SS)
        local time_part=$(echo "$line" | sed -E 's/^\s*([0-9]+):([0-9]+).*/\1:\2/')
        if [ "$time_part" != "$line" ]; then
            local minutes=$(echo "$time_part" | cut -d: -f1)
            local seconds=$(echo "$time_part" | cut -d: -f2)
            local time_sec=$((minutes * 60 + seconds))
            
            # Extract test name (after "+N: ")
            local test_name=$(echo "$line" | sed -E 's/.*\+[0-9]+:[[:space:]]+(.+)$/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [ -n "$test_name" ]; then
                echo "${time_sec}|${test_name}"
            fi
        fi
    done > "$temp_file" 2>/dev/null
    
    # Process to find duplicates and calculate durations
    local prev_time=0
    local prev_name=""
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        while IFS='|' read -r time_sec test_name; do
            if [ -n "$prev_name" ] && [ "$prev_name" = "$test_name" ]; then
                local duration=$((time_sec - prev_time))
                if [ $duration -gt 0 ]; then
                    echo -e "${YELLOW}    ✓ $test_name${NC} - ${GREEN}${duration}s${NC}"
                fi
            fi
            prev_time=$time_sec
            prev_name="$test_name"
        done < "$temp_file"
        
        # Handle last test using "All tests passed" line
        local final_line=$(grep "All tests passed" "$output_file" 2>/dev/null | head -1)
        if [ -n "$final_line" ] && [ -n "$prev_name" ]; then
            local final_time_part=$(echo "$final_line" | sed -E 's/^\s*([0-9]+):([0-9]+).*/\1:\2/')
            if [ "$final_time_part" != "$final_line" ]; then
                local final_minutes=$(echo "$final_time_part" | cut -d: -f1)
                local final_seconds=$(echo "$final_time_part" | cut -d: -f2)
                local final_time=$((final_minutes * 60 + final_seconds))
                local duration=$((final_time - prev_time))
                if [ $duration -gt 0 ]; then
                    echo -e "${YELLOW}    ✓ $prev_name${NC} - ${GREEN}${duration}s${NC}"
                fi
            fi
        fi
    fi
    
    rm -f "$temp_file"
}

# Function to run a single test with 180s timeout
run_single_test() {
  local test_file=$1
  local phase_name=$2
  local test_num=$3
  local total_in_phase=$4

  # Virtual-mode toggle: when RUN_VIRTUAL=1, swap to the *_virtual_test.dart
  # sibling if it exists. Falls back to the wall-clock original when no
  # virtual variant has been authored yet. Set RUN_VIRTUAL=0 (default) for
  # the legacy wall-clock run.
  if [ "${RUN_VIRTUAL:-0}" = "1" ]; then
    local virtual_file="${test_file%_test.dart}_virtual_test.dart"
    if [ -f "$virtual_file" ]; then
      test_file="$virtual_file"
    fi
  fi

  local test_name=$(basename "$test_file" .dart)

  echo "" | tee -a "$RESULTS_FILE"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${YELLOW}[$phase_name] Test $test_num/$total_in_phase: $test_name${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$RESULTS_FILE"

  # Use 300s timeout for tests that need more time (conference, nospam, group_create_debug).
  # Group moderation runs 4 sub-tests that each need a fresh group + invite +
  # join + member-discovery cycle (~90s each on local bootstrap), totalling
  # ~360s — easily over the default 180s. Even when individual sub-tests
  # fail fast, setUpAll/tearDownAll between them adds up. Give the whole
  # file 600s so timeouts surface as real assertion failures, not runner
  # kills.
  # Strip optional _virtual suffix for timeout matching so wall + virtual
  # variants share the same per-file budget.
  local test_basekey="${test_name%_virtual_test}"
  test_basekey="${test_basekey%_test}"
  local test_timeout=180
  case "$test_basekey" in
    scenario_conference|scenario_nospam|scenario_group_create_debug)
      test_timeout=300 ;;
    scenario_group_large)
      # 5 nodes + 4 friendships; each invite retry can wait 30s × 3 tries
      # when Tox friend P2P is racy in local bootstrap. 5 sub-tests × worst-
      # case 90s + setUpAll fits in 600s.
      test_timeout=600 ;;
    scenario_group_moderation)
      test_timeout=600 ;;
  esac

  # Retry loop: attempt 0 is the first run; attempts 1..RETRY_COUNT are retries.
  # On a retry pass, count PASSED + record in FLAKY_TESTS. On all-attempts-fail,
  # fall through to the legacy FAILED accounting using the LAST attempt's output.
  local max_attempts=$((RETRY_COUNT + 1))
  local attempt=0
  local last_exit_code=0
  local last_output_file=""
  local last_duration=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    if [ "$attempt" -gt 0 ]; then
      echo -e "${YELLOW}🔁 RETRY $attempt/$RETRY_COUNT: $test_name${NC}" | tee -a "$RESULTS_FILE"
    fi

    local start_time=$(date +%s)
    local output_file="/tmp/test_${test_name}_$(date +%s)_${attempt}_$$.log"

    if timeout ${test_timeout}s flutter test "$test_file" > "$output_file" 2>&1; then
      local end_time=$(date +%s)
      local duration=$((end_time - start_time))
      echo -e "${GREEN}✅ PASSED: $test_name (${duration}s)${NC}" | tee -a "$RESULTS_FILE"
      echo -e "${GREEN}  Test case timings:${NC}" | tee -a "$RESULTS_FILE"
      parse_test_timings "$output_file" | tee -a "$RESULTS_FILE"
      ((TOTAL_PASSED++))
      if [ "$attempt" -gt 0 ]; then
        # Passed after at least one retry — record as flaky.
        ((TOTAL_FLAKY++))
        FLAKY_TESTS+=("$test_name (passed on retry $attempt/$RETRY_COUNT)")
      fi
      rm -f "$output_file"
      return 0
    fi
    last_exit_code=$?
    local end_time=$(date +%s)
    last_duration=$((end_time - start_time))
    # Clean up intermediate retry logs; only keep the last attempt's output
    # for the FAILED tail dump below.
    if [ -n "$last_output_file" ]; then
      rm -f "$last_output_file"
    fi
    last_output_file="$output_file"
    ((attempt++))
  done

  # All attempts failed — replicate the original failure handling using the
  # LAST attempt's output_file / duration / exit_code.
  if [ "$last_exit_code" -eq 124 ]; then
    # Timeout
    echo -e "${RED}⏱️  TIMEOUT: $test_name (exceeded ${test_timeout}s)${NC}" | tee -a "$RESULTS_FILE"
    FAILED_TESTS+=("$test_name (TIMEOUT)")
  else
    # Test failure
    echo -e "${RED}❌ FAILED: $test_name (${last_duration}s)${NC}" | tee -a "$RESULTS_FILE"
    echo -e "${YELLOW}  Test case timings:${NC}" | tee -a "$RESULTS_FILE"
    parse_test_timings "$last_output_file" | tee -a "$RESULTS_FILE"
    FAILED_TESTS+=("$test_name")
  fi

  # Surface the actual Dart test assertion(s) first — on multi-subtest scenarios the
  # failing 'expect'/timeout is otherwise buried far above the teardown spam that the
  # tail captures, making CI failures undiagnosable from the artifact alone.
  echo -e "${YELLOW}Assertion markers:${NC}" | tee -a "$RESULTS_FILE"
  grep -aE '[+][0-9]+ -[0-9]+:|\[E\]|Expected:|Actual:|TimeoutException|Exception:|Test failed|Which:' "$last_output_file" \
    | grep -avE '^Shell:|\[establishFriendship\]|\[waitForFriendConnection\]|\[Bootstrap\]' \
    | tail -60 | tee -a "$RESULTS_FILE" || true

  # Show last 120 lines of output for debugging (enough to clear teardown noise and
  # reach the failing subtest's native logs on multi-subtest scenario files).
  echo -e "${YELLOW}Last 120 lines of output:${NC}" | tee -a "$RESULTS_FILE"
  tail -120 "$last_output_file" | tee -a "$RESULTS_FILE"

  ((TOTAL_FAILED++))
  rm -f "$last_output_file"
  return 1
}

# Function to run a phase of tests
run_phase() {
  local phase_name=$1
  shift
  local test_files=("$@")

  echo "" | tee -a "$RESULTS_FILE"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${GREEN}  Phase: $phase_name (${#test_files[@]} tests)${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$RESULTS_FILE"

  local phase_passed=0
  local phase_failed=0
  local total=${#test_files[@]}
  local test_num=0

  for test_file in "${test_files[@]}"; do
    ((test_num++))
    if run_single_test "$test_file" "$phase_name" "$test_num" "$total"; then
      ((phase_passed++))
    else
      ((phase_failed++))
    fi
    # The previous 1-second inter-test sleep was a 70+ s tax across the full
    # run that wasn't tied to any observable resource issue — flutter_tester
    # already exits before we move on. Drop it. If a regression points at
    # genuine resource contention, restore with TEST_INTER_DELAY env.
    if [ -n "${TEST_INTER_DELAY:-}" ] && [ "$TEST_INTER_DELAY" -gt 0 ] 2>/dev/null; then
      sleep "$TEST_INTER_DELAY"
    fi
  done

  echo "" | tee -a "$RESULTS_FILE"
  echo -e "${YELLOW}=== $phase_name Summary: $phase_passed/$total passed, $phase_failed/$total failed ===${NC}" | tee -a "$RESULTS_FILE"

  return $phase_failed
}

# Bundle-mode runner: dispatch all of [phase_name]'s test files into ONE
# `flutter test` invocation so they can share the SharedScenarioPool
# fixtures (see test_helper.dart). Test files that have been converted
# to call `acquireSharedScenario(...)` reuse a cached scenario across
# setUpAll boundaries; tests still on the legacy createTestScenario path
# pay their original cold-start cost.
#
# Output parsing: flutter test prints each file's results as
#   "<elapsed> +N -M: <abs/path/to/file.dart>: <group> <test>"
# We grep for the "All tests passed!" terminator at the end and treat
# the whole bundle as one pass/fail unit. Individual file granularity is
# preserved in the bundle log file for post-mortem.
run_phase_bundled() {
  local phase_name=$1
  shift
  local test_files=("$@")

  echo "" | tee -a "$RESULTS_FILE"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${GREEN}  Phase: $phase_name (${#test_files[@]} tests, BUNDLED)${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$RESULTS_FILE"

  # Resolve each test_file through the same RUN_VIRTUAL swap that
  # run_single_test does, so bundle mode honours the same flag.
  local resolved_files=()
  for tf in "${test_files[@]}"; do
    if [ "${RUN_VIRTUAL:-0}" = "1" ]; then
      local virtual_file="${tf%_test.dart}_virtual_test.dart"
      if [ -f "$virtual_file" ]; then
        tf="$virtual_file"
      fi
    fi
    resolved_files+=("$tf")
  done

  # Bundle timeout: sum of per-file timeouts is overly pessimistic (the
  # whole point of bundling is fixture reuse). Use a flat ceiling that
  # scales with file count but caps at 1800s (30 min) for very large
  # phases. Tunable via BUNDLE_TIMEOUT env.
  local n=${#resolved_files[@]}
  local bundle_timeout="${BUNDLE_TIMEOUT:-$((n * 60))}"
  if [ "$bundle_timeout" -gt 1800 ]; then bundle_timeout=1800; fi
  if [ "$bundle_timeout" -lt 180 ]; then bundle_timeout=180; fi

  local bundle_log="/tmp/bundle_${phase_name// /_}_$(date +%s).log"
  local start_time
  start_time=$(date +%s)

  echo -e "${BLUE}[Bundle] Dispatching ${n} files in one flutter test invocation (timeout ${bundle_timeout}s)${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${BLUE}[Bundle] Output: $bundle_log${NC}" | tee -a "$RESULTS_FILE"

  # Capture exit code without `if` so we can branch correctly. The `set -e`
  # at the top of the script would otherwise abort on the non-zero status;
  # `|| true` pattern keeps the script going while preserving the code.
  local exit_code=0
  timeout "${bundle_timeout}s" flutter test "${resolved_files[@]}" > "$bundle_log" 2>&1 || exit_code=$?
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  if [ "$exit_code" -eq 0 ]; then
    echo -e "${GREEN}✅ BUNDLE PASSED: $phase_name (${duration}s for ${n} files)${NC}" | tee -a "$RESULTS_FILE"
    TOTAL_PASSED=$((TOTAL_PASSED + n))
    rm -f "$bundle_log"
    return 0
  fi

  if [ "$exit_code" -eq 124 ]; then
    echo -e "${RED}⏱️  BUNDLE TIMEOUT: $phase_name (exceeded ${bundle_timeout}s)${NC}" | tee -a "$RESULTS_FILE"
  else
    echo -e "${RED}❌ BUNDLE FAILED: $phase_name (${duration}s, exit=$exit_code)${NC}" | tee -a "$RESULTS_FILE"
  fi

  # Try to extract per-file pass/fail from flutter test's output. Each
  # failing test prints a line like:
  #   "00:34 +5 -1: <file.dart>: <group> <test name> [E]"
  # We grep the unique file paths that had failures and attribute them.
  local failed_files
  failed_files=$(grep -E "\-[0-9]+:.+\.dart:" "$bundle_log" 2>/dev/null \
                  | grep -oE "/[^[:space:]]+\.dart" 2>/dev/null \
                  | sort -u || true)
  local bundle_failed=0
  local bundle_passed=0
  if [ -n "$failed_files" ]; then
    for ff in $failed_files; do
      FAILED_TESTS+=("$(basename "$ff" .dart) (BUNDLE)")
      ((bundle_failed++))
    done
  fi
  # Any file we sent that didn't appear in failed_files is treated as passed.
  for tf in "${resolved_files[@]}"; do
    local hit=0
    for ff in $failed_files; do
      if [ "$(basename "$tf")" = "$(basename "$ff")" ]; then
        hit=1
        break
      fi
    done
    if [ "$hit" -eq 0 ]; then
      ((bundle_passed++))
    fi
  done
  TOTAL_PASSED=$((TOTAL_PASSED + bundle_passed))
  TOTAL_FAILED=$((TOTAL_FAILED + bundle_failed))

  echo -e "${YELLOW}[Bundle] $bundle_passed pass / $bundle_failed fail (attributed); see $bundle_log${NC}" | tee -a "$RESULTS_FILE"
  # Show last 50 lines for diagnostics
  echo -e "${YELLOW}Last 50 lines of bundle log:${NC}" | tee -a "$RESULTS_FILE"
  tail -50 "$bundle_log" | tee -a "$RESULTS_FILE"

  return 1
}

# Start logging
echo "Test execution started at $(date)" > "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"

# Return the per-test timeout (seconds) for a given test file path.
# Mirrors the timeout case-block inside run_single_test so the parallel
# path uses the same per-file budgets.
get_test_timeout_for_file() {
  local test_file=$1
  local test_name=$(basename "$test_file" .dart)
  local test_basekey="${test_name%_virtual_test}"
  test_basekey="${test_basekey%_test}"
  case "$test_basekey" in
    scenario_conference|scenario_nospam|scenario_group_create_debug) echo 300 ;;
    scenario_group_large|scenario_group_moderation) echo 600 ;;
    *) echo 180 ;;
  esac
}

# Worker entry point used by parallel mode (PARALLEL_WORKERS>1).
# Writes <status> <test_name> <duration> <phase_label> to a per-test
# status file in $PARALLEL_RESULT_DIR. The master aggregates these
# after xargs returns.
run_test_worker() {
  local test_file=$1
  local phase_label=$2

  # Virtual-mode swap (same logic as run_single_test).
  if [ "${RUN_VIRTUAL:-0}" = "1" ]; then
    local virtual_file="${test_file%_test.dart}_virtual_test.dart"
    if [ -f "$virtual_file" ]; then
      test_file="$virtual_file"
    fi
  fi

  local test_name=$(basename "$test_file" .dart)
  local start_time=$(date +%s)
  local output_file="$PARALLEL_RESULT_DIR/${test_name}.log"
  local test_timeout
  test_timeout=$(get_test_timeout_for_file "$test_file")
  local status=""

  if timeout "${test_timeout}s" flutter test "$test_file" > "$output_file" 2>&1; then
    status="PASSED"
  else
    local rc=$?
    if [ "$rc" -eq 124 ]; then status="TIMEOUT"; else status="FAILED"; fi
  fi
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  # One line per test, phase label is single-token (no spaces) for easy parsing.
  printf '%s %s %d %s\n' "$status" "$test_name" "$duration" "$phase_label" \
    > "$PARALLEL_RESULT_DIR/${test_name}.status"
}
export -f get_test_timeout_for_file run_test_worker

# phase_label_for_num is defined with the other manifest accessors near the top.

# Build "test_file<TAB>phase_label" pairs for every test in the
# selected phases. Used only by parallel mode.
build_parallel_queue() {
  local pn var label test
  for pn in "${SELECTED_PHASES[@]}"; do
    var=$(phase_varname_for_num "$pn") || continue
    eval "local arr=(\"\${${var}[@]}\")"
    label=$(phase_label_for_num "$pn")
    for test in "${arr[@]}"; do
      printf '%s\t%s\n' "$test" "$label"
    done
  done
}

# Aggregate parallel status files back into the global counters and
# print phase-grouped output, sorted by dispatch order.
collect_parallel_results() {
  local pn var arr label total phase_total phase_passed phase_failed
  for pn in "${SELECTED_PHASES[@]}"; do
    var=$(phase_varname_for_num "$pn") || continue
    eval "arr=(\"\${${var}[@]}\")"
    label=$(phase_name_for_num "$pn")
    total=${#arr[@]}
    phase_passed=0
    phase_failed=0
    echo "" | tee -a "$RESULTS_FILE"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$RESULTS_FILE"
    echo -e "${GREEN}  Phase: $label ($total tests)${NC}" | tee -a "$RESULTS_FILE"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$RESULTS_FILE"

    local tnum=0
    local test_file test_basename effective_basename status_line status duration_sec
    for test_file in "${arr[@]}"; do
      ((tnum++))
      effective_basename=$(basename "$test_file" .dart)
      # Account for the virtual-mode rename.
      if [ "${RUN_VIRTUAL:-0}" = "1" ]; then
        local v="${test_file%_test.dart}_virtual_test.dart"
        if [ -f "$v" ]; then
          effective_basename=$(basename "$v" .dart)
        fi
      fi
      test_basename="$effective_basename"
      local status_file="$PARALLEL_RESULT_DIR/${test_basename}.status"
      if [ ! -f "$status_file" ]; then
        echo -e "${RED}❓ NO RESULT: $test_basename (worker did not produce status)${NC}" | tee -a "$RESULTS_FILE"
        FAILED_TESTS+=("$test_basename (NO_RESULT)")
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        ((phase_failed++))
        continue
      fi
      status_line=$(cat "$status_file")
      status=$(echo "$status_line" | awk '{print $1}')
      duration_sec=$(echo "$status_line" | awk '{print $3}')

      case "$status" in
        PASSED)
          echo -e "${GREEN}✅ PASSED: $test_basename (${duration_sec}s)${NC}" | tee -a "$RESULTS_FILE"
          TOTAL_PASSED=$((TOTAL_PASSED + 1))
          ((phase_passed++))
          ;;
        TIMEOUT)
          local to
          to=$(get_test_timeout_for_file "$test_file")
          echo -e "${RED}⏱️  TIMEOUT: $test_basename (exceeded ${to}s)${NC}" | tee -a "$RESULTS_FILE"
          FAILED_TESTS+=("$test_basename (TIMEOUT)")
          TOTAL_FAILED=$((TOTAL_FAILED + 1))
          ((phase_failed++))
          ;;
        FAILED|*)
          echo -e "${RED}❌ FAILED: $test_basename (${duration_sec}s)${NC}" | tee -a "$RESULTS_FILE"
          if [ -f "$PARALLEL_RESULT_DIR/${test_basename}.log" ]; then
            echo -e "${YELLOW}  Last 30 lines:${NC}" | tee -a "$RESULTS_FILE"
            tail -30 "$PARALLEL_RESULT_DIR/${test_basename}.log" | tee -a "$RESULTS_FILE"
          fi
          FAILED_TESTS+=("$test_basename")
          TOTAL_FAILED=$((TOTAL_FAILED + 1))
          ((phase_failed++))
          ;;
      esac
    done

    echo "" | tee -a "$RESULTS_FILE"
    echo -e "${YELLOW}=== $label Summary: $phase_passed/$total passed, $phase_failed/$total failed ===${NC}" | tee -a "$RESULTS_FILE"
  done
}

run_phase_by_number() {
  local num="$1"
  local runner=run_phase
  if [ "${BUNDLE:-0}" = "1" ]; then
    runner=run_phase_bundled
  fi
  local var name
  var=$(phase_varname_for_num "$num") || {
    echo -e "${RED}Internal error: unsupported phase number: $num${NC}"
    exit 3
  }
  name=$(phase_name_for_num "$num")
  eval "local _files=(\"\${${var}[@]}\")"
  "$runner" "$name" "${_files[@]}" || true
}

# PARALLEL_WORKERS=N runs the entire selected queue across N concurrent
# `flutter test` invocations. Default 1 keeps the legacy sequential
# behavior. Tox tests are timing-sensitive (60s DHT ping, 122s BAD_NODE);
# 2-3 workers usually fit on a developer Mac without flaking, higher
# values risk wall-clock-timer starvation.
PARALLEL_WORKERS="${PARALLEL_WORKERS:-1}"
if ! [[ "$PARALLEL_WORKERS" =~ ^[0-9]+$ ]] || [ "$PARALLEL_WORKERS" -lt 1 ]; then
  echo -e "${RED}PARALLEL_WORKERS must be a positive integer (got: $PARALLEL_WORKERS)${NC}"
  exit 2
fi

if [ "$PARALLEL_WORKERS" -gt 1 ]; then
  PARALLEL_RESULT_DIR="$(mktemp -d /tmp/tim2tox_parallel.XXXXXX)"
  export PARALLEL_RESULT_DIR RUN_VIRTUAL
  echo -e "${GREEN}Parallel mode: PARALLEL_WORKERS=$PARALLEL_WORKERS, scratch dir: $PARALLEL_RESULT_DIR${NC}" | tee -a "$RESULTS_FILE"
  PARALLEL_START=$(date +%s)
  # Dispatch every test through xargs -P. Each line of the queue is one
  # "<test_file>\t<phase_label>" pair; awk splits it back inside the
  # worker so paths with spaces are handled defensively.
  build_parallel_queue | \
    xargs -P "$PARALLEL_WORKERS" -n 1 -I '{}' bash -c '
      line="$1"
      tf="${line%%	*}"
      lbl="${line##*	}"
      run_test_worker "$tf" "$lbl"
    ' _ '{}'
  PARALLEL_END=$(date +%s)
  PARALLEL_ELAPSED=$((PARALLEL_END - PARALLEL_START))
  echo -e "${GREEN}Parallel run finished in ${PARALLEL_ELAPSED}s wall-clock${NC}" | tee -a "$RESULTS_FILE"
  collect_parallel_results
  rm -rf "$PARALLEL_RESULT_DIR"
else
  for phase_num in "${SELECTED_PHASES[@]}"; do
    run_phase_by_number "$phase_num"
  done
fi

# Calculate totals
TOTAL_TESTS=$((TOTAL_PASSED + TOTAL_FAILED + TOTAL_SKIPPED))

# Write summary (direct to file to avoid pipeline subshell array inheritance issues)
{
  echo "═══════════════════════════════════════════════════════════"
  echo "  Test Execution Summary"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "Execution Date: $(date)"
  echo "Total Tests: $TOTAL_TESTS"
  echo "Passed: $TOTAL_PASSED"
  echo "Failed: $TOTAL_FAILED"
  echo "Skipped: $TOTAL_SKIPPED"
  echo "Flaky:  $TOTAL_FLAKY"
  echo ""

  if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo "Failed Tests:"
    for test in "${FAILED_TESTS[@]}"; do
      echo "  - $test"
    done
    echo ""
  fi

  if [ ${#FLAKY_TESTS[@]} -gt 0 ]; then
    echo "Flaky Tests:"
    for test in "${FLAKY_TESTS[@]}"; do
      echo "  - $test"
    done
    echo ""
  fi

  if [ ${#SKIPPED_TESTS[@]} -gt 0 ]; then
    echo "Skipped Tests:"
    for test in "${SKIPPED_TESTS[@]}"; do
      echo "  - $test"
    done
    echo ""
  fi

  echo "═══════════════════════════════════════════════════════════"
} > "$SUMMARY_FILE"
cat "$SUMMARY_FILE"

# Display summary
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Final Summary${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "Total Tests: ${BLUE}$TOTAL_TESTS${NC}"
echo -e "Passed: ${GREEN}$TOTAL_PASSED${NC}"
echo -e "Failed: ${RED}$TOTAL_FAILED${NC}"
echo -e "Skipped: ${YELLOW}$TOTAL_SKIPPED${NC}"
echo -e "Flaky:  ${YELLOW}$TOTAL_FLAKY${NC}"
echo ""
echo "Detailed results: $RESULTS_FILE"
echo "Summary: $SUMMARY_FILE"

if [ $TOTAL_FAILED -eq 0 ]; then
  echo -e "${GREEN}✅ All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ $TOTAL_FAILED tests failed${NC}"
  exit 1
fi
