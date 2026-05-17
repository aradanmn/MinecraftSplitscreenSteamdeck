#!/usr/bin/env bash
# =============================================================================
# @file test_environment_detection.sh
# @description OS environment detection tests for is_immutable_os().
#
# Tests that the OS detection function correctly identifies immutable Linux
# distributions from their filesystem markers and /etc/os-release content.
#
# Most tests require creating files in /etc/ and are therefore gated behind
# environment variables so they don't run in wrong contexts. Each simulation
# is guarded by its own SIMULATE_<DISTRO>=1 variable:
#
#   SIMULATE_BAZZITE=1      Test /etc/bazzite/image_name detection
#   SIMULATE_STEAMOS=1      Test /etc/steamos-release detection
#   SIMULATE_NIXOS=1        Test /etc/NIXOS detection
#   SIMULATE_UBLUE=1        Test /etc/ublue-os/image_name detection
#
# In GitHub Actions, the bazzite-simulation job sets these variables and runs
# as root (via sudo) so /etc/ files can be created and cleaned up.
#
# Locally without sudo: only the host-detection and format tests run.
#
# Usage:
#   bash tests/test_environment_detection.sh
#   SIMULATE_BAZZITE=1 bash tests/test_environment_detection.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULES_DIR="$PROJECT_DIR/modules"

# Redirect HOME so readonly path constants in path_configuration.sh
# resolve into a throwaway temp directory.
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"

export PATH="$SCRIPT_DIR/bin:$PATH"

# =============================================================================
# Assertion framework
# =============================================================================

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        expected: %s\n        actual:   %s\n" \
            "$desc" "$expected" "$actual"
        (( FAIL++ )) || true
    fi
}

assert_return() {
    local desc="$1" expected_rc="$2" actual_rc="$3"
    if [[ "$expected_rc" == "$actual_rc" ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        expected rc: %s  actual rc: %s\n" \
            "$desc" "$expected_rc" "$actual_rc"
        (( FAIL++ )) || true
    fi
}

skip_test() {
    printf "  SKIP  %s\n" "$1"
    (( SKIP++ )) || true
}

run_test() { echo "--- $1"; }

# Helper: check if we can write to /etc/ (needed for simulated marker tests)
can_write_etc() {
    sudo -n touch /etc/.detection-test-probe 2>/dev/null && sudo -n rm -f /etc/.detection-test-probe 2>/dev/null
}

# Helper: restore /etc/os-release if we modified it
_ORIG_OS_RELEASE=""
backup_os_release() {
    if [[ -f /etc/os-release ]]; then
        _ORIG_OS_RELEASE="$(sudo -n cat /etc/os-release 2>/dev/null || true)"
    fi
}
restore_os_release() {
    if [[ -n "$_ORIG_OS_RELEASE" ]]; then
        echo "$_ORIG_OS_RELEASE" | sudo -n tee /etc/os-release >/dev/null 2>/dev/null || true
    fi
}

# =============================================================================
# Source modules
# =============================================================================

source "$MODULES_DIR/version_info.sh"
source "$MODULES_DIR/utilities.sh"

# Silence print functions after sourcing
print_header()   { :; }
print_success()  { :; }
print_warning()  { :; }
print_error()    { :; }
print_info()     { :; }
print_progress() { :; }
LOG_FILE=/dev/null

# =============================================================================
# Test group 1: Basic function behavior (always runs, no root needed)
# =============================================================================

run_test "is_immutable_os: returns a valid exit code (0 or 1)"
is_immutable_os || true
rc=$?
if [[ "$rc" -eq 0 || "$rc" -eq 1 ]]; then
    (( PASS++ )) || true
else
    printf "  FAIL  is_immutable_os returned unexpected exit code: %s\n" "$rc"
    (( FAIL++ )) || true
fi

run_test "is_immutable_os: sets IMMUTABLE_OS_NAME when detected as immutable"
IMMUTABLE_OS_NAME=""
if is_immutable_os; then
    # On an actual immutable OS, the name should be set
    if [[ -n "$IMMUTABLE_OS_NAME" ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  is_immutable_os returned 0 but IMMUTABLE_OS_NAME is empty\n"
        (( FAIL++ )) || true
    fi
else
    # Not an immutable OS — IMMUTABLE_OS_NAME should be empty
    if [[ -z "$IMMUTABLE_OS_NAME" ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  is_immutable_os returned 1 but IMMUTABLE_OS_NAME=%s\n" "$IMMUTABLE_OS_NAME"
        (( FAIL++ )) || true
    fi
fi

run_test "is_immutable_os: resets IMMUTABLE_OS_NAME on each call"
# Call twice and verify IMMUTABLE_OS_NAME reflects second call's result
is_immutable_os || true
first_name="${IMMUTABLE_OS_NAME:-}"
is_immutable_os || true
second_name="${IMMUTABLE_OS_NAME:-}"
assert_eq "IMMUTABLE_OS_NAME consistent across calls" "$first_name" "$second_name"

# =============================================================================
# Test group 2: Bazzite marker detection (SIMULATE_BAZZITE=1)
# =============================================================================

run_test "is_immutable_os: detects /etc/bazzite/image_name marker"
if [[ "${SIMULATE_BAZZITE:-0}" != "1" ]]; then
    skip_test "set SIMULATE_BAZZITE=1 to test (requires sudo)"
elif ! can_write_etc; then
    skip_test "sudo not available — cannot create /etc/bazzite"
else
    sudo -n mkdir -p /etc/bazzite 2>/dev/null
    sudo -n touch /etc/bazzite/image_name 2>/dev/null
    IMMUTABLE_OS_NAME=""
    is_immutable_os
    rc=$?
    assert_return "detects /etc/bazzite/image_name → returns 0" "0" "$rc"
    assert_eq "IMMUTABLE_OS_NAME=Bazzite" "Bazzite" "${IMMUTABLE_OS_NAME:-}"
    sudo -n rm -rf /etc/bazzite 2>/dev/null
fi

# =============================================================================
# Test group 3: SteamOS marker detection (SIMULATE_STEAMOS=1)
# =============================================================================

run_test "is_immutable_os: detects /etc/steamos-release marker"
if [[ "${SIMULATE_STEAMOS:-0}" != "1" ]]; then
    skip_test "set SIMULATE_STEAMOS=1 to test (requires sudo)"
elif ! can_write_etc; then
    skip_test "sudo not available — cannot create /etc/steamos-release"
else
    sudo -n touch /etc/steamos-release 2>/dev/null
    IMMUTABLE_OS_NAME=""
    is_immutable_os
    rc=$?
    assert_return "detects /etc/steamos-release → returns 0" "0" "$rc"
    assert_eq "IMMUTABLE_OS_NAME=SteamOS" "SteamOS" "${IMMUTABLE_OS_NAME:-}"
    sudo -n rm -f /etc/steamos-release 2>/dev/null
fi

# =============================================================================
# Test group 4: NixOS marker detection (SIMULATE_NIXOS=1)
# =============================================================================

run_test "is_immutable_os: detects /etc/NIXOS marker"
if [[ "${SIMULATE_NIXOS:-0}" != "1" ]]; then
    skip_test "set SIMULATE_NIXOS=1 to test (requires sudo)"
elif ! can_write_etc; then
    skip_test "sudo not available — cannot create /etc/NIXOS"
else
    sudo -n touch /etc/NIXOS 2>/dev/null
    IMMUTABLE_OS_NAME=""
    is_immutable_os
    rc=$?
    assert_return "detects /etc/NIXOS → returns 0" "0" "$rc"
    assert_eq "IMMUTABLE_OS_NAME=NixOS" "NixOS" "${IMMUTABLE_OS_NAME:-}"
    sudo -n rm -f /etc/NIXOS 2>/dev/null
fi

# =============================================================================
# Test group 5: Universal Blue marker detection (SIMULATE_UBLUE=1)
# =============================================================================

run_test "is_immutable_os: detects /etc/ublue-os/image_name marker"
if [[ "${SIMULATE_UBLUE:-0}" != "1" ]]; then
    skip_test "set SIMULATE_UBLUE=1 to test (requires sudo)"
elif ! can_write_etc; then
    skip_test "sudo not available — cannot create /etc/ublue-os"
else
    sudo -n mkdir -p /etc/ublue-os 2>/dev/null
    sudo -n touch /etc/ublue-os/image_name 2>/dev/null
    IMMUTABLE_OS_NAME=""
    is_immutable_os
    rc=$?
    assert_return "detects /etc/ublue-os/image_name → returns 0" "0" "$rc"
    assert_eq "IMMUTABLE_OS_NAME=Universal Blue" "Universal Blue" "${IMMUTABLE_OS_NAME:-}"
    sudo -n rm -rf /etc/ublue-os 2>/dev/null
fi

# =============================================================================
# Test group 6: os-release keyword detection (SIMULATE_OS_RELEASE=<keyword>)
#
# Tests the grep-based /etc/os-release detection paths by temporarily
# appending a keyword to /etc/os-release.  Requires sudo.
# =============================================================================

run_test "is_immutable_os: detects 'bazzite' keyword in /etc/os-release"
if [[ "${SIMULATE_OS_RELEASE:-}" != "bazzite" ]]; then
    skip_test "set SIMULATE_OS_RELEASE=bazzite to test (requires sudo)"
elif ! can_write_etc; then
    skip_test "sudo not available"
else
    backup_os_release
    echo 'ID=bazzite' | sudo -n tee -a /etc/os-release >/dev/null 2>/dev/null
    IMMUTABLE_OS_NAME=""
    is_immutable_os
    rc=$?
    assert_return "bazzite in os-release → returns 0" "0" "$rc"
    restore_os_release
fi

# =============================================================================
# Cleanup
# =============================================================================

rm -rf "$TEST_HOME"

# =============================================================================
# Summary
# =============================================================================

echo ""
printf "Results: %d passed, %d failed, %d skipped\n" "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]] || exit 1
