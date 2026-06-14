#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 2: Handheld Mode Test
# =============================================================================
# Operator-guided. Tests launching a single Minecraft instance in handheld mode.
# Requires: Steam Deck in handheld mode (undocked), built-in screen only.
#
# Automated checks:
#   - Display mode is handheld
#   - Orchestrator starts and FIFO appears
#   - Slot 1 becomes active in state file within 60s
#   - SplitscreenP1 window appears and is positioned fullscreen
#   - splitscreen.properties written with FULLSCREEN mode
#   - Slot 1 clears on game exit
#   - No orphan bwrap processes remain
#
# Human-in-loop checks:
#   - Game renders correctly (not black / corrupted)
#   - Controller input works (left stick moves view)
#   - Audio is audible
#   - Exit via in-game menu works cleanly
#
# Run standalone:
#   bash tests/hardware/stage2_handheld.sh
# =============================================================================

_STAGE2_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [[ -z "${HW_LOG:-}" ]]; then
    export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S).log"
    export REPO_ROOT="$(cd "$_STAGE2_SCRIPT_DIR/../.." && pwd)"
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0
    export HW_FAILED=0
    export HW_SKIPPED=0
fi

source "$_STAGE2_SCRIPT_DIR/lib/helpers.sh"
hw_detect_display
source "${REPO_ROOT}/modules/dock_detection.sh"

# ---------------------------------------------------------------------------
run_stage2_handheld() {
    hw_section "Stage 2: Handheld Mode"

    # -----------------------------------------------------------------------
    # H2.1 — Confirm handheld mode (automated + operator gate)
    # -----------------------------------------------------------------------
    hw_info "H2.1 — Confirm handheld mode"

    if ! hw_prompt "Ensure the Steam Deck is in HANDHELD mode (not docked).
  The built-in screen should be the only active display.
  If it is docked, undock it now and wait for the screen to switch back.
  Press Enter when ready, or type 'skip' to skip this entire stage."; then
        hw_skip "Stage 2 skipped by operator"
        return 0
    fi

    local current_mode=""
    current_mode=$(get_display_mode 2>>"${HW_LOG}" || true)
    hw_log "get_display_mode returned: '${current_mode}'"
    hw_assert_eq "H2.1 display mode is handheld" "handheld" "$current_mode"

    if [[ "$current_mode" != "handheld" ]]; then
        hw_fail "H2.1 aborting stage 2 — mode is '${current_mode}', expected 'handheld'"
        return 1
    fi

    # Capture screen resolution now, before Minecraft launches
    local screen_res sw sh
    screen_res=$(hw_get_screen_resolution)
    sw="${screen_res%%x*}"
    sh="${screen_res##*x}"
    hw_log "H2.1 screen resolution: ${screen_res} (${sw}×${sh})"

    # -----------------------------------------------------------------------
    # H2.2 — Launch orchestrator
    # -----------------------------------------------------------------------
    hw_info "H2.2 — Launching orchestrator in handheld mode..."
    hw_launch_orchestrator handheld

    if ! hw_wait_for "H2.2 FIFO created" 10 test -p "${SPLITSCREEN_FIFO}"; then
        hw_warn "FIFO did not appear — orchestrator may not have started"
        hw_dump_processes
    fi
    hw_log "Orchestrator PID: ${HW_ORCH_PID:-<unknown>}"

    # -----------------------------------------------------------------------
    # H2.3 — Slot 1 becomes active in state file (automated)
    # -----------------------------------------------------------------------
    hw_info "H2.3 — Waiting for slot 1 to become active (up to 60s)"

    if hw_wait_for "H2.3 slot 1 active" 60 \
        jq -e '.slots["1"].active == true' "${SPLITSCREEN_STATE}"; then

        local bwrap_pid java_pid
        bwrap_pid=$(jq -r '.slots["1"].bwrap_pid // empty' "${SPLITSCREEN_STATE}" 2>/dev/null || true)
        java_pid=$(jq -r  '.slots["1"].pid // empty'       "${SPLITSCREEN_STATE}" 2>/dev/null || true)
        hw_log "H2.3 slot 1 bwrap PID: ${bwrap_pid:-<not set>}"
        hw_log "H2.3 slot 1 java PID:  ${java_pid:-<not set>}"

        # Verify bwrap is actually alive
        if [[ -n "$bwrap_pid" ]]; then
            if kill -0 "$bwrap_pid" 2>/dev/null; then
                hw_pass "H2.3 bwrap PID ${bwrap_pid} is alive"
            else
                hw_fail "H2.3 bwrap PID ${bwrap_pid} in state but process not found"
            fi
        fi

        hw_dump_state
        hw_dump_processes
    else
        hw_warn "H2.3 slot 1 did not activate within 60s"
        hw_dump_state
        hw_dump_processes
    fi

    # -----------------------------------------------------------------------
    # H2.4 — Minecraft window appears (automated)
    # -----------------------------------------------------------------------
    hw_info "H2.4 — Waiting for SplitscreenP1 window (up to 60s)"

    hw_wait_for "H2.4 SplitscreenP1 window" 60 \
        bash -c "xdotool search --onlyvisible --name SplitscreenP1 >/dev/null 2>&1" || true

    # -----------------------------------------------------------------------
    # H2.4b — Verify window geometry matches fullscreen (automated)
    # -----------------------------------------------------------------------
    hw_info "H2.4b — Verifying SplitscreenP1 window is fullscreen"

    local exp_x exp_y exp_w exp_h
    read -r exp_x exp_y exp_w exp_h < <(hw_expected_slot_geometry 1 "1" "$sw" "$sh")
    hw_log "H2.4b expected geometry: x=${exp_x} y=${exp_y} w=${exp_w} h=${exp_h}"

    hw_assert_window_at "H2.4b SplitscreenP1 fullscreen geometry" \
        "SplitscreenP1" "$exp_x" "$exp_y" "$exp_w" "$exp_h" 50

    # -----------------------------------------------------------------------
    # H2.4c — splitscreen.properties written correctly (automated)
    # -----------------------------------------------------------------------
    hw_info "H2.4c — Verifying splitscreen.properties for slot 1"
    hw_assert_splitscreen_properties "H2.4c" 1 "FULLSCREEN"

    # -----------------------------------------------------------------------
    # H2.5 — Human gameplay verification (checklist)
    # -----------------------------------------------------------------------
    hw_info "H2.5 — Human gameplay verification"

    if hw_prompt "Minecraft should now be running fullscreen on the built-in screen.
  You will be asked to confirm specific items one by one.
  For each item: type y (yes/confirmed), n (no/wrong), or s (skip).
  Press Enter to begin the checklist."; then

        hw_checklist "H2.5 Handheld gameplay" \
            "The Minecraft window fills the entire built-in screen with no gaps or borders" \
            "The game renders correctly — no black screen, no visual corruption" \
            "A world or the main menu is visible (game is not stuck loading)" \
            "Moving the LEFT STICK rotates the camera / navigates the menu" \
            "Pressing the A button (or equivalent) confirms menu selections" \
            "Audio is audible from the Steam Deck speakers" \
            "The frame rate feels smooth (not severely choppy)"

    else
        hw_skip "H2.5 Gameplay checklist skipped by operator"
    fi

    # -----------------------------------------------------------------------
    # H2.6 — Graceful in-game exit (operator action + automated verification)
    # -----------------------------------------------------------------------
    hw_info "H2.6 — Operator exits Minecraft via in-game menu"

    hw_prompt "Exit Minecraft using the in-game QUIT button (not a force-kill).
  Open the pause menu → Quit to Title → Quit Game (or equivalent).
  Wait for the game to close completely, then press Enter." || true

    hw_log "Waiting up to 30s for slot 1 to go inactive after exit"
    if ! hw_wait_for "H2.6 slot 1 cleared on exit" 30 \
        jq -e '.slots["1"].active == false' "${SPLITSCREEN_STATE}"; then
        hw_fail "H2.6 slot 1 did not clear within 30s — watchdog or teardown may be broken"
        hw_dump_state
        hw_dump_processes
    fi

    # Verify window is gone
    sleep 2
    local window_gone=""
    window_gone=$(xdotool search --onlyvisible --name SplitscreenP1 2>/dev/null || true)
    hw_log "H2.6 SplitscreenP1 window after exit: '${window_gone:-<not found (expected)>}'"
    hw_assert_empty "H2.6 SplitscreenP1 window closed after game exit" "$window_gone"

    # -----------------------------------------------------------------------
    # H2.7 — No orphan processes after exit (automated)
    # -----------------------------------------------------------------------
    hw_info "H2.7 — Verifying cleanup: no orphan bwrap/java processes"
    sleep 2

    local bwrap_procs=""
    bwrap_procs=$(pgrep -af 'bwrap.*latestUpdate' 2>/dev/null || true)
    hw_log "H2.7 bwrap+latestUpdate processes: ${bwrap_procs:-<none>}"
    hw_assert_empty "H2.7 no orphan bwrap processes after exit" "$bwrap_procs"

    local java_procs=""
    java_procs=$(pgrep -af 'java.*latestUpdate' 2>/dev/null || true)
    hw_log "H2.7 java+latestUpdate processes: ${java_procs:-<none>}"
    hw_assert_empty "H2.7 no orphan java processes after exit" "$java_procs"

    hw_dump_state
    hw_dump_processes
    hw_stop_orchestrator

    hw_info "Stage 2 complete."
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    run_stage2_handheld
fi
