#!/usr/bin/env bash
# =============================================================================
# @file test_dynamic_mode.sh
# @description Automated assertions for the dynamic splitscreen event loop.
#
# Tests state management in the generated launcher without a display,
# PrismLauncher, or physical controllers. Each test asserts exact values of
# INSTANCE_ACTIVE, INSTANCE_PIDS, and KNOWN_CONTROLLER_COUNT after calling
# the real event-loop functions with mocked side-effects.
#
# Usage:
#   bash tests/test_dynamic_mode.sh
#   GENERATED_SCRIPT=/path/to/real/minecraftSplitscreen.sh bash tests/test_dynamic_mode.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="${GENERATED_SCRIPT:-$SCRIPT_DIR/fixtures/minecraftSplitscreen.sh}"

# =============================================================================
# Bootstrap — source function definitions only, same technique as
# tools/test-dynamic-mode.sh, but we never call runDynamicSplitscreen.
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
AFTER_CHECK=$(( VALIDATE_CHECK_LINE + 3 ))  # skip 3-line if/exit/fi block

# shellcheck disable=SC1090
source <(
    head -n "$BEFORE_CHECK" "$FIXTURE"
    echo 'validate_launcher() { return 0; }'
    sed -n "${AFTER_CHECK},${DEFS_END}p" "$FIXTURE"
)

# =============================================================================
# Mocks
# =============================================================================

# Make handleControllerChange instant — it has sleep 5/10/7 for GPU/window waits.
sleep() { :; }

# Spawn a real background process so INSTANCE_PIDS holds a trackable PID.
# Uses 'command sleep' to bypass the sleep() no-op above.
launchGame() { command sleep 300; }

# Skip the 180s grace period; just check whether the tracked PID is alive.
# The real isInstanceRunning tries to find the Java PID via pgrep and falls
# back to a grace period when neither wrapper nor Java is alive yet, which
# would make killed-PID tests falsely report "still running" for 3 minutes.
isInstanceRunning() {
    local idx=$(( $1 - 1 ))
    [[ -n "${INSTANCE_PIDS[$idx]}" ]] && kill -0 "${INSTANCE_PIDS[$idx]}" 2>/dev/null
}

# No-op all functions that touch the filesystem, display, or external processes.
setControllableAutoSelect()    { :; }
assignControllerToSlot()       { :; }
setSplitscreenModeForPlayer()  { :; }
initSdlWrappers()              { :; }
writeInstanceSdlEnv()          { :; }
clearInstanceSdlEnv()          { :; }
inhibitScreen()                { :; }
uninhibitScreen()              { :; }
hidePanels()                   { :; }
restorePanels()                { :; }
showPanels()                   { :; }
repositionAllWindows()         { :; }
installKWinRepositionScript()  { :; }
returnFocusToSteam()           { :; }
showNotification()             { :; }
updatePlaceholderWindow()      { :; }
hidePlaceholderWindow()        { :; }
showPlaceholderWindow()        { :; }
enforceMemorySettings()        { :; }
isSteamDeckGameMode()          { return 1; }
hasSteamVirtualController()    { return 1; }
log_info()                     { :; }
log_debug()                    { :; }
log_warning()                  { :; }
log_error()                    { :; }
log()                          { :; }

# =============================================================================
# State helpers
# =============================================================================

reset_state() {
    INSTANCE_ACTIVE=(0 0 0 0)
    INSTANCE_PIDS=("" "" "" "")
    INSTANCE_WRAPPER_PIDS=("" "" "" "")
    INSTANCE_JAVA_RESOLVED=(0 0 0 0)
    INSTANCE_LAUNCH_TIME=(0 0 0 0)
    INSTANCE_CONTROLLER_DEVICE=("" "" "" "")
    KNOWN_CONTROLLER_COUNT=0
    CURRENT_PLAYER_COUNT=0
}

kill_mock_instances() {
    local pid
    for pid in "${INSTANCE_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}

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

run_test() { echo "--- $1"; }

# =============================================================================
# Test 1: scale-up 0 → 1
# =============================================================================
run_test "scale-up: 0 → 1 controller"
reset_state
handleControllerChange 1
assert_eq "slot 1 active"           "1"   "${INSTANCE_ACTIVE[0]}"
assert_eq "slots 2-4 inactive"      "000" "${INSTANCE_ACTIVE[1]}${INSTANCE_ACTIVE[2]}${INSTANCE_ACTIVE[3]}"
assert_eq "KNOWN_CONTROLLER_COUNT"  "1"   "$KNOWN_CONTROLLER_COUNT"
assert_eq "countActiveInstances"    "1"   "$(countActiveInstances)"
assert_eq "slot 1 PID set"          "1"   "$([[ -n ${INSTANCE_PIDS[0]} ]] && echo 1 || echo 0)"
kill_mock_instances; reset_state

# =============================================================================
# Test 2: scale-up across two events (0 → 1 → 2)
# =============================================================================
run_test "scale-up: 0 → 1 → 2 controllers"
reset_state
handleControllerChange 1
handleControllerChange 2
assert_eq "slot 1 active"           "1"  "${INSTANCE_ACTIVE[0]}"
assert_eq "slot 2 active"           "1"  "${INSTANCE_ACTIVE[1]}"
assert_eq "slots 3-4 inactive"      "00" "${INSTANCE_ACTIVE[2]}${INSTANCE_ACTIVE[3]}"
assert_eq "KNOWN_CONTROLLER_COUNT"  "2"  "$KNOWN_CONTROLLER_COUNT"
assert_eq "countActiveInstances"    "2"  "$(countActiveInstances)"
kill_mock_instances; reset_state

# =============================================================================
# Test 3: scale-up 0 → 4 in a single event (max players)
# =============================================================================
run_test "scale-up: 0 → 4 controllers (max, single event)"
reset_state
handleControllerChange 4
assert_eq "all 4 slots active"     "1111" \
    "${INSTANCE_ACTIVE[0]}${INSTANCE_ACTIVE[1]}${INSTANCE_ACTIVE[2]}${INSTANCE_ACTIVE[3]}"
assert_eq "KNOWN_CONTROLLER_COUNT" "4"    "$KNOWN_CONTROLLER_COUNT"
assert_eq "countActiveInstances"   "4"    "$(countActiveInstances)"
kill_mock_instances; reset_state

# =============================================================================
# Test 4: checkForExitedInstances detects a dead process and clears its slot
# =============================================================================
run_test "checkForExitedInstances: clears slot when PID dies"
reset_state
handleControllerChange 1
pid1="${INSTANCE_PIDS[0]}"
assert_eq "slot 1 initially active" "1" "${INSTANCE_ACTIVE[0]}"

kill "$pid1" 2>/dev/null; wait "$pid1" 2>/dev/null || true
checkForExitedInstances

assert_eq "slot 1 marked stopped"  "0" "${INSTANCE_ACTIVE[0]}"
assert_eq "slot 1 PID cleared"     ""  "${INSTANCE_PIDS[0]}"
assert_eq "countActiveInstances"   "0" "$(countActiveInstances)"
kill_mock_instances; reset_state

# =============================================================================
# Test 5: Issue #10 — no spurious relaunch when controller stays connected
#
# Scenario: 2 players active. Player 1 quits Minecraft (PID dies) but leaves
# their controller plugged in. A CONTROLLER_CHANGE event with the same count
# (2) must NOT relaunch slot 1 — the reconnect gate requires a physical
# disconnect before a new session can be triggered.
# =============================================================================
run_test "Issue #10: no relaunch when controller stays connected after exit"
reset_state
handleControllerChange 2
assert_eq "2 active before exit"  "2" "$(countActiveInstances)"

pid1="${INSTANCE_PIDS[0]}"
known_before="$KNOWN_CONTROLLER_COUNT"

# Player 1 quits Minecraft; controller stays connected.
kill "$pid1" 2>/dev/null; wait "$pid1" 2>/dev/null || true
checkForExitedInstances

assert_eq "slot 1 stopped"                    "0"            "${INSTANCE_ACTIVE[0]}"
assert_eq "KNOWN unchanged (gate enforced)"   "$known_before" "$KNOWN_CONTROLLER_COUNT"

# A CONTROLLER_CHANGE:2 arrives (same count — controller never disconnected).
# slots_to_launch = 2 - KNOWN(2) = 0 → no relaunch.
handleControllerChange 2
assert_eq "still 1 active (no relaunch)"  "1" "$(countActiveInstances)"
assert_eq "slot 1 not relaunched"         "0" "${INSTANCE_ACTIVE[0]}"
assert_eq "slot 2 still running"          "1" "${INSTANCE_ACTIVE[1]}"

kill_mock_instances; reset_state

# =============================================================================
# Summary
# =============================================================================
echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
