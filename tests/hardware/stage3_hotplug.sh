#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 3: Docked Hot-Plug
# =============================================================================
# Tests controller hot-plug in docked mode: plug/unplug up to 4 controllers,
# verify sticky slots, layout changes, and placeholder windows.
#
# Automated checks per slot:
#   - State file shows slot active within 30s
#   - event_node/js_node recorded correctly
#   - SplitscreenPn window appears and is positioned at the correct grid cell
#   - splitscreen.properties written with correct mode (FULLSCREEN/TOP/BOTTOM/etc)
#
# Human-in-loop checks:
#   - Visual confirmation of each layout change
#   - Gameplay confirmation (each player can control their character)
#   - Sticky slot verification (unplugging keeps other slots alive)
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
    # Docked contract (owner decision, 2026-07-05): pads are plugged BEFORE launch.
    # The orchestrator's startup controller acquisition exits cleanly if no external
    # controller appears within its 5s window (you can't play docked on the built-in
    # pad), so the FIRST pad must already be connected when the orchestrator starts.
    # This stage therefore begins with exactly ONE pad connected; pads 2-4 still
    # exercise true hotplug against the running event loop.
    if ! hw_prompt "Connect the Steam Deck to a dock or hub with an HDMI or DisplayPort cable.
  The external display should now be active.
  Plug in exactly ONE external controller (USB or Bluetooth gamepad) NOW —
  docked launch requires a controller already connected (5s acquisition window).
  Ensure all OTHER external controllers are unplugged.
  Once the display is up and exactly one controller is connected, press Enter."; then
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

    # Capture external screen resolution
    local screen_res sw sh
    screen_res=$(hw_get_screen_resolution)
    sw="${screen_res%%x*}"
    sh="${screen_res##*x}"
    hw_log "D3.0 external screen resolution: ${screen_res} (${sw}×${sh})"

    # --- D3.1: Launch orchestrator in docked mode ---
    hw_info "D3.1 — Launching orchestrator in docked mode..."
    hw_launch_orchestrator docked

    hw_wait_for "D3.1 FIFO created" 10 test -p "${SPLITSCREEN_FIFO}"

    # (The old "zero active slots before any controller" assertion is gone: with the
    # pads-first contract the startup acquisition claims the already-connected pad
    # immediately, so slot 1 activating IS the expected launch state — checked in D3.2.)

    # --- D3.2: First controller (already connected — claimed by startup acquisition) ---
    hw_info "D3.2 — Waiting for slot 1 to become active (up to 30s)..."
    if hw_wait_for "D3.2 slot 1 active" 30 _slot_active 1; then
        hw_dump_state
        local ev1 js1
        ev1=$(jq -r '.slots["1"].event_node // "null"' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "null")
        js1=$(jq -r '.slots["1"].js_node    // "null"' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "null")
        hw_log "D3.2 slot 1: event_node=${ev1}  js_node=${js1}"
        hw_assert_nonempty "D3.2 slot 1 event_node recorded" "$ev1"

        # Automated: wait for window and verify geometry (1 player = fullscreen)
        hw_wait_for "D3.2 SplitscreenP1 window" 30 \
            bash -c "xdotool search --onlyvisible --name SplitscreenP1 >/dev/null 2>&1" || true

        local g_x g_y g_w g_h
        read -r g_x g_y g_w g_h < <(hw_expected_slot_geometry 1 "1" "$sw" "$sh")
        hw_assert_window_at "D3.2 P1 window position (1-player fullscreen)" \
            "SplitscreenP1" "$g_x" "$g_y" "$g_w" "$g_h" 50

        # Automated: properties file has FULLSCREEN mode
        hw_assert_splitscreen_properties "D3.2" 1 "FULLSCREEN"
    else
        hw_dump_state; hw_dump_processes
        hw_warn "D3.2 — slot 1 did not activate; checking input devices"
        hw_dump_input_devices
    fi

    # --- D3.3: Gameplay confirmation — 1 player ---
    if hw_prompt "P1's game should be fullscreen on the external display.
  Press Enter to start the D3.3 checklist, or type 'skip'."; then
        hw_checklist "D3.3 P1 fullscreen docked" \
            "P1 Minecraft window fills the entire external display" \
            "The game renders correctly (no black / corruption)" \
            "Moving the left stick on P1's controller rotates the view" \
            "No input from the BUILT-IN Steam Deck buttons affects P1"
    else
        hw_skip "D3.3 checklist skipped"
    fi

    # --- D3.4: Second controller ---
    if ! hw_prompt "Plug in a SECOND external controller.
  Wait 3 seconds after plugging it in, then press Enter."; then
        hw_skip "D3.4-D3.9 — operator skipped remaining controller tests"
        return 0
    fi

    hw_info "D3.4 — Waiting for slot 2 to become active (up to 30s)..."
    hw_wait_for "D3.4 slot 2 active" 30 _slot_active 2 || true
    hw_dump_state

    # Automated: verify window positions for 2-player (top/bottom)
    hw_wait_for "D3.4 SplitscreenP2 window" 20 \
        bash -c "xdotool search --onlyvisible --name SplitscreenP2 >/dev/null 2>&1" || true

    local g1_x g1_y g1_w g1_h  g2_x g2_y g2_w g2_h
    read -r g1_x g1_y g1_w g1_h < <(hw_expected_slot_geometry 1 "1 2" "$sw" "$sh")
    read -r g2_x g2_y g2_w g2_h < <(hw_expected_slot_geometry 2 "1 2" "$sw" "$sh")
    hw_assert_window_at "D3.4 P1 window (2-player top)"    "SplitscreenP1" "$g1_x" "$g1_y" "$g1_w" "$g1_h" 50
    hw_assert_window_at "D3.4 P2 window (2-player bottom)" "SplitscreenP2" "$g2_x" "$g2_y" "$g2_w" "$g2_h" 50
    hw_assert_splitscreen_properties "D3.4 slot 1" 1 "TOP"
    hw_assert_splitscreen_properties "D3.4 slot 2" 2 "BOTTOM"

    if hw_prompt "Two Minecraft instances should be visible (top=P1, bottom=P2).
  Press Enter to start the D3.4 checklist, or type 'skip'."; then
        hw_checklist "D3.4 2-player top/bottom split" \
            "External display shows TWO Minecraft windows stacked top/bottom" \
            "P1 (top half): moving left stick moves P1's view ONLY" \
            "P2 (bottom half): moving left stick on P2's controller moves P2's view ONLY" \
            "Neither player's input affects the other"
    else
        hw_skip "D3.4 checklist skipped"
    fi

    # --- D3.5: Third controller ---
    if ! hw_prompt "Plug in a THIRD external controller.
  Wait 3 seconds after plugging it in, then press Enter."; then
        hw_skip "D3.5-D3.9 — operator skipped"
        hw_stop_orchestrator; return 0
    fi

    hw_wait_for "D3.5 slot 3 active" 30 _slot_active 3 || true
    hw_dump_state

    # Automated: verify 3-player quad geometry
    hw_wait_for "D3.5 SplitscreenP3 window" 20 \
        bash -c "xdotool search --onlyvisible --name SplitscreenP3 >/dev/null 2>&1" || true

    local g3_x g3_y g3_w g3_h
    read -r g3_x g3_y g3_w g3_h < <(hw_expected_slot_geometry 3 "1 2 3" "$sw" "$sh")
    # Re-read P1 and P2 with quad geometry
    read -r g1_x g1_y g1_w g1_h < <(hw_expected_slot_geometry 1 "1 2 3" "$sw" "$sh")
    read -r g2_x g2_y g2_w g2_h < <(hw_expected_slot_geometry 2 "1 2 3" "$sw" "$sh")
    hw_assert_window_at "D3.5 P1 position (3-player quad top-left)"    "SplitscreenP1" "$g1_x" "$g1_y" "$g1_w" "$g1_h" 50
    hw_assert_window_at "D3.5 P2 position (3-player quad top-right)"   "SplitscreenP2" "$g2_x" "$g2_y" "$g2_w" "$g2_h" 50
    hw_assert_window_at "D3.5 P3 position (3-player quad bottom-left)" "SplitscreenP3" "$g3_x" "$g3_y" "$g3_w" "$g3_h" 50
    hw_assert_splitscreen_properties "D3.5 slot 1" 1 "TOP_LEFT"
    hw_assert_splitscreen_properties "D3.5 slot 2" 2 "TOP_RIGHT"
    hw_assert_splitscreen_properties "D3.5 slot 3" 3 "BOTTOM_LEFT"

    if hw_prompt "Three Minecraft instances + one black placeholder (bottom-right) should be visible.
  Press Enter for D3.5 checklist, or type 'skip'."; then
        hw_checklist "D3.5 3-player quad layout" \
            "Top-left=P1, top-right=P2, bottom-left=P3, bottom-right=BLACK placeholder" \
            "P1 left stick moves P1's view ONLY" \
            "P2 left stick moves P2's view ONLY" \
            "P3 left stick moves P3's view ONLY" \
            "Black placeholder (bottom-right) shows no Minecraft content"
    else
        hw_skip "D3.5 checklist skipped"
    fi

    # --- D3.6: Fourth controller ---
    if ! hw_prompt "Plug in a FOURTH external controller.
  Wait 3 seconds, then press Enter."; then
        hw_skip "D3.6-D3.9 — operator skipped"
        return 0
    fi

    hw_wait_for "D3.6 slot 4 active" 30 _slot_active 4 || true
    hw_dump_state

    # Automated: verify all 4 windows at quad positions
    hw_wait_for "D3.6 SplitscreenP4 window" 20 \
        bash -c "xdotool search --onlyvisible --name SplitscreenP4 >/dev/null 2>&1" || true

    local g4_x g4_y g4_w g4_h
    read -r g1_x g1_y g1_w g1_h < <(hw_expected_slot_geometry 1 "1 2 3 4" "$sw" "$sh")
    read -r g2_x g2_y g2_w g2_h < <(hw_expected_slot_geometry 2 "1 2 3 4" "$sw" "$sh")
    read -r g3_x g3_y g3_w g3_h < <(hw_expected_slot_geometry 3 "1 2 3 4" "$sw" "$sh")
    read -r g4_x g4_y g4_w g4_h < <(hw_expected_slot_geometry 4 "1 2 3 4" "$sw" "$sh")
    hw_assert_window_at "D3.6 P1 quad top-left"     "SplitscreenP1" "$g1_x" "$g1_y" "$g1_w" "$g1_h" 50
    hw_assert_window_at "D3.6 P2 quad top-right"    "SplitscreenP2" "$g2_x" "$g2_y" "$g2_w" "$g2_h" 50
    hw_assert_window_at "D3.6 P3 quad bottom-left"  "SplitscreenP3" "$g3_x" "$g3_y" "$g3_w" "$g3_h" 50
    hw_assert_window_at "D3.6 P4 quad bottom-right" "SplitscreenP4" "$g4_x" "$g4_y" "$g4_w" "$g4_h" 50
    hw_assert_splitscreen_properties "D3.6 slot 4" 4 "BOTTOM_RIGHT"

    if hw_prompt "All four Minecraft instances should be visible in a 2×2 grid.
  Press Enter for D3.6 checklist, or type 'skip'."; then
        hw_checklist "D3.6 4-player quad layout" \
            "Four Minecraft windows fill the external display in a 2×2 grid" \
            "P1 (top-left) responds to P1's controller ONLY" \
            "P2 (top-right) responds to P2's controller ONLY" \
            "P3 (bottom-left) responds to P3's controller ONLY" \
            "P4 (bottom-right) responds to P4's controller ONLY" \
            "No player's input bleeds into another player's game"
    else
        hw_skip "D3.6 checklist skipped"
    fi

    # --- D3.7: Controller disconnect (sticky slots) ---
    local slot2_event
    slot2_event=$(jq -r '.slots["2"].event_node // "null"' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "null")
    hw_log "D3.7 slot 2 event_node before disconnect: ${slot2_event}"

    if ! hw_prompt "UNPLUG the controller assigned to P2 (slot 2, top-right quadrant).
  Remember which controller it is so you can re-plug it later.
  Wait 3 seconds after unplugging, then press Enter."; then
        hw_skip "D3.7-D3.9 — operator skipped"
        return 0
    fi

    hw_info "D3.7 — Waiting for slot 2 to become inactive (up to 15s)..."
    hw_wait_for "D3.7 slot 2 inactive after disconnect" 15 \
        bash -c "jq -e '.slots[\"2\"].active == false' '${SPLITSCREEN_STATE}' >/dev/null 2>&1" || true

    hw_dump_state

    # Automated: verify slots 1, 3, 4 are still active (sticky)
    local s1_still s3_still s4_still
    s1_still=$(jq -r '.slots["1"].active' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "?")
    s3_still=$(jq -r '.slots["3"].active' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "?")
    s4_still=$(jq -r '.slots["4"].active' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "?")
    hw_log "D3.7 sticky: slot1=${s1_still} slot3=${s3_still} slot4=${s4_still}"
    hw_assert_eq "D3.7 slot 1 still active (sticky)" "true" "$s1_still"
    hw_assert_eq "D3.7 slot 3 still active (sticky)" "true" "$s3_still"
    hw_assert_eq "D3.7 slot 4 still active (sticky)" "true" "$s4_still"

    # Automated: P1, P3, P4 windows still at quad positions; P2 should be a placeholder (not a Minecraft window)
    read -r g1_x g1_y g1_w g1_h < <(hw_expected_slot_geometry 1 "1 2 3 4" "$sw" "$sh")
    read -r g3_x g3_y g3_w g3_h < <(hw_expected_slot_geometry 3 "1 2 3 4" "$sw" "$sh")
    read -r g4_x g4_y g4_w g4_h < <(hw_expected_slot_geometry 4 "1 2 3 4" "$sw" "$sh")
    hw_assert_window_at "D3.7 P1 still at top-left after P2 disconnect"    "SplitscreenP1" "$g1_x" "$g1_y" "$g1_w" "$g1_h" 50
    hw_assert_window_at "D3.7 P3 still at bottom-left after P2 disconnect" "SplitscreenP3" "$g3_x" "$g3_y" "$g3_w" "$g3_h" 50
    hw_assert_window_at "D3.7 P4 still at bottom-right after P2 disconnect" "SplitscreenP4" "$g4_x" "$g4_y" "$g4_w" "$g4_h" 50

    local p2_still_there
    p2_still_there=$(xdotool search --onlyvisible --name SplitscreenP2 2>/dev/null || true)
    hw_log "D3.7 SplitscreenP2 window after disconnect: '${p2_still_there:-<not found>}'"
    hw_assert_empty "D3.7 SplitscreenP2 Minecraft window gone after disconnect" "$p2_still_there"

    if hw_prompt "P1, P3, P4 should still be running. Top-right should be a black placeholder.
  Press Enter for D3.7 checklist, or type 'skip'."; then
        hw_checklist "D3.7 Sticky slots after P2 disconnect" \
            "P1 (top-left), P3 (bottom-left), P4 (bottom-right) are still running" \
            "Top-right shows a BLACK placeholder (empty, no Minecraft window)" \
            "P1 can still be controlled with P1's controller" \
            "Slot numbers did NOT re-shuffle (P3 is still bottom-left, not moved to top-right)"
    else
        hw_skip "D3.7 checklist skipped"
    fi

    # --- D3.8: Reconnect controller (slot 2 reuse) ---
    if ! hw_prompt "Re-plug the P2 controller you just disconnected.
  Wait 5 seconds for the new Minecraft instance to start, then press Enter."; then
        hw_skip "D3.8-D3.9 — operator skipped"
        return 0
    fi

    hw_info "D3.8 — Waiting for slot 2 to be reused (up to 20s)..."
    hw_wait_for "D3.8 slot 2 reactivated" 20 _slot_active 2 || true
    hw_dump_state

    hw_wait_for "D3.8 SplitscreenP2 window reappears" 20 \
        bash -c "xdotool search --onlyvisible --name SplitscreenP2 >/dev/null 2>&1" || true
    read -r g2_x g2_y g2_w g2_h < <(hw_expected_slot_geometry 2 "1 2 3 4" "$sw" "$sh")
    hw_assert_window_at "D3.8 P2 back at top-right after reconnect" "SplitscreenP2" "$g2_x" "$g2_y" "$g2_w" "$g2_h" 50
    hw_assert_splitscreen_properties "D3.8 slot 2 reused" 2 "TOP_RIGHT"

    if hw_prompt "Slot 2 (top-right) should now show a new Minecraft instance for P2.
  Press Enter for D3.8 checklist, or type 'skip'."; then
        hw_checklist "D3.8 Slot 2 reuse after reconnect" \
            "Top-right quadrant shows a new Minecraft instance (not black)" \
            "P2 controller controls the new top-right instance" \
            "All four slots are running (no black placeholder)"
    else
        hw_skip "D3.8 checklist skipped"
    fi

    # --- D3.9: Max-4 cap (optional) ---
    if hw_prompt "OPTIONAL: If you have a 5th controller available, plug it in now.
  Type 'skip' if you only have 4 controllers."; then
        sleep 5
        local count_after
        count_after=$(_active_slot_count)
        hw_log "D3.9 active slot count after 5th controller attempt: ${count_after}"
        hw_assert_eq "D3.9 still only 4 active slots (max cap enforced)" "4" "$count_after"
        local orch_log="${HW_LOG}.orch"
        if grep -q 'max 4\|Max 4\|No free slot' "${orch_log}" 2>/dev/null; then
            hw_pass "D3.9 orchestrator log confirms max-4 rejection"
        else
            hw_warn "D3.9 max-4 rejection not found in log — check orchestrator output manually"
        fi

        hw_checklist "D3.9 5th controller rejected" \
            "The 5th controller did NOT spawn a new Minecraft window" \
            "The existing 4 windows are unaffected"
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
