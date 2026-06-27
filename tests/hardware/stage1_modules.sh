#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 1: Module Smoke Tests
# =============================================================================
# Automated — no operator interaction required.
# Sources the modules directly and calls their public API functions,
# checking outputs and exit codes without spawning real processes.
#
# Run standalone:
#   bash tests/hardware/stage1_modules.sh
# =============================================================================

_STAGE1_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Bootstrap when run standalone
if [[ -z "${HW_LOG:-}" ]]; then
    export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S).log"
    export REPO_ROOT="$(cd "$_STAGE1_SCRIPT_DIR/../.." && pwd)"
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0
    export HW_FAILED=0
    export HW_SKIPPED=0
fi

source "$_STAGE1_SCRIPT_DIR/lib/helpers.sh"
hw_detect_display

# ---------------------------------------------------------------------------
run_stage1_modules() {
    hw_section "Stage 1: Module Smoke Tests"

    # Source all modules into the current shell so we can call their functions
    hw_info "Sourcing modules from ${REPO_ROOT}/modules/"
    hw_log "Running: source ${REPO_ROOT}/modules/dock_detection.sh"
    source "${REPO_ROOT}/modules/dock_detection.sh"
    hw_log "Running: source ${REPO_ROOT}/modules/controller_monitor.sh"
    source "${REPO_ROOT}/modules/controller_monitor.sh"
    hw_log "Running: source ${REPO_ROOT}/modules/window_manager.sh"
    source "${REPO_ROOT}/modules/window_manager.sh"
    hw_log "Running: source ${REPO_ROOT}/modules/instance_lifecycle.sh"
    source "${REPO_ROOT}/modules/instance_lifecycle.sh"
    hw_info "All modules sourced successfully"

    # -----------------------------------------------------------------------
    # S1.1 — get_display_mode returns 'handheld' or 'docked'
    # -----------------------------------------------------------------------
    hw_info "S1.1 — get_display_mode returns a valid mode"
    hw_log "Running: get_display_mode"
    local display_mode=""
    display_mode=$(get_display_mode 2>>"${HW_LOG}" || true)
    hw_log "get_display_mode output: '${display_mode}'"
    hw_assert_match "S1.1 get_display_mode output" "^(handheld|docked)$" "$display_mode"

    # Save for use in S1.4
    local s1_1_mode="$display_mode"

    # -----------------------------------------------------------------------
    # S1.2 — list_eligible_controllers handheld returns exactly 1 line with /dev/input/event
    # -----------------------------------------------------------------------
    hw_info "S1.2 — list_eligible_controllers handheld returns exactly 1 line"
    hw_log "Running: list_eligible_controllers handheld"
    local handheld_controllers=""
    handheld_controllers=$(list_eligible_controllers handheld 2>>"${HW_LOG}" || true)
    hw_log "list_eligible_controllers handheld output:"
    hw_log "${handheld_controllers:-<empty>}"

    local handheld_line_count=0
    if [[ -n "$handheld_controllers" ]]; then
        handheld_line_count=$(echo "$handheld_controllers" | wc -l)
    fi
    hw_assert_eq "S1.2 handheld controller line count" "1" "$handheld_line_count"

    local handheld_first_line
    handheld_first_line=$(echo "$handheld_controllers" | head -1)
    hw_assert_match "S1.2 handheld controller line contains /dev/input/event" \
        "/dev/input/event" "$handheld_first_line"

    # -----------------------------------------------------------------------
    # S1.3 — list_eligible_controllers docked returns 0–4 lines, no error
    # -----------------------------------------------------------------------
    hw_info "S1.3 — list_eligible_controllers docked returns 0–4 lines with no error"
    hw_log "Running: list_eligible_controllers docked"
    local docked_controllers=""
    local docked_rc=0
    docked_controllers=$(list_eligible_controllers docked 2>>"${HW_LOG}") || docked_rc=$?
    hw_log "list_eligible_controllers docked output:"
    hw_log "${docked_controllers:-<empty (0 controllers, valid)>}"
    hw_log "Exit code: ${docked_rc}"

    if (( docked_rc == 0 )); then
        local docked_line_count=0
        if [[ -n "$docked_controllers" ]]; then
            docked_line_count=$(echo "$docked_controllers" | wc -l)
        fi
        hw_log "Docked controller count: ${docked_line_count}"
        if (( docked_line_count >= 0 && docked_line_count <= 4 )); then
            hw_pass "S1.3 list_eligible_controllers docked returned ${docked_line_count} line(s) (valid: 0–4)"
        else
            hw_fail "S1.3 list_eligible_controllers docked returned ${docked_line_count} line(s) — expected 0–4"
        fi
    else
        hw_fail "S1.3 list_eligible_controllers docked exited ${docked_rc} (expected 0)"
    fi

    # -----------------------------------------------------------------------
    # S1.4 — is_handheld / is_docked exit codes consistent with S1.1
    # -----------------------------------------------------------------------
    hw_info "S1.4 — is_handheld / is_docked exit codes consistent with get_display_mode"
    hw_log "Current mode from S1.1: ${s1_1_mode}"

    local is_handheld_rc=0
    local is_docked_rc=0
    set +e
    hw_log "Running: is_handheld"
    is_handheld 2>>"${HW_LOG}"
    is_handheld_rc=$?
    hw_log "Running: is_docked"
    is_docked 2>>"${HW_LOG}"
    is_docked_rc=$?
    set -e

    hw_log "is_handheld exit code: ${is_handheld_rc}"
    hw_log "is_docked exit code:   ${is_docked_rc}"

    if [[ "$s1_1_mode" == "handheld" ]]; then
        hw_assert_eq "S1.4 is_handheld() exits 0 when mode=handheld" "0" "$is_handheld_rc"
        hw_assert_eq "S1.4 is_docked() exits 1 when mode=handheld"   "1" "$is_docked_rc"
    else
        hw_assert_eq "S1.4 is_docked() exits 0 when mode=docked"   "0" "$is_docked_rc"
        hw_assert_eq "S1.4 is_handheld() exits 1 when mode=docked" "1" "$is_handheld_rc"
    fi

    # -----------------------------------------------------------------------
    # S1.5 — compute_grid_mode "1 2 3" returns "quad"
    # -----------------------------------------------------------------------
    hw_info "S1.5 — compute_grid_mode '1 2 3' returns 'quad'"
    hw_log "Running: compute_grid_mode '1 2 3'"
    local grid_mode_out=""
    grid_mode_out=$(compute_grid_mode "1 2 3" 2>>"${HW_LOG}" || true)
    hw_log "compute_grid_mode '1 2 3' output: '${grid_mode_out}'"
    hw_assert_eq "S1.5 compute_grid_mode '1 2 3'" "quad" "$grid_mode_out"

    # -----------------------------------------------------------------------
    # S1.6 — compute_slot_geometry 1 quad 1280 800 returns "0 0 640 400"
    # -----------------------------------------------------------------------
    hw_info "S1.6 — compute_slot_geometry 1 quad 1280 800 returns '0 0 640 400'"
    hw_log "Running: compute_slot_geometry 1 quad 1280 800"
    local geom_out=""
    geom_out=$(compute_slot_geometry 1 quad 1280 800 2>>"${HW_LOG}" || true)
    hw_log "compute_slot_geometry 1 quad 1280 800 output: '${geom_out}'"
    hw_assert_eq "S1.6 compute_slot_geometry 1 quad 1280 800" "0 0 640 400" "$geom_out"

    # -----------------------------------------------------------------------
    # S1.7 — update_slot_state 1 '{"active": true}' produces valid JSON with slot 1 active
    # -----------------------------------------------------------------------
    hw_info "S1.7 — update_slot_state writes valid JSON with slot 1 active (using temp state file)"

    # Use a temp file to avoid clobbering the real state
    local tmp_state
    tmp_state=$(mktemp --suffix=.json)
    hw_log "Using temp state file: ${tmp_state}"

    # Save original SPLITSCREEN_STATE and override
    local _orig_state="${SPLITSCREEN_STATE:-}"
    export SPLITSCREEN_STATE="$tmp_state"

    # Remove the tmp file so _ensure_state_file initializes it
    rm -f "$tmp_state"

    hw_log "Running: update_slot_state 1 '{\"active\": true}'"
    local update_rc=0
    update_slot_state 1 '{"active": true}' 2>>"${HW_LOG}" || update_rc=$?
    hw_log "update_slot_state exit code: ${update_rc}"

    if (( update_rc == 0 )); then
        hw_log "State file contents after update:"
        jq '.' "$tmp_state" 2>&1 | tee -a "${HW_LOG}"

        # Validate it's valid JSON
        local is_valid_json=0
        jq -e '.' "$tmp_state" >/dev/null 2>&1 && is_valid_json=1
        hw_assert_eq "S1.7 state file is valid JSON" "1" "$is_valid_json"

        # Validate slot 1 is active
        local slot1_active=""
        slot1_active=$(jq -r '.slots["1"].active' "$tmp_state" 2>/dev/null || true)
        hw_log "Slot 1 active value: '${slot1_active}'"
        hw_assert_eq "S1.7 slot 1 active == true" "true" "$slot1_active"
    else
        hw_fail "S1.7 update_slot_state failed with exit code ${update_rc}"
    fi

    # Restore original SPLITSCREEN_STATE and clean up
    export SPLITSCREEN_STATE="$_orig_state"
    rm -f "$tmp_state"

    # -----------------------------------------------------------------------
    # Final diagnostic dump
    # -----------------------------------------------------------------------
    hw_dump_state
    hw_dump_processes

    hw_info "Stage 1 complete."
}

# Run standalone if executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    run_stage1_modules
fi
