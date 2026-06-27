#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 4: Controller Isolation Verification
# =============================================================================
# Semi-automated. Tests that bwrap sandboxing prevents cross-instance input
# leakage. Requires active instances from a previous stage (stage3) or that
# the operator has already launched the orchestrator with instances running.
#
# Run standalone:
#   bash tests/hardware/stage4_isolation.sh
# =============================================================================

_STAGE4_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Bootstrap when run standalone
if [[ -z "${HW_LOG:-}" ]]; then
    export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S).log"
    export REPO_ROOT="$(cd "$_STAGE4_SCRIPT_DIR/../.." && pwd)"
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0
    export HW_FAILED=0
    export HW_SKIPPED=0
fi

source "$_STAGE4_SCRIPT_DIR/lib/helpers.sh"
hw_detect_display

# ---------------------------------------------------------------------------
run_stage4_isolation() {
    hw_section "Stage 4: Controller Isolation Verification"

    # -----------------------------------------------------------------------
    # Pre-check: need active instances
    # -----------------------------------------------------------------------
    hw_info "Checking for active instances in state file"
    hw_log "Running: jq -r '[.slots[].active] | any' '${SPLITSCREEN_STATE}'"

    local any_active="false"
    if [[ -f "${SPLITSCREEN_STATE}" ]]; then
        any_active=$(jq -r '[.slots[].active] | any | tostring' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "false")
    fi
    hw_log "Any slots active: ${any_active}"

    if [[ "$any_active" != "true" ]]; then
        hw_warn "No active instances found. Stage 4 requires running Minecraft instances."
        hw_warn "If you ran stage3, the orchestrator should already be running."
        hw_warn "If running standalone, launch the orchestrator manually first."
        hw_skip "Stage 4 skipped — no active instances"
        hw_dump_state
        return 0
    fi

    # Collect active slots
    hw_log "Running: jq -r '[.slots | to_entries[] | select(.value.active == true) | .key] | join(\" \")' '${SPLITSCREEN_STATE}'"
    local active_slots_str=""
    active_slots_str=$(jq -r \
        '[.slots | to_entries[] | select(.value.active == true) | .key] | join(" ")' \
        "${SPLITSCREEN_STATE}" 2>/dev/null || true)
    hw_log "Active slots: ${active_slots_str}"

    # -----------------------------------------------------------------------
    # I4.1 — bwrap fd count per instance
    # -----------------------------------------------------------------------
    hw_info "I4.1 — Verify each bwrap process has exactly 2 /dev/input file descriptors"

    local slot
    for slot in $active_slots_str; do
        hw_log "Checking bwrap fd count for slot ${slot}"

        local bwrap_pid=""
        bwrap_pid=$(jq -r ".slots[\"${slot}\"].bwrap_pid // empty" "${SPLITSCREEN_STATE}" 2>/dev/null || true)
        hw_log "Slot ${slot} bwrap_pid: ${bwrap_pid:-<not set>}"

        if [[ -z "$bwrap_pid" ]]; then
            hw_warn "I4.1 Slot ${slot} has no bwrap_pid in state file"
            hw_skip "I4.1 slot ${slot} bwrap fd count — bwrap_pid not in state"
            continue
        fi

        if [[ ! -d "/proc/${bwrap_pid}" ]]; then
            hw_warn "I4.1 Slot ${slot} bwrap PID ${bwrap_pid} no longer exists"
            hw_skip "I4.1 slot ${slot} bwrap fd count — process not running"
            continue
        fi

        hw_log "Running: ls -la /proc/${bwrap_pid}/fd | grep -oE '/dev/input/event[0-9]+|/dev/input/js[0-9]+' | sort -u | wc -l"
        local input_fds=0
        if [[ -d "/proc/${bwrap_pid}/fd" ]]; then
            input_fds=$(ls -la "/proc/${bwrap_pid}/fd" 2>/dev/null \
                | grep -oE '/dev/input/event[0-9]+|/dev/input/js[0-9]+' \
                | sort -u | wc -l || echo 0)
        else
            hw_warn "I4.1 Cannot read /proc/${bwrap_pid}/fd (permission denied?)"
            hw_skip "I4.1 slot ${slot} bwrap fd count — /proc/${bwrap_pid}/fd not readable"
            continue
        fi

        hw_log "Slot ${slot} bwrap PID ${bwrap_pid}: unique /dev/input device fds = ${input_fds}"
        hw_assert_eq "I4.1 slot ${slot} bwrap /dev/input unique device count" "2" "$input_fds"
    done

    # -----------------------------------------------------------------------
    # I4.2 — Event nodes are unique per slot
    # -----------------------------------------------------------------------
    hw_info "I4.2 — Verify event nodes are unique across active slots"

    local -A seen_event_nodes
    local duplicates_found=0

    for slot in $active_slots_str; do
        local event_node=""
        event_node=$(jq -r ".slots[\"${slot}\"].event_node // empty" "${SPLITSCREEN_STATE}" 2>/dev/null || true)
        hw_log "Slot ${slot} event_node: ${event_node:-<not set>}"

        if [[ -z "$event_node" ]]; then
            hw_warn "I4.2 Slot ${slot} has no event_node in state file"
            continue
        fi

        if [[ -n "${seen_event_nodes[$event_node]:-}" ]]; then
            hw_fail "I4.2 Duplicate event_node '${event_node}' found in slots ${seen_event_nodes[$event_node]} and ${slot}"
            duplicates_found=1
        else
            seen_event_nodes["$event_node"]="$slot"
        fi
    done

    if (( duplicates_found == 0 )); then
        hw_pass "I4.2 All active slots have unique event_node values"
    fi

    # -----------------------------------------------------------------------
    # I4.3 — Operator cross-input check
    # -----------------------------------------------------------------------
    hw_info "I4.3 — Operator cross-input check"

    if hw_prompt "In one Minecraft instance, navigate to Settings → Controls.
           Then press a button on the controller assigned to a DIFFERENT instance.
           The controls settings in the first instance should NOT respond to the other controller.
           Confirm there is no cross-input leakage.
           Press Enter to confirm, or type 'skip' to skip this check."; then

        if hw_confirm "Did the first instance's Controls screen stay unresponsive to the other controller? [y/N]"; then
            hw_pass "I4.3 Operator confirmed no cross-input leakage between instances"
        else
            hw_fail "I4.3 Operator reported cross-input leakage detected"
            hw_dump_state
            hw_dump_processes
        fi
    else
        hw_skip "I4.3 Cross-input check skipped by operator"
    fi

    # -----------------------------------------------------------------------
    # I4.4 — /dev/input visible in bwrap namespace (requires nsenter + root)
    # -----------------------------------------------------------------------
    hw_info "I4.4 — Verify /dev/input namespace isolation via nsenter (requires root)"

    # Get slot 1's bwrap PID
    local slot1_bwrap_pid=""
    slot1_bwrap_pid=$(jq -r '.slots["1"].bwrap_pid // empty' "${SPLITSCREEN_STATE}" 2>/dev/null || true)
    hw_log "Slot 1 bwrap_pid: ${slot1_bwrap_pid:-<not set>}"

    if [[ -z "$slot1_bwrap_pid" ]]; then
        hw_skip "I4.4 Slot 1 has no bwrap_pid — skipping namespace check"
    elif ! command -v nsenter >/dev/null 2>&1; then
        hw_skip "I4.4 nsenter not available — skipping namespace check"
    elif [[ "$(id -u)" != "0" ]]; then
        hw_warn "I4.4 nsenter requires root — running as $(id -u), skipping"
        hw_skip "I4.4 nsenter requires root — skipping namespace check (run as root to enable)"
    elif [[ ! -d "/proc/${slot1_bwrap_pid}" ]]; then
        hw_skip "I4.4 Slot 1 bwrap PID ${slot1_bwrap_pid} is not running — skipping"
    else
        hw_log "Running: nsenter -t ${slot1_bwrap_pid} --mount -- ls /dev/input/"
        local ns_output=""
        ns_output=$(nsenter -t "${slot1_bwrap_pid}" --mount -- ls /dev/input/ 2>/dev/null || true)
        hw_log "nsenter /dev/input/ output for slot 1 bwrap (PID ${slot1_bwrap_pid}):"
        hw_log "${ns_output:-<empty output>}"
        echo "$ns_output" | tee -a "${HW_LOG}" || true

        # Expect to see only the 2 nodes bound for slot 1
        local ns_node_count=0
        ns_node_count=$(echo "$ns_output" | grep -c 'event\|js' 2>/dev/null || echo 0)
        hw_log "Node count in bwrap namespace: ${ns_node_count}"

        if (( ns_node_count > 0 && ns_node_count <= 2 )); then
            hw_pass "I4.4 bwrap namespace for slot 1 shows ${ns_node_count} /dev/input node(s) (expected 1–2)"
        elif (( ns_node_count == 0 )); then
            hw_warn "I4.4 No /dev/input nodes visible in bwrap namespace (may be expected)"
            hw_skip "I4.4 namespace isolation check inconclusive"
        else
            hw_fail "I4.4 bwrap namespace for slot 1 shows ${ns_node_count} /dev/input nodes (expected <= 2)"
        fi
    fi

    # -----------------------------------------------------------------------
    # Final dumps
    # -----------------------------------------------------------------------
    hw_dump_state
    hw_dump_processes

    hw_info "Stage 4 complete."
}

# Run standalone if executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    run_stage4_isolation
fi
