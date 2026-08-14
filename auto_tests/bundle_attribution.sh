#!/usr/bin/env bash

bundle_failed_files_from_log() {
  local bundle_log="$1"
  grep -E "\-[0-9]+:.+\.dart:" "$bundle_log" 2>/dev/null \
    | grep -oE "/[^[:space:]]+\.dart" 2>/dev/null \
    | sort -u || true
}

bundle_attribution_rows() {
  local exit_code="$1"
  local bundle_log="$2"
  shift 2

  local failed_files
  failed_files=$(bundle_failed_files_from_log "$bundle_log")

  local attributed_failed=0
  local test_file failed_file test_basename failed_basename
  for test_file in "$@"; do
    test_basename="${test_file##*/}"
    while IFS= read -r failed_file; do
      [ -n "$failed_file" ] || continue
      failed_basename="${failed_file##*/}"
      if [ "$test_basename" = "$failed_basename" ]; then
        attributed_failed=$((attributed_failed + 1))
        break
      fi
    done <<< "$failed_files"
  done

  local unresolved_label=""
  if [ "$exit_code" -eq 124 ]; then
    unresolved_label="BUNDLE TIMEOUT"
  elif [ "$exit_code" -ne 0 ] && [ "$attributed_failed" -eq 0 ]; then
    unresolved_label="BUNDLE UNATTRIBUTED exit=$exit_code"
  elif [ "$exit_code" -ne 0 ]; then
    unresolved_label="BUNDLE UNRESOLVED exit=$exit_code"
  fi

  local status label
  for test_file in "$@"; do
    test_basename="${test_file##*/}"
    test_basename="${test_basename%.dart}"
    status="PASSED"
    label=""

    while IFS= read -r failed_file; do
      [ -n "$failed_file" ] || continue
      failed_basename="${failed_file##*/}"
      if [ "${test_file##*/}" = "$failed_basename" ]; then
        status="FAILED"
        label="BUNDLE"
        break
      fi
    done <<< "$failed_files"

    if [ "$status" = "PASSED" ] && [ "$exit_code" -ne 0 ]; then
      status="FAILED"
      label="$unresolved_label"
    fi

    printf '%s\t%s\t%s\n' "$status" "$test_basename" "$label"
  done
}
