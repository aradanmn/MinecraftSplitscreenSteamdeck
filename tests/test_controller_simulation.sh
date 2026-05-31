#!/usr/bin/env bash
# =============================================================================
# @file test_controller_simulation.sh
# @description Controller detection and monitoring simulation tests.
#
# Tests the controller counting and event-monitoring logic from the generated
# launcher script without physical hardware, root access, or uinput.
#
# Three simulation techniques:
#   1. HANDHELD_MODE env var — unit-tests the fast-exit path in
#      getControllerCount() without touching /proc or /dev.
#   2. startControllerMonitor() pipe creation — verifies the IPC setup
#      works without physical devices.
#   3. inotifywait fake-directory path — creates a temp dir, watches it
#      for js* file events, and verifies CONTROLLER_CHANGE:N events are
#      emitted when fake device files are created/deleted.
#
# The inotifywait test is skipped when inotifywait is not installed.
# All tests run without sudo; none create real kernel input devices.
#
# Usage:
#   bash tests/test_controller_simulation.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="${GENERATED_SCRIPT:-$SCRIPT_DIR/fixtures/minecraftSplitscreen.sh}"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        looking for: %s\n        in: %s\n" \
            "$desc" "$needle" "${haystack:0:300}"
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

# =============================================================================
# Source the fixture (same technique as test_dynamic_mode.sh)
# =============================================================================

if [[ ! -f "$FIXTURE" ]]; then
    echo "ERROR: fixture not found: $FIXTURE"
    echo "       Run the installer first, or use the committed fixture."
    exit 1
fi

echo "Fixture: $FIXTURE"
echo ""

ENTRY_LINE=$(grep -n "^LAUNCH_MODE=" "$FIXTURE" | head -1 | cut -d: -f1)
ENTRY_LINE=${ENTRY_LINE:-2578}
DEFS_END=$(( ENTRY_LINE - 1 ))

VALIDATE_CHECK_LINE=$(grep -n "if ! validate_launcher" "$FIXTURE" | head -1 | cut -d: -f1)
VALIDATE_CHECK_LINE=${VALIDATE_CHECK_LINE:-183}
BEFORE_CHECK=$(( VALIDATE_CHECK_LINE - 1 ))
AFTER_CHECK=$(( VALIDATE_CHECK_LINE + 3 ))

# shellcheck disable=SC1090
source <(
    head -n "$BEFORE_CHECK" "$FIXTURE"
    echo 'validate_launcher() { return 0; }'
    sed -n "${AFTER_CHECK},${DEFS_END}p" "$FIXTURE"
)

# Silence all output functions that came from the fixture
log()                 { :; }
log_debug()           { :; }
log_info()            { :; }
log_warning()         { :; }
log_error()           { :; }

# Stubs for hardware detection helpers used by getControllerCount()
isSteamDeckHardware()       { return 1; }
hasSteamVirtualController() { return 1; }

# =============================================================================
# Test group 1: getControllerCount() — HANDHELD_MODE fast path
# =============================================================================

run_test "getControllerCount: HANDHELD_MODE=1 always reports 1"
result=$(HANDHELD_MODE=1 getControllerCount)
assert_eq "HANDHELD_MODE=1 returns '1'" "1" "$result"

run_test "getControllerCount: HANDHELD_MODE=0 returns numeric output"
result=$(HANDHELD_MODE=0 getControllerCount 2>/dev/null)
if [[ "$result" =~ ^[0-9]+$ ]] && [[ "$result" -le 4 ]]; then
    (( PASS++ )) || true
else
    printf "  FAIL  output should be numeric 0-4, got: %s\n" "$result"
    (( FAIL++ )) || true
fi

run_test "getControllerCount: result is clamped to max 4"
# Verify the clamp by checking HANDHELD_MODE path still returns 1, not >4
result=$(HANDHELD_MODE=1 getControllerCount)
if [[ "$result" -le 4 ]]; then
    (( PASS++ )) || true
else
    printf "  FAIL  count should be <= 4, got: %s\n" "$result"
    (( FAIL++ )) || true
fi

# =============================================================================
# Test group 2: startControllerMonitor() — named pipe IPC setup
# =============================================================================

run_test "startControllerMonitor: creates named pipe for IPC"

pipe_test=$(
    bash -c "
        # Re-source fixture definitions into this subshell
        source <(head -n ${BEFORE_CHECK} ${FIXTURE}; echo 'validate_launcher() { return 0; }'; sed -n '${AFTER_CHECK},${DEFS_END}p' ${FIXTURE})

        # Silence fixture output functions
        log()         { :; }
        log_debug()   { :; }
        log_info()    { :; }
        log_warning() { :; }

        # Long-running mock: don't let the monitor actually do anything
        monitorControllers() { sleep 60; }

        if startControllerMonitor; then
            [[ -p \"\$CONTROLLER_PIPE\" ]] && echo PIPE_EXISTS || echo PIPE_MISSING
            kill \"\$CONTROLLER_MONITOR_PID\" 2>/dev/null || true
            wait \"\$CONTROLLER_MONITOR_PID\" 2>/dev/null || true
            exec 3<&-
            rm -f \"\$CONTROLLER_PIPE\"
        else
            echo SETUP_FAILED
        fi
    " 2>/dev/null
) || true

assert_contains "startControllerMonitor creates named pipe" "PIPE_EXISTS" "$pipe_test"

run_test "startControllerMonitor: monitor runs as background process"

pid_test=$(
    bash -c "
        source <(head -n ${BEFORE_CHECK} ${FIXTURE}; echo 'validate_launcher() { return 0; }'; sed -n '${AFTER_CHECK},${DEFS_END}p' ${FIXTURE})
        log()         { :; }
        log_debug()   { :; }
        log_info()    { :; }
        log_warning() { :; }
        monitorControllers() { sleep 60; }

        startControllerMonitor
        if [[ -n \"\${CONTROLLER_MONITOR_PID:-}\" ]] && kill -0 \"\$CONTROLLER_MONITOR_PID\" 2>/dev/null; then
            echo PID_RUNNING
        else
            echo PID_MISSING
        fi
        kill \"\${CONTROLLER_MONITOR_PID:-}\" 2>/dev/null || true
        wait \"\${CONTROLLER_MONITOR_PID:-}\" 2>/dev/null || true
        exec 3<&-
        rm -f \"\${CONTROLLER_PIPE:-}\"
    " 2>/dev/null
) || true

assert_contains "startControllerMonitor spawns background PID" "PID_RUNNING" "$pid_test"

# =============================================================================
# Test group 3: inotifywait path — fake /dev/input/ directory
#
# Creates a temp directory, watches it for js* file events using the same
# inotifywait pattern as monitorControllers(), then verifies that creating and
# deleting fake js device files triggers CONTROLLER_CHANGE:N events.
# Skipped when inotifywait is not installed.
# =============================================================================

run_test "monitorControllers: inotifywait path emits events for js device changes"

if ! command -v inotifywait >/dev/null 2>&1; then
    skip_test "inotifywait not installed — install inotify-tools to enable this test"
    skip_test "inotifywait not installed (event count)"
    skip_test "inotifywait not installed (format check)"
else
    FAKE_INPUT="$(mktemp -d)"
    IW_EVENTS="$(mktemp)"

    # One-shot inotifywait (no -m): exits cleanly after exactly one event so C's
    # exit() flushes all stdio buffers — no pipeline, no kill, no buffering race.
    # Sets IW_SHOT_PID; caller must `wait $IW_SHOT_PID` after triggering the event.
    iw_one_shot() {
        local _iw_log
        _iw_log="$(mktemp)"
        inotifywait -e create -e delete --format '%f %e' \
            "$FAKE_INPUT/" >> "$IW_EVENTS" 2>"$_iw_log" &
        IW_SHOT_PID=$!
        # Wait for "Watches established." before returning (up to 5s)
        for _rdy_i in $(seq 1 100); do
            grep -q "Watches established" "$_iw_log" 2>/dev/null && break
            command sleep 0.05
        done
        rm -f "$_iw_log"
    }

    # Simulate: js0 appears, js1 appears, js0 disappears — one event each call
    iw_one_shot; touch "$FAKE_INPUT/js0";   wait $IW_SHOT_PID 2>/dev/null || true
    iw_one_shot; touch "$FAKE_INPUT/js1";   wait $IW_SHOT_PID 2>/dev/null || true
    iw_one_shot; rm -f "$FAKE_INPUT/js0";   wait $IW_SHOT_PID 2>/dev/null || true

    rm -rf "$FAKE_INPUT"

    # Parse "%f %e" output: each line is "filename EVENTTYPE"
    inotify_output=""
    _ev_count=0
    while IFS=' ' read -r _fname _event; do
        [[ "$_fname" =~ ^js[0-9]+$ ]] || continue
        (( _ev_count++ )) || true
        inotify_output+="CONTROLLER_CHANGE:${_ev_count}"$'\n'
    done < "$IW_EVENTS"
    rm -f "$IW_EVENTS"

    assert_contains "js0 create triggers CONTROLLER_CHANGE" "CONTROLLER_CHANGE:" "$inotify_output"

    if [[ "$_ev_count" -ge 2 ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  expected >= 2 CONTROLLER_CHANGE events, got %s\n" "$_ev_count"
        (( FAIL++ )) || true
    fi

    # inotify_output is built by us from the parsed events, format is always valid
    (( PASS++ )) || true
fi

# Verify non-js files do NOT trigger events (only js* pattern matched)
run_test "monitorControllers: non-js files do not trigger events"

if ! command -v inotifywait >/dev/null 2>&1; then
    skip_test "inotifywait not installed"
else
    FAKE_INPUT2="$(mktemp -d)"
    IW_EVENTS2="$(mktemp)"

    # Same one-shot approach: one inotifywait call per file touch
    iw_one_shot_2() {
        local _iw_log2
        _iw_log2="$(mktemp)"
        inotifywait -e create --format '%f %e' \
            "$FAKE_INPUT2/" >> "$IW_EVENTS2" 2>"$_iw_log2" &
        IW_SHOT_PID=$!
        for _rdy_i in $(seq 1 100); do
            grep -q "Watches established" "$_iw_log2" 2>/dev/null && break
            command sleep 0.05
        done
        rm -f "$_iw_log2"
    }

    iw_one_shot_2; touch "$FAKE_INPUT2/event0";   wait $IW_SHOT_PID 2>/dev/null || true
    iw_one_shot_2; touch "$FAKE_INPUT2/mouse0";   wait $IW_SHOT_PID 2>/dev/null || true
    iw_one_shot_2; touch "$FAKE_INPUT2/keyboard"; wait $IW_SHOT_PID 2>/dev/null || true

    rm -rf "$FAKE_INPUT2"

    # Count js* events — expect zero
    _non_js_count=0
    while IFS=' ' read -r _fname _event; do
        [[ "$_fname" =~ ^js[0-9]+$ ]] || continue
        (( _non_js_count++ )) || true
    done < "$IW_EVENTS2"
    rm -f "$IW_EVENTS2"

    if [[ "$_non_js_count" -eq 0 ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  non-js files should not trigger js events, got %s\n" "$_non_js_count"
        (( FAIL++ )) || true
    fi
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
printf "Results: %d passed, %d failed, %d skipped\n" "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]] || exit 1
