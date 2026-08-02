#!/bin/bash
set -uo pipefail

# =============================================================================
# probe-node-swap.sh — can we FORCE a real eventN swap between two pads?
# =============================================================================
# PR-5 of build plan #157 (issue #136), prerequisite for #151's repro.
#
# #151 ("node-swap race when 2+ pads disconnect at once and reclaim each
# other's freed eventN") needs the kernel to hand pad A the eventN pad B just
# vacated, and vice versa — a genuine two-way RENUMBER. PR-0's own probe
# (tests/probe-uhid-feasibility.sh, V8) tried the simplest version of this —
# destroy pad 1, recreate pad 1 — and got SAME_NODE every time: the just-freed
# number is the lowest free number, so the very next uhid create claims it
# right back. That result is why PLAN.md flags the swap case as still
# genuinely UNTESTED, not just unfixed — nobody has confirmed the underlying
# kernel-level condition #151 depends on can even be forced yet.
#
# HYPOTHESIS (Deck-validated 2026-08-02, see below): Linux's input core
# allocates event/js minor numbers lowest-free-first (standard kernel
# behavior, not specific to this project). If pad A's node is numerically
# LOWER than pad B's, and BOTH are destroyed before EITHER is recreated, then
# recreating B's identity FIRST should claim A's now-lower free node, and
# recreating A's identity SECOND should claim B's now-only-remaining free
# node — a genuine two-way swap, matching #151's repro ("P4 came back on P2's
# old node, P2 came back on P4's old node") exactly. V8 never tested this
# because it only ever destroyed+recreated ONE pad at a time, with nothing
# else contending for that number.
#
# TWO SCENARIOS, Deck-validated 2026-08-02 with very different confidence:
#   Scenario 1 (2pad): two pads only, both dropped and swapped. SWAPPED
#     cleanly on EVERY attempt (3/3) — this technique is solid.
#   Scenario 2 (3pad-gap): three pads — drop the OUTER two, leave the MIDDLE
#     one live throughout (the realistic #151 shape: a real 4-up session has
#     other players' pads still connected while two swap). Genuinely
#     INCONSISTENT across 3 attempts, including two with the IDENTICAL
#     starting node numbers that still produced different outcomes: one
#     clean swap, one confounded by an unrelated real physical controller
#     disconnecting mid-test (root-caused live, not this technique's fault),
#     and one where the "high" pad kept its own original node instead of
#     claiming "low"'s freed one and "low" landed on a third number neither
#     pad had touched — a pattern the lowest-free-number hypothesis alone
#     does not explain. NOT YET a reliable, on-demand repro technique.
#     Read literally, this might be a faithful finding rather than a probe
#     bug: #151 IS a race, and a live third pad may be exactly what
#     introduces the non-determinism — but that's not confirmed either.
#     Needs more attempts (and ideally a kernel-level explanation, not just
#     more data) before Tier 2 can lean on it.
#
# This probe tests ONLY the swap-forcing question — no orchestrator, no
# evsieve, no live session. Producing the actual PRODUCTION bug (wrong
# player's input driving the wrong instance) is Tier 2, deliberately NOT
# attempted here: building that against an unconfirmed swap technique would
# be designing against a guess. Scenario 1 alone is enough to unblock a FIRST
# Tier 2 attempt (a real 4-up docked session with MCSS_CONTROLLER_PROXY=1,
# forcing the swap on two of the four live pads via the scenario-1 technique,
# checking the state file / proxy symlinks land on the WRONG slot per #151's
# mechanism) — scenario 2's inconsistency should be treated as a known
# open question alongside it, not a blocker.
#
# USAGE (on the Deck, no dock/display required — this never launches a game.
# No OTHER controllers, real or otherwise, should be connected — see above):
#   bash tests/probe-node-swap.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/hardware/lib/helpers.sh"
source "$REPO_ROOT/modules/runtime_context.sh"
source "$REPO_ROOT/modules/controller_monitor.sh"
source "$SCRIPT_DIR/lib/uhid_rig.sh"

# _swap_node_for_uniq: the eventN the PRODUCTION enumerator currently reports
# for UNIQ, or empty if not present. Reuses _list_raw_external_pads rather
# than re-parsing /proc/bus/input/devices (ARCHITECTURE.md §2 — this project
# never re-implements enumeration outside controller_monitor.sh).
# Inputs:  $1 — uniq string
# Outputs: stdout — bare eventN (no "event" prefix), or empty.
_swap_node_for_uniq() {
    local uniq="$1"
    _list_raw_external_pads 2>/dev/null | awk -v u="$uniq" '$NF==u{print $1}'
}

# _swap_wait_node: poll until UNIQ's reported eventN is non-empty AND, if
# AVOID is given, different from it (used after a destroy+recreate so we
# don't read a stale enumerator line that hasn't refreshed yet).
# Inputs:  $1 — uniq, $2 — timeout_s, $3 — optional node to treat as stale
# Outputs: stdout — the node found (also on timeout, whatever was last seen)
#          return — 0 found a fresh node, 1 timed out
_swap_wait_node() {
    local uniq="$1" timeout_s="$2" avoid="${3:-}"
    local deadline=$(( SECONDS + timeout_s )) node=""
    while (( SECONDS < deadline )); do
        node="$(_swap_node_for_uniq "$uniq")"
        if [[ -n "$node" && ( -z "$avoid" || "$node" != "$avoid" ) ]]; then
            printf '%s\n' "$node"
            return 0
        fi
        sleep 0.3
    done
    printf '%s\n' "$node"
    return 1
}

# _swap_wait_gone: plain in-process poll for UNIQ_A and UNIQ_B both leaving
# the enumerator. NOT hw_wait_for: hw_wait_for runs its check via a fresh
# `bash -c`, which never sees this script's own functions (the same class of
# bug caught twice already in PR-3/PR-4 — stage3_hotplug.sh,
# probe-burst-spawn.sh).
# Inputs:  $1 — uniq_a, $2 — uniq_b, $3 — timeout_s
_swap_wait_gone() {
    local uniq_a="$1" uniq_b="$2" timeout_s="$3"
    local deadline=$(( SECONDS + timeout_s ))
    while (( SECONDS < deadline )); do
        [[ -z "$(_swap_node_for_uniq "$uniq_a")" && -z "$(_swap_node_for_uniq "$uniq_b")" ]] && return 0
        sleep 0.3
    done
    return 1
}

# _swap_run_scenario: create pads at LOW_IDX [GAP_IDX] HIGH_IDX (in that
# order — GAP_IDX, if given, stays live the whole time), destroy LOW_IDX and
# HIGH_IDX, recreate HIGH_IDX's identity first then LOW_IDX's, and report
# whether a clean two-way swap happened. GAP_IDX empty = plain 2-pad
# scenario; GAP_IDX set = the more realistic "other players still connected"
# shape.
# Inputs:  $1 — scenario label (for logging), $2 — low rig index,
#   $3 — high rig index, $4 — optional gap rig index (empty = 2-pad scenario)
# Outputs: return — 0 SWAPPED, 1 anything else (NO SWAP / PARTIAL / error)
_swap_run_scenario() {
    local label="$1" low_idx="$2" high_idx="$3" gap_idx="${4:-}"
    hw_section "Scenario: ${label}"

    local uniq_low uniq_high uniq_gap=""
    uniq_low="$(rig_default_uniq "$low_idx")"
    uniq_high="$(rig_default_uniq "$high_idx")"
    [[ -n "$gap_idx" ]] && uniq_gap="$(rig_default_uniq "$gap_idx")"

    hw_info "Creating low pad ($uniq_low)${gap_idx:+, gap pad ($uniq_gap)}, then high pad ($uniq_high)..."
    if ! rig_create_pad "$low_idx"; then
        hw_fail "${label}: low pad failed to create"; rig_cleanup; return 1
    fi
    if [[ -n "$gap_idx" ]] && ! rig_create_pad "$gap_idx"; then
        hw_fail "${label}: gap pad failed to create"; rig_cleanup; return 1
    fi
    if ! rig_create_pad "$high_idx"; then
        hw_fail "${label}: high pad failed to create"; rig_cleanup; return 1
    fi

    local node_low0 node_high0 node_gap0=""
    node_low0="$(_swap_wait_node "$uniq_low" 10)" || { hw_fail "${label}: low pad never enumerated"; rig_cleanup; return 1; }
    node_high0="$(_swap_wait_node "$uniq_high" 10)" || { hw_fail "${label}: high pad never enumerated"; rig_cleanup; return 1; }
    if [[ -n "$gap_idx" ]]; then
        node_gap0="$(_swap_wait_node "$uniq_gap" 10)" || { hw_fail "${label}: gap pad never enumerated"; rig_cleanup; return 1; }
    fi
    hw_info "Initial: low=event${node_low0}${gap_idx:+  gap=event${node_gap0}(stays live)}  high=event${node_high0}"

    if [[ "$node_low0" == "$node_high0" ]]; then
        hw_fail "${label}: low and high pads enumerated on the SAME node ($node_low0) — enumerator/dedup problem, aborting"
        rig_cleanup; return 1
    fi

    hw_info "Destroying low and high pads (matching #151's repro: two down at once)${gap_idx:+ — gap pad stays live}..."
    rig_destroy_pad "$low_idx" || hw_warn "${label}: low pad destroy reported trouble"
    rig_destroy_pad "$high_idx" || hw_warn "${label}: high pad destroy reported trouble"
    _swap_wait_gone "$uniq_low" "$uniq_high" 15 || \
        hw_warn "${label}: enumerator still shows a stale entry after 15s — proceeding anyway, the recreate below will surface it"

    hw_info "Recreating in REVERSE order (high's identity first, then low's)..."
    if ! rig_create_pad "$high_idx"; then
        hw_fail "${label}: high pad (recreated first) failed to create"; rig_cleanup; return 1
    fi
    local node_high1
    node_high1="$(_swap_wait_node "$uniq_high" 10 "$node_high0")" || true
    hw_info "high recreated -> event${node_high1:-?} (was event$node_high0)"

    if ! rig_create_pad "$low_idx"; then
        hw_fail "${label}: low pad (recreated second) failed to create"; rig_cleanup; return 1
    fi
    local node_low1
    node_low1="$(_swap_wait_node "$uniq_low" 10 "$node_low0")" || true
    hw_info "low recreated -> event${node_low1:-?} (was event$node_low0)"

    local node_gap1=""
    [[ -n "$gap_idx" ]] && node_gap1="$(_swap_node_for_uniq "$uniq_gap")"

    hw_log "  Before: low=event${node_low0}${gap_idx:+  gap=event${node_gap0}}  high=event${node_high0}"
    hw_log "  After:  low=event${node_low1:-?}${gap_idx:+  gap=event${node_gap1:-?}}  high=event${node_high1:-?}"

    local verdict=1
    if [[ -n "$node_low1" && -n "$node_high1" && "$node_low1" == "$node_high0" && "$node_high1" == "$node_low0" ]]; then
        hw_pass "${label}: SWAPPED — low now holds high's old node and high now holds low's old node."
        verdict=0
    elif [[ "$node_low1" == "$node_low0" && "$node_high1" == "$node_high0" ]]; then
        hw_fail "${label}: NO SWAP — both pads landed back on their OWN original nodes (matches V8's SAME_NODE finding)."
    else
        hw_warn "${label}: PARTIAL/UNEXPECTED — some renumbering happened but not a clean two-way swap. Likely a THIRD node (real controller or other system device) churned mid-test — rerun with nothing else connected before treating this as a technique failure."
    fi

    if [[ -n "$gap_idx" && -n "$node_gap1" && "$node_gap1" != "$node_gap0" ]]; then
        hw_fail "${label}: gap pad (never touched) changed node too — $node_gap0 -> $node_gap1 — something disturbed a pad we never destroyed"
        verdict=1
    fi

    rig_cleanup
    return $verdict
}

main() {
    mcss_workdir_init hardware || true
    HW_LOG="$(hw_log_path node-swap)"; export HW_LOG
    export HW_PASSED=0 HW_FAILED=0 HW_SKIPPED=0

    if ! rig_init; then
        hw_fail "rig_init failed — see stderr above"
        exit 1
    fi
    rig_install_traps || hw_warn "rig_install_traps refused (a trap already existed)"

    hw_section "Node-swap forcing probe (#151 prerequisite)"

    local s1=1 s2=1
    _swap_run_scenario "1: plain 2-pad swap" 1 2 && s1=0
    _swap_run_scenario "2: 3-pad, live gap in the middle" 1 3 2 && s2=0

    hw_section "Overall summary"
    hw_log "  Scenario 1 (2-pad):        $([[ $s1 -eq 0 ]] && echo SWAPPED || echo "did not swap cleanly")"
    hw_log "  Scenario 2 (3-pad w/ gap): $([[ $s2 -eq 0 ]] && echo SWAPPED || echo "did not swap cleanly")"
    if [[ $s1 -eq 0 && $s2 -eq 0 ]]; then
        hw_log "  Both scenarios confirm the swap is forceable — #151's precondition is real; Tier 2 (the live-session production repro) is unblocked."
    fi

    hw_log "Node-swap probe: ${HW_PASSED} passed, ${HW_FAILED} failed, ${HW_SKIPPED} skipped — log: ${HW_LOG}"
    (( HW_FAILED == 0 )) && exit 0 || exit 1
}

main "$@"
