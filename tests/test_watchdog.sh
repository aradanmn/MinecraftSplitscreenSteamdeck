#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: watchdog.sh
# =============================================================================
# Tests the bwrap PID watchdog module.
# Uses real background processes and temp FIFOs.
# No hardware, root, or Steam client required.
# Run: bash tests/test_watchdog.sh
# =============================================================================

readonly TEST_TOTAL=7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/modules/watchdog.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# _dead_pid: spawn a process, kill it, return its PID (guaranteed dead)
_dead_pid() {
    local pid
    sleep 300 &
    pid=$!
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "$pid"
}

# _make_state: write a minimal state JSON to $1
# Usage: _make_state <file> <slot> <active> <bwrap_pid_value>
# bwrap_pid_value: an integer, or the literal string "null"
_make_state() {
    local file="$1"
    local slot="$2"
    local active="$3"
    local bwrap_pid="$4"   # integer or "null"
    local bwrap_json="$bwrap_pid"
    cat > "$file" <<JSON
{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON
    # Patch the target slot using jq
    local tmp_file="${file}.tmp.$$"
    jq --arg slot "$slot" \
       --argjson active "$active" \
       --argjson bwrap_json "$bwrap_json" \
       '.slots[$slot].active = $active | .slots[$slot].bwrap_pid = $bwrap_json' \
       "$file" > "$tmp_file" && mv "$tmp_file" "$file"
}

# =============================================================================
# T5.1 — SLOT_DIED emitted for dead bwrap PID
# =============================================================================
test_t5_1() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    mkfifo "$fifo"
    exec 9>"$fifo"   # keep write end open so watchdog can open FIFO

    local dead="$(_dead_pid)"
    _make_state "$state" "1" "true" "$dead"

    SPLITSCREEN_STATE="$state" \
    SPLITSCREEN_FIFO="$fifo" \
    WATCHDOG_POLL_INTERVAL_S=0.1 \
    start_watchdog &
    local watchdog_pid=$!

    local msg=""
    if read -r -t 3 msg < "$fifo"; then
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        if [[ "$msg" == "SLOT_DIED 1" ]]; then
            _pass "T5.1 — SLOT_DIED emitted for dead bwrap PID"
        else
            _fail "T5.1" "expected 'SLOT_DIED 1', got '$msg'"
        fi
    else
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _fail "T5.1" "timed out waiting for SLOT_DIED message"
    fi
}

# =============================================================================
# T5.2 — No SLOT_DIED when bwrap PID is alive
# =============================================================================
test_t5_2() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    mkfifo "$fifo"
    exec 9>"$fifo"

    _make_state "$state" "1" "true" "$$"   # $$ = current shell, definitely alive

    SPLITSCREEN_STATE="$state" \
    SPLITSCREEN_FIFO="$fifo" \
    WATCHDOG_POLL_INTERVAL_S=0.1 \
    start_watchdog &
    local watchdog_pid=$!

    # Wait a few poll cycles, then check nothing arrived
    local msg=""
    if read -r -t 0.5 msg < "$fifo" 2>/dev/null; then
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _fail "T5.2" "unexpected FIFO message for alive PID: '$msg'"
    else
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _pass "T5.2 — no SLOT_DIED for alive bwrap PID"
    fi
}

# =============================================================================
# T5.3 — No SLOT_DIED for inactive slot (active=false)
# =============================================================================
test_t5_3() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    mkfifo "$fifo"
    exec 9>"$fifo"

    local dead="$(_dead_pid)"
    _make_state "$state" "1" "false" "$dead"   # inactive, dead PID — should be ignored

    SPLITSCREEN_STATE="$state" \
    SPLITSCREEN_FIFO="$fifo" \
    WATCHDOG_POLL_INTERVAL_S=0.1 \
    start_watchdog &
    local watchdog_pid=$!

    local msg=""
    if read -r -t 0.5 msg < "$fifo" 2>/dev/null; then
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _fail "T5.3" "unexpected SLOT_DIED for inactive slot: '$msg'"
    else
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _pass "T5.3 — no SLOT_DIED for inactive slot (active=false)"
    fi
}

# =============================================================================
# T5.4 — No SLOT_DIED when bwrap_pid is null
# =============================================================================
test_t5_4() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    mkfifo "$fifo"
    exec 9>"$fifo"

    _make_state "$state" "1" "true" "null"   # active but no PID yet

    SPLITSCREEN_STATE="$state" \
    SPLITSCREEN_FIFO="$fifo" \
    WATCHDOG_POLL_INTERVAL_S=0.1 \
    start_watchdog &
    local watchdog_pid=$!

    local msg=""
    if read -r -t 0.5 msg < "$fifo" 2>/dev/null; then
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _fail "T5.4" "unexpected SLOT_DIED for null bwrap_pid: '$msg'"
    else
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _pass "T5.4 — no SLOT_DIED when bwrap_pid is null"
    fi
}

# =============================================================================
# T5.5 — Message format: "SLOT_DIED <digit>" (exact, no extra whitespace)
# =============================================================================
test_t5_5() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    mkfifo "$fifo"
    exec 9>"$fifo"

    local dead="$(_dead_pid)"
    _make_state "$state" "2" "true" "$dead"

    SPLITSCREEN_STATE="$state" \
    SPLITSCREEN_FIFO="$fifo" \
    WATCHDOG_POLL_INTERVAL_S=0.1 \
    start_watchdog &
    local watchdog_pid=$!

    local msg=""
    if read -r -t 3 msg < "$fifo"; then
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        if [[ "$msg" =~ ^SLOT_DIED\ [1-4]$ ]]; then
            _pass "T5.5 — SLOT_DIED message format: '$msg'"
        else
            _fail "T5.5" "format wrong: '$msg' (expected SLOT_DIED <1-4>)"
        fi
    else
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _fail "T5.5" "timed out waiting for SLOT_DIED message"
    fi
}

# =============================================================================
# T5.6 — Multiple dead slots emit multiple SLOT_DIED messages
# =============================================================================
test_t5_6() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    mkfifo "$fifo"
    exec 9>"$fifo"

    local dead1; dead1=$(_dead_pid)
    local dead3; dead3=$(_dead_pid)

    # Slots 1 and 3 active with dead PIDs; 2 and 4 inactive
    cat > "$state" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":${dead1}},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":true,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":${dead3}},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    SPLITSCREEN_STATE="$state" \
    SPLITSCREEN_FIFO="$fifo" \
    WATCHDOG_POLL_INTERVAL_S=0.1 \
    start_watchdog &
    local watchdog_pid=$!

    local msg1="" msg2=""
    local got=0
    if read -r -t 3 msg1 < "$fifo"; then
        got=$((got + 1))
        if read -r -t 2 msg2 < "$fifo"; then
            got=$((got + 1))
        fi
    fi

    kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
    exec 9>&-

    if (( got == 2 )); then
        local slots_found=""
        for m in "$msg1" "$msg2"; do
            if [[ "$m" =~ ^SLOT_DIED\ ([1-4])$ ]]; then
                slots_found="$slots_found ${BASH_REMATCH[1]}"
            fi
        done
        # Both slot 1 and slot 3 should appear
        if [[ "$slots_found" == *"1"* && "$slots_found" == *"3"* ]]; then
            _pass "T5.6 — multiple dead slots: got SLOT_DIED for slots 1 and 3"
        else
            _fail "T5.6" "expected slots 1 and 3, got:$slots_found"
        fi
    else
        _fail "T5.6" "expected 2 SLOT_DIED messages, got $got (msg1='$msg1' msg2='$msg2')"
    fi
}

# =============================================================================
# T5.7 — Deduplication: SLOT_DIED not re-emitted until slot is reset
# =============================================================================
test_t5_7() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    mkfifo "$fifo"
    exec 9>"$fifo"

    local dead; dead=$(_dead_pid)
    _make_state "$state" "1" "true" "$dead"

    SPLITSCREEN_STATE="$state" \
    SPLITSCREEN_FIFO="$fifo" \
    WATCHDOG_POLL_INTERVAL_S=0.1 \
    start_watchdog &
    local watchdog_pid=$!

    # Read the first SLOT_DIED
    local first_msg=""
    if ! read -r -t 3 first_msg < "$fifo"; then
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _fail "T5.7" "timed out waiting for first SLOT_DIED"
        return
    fi

    # State file unchanged (orchestrator hasn't cleared it yet).
    # Wait several more poll cycles. Should NOT get a second SLOT_DIED.
    local second_msg=""
    if read -r -t 0.7 second_msg < "$fifo" 2>/dev/null; then
        kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
        exec 9>&-
        _fail "T5.7" "SLOT_DIED re-emitted before slot was reset (dedup failed): '$second_msg'"
        return
    fi

    kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true
    exec 9>&-

    if [[ "$first_msg" == "SLOT_DIED 1" ]]; then
        _pass "T5.7 — deduplication: SLOT_DIED emitted once, not repeated (first='$first_msg')"
    else
        _fail "T5.7" "unexpected first message: '$first_msg'"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== watchdog test suite ==="
echo ""

test_t5_1
test_t5_2
test_t5_3
test_t5_4
test_t5_5
test_t5_6
test_t5_7

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
