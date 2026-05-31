#!/usr/bin/env bats
# =============================================================================
# @file test_utilities.bats
# @description BATS tests for pure utility functions in modules/utilities.sh.
#
# Covers the version-handling family:
#   detect_version_format, get_version_series, get_version_patch,
#   get_java_version_for_mc, get_lwjgl_version_for_mc
#
# All tested functions are pure (stdout-only, no side effects), so every
# test uses `run` and checks $output + $status.
#
# Usage:
#   bats tests/test_utilities.bats
# =============================================================================

setup() {
    PROJECT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MODULES_DIR="$PROJECT_DIR/modules"

    # Silence installer output before sourcing.
    print_header()    { :; }
    is_immutable_os() { return 1; }

    source "$MODULES_DIR/version_info.sh"
    source "$MODULES_DIR/utilities.sh"

    # Re-apply after sourcing so utilities.sh definitions don't win.
    LOG_FILE=/dev/null
    print_header()    { :; }
    print_success()   { :; }
    print_warning()   { :; }
    print_error()     { :; }
    print_info()      { :; }
    print_progress()  { :; }
}

# =============================================================================
# detect_version_format
# =============================================================================

@test "detect_version_format: 1.21.4 → legacy" {
    run detect_version_format "1.21.4"
    [ "$status" -eq 0 ]
    [ "$output" = "legacy" ]
}

@test "detect_version_format: 1.8.9 → legacy" {
    run detect_version_format "1.8.9"
    [ "$output" = "legacy" ]
}

@test "detect_version_format: 25.1 → year" {
    run detect_version_format "25.1"
    [ "$output" = "year" ]
}

@test "detect_version_format: 25.1.2 → year" {
    run detect_version_format "25.1.2"
    [ "$output" = "year" ]
}

@test "detect_version_format: 26.3 → year" {
    run detect_version_format "26.3"
    [ "$output" = "year" ]
}

# =============================================================================
# get_version_series
# =============================================================================

@test "get_version_series: 1.21.4 → 1.21" {
    run get_version_series "1.21.4"
    [ "$output" = "1.21" ]
}

@test "get_version_series: 1.21 → 1.21 (no patch)" {
    run get_version_series "1.21"
    [ "$output" = "1.21" ]
}

@test "get_version_series: 1.20.4 → 1.20" {
    run get_version_series "1.20.4"
    [ "$output" = "1.20" ]
}

@test "get_version_series: 25.1.2 → 25.1 (year-based)" {
    run get_version_series "25.1.2"
    [ "$output" = "25.1" ]
}

@test "get_version_series: 25.1 → 25.1 (year-based, no patch)" {
    run get_version_series "25.1"
    [ "$output" = "25.1" ]
}

# =============================================================================
# get_version_patch
# =============================================================================

@test "get_version_patch: 1.21.4 → 4" {
    run get_version_patch "1.21.4"
    [ "$output" = "4" ]
}

@test "get_version_patch: 1.21.0 → 0" {
    run get_version_patch "1.21.0"
    [ "$output" = "0" ]
}

@test "get_version_patch: 1.21 → 0 (no patch component)" {
    run get_version_patch "1.21"
    [ "$output" = "0" ]
}

@test "get_version_patch: 25.1.2 → 2 (year-based)" {
    run get_version_patch "25.1.2"
    [ "$output" = "2" ]
}

@test "get_version_patch: 25.1 → 0 (year-based, no patch)" {
    run get_version_patch "25.1"
    [ "$output" = "0" ]
}

# =============================================================================
# get_java_version_for_mc
# =============================================================================

@test "get_java_version_for_mc: 1.21.4 → 21" {
    run get_java_version_for_mc "1.21.4"
    [ "$output" = "21" ]
}

@test "get_java_version_for_mc: 1.21.0 → 21" {
    run get_java_version_for_mc "1.21.0"
    [ "$output" = "21" ]
}

@test "get_java_version_for_mc: 1.20.4 → 17" {
    run get_java_version_for_mc "1.20.4"
    [ "$output" = "17" ]
}

@test "get_java_version_for_mc: 1.18.2 → 17" {
    run get_java_version_for_mc "1.18.2"
    [ "$output" = "17" ]
}

@test "get_java_version_for_mc: 1.17.1 → 16" {
    run get_java_version_for_mc "1.17.1"
    [ "$output" = "16" ]
}

@test "get_java_version_for_mc: 1.16.5 → 8" {
    run get_java_version_for_mc "1.16.5"
    [ "$output" = "8" ]
}

@test "get_java_version_for_mc: 25.1 → 21 (year-based assumed modern)" {
    run get_java_version_for_mc "25.1"
    [ "$output" = "21" ]
}

# =============================================================================
# get_lwjgl_version_for_mc
# =============================================================================

@test "get_lwjgl_version_for_mc: 1.21.4 → 3.3.3" {
    run get_lwjgl_version_for_mc "1.21.4"
    [ "$output" = "3.3.3" ]
}

@test "get_lwjgl_version_for_mc: 1.20.4 → 3.3.1" {
    run get_lwjgl_version_for_mc "1.20.4"
    [ "$output" = "3.3.1" ]
}

@test "get_lwjgl_version_for_mc: 1.19.4 → 3.3.1" {
    run get_lwjgl_version_for_mc "1.19.4"
    [ "$output" = "3.3.1" ]
}

@test "get_lwjgl_version_for_mc: 1.18.2 → 3.2.2" {
    run get_lwjgl_version_for_mc "1.18.2"
    [ "$output" = "3.2.2" ]
}

@test "get_lwjgl_version_for_mc: 1.16.5 → 3.2.1" {
    run get_lwjgl_version_for_mc "1.16.5"
    [ "$output" = "3.2.1" ]
}

@test "get_lwjgl_version_for_mc: 1.14.4 → 3.1.6" {
    run get_lwjgl_version_for_mc "1.14.4"
    [ "$output" = "3.1.6" ]
}

@test "get_lwjgl_version_for_mc: 1.13.2 → 3.1.2" {
    run get_lwjgl_version_for_mc "1.13.2"
    [ "$output" = "3.1.2" ]
}

@test "get_lwjgl_version_for_mc: 25.1 → 3.3.3 (year-based assumed modern)" {
    run get_lwjgl_version_for_mc "25.1"
    [ "$output" = "3.3.3" ]
}
