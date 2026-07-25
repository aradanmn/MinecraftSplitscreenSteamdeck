#!/bin/bash
set -euo pipefail

# =============================================================================
# SLOT MANAGER MODULE  (#38 M2 / PR-a)
# =============================================================================
# The single owner of per-slot controller state and the reconnect intent
# policy. Event handlers (CONTROLLER_ADD / CONTROLLER_REMOVE / SLOT_DIED) must
# hold NO policy of their own — they translate a raw device event into ONE
# manager verb and execute the returned outcome. This keeps "which slot does a
# (re)connecting pad belong to" in exactly one testable place.
#
# Design: docs/DESIGN-38-RECONNECT-WIRING.md  (decisions locked 2026-07-25).
#
# DARK ON ARRIVAL (PR-a): this module is sourced but has ZERO runtime callers —
# the orchestrator is not rewired to use it until PR-c, and the proxy launch
# path lands in PR-b behind MCSS_PROXY_ENABLE. So PR-a changes NO behavior; it
# adds the module + its hardware-free unit-test decision matrix. Pure state +
# policy: no FIFO, no bwrap, no evsieve.
#
# Public API:
#   -- GET (pure queries; no mutation) --
#   slot_find_by_uniq(uniq)            — stdout: active slot(s) with phys_uniq==uniq
#   slot_find_by_event_node(ev)        — stdout: active slot whose event_node==ev
#   slot_find_free()                   — stdout: lowest inactive slot; return 1 if none
#   slot_find_abandoned_within(grace)  — stdout: newest disconnected slot within grace
#   slot_is_disconnected(slot)         — exit 0 if slot active AND disconnected
#   -- SET (transitions; POLICY lives in slot_claim, nowhere else) --
#   slot_claim(uniq,vendor,product,ev) — stdout: "<OUTCOME> [slot]" and mutates
#       state accordingly. OUTCOME ∈ SPAWN|RESUME|ADOPT|REJECT.
#   slot_reserve(slot,uniq,vendor,product,ev)  — low-level identity write
#   slot_touch(slot,ev)                — refresh event_node, clear disconnected
#   -- RELEASE --
#   slot_release(ev|slot)              — controller gone: mark disconnected+ts,
#                                        KEEP the instance (#37 sticky)
#   slot_free(slot)                    — hard free: clear the whole slot record
#
# Globals PROVIDED: MCSS_RECONNECT_GRACE_S (readonly module constant, default
#   180 — how long after a disconnect an UNKNOWN pad is assumed to be the same
#   player returning with a different controller, per the locked Q1 decision).
# Globals CONSUMED: SPLITSCREEN_STATE, MCSS_MAX_PLAYERS (from runtime_context);
#   MCSS_TEST_NOW (test-only epoch override, see _slot_now).
# Depends (sourced before this module by the orchestrator prologue, or by the
#   test): instance_lifecycle's state I/O — update_slot_state (the flock-guarded
#   canonical writer; NOT re-implemented here), read_state, _get_slot_field,
#   slot_is_active. PR-c retires the orchestrator's near-duplicate
#   _find_free_slot / _find_slot_by_uniq / _find_slot_by_event_node in favor of
#   the slot_find_* verbs here (this module becomes the canonical home).
#
# Slot record fields this module owns on .slots["N"] (reusing the existing
#   schema; only phys_vendor/phys_product/disconnected/disconnected_at are new —
#   event_node/js_node/phys_uniq/active already exist):
#     active event_node js_node phys_uniq phys_vendor phys_product
#     disconnected disconnected_at
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.0 2026-07-25  #38 M2/PR-a: dark module — slot record schema, GET/SET/
#                    RELEASE surface, slot_claim resume-first-with-grace policy
# =============================================================================

# Ride runtime_context for SPLITSCREEN_STATE / MCSS_MAX_PLAYERS resolution.
# Idempotent (process-local sentinels), same pattern as dock_detection.sh.
source "$(dirname "${BASH_SOURCE[0]}")/runtime_context.sh"

# --- Module-level constants (guarded, house pattern) ---
if [[ -z "${_SLOT_MANAGER_CONSTANTS_LOCKED:-}" ]]; then
    # Q1 (locked 2026-07-25): 180s covers a battery swap but excludes a genuine
    # new player. Overridable via the environment for tuning/tests.
    readonly MCSS_RECONNECT_GRACE_S="${MCSS_RECONNECT_GRACE_S:-180}"
    _SLOT_MANAGER_CONSTANTS_LOCKED=1   # process-local — NOT exported
fi

# --- Internal ---

# _slot_now: current epoch seconds, with a test override. A timed loop-free
# clock: MCSS_TEST_NOW makes the grace-window logic deterministic in unit tests
# (the suite can't call date and expect a stable answer). Runtime uses date.
_slot_now() {
    if [[ -n "${MCSS_TEST_NOW:-}" ]]; then
        printf '%s\n' "$MCSS_TEST_NOW"
    else
        date +%s
    fi
}

# _slot_state: read the whole state JSON once (delegates to instance_lifecycle's
# read_state, which returns "null" when the file is missing/invalid).
_slot_state() {
    read_state
}

# --- GET ---

# slot_find_by_uniq: active slot(s) whose phys_uniq matches. May emit >1 line
# only for genuinely duplicated (counterfeit) MACs — real BT pads are unique
# (DS4 + Xbox verified), so callers treat multi-match as the theoretical
# safety-net case (design §5). Empty uniq NEVER matches (a blank key must never
# sticky-collide — same rule as the retired _find_slot_by_uniq).
slot_find_by_uniq() {
    local uniq="$1" state
    [[ -n "$uniq" ]] || return 0
    state=$(_slot_state)
    [[ "$state" == "null" ]] && return 0
    jq -r --arg u "$uniq" \
        '.slots | to_entries[]
         | select(.value.active == true and .value.phys_uniq == $u)
         | .key' <<< "$state" 2>/dev/null
}

# slot_find_by_event_node: the active slot currently bound to event node $1.
slot_find_by_event_node() {
    local node="$1" state
    [[ -n "$node" ]] || return 0
    state=$(_slot_state)
    [[ "$state" == "null" ]] && return 0
    jq -r --arg n "$node" \
        'first(.slots | to_entries[]
         | select(.value.active == true and .value.event_node == $n)
         | .key) // empty' <<< "$state" 2>/dev/null
}

# slot_find_free: lowest inactive slot in 1..MCSS_MAX_PLAYERS.
# Outputs: stdout — the free slot; return 1 if all slots are full.
slot_find_free() {
    local slot
    for slot in $(seq 1 "${MCSS_MAX_PLAYERS:-4}"); do
        if ! slot_is_active "$slot" 2>/dev/null; then
            printf '%s\n' "$slot"
            return 0
        fi
    done
    return 1
}

# slot_is_disconnected: exit 0 iff the slot is active AND flagged disconnected
# (an abandoned slot — instance preserved, controller gone).
slot_is_disconnected() {
    local slot="$1"
    slot_is_active "$slot" 2>/dev/null || return 1
    [[ "$(_get_slot_field "$slot" disconnected false)" == "true" ]]
}

# slot_find_abandoned_within: the MOST-RECENTLY-abandoned slot whose disconnect
# is within GRACE seconds of now. Empty if none qualify.
# Inputs: $1 — grace seconds (default MCSS_RECONNECT_GRACE_S)
# Outputs: stdout — slot number, or empty
# shellcheck disable=SC2120  # slot_claim calls this bare, relying on the default
slot_find_abandoned_within() {
    local grace="${1:-$MCSS_RECONNECT_GRACE_S}" now state
    now=$(_slot_now)
    state=$(_slot_state)
    [[ "$state" == "null" ]] && return 0
    # Pick disconnected slots with (now - disconnected_at) <= grace, newest first.
    jq -r --argjson now "$now" --argjson grace "$grace" \
        '[.slots | to_entries[]
          | select(.value.active == true and .value.disconnected == true
                   and .value.disconnected_at != null
                   and ($now - .value.disconnected_at) <= $grace)]
         | sort_by(.value.disconnected_at) | reverse | first | .key // empty' \
        <<< "$state" 2>/dev/null
}

# slot_find_abandoned_any: newest abandoned slot regardless of age (used only on
# the "session full" branch, where adopting the orphan is the sole physical
# option — no 5th instance is ever possible, #70).
slot_find_abandoned_any() {
    local state
    state=$(_slot_state)
    [[ "$state" == "null" ]] && return 0
    jq -r '[.slots | to_entries[]
            | select(.value.active == true and .value.disconnected == true
                     and .value.disconnected_at != null)]
           | sort_by(.value.disconnected_at) | reverse | first | .key // empty' \
        <<< "$state" 2>/dev/null
}

# --- SET ---

# slot_reserve: write a slot's full identity + mark it active and connected.
# Used by slot_claim for SPAWN and (with overwrite) for ADOPT.
slot_reserve() {
    local slot="$1" uniq="$2" vendor="$3" product="$4" ev="$5"
    update_slot_state "$slot" "$(jq -n \
        --arg u "$uniq" --arg vn "$vendor" --arg pr "$product" --arg ev "$ev" \
        '{active:true, phys_uniq:$u, phys_vendor:$vn, phys_product:$pr,
          event_node:$ev, disconnected:false, disconnected_at:null}')"
}

# slot_touch: a same-pad return — refresh the (churned) event node and clear the
# abandoned flag, WITHOUT touching identity (RESUME keeps the same controller).
slot_touch() {
    local slot="$1" ev="$2"
    update_slot_state "$slot" "$(jq -n --arg ev "$ev" \
        '{event_node:$ev, disconnected:false, disconnected_at:null}')"
}

# slot_claim: THE decision verb (resume-first-with-grace, design §5). Given a
# physical pad, mutate state to reserve/refresh the winning slot and echo the
# outcome the caller must execute.
# Inputs:
#   $1 uniq  $2 vendor  $3 product  $4 event_node (the js-owner node — §7)
# Outputs:
#   stdout — "RESUME <slot>" | "ADOPT <slot>" | "SPAWN <slot>" | "REJECT"
#   side effects — reserves/refreshes the chosen slot's record (none on REJECT)
slot_claim() {
    local uniq="$1" vendor="$2" product="$3" ev="$4"
    local slot free aband

    # 1. KNOWN MAC → resume its slot (identity definitive; no time limit).
    if [[ -n "$uniq" ]]; then
        slot=$(slot_find_by_uniq "$uniq" | head -n 1)   # newest/first; multi only on clones
        if [[ -n "$slot" ]]; then
            if slot_is_disconnected "$slot"; then
                slot_touch "$slot" "$ev"
                printf 'RESUME %s\n' "$slot"
                return 0
            fi
            # Already active+connected — a duplicate/echo add. No-op.
            printf 'REJECT\n'
            return 0
        fi
    fi

    # 2. UNKNOWN MAC → grace policy.
    free=$(slot_find_free || true)
    if [[ -z "$free" ]]; then
        # Session full: adopt an orphan if there is one (the only physical
        # option — 4-up ceiling means no 5th instance). Age-agnostic here.
        aband=$(slot_find_abandoned_any)
        if [[ -n "$aband" ]]; then
            slot_reserve "$aband" "$uniq" "$vendor" "$product" "$ev"
            printf 'ADOPT %s\n' "$aband"
            return 0
        fi
        printf 'REJECT\n'
        return 0
    fi

    # A free slot exists: within grace, adopt the orphan (same human, new stick);
    # past grace, treat as a genuine new player and spawn.
    aband=$(slot_find_abandoned_within)
    if [[ -n "$aband" ]]; then
        slot_reserve "$aband" "$uniq" "$vendor" "$product" "$ev"
        printf 'ADOPT %s\n' "$aband"
        return 0
    fi

    slot_reserve "$free" "$uniq" "$vendor" "$product" "$ev"
    printf 'SPAWN %s\n' "$free"
    return 0
}

# --- RELEASE ---

# slot_release: a controller dropped (dead battery / idle power-off). Mark the
# slot disconnected + stamp the time; PRESERVE the instance (#37 sticky) so the
# grace/abandoned logic can adopt or resume it. Accepts a slot number or the
# removed controller's event node (controller_monitor emits the node).
slot_release() {
    local arg="$1" slot
    if [[ "$arg" =~ ^[1-9][0-9]*$ ]]; then
        slot="$arg"
    else
        slot=$(slot_find_by_event_node "$arg")
    fi
    [[ -n "$slot" ]] || { echo "[slot_manager] slot_release: no active slot for '$arg'" >&2; return 0; }
    slot_is_active "$slot" 2>/dev/null || { echo "[slot_manager] slot_release: slot $slot not active" >&2; return 0; }
    update_slot_state "$slot" "$(jq -n --argjson t "$(_slot_now)" \
        '{disconnected:true, disconnected_at:$t}')"
}

# slot_free: a real player-leave (game window destroyed → SLOT_DIED). Hard-free
# the slot: drop active + the whole identity so slot_find_free can reissue it.
slot_free() {
    local slot="$1"
    update_slot_state "$slot" "$(jq -n \
        '{active:false, disconnected:false, disconnected_at:null,
          phys_uniq:null, phys_vendor:null, phys_product:null, event_node:null}')"
}
