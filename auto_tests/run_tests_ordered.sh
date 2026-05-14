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
EOF
}

# Resolve selector token to phase number (1-14)
resolve_phase_arg() {
  local arg="$1"
  if [ -z "$arg" ]; then
    echo ""
    return
  fi

  local upper
  upper=$(echo "$arg" | tr '[:lower:]' '[:upper:]')

  if [ "$upper" -eq "$upper" ] 2>/dev/null; then
    if [ "$upper" -ge 1 ] && [ "$upper" -le 14 ]; then
      echo "$upper"
      return
    fi
  fi

  case "$upper" in
    1|BASIC|PHASE1|PHASE1_BASIC) echo "1" ;;
    2|FRIENDSHIP|PHASE2|PHASE2_FRIENDSHIP) echo "2" ;;
    3|MESSAGE|PHASE3|PHASE3_MESSAGE) echo "3" ;;
    4|GROUP|PHASE4|PHASE4_GROUP) echo "4" ;;
    5|TOXAV|PHASE5|PHASE5_TOXAV) echo "5" ;;
    6|PROFILE|PHASE6|PHASE6_PROFILE) echo "6" ;;
    7|CONVERSATION|PHASE7|PHASE7_CONVERSATION) echo "7" ;;
    8|FILE|PHASE8|PHASE8_FILE) echo "8" ;;
    9|CONFERENCE|PHASE9|PHASE9_CONFERENCE) echo "9" ;;
    10|GROUP_EXT|GROUPEXT|PHASE10|PHASE10_GROUP_EXT) echo "10" ;;
    11|NETWORK|PHASE11|PHASE11_NETWORK) echo "11" ;;
    12|OTHER|PHASE12|PHASE12_OTHER) echo "12" ;;
    13|BINARY|PHASE13|PHASE13_BINARY|PHASE13_BINARY_REPLACEMENT|BINARY_REPLACEMENT) echo "13" ;;
    14|UNIT|UNIT_TEST|UNIT_TESTS|PHASE14|PHASE14_UNIT) echo "14" ;;
    *) echo "" ;;
  esac
}

phase_name_for_num() {
  case "$1" in
    1) echo "Phase 1: Basic Tests" ;;
    2) echo "Phase 2: Friendship Tests" ;;
    3) echo "Phase 3: Message Tests" ;;
    4) echo "Phase 4: Group Tests" ;;
    5) echo "Phase 5: ToxAV Tests" ;;
    6) echo "Phase 6: Profile Tests" ;;
    7) echo "Phase 7: Conversation Tests" ;;
    8) echo "Phase 8: File Tests" ;;
    9) echo "Phase 9: Conference Tests" ;;
    10) echo "Phase 10: Group Extended Tests" ;;
    11) echo "Phase 11: Network Tests" ;;
    12) echo "Phase 12: Other Tests" ;;
    13) echo "Phase 13: Binary Replacement Tests" ;;
    14) echo "Phase 14: Unit Tests" ;;
    *) echo "Phase ?: Unknown" ;;
  esac
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
  for p in $(seq 1 14); do
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

# Install dependencies
echo -e "${YELLOW}Installing dependencies...${NC}"
flutter pub get

# Test files organized by complexity/dependencies (69 scenario + 3 binary + 1 unit)
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
  "test/scenarios/scenario_conference_offline_test.dart"
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
FAILED_TESTS=()
SKIPPED_TESTS=()

# Known unstable tests (native crash in current branch/environment)
# Set RUN_NATIVE_CRASH_TESTS=1 to include them.
RUN_NATIVE_CRASH_TESTS="${RUN_NATIVE_CRASH_TESTS:-0}"
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
  
  local test_name=$(basename "$test_file" .dart)
  
  echo "" | tee -a "$RESULTS_FILE"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${YELLOW}[$phase_name] Test $test_num/$total_in_phase: $test_name${NC}" | tee -a "$RESULTS_FILE"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$RESULTS_FILE"
  
  local start_time=$(date +%s)
  local output_file="/tmp/test_${test_name}_$(date +%s).log"
  
  # Use 300s timeout for tests that need more time (conference, nospam, group_create_debug).
  # Group moderation runs 4 sub-tests that each need a fresh group + invite +
  # join + member-discovery cycle (~90s each on local bootstrap), totalling
  # ~360s — easily over the default 180s. Even when individual sub-tests
  # fail fast, setUpAll/tearDownAll between them adds up. Give the whole
  # file 600s so timeouts surface as real assertion failures, not runner
  # kills.
  local test_timeout=180
  if [[ "$test_name" == "scenario_conference_test" ]] || \
     [[ "$test_name" == "scenario_nospam_test" ]] || \
     [[ "$test_name" == "scenario_group_create_debug_test" ]]; then
    test_timeout=300
  elif [[ "$test_name" == "scenario_group_moderation_test" ]]; then
    test_timeout=600
  fi
  
  # Run test with timeout, capture output
  if timeout ${test_timeout}s flutter test "$test_file" > "$output_file" 2>&1; then
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo -e "${GREEN}✅ PASSED: $test_name (${duration}s)${NC}" | tee -a "$RESULTS_FILE"
    echo -e "${GREEN}  Test case timings:${NC}" | tee -a "$RESULTS_FILE"
    parse_test_timings "$output_file" | tee -a "$RESULTS_FILE"
    ((TOTAL_PASSED++))
    rm -f "$output_file"
    return 0
  else
    local exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ $exit_code -eq 124 ]; then
      # Timeout
      echo -e "${RED}⏱️  TIMEOUT: $test_name (exceeded ${test_timeout}s)${NC}" | tee -a "$RESULTS_FILE"
      FAILED_TESTS+=("$test_name (TIMEOUT)")
    else
      # Test failure
      echo -e "${RED}❌ FAILED: $test_name (${duration}s)${NC}" | tee -a "$RESULTS_FILE"
      echo -e "${YELLOW}  Test case timings:${NC}" | tee -a "$RESULTS_FILE"
      parse_test_timings "$output_file" | tee -a "$RESULTS_FILE"
      FAILED_TESTS+=("$test_name")
    fi
    
    # Show last 30 lines of output for debugging
    echo -e "${YELLOW}Last 30 lines of output:${NC}" | tee -a "$RESULTS_FILE"
    tail -30 "$output_file" | tee -a "$RESULTS_FILE"
    
    ((TOTAL_FAILED++))
    rm -f "$output_file"
    return 1
  fi
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
    # Small delay between tests to avoid resource exhaustion
    sleep 1
  done
  
  echo "" | tee -a "$RESULTS_FILE"
  echo -e "${YELLOW}=== $phase_name Summary: $phase_passed/$total passed, $phase_failed/$total failed ===${NC}" | tee -a "$RESULTS_FILE"
  
  return $phase_failed
}

# Start logging
echo "Test execution started at $(date)" > "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"

run_phase_by_number() {
  local num="$1"
  case "$num" in
    1) run_phase "Phase 1: Basic Tests" "${PHASE1_BASIC[@]}" || true ;;
    2) run_phase "Phase 2: Friendship Tests" "${PHASE2_FRIENDSHIP[@]}" || true ;;
    3) run_phase "Phase 3: Message Tests" "${PHASE3_MESSAGE[@]}" || true ;;
    4) run_phase "Phase 4: Group Tests" "${PHASE4_GROUP[@]}" || true ;;
    5) run_phase "Phase 5: ToxAV Tests" "${PHASE5_TOXAV[@]}" || true ;;
    6) run_phase "Phase 6: Profile Tests" "${PHASE6_PROFILE[@]}" || true ;;
    7) run_phase "Phase 7: Conversation Tests" "${PHASE7_CONVERSATION[@]}" || true ;;
    8) run_phase "Phase 8: File Tests" "${PHASE8_FILE[@]}" || true ;;
    9) run_phase "Phase 9: Conference Tests" "${PHASE9_CONFERENCE[@]}" || true ;;
    10) run_phase "Phase 10: Group Extended Tests" "${PHASE10_GROUP_EXT[@]}" || true ;;
    11) run_phase "Phase 11: Network Tests" "${PHASE11_NETWORK[@]}" || true ;;
    12) run_phase "Phase 12: Other Tests" "${PHASE12_OTHER[@]}" || true ;;
    13) run_phase "Phase 13: Binary Replacement Tests" "${PHASE13_BINARY_REPLACEMENT[@]}" || true ;;
    14) run_phase "Phase 14: Unit Tests" "${PHASE14_UNIT[@]}" || true ;;
    *)
      echo -e "${RED}Internal error: unsupported phase number: $num${NC}"
      exit 3
      ;;
  esac
}

for phase_num in "${SELECTED_PHASES[@]}"; do
  run_phase_by_number "$phase_num"
done

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
  echo ""
  
  if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo "Failed Tests:"
    for test in "${FAILED_TESTS[@]}"; do
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
