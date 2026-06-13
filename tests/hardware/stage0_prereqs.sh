#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 0: Prerequisites Check
# =============================================================================
# Automated — no operator interaction required.
# Verifies that the host environment has all tools, paths, and services
# needed before hardware tests can proceed.
#
# Run standalone:
#   bash tests/hardware/stage0_prereqs.sh
# =============================================================================

_STAGE0_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Bootstrap when run standalone
if [[ -z "${HW_LOG:-}" ]]; then
    export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S).log"
    export REPO_ROOT="$(cd "$_STAGE0_SCRIPT_DIR/../.." && pwd)"
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0
    export HW_FAILED=0
    export HW_SKIPPED=0
fi

source "$_STAGE0_SCRIPT_DIR/lib/helpers.sh"
hw_detect_display

# ---------------------------------------------------------------------------
run_stage0_prereqs() {
    hw_section "Stage 0: Prerequisites"
    local prereq_failed=0

    # -----------------------------------------------------------------------
    # P0.1 — Required commands present
    # -----------------------------------------------------------------------
    hw_info "P0.1 — Checking required commands"
    local required_cmds=(bwrap jq xdotool python3 busctl)
    for cmd in "${required_cmds[@]}"; do
        hw_log "Running: command -v ${cmd}"
        if command -v "$cmd" >/dev/null 2>&1; then
            hw_pass "P0.1 command '${cmd}' found at $(command -v "$cmd")"
        else
            hw_fail "P0.1 command '${cmd}' NOT FOUND in PATH"
            prereq_failed=1
        fi
    done

    # -----------------------------------------------------------------------
    # P0.2 — PolyMC instance directories exist
    # -----------------------------------------------------------------------
    hw_info "P0.2 — Checking PolyMC instance directories"
    local instance_ok=1
    for n in 1 2 3 4; do
        local idir="$HOME/.local/share/PolyMC/instances/latestUpdate-${n}"
        hw_log "Checking: ${idir}"
        if [[ -d "$idir" ]]; then
            hw_pass "P0.2 instance dir exists: ${idir}"
        else
            hw_fail "P0.2 instance dir MISSING: ${idir}"
            instance_ok=0
            prereq_failed=1
        fi
    done
    if (( instance_ok == 1 )); then
        hw_info "All 4 instance directories present"
    fi

    # -----------------------------------------------------------------------
    # P0.3 — PolyMC AppImage exists and is executable
    # -----------------------------------------------------------------------
    hw_info "P0.3 — Checking PolyMC AppImage"
    local appimage="$HOME/.local/share/PolyMC/PolyMC.AppImage"
    hw_log "Checking: ${appimage}"
    if [[ -f "$appimage" && -x "$appimage" ]]; then
        hw_pass "P0.3 PolyMC AppImage exists and is executable: ${appimage}"
    elif [[ -f "$appimage" ]]; then
        hw_fail "P0.3 PolyMC AppImage exists but is NOT executable: ${appimage}"
        prereq_failed=1
    else
        hw_fail "P0.3 PolyMC AppImage NOT FOUND: ${appimage}"
        prereq_failed=1
    fi

    # -----------------------------------------------------------------------
    # P0.4 — Steam is running
    # -----------------------------------------------------------------------
    hw_info "P0.4 — Checking Steam process"
    hw_log "Running: pgrep -af steam"
    local steam_pids
    steam_pids=$(pgrep -af steam 2>/dev/null || true)
    hw_log "Steam processes: ${steam_pids:-<none>}"
    if [[ -n "$steam_pids" ]]; then
        hw_pass "P0.4 Steam is running"
    else
        hw_fail "P0.4 Steam is NOT running (pgrep -af steam returned empty)"
        prereq_failed=1
    fi

    # -----------------------------------------------------------------------
    # P0.5 — At least one 28de:11ff device in /proc/bus/input/devices
    # -----------------------------------------------------------------------
    hw_info "P0.5 — Checking for 28de:11ff input devices"
    hw_log "Running: grep -c '28de' /proc/bus/input/devices (filtered to 11ff context)"
    local proc_path="/proc/bus/input/devices"
    local found_steam_device=0
    if [[ -f "$proc_path" ]]; then
        # Look for blocks containing both Vendor=28de and Product=11ff
        local match_count
        match_count=$(awk '
            /^$/ { if (vendor=="28de" && product=="11ff") count++; vendor=""; product="" }
            /Vendor=28de/ { vendor="28de" }
            /Product=11ff/ { product="11ff" }
            END { if (vendor=="28de" && product=="11ff") count++; print count+0 }
        ' "$proc_path" 2>/dev/null || echo 0)
        hw_log "Found ${match_count} 28de:11ff device(s) in ${proc_path}"
        if (( match_count > 0 )); then
            hw_pass "P0.5 Found ${match_count} Steam virtual gamepad device(s) (28de:11ff)"
            found_steam_device=1
        fi
    fi
    if (( found_steam_device == 0 )); then
        hw_fail "P0.5 No 28de:11ff devices found in /proc/bus/input/devices"
        prereq_failed=1
    fi

    # -----------------------------------------------------------------------
    # P0.6 — InputPlumber on D-Bus (WARN not FAIL)
    # -----------------------------------------------------------------------
    hw_info "P0.6 — Checking InputPlumber on D-Bus (non-fatal)"
    hw_log "Running: busctl list | grep -q InputPlumber"
    if busctl list 2>/dev/null | grep -q InputPlumber; then
        hw_pass "P0.6 InputPlumber found on D-Bus"
    else
        hw_warn "P0.6 InputPlumber NOT found on D-Bus — controller identification may fall back to enumeration"
        hw_skip "P0.6 InputPlumber not present (non-fatal)"
    fi

    # -----------------------------------------------------------------------
    # P0.7 — Display is reachable via xdotool
    # -----------------------------------------------------------------------
    hw_info "P0.7 — Checking display reachability"
    hw_log "Running: DISPLAY=${DISPLAY:-:0} xdotool getactivewindow"
    local xdotool_out
    xdotool_out=$(DISPLAY="${DISPLAY:-:0}" xdotool getactivewindow 2>&1 || true)
    hw_log "xdotool output: ${xdotool_out}"
    if DISPLAY="${DISPLAY:-:0}" xdotool getactivewindow >/dev/null 2>&1; then
        hw_pass "P0.7 Display ${DISPLAY:-:0} is reachable via xdotool"
    else
        hw_fail "P0.7 xdotool getactivewindow failed on DISPLAY=${DISPLAY:-:0}"
        prereq_failed=1
    fi

    # -----------------------------------------------------------------------
    # P0.8 — Orchestrator script passes bash -n syntax check
    # -----------------------------------------------------------------------
    hw_info "P0.8 — Syntax check on orchestrator script"
    local orch_script="${REPO_ROOT}/minecraftSplitscreen.sh"
    hw_log "Running: bash -n ${orch_script}"
    local bash_n_out
    bash_n_out=$(bash -n "$orch_script" 2>&1 || true)
    hw_log "bash -n output: ${bash_n_out:-<none>}"
    if bash -n "$orch_script" 2>/dev/null; then
        hw_pass "P0.8 ${orch_script} passes bash -n syntax check"
    else
        hw_fail "P0.8 ${orch_script} FAILED bash -n: ${bash_n_out}"
        prereq_failed=1
    fi

    # -----------------------------------------------------------------------
    # Final verdict
    # -----------------------------------------------------------------------
    hw_dump_input_devices
    hw_dump_processes

    if (( prereq_failed == 1 )); then
        hw_log ""
        hw_log "ABORT: Prerequisites failed — fix above before running hardware tests"
        return 1
    fi

    hw_info "All critical prerequisites passed."
    return 0
}

# Run standalone if executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    run_stage0_prereqs || exit 1
fi
