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
readonly TEST_TOTAL=11

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

    # Start watch_display_mode in background. Redirected off the CI capture
    # pipe for the same reason as T1.11 — see the comment there.
    SPLITSCREEN_FIFO="$fifo" DOCK_DETECTION_DRM_PATH="$drm_dir" \
        watch_display_mode >/dev/null 2>&1 &
    local watcher_pid=$!

    # Give the watcher a moment to start
    sleep 0.5

    local test_failed=0

    # Change HDMI to connected (simulate dock event)
    echo "connected" > "$drm_dir/card0-HDMI-A-1/status"

    # Read from FIFO with timeout
    local line1
    if read -r -t 15 line1 < "$fifo"; then
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
        if read -r -t 15 line2 < "$fifo"; then
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

# --- #133 debounce helpers -------------------------------------------------
# The watcher's timing is owned by module constants we cannot override
# (DOCK_DETECTION_POLL_INTERVAL_S is readonly by the time this suite has
# sourced the module), so T1.11 drives the loop through two seams instead of
# the wall clock: a scripted get_display_mode and a fast `sleep`. That keeps
# the debounce assertions deterministic rather than racing a 3s poll.

# _install_mode_mock <seq-file>: replace get_display_mode with one that pops a
# mode per call from <seq-file>, repeating the last line once exhausted.
# Both the mock and MCSS_TEST_MODE_SEQ must exist before the watcher is
# backgrounded — a `&` subshell inherits functions and variables, and the
# seq-file is a real file so the watcher's own pops persist back to us.
_install_mode_mock() {
    MCSS_TEST_MODE_SEQ="$1"
    get_display_mode() {
        local first rest
        first=$(head -n 1 "$MCSS_TEST_MODE_SEQ")
        rest=$(tail -n +2 "$MCSS_TEST_MODE_SEQ")
        [[ -n "$rest" ]] && printf '%s\n' "$rest" > "$MCSS_TEST_MODE_SEQ"
        printf '%s\n' "$first"
    }
    # Collapse the watcher's poll interval and the confirm spacing so the loop
    # runs at test speed. Not a no-op: once the sequence is exhausted the
    # watcher loops forever with nothing to report, and a zero-delay loop would
    # peg a core forking head/tail until the test kills it.
    sleep() { command sleep 0.05; }
}

_uninstall_mode_mock() {
    unset -f get_display_mode sleep
    unset MCSS_TEST_MODE_SEQ
    # Restore the real implementation for any later test.
    source "$REPO_ROOT/modules/dock_detection.sh"
}

# --- Test T1.9: #133 — a candidate that reverts is REJECTED ---
test_t1_9() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    # eDP only → get_display_mode reads "handheld" for real.
    local drm_dir="$tmpdir/sys/class/drm"
    mkdir -p "$drm_dir/card0-eDP-1"
    echo "connected" > "$drm_dir/card0-eDP-1/status"

    # Claim "docked" as the candidate while sysfs says handheld — exactly the
    # HW-2 shape: one spurious read that the next read contradicts.
    local rc=0
    set +e
    DOCK_DETECTION_DRM_PATH="$drm_dir" \
    DOCK_DETECTION_CONFIRM_SAMPLES=3 DOCK_DETECTION_CONFIRM_INTERVAL_S=0.05 \
        _confirm_display_mode "docked" 2>/dev/null
    rc=$?
    set -e

    assert_exit_code 1 "$rc" "T1.9 — #133 transient candidate rejected"
}

# --- Test T1.10: #133 — a candidate that holds is CONFIRMED (and SAMPLES=1
#     degrades to the pre-#133 emit-on-first-read) ---
test_t1_10() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    local drm_dir="$tmpdir/sys/class/drm"
    mkdir -p "$drm_dir/card0-HDMI-A-1"
    echo "connected" > "$drm_dir/card0-HDMI-A-1/status"

    local test_failed=0 rc=0

    # A real dock: sysfs agrees on every sample.
    set +e
    DOCK_DETECTION_DRM_PATH="$drm_dir" \
    DOCK_DETECTION_CONFIRM_SAMPLES=3 DOCK_DETECTION_CONFIRM_INTERVAL_S=0.05 \
        _confirm_display_mode "docked" 2>/dev/null
    rc=$?
    set -e
    if (( rc != 0 )); then
        echo "[FAIL] T1.10a — sustained candidate should confirm, got exit $rc"
        test_failed=1
    fi

    # SAMPLES=1 takes no extra reads at all: it must confirm even when the
    # live mode disagrees (the escape hatch back to pre-#133 behavior).
    set +e
    DOCK_DETECTION_DRM_PATH="$drm_dir" \
    DOCK_DETECTION_CONFIRM_SAMPLES=1 \
        _confirm_display_mode "handheld" 2>/dev/null
    rc=$?
    set -e
    if (( rc != 0 )); then
        echo "[FAIL] T1.10b — SAMPLES=1 should confirm without re-reading, got exit $rc"
        test_failed=1
    fi

    # A garbage override must clamp, not kill the watcher.
    set +e
    DOCK_DETECTION_DRM_PATH="$drm_dir" \
    DOCK_DETECTION_CONFIRM_SAMPLES="banana" \
        _confirm_display_mode "handheld" 2>/dev/null
    rc=$?
    set -e
    if (( rc != 0 )); then
        echo "[FAIL] T1.10c — non-numeric SAMPLES should clamp to 1, got exit $rc"
        test_failed=1
    fi

    if (( test_failed == 0 )); then
        echo "[PASS] T1.10 — #133 sustained candidate confirmed; overrides clamp safely"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# --- Test T1.11: #133 — watch_display_mode swallows a blip, then emits on a
#     sustained change (the HW-2 regression, end to end) ---
test_t1_11() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    mkfifo "$fifo"

    local seq="$tmpdir/modes.seq"
    # The HW-2 shape: a LIVE DOCKED session sees one spurious handheld read.
    # 1  initial read      → docked    (current_mode — the live docked session)
    # 2  poll read         → handheld  (candidate — THE BLIP)
    # 3  confirm sample 2  → docked    (blip reverted → REJECT, no emit)
    # 4  poll read         → docked    (steady; nothing to report)
    # 5  poll read         → handheld  (candidate — the real undock)
    # 6+ everything after  → handheld  (last line repeats forever → confirmed)
    #
    # Both the blip and the real change are "handheld", so asserting on the
    # first message's CONTENT cannot tell them apart — a no-debounce build
    # emits handheld first either way. What separates the two is what follows:
    # un-debounced, the blip's revert emits a SECOND message (docked). So the
    # gate is "exactly one message, and it is handheld". Verified by mutation:
    # replacing the confirm call with `true` makes this test fail.
    printf '%s\n' docked handheld docked docked handheld handheld > "$seq"

    # Point the watcher at a path that is not a directory so it takes the poll
    # branch regardless of whether inotifywait exists on this machine.
    local fake_drm="$tmpdir/no-such-drm"

    # Hold the FIFO open read-write for the whole test. `read -t` bounds the
    # READ, not the OPEN — and opening a FIFO read-only blocks until a writer
    # shows up, so the "no second message" assertion below would hang forever
    # on a correct build. An O_RDWR fd never blocks on open.
    exec 3<>"$fifo"

    _install_mode_mock "$seq"
    # `>/dev/null 2>&1` is not cosmetic: CI runs `out=$(bash "$suite" 2>&1)`,
    # and a command substitution blocks until EVERY process holding the stdout
    # pipe exits. A backgrounded watcher — or a get_display_mode grandchild it
    # spawned — that outlives the kill below would hang the whole CI job (the
    # #80/#103 failure mode). Keep every backgrounded subshell off that pipe.
    SPLITSCREEN_FIFO="$fifo" DOCK_DETECTION_DRM_PATH="$fake_drm" \
    DOCK_DETECTION_CONFIRM_SAMPLES=2 DOCK_DETECTION_CONFIRM_INTERVAL_S=0 \
        watch_display_mode >/dev/null 2>&1 &
    local watcher_pid=$!

    local test_failed=0 line="" extra=""

    # Half 1 — the watcher still works: the real undock must arrive.
    if read -r -t 10 line <&3; then
        if [[ "$line" != "DISPLAY_MODE_CHANGE handheld" ]]; then
            echo "[FAIL] T1.11 — expected 'DISPLAY_MODE_CHANGE handheld', got '$line'"
            test_failed=1
        fi
    else
        echo "[FAIL] T1.11 — timed out; the sustained change never emitted"
        test_failed=1
    fi

    # Half 2 — the blip was swallowed: nothing else may ever reach the FIFO.
    # A no-debounce build emits the blip's revert (docked) here.
    if read -r -t 3 extra <&3; then
        echo "[FAIL] T1.11 — extra message '$extra'; the blip was not debounced"
        test_failed=1
    fi

    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
    exec 3<&-
    rm -f "$fifo"
    _uninstall_mode_mock

    if (( test_failed == 0 )); then
        echo "[PASS] T1.11 — #133 blip swallowed, sustained change still emitted"
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
    test_t1_9
    test_t1_10
    test_t1_11
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
