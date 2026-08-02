#!/bin/bash
set -uo pipefail

# =============================================================================
# probe-reconnect-swap.sh — #151 Tier 2: does the swap actually mis-route
#                            input to the WRONG player's instance?
# =============================================================================
# PR-5 of build plan #157 (issue #136). Tier 2 of #151's repro — the real
# production-scenario test, building on tests/probe-node-swap.sh's Tier 1
# result (2026-08-02): forcing two pads to land on EACH OTHER's freed eventN
# is confirmed real and reliably forceable (its "plain 2-pad" scenario, 3/3
# clean). This script forces that exact swap inside a REAL 4-up docked
# session with MCSS_CONTROLLER_PROXY=1 (evsieve actually running, the
# production default) and checks for the real bug's signature, not just the
# kernel-level precondition.
#
# NOT YET RUN ON HARDWARE as of authoring (2026-08-02 night) — built so it's
# ready the next time both the Deck and an operator are free, same "build
# now, validate next sitting" pattern as every other probe this cycle.
# Everything below is reasoned from the issue's own diagnostic trace and
# controller_proxy.sh's real code, not guessed — but per PRINCIPLES #3/#4,
# reasoning is not validation. Expect to adjust settle timings and maybe the
# verification logic once this actually runs.
#
# THE REAL BUG (from #151, filed 2026-07-26, right after #38 shipped):
#   4-up, proxy on. Disconnect P4 then P2. Reconnect P4 then P2. The
#   ORCHESTRATOR'S identity logic is CORRECT (RESUME matches by MAC
#   perfectly, slot4->event22, slot2->event30, final state right) — the bug
#   is a RACE between the repoint and evsieve's own persist=reopen: when P4
#   reconnects on event22 (P2's OLD node), slot2's evsieve is still watching
#   that symlink (not yet repointed) and grabs P4's pad FIRST (exclusive
#   `grab`). By the time the orchestrator repoints slot4's symlink to
#   event22, slot4's evsieve can't grab it (EBUSY). Net effect: P4's pad
#   drives P2's instance, P4's instance is uncontrollable.
#
# WHY THE REAL TRACE MATCHES TIER 1's TECHNIQUE EXACTLY: the issue's trace
# shows P4 (originally the HIGHER node, event30) reconnecting FIRST claims
# the LOWER free node (event22, P2's old one) — because reconnect order, not
# original ownership, determines who gets the lowest free number. That is
# exactly probe-node-swap.sh's confirmed mechanism ("recreate the
# higher-original-node identity FIRST"), not a lab artifact — this script
# reconnects P4 (whichever pad has the higher pre-drop node) first, mirroring
# the real trace rather than an arbitrary choice.
#
# VERIFICATION (three checks, all against controller_proxy.sh's real paths —
# see that module's header for MCSS_PROXY_PADS_DIR/MCSS_PROXY_VIRT_DIR/
# MCSS_HELPER_DIR):
#   1. State-file sanity: each slot's phys_uniq matches its INTENDED
#      identity (expected TRUE per the issue — "the identity logic is
#      correct" — a sanity check, not the bug itself).
#   2. Symlink target: does MCSS_PROXY_PADS_DIR/slot<N> actually resolve to
#      the physical eventN that slot N's OWN pad currently holds? A mismatch
#      here is the bug made visible structurally.
#   3. evsieve's own log ($MCSS_HELPER_DIR/evsieve-slot<N>.log) for the
#      EXACT strings the issue's own diagnostic quoted — "failed to grab
#      input device" / "EBUSY" / "capabilities of the reconnected device are
#      different than expected". Presence = the bug's signature, directly,
#      the same way the issue itself was originally diagnosed.
#
# Races are intermittent — repeats the full cycle (default 3, override with
# $1 or MCSS_RECONNECT_ITERATIONS; kept lower than probe-burst-spawn.sh's
# default 5 since each iteration boots four real JVMs from cold AND tears
# them down, the heaviest cycle of any probe in this build plan).
#
# USAGE (on the Deck, docked, external display already up, NO physical
# controllers connected — this is rig-only):
#   bash tests/probe-reconnect-swap.sh [iterations]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/hardware/lib/helpers.sh"
# #50 loading-order rule: runtime_context first (see stage3_hotplug.sh).
source "$REPO_ROOT/modules/runtime_context.sh"
source "$REPO_ROOT/modules/dock_detection.sh"
source "$REPO_ROOT/modules/instance_lifecycle.sh"
source "$REPO_ROOT/modules/controller_monitor.sh"
source "$REPO_ROOT/modules/controller_proxy.sh"
source "$SCRIPT_DIR/lib/uhid_rig.sh"

_recon_slot_active() {
    jq -e ".slots[\"${1}\"].active == true" "${SPLITSCREEN_STATE}" >/dev/null 2>&1
}

# _recon_node_for_uniq / _recon_wait_node: same pattern as
# probe-node-swap.sh's _swap_node_for_uniq/_swap_wait_node — duplicated
# rather than sourced, since that file runs its own main() unconditionally
# on source (no BASH_SOURCE guard, matching the tests/probe-*.sh
# convention) and would immediately execute its own scenarios if sourced
# here.
_recon_node_for_uniq() {
    _list_raw_external_pads 2>/dev/null | awk -v u="$1" '$NF==u{print $1}'
}
_recon_wait_node() {
    local uniq="$1" timeout_s="$2" avoid="${3:-}"
    local deadline=$(( SECONDS + timeout_s )) node=""
    while (( SECONDS < deadline )); do
        node="$(_recon_node_for_uniq "$uniq")"
        if [[ -n "$node" && ( -z "$avoid" || "$node" != "$avoid" ) ]]; then
            printf '%s\n' "$node"; return 0
        fi
        sleep 0.3
    done
    printf '%s\n' "$node"; return 1
}

# _recon_run_one_iteration: launch a real 4-up docked session, force the
# swap on slots 2 and 4 (the issue's literal P4/P2), let the live
# orchestrator + evsieve process the reconnect, then check for the bug's
# signature. Inputs: $1 — iteration number (labeling only).
# Outputs: return — 0 clean (no signature found), 1 REPRODUCED or a setup
#   failure (both recorded via hw_fail/hw_pass, caller doesn't need to
#   distinguish for the tally).
_recon_run_one_iteration() {
    local i="$1"
    hw_section "Reconnect-swap iteration ${i}"

    hw_info "iter ${i} — creating 4 pads and launching docked (proxy default ON)..."
    local n
    for n in 1 2 3 4; do
        rig_create_pad "$n" || { hw_fail "iter ${i}: pad ${n} failed to create"; rig_cleanup; return 1; }
        # Operator-observed 2026-08-02: creating all 4 pads back-to-back (and,
        # more broadly, the whole cycle's rapid connect/disconnect churn) is
        # plausibly hard on the machine — a Steam-triggered watchdog restart
        # was observed during a run. Give udev/the kernel a couple seconds
        # between each pad's creation rather than slamming all 4 through at once.
        (( n < 4 )) && sleep 2
    done
    for n in 1 2 3 4; do
        rig_wait_for_pad "$n" 15 || hw_warn "iter ${i}: pad ${n} slow to enumerate pre-launch"
    done

    hw_launch_orchestrator docked
    hw_wait_for "iter ${i} FIFO created" 10 test -p "${SPLITSCREEN_FIFO}"
    if ! hw_wait_for "iter ${i} launchFromPlasma supervisor present" 10 \
        bash -c 'pgrep -f "minecraftSplitscreen.sh launchFromPlasma" >/dev/null 2>&1'
    then
        hw_fail "iter ${i}: no launchFromPlasma process appeared — launch never happened"
        rig_cleanup; return 1
    fi

    for n in 1 2 3 4; do
        hw_wait_for "iter ${i} slot ${n} active" 30 _recon_slot_active "$n" || \
            hw_warn "iter ${i}: slot ${n} never went active"
    done

    # WRONG in an earlier draft, caught live 2026-08-02 (operator question:
    # "how much time between loading MC and starting the controller
    # tests?"): "slot active" fires the instant the controller is CLAIMED,
    # at the very start of spawn_instance — not when Minecraft has actually
    # finished booting. A flat 10s here was starting the reconnect dance
    # while the JVMs were plausibly still mid-boot (probe-burst-spawn.sh
    # separately measured ~48-54s from slot-active to window-visible for
    # the SAME kind of cold launch). Wait for each slot's actual WINDOW
    # instead — the same hw_slot_window_visible check every other hardware
    # probe in this build plan already trusts for "is this instance really
    # up," not a guessed sleep.
    for n in 1 2 3 4; do
        hw_wait_for "iter ${i} P${n} window visible" 120 hw_slot_window_visible "$n" || \
            hw_warn "iter ${i}: slot ${n} window never became visible — proceeding anyway, but this iteration's result may be unreliable"
    done
    # Operator-observed live 2026-08-02: the forced disconnect fired the
    # instant the 4th window appeared, with essentially no settle — and
    # evsieve's own reconnect logs (captured separately) show a
    # permission-denied retry loop against freshly-created uhid nodes
    # (plausibly udev's uaccess ACL tagging lagging the device node's own
    # appearance) that can run for TENS of seconds before self-healing.
    # 5s was nowhere near enough headroom for the whole proxy pipeline
    # (not just Minecraft) to settle after a cold 4-up launch.
    hw_info "iter ${i} — settling after all windows visible before forcing the swap..."
    sleep 15

    local uniq2 uniq4
    uniq2="$(rig_default_uniq 2)"
    uniq4="$(rig_default_uniq 4)"
    local node2_0 node4_0
    node2_0="$(_recon_node_for_uniq "$uniq2")"
    node4_0="$(_recon_node_for_uniq "$uniq4")"
    if [[ -z "$node2_0" || -z "$node4_0" ]]; then
        hw_fail "iter ${i}: couldn't read pre-swap nodes for slot 2/4 (node2=${node2_0:-?} node4=${node4_0:-?})"
        rig_cleanup; return 1
    fi
    hw_info "iter ${i}: pre-swap — slot2=event${node2_0}  slot4=event${node4_0}"

    # Reconnect-FIRST claims the lowest free number (Tier 1's confirmed
    # mechanism, and exactly what the issue's own trace shows) — reconnect
    # whichever pad currently holds the HIGHER node first, matching the real
    # repro's P4-then-P2 order when P4 is the higher one, or the mirror case
    # if the live session happened to assign them the other way around.
    local first_idx first_uniq first_node0 second_idx second_uniq second_node0
    if (( node4_0 > node2_0 )); then
        first_idx=4; first_uniq="$uniq4"; first_node0="$node4_0"
        second_idx=2; second_uniq="$uniq2"; second_node0="$node2_0"
    else
        first_idx=2; first_uniq="$uniq2"; first_node0="$node2_0"
        second_idx=4; second_uniq="$uniq4"; second_node0="$node4_0"
    fi

    hw_info "iter ${i} — dropping both (higher-node pad, slot ${first_idx}, first — matches the issue's own trace)..."
    rig_destroy_pad "$first_idx" || hw_warn "iter ${i}: slot ${first_idx} pad destroy reported trouble"
    # Operator-observed 2026-08-02: a couple seconds between disconnects (and
    # reconnects, below) rather than back-to-back — the swap mechanism only
    # needs BOTH freed before the first recreate (kernel hands out the
    # lowest-free number at create time, not destroy time), so this spacing
    # doesn't defeat the swap, it just stops hammering the machine.
    sleep 2
    rig_destroy_pad "$second_idx" || hw_warn "iter ${i}: slot ${second_idx} pad destroy reported trouble"
    local _gone_deadline=$(( SECONDS + 15 ))
    while (( SECONDS < _gone_deadline )); do
        [[ -z "$(_recon_node_for_uniq "$first_uniq")" && -z "$(_recon_node_for_uniq "$second_uniq")" ]] && break
        sleep 0.3
    done

    hw_info "iter ${i} — reconnecting slot ${first_idx} first, then slot ${second_idx} (forcing the swap)..."
    rig_create_pad "$first_idx" || { hw_fail "iter ${i}: slot ${first_idx} recreate failed"; rig_cleanup; return 1; }
    _recon_wait_node "$first_uniq" 10 "$first_node0" >/dev/null || true
    sleep 2   # operator-observed pacing — see the destroy side's comment above
    rig_create_pad "$second_idx" || { hw_fail "iter ${i}: slot ${second_idx} recreate failed"; rig_cleanup; return 1; }
    _recon_wait_node "$second_uniq" 10 "$second_node0" >/dev/null || true

    local node2_1 node4_1
    node2_1="$(_recon_node_for_uniq "$uniq2")"
    node4_1="$(_recon_node_for_uniq "$uniq4")"
    hw_info "iter ${i}: post-swap — slot2=event${node2_1:-?} (was event$node2_0)  slot4=event${node4_1:-?} (was event$node4_0)"
    if [[ "$node2_1" != "$node4_0" || "$node4_1" != "$node2_0" ]]; then
        hw_warn "iter ${i}: the kernel-level swap itself didn't land cleanly this time (see Tier 1's scenario-2 finding — this can be inconsistent even with a live gap pad); the verification below may be inconclusive"
    fi

    # Give the FIFO event loop + slot_claim RESUME + _reconnect_repoint +
    # proxy_repoint_slot time to actually process both CONTROLLER_ADDs —
    # POLL for it, don't guess a sleep. Live evidence (evsieve's own logs,
    # captured separately) showed a permission-denied retry loop against
    # freshly-created uhid nodes running for tens of seconds before
    # self-healing — a fixed 8s was reading this mid-flight and reporting a
    # false "still mismatched" against something that was still settling,
    # not actually stuck. Poll up to 60s for BOTH links to resolve to their
    # expected targets; if they get there, check 2 below passes; if not,
    # THAT'S the real finding, not a premature snapshot.
    mcss_resolve_paths
    local want2="/dev/input/event${node2_1:-X}" want4="/dev/input/event${node4_1:-X}"
    local link2="" link4="" link_ok=0
    local _link_deadline=$(( SECONDS + 60 ))
    hw_info "iter ${i} — waiting (up to 60s) for both proxy symlinks to resolve..."
    while (( SECONDS < _link_deadline )); do
        link2=$(readlink -f "${MCSS_PROXY_PADS_DIR}/slot2" 2>/dev/null || true)
        link4=$(readlink -f "${MCSS_PROXY_PADS_DIR}/slot4" 2>/dev/null || true)
        if [[ "$link2" == "$want2" && "$link4" == "$want4" ]]; then
            link_ok=1
            break
        fi
        sleep 2
    done

    hw_dump_state

    # Check 1: state-file identity sanity (expected correct per the issue).
    local sf_uniq2 sf_uniq4
    sf_uniq2=$(jq -r '.slots["2"].phys_uniq // empty' "${SPLITSCREEN_STATE}" 2>/dev/null)
    sf_uniq4=$(jq -r '.slots["4"].phys_uniq // empty' "${SPLITSCREEN_STATE}" 2>/dev/null)
    if [[ "$sf_uniq2" == "$uniq2" && "$sf_uniq4" == "$uniq4" ]]; then
        hw_pass "iter ${i}: state-file identity correct (slot2=${uniq2}, slot4=${uniq4}) — matches the issue's own finding that this part is never the bug"
    else
        hw_warn "iter ${i}: state-file identity unexpected (slot2=${sf_uniq2:-?}, slot4=${sf_uniq4:-?}) — different failure mode than #151 describes, worth a closer look"
    fi

    # Check 2: symlink target — does each slot's proxy-pads symlink actually
    # point at THAT slot's own current physical node? (polled above)
    if (( link_ok )); then
        hw_pass "iter ${i}: symlink targets correct (slot2->${link2}, slot4->${link4})"
    else
        hw_fail "iter ${i}: symlink target MISMATCH after 60s — slot2->${link2:-<none>} (want ${want2}), slot4->${link4:-<none>} (want ${want4})"
    fi

    # Check 3: evsieve's own log for the issue's exact diagnostic signature.
    local log2="${MCSS_HELPER_DIR}/evsieve-slot2.log" log4="${MCSS_HELPER_DIR}/evsieve-slot4.log"
    local sig_pattern='EBUSY|failed to grab input device|capabilities of the reconnected device are different'
    local hit2 hit4
    hit2=$(grep -Ec "$sig_pattern" "$log2" 2>/dev/null || echo 0)
    hit4=$(grep -Ec "$sig_pattern" "$log4" 2>/dev/null || echo 0)
    if (( hit2 > 0 || hit4 > 0 )); then
        hw_fail "iter ${i}: #151 REPRODUCED — evsieve log signature found (slot2 hits=${hit2}, slot4 hits=${hit4})"
        hw_log "  --- slot2 log tail ---"; tail -n 5 "$log2" 2>/dev/null | sed 's/^/    /' >&2
        hw_log "  --- slot4 log tail ---"; tail -n 5 "$log4" 2>/dev/null | sed 's/^/    /' >&2
        rig_cleanup
        return 1
    else
        hw_pass "iter ${i}: no EBUSY/grab-failure signature in either slot's evsieve log"
    fi

    rig_cleanup
    if (( link_ok )); then
        hw_pass "iter ${i}: #151 did NOT reproduce this time — identity, symlinks, and evsieve logs all clean"
        return 0
    fi
    return 1
}

# _recon_teardown_and_recover: mirrors probe-burst-spawn.sh's proven-working
# teardown (hw_stop_orchestrator, now reliable since the kwin_wayland
# marker-gate fix landed the same night) plus the stale-FIFO/Steam-relaunch-
# race fix from that same file. NOT called from inside
# _recon_run_one_iteration itself (that function already calls rig_cleanup
# on every exit path) — this is the between-iterations step.
_recon_teardown_and_recover() {
    local i="$1"
    hw_info "iter ${i} — ending session..."
    hw_stop_orchestrator
    rig_cleanup
    rm -f "${SPLITSCREEN_FIFO:-}" 2>/dev/null || true
    hw_wait_for "iter ${i} Steam reaper released" 15 \
        bash -c '! pgrep -f "SteamLaunch.*minecraftSplitscreen" >/dev/null 2>&1' || \
        hw_warn "iter ${i}: Steam reaper still present 15s after teardown — next launch may race it"

    local mode
    mode=$(get_display_mode 2>>"${HW_LOG}")
    if [[ "$mode" != "docked" ]]; then
        hw_warn "iter ${i}: post-teardown display mode is '${mode}', not docked"
        hw_prompt "If the display looks stuck or black, clear it now on-device
  (Steam button -> Power -> Restart Steam), THEN press Enter to continue.
  Type 'skip' to stop the probe here instead." || return 1
    fi
    return 0
}

main() {
    mcss_workdir_init hardware || true
    HW_LOG="$(hw_log_path reconnect-swap)"; export HW_LOG
    export REPO_ROOT
    export SPLITSCREEN_STATE="$HOME/.local/share/PolyMC/splitscreen_state.json"
    export SPLITSCREEN_FIFO="/tmp/minecraft-splitscreen.fifo"
    export HW_PASSED=0 HW_FAILED=0 HW_SKIPPED=0
    hw_detect_display

    local iterations="${1:-${MCSS_RECONNECT_ITERATIONS:-3}}"
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
    if [[ "$mode" != "docked" ]]; then
        hw_fail "not docked (mode=${mode}) — connect the dock/external display before running this probe"
        rig_cleanup
        exit 1
    fi

    local -a results=()
    local i
    for (( i = 1; i <= iterations; i++ )); do
        if _recon_run_one_iteration "$i"; then
            results+=("clean")
        else
            results+=("REPRODUCED-or-error")
        fi

        if ! _recon_teardown_and_recover "$i"; then
            hw_skip "reconnect-swap probe stopped early by operator after iteration ${i}/${iterations}"
            break
        fi

        # Operator-observed 2026-08-02: iterations were launching again
        # almost the instant the previous one's teardown finished — four
        # real JVMs spun up and torn down, three times in a row, back to
        # back. A Steam-triggered watchdog restart was observed during a
        # run. Give the machine a real rest between iterations, not just
        # the teardown's own reaper-released check.
        if (( i < iterations )); then
            hw_info "iter ${i} — resting 20s before the next iteration..."
            sleep 20
        fi
    done

    hw_section "#151 reconnect-swap probe — summary"
    local idx clean=0 bad=0
    for idx in "${!results[@]}"; do
        hw_log "  iteration $(( idx + 1 )): ${results[$idx]}"
        [[ "${results[$idx]}" == "clean" ]] && clean=$(( clean + 1 )) || bad=$(( bad + 1 ))
    done
    hw_log "  ${clean}/${#results[@]} clean, ${bad}/${#results[@]} reproduced (or hit a setup error — check individual iteration logs above to tell them apart)"

    hw_log "Reconnect-swap probe: ${HW_PASSED} passed, ${HW_FAILED} failed, ${HW_SKIPPED} skipped — log: ${HW_LOG}"
    (( HW_FAILED == 0 )) && exit 0 || exit 1
}

main "$@"
