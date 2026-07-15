#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: watchdog.sh
# =============================================================================
# All tests mock $SPLITSCREEN_STATE with crafted JSON files.
# No hardware, root, or real processes required.
# Run: bash tests/test_watchdog.sh
# =============================================================================

readonly TEST_TOTAL=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Fix #51 (D11): watchdog consumes the instance_lifecycle state accessors
# now — source it first, same relative order as runtime_modules.list.
source "$REPO_ROOT/modules/instance_lifecycle.sh"
source "$REPO_ROOT/modules/watchdog.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# =============================================================================
# T5.1 — dead PID → SLOT_DIED emitted
# =============================================================================
test_t5_1() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"  # keep write end open

    # Spawn a short-lived process, capture its PID, let it die
    sleep 0.1 &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true  # ensure it's dead

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":null,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":$dead_pid},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    SPLITSCREEN_STATE="$state_file" \
        SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 \
        start_watchdog &
    local wd_pid=$!

    local line
    if read -r -t 3 line < "$fifo"; then
        if [[ "$line" == "SLOT_DIED 1" ]]; then
            _pass "T5.1 — SLOT_DIED 1 emitted for dead bwrap PID"
        else
            _fail "T5.1" "expected 'SLOT_DIED 1', got '$line'"
        fi
    else
        _fail "T5.1" "timed out waiting for SLOT_DIED"
    fi

    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# T5.2 — alive PID ($$) → no message
# =============================================================================
test_t5_2() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":null,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":$$},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    SPLITSCREEN_STATE="$state_file" \
        SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 \
        start_watchdog &
    local wd_pid=$!

    sleep 0.4

    local line
    if read -r -t 0.3 line < "$fifo"; then
        _fail "T5.2" "unexpected message: '$line'"
    else
        _pass "T5.2 — no SLOT_DIED for alive bwrap PID ($$)"
    fi

    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# T5.3 — inactive slot → no message
# =============================================================================
test_t5_3() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    # Dead PID but slot is inactive
    sleep 0.1 &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":$dead_pid},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    SPLITSCREEN_STATE="$state_file" \
        SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 \
        start_watchdog &
    local wd_pid=$!

    sleep 0.4

    local line
    if read -r -t 0.3 line < "$fifo"; then
        _fail "T5.3" "unexpected message for inactive slot: '$line'"
    else
        _pass "T5.3 — no SLOT_DIED for inactive slot (active: false)"
    fi

    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# T5.4 — bwrap_pid null → no message
# =============================================================================
test_t5_4() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    cat > "$state_file" <<'JSON'
{"mode":"docked","slots":{"1":{"active":true,"pid":null,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    SPLITSCREEN_STATE="$state_file" \
        SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 \
        start_watchdog &
    local wd_pid=$!

    sleep 0.4

    local line
    if read -r -t 0.3 line < "$fifo"; then
        _fail "T5.4" "unexpected message for null bwrap_pid: '$line'"
    else
        _pass "T5.4 — no SLOT_DIED when bwrap_pid is null"
    fi

    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# T5.5 — exact format: ^SLOT_DIED [1-4]$
# =============================================================================
test_t5_5() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    sleep 0.1 &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":null,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":$dead_pid},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    SPLITSCREEN_STATE="$state_file" \
        SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 \
        start_watchdog &
    local wd_pid=$!

    local line
    if read -r -t 3 line < "$fifo"; then
        if [[ "$line" =~ ^SLOT_DIED\ [1-4]$ ]]; then
            _pass "T5.5 — exact format: '$line' matches ^SLOT_DIED [1-4]\$"
        else
            _fail "T5.5" "format mismatch: '$line'"
        fi
    else
        _fail "T5.5" "timed out waiting for SLOT_DIED"
    fi

    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# T5.6 — multiple dead slots emit multiple SLOT_DIED in one cycle
# =============================================================================
test_t5_6() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    sleep 0.1 &
    local dead1=$!
    sleep 0.1 &
    local dead2=$!
    wait "$dead1" 2>/dev/null || true
    wait "$dead2" 2>/dev/null || true

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":null,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":$dead1},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":true,"pid":null,"event_node":"/dev/input/event5","js_node":"/dev/input/js2","bwrap_pid":$dead2},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    SPLITSCREEN_STATE="$state_file" \
        SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 \
        start_watchdog &
    local wd_pid=$!

    local lines=()
    local l
    while IFS= read -r -t 3 l; do
        lines+=("$l")
        if (( ${#lines[@]} >= 2 )); then
            break
        fi
    done < "$fifo"

    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"

    local has_1=0 has_3=0
    for l in "${lines[@]}"; do
        [[ "$l" == "SLOT_DIED 1" ]] && has_1=1
        [[ "$l" == "SLOT_DIED 3" ]] && has_3=1
    done

    if (( has_1 == 1 && has_3 == 1 )); then
        _pass "T5.6 — both SLOT_DIED 1 and SLOT_DIED 3 emitted"
    else
        _fail "T5.6" "got ${#lines[@]} lines: ${lines[*]}"
    fi
}

# =============================================================================
# T5.7 — dedup: no re-emit until slot reset (active: false)
# =============================================================================
test_t5_7() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    sleep 0.1 &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":null,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":$dead_pid},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    SPLITSCREEN_STATE="$state_file" \
        SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 \
        start_watchdog &
    local wd_pid=$!

    # Read first SLOT_DIED
    local first_line
    if read -r -t 3 first_line < "$fifo"; then
        if [[ "$first_line" != "SLOT_DIED 1" ]]; then
            _fail "T5.7" "expected SLOT_DIED 1, got '$first_line'"
        fi
    else
        _fail "T5.7" "timed out waiting for first SLOT_DIED"
    fi

    # Wait for several more poll cycles — should NOT re-emit
    sleep 0.6

    local extra_line
    if read -r -t 0.3 extra_line < "$fifo"; then
        _fail "T5.7" "SLOT_DIED re-emitted before reset: '$extra_line'"
    fi

    # Now reset slot to inactive
    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    sleep 0.4

    # Should be ready to emit again (no actual re-emit since inactive)
    # Verify the watchdog didn't crash — it's still running
    if kill -0 "$wd_pid" 2>/dev/null; then
        _pass "T5.7 — dedup: no re-emit before reset, watchdog still alive after reset"
    else
        _fail "T5.7" "watchdog died"
    fi

    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# T5.8 — window GONE while process alive → SLOT_DIED (#37: player quit, JVM may hang)
# =============================================================================
test_t5_8() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    local state_file="$tmpdir/state.json" fifo="$tmpdir/fifo"
    mkfifo "$fifo"; exec 9<>"$fifo"

    # Process is ALIVE ($$ — so the pid check can't fire), but the slot's window
    # (wid 12345) is NOT in the window tree → window-gone must drive SLOT_DIED.
    dex_list_windows() { echo "999  root"; echo "111  plasmashell"; }

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":$$,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":$$,"wid":12345},"2":{"active":false},"3":{"active":false},"4":{"active":false}}}
JSON

    SPLITSCREEN_STATE="$state_file" SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 start_watchdog &
    local wd_pid=$!

    local line
    if read -r -t 3 line < "$fifo"; then
        if [[ "$line" == "SLOT_DIED 1" ]]; then
            _pass "T5.8 — window gone (alive process) → SLOT_DIED 1"
        else
            _fail "T5.8" "expected 'SLOT_DIED 1', got '$line'"
        fi
    else
        _fail "T5.8" "timed out — window-gone did not emit SLOT_DIED"
    fi

    kill "$wd_pid" 2>/dev/null || true; wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true; rm -f "$fifo"; unset -f dex_list_windows 2>/dev/null || true
}

# =============================================================================
# T5.9 — window PRESENT (alive process) → no SLOT_DIED
# =============================================================================
test_t5_9() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    local state_file="$tmpdir/state.json" fifo="$tmpdir/fifo"
    mkfifo "$fifo"; exec 9<>"$fifo"

    # wid 12345 IS in the window tree → must NOT emit (even if the caption changed).
    dex_list_windows() { echo "12345  Minecraft* 26.1.2"; echo "999  root"; }

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":$$,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":$$,"wid":12345},"2":{"active":false},"3":{"active":false},"4":{"active":false}}}
JSON

    SPLITSCREEN_STATE="$state_file" SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 start_watchdog &
    local wd_pid=$!

    sleep 0.6
    local line
    if read -r -t 0.3 line < "$fifo"; then
        _fail "T5.9" "unexpected message while window present: '$line'"
    else
        _pass "T5.9 — window present → no SLOT_DIED"
    fi

    kill "$wd_pid" 2>/dev/null || true; wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true; rm -f "$fifo"; unset -f dex_list_windows 2>/dev/null || true
}

# =============================================================================
# T5.10 — wid null (mid-spawn) → window check skipped, no SLOT_DIED
# =============================================================================
test_t5_10() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    local state_file="$tmpdir/state.json" fifo="$tmpdir/fifo"
    mkfifo "$fifo"; exec 9<>"$fifo"

    # dex would report the window absent, but wid is null (still spawning) → must SKIP
    # the window check entirely and NOT kill the launching instance.
    dex_list_windows() { echo "999  root"; }

    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":$$,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":$$,"wid":null},"2":{"active":false},"3":{"active":false},"4":{"active":false}}}
JSON

    SPLITSCREEN_STATE="$state_file" SPLITSCREEN_FIFO="$fifo" \
        WATCHDOG_POLL_INTERVAL_S=0.1 start_watchdog &
    local wd_pid=$!

    sleep 0.6
    local line
    if read -r -t 0.3 line < "$fifo"; then
        _fail "T5.10" "killed a mid-spawn instance (wid null): '$line'"
    else
        _pass "T5.10 — wid null (mid-spawn) → window check skipped, no SLOT_DIED"
    fi

    kill "$wd_pid" 2>/dev/null || true; wait "$wd_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true; rm -f "$fifo"; unset -f dex_list_windows 2>/dev/null || true
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
test_t5_8
test_t5_9
test_t5_10
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
