#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 3: Docked Hot-Plug
# =============================================================================
# Tests controller hot-plug in docked mode: plug/unplug up to 4 controllers,
# verify sticky slots, layout changes, and placeholder windows.
# Requires operator interaction and a dock + 2–4 external controllers.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$REPO_ROOT/modules/dock_detection.sh"
source "$REPO_ROOT/modules/instance_lifecycle.sh"

# Count currently active slots in the state file
_active_slot_count() {
    jq '[.slots[].active] | map(select(. == true)) | length' \
        "${SPLITSCREEN_STATE}" 2>/dev/null || echo "0"
}

# Check if a specific slot is active
_slot_active() {
    local slot="$1"
    jq -e ".slots[\"${slot}\"].active == true" "${SPLITSCREEN_STATE}" >/dev/null 2>&1
}

run_stage3_hotplug() {
    hw_section "Stage 3: Docked Hot-Plug"

    # --- D3.0: Confirm docked mode ---
    if ! hw_prompt "Connect the Steam Deck to a dock or hub with an HDMI or DisplayPort cable.
  The external display should now be active.
  IMPORTANT: Ensure ALL external controllers are UNPLUGGED before continuing.
  Once the external display is showing and controllers are unplugged, press Enter."; then
        hw_skip "D3.0-D3.9 — operator skipped docked mode setup"
        return 0
    fi

    local mode
    mode=$(get_display_mode 2>>"${HW_LOG}")
    hw_log "get_display_mode returned: ${mode}"
    hw_assert_eq "D3.0 display mode is docked" "docked" "$mode"

    if [[ "$mode" != "docked" ]]; then
        hw_fail "D3.0 — aborting stage 3: not in docked mode"
        return 0
    fi

    # --- D3.1: Launch orchestrator in docked mode ---
    hw_info "D3.1 — Launching orchestrator in docked mode..."
    hw_launch_orchestrator docked

    hw_wait_for "D3.1 FIFO created" 10 test -p "${SPLITSCREEN_FIFO}"

    # No controllers yet — no slots should be active
    sleep 2
    local initial_count
    initial_count=$(_active_slot_count)
    hw_log "D3.1 active slots at start: ${initial_count}"
    hw_assert_eq "D3.1 zero active slots before any controller" "0" "$initial_count"

    # --- D3.2: First controller ---
    if ! hw_prompt "Plug in ONE external controller (USB or Bluetooth gamepad).
  Wait 3 seconds after plugging it in, then press Enter."; then
        hw_skip "D3.2-D3.9 — operator skipped controller tests"
        hw_stop_orchestrator
        return 0
    fi

    hw_info "D3.2 — Waiting for slot 1 to become active (up to 30s)..."
    if hw_wait_for "D3.2 slot 1 active" 30 _slot_active 1; then
        hw_dump_state
        local ev1 js1
        ev1=$(jq -r '.slots["1"].event_node // "null"' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "null")
        js1=$(jq -r '.slots["1"].js_node    // "null"' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "null")
        hw_log "D3.2 slot 1: event_node=${ev1}  js_node=${js1}"
        hw_assert_nonempty "D3.2 slot 1 event_node recorded" "$ev1"
    else
        hw_dump_state; hw_dump_processes
        hw_warn "D3.2 — slot 1 did not activate; checking input devices"
        hw_dump_input_devices
    fi

    if hw_confirm "D3.3 Does the external display show ONE Minecraft instance running fullscreen (P1)?"; then
        hw_pass "D3.3 — operator confirmed P1 fullscreen on external display"
    else
        hw_fail "D3.3 — operator did not confirm P1 fullscreen"
    fi

    # --- D3.4: Second controller ---
    if ! hw_prompt "Plug in a SECOND external controller.
  Wait 3 seconds after plugging it in, then press Enter."; then
        hw_skip "D3.4-D3.9 — operator skipped remaining controller tests"
        hw_stop_orchestrator; return 0
    fi

    hw_info "D3.4 — Waiting for slot 2 to become active (up to 30s)..."
    hw_wait_for "D3.4 slot 2 active" 30 _slot_active 2 || true
    hw_dump_state

    if hw_confirm "D3.4 Does the display show TWO Minecraft instances (top-half P1, bottom-half P2)?"; then
        hw_pass "D3.4 — operator confirmed 2-player top/bottom split"
    else
        hw_fail "D3.4 — operator did not confirm 2-player layout"
    fi

    # --- D3.5: Third controller ---
    if ! hw_prompt "Plug in a THIRD external controller.
  Wait 3 seconds after plugging it in, then press Enter."; then
        hw_skip "D3.5-D3.9 — operator skipped"
        hw_stop_orchestrator; return 0
    fi

    hw_wait_for "D3.5 slot 3 active" 30 _slot_active 3 || true
    hw_dump_state

    if hw_confirm "D3.5 Does the display show THREE Minecraft instances (quad grid)?
  Top-left=P1, top-right=P2, bottom-left=P3, bottom-right=BLACK placeholder."; then
        hw_pass "D3.5 — operator confirmed 3-player quad with black placeholder"
    else
        hw_fail "D3.5 — operator did not confirm 3-player layout"
    fi

    # --- D3.6: Fourth controller ---
    if ! hw_prompt "Plug in a FOURTH external controller.
  Wait 3 seconds, then press Enter."; then
        hw_skip "D3.6-D3.9 — operator skipped"
        hw_stop_orchestrator; return 0
    fi

    hw_wait_for "D3.6 slot 4 active" 30 _slot_active 4 || true
    hw_dump_state

    if hw_confirm "D3.6 Does the display show FOUR Minecraft instances (2x2 quad grid, no placeholder)?"; then
        hw_pass "D3.6 — operator confirmed 4-player quad grid"
    else
        hw_fail "D3.6 — operator did not confirm 4-player layout"
    fi

    # --- D3.7: Controller disconnect (sticky slots) ---
    # Record which event_node is assigned to slot 2 before disconnect
    local slot2_event
    slot2_event=$(jq -r '.slots["2"].event_node // "null"' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "null")
    hw_log "D3.7 slot 2 event_node before disconnect: ${slot2_event}"

    if ! hw_prompt "UNPLUG the controller assigned to P2 (slot 2, top-right quadrant).
  Note which physical controller it is so you can re-plug it later.
  Wait 3 seconds after unplugging, then press Enter."; then
        hw_skip "D3.7-D3.9 — operator skipped"
        hw_stop_orchestrator; return 0
    fi

    hw_info "D3.7 — Waiting for slot 2 to become inactive (up to 15s)..."
    hw_wait_for "D3.7 slot 2 inactive after disconnect" 15 \
        bash -c "jq -e '.slots[\"2\"].active == false' '${SPLITSCREEN_STATE}' >/dev/null 2>&1" || true

    hw_dump_state

    # Verify other slots are still active (sticky slots)
    local s1_still s3_still s4_still
    s1_still=$(jq -r '.slots["1"].active' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "?")
    s3_still=$(jq -r '.slots["3"].active' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "?")
    s4_still=$(jq -r '.slots["4"].active' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "?")
    hw_log "D3.7 sticky slot check — slot1=${s1_still} slot3=${s3_still} slot4=${s4_still}"
    hw_assert_eq "D3.7 slot 1 still active (sticky)" "true" "$s1_still"
    hw_assert_eq "D3.7 slot 3 still active (sticky)" "true" "$s3_still"
    hw_assert_eq "D3.7 slot 4 still active (sticky)" "true" "$s4_still"

    if hw_confirm "D3.7 Are slots P1 (top-left), P3 (bottom-left), P4 (bottom-right) still running?
  And is top-right now a BLACK placeholder (not renumbered)?"; then
        hw_pass "D3.7 — operator confirmed sticky slots and black placeholder"
    else
        hw_fail "D3.7 — operator did not confirm sticky slot behaviour"
    fi

    # --- D3.8: Reconnect controller (slot reuse) ---
    if ! hw_prompt "Re-plug the controller you just disconnected (P2's controller).
  Wait 5 seconds, then press Enter."; then
        hw_skip "D3.8-D3.9 — operator skipped"
        hw_stop_orchestrator; return 0
    fi

    hw_info "D3.8 — Waiting for slot 2 to be reused (up to 20s)..."
    hw_wait_for "D3.8 slot 2 reactivated" 20 _slot_active 2 || true
    hw_dump_state

    if hw_confirm "D3.8 Is the top-right quadrant (slot 2 / P2) showing a new Minecraft instance?"; then
        hw_pass "D3.8 — operator confirmed slot reuse after reconnect"
    else
        hw_fail "D3.8 — operator did not confirm slot reuse"
    fi

    # --- D3.9: Max-4 cap (optional) ---
    if hw_prompt "OPTIONAL: If you have a 5th controller available, plug it in now.
  Type 'skip' if you only have 4 controllers."; then
        sleep 5
        local count_after
        count_after=$(_active_slot_count)
        hw_log "D3.9 active slot count after 5th controller attempt: ${count_after}"
        hw_assert_eq "D3.9 still only 4 active slots (max cap)" "4" "$count_after"
        # Check orchestrator log for max-4 message
        local orch_log="${HW_LOG}.orch"
        if grep -q 'max 4\|Max 4\|MAX_PLAYERS' "${orch_log}" 2>/dev/null; then
            hw_pass "D3.9 orchestrator log contains max-4 rejection message"
        else
            hw_warn "D3.9 max-4 rejection message not found in orchestrator log (may still be correct)"
        fi
    else
        hw_skip "D3.9 — max-4 cap test skipped (no 5th controller)"
    fi

    hw_dump_state
    hw_dump_processes
    hw_info "Stage 3 complete — orchestrator left running for stages 4 and 5"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S)-stage3.log"
    export REPO_ROOT
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0 HW_FAILED=0 HW_SKIPPED=0
    hw_detect_display
    run_stage3_hotplug
    hw_log "Stage 3: ${HW_PASSED} passed, ${HW_FAILED} failed, ${HW_SKIPPED} skipped — log: ${HW_LOG}"
    (( HW_FAILED == 0 )) && exit 0 || exit 1
fi
