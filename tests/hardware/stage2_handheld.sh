#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 2: Handheld Mode Test
# =============================================================================
# Operator-guided. Tests launching a single Minecraft instance in handheld mode.
# Requires: Steam Deck in handheld mode (undocked), built-in screen only.
#
# Run standalone:
#   bash tests/hardware/stage2_handheld.sh
# =============================================================================

_STAGE2_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Bootstrap when run standalone
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

# Source modules so we can call get_display_mode directly
source "${REPO_ROOT}/modules/dock_detection.sh"

# ---------------------------------------------------------------------------
run_stage2_handheld() {
    hw_section "Stage 2: Handheld Mode"

    # -----------------------------------------------------------------------
    # H2.1 — Confirm undocked
    # -----------------------------------------------------------------------
    hw_info "H2.1 — Confirm handheld mode"

    if ! hw_prompt "Ensure the Steam Deck is in HANDHELD mode (not docked).
           The built-in screen should be the only display.
           If it is docked, undock it now and wait for the display to switch back.
           Press Enter when ready, or type 'skip' to skip this entire stage."; then
        hw_skip "H2.1 Stage 2 skipped by operator"
        return 0
    fi

    hw_log "Running: get_display_mode"
    local current_mode=""
    current_mode=$(get_display_mode 2>>"${HW_LOG}" || true)
    hw_log "get_display_mode returned: '${current_mode}'"
    hw_assert_eq "H2.1 display mode is handheld" "handheld" "$current_mode"

    if [[ "$current_mode" != "handheld" ]]; then
        hw_fail "H2.1 Cannot proceed — display mode is '${current_mode}', expected 'handheld'"
        hw_dump_state
        hw_dump_processes
        return 1
    fi

    # -----------------------------------------------------------------------
    # H2.2 — Launch orchestrator in handheld mode
    # -----------------------------------------------------------------------
    hw_info "H2.2 — Launching orchestrator in handheld mode..."

    hw_launch_orchestrator handheld

    hw_log "Running: hw_wait_for 'FIFO created' 10 test -p '${SPLITSCREEN_FIFO}'"
    if ! hw_wait_for "H2.2 FIFO created" 10 test -p "${SPLITSCREEN_FIFO}"; then
        hw_warn "FIFO did not appear — orchestrator may not have started correctly"
        hw_dump_state
        hw_dump_processes
    fi

    hw_info "Orchestrator PID: ${HW_ORCH_PID:-<unknown>}"
    hw_dump_processes

    # -----------------------------------------------------------------------
    # H2.3 — Instance spawns within 60s
    # -----------------------------------------------------------------------
    hw_info "H2.3 — Waiting for slot 1 to become active in state file"

    hw_log "Running: jq -e '.slots[\"1\"].active == true' '${SPLITSCREEN_STATE}'"
    if hw_wait_for "H2.3 slot 1 active in state" 60 \
        jq -e '.slots["1"].active == true' "${SPLITSCREEN_STATE}"; then

        hw_info "Slot 1 is active. Dumping state and processes."
        hw_dump_state
        hw_dump_processes

        # Log bwrap PID and java PID
        local bwrap_pid=""
        local java_pid=""
        bwrap_pid=$(jq -r '.slots["1"].bwrap_pid // empty' "${SPLITSCREEN_STATE}" 2>/dev/null || true)
        java_pid=$(jq -r '.slots["1"].pid // empty' "${SPLITSCREEN_STATE}" 2>/dev/null || true)
        hw_log "Slot 1 bwrap PID: ${bwrap_pid:-<not yet set>}"
        hw_log "Slot 1 java PID:  ${java_pid:-<not yet set>}"
    else
        hw_warn "H2.3 Slot 1 did not become active within 60s"
        hw_dump_state
        hw_dump_processes
    fi

    # -----------------------------------------------------------------------
    # H2.4 — Minecraft window appears
    # -----------------------------------------------------------------------
    hw_info "H2.4 — Waiting for SplitscreenP1 window to appear"
    hw_log "Running: xdotool search --name SplitscreenP1"
    hw_wait_for "H2.4 SplitscreenP1 window" 60 \
        xdotool search --name SplitscreenP1 || true

    # -----------------------------------------------------------------------
    # H2.5 — Operator confirms fullscreen
    # -----------------------------------------------------------------------
    hw_info "H2.5 — Operator visual confirmation"

    if hw_prompt "Look at the Steam Deck screen.
           Minecraft should be fullscreen on the built-in display.
           Confirm it is running and filling the screen.
           Press Enter to continue, or type 'skip' to skip this check."; then

        if hw_confirm "Did Minecraft appear fullscreen on the built-in display? [y/N]"; then
            hw_pass "H2.5 Operator confirmed Minecraft is fullscreen on built-in display"
        else
            hw_fail "H2.5 Operator reported Minecraft did NOT appear fullscreen"
            hw_dump_state
            hw_dump_processes
        fi
    else
        hw_skip "H2.5 Visual confirmation skipped by operator"
    fi

    # -----------------------------------------------------------------------
    # H2.6 — Operator exits Minecraft
    # -----------------------------------------------------------------------
    hw_info "H2.6 — Operator exits Minecraft gracefully"

    hw_prompt "Exit Minecraft using the in-game quit button (not force kill).
           Wait for the game to fully close before pressing Enter." || true

    hw_log "Running: jq -e '.slots[\"1\"].active == false' '${SPLITSCREEN_STATE}'"
    if ! hw_wait_for "H2.6 slot 1 inactive after exit" 30 \
        jq -e '.slots["1"].active == false' "${SPLITSCREEN_STATE}"; then
        hw_warn "H2.6 Slot 1 did not become inactive within 30s — may require manual cleanup"
        hw_dump_state
        hw_dump_processes
    fi

    # -----------------------------------------------------------------------
    # H2.7 — Cleanup verified
    # -----------------------------------------------------------------------
    hw_info "H2.7 — Verifying cleanup: no lingering bwrap processes"

    # Give orchestrator a moment to clean up
    sleep 2

    local bwrap_procs=""
    bwrap_procs=$(pgrep -f 'bwrap' 2>/dev/null || true)
    hw_log "bwrap processes after exit: ${bwrap_procs:-<none>}"
    hw_assert_empty "H2.7 no bwrap processes remain after slot 1 exit" "$bwrap_procs"

    hw_dump_state
    hw_dump_processes

    # Stop orchestrator cleanly if still running
    hw_stop_orchestrator

    hw_info "Stage 2 complete."
}

# Run standalone if executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    run_stage2_handheld
fi
