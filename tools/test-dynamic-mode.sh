#!/usr/bin/env bash
#
# @file test-dynamic-mode.sh
# @description Test harness for the dynamic splitscreen event loop.
#
# Mocks Minecraft instances with "sleep 300" processes so the controller
# detection, join/leave logic, and Issue #10 disconnect+reconnect gate can
# be exercised over SSH without PrismLauncher or a display.
#
# Usage:
#   Terminal 1 (virtual controllers):
#     python3 test-virtual-controller.py      # a=add  r=remove  q=quit
#
#   Terminal 2 (this harness):
#     ./tools/test-dynamic-mode.sh
#
# Test scenario — confirm Issue #10 bug (before fix):
#   1. Add 2 controllers  →  2 mock instances launch (PIDs shown)
#   2. kill <PID>         →  KNOWN syncs down; any subsequent CONTROLLER_CHANGE relaunches
#   3. 'r' then 'a' in controller tool to trigger the relaunch without physical disconnect
#
# Test scenario — confirm fix (after fix):
#   1. Add 2 controllers  →  2 mock instances launch
#   2. kill <PID>         →  "controller still connected, waiting for disconnect" logged
#   3. KNOWN stays at 2   →  no relaunch, even if controller events fire
#   4. 'r'               →  CONTROLLER_CHANGE:1  →  scale down, KNOWN=1
#   5. 'a'               →  CONTROLLER_CHANGE:2  →  relaunch ✓

set -uo pipefail   # Note: no -e so sourced script errors don't abort the harness

# =============================================================================
# Locate generated launcher script
# =============================================================================

GENERATED_SCRIPT="${GENERATED_SCRIPT:-}"
if [[ -z "$GENERATED_SCRIPT" ]]; then
    if [[ -f "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/minecraftSplitscreen.sh" ]]; then
        GENERATED_SCRIPT="$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/minecraftSplitscreen.sh"
    elif [[ -f "$HOME/.local/share/PrismLauncher/minecraftSplitscreen.sh" ]]; then
        GENERATED_SCRIPT="$HOME/.local/share/PrismLauncher/minecraftSplitscreen.sh"
    else
        echo "[!] Cannot find minecraftSplitscreen.sh — run the installer first,"
        echo "    or set GENERATED_SCRIPT=/path/to/minecraftSplitscreen.sh"
        exit 1
    fi
fi

echo "=== Dynamic Mode Test Harness ==="
echo "Generated script: $GENERATED_SCRIPT"
echo ""

# =============================================================================
# Source function definitions only (lines 1–2253).
#
# The generated script runs `if ! validate_launcher; then exit 1; fi` at line 171.
# We bypass this by:
#   1. Source lines 1-170  (includes the real validate_launcher definition)
#   2. Inject mock that overrides it  (returns 0 always)
#   3. Source lines 172-2253  (skips line 171, picks up remaining function defs)
# =============================================================================

# Find the actual line where function defs end (entry point starts).
# The entry point is "# Parse command line arguments" / LAUNCH_MODE= line.
ENTRY_LINE=$(grep -n "^LAUNCH_MODE=" "$GENERATED_SCRIPT" | head -1 | cut -d: -f1)
ENTRY_LINE=${ENTRY_LINE:-2254}
DEFS_END=$(( ENTRY_LINE - 1 ))

# Line where validate_launcher check is (if ! validate_launcher...)
VALIDATE_CHECK_LINE=$(grep -n "if ! validate_launcher" "$GENERATED_SCRIPT" | head -1 | cut -d: -f1)
VALIDATE_CHECK_LINE=${VALIDATE_CHECK_LINE:-171}
BEFORE_CHECK=$(( VALIDATE_CHECK_LINE - 1 ))
AFTER_CHECK=$(( VALIDATE_CHECK_LINE + 2 ))  # skip the "if ! validate_launcher; then" + "exit 1" + "fi" lines

echo "Sourcing function definitions (lines 1-${DEFS_END}, skipping validate_launcher check at ${VALIDATE_CHECK_LINE})..."

# shellcheck disable=SC1090
source <(
    head -n "$BEFORE_CHECK" "$GENERATED_SCRIPT"
    echo 'validate_launcher() { return 0; }'
    sed -n "${AFTER_CHECK},${DEFS_END}p" "$GENERATED_SCRIPT"
)

echo "Functions loaded."
echo ""

# =============================================================================
# Mock overrides — replace real operations with test stubs
# =============================================================================

# Track mock PIDs separately for clean display
declare -a MOCK_SLEEP_PIDS=("" "" "" "")

# Mock: run a sleep process instead of Minecraft
launchGame() {
    # Called as: launchGame "latestUpdate-$slot" "PlayerN"
    # The real function calls flatpak/kde-inhibit. We just sleep.
    sleep 300
}

# Override launchInstanceForSlot to:
#   - call the real version (which calls launchGame → sleep 300)
#   - then immediately mark INSTANCE_JAVA_RESOLVED so isInstanceRunning
#     skips the 180-second grace period
launchInstanceForSlot() {
    local slot=$1
    local total_players=$2
    local idx=$((slot - 1))

    # Call real implementation (which spawns launchGame in a subshell)
    # We need to replicate the core of it here since we can't call the real
    # one and then modify arrays (subshell vs parent scope issue with the &)
    INSTANCE_ACTIVE[$idx]=1
    INSTANCE_LAUNCH_TIME[$idx]=$(date +%s)
    INSTANCE_JAVA_RESOLVED[$idx]=1  # skip grace period

    ( trap - EXIT INT TERM; launchGame "latestUpdate-$slot" "Player$slot" ) &
    local mock_pid=$!
    INSTANCE_PIDS[$idx]=$mock_pid
    INSTANCE_WRAPPER_PIDS[$idx]=$mock_pid
    MOCK_SLEEP_PIDS[$idx]=$mock_pid

    echo ""
    echo "  [MOCK] Instance $slot launched  (PID $mock_pid) — to simulate Minecraft exit:"
    echo "         kill $mock_pid"
    echo ""
    log_info "Mock instance $slot started (PID: $mock_pid), total players: $total_players"
}

# Override isInstanceRunning: just check if PID is alive, no grace period
isInstanceRunning() {
    local slot=$1
    local idx=$((slot - 1))
    local pid="${INSTANCE_PIDS[$idx]}"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# No-op overrides for display/system operations
assignControllerToSlot()       { log_debug "[MOCK] assignControllerToSlot($*)"; }
setSplitscreenModeForPlayer()  { log_debug "[MOCK] setSplitscreenModeForPlayer($*)"; }
initSdlWrappers()              { log_debug "[MOCK] initSdlWrappers"; }
writeInstanceSdlEnv()          { log_debug "[MOCK] writeInstanceSdlEnv($*)"; }
clearInstanceSdlEnv()          { log_debug "[MOCK] clearInstanceSdlEnv($*)"; }
inhibitScreen()                { log_debug "[MOCK] inhibitScreen"; }
uninhibitScreen()              { log_debug "[MOCK] uninhibitScreen"; }
hidePanels()                   { log_debug "[MOCK] hidePanels"; }
restorePanels()                { log_debug "[MOCK] restorePanels"; }
showPanels()                   { log_debug "[MOCK] showPanels"; }
repositionAllWindows()         { log_info  "[MOCK] repositionAllWindows (total=$*)"; }
installKWinRepositionScript()  { log_debug "[MOCK] installKWinRepositionScript"; }
returnFocusToSteam()           { log_debug "[MOCK] returnFocusToSteam"; }
showNotification()             { log_info  "[NOTIFY] $*"; }
isSteamDeckGameMode()          { return 1; }   # always desktop mode
hasSteamVirtualController()    { return 1; }   # false — no Steam virtual gamepad

# Make log_debug also print to stdout (it goes to stderr by default)
log_debug() { echo "[Debug] $*"; log "DEBUG: $*"; }

# =============================================================================
# Display instructions and current controller state
# =============================================================================

initial_count=$(getControllerCount)
echo "Current controller count: $initial_count"
echo ""
echo "Instructions:"
echo "  Terminal 1: python3 test-virtual-controller.py"
echo "              a=add controller  r=remove last  q=quit"
echo ""
echo "  Once controllers are added, instances will auto-launch."
echo "  To simulate Minecraft crash: kill <PID shown at launch>"
echo "  Ctrl-C to stop the harness."
echo ""
echo "Starting dynamic mode event loop..."
echo "─────────────────────────────────────────────────────"

# =============================================================================
# Run the dynamic mode event loop directly
# =============================================================================

DYNAMIC_MODE=1
runDynamicSplitscreen
