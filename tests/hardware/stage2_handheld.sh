#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 2: Handheld Mode Test (non-interactive)
# =============================================================================
# No prompts. Runs orchestrator, logs mechanical state, then operator
# reports results manually. Minecraft launch/controller/audio tested
# visually by the operator.
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

run_stage2_handheld() {
    hw_section "Stage 2: Handheld Mode (non-interactive)"

    # --- H2.1 — Confirm handheld mode ---
    hw_info "H2.1 — Checking display mode"
    local current_mode
    current_mode=$(get_display_mode 2>>"${HW_LOG}" || true)
    hw_log "get_display_mode: ${current_mode}"
    hw_assert_eq "H2.1 display mode is handheld" "handheld" "$current_mode"

    if [[ "$current_mode" != "handheld" ]]; then
        hw_fail "H2.1 aborting — mode is '${current_mode}', expected 'handheld'"
        return 1
    fi

    local screen_res sw sh
    screen_res=$(hw_get_screen_resolution)
    sw="${screen_res%%x*}"
    sh="${screen_res##*x}"
    hw_log "H2.1 screen: ${screen_res} (${sw}x${sh})"

    # --- H2.2 — Launch orchestrator ---
    hw_info "H2.2 — Launching orchestrator handheld"
    rm -f "$SPLITSCREEN_STATE" "$SPLITSCREEN_FIFO"
    SPLITSCREEN_MODE=handheld bash "${REPO_ROOT}/minecraftSplitscreen.sh" launchFromPlasma >> "${HW_LOG}.orch" 2>&1 &
    HW_ORCH_PID=$!
    export HW_ORCH_PID
    hw_log "Orchestrator PID: ${HW_ORCH_PID}"

    if hw_wait_for "H2.2 FIFO created" 10 test -p "$SPLITSCREEN_FIFO"; then
        hw_pass "H2.2 FIFO created"
    else
        hw_warn "H2.2 FIFO did not appear"
    fi

    # --- H2.3 — Slot 1 active ---
    hw_info "H2.3 — Waiting for slot 1 active (60s)"
    if hw_wait_for "H2.3 slot 1 active" 60 \
        jq -e '.slots["1"].active == true' "$SPLITSCREEN_STATE"; then

        local bwrap_pid java_pid
        bwrap_pid=$(jq -r '.slots["1"].bwrap_pid // empty' "$SPLITSCREEN_STATE" 2>/dev/null || true)
        java_pid=$(jq  -r '.slots["1"].pid // empty'        "$SPLITSCREEN_STATE" 2>/dev/null || true)
        hw_log "Slot 1: bwrap=${bwrap_pid:-?} java=${java_pid:-?}"

        if [[ -n "$bwrap_pid" ]] && kill -0 "$bwrap_pid" 2>/dev/null; then
            hw_pass "H2.3 bwrap PID ${bwrap_pid} alive"
        else
            hw_fail "H2.3 bwrap PID ${bwrap_pid:-<none>} not found"
        fi
        hw_dump_state
    else
        hw_warn "H2.3 slot 1 did not activate within 60s"
        hw_dump_state
        hw_dump_processes
    fi

    # --- H2.4 — splitscreen.properties ---
    hw_info "H2.4 — splitscreen.properties check"
    hw_assert_splitscreen_properties "H2.4" 1 "FULLSCREEN"

    # --- NO PROMPTS ---
    echo ""
    echo "=============================================="
    echo "  MINECRAFT IS RUNNING — OBSERVE AND REPORT"
    echo "=============================================="
    echo ""
    echo "  Tell Scott in chat:"
    echo "  1. Did Minecraft appear on screen? (fullscreen?)"
    echo "  2. Did Controlify detect the controller?"
    echo "  3. Do the built-in controls work as a gamepad?"
    echo "  4. Any keyboard/mouse conflict messages?"
    echo "  5. Did in-game quit work? Did it exit cleanly?"
    echo ""
    echo "  Wait for Minecraft to exit or press Ctrl+C here."
    echo ""
    echo "  PROCESS STATE:"
    echo "  bwrap PID: ${bwrap_pid:-unknown}"
    echo "  java PID:  ${java_pid:-unknown}"
    echo ""

    # --- Wait for orchestrator to exit naturally ---
    hw_info "H2.5 — Waiting for orchestrator to exit (operator quits Minecraft)"
    hw_log "Waiting for orchestrator PID ${HW_ORCH_PID} to exit..."
    wait "$HW_ORCH_PID" 2>/dev/null || true
    hw_log "Orchestrator exited"

    # --- H2.6 — Verify cleanup ---
    sleep 2
    hw_info "H2.6 — Verifying cleanup"

    local bwrap_procs
    bwrap_procs=$(pgrep -af 'bwrap.*latestUpdate' 2>/dev/null || true)
    hw_log "Orphan bwrap: ${bwrap_procs:-<none>}"
    hw_assert_empty "H2.6 no orphan bwrap" "$bwrap_procs"

    local java_procs
    java_procs=$(pgrep -af 'java.*SplitscreenP1' 2>/dev/null || true)
    hw_log "Orphan java: ${java_procs:-<none>}"
    hw_assert_empty "H2.6 no orphan java" "$java_procs"

    hw_dump_state
    hw_dump_processes
    hw_stop_orchestrator
    hw_info "Stage 2 complete."
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    run_stage2_handheld
fi
