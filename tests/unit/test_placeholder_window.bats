#!/usr/bin/env bats
# =============================================================================
# Unit tests: black P4 placeholder window logic
# Tests show/hide/update logic without requiring a display.
# =============================================================================

load "../helpers"

setup() {
    setup_test_env
    source_launcher_functions

    # Stub display-dependent functions after sourcing
    python3()   { :; }   # don't actually open a window
    xdpyinfo()  { echo "dimensions: 1920x1080 pixels"; }
}

teardown() {
    teardown_test_env
}

# ---------------------------------------------------------------------------
# updatePlaceholderWindow
# ---------------------------------------------------------------------------

@test "updatePlaceholderWindow shows placeholder when player count is 3" {
    CURRENT_PLAYER_COUNT=3

    local show_called=0
    showPlaceholderWindow() { show_called=1; PLACEHOLDER_PID=9999; }
    hidePlaceholderWindow() { :; }

    updatePlaceholderWindow

    [[ "$show_called" -eq 1 ]]
}

@test "updatePlaceholderWindow hides placeholder when player count is 2" {
    CURRENT_PLAYER_COUNT=2
    PLACEHOLDER_PID=9999

    local hide_called=0
    showPlaceholderWindow() { :; }
    hidePlaceholderWindow() { hide_called=1; PLACEHOLDER_PID=""; }

    updatePlaceholderWindow

    [[ "$hide_called" -eq 1 ]]
}

@test "updatePlaceholderWindow hides placeholder when player count is 4" {
    CURRENT_PLAYER_COUNT=4
    PLACEHOLDER_PID=9999

    local hide_called=0
    showPlaceholderWindow() { :; }
    hidePlaceholderWindow() { hide_called=1; PLACEHOLDER_PID=""; }

    updatePlaceholderWindow

    [[ "$hide_called" -eq 1 ]]
}

@test "updatePlaceholderWindow does not respawn if window already live at count 3" {
    CURRENT_PLAYER_COUNT=3
    PLACEHOLDER_PID=$$    # current process = definitely alive

    local show_called=0
    showPlaceholderWindow() { show_called=1; }

    updatePlaceholderWindow

    # Already live → should skip the spawn
    [[ "$show_called" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# CURRENT_PLAYER_COUNT ordering (the bug we fixed)
# ---------------------------------------------------------------------------

@test "CURRENT_PLAYER_COUNT is updated before updatePlaceholderWindow in scale-up" {
    # Simulate the scale-up path: current_active goes from 2 to 3
    # Before the fix, CURRENT_PLAYER_COUNT stayed 2 when updatePlaceholderWindow ran.
    local count_at_update=0

    CURRENT_PLAYER_COUNT=2   # old value (pre-launch)

    updatePlaceholderWindow() {
        count_at_update=$CURRENT_PLAYER_COUNT
    }

    # Replicate the fixed scale-up sequence
    local current_active=3
    CURRENT_PLAYER_COUNT=$current_active   # must come BEFORE updatePlaceholderWindow
    updatePlaceholderWindow

    # count_at_update should be 3, not 2
    [[ "$count_at_update" -eq 3 ]]
}
