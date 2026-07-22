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
    # I4.1 — game process holds only its own slot's /dev/input node(s)
    # -----------------------------------------------------------------------
    # #111: the old check counted /dev/input fds on the bwrap SUPERVISOR and
    # expected exactly 2 (an event+js pair). Both assumptions are wrong now:
    #   1. the device fds live in the JAVA child, not the bwrap supervisor
    #      (state: .slots[slot].pid is java, .slots[slot].bwrap_pid is bwrap);
    #   2. under the MCSS_RAW_BINDING=1 default only the jsN node is dev-bound
    #      (event+js only under the legacy virtual-mapper; a virtual pair under
    #      the future #38 uinput proxy) — so the count is mode-dependent.
    # Instead we read the ground-truth set of input nodes bwrap actually bound
    # for the slot from its argv (mode-agnostic), then assert the java process's
    # open /dev/input fds are non-empty (the game holds its controller) and all
    # within that bound set (no cross-slot leakage). Every path logs the java
    # pid, the bound nodes, and the observed fds so a Deck run is self-diagnosing.
    hw_info "I4.1 — Each game process holds only its own slot's /dev/input node(s)"

    local slot
    for slot in $active_slots_str; do
        hw_log "Checking /dev/input isolation for slot ${slot}"

        local bwrap_pid="" java_pid=""
        bwrap_pid=$(jq -r ".slots[\"${slot}\"].bwrap_pid // empty" "${SPLITSCREEN_STATE}" 2>/dev/null || true)
        java_pid=$(jq -r ".slots[\"${slot}\"].pid // empty" "${SPLITSCREEN_STATE}" 2>/dev/null || true)
        hw_log "Slot ${slot} bwrap_pid=${bwrap_pid:-<unset>} java_pid=${java_pid:-<unset>}"

        if [[ -z "$java_pid" ]]; then
            hw_warn "I4.1 Slot ${slot} has no java pid (.pid) in state file"
            hw_skip "I4.1 slot ${slot} input isolation — java pid not in state"
            continue
        fi
        if [[ ! -d "/proc/${java_pid}" ]]; then
            hw_warn "I4.1 Slot ${slot} java PID ${java_pid} no longer exists"
            hw_skip "I4.1 slot ${slot} input isolation — java process not running"
            continue
        fi
        if [[ ! -r "/proc/${java_pid}/fd" ]]; then
            hw_warn "I4.1 Cannot read /proc/${java_pid}/fd (permission denied?)"
            hw_skip "I4.1 slot ${slot} input isolation — /proc/${java_pid}/fd not readable"
            continue
        fi

        # Ground truth: input nodes bwrap bound for this slot, from its argv
        # (matches _build_bwrap_command's --dev-bind of the js/event node(s)).
        local bound_nodes="" bound_count=0
        if [[ -n "$bwrap_pid" && -r "/proc/${bwrap_pid}/cmdline" ]]; then
            bound_nodes=$(tr '\0' '\n' < "/proc/${bwrap_pid}/cmdline" 2>/dev/null \
                | grep -oE '/dev/input/(event|js)[0-9]+' | sort -u || true)
        fi
        [[ -n "$bound_nodes" ]] && bound_count=$(printf '%s\n' "$bound_nodes" | grep -c .)

        # Actual: the game process's open /dev/input fds.
        local fd_nodes="" fd_count=0
        fd_nodes=$(ls -la "/proc/${java_pid}/fd" 2>/dev/null \
            | grep -oE '/dev/input/(event|js)[0-9]+' | sort -u || true)
        [[ -n "$fd_nodes" ]] && fd_count=$(printf '%s\n' "$fd_nodes" | grep -c .)

        hw_log "Slot ${slot}: bwrap-bound input nodes (${bound_count}): ${bound_nodes//$'\n'/ }"
        hw_log "Slot ${slot}: java PID ${java_pid} open input fds (${fd_count}): ${fd_nodes//$'\n'/ }"

        # Isolation: every input fd the game holds must be one bwrap bound for THIS slot.
        local leaked="" n
        for n in $fd_nodes; do
            if ! grep -qxF "$n" <<<"$bound_nodes"; then
                leaked+="${n} "
            fi
        done

        if (( bound_count == 0 )); then
            hw_warn "I4.1 Slot ${slot} could not read bwrap argv (${bwrap_pid:-<unset>}) for the ground-truth bound set"
            hw_skip "I4.1 slot ${slot} input isolation — no bwrap-bound node list to check against"
        elif (( fd_count == 0 )); then
            hw_fail "I4.1 slot ${slot} game process (PID ${java_pid}) holds NO /dev/input fd (expected its bound jsN)"
        elif [[ -n "$leaked" ]]; then
            hw_fail "I4.1 slot ${slot} game holds input node(s) outside its bwrap binding: ${leaked}— leakage"
        else
            hw_pass "I4.1 slot ${slot} game input fds (${fd_count}) all within the slot's ${bound_count} bwrap-bound node(s); no leakage"
        fi
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
