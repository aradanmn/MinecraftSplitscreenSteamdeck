#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: dock_detection.sh
# =============================================================================
# All tests use mocked /sys/class/drm trees. No hardware required.
# Run: bash tests/test_dock_detection.sh
# =============================================================================

readonly TEST_PASSED=0
readonly TEST_FAILED=1
readonly TEST_TOTAL=8

# Find the repo root (parent of the tests/ directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the module under test
source "$REPO_ROOT/modules/dock_detection.sh"

# --- Test state ---
TESTS_PASSED=0
TESTS_FAILED=0

# --- Helpers ---

assert_equals() {
    local actual="$1"
    local expected="$2"
    local test_name="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo "[PASS] $test_name — got \"$actual\""
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "[FAIL] $test_name — expected \"$expected\", got \"$actual\""
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_exit_code() {
    local expected_code="$1"
    local actual_code="$2"
    local test_name="$3"

    if (( actual_code == expected_code )); then
        echo "[PASS] $test_name — exit code $actual_code"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "[FAIL] $test_name — expected exit code $expected_code, got $actual_code"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# --- Test T1.1: env override handheld ---
test_t1_1() {
    local result
    result=$(SPLITSCREEN_MODE=handheld get_display_mode 2>/dev/null)
    assert_equals "$result" "handheld" "T1.1 — env override handheld"
}

# --- Test T1.2: env override docked ---
test_t1_2() {
    local result
    result=$(SPLITSCREEN_MODE=docked get_display_mode 2>/dev/null)
    assert_equals "$result" "docked" "T1.2 — env override docked"
}

# --- Test T1.3: DRM sysfs: only eDP connected → handheld ---
test_t1_3() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    local drm_dir="$tmpdir/sys/class/drm/card0-eDP-1"
    mkdir -p "$drm_dir"
    echo "connected" > "$drm_dir/status"

    # Also create a disconnected HDMI
    local hdmi_dir="$tmpdir/sys/class/drm/card0-HDMI-A-1"
    mkdir -p "$hdmi_dir"
    echo "disconnected" > "$hdmi_dir/status"

    local result
    result=$(DOCK_DETECTION_DRM_PATH="$tmpdir/sys/class/drm" get_display_mode 2>/dev/null)
    assert_equals "$result" "handheld" "T1.3 — only eDP connected → handheld"
}

# --- Test T1.4: DRM sysfs: HDMI connected → docked ---
test_t1_4() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    local edp_dir="$tmpdir/sys/class/drm/card0-eDP-1"
    mkdir -p "$edp_dir"
    echo "connected" > "$edp_dir/status"

    local hdmi_dir="$tmpdir/sys/class/drm/card0-HDMI-A-1"
    mkdir -p "$hdmi_dir"
    echo "connected" > "$hdmi_dir/status"

    local result
    result=$(DOCK_DETECTION_DRM_PATH="$tmpdir/sys/class/drm" get_display_mode 2>/dev/null)
    assert_equals "$result" "docked" "T1.4 — HDMI connected → docked"
}

# --- Test T1.5: DRM sysfs: no files → handheld ---
test_t1_5() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    # Empty DRM dir — no connectors at all
    local drm_dir="$tmpdir/sys/class/drm"
    mkdir -p "$drm_dir"

    local result
    result=$(DOCK_DETECTION_DRM_PATH="$tmpdir/sys/class/drm" get_display_mode 2>/dev/null)
    assert_equals "$result" "handheld" "T1.5 — no DRM files → handheld"
}

# --- Test T1.6: DRM sysfs: only HDMI connected (no eDP) → docked ---
test_t1_6() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    local hdmi_dir="$tmpdir/sys/class/drm/card0-HDMI-A-1"
    mkdir -p "$hdmi_dir"
    echo "connected" > "$hdmi_dir/status"

    local result
    result=$(DOCK_DETECTION_DRM_PATH="$tmpdir/sys/class/drm" get_display_mode 2>/dev/null)
    assert_equals "$result" "docked" "T1.6 — only HDMI connected (no eDP) → docked"
}

# --- Test T1.7: is_handheld() and is_docked() return correct exit codes ---
test_t1_7() {
    local exit_code
    local test_failed=0

    # T1.7a
    set +e
    SPLITSCREEN_MODE=handheld is_handheld 2>/dev/null
    exit_code=$?
    set -e
    if (( exit_code != 0 )); then
        echo "[FAIL] T1.7a — is_handheld in handheld mode: expected exit 0, got $exit_code"
        test_failed=1
    fi

    # T1.7b
    set +e
    SPLITSCREEN_MODE=handheld is_docked 2>/dev/null
    exit_code=$?
    set -e
    if (( exit_code != 1 )); then
        echo "[FAIL] T1.7b — is_docked in handheld mode: expected exit 1, got $exit_code"
        test_failed=1
    fi

    # T1.7c
    set +e
    SPLITSCREEN_MODE=docked is_docked 2>/dev/null
    exit_code=$?
    set -e
    if (( exit_code != 0 )); then
        echo "[FAIL] T1.7c — is_docked in docked mode: expected exit 0, got $exit_code"
        test_failed=1
    fi

    # T1.7d
    set +e
    SPLITSCREEN_MODE=docked is_handheld 2>/dev/null
    exit_code=$?
    set -e
    if (( exit_code != 1 )); then
        echo "[FAIL] T1.7d — is_handheld in docked mode: expected exit 1, got $exit_code"
        test_failed=1
    fi

    if (( test_failed == 0 )); then
        echo "[PASS] T1.7 — is_handheld/is_docked exit codes correct"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "[FAIL] T1.7 — one or more exit code checks failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# --- Test T1.8: watch_display_mode() emits on change ---
test_t1_8() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    local drm_dir="$tmpdir/sys/class/drm"
    mkdir -p "$drm_dir/card0-eDP-1"
    echo "connected" > "$drm_dir/card0-eDP-1/status"

    # Create a disconnected HDMI initially
    mkdir -p "$drm_dir/card0-HDMI-A-1"
    echo "disconnected" > "$drm_dir/card0-HDMI-A-1/status"

    local fifo="$tmpdir/splitscreen.fifo"
    mkfifo "$fifo"

    # Start watch_display_mode in background
    SPLITSCREEN_FIFO="$fifo" DOCK_DETECTION_DRM_PATH="$drm_dir" watch_display_mode &
    local watcher_pid=$!

    # Give the watcher a moment to start
    sleep 0.5

    local test_failed=0

    # Change HDMI to connected (simulate dock event)
    echo "connected" > "$drm_dir/card0-HDMI-A-1/status"

    # Read from FIFO with timeout
    local line1
    if read -r -t 5 line1 < "$fifo"; then
        if [[ "$line1" != "DISPLAY_MODE_CHANGE docked" ]]; then
            echo "[FAIL] T1.8 — expected 'DISPLAY_MODE_CHANGE docked', got '$line1'"
            test_failed=1
        fi
    else
        echo "[FAIL] T1.8 — timed out waiting for DISPLAY_MODE_CHANGE docked"
        test_failed=1
    fi

    if (( test_failed == 0 )); then
        # Change HDMI back to disconnected
        echo "disconnected" > "$drm_dir/card0-HDMI-A-1/status"

        local line2
        if read -r -t 5 line2 < "$fifo"; then
            if [[ "$line2" != "DISPLAY_MODE_CHANGE handheld" ]]; then
                echo "[FAIL] T1.8 — expected 'DISPLAY_MODE_CHANGE handheld', got '$line2'"
                test_failed=1
            fi
        else
            echo "[FAIL] T1.8 — timed out waiting for DISPLAY_MODE_CHANGE handheld"
            test_failed=1
        fi
    fi

    # Kill the watcher
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
    rm -f "$fifo"

    if (( test_failed == 0 )); then
        echo "[PASS] T1.8 — watch_display_mode emits correct DISPLAY_MODE_CHANGE messages"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# --- Run all tests ---
run_all_tests() {
    echo "=== dock_detection test suite ==="
    echo ""
    test_t1_1
    test_t1_2
    test_t1_3
    test_t1_4
    test_t1_5
    test_t1_6
    test_t1_7
    test_t1_8
    echo ""

    local total=$((TESTS_PASSED + TESTS_FAILED))
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
