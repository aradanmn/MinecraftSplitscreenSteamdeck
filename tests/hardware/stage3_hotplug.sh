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
#
# #136 PR-3: MCSS_VIRTUAL_PADS=1 drives every "plug in a controller" step
# below with tests/lib/uhid_rig.sh virtual pads instead of an operator's
# physical gamepads. DEFAULT (unset/0) is UNCHANGED — every human-mode
# branch below is the exact code this stage shipped with before the flag
# existed; the virtual path is an added `if`/`elif` arm, never a rewrite of
# the human one. Gameplay/visual checklists have no automated equivalent
# (no human pilot), so they hw_skip in virtual mode and point back at the
# automated geometry/property assertions that already ran. The dock/display
# itself is still real hardware — this flag removes the CONTROLLERS from the
# loop, not the Deck or the external display.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"
# #50 loading-order rule: runtime_context resolves+exports the shared globals
# (SPLITSCREEN_STATE, MCSS_STATE_LOCK, MCSS_ENV_CONTEXT) that other modules
# bare-read; it must source before any of them (caught by stage1 on-Deck:
# update_slot_state died on an unset global under set -u).
source "$REPO_ROOT/modules/runtime_context.sh"
source "$REPO_ROOT/modules/dock_detection.sh"
source "$REPO_ROOT/modules/instance_lifecycle.sh"

# #136 PR-3: only pull in the rig + its enumerator dependency when the flag
# is live, so the human-mode default sources the exact same file set as
# before this PR (no footprint change when off).
if [[ "${MCSS_VIRTUAL_PADS:-0}" == "1" ]]; then
    source "$REPO_ROOT/tests/lib/uhid_rig.sh"
    # rig_wait_for_pad/rig_wait_for_pad_gone poll _list_raw_external_pads
    # (ARCHITECTURE.md §2 — the rig never re-implements enumeration itself).
    source "$REPO_ROOT/modules/controller_monitor.sh"
fi

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

# --- #136 PR-3: virtual-pad mode helpers ------------------------------------

# _stage3_virtual_mode: predicate, no stdout.
_stage3_virtual_mode() { [[ "${MCSS_VIRTUAL_PADS:-0}" == "1" ]]; }

# _stage3_virtual_connect: rig_create_pad N, then wait for the PRODUCTION
# enumerator (not just the rig's own process) to see it — the virtual-mode
# replacement for "operator plugs in controller N, waits 3s". ORDINAL is
# used only in the log line.
# Inputs:  $1 — pad index, $2 — ordinal for the log line, $3 — optional
#   enumerator-wait timeout_s (default 10).
# Outputs: return — 0 pad live and enumerated, 1 create or enumerate failed.
_stage3_virtual_connect() {
    local n="$1" ordinal="$2" wait_s="${3:-10}"
    hw_info "creating virtual pad $n ($ordinal, MCSS_VIRTUAL_PADS=1)..."
    if ! rig_create_pad "$n"; then
        hw_fail "virtual pad $n failed to create"
        return 1
    fi
    if ! rig_wait_for_pad "$n" "$wait_s"; then
        hw_fail "virtual pad $n did not reach the production enumerator within ${wait_s}s"
        return 1
    fi
    return 0
}

# _stage3_skip_checklist_if_virtual: in virtual-pad mode there is no human
# pilot to confirm gameplay/visual state, so every checklist becomes an
# hw_skip pointing back at the automated geometry/property assertions that
# already ran for that step. Returns 1 (do nothing) in human mode so callers
# fall through to their original hw_prompt/hw_checklist branch, untouched.
# Inputs:  $1 — the skip label to log.
# Outputs: return — 0 handled (virtual mode), 1 not virtual mode.
_stage3_skip_checklist_if_virtual() {
    local label="$1"
    _stage3_virtual_mode || return 1
    hw_skip "${label} — virtual-pad mode, no human pilot to confirm (automated checks above cover this step)"
    return 0
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
    if _stage3_virtual_mode; then
        if ! rig_init; then
            hw_fail "D3.0 — rig_init failed (MCSS_VIRTUAL_PADS=1); see stderr above"
            return 0
        fi
        # EXIT/INT/TERM cleanup for the whole process, not just this function —
        # run_all.sh sources every stage into ONE shell, and stage 3's pads must
        # stay alive through stages 4-5 (same contract as physical controllers),
        # so per-return cleanup here would be wrong; only a real process exit
        # should reap them. Refusal (rc 1) means something upstream already owns
        # these signals — rig_cleanup then only runs at the natural end of this
        # function's own explicit calls, logged so it's not a silent gap.
        rig_install_traps || hw_warn "D3.0 rig_install_traps refused (a trap already existed) — pads will only be cleaned up where this stage calls rig_cleanup explicitly"
        if ! hw_prompt "Connect the Steam Deck to a dock or hub with an HDMI or DisplayPort cable.
  The external display should now be active.
  MCSS_VIRTUAL_PADS=1 — controllers are virtual uhid pads, not physical.
  Once the display is up, press Enter."; then
            hw_skip "D3.0-D3.9 — operator skipped docked mode setup"
            rig_cleanup
            return 0
        fi
        if ! _stage3_virtual_connect 1 "FIRST" 30; then
            hw_fail "D3.0 — aborting stage 3: virtual pad 1 failed to enumerate"
            rig_cleanup
            return 0
        fi
    elif ! hw_prompt "Connect the Steam Deck to a dock or hub with an HDMI or DisplayPort cable.
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
        if _stage3_virtual_mode; then
            rig_cleanup
        fi
        return 0
    fi

    # (Screen resolution is captured in D3.2, after the session is up — before
    # launch there is no nested root to measure and the fallback ambient display
    # reports the wrong tiling space.)
    local screen_res sw sh

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
        screen_res=$(hw_get_screen_resolution)
        sw="${screen_res%%x*}"; sh="${screen_res##*x}"
        hw_log "D3.2 nested tiling area: ${screen_res} (${sw}×${sh})"
        local ev1 js1
        ev1=$(jq -r '.slots["1"].event_node // "null"' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "null")
        js1=$(jq -r '.slots["1"].js_node    // "null"' "${SPLITSCREEN_STATE}" 2>/dev/null || echo "null")
        hw_log "D3.2 slot 1: event_node=${ev1}  js_node=${js1}"
        hw_assert_nonempty "D3.2 slot 1 event_node recorded" "$ev1"

        # Automated: wait for window and verify geometry (1 player = fullscreen)
        hw_wait_for "D3.2 SplitscreenP1 window" 30 \
            hw_slot_window_visible 1 || true

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
    if _stage3_skip_checklist_if_virtual "D3.3 P1 fullscreen docked"; then
        :
    elif hw_prompt "P1's game should be fullscreen on the external display.
  Press Enter to start the D3.3 checklist, or type 'skip'."; then
        hw_checklist "D3.3 P1 fullscreen docked" \
            "P1 Minecraft window fills the entire external display" \
            "The game renders correctly (no black / corruption)" \
            "P1's left stick moves the player, right stick the camera" \
            "No input from the BUILT-IN Steam Deck buttons affects P1"
    else
        hw_skip "D3.3 checklist skipped"
    fi

    # --- D3.4: Second controller ---
    if _stage3_virtual_mode; then
        if ! _stage3_virtual_connect 2 "SECOND"; then
            hw_skip "D3.4-D3.9 — virtual pad 2 unavailable, remaining controller tests skipped"
            return 0
        fi
    elif ! hw_prompt "Plug in a SECOND external controller.
  Wait 3 seconds after plugging it in, then press Enter."; then
        hw_skip "D3.4-D3.9 — operator skipped remaining controller tests"
        return 0
    fi

    hw_info "D3.4 — Waiting for slot 2 to become active (up to 30s)..."
    hw_wait_for "D3.4 slot 2 active" 60 _slot_active 2 || true
    hw_dump_state

    # Automated: verify window positions for 2-player (top/bottom)
    hw_wait_for "D3.4 SplitscreenP2 window" 45 \
        hw_slot_window_visible 2 || true

    local g1_x g1_y g1_w g1_h  g2_x g2_y g2_w g2_h
    read -r g1_x g1_y g1_w g1_h < <(hw_expected_slot_geometry 1 "1 2" "$sw" "$sh")
    read -r g2_x g2_y g2_w g2_h < <(hw_expected_slot_geometry 2 "1 2" "$sw" "$sh")
    hw_assert_slot_window_at "D3.4 P1 window (2-player top)" 1 "$g1_x" "$g1_y" "$g1_w" "$g1_h" 50
    hw_assert_slot_window_at "D3.4 P2 window (2-player bottom)" 2 "$g2_x" "$g2_y" "$g2_w" "$g2_h" 50
    hw_assert_splitscreen_properties "D3.4 slot 1" 1 "TOP"
    hw_assert_splitscreen_properties "D3.4 slot 2" 2 "BOTTOM"

    if _stage3_skip_checklist_if_virtual "D3.4 2-player top/bottom split"; then
        :
    elif hw_prompt "Two Minecraft instances should be visible (top=P1, bottom=P2).
  Press Enter to start the D3.4 checklist, or type 'skip'."; then
        hw_checklist "D3.4 2-player top/bottom split" \
            "External display shows TWO Minecraft windows stacked top/bottom" \
            "P1 (top half): P1's sticks affect P1's screen ONLY" \
            "P2 (bottom half): P2's sticks affect P2's screen ONLY" \
            "Neither player's input affects the other"
    else
        hw_skip "D3.4 checklist skipped"
    fi

    # --- D3.5: Third controller ---
    if _stage3_virtual_mode; then
        if ! _stage3_virtual_connect 3 "THIRD"; then
            hw_skip "D3.5-D3.9 — virtual pad 3 unavailable"
            hw_stop_orchestrator; return 0
        fi
    elif ! hw_prompt "Plug in a THIRD external controller.
  Wait 3 seconds after plugging it in, then press Enter."; then
        hw_skip "D3.5-D3.9 — operator skipped"
        hw_stop_orchestrator; return 0
    fi

    hw_wait_for "D3.5 slot 3 active" 60 _slot_active 3 || true
    hw_dump_state

    # Automated: verify 3-player quad geometry
    hw_wait_for "D3.5 SplitscreenP3 window" 45 \
        hw_slot_window_visible 3 || true

    local g3_x g3_y g3_w g3_h
    read -r g3_x g3_y g3_w g3_h < <(hw_expected_slot_geometry 3 "1 2 3" "$sw" "$sh")
    # Re-read P1 and P2 with quad geometry
    read -r g1_x g1_y g1_w g1_h < <(hw_expected_slot_geometry 1 "1 2 3" "$sw" "$sh")
    read -r g2_x g2_y g2_w g2_h < <(hw_expected_slot_geometry 2 "1 2 3" "$sw" "$sh")
    hw_assert_slot_window_at "D3.5 P1 position (3-player quad top-left)" 1 "$g1_x" "$g1_y" "$g1_w" "$g1_h" 50
    hw_assert_slot_window_at "D3.5 P2 position (3-player quad top-right)" 2 "$g2_x" "$g2_y" "$g2_w" "$g2_h" 50
    hw_assert_slot_window_at "D3.5 P3 position (3-player quad bottom-left)" 3 "$g3_x" "$g3_y" "$g3_w" "$g3_h" 50
    hw_assert_splitscreen_properties "D3.5 slot 1" 1 "TOP_LEFT"
    hw_assert_splitscreen_properties "D3.5 slot 2" 2 "TOP_RIGHT"
    hw_assert_splitscreen_properties "D3.5 slot 3" 3 "BOTTOM_LEFT"

    if _stage3_skip_checklist_if_virtual "D3.5 3-player quad layout"; then
        :
    elif hw_prompt "Three Minecraft instances + one black placeholder (bottom-right) should be visible.
  Press Enter for D3.5 checklist, or type 'skip'."; then
        hw_checklist "D3.5 3-player quad layout" \
            "Top-left=P1, top-right=P2, bottom-left=P3, bottom-right=BLACK placeholder" \
            "P1's sticks affect P1's screen ONLY" \
            "P2's sticks affect P2's screen ONLY" \
            "P3's sticks affect P3's screen ONLY" \
            "Black placeholder (bottom-right) shows no Minecraft content"
    else
        hw_skip "D3.5 checklist skipped"
    fi

    # --- D3.6: Fourth controller ---
    if _stage3_virtual_mode; then
        if ! _stage3_virtual_connect 4 "FOURTH"; then
            hw_skip "D3.6-D3.9 — virtual pad 4 unavailable"
            return 0
        fi
    elif ! hw_prompt "Plug in a FOURTH external controller.
  Wait 3 seconds, then press Enter."; then
        hw_skip "D3.6-D3.9 — operator skipped"
        return 0
    fi

    hw_wait_for "D3.6 slot 4 active" 60 _slot_active 4 || true
    hw_dump_state

    # Automated: verify all 4 windows at quad positions
    hw_wait_for "D3.6 SplitscreenP4 window" 45 \
        hw_slot_window_visible 4 || true

    local g4_x g4_y g4_w g4_h
    read -r g1_x g1_y g1_w g1_h < <(hw_expected_slot_geometry 1 "1 2 3 4" "$sw" "$sh")
    read -r g2_x g2_y g2_w g2_h < <(hw_expected_slot_geometry 2 "1 2 3 4" "$sw" "$sh")
    read -r g3_x g3_y g3_w g3_h < <(hw_expected_slot_geometry 3 "1 2 3 4" "$sw" "$sh")
    read -r g4_x g4_y g4_w g4_h < <(hw_expected_slot_geometry 4 "1 2 3 4" "$sw" "$sh")
    hw_assert_slot_window_at "D3.6 P1 quad top-left" 1 "$g1_x" "$g1_y" "$g1_w" "$g1_h" 50
    hw_assert_slot_window_at "D3.6 P2 quad top-right" 2 "$g2_x" "$g2_y" "$g2_w" "$g2_h" 50
    hw_assert_slot_window_at "D3.6 P3 quad bottom-left" 3 "$g3_x" "$g3_y" "$g3_w" "$g3_h" 50
    hw_assert_slot_window_at "D3.6 P4 quad bottom-right" 4 "$g4_x" "$g4_y" "$g4_w" "$g4_h" 50
    hw_assert_splitscreen_properties "D3.6 slot 4" 4 "BOTTOM_RIGHT"

    if _stage3_skip_checklist_if_virtual "D3.6 4-player quad layout"; then
        :
    elif hw_prompt "All four Minecraft instances should be visible in a 2×2 grid.
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

    if _stage3_virtual_mode; then
        hw_info "D3.7 — destroying virtual pad 2 (simulated P2 disconnect)..."
        rig_destroy_pad 2 || hw_warn "D3.7 virtual pad 2 destroy reported trouble"
    elif ! hw_prompt "UNPLUG the controller assigned to P2 (slot 2, top-right quadrant).
  Remember which controller it is so you can re-plug it later.
  Wait 3 seconds after unplugging, then press Enter."; then
        hw_skip "D3.7-D3.9 — operator skipped"
        return 0
    fi

    # Fix #84: #37's CONTROLLER_REMOVE handler (orchestrator.sh) is a
    # deliberate no-op on the state — it never calls update_slot_state, so
    # slot 2 stays exactly as it was (active, same event_node/js_node/pid/
    # wid). Only a game-window death (SLOT_DIED) reaps a slot. The old
    # "slot 2 inactive after disconnect" wait_for asserted the PRE-#37
    # teardown-on-disconnect contract and always timed out against current
    # behavior — contradicting the persistence check a few lines below in
    # this same section (confirmed on-Deck 2026-07-15, #84).
    hw_info "D3.7 — slot 2 must STAY active after disconnect (#37)..."
    # Settle window: give the monitor/orchestrator time to process the
    # remove event, then read the state ONCE — the expected outcome is "no
    # state change", so a wait-until-true loop would pass instantly and
    # mask a late, buggy deactivation.
    sleep 5

    hw_dump_state

    # Automated: ALL four slots still active — #37 keeps slot 2 itself
    # active too (only window death reaps), not just its siblings.
    local s1_still s2_still s3_still s4_still
    s1_still=$(jq -r '.slots["1"].active' "${SPLITSCREEN_STATE}" \
        2>/dev/null || echo "?")
    s2_still=$(jq -r '.slots["2"].active' "${SPLITSCREEN_STATE}" \
        2>/dev/null || echo "?")
    s3_still=$(jq -r '.slots["3"].active' "${SPLITSCREEN_STATE}" \
        2>/dev/null || echo "?")
    s4_still=$(jq -r '.slots["4"].active' "${SPLITSCREEN_STATE}" \
        2>/dev/null || echo "?")
    hw_log "D3.7 sticky: slot1=${s1_still} slot2=${s2_still}" \
        "slot3=${s3_still} slot4=${s4_still}"
    hw_assert_eq "D3.7 slot 1 still active (sticky)" "true" "$s1_still"
    hw_assert_eq \
        "D3.7 slot 2 STILL active after disconnect (#37 owner design)" \
        "true" "$s2_still"
    hw_assert_eq "D3.7 slot 3 still active (sticky)" "true" "$s3_still"
    hw_assert_eq "D3.7 slot 4 still active (sticky)" "true" "$s4_still"

    # Automated: P1, P3, P4 windows still at quad positions — #37/#84: no
    # reflow on disconnect, so the grid stays a 4-up quad (P2's cell keeps
    # showing P2's persisted, still-running window; asserted separately
    # below).
    read -r g1_x g1_y g1_w g1_h < <(hw_expected_slot_geometry 1 "1 2 3 4" "$sw" "$sh")
    read -r g3_x g3_y g3_w g3_h < <(hw_expected_slot_geometry 3 "1 2 3 4" "$sw" "$sh")
    read -r g4_x g4_y g4_w g4_h < <(hw_expected_slot_geometry 4 "1 2 3 4" "$sw" "$sh")
    hw_assert_slot_window_at "D3.7 P1 still at top-left after P2 disconnect" 1 "$g1_x" "$g1_y" "$g1_w" "$g1_h" 50
    hw_assert_slot_window_at "D3.7 P3 still at bottom-left after P2 disconnect" 3 "$g3_x" "$g3_y" "$g3_w" "$g3_h" 50
    hw_assert_slot_window_at "D3.7 P4 still at bottom-right after P2 disconnect" 4 "$g4_x" "$g4_y" "$g4_w" "$g4_h" 50

    # Owner design (2026-07-06): a controller disconnect does NOT reap the
    # instance — the game and window PERSIST (only MC exit reaps); the slot
    # releases input. The old title-search absence check both encoded the wrong
    # semantics AND passed vacuously (MC renames its window after load).
    local p2_wid_persist
    p2_wid_persist=$(hw_slot_wid 2)
    if [[ -n "$p2_wid_persist" && "$p2_wid_persist" != "null" ]] && \
            hw_xdo xwininfo -id "$p2_wid_persist" 2>/dev/null | grep -q "Map State: IsViewable"; then
        hw_pass "D3.7 P2 instance window persists after disconnect (owner design)"
    else
        hw_fail "D3.7 P2 instance window did NOT persist after disconnect (wid ${p2_wid_persist:-none})"
    fi

    if _stage3_skip_checklist_if_virtual "D3.7 Sticky slots after P2 disconnect"; then
        :
    elif hw_prompt "P1, P3, P4 still controllable; P2's game KEEPS RUNNING (uncontrollable until reconnect).
  Press Enter for D3.7 checklist, or type 'skip'."; then
        hw_checklist "D3.7 Sticky slots after P2 disconnect" \
            "P1 (top-left), P3 (bottom-left), P4 (bottom-right) are still running" \
            "Top-right still shows P2's running game (instance persists on disconnect)" \
            "P1 can still be controlled with P1's controller" \
            "Slot numbers did NOT re-shuffle (P3 is still bottom-left, not moved to top-right)"
    else
        hw_skip "D3.7 checklist skipped"
    fi

    # --- D3.8: Reconnect controller (slot 2 reuse) ---
    if _stage3_virtual_mode; then
        hw_info "D3.8 — recreating virtual pad 2 with its original uniq (simulated P2 reconnect)..."
        rig_create_pad 2 || hw_warn "D3.8 virtual pad 2 recreate reported trouble"
    elif ! hw_prompt "Re-plug the P2 controller you just disconnected.
  Expected (owner design): input REATTACHES to the still-running P2 instance,
  via the MCSS_CONTROLLER_PROXY seamless-reconnect path (#38, default ON
  since v1.2.0) — #62's static dev-bind limitation predates that and no
  longer applies. Wait 5s, press Enter."; then
        hw_skip "D3.8-D3.9 — operator skipped"
        return 0
    fi

    hw_info "D3.8 — Waiting for slot 2 to be reused (up to 20s)..."
    hw_wait_for "D3.8 slot 2 reactivated" 20 _slot_active 2 || true
    hw_dump_state

    hw_wait_for "D3.8 P2 window still viewable" 45 \
        hw_slot_window_visible 2 || true
    read -r g2_x g2_y g2_w g2_h < <(hw_expected_slot_geometry 2 "1 2 3 4" "$sw" "$sh")
    hw_assert_slot_window_at "D3.8 P2 back at top-right after reconnect" 2 "$g2_x" "$g2_y" "$g2_w" "$g2_h" 50
    hw_assert_splitscreen_properties "D3.8 slot 2 reused" 2 "TOP_RIGHT"

    if _stage3_skip_checklist_if_virtual "D3.8 Slot 2 reuse after reconnect"; then
        :
    elif hw_prompt "Slot 2 (top-right): the SAME P2 instance, now (per design) controllable again.
  Press Enter for D3.8 checklist, or type 'skip'."; then
        hw_checklist "D3.8 Slot 2 reuse after reconnect" \
            "Top-right quadrant still shows the SAME P2 game (no respawn, no black)" \
            "P2 controller controls the running instance again (seamless reconnect, #38)" \
            "All four slots are running (no black placeholder)"
    else
        hw_skip "D3.8 checklist skipped"
    fi

    # --- D3.9: Max-4 cap (optional) ---
    if _stage3_virtual_mode; then
        hw_info "D3.9 — creating a 5th virtual pad to test the MCSS_MAX_PLAYERS cap..."
        rig_create_pad 5 || hw_warn "D3.9 virtual pad 5 failed at the rig level (not itself a cap-test result)"
        sleep 5
        local count_after
        count_after=$(_active_slot_count)
        hw_log "D3.9 active slot count after 5th virtual pad: ${count_after}"
        hw_assert_eq "D3.9 still only 4 active slots (max cap enforced)" "4" "$count_after"
        local orch_log="${HW_LOG}.orch"
        if grep -q 'max 4\|Max 4\|No free slot' "${orch_log}" 2>/dev/null; then
            hw_pass "D3.9 orchestrator log confirms max-4 rejection"
        else
            hw_warn "D3.9 max-4 rejection not found in log — check orchestrator output manually"
        fi
        rig_destroy_pad 5 || hw_warn "D3.9 cleanup: virtual pad 5 did not fully stop"
        hw_skip "D3.9 5th controller rejected — virtual-pad mode, no human pilot (automated check above)"
    elif hw_prompt "OPTIONAL: If you have a 5th controller available, plug it in now.
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

    # ── D3.10 (#16): controller monitor killed mid-session → orchestrator restarts it
    if hw_prompt "CHAOS 1/3 (#16): the controller monitor will now be killed mid-session.
  Expected: the orchestrator's heartbeat restarts it within ~15s and hotplug keeps working.
  Press Enter to run, or type 'skip'."; then
        local mon_udev old_mon new_udev
        mon_udev=$(pgrep -f 'udevadm monitor' | head -1 || true)
        if [[ -n "$mon_udev" ]]; then
            old_mon=$(ps -o ppid= -p "$mon_udev" 2>/dev/null | tr -d ' ')
            hw_log "D3.10 monitor shell=$old_mon (udevadm child=$mon_udev) — kill -9 both"
            kill -9 "$old_mon" "$mon_udev" 2>/dev/null || true
            hw_wait_for "D3.10 heartbeat restarted the monitor (new udevadm)" 30 \
                bash -c '[[ -n "$(pgrep -f "udevadm monitor" 2>/dev/null)" ]]' || true
            if _stage3_virtual_mode; then
                hw_info "D3.10 — cycling virtual pad 3 (destroy+recreate) in place of a physical unplug/replug..."
                rig_destroy_pad 3 || hw_warn "D3.10 virtual pad 3 destroy reported trouble"
                sleep 3
                rig_create_pad 3 || hw_warn "D3.10 virtual pad 3 recreate reported trouble"
                # No validated automated verdict for "did input reattach correctly"
                # exists yet — inventing one without hardware validation would be
                # a confidently-wrong pass/fail (PRINCIPLES #3/#4). Cycle the pad
                # programmatically, record it as open rather than guess a verdict.
                hw_skip "D3.10 (#16) reattach verdict — virtual-pad mode has no validated automated check yet; pad 3 cycled programmatically, needs a Deck look until one exists"
            else
                # Sticky slots (#37/#84): unplug/replug does NOT tear the game down
                # and respawn it — only an in-game quit reaps a slot. The correct
                # expectation here is the same as D3.7/D3.8: the game keeps running
                # throughout, and the replugged pad's input reattaches to it.
                hw_prompt "Unplug ANY one pad, wait 3s, plug it back in — its input should
  reattach to the still-running game (sticky slots, #37 — NOT a teardown+respawn).
  Press Enter when you have seen it reattach, or 'skip'." \
                    && hw_confirm "Did input reattach correctly to that pad's slot after the monitor kill?" \
                    && hw_pass "D3.10 (#16) session survived monitor kill; hotplug still live" \
                    || hw_fail "D3.10 (#16) hotplug did not survive the monitor kill"
            fi
        else
            hw_skip "D3.10 — no udevadm monitor process found (polling fallback in use?)"
        fi
    else
        hw_skip "D3.10 (#16) monitor-kill chaos skipped"
    fi

    # ── D3.11 (#23): rapid double-plug must not double-add
    local _d311_run=0
    if _stage3_virtual_mode; then
        hw_info "D3.11 (#23) — virtual double-plug: unplug pad 4, then insert/yank/insert rapidly..."
        rig_destroy_pad 4 || hw_warn "D3.11 unplug (destroy) of pad 4 reported trouble"
        rig_create_pad 4 || hw_warn "D3.11 first rapid re-insert of pad 4 failed"
        rig_destroy_pad 4 || hw_warn "D3.11 rapid yank of pad 4 failed"
        rig_create_pad 4 || hw_warn "D3.11 second rapid re-insert of pad 4 failed"
        _d311_run=1
    elif hw_prompt "CHAOS 2/3 (#23): unplug ONE pad, then plug it back in TWICE in rapid
  succession (insert, yank within ~1s, insert again). Do that now, wait 10s, press Enter."; then
        _d311_run=1
    else
        hw_skip "D3.11 (#23) rapid double-plug chaos skipped"
    fi

    if (( _d311_run )); then
        sleep 5
        local n_active n_java
        n_active=$(_active_slot_count)
        n_java=$(pgrep -fc 'java.*latestUpd[a]te' 2>/dev/null || echo 0)
        hw_log "D3.11 active_slots=$n_active java_instances=$n_java"
        hw_assert_eq "D3.11 (#23) no double-add: java count matches active slots" "$n_active" "$n_java"
        if (( n_active <= 4 )); then
            hw_pass "D3.11 (#23) slot count within cap after rapid double-plug ($n_active)"
        else
            hw_fail "D3.11 (#23) slot count exceeded cap: $n_active"
        fi
        hw_dump_state
    fi

    # ── D3.12 (#25): whole-hub unplug/replug
    if _stage3_virtual_mode; then
        hw_info "D3.12 (#25) — destroying every tracked virtual pad at once (simulated hub drop)..."
        local _d312_idx
        for _d312_idx in $(rig_list_pads); do
            rig_destroy_pad "$_d312_idx" || hw_warn "D3.12 pad $_d312_idx destroy reported trouble"
        done
        sleep 5
        hw_info "D3.12 (#25) — recreating all four virtual pads (simulated hub replug)..."
        for _d312_idx in 1 2 3 4; do
            rig_create_pad "$_d312_idx" || hw_warn "D3.12 pad $_d312_idx recreate reported trouble"
        done
        sleep 5
        hw_dump_state
        hw_skip "D3.12 (#25) hub replug checklist — virtual-pad mode, no human pilot to confirm visual recovery"
    elif hw_prompt "CHAOS 3/3 (#25): unplug the WHOLE hub/dock USB (all pads drop at once).
  Wait 5s, then plug the hub back in. Wait ~30s for respawns, then press Enter."; then
        sleep 5
        hw_dump_state
        hw_checklist "D3.12 (#25) hub replug" \
            "All quadrants eventually returned to running games (or placeholders while loading)" \
            "No stuck black quadrant that never recovers" \
            "Each pad controls the same quadrant it did before the hub pull"
    else
        hw_skip "D3.12 (#25) hub replug chaos skipped"
    fi

    hw_dump_state
    hw_dump_processes
    hw_info "Stage 3 complete — orchestrator left running for stages 4 and 5"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    mcss_workdir_init hardware || true
    HW_LOG="$(hw_log_path stage3)"; export HW_LOG
    export REPO_ROOT
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0 HW_FAILED=0 HW_SKIPPED=0
    hw_detect_display
    run_stage3_hotplug
    hw_log "Stage 3: ${HW_PASSED} passed, ${HW_FAILED} failed, ${HW_SKIPPED} skipped — log: ${HW_LOG}"
    (( HW_FAILED == 0 )) && exit 0 || exit 1
fi
