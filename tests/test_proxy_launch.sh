#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: proxy launch wiring  (#38 M2 / PR-b)
# =============================================================================
# Covers instance_lifecycle's _maybe_proxy_swap (physical→virtual bind swap
# behind MCSS_CONTROLLER_PROXY) and _vp_of_js_node (device-id derivation).
# proxy_start_slot / proxy_virtual_nodes are stubbed per-test — no evsieve, no
# uinput, no hardware. Run: bash tests/test_proxy_launch.sh
# =============================================================================

readonly TEST_TOTAL=7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pre-lock runtime_context's constants so MCSS_CONTROLLER_PROXY stays a normal
# (settable) variable — this suite flips it per-test. (Same load-guard hook the
# module documents.) Because the guarded block is skipped, provide the constants
# the sourced modules read at source time themselves.
export _MCSS_CONSTANTS_LOCKED=1
export MCSS_MAX_PLAYERS=4
export MCSS_STEAM_VENDOR_ID=28de MCSS_STEAM_PRODUCT_ID=11ff
export MCSS_RAW_BINDING=1 MCSS_INSTANCE_PREFIX=latestUpdate- MCSS_ACCOUNT_PREFIX=Player
export MCSS_WINDOW_TITLE_PREFIX=SplitscreenP MCSS_STATE_LOCK_TIMEOUT_S=5

# parse_input_device_blocks lives in controller_monitor; the swap/vp helpers in
# instance_lifecycle.
# shellcheck source=/dev/null
source "$REPO_ROOT/modules/controller_monitor.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/modules/instance_lifecycle.sh"

TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "[PASS] $name — got \"$actual\""
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "[FAIL] $name — expected \"$expected\", got \"$actual\""
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Default stubs (individual tests override as needed).
proxy_start_slot()   { return 0; }
proxy_virtual_nodes() { echo "/dev/input/event20 /dev/input/js2"; return 0; }

# --- _maybe_proxy_swap ---

test_swap_flag_off_is_noop() {
    export MCSS_CONTROLLER_PROXY=0
    assert_equals \
        "$(_maybe_proxy_swap 1 /dev/input/event5 /dev/input/js0 2>/dev/null)" \
        "/dev/input/event5 /dev/input/js0" \
        "flag off → bind physical unchanged (behavior-neutral)"
}

test_swap_handheld_no_js_is_noop() {
    export MCSS_CONTROLLER_PROXY=1
    assert_equals \
        "$(_maybe_proxy_swap 1 /dev/input/event5 '' 2>/dev/null)" \
        "/dev/input/event5 " \
        "flag on but no js (handheld) → no swap"
}

test_swap_on_success_binds_virtual() {
    export MCSS_CONTROLLER_PROXY=1
    proxy_start_slot()   { return 0; }
    proxy_virtual_nodes() { echo "/dev/input/event20 /dev/input/js2"; return 0; }
    assert_equals \
        "$(_maybe_proxy_swap 1 /dev/input/event5 /dev/input/js0 2>/dev/null)" \
        "/dev/input/event20 /dev/input/js2" \
        "flag on + proxy up → bind the virtual nodes"
}

test_swap_start_failure_falls_back() {
    export MCSS_CONTROLLER_PROXY=1
    proxy_start_slot() { return 1; }    # evsieve missing / never came up
    assert_equals \
        "$(_maybe_proxy_swap 1 /dev/input/event5 /dev/input/js0 2>/dev/null)" \
        "/dev/input/event5 /dev/input/js0" \
        "proxy_start_slot fails → fall back to raw pad bind"
    proxy_start_slot() { return 0; }    # restore default for later tests
}

test_swap_virtual_absent_falls_back() {
    export MCSS_CONTROLLER_PROXY=1
    proxy_start_slot()   { return 0; }
    proxy_virtual_nodes() { return 1; } # virtual node never resolved
    assert_equals \
        "$(_maybe_proxy_swap 1 /dev/input/event5 /dev/input/js0 2>/dev/null)" \
        "/dev/input/event5 /dev/input/js0" \
        "virtual node not live → fall back to raw pad bind"
    proxy_virtual_nodes() { echo "/dev/input/event20 /dev/input/js2"; return 0; }
}

# --- _vp_of_js_node ---

test_vp_derives_vendor_product() {
    local d; d=$(mktemp -d)
    printf '%s\n' \
        'I: Bus=0005 Vendor=054c Product=09cc Version=8100' \
        'N: Name="Wireless Controller"' \
        'P: Phys=' \
        'S: Sysfs=/devices/virtual/misc/uhid/0005:054C:09CC.000B/input/input78' \
        'U: Uniq=dc:0c:2d:bb:33:0a' \
        'H: Handlers=event17 js0 ' \
        'B: EV=20000b' \
        '' > "$d/devices"
    assert_equals "$(PROC_INPUT_DEVICES="$d/devices" _vp_of_js_node /dev/input/js0)" \
        "054c 09cc" "vp_of_js_node derives vendor+product for the owning block"
    rm -rf "$d"
}

test_vp_no_match_is_empty() {
    local d; d=$(mktemp -d)
    printf '%s\n' \
        'I: Bus=0005 Vendor=054c Product=09cc Version=8100' \
        'N: Name="Wireless Controller"' \
        'H: Handlers=event17 js0 ' \
        'B: EV=20000b' \
        '' > "$d/devices"
    # js9 is not present → no match → empty
    assert_equals "$(PROC_INPUT_DEVICES="$d/devices" _vp_of_js_node /dev/input/js9)" \
        "" "vp_of_js_node no matching block → empty"
    rm -rf "$d"
}

run_all_tests() {
    echo "=== proxy launch (PR-b) test suite ==="
    echo ""
    test_swap_flag_off_is_noop
    test_swap_handheld_no_js_is_noop
    test_swap_on_success_binds_virtual
    test_swap_start_failure_falls_back
    test_swap_virtual_absent_falls_back
    test_vp_derives_vendor_product
    test_vp_no_match_is_empty
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
