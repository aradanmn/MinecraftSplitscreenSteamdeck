#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 5: Crash Recovery Test
# =============================================================================
# Mostly automated. Tests watchdog-triggered crash recovery.
# Requires: orchestrator running with at least 2 active instances.
#
# Run standalone:
#   bash tests/hardware/stage5_crash.sh
# =============================================================================

_STAGE5_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Bootstrap when run standalone
if [[ -z "${HW_LOG:-}" ]]; then
    export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S).log"
    export REPO_ROOT="$(cd "$_STAGE5_SCRIPT_DIR/../.." && pwd)"
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0
    export HW_FAILED=0
    export HW_SKIPPED=0
fi

source "$_STAGE5_SCRIPT_DIR/lib/helpers.sh"
hw_detect_display

# ---------------------------------------------------------------------------
run_stage5_crash() {
    hw_section "Stage 5: Crash Recovery"

    # -----------------------------------------------------------------------
    # C5.1 — Requires 2+ active instances
    # -----------------------------------------------------------------------
    hw_info "C5.1 — Checking for at least 2 active instances"

    # Helper: count active slots
    _count_active_slots() {
        if [[ ! -f "${SPLITSCREEN_STATE}" ]]; then
            echo "0"
            return 0
        fi
        jq -r '[.slots | to_entries[] | select(.value.active == true)] | length' \
            "${SPLITSCREEN_STATE}" 2>/dev/null || echo "0"
    }

    local active_count=0
    active_count=$(_count_active_slots)
    hw_log "Active slot count: ${active_count}"

    if (( active_count < 2 )); then
        hw_warn "C5.1 Only ${active_count} active slot(s) — need at least 2 for crash tests"
        hw_warn "Please ensure the orchestrator is running and at least 2 controllers are plugged in."

        if hw_prompt "Plug in at least 2 controllers to get 2 active Minecraft instances.
           Wait up to 30 seconds for them to start.
           Press Enter when done, or type 'skip' to skip this stage."; then

            hw_wait_for "C5.1 at least 2 active slots" 30 \
                bash -c "
                    count=\$(jq -r '[.slots | to_entries[] | select(.value.active == true)] | length' '${SPLITSCREEN_STATE}' 2>/dev/null || echo 0)
                    (( count >= 2 ))
                " || true

            active_count=$(_count_active_slots)
            hw_log "Active slot count after wait: ${active_count}"
        else
            hw_skip "Stage 5 skipped by operator"
            return 0
        fi
    fi

    if (( active_count < 2 )); then
        hw_warn "C5.1 Still only ${active_count} active slot(s) after waiting — skipping stage 5"
        hw_skip "C5.1 Insufficient active instances for crash tests"
        hw_dump_state
        return 0
    fi

    hw_pass "C5.1 ${active_count} active slots found — proceeding with crash tests"
    hw_dump_state

    # -----------------------------------------------------------------------
    # C5.2 — Kill Java process for slot 2 (simulate crash)
    # -----------------------------------------------------------------------
    hw_info "C5.2 — Simulating Java crash: killing Java PID for slot 2"

    local java_pid_2=""
    java_pid_2=$(jq -r '.slots["2"].pid // empty' "${SPLITSCREEN_STATE}" 2>/dev/null || true)
    hw_log "Slot 2 Java PID: ${java_pid_2:-<not set>}"

    if [[ -z "$java_pid_2" ]]; then
        hw_warn "C5.2 Slot 2 has no Java PID in state file — cannot simulate crash"
        hw_skip "C5.2 Slot 2 Java PID not in state file"
    else
        hw_log "Running: kill -9 ${java_pid_2}"
        kill -9 "$java_pid_2" 2>/dev/null || true
        hw_info "Sent SIGKILL to Java PID ${java_pid_2} for slot 2"

        hw_log "Running: jq -e '.slots[\"2\"].active == false' '${SPLITSCREEN_STATE}'"
        if hw_wait_for "C5.2 slot 2 cleared by watchdog after Java kill" 30 \
            jq -e '.slots["2"].active == false' "${SPLITSCREEN_STATE}"; then

            hw_info "C5.2 Watchdog detected and cleared slot 2 crash successfully"
            hw_dump_state
        else
            hw_fail "C5.2 Watchdog did not clear slot 2 within 30s — watchdog may not be running"
            hw_dump_state
            hw_dump_processes

            # Check orchestrator log for watchdog activity
            local orch_log="${HW_LOG}.orch"
            if [[ -f "$orch_log" ]]; then
                hw_log "Checking orchestrator log for watchdog entries:"
                grep -i 'watchdog\|SLOT_DIED\|dead\|died' "$orch_log" 2>/dev/null | \
                    tee -a "${HW_LOG}" || true
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # C5.3 — Slot 2 shows black placeholder after crash
    # -----------------------------------------------------------------------
    hw_info "C5.3 — Operator confirmation: slot 2 shows black placeholder"

    if hw_prompt "Slot 2 (top-right quadrant in 2+ player layout) should now show a BLACK placeholder.
           Slot 1 should still be running normally.
           Confirm this is what you see.
           Press Enter to confirm, or type 'skip' to skip this check."; then

        if hw_confirm "Does slot 2 show a black placeholder with slot 1 still running? [y/N]"; then
            hw_pass "C5.3 Operator confirmed slot 2 shows black placeholder after crash"
        else
            hw_fail "C5.3 Operator reported slot 2 crash recovery NOT displayed correctly"
            hw_dump_state
            hw_dump_processes
        fi
    else
        hw_skip "C5.3 Visual confirmation skipped by operator"
    fi

    # -----------------------------------------------------------------------
    # C5.4 — Kill bwrap process for slot 1 (simulate crash at sandbox level)
    # -----------------------------------------------------------------------
    hw_info "C5.4 — Simulating bwrap crash: killing bwrap PID for slot 1"

    # Re-read state in case it changed
    local bwrap_pid_1=""
    bwrap_pid_1=$(jq -r '.slots["1"].bwrap_pid // empty' "${SPLITSCREEN_STATE}" 2>/dev/null || true)
    hw_log "Slot 1 bwrap PID: ${bwrap_pid_1:-<not set>}"

    if [[ -z "$bwrap_pid_1" ]]; then
        hw_warn "C5.4 Slot 1 has no bwrap_pid in state file — cannot simulate bwrap crash"
        hw_skip "C5.4 Slot 1 bwrap PID not in state file"
    else
        hw_log "Running: kill -9 ${bwrap_pid_1}"
        kill -9 "$bwrap_pid_1" 2>/dev/null || true
        hw_info "Sent SIGKILL to bwrap PID ${bwrap_pid_1} for slot 1"

        hw_log "Running: jq -e '.slots[\"1\"].active == false' '${SPLITSCREEN_STATE}'"
        if hw_wait_for "C5.4 slot 1 cleared by watchdog after bwrap kill" 30 \
            jq -e '.slots["1"].active == false' "${SPLITSCREEN_STATE}"; then

            hw_info "C5.4 Watchdog detected and cleared slot 1 bwrap crash"
            hw_dump_state
        else
            hw_fail "C5.4 Watchdog did not clear slot 1 within 30s after bwrap kill"
            hw_dump_state
            hw_dump_processes
        fi
    fi

    # -----------------------------------------------------------------------
    # C5.5 — Orchestrator still running after crash
    # -----------------------------------------------------------------------
    hw_info "C5.5 — Verifying orchestrator is still alive after induced crashes"

    hw_log "HW_ORCH_PID: ${HW_ORCH_PID:-<not set>}"

    if [[ -z "${HW_ORCH_PID:-}" ]]; then
        hw_warn "C5.5 HW_ORCH_PID not set — cannot verify orchestrator is running"
        hw_skip "C5.5 orchestrator PID unknown (run via run_all.sh to track PID)"
    else
        hw_log "Running: kill -0 ${HW_ORCH_PID}"
        local orch_alive_rc=0
        kill -0 "${HW_ORCH_PID}" 2>/dev/null || orch_alive_rc=$?
        hw_log "kill -0 ${HW_ORCH_PID} exit code: ${orch_alive_rc}"
        hw_assert_eq "C5.5 orchestrator PID ${HW_ORCH_PID} still alive after crashes" "0" "$orch_alive_rc"
    fi

    # -----------------------------------------------------------------------
    # C5.6 — Slot can be reused after crash (plug new controller)
    # -----------------------------------------------------------------------
    hw_info "C5.6 — Verify slot reuse after crash recovery"

    if hw_prompt "Plug in a controller. It should spawn a new Minecraft instance
           in one of the cleared slots (slot 1 or slot 2).
           Press Enter when done, or type 'skip' to skip this check."; then

        hw_log "Running: jq -e '[.slots[].active] | any' '${SPLITSCREEN_STATE}'"
        if hw_wait_for "C5.6 any slot becomes active after controller plug-in" 30 \
            jq -e '[.slots[].active] | any' "${SPLITSCREEN_STATE}"; then

            hw_info "C5.6 A slot became active after crash recovery"
            hw_dump_state

            if hw_confirm "Did a new Minecraft instance appear in one of the cleared slots? [y/N]"; then
                hw_pass "C5.6 Operator confirmed slot reuse after crash recovery"
            else
                hw_fail "C5.6 Operator reported slot reuse did NOT work after crash"
                hw_dump_state
                hw_dump_processes
            fi
        else
            hw_fail "C5.6 No slot became active within 30s after controller plug-in"
            hw_dump_state
            hw_dump_processes
        fi
    else
        hw_skip "C5.6 Slot reuse after crash skipped by operator"
    fi

    # -----------------------------------------------------------------------
    # Final dumps and cleanup
    # -----------------------------------------------------------------------
    hw_dump_state
    hw_dump_processes

    # Stop orchestrator if we're running from run_all.sh (it manages cleanup)
    if [[ -n "${HW_ORCH_PID:-}" ]]; then
        hw_stop_orchestrator
    fi

    hw_info "Stage 5 complete."
}

# Run standalone if executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    run_stage5_crash
fi
