#!/bin/bash
set -euo pipefail

# =============================================================================
# Stage 6: Teardown Exit Matrix (#15 / #60 — plan Phase D item 10)
# =============================================================================
# Runs a live session through each of the three exit paths and asserts the
# whole tree is actually gone afterwards. This is the validation the #60
# supervisor rework has never had: every observed exit so far died silently
# before the supervised reap logged a single line.
#
# Exit paths:
#   T6.1  In-game quit (operator: Esc → Quit Game in P1)
#   T6.2  Steam Stop  (operator: Steam button → Stop game / Exit)
#   T6.3  SIGTERM to the supervisor (automated)
#
# Post-exit assertions (each path, within a 90s budget):
#   - no marked survivors (startplasma/kwin/java/bwrap/udevadm/minecraftSplitscreen)
#   - Steam reaper for the shortcut released
#   - no app-MinecraftSplitscreen systemd --user units
#   - debug log contains "[supervise_reap] entered" (breadcrumb, #60)
#   - operator: back at Game Mode UI, no black screen
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

_marked_survivor_count() {
    local pid c=0
    for pid in $(pgrep -f 'startplasma-wayland|kwin_wayland|latestUpdate|bwrap.*PolyMC|udevadm monitor|minecraftSplitscreen' 2>/dev/null || true); do
        grep -qz 'SPLITSCREEN_DEBUG_LOG=' "/proc/$pid/environ" 2>/dev/null && c=$(( c + 1 ))
    done
    echo "$c"
}

_reaper_alive() {
    pgrep -f 'SteamLaunch.*minecraftSplitscreen' >/dev/null 2>&1
}

_mcss_units_present() {
    systemctl --user list-units 'app-MinecraftSplitscreen*' --no-legend 2>/dev/null | grep -q .
}

_assert_torn_down() {
    local label="$1"
    hw_wait_for "${label} marked tree gone" 90 \
        bash -c '[[ "$(c=0; for pid in $(pgrep -f "startplasma-wayland|kwin_wayland|latestUpdate|bwrap.*PolyMC|udevadm monitor|minecraftSplitscreen" 2>/dev/null); do grep -qz SPLITSCREEN_DEBUG_LOG= /proc/$pid/environ 2>/dev/null && c=$((c+1)); done; echo $c)" == "0" ]]' || true

    local survivors reaper units
    survivors=$(_marked_survivor_count)
    hw_assert_eq "${label} zero marked survivors" "0" "$survivors"

    if _reaper_alive; then
        hw_fail "${label} Steam reaper still alive — Steam thinks the game is running (#15 symptom)"
    else
        hw_pass "${label} Steam reaper released"
    fi

    if _mcss_units_present; then
        hw_fail "${label} app-MinecraftSplitscreen systemd --user unit(s) still present"
    else
        hw_pass "${label} no app-MinecraftSplitscreen systemd units"
    fi

    local log
    log=$(readlink -f /tmp/splitscreen-debug-latest.log 2>/dev/null || true)
    if [[ -n "$log" ]] && grep -q '\[supervise_reap\] entered' "$log"; then
        hw_pass "${label} supervisor reap breadcrumb present (#60 instrumentation)"
        if grep -q 'own nested-session tree confirmed clean' "$log"; then
            hw_pass "${label} supervised reap ran to completion — FIRST EVER observation"
        else
            hw_fail "${label} supervised reap entered but never confirmed clean (#60 residual persists)"
        fi
    else
        hw_fail "${label} no supervisor breadcrumb in ${log:-<no log>} (#60 residual: died before entry)"
    fi

    hw_confirm "TV shows the Game Mode UI (library) — no black screen, no stuck game?" \
        && hw_pass "${label} operator confirms clean return to Game Mode" \
        || hw_fail "${label} operator reports the session did not return cleanly"
}

_launch_and_wait_ready() {
    hw_launch_orchestrator docked
    hw_wait_for "session slot 1 active" 60 \
        bash -c "jq -e '.slots[\"1\"].active == true' '${SPLITSCREEN_STATE}' >/dev/null 2>&1" || true
    hw_wait_for "P1 window up" 60 hw_slot_window_visible 1 || true
}

run_stage6_teardown() {
    hw_section "Stage 6: Teardown Exit Matrix"

    if ! hw_prompt "Deck docked, exactly ONE pad connected (pads-first contract).
  Three launch/exit rounds follow. Press Enter to start, or 'skip'."; then
        hw_skip "T6.* — operator skipped stage 6"
        return 0
    fi

    # ── T6.1 in-game quit
    hw_info "T6.1 — launching for the in-game-quit round"
    _launch_and_wait_ready
    if hw_prompt "T6.1: quit from INSIDE the game (Esc → Quit Game / Disconnect).
  Press Enter AFTER the game has exited."; then
        _assert_torn_down "T6.1 (in-game quit)"
    else
        hw_skip "T6.1 skipped"
        hw_reap_stale_session
    fi

    # ── T6.2 Steam Stop
    hw_info "T6.2 — launching for the Steam-Stop round"
    _launch_and_wait_ready
    if hw_prompt "T6.2: stop the game FROM STEAM (Steam button → running game → Stop/Exit).
  Press Enter AFTER Steam shows it stopped."; then
        _assert_torn_down "T6.2 (Steam Stop)"
    else
        hw_skip "T6.2 skipped"
        hw_reap_stale_session
    fi

    # ── T6.3 SIGTERM (automated)
    hw_info "T6.3 — launching for the SIGTERM round"
    _launch_and_wait_ready
    local sup=""
    local pid
    for pid in $(pgrep -f 'minecraftSplitscreen.sh launchFromPlasma' 2>/dev/null || true); do
        grep -qz 'SPLITSCREEN_DEBUG_LOG=' "/proc/$pid/environ" 2>/dev/null && sup="$pid"
    done
    if [[ -n "$sup" ]]; then
        hw_log "T6.3 SIGTERM → supervisor $sup"
        kill -TERM "$sup" 2>/dev/null || true
        _assert_torn_down "T6.3 (SIGTERM)"
    else
        hw_skip "T6.3 — no marked supervisor found to signal"
        hw_reap_stale_session
    fi

    hw_dump_processes
    hw_info "Stage 6 complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    export HW_LOG="$HOME/splitscreen-hwtest-$(date +%Y%m%d_%H%M%S)-stage6.log"
    export REPO_ROOT
    export SPLITSCREEN_STATE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    export SPLITSCREEN_FIFO="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}"
    export HW_PASSED=0 HW_FAILED=0 HW_SKIPPED=0
    hw_detect_display
    run_stage6_teardown
    hw_log "Stage 6: ${HW_PASSED} passed, ${HW_FAILED} failed, ${HW_SKIPPED} skipped — log: ${HW_LOG}"
    (( HW_FAILED == 0 )) && exit 0 || exit 1
fi
