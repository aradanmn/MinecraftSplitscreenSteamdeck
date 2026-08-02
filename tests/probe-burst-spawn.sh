#!/bin/bash
set -uo pipefail

# =============================================================================
# probe-burst-spawn.sh — repro for #71 (burst-spawn reflow race)
# =============================================================================
# PR-4 of build plan #157 (issue #136). #71: "connect 4 pads, then launch"
# (the pads-first party scenario) left slot 4 stuck at Minecraft's initial
# centered 854x480 with zero reposition events, while slots 1-3 tiled
# correctly — filed 2026-07-06. By hand this needs 4 controllers arriving
# within the same ~second, which is next to impossible to land reliably with
# real hardware; tests/lib/uhid_rig.sh's rig_create_pad calls land a true
# burst (each returns as soon as ITS OWN pad process is ready, without
# waiting for kernel enumeration — see uhid_rig.sh's header).
#
# Since #71 was filed, orchestrator.sh's per-slot spawn path changed to defer
# _reflow_layout until AFTER spawn_instance returns (i.e. after that slot's
# OWN window exists — up to INSTANCE_LIFECYCLE_WINDOW_POLL_TIMEOUT_S=120s),
# which on paper should already fix the race: the straggler's own late
# reflow recomputes the WHOLE layout, itself included. Nobody has confirmed
# this on hardware against the ORIGINAL repro shape (docs/RUNBOOK-HW2-TEST-
# HARNESS.md's Part 4 marked it optional and it was never run) — this probe
# is that confirmation, not an assumed-fixed checkbox (PRINCIPLES #3/#4).
#
# Races are intermittent by nature: a single green run is weak evidence.
# This probe repeats the full stop/burst-launch/assert cycle several times
# (default 5, override with $1 or MCSS_BURST_ITERATIONS) and reports a
# per-iteration verdict plus a final tally — "N/5 converged" is the actual
# finding, not a single pass/fail.
#
# USAGE (on the Deck, docked, external display already up):
#   bash tests/probe-burst-spawn.sh [iterations]
#   No physical controllers needed — this is rig-only (tests/lib/uhid_rig.sh),
#   same NO SUDO / no live-session-refusal contract as the rig itself.
#   Each iteration fully stops the session and relaunches it — the FIRST
#   iteration needs nothing pre-connected (the rig connects all 4 before
#   launch itself); later iterations need the display to have recovered from
#   the previous stop (see the canary check between iterations below).
#
# NOT wired into tests/hardware/run_all.sh: this is a one-off bug repro
# (like the other tests/probe-*.sh scripts), not a standing regression gate.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/hardware/lib/helpers.sh"
# #50 loading-order rule: runtime_context first (see stage3_hotplug.sh).
source "$REPO_ROOT/modules/runtime_context.sh"
source "$REPO_ROOT/modules/dock_detection.sh"
source "$REPO_ROOT/modules/instance_lifecycle.sh"
source "$REPO_ROOT/modules/controller_monitor.sh"
source "$SCRIPT_DIR/lib/uhid_rig.sh"

# _burst_slot_active: same one-liner stage3_hotplug.sh uses.
_burst_slot_active() {
    jq -e ".slots[\"${1}\"].active == true" "${SPLITSCREEN_STATE}" >/dev/null 2>&1
}

# _burst_run_one_iteration: burst-create all 4 pads, launch docked, assert
# quad convergence for every slot. Never aborts the probe on its own — every
# failure is recorded via hw_fail and the caller moves on to teardown.
# Inputs: $1 — iteration number (for labeling only).
# Outputs: return — 0 all 4 slots converged, 1 at least one did not.
_burst_run_one_iteration() {
    local i="$1"
    hw_section "Burst-spawn iteration ${i}"

    hw_info "iter ${i} — burst-creating 4 virtual pads (no waits between creates)..."
    local n ok=1
    for n in 1 2 3 4; do
        rig_create_pad "$n" || { hw_fail "iter ${i}: virtual pad ${n} failed to create"; ok=0; }
    done
    if (( ! ok )); then
        hw_fail "iter ${i}: aborting — not all 4 pads created"
        return 1
    fi

    # Confirm the burst actually landed on the PRODUCTION enumerator before
    # launching — a slow enumerate here would confound the repro (indist-
    # inguishable from a slow-to-tile straggler caused by something else).
    for n in 1 2 3 4; do
        rig_wait_for_pad "$n" 15 || \
            hw_warn "iter ${i}: pad ${n} took >15s to reach the production enumerator (pre-launch, so not #71 itself, but note it)"
    done

    hw_info "iter ${i} — launching orchestrator (docked, all 4 pads already connected)..."
    hw_launch_orchestrator docked
    hw_wait_for "iter ${i} FIFO created" 10 test -p "${SPLITSCREEN_FIFO}"

    # Stronger-than-the-FIFO readiness signal: the FIFO is a named pipe that
    # can pre-exist on disk from an earlier run (see _burst_teardown_and_
    # recover's cleanup, added after this exact failure mode showed up live
    # 2026-08-02) — a supervisor process actually existing is real evidence
    # a launch happened, not just that a stale file is sitting on disk.
    # Fails FAST (10s) rather than silently burning 4x30s of slot-active
    # timeouts against a session that was never launched.
    if ! hw_wait_for "iter ${i} launchFromPlasma supervisor present" 10 \
        bash -c 'pgrep -f "minecraftSplitscreen.sh launchFromPlasma" >/dev/null 2>&1'
    then
        hw_fail "iter ${i}: no launchFromPlasma process appeared — the launch itself never happened (Steam may still have been settling from the previous teardown)"
        return 1
    fi

    for n in 1 2 3 4; do
        hw_wait_for "iter ${i} slot ${n} active" 30 _burst_slot_active "$n" || \
            hw_warn "iter ${i}: slot ${n} never went active"
    done

    hw_dump_state

    local screen_res sw sh
    screen_res=$(hw_get_screen_resolution)
    sw="${screen_res%%x*}"; sh="${screen_res##*x}"

    # Generous per-slot budget: spawn_instance's own window poll allows up to
    # INSTANCE_LIFECYCLE_WINDOW_POLL_TIMEOUT_S=120s for a cold JVM, and
    # hw_assert_slot_window_at already retries internally — one call covers
    # both "hasn't spawned yet" and "spawned but not yet repositioned".
    local iter_ok=1 gx gy gw gh
    for n in 1 2 3 4; do
        read -r gx gy gw gh < <(hw_expected_slot_geometry "$n" "1 2 3 4" "$sw" "$sh")
        hw_assert_slot_window_at "iter ${i} P${n} quad position" "$n" \
            "$gx" "$gy" "$gw" "$gh" 50 150 || iter_ok=0
    done

    # Settle grace before the verdict: hw_assert_slot_window_at reads the
    # window manager's own idea of "mapped at position X,Y" via xdotool —
    # that can land well AHEAD of gamescope's compositor actually presenting
    # the frame on the physical display, especially under the load of 4 JVMs
    # booting at once. Operator-observed TWICE on 2026-08-02 (a 5s grace was
    # not enough the second time either): windows the automated check had
    # already passed were not yet visually apparent. This does not change
    # what gets asserted (already recorded above) — it just gives a real
    # render lag, if there is one, room to resolve, and gives an operator
    # watching live enough time to actually see the quad settle in.
    if (( iter_ok )); then
        sleep 20
    fi

    if (( iter_ok )); then
        hw_pass "iter ${i}: #71 did NOT reproduce — all 4 windows converged on the quad layout"
    else
        hw_fail "iter ${i}: #71 REPRODUCED — at least one window never converged"
        hw_dump_processes
    fi

    (( iter_ok )) && return 0 || return 1
}

# _burst_teardown_and_recover: end the session via hw_stop_orchestrator
# (hw_reap_stale_session). An earlier version of this function tried
# SIGTERM-ing the marker-matched `minecraftSplitscreen.sh launchFromPlasma`
# supervisor directly (mirroring stage6_teardown.sh's T6.3 round), on the
# theory that letting the launcher's own registered trap run its graceful
# teardown would avoid the orphaned-kwin_wayland wedge PR-3 hit. Live-
# diagnosed 2026-08-02 that this can never work: launchFromPlasma exports
# SPLITSCREEN_DEBUG_LOG to ITSELF partway through its own execution, which
# only affects children forked AFTER that point — its own /proc/$pid/environ
# (captured at ITS exec, before that export ran) never carries the marker,
# so the marker-gated pgrep search can never find it (same reason
# stage6_teardown.sh's T6.3 likely never actually engages either, though
# that wasn't independently confirmed here). The REAL bug turned out to be
# one line in hw_reap_stale_session itself — kwin_wayland's own environ has
# the identical problem, so its marker-gated kill silently skipped it every
# time. Fixed there directly (tests/hardware/lib/helpers.sh, 2026-08-02) —
# kwin_wayland is now killed unconditionally, benefiting every hardware
# script that calls hw_stop_orchestrator, not just this probe.
# Inputs: $1 — iteration number (for labeling only).
_burst_teardown_and_recover() {
    local i="$1"
    hw_info "iter ${i} — ending session..."
    hw_stop_orchestrator
    rig_cleanup

    # Live-diagnosed 2026-08-02 (iteration 2 of a 5x run): SPLITSCREEN_FIFO is
    # a named pipe that persists on disk independent of any process — after a
    # stop it stays behind, so the NEXT iteration's `hw_launch_orchestrator`
    # "FIFO appeared" check trivially passes against the STALE file even when
    # the new launch never actually started. That produced a false "#71
    # REPRODUCED" (30s x4 slot-active timeouts, zero geometry, all against a
    # session that was never running) — not a real repro, a broken readiness
    # check. Remove it here so only a genuinely fresh launch can satisfy the
    # next iteration's check.
    rm -f "${SPLITSCREEN_FIFO:-}" 2>/dev/null || true

    # Also wait for Steam's OWN reaper to actually be gone, not just the OS-
    # level process tree: while it lingers, Steam's internal bookkeeping still
    # thinks the game is running and a fresh `steam://rungameid/` request can
    # be silently ignored (same root cause as iteration 2's failure — Steam
    # had not yet caught up to hw_reap_stale_session already having killed
    # the reaper process itself moments earlier).
    hw_wait_for "iter ${i} Steam reaper released" 15 \
        bash -c '! pgrep -f "SteamLaunch.*minecraftSplitscreen" >/dev/null 2>&1' || \
        hw_warn "iter ${i}: Steam reaper still present 15s after teardown — next launch may race it"

    local mode
    mode=$(get_display_mode 2>>"${HW_LOG}")
    if [[ "$mode" != "docked" ]]; then
        hw_warn "iter ${i}: post-teardown display mode is '${mode}', not docked — Steam may be stuck on a stale game-tracking state (see PR-3's session-stop lesson)"
        hw_prompt "If the display looks stuck or black, clear it now on-device
  (Steam button -> Power -> Restart Steam, or Exit Game if the overlay
  responds), THEN press Enter to continue to the next iteration.
  Type 'skip' to stop the probe here instead." || return 1
    fi
    return 0
}

main() {
    mcss_workdir_init hardware || true
    HW_LOG="$(hw_log_path burst)"; export HW_LOG
    export REPO_ROOT
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="$HOME/.local/share/PolyMC/splitscreen.fifo"
    export HW_PASSED=0 HW_FAILED=0 HW_SKIPPED=0
    hw_detect_display

    local iterations="${1:-${MCSS_BURST_ITERATIONS:-5}}"
    if [[ ! "$iterations" =~ ^[0-9]+$ || "$iterations" -lt 1 ]]; then
        hw_fail "bad iteration count: '${iterations}' (must be a positive integer)"
        exit 1
    fi

    if ! rig_init; then
        hw_fail "rig_init failed — see stderr above"
        exit 1
    fi
    rig_install_traps || hw_warn "rig_install_traps refused (a trap already existed)"

    local mode
    mode=$(get_display_mode 2>>"${HW_LOG}")
    hw_log "get_display_mode returned: ${mode}"
    if [[ "$mode" != "docked" ]]; then
        hw_fail "not docked (mode=${mode}) — connect the dock/external display before running this probe"
        rig_cleanup
        exit 1
    fi

    local -a results=()
    local i
    for (( i = 1; i <= iterations; i++ )); do
        if _burst_run_one_iteration "$i"; then
            results+=("converged")
        else
            results+=("REPRODUCED")
        fi

        if ! _burst_teardown_and_recover "$i"; then
            hw_skip "burst-spawn probe stopped early by operator after iteration ${i}/${iterations}"
            break
        fi
    done

    hw_section "#71 burst-spawn probe — summary"
    local idx converged=0 reproduced=0
    for idx in "${!results[@]}"; do
        hw_log "  iteration $(( idx + 1 )): ${results[$idx]}"
        [[ "${results[$idx]}" == "converged" ]] && converged=$(( converged + 1 )) || reproduced=$(( reproduced + 1 ))
    done
    hw_log "  ${converged}/${#results[@]} converged, ${reproduced}/${#results[@]} reproduced #71"

    hw_log "Burst-spawn probe: ${HW_PASSED} passed, ${HW_FAILED} failed, ${HW_SKIPPED} skipped — log: ${HW_LOG}"
    (( reproduced == 0 )) && exit 0 || exit 1
}

main "$@"
