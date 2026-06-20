#!/bin/bash
# =============================================================================
# Phase B Test: Dynamic lifecycle with real instances
# =============================================================================
# Simulates controller connect/disconnect lifecycle via the orchestrator's
# SPLITSCREEN_FIFO without requiring physical controllers.
# Tests: spawn timing, layout reflow, teardown correctness, mode transitions.
#
# Usage:
#   bash tests/test_phase_b_lifecycle.sh [test_number]
#
# Test numbers:
#   1 — Handheld: 1 player joins, plays, quits → clean teardown
#   2 — Docked: 2 players join sequentially, reflow, 1 quits → reflow
#   3 — Docked: 3 players join, 2 quit → reflow to 1
#   4 — Docked: Max 4 players, 5th ignored
#   5 — Docked→Handheld: 2+ players active, undock → keeps P1 only
#   6 — Load timing: measure real load time under render contention
#   7 — Full lifecycle: 4 players, P2 dies mid-session, P4 quits cleanly
# All (default) — run all tests in sequence
# =============================================================================

set -uo pipefail   # no -e: individual test failures must not abort the harness

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$HOME/splitscreen-phase-b-test.log"

# ── Orchestrator FIFO path (must match what orchestrator.sh uses) ──────────
FIFO="${SPLITSCREEN_FIFO:-/tmp/minecraft-splitscreen.fifo}"

# ── Production state-query functions (jq-based, no module sourcing needed) ──
# These match the implementations in modules/instance_lifecycle.sh exactly.
_state_file() { echo "${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"; }

slot_is_active() {
    jq -e ".slots[\"$1\"].active == true" "$(_state_file)" >/dev/null 2>&1
}

get_active_slots() {
    jq -r '[.slots | to_entries[] | select(.value.active == true) | .key | tonumber] | sort | join(" ")' \
        "$(_state_file)" 2>/dev/null
}

# ── Helpers ─────────────────────────────────────────────────────────────────
_pass() { echo "[PASS] $*" | tee -a "$LOG"; }
_fail() { echo "[FAIL] $*" | tee -a "$LOG"; }
_info() { echo "[Info] $*" | tee -a "$LOG"; }
_header() {
    echo "" | tee -a "$LOG"
    echo "==============================================================" | tee -a "$LOG"
    echo "  $*" | tee -a "$LOG"
    echo "==============================================================" | tee -a "$LOG"
}

# Wait for a slot to become active in the state file (timeout in seconds)
_wait_for_slot_active() {
    local slot="$1" timeout_s="${2:-60}" label="${3:-}"
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    local deadline=$(( $(date +%s) + timeout_s ))
    while [[ $(date +%s) -lt $deadline ]]; do
        if jq -e ".slots[\"$slot\"].active == true" "$state" >/dev/null 2>&1; then
            local elapsed=$(( $(date +%s) - deadline + timeout_s ))
            [[ -n "$label" ]] && _info "$label: slot $slot active after ${elapsed}s"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

_wait_for_slot_inactive() {
    local slot="$1" timeout_s="${2:-15}" label="${3:-}"
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    local deadline=$(( $(date +%s) + timeout_s ))
    while [[ $(date +%s) -lt $deadline ]]; do
        if jq -e ".slots[\"$slot\"].active != true" "$state" >/dev/null 2>&1; then
            [[ -n "$label" ]] && _info "$label: slot $slot inactive ✅"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

_get_active_count() {
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    jq '[.slots[] | select(.active == true)] | length' "$state" 2>/dev/null || echo 0
}

_get_slot_pid() {
    local slot="$1"
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    # Return java PID if present, else bwrap PID.
    # For slots 2-4, the bwrap process exits immediately after SingleApp forwarding
    # (PolyMC detects slot 1's primary and routes -l there), so bwrap_pid is dead.
    # The Java PID is what actually lives on.
    jq -r ".slots[\"$slot\"].pid // .slots[\"$slot\"].bwrap_pid // empty" "$state" 2>/dev/null
}

_slot_pid_alive() {
    local slot="$1"
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    # Check java PID first, then bwrap PID — either alive means the instance is running
    local java_pid bwrap_pid
    java_pid=$(jq -r ".slots[\"$slot\"].pid // empty" "$state" 2>/dev/null)
    bwrap_pid=$(jq -r ".slots[\"$slot\"].bwrap_pid // empty" "$state" 2>/dev/null)
    [[ -n "$java_pid"  ]] && kill -0 "$java_pid"  2>/dev/null && return 0
    [[ -n "$bwrap_pid" ]] && kill -0 "$bwrap_pid" 2>/dev/null && return 0
    return 1
}

# Wait for Minecraft to reach the main menu by polling latest.log for
# "Sound engine started".  This is the real readiness signal — active=true
# in the state file only means the bwrap process started, not that the game
# is loaded.  Timeout default: 360s (Minecraft can take 3-6 min under load).
_wait_for_minecraft_ready() {
    local slot="$1" timeout_s="${2:-360}" label="${3:-slot $slot}"
    local launcher_dir="${INSTANCE_LIFECYCLE_LAUNCHER_DIR:-$HOME/.local/share/PolyMC}"
    local log="${launcher_dir}/instances/latestUpdate-${slot}/.minecraft/logs/latest.log"
    local deadline=$(( $(date +%s) + timeout_s ))
    _info "$label: waiting for Minecraft main menu (Sound engine started) …"
    while [[ $(date +%s) -lt $deadline ]]; do
        if grep -q "Sound engine started" "$log" 2>/dev/null; then
            local elapsed=$(( $(date +%s) - deadline + timeout_s ))
            _info "$label: Minecraft ready after ${elapsed}s"
            return 0
        fi
        sleep 5
    done
    _fail "$label: Minecraft did not reach main menu within ${timeout_s}s"
    return 1
}

# Truncate a slot's latest.log before spawning so _wait_for_minecraft_ready
# does not see "Sound engine started" from the PREVIOUS run's log (Minecraft
# rotates the log at JVM startup, but that rotation happens after we start
# polling, so a stale log causes an immediate false-positive on second+ tests).
_prep_slot() {
    local slot="$1"
    local launcher_dir="${INSTANCE_LIFECYCLE_LAUNCHER_DIR:-$HOME/.local/share/PolyMC}"
    : > "${launcher_dir}/instances/latestUpdate-${slot}/.minecraft/logs/latest.log" 2>/dev/null || true
}

# Inject a message into the FIFO.
# Writes in the background so a temporary gap in the orchestrator restart loop
# doesn't block forever, AND so we can wait while spawn_instance is blocking
# docked_flow (up to 120s polling for Java PID + X window per slot).
_inject() {
    local msg="$1"
    _info "INJECT: $msg"
    echo "$msg" > "$FIFO" &
    local write_pid=$!
    local i
    for i in $(seq 1 400); do   # up to 200s: _poll_for_java(60s) + _poll_for_window(120s) + buffer
        sleep 0.5
        if ! kill -0 "$write_pid" 2>/dev/null; then
            return 0   # write was consumed by the orchestrator
        fi
    done
    kill "$write_pid" 2>/dev/null || true
    _fail "FIFO write not consumed within 200s — orchestrator not reading ($FIFO)"
    return 1
}

# Best-effort drain of any instances a test left running (e.g., early bail-out).
# Does NOT kill kwin_wayland or the parent minecraftSplitscreen.sh — the parent's
# EXIT trap handles those.  Uses direct FIFO writes rather than _inject() because
# the orchestrator may have died already.
_clean_instances() {
    [[ -p "$FIFO" ]] || return 0
    local slot
    for slot in 1 2 3 4; do
        if slot_is_active "$slot" 2>/dev/null; then
            _info "cleanup: slot $slot still active — sending SLOT_DIED"
            echo "SLOT_DIED $slot" > "$FIFO" 2>/dev/null || true
        fi
    done
    sleep 5
}

# ── Test 1: Handheld — single player lifecycle ────────────────────────────
test_handheld_single_player() {
    _header "Test 1: Handheld — single player joins, plays, quits"

    # Ensure mode is handheld
    _inject "DISPLAY_MODE_CHANGE handheld"
    sleep 1

    # /dev/null as device: bwrap binds it successfully, SDL sees a dead device,
    # Minecraft loads without controller input.
    local slot=1
    if ! slot_is_active "$slot" 2>/dev/null; then
        _prep_slot "$slot"
        _inject "CONTROLLER_ADD /dev/null /dev/null"
    else
        _info "Slot $slot already active — skipping ADD"
    fi

    if _wait_for_slot_active "$slot" 30 "Test 1"; then
        _pass "Test 1.1 — Slot $slot bwrap started"
    else
        _fail "Test 1.1 — Slot $slot bwrap did not start within 30s"
        return
    fi

    # Wait for Minecraft to reach the main menu
    _wait_for_minecraft_ready "$slot" 360 "Test 1" || { return; }

    # Verify PID is alive
    if _slot_pid_alive "$slot"; then
        _pass "Test 1.2 — PID for slot $slot is alive"
    else
        _fail "Test 1.2 — PID for slot $slot is not alive"
    fi

    # Simulate player quit / death
    _inject "SLOT_DIED $slot"

    if _wait_for_slot_inactive "$slot" 30 "Test 1"; then
        _pass "Test 1.3 — Slot $slot properly torn down after SLOT_DIED"
    else
        _fail "Test 1.3 — Slot $slot still active after SLOT_DIED"
    fi

    # Verify PID is gone
    if _slot_pid_alive "$slot"; then
        _fail "Test 1.4 — PID still alive after teardown (leak!)"
    else
        _pass "Test 1.4 — PID reaped after teardown"
    fi
}

# ── Test 2: Docked — 2 players join, reflow, 1 quits ─────────────────────
test_docked_two_players() {
    _header "Test 2: Docked — 2 players sequential, reflow, 1 quits"

    _inject "DISPLAY_MODE_CHANGE docked"
    sleep 1

    # Player 1 connects → slot 1
    _prep_slot 1
    _inject "CONTROLLER_ADD /dev/null /dev/null"
    if _wait_for_slot_active 1 30 "Test 2"; then
        _pass "Test 2.1 — Slot 1 bwrap started"
    else
        _fail "Test 2.1 — Slot 1 did not start"
        return
    fi
    _wait_for_minecraft_ready 1 360 "Test 2-P1" || { return; }

    local count_1
    count_1=$(get_active_slots 2>/dev/null | wc -w)
    _info "Active slots after P1: $count_1"

    # Player 2 connects → slot 2
    _prep_slot 2
    _inject "CONTROLLER_ADD /dev/null /dev/null"
    if _wait_for_slot_active 2 30 "Test 2"; then
        _pass "Test 2.2 — Slot 2 bwrap started"
    else
        _fail "Test 2.2 — Slot 2 did not start"
        return
    fi
    _wait_for_minecraft_ready 2 360 "Test 2-P2" || { return; }

    sleep 3  # Allow reflow to complete

    # Verify layout reflowed (2 windows now)
    local count_2
    count_2=$(get_active_slots 2>/dev/null | wc -w)
    _info "Active slots after P2: $(get_active_slots 2>/dev/null)"

    # P2 disconnects → slot 2 teardown + reflow
    _inject "CONTROLLER_REMOVE 2"
    if _wait_for_slot_inactive 2 30 "Test 2"; then
        _pass "Test 2.3 — Slot 2 torn down on disconnect"
    else
        _fail "Test 2.3 — Slot 2 still active after disconnect"
    fi

    # Verify slot 1 still alive
    if _slot_pid_alive 1; then
        _pass "Test 2.4 — Slot 1 survives P2 disconnect"
    else
        _fail "Test 2.4 — Slot 1 died when P2 disconnected (regression)"
    fi

    # Clean up remaining P1
    _inject "SLOT_DIED 1"
    _wait_for_slot_inactive 1 15 "Test 2 cleanup"
}

# ── Test 3: Docked — 3 players, 2 sequential quits ────────────────────────
test_docked_three_players() {
    _header "Test 3: Docked — 3 players join, 2 quit sequentially"

    _inject "DISPLAY_MODE_CHANGE docked"
    sleep 1

    for slot in 1 2 3; do
        _prep_slot "$slot"
        _inject "CONTROLLER_ADD /dev/null /dev/null"
        if _wait_for_slot_active "$slot" 30 "Test 3"; then
            _pass "Test 3.1 — Slot $slot bwrap started"
        else
            _fail "Test 3.1 — Slot $slot did not start"
            return
        fi
        _wait_for_minecraft_ready "$slot" 360 "Test 3-P${slot}" || { return; }
    done

    sleep 3  # Allow reflow

    local count
    count=$(get_active_slots 2>/dev/null | wc -w)
    _info "Active slots: $(get_active_slots 2>/dev/null)"

    # P3 disconnects
    _inject "CONTROLLER_REMOVE 3"
    if _wait_for_slot_inactive 3 30 "Test 3"; then
        _pass "Test 3.2 — Slot 3 torn down"
    else
        _fail "Test 3.2 — Slot 3 still active"
    fi

    # Verify 1+2 remain
    if slot_is_active 1 2>/dev/null && slot_is_active 2 2>/dev/null; then
        _pass "Test 3.3 — Slots 1 and 2 survive after P3 leaves"
    else
        _fail "Test 3.3 — Slot 1 or 2 incorrectly torn down"
    fi

    # P1 disconnects
    _inject "CONTROLLER_REMOVE 1"
    if _wait_for_slot_inactive 1 30 "Test 3"; then
        _pass "Test 3.4 — Slot 1 torn down"
    else
        _fail "Test 3.4 — Slot 1 still active"
    fi

    # Verify only P2 remains
    if slot_is_active 2 2>/dev/null; then
        _pass "Test 3.5 — Slot 2 survives, alone"
    else
        _fail "Test 3.5 — Slot 2 incorrectly torn down"
    fi

    _inject "SLOT_DIED 2"
    _wait_for_slot_inactive 2 15 "Test 3 cleanup"
}

# ── Test 4: Max 4, 5th ignored ────────────────────────────────────────────
test_max_four() {
    _header "Test 4: Docked — max 4 players, 5th controller ignored"

    _inject "DISPLAY_MODE_CHANGE docked"
    sleep 1

    for slot in 1 2 3 4; do
        _prep_slot "$slot"
        _inject "CONTROLLER_ADD /dev/null /dev/null"
        _wait_for_slot_active "$slot" 30 "Test 4" || { _fail "Test 4.1 — Slot $slot did not start"; return; }
        _wait_for_minecraft_ready "$slot" 360 "Test 4-P${slot}" || { return; }
    done

    _info "Test 4: 4 slots should be active now"
    local active
    active=$(get_active_slots 2>/dev/null | wc -w)
    if (( active == 4 )); then
        _pass "Test 4.2 — 4 slots active"
    else
        _fail "Test 4.2 — Expected 4 active, got $active"
    fi

    # 5th controller — should be ignored (all 4 slots full)
    _inject "CONTROLLER_ADD /dev/null /dev/null"
    sleep 2
    active=$(get_active_slots 2>/dev/null | wc -w)
    if (( active == 4 )); then
        _pass "Test 4.3 — 5th controller correctly ignored (still 4 active)"
    else
        _fail "Test 4.3 — Expected 4 active after 5th add, got $active"
    fi

    # Clean up all — wait for each teardown to complete before the next test
    for slot in 1 2 3 4; do
        _inject "SLOT_DIED $slot"
        _wait_for_slot_inactive "$slot" 30 "Test 4 cleanup slot $slot"
    done
}

# ── Test 5: Docked→Handheld transition guard ──────────────────────────────
test_docked_to_handheld() {
    _header "Test 5: Docked→Handheld — 2+ players, undock keeps P1 only"

    _inject "DISPLAY_MODE_CHANGE docked"
    sleep 1

    # Launch 2 players
    _prep_slot 1
    _inject "CONTROLLER_ADD /dev/null /dev/null"
    _wait_for_slot_active 1 30 "Test 5"
    _wait_for_minecraft_ready 1 360 "Test 5-P1" || { return; }
    _prep_slot 2
    _inject "CONTROLLER_ADD /dev/null /dev/null"
    _wait_for_slot_active 2 30 "Test 5"
    _wait_for_minecraft_ready 2 360 "Test 5-P2" || { return; }

    _info "Test 5: 2 players active, simulating undock..."

    # Switch to handheld — should kill slot 2, keep slot 1.
    # _inject returns once the message is consumed by docked_flow; the teardown
    # of slot 2 happens AFTER that, so wait for it explicitly instead of sleeping.
    _inject "DISPLAY_MODE_CHANGE handheld"

    if _wait_for_slot_inactive 2 30 "Test 5"; then
        _pass "Test 5.1 — Slot 2 torn down on undock"
    else
        _fail "Test 5.1 — Slot 2 survived dock→handheld transition (should have been torn down)"
    fi

    # Slot 1 should survive (it's P1 / Deck controls)
    if slot_is_active 1 2>/dev/null; then
        _pass "Test 5.2 — Slot 1 survives undock (Deck controls)"
    else
        _fail "Test 5.2 — Slot 1 was incorrectly torn down on undock"
    fi

    _inject "SLOT_DIED 1"
    _wait_for_slot_inactive 1 15 "Test 5 cleanup"
}

# ── Test 6: Load timing under render contention ──────────────────────────
test_load_timing() {
    _header "Test 6: Load timing — measure real instance load time under contention"

    _inject "DISPLAY_MODE_CHANGE docked"
    sleep 1

    # Launch P1, time to main menu
    _info "Timing load for P1 (solo)..."
    local t_start t_end elapsed
    t_start=$(date +%s%N)
    _prep_slot 1
    _inject "CONTROLLER_ADD /dev/null /dev/null"
    _wait_for_slot_active 1 30 "Test 6-P1" || { _fail "Test 6 — Slot 1 bwrap did not start"; return; }
    _wait_for_minecraft_ready 1 360 "Test 6-P1" || { return; }
    t_end=$(date +%s%N)
    elapsed=$(( (t_end - t_start) / 1000000 ))
    _info "P1 load time to main menu: ${elapsed}ms"
    echo "TIMING|P1|${elapsed}" >> "$LOG"

    # Launch P2 with P1 already rendering, time to main menu
    _info "Timing load for P2 (with P1 already rendering)..."
    t_start=$(date +%s%N)
    _prep_slot 2
    _inject "CONTROLLER_ADD /dev/null /dev/null"
    _wait_for_slot_active 2 30 "Test 6-P2" || { _fail "Test 6 — Slot 2 bwrap did not start"; return; }
    _wait_for_minecraft_ready 2 360 "Test 6-P2" || { return; }
    t_end=$(date +%s%N)
    elapsed=$(( (t_end - t_start) / 1000000 ))
    _info "P2 load time to main menu (with render contention): ${elapsed}ms"
    echo "TIMING|P2|${elapsed}" >> "$LOG"

    _info "Timing results recorded. Baseline comparison available after test."

    # Clean up
    _inject "SLOT_DIED 1"
    _inject "SLOT_DIED 2"
    _wait_for_slot_inactive 1 15
    _wait_for_slot_inactive 2 15
}

# ── Test 7: Full lifecycle ────────────────────────────────────────────────
test_full_lifecycle() {
    _header "Test 7: Full lifecycle — 4 players, P2 dies mid-session, P4 quits cleanly"

    _inject "DISPLAY_MODE_CHANGE docked"
    sleep 1

    # Launch 4 players
    for slot in 1 2 3 4; do
        _prep_slot "$slot"
        _inject "CONTROLLER_ADD /dev/null /dev/null"
        _wait_for_slot_active "$slot" 30 "Test 7" || { _fail "Test 7.1 — Slot $slot did not start"; return; }
        _wait_for_minecraft_ready "$slot" 360 "Test 7-P${slot}" || { return; }
    done

    sleep 3
    local active
    active=$(get_active_slots 2>/dev/null | wc -w)
    if (( active == 4 )); then
        _pass "Test 7.2 — All 4 slots active"
    else
        _fail "Test 7.2 — Expected 4 active, got $active"
    fi

    # P2 dies (simulate crash)
    _info "Simulating P2 crash..."
    _inject "SLOT_DIED 2"
    if _wait_for_slot_inactive 2 30 "Test 7"; then
        _pass "Test 7.3 — Slot 2 torn down on crash"
    else
        _fail "Test 7.3 — Slot 2 still active after crash"
    fi

    # Verify 1, 3, 4 remain
    local count
    count=$(get_active_slots 2>/dev/null | wc -w)
    _info "Active after P2 death: $(get_active_slots 2>/dev/null)"
    if (( count == 3 )); then
        _pass "Test 7.4 — 3 slots remain (P1, P3, P4)"
    else
        _fail "Test 7.4 — Expected 3, got $count"
    fi

    # P4 quits voluntarily
    _inject "CONTROLLER_REMOVE 4"
    if _wait_for_slot_inactive 4 30 "Test 7"; then
        _pass "Test 7.5 — Slot 4 torn down on quit"
    else
        _fail "Test 7.5 — Slot 4 still active after quit"
    fi

    # Verify final state: 2 slots (P1, P3)
    count=$(get_active_slots 2>/dev/null | wc -w)
    if (( count == 2 )); then
        _pass "Test 7.6 — Final state: 2 slots"
    else
        _fail "Test 7.6 — Expected 2, got $count"
    fi

    # Clean up — wait for teardowns so the next test starts clean
    _inject "CONTROLLER_REMOVE 1"
    _wait_for_slot_inactive 1 30 "Test 7 cleanup"
    _inject "CONTROLLER_REMOVE 3"
    _wait_for_slot_inactive 3 30 "Test 7 cleanup"
}

# ── Main dispatch ──────────────────────────────────────────────────────────
_main() {
    echo "=== $(date) PHASE B LIFECYCLE TEST ===" > "$LOG"
    echo "FIFO: $FIFO" >> "$LOG"
    echo "State: ${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}" >> "$LOG"
    echo "" >> "$LOG"

    local tests=()
    case "${1:-all}" in
        1) tests=(test_handheld_single_player) ;;
        2) tests=(test_docked_two_players) ;;
        3) tests=(test_docked_three_players) ;;
        4) tests=(test_max_four) ;;
        5) tests=(test_docked_to_handheld) ;;
        6) tests=(test_load_timing) ;;
        7) tests=(test_full_lifecycle) ;;
        all|*) tests=(test_handheld_single_player test_docked_two_players
                      test_docked_three_players test_max_four
                      test_docked_to_handheld test_load_timing
                      test_full_lifecycle) ;;
    esac

    _info "Running ${#tests[@]} test(s)..."
    for t in "${tests[@]}"; do
        "$t" 2>&1 | tee -a "$LOG" || _fail "Test $t exited with error"
    done

    _clean_instances

    echo "" | tee -a "$LOG"
    echo "=== PHASE B TEST COMPLETE ===" | tee -a "$LOG"
    echo "Results logged to: $LOG" | tee -a "$LOG"
    grep -c "PASS" "$LOG" 2>/dev/null && _info "Passes: $(grep -c '\[PASS\]' "$LOG")"
    grep -c "FAIL" "$LOG" 2>/dev/null && _info "Failures: $(grep -c '\[FAIL\]' "$LOG")"
}

_main "$@"
