#!/usr/bin/env bash
# =============================================================================
# @file test_dynamic_session.sh
# @description Full dynamic-mode session simulation.
#
# Runs runDynamicSplitscreen() end-to-end by:
#   1. Pre-writing controller events to a temp file opened on fd 3
#      (the same fd the event loop reads with `read -t 1 -u 3 event`)
#   2. Mocking launchGame() to start a real `command sleep N` process so
#      INSTANCE_PIDS hold trackable PIDs and isInstanceRunning() works
#   3. No-opping all display/window calls and all sleep() delays
#
# The real code paths exercised:
#   - startControllerMonitor() IPC setup
#   - Initial-controller-count branch (join immediately vs wait for events)
#   - handleControllerChange() scale-up logic
#   - checkForExitedInstances() + markInstanceStopped() lifecycle
#   - Session exit condition: CURRENT_PLAYER_COUNT == 0 && instances_ever_launched
#   - stopControllerMonitor() cleanup
#
# Each scenario runs runDynamicSplitscreen() directly in the main shell so
# all INSTANCE_* globals are visible after the function returns.
# A 10-second watchdog kills the process if a scenario hangs.
#
# Usage:
#   bash tests/test_dynamic_session.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="${GENERATED_SCRIPT:-$SCRIPT_DIR/fixtures/minecraftSplitscreen.sh}"

# =============================================================================
# Assertion framework
# =============================================================================

PASS=0
FAIL=0

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

run_test() { echo "--- $1"; }

# =============================================================================
# Source fixture (same technique as test_dynamic_mode.sh)
# =============================================================================

if [[ ! -f "$FIXTURE" ]]; then
    echo "ERROR: fixture not found: $FIXTURE"
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

# =============================================================================
# Persistent mocks (apply once, survive all scenarios)
# =============================================================================

# Silence all output from the fixture
log()          { :; }
log_debug()    { :; }
log_info()     { :; }
log_warning()  { :; }
log_error()    { :; }

# Eliminate all sleep() delays so the event loop spins fast.
# Use `command sleep N` explicitly when a REAL wait is needed (launchGame).
sleep() { :; }

# Hardware and display stubs
inhibitScreen()            { :; }
uninhibitScreen()          { :; }
hidePanels()               { :; }
restorePanels()            { :; }
showNotification()         { :; }
canUseKWinScripting()      { return 1; }
installBorderEnforcer()    { :; }
enforceMemorySettings()    { :; }

# Window management stubs
repositionAllWindows()     { :; }
updatePlaceholderWindow()  { :; }
hidePlaceholderWindow()    { :; }

# SDL / controller assignment stubs
initSdlWrappers()            { :; }
writeInstanceSdlEnv()        { :; }
clearInstanceSdlEnv()        { :; }
setControllableAutoSelect()  { :; }
assignControllerToSlot()     { :; }
setSplitscreenModeForPlayer(){ :; }

# isInstanceRunning: check real PID only (skip 180s Java grace period).
# INSTANCE_PIDS holds the subshell wrapper PID, which is alive while
# launchGame() runs and dead after it exits.
isInstanceRunning() {
    local idx=$(( $1 - 1 ))
    [[ -n "${INSTANCE_PIDS[$idx]}" ]] && kill -0 "${INSTANCE_PIDS[$idx]}" 2>/dev/null
}

# =============================================================================
# Session infrastructure
# =============================================================================

# File path written before each scenario; holds newline-separated events.
_SESSION_EVENTS=""

# Temp file used by launchGame() to count launches across subshell boundary.
_LAUNCH_COUNT_FILE=$(mktemp)
echo "0" > "$_LAUNCH_COUNT_FILE"

# Override startControllerMonitor: open pre-written event file on fd 3.
# The event loop reads it with `read -t 1 -u 3 event`.  A regular file at
# EOF causes read to return immediately (not block for 1 s), so the loop
# spins fast once all events are consumed.
startControllerMonitor() {
    CONTROLLER_PIPE="$_SESSION_EVENTS"
    CONTROLLER_MONITOR_PID=""
    exec 3< "$_SESSION_EVENTS" 2>/dev/null || return 1
    return 0
}

stopControllerMonitor() {
    exec 3<&- 2>/dev/null || true
    CONTROLLER_PIPE=""
    CONTROLLER_MONITOR_PID=""
}

# Game "process": runs for 2 real seconds (using `command sleep` to bypass
# the sleep() no-op), then exits.  Called inside ( ... ) & by
# launchInstanceForSlot(), so the subshell PID is what INSTANCE_PIDS tracks.
launchGame() {
    local n
    n=$(cat "$_LAUNCH_COUNT_FILE" 2>/dev/null || echo 0)
    echo $(( n + 1 )) > "$_LAUNCH_COUNT_FILE"
    command sleep 2
}

# Reset all dynamic-mode globals between scenarios.
reset_state() {
    INSTANCE_ACTIVE=(0 0 0 0)
    INSTANCE_PIDS=("" "" "" "")
    INSTANCE_WRAPPER_PIDS=("" "" "" "")
    INSTANCE_LAUNCH_TIME=(0 0 0 0)
    INSTANCE_JAVA_RESOLVED=(0 0 0 0)
    INSTANCE_CONTROLLER_DEVICE=("" "" "" "")
    KNOWN_CONTROLLER_COUNT=0
    CURRENT_PLAYER_COUNT=0
    DYNAMIC_MODE=0
    echo "0" > "$_LAUNCH_COUNT_FILE"
    exec 3<&- 2>/dev/null || true
}

# Run the session with a 10-second watchdog.
# If the session hangs the watchdog kills this process, causing the grade
# suite to mark this test as failed rather than hanging forever.
run_session() {
    ( command sleep 10; kill $$ 2>/dev/null ) &
    local watchdog=$!
    runDynamicSplitscreen
    local rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
}

# =============================================================================
# Scenario 1: 0→1→2 players via controller-change events
#
# Timeline:
#   t=0s   initial getControllerCount()=0 → wait for events
#   t~0s   CONTROLLER_CHANGE:1 → slot 1 launched (command sleep 2 in background)
#   t~0s   CONTROLLER_CHANGE:2 → slot 2 launched (command sleep 2 in background)
#   t~2s   both sleep processes exit → checkForExitedInstances detects both dead
#   t~2s   CURRENT_PLAYER_COUNT→0 → session exits
#
# Verifies: initial-wait branch, scale-up to 2, natural process exit, session end
# =============================================================================

run_test "Scenario 1: 0→2 players via events, natural exit"
reset_state

_SESSION_EVENTS=$(mktemp)
printf 'CONTROLLER_CHANGE:1\nCONTROLLER_CHANGE:2\n' > "$_SESSION_EVENTS"
getControllerCount() { echo "0"; }

session_rc=0
run_session || session_rc=$?

launch_count=$(<"$_LAUNCH_COUNT_FILE")
assert_return "session exits cleanly (rc=0)"          "0"  "$session_rc"
assert_eq     "2 game instances were launched"         "2"  "$launch_count"
assert_eq     "KNOWN_CONTROLLER_COUNT=2"               "2"  "$KNOWN_CONTROLLER_COUNT"
assert_eq     "CURRENT_PLAYER_COUNT=0 at end"          "0"  "$CURRENT_PLAYER_COUNT"
assert_eq     "slot 1 marked stopped"                  "0"  "${INSTANCE_ACTIVE[0]}"
assert_eq     "slot 2 marked stopped"                  "0"  "${INSTANCE_ACTIVE[1]}"
assert_eq     "slot 3 never activated"                 "0"  "${INSTANCE_ACTIVE[2]}"

rm -f "$_SESSION_EVENTS"

# =============================================================================
# Scenario 2: 2 controllers already connected at session start
#
# Timeline:
#   t=0s   initial getControllerCount()=2 → immediate launch of slots 1 and 2
#   t~0s   no events in pipe (EOF immediately)
#   t~2s   both processes exit → session ends
#
# Verifies: initial-count>0 branch (not the wait-for-events path)
# =============================================================================

run_test "Scenario 2: 2 controllers already connected at start"
reset_state

_SESSION_EVENTS=$(mktemp)
# No events — just EOF
> "$_SESSION_EVENTS"
getControllerCount() { echo "2"; }

session_rc=0
run_session || session_rc=$?

launch_count=$(<"$_LAUNCH_COUNT_FILE")
assert_return "session exits cleanly"                  "0"  "$session_rc"
assert_eq     "2 instances launched from initial count" "2"  "$launch_count"
assert_eq     "KNOWN_CONTROLLER_COUNT=2"               "2"  "$KNOWN_CONTROLLER_COUNT"
assert_eq     "CURRENT_PLAYER_COUNT=0 at end"          "0"  "$CURRENT_PLAYER_COUNT"
assert_eq     "slot 1 marked stopped"                  "0"  "${INSTANCE_ACTIVE[0]}"
assert_eq     "slot 2 marked stopped"                  "0"  "${INSTANCE_ACTIVE[1]}"

rm -f "$_SESSION_EVENTS"

# =============================================================================
# Scenario 3: Single-player session
#
# Timeline:
#   t=0s   CONTROLLER_CHANGE:1 → slot 1 launched
#   t~2s   process exits → session ends
#
# Verifies: 1-player boundary (no repositioning needed, no placeholder window)
# =============================================================================

run_test "Scenario 3: single player joins and exits"
reset_state

_SESSION_EVENTS=$(mktemp)
printf 'CONTROLLER_CHANGE:1\n' > "$_SESSION_EVENTS"
getControllerCount() { echo "0"; }

session_rc=0
run_session || session_rc=$?

launch_count=$(<"$_LAUNCH_COUNT_FILE")
assert_return "session exits cleanly"                  "0"  "$session_rc"
assert_eq     "1 instance launched"                    "1"  "$launch_count"
assert_eq     "KNOWN_CONTROLLER_COUNT=1"               "1"  "$KNOWN_CONTROLLER_COUNT"
assert_eq     "CURRENT_PLAYER_COUNT=0 at end"          "0"  "$CURRENT_PLAYER_COUNT"
assert_eq     "slot 1 marked stopped"                  "0"  "${INSTANCE_ACTIVE[0]}"
assert_eq     "slots 2-4 never activated"              "000" \
    "${INSTANCE_ACTIVE[1]}${INSTANCE_ACTIVE[2]}${INSTANCE_ACTIVE[3]}"

rm -f "$_SESSION_EVENTS"

# =============================================================================
# Scenario 4: Controller disconnect event updates KNOWN but does not force-stop
#
# Timeline:
#   t=0s   CONTROLLER_CHANGE:2 → slots 1+2 launched
#   t~0s   CONTROLLER_CHANGE:1 → handleControllerChange(1) called
#           slots_to_launch = 1 - 2 = -1 → scale-down path
#           INSTANCE_CONTROLLER_DEVICE is empty → no force-stop, CURRENT unchanged
#   t~0s   CONTROLLER_CHANGE:0 → handleControllerChange(0)
#           KNOWN becomes 0, no device paths → no force-stop
#   t~2s   both processes exit naturally → session ends
#
# Verifies: scale-down path does not kill instances when INSTANCE_CONTROLLER_DEVICE
#           is unset (correct behavior: requires disconnect+reconnect per Issue #10)
# =============================================================================

run_test "Scenario 4: controller disconnect event updates KNOWN but keeps instances running"
reset_state

_SESSION_EVENTS=$(mktemp)
printf 'CONTROLLER_CHANGE:2\nCONTROLLER_CHANGE:1\nCONTROLLER_CHANGE:0\n' > "$_SESSION_EVENTS"
getControllerCount() { echo "0"; }

session_rc=0
run_session || session_rc=$?

launch_count=$(<"$_LAUNCH_COUNT_FILE")
assert_return "session exits cleanly"                  "0"  "$session_rc"
assert_eq     "2 instances launched despite disconnect events" "2" "$launch_count"
assert_eq     "KNOWN_CONTROLLER_COUNT=0 at end"        "0"  "$KNOWN_CONTROLLER_COUNT"
assert_eq     "CURRENT_PLAYER_COUNT=0 at end"          "0"  "$CURRENT_PLAYER_COUNT"
assert_eq     "slot 1 marked stopped"                  "0"  "${INSTANCE_ACTIVE[0]}"
assert_eq     "slot 2 marked stopped"                  "0"  "${INSTANCE_ACTIVE[1]}"

rm -f "$_SESSION_EVENTS"

# =============================================================================
# Scenario 5: Maximum players — all 4 slots filled
#
# Timeline:
#   t=0s   CONTROLLER_CHANGE:4 → slots 1+2+3+4 launched
#   t~2s   all 4 processes exit → session ends
#
# Verifies: 4-player launch, all slots cleaned up, clamping not triggered (<=4)
# =============================================================================

run_test "Scenario 5: four players (maximum) join and all exit"
reset_state

_SESSION_EVENTS=$(mktemp)
printf 'CONTROLLER_CHANGE:4\n' > "$_SESSION_EVENTS"
getControllerCount() { echo "0"; }

session_rc=0
run_session || session_rc=$?

launch_count=$(<"$_LAUNCH_COUNT_FILE")
assert_return "session exits cleanly"                  "0"  "$session_rc"
assert_eq     "4 instances launched"                   "4"  "$launch_count"
assert_eq     "KNOWN_CONTROLLER_COUNT=4"               "4"  "$KNOWN_CONTROLLER_COUNT"
assert_eq     "CURRENT_PLAYER_COUNT=0 at end"          "0"  "$CURRENT_PLAYER_COUNT"
for i in 0 1 2 3; do
    assert_eq "slot $((i+1)) marked stopped" "0" "${INSTANCE_ACTIVE[$i]}"
done

rm -f "$_SESSION_EVENTS"

# =============================================================================
# Scenario 6: Event count clamped at 4 — over-limit event is safe
#
# Timeline:
#   t=0s   CONTROLLER_CHANGE:5 → handleControllerChange(5) clamped to 4 slots
#   t~2s   all 4 exit → session ends
#
# Verifies: new_total clamped to 4 even when event count exceeds maximum
# =============================================================================

run_test "Scenario 6: controller count > 4 is clamped to 4 slots"
reset_state

_SESSION_EVENTS=$(mktemp)
printf 'CONTROLLER_CHANGE:5\n' > "$_SESSION_EVENTS"
getControllerCount() { echo "0"; }

session_rc=0
run_session || session_rc=$?

launch_count=$(<"$_LAUNCH_COUNT_FILE")
assert_return "session exits cleanly"                  "0"  "$session_rc"
assert_eq     "clamped to 4 instances (not 5)"         "4"  "$launch_count"
assert_eq     "KNOWN_CONTROLLER_COUNT=5 (raw event)"   "5"  "$KNOWN_CONTROLLER_COUNT"
assert_eq     "CURRENT_PLAYER_COUNT=0 at end"          "0"  "$CURRENT_PLAYER_COUNT"

rm -f "$_SESSION_EVENTS"

# =============================================================================
# Cleanup
# =============================================================================

rm -f "$_LAUNCH_COUNT_FILE"

# =============================================================================
# Summary
# =============================================================================

echo ""
TOTAL=$(( PASS + FAIL ))
printf "Results: %d/%d passed\n" "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]] || exit 1
